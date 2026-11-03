//  RoomEQDesign.swift
//  Room EQ（RoomEqPlugin）の補正 FIR の設計そのもの。Foundation と FIRDesign と
//  AssetUpload の見積り（maximumFrames）だけで建つ。持つ状態は合成の下ごしらえの
//  使い回し（鍵つき）だけ。
//
//  RoomEQDesigner.swift から切り出した。送り込み（RoomEQDesigner.send と RoomEQCorrection）は
//  あちらに残し、こちらは試験のバンドルへそのまま入れて上流の見本と照合する
//  （Tests/Unit/RoomEQDesignTests.swift。見本は Tools/golden/designers_b_golden.mjs）。
//
//  元は Vendor/effetune/js/room-eq/design-core.js（2890 行）。
//  カーネル（Vendor/effetune/dsp/plugins/eq/room_eq/kernel.cpp）は出来上がった
//  係数を畳み込むだけで、係数を作るのは全部 JS 側にある。
//  ペイロードの並びと begin の制約は RoomEQDesigner.swift の頭に書いてある。
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
//  移した: previews（画面に出す曲線）。計算は RoomEQPreview.swift。
//  移していない: diagnostics。音には効かない。
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
    /// 立ち上がりの位置。min / lin の設計では使わない（full と残響、画面の位相・群遅延・インパルスの図で使う）。
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
    /// チャンネルごとの画面の曲線（design-core.js:2810-2830）。測定が無いチャンネルは nil。
    var previews: [RoomEQPreview?] = []

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
        var previews = [RoomEQPreview?]()
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
                previews.append(nil)
                continue
            }

            let impulses = source.impulses.filter { !$0.data.isEmpty }
            var measuredDb: [Double]
            // 画面に出す測定（design-core.js:2531, 2552）。補正には使わない。
            let displayMeasuredDb: [Double]
            // 位相・群遅延・インパルスの図の材料（design-core.js:2532-2533, 2553-2565）。
            var referenceAnalysis: RoomEQImpulseAnalysis?
            var groupDelaySources: [RoomEQImpulseAnalysis] = []
            if impulses.isEmpty {
                // 周波数特性だけの測定。full は作れない（design-core.js:2693-2697）。
                // 中身が空なら 0 dB が並ぶ（smoothing.js:145）。補正も 0 になる。
                supportsFullPhase = false
                measuredDb = interpolateLogResponse(response: source.frequencyResponse,
                                                    frequencies: frequencies)
                displayMeasuredDb = measuredDb
            } else {
                // design-core.js:2574-2589。電力の平均を取り、dB へ戻す。
                // 画面の分は dB のまま平均する（:2548, :2552）。
                let analyses = impulses.map {
                    analyzeImpulse($0, contextRate: config.sampleRate, frequencies: frequencies)
                }
                var powerMean = [Double](repeating: 0, count: frequencies.count)
                var decibelMean = [Double](repeating: 0, count: frequencies.count)
                let count = Double(analyses.count)
                for analysis in analyses {
                    let magnitude = analysis.magnitude
                    for index in 0..<powerMean.count {
                        powerMean[index] += magnitude[index] * magnitude[index] / count
                        decibelMean[index] += decibels(fromGain: magnitude[index]) / count
                    }
                }
                measuredDb = powerMean.map { decibels(fromGain: $0.squareRoot()) }
                displayMeasuredDb = decibelMean
                // design-core.js:2553-2565。referencePoint が 0 なら全部の点の合意、
                // 1 以上ならその点だけ。点の番号は並びの位置（pointId を持たないので :2556 の index）。
                if config.referencePoint > 0 && config.referencePoint <= analyses.count {
                    let requested = analyses[config.referencePoint - 1]
                    referenceAnalysis = requested
                    groupDelaySources = [requested]
                } else {
                    referenceAnalysis = alignedAverageAnalysis(analyses, config: config)
                    groupDelaySources = analyses
                }
            }

            // design-core.js:2700-2706。平滑化前の値は補正の計算に使うので残す。
            let unsmoothedMeasuredDb = measuredDb
            measuredDb = smoothFrequencyResponse(frequencies: frequencies,
                                                 magnitudes: measuredDb,
                                                 sigma: config.smoothing)
            // design-core.js:2675-2680。周波数特性だけの測定は補正に使ったものと同じ。
            let displaySmoothed = impulses.isEmpty
                ? measuredDb
                : smoothFrequencyResponse(frequencies: frequencies,
                                          magnitudes: displayMeasuredDb,
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
            var baseCorrectionDb = [Double](repeating: 0, count: frequencies.count)
            for index in 0..<frequencies.count {
                baseCorrectionDb[index] = smoothedAutomatic[index] * config.correctionAmount
                correctionDb[index] = baseCorrectionDb[index] + eqDb[index]
            }

            let synthesis = synthesizeFilter(correctionDb: correctionDb, config: config, plan: plan)
            // design-core.js:2777-2780。
            if synthesis.maximumMagnitudeErrorDb > 0.5 || synthesis.maximumPhaseErrorRadians > 0.05 {
                addWarning(.filterAccuracy)
            }
            channels.append(synthesis.taps)
            referenceLevels.append(levelDb)
            previews.append(preview(channel: previews.count,
                                    config: config,
                                    frequencies: frequencies,
                                    levelDb: levelDb,
                                    displayMeasuredDb: displayMeasuredDb,
                                    displaySmoothed: displaySmoothed,
                                    baseCorrectionDb: baseCorrectionDb,
                                    equalizerDb: eqDb,
                                    taps: synthesis.taps,
                                    referenceAnalysis: referenceAnalysis,
                                    groupDelaySources: groupDelaySources))
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
            referenceLevelDb: referenceLevels,
            previews: previews
        )
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

