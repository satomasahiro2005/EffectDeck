//  RoomEQDesigner.swift
//  Room EQ（RoomEqPlugin）の補正 FIR を設計して instance へ送り込む。
//
//  元は Vendor/effetune/js/room-eq/design-core.js（2890 行）。
//  カーネル（Vendor/effetune/dsp/plugins/eq/room_eq/kernel.cpp）は出来上がった
//  係数を畳み込むだけで、係数を作るのは全部 JS 側にある。
//
//  --- どこまで移したか（先に書いておく）---
//  移した: phase = min / lin の経路。これが既定（room_eq.js:901 で pm='min'）。
//          測定が周波数特性だけの場合も、インパルス応答が在る場合も通る。
//  移していない: phase = full の経路（位相補正・低域位相拡張・残響補正）。
//          directSpectrum / consensusDirectPhaseCorrection / consensusLowPhaseCorrection /
//          reverbExtendedConsensus / correctionTimingAlignment と
//          js/room-eq/group-delay-analysis.js（389 行）が丸ごと要る。
//          design(config:sources:) に .full を渡すと .linear に落として設計し、
//          RoomEQDesign.phaseFallback に true を立てて知らせる。黙って通さない。
//  移していない: previews（画面に出す曲線）と diagnostics。音には効かない。
//
//  --- ペイロードの並び（ETA1）---
//  読み手: dsp/plugins/eq/room_eq/kernel.cpp:311-318 (validatePayload)
//            +0  u32 magic 0x31415445
//            +4  u32 channels      … begin へ渡した channels と一致すること
//            +8  u32 frames        … 同上
//            +12 u32 sampleRate    … std::lround(sample_rate_) と一致すること
//            +16 u32 topology      … 同上
//            +20/+24/+28 u32 0
//          dsp/plugins/eq/room_eq/kernel.cpp:249-250
//            頭の 32 バイトの直後から float32 が channel-major で channels*frames 個。
//            そのまま convolver_.commit(samples, channels, frames) へ渡される
//  書き手: js/ir-library/ir-asset-payload.js:59-96 (buildIrAssetPayload)
//          js/room-eq/design-worker.js:21-27
//            topology は channels.length > 1 なら independent、そうでなければ mono
//            sampleRate は result.config.sampleRate（正規化後の整数）
//
//  --- begin の制約（kernel.cpp:292-309 validateBegin）---
//    topology=mono なら channels==1、independent なら channels==processingChannels
//    frames は 1〜131072
//    headBlock は 0 / 128 / 256 / 512 / 1024 のどれか
//    rateDivider==1、pathCount==0、inputCount==0
//    byteSize == 32 + channels*frames*4
//    **filterDelaySamples（fd）が 0〜65536 の範囲に入っていること。**
//    fd は begin の時点のパラメータが読まれる（kernel.cpp:232-233 で
//    candidate_latency_ = headBlock + fd）。だから送り込む前に
//    RoomEQDesign.filterDelaySamples と latencyMode を先にパラメータへ書くこと。
//    順番を逆にすると、遅延だけ前の設計のまま残る。
//
//  --- 重さ ---
//  設計は taps=32768 で FFT 65536 点を 1 チャンネルあたり 3 回（最小位相の
//  ケプストラムで 2 回、合成と検証で 2 回のうち 1 回は共通）回す。音のスレッドでは
//  やらない。RoomEQCorrection が Task.detached で外へ出し、出来上がってから
//  MainActor で送る。JS も Worker でやっている（js/room-eq/designer.js:1-10）。
//
//  --- 数の扱い ---
//  JS の Number は double。途中は Double、カーネルへ渡す直前に Float へ落とす。

import Foundation
import os

// MARK: - 設定

/// 位相の作り方。room_eq.js の pm。
enum RoomEQPhase: String, Sendable, CaseIterable {
    /// 最小位相。遅延ゼロ。既定（room_eq.js:901）。
    case minimum = "min"
    /// 直線位相。taps/2 の遅延が付く。
    case linear = "lin"
    /// 測った位相まで直す。**この Swift 版では設計できない**（.linear に落ちる）。
    case full = "full"
}

/// Additional EQ の 1 バンド。room_eq.js:924-930 と同じ既定。
enum RoomEQBandType: String, Sendable {
    case peaking = "pk"
    case lowShelf = "ls"
    case highShelf = "hs"
}

struct RoomEQBand: Sendable, Equatable {
    var enabled: Bool = true
    var type: RoomEQBandType = .peaking
    var frequency: Double
    var gain: Double = 0
    var q: Double = 1

    /// room_eq.js:924-930 の既定 5 本。
    static let defaults: [RoomEQBand] = {
        let frequencies: [Double] = [100, 316, 1000, 3160, 10000]
        return frequencies.map { RoomEQBand(frequency: $0) }
    }()
}

/// 設計の設定。room_eq.js:1733-1755 の _designConfig() が作るものと同じ形。
/// 既定値は room_eq.js:901-921 のコンストラクタに合わせてある。
struct RoomEQConfig: Sendable, Equatable {
    /// エンジンのサンプルレート。**カーネルの sample_rate_ と一致していないと
    /// commit が validatePayload で落ちる**（kernel.cpp:315）。
    var sampleRate: Int = 48000
    /// 8192 / 16384 / 32768 / 65536 / 131072 のどれか。外れると 32768 になる。
    var taps: Int = 32768
    var phase: RoomEQPhase = .minimum
    /// 平滑化の幅（オクターブの σ）。0.02〜1。
    var smoothing: Double = 0.17
    /// 補正する下端。20 未満は 20 になる。
    var lowFrequency: Double = 80
    /// 補正する上端。20000 を超えない。
    var highFrequency: Double = 16000
    /// 持ち上げの上限 dB。0〜18。
    var maxBoostDb: Double = 6
    /// 補正の効き。0〜1（room_eq.js は cr/100）。
    var correctionAmount: Double = 1
    /// 直接音の窓 ms。1〜50。full 専用だが正規化はしておく。
    var directWindowMs: Double = 6
    /// 位相補正の効き。0〜1。full 専用。
    var phaseCorrectionAmount: Double = 1
    /// nil は自動。full 専用。
    var phaseLowFrequency: Double? = nil
    /// full 専用。
    var lowFrequencyPhaseExtension: Bool = false
    /// 残響補正の効き。0〜1。full 専用。
    var reverbAmount: Double = 0
    var reverbWindowMs: Double = 300
    var reverbMaxFrequency: Double = 250
    var reverbSmoothing: Double = 0.05
    /// nil は smoothing と同じ。full 専用。
    var phaseSmoothing: Double? = nil
    /// 0 は「全測定点の合意」。1 以上はその点だけ。full と previews 専用。
    var referencePoint: Int = 0
    /// Additional EQ。
    var bands: [RoomEQBand] = RoomEQBand.defaults

