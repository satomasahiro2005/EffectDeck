//  FIRCrossoverDesign.swift
//  FIR Crossoverの設計の半分（Foundationだけ）。条件の正規化・帯の重み・FIRの設計・経路の並び、
//  それに画面側が持つ値（FIRCrossoverSettings）。
//
//  上流のVendor/effetune/js/fir-crossover/design-core.js（designFIRCrossover）と
//  plugins/basics/fir_crossover.jsの値の丸め方を移したもの。カーネルへ送り込む半分
//  （@MainActorのFIRCrossoverDesigner）はFIRCrossoverDesigner.swiftに残してある。
//  資産の並びとカーネルの条件はそちらの頭に書いてある。
//
//  ここはEffeTuneDSPにもet_*にも触らないので、Logicのテストへそのまま入れられる
//  （FIRCrossoverDesignTests。見本はTools/golden/designers_a_golden.mjsが上流に作らせる）。
//  使うのはFIRDesign（FFTと窓）とETAssetPath（IRPreparation.swift）だけ。

import Foundation

// MARK: - 位相

/// design-core.js:30 の phase。'lin' 以外は全部 'min' に倒れる。
enum FIRCrossoverPhase: String, Equatable, Sendable {
    case minimum = "min"
    case linear = "lin"
}

// MARK: - 正規化済みの設計条件

/// design-core.js:28-56 の normalizeConfig が返すもの。
struct FIRCrossoverConfig: Equatable, Sendable {
    /// 整数。カーネルはこれが engine の sampleRate と一致するかを見る（kernel.cpp:345）。
    let sampleRate: Int
    /// 8192 / 16384 / 32768 / 65536 / 131072 のどれか。
    let taps: Int
    let phase: FIRCrossoverPhase
    /// 2〜4。
    let bandCount: Int
    /// 3 個。使うのは先頭 bandCount-1 個だけ。
    let frequencies: [Double]
    /// 3 個。正の値（dB/oct）。画面が負で持っていても design-core.js:45 が絶対値を取る。
    let slopes: [Int]
}

/// design-core.js:207-210 の latencyInfo。
struct FIRCrossoverLatencyInfo: Equatable, Sendable {
    /// 最小位相なら 0、線形位相なら taps/2。params の filterDelaySamples と同じ値。
    let filterDelaySamples: Int
    /// 1 bin あたりの周波数。画面に出す用。
    let resolutionHz: Double
}

/// design-core.js:204-211 が返すもの。channels は channel-major（帯ごと）。
struct FIRCrossoverDesign: Sendable {
    let channels: [[Float]]
    let config: FIRCrossoverConfig
    let latencyInfo: FIRCrossoverLatencyInfo
}

// MARK: - 設計が失敗する形

enum FIRCrossoverDesignError: Error, LocalizedError {
    case fftUnavailable(size: Int)
    case badBandCount(Int)
    case tooLargeForSlot(footprintBytes: Int, capacityBytes: Int)

    var errorDescription: String? {
        switch self {
        case .fftUnavailable(let size):
            return "A \(size)-point transform is not available on this device."
        case .badBandCount(let count):
            return "A crossover needs 2 to 4 bands, not \(count)."
        case .tooLargeForSlot(let bytes, let capacity):
            return "The filters need \(bytes) bytes and the effect accepts \(capacity)."
        }
    }
}

// MARK: - 設計そのもの（design-core.js の移植）

/// 状態を持たない。重いので必ず音のスレッドの外で呼ぶこと。
enum FIRCrossoverDesignCore {

    /// design-core.js:3
    static let minimumMagnitude = 1e-8
    /// design-core.js:4。20*log10(2) ＝ 1 オクターブぶんの dB。
    static let octaveDecibels = 20 * log10(2.0)
    /// design-core.js:5
    static let allowedTaps: Set<Int> = [8192, 16384, 32768, 65536, 131072]
    /// design-core.js:6
    static let allowedSlopes: Set<Int> = [24, 48, 72, 96, 144, 192, 288, 384]

