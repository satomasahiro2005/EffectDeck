//  CrosstalkCancellationDesigner.swift
//  Crosstalk Cancellation（CrosstalkCancellationPlugin）の係数を作る。
//
//  カーネル（Vendor/effetune/dsp/plugins/spatial/crosstalk_cancellation/kernel.cpp）は
//  出来上がった FIR を 4 チャンネル受け取るだけで、設計は JS 側にある。
//  その設計を写したのがこのファイル。元は
//  Vendor/effetune/js/crosstalk-cancellation/design-core.js（649 行）。
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
//  --- 係数の並び ---
//  design-core.js:4 の CROSSTALK_FIR_CHANNEL_ORDER が ['C11','C21','C12','C22']。
//  design-core.js:626-629 に「ETA1 trueStereo は input-major に経路を食うので
//  行優先ではなくこの順」と書いてある。上の paths と一致している。
//
//  --- 何を写したか ---
//    normalizeConfig                 design-core.js:53-72
//    baseMeasurementId / sourceRecord design-core.js:74-156
//    validateCrosstalkSources        design-core.js:158-189
//    alignedSession                  design-core.js:191-228
//    smoothDelayCompensatedSpectrum  design-core.js:261-315
//    prepareCrosstalkPlant           design-core.js:328-432
//    solveRegularizedCrosstalkBin    design-core.js:439-473
//    singularValuesSquared / bandWeight design-core.js:479-514
//    designSpectra                   design-core.js:516-588
//    firEdgeWindow                   design-core.js:590-597
//    designCrosstalkCancellation     design-core.js:599-649
//    resampleWindowedSinc            js/utils/measurement-dsp/resample.js:1-119
//  定数はすべて design-core.js:6-18 の値をそのまま写した。
//
//  --- 数の扱い ---
//  JS の Number は double。途中計算はすべて Double で回し、Float へ落とすのは
//  JS が Float32Array に入れている所だけ（整列後の応答・リサンプラの出力・最後の係数）。
//  そこで float32 に丸まるのは JS も同じなので、丸め位置まで合わせてある。
//
//  --- 重さ ---
//  JS は Worker で回している（design-worker.js:7）。理由は重いから。
//  taps=16384 なら FFT の大きさは 65536 で、それを 4 本ぶん逆変換する。
//  だからここでも設計は Task.detached へ出し、出来上がってから送る。
//  送り込み（AssetUpload.send）だけは MainActor で行う。

import Combine
import Foundation
import os

// MARK: - 設計そのもの

enum CrosstalkCancellationDesigner {

    // MARK: 定数（design-core.js:4-18 の逐語）

    /// 出来上がる 4 本の名前。並びはこの順で固定（design-core.js:4）。
    static let firChannelOrder = ["C11", "C21", "C12", "C22"]

    /// design-core.js:7。これ以外の taps は 4096 に倒される。
    static let allowedTaps = [1024, 2048, 4096, 8192, 16384]

    private static let virtualChannelSeparator = "::ch="
    private static let commonPrerollSeconds = 0.001
    /// 1/6 オクターブ。smoothDelayCompensatedSpectrum の既定値なので private にしない。
    static let complexSmoothingOctaves = 1.0 / 6.0
    private static let bandTransitionOctaves = 1.0
    private static let directWindowLowFrequencyCycles = 1.0
    private static let firEdgeTaperFraction = 0.01
    static let outOfWindowWarningRatio = 1e-3
    private static let minimumMagnitude = 1e-12
    private static let resampleAttenuationDb = 100.0
    private static let resampleTransitionBandFraction = 0.1

    /// JS に無い歯止め。JS は長さが負や桁外れだと RangeError で落ちるだけだが、
    /// Swift は `[Float](repeating:count:)` が負の数で trap するので、
    /// その手前で設計失敗として返す。値は 4M サンプル（768kHz で 5.4 秒）。
    private static let maximumAlignedFrames = 1 << 22
    private static let maximumFFTSize = 1 << 22

    // MARK: - 型

    /// 4 つの枠。並びは design-core.js:6 の SOURCE_SLOTS と同じ。
    enum Slot: String, CaseIterable, Sendable {
        case ll, lr, rl, rr

        /// 画面に出す名前。
        var label: String { rawValue.uppercased() }
    }

    /// 枠ごとに 1 つ持つ入れ物。JS の `Object.fromEntries(SOURCE_SLOTS.map(...))` の代わり。
    struct SlotMap<Value: Sendable>: Sendable {
        var ll: Value
        var lr: Value
        var rl: Value
        var rr: Value

        subscript(slot: Slot) -> Value {
            get {
                switch slot {
                case .ll: return ll
                case .lr: return lr
                case .rl: return rl
                case .rr: return rr
                }
            }
            set {
                switch slot {
                case .ll: ll = newValue
                case .lr: lr = newValue
                case .rl: rl = newValue
                case .rr: rr = newValue
                }
            }
        }
    }

    /// 測定の出力時刻の基準。design-core.js:8 の SUPPORTED_TIME_REFERENCES は
    /// audio-context と file だけを通す。media-element は :111-117 で名指しで弾かれる。
    enum TimeReference: String, Sendable {
        case audioContext = "audio-context"
        case file = "file"
        case mediaElement = "media-element"
    }