    /// design-core.js:2360-2409 の normalizeConfig を逐語で移したもの。
    func normalized() -> RoomEQConfig {
        var result = self
        if !RoomEQConfig.allowedTaps.contains(taps) { result.taps = 32768 }
        result.sampleRate = max(1, RoomEQDesigner.jsRound(Double(sampleRate > 0 ? sampleRate : 48000)))
        result.directWindowMs = max(1, min(50, directWindowMs))
        result.reverbWindowMs = max(20, min(1000, reverbWindowMs))
        result.smoothing = max(0.02, min(1, smoothing))
        result.lowFrequency = max(20, lowFrequency)
        result.highFrequency = min(20000, highFrequency)
        result.maxBoostDb = max(0, min(18, maxBoostDb))
        result.correctionAmount = max(0, min(1, correctionAmount))
        result.phaseCorrectionAmount = max(0, min(1, phaseCorrectionAmount))
        result.reverbAmount = max(0, min(1, reverbAmount))
        result.reverbMaxFrequency = max(20, min(20000, reverbMaxFrequency))
        result.reverbSmoothing = max(0.02, min(1, reverbSmoothing))
        if let requested = phaseLowFrequency, requested.isFinite {
            result.phaseLowFrequency = max(20, min(20000, requested))
        } else {
            result.phaseLowFrequency = nil
        }
        // 自動（nil）は振幅の平滑化と同じ値に落ちる（design-core.js:2394-2400）。
        if let requested = phaseSmoothing, requested.isFinite {
            result.phaseSmoothing = max(0.02, min(1, requested))
        } else {
            result.phaseSmoothing = result.smoothing
        }
        result.referencePoint = referencePoint >= 0 ? referencePoint : 0
        return result
    }

    /// design-core.js:2362 の一覧。
    static let allowedTaps = [8192, 16384, 32768, 65536, 131072]
}

// MARK: - 測定

/// 測った周波数特性の 1 点。
struct RoomEQResponsePoint: Sendable, Equatable {
    var frequency: Double
    var decibels: Double

    init(frequency: Double, decibels: Double) {
        self.frequency = frequency
        self.decibels = decibels
    }
}

/// 測ったインパルス応答 1 本。
struct RoomEQImpulse: Sendable {
    var data: [Float]
    /// 録った時のサンプルレート。config と違えば窓付き sinc で直す。
    var sampleRate: Int
    /// 立ち上がりの位置。min / lin では使わない（full と残響で使う）。
    var onsetIndex: Int = 0
    /// 基準の大きさ。1 以外なら割ってから解析する（design-core.js:365-372）。
    var referenceScale: Double = 1

    init(data: [Float], sampleRate: Int, onsetIndex: Int = 0, referenceScale: Double = 1) {
        self.data = data
        self.sampleRate = sampleRate
        self.onsetIndex = onsetIndex
        self.referenceScale = referenceScale
    }
}

/// 1 チャンネル分の測定。
/// インパルス応答が 1 本でも在ればそちらが使われ、無ければ frequencyResponse を読む
/// （design-core.js:2572, 2694-2698）。
struct RoomEQSource: Sendable {
    var impulses: [RoomEQImpulse] = []
    var frequencyResponse: [RoomEQResponsePoint] = []

    init(impulses: [RoomEQImpulse] = [], frequencyResponse: [RoomEQResponsePoint] = []) {
        self.impulses = impulses
        self.frequencyResponse = frequencyResponse
    }
}

// MARK: - 出来上がり

/// 設計の結果に付く注意。design-core.js:18-19。
enum RoomEQQualityWarning: String, Sendable {
    /// 合成した FIR が狙いから離れている。taps か smoothing を増やす。
    case filterAccuracy
    /// full を頼まれたが、インパルス応答が無い測定が混じっている。
    case impulseResponseRequired
    /// この Swift 版が full を設計できないので lin に落とした（JS には無い）。
    case fullPhaseNotPorted
}

struct RoomEQDesign: Sendable {
    /// 係数。channel-major。そのまま AssetUpload.send の channels へ渡せる。
    var channels: [[Float]]
    /// 正規化した後の設定。
    var config: RoomEQConfig
    /// 実際に作った位相の種類（.full を頼まれても .linear が入る）。
    var appliedPhase: RoomEQPhase
    /// .full を頼まれて .linear に落としたか。
    var phaseFallback: Bool
    /// カーネルの fd へ書く値。design-core.js:2879。
    var filterDelaySamples: Int
    /// 1 bin あたりの Hz。design-core.js:2880。
    var resolutionHz: Double
    /// 全チャンネルにインパルス応答が揃っていたか。design-core.js:2545, 2693。
    var supportsFullPhase: Bool
    var qualityWarnings: [RoomEQQualityWarning]
    /// チャンネルごとの基準レベル dB（補正の狙い）。測定が無いチャンネルは nil。
    var referenceLevelDb: [Double?]

    var sampleRate: Int { config.sampleRate }
    var taps: Int { config.taps }
}

enum RoomEQDesignError: Error, LocalizedError {
    case noSources
    case channelCountMismatch(assetChannels: Int, processingChannels: Int)
    case tapsExceedAssetCapacity(taps: Int, maximumTaps: Int)
    case invalidLatencyMode(UInt32)

    var errorDescription: String? {
        switch self {
        case .noSources:
            return "Room EQ needs at least one measured channel."
        case .channelCountMismatch(let assetChannels, let processingChannels):
            return "The correction has \(assetChannels) channels but the effect processes \(processingChannels)."
        case .tapsExceedAssetCapacity(let taps, let maximumTaps):
            return "\(taps) taps do not fit in the 32 MiB asset slot. Use \(maximumTaps) or fewer."
        case .invalidLatencyMode(let value):
            return "Latency mode \(value) is not one of 0, 128, 256, 512, 1024."
        }
    }
}

// MARK: - 設計

enum RoomEQDesigner {

    // 名前を log にすると Foundation の log() が隠れて自然対数が呼べなくなる。
    private static let logger = Logger(subsystem: "ai.nemut.effetune", category: "roomeq")

    /// design-core.js:16。
    static let minimumMagnitude = 1e-8

    /// カーネルが受け取る latencyMode（params.json の lt）。
    static let allowedLatencyModes: [UInt32] = [0, 128, 256, 512, 1024]

    // MARK: 入口

