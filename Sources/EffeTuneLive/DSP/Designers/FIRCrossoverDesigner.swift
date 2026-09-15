//  FIRCrossoverDesigner.swift
//  FIR Crossover の係数を作って、instance へ送り込む。
//
//  カーネル（dsp/plugins/basics/fir_crossover/kernel.cpp）は出来上がった FIR を
//  受け取るだけで、係数の設計は JS 側にある。ここはその設計を移したもの。
//  DSP そのものは触っていない。
//
//  移した元:
//    js/fir-crossover/design-core.js        1-215   設計の本体
//    js/fir-crossover/design-worker.js      18-50   経路の並べ方と資産の組み立て
//    js/fir-crossover/designer.js           1-44    Worker で回す（＝重い）という扱い
//    plugins/basics/fir_crossover.js        1-330   画面側の値の丸め方・送り込む形
//
//  --- 資産として何を渡すのか（読み取った出典つき）---
//  受け取り側は 3 か所で見ている。どれも同じ並びを言っている。
//
//    kernel.cpp:341-349  validatePayload      頭の 32 バイトの中身
//    kernel.cpp:351-367  decodeMatrixPaths    頭の直後に来る経路
//    kernel.cpp:275-278  commitAsset          係数の本体はその後ろから
//    kernel.cpp:321-339  validateBegin        begin の引数に対する条件
//
//  ペイロード（すべてリトルエンディアン）:
//    +0  u32  0x31415445                        kernel.cpp:343 / kAssetMagic は :22
//    +4  u32  channels  = 帯の数（2〜4）        kernel.cpp:343、validateBegin :322
//    +8  u32  frames    = taps                  kernel.cpp:344、上限 131072 は :326
//    +12 u32  sampleRate = lround(engine の sr) kernel.cpp:345 ← **engine の値と一致必須**
//    +16 u32  topology  = 4（matrix）           kernel.cpp:346 / kMatrixTopology は :23
//    +20 u32  pathCount = 帯の数 * 2            kernel.cpp:347、:326 で channels*2 と照合
//    +24 u32  0                                 kernel.cpp:347
//    +28 u32  0                                 kernel.cpp:348
//    +32      経路が pathCount 本。1 本 12 バイトで u32 input / u32 output / u32 irChannel
//             kernel.cpp:355-364 が並びまで固定していて、
//             band 番目の入力 input は {input, band*2+input, band} でないと弾かれる。
//             書き手は design-worker.js:24-27 で、同じ並びを作っている。
//    その後   float32 が channel-major（帯 0 の taps 個、次に帯 1 …）
//             kernel.cpp:276-278 が (32 + pathCount*12) の後ろから読んでいる。
//
//  書き手側の出典は js/ir-library/ir-asset-payload.js:74-93（buildIrAssetPayload）。
//  +24 と +28 は JS が一度も書いていない（ArrayBuffer の 0 のまま）が、
//  カーネルは 0 であることを要求している。組み立ては AssetUpload.makePayload が持つ。
//
//  --- 送り込む形 ---
//    headBlock          = latencyMode の**文字列の値**（0/128/256/512/1024）。
//                         params.json の latencyMode は enum なので、
//                         カーネルへ渡す float は添字、begin へ渡すのは値。
//                         JS も Number(this.lt) と分けている（fir_crossover.js:303）
//    rateDivider        = 1 固定（kernel.cpp:330 が 1 以外を弾く）
//    inputCount         = 2 固定（kernel.cpp:327）
//    processingChannels = 4〜16 の偶数（kernel.cpp:323-325）
//    footprintBytes     = AssetUpload の見積り（JS も同じ式：fir_crossover.js:299-307）
//
//  --- いまの app では鳴らない ---
//  帯ごとにステレオ 1 対を吐くので、出口が 4 チャンネル以上ないと成り立たない。
//  カーネルも channelCount == 2 のときは何もせずに戻る（kernel.cpp:105-106）。
//  この app は et_engine_prepare に maxChannels=2 を渡し（AudioIO.swift:110,178）、
//  ETPipeline_Process にも 2 を渡している（AudioIO.swift:216,220）ので、
//  いまの状態だと begin が必ず弾かれる（kernel.cpp:325 の processingChannels > max_channels_）。
//  そこは engine の用意のしかたの問題なので、ここでは触らず .unavailable として画面に出す。
//  文言は JS の _settleUnavailable（fir_crossover.js:248-250）と同じにしてある。
//
//  --- 重さの扱い ---
//  JS は Worker へ出している（designer.js）。taps は最大 131072 で、
//  FFT は 262144 点を帯ごとに 3 回。これは音のスレッドどころか UI スレッドでも
//  やってはいけない量なので、Task.detached で外へ出してから送り込む。
//  送り込み（AssetUpload.send）だけは UI スレッドで行う。理由は AssetUpload.swift の冒頭。
//
//  --- 数の扱い ---
//  JS の Number は double。途中は Double で回して、係数にするところだけ Float へ落とす。
//  線形位相の最後の帯だけは、**Float へ落とした後の値**を Double で引き算する
//  （design-core.js:193-202 が Float32Array を読みながら引いているのと同じ）。

