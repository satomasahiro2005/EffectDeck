//  GroupDelayEQDesigner.swift
//  Group Delay EQ の係数を instance へ送り込む係。設計そのものは GroupDelayEQDesign.swift。
//
//  カーネル（dsp/plugins/eq/group_delay_eq/kernel.cpp）は出来上がった FIR を
//  受け取って畳み込むだけで、係数の設計は JS 側にある。その設計は
//  GroupDelayEQDesign.swift に移してあり、このファイルは設計を main の外で回して
//  カーネルへ送るところだけを持つ。
//
//  元:
//    Vendor/effetune/js/group-delay-eq/design-worker.js（設計→ペイロードの流れ）
//    Vendor/effetune/plugins/eq/group_delay_eq.js（既定値・繋ぎ方）
//
//  --- カーネルが資産として何を期待しているか ---
//  読み取り側は kernel.cpp の 3 か所。
//
//  validateBegin（kernel.cpp:266-280）:
//    slot == 0 / channels == 1（モノ 1 本だけ）/ frames は 1〜131072 /
//    topology == 1（mono）/ headBlock は 0,128,256,512,1024 のどれか /
//    rateDivider == 1 / pathCount == 0 / inputCount == 0 /
//    processingChannels は 1〜maxChannels /
//    byteSize == 32 + channels * frames * 4 /
//    footprintBytes は byteSize 以上 32MiB 以下 /
//    さらに **params の filterDelaySamples が 0〜65536 であること**。
//    beginAsset は冒頭で applyPendingParameters() を呼ぶ（kernel.cpp:171）ので、
//    資産を送る前に params を入れておかないとここで弾かれる。
//
//  validatePayload（kernel.cpp:282-289）:
//    +0  u32 0x31415445
//    +4  u32 channels（= 1）
//    +8  u32 frames（= taps）
//    +12 u32 (uint32)(sample_rate + 0.5) つまり engine の整数サンプルレート
//    +16 u32 1（mono）
//    +20 u32 0 / +24 u32 0 / +28 u32 0
//    +32 以降 float32 が frames 個
//  この並びは AssetUpload.makePayload がそのまま作る。
//
//  commitAsset（kernel.cpp:214-241）:
//    formatTag は ET_ASSET_F32_MULTICH（1）。resident_latency_ は
//    headBlock + filterDelaySamples になる（kernel.cpp:207, 231）。
//    つまり **fd = taps/2 を入れておかないと遅延補正がずれる**。
//    JS も同じ値を入れている（group_delay_eq.js:113-114 の `fd: this.tp / 2`）。
//
//  --- 移していないもの ---
//  画面（スライダ・グラフ・状態表示）と、書き出し時のオフライン経路
//  （group_delay_eq.js:340-480 の _externalAssetSignature / offlineDspAsset）は
//  移していない。設計と送り込みだけ。

import Combine
import Foundation
import os

// MARK: - instance へ送り込む側

/// Group Delay EQ 1 個ぶんの設計係。
///
/// 画面から帯の遅延・taps・latency を受け取り、重い設計を main の外で回して、
/// 出来たら AssetUpload でカーネルへ送る。
///
/// 帯の遅延（15 個）は**カーネルのパラメータではない**（params.json の
/// フィールドは latencyMode と filterDelaySamples の 2 つだけ）。
/// だからこの値はここが持つ。鎖と一緒に保存する口はまだ無い。
@MainActor
final class GroupDelayEQDesigner: ObservableObject {

    /// いまどの段にいるか。画面に出す文言は英語。
    enum Stage: Equatable {
        /// 全部 0 ms。素通し。group_delay_eq.js:238-239。
        case flat
        case designing
        case staging
        case active
        case failed(String)

        var message: String {
            switch self {
            case .flat:
                return "All bands are at 0 ms."
            case .designing:
                return "Designing filter…"
            case .staging:
                return "Loading the filter…"
            case .active:
                return "The filter is running."
            case .failed(let text):
                return text
            }
        }
    }

    private static let log = Logger(subsystem: "ai.nemut.effetune", category: "groupDelayEq")
    private static let kernelType = "GroupDelayEqPlugin"

    // MARK: 設定