    /// 補正 FIR を設計する。
    /// design-core.js:2529-2890 の designRoomEq を、phase = min / lin の範囲で移したもの。
    ///
    /// **重い。** taps=32768・2 チャンネルで 65536 点の FFT を 6 回ほど回す。
    /// 音のスレッドからも MainActor からも呼ばないこと。RoomEQCorrection が
    /// Task.detached の中から呼ぶ。
    ///
    /// - Parameter sources: チャンネルの並び。nil の枠は素通し（単位インパルス）になる
    ///   （design-core.js:2547-2549）。
    static func design(config requestedConfig: RoomEQConfig,
                       sources: [RoomEQSource?]) -> RoomEQDesign {
        var config = requestedConfig.normalized()
        let phaseFallback = config.phase == .full
        if phaseFallback {
            // full は移せていない。黙って違う音を出すより、lin で設計して知らせる。
            config.phase = .linear
        }

        let nyquist = Double(config.sampleRate) / 2
        let frequencies = createLogFrequencyGrid(low: 20,
                                                 high: min(20000, nyquist * 0.96),
                                                 spacingOctaves: 0.01)
        let eqDb = equalizerDecibels(config: config, frequencies: frequencies)

        var channels = [[Float]]()
        var referenceLevels = [Double?]()
        var warnings = [RoomEQQualityWarning]()
        var supportsFullPhase = true

        func addWarning(_ warning: RoomEQQualityWarning) {
            // JS はチャンネルごとに push するので同じものが並ぶ。読む側は [0] しか
            // 見ないので（room_eq.js:1035）、ここでは 1 つにまとめている。
            if !warnings.contains(warning) { warnings.append(warning) }
        }

        if phaseFallback { addWarning(.fullPhaseNotPorted) }

        let plan: SynthesisPlan? = frequencies.count >= 2
            ? synthesisPlan(gridFrequencies: frequencies, config: config)
            : nil

        for source in sources {
            // 測定の無い枠は素通し（design-core.js:2546-2565）。
            // JS はここで supportsFullPhase を触らないので、こちらも触らない。
            guard let source, let plan, !frequencies.isEmpty else {
                channels.append(unitImpulse(config: config))
                referenceLevels.append(nil)
                continue
            }

            let impulses = source.impulses.filter { !$0.data.isEmpty }
            var measuredDb: [Double]
            if impulses.isEmpty {
                // 周波数特性だけの測定。full は作れない（design-core.js:2693-2697）。
                // 中身が空なら 0 dB が並ぶ（smoothing.js:145）。補正も 0 になる。
                supportsFullPhase = false
                measuredDb = interpolateLogResponse(response: source.frequencyResponse,
                                                    frequencies: frequencies)
            } else {
                // design-core.js:2574-2589。電力の平均を取り、dB へ戻す。
                var powerMean = [Double](repeating: 0, count: frequencies.count)
                let count = Double(impulses.count)
                for impulse in impulses {
                    let magnitude = impulseMagnitude(impulse: impulse,
                                                     contextRate: config.sampleRate,
                                                     frequencies: frequencies)
                    for index in 0..<powerMean.count {
                        powerMean[index] += magnitude[index] * magnitude[index] / count
                    }
                }
                measuredDb = powerMean.map { decibels(fromGain: $0.squareRoot()) }
            }

            // design-core.js:2700-2706。平滑化前の値は補正の計算に使うので残す。
            let unsmoothedMeasuredDb = measuredDb
            measuredDb = smoothFrequencyResponse(frequencies: frequencies,
                                                 magnitudes: measuredDb,
                                                 sigma: config.smoothing)

            let effectiveHigh = min(config.highFrequency, Double(config.sampleRate) * 0.45)

            // design-core.js:2713-2722。帯域内の電力平均が補正の狙いになる。
            var levelPower = 0.0
            var levelCount = 0
            for index in 0..<frequencies.count {
                let frequency = frequencies[index]
                if frequency < config.lowFrequency || frequency > effectiveHigh { continue }
                let amplitude = gain(fromDecibels: measuredDb[index])
                levelPower += amplitude * amplitude
                levelCount += 1
            }
            let levelDb = decibels(fromGain: (levelPower / Double(levelCount > 0 ? levelCount : 1)).squareRoot())

            // design-core.js:2723-2735。帯域の内側だけ持ち上げ／下げ、外は 0。
            var automatic = [Double](repeating: 0, count: frequencies.count)
            for index in 0..<frequencies.count {
                let frequency = frequencies[index]
                automatic[index] = frequency > config.lowFrequency && frequency < effectiveHigh
                    ? softLimitBoost(levelDb - unsmoothedMeasuredDb[index], maximum: config.maxBoostDb)
                    : 0
            }
            let smoothedAutomatic = smoothFrequencyResponse(frequencies: frequencies,
                                                            magnitudes: automatic,
                                                            sigma: config.smoothing)

            // design-core.js:2736-2745。
            var correctionDb = [Double](repeating: 0, count: frequencies.count)
            for index in 0..<frequencies.count {
                correctionDb[index] = smoothedAutomatic[index] * config.correctionAmount + eqDb[index]
            }

            let synthesis = synthesizeFilter(correctionDb: correctionDb, config: config, plan: plan)
            // design-core.js:2777-2780。
            if synthesis.maximumMagnitudeErrorDb > 0.5 || synthesis.maximumPhaseErrorRadians > 0.05 {
                addWarning(.filterAccuracy)
            }
            channels.append(synthesis.taps)
            referenceLevels.append(levelDb)
        }

        if requestedConfig.phase == .full && !supportsFullPhase {
            addWarning(.impulseResponseRequired)
        }

        return RoomEQDesign(
            channels: channels,
            config: config,
            appliedPhase: config.phase,
            phaseFallback: phaseFallback,
            // design-core.js:2879。min は遅延ゼロ、それ以外は taps/2。
            filterDelaySamples: config.phase == .minimum ? 0 : config.taps / 2,
            resolutionHz: Double(config.sampleRate) / Double(config.taps),
            supportsFullPhase: supportsFullPhase,
            qualityWarnings: warnings,
            referenceLevelDb: referenceLevels
        )
    }

    // MARK: 送り込む

    /// 出来上がった係数を instance の枠 0 へ送る。
    ///
    /// **先にパラメータ（fd / lt）を書いてから呼ぶこと。** カーネルは begin の時点の
    /// fd を読んで遅延を決める（kernel.cpp:232-233）。
    @MainActor
    static func send(design: RoomEQDesign,
                     engine: UInt32,
                     instance: UInt32,
                     slot: UInt32 = 0,
                     processingChannels: UInt32,
                     latencyMode: UInt32 = 128) throws {
        guard !design.channels.isEmpty else { throw RoomEQDesignError.noSources }
        guard allowedLatencyModes.contains(latencyMode) else {
            throw RoomEQDesignError.invalidLatencyMode(latencyMode)
        }
        // design-worker.js:24-26 と同じ決め方。
        let topology: ETAssetTopology = design.channels.count > 1 ? .independent : .mono
        // kernel.cpp:293-295。mono は 1 チャンネル、independent は処理幅と一致。
        if topology == .independent && UInt32(design.channels.count) != processingChannels {
            throw RoomEQDesignError.channelCountMismatch(assetChannels: design.channels.count,
                                                          processingChannels: Int(processingChannels))
        }
        try AssetUpload.send(engine: engine,
                             instance: instance,
                             slot: slot,
                             channels: design.channels,
                             sampleRate: design.sampleRate,
                             topology: topology,
                             headBlock: latencyMode,
                             rateDivider: 1,
                             processingChannels: processingChannels)
        logger.notice("room eq 送り込み ch=\(design.channels.count) taps=\(design.taps) fd=\(design.filterDelaySamples)")
    }

