//  EffeTuneDSP.swift
//  EffeTune の DSP コア (dsp/) を Swift から使う。
//
//  DSP そのものは EffeTune のものをそのまま動かしている。移植も書き直しもしていない。
//  dsp/ は host-neutral な C++20 で、ブラウザや WebAudio に触っていないので、
//  WASM を経由せず iOS 向けに arm64 で建つ。
//
//  役割分担:
//    - instance の作成・破棄・パラメータ更新は、このクラス（メインスレッド）
//    - 音のスレッドが読む「鎖の並び」だけ ETChain.c が持つ
//
//  instance を壊すときは、音のスレッドがそれを読み終えるのを待つ。
//  ETChain_ProcessCount が 2 つ進めば、その面はもう読まれていない。

import Foundation
import os

@MainActor
final class EffeTuneDSP: ObservableObject {

    /// 鎖に並んでいる 1 個。
    struct Node: Identifiable {
        let id = UUID()
        let spec: ETEffect
        var values: [Float]
        var enabled: Bool = true
        var instance: UInt32 = 0
        /// 描画用の値がどのエフェクトから出たかを見分ける番号。
        var tapId: UInt32 = 0

        // --- 鎖の形 ---
        // 普通の使い方では全部 0→0 の All なので、既定から外れたものだけ画面に出す。
        var inputBus: UInt8 = 0
        var outputBus: UInt8 = 0
        var channelSpec: Int8 = -2      // ET_CHANNEL_ALL
        var sectionGate: UInt8 = 1

        var isDefaultRouting: Bool {
            inputBus == 0 && outputBus == 0 && channelSpec == -2 && sectionGate == 1
        }
    }

    static let shared = EffeTuneDSP()

    private let log = Logger(subsystem: "ai.nemut.effetune", category: "dsp")

    @Published private(set) var chain: [Node] = []
    @Published private(set) var ready = false
    @Published var bypass = false { didSet { ETPipeline_SetBypass(bypass ? 1 : 0) } }

    /// テレメトリを読むのに要るので外へ出す。
    private(set) var engine: UInt32 = 0
    private var nextTap: UInt32 = 1
    private var sampleRate: Double = 48000
    private var maxFrames: UInt32 = 4096
    private var kernelIndex: [String: UInt32] = [:]

    /// 利用できるエフェクト。カーネルとして登録されているものだけ。
    private(set) var available: [ETEffect] = []

    /// 可視化の値を貯める輪の大きさと、1 秒あたりに出す回数。
    private static let telemetryRingBytes: UInt32 = 256 * 1024
    private static let telemetryHz: Float = 30

    private init() {}

    // MARK: - 用意

    func prepare(sampleRate: Double, maxChannels: UInt32 = 2, maxFrames: UInt32 = 4096) {
        self.sampleRate = sampleRate
        self.maxFrames = maxFrames

        if engine == 0 {
            engine = et_engine_create()
            guard engine != 0 else {
                log.error("et_engine_create が 0 を返した")
                return
            }
            ETPipeline_SetEngine(engine)
            buildKernelIndex()
        }

        // テレメトリの輪を確保しないと、可視化の値が一切出てこない。
        let st = et_engine_prepare(engine, Float(sampleRate), maxChannels, maxFrames,
                                   Self.telemetryRingBytes)
        guard Int(st) == ET_OK else {
            log.error("et_engine_prepare が \(st) を返した")
            ready = false
            return
        }
        ready = true
        et_engine_set_telemetry_rate(engine, Self.telemetryHz)
        Telemetry.shared.clear()
        log.notice("DSP ready sr=\(sampleRate) engine=\(self.engine) kinds=\(self.available.count) abi=\(et_abi_version())")

        // 用意し直したので、いま並んでいるものを作り直す。
        rebuildAll()
    }

    func reset() {
        guard engine != 0 else { return }
        et_engine_reset(engine)
    }

    /// カーネルとして実際に登録されている型だけをカタログから残す。
    private func buildKernelIndex() {
        let count = et_kernel_count()
        var buf = [CChar](repeating: 0, count: 128)
        for i in 0..<count {
            let n = et_kernel_name(i, &buf, UInt32(buf.count))
            guard n > 0 else { continue }
            kernelIndex[String(cString: buf)] = i
        }
        // analyzer も出す。値は DSP がテレメトリで吐くので、こちらは描くだけでよい。
        available = ETCatalog.filter { kernelIndex[$0.type] != nil }
        let missing = ETCatalog.filter { kernelIndex[$0.type] == nil }
        if !missing.isEmpty {
            log.info("カーネルが無い型 \(missing.count) 個: \(missing.prefix(5).map(\.type).joined(separator: ","))")
        }
    }

    // MARK: - 鎖をいじる