    // MARK: 条件を整える

    /// design-core.js:28-56 の normalizeConfig。
    ///
    /// 上限周波数に使う sampleRate は**丸めただけで、まだ 8000〜768000 に収めていない**もの。
    /// JS が maximumFrequency を先に作って、返す値だけを後から clamp しているため
    /// （design-core.js:31-33 と :49）。順番を入れ替えると値が変わるので、そのまま写した。
    static func normalize(sampleRate: Double,
                          taps: Int,
                          phase: FIRCrossoverPhase,
                          bandCount: Int,
                          frequencies: [Double],
                          slopes: [Int]) -> FIRCrossoverConfig {
        // Number(x) || 48000。JS では 0 と NaN が falsy なので 48000 に倒れる。
        // 無限大は falsy でないのでそのまま通り、上限周波数も無限大になる（返すレートは端に寄る）。
        let raw = (sampleRate.isNaN || sampleRate == 0) ? 48000 : sampleRate
        let roundedRate = jsRound(raw)
        let bands = max(2, min(4, Int(jsRound(Double(bandCount)))))
        let maximumFrequency = roundedRate * 0.48

        let fallbacks: [Double] = [2000, 4000, 8000]
        var resolved = (0..<3).map { index -> Double in
            let candidate = index < frequencies.count ? frequencies[index] : Double.nan
            let value = candidate.isFinite ? candidate : fallbacks[index]
            return max(10, min(maximumFrequency, value))
        }
        let activeCrossovers = bands - 1
        if activeCrossovers > 0 {
            for index in 0..<activeCrossovers {
                let minimum = index == 0 ? 10 : resolved[index - 1] + 1
                let maximum = maximumFrequency - Double(activeCrossovers - index - 1)
                resolved[index] = max(minimum, min(maximum, resolved[index]))
            }
        }

        let resolvedSlopes = (0..<3).map { index -> Int in
            let candidate = index < slopes.count ? Double(slopes[index]) : Double.nan
            guard candidate.isFinite else { return 24 }
            let value = Int(abs(jsRound(candidate)))
            return allowedSlopes.contains(value) ? value : 24
        }

        return FIRCrossoverConfig(
            sampleRate: Int(max(8000, min(768000, roundedRate))),
            taps: allowedTaps.contains(taps) ? taps : 32768,
            phase: phase,
            bandCount: bands,
            frequencies: resolved,
            slopes: resolvedSlopes
        )
    }

    // MARK: 帯の重み

    /// design-core.js:58-64 の crossoverLowWeight。
    /// 下側に残る割合。slope が急なほど切り替わりが速い。
    static func lowWeight(frequency: Double, cutoff: Double, slope: Double) -> Double {
        guard frequency > 0 else { return 1 }
        let exponent = slope / octaveDecibels * log(frequency / cutoff)
        if exponent <= -36 { return 1 }
        if exponent >= 36 { return 0 }
        return 1 / (1 + exp(exponent))
    }

    /// design-core.js:66-80 の crossoverBandMagnitudes。
    /// 上の帯へ残りを渡していくので、全部足すと必ず 1 になる。
    static func bandMagnitudes(_ config: FIRCrossoverConfig, frequency: Double) -> [Double] {
        var bands = [Double](repeating: 0, count: config.bandCount)
        var remainder = 1.0
        if config.bandCount > 1 {
            for crossover in 0..<(config.bandCount - 1) {
                let low = lowWeight(frequency: frequency,
                                    cutoff: config.frequencies[crossover],
                                    slope: Double(config.slopes[crossover]))
                bands[crossover] = remainder * low
                remainder *= 1 - low
            }
        }
        bands[config.bandCount - 1] = remainder
        return bands
    }

    // MARK: 設計