    /// 設計を外のスレッドで回し、出来上がってから送るところまで。
    @discardableResult
    static func designAndSend(config: RoomEQConfig,
                              sources: [RoomEQSource?],
                              engine: UInt32,
                              instance: UInt32,
                              slot: UInt32 = 0,
                              processingChannels: UInt32,
                              latencyMode: UInt32 = 128) async throws -> RoomEQDesign {
        try checkCapacity(config: config,
                          channelCount: sources.count,
                          processingChannels: Int(processingChannels),
                          latencyMode: latencyMode)
        let design = await Task.detached(priority: .userInitiated) {
            RoomEQDesigner.design(config: config, sources: sources)
        }.value
        try await MainActor.run {
            try send(design: design,
                     engine: engine,
                     instance: instance,
                     slot: slot,
                     processingChannels: processingChannels,
                     latencyMode: latencyMode)
        }
        return design
    }

    /// 32MiB の枠に収まるか。設計に数秒かけてから落とすのは無駄なので先に見る。
    /// 上限は AssetUpload.maximumFrames が畳み込み器の分まで含めて出す。
    static func checkCapacity(config: RoomEQConfig,
                              channelCount: Int,
                              processingChannels: Int,
                              latencyMode: UInt32 = 128) throws {
        let normalized = config.normalized()
        guard channelCount >= 1 else { throw RoomEQDesignError.noSources }
        let topology: ETAssetTopology = channelCount > 1 ? .independent : .mono
        let maximum = AssetUpload.maximumFrames(sourceFrames: normalized.taps,
                                                assetChannels: channelCount,
                                                topology: topology,
                                                processingChannels: max(1, processingChannels),
                                                headBlock: Int(latencyMode))
        guard maximum >= normalized.taps else {
            let usable = RoomEQConfig.allowedTaps.filter { $0 <= maximum }.max() ?? 0
            throw RoomEQDesignError.tapsExceedAssetCapacity(taps: normalized.taps,
                                                            maximumTaps: usable)
        }
    }

    /// 枠に収まる一番大きい taps。画面で選ばせる前に絞るのに使う。
    static func largestUsableTaps(channelCount: Int,
                                  processingChannels: Int,
                                  latencyMode: UInt32 = 128) -> Int? {
        let topology: ETAssetTopology = channelCount > 1 ? .independent : .mono
        for taps in RoomEQConfig.allowedTaps.sorted(by: >) {
            let maximum = AssetUpload.maximumFrames(sourceFrames: taps,
                                                    assetChannels: max(1, channelCount),
                                                    topology: topology,
                                                    processingChannels: max(1, processingChannels),
                                                    headBlock: Int(latencyMode))
            if maximum >= taps { return taps }
        }
        return nil
    }
}

// MARK: - 合成

private extension RoomEQDesigner {

    /// design-core.js:196-245 の getSynthesisPlan。
    struct SynthesisPlan {
        var fftSize: Int
        var binFrequencies: [Double]
        var lowerIndices: [Int]
        var fractions: [Double]
        var linearWindow: [Double]
        var minimumWindow: [Double]
    }

    struct PlanKey: Hashable {
        var sampleRate: Int
        var taps: Int
        var gridCount: Int
        var first: Double
        var last: Double
    }

    struct SynthesisResult {
        var taps: [Float]
        var maximumMagnitudeErrorDb: Double
        var maximumPhaseErrorRadians: Double
    }

    static func synthesisPlan(gridFrequencies: [Double], config: RoomEQConfig) -> SynthesisPlan {
        let key = PlanKey(sampleRate: config.sampleRate,
                          taps: config.taps,
                          gridCount: gridFrequencies.count,
                          first: gridFrequencies[0],
                          last: gridFrequencies[gridFrequencies.count - 1])
        planCacheLock.lock()
        if let cached = planCache[key] {
            planCacheLock.unlock()
            return cached
        }
        planCacheLock.unlock()

        let fftSize = config.taps * 2
        let binCount = fftSize / 2 + 1
        var binFrequencies = [Double](repeating: 0, count: binCount)
        var lowerIndices = [Int](repeating: 0, count: binCount)
        var fractions = [Double](repeating: 0, count: binCount)
        var upper = 1
        for bin in 0..<binCount {
            let frequency = Double(bin) * Double(config.sampleRate) / Double(fftSize)
            binFrequencies[bin] = frequency
            while upper < gridFrequencies.count && gridFrequencies[upper] < frequency { upper += 1 }
            if frequency <= gridFrequencies[0] {
                lowerIndices[bin] = 0
                fractions[bin] = 0
            } else if upper >= gridFrequencies.count {
                lowerIndices[bin] = gridFrequencies.count - 2
                fractions[bin] = 1
            } else {
                let low = gridFrequencies[upper - 1]
                let high = gridFrequencies[upper]
                lowerIndices[bin] = upper - 1
                fractions[bin] = Foundation.log(frequency / low) / Foundation.log(high / low)
            }
        }

        // design-core.js:216-234 の 2 つの窓は FIRDesign.createWindow と同じ式
        // （fir-crossover:97-115 と five-band-fir-peq:216-234 の実装がそれ）。
        let plan = SynthesisPlan(fftSize: fftSize,
                                 binFrequencies: binFrequencies,
                                 lowerIndices: lowerIndices,
                                 fractions: fractions,
                                 linearWindow: FIRDesign.createWindow(taps: config.taps,
                                                                      minimumPhase: false),
                                 minimumWindow: FIRDesign.createWindow(taps: config.taps,
                                                                       minimumPhase: true))
        planCacheLock.lock()
        planCache[key] = plan
        planOrder.append(key)
        // JS は 8 個で一番古いものを捨てる（design-core.js:241-243）。
        while planOrder.count > 8 {
            planCache.removeValue(forKey: planOrder.removeFirst())
        }
        planCacheLock.unlock()
        return plan
    }

    /// design-core.js:257-266 の interpolateGainsWithPlan。dB で補間してから振幅へ。
    static func interpolateGains(_ values: [Double], plan: SynthesisPlan) -> [Double] {
        var result = [Double](repeating: 0, count: plan.binFrequencies.count)
        for index in 0..<result.count {
            let lower = plan.lowerIndices[index]
            let fraction = plan.fractions[index]
            let interpolated = values[lower] + fraction * (values[lower + 1] - values[lower])
            result[index] = gain(fromDecibels: interpolated)
        }
        return result
    }

    /// design-core.js:1784-2134 の synthesizeFilter のうち、min / lin だけ。
    /// full の枝（位相補正・低域位相拡張・残響）は移していない。
    static func synthesizeFilter(correctionDb: [Double],
                                 config: RoomEQConfig,
                                 plan: SynthesisPlan) -> SynthesisResult {
        let magnitudes = interpolateGains(correctionDb, plan: plan)
        var phase = [Double](repeating: 0, count: magnitudes.count)
        if config.phase == .minimum {
            phase = minimumPhase(magnitudes: magnitudes, fftSize: plan.fftSize)
        }
        return render(magnitudes: magnitudes, phase: phase, config: config, plan: plan)
    }

