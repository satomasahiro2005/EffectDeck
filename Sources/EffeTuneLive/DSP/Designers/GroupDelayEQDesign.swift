//  GroupDelayEQDesign.swift
//  Group Delay EQ の係数設計そのもの。状態を持たず、Foundation と FIRDesign だけで建つ。
//
//  GroupDelayEQDesigner.swift から切り出した。送り込み（AssetUpload・EffeTuneDSP・カーネルの
//  パラメータ）はあちらに残し、こちらは試験のバンドルへそのまま入れて上流の見本と照合する
//  （Tests/Unit/GroupDelayEQDesignTests.swift。見本は Tools/golden/designers_b_golden.mjs）。
//
//  元:
//    Vendor/effetune/js/group-delay-eq/design-core.js（266 行。全部移した）
//    Vendor/effetune/plugins/eq/group_delay_eq.js（既定値・警告の文言）
//
//  何をする設計か:
//    振幅が平らなまま群遅延だけを帯ごとにずらす全域通過 FIR を作る。
//    無限長の理想全域通過を、長さの制約（taps 個で打ち切る）と
//    振幅 1 の制約とのあいだで交互に射影して、有限長へ落とす
//    （design-core.js:4-8 の説明どおり。反復は 12 回）。
//
//  --- 重さ ---
//  taps が 32768 のとき FFT の大きさは 65536、反復は最大 12 回で
//  1 回につき前進と逆の 2 回。JS が Worker へ出しているのはこれが理由なので
//  （design-worker.js）、呼ぶ側（GroupDelayEQDesigner）が Task.detached へ出す。

import Foundation

// MARK: - 設計そのもの（スレッドに縛られない）

enum GroupDelayEQDesignError: Error, LocalizedError, Sendable {
    case unsupportedTaps
    case invalidSampleRate
    case fftUnavailable
    case cancelled
    case designFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedTaps:
            return "Group Delay EQ tap count is unsupported."
        case .invalidSampleRate:
            return "Group Delay EQ sample rate is invalid."
        case .fftUnavailable:
            return "The transform for this tap count could not be created."
        case .cancelled:
            return "The filter design was cancelled."
        case .designFailed:
            return "The filter could not be designed. Try a different Taps setting."
        }
    }
}

/// design-core.js の中身。状態を持たないので、どのスレッドから呼んでもよい。
enum GroupDelayEQDesign {

    // MARK: 定数（design-core.js:12-23、group_delay_eq.js:19-24）

    /// 帯の中心周波数。design-core.js:12-14。
    static let bands: [Double] = [
        25, 40, 63, 100, 160, 250, 400, 630, 1000, 1600, 2500, 4000, 6300, 10000, 16000
    ]
    /// design-core.js:15。
    static let tapsChoices: [Int] = [4096, 8192, 16384, 32768]
    /// params.json:9 の latencyMode。値は頭ブロックの大きさそのもの。
    static let headBlockChoices: [UInt32] = [0, 128, 256, 512, 1024]
    /// group_delay_eq.js:23。これを超えたら「追従できていない」と出す。
    static let rippleWarningDb: Double = 0.3

    /// DESIGN_ITERATIONS。design の既定引数から参照するので private にしない。
    static let designIterations = 12
    private static let spectrumOversampling = 2    // SPECTRUM_OVERSAMPLING
    private static let guardDivisor: Double = 16   // GUARD_DIVISOR
    private static let responsePoints = 128        // RESPONSE_POINTS
    private static let responseLowFrequency: Double = 20      // RESPONSE_LOW_FREQUENCY
    private static let responseHighFrequency: Double = 20000  // RESPONSE_HIGH_FREQUENCY
    private static let magnitudeEpsilon: Double = 1e-12       // MAGNITUDE_EPSILON

    // MARK: 出来上がるもの