    /// design-core.js:140-215 の designFIRCrossover。
    ///
    /// JS は帯ごとのスペクトルを全部並べてから合成しているが、帯どうしは独立なので
    /// ここでは 1 帯ずつ作って捨てている。出てくる値は同じで、置き場だけ半分になる。
    /// 唯一の例外は線形位相の最後の帯で、これは他の帯が出そろってから作る。
    static func design(_ config: FIRCrossoverConfig) throws -> FIRCrossoverDesign {
        guard config.bandCount >= 2, config.bandCount <= 4 else {
            throw FIRCrossoverDesignError.badBandCount(config.bandCount)
        }
        let taps = config.taps
        let fftSize = taps * 2
        guard let fft = FIRDesign.fft(size: fftSize) else {
            throw FIRCrossoverDesignError.fftUnavailable(size: fftSize)
        }
        let half = fftSize / 2
        let binCount = half + 1

        // design-core.js:147-157。bin ごとに帯の重みを出す。
        var targetMagnitudes = [[Double]](
            repeating: [Double](repeating: 0, count: binCount),
            count: config.bandCount
        )
        let rate = Double(config.sampleRate)
        for bin in 0..<binCount {
            let frequency = Double(bin) * rate / Double(fftSize)
            let weights = bandMagnitudes(config, frequency: frequency)
            for band in 0..<config.bandCount {
                targetMagnitudes[band][bin] = weights[band]
            }
        }

        // design-core.js:159。窓は FIRDesign が持っている（同じ実装が JS に 2 か所ある）。
        let window = FIRDesign.createWindow(taps: taps, minimumPhase: config.phase == .minimum)

        var channels = [[Float]]()
        channels.reserveCapacity(config.bandCount)
        for band in 0..<config.bandCount {
            var real = [Double](repeating: 0, count: binCount)
            var imaginary = [Double](repeating: 0, count: binCount)

            if config.phase == .linear {
                // design-core.js:168-177。
                // taps/2 だけ遅らせる線形位相を、bin ごとに 4 通りへ畳んだもの。
                // 遅延 taps/2 ＝ fftSize/4 なので、位相は -π*bin/2 の繰り返しになる。
                for bin in 0..<binCount {
                    let magnitude = targetMagnitudes[band][bin]
                    switch bin & 3 {
                    case 0: real[bin] = magnitude
                    case 1: imaginary[bin] = -magnitude
                    case 2: real[bin] = -magnitude
                    default: imaginary[bin] = magnitude
                    }
                }
            } else {
                // design-core.js:179-188。
                let phase = minimumPhase(for: targetMagnitudes[band], fftSize: fftSize, fft: fft)
                for bin in 0..<binCount {
                    let magnitude = targetMagnitudes[band][bin]
                    real[bin] = magnitude * cos(phase[bin])
                    imaginary[bin] = magnitude * sin(phase[bin])
                }
            }

            channels.append(synthesize(real: real,
                                       imaginary: imaginary,
                                       taps: taps,
                                       window: window,
                                       fft: fft))
        }

        // design-core.js:192-202。
        // 線形位相のときだけ、最後の帯を「単位インパルス － 他の帯」で作り直す。
        // こうすると足し戻したときに必ず元へ戻る（他の帯の誤差ごと吸う）。
        let reconstructionDelay = config.phase == .minimum ? 0 : taps / 2
        if config.phase == .linear {
            let lastIndex = channels.count - 1
            var last = [Float](repeating: 0, count: taps)
            for index in 0..<taps {
                // JS は Float32Array を読みながら double で引いている。同じ順で写す。
                var value = index == reconstructionDelay ? 1.0 : 0.0
                for band in 0..<lastIndex {
                    value -= Double(channels[band][index])
                }
                last[index] = Float(value)
            }
            channels[lastIndex] = last
        }

        return FIRCrossoverDesign(
            channels: channels,
            config: config,
            latencyInfo: FIRCrossoverLatencyInfo(
                filterDelaySamples: config.phase == .minimum ? 0 : taps / 2,
                resolutionHz: rate / Double(taps)
            )
        )
    }