    /// design-core.js:729-740 の minimumPhaseForMagnitude。実ケプストラムの折り返し。
    static func minimumPhase(magnitudes: [Double], fftSize: Int) -> [Double] {
        guard let fft = FIRDesign.fft(size: fftSize) else {
            return [Double](repeating: 0, count: fftSize / 2 + 1)
        }
        let half = fftSize / 2
        var logMagnitude = [Double](repeating: 0, count: half + 1)
        for bin in 0...half {
            logMagnitude[bin] = Foundation.log(max(minimumMagnitude, magnitudes[bin]))
        }
        let halfImaginary = [Double](repeating: 0, count: logMagnitude.count)
        var cepstrum = fft.inverseRealTransform(real: logMagnitude, imag: halfImaginary)
        for index in 1..<half { cepstrum[index] *= 2 }
        for index in (half + 1)..<fftSize { cepstrum[index] = 0 }
        return fft.realTransform(cepstrum).imag
    }

    /// design-core.js:1623-1656 の renderSynthesis と 1584-1620 の verifySynthesis。
    static func render(magnitudes: [Double],
                       phase: [Double],
                       config: RoomEQConfig,
                       plan: SynthesisPlan) -> SynthesisResult {
        let fftSize = plan.fftSize
        let half = fftSize / 2
        var real = [Double](repeating: 0, count: half + 1)
        var imag = [Double](repeating: 0, count: half + 1)
        if config.phase == .linear {
            // 1 bin あたり -π/2 ずつ回す。時間にすると fftSize/4 = taps/2 の遅れ。
            for bin in 0...half {
                let magnitude = magnitudes[bin]
                switch bin & 3 {
                case 0: real[bin] = magnitude
                case 1: imag[bin] = -magnitude
                case 2: real[bin] = -magnitude
                default: imag[bin] = magnitude
                }
            }
        } else {
            for bin in 0...half {
                real[bin] = magnitudes[bin] * cos(phase[bin])
                imag[bin] = magnitudes[bin] * sin(phase[bin])
            }
        }
        imag[0] = 0
        imag[imag.count - 1] = 0

        guard let fft = FIRDesign.fft(size: fftSize) else {
            return SynthesisResult(taps: [Float](repeating: 0, count: config.taps),
                                   maximumMagnitudeErrorDb: 0,
                                   maximumPhaseErrorRadians: 0)
        }
        let time = fft.inverseRealTransform(real: real, imag: imag)
        let window = config.phase == .minimum ? plan.minimumWindow : plan.linearWindow
        var taps = [Float](repeating: 0, count: config.taps)
        for index in 0..<config.taps {
            // Float32Array への代入で丸まるところまで JS と同じにする。
            taps[index] = Float(time[index] * window[index])
        }

        let verification = verify(taps: taps,
                                  intendedMagnitudes: magnitudes,
                                  intendedReal: real,
                                  intendedImaginary: imag,
                                  config: config,
                                  fft: fft)
        return SynthesisResult(taps: taps,
                               maximumMagnitudeErrorDb: verification.magnitude,
                               maximumPhaseErrorRadians: verification.phase)
    }

    /// design-core.js:1584-1620 の verifySynthesis。
    static func verify(taps: [Float],
                       intendedMagnitudes: [Double],
                       intendedReal: [Double],
                       intendedImaginary: [Double],
                       config: RoomEQConfig,
                       fft: FIRDesign.RealFFT) -> (magnitude: Double, phase: Double) {
        let fftSize = config.taps * 2
        var input = [Double](repeating: 0, count: fftSize)
        for index in 0..<min(taps.count, fftSize) { input[index] = Double(taps[index]) }
        let spectrum = fft.realTransform(input)
        let effectiveHigh = min(config.highFrequency, Double(config.sampleRate) * 0.45)
        var maximumMagnitudeErrorDb = 0.0
        var minimumPhaseCosine = 1.0
        let floorPower = minimumMagnitude * minimumMagnitude
        guard spectrum.real.count > 1 else { return (0, 0) }
        for bin in 1..<spectrum.real.count {
            let frequency = Double(bin) * Double(config.sampleRate) / Double(fftSize)
            if frequency < config.lowFrequency || frequency > effectiveHigh { continue }
            let actualReal = spectrum.real[bin]
            let actualImaginary = spectrum.imag[bin]
            let actualPower = actualReal * actualReal + actualImaginary * actualImaginary
            let intendedMagnitude = intendedMagnitudes[bin]
            let intendedPower = intendedMagnitude * intendedMagnitude
            let magnitudeError = abs(10 * log10(max(floorPower, actualPower) / intendedPower))
            if magnitudeError > maximumMagnitudeErrorDb { maximumMagnitudeErrorDb = magnitudeError }
            if config.phase != .minimum {
                let denominator = (actualPower * intendedPower).squareRoot()
                if denominator > floorPower {
                    let phaseCosine = (actualReal * intendedReal[bin] +
                                       actualImaginary * intendedImaginary[bin]) / denominator
                    if phaseCosine < minimumPhaseCosine { minimumPhaseCosine = phaseCosine }
                }
            }
        }
        let maximumPhaseErrorRadians = config.phase == .minimum
            ? 0
            : acos(max(-1, min(1, minimumPhaseCosine)))
        return (maximumMagnitudeErrorDb, maximumPhaseErrorRadians)
    }

    /// design-core.js:2354-2358 の unitImpulse。測定の無いチャンネルは素通し。
    static func unitImpulse(config: RoomEQConfig) -> [Float] {
        var taps = [Float](repeating: 0, count: config.taps)
        taps[config.phase == .minimum ? 0 : config.taps / 2] = 1
        return taps
    }
}

// MARK: - 測定を読む

private extension RoomEQDesigner {

    /// design-core.js:341-388 の analyzeImpulse のうち、対数格子の振幅だけ。
    /// onsetIndex と時間波形は full / 残響でしか使わないので持ち回らない。
    static func impulseMagnitude(impulse: RoomEQImpulse,
                                 contextRate: Int,
                                 frequencies: [Double]) -> [Double] {
        var samples: [Float]
        if impulse.sampleRate == contextRate {
            samples = impulse.data
        } else {
            samples = resampleWindowedSinc(input: impulse.data,
                                           sourceRate: impulse.sampleRate,
                                           targetRate: contextRate)
        }
        // design-core.js:365-372。
        let referenceScale = impulse.referenceScale.isFinite && impulse.referenceScale > minimumMagnitude
            ? impulse.referenceScale
            : 1
        if referenceScale != 1 {
            for index in 0..<samples.count {
                samples[index] = Float(Double(samples[index]) / referenceScale)
            }
        }
        // FFT は 4 点以上の 2 の冪でないと作れないので、そこだけ下限を置いている
        // （JS は FFT(1) を作ろうとして壊れる。測定として意味の無い長さ）。
        let fftSize = max(4, FIRDesign.nextPowerOfTwo(samples.count))
        guard let fft = FIRDesign.fft(size: fftSize) else {
            return [Double](repeating: 0, count: frequencies.count)
        }
        var input = [Double](repeating: 0, count: fftSize)
        for index in 0..<min(samples.count, fftSize) { input[index] = Double(samples[index]) }
        let spectrum = fft.realTransform(input)
        return reduceSpectrumToLogGrid(real: spectrum.real,
                                       imag: spectrum.imag,
                                       sampleRate: contextRate,
                                       fftSize: fftSize,
                                       frequencies: frequencies)
    }