    /// 設計の結果。designGroupDelayFilter（design-core.js:175-215）の戻り値。
    struct Filter: Sendable {
        /// カーネルへ渡す係数。長さは taps。
        let ir: [Float]
        /// 全体にかかる遅延（サンプル）。taps / 2。
        let bulkDelaySamples: Double
        /// 要求した遅延が長すぎて切り詰めたか。
        let clamped: Bool
        /// この taps で出せる遅延の上限（ms）。
        let limitMs: Double
        /// 実際に出た振幅のうねり（dB）。平らなはずなので 0 に近いほどよい。
        let rippleDb: Double
        /// 画面のグラフ用。
        let response: Response
        let taps: Int
        let sampleRate: Double
    }

    struct Response: Sendable {
        let frequencies: [Double]
        let targetMs: [Double]
        let realizedMs: [Double]
    }

    /// clampDelays（design-core.js:51-64）の戻り値。
    struct ClampedDelays: Sendable {
        let valuesMs: [Double]
        let clamped: Bool
        let limitMs: Double
    }

    /// buildTargetSpectrum（design-core.js:138-162）の戻り値。
    struct TargetSpectrum {
        var real: [Double]
        var imag: [Double]
        let clampedMs: [Double]
        let clamped: Bool
        let limitMs: Double
        let bulkDelaySamples: Double
        let curve: TargetCurve
    }

    // MARK: 単調性を保つ傾き

    /// Fritsch-Carlson の傾き。design-core.js:29-49 をそのまま。
    /// 形を保つ選び方なので、スライダのあいだで遅延曲線が行き過ぎない。
    static func monotoneSlopes(positions: [Double], values: [Double]) -> [Double] {
        let count = positions.count
        guard count >= 2 else { return [Double](repeating: 0, count: count) }
        var slopes = [Double](repeating: 0, count: count)
        var secants = [Double](repeating: 0, count: count - 1)
        for index in 0..<(count - 1) {
            secants[index] =
                (values[index + 1] - values[index]) / (positions[index + 1] - positions[index])
        }
        slopes[0] = secants[0]
        slopes[count - 1] = secants[count - 2]
        guard count > 2 else { return slopes }
        for index in 1..<(count - 1) {
            let previous = secants[index - 1]
            let next = secants[index]
            // 符号が変わる所（山や谷）は傾き 0 のまま。JS の continue と同じ。
            if previous * next <= 0 { continue }
            let leftWidth = positions[index] - positions[index - 1]
            let rightWidth = positions[index + 1] - positions[index]
            let leftWeight = 2 * rightWidth + leftWidth
            let rightWeight = rightWidth + 2 * leftWidth
            slopes[index] = (leftWeight + rightWeight) / (leftWeight / previous + rightWeight / next)
        }
        return slopes
    }

    // MARK: 遅延の頭打ち

    /// design-core.js:51-64。taps の半分から guard（taps/16）を引いた分までしか出せない。
    static func clampDelays(_ delaysMs: [Double], taps: Int, sampleRate: Double) -> ClampedDelays {
        let tapCount = Double(taps)
        let limitSamples = tapCount / 2 - tapCount / guardDivisor
        let limitMs = limitSamples * 1000 / sampleRate
        var values = [Double](repeating: 0, count: bands.count)
        var clamped = false
        for band in 0..<bands.count {
            // JS は Number(delaysMs?.[band]) で、無いか NaN なら 0 に落とす。
            let requested = band < delaysMs.count ? delaysMs[band] : Double.nan
            let value = requested.isFinite ? requested : 0
            let bounded = value > limitMs ? limitMs : (value < -limitMs ? -limitMs : value)
            if bounded != value { clamped = true }
            values[band] = bounded
        }
        return ClampedDelays(valuesMs: values, clamped: clamped, limitMs: limitMs)
    }

    /// 画面のスライダが使う上限。小数 1 桁に切り捨てる。
    /// group_delay_eq.js:94 の _delayLimitMs。設計側の limitMs より少しだけ狭い。
    static func uiDelayLimitMs(taps: Int, sampleRate: Double) -> Double {
        let tapCount = Double(taps)
        return ((tapCount / 2 - tapCount / guardDivisor) * 1000 / sampleRate * 10).rounded(.down) / 10
    }

    // MARK: 目標の群遅延

