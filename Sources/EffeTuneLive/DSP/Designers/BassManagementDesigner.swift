//  BassManagementDesigner.swift
//  Bass Management の Linear 位相。入力ごとの低域 FIR を設計して instance へ送り込む。
//
//  カーネル（dsp/plugins/basics/bass_management/kernel.cpp）は IIR なら自分で
//  係数を作るが、Linear は出来上がった FIR を資産として受け取るだけ。
//  **資産が来ないあいだ Sub と LFE は無音、メインは遅れたドライ**になる（kernel.cpp:329-381）。
//
//  移した元:
//    js/bass-management/design-core.js   59-118  入力ごとの設計と使い回し
//    js/bass-management/design-worker.js 34-45   経路の並べ方と資産の組み立て
//    js/fir-crossover/design-core.js     82-106  analyzeFIRAtFrequencies（2.11.0 で増えた）
//    plugins/basics/bass_management.js   316-402 150ms の間引き・送り込む形
//
//  --- 設計 ---
//  Managed の入力と、LFE Low-pass が入っているときの LFE の入力ごとに、
//  FIR Crossover の設計（FIRCrossoverDesignCore）を 2 帯・線形位相・
//  周波数 [fc, fc, fc]・傾き [s, s, s] で回し、**下の帯（channels[0]）だけ**を取る。
//  (fc, slope) が同じ入力は同じ係数を使い回す（design-core.js:73-97）。
//  **設計の本体は FIRCrossoverDesignCore をそのまま呼ぶ。**写し直さない。
//
//  --- 資産 ---
//    topology       = matrix（kernel.cpp:218 が 4 以外を弾く）
//    paths          = 入力 ch ごとに {ch, ch, 何本目}（kernel.cpp:249-252, 275-281）
//    sampleRate     = lround(処理レート)（kernel.cpp:271）
//    headBlock 128 / rateDivider 1（kernel.cpp:219）
//    pathCount      = 本数、inputCount = processingChannels = 処理幅（kernel.cpp:216-222）
//    footprintBytes = AssetUpload.estimateFootprintBytes（bass_management.js:364-372 と同じ引数）
//  begin は params を読んで条件を見る（kernel.cpp:211-227）ので、**値を先に積んでから送る。**
//  値は EffeTuneDSP.setValue / setValues が送った直後に pushParams 済み。
//
//  --- 遅延 ---
//  Linear は taps/2 + 128、IIR は 0。begin で latency_ が変わるので commit の後に
//  鎖を組み直す。Linear → IIR は音のスレッドで遷移し終えてから 0 になる
//  （kernel.cpp:486-501 の transition → activate）ので、値を変えたあと少しのあいだ
//  instance の遅延を見て、変わったら組み直す。

import Combine
import Foundation
import os

// MARK: - 設計の結果

/// 設計して、送り込める形まで畳んだもの。応答は図に使う。
struct BassManagementDesign: Sendable {
    let key: BassManagementDesignKey
    let payload: [UInt8]
    /// 資産の経路の順（＝ key.filters の順）。
    let inputChannels: [Int]
    /// 入力ごとの |H|。responseFrequencies の点で取ったもの（design-core.js:84-88）。
    let responses: [[Float]]
    let responseFrequencies: [Double]

    /// この入力の応答。設計したときの (cutoff, slope) が今と同じときだけ返す。
    func response(channel: Int, cutoff: Double, slope: Int, sampleRate: Int) -> [Float]? {
        guard key.sampleRate == sampleRate,
              let index = key.filters.firstIndex(where: { $0.channel == channel }),
              key.filters[index].cutoff == cutoff, key.filters[index].slope == slope,
              responses.indices.contains(index) else { return nil }
        return responses[index]
    }
}

// MARK: - 設計そのもの（design-core.js の移植）

/// 状態を持たない。重いので必ず UI スレッドの外で呼ぶこと。
enum BassManagementDesignCore {

    /// design-core.js:51-57。10Hz から min(20k, 0.48·sr) までの対数 160 点。
    static func responseFrequencies(sampleRate: Int, count: Int = 160) -> [Double] {
        let maximum = min(20000, Double(sampleRate) * 0.48)
        let minimumLog = log(10.0)
        let span = log(maximum) - minimumLog
        return (0..<count).map { index in
            exp(minimumLog + span * Double(index) / Double(max(1, count - 1)))
        }
    }

