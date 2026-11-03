//  CrosstalkCancellationDesigner.swift
//  Crosstalk Cancellation（CrosstalkCancellationPlugin）の係数を instance へ送る係
//  （CrosstalkCancellationController）。設計そのもの（enum CrosstalkCancellationDesigner）は
//  CrosstalkDesign.swift に切り出してある。
//
//  カーネル（Vendor/effetune/dsp/plugins/spatial/crosstalk_cancellation/kernel.cpp）は
//  出来上がった FIR を 4 チャンネル受け取るだけで、設計は JS 側にある。
//
//  --- カーネルが資産として何を期待しているか ---
//  読み取り側を先に確かめた。出典は kernel.cpp の行番号。
//
//    assetCapacity(slot)            :63-65   slot 0 だけ 32MiB、他は 0
//    validateBegin(slot, info)      :243-257
//        slot == 0
//        topology == 3（trueStereo。kTrueStereoTopology）
//        channels == 4（kAssetChannels）
//        processingChannels == 2（kProcessingChannels）
//        1 <= frames <= 131072（kMaximumIrFrames）
//        headBlock は 0 / 128 / 256 / 512 / 1024（supportedHeadBlock :53-55）
//        rateDivider == 1
//        pathCount == 0 かつ inputCount == 0
//            （trueStereo の 4 経路はカーネルが自分で組む。:170-173 で
//              paths[0]={0,0,0} paths[1]={0,1,1} paths[2]={1,0,2} paths[3]={1,1,3}。
//              つまり IR チャンネルは 入力 L→出力 L, L→R, R→L, R→R の順）
//        byteSize == 32 + 4 * frames * 4   （:253-256）
//        byteSize <= footprintBytes <= 32MiB
//        params_.filterDelaySamples が 0 以上 65536 以下
//    validatePayload()              :259-266
//        +0  magic 0x31415445
//        +4  channels == 4
//        +8  frames == begin の frames
//        +12 sampleRate == std::lround(エンジンの sampleRate)   ← エンジンのレートと一致必須
//        +16 topology == 3
//        +20/+24/+28 は 0
//    commitAsset(...)               :204-226
//        formatTag == ET_ASSET_F32_MULTICH(1)、bytes == begin の byteSize
//        頭 32 バイトの後ろから float をそのまま読む（:211）
//
//  つまりペイロードの並びは ETA1 の共通形そのままで、
//  channel-major に C11 / C21 / C12 / C22 を 4 本並べる。
//  組み立てと送り込みは AssetUpload に在るので、ここでは係数だけ作る。
//
//  --- 重さ ---
//  JS は Worker で回している（design-worker.js:7）。理由は重いから。
//  だからここでも設計は Task.detached へ出し、出来上がってから送る。
//  送り込み（AssetUpload.send）だけは MainActor で行う。

import Combine
import Foundation
import os

// MARK: - 送り込む側

/// 設計を外のスレッドで回して、出来上がったら instance へ送る。
///
/// 使い方:
///   let controller = CrosstalkCancellationController()
///   controller.apply(chainIndex: index, config: config, sources: sources)
///
/// パラメータ（taps や帯域）が変わるたびに呼んでよい。
/// 直前の注文と同じなら何もしないし、違えば走っている設計を捨てて作り直す。
@MainActor
final class CrosstalkCancellationController: ObservableObject {

    typealias Config = CrosstalkCancellationDesigner.Config
    typealias Sources = CrosstalkCancellationDesigner.Sources
    typealias Design = CrosstalkCancellationDesigner.Design
    typealias Diagnostics = CrosstalkCancellationDesigner.Diagnostics
    typealias DesignError = CrosstalkCancellationDesigner.DesignError

    /// 画面に出す状態。文言は英語。
    enum Phase: Equatable {
        case idle
        case designing
        case sending
        case sent
        case failed(String)

        var isBusy: Bool { self == .designing || self == .sending }

        var message: String {
            switch self {
            case .idle: return "No filter yet."
            case .designing: return "Designing the crosstalk filter…"
            case .sending: return "Loading the filter…"
            case .sent: return "Filter loaded."
            case .failed(let text): return text
            }
        }
    }

