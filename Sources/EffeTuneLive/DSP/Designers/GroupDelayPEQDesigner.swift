//  GroupDelayPEQDesigner.swift
//  Group Delay PEQ（GroupDelayPEQPlugin）の係数を instance へ送る係。
//  設計そのもの（design-core.js の移し）は GroupDelayPEQDesign.swift。
//
//  カーネルは出来上がった FIR 係数を受け取るだけで、係数の設計は JS 側にある。
//  ここは設計を Task.detached で回し、出来上がった係数とパラメータをカーネルへ渡す。
//
//  --- カーネルが資産として何を期待しているか ---
//  読み取り側は dsp/plugins/eq/group_delay_peq/kernel.cpp。
//
//    assetCapacity      kernel.cpp:49-51    slot 0 だけ。上限 32MiB（同 17 行）
//    beginAsset         kernel.cpp:170-212  staging を確保して番地を返す
//    validateBegin      kernel.cpp:266-280  channels=1 / topology=1(mono) /
//                                           frames は 1〜131072 /
//                                           headBlock は 0,128,256,512,1024 のどれか /
//                                           rateDivider=1 / pathCount=0 / inputCount=0 /
//                                           byteSize == 32 + channels*frames*4 /
//                                           footprintBytes >= byteSize かつ <= 32MiB /
//                                           params_.filterDelaySamples が 0〜65536
//    commitAsset        kernel.cpp:214-241  formatTag は ET_ASSET_F32_MULTICH(1) だけ。
//                                           係数の本体は staging の +32 バイトから読む（同 223）
//    validatePayload    kernel.cpp:282-289  ペイロードの頭 32 バイトを 1 語ずつ検める
//
//  --- ペイロードの並び（頭 32 バイト＋係数）---
//  書き手 js/ir-library/ir-asset-payload.js:76-95 と
//  読み手 kernel.cpp:282-289 が同じことを言っている。リトルエンディアン。
//
//    +0   u32  0x31415445
//    +4   u32  channels        → この効果は必ず 1（kernel.cpp:267）
//    +8   u32  frames          → タップ数（4096 / 8192 / 16384 / 32768）
//    +12  u32  sampleRate      → engine の sample_rate_ を丸めた整数（kernel.cpp:286）
//    +16  u32  topology        → 1 = mono（kernel.cpp:287）
//    +20  u32  0               → matrix ではないので path は無い
//    +24  u32  0
//    +28  u32  0
//    +32  f32 × frames         → 係数（1 チャンネルなので channel-major は自明）
//
//  組み立てと送り込みは AssetUpload に全部ある。ここでは係数を作って渡すだけ。
//
//  --- パラメータ（params.json）---
//  dsp/plugins/eq/group_delay_peq/params.json:8-11 の fields は 2 つしか無い。
//  バンドの形（t/f/d/q/e）とタップ数は DSP へ渡らない。渡るのは資産だけ。
//
//    latencyMode        lt  enum ["0","128","256","512","1024"]  → 添字を float で渡す
//                           （js/audio/dsp-params.generated.js:676 が indexOf を取っている）
//    filterDelaySamples fd  int 0〜65536 → **タップ数の半分**
//                           （plugins/eq/group_delay_peq.js:161-167 の _packedParameters）
//
//  fd は遅延の申告にしか使われない（kernel.cpp:207 candidate_latency_ =
//  headBlock + filterDelaySamples）。オールパスの山が taps/2 にあるので、
//  そこを「遅れ」として鎖に申告し、他のエフェクトと頭を揃える。
//  beginAsset は入口で applyPendingParameters を呼ぶ（kernel.cpp:171）ので、
//  **資産より先にパラメータを入れる**。逆にすると遅延の申告が 1 回ぶんずれる。

import Combine
import Foundation
import os

// MARK: - 設計して送り込む

/// 設計した結果を detached から持ち帰るための入れ物。
private enum GroupDelayPEQOutcome: Sendable {
    case designed(GroupDelayPEQDesign)
    case cancelled
    case failed(String)
}