    /// 1 枠ぶんの測定。JS の assignment + impulse record を 1 つにまとめたもの
    /// （design-core.js:79-156 が読むフィールドだけ）。
    struct Measurement: Equatable, Sendable {
        /// 測定の ID。`::ch=` の後ろがチャンネル番号で、前が測定セッションの ID。
        var id: String
        /// インパルス応答。JS の record.data（Float32Array か Float64Array）。
        var data: [Double]
        /// 測定のサンプリング周波数。4 枠すべてで同じでないといけない。
        var sampleRate: Int
        /// 記録の先頭が、測定開始から何サンプル目か。
        var trimStartSamples: Int
        /// data の中で音が立ち上がる位置。
        var onsetIndex: Int
        /// deconvolution の基準の倍率（JS の refScale）。
        /// 校正済みなら 1 前後、未校正だと数万になる。割り戻さないと
        /// 行列の階数が 1 に潰れる（design-core.js:201-207 の注記）。
        var referenceScale: Double
        var timeReference: TimeReference

        init(id: String,
             data: [Double],
             sampleRate: Int,
             trimStartSamples: Int,
             onsetIndex: Int,
             referenceScale: Double = 1,
             timeReference: TimeReference = .audioContext) {
            self.id = id
            self.data = data
            self.sampleRate = sampleRate
            self.trimStartSamples = trimStartSamples
            self.onsetIndex = onsetIndex
            self.referenceScale = referenceScale
            self.timeReference = timeReference
        }
    }

    typealias Sources = SlotMap<Measurement>

    /// 設計の指示。design-core.js:53-72 の normalizeConfig が受ける形。
    /// 画面から来た値をそのまま入れてよい。normalized() が JS と同じ倒し方をする。
    ///
    /// sampleRate は **エンジンのレート**（AudioIO.processingRate）でないといけない。
    /// kernel.cpp:263 がペイロードの +12 とエンジンのレートを突き合わせるから。
    struct Config: Equatable, Sendable {
        var sampleRate: Int = 48000
        var taps: Int = 4096
        var regularization: Double = 50
        var maxGainDb: Double = 12
        var lowFrequency: Double = 200
        var highFrequency: Double = 6000
        var directWindowMs: Double = 8

        /// design-core.js:65。設計は本線の山をここへ置く。
        /// カーネル側の `filterDelaySamples`（params.json の fd）を同じ値にしないと
        /// dry が wet とずれる（kernel.cpp:198 が dry の遅延に足している）。
        var filterDelaySamples: Int { taps / 2 }

        /// design-core.js:53-72 の逐語。
        func normalized() -> Config {
            var result = Config()
            result.taps = CrosstalkCancellationDesigner.allowedTaps.contains(taps) ? taps : 4096
            result.sampleRate = Int(
                CrosstalkCancellationDesigner.clamp(Double(sampleRate), 8000, 768000, 48000).rounded()
            )
            let low = CrosstalkCancellationDesigner.clamp(lowFrequency, 20, 2000, 200)
            result.lowFrequency = low
            result.highFrequency = max(
                low,
                CrosstalkCancellationDesigner.clamp(highFrequency, 1000, 20000, 6000)
            )
            result.regularization = CrosstalkCancellationDesigner.clamp(regularization, 0, 100, 50)
            result.maxGainDb = CrosstalkCancellationDesigner.clamp(maxGainDb, 0, 24, 12)
            result.directWindowMs = CrosstalkCancellationDesigner.clamp(directWindowMs, 2, 50, 8)
            return result
        }
    }

    /// design-core.js:631-647 の diagnostics。
    struct Diagnostics: Equatable, Sendable {
        var fftSize: Int
        var measurementSampleRate: Int
        var maxGainLinear: Double
        var maxGainDb: Double
        var maxGainLimitDb: Double
        var gainLimitActive: Bool
        var gainLimitedBins: Int
        var outOfWindowEnergyRatio: Double
        var outOfWindowWarningThreshold: Double
        var tapsWarning: Bool
        var requestedLowFrequency: Double
        var effectiveLowFrequency: Double
        var lowFrequencyClamped: Bool
        var effectiveHighFrequency: Double
        var normalizationScale: Double
    }

    /// design-core.js:625-648 の戻り値。
    struct Design: Sendable {
        /// C11 / C21 / C12 / C22 の順。長さは config.taps。
        var channels: [[Float]]
        /// 倒した後の config。fd の付け替えにはこちらを使う。
        var config: Config
        var diagnostics: Diagnostics
    }

    /// 設計の失敗。code は design-core.js の fail(code, ...) と同じ文字列。
    /// message も JS の文面をそのまま英語で持つ（画面に出すのは英語）。
    struct DesignError: Error, LocalizedError, Equatable, Sendable {
        let code: String
        let slot: Slot?
        let message: String

        var errorDescription: String? { message }

        fileprivate init(_ code: String, _ message: String, slot: Slot? = nil) {
            self.code = code
            self.message = message
            self.slot = slot
        }
    }

    /// 複素数。design-core.js:230-255 の complex* 群。
    struct Cx: Equatable, Sendable {
        var re: Double
        var im: Double

        init(_ re: Double, _ im: Double) {
            self.re = re
            self.im = im
        }

