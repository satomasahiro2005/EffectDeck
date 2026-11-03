//  BandFIRPEQDesign.swift
//  5Band FIR PEQの設計の半分（Foundationだけ）。帯域の設定・正規化・RBJの係数・FIRの設計。
//
//  上流のVendor/effetune/js/five-band-fir-peq/design-core.js（designFiveBandFirPeq）を
//  Swiftへ移したもの。カーネルへ送り込む半分（@MainActorのBandFIRPEQDesigner）は
//  BandFIRPEQDesigner.swiftに残してある。資産の並びとカーネルの条件はそちらの頭に書いてある。
//
//  ここはEffeTuneDSPにもet_*にも触らないので、Logicのテストへそのまま入れられる
//  （BandFIRPEQDesignTests。見本はTools/golden/designers_a_golden.mjsが上流に作らせる）。
//  使う道具はFIRDesign（FFTと窓）だけ。

import Foundation

// MARK: - 帯域の設定

/// 帯域の種類。文字列は EffeTune の保存形式と同じ（design-core.js:6 の ALLOWED_TYPES）。
enum BandFIRPEQFilterType: String, CaseIterable, Codable, Sendable {
    case peaking = "pk"
    case lowPass = "lp"
    case highPass = "hp"
    case lowShelf = "ls"
    case highShelf = "hs"
    case bandPass = "bp"
    case notch = "no"

    /// 画面に出す名前。plugins/eq/five_band_fir_peq.js:10-18 の FILTER_TYPES と同じ綴り。
    var displayName: String {
        switch self {
        case .peaking:   return "Peaking"
        case .lowPass:   return "LowPass"
        case .highPass:  return "HighPass"
        case .lowShelf:  return "LowShelv"
        case .highShelf: return "HighShel"
        case .bandPass:  return "BandPass"
        case .notch:     return "Notch"
        }
    }

    /// slope が効くのは lp と hp だけ（design-core.js:7 の SLOPE_TYPES）。
    var usesSlope: Bool { self == .lowPass || self == .highPass }

    /// gain が 0 でも応答を変える種類。design-core.js:337 の絞り込みと同じ。
    var changesResponseWithoutGain: Bool {
        switch self {
        case .lowPass, .highPass, .bandPass, .notch: return true
        case .peaking, .lowShelf, .highShelf:        return false
        }
    }
}

/// 位相の作り方。design-core.js:70（'lin' 以外は 'min'）。
enum BandFIRPEQPhase: String, CaseIterable, Codable, Sendable {
    case minimum = "min"
    case linear = "lin"

    var displayName: String {
        switch self {
        case .minimum: return "Minimum Phase"
        case .linear:  return "Linear Phase"
        }
    }
}

/// FIR の長さ。design-core.js:5 の ALLOWED_TAPS。
enum BandFIRPEQTaps: Int, CaseIterable, Codable, Sendable {
    case taps8192 = 8192
    case taps16384 = 16384
    case taps32768 = 32768
    case taps65536 = 65536
    case taps131072 = 131072

    var displayName: String { "\(rawValue) taps" }
}

/// 頭ブロックの大きさ。カーネルが受け取るのはこの 5 つだけ（kernel.cpp:270-271）。
/// 0 は「遅延を足さない」で、畳み込み器は 128 の頭ブロックを使う。
enum BandFIRPEQLatency: Int, CaseIterable, Codable, Sendable {
    case zero = 0
    case block128 = 128
    case block256 = 256
    case block512 = 512
    case block1024 = 1024

    var displayName: String { rawValue == 0 ? "0 (no added latency)" : "\(rawValue) samples" }

    /// packed params に入るのは値そのものではなく **並びの添字**。
    /// dsp-params.generated.js:574 が ["0","128","256","512","1024"].indexOf(lt) を書いている。
    var parameterIndex: Float {
        switch self {
        case .zero:     return 0
        case .block128: return 1
        case .block256: return 2
        case .block512: return 3
        case .block1024: return 4
        }
    }
}