    /// 1 回ぶんの注文。同じものが来たら作り直さないための控えにも使う。
    struct Order: Equatable, Sendable {
        var instance: UInt32
        var headBlock: UInt32
        var config: Config
        var sources: Sources
    }

    private static let log = Logger(subsystem: "ai.nemut.effetune", category: "xtc")

    /// 連打を吸う待ち時間。設計が重いので、指が止まってから始める。
    private static let debounceNanoseconds: UInt64 = 150_000_000

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var diagnostics: Diagnostics?

    /// 送り込みまで終わった注文。同じものが来たら何もしない。
    private var applied: Order?
    /// いま設計している注文。
    private var inFlight: Order?
    private var running: Task<Void, Never>?
    // 走っている 1 本ぶんの後始末。Task の中へ閉じ込めると @Sendable の
    // 捕まえ方がうるさくなるので、MainActor の持ち物として置いておく。
    private var beforeSend: ((Design) -> Void)?
    private var afterSend: (() -> Void)?

    init() {}

    // MARK: 入口

    /// 鎖の位置から engine / instance / headBlock を引いて設計と送り込みをする。
    /// カーネルの `filterDelaySamples`（fd）の付け替えと、
    /// 送り込んだ後の publish のやり直しもここでやる。
    func apply(chainIndex: Int, config: Config, sources: Sources, force: Bool = false) {
        let dsp = EffeTuneDSP.shared
        guard dsp.nodes.indices.contains(chainIndex) else {
            phase = .failed("This effect is no longer in the chain.")
            return
        }
        let node = dsp.nodes[chainIndex]
        guard node.spec.type == "CrosstalkCancellationPlugin", node.instance != 0 else {
            phase = .failed("This effect does not take a crosstalk filter.")
            return
        }

        // 設計するレートはエンジンのレート。ペイロードの +12 と突き合わされる
        // （kernel.cpp:263）。倍率つきで動いているときは倍率込みの値。
        var resolved = config
        let engineRate = AudioIO.shared.processingRate
        if engineRate.isFinite, engineRate > 0, engineRate < 1_000_000 {
            resolved.sampleRate = Int(engineRate.rounded())
        }

        var latencyMode: Float = 1          // params.json の既定は添字 1（= 128）
        if let slot = paramOffset(named: "latencyMode", in: node.spec),
           node.values.indices.contains(slot) {
            latencyMode = node.values[slot]
        }
        let headBlock = CrosstalkCancellationDesigner.headBlock(forLatencyMode: latencyMode)

        let instance = node.instance
        apply(engine: dsp.engine,
              instance: instance,
              headBlock: headBlock,
              config: resolved,
              sources: sources,
              force: force,
              beforeSend: { [weak self] design in
                  self?.pushFilterDelay(design.config, instance: instance)
              },
              afterSend: { [weak self] in
                  self?.republish(instance: instance)
              })
    }

