//  BandFIRPEQDesigner.swift
//  5Band FIR PEQ の係数を作って instance へ送り込む。
//
//  カーネル（Vendor/effetune/dsp/plugins/eq/five_band_fir_peq/kernel.cpp）が持っている
//  パラメータは 2 つだけで（params.json:8-11）、5 本の帯域の設定はどこにも無い。
//  帯域から FIR 係数を設計するのは JS 側の仕事で、その場所が
//  Vendor/effetune/js/five-band-fir-peq/design-core.js:327-397（designFiveBandFirPeq）。
//  ここはその設計を Swift へ移したもの。DSP 本体には一切触っていない。
//  設計の半分（Foundationだけ）はBandFIRPEQDesign.swiftへ分けた。ここは送り込む半分。
//
//  --- カーネルが資産として何を期待しているか ---
//  読み取り側は kernel.cpp の 2 か所。
//
//  beginAsset の入口（validateBegin、kernel.cpp:266-280）:
//    channels == 1                      IR は 1 本だけ
//    topology == 1 (mono)               kMonoTopology
//    frames は 1〜131072
//    headBlock は 0 / 128 / 256 / 512 / 1024
//    rateDivider == 1、pathCount == 0、inputCount == 0
//    0 <= params_.filterDelaySamples <= 65536
//    byteSize == 32 + channels * frames * 4   ← 頭 32 バイト + float32 の本体
//    footprintBytes は byteSize 以上 32MiB 以下
//  **filterDelaySamples を見ているので、資産より先にパラメータを送らないと弾かれる。**
//  beginAsset の先頭で applyPendingParameters() を呼んでいる（kernel.cpp:171）ので、
//  et_instance_set_params → asset_begin の順なら音が鳴っていなくても反映される
//  （engine.cpp:461 の stageParameters はその場で書く）。
//
//  commitAsset が見る中身（validatePayload、kernel.cpp:282-289）:
//    +0  u32 0x31415445 (kAssetMagic)
//    +4  u32 channels    ( == begin の channels )
//    +8  u32 frames      ( == begin の frames )
//    +12 u32 sampleRate  ( == (uint32)(sample_rate_ + 0.5f) なので engine と同じ整数 )
//    +16 u32 1           ( kMonoTopology )
//    +20 u32 0
//    +24 u32 0
//    +28 u32 0
//    +32     float32 が frames 個（kernel.cpp:223 で頭 32 バイトを飛ばして読む）
//  書き手側の同じ並びは js/ir-library/ir-asset-payload.js:74-93。
//  組み立ては AssetUpload.makePayload が持っているので、ここでは係数を渡すだけ。
//
//  latencySamples は headBlock + filterDelaySamples（kernel.cpp:207）。
//  最小位相なら filterDelaySamples は 0、線形位相なら taps/2 を入れる。
//  これは JS も同じで、plugins/eq/five_band_fir_peq.js:94-100 の _packedParameters が
//  `fd: this.pm === 'min' ? 0 : this.tp / 2` と書いている。
//
//  --- 重いので音のスレッドでは作らない ---
//  JS は設計を Worker へ出している（js/five-band-fir-peq/design-worker.js）。
//  taps が 131072 のとき FFT の大きさは 262144 で、逆変換 2 回と前進変換 2 回、
//  それに 131073 本の bin ぶんの pow() が走る。ここも同じ扱いにして、
//  設計は Task.detached、送り込みだけ MainActor でやる。
//
//  --- 送り込んだ後 ---
//  commit が通ると instance の遅延が変わるので、鎖を publish し直して
//  et_pipeline_configure に遅延補正を組み直させる（AssetUpload.swift:46-50 の但し書き）。
//  JS も同じ場所で refreshDspPipelineForLatencyChange を呼んでいる。

import Combine
import Foundation
import os

// MARK: - 設計して送り込む

/// instance 1 個ぶんの面倒を見る。画面はこれを持って設定を書き換える。
@MainActor
final class BandFIRPEQDesigner: ObservableObject {

    /// 画面に出す状態。文言は英語。
    enum Status: Equatable {
        case idle
        case designing
        case staging
        case ready(latencySamples: Int, maximumErrorDb: Double)
        case unsupported
        case failed(String)