/// 1 本の帯域。
struct BandFIRPEQBand: Equatable, Codable, Sendable {
    var enabled: Bool = true
    var type: BandFIRPEQFilterType = .peaking
    var frequency: Double
    var gain: Double = 0
    var q: Double = 0.7
    var slope: Double = 12
}

/// 5Band FIR PEQ の設定ひとまとめ。
/// 既定値は plugins/eq/five_band_fir_peq.js:41-80 のコンストラクタから写した。
struct BandFIRPEQSettings: Equatable, Codable, Sendable {
    var bands: [BandFIRPEQBand]
    var taps: BandFIRPEQTaps = .taps32768
    var phase: BandFIRPEQPhase = .minimum
    var latency: BandFIRPEQLatency = .block128

    static let bandCount = 5

    /// 既定の中心周波数。design-core.js:8 の DEFAULT_FREQUENCIES と
    /// five_band_fir_peq.js:2-8 の BANDS は同じ並び。
    static let defaultFrequencies: [Double] = [100, 316, 1000, 3160, 10000]

    static let `default` = BandFIRPEQSettings(
        bands: defaultFrequencies.map { BandFIRPEQBand(frequency: $0) }
    )
}

// MARK: - 正規化した設計の引数

/// design-core.js:41-73 の normalizeConfig を通した後の形。
/// 設計はこれだけで決まるので、そのままキャッシュの鍵にしている。
struct BandFIRPEQConfig: Equatable, Sendable {
    let sampleRate: Int
    let taps: Int
    let phase: BandFIRPEQPhase
    let bands: [BandFIRPEQBand]

    init(settings: BandFIRPEQSettings, sampleRate: Double) {
        // JS は Math.round(Number(x) || 48000) を [8000, 768000] に丸める。
        // Number(x) || 48000 なので 0 と NaN は 48000 に落ちる。
        // 丸めと切り詰めの順を入れ替えてあるのは、1e300 のような値で
        // Int(_:) が落ちるのを避けるため。有限の入力なら結果は同じ。
        // 無限大は falsy でないので既定へ倒さない（+∞は768000、-∞は8000に寄る）。
        let requested = (sampleRate.isNaN || sampleRate == 0) ? 48000 : sampleRate
        let rounded = requested.rounded(.toNearestOrAwayFromZero)
        let bounded = rounded < 8000 ? 8000 : (rounded > 768000 ? 768000 : rounded)
        let rate = Int(bounded)
        self.sampleRate = rate
        self.taps = settings.taps.rawValue
        self.phase = settings.phase

        // 中心周波数の上限は Nyquist の 0.49 倍か 20kHz の低いほう（design-core.js:48-49）。
        let nyquistLimit = Double(rate) * 0.49
        let maximumFrequency = nyquistLimit < 20000 ? nyquistLimit : 20000
        var normalized = [BandFIRPEQBand]()
        normalized.reserveCapacity(BandFIRPEQSettings.bandCount)
        for index in 0..<BandFIRPEQSettings.bandCount {
            let fallbackFrequency = BandFIRPEQSettings.defaultFrequencies[index]
            let band = index < settings.bands.count
                ? settings.bands[index]
                : BandFIRPEQBand(frequency: fallbackFrequency)
            normalized.append(BandFIRPEQBand(
                enabled: band.enabled,
                type: band.type,
                frequency: BandFIRPEQCore.finiteNumber(
                    band.frequency, 20, maximumFrequency,
                    fallbackFrequency < maximumFrequency ? fallbackFrequency : maximumFrequency
                ),
                gain: BandFIRPEQCore.finiteNumber(band.gain, -20, 20, 0),
                q: BandFIRPEQCore.finiteNumber(band.q, 0.1, 100, 0.7),
                slope: BandFIRPEQCore.finiteNumber(band.slope, 0.1, 384, 12)
            ))
        }
        self.bands = normalized
    }
}