import Combine
import Foundation
import os

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
        let raw = (sampleRate.isFinite && sampleRate != 0) ? sampleRate : 48000
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
        let exponent = slope / octaveDecibels * Foundation.log(frequency / cutoff)
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
            logMagnitude[bin] = Foundation.log(max(minimumMagnitude, magnitudes[bin]))
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

// MARK: - 出来上がったもの（送り込む直前の形）

/// 設計の結果を、送り込める形まで畳んだもの。
/// 係数そのものは持たない。ペイロードを作った時点でもう要らないので、
/// taps=131072 のときに 2MiB を二重に抱えないようにしている。
private struct FIRCrossoverStaged: Sendable {
    let config: FIRCrossoverConfig
    let payload: [UInt8]
    let latencyInfo: FIRCrossoverLatencyInfo
    let powerGainUpperBoundDecibels: Double
}

// MARK: - 設計して送り込む

/// パラメータが変わるたびに、設計し直して instance へ送り込む。
///
/// 設計は Task.detached で外へ出す（JS が Worker へ出しているのと同じ理由）。
/// 送り込みだけは UI スレッドで行う。AssetUpload がそのあいだ bypass を上げるので、
/// 音のスレッドは engine に触らない。
@MainActor
final class FIRCrossoverDesigner: ObservableObject {

    /// 送り先。
    struct Target: Equatable, Sendable {
        var engine: UInt32
        var instance: UInt32
        /// **et_engine_prepare へ渡した値**。カーネルはこれと同じ整数が
        /// ペイロードの +12 に入っているかを見る（kernel.cpp:345）。
        /// この app は倍率を掛けて渡している（AudioIO.swift:178 の `sr * Double(factor)`）ので、
        /// 機器の sampleRate をそのまま入れると commit が通らない。
        var sampleRate: Double
        /// この instance が処理するチャンネル数。4〜16 の偶数でないと成り立たない。
        var processingChannels: Int
        var slot: UInt32 = 0

        init(engine: UInt32,
             instance: UInt32,
             sampleRate: Double,
             processingChannels: Int,
             slot: UInt32 = 0) {
            self.engine = engine
            self.instance = instance
            self.sampleRate = sampleRate
            self.processingChannels = processingChannels
            self.slot = slot
        }
    }

    /// 画面に出す状態。文言は英語。
    enum Status: Equatable {
        case idle
        /// 出口の幅が足りない。
        case unavailable
        case designing
        case staging
        /// 送り込めたが、音が来ていないので畳み込み器がまだ立ち上がっていない。
        case waitingForAudio
        case active
        case designFailed
        case stageFailed(String)

        var message: String {
            switch self {
            case .idle:
                return "FIR Crossover is idle."
            case .unavailable:
                return "FIR Crossover needs an even number of output channels from 4 to 16."
            case .designing:
                return "Designing FIR crossover filters…"
            case .staging:
                return "Loading the FIR crossover filters…"
            case .waitingForAudio:
                return "The FIR crossover filters start with the next audio."
            case .active:
                return "The FIR crossover filters are running."
            case .designFailed:
                return "The FIR crossover filters could not be designed. Try fewer taps."
            case .stageFailed:
                return "The FIR crossover filters could not be prepared. "
                    + "Try fewer taps or a higher latency."
            }
        }

        /// 失敗の中身。画面には出さず、記録にだけ使う。
        var detail: String? {
            if case .stageFailed(let reason) = self { return reason }
            return nil
        }

        var isError: Bool {
            switch self {
            case .designFailed, .stageFailed, .unavailable: return true
            default: return false
            }
        }
    }

    // MARK: 外から見えるもの

    @Published private(set) var settings = FIRCrossoverSettings()
    @Published private(set) var status: Status = .idle
    /// 通したときに出得る最大の増幅。画面の余裕の表示に使う。
    @Published private(set) var powerGainUpperBoundDecibels: Double = 0
    @Published private(set) var latencyInfo: FIRCrossoverLatencyInfo?

    /// パラメータを鎖へ書き戻す口。EffeTuneDSP.setValue(_:at:offset:) を繋ぐ。
    ///
    /// 渡す並びは EffectCatalog.swift:123-125 のとおり
    /// [latencyMode の添字, filterDelaySamples, bandCount]。
    /// nil のあいだは et_instance_set_params を直に叩くが、それだと EffeTuneDSP が
    /// 持っている values とずれて、次の publish で上書きされる。画面側で必ず繋ぐこと。
    var parameterWriter: (([Float]) -> Void)?