        static func * (left: Cx, right: Cx) -> Cx {
            Cx(left.re * right.re - left.im * right.im, left.re * right.im + left.im * right.re)
        }

        static func + (left: Cx, right: Cx) -> Cx { Cx(left.re + right.re, left.im + right.im) }
        static func - (left: Cx, right: Cx) -> Cx { Cx(left.re - right.re, left.im - right.im) }

        func scaled(_ scale: Double) -> Cx { Cx(re * scale, im * scale) }
        var conjugate: Cx { Cx(re, -im) }
        var magnitudeSquared: Double { re * re + im * im }
    }

    /// 片側スペクトル。長さは fftSize/2+1。
    struct Spectrum: Sendable {
        var real: [Double]
        var imag: [Double]
    }

    // MARK: - 入口

    /// 4 つの測定から 4 本の FIR を作る。**重い。音のスレッドから呼ばない。**
    /// design-core.js:599-649 の designCrosstalkCancellation。
    static func design(config rawConfig: Config, sources: Sources) throws -> Design {
        let plant = try preparePlant(config: rawConfig, sources: sources)
        let designed = designSpectra(plant)

        guard let fft = FIRDesign.fft(size: plant.fftSize) else {
            throw DesignError("fft-unavailable", "The design transform could not be created.")
        }
        let completeResponses = designed.output.map {
            fft.inverseRealTransform(real: $0.real, imag: $0.imag)
        }

        var totalEnergy = 0.0
        var outOfWindowEnergy = 0.0
        for response in completeResponses {
            for index in 0..<response.count {
                let energy = response[index] * response[index]
                totalEnergy += energy
                if index >= plant.config.taps { outOfWindowEnergy += energy }
            }
        }
        let outOfWindowEnergyRatio = outOfWindowEnergy / max(totalEnergy, minimumMagnitude)

        let taps = plant.config.taps
        let channels: [[Float]] = completeResponses.map { response in
            (0..<taps).map { Float(response[$0] * firEdgeWindow($0, taps)) }
        }
        for channel in channels {
            for sample in channel where !sample.isFinite {
                throw DesignError("non-finite-design", "The crosstalk filter could not be designed.")
            }
        }

        let diagnostics = Diagnostics(
            fftSize: plant.fftSize,
            measurementSampleRate: plant.measurementSampleRate,
            maxGainLinear: designed.maximumGain,
            maxGainDb: 20 * log10(max(designed.maximumGain, minimumMagnitude)),
            maxGainLimitDb: plant.config.maxGainDb,
            gainLimitActive: designed.gainLimitedBins > 0,
            gainLimitedBins: designed.gainLimitedBins,
            outOfWindowEnergyRatio: outOfWindowEnergyRatio,
            outOfWindowWarningThreshold: outOfWindowWarningRatio,
            tapsWarning: outOfWindowEnergyRatio > outOfWindowWarningRatio,
            requestedLowFrequency: plant.config.lowFrequency,
            effectiveLowFrequency: plant.effectiveLowFrequency,
            lowFrequencyClamped: plant.lowFrequencyClamped,
            effectiveHighFrequency: plant.effectiveHighFrequency,
            normalizationScale: plant.normalizationScale
        )
        return Design(channels: channels, config: plant.config, diagnostics: diagnostics)
    }

    // MARK: - 測定を確かめる（design-core.js:74-189）

    /// design-core.js:74-77。`::ch=` の前だけを取る。先頭に在るときは切らない。
    static func baseMeasurementId(_ id: String) -> String {
        guard let found = id.range(of: virtualChannelSeparator, options: .backwards) else { return id }
        let separator = id.distance(from: id.startIndex, to: found.lowerBound)
        return separator > 0 ? String(id[id.startIndex..<found.lowerBound]) : id
    }