/// パラメータを受け取り、係数を作って instance へ送るところまでを持つ。
///
/// **設計は音のスレッドでやらない。** Task.detached へ出して、出来上がってから送る
/// （送り込みは AssetUpload が bypass を上げて UI スレッドで行う）。
@MainActor
final class GroupDelayPEQDesigner: ObservableObject {

    /// 画面に出す状態。文言は英語。
    enum Status: Equatable {
        /// まだ instance に繋がっていない。
        case detached
        /// 全部 0 ms。素通し。
        case flat
        case designing
        case staging
        /// 送り込んだが、まだ音が通っていないので効き始めていない。
        case staged
        case ready(warning: String?)
        case failed(String)

        var message: String {
            switch self {
            case .detached:
                return "Not connected to the audio engine."
            case .flat:
                return "All bands are at 0 ms."
            case .designing:
                return "Designing filter…"
            case .staging:
                return "Loading the filter…"
            case .staged:
                return "The filter starts once audio is playing."
            case .ready(let warning):
                return warning ?? "The filter is ready."
            case .failed(let message):
                return message
            }
        }

        var isWarning: Bool {
            if case .ready(let warning) = self { return warning != nil }
            return false
        }

        var isError: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    @Published private(set) var status: Status = .detached
    /// いちばん新しく出来上がった設計。図を描くのに使える。
    @Published private(set) var design: GroupDelayPEQDesign?
    @Published private(set) var settings: GroupDelayPEQSettings

    private let log = Logger(subsystem: "ai.nemut.effetune", category: "gdpeq")
    private static let kernelType = "GroupDelayPEQPlugin"
    private let slot: UInt32 = 0

    /// engine は用意し直すと番号が変わる（EffeTuneDSP.prepare）。控えずに毎回引く。
    private var engine: UInt32 { EffeTuneDSP.shared.engine }
    private var instance: UInt32 = 0
    /// 鎖での位置。パラメータを入れるのと、送った後に publish し直すのに要る。
    private var nodeIndex: Int?

    /// いま走っている仕事。新しい設定が来たら捨てる。
    private var work: Task<Void, Never>?
    private var designWork: Task<GroupDelayPEQOutcome, Never>?
    private var generation = 0
    /// 送り込んだときの設定。
    private var stagedSettings: GroupDelayPEQSettings?

    init(settings: GroupDelayPEQSettings = GroupDelayPEQSettings()) {
        self.settings = settings
    }

    // MARK: 繋ぐ

    /// instance に繋ぐ。鎖に足した直後と、engine を用意し直した後に呼ぶ。
    /// DSP がまだ用意できていない（engine が 0）ときは何もしないので、
    /// 用意できてからもう一度呼ぶ。
    func attach(instance: UInt32, nodeIndex: Int?) {
        self.instance = instance
        self.nodeIndex = nodeIndex
        guard engine != 0, instance != 0 else {
            status = .detached
            return
        }
        // 繋ぎ直したら資産は残っていないものとして送り直す。
        stagedSettings = nil
        start(debounce: 0)
    }

    func detach() {
        work?.cancel()
        designWork?.cancel()
        work = nil
        designWork = nil
        if engine != 0, instance != 0 {
            AssetUpload.clear(engine: engine, instance: instance, slot: slot)
        }
        instance = 0
        nodeIndex = nil
        stagedSettings = nil
        design = nil
        status = .detached
    }

    // MARK: 設定を変える

    /// 設定を入れ替える。要るときだけ設計し直して、送り直す。
    /// 触るたびに呼んでよい（150ms 待ってから走る。JS の _scheduleDesign と同じ）。
    func update(_ next: GroupDelayPEQSettings, debounce: TimeInterval = 0.15) {
        let previous = settings
        settings = next
        // 同じものを送り直さない。送り込んでいるあいだ鎖は素通しになるので、
        // 何も変わっていないのに送ると音が途切れるだけになる。
        if next == previous && stagedSettings == next { return }
        if design != nil && next.requiresRedesign(comparedTo: previous) {
            design = nil
        }
        start(debounce: design == nil ? debounce : 0)
    }