    /// commit が通った直後に呼ばれる。instance の遅延が変わっているので、
    /// 鎖を publish し直して遅延合わせをやり直すこと。
    /// JS も同じ場所で refreshDspPipelineForLatencyChange を呼んでいる
    /// （plugins/audio-processor.js:3226）。
    var onAssetCommitted: (() -> Void)?

    // MARK: 中身

    private static let log = Logger(subsystem: "ai.nemut.effetune", category: "fir-crossover")

    /// EffectCatalog から引く。無ければ生成ヘッダの値
    /// （dsp/generated/cpp/FIRCrossoverPluginParams.h:13）。
    private static let paramsHash: UInt32 =
        ETCatalog.first(where: { $0.type == "FIRCrossoverPlugin" })?.paramsHash ?? 0x2267_c350
    private static let floatCount = 3
    /// fir_crossover.js:169 の _scheduleDesign(150)。
    private static let designDebounce: TimeInterval = 0.15

    private var target: Target?
    private var designTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    /// design-core.js:7 の designCache と同じで 2 つまで持つ。
    private var cache = [FIRCrossoverStaged]()

    init() {}

    // MARK: 繋ぐ・外す

    /// 送り先を決める。決まった時点で設計が走る。
    func attach(_ target: Target) {
        guard self.target != target else { return }
        self.target = target
        refresh(delay: 0)
    }

    /// 鎖から外れたとき。資産も外して素通しに戻す。
    func detach() {
        designTask?.cancel()
        designTask = nil
        generation &+= 1
        if let target = target {
            AssetUpload.clear(engine: target.engine, instance: target.instance, slot: target.slot)
        }
        target = nil
        cache.removeAll()
        latencyInfo = nil
        powerGainUpperBoundDecibels = 0
        status = .idle
    }

    // MARK: パラメータ

    /// 画面から値が変わったとき。丸めてから、変わっていれば作り直す。
    func update(_ candidate: FIRCrossoverSettings) {
        var next = candidate
        next.clamp()
        guard next != settings else { return }
        settings = next
        refresh(delay: Self.designDebounce)
    }

    /// 1 つだけ変える口。画面のつまみから呼ぶ用。
    func update(_ change: (inout FIRCrossoverSettings) -> Void) {
        var next = settings
        change(&next)
        update(next)
    }

    /// engine の sampleRate や出口の幅が変わったとき。
    func retarget(sampleRate: Double? = nil, processingChannels: Int? = nil) {
        guard var next = target else { return }
        if let sampleRate = sampleRate { next.sampleRate = sampleRate }
        if let processingChannels = processingChannels { next.processingChannels = processingChannels }
        guard next != target else { return }
        target = next
        refresh(delay: 0)
    }

    // MARK: 作り直して送り直す