    /// 帯ごとの遅延（ms）。長さは GroupDelayEQDesign.bands と同じ 15。
    @Published private(set) var delaysMs: [Double]
    /// 4096 / 8192 / 16384 / 32768。
    @Published private(set) var taps: Int
    /// 頭ブロック。0 / 128 / 256 / 512 / 1024。
    @Published private(set) var headBlock: UInt32
    /// engine のサンプルレート。ペイロードの +12 に入るので、
    /// **et_engine_prepare へ渡した値と同じでないとカーネルに弾かれる**
    /// （kernel.cpp:286）。
    @Published private(set) var sampleRate: Double
    /// engine の最大チャンネル数。EffeTuneDSP.prepare の maxChannels。
    @Published private(set) var engineChannels: UInt32

    // MARK: 出来たもの

    @Published private(set) var stage: Stage = .flat
    /// 品質の注意書き。無ければ nil。group_delay_eq.js:280-291。
    @Published private(set) var warning: String?
    /// 直近の設計。グラフはここから引く。
    @Published private(set) var filter: GroupDelayEQDesign.Filter?

    /// 送り込みが効いているときの遅延（サンプル）。group_delay_eq.js:522。
    var latencySamples: Int {
        stage == .active ? Int(headBlock) + taps / 2 : 0
    }

    /// スライダの上限（ms）。
    var delayLimitMs: Double {
        GroupDelayEQDesign.uiDelayLimitMs(taps: taps, sampleRate: sampleRate)
    }

    // MARK: 繋ぎ先

    private var instance: UInt32 = 0
    private var engine: UInt32 { EffeTuneDSP.shared.engine }

    // MARK: 進行中のもの

    private typealias Outcome = Swift.Result<GroupDelayEQDesign.Filter, GroupDelayEQDesignError>
    private var schedule: Task<Void, Never>?
    private var work: Task<Outcome, Never>?
    private var generation: UInt64 = 0

    init(instance: UInt32 = 0,
         sampleRate: Double = 48000,
         engineChannels: UInt32 = 2,
         taps: Int = 16384,
         headBlock: UInt32 = 128,
         delaysMs: [Double]? = nil) {
        self.instance = instance
        self.sampleRate = sampleRate > 0 ? sampleRate : 48000
        self.engineChannels = engineChannels
        self.taps = GroupDelayEQDesign.tapsChoices.contains(taps) ? taps : 16384
        self.headBlock = GroupDelayEQDesign.headBlockChoices.contains(headBlock) ? headBlock : 128
        let count = GroupDelayEQDesign.bands.count
        var initial = [Double](repeating: 0, count: count)
        if let given = delaysMs {
            for band in 0..<min(count, given.count) where given[band].isFinite {
                initial[band] = given[band]
            }
        }
        self.delaysMs = initial
    }

    // MARK: - 繋ぐ

    /// 面倒を見る instance を決める。engine を作り直した後にも呼ぶ。
    func attach(instance: UInt32) {
        guard self.instance != instance else { return }
        self.instance = instance
        filter = nil
        refresh(debounce: 0)
    }

    func detach() {
        schedule?.cancel()
        work?.cancel()
        if instance != 0 { AssetUpload.clear(engine: engine, instance: instance) }
        instance = 0
        filter = nil
        stage = .flat
        warning = nil
    }

    // MARK: - 値を変える

    func setDelay(_ milliseconds: Double, band: Int) {
        guard delaysMs.indices.contains(band) else { return }
        let limit = delayLimitMs
        let value = milliseconds.isFinite ? min(max(milliseconds, -limit), limit) : 0
        guard delaysMs[band] != value else { return }
        delaysMs[band] = value
        refresh()
    }

    func setDelays(_ values: [Double]) {
        let limit = delayLimitMs
        var next = [Double](repeating: 0, count: GroupDelayEQDesign.bands.count)
        for band in 0..<min(next.count, values.count) where values[band].isFinite {
            next[band] = min(max(values[band], -limit), limit)
        }
        guard next != delaysMs else { return }
        delaysMs = next
        refresh()
    }

    /// 全部 0 ms へ。group_delay_eq.js:169-173。
    func reset() {
        setDelays([Double](repeating: 0, count: GroupDelayEQDesign.bands.count))
    }

    func setTaps(_ value: Int) {
        guard GroupDelayEQDesign.tapsChoices.contains(value), value != taps else { return }
        taps = value
        // taps を減らすと出せる遅延も縮むので、しまってある値を詰め直す
        // （group_delay_eq.js:96-102 の _clampDelaysToLimit）。
        clampDelaysToLimit()
        refresh(debounce: 0)
    }

