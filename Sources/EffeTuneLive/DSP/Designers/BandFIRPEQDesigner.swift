//  BandFIRPEQDesigner.swift
//  5Band FIR PEQ の係数を作って instance へ送り込む。
//
//  カーネル（Vendor/effetune/dsp/plugins/eq/five_band_fir_peq/kernel.cpp）が持っている
//  パラメータは 2 つだけで（params.json:8-11）、5 本の帯域の設定はどこにも無い。
//  帯域から FIR 係数を設計するのは JS 側の仕事で、その場所が
//  Vendor/effetune/js/five-band-fir-peq/design-core.js:327-397（designFiveBandFirPeq）。
//  ここはその設計を Swift へ移したもの。DSP 本体には一切触っていない。
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
//  et_pipeline_configure に遅延補正を組み直させる（AssetUpload.swift:64-68 の但し書き）。
//  JS も同じ場所で refreshDspPipelineForLatencyChange を呼んでいる。

import Combine
import Foundation
import os

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
        let requested = (sampleRate.isFinite && sampleRate != 0) ? sampleRate : 48000
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
    /// 中身は AssetUpload.swift:576-621 の但し書きのとおり。
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

    /// 資産を外して素通しに戻す。
    func removeAsset() {
        pending?.cancel()
        pending = nil
        generation &+= 1
        AssetUpload.clear(engine: EffeTuneDSP.shared.engine, instance: instance)
        latestDesign = nil
        status = .idle
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
        guard let index = dsp.chain.firstIndex(where: { $0.instance == instance }) else {
            pushKernelParametersDirectly(filterDelaySamples: filterDelaySamples)
            return
        }
        let spec = dsp.chain[index].spec
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

    /// 遅延が変わったことを et_pipeline_configure に教える。
    /// EffeTuneDSP.publish() と同じ並びを作り直しているだけで、鎖は変えていない。
    private func republishForLatencyChange() {
        let nodes = EffeTuneDSP.shared.chain.filter { $0.instance != 0 }.map { node in
            ETPipeNode(instance: node.instance,
                       enabled: node.enabled ? 1 : 0,
                       inputBus: node.inputBus,
                       outputBus: node.outputBus,
                       channelSpec: node.channelSpec,
                       sectionGate: node.sectionGate,
                       kind: UInt8(ET_PIPE_NODE_NATIVE),
                       externalIndex: 0)
        }
        nodes.withUnsafeBufferPointer { ETPipeline_Publish($0.baseAddress, UInt32($0.count)) }
    }

    // MARK: チャンネル

    private func processingChannels() -> Int {
        let spec = EffeTuneDSP.shared.chain.first { $0.instance == instance }?.channelSpec ?? -1
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