    private func refresh(delay: TimeInterval) {
        designTask?.cancel()
        designTask = nil
        generation &+= 1
        let mine = generation

        guard let target = target, target.engine != 0, target.instance != 0 else {
            status = .idle
            return
        }
        guard let config = settings.config(sampleRate: target.sampleRate,
                                           processingChannels: target.processingChannels) else {
            // fir_crossover.js:236-251 の _settleUnavailable。
            cache.removeAll()
            latencyInfo = nil
            powerGainUpperBoundDecibels = 0
            AssetUpload.clear(engine: target.engine, instance: target.instance, slot: target.slot)
            status = .unavailable
            return
        }
        guard AssetUpload.canStage else {
            status = .stageFailed(ETAssetUploadError.stagingAddressUnavailable.localizedDescription)
            return
        }

        // 入り切らないものは、数秒かけて設計する前に落とす。
        let footprint = AssetUpload.estimateFootprintBytes(
            frames: config.taps,
            assetChannels: config.bandCount,
            topology: .matrix,
            processingChannels: target.processingChannels,
            headBlock: Int(settings.headBlock),
            pathCount: config.bandCount * 2,
            inputCount: 2
        )
        guard footprint <= AssetUpload.capacityBytes else {
            let error = FIRCrossoverDesignError.tooLargeForSlot(
                footprintBytes: footprint,
                capacityBytes: AssetUpload.capacityBytes
            )
            Self.log.error("資産が枠に入らない \(error.localizedDescription, privacy: .public)")
            status = .stageFailed(error.localizedDescription)
            return
        }

        // 設計が同じなら作り直さない。遅延モードや出口の幅だけ変わったときがこれ。
        // JS も _lastDesign があれば _stageDesign だけを呼び直す（fir_crossover.js:170-172）。
        if let staged = cache.first(where: { $0.config == config }) {
            status = .staging
            designTask = Task { [weak self] in
                await self?.stage(staged, target: target, generation: mine)
            }
            return
        }

        status = .designing
        designTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            await self?.designAndStage(config: config, target: target, generation: mine)
        }
    }

    /// 重いところ。UI スレッドから外して回す。
    private func designAndStage(config: FIRCrossoverConfig,
                                target: Target,
                                generation mine: UInt64) async {
        let staged: FIRCrossoverStaged
        do {
            staged = try await Task.detached(priority: .userInitiated) {
                let design = try FIRCrossoverDesignCore.design(config)
                // ペイロードの組み立てもここでやる。2MiB を UI スレッドで並べない。
                let payload = try AssetUpload.makePayload(
                    channels: design.channels,
                    sampleRate: design.config.sampleRate,
                    topology: .matrix,
                    paths: FIRCrossoverDesignCore.paths(bandCount: design.config.bandCount)
                )
                return FIRCrossoverStaged(
                    config: design.config,
                    payload: payload,
                    latencyInfo: design.latencyInfo,
                    powerGainUpperBoundDecibels:
                        FIRCrossoverDesignCore.powerGainUpperBoundDecibels(design.channels)
                )
            }.value
        } catch {
            guard mine == generation else { return }
            Self.log.error("設計に失敗 \(error.localizedDescription, privacy: .public)")
            status = .designFailed
            return
        }
        guard mine == generation else { return }
        remember(staged)
        await stage(staged, target: target, generation: mine)
    }

    /// begin → 写す → commit。AssetUpload がそのあいだ音のスレッドを締め出す。
    private func stage(_ staged: FIRCrossoverStaged,
                       target: Target,
                       generation mine: UInt64) async {
        guard mine == generation else { return }
        status = .staging
        powerGainUpperBoundDecibels = staged.powerGainUpperBoundDecibels
        latencyInfo = staged.latencyInfo

        // begin は params_.filterDelaySamples を読む（kernel.cpp:251 と :331）。
        // beginAsset の頭で applyPendingParameters() が走るので、先に積んでおけば間に合う。
        pushParameters(config: staged.config)

        let info = AssetUpload.BeginInfo(
            topology: .matrix,
            headBlock: settings.headBlock,
            rateDivider: 1,
            pathCount: UInt32(staged.config.bandCount * 2),
            inputCount: 2,
            processingChannels: UInt32(target.processingChannels)
        )
        do {
            try AssetUpload.send(engine: target.engine,
                                 instance: target.instance,
                                 slot: target.slot,
                                 payload: staged.payload,
                                 info: info)
        } catch {
            guard mine == generation else { return }
            Self.log.error("送り込みに失敗 \(error.localizedDescription, privacy: .public)")
            status = .stageFailed(error.localizedDescription)
            return
        }
        guard mine == generation else { return }

        // 遅延が変わっている。鎖を publish し直してもらう。
        onAssetCommitted?()

        // commit の直後は preparing で、音が何ブロックか通ってから active になる。
        // 鳴っていなければ進まないので、待つのは 1 秒まで。
        let state = await AssetUpload.waitForActive(engine: target.engine,
                                                    instance: target.instance,
                                                    slot: target.slot,
                                                    timeout: 1.0)
        guard mine == generation else { return }
        switch state.state {
        case .active:
            status = .active
        case .error:
            // reason の意味は AssetUpload.ETAssetStatus.reason に書いてある。
            let reason = "asset state error reason=\(state.reason)"
            Self.log.error("カーネルが資産を拒んだ \(reason, privacy: .public)")
            status = .stageFailed(reason)
        default:
            status = .waitingForAudio
        }
    }

    /// カーネルへ渡す 3 つ。並びは EffectCatalog.swift:123-125。
    ///   latencyMode        enum の**添字**（0/128/256/512/1024 の何番目か）
    ///   filterDelaySamples 最小位相なら 0、線形位相なら taps/2（fir_crossover.js:88）
    ///   bandCount          実際に設計した帯の数
    private func pushParameters(config: FIRCrossoverConfig) {
        let values: [Float] = [
            Float(settings.latencyModeIndex),
            Float(config.phase == .minimum ? 0 : config.taps / 2),
            Float(config.bandCount)
        ]
        if let writer = parameterWriter {
            writer(values)
            return
        }
        guard let target = target, target.engine != 0, target.instance != 0 else { return }
        let result = values.withUnsafeBufferPointer {
            et_instance_set_params(target.engine, target.instance, $0.baseAddress,
                                   UInt32(Self.floatCount), Self.paramsHash, 0)
        }
        if Int(result) != ET_OK {
            Self.log.error("set_params が \(Int(result)) を返した")
        }
    }

    /// design-core.js:212-213 と同じで、持つのは 2 つまで。古いほうから捨てる。
    private func remember(_ staged: FIRCrossoverStaged) {
        cache.removeAll { $0.config == staged.config }
        cache.append(staged)
        while cache.count > 2 { cache.removeFirst() }
    }
}