    /// latency だけの変更は設計し直さない。出来ている係数をもう一度送るだけ
    /// （group_delay_eq.js:166 が同じことをしている）。
    func setHeadBlock(_ value: UInt32) {
        guard GroupDelayEQDesign.headBlockChoices.contains(value), value != headBlock else { return }
        headBlock = value
        guard let filter else { return }
        guard hasDelay() else { return }
        schedule?.cancel()
        generation &+= 1
        let generation = self.generation
        schedule = Task { [weak self] in
            guard let self else { return }
            await self.stageFilter(filter, generation: generation)
        }
    }

    func setSampleRate(_ value: Double) {
        guard value.isFinite, value > 0, value != sampleRate else { return }
        sampleRate = value
        clampDelaysToLimit()
        refresh(debounce: 0)
    }

    private func clampDelaysToLimit() {
        let limit = delayLimitMs
        for band in delaysMs.indices {
            delaysMs[band] = min(max(delaysMs[band], -limit), limit)
        }
    }

    private func hasDelay() -> Bool {
        delaysMs.contains { $0 != 0 }
    }

    // MARK: - 設計して送る

    /// 設計し直して送り込む。既定の 150ms は JS の待ち（group_delay_eq.js:164）と同じで、
    /// スライダを動かしているあいだ何度も設計しないため。
    func refresh(debounce: TimeInterval = 0.15) {
        schedule?.cancel()
        work?.cancel()
        generation &+= 1
        let generation = self.generation

        guard instance != 0, engine != 0 else {
            stage = .failed(ETAssetUploadError.engineNotReady.errorDescription ?? "Not ready.")
            return
        }

        // 全部 0 ms なら設計しない。資産を外して素通しへ戻す
        // （group_delay_eq.js:227-241 の _settleFlat）。
        guard hasDelay() else {
            AssetUpload.clear(engine: engine, instance: instance)
            filter = nil
            warning = nil
            stage = .flat
            return
        }

        stage = .designing
        warning = nil

        let delays = delaysMs
        let taps = self.taps
        let sampleRate = self.sampleRate

        schedule = Task { [weak self] in
            if debounce > 0 {
                try? await Task.sleep(nanoseconds: UInt64(debounce * 1_000_000_000))
                if Task.isCancelled { return }
            }
            guard let self else { return }
            guard self.isCurrent(generation) else { return }

            // 重いところ。main から外す（JS が Worker へ出しているのと同じ理由）。
            let work = Task.detached(priority: .userInitiated) { () -> Outcome in
                do {
                    let designed = try GroupDelayEQDesign.design(delaysMs: delays,
                                                                 taps: taps,
                                                                 sampleRate: sampleRate,
                                                                 isCancelled: { Task.isCancelled })
                    return .success(designed)
                } catch let error as GroupDelayEQDesignError {
                    return .failure(error)
                } catch {
                    return .failure(.designFailed)
                }
            }
            self.remember(work: work)
            let outcome = await work.value
            await self.finish(outcome, generation: generation)
        }
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        self.generation == generation && instance != 0
    }

    private func remember(work: Task<Outcome, Never>) {
        self.work = work
    }

    private func finish(_ outcome: Outcome, generation: UInt64) async {
        guard isCurrent(generation) else { return }
        switch outcome {
        case .failure(let error):
            if case .cancelled = error { return }
            Self.log.error("設計に失敗 \(String(describing: error))")
            filter = nil
            stage = .failed(GroupDelayEQDesignError.designFailed.errorDescription ?? "Failed.")
        case .success(let designed):
            // 送る前にグラフへ出す。カーネルが受け取るのを待たせない
            // （group_delay_eq.js:265-268 と同じ順番）。
            filter = designed
            warning = GroupDelayEQDesign.qualityWarning(for: designed)
            await stageFilter(designed, generation: generation)
        }
    }