// MARK: - 出来上がったもの

struct BandFIRPEQDesign: Sendable {
    /// 画面に出す応答の曲線。design-core.js:304-307 の response と同じ 3 本。
    struct Response: Sendable {
        let frequencies: [Double]
        let targetDb: [Double]
        let realizedDb: [Double]
    }

    let config: BandFIRPEQConfig
    /// カーネルへ渡す係数。mono なので 1 本だけ。
    let channels: [[Float]]
    /// fd パラメータに入れる値。最小位相は 0、線形位相は taps/2（design-core.js:388）。
    let filterDelaySamples: Int
    /// 1 bin あたりの周波数（design-core.js:389）。画面の注記用。
    let resolutionHz: Double
    /// 狙いと出来上がりのずれの最大値（design-core.js:267-280）。
    let maximumErrorDb: Double
    let response: Response

    /// design-core.js:386 と同じ境目。
    var hasAccuracyWarning: Bool { maximumErrorDb > 0.5 }
}

enum BandFIRPEQDesignError: Error, LocalizedError {
    case fftUnavailable(size: Int)
    case instanceMissing
    case channelsUnavailable
    case kernelRefused(reason: UInt32)

    var errorDescription: String? {
        switch self {
        case .fftUnavailable(let size):
            return "A \(size)-point transform is not available on this device."
        case .instanceMissing:
            return "The equalizer is not running."
        case .channelsUnavailable:
            return "The selected audio channels are not available."
        case .kernelRefused(let reason):
            // 理由の値は kernel.cpp:203 / 218 / 227。
            switch reason {
            case 1:  return "The effect rejected the filter data."
            case 2:  return "There was not enough memory for this filter. Try fewer taps."
            case 3:  return "The convolution engine could not take the filter."
            default: return "The effect could not take the filter."
            }
        }
    }
}

// MARK: - 設計そのもの

/// design-core.js の移植。音のスレッドから呼んではいけない。
/// どこにも隔離していないので、Task.detached の中から呼べる。
enum BandFIRPEQCore {

    // design-core.js:3-12 の定数をそのまま写した。
    static let minimumMagnitude = 1e-8
    static let verificationFloor = 1e-4
    static let responseLowFrequency = 10.0
    static let responseHighFrequency = 40000.0
    static let responsePoints = 512

    // MARK: 数の丸め

    /// design-core.js:34-39 の finiteNumber。fallback は clamp しないのが元の挙動。
    static func finiteNumber(_ value: Double,
                             _ minimum: Double,
                             _ maximum: Double,
                             _ fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        if value < minimum { return minimum }
        return value > maximum ? maximum : value
    }

    // MARK: 双二次の係数

    /// a0 で割った後の biquad。design-core.js:144-151 の戻り値と同じ形。
    struct Coefficients: Sendable {
        var b0: Double
        var b1: Double
        var b2: Double
        var a1: Double
        var a2: Double
    }