    /// 周波数から目標の群遅延（ms）を返す曲線。design-core.js:71-108。
    /// いちばん下の帯より下は値を保ち、Nyquist の手前で 0 へ落とす
    /// （実数のインパルス応答と辻褄が合うように）。
    ///
    /// JS は closure を返すが、bin ごとに何万回も呼ぶので struct にした。
    struct TargetCurve {
        let positions: [Double]
        let values: [Double]
        let slopes: [Double]
        let fadeStart: Double
        let fadeEnd: Double

        func value(at frequency: Double) -> Double {
            if frequency >= fadeEnd { return 0 }
            let bandCount = GroupDelayEQDesign.bands.count
            var result: Double
            if frequency <= GroupDelayEQDesign.bands[0] {
                result = values[0]
            } else if frequency >= GroupDelayEQDesign.bands[bandCount - 1] {
                result = values[bandCount - 1]
            } else {
                let position = log10(frequency)
                var segment = 0
                while segment < bandCount - 2 && position > positions[segment + 1] {
                    segment += 1
                }
                let width = positions[segment + 1] - positions[segment]
                let ratio = (position - positions[segment]) / width
                let squared = ratio * ratio
                let cubed = squared * ratio
                result = (2 * cubed - 3 * squared + 1) * values[segment]
                    + (cubed - 2 * squared + ratio) * width * slopes[segment]
                    + (-2 * cubed + 3 * squared) * values[segment + 1]
                    + (cubed - squared) * width * slopes[segment + 1]
            }
            if frequency > fadeStart {
                result *= 0.5 + 0.5 * cos(Double.pi * (frequency - fadeStart) / (fadeEnd - fadeStart))
            }
            return result
        }
    }

    /// design-core.js:71-108 の createTargetCurve。
    static func makeTargetCurve(delaysMs: [Double], sampleRate: Double) -> TargetCurve {
        let bandCount = bands.count
        var positions = [Double](repeating: 0, count: bandCount)
        var values = [Double](repeating: 0, count: bandCount)
        for band in 0..<bandCount {
            positions[band] = log10(bands[band])
            values[band] = band < delaysMs.count ? delaysMs[band] : 0
        }
        let slopes = monotoneSlopes(positions: positions, values: values)
        let nyquist = sampleRate / 2
        let fadeEnd = min(responseHighFrequency, nyquist * 0.9)
        let fadeStart = min(bands[bandCount - 1], fadeEnd * 0.9)
        return TargetCurve(positions: positions,
                           values: values,
                           slopes: slopes,
                           fadeStart: fadeStart,
                           fadeEnd: fadeEnd)
    }

    /// グラフと設計で共有する周波数の並び。design-core.js:113-121。
    /// 中身は FIRDesign.logFrequencies と同じ式（対数で等間隔）。
    static func responseFrequencies(sampleRate: Double) -> [Double] {
        let highest = min(responseHighFrequency, sampleRate * 0.45)
        return FIRDesign.logFrequencies(low: responseLowFrequency,
                                        high: highest,
                                        count: responsePoints)
    }

    /// いまの設定の目標群遅延（ms）。design-core.js:126-133 の groupDelayTargetMs。
    /// 設計を回さずにグラフの目標線だけ引きたいときに使う。
    static func targetMs(delaysMs: [Double],
                         taps: Int,
                         sampleRate: Double,
                         frequencies: [Double]? = nil) -> [Double] {
        let clamped = clampDelays(delaysMs, taps: taps, sampleRate: sampleRate)
        let curve = makeTargetCurve(delaysMs: clamped.valuesMs, sampleRate: sampleRate)
        let grid = frequencies ?? responseFrequencies(sampleRate: sampleRate)
        return grid.map { curve.value(at: $0) }
    }

    // MARK: 理想の全域通過スペクトル