        var message: String {
            switch self {
            case .idle:
                return "Preparing the FIR filter…"
            case .designing:
                return "Designing the FIR filter…"
            case .staging:
                return "Loading the filter…"
            case .ready(let latencySamples, let maximumErrorDb):
                let accuracy = maximumErrorDb > 0.5
                    ? String(format: " Accuracy is off by up to %.1f dB.", maximumErrorDb)
                    : ""
                return "Filter running. Latency \(latencySamples) samples." + accuracy
            case .unsupported:
                return "This build cannot load FIR filters."
            case .failed(let text):
                return text
            }
        }

        var isFailure: Bool {
            switch self {
            case .failed, .unsupported: return true
            default: return false
            }
        }
    }

    static let kernelType = "FiveBandFIRPEQPlugin"

    /// JS と同じ待ち。plugins/eq/five_band_fir_peq.js:181 が 150ms で仕掛けている。
    private static let debounceMilliseconds: UInt64 = 150

    private let log = Logger(subsystem: "ai.nemut.effetune", category: "fir-peq")

    /// 送り先。EffeTuneDSP.Node.instance と同じ番号。
    let instance: UInt32

    @Published private(set) var status: Status = .idle
    /// 直近に出来上がったもの。応答の曲線を引くのに使う。
    @Published private(set) var latestDesign: BandFIRPEQDesign?

    /// 帯域の設定。書き換えると作り直して送り直す。
    @Published var settings: BandFIRPEQSettings {
        didSet { settingsChanged(from: oldValue) }
    }

    /// engine の sample rate。変わったら設計からやり直す。
    private(set) var sampleRate: Double
    /// engine が出しているチャンネル数。processingChannels の計算に要る。
    private(set) var outputChannelCount: Int

    private var generation = 0
    private var pending: Task<Void, Never>?

    init(instance: UInt32,
         settings: BandFIRPEQSettings = .default,
         sampleRate: Double = 48000,
         outputChannelCount: Int = 2) {
        self.instance = instance
        self.settings = settings
        self.sampleRate = sampleRate
        self.outputChannelCount = outputChannelCount
    }

    // deinit は置いていない。@MainActor の持ち物を非隔離の deinit から触ると
    // 言語版によって通らなくなる。仕掛けてある Task は [weak self] なので、
    // この物が消えれば次の再開で自分から抜ける。

    /// 送り込める build かどうか。false のあいだは画面に出す前に諦められる。
    /// 中身は AssetUpload.swift:217-226 の但し書きのとおり。
    var canStage: Bool { AssetUpload.canStage }

    // MARK: 外からの合図

    /// 最初の 1 回。instance を作ってパラメータを押し込んだ直後に呼ぶ。
    func start() {
        schedule(delayMilliseconds: 0)
    }

    /// engine の都合が変わったとき。JS も commitSampleRate で待たずに仕掛け直す
    /// （five_band_fir_peq.js:113-117）。
    func update(sampleRate: Double, outputChannelCount: Int) {
        guard sampleRate != self.sampleRate || outputChannelCount != self.outputChannelCount else {
            return
        }
        self.sampleRate = sampleRate
        self.outputChannelCount = outputChannelCount
        schedule(delayMilliseconds: 0)
    }

    /// 作り直して送り直す。控えは使わない。
    func refresh() {
        schedule(delayMilliseconds: 0)
    }

    // MARK: 中身

    private func settingsChanged(from previous: BandFIRPEQSettings) {
        guard settings != previous else { return }
        // 遅延だけが違うなら係数は同じ。JS も作り直さずに送り直している
        // （five_band_fir_peq.js:182 の `_stageDesign(this._lastDesign)`）。
        let sameDesign = BandFIRPEQConfig(settings: settings, sampleRate: sampleRate)
            == BandFIRPEQConfig(settings: previous, sampleRate: sampleRate)
        if sameDesign, let design = latestDesign {
            restage(design)
            return
        }
        schedule(delayMilliseconds: Self.debounceMilliseconds)
    }

    private func schedule(delayMilliseconds: UInt64) {
        generation &+= 1
        let generation = self.generation
        pending?.cancel()
        status = .designing
        let config = BandFIRPEQConfig(settings: settings, sampleRate: sampleRate)
        pending = Task { @MainActor [weak self] in
            if delayMilliseconds > 0 {
                try? await Task.sleep(nanoseconds: delayMilliseconds * 1_000_000)
            }
            if Task.isCancelled { return }
            guard let self else { return }
            await self.designAndStage(config: config, generation: generation)
        }
    }