    /// design-core.js:59-118 と design-worker.js:34-45。
    static func design(_ key: BassManagementDesignKey) throws -> BassManagementDesign {
        let frequencies = responseFrequencies(sampleRate: key.sampleRate)
        var designs: [String: (impulse: [Float], response: [Float])] = [:]
        var channels: [[Float]] = []
        var responses: [[Float]] = []

        for filter in key.filters {
            // design-core.js:73。JS は `${cutoff}:${slope}` で引く。
            let cacheKey = "\(filter.cutoff):\(filter.slope)"
            if designs[cacheKey] == nil {
                // design-core.js:76-83。designFIRCrossover の normalizeConfig も通す。
                let config = FIRCrossoverDesignCore.normalize(
                    sampleRate: Double(key.sampleRate),
                    taps: key.taps,
                    phase: .linear,
                    bandCount: 2,
                    frequencies: [filter.cutoff, filter.cutoff, filter.cutoff],
                    slopes: [filter.slope, filter.slope, filter.slope])
                let impulse = try FIRCrossoverDesignCore.design(config).channels[0]
                let response = try FIRCrossoverDesignCore.analyzeFIR(
                    impulse, sampleRate: Double(key.sampleRate), frequencies: frequencies)
                designs[cacheKey] = (impulse, response)
            }
            if let designed = designs[cacheKey] {
                channels.append(designed.impulse)
                responses.append(designed.response)
            }
        }

        // design-worker.js:34-38。入力 ch をそのまま出力 ch へ、IR は設計した順。
        let paths = key.filters.enumerated().map { index, filter in
            ETAssetPath(inputSlot: UInt32(filter.channel),
                        outputSlot: UInt32(filter.channel),
                        irChannel: UInt32(index))
        }
        let payload = try AssetUpload.makePayload(channels: channels,
                                                  sampleRate: key.sampleRate,
                                                  topology: .matrix,
                                                  paths: paths)
        return BassManagementDesign(key: key,
                                    payload: payload,
                                    inputChannels: key.filters.map(\.channel),
                                    responses: responses,
                                    responseFrequencies: frequencies)
    }
}

extension FIRCrossoverDesignCore {

    /// fir-crossover/design-core.js:82-106 の analyzeFIRAtFrequencies（2.11.0 で増えた）。
    /// 長さの 2 倍に 0 を詰めて変換し、各周波数の |H| を隣の bin と線形に補う。
    static func analyzeFIR(_ channel: [Float],
                           sampleRate: Double,
                           frequencies: [Double]) throws -> [Float] {
        let fftSize = channel.count * 2
        guard let fft = FIRDesign.fft(size: fftSize) else {
            throw FIRCrossoverDesignError.fftUnavailable(size: fftSize)
        }
        let spectrum = fft.realTransform(channel.map { Double($0) })
        let last = spectrum.real.count - 1
        return frequencies.map { frequency in
            let position = max(0, min(Double(last), frequency * Double(fftSize) / sampleRate))
            let lower = Int(position.rounded(.down))
            let upper = min(lower + 1, last)
            let fraction = position - Double(lower)
            let lowerMagnitude = hypot(spectrum.real[lower], spectrum.imag[lower])
            if upper == lower { return Float(lowerMagnitude) }
            let upperMagnitude = hypot(spectrum.real[upper], spectrum.imag[upper])
            return Float(lowerMagnitude + (upperMagnitude - lowerMagnitude) * fraction)
        }
    }
}

// MARK: - 設計して送り込む

/// 段 1 つぶん。材料は全部 params にあるので、値を渡されるたびに
/// 「送ってある係数と同じか」を見て、違えば設計し直す。
@MainActor
final class BassManagementDesigner: ObservableObject {

    struct Target: Equatable {
        var engine: UInt32
        var instance: UInt32
        /// et_engine_prepare へ渡した処理レート。
        var sampleRate: Double
        /// この段が処理する幅（EffeTuneDSP.routedChannels）。
        var width: Int
        /// Ch が All。違えば段ごと外れていて、カーネルは回らない（EffeTuneDSP.isChannelBypassed）。
        var allChannels: Bool
    }

    /// 画面に出す状態。文言は短い英語。
    enum Status: Equatable {
        case idle
        /// su = 0、または設定が誤っている。カーネルは素通し（kernel.cpp:455-485）。
        case passThrough
        case iir
        /// Linear だが LP の掛かる入力が無い。
        case linearWithoutFilters
        case designing
        case loading
        case waitingForAudio
        case active
        case designFailed
        case loadFailed