    /// バンド 1 本だけ差し替える。
    func setBand(_ index: Int, _ band: GroupDelayPEQBand, debounce: TimeInterval = 0.15) {
        guard settings.bands.indices.contains(index) else { return }
        var next = settings
        next.bands[index] = band
        update(next, debounce: debounce)
    }

    /// タップ数を変える。入りきらない遅延はその場で切る（group_delay_peq.js:235-236）。
    func setTaps(_ taps: Int) {
        guard GroupDelayPEQDesignCore.tapsChoices.contains(taps) else { return }
        var next = settings
        next.taps = taps
        update(next.clampingDelaysToLimit(), debounce: 0)
    }

    /// lt を変える。係数は変わらないので送り直すだけ（group_delay_peq.js:240）。
    func setLatencySamples(_ samples: Int) {
        guard GroupDelayPEQDesignCore.latencyChoices.contains(samples) else { return }
        var next = settings
        next.latencySamples = samples
        update(next, debounce: 0)
    }

    /// engine のレートが変わったとき。AudioIO.shared.processingRate を渡す。
    func setSampleRate(_ sampleRate: Double) {
        guard sampleRate.isFinite, sampleRate > 0, sampleRate != settings.sampleRate else { return }
        var next = settings
        next.sampleRate = sampleRate
        update(next.clampingDelaysToLimit(), debounce: 0)
    }

    // MARK: 画面に出す文字

    /// JS の details 行（group_delay_peq.js:616-629）と同じもの。
    var detailText: String {
        let active = design != nil && settings.hasDelay
        let samples = active ? settings.reportedLatencySamples : 0
        let milliseconds = String(format: "%.1f", Double(samples) * 1000 / settings.sampleRate)
        let ripple = String(format: "%.2f", active ? (design?.rippleDb ?? 0) : 0)
        return "Latency \(samples) samples / \(milliseconds) ms · Ripple \(ripple) dB"
    }

    // MARK: 中身

    private func start(debounce: TimeInterval) {
        work?.cancel()
        designWork?.cancel()
        work = nil
        designWork = nil
        generation += 1
        let generation = self.generation
        let settings = self.settings

        guard engine != 0, instance != 0 else {
            status = .detached
            return
        }
        guard settings.hasDelay else {
            // 全部 0 ms。資産を外して素通しに戻す（group_delay_peq.js:309-326 _settleFlat）。
            design = nil
            stagedSettings = nil
            AssetUpload.clear(engine: engine, instance: instance, slot: slot)
            pushParameters(settings)
            republishChain()
            status = .flat
            return
        }

        status = design == nil ? .designing : .staging
        work = Task { [weak self] in
            if debounce > 0 {
                try? await Task.sleep(nanoseconds: UInt64(debounce * 1_000_000_000))
                if Task.isCancelled { return }
            }
            await self?.run(settings: settings, generation: generation)
        }
    }

    private func run(settings: GroupDelayPEQSettings, generation: Int) async {
        guard self.generation == generation else { return }

        var designed = design
        if designed == nil {
            // 重いので外へ出す。design-worker.js が Worker でやっているのと同じ意味。
            let task = Task.detached(priority: .userInitiated) { () -> GroupDelayPEQOutcome in
                do {
                    let result = try GroupDelayPEQDesignCore.design(settings: settings,
                                                                    shouldStop: { Task.isCancelled })
                    return .designed(result)
                } catch GroupDelayPEQDesignError.cancelled {
                    return .cancelled
                } catch {
                    return .failed(error.localizedDescription)
                }
            }
            designWork = task
            let outcome = await task.value
            guard self.generation == generation else { return }
            designWork = nil
            switch outcome {
            case .designed(let result):
                design = result
                designed = result
            case .cancelled:
                return
            case .failed(let message):
                log.error("設計できない \(message, privacy: .public)")
                status = .failed("The filter could not be designed. Try a different tap count.")
                return
            }
        }
        guard let result = designed, self.generation == generation else { return }
        await stage(result, settings: settings, generation: generation)
    }