    /// design-core.js:79-156 の sourceRecord。
    /// 枠に 1 つしか入らない形にしてあるので、複数点の検査（:93-104）は要らない。
    private static func validate(_ measurement: Measurement, slot: Slot) throws {
        let id = measurement.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            throw DesignError("missing-measurement-id",
                              "This measurement assignment does not have an ID.", slot: slot)
        }
        if measurement.timeReference == .mediaElement {
            throw DesignError("media-element-time-reference",
                              "This measurement does not have an audio-clock time reference.",
                              slot: slot)
        }
        guard measurement.onsetIndex >= 0 else {
            throw DesignError("invalid-onset",
                              "This measurement has an invalid impulse-response onset.", slot: slot)
        }
        guard measurement.sampleRate > 0 else {
            throw DesignError("invalid-sample-rate",
                              "This measurement has an invalid sample rate.", slot: slot)
        }
        guard !measurement.data.isEmpty else {
            throw DesignError("invalid-impulse-response",
                              "This measurement has an empty impulse response.", slot: slot)
        }
        for sample in measurement.data where !sample.isFinite {
            throw DesignError("invalid-impulse-response",
                              "This measurement has invalid impulse-response data.", slot: slot)
        }
    }

    /// design-core.js:158-189 の validateCrosstalkSources。
    static func validate(_ sources: Sources) throws -> (sources: Sources, sampleRate: Int) {
        var normalized = sources
        for slot in Slot.allCases {
            try validate(sources[slot], slot: slot)
            normalized[slot].id = sources[slot].id.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let ids = Slot.allCases.map { normalized[$0].id }
        if Set(ids).count != ids.count {
            throw DesignError("duplicate-measurement-assignment",
                              "Assign a different measurement channel to each slot.")
        }
        if baseMeasurementId(normalized.ll.id) != baseMeasurementId(normalized.rl.id) {
            throw DesignError(
                "left-ear-session-mismatch",
                "LL and RL must be two different channels of one measurement made with the microphone at your left ear."
            )
        }
        if baseMeasurementId(normalized.lr.id) != baseMeasurementId(normalized.rr.id) {
            throw DesignError(
                "right-ear-session-mismatch",
                "LR and RR must be two different channels of one measurement made with the microphone at your right ear."
            )
        }
        let rates = Set(Slot.allCases.map { normalized[$0].sampleRate })
        guard rates.count == 1, let rate = rates.first else {
            throw DesignError("sample-rate-mismatch",
                              "All four measurements must use the same sample rate.")
        }
        return (normalized, rate)
    }

    // MARK: - 共通の頭出しと直接音の窓（design-core.js:191-228）

    private struct AlignedSession {
        var channels: [[Float]]
        var delaySeconds: [Double]
    }

    private static func alignedSession(_ first: Measurement,
                                       _ second: Measurement,
                                       sampleRate: Int,
                                       directWindowMs: Double) throws -> AlignedSession {
        let records = [first, second]
        let absoluteOnsets = records.map { $0.trimStartSamples + $0.onsetIndex }
        let prerollSamples = max(1, Int((Double(sampleRate) * commonPrerollSeconds).rounded()))
        let commonOffset = max(0, (absoluteOnsets.min() ?? 0) - prerollSamples)
        let directSamples = max(1, Int((Double(sampleRate) * directWindowMs / 1000).rounded()))
        let alignedOnsets = absoluteOnsets.map { $0 - commonOffset }
        let length = alignedOnsets.map { $0 + directSamples + 1 }.max() ?? 0

        // JS には無い歯止め。上の maximumAlignedFrames の注記を参照。
        guard length > 0, length <= maximumAlignedFrames, alignedOnsets.allSatisfy({ $0 >= 0 }) else {
            throw DesignError("unusable-alignment",
                              "These measurements cannot be aligned. Please measure again.")
        }

        var channels = [[Float]]()
        channels.reserveCapacity(records.count)
        for (recordIndex, record) in records.enumerated() {
            var output = [Float](repeating: 0, count: length)
            let referenceScale = record.referenceScale.isFinite && record.referenceScale > minimumMagnitude
                ? record.referenceScale
                : 1
            let dataStart = record.trimStartSamples - commonOffset
            let end = alignedOnsets[recordIndex] + directSamples
            let fadeLength = max(1, directSamples / 2)
            let fadeStart = end - fadeLength
            for inputIndex in 0..<record.data.count {
                let outputIndex = dataStart + inputIndex
                if outputIndex < 0 { continue }
                // JS は continue だが、どちらも上限なのでここから先は全部外れる。
                if outputIndex >= length || outputIndex >= end { break }
                var gain = 1.0
                if outputIndex >= fadeStart {
                    let fraction = Double(outputIndex - fadeStart) / Double(fadeLength)
                    gain = 0.5 + 0.5 * cos(Double.pi * fraction)
                }
                output[outputIndex] = Float(record.data[inputIndex] * gain / referenceScale)
            }
            channels.append(output)
        }
        return AlignedSession(channels: channels,
                              delaySeconds: alignedOnsets.map { Double($0) / Double(sampleRate) })
    }

    // MARK: - リサンプラ（js/utils/measurement-dsp/resample.js）

    /// design-core.js:44-51 の resampleSupportRadius。
    private static func resampleSupportRadius(sourceRate: Int, targetRate: Int) -> Int {
        if sourceRate == targetRate { return 0 }
        let bandLimit = targetRate < sourceRate ? Double(targetRate) / Double(sourceRate) : 1
        let transitionWidthRadians = Double.pi * bandLimit * resampleTransitionBandFraction
        return Int(((resampleAttenuationDb - 8) / (4.57 * transitionWidthRadians)).rounded(.up))
    }

    /// resample.js:1-3。
    private static func sinc(_ value: Double) -> Double {
        value == 0 ? 1 : sin(Double.pi * value) / (Double.pi * value)
    }

    private static func greatestCommonDivisor(_ left: Int, _ right: Int) -> Int {
        var a = left
        var b = right
        while b != 0 {
            let remainder = a % b
            a = b
            b = remainder
        }
        return a
    }

    /// resample.js:28-45 の createPhaseCoefficients。
    private static func phaseCoefficients(fraction: Double,
                                          cutoff: Double,
                                          radius: Int,
                                          beta: Double,
                                          normalizer: Double) -> [Double] {
        var coefficients = [Double](repeating: 0, count: radius * 2)
        var total = 0.0
        for tap in 0..<coefficients.count {
            let offset = tap - radius + 1
            let distance = fraction - Double(offset)
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

    /// resample.js:61-119 の resampleWindowedSinc。
    ///
    /// JS には整数でないレート用の道（:87-94 の table なし側）も在るが、
    /// こちらはレートが Int なので必ず表の側を通る。だから写したのは表の側だけ。
    private static func resampleWindowedSinc(_ input: [Float],
                                             sourceRate: Int,
                                             targetRate: Int,
                                             radius: Int) -> [Float] {
        if sourceRate == targetRate { return input }
        let outputLength = max(
            1,
            Int((Double(input.count) * Double(targetRate) / Double(sourceRate)).rounded())
        )
        var output = [Float](repeating: 0, count: outputLength)
        let bandLimit = targetRate < sourceRate ? Double(targetRate) / Double(sourceRate) : 1
        let cutoff = bandLimit * 0.95
        let beta = 0.1102 * (resampleAttenuationDb - 8.7)
        let normalizer = FIRDesign.besselI0(beta)

        let divisor = greatestCommonDivisor(sourceRate, targetRate)
        guard divisor > 0, radius >= 1 else { return output }
        let sourceStep = sourceRate / divisor
        let phaseCount = targetRate / divisor
        // JS の coefficientTableCache と同じ「使った位相だけ作る」やり方。
        var phases = [Int: [Double]]()

        for outputIndex in 0..<outputLength {
            let position = outputIndex * sourceStep
            let center = position / phaseCount          // JS の Math.floor(...) と同じ
            let phaseIndex = position % phaseCount
            let coefficients: [Double]
            if let cached = phases[phaseIndex] {
                coefficients = cached
            } else {
                let created = phaseCoefficients(fraction: Double(phaseIndex) / Double(phaseCount),
                                                cutoff: cutoff,
                                                radius: radius,
                                                beta: beta,
                                                normalizer: normalizer)
                phases[phaseIndex] = created
                coefficients = created
            }

            let firstInputIndex = center - radius + 1
            var weighted = 0.0
            if firstInputIndex >= 0 && firstInputIndex + coefficients.count <= input.count {
                for tap in 0..<coefficients.count {
                    weighted += Double(input[firstInputIndex + tap]) * coefficients[tap]
                }
                output[outputIndex] = Float(weighted)
                continue
            }
            // 端。届いた分だけで重みを割り直す。
            var weightTotal = 0.0
            for tap in 0..<coefficients.count {
                let inputIndex = firstInputIndex + tap
                if inputIndex < 0 || inputIndex >= input.count { continue }
                weighted += Double(input[inputIndex]) * coefficients[tap]
                weightTotal += coefficients[tap]
            }
            output[outputIndex] = weightTotal == 0 ? 0 : Float(weighted / weightTotal)
        }
        return output
    }

    // MARK: - 平滑（design-core.js:261-315）

    /// 既知の遅延を外してから 1/6 オクターブの箱形平均を掛け、また遅延を戻す。
    /// 遅延を外さずに平滑すると両耳間の時間差が消える。
    static func smoothDelayCompensatedSpectrum(_ spectrum: Spectrum,
                                               sampleRate: Double,
                                               fftSize: Int,
                                               delaySeconds: Double,
                                               smoothingOctaves: Double
                                                   = CrosstalkCancellationDesigner.complexSmoothingOctaves) throws -> Spectrum {
        let length = fftSize / 2 + 1
        guard fftSize >= 2, (fftSize & (fftSize - 1)) == 0,
              sampleRate.isFinite, sampleRate > 0,
              delaySeconds.isFinite, delaySeconds >= 0,
              smoothingOctaves.isFinite, smoothingOctaves >= 0 else {
            throw DesignError("invalid-smoothing", "Complex smoothing parameters are invalid.")
        }
        guard spectrum.real.count == length, spectrum.imag.count == length else {
            throw DesignError("invalid-smoothing", "The spectrum size does not match the FFT size.")
        }

        var alignedReal = [Double](repeating: 0, count: length)
        var alignedImag = [Double](repeating: 0, count: length)
        var prefixReal = [Double](repeating: 0, count: length + 1)
        var prefixImag = [Double](repeating: 0, count: length + 1)
        for bin in 0..<length {
            let frequency = Double(bin) * sampleRate / Double(fftSize)
            let phase = 2 * Double.pi * frequency * delaySeconds
            let cosine = cos(phase)
            let sine = sin(phase)
            alignedReal[bin] = spectrum.real[bin] * cosine - spectrum.imag[bin] * sine
            alignedImag[bin] = spectrum.real[bin] * sine + spectrum.imag[bin] * cosine
            prefixReal[bin + 1] = prefixReal[bin] + alignedReal[bin]
            prefixImag[bin + 1] = prefixImag[bin] + alignedImag[bin]
        }

        var smoothedReal = [Double](repeating: 0, count: length)
        var smoothedImag = [Double](repeating: 0, count: length)
        let halfWidth = max(0, smoothingOctaves) / 2
        let lowerScale = pow(2, -halfWidth)
        let upperScale = pow(2, halfWidth)
        for bin in 0..<length {
            let first = bin == 0 ? 0 : max(1, Int((Double(bin) * lowerScale).rounded(.up)))
            let last = bin == 0 ? 0 : min(length - 1, Int((Double(bin) * upperScale).rounded(.down)))
            let count = last - first + 1
            let averageReal = (prefixReal[last + 1] - prefixReal[first]) / Double(count)
            let averageImag = (prefixImag[last + 1] - prefixImag[first]) / Double(count)
            let frequency = Double(bin) * sampleRate / Double(fftSize)
            let phase = -2 * Double.pi * frequency * delaySeconds
            let cosine = cos(phase)
            let sine = sin(phase)
            smoothedReal[bin] = averageReal * cosine - averageImag * sine
            smoothedImag[bin] = averageReal * sine + averageImag * cosine
        }
        smoothedImag[0] = 0
        smoothedImag[length - 1] = 0
        return Spectrum(real: smoothedReal, imag: smoothedImag)
    }

    // MARK: - 測定から plant へ（design-core.js:328-432）

    private struct Plant {
        let config: Config
        let spectra: SlotMap<Spectrum>
        let delays: SlotMap<Double>
        let fftSize: Int
        let measurementSampleRate: Int
        let normalizationScale: Double
        let effectiveLowFrequency: Double
        let effectiveHighFrequency: Double
        let lowFrequencyClamped: Bool
    }

    private static func preparePlant(config rawConfig: Config, sources: Sources) throws -> Plant {
        let config = rawConfig.normalized()
        let validated = try validate(sources)
        let measurementRate = validated.sampleRate

        let leftEar = try alignedSession(validated.sources.ll, validated.sources.rl,
                                         sampleRate: measurementRate,
                                         directWindowMs: config.directWindowMs)
        let rightEar = try alignedSession(validated.sources.lr, validated.sources.rr,
                                          sampleRate: measurementRate,
                                          directWindowMs: config.directWindowMs)

        let resampleRadius = resampleSupportRadius(sourceRate: measurementRate,
                                                   targetRate: config.sampleRate)
        let resampleGuardSamples = resampleRadius * 2
        func resample(_ samples: [Float]) -> [Float] {
            if resampleRadius == 0 { return samples }
            var guarded = [Float](repeating: 0, count: samples.count + resampleGuardSamples * 2)
            for index in 0..<samples.count { guarded[resampleGuardSamples + index] = samples[index] }
            return resampleWindowedSinc(guarded,
                                        sourceRate: measurementRate,
                                        targetRate: config.sampleRate,
                                        radius: resampleRadius)
        }

        let resampled = SlotMap(ll: resample(leftEar.channels[0]),
                                lr: resample(rightEar.channels[0]),
                                rl: resample(leftEar.channels[1]),
                                rr: resample(rightEar.channels[1]))
        let resampleGuardSeconds = Double(resampleGuardSamples) / Double(measurementRate)
        let delays = SlotMap(ll: leftEar.delaySeconds[0] + resampleGuardSeconds,
                             lr: rightEar.delaySeconds[0] + resampleGuardSeconds,
                             rl: leftEar.delaySeconds[1] + resampleGuardSeconds,
                             rr: rightEar.delaySeconds[1] + resampleGuardSeconds)

        let longestResponse = Slot.allCases.map { resampled[$0].count }.max() ?? 0
        let fftSize = FIRDesign.nextPowerOfTwo(max(config.taps * 4, longestResponse))
        guard fftSize <= maximumFFTSize, let fft = FIRDesign.fft(size: fftSize) else {
            throw DesignError("fft-unavailable", "The design transform could not be created.")
        }

        func spectrum(_ samples: [Float]) -> Spectrum {
            let transformed = fft.realTransform(samples.map { Double($0) })
            return Spectrum(real: transformed.real, imag: transformed.imag)
        }
        var unsmoothed = SlotMap(ll: spectrum(resampled.ll),
                                 lr: spectrum(resampled.lr),
                                 rl: spectrum(resampled.rl),
                                 rr: spectrum(resampled.rr))

        // 直接音の窓が 1 周期も入らない低い所は設計しない（design-core.js:375-377）。
        let requestedWindowLow = directWindowLowFrequencyCycles * 1000 / config.directWindowMs
        let effectiveLowFrequency = max(config.lowFrequency, requestedWindowLow)
        let effectiveHighFrequency = min(config.highFrequency,
                                         Double(measurementRate) * 0.475,
                                         Double(config.sampleRate) * 0.475)
        let firstBin = max(
            1,
            Int((effectiveLowFrequency * Double(fftSize) / Double(config.sampleRate)).rounded(.up))
        )
        let lastBin = min(
            fftSize / 2,
            Int((effectiveHighFrequency * Double(fftSize) / Double(config.sampleRate)).rounded(.down))
        )

        var magnitudeSum = 0.0
        var magnitudeCount = 0
        if firstBin <= lastBin {
            for bin in firstBin...lastBin {
                magnitudeSum += hypot(unsmoothed.ll.real[bin], unsmoothed.ll.imag[bin])
                magnitudeSum += hypot(unsmoothed.rr.real[bin], unsmoothed.rr.imag[bin])
                magnitudeCount += 2
            }
        }
        guard magnitudeCount != 0, magnitudeSum > minimumMagnitude else {
            throw DesignError("empty-design-band", "The selected frequency range cannot be designed.")
        }
        let normalizationScale = Double(magnitudeCount) / magnitudeSum
        for slot in Slot.allCases {
            var value = unsmoothed[slot]
            for bin in 0..<value.real.count {
                value.real[bin] *= normalizationScale
                value.imag[bin] *= normalizationScale
            }
            unsmoothed[slot] = value
        }

        var spectra = unsmoothed
        for slot in Slot.allCases {
            spectra[slot] = try smoothDelayCompensatedSpectrum(unsmoothed[slot],
                                                               sampleRate: Double(config.sampleRate),
                                                               fftSize: fftSize,
                                                               delaySeconds: delays[slot])
        }

        return Plant(config: config,
                     spectra: spectra,
                     delays: delays,
                     fftSize: fftSize,
                     measurementSampleRate: measurementRate,
                     normalizationScale: normalizationScale,
                     effectiveLowFrequency: effectiveLowFrequency,
                     effectiveHighFrequency: effectiveHighFrequency,
                     lowFrequencyClamped: effectiveLowFrequency > config.lowFrequency)
    }

    // MARK: - 1 ビンを解く（design-core.js:434-473）

    struct CrosstalkSolution: Sendable {
        var c11: Cx
        var c21: Cx
        var c12: Cx
        var c22: Cx
    }

    /// C = (H^H H + beta I)^-1 H^H D を 1 ビンぶん。
    /// 行が耳、列がスピーカー: H = [[H_LL, H_RL], [H_LR, H_RR]]。
    static func solveRegularizedCrosstalkBin(hLL: Cx, hLR: Cx, hRL: Cx, hRR: Cx,
                                             targetLL: Cx, targetRR: Cx,
                                             beta: Double) -> CrosstalkSolution {
        let a11 = hLL.magnitudeSquared + hLR.magnitudeSquared + beta
        let a22 = hRL.magnitudeSquared + hRR.magnitudeSquared + beta
        let a12 = (hLL.conjugate * hRL) + (hLR.conjugate * hRR)
        let determinant = a11 * a22 - a12.magnitudeSquared
        let b11 = hLL.conjugate * targetLL
        let b21 = hRL.conjugate * targetLL
        let b12 = hLR.conjugate * targetRR
        let b22 = hRR.conjugate * targetRR
        let a21 = a12.conjugate
        let inverse = 1 / determinant
        return CrosstalkSolution(
            c11: (b11.scaled(a22) - (a12 * b21)).scaled(inverse),
            c21: (b21.scaled(a11) - (a21 * b11)).scaled(inverse),
            c12: (b12.scaled(a22) - (a12 * b22)).scaled(inverse),
            c22: (b22.scaled(a11) - (a21 * b12)).scaled(inverse)
        )
    }

    /// design-core.js:479-492。特異値の 2 乗を大きい順に 2 つ。
    private static func singularValuesSquared(_ hLL: Cx, _ hLR: Cx, _ hRL: Cx, _ hRR: Cx) -> [Double] {
        let trace = hLL.magnitudeSquared + hLR.magnitudeSquared
            + hRL.magnitudeSquared + hRR.magnitudeSquared
        let determinant = (hLL * hRR) - (hRL * hLR)
        let discriminant = max(0, trace * trace - 4 * determinant.magnitudeSquared)
        let root = discriminant.squareRoot()
        return [(trace + root) / 2, max(0, (trace - root) / 2)]
    }

    /// design-core.js:494-496。
    private static func maximumSingularValue(_ c11: Cx, _ c21: Cx, _ c12: Cx, _ c22: Cx) -> Double {
        singularValuesSquared(c11, c21, c12, c22)[0].squareRoot()
    }

    /// design-core.js:498-514。帯の外は 1 オクターブで持ち上げ余弦に落とす。
    private static func bandWeight(_ frequency: Double,
                                   _ lowFrequency: Double,
                                   _ highFrequency: Double) -> Double {
        if !(frequency > 0) { return 0 }
        let transitionScale = pow(2, bandTransitionOctaves)
        if frequency < lowFrequency / transitionScale || frequency > highFrequency * transitionScale {
            return 0
        }
        if frequency < lowFrequency {
            let fraction = log2(frequency / (lowFrequency / transitionScale)) / bandTransitionOctaves
            return 0.5 - 0.5 * cos(Double.pi * fraction)
        }
        if frequency > highFrequency {
            let fraction = log2(frequency / highFrequency) / bandTransitionOctaves
            return 0.5 + 0.5 * cos(Double.pi * fraction)
        }
        return 1
    }

    // MARK: - 4 本のスペクトルを作る（design-core.js:516-588）

    private struct DesignedSpectra {
        var output: [Spectrum]
        var maximumGain: Double
        var gainLimitedBins: Int
    }

    private static func designSpectra(_ plant: Plant) -> DesignedSpectra {
        let config = plant.config
        let spectra = plant.spectra
        let fftSize = plant.fftSize
        let length = fftSize / 2 + 1
        var output = (0..<4).map { _ in
            Spectrum(real: [Double](repeating: 0, count: length),
                     imag: [Double](repeating: 0, count: length))
        }
        let betaMid = pow(10, (-60 + 0.4 * config.regularization) / 10)
        let gainLimit = pow(10, config.maxGainDb / 20)
        var maximumGain = 0.0
        var gainLimitedBins = 0

        for bin in 0..<length {
            let frequency = Double(bin) * Double(config.sampleRate) / Double(fftSize)
            let hLL = Cx(spectra.ll.real[bin], spectra.ll.imag[bin])
            let hLR = Cx(spectra.lr.real[bin], spectra.lr.imag[bin])
            let hRL = Cx(spectra.rl.real[bin], spectra.rl.imag[bin])
            let hRR = Cx(spectra.rr.real[bin], spectra.rr.imag[bin])

            let delayPhase = -2 * Double.pi * frequency
                * Double(config.filterDelaySamples) / Double(config.sampleRate)
            let delayedUnit = Cx(cos(delayPhase), sin(delayPhase))
            let targetLL = hLL * delayedUnit
            let targetRR = hRR * delayedUnit

            let lowRatio = frequency > 0 ? plant.effectiveLowFrequency / frequency : Double.infinity
            let highRatio = plant.effectiveHighFrequency > 0
                ? frequency / plant.effectiveHighFrequency
                : 1
            let shape = min(100, max(1, lowRatio * lowRatio, highRatio * highRatio))
            let betaShape = betaMid * shape

            let targetMagnitude = max(hLL.magnitudeSquared.squareRoot(),
                                      hRR.magnitudeSquared.squareRoot())
            var betaBin = 0.0
            for sigmaSquared in singularValuesSquared(hLL, hLR, hRL, hRR) {
                let sigma = sigmaSquared.squareRoot()
                betaBin = max(betaBin, sigma * targetMagnitude / gainLimit - sigmaSquared)
            }
            betaBin = max(0, betaBin)
            if betaBin > betaShape { gainLimitedBins += 1 }

            let solution = solveRegularizedCrosstalkBin(hLL: hLL, hLR: hLR, hRL: hRL, hRR: hRR,
                                                        targetLL: targetLL, targetRR: targetRR,
                                                        beta: max(betaShape, betaBin))
            let weight = bandWeight(frequency,
                                    plant.effectiveLowFrequency,
                                    plant.effectiveHighFrequency)
            // 帯の外では素通し（遅延だけ）に寄せる。斜めは 0 に寄せる。
            let c11 = Cx(solution.c11.re * weight + delayedUnit.re * (1 - weight),
                         solution.c11.im * weight + delayedUnit.im * (1 - weight))
            let c21 = solution.c21.scaled(weight)
            let c12 = solution.c12.scaled(weight)
            let c22 = Cx(solution.c22.re * weight + delayedUnit.re * (1 - weight),
                         solution.c22.im * weight + delayedUnit.im * (1 - weight))

            let ordered = [c11, c21, c12, c22]
            for channel in 0..<ordered.count {
                output[channel].real[bin] = ordered[channel].re
                output[channel].imag[bin] = ordered[channel].im
            }
            maximumGain = max(maximumGain, maximumSingularValue(c11, c21, c12, c22))
        }

        for channel in 0..<output.count {
            output[channel].imag[0] = 0
            output[channel].imag[length - 1] = 0
        }
        return DesignedSpectra(output: output,
                               maximumGain: maximumGain,
                               gainLimitedBins: gainLimitedBins)
    }

    // MARK: - 端を落とす窓（design-core.js:590-597）

    private static func firEdgeWindow(_ index: Int, _ length: Int) -> Double {
        let edge = max(2, Int((Double(length) * firEdgeTaperFraction).rounded()))
        if index < edge {
            return 0.5 - 0.5 * cos(Double.pi * Double(index) / Double(edge))
        }
        if index >= length - edge {
            return 0.5 - 0.5 * cos(Double.pi * Double(length - 1 - index) / Double(edge))
        }
        return 1
    }

    // MARK: - 細かい道具

    /// design-core.js:33-36。有限でなければ fallback を使ってから挟む。
    fileprivate static func clamp(_ value: Double,
                                  _ minimum: Double,
                                  _ maximum: Double,
                                  _ fallback: Double) -> Double {
        max(minimum, min(maximum, value.isFinite ? value : fallback))
    }

    // MARK: - カーネルの口に合わせる

    /// params.json の latencyMode。値は添字で入っている
    /// （dsp-params.generated.js:222 が `["0","128",...].indexOf(...)` を packed[0] に入れる）。
    /// 並びが supportedHeadBlock（kernel.cpp:53-55）の受け付ける値とそのまま重なるので、
    /// 添字を引いたものを begin の headBlock に渡す。
    static let latencyModeHeadBlocks: [UInt32] = [0, 128, 256, 512, 1024]

    static func headBlock(forLatencyMode value: Float) -> UInt32 {
        guard value.isFinite, value >= 0, value < 16 else { return 128 }
        let index = Int(value.rounded())
        return latencyModeHeadBlocks.indices.contains(index) ? latencyModeHeadBlocks[index] : 128
    }
}

extension CrosstalkCancellationDesigner.SlotMap: Equatable where Value: Equatable {}

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
        guard dsp.chain.indices.contains(chainIndex) else {
            phase = .failed("This effect is no longer in the chain.")
            return
        }
        let node = dsp.chain[chainIndex]
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
        guard let index = dsp.chain.firstIndex(where: { $0.instance == instance }),
              let slot = paramOffset(named: "filterDelaySamples", in: dsp.chain[index].spec) else {
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
        guard let index = dsp.chain.firstIndex(where: { $0.instance == instance }) else { return }
        dsp.setRouting(at: index)
    }

    /// params.json の名前から packed float 配列での位置を引く。
    private func paramOffset(named name: String, in spec: ETEffect) -> Int? {
        spec.params.first { $0.name == name }?.offset
    }
}