    /// 一定の全体遅延に、要求されたぶんの偏差を足したもの。design-core.js:138-162。
    /// 偏差の位相は群遅延を台形則で積み上げて作る。
    static func buildTargetSpectrum(delaysMs: [Double],
                                    taps: Int,
                                    sampleRate: Double,
                                    size: Int) -> TargetSpectrum {
        let clamped = clampDelays(delaysMs, taps: taps, sampleRate: sampleRate)
        let bulkDelaySamples = Double(taps) / 2
        let curve = makeTargetCurve(delaysMs: clamped.valuesMs, sampleRate: sampleRate)
        let samplesPerMillisecond = sampleRate / 1000
        let bins = size / 2 + 1
        var real = [Double](repeating: 0, count: bins)
        var imag = [Double](repeating: 0, count: bins)
        let step = 2 * Double.pi / Double(size)
        var deviationPhase = 0.0
        var previous = curve.value(at: 0) * samplesPerMillisecond
        real[0] = 1
        for bin in 1..<bins {
            let deviation =
                curve.value(at: Double(bin) * sampleRate / Double(size)) * samplesPerMillisecond
            deviationPhase += 0.5 * (previous + deviation) * step
            previous = deviation
            let phase = -(step * Double(bin) * bulkDelaySamples + deviationPhase)
            real[bin] = cos(phase)
            imag[bin] = sin(phase)
        }
        // 実数列の Nyquist bin に虚部は無い（design-core.js:158-160）。
        real[bins - 1] = real[bins - 1] < 0 ? -1 : 1
        imag[bins - 1] = 0
        return TargetSpectrum(real: real,
                              imag: imag,
                              clampedMs: clamped.valuesMs,
                              clamped: clamped.clamped,
                              limitMs: clamped.limitMs,
                              bulkDelaySamples: bulkDelaySamples,
                              curve: curve)
    }

    // MARK: 設計

    /// 全域通過 FIR を設計して、有限の taps で実際に何が出たかを測る。
    /// design-core.js:175-215 の designGroupDelayFilter。
    ///
    /// - Parameter isCancelled: 反復ごとに見る。重いので途中で降りられるようにした。
    static func design(delaysMs: [Double],
                       taps: Int = 16384,
                       sampleRate: Double = 48000,
                       iterations: Int = GroupDelayEQDesign.designIterations,
                       isCancelled: () -> Bool = { false }) throws -> Filter {
        guard tapsChoices.contains(taps) else { throw GroupDelayEQDesignError.unsupportedTaps }
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw GroupDelayEQDesignError.invalidSampleRate
        }
        let size = taps * spectrumOversampling
        guard let fft = FIRDesign.fft(size: size) else {
            throw GroupDelayEQDesignError.fftUnavailable
        }
        let target = buildTargetSpectrum(delaysMs: delaysMs,
                                         taps: taps,
                                         sampleRate: sampleRate,
                                         size: size)

        // 理想のスペクトルから始めて、
        //   (1) taps より後ろを 0 にする（長さの制約）
        //   (2) 各 bin の振幅を 1 に戻す（全域通過の制約）
        // を交互に射影する。どちらの制約も満たせば収束。
        var impulse = fft.inverseRealTransform(real: target.real, imag: target.imag)
        for _ in 0..<iterations {
            if isCancelled() { throw GroupDelayEQDesignError.cancelled }
            zeroTail(&impulse, from: taps)
            var spectrum = fft.realTransform(impulse)
            var converged = true
            for bin in 0..<spectrum.real.count {
                let real = spectrum.real[bin]
                let imag = spectrum.imag[bin]
                let magnitude = (real * real + imag * imag).squareRoot()
                if magnitude < magnitudeEpsilon { continue }
                if magnitude > 1.0001 || magnitude < 0.9999 { converged = false }
                spectrum.real[bin] = real / magnitude
                spectrum.imag[bin] = imag / magnitude
            }
            if converged { break }
            impulse = fft.inverseRealTransform(real: spectrum.real, imag: spectrum.imag)
        }
        zeroTail(&impulse, from: taps)

        // ここで Float へ落とす。以降の測定も Float に落ちた値で行う
        // （JS も Float32Array に入れてから測っている。design-core.js:211-214）。
        var ir = [Float](repeating: 0, count: taps)
        for index in 0..<taps { ir[index] = Float(impulse[index]) }