        var label: String {
            switch self {
            case .idle, .passThrough: return "Pass-through"
            case .iir: return "IIR"
            case .linearWithoutFilters: return "Linear"
            case .designing: return "Designing…"
            case .loading: return "Loading…"
            case .waitingForAudio: return "Waiting for audio"
            case .active: return "Active"
            case .designFailed: return "Design failed"
            case .loadFailed: return "Load failed"
            }
        }

        var isError: Bool { self == .designFailed || self == .loadFailed }
    }

    @Published private(set) var status: Status = .idle
    /// いま instance に入っている設計。図はここから応答を引く。
    @Published private(set) var design: BassManagementDesign?

    private static let log = Logger(subsystem: "ai.nemut.effetune", category: "bass-management")
    /// bass_management.js:214 の _scheduleDesign(150)。
    private static let designDebounce: TimeInterval = 0.15

    private var target: Target?
    private var settings = BassManagementSettings()
    /// 送り込めた相手と中身。instance が変わったら無いものとして扱う。
    private var residentInstance: UInt32 = 0
    private var residentKey: BassManagementDesignKey?
    /// 設計中のもの。同じ鍵で何度呼ばれても 1 回だけ回す。
    private var pendingKey: BassManagementDesignKey?
    /// この instance へ最後に回した鍵。すぐ回すか 150ms 待つかをこれで決める。
    private var attemptedKey: BassManagementDesignKey?
    /// 失敗した鍵とそのときの状態。**同じ鍵ではやり直さない。**
    /// 上流は係数が無ければ次の setParameters で組み直す（:212-213）が、こちらの送り込みは
    /// 失敗しても鎖全体の音を一瞬止める（AssetUpload.swift:48-60）。ゲインを動かすたびに
    /// それを繰り返させないため、鍵（レート・幅・taps・LP の掛かる入力）が変わるまで待つ。
    private var failure: (key: BassManagementDesignKey, status: Status)?
    /// 最後に設計したもの。送り込みだけ失敗したときは設計をやり直さずに送り直す
    /// （FIR Crossover の cache と同じ役目。FIRCrossoverDesigner.swift:744-752）。
    private var lastDesign: BassManagementDesign?
    private var designTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var latencyTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    /// 最後に鎖へ載せた（と見なした）この段の遅延。
    private var knownLatency: UInt32?

    init() {}

    // MARK: 値を受ける

    /// 値・送り先・処理幅のどれかが変わったとき。何度呼んでもよい。
    func update(target next: Target, settings nextSettings: BassManagementSettings) {
        if target?.engine != next.engine || target?.instance != next.instance {
            // 作り直された instance には資産も遅延の控えも無い。
            // 古い番号へは clear を撃たない（EffeTuneDSP が instance ごと壊している）。
            cancelDesign()
            residentInstance = 0
            residentKey = nil
            attemptedKey = nil
            failure = nil
            design = nil
            knownLatency = latency(of: next)
        }
        target = next
        settings = nextSettings
        evaluate()
        watchLatency()
    }

    /// 鎖から外れた。走っている設計を止めるだけで、engine には触らない。
    func detach() {
        cancelDesign()
        latencyTask?.cancel()
        latencyTask = nil
        statusTask?.cancel()
        statusTask = nil
        target = nil
        residentInstance = 0
        residentKey = nil
        attemptedKey = nil
        failure = nil
        lastDesign = nil
        design = nil
        status = .idle
    }

    // MARK: 判断