    /// engine / instance を自分で用意できるときの口。
    /// beforeSend は設計が終わって送る直前、afterSend は commit が通った後に呼ばれる。
    func apply(engine: UInt32,
               instance: UInt32,
               headBlock: UInt32,
               config: Config,
               sources: Sources,
               force: Bool = false,
               beforeSend: ((Design) -> Void)? = nil,
               afterSend: (() -> Void)? = nil) {
        guard engine != 0, instance != 0 else {
            phase = .failed("The audio engine is not ready.")
            return
        }
        guard AssetUpload.canStage else {
            // 送り込めない build なら設計する前に諦める。
            phase = .failed("This build cannot reach the effect's staging buffer.")
            return
        }

        let order = Order(instance: instance,
                          headBlock: headBlock,
                          config: config.normalized(),
                          sources: sources)
        if !force, applied == order, phase == .sent { return }
        // 同じ注文が走っている最中なら触らない。触ると待ち時間が伸び続けて
        // いつまでも始まらない。
        if !force, inFlight == order, phase.isBusy { return }

        running?.cancel()
        self.beforeSend = beforeSend
        self.afterSend = afterSend
        inFlight = order
        phase = .designing
        running = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
            if Task.isCancelled { return }

            let outcome = await Self.designOffThread(order: order)
            if Task.isCancelled { return }
            guard let self else { return }

            switch outcome {
            case .failure(let error):
                Self.log.error("設計に失敗 code=\(error.code, privacy: .public)")
                self.diagnostics = nil
                self.phase = .failed(error.message)
            case .success(let design):
                self.diagnostics = design.diagnostics
                self.phase = .sending
                self.beforeSend?(design)
                do {
                    try AssetUpload.send(engine: engine,
                                         instance: instance,
                                         slot: 0,
                                         channels: design.channels,
                                         sampleRate: design.config.sampleRate,
                                         topology: .trueStereo,
                                         headBlock: order.headBlock,
                                         rateDivider: 1,
                                         processingChannels: 2)
                    self.applied = order
                    self.phase = .sent
                    self.afterSend?()
                    let taps = design.config.taps
                    let gain = design.diagnostics.maxGainDb
                    Self.log.notice("送り込み済み instance=\(instance) taps=\(taps) gain=\(gain)dB")
                } catch {
                    self.applied = nil
                    self.phase = .failed(error.localizedDescription)
                    Self.log.error("送り込みに失敗 \(String(describing: error))")
                }
            }
            self.inFlight = nil
        }
    }

    /// 資産を外して素通しに戻す。
    func clear(instance: UInt32) {
        running?.cancel()
        running = nil
        applied = nil
        inFlight = nil
        beforeSend = nil
        afterSend = nil
        diagnostics = nil
        phase = .idle
        AssetUpload.clear(engine: EffeTuneDSP.shared.engine, instance: instance, slot: 0)
    }

    /// いま資産が効いているか。preparing のあいだは音が何ブロックか通るまで進まない。
    func status(instance: UInt32) -> ETAssetStatus {
        AssetUpload.status(engine: EffeTuneDSP.shared.engine, instance: instance, slot: 0)
    }

    // MARK: 中身

    /// 設計だけを外へ出す。JS が Worker でやっているのと同じ扱い
    /// （design-worker.js:7-34）。
    private static func designOffThread(order: Order) async -> Result<Design, DesignError> {
        let config = order.config
        let sources = order.sources
        return await Task.detached(priority: .userInitiated) { () async -> Result<Design, DesignError> in
            do {
                return .success(try CrosstalkCancellationDesigner.design(config: config,
                                                                         sources: sources))
            } catch let error as DesignError {
                return .failure(error)
            } catch {
                return .failure(DesignError("design-failed",
                                            "The crosstalk filter could not be designed."))
            }
        }.value
    }

    /// 設計が置いた山の位置を、カーネルの dry 側の遅延にも入れる。
    /// beginAsset は applyPendingParameters() を先に呼ぶ（kernel.cpp:156）ので、
    /// 送り込む直前に入れておけば同じ begin で効く。
    private func pushFilterDelay(_ config: Config, instance: UInt32) {
        let dsp = EffeTuneDSP.shared
        guard let index = dsp.nodes.firstIndex(where: { $0.instance == instance }),
              let slot = paramOffset(named: "filterDelaySamples", in: dsp.nodes[index].spec) else {
            return
        }
        dsp.setValue(Float(config.filterDelaySamples), at: index, offset: slot)
    }

    /// commit で instance の遅延が変わるので、鎖を組み直させる。
    /// EffeTuneDSP の publish() は外から呼べないが、setRouting は何も変えずに
    /// 呼んでも publish まで進む（EffeTuneDSP.swift:282-290）。
    /// JS も同じ所で refreshDspPipelineForLatencyChange を呼んでいる。
    private func republish(instance: UInt32) {
        let dsp = EffeTuneDSP.shared
        guard let index = dsp.nodes.firstIndex(where: { $0.instance == instance }) else { return }
        dsp.setRouting(at: index)
    }

    /// params.json の名前から packed float 配列での位置を引く。
    private func paramOffset(named name: String, in spec: ETEffect) -> Int? {
        spec.params.first { $0.name == name }?.offset
    }
}