    private func designAndStage(config: BandFIRPEQConfig, generation: Int) async {
        do {
            // **ここが重い。** 設計は音のスレッドでもメインスレッドでもやらない。
            let design = try await Task.detached(priority: .userInitiated) {
                try BandFIRPEQCore.design(config)
            }.value
            guard generation == self.generation else { return }
            latestDesign = design
            try await stage(design)
        } catch is CancellationError {
            return
        } catch {
            guard generation == self.generation else { return }
            report(error)
        }
    }

    private func restage(_ design: BandFIRPEQDesign) {
        generation &+= 1
        let generation = self.generation
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            // 走り出す前に後の仕掛けに取り消されたら送らない（scheduleと同じ）。
            // stageは取り消しを見ずに送り込むので、ここで見ないと古い係数を送ってしまう。
            if Task.isCancelled { return }
            guard let self else { return }
            do {
                try await self.stage(design)
            } catch is CancellationError {
                return
            } catch {
                guard generation == self.generation else { return }
                self.report(error)
            }
        }
    }

    private func stage(_ design: BandFIRPEQDesign) async throws {
        let dsp = EffeTuneDSP.shared
        guard dsp.engine != 0, instance != 0 else { throw BandFIRPEQDesignError.instanceMissing }
        guard AssetUpload.canStage else { throw ETAssetUploadError.stagingAddressUnavailable }

        let channels = processingChannels()
        guard channels >= 1 else { throw BandFIRPEQDesignError.channelsUnavailable }

        status = .staging
        // **資産より先にパラメータ。** beginAsset が filterDelaySamples を見る
        // （kernel.cpp:207 と :274-275）。
        pushKernelParameters(filterDelaySamples: design.filterDelaySamples)

        try AssetUpload.send(engine: dsp.engine,
                             instance: instance,
                             slot: 0,
                             channels: design.channels,
                             sampleRate: design.config.sampleRate,
                             topology: .mono,
                             headBlock: UInt32(settings.latency.rawValue),
                             rateDivider: 1,
                             processingChannels: UInt32(channels))

        // commit が通ると遅延が変わる。鎖を組み直させる。
        republishForLatencyChange()

        let latency = settings.latency.rawValue + design.filterDelaySamples
        // 分割畳み込みは音が何ブロックか通ってから active になる。
        // 無音のあいだは preparing のまま進まないので、待つのは期限つき。
        let state = await AssetUpload.waitForActive(engine: dsp.engine, instance: instance, slot: 0)
        if state.state == .error {
            throw BandFIRPEQDesignError.kernelRefused(reason: state.reason)
        }
        status = .ready(latencySamples: latency, maximumErrorDb: design.maximumErrorDb)

        // os_log の補間は自動クロージャなので、self を捕まえないよう控えてから渡す
        // （EffeTuneDSP.swift:228 も同じ理由で控えている）。
        let instanceId = instance
        let taps = design.config.taps
        let rate = design.config.sampleRate
        let errorDb = design.maximumErrorDb
        log.notice("5Band FIR PEQ instance=\(instanceId) taps=\(taps) rate=\(rate) latency=\(latency) errDb=\(errorDb)")
    }

    private func report(_ error: Error) {
        // Error は存在型なので、enum の case で照合する前に降ろす。
        if let upload = error as? ETAssetUploadError,
           case .stagingAddressUnavailable = upload {
            status = .unsupported
        } else {
            status = .failed((error as? LocalizedError)?.errorDescription
                             ?? "The FIR filter could not be prepared.")
        }
        let instanceId = instance
        let text = String(describing: error)
        log.error("5Band FIR PEQ instance=\(instanceId) \(text, privacy: .public)")
    }

    // MARK: パラメータ

    /// lt（頭ブロックの添字）と fd（足す遅延）をカーネルへ渡す。
    /// 鎖に並んでいる instance なら EffeTuneDSP 側の控えも一緒に書き換えて、
    /// 作り直しのときに同じ値が出るようにする。
    private func pushKernelParameters(filterDelaySamples: Int) {
        let dsp = EffeTuneDSP.shared
        guard let index = dsp.nodes.firstIndex(where: { $0.instance == instance }) else {
            pushKernelParametersDirectly(filterDelaySamples: filterDelaySamples)
            return
        }
        let spec = dsp.nodes[index].spec
        let latencyOffset = spec.params.first { $0.name == "latencyMode" }?.offset ?? 0
        let delayOffset = spec.params.first { $0.name == "filterDelaySamples" }?.offset ?? 1
        dsp.setValue(settings.latency.parameterIndex, at: index, offset: latencyOffset)
        dsp.setValue(Float(filterDelaySamples), at: index, offset: delayOffset)
    }

    /// 鎖に無い instance（自前で作ったもの）へ直に押し込む。
    private func pushKernelParametersDirectly(filterDelaySamples: Int) {
        guard let spec = ETCatalog.first(where: { $0.type == Self.kernelType }),
              spec.floatCount > 0,
              spec.defaults.count == spec.floatCount else { return }
        let latencyOffset = spec.params.first { $0.name == "latencyMode" }?.offset ?? 0
        let delayOffset = spec.params.first { $0.name == "filterDelaySamples" }?.offset ?? 1
        guard spec.defaults.indices.contains(latencyOffset),
              spec.defaults.indices.contains(delayOffset) else { return }
        var values = spec.defaults
        values[latencyOffset] = settings.latency.parameterIndex
        values[delayOffset] = Float(filterDelaySamples)
        let engine = EffeTuneDSP.shared.engine
        let instance = self.instance
        _ = values.withUnsafeBufferPointer {
            et_instance_set_params(engine, instance, $0.baseAddress,
                                   UInt32(spec.floatCount), spec.paramsHash, 0)
        }
    }

    // MARK: 鎖

    /// 遅延が変わったことを et_pipeline_configure に教える。鎖は変えていない。
    ///
    /// **並びを自前で組まない。EffeTuneDSP.republish() を通す。**
    /// 前は chain から `instance != 0` だけを拾って NATIVE で出していた。
    /// JSFX / AU の段は instance を持たないのでそこで落ち、探りも chain に
    /// 居ないので落ちた。この descriptor が最後に出るので、次に誰かが
    /// publish するまで JSFX / AU が音から外れ、図の重ねも止まっていた。
    private func republishForLatencyChange() {
        EffeTuneDSP.shared.republish(reason: "FIR PEQ の遅延が変わった")
    }

    // MARK: チャンネル

    private func processingChannels() -> Int {
        let spec = EffeTuneDSP.shared.nodes.first { $0.instance == instance }?.channelSpec ?? -1
        return Self.processingChannels(channelSpec: spec, engineChannels: outputChannelCount)
    }

    /// js/ir-library/ir-plugin-contract.js:26-39 の selectedIrChannelCount。
    /// 向こうは保存形式の文字列で書いてあるので、ETChannel.swift の対応表で読み替えた。
    static func processingChannels(channelSpec: Int8, engineChannels: Int) -> Int {
        guard engineChannels >= 1, engineChannels <= 16 else { return 0 }
        switch channelSpec {
        case -2:                                    // "A"
            return engineChannels
        case -1:                                    // キー無し。Stereo
            return engineChannels >= 2 ? 2 : 1
        case 0...15:                                // "L" / "R" / "3"〜"16"
            return 1
        // 16 は JS の保存形式に綴りが無いが、engine は 16 以上を対として扱う
        // （engine.cpp:759-764）。GroupDelayEQ / GroupDelayPEQ の担当も engine に
        // 合わせているので、ここも揃える。
        case 16:  return engineChannels >= 2 ? 2 : 0   // 1ch 目と 2ch 目の対
        case 17:  return engineChannels >= 4 ? 2 : 0   // "34"
        case 18:  return engineChannels >= 6 ? 2 : 0   // "56"
        case 19:  return engineChannels >= 8 ? 2 : 0   // "78"
        case 20:  return engineChannels >= 10 ? 2 : 0  // "910"
        case 21:  return engineChannels >= 12 ? 2 : 0  // "1112"
        case 22:  return engineChannels >= 14 ? 2 : 0  // "1314"
        case 23:  return engineChannels >= 16 ? 2 : 0  // "1516"
        default:
            return 0
        }
    }
}