    /// bass_management.js:181-220 の分岐。
    ///
    /// **All 以外では設計しない。**上流は All 以外を丸ごと bypass し（:18 の
    /// supportedChannelModes と :632）、こちらも descriptor で段ごと外す
    /// （EffeTuneDSP.isChannelBypassed）。All のときの誤りは、カーネルが実際に受け取る
    /// 幅（target.width）で判断する。All でないことは画面が「Use all output channels」で出す。
    private func evaluate() {
        guard let target, target.engine != 0, target.instance != 0 else {
            cancelDesign()
            status = .idle
            return
        }
        if settings.subs == 0 {
            cancelDesign()
            clearResident()
            status = .passThrough
            return
        }
        let error = settings.configurationError(allChannels: target.allChannels, width: target.width)
        if !settings.linear {
            cancelDesign()
            clearResident()
            status = error == nil ? .iir : .passThrough
            return
        }
        if error != nil {
            // 上流も資産は外さずに止めるだけ（:201-203）。
            cancelDesign()
            status = .passThrough
            return
        }
        let key = settings.designKey(sampleRate: target.sampleRate, width: target.width)
        if key.filters.isEmpty {
            cancelDesign()
            clearResident()
            status = .linearWithoutFilters
            return
        }
        if residentInstance == target.instance, residentKey == key {
            // 送ってあるものに戻った。走っている別の設計は捨てる。
            if pendingKey != nil { cancelDesign() }
            if status != .active && status != .waitingForAudio { refreshAssetStatus() }
            return
        }
        if pendingKey == key { return }
        if let failure, failure.key == key {
            cancelDesign()
            status = failure.status
            return
        }

        // 初回と、レート・処理幅が変わったときはすぐ（:131, :613 の _scheduleDesign(0)）。
        // それ以外は 150ms 待つ（:214）。つまみを動かしているあいだは送り込まない。
        let immediate = attemptedKey == nil
            || attemptedKey?.sampleRate != key.sampleRate
            || attemptedKey?.width != key.width
        schedule(key, target: target, delay: immediate ? 0 : Self.designDebounce)
    }

    private func schedule(_ key: BassManagementDesignKey, target: Target, delay: TimeInterval) {
        cancelDesign()
        let mine = generation
        pendingKey = key
        attemptedKey = key
        status = .designing
        designTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            await self?.designAndStage(key, target: target, generation: mine)
        }
    }

    /// 重いところは UI スレッドの外。送り込みだけ UI スレッドで（AssetUpload.swift の頭）。
    private func designAndStage(_ key: BassManagementDesignKey,
                                target: Target,
                                generation mine: UInt64) async {
        let designed: BassManagementDesign
        if let cached = lastDesign, cached.key == key {
            designed = cached
        } else {
            do {
                designed = try await Task.detached(priority: .userInitiated) {
                    try BassManagementDesignCore.design(key)
                }.value
            } catch {
                guard mine == generation else { return }
                Self.log.error("設計に失敗 \(error.localizedDescription, privacy: .public)")
                pendingKey = nil
                failure = (key, .designFailed)
                status = .designFailed
                return
            }
            guard mine == generation else { return }
            lastDesign = designed
        }

        // 設計しているあいだに段が消えていれば送らない。instance の番号は engine が
        // 使い回すので、消えた段の番号へ送ると別のエフェクトの資産枠に届きうる。
        guard EffeTuneDSP.shared.chain.contains(where: {
            $0.instance == target.instance && $0.spec.type == BassManagementDesigners.type
        }) else {
            pendingKey = nil
            return
        }

        status = .loading
        let paths = key.filters.count
        let footprint = AssetUpload.estimateFootprintBytes(
            frames: key.taps,
            assetChannels: paths,
            topology: .matrix,
            processingChannels: key.width,
            headBlock: BassManagementSettings.headBlock,
            pathCount: paths,
            inputCount: key.width)
        let info = AssetUpload.BeginInfo(
            topology: .matrix,
            headBlock: UInt32(BassManagementSettings.headBlock),
            rateDivider: 1,
            pathCount: UInt32(paths),
            inputCount: UInt32(key.width),
            processingChannels: UInt32(key.width),
            footprintBytes: UInt32(clamping: footprint))
        do {
            try AssetUpload.send(engine: target.engine,
                                 instance: target.instance,
                                 payload: designed.payload,
                                 info: info)
        } catch {
            Self.log.error("送り込みに失敗 \(error.localizedDescription, privacy: .public)")
            pendingKey = nil
            // begin の条件で弾かれたなら前の係数は残っている（kernel.cpp:228 の前で戻る）。
            // 確保で落ちたなら消えている。どちらかは状態で見る。
            let state = AssetUpload.status(engine: target.engine, instance: target.instance).state
            if state != .active && state != .preparing {
                residentInstance = 0
                residentKey = nil
                design = nil
            }
            failure = (key, .loadFailed)
            status = .loadFailed
            return
        }

        pendingKey = nil
        residentInstance = target.instance
        residentKey = key
        design = designed
        // begin で latency_ が taps/2+128 になっている（kernel.cpp:241）。
        republishIfLatencyChanged(force: true)

        let state = await AssetUpload.waitForActive(engine: target.engine,
                                                    instance: target.instance,
                                                    timeout: 1.0)
        guard mine == generation else { return }
        apply(state)
    }

    // MARK: 資産

    /// Linear の係数が要らなくなった。入っていれば外す（bass_management.js:185, 194, 206）。
    private func clearResident() {
        guard let target, residentInstance == target.instance, residentKey != nil else {
            residentKey = nil
            design = nil
            return
        }
        AssetUpload.clear(engine: target.engine, instance: target.instance)
        residentInstance = 0
        residentKey = nil
        design = nil
    }

    private func cancelDesign() {
        designTask?.cancel()
        designTask = nil
        generation &+= 1
        pendingKey = nil
    }

    private func refreshAssetStatus() {
        guard let target else { return }
        apply(AssetUpload.status(engine: target.engine, instance: target.instance))
    }

    private func apply(_ state: ETAssetStatus) {
        switch state.state {
        case .active:
            status = .active
        case .error:
            status = .loadFailed
        default:
            // 音が来ないと畳み込み器が立ち上がらない。来たら active に変える。
            status = .waitingForAudio
            watchAssetStatus()
        }
    }

    /// waitingForAudio のあいだだけ、ゆっくり見に行く。
    private func watchAssetStatus() {
        statusTask?.cancel()
        let mine = generation
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, !Task.isCancelled, mine == self.generation,
                      self.status == .waitingForAudio, let target = self.target else { return }
                let state = AssetUpload.status(engine: target.engine, instance: target.instance)
                if state.state == .active {
                    self.status = .active
                    return
                }
                if state.state == .error {
                    self.status = .loadFailed
                    return
                }
            }
        }
    }

    // MARK: 遅延

    /// 値を変えたあと 1 秒だけ遅延を見る。Phase を IIR へ戻したときは
    /// 音のスレッドが遷移を終えてから 0 になる（kernel.cpp:486-489）。
    private func watchLatency() {
        latencyTask?.cancel()
        latencyTask = Task { [weak self] in
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard !Task.isCancelled, let self else { return }
                self.republishIfLatencyChanged(force: false)
            }
        }
    }

    private func republishIfLatencyChanged(force: Bool) {
        guard let target else { return }
        let now = latency(of: target)
        let changed = knownLatency.map { $0 != now } ?? false
        knownLatency = now
        if force || changed {
            EffeTuneDSP.shared.republish(reason: "遅延が変わった")
        }
    }

    private func latency(of target: Target) -> UInt32 {
        guard target.engine != 0, target.instance != 0 else { return 0 }
        return et_instance_latency(target.engine, target.instance)
    }
}