        let measured = measureResponse(ir: ir,
                                       target: target,
                                       size: size,
                                       sampleRate: sampleRate,
                                       fft: fft)
        return Filter(ir: ir,
                      bulkDelaySamples: target.bulkDelaySamples,
                      clamped: target.clamped,
                      limitMs: target.limitMs,
                      rippleDb: measured.rippleDb,
                      response: measured.response,
                      taps: taps,
                      sampleRate: sampleRate)
    }

    // MARK: 測る

    /// 出来上がった FIR の振幅のうねりと群遅延。design-core.js:222-266。
    /// 群遅延は「傾斜をかけた変換との比」で出すので、位相をほどく必要がない。
    private static func measureResponse(ir: [Float],
                                        target: TargetSpectrum,
                                        size: Int,
                                        sampleRate: Double,
                                        fft: FIRDesign.RealFFT)
        -> (rippleDb: Double, response: Response) {
        var impulse = [Double](repeating: 0, count: size)
        var ramped = [Double](repeating: 0, count: size)
        for index in 0..<ir.count {
            impulse[index] = Double(ir[index])
            ramped[index] = Double(ir[index]) * Double(index)
        }
        let spectrum = fft.realTransform(impulse)
        let rampedSpectrum = fft.realTransform(ramped)
        let bins = spectrum.real.count
        var magnitudeDb = [Double](repeating: 0, count: bins)
        var delaySamples = [Double](repeating: 0, count: bins)
        for bin in 0..<bins {
            let real = spectrum.real[bin]
            let imag = spectrum.imag[bin]
            let power = real * real + imag * imag
            magnitudeDb[bin] = FIRDesign.decibels(fromPower: power, floor: magnitudeEpsilon)
            delaySamples[bin] = power > magnitudeEpsilon
                ? (rampedSpectrum.real[bin] * real + rampedSpectrum.imag[bin] * imag) / power
                : target.bulkDelaySamples
        }

        let frequencies = responseFrequencies(sampleRate: sampleRate)
        var targetMs = [Double](repeating: 0, count: frequencies.count)
        var realizedMs = [Double](repeating: 0, count: frequencies.count)
        let millisecondsPerSample = 1000 / sampleRate
        var rippleDb = 0.0
        for point in 0..<frequencies.count {
            let frequency = frequencies[point]
            targetMs[point] = target.curve.value(at: frequency)
            realizedMs[point] = (sampleAtFrequency(delaySamples, frequency, size, sampleRate)
                - target.bulkDelaySamples) * millisecondsPerSample
            let deviation = sampleAtFrequency(magnitudeDb, frequency, size, sampleRate)
            let absolute = deviation < 0 ? -deviation : deviation
            if absolute > rippleDb { rippleDb = absolute }
        }
        return (rippleDb, Response(frequencies: frequencies,
                                   targetMs: targetMs,
                                   realizedMs: realizedMs))
    }

    /// bin の並びを周波数で線形に読む。design-core.js:164-170。
    private static func sampleAtFrequency(_ values: [Double],
                                          _ frequency: Double,
                                          _ size: Int,
                                          _ sampleRate: Double) -> Double {
        let position = frequency * Double(size) / sampleRate
        let lower = Int(position.rounded(.down))
        let upper = lower + 1
        if upper >= values.count { return values[values.count - 1] }
        if lower < 0 { return values[0] }
        return values[lower] + (values[upper] - values[lower]) * (position - Double(lower))
    }

    /// JS の TypedArray.fill(0, from) と同じ。
    private static func zeroTail(_ values: inout [Double], from index: Int) {
        guard index < values.count else { return }
        for position in index..<values.count { values[position] = 0 }
    }

    // MARK: 注意書き（英語）

    /// group_delay_eq.js:280-291 の _qualityWarning。届かない遅延を切った注意が、うねりの注意より先。
    static func qualityWarning(for filter: Filter) -> String? {
        if filter.clamped {
            let limit = String(format: "%.1f", filter.limitMs)
            return "This Taps setting cannot reach the requested delay. "
                + "The filter uses up to \(limit) ms."
        }
        if filter.rippleDb > rippleWarningDb {
            return "The filter cannot follow these settings closely. "
                + "Increase Taps or reduce the difference between neighbouring bands."
        }
        return nil
    }
}