    private func stage(_ design: GroupDelayPEQDesign,
                       settings: GroupDelayPEQSettings,
                       generation: Int) async {
        guard engine != 0, instance != 0 else { return }
        status = .staging

        // beginAsset は入口で applyPendingParameters を呼ぶ（kernel.cpp:171）。
        // fd（＝タップ数の半分）を先に入れておかないと、遅延の申告が 1 回ぶんずれる。
        pushParameters(settings)

        do {
            try AssetUpload.send(engine: engine,
                                 instance: instance,
                                 slot: slot,
                                 channels: [design.ir],
                                 sampleRate: Int(settings.sampleRate.rounded()),
                                 topology: .mono,
                                 headBlock: settings.headBlock,
                                 rateDivider: 1,
                                 processingChannels: settings.assetProcessingChannels)
        } catch {
            guard self.generation == generation else { return }
            log.error("送り込めない \(String(describing: error), privacy: .public)")
            status = .failed(error.localizedDescription)
            return
        }
        guard self.generation == generation else { return }
        stagedSettings = settings

        // 資産が入ると instance の遅延が変わる。鎖の遅延合わせは
        // et_pipeline_configure が instanceLatency を数え直して作るので
        // （engine.cpp:648-711 configurePipeline）、ここで publish し直す。
        republishChain()

        // commit の直後は preparing。畳み込み器が分割を積み終えるのは process の中なので、
        // 音が鳴っていないあいだは進まない。期限を切って待つ。
        let state = await AssetUpload.waitForActive(engine: engine,
                                                   instance: instance,
                                                   slot: slot,
                                                   timeout: 2.0)
        guard self.generation == generation else { return }
        if state.isActive {
            status = .ready(warning: GroupDelayPEQDesignCore.qualityWarning(for: design))
        } else if state.state == .error {
            log.error("資産が拒まれた reason=\(state.reason)")
            status = .failed("The filter could not be prepared. Try fewer taps or a higher latency.")
        } else {
            status = .staged
        }
    }

    /// lt と fd を instance へ入れる。
    /// lt は選択肢の添字（dsp-params.generated.js:676 が indexOf を取っている）、
    /// fd はタップ数の半分（group_delay_peq.js:161-167）。
    private func pushParameters(_ settings: GroupDelayPEQSettings) {
        let latencyIndex = Float(
            GroupDelayPEQDesignCore.latencyChoices.firstIndex(of: settings.latencySamples) ?? 1
        )
        let filterDelay = Float(settings.taps / 2)

        // 鎖に並んでいるなら、そちらの控えも一緒に直す。
        if let index = currentNodeIndex {
            EffeTuneDSP.shared.setValue(latencyIndex, at: index, offset: 0)
            EffeTuneDSP.shared.setValue(filterDelay, at: index, offset: 1)
            return
        }
        // 鎖に無い instance（まだ publish していないなど）へは直に入れる。
        // ここを飛ばすと fd が既定の 8192 のままになり、taps が 16384 以外のときに
        // 申告する遅延がずれる。
        guard let spec = ETCatalog.first(where: { $0.type == Self.kernelType }) else { return }
        let packed: [Float] = [latencyIndex, filterDelay]
        _ = packed.withUnsafeBufferPointer {
            et_instance_set_params(engine, instance, $0.baseAddress,
                                   UInt32(spec.floatCount), spec.paramsHash, 0)
        }
    }

    /// 鎖での位置。並べ替えで添字がずれるので、instance で引き直してから使う。
    private var currentNodeIndex: Int? {
        let chain = EffeTuneDSP.shared.nodes
        if let index = nodeIndex, chain.indices.contains(index),
           chain[index].instance == instance {
            return index
        }
        return chain.firstIndex { $0.instance == instance }
    }

    /// 鎖を publish し直す。EffeTuneDSP に publish だけを呼ぶ口が無いので、
    /// 何も変えない setRouting で代えている（中で publish している）。
    private func republishChain() {
        guard let index = currentNodeIndex else { return }
        EffeTuneDSP.shared.setRouting(at: index)
    }
}