// ここから下の 4 つは図の計算（RoomEQPreview.swift）も使うので private にしない。
extension RoomEQDesigner {

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
                fractions[bin] = log(frequency / low) / log(high / low)
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
            logMagnitude[bin] = log(max(minimumMagnitude, magnitudes[bin]))
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

extension RoomEQDesigner {

    /// design-core.js:304-351 の analyzeImpulse。対数格子の振幅と、図に使う時間波形・立ち上がり。
    static func analyzeImpulse(_ impulse: RoomEQImpulse,
                               contextRate: Int,
                               frequencies: [Double]) -> RoomEQImpulseAnalysis {
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
        // design-core.js:323。立ち上がりも処理レートへ写す。
        let onsetIndex = impulse.sampleRate > 0
            ? jsRound(Double(impulse.onsetIndex) * Double(contextRate) / Double(impulse.sampleRate))
            : impulse.onsetIndex
        // FFT は 4 点以上の 2 の冪でないと作れないので、そこだけ下限を置いている
        // （JS は FFT(1) を作ろうとして壊れる。測定として意味の無い長さ）。
        let fftSize = max(4, FIRDesign.nextPowerOfTwo(samples.count))
        guard let fft = FIRDesign.fft(size: fftSize) else {
            return RoomEQImpulseAnalysis(samples: samples, onsetIndex: onsetIndex,
                                         magnitude: [Double](repeating: 0, count: frequencies.count))
        }
        var input = [Double](repeating: 0, count: fftSize)
        for index in 0..<min(samples.count, fftSize) { input[index] = Double(samples[index]) }
        let spectrum = fft.realTransform(input)
        let magnitude = reduceSpectrumToLogGrid(real: spectrum.real,
                                                imag: spectrum.imag,
                                                sampleRate: contextRate,
                                                fftSize: fftSize,
                                                frequencies: frequencies)
        return RoomEQImpulseAnalysis(samples: samples, onsetIndex: onsetIndex, magnitude: magnitude)
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

extension RoomEQDesigner {

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
                let fraction = log(frequency / low.frequency) / log(high.frequency / low.frequency)
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
            let significantDistance = sigma * (-2 * log(minimumSignificantWeight)).squareRoot()
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

extension RoomEQDesigner {

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

    /// design-core.js:96-98。
    static func gain(fromDecibels decibels: Double) -> Double {
        FIRDesign.gain(fromDecibels: decibels)
    }

    /// design-core.js:100-102。床は MIN_MAGNITUDE = 1e-8。
    static func decibels(fromGain value: Double) -> Double {
        FIRDesign.decibels(fromGain: value, floor: minimumMagnitude)
    }
}

// MARK: - 持ち上げの頭打ち

extension RoomEQDesigner {

    /// design-core.js:721-727 の softLimitBoost（上流も export している）。
    /// 上限の 1dB 手前から丸めて、上限で止める。
    static func softLimitBoost(_ decibels: Double, maximum: Double) -> Double {
        let kneeStart = maximum - 1
        if decibels <= kneeStart { return decibels }
        if decibels >= maximum { return maximum }
        let position = decibels - kneeStart
        return kneeStart + position + position * position - position * position * position
    }
}

// MARK: - ETEffect のパラメータとの行き来

extension RoomEQDesigner {

    /// ETEffect の値の並びでの位置。Generated/EffectCatalog.swift:606-612。
    enum ParameterOffset {
        static let latencyMode = 0
        static let filterDelaySamples = 1
        static let channelDelay = 2
        static let outputGain = 3
    }

    /// latencyMode は列挙の**番号**で入っている（0→"0"、1→"128"、2→"256"…）。
    /// カーネルの headBlock は中身のほうの数なので、ここで読み替える。
    /// EffectCatalog.swift:607 と dsp/plugins/eq/room_eq/params.json:8。
    /// 有限でない値と、Int に入らないほど大きい値は、丸める前に 128 へ倒す
    /// （`Int(Float.nan)` は trap する）。表の外は元から 128 なので、それ以外の答えは変わらない。
    static func latencyMode(fromParameterValue value: Float) -> UInt32 {
        guard value.isFinite, abs(value) < 64 else { return 128 }
        let index = Int(value.rounded())
        guard index >= 0, index < allowedLatencyModes.count else { return 128 }
        return allowedLatencyModes[index]
    }

    static func parameterValue(forLatencyMode mode: UInt32) -> Float {
        Float(allowedLatencyModes.firstIndex(of: mode) ?? 1)
    }

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