    /// 出来た係数をカーネルへ。
    private func stageFilter(_ designed: GroupDelayEQDesign.Filter, generation: UInt64) async {
        guard isCurrent(generation) else { return }
        let engine = self.engine
        let instance = self.instance
        guard engine != 0, instance != 0 else {
            stage = .failed(ETAssetUploadError.engineNotReady.errorDescription ?? "Not ready.")
            return
        }
        guard AssetUpload.canStage else {
            stage = .failed(ETAssetUploadError.stagingAddressUnavailable.errorDescription
                            ?? "Cannot stage.")
            return
        }
        let channels = processingChannels()
        guard channels >= 1 else {
            stage = .failed("The selected audio channels are not available.")
            return
        }

        stage = .staging

        // **params が先。** beginAsset は冒頭で applyPendingParameters() を呼び、
        // filterDelaySamples を見て候補の遅延を決める（kernel.cpp:171, 207）。
        pushKernelParameters(instance: instance)

        do {
            try AssetUpload.send(engine: engine,
                                 instance: instance,
                                 slot: 0,
                                 channels: [designed.ir],
                                 sampleRate: Int(sampleRate.rounded()),
                                 topology: .mono,
                                 headBlock: headBlock,
                                 rateDivider: 1,
                                 processingChannels: channels)
        } catch {
            Self.log.error("送り込みに失敗 \(String(describing: error))")
            let text = (error as? LocalizedError)?.errorDescription
            stage = .failed(text ?? "The filter could not be loaded.")
            return
        }

        // commit が通ると instance の遅延が変わる。鎖を publish し直して
        // et_pipeline_configure に読み直させる（AssetUpload.swift:64-68）。
        republishForLatencyChange()

        let status = await AssetUpload.waitForActive(engine: engine, instance: instance, slot: 0)
        guard isCurrent(generation) else { return }
        switch status.state {
        case .active:
            stage = .active
        case .error:
            stage = .failed(Self.failureText(reason: status.reason))
        default:
            // 無音のあいだは preparing のまま進まない。音が来れば active になる。
            stage = .staging
        }
    }

    // MARK: - カーネルのパラメータ

    /// latencyMode は選択肢の**添字**、filterDelaySamples は taps/2。
    /// 添字であることの出典は js/audio/dsp-params.generated.js:666-671
    /// （`["0","128",…].indexOf(params["lt"])` を packed[0] に入れている）。
    /// taps/2 の出典は plugins/eq/group_delay_eq.js:113-114。
    private func pushKernelParameters(instance: UInt32) {
        let latencyIndex = Float(GroupDelayEQDesign.headBlockChoices.firstIndex(of: headBlock) ?? 1)
        let filterDelay = Float(taps / 2)

        // 鎖に並んでいるなら、そちらの控えも一緒に直す。
        if let index = chainIndex(for: instance) {
            EffeTuneDSP.shared.setValue(latencyIndex, at: index, offset: 0)
            EffeTuneDSP.shared.setValue(filterDelay, at: index, offset: 1)
            return
        }
        guard let spec = ETCatalog.first(where: { $0.type == Self.kernelType }) else { return }
        let packed: [Float] = [latencyIndex, filterDelay]
        _ = packed.withUnsafeBufferPointer {
            et_instance_set_params(engine, instance, $0.baseAddress,
                                   UInt32(spec.floatCount), spec.paramsHash, 0)
        }
    }

    private func chainIndex(for instance: UInt32) -> Int? {
        EffeTuneDSP.shared.nodes.firstIndex { $0.instance == instance }
    }

    /// 鎖の中身は変えずに publish だけやり直す。
    /// EffeTuneDSP.publish は private なので、何も渡さない setRouting を通す
    /// （中で publish を呼ぶ。EffeTuneDSP.swift:282-290）。
    private func republishForLatencyChange() {
        guard let index = chainIndex(for: instance) else { return }
        EffeTuneDSP.shared.setRouting(at: index)
    }

    /// この instance が何チャンネルを受け持つか。
    /// ir-plugin-contract.js:26-39 の selectedIrChannelCount を、
    /// こちらの channelSpec（ETPipeline.h の値）へ読み替えたもの。
    private func processingChannels() -> UInt32 {
        let spec = chainIndex(for: instance).map { EffeTuneDSP.shared.nodes[$0].channelSpec } ?? -1
        switch spec {
        case -2:                       // All
            return engineChannels
        case -1:                       // Stereo（既定）
            return engineChannels >= 2 ? 2 : 1
        case 0...15:                   // 1 本だけ
            return UInt32(spec) < engineChannels ? 1 : 0
        case 16...23:                  // ステレオ対
            let pair = UInt32(spec - 16)
            return engineChannels >= (pair + 1) * 2 ? 2 : 0
        default:
            return 0
        }
    }

    // MARK: - 文言（英語）

    /// assetState の理由。ETAssetStatus.reason の値は five_band_fir_peq/kernel.cpp:259-263、
    /// 意味は group_delay_eq/kernel.cpp:203/217-221/225-228。
    private static func failureText(reason: UInt32) -> String {
        switch reason {
        case 2:
            return "The filter needs more memory than the effect accepts. Try fewer taps."
        case 3:
            return "The effect could not take the filter. Try fewer taps or a higher latency."
        default:
            return "The filter could not be prepared. Try fewer taps or a higher latency."
        }
    }
}