    /// design-core.js:268-292 の reduceSpectrumToLogGrid。
    /// 格子の 1 点が受け持つ幅の中で電力の平均を取る。
    static func reduceSpectrumToLogGrid(real: [Double],
                                        imag: [Double],
                                        sampleRate: Int,
                                        fftSize: Int,
                                        frequencies: [Double]) -> [Double] {
        var output = [Double](repeating: 0, count: frequencies.count)
        guard frequencies.count >= 2, real.count >= 2 else { return output }
        let binWidth = Double(sampleRate) / Double(fftSize)
        for index in 0..<frequencies.count {
            let lower = index == 0
                ? frequencies[index] / (frequencies[1] / frequencies[0]).squareRoot()
                : (frequencies[index - 1] * frequencies[index]).squareRoot()
            let upper = index == frequencies.count - 1
                ? frequencies[index] * (frequencies[index] / frequencies[index - 1]).squareRoot()
                : (frequencies[index] * frequencies[index + 1]).squareRoot()
            var firstBin = Int((lower / binWidth).rounded(.up))
            var lastBin = Int((upper / binWidth).rounded(.down))
            if firstBin < 1 { firstBin = 1 }
            if lastBin >= real.count { lastBin = real.count - 1 }
            if lastBin < firstBin {
                let centre = min(real.count - 1, max(1, jsRound(frequencies[index] / binWidth)))
                firstBin = centre
                lastBin = centre
            }
            var power = 0.0
            var count = 0
            if firstBin <= lastBin {
                for bin in firstBin...lastBin {
                    power += real[bin] * real[bin] + imag[bin] * imag[bin]
                    count += 1
                }
            }
            output[index] = (power / Double(count > 0 ? count : 1)).squareRoot()
        }
        return output
    }

    /// utils/measurement-dsp/resample.js:61-118 の resampleWindowedSinc。
    /// 係数の並びは整数レートかどうかで分岐する。分岐ごと移さないと位相がずれる。
    static func resampleWindowedSinc(input: [Float], sourceRate: Int, targetRate: Int) -> [Float] {
        guard sourceRate > 0, targetRate > 0 else { return input }
        if sourceRate == targetRate { return input }
        let outputLength = max(1, jsRound(Double(input.count) * Double(targetRate) / Double(sourceRate)))
        var output = [Float](repeating: 0, count: outputLength)
        let ratio = Double(sourceRate) / Double(targetRate)
        let bandLimit = targetRate < sourceRate ? Double(targetRate) / Double(sourceRate) : 1
        let cutoff = bandLimit * 0.95
        let transitionWidthRadians = Double.pi * bandLimit * 0.1
        let attenuationDb = 100.0
        let beta = 0.1102 * (attenuationDb - 8.7)
        let radius = Int(((attenuationDb - 8) / (4.57 * transitionWidthRadians)).rounded(.up))
        guard radius >= 1 else { return input }
        let normalizer = FIRDesign.besselI0(beta)

        // 整数レートなら位相は有限個。JS は表に貯めて使い回す（resample.js:47-59）。
        let divisor = greatestCommonDivisor(sourceRate, targetRate)
        let sourceStep = sourceRate / divisor
        let phaseCount = targetRate / divisor
        var phases = [Int: [Double]]()

        for outputIndex in 0..<outputLength {
            let position = Double(outputIndex) * ratio
            let centre = phaseCount > 0
                ? (outputIndex * sourceStep) / phaseCount
                : Int(position.rounded(.down))
            let phaseIndex = phaseCount > 0 ? (outputIndex * sourceStep) % phaseCount : 0
            let coefficients: [Double]
            if let cached = phases[phaseIndex] {
                coefficients = cached
            } else {
                let fraction = phaseCount > 0
                    ? Double(phaseIndex) / Double(phaseCount)
                    : position - Double(centre)
                coefficients = phaseCoefficients(fraction: fraction,
                                                 cutoff: cutoff,
                                                 radius: radius,
                                                 beta: beta,
                                                 normalizer: normalizer)
                phases[phaseIndex] = coefficients
            }
            let firstInputIndex = centre - radius + 1
            var weighted = 0.0
            if firstInputIndex >= 0 && firstInputIndex + coefficients.count <= input.count {
                for tap in 0..<coefficients.count {
                    weighted += Double(input[firstInputIndex + tap]) * coefficients[tap]
                }
                output[outputIndex] = Float(weighted)
                continue
            }
            var weightTotal = 0.0
            for tap in 0..<coefficients.count {
                let inputIndex = firstInputIndex + tap
                if inputIndex < 0 || inputIndex >= input.count { continue }
                let weight = coefficients[tap]
                weighted += Double(input[inputIndex]) * weight
                weightTotal += weight
            }
            output[outputIndex] = weightTotal == 0 ? 0 : Float(weighted / weightTotal)
        }
        return output
    }

    /// resample.js:28-45 の createPhaseCoefficients。
    static func phaseCoefficients(fraction: Double,
                                  cutoff: Double,
                                  radius: Int,
                                  beta: Double,
                                  normalizer: Double) -> [Double] {
        var coefficients = [Double](repeating: 0, count: radius * 2)
        var total = 0.0
        for tap in 0..<coefficients.count {
            let offset = Double(tap - radius + 1)
            let distance = fraction - offset
            let normalized = distance / Double(radius)
            if normalized <= -1 || normalized >= 1 { continue }
            let window = FIRDesign.besselI0(beta * (1 - normalized * normalized).squareRoot()) / normalizer
            let weight = cutoff * sinc(distance * cutoff) * window
            coefficients[tap] = weight
            total += weight
        }
        if total != 0 {
            for tap in 0..<coefficients.count { coefficients[tap] /= total }
        }
        return coefficients
    }

    static func sinc(_ value: Double) -> Double {
        value == 0 ? 1 : sin(Double.pi * value) / (Double.pi * value)
    }

    static func greatestCommonDivisor(_ left: Int, _ right: Int) -> Int {
        var a = left
        var b = right
        while b != 0 {
            let remainder = a % b
            a = b
            b = remainder
        }
        return a
    }
}

// MARK: - 周波数の軸と平滑化

private extension RoomEQDesigner {

    /// utils/measurement-dsp/smoothing.js:137-142 の createLogFrequencyGrid。
    static func createLogFrequencyGrid(low: Double, high: Double, spacingOctaves: Double) -> [Double] {
        guard low > 0, high > low, spacingOctaves > 0 else { return [] }
        let span = log2(high / low)
        let steps = Int((span / spacingOctaves).rounded(.up))
        guard steps >= 1 else { return [] }
        return (0...steps).map { low * pow(2, Double($0) / Double(steps) * span) }
    }