    func add(_ spec: ETEffect) {
        var node = Node(spec: spec, values: spec.defaults)
        if node.values.count != spec.floatCount {
            node.values = spec.defaults + Array(repeating: 0,
                                                count: max(0, spec.floatCount - spec.defaults.count))
        }
        guard instantiate(&node) else { return }
        chain.append(node)
        publish()
    }

    func remove(at offsets: IndexSet) {
        let doomed = offsets.map { chain[$0].instance }.filter { $0 != 0 }
        chain.remove(atOffsets: offsets)
        publish()
        retire(doomed)
    }

    func move(from source: IndexSet, to destination: Int) {
        chain.move(fromOffsets: source, toOffset: destination)
        publish()
    }

    func setEnabled(_ enabled: Bool, at index: Int) {
        guard chain.indices.contains(index) else { return }
        chain[index].enabled = enabled
        publish()
    }

    /// パラメータを 1 つ変える。offset は ETParam.offset（配列なら +i）。
    func setValue(_ value: Float, at index: Int, offset: Int) {
        guard chain.indices.contains(index),
              chain[index].values.indices.contains(offset) else { return }
        chain[index].values[offset] = value
        pushParams(chain[index])
    }

    func resetParams(at index: Int) {
        guard chain.indices.contains(index) else { return }
        chain[index].values = chain[index].spec.defaults
        pushParams(chain[index])
    }

    func clear() {
        let doomed = chain.map(\.instance).filter { $0 != 0 }
        chain.removeAll()
        publish()
        retire(doomed)
    }

    // MARK: - 中身

    private func instantiate(_ node: inout Node) -> Bool {
        guard engine != 0, ready else { return false }
        let typeName = node.spec.type          // inout を os_log に渡せないので控えておく
        let inst = typeName.withCString { et_instance_create(engine, $0) }
        guard inst != 0 else {
            log.error("et_instance_create に失敗 \(typeName, privacy: .public)")
            return false
        }
        let tap = nextTap
        nextTap &+= 1
        node.instance = inst
        node.tapId = tap
        et_instance_set_tap(engine, inst, tap)
        log.notice("instance=\(inst) tap=\(tap) \(typeName, privacy: .public)")
        pushParams(node)
        return true
    }

    private func rebuildAll() {
        guard ready else { return }
        for i in chain.indices {
            if chain[i].instance == 0 {
                _ = instantiate(&chain[i])
            } else {
                pushParams(chain[i])
            }
        }
        publish()
    }

    private func pushParams(_ node: Node) {
        guard engine != 0, node.instance != 0, node.spec.floatCount > 0 else { return }
        var v = node.values
        let st = v.withUnsafeBufferPointer {
            et_instance_set_params(engine, node.instance, $0.baseAddress,
                                   UInt32(node.spec.floatCount), node.spec.paramsHash, 0)
        }
        log.notice("set_params=\(st) \(node.spec.type, privacy: .public) n=\(node.spec.floatCount) v0=\(v.first ?? 0)")
    }

    /// 有効なものだけを並べて音のスレッドへ渡す。
    private func publish() {
        let nodes = chain.filter { $0.instance != 0 }.map { n in
            ETPipeNode(instance: n.instance,
                       enabled: n.enabled ? 1 : 0,
                       inputBus: n.inputBus,
                       outputBus: n.outputBus,
                       channelSpec: n.channelSpec,
                       sectionGate: n.sectionGate)
        }
        nodes.withUnsafeBufferPointer { ETPipeline_Publish($0.baseAddress, UInt32($0.count)) }
        log.notice("publish nodes=\(nodes.count)")
    }

    /// 鎖の形を変える。既定は 0→0 の All。
    func setRouting(at index: Int, inputBus: UInt8? = nil, outputBus: UInt8? = nil,
                    channelSpec: Int8? = nil, sectionGate: UInt8? = nil) {
        guard chain.indices.contains(index) else { return }
        if let v = inputBus    { chain[index].inputBus = v }
        if let v = outputBus   { chain[index].outputBus = v }
        if let v = channelSpec { chain[index].channelSpec = v }
        if let v = sectionGate { chain[index].sectionGate = v }
        publish()
    }

    /// 外した instance を、音のスレッドが読み終えてから壊す。
    private func retire(_ instances: [UInt32]) {
        guard !instances.isEmpty, engine != 0 else { return }
        let engine = self.engine
        let mark = ETPipeline_ProcessCount()
        Task.detached(priority: .utility) {
            // 音のスレッドが 2 周するのを待つ。鳴っていなければ待っても進まないので、
            // 0.5 秒で諦めて壊す（鳴っていない＝誰も読んでいない）。
            let deadline = Date().addingTimeInterval(0.5)
            while ETPipeline_ProcessCount() < mark + 2 && Date() < deadline {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            for i in instances { et_instance_destroy(engine, i) }
        }
    }
}