    /// design-core.js:82-95 の minimumPhaseForMagnitude。
    /// 振幅の対数の実ケプストラムを因果側へ折り返して、位相を取り出す（Hilbert 変換）。
    ///
    /// 折り返しで index == fftSize/2 だけは 2 倍にも 0 にもしていない。
    /// JS の 2 本のループがどちらもその添字を外しているため（:92 と :93）。
    private static func minimumPhase(for magnitudes: [Double],
                                     fftSize: Int,
                                     fft: FIRDesign.RealFFT) -> [Double] {
        var logMagnitude = [Double](repeating: 0, count: magnitudes.count)
        for bin in 0..<magnitudes.count {
            logMagnitude[bin] = log(max(minimumMagnitude, magnitudes[bin]))
        }
        var cepstrum = fft.inverseRealTransform(
            real: logMagnitude,
            imag: [Double](repeating: 0, count: logMagnitude.count)
        )
        let half = fftSize / 2
        if half > 1 {
            for index in 1..<half { cepstrum[index] *= 2 }
        }
        if half + 1 < fftSize {
            for index in (half + 1)..<fftSize { cepstrum[index] = 0 }
        }
        return fft.realTransform(cepstrum).imag
    }

    /// design-core.js:117-126 の synthesizeSpectrum。
    /// 逆変換して頭から taps 個を取り、窓を掛けて Float にする。
    private static func synthesize(real: [Double],
                                   imaginary: [Double],
                                   taps: Int,
                                   window: [Double],
                                   fft: FIRDesign.RealFFT) -> [Float] {
        var imag = imaginary
        if !imag.isEmpty {
            imag[0] = 0
            imag[imag.count - 1] = 0
        }
        let time = fft.inverseRealTransform(real: real, imag: imag)
        var output = [Float](repeating: 0, count: taps)
        let count = min(taps, min(time.count, window.count))
        for index in 0..<count {
            output[index] = Float(time[index] * window[index])
        }
        return output
    }

    // MARK: 送り込む形

    /// 経路の並び。design-worker.js:24-27。
    /// kernel.cpp:355-364 が並びまで見ているので、この順以外は commit で弾かれる。
    static func paths(bandCount: Int) -> [ETAssetPath] {
        var paths = [ETAssetPath]()
        paths.reserveCapacity(bandCount * 2)
        for band in 0..<bandCount {
            paths.append(ETAssetPath(inputSlot: 0,
                                     outputSlot: UInt32(band * 2),
                                     irChannel: UInt32(band)))
            paths.append(ETAssetPath(inputSlot: 1,
                                     outputSlot: UInt32(band * 2 + 1),
                                     irChannel: UInt32(band)))
        }
        return paths
    }

    /// fir_crossover.js:349-366 の _updatePowerGainBound。
    /// 係数の絶対値の和（＝入力 1 に対して出得る最大）を dB で。1 を下回らせない。
    static func powerGainUpperBoundDecibels(_ channels: [[Float]]) -> Double {
        var maximum = 1.0
        for channel in channels {
            var sum = 0.0
            for value in channel { sum += Double(value < 0 ? -value : value) }
            if sum > maximum { maximum = sum }
        }
        return 20 * log10(maximum)
    }

    // MARK: 細かい道具

    /// JS の Math.round。floor(x + 0.5) で、半分は常に上へ行く。
    /// Swift の rounded() は 0 から遠い側へ丸めるので、負の値で食い違う。
    static func jsRound(_ value: Double) -> Double {
        guard value.isFinite else { return value }
        return (value + 0.5).rounded(.down)
    }
}

// MARK: - 画面側が持つ値（plugins/basics/fir_crossover.js の移植）

/// params.json に載っているのは latencyMode / filterDelaySamples / bandCount の 3 つだけで、
/// 周波数・傾き・位相・taps はカーネルへ行かない（係数の中に溶けている）。
/// だから JS も画面側の状態として持っている。ここも同じにした。
/// 既定値は fir_crossover.js:8-18。
struct FIRCrossoverSettings: Equatable, Sendable {