    /// utils/measurement-dsp/smoothing.js:144-157 の interpolateLogResponse。
    /// 周波数の対数で線形に補間する。両端は端の値で止める。
    static func interpolateLogResponse(response: [RoomEQResponsePoint],
                                       frequencies: [Double]) -> [Double] {
        guard !response.isEmpty else { return [Double](repeating: 0, count: frequencies.count) }
        let points = response.sorted { $0.frequency < $1.frequency }
        var result = [Double](repeating: 0, count: frequencies.count)
        var upper = 1
        for index in 0..<frequencies.count {
            let frequency = frequencies[index]
            while upper < points.count && points[upper].frequency < frequency { upper += 1 }
            if upper >= points.count {
                result[index] = points[points.count - 1].decibels
            } else if frequency <= points[0].frequency {
                result[index] = points[0].decibels
            } else {
                let low = points[upper - 1]
                let high = points[upper]
                let fraction = Foundation.log(frequency / low.frequency) / Foundation.log(high.frequency / low.frequency)
                result[index] = low.decibels + fraction * (high.decibels - low.decibels)
            }
        }
        return result
    }

    /// utils/measurement-dsp/smoothing.js:10-135 の smoothFrequencyResponse。
    /// 周波数はそのままなので dB だけ返す。
    /// σ はオクターブ（log2 の距離）で測る。等間隔の格子なら重みを 1 本作って使い回す。
    static func smoothFrequencyResponse(frequencies: [Double],
                                        magnitudes: [Double],
                                        sigma: Double) -> [Double] {
        let count = frequencies.count
        guard count >= 3, sigma > 0 else { return magnitudes }
        var logFrequencies = [Double](repeating: 0, count: count)
        var ascending = true
        for index in 0..<count {
            logFrequencies[index] = log2(frequencies[index])
            if index > 0 && !(logFrequencies[index] >= logFrequencies[index - 1]) { ascending = false }
        }
        let spacing = (logFrequencies[count - 1] - logFrequencies[0]) / Double(count - 1)
        var uniform = spacing.isFinite && spacing > 0
        var index = 1
        while uniform && index < count - 1 {
            let expected = logFrequencies[0] + Double(index) * spacing
            uniform = abs(logFrequencies[index] - expected) <= 1e-10
            index += 1
        }

        // Number.EPSILON の二乗（smoothing.js:8）。ここを下回る重みは足しても動かない。
        let minimumSignificantWeight = Double.ulpOfOne * Double.ulpOfOne
        var offsetWeights: [Double]? = nil
        var weightRadius = count - 1
        var firstCandidates: [Int]? = nil
        var lastCandidates: [Int]? = nil

        if uniform {
            var weights = [Double](repeating: 0, count: count)
            let denominator = 2 * sigma * sigma
            for offset in 0..<count {
                let distance = Double(offset) * spacing
                weights[offset] = exp(-(distance * distance) / denominator)
            }
            while weightRadius > 0 && weights[weightRadius] <= minimumSignificantWeight {
                weightRadius -= 1
            }
            offsetWeights = weights
        } else if ascending {
            let significantDistance = sigma * (-2 * Foundation.log(minimumSignificantWeight)).squareRoot()
            var first = [Int](repeating: 0, count: count)
            var last = [Int](repeating: 0, count: count)
            var firstCandidate = 0
            var lastCandidate = 0
            for pointIndex in 0..<count {
                let centre = logFrequencies[pointIndex]
                while firstCandidate < count && logFrequencies[firstCandidate] < centre - significantDistance {
                    firstCandidate += 1
                }
                if lastCandidate < firstCandidate { lastCandidate = firstCandidate }
                while lastCandidate < count && logFrequencies[lastCandidate] <= centre + significantDistance {
                    lastCandidate += 1
                }
                first[pointIndex] = firstCandidate
                last[pointIndex] = lastCandidate
            }
            firstCandidates = first
            lastCandidates = last
        }

        var smoothed = [Double](repeating: 0, count: count)
        for pointIndex in 0..<count {
            var weighted = 0.0
            var weightTotal = 0.0
            if let weights = offsetWeights {
                let first = max(0, pointIndex - weightRadius)
                let last = min(count, pointIndex + weightRadius + 1)
                var candidateIndex = first
                while candidateIndex < pointIndex {
                    let weight = weights[pointIndex - candidateIndex]
                    weighted += magnitudes[candidateIndex] * weight
                    weightTotal += weight
                    candidateIndex += 1
                }
                weighted += magnitudes[pointIndex] * weights[0]
                weightTotal += weights[0]
                candidateIndex = pointIndex + 1
                while candidateIndex < last {
                    let weight = weights[candidateIndex - pointIndex]
                    weighted += magnitudes[candidateIndex] * weight
                    weightTotal += weight
                    candidateIndex += 1
                }
            } else {
                let first = firstCandidates?[pointIndex] ?? 0
                let last = lastCandidates?[pointIndex] ?? count
                let denominator = 2 * sigma * sigma
                var candidateIndex = first
                while candidateIndex < last {
                    let distance = logFrequencies[candidateIndex] - logFrequencies[pointIndex]
                    let weight = exp(-(distance * distance) / denominator)
                    weighted += magnitudes[candidateIndex] * weight
                    weightTotal += weight
                    candidateIndex += 1
                }
            }
            smoothed[pointIndex] = weighted / weightTotal
        }
        return smoothed
    }
}

// MARK: - Additional EQ と小道具

private extension RoomEQDesigner {

    /// design-core.js:639-655 の equalizerDb。バンドの振幅特性を dB で足し合わせる。
    static func equalizerDecibels(config: RoomEQConfig, frequencies: [Double]) -> [Double] {
        var result = [Double](repeating: 0, count: frequencies.count)
        for band in config.bands {
            if !band.enabled || band.gain == 0 { continue }
            for index in 0..<frequencies.count {
                result[index] += decibels(fromGain: rbjMagnitude(type: band.type,
                                                                 center: band.frequency,
                                                                 gainDb: band.gain,
                                                                 q: band.q,
                                                                 frequency: frequencies[index],
                                                                 sampleRate: config.sampleRate))
            }
        }
        return result
    }