// MARK: - designer の置き場

/// 段ごとの BassManagementDesigner。鍵は Node.id（rebuildAll でも据え置き）。
///
/// FIR Crossover と違い、材料は全部 params にある。だから**ビューが無くても作る。**
/// 畳んだカードでも、プリセットを当てた直後・鎖を読んだ直後・instance を作り直した直後に
/// ETAssetReattach から呼ばれて設計まで進む。
@MainActor
final class BassManagementDesigners {

    static let shared = BassManagementDesigners()
    nonisolated static let type = "BassManagementPlugin"

    private var byNode: [UUID: BassManagementDesigner] = [:]

    private init() {}

    func designer(for id: UUID) -> BassManagementDesigner {
        if let existing = byNode[id] { return existing }
        let made = BassManagementDesigner()
        byNode[id] = made
        return made
    }

    /// 段の今の値で designer を合わせる。渡された node は古いことがあるので、
    /// 鎖から id で引き直す。鎖に居なければ何もしない。
    func sync(node: EffeTuneDSP.Node) {
        let dsp = EffeTuneDSP.shared
        prune(keeping: dsp.chain.map(\.id))
        guard let current = dsp.chain.first(where: { $0.id == node.id }),
              current.spec.type == Self.type,
              let layout = BassManagementSettings.Layout(params: current.spec.params) else { return }
        designer(for: current.id).update(
            target: BassManagementDesigner.Target(
                engine: dsp.engine,
                instance: current.instance,
                sampleRate: dsp.sampleRate,
                width: EffeTuneDSP.routedChannels(of: current),
                allChannels: !EffeTuneDSP.isChannelBypassed(current)),
            settings: BassManagementSettings(values: current.values, layout: layout))
    }

    /// 鎖から外れた段のぶんを捨てる。instance は段と一緒に壊れているので資産は外さない。
    func prune(keeping ids: [UUID]) {
        let live = Set(ids)
        for (id, designer) in byNode where !live.contains(id) {
            designer.detach()
            byNode.removeValue(forKey: id)
        }
    }
}