    /// latencyMode の選択肢。params.json:9 と同じ並び。float で渡すのは**この添字**。
    static let latencyModeValues = [0, 128, 256, 512, 1024]
    /// 画面に出す taps の選択肢。fir_crossover.js:141。
    static let tapChoices = [8192, 16384, 32768, 65536, 131072]
    /// 画面に出す傾きの選択肢。fir_crossover.js:4（負の値で持っている）。
    static let slopeChoices = [-24, -48, -72, -96, -144, -192, -288, -384]

    var bandCount: Int = 2
    var frequencies: [Double] = [2000, 4000, 8000]
    /// 負で持つ。design-core が絶対値を取る。
    var slopes: [Int] = [-24, -24, -24]
    var phase: FIRCrossoverPhase = .minimum
    var taps: Int = 32768
    /// latencyModeValues の添字。既定は 1（＝128）。EffectCatalog の defaultValue と同じ。
    var latencyModeIndex: Int = 1

    /// begin へ渡す頭ブロック。添字ではなく値のほう（fir_crossover.js:303 の Number(this.lt)）。
    var headBlock: UInt32 {
        let index = min(max(latencyModeIndex, 0), Self.latencyModeValues.count - 1)
        return UInt32(Self.latencyModeValues[index])
    }

    /// 画面から来た値を丸める。fir_crossover.js:133-159 と同じ順で行う。
    /// 周波数の上限がここでは 40000 で、sampleRate に対する上限は
    /// design-core 側（sampleRate*0.48）が別に掛ける。JS も二段になっている。
    mutating func clamp() {
        bandCount = max(2, min(4, bandCount))
        if !Self.tapChoices.contains(taps) { taps = 32768 }
        latencyModeIndex = min(max(latencyModeIndex, 0), Self.latencyModeValues.count - 1)

        let fallbacks: [Double] = [2000, 4000, 8000]
        var resolved = (0..<3).map { index -> Double in
            let candidate = index < frequencies.count ? frequencies[index] : Double.nan
            guard candidate.isFinite else { return fallbacks[index] }
            return min(max(candidate, 10), 40000)
        }
        let activeCrossovers = bandCount - 1
        if activeCrossovers > 0 {
            for index in 0..<activeCrossovers {
                let minimum = index == 0 ? 10 : resolved[index - 1] + 1
                let maximum = 40000 - Double(activeCrossovers - index - 1)
                resolved[index] = max(minimum, min(maximum, resolved[index]))
            }
        }
        frequencies = resolved

        let previousSlopes = slopes
        slopes = (0..<3).map { index -> Int in
            let candidate = index < previousSlopes.count ? previousSlopes[index] : -24
            return Self.slopeChoices.contains(candidate) ? candidate : -24
        }
    }

    /// fir_crossover.js:76-78 の _maximumBandCount。
    /// 帯ごとにステレオ 1 対を吐くので、出口が偶数で 4 以上ないと成り立たない。
    static func maximumBandCount(processingChannels: Int) -> Int {
        guard processingChannels >= 4, processingChannels <= 16,
              processingChannels % 2 == 0 else { return 0 }
        return min(processingChannels / 2, 4)
    }

    /// fir_crossover.js:80-83 の _effectiveBandCount。0 なら成り立たない。
    func effectiveBandCount(processingChannels: Int) -> Int {
        let maximum = Self.maximumBandCount(processingChannels: processingChannels)
        return maximum == 0 ? 0 : min(bandCount, maximum)
    }

    /// fir_crossover.js:187-199 の _designConfig を通して正規化したもの。
    /// 出口の幅が足りないときは nil。
    func config(sampleRate: Double, processingChannels: Int) -> FIRCrossoverConfig? {
        let bands = effectiveBandCount(processingChannels: processingChannels)
        guard bands > 0 else { return nil }
        return FIRCrossoverDesignCore.normalize(sampleRate: sampleRate,
                                                taps: taps,
                                                phase: phase,
                                                bandCount: bands,
                                                frequencies: frequencies,
                                                slopes: slopes)
    }
}