    /// design-core.js:590-637 の rbjMagnitude。
    /// RBJ Cookbook の双二次を組んで、その振幅だけを 1 点で読む。
    static func rbjMagnitude(type: RoomEQBandType,
                             center: Double,
                             gainDb: Double,
                             q: Double,
                             frequency: Double,
                             sampleRate: Int) -> Double {
        let rate = Double(sampleRate)
        let nyquistCenter = center < rate * 0.49 ? center : rate * 0.49
        let omega = 2 * Double.pi * nyquistCenter / rate
        let cosine = cos(omega)
        let sine = sin(omega)
        let amplitude = FIRDesign.amplitude(fromDecibels: gainDb)
        let alpha = sine / (2 * q)
        let root = amplitude.squareRoot()
        let b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double
        switch type {
        case .lowShelf:
            b0 = amplitude * ((amplitude + 1) - (amplitude - 1) * cosine + 2 * root * alpha)
            b1 = 2 * amplitude * ((amplitude - 1) - (amplitude + 1) * cosine)
            b2 = amplitude * ((amplitude + 1) - (amplitude - 1) * cosine - 2 * root * alpha)
            a0 = (amplitude + 1) + (amplitude - 1) * cosine + 2 * root * alpha
            a1 = -2 * ((amplitude - 1) + (amplitude + 1) * cosine)
            a2 = (amplitude + 1) + (amplitude - 1) * cosine - 2 * root * alpha
        case .highShelf:
            b0 = amplitude * ((amplitude + 1) + (amplitude - 1) * cosine + 2 * root * alpha)
            b1 = -2 * amplitude * ((amplitude - 1) + (amplitude + 1) * cosine)
            b2 = amplitude * ((amplitude + 1) + (amplitude - 1) * cosine - 2 * root * alpha)
            a0 = (amplitude + 1) - (amplitude - 1) * cosine + 2 * root * alpha
            a1 = 2 * ((amplitude - 1) - (amplitude + 1) * cosine)
            a2 = (amplitude + 1) - (amplitude - 1) * cosine - 2 * root * alpha
        case .peaking:
            b0 = 1 + alpha * amplitude
            b1 = -2 * cosine
            b2 = 1 - alpha * amplitude
            a0 = 1 + alpha / amplitude
            a1 = -2 * cosine
            a2 = 1 - alpha / amplitude
        }
        let targetOmega = 2 * Double.pi * frequency / rate
        let targetCosine = cos(targetOmega)
        let targetSine = sin(targetOmega)
        let doubleCosine = cos(2 * targetOmega)
        let doubleSine = sin(2 * targetOmega)
        let numeratorReal = b0 + b1 * targetCosine + b2 * doubleCosine
        let numeratorImag = -b1 * targetSine - b2 * doubleSine
        let denominatorReal = a0 + a1 * targetCosine + a2 * doubleCosine
        let denominatorImag = -a1 * targetSine - a2 * doubleSine
        return hypot(numeratorReal, numeratorImag) /
            max(minimumMagnitude, hypot(denominatorReal, denominatorImag))
    }

    /// design-core.js:721-727 の softLimitBoost。
    /// 上限の 1dB 手前から丸めて、上限で止める。
    static func softLimitBoost(_ decibels: Double, maximum: Double) -> Double {
        let kneeStart = maximum - 1
        if decibels <= kneeStart { return decibels }
        if decibels >= maximum { return maximum }
        let position = decibels - kneeStart
        return kneeStart + position + position * position - position * position * position
    }

    /// design-core.js:96-98。
    static func gain(fromDecibels decibels: Double) -> Double {
        FIRDesign.gain(fromDecibels: decibels)
    }

    /// design-core.js:100-102。床は MIN_MAGNITUDE = 1e-8。
    static func decibels(fromGain value: Double) -> Double {
        FIRDesign.decibels(fromGain: value, floor: minimumMagnitude)
    }
}

extension RoomEQDesigner {
    /// JS の Math.round。0.5 は常に大きい方へ行く（Swift の rounded() は
    /// 負の 0.5 で向きが違う）。
    static func jsRound(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int((value + 0.5).rounded(.down))
    }
}

private extension RoomEQDesigner {
    // 合成の下ごしらえは設定が同じなら使い回せる（design-core.js:196-245 の
    // synthesisPlanCache と同じ役目）。設計は外のスレッドで走るので鍵を掛ける。
    static let planCacheLock = NSLock()
    static var planCache = [PlanKey: SynthesisPlan]()
    static var planOrder = [PlanKey]()
}

// MARK: - 作り直しと送り直し

/// パラメータが変わったら設計し直して送り直す係。
/// room_eq.js:1770-1774 の _scheduleDesign と同じで、150ms 待ってからまとめて 1 回だけ
/// 設計する。設計は Task.detached で外へ出す（JS は Worker：designer.js:1-10）。
/// 途中で新しい注文が来たら、古い結果は世代番号で捨てる（room_eq.js:1843-1846）。
@MainActor
final class RoomEQCorrection: ObservableObject {

    enum State: Equatable {
        case idle
        case designing
        case sending
        /// 送り込み済み。カーネルが active になるのは音が何ブロックか通った後。
        case sent
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var design: RoomEQDesign?
    /// カーネルの資産の様子。送った後に読むと preparing → active と進む。
    @Published private(set) var assetState: ETAssetState = .none

    private var task: Task<Void, Never>?
    private var generation = 0

    init() {}

    /// 設計と送り込みを予約する。既に予約が在れば捨てて取り直す。
    /// - Parameter delay: まとめる待ち時間。既定 150ms は room_eq.js:1770 と同じ。
    func schedule(config: RoomEQConfig,
                  sources: [RoomEQSource?],
                  engine: UInt32,
                  instance: UInt32,
                  slot: UInt32 = 0,
                  processingChannels: UInt32,
                  latencyMode: UInt32 = 128,
                  delay: Duration = .milliseconds(150),
                  onDesigned: ((RoomEQDesign) -> Void)? = nil) {
        generation += 1
        let generation = self.generation
        task?.cancel()
        state = .designing
        // この Task は @MainActor の中で作るので、中身も MainActor で走る。
        // 外へ出るのは下の Task.detached だけ。
        task = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            if Task.isCancelled { return }
            guard let self, self.isCurrent(generation) else { return }

            do {
                try RoomEQDesigner.checkCapacity(config: config,
                                                 channelCount: sources.count,
                                                 processingChannels: Int(processingChannels),
                                                 latencyMode: latencyMode)
            } catch {
                self.finish(generation, failure: error)
                return
            }

            // 重いのは全部ここ。音のスレッドにも MainActor にも乗せない。
            let designed = await Task.detached(priority: .userInitiated) {
                RoomEQDesigner.design(config: config, sources: sources)
            }.value

            if Task.isCancelled { return }
            guard self.isCurrent(generation) else { return }
            self.publish(generation, design: designed)
            // 出来上がった遅延を先にパラメータへ書かせる。カーネルは begin の時点の
            // fd を読む（kernel.cpp:232-233）ので、送るより前でないと効かない。
            onDesigned?(designed)

            do {
                try RoomEQDesigner.send(design: designed,
                                        engine: engine,
                                        instance: instance,
                                        slot: slot,
                                        processingChannels: processingChannels,
                                        latencyMode: latencyMode)
            } catch {
                self.finish(generation, failure: error)
                return
            }
            guard self.isCurrent(generation) else { return }
            let status = await AssetUpload.waitForActive(engine: engine,
                                                         instance: instance,
                                                         slot: slot)
            self.finish(generation, status: status)
        }
    }

    /// 予約を取り消す。送り込み済みのものは外さない。
    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        if state == .designing || state == .sending { state = .idle }
    }

    /// 資産を外して素通しに戻す。
    func clear(engine: UInt32, instance: UInt32, slot: UInt32 = 0) {
        cancel()
        AssetUpload.clear(engine: engine, instance: instance, slot: slot)
        design = nil
        assetState = .none
        state = .idle
    }

    private func isCurrent(_ generation: Int) -> Bool {
        self.generation == generation
    }

    private func publish(_ generation: Int, design: RoomEQDesign) {
        guard isCurrent(generation) else { return }
        self.design = design
        state = .sending
    }

    private func finish(_ generation: Int, status: ETAssetStatus) {
        guard isCurrent(generation) else { return }
        assetState = status.state
        state = .sent
    }

    private func finish(_ generation: Int, failure: Error) {
        guard isCurrent(generation) else { return }
        let message = (failure as? LocalizedError)?.errorDescription ?? "The correction could not be loaded."
        state = .failed(message)
    }
}