    /// RBJ のクックブック。design-core.js:75-152 の rbjCoefficients。
    static func rbjCoefficients(_ band: BandFIRPEQBand, _ sampleRate: Double) -> Coefficients {
        let maximumCenter = sampleRate * 0.49
        let center = band.frequency < maximumCenter ? band.frequency : maximumCenter
        let omega = 2 * Double.pi * center / sampleRate
        let cosine = cos(omega)
        let sine = sin(omega)
        let amplitude = pow(10, band.gain / 40)
        let alpha = sine / (2 * band.q)
        let root = amplitude.squareRoot()

        let b0: Double
        let b1: Double
        let b2: Double
        let a0: Double
        let a1: Double
        let a2: Double

        switch band.type {
        case .lowPass:
            b0 = (1 - cosine) / 2
            b1 = 1 - cosine
            b2 = (1 - cosine) / 2
            a0 = 1 + alpha
            a1 = -2 * cosine
            a2 = 1 - alpha
        case .highPass:
            b0 = (1 + cosine) / 2
            b1 = -(1 + cosine)
            b2 = (1 + cosine) / 2
            a0 = 1 + alpha
            a1 = -2 * cosine
            a2 = 1 - alpha
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
        case .bandPass:
            b0 = alpha
            b1 = 0
            b2 = -alpha
            a0 = 1 + alpha
            a1 = -2 * cosine
            a2 = 1 - alpha
        case .notch:
            b0 = 1
            b1 = -2 * cosine
            b2 = 1
            a0 = 1 + alpha
            a1 = -2 * cosine
            a2 = 1 - alpha
        case .peaking:
            b0 = 1 + alpha * amplitude
            b1 = -2 * cosine
            b2 = 1 - alpha * amplitude
            a0 = 1 + alpha / amplitude
            a1 = -2 * cosine
            a2 = 1 - alpha / amplitude
        }

        let inverseA0 = 1 / a0
        return Coefficients(b0: b0 * inverseA0,
                            b1: b1 * inverseA0,
                            b2: b2 * inverseA0,
                            a1: a1 * inverseA0,
                            a2: a2 * inverseA0)
    }

    /// その周波数での振幅。design-core.js:154-172 の coefficientMagnitude。
    static func coefficientMagnitude(_ coefficients: Coefficients,
                                     _ frequency: Double,
                                     _ sampleRate: Double) -> Double {
        let omega = 2 * Double.pi * frequency / sampleRate
        let cosine = cos(omega)
        let sine = sin(omega)
        let doubleCosine = cos(2 * omega)
        let doubleSine = sin(2 * omega)
        let numeratorReal = coefficients.b0 + coefficients.b1 * cosine + coefficients.b2 * doubleCosine
        let numeratorImaginary = -coefficients.b1 * sine - coefficients.b2 * doubleSine
        let denominatorReal = 1 + coefficients.a1 * cosine + coefficients.a2 * doubleCosine
        let denominatorImaginary = -coefficients.a1 * sine - coefficients.a2 * doubleSine
        let numerator = hypot(numeratorReal, numeratorImaginary)
        let denominator = hypot(denominatorReal, denominatorImaginary)
        return (numerator > minimumMagnitude ? numerator : minimumMagnitude)
            / (denominator > minimumMagnitude ? denominator : minimumMagnitude)
    }

    /// 帯域 1 本の応答。画面の曲線を引くのに使う。
    /// design-core.js:174-196 の fiveBandFirPeqMagnitude と同じ。
    static func magnitude(of band: BandFIRPEQBand,
                          at frequency: Double,
                          sampleRate: Double) -> Double {
        let value = coefficientMagnitude(rbjCoefficients(band, sampleRate), frequency, sampleRate)
        guard band.type.usesSlope, value < 1 else { return value }
        return pow(value, finiteNumber(band.slope, 0.1, 384, 12) / 12)
    }

    // MARK: 設計

    private struct ActiveBand {
        let coefficients: Coefficients
        let exponent: Double
    }

    /// design-core.js:327-397 の designFiveBandFirPeq。
    static func design(_ config: BandFIRPEQConfig) throws -> BandFIRPEQDesign {
        if let cached = cache.value(for: config) { return cached }

        let taps = config.taps
        let fftSize = taps * 2
        guard let fft = FIRDesign.fft(size: fftSize) else {
            throw BandFIRPEQDesignError.fftUnavailable(size: fftSize)
        }
        let sampleRate = Double(config.sampleRate)
        let binCount = fftSize / 2 + 1

        // 狙いの振幅。効かない帯域はここで落とす（design-core.js:335-341）。
        let activeBands: [ActiveBand] = config.bands.compactMap { band in
            guard band.enabled else { return nil }
            guard band.type.changesResponseWithoutGain || band.gain != 0 else { return nil }
            return ActiveBand(coefficients: rbjCoefficients(band, sampleRate),
                              exponent: band.type.usesSlope ? band.slope / 12 : 1)
        }
        var magnitudes = [Double](repeating: 1, count: binCount)
        for bin in 0..<binCount {
            let frequency = Double(bin) * sampleRate / Double(fftSize)
            var magnitude = 1.0
            for band in activeBands {
                let bandMagnitude = coefficientMagnitude(band.coefficients, frequency, sampleRate)
                magnitude *= band.exponent != 1 && bandMagnitude < 1
                    ? pow(bandMagnitude, band.exponent)
                    : bandMagnitude
            }
            magnitudes[bin] = magnitude > minimumMagnitude ? magnitude : minimumMagnitude
        }

        // 位相を付ける（design-core.js:358-376）。
        var real = [Double](repeating: 0, count: binCount)
        var imaginary = [Double](repeating: 0, count: binCount)
        switch config.phase {
        case .linear:
            // bin ごとに 4 つの向きを回す。これは fftSize/4 = taps/2 サンプルの遅れ。
            for bin in 0..<binCount {
                let magnitude = magnitudes[bin]
                switch bin & 3 {
                case 0:  real[bin] = magnitude
                case 1:  imaginary[bin] = -magnitude
                case 2:  real[bin] = -magnitude
                default: imaginary[bin] = magnitude
                }
            }
        case .minimum:
            let phase = minimumPhase(for: magnitudes, fftSize: fftSize, fft: fft)
            for bin in 0..<binCount {
                real[bin] = magnitudes[bin] * cos(phase[bin])
                imaginary[bin] = magnitudes[bin] * sin(phase[bin])
            }
        }
        imaginary[0] = 0
        imaginary[binCount - 1] = 0

        // 時間へ戻して端を落とす（design-core.js:377-382）。
        let time = fft.inverseRealTransform(real: real, imag: imaginary)
        let window = FIRDesign.createWindow(taps: taps, minimumPhase: config.phase == .minimum)
        var coefficients = [Float](repeating: 0, count: taps)
        for index in 0..<taps {
            // JS も Float32Array へ落としてから測っているので、丸めの位置を合わせる。
            coefficients[index] = Float(time[index] * window[index])
        }

        let measured = measureMagnitudeResponse(coefficients: coefficients,
                                                intended: magnitudes,
                                                config: config,
                                                fft: fft)
        let design = BandFIRPEQDesign(
            config: config,
            channels: [coefficients],
            filterDelaySamples: config.phase == .minimum ? 0 : taps / 2,
            resolutionHz: sampleRate / Double(taps),
            maximumErrorDb: measured.maximumErrorDb,
            response: measured.response
        )
        cache.store(design, for: config)
        return design
    }

    /// design-core.js:198-214 の minimumPhaseForMagnitude。
    /// 実ケプストラムを折り返して、その FFT の虚部を位相として使う。
    private static func minimumPhase(for magnitudes: [Double],
                                     fftSize: Int,
                                     fft: FIRDesign.RealFFT) -> [Double] {
        var logMagnitude = [Double](repeating: 0, count: magnitudes.count)
        for bin in 0..<magnitudes.count {
            let magnitude = magnitudes[bin]
            logMagnitude[bin] = log(magnitude > minimumMagnitude ? magnitude : minimumMagnitude)
        }
        var cepstrum = fft.inverseRealTransform(
            real: logMagnitude,
            imag: [Double](repeating: 0, count: logMagnitude.count)
        )
        // 前半を 2 倍、後半を 0 に。真ん中（fftSize/2）はそのまま。
        var index = 1
        while index < fftSize / 2 {
            cepstrum[index] *= 2
            index += 1
        }
        index = fftSize / 2 + 1
        while index < fftSize {
            cepstrum[index] = 0
            index += 1
        }
        return fft.realTransform(cepstrum).imag
    }

    /// design-core.js:257-308 の measureMagnitudeResponse。
    private static func measureMagnitudeResponse(
        coefficients: [Float],
        intended: [Double],
        config: BandFIRPEQConfig,
        fft: FIRDesign.RealFFT
    ) -> (maximumErrorDb: Double, response: BandFIRPEQDesign.Response) {
        let sampleRate = Double(config.sampleRate)
        let length = config.taps * 2
        var input = [Double](repeating: 0, count: length)
        let copyCount = min(coefficients.count, length)
        for index in 0..<copyCount { input[index] = Double(coefficients[index]) }

        let spectrum = fft.realTransform(input)
        var realizedMagnitudes = [Double](repeating: 0, count: spectrum.real.count)
        let maximumVerificationFrequency = sampleRate * 0.45
        let highFrequency = maximumVerificationFrequency < 20000
            ? maximumVerificationFrequency
            : 20000
        var maximumErrorDb = 0.0
        for bin in 0..<spectrum.real.count {
            let measured = hypot(spectrum.real[bin], spectrum.imag[bin])
            realizedMagnitudes[bin] = measured
            if bin == 0 { continue }
            let frequency = Double(bin) * sampleRate / Double(length)
            if frequency < 20 || frequency > highFrequency { continue }
            let actual = measured > verificationFloor ? measured : verificationFloor
            let intendedMagnitude = bin < intended.count ? intended[bin] : 0
            let target = intendedMagnitude > verificationFloor ? intendedMagnitude : verificationFloor
            let error = abs(20 * log10(actual / target))
            if error > maximumErrorDb { maximumErrorDb = error }
        }

        // design-core.js:237-247 の responseFrequencies と同じ並び。
        let highest = sampleRate * 0.5 < responseHighFrequency
            ? sampleRate * 0.5
            : responseHighFrequency
        let frequencies = FIRDesign.logFrequencies(low: responseLowFrequency,
                                                   high: highest,
                                                   count: responsePoints)
        var targetDb = [Double](repeating: 0, count: frequencies.count)
        var realizedDb = [Double](repeating: 0, count: frequencies.count)
        for point in 0..<frequencies.count {
            let frequency = frequencies[point]
            let target = sampleAtFrequency(intended, frequency, length, sampleRate)
            let realized = sampleAtFrequency(realizedMagnitudes, frequency, length, sampleRate)
            targetDb[point] = 20 * log10(target > minimumMagnitude ? target : minimumMagnitude)
            realizedDb[point] = 20 * log10(realized > minimumMagnitude ? realized : minimumMagnitude)
        }
        return (maximumErrorDb,
                BandFIRPEQDesign.Response(frequencies: frequencies,
                                          targetDb: targetDb,
                                          realizedDb: realizedDb))
    }

    /// design-core.js:249-255 の sampleAtFrequency。bin のあいだは直線で結ぶ。
    private static func sampleAtFrequency(_ values: [Double],
                                          _ frequency: Double,
                                          _ fftSize: Int,
                                          _ sampleRate: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let position = frequency * Double(fftSize) / sampleRate
        let lower = Int(position.rounded(.down))
        let upper = lower + 1
        if upper >= values.count { return values[values.count - 1] }
        if lower < 0 { return values[0] }
        return values[lower] + (values[upper] - values[lower]) * (position - Double(lower))
    }

    // MARK: 作り直さないための控え

    /// design-core.js:12 の designCache と同じ役目。JS も 2 つまでしか持たない（:394-395）。
    private final class DesignCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries = [(config: BandFIRPEQConfig, design: BandFIRPEQDesign)]()

        func value(for config: BandFIRPEQConfig) -> BandFIRPEQDesign? {
            lock.lock()
            defer { lock.unlock() }
            return entries.first { $0.config == config }?.design
        }

        func store(_ design: BandFIRPEQDesign, for config: BandFIRPEQConfig) {
            lock.lock()
            defer { lock.unlock() }
            entries.removeAll { $0.config == config }
            entries.append((config, design))
            if entries.count > 2 { entries.removeFirst(entries.count - 2) }
        }
    }

    private static let cache = DesignCache()
}
