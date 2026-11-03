//  TonalBalanceModel.swift
//  Tonal Balance EQ（TonalBalanceEQPlugin、2.12.0 で増えた）の値の計算。
//  画面（TonalBalanceEQView）は描くだけ。**Foundation だけ**で、実機なしで試せる
//  （Tests/Unit/TonalBalanceTests.swift）。
//
//  上流は plugins/eq/tonal_balance_eq.js。枠の読み（parseTonalBalanceEqFrame）、
//  帯域ごとの値を曲線に伸ばす補間（interpolateBands）、描く曲線の計算（computeTonalBalanceEqView）、
//  Target adjust の応答（room_eq.js:680 の calculateBandResponse）、縦軸の追従（_fitDbRange）を写した。
//
//  テレメトリ: ETFrameType.tonalBalance = 29、formatVersion 1、1564 バイト
//  （dsp/plugins/eq/tonal_balance_eq/kernel.cpp、tonal_balance_eq.js:1-5）
//
//  ペイロードの並び（tonal_balance_eq.js:78-107、dsp/bindings/js/src/telemetry.js:601-659）:
//      0      f32 sampleRate
//      4      u16 帯域の数 41      6  u16 応答の点の数 128
//      8      u8  stateFlags   bit0 絶対ゲート、bit1 相対ゲート、bit2 ラウドネス有効、bit3 目標が有効
//      9      u8  targetIndex  ETTonalBalance.targets の添字
//      12     f32 loudness（LKFS、無効なら 0）   16 f32 makeup（dB）   20 u32 ゲートを通ったホップ数
//      24     f32 × 41 levelDb       188 persistence   352 presence   516 command
//      680    f32 × 41 mu（目標の平均）   844 sigma（目標のばらつき）
//      1008   u8  × 41 bandFlags   bit2 目標がある、bit3 測定がある、bit4 Low–High の中
//      1052   f32 × 128 response（EQ の応答 dB、20Hz〜20kHz を対数で等間隔）
//  帯域は ERB レートで 41 本。中心は (10^((b+1)/21.4) - 1) * 1000 / 4.37（Hz）。

import Foundation

enum ETTonalBalance {

    // MARK: 定数（tonal_balance_eq.js:1-52）

    static let bands = 41
    static let gridPoints = 128
    static let payloadBytes = 1564
    static let targets = ["All", "Classical", "Electronic", "Pop", "Rock", "Tilt"]
    static let adjustTypes = ["pk", "ls", "hs"]
    static let adjustFrequencies: [Double] = [100, 316, 1000, 3160, 10000]
    /// Averaging Time の一番上（100）は無限の時定数（Reset からの全部の平均）。
    static let averagingTimeInfinite: Double = 100
    static let averagingTimeMinimum: Double = 0.1

    static let hasTarget: UInt8 = 4
    static let hasLevel: UInt8 = 8
    static let inRange: UInt8 = 16
    static let loudnessValid: UInt8 = 4

    /// ERB レートの帯域の中心（Hz）。
    static let bandCentres: [Double] = (0..<41).map {
        (pow(10, Double($0 + 1) / 21.4) - 1) * 1000 / 4.37
    }
    static let bandLogFreqs: [Double] = bandCentres.map { log10($0) }
    static let gridLogMin = log10(20.0)
    static let gridLogSpan = log10(20000.0) - log10(20.0)
    /// 応答の 128 点（20Hz〜20kHz）。
    static let gridLogFreqs: [Double] = (0..<128).map {
        gridLogMin + gridLogSpan * Double($0) / 127
    }
    /// 横軸は帯域の中心の両端に合わせる（曲線が両端まで届く。応答の点は枠で切る）。
    static let logMin = bandLogFreqs[0]
    static let logSpan = bandLogFreqs[40] - bandLogFreqs[0]
    /// Target adjust の曲線を引く点。
    static let adjustLogFreqs: [Double] = (0..<512).map { logMin + logSpan * Double($0) / 511 }
    /// 帯域ごとの曲線を引く点。応答の点と帯域の中心を混ぜて、曲線が全部の帯域の値を通るようにする。
    static let curveLogFreqs: [Double] = (gridLogFreqs + bandLogFreqs).sorted()
    static let freqTicks: [Double] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]
    static let defaultDbRange: Double = 12
    /// Range の上限（TONAL_BALANCE_EQ_RANGES.rg[1]）。
    static let rangeMaximum: Double = 12

    // MARK: Averaging Time（対数のスライダー。一番上が ∞）

    static func averagingTimeToSliderPosition(_ seconds: Double) -> Double {
        100 * log(max(seconds, averagingTimeMinimum) / averagingTimeMinimum)
            / log(averagingTimeInfinite / averagingTimeMinimum)
    }

    static func sliderPositionToAveragingTime(_ position: Double) -> Double {
        let value = averagingTimeMinimum * pow(averagingTimeInfinite / averagingTimeMinimum, position / 100)
        let rounded = (value * 10).rounded() / 10
        return rounded < averagingTimeMinimum ? averagingTimeMinimum
            : rounded > averagingTimeInfinite ? averagingTimeInfinite : rounded
    }

    static func formatAveragingTime(_ seconds: Double) -> String {
        seconds >= averagingTimeInfinite ? "∞" : String(format: "%.1f", seconds)
    }

    /// 打たれた字。"∞" や "inf…" は無限。読めなければ nil（前の値のまま）。
    static func parseAveragingTime(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t == "∞" || t.lowercased().hasPrefix("inf") { return averagingTimeInfinite }
        guard let v = Double(t), v.isFinite else { return nil }
        return min(max(v, averagingTimeMinimum), averagingTimeInfinite)
    }

    // MARK: Target adjust（シェルフの Q は 2 まで）

    /// ta の添字（0 = pk、1 = ls、2 = hs）ごとの Q の上限。
    static func maximumQ(type: Int) -> Double { type == 0 ? 10 : 2 }

    // MARK: 枠

    struct Reading: Equatable {
        var sampleRate: Double
        var stateFlags: UInt8
        var targetIndex: Int
        var loudness: Double
        var makeup: Double
        var levelDb: [Double]
        var persistence: [Double]
        var presence: [Double]
        var mu: [Double]
        var sigma: [Double]
        var bandFlags: [UInt8]
        var response: [Double]
        var sequence: UInt32

        var loudnessIsValid: Bool { stateFlags & ETTonalBalance.loudnessValid != 0 }
    }

    /// 枠を読む（parseTonalBalanceEqFrame）。読めなければ nil。
    static func parse(_ frame: ETFrame?) -> Reading? {
        guard let frame, frame.type == ETFrameType.tonalBalance.rawValue, frame.version == 1 else {
            return nil
        }
        let p = ETPayload(frame)
        guard p.count == payloadBytes, p.u16(at: 4) == UInt16(bands),
              p.u16(at: 6) == UInt16(gridPoints),
              let rate = p.f32(at: 0), let flags = p.u8(at: 8), let target = p.u8(at: 9),
              let loud = p.f32(at: 12), let makeup = p.f32(at: 16) else { return nil }
        func floats(_ offset: Int, _ count: Int) -> [Double]? {
            guard let raw = p.floats(at: offset, count: count) else { return nil }
            var out: [Double] = []
            out.reserveCapacity(count)
            for v in raw {
                guard v.isFinite else { return nil }
                out.append(Double(v))
            }
            return out
        }
        guard rate > 0, rate.isFinite, loud.isFinite, makeup.isFinite,
              let level = floats(24, bands), let persistence = floats(188, bands),
              let presence = floats(352, bands), let mu = floats(680, bands),
              let sigma = floats(844, bands), let response = floats(1052, gridPoints) else {
            return nil
        }
        var bandFlags: [UInt8] = []
        bandFlags.reserveCapacity(bands)
        for band in 0..<bands { bandFlags.append(p.u8(at: 1008 + band) ?? 0) }
        return Reading(sampleRate: Double(rate), stateFlags: flags, targetIndex: Int(target),
                       loudness: Double(loud), makeup: Double(makeup), levelDb: level,
                       persistence: persistence, presence: presence, mu: mu, sigma: sigma,
                       bandFlags: bandFlags, response: response, sequence: frame.sequence)
    }

    // MARK: 補間

    /// 帯域ごとの値を、曲線の点（curveLogFreqs）へ。対数周波数で単調な 3 次（Fritsch–Carlson、PCHIP の傾き）。
    /// どの帯域の中心も通り、隣り合う 2 つの値の外へは出ない。有限な帯域が続く所の外は NaN
    /// （interpolateBands、tonal_balance_eq.js:131-168）。
    static func interpolateBands(_ values: [Double]) -> [Double] {
        let xs = bandLogFreqs
        let last = bands - 1
        func secant(_ band: Int) -> Double { (values[band + 1] - values[band]) / (xs[band + 1] - xs[band]) }
        var slopes = [Double](repeating: 0, count: bands)
        for band in 0...last {
            let left = band > 0 ? secant(band - 1) : Double.nan
            let right = band < last ? secant(band) : Double.nan
            if !left.isFinite {
                slopes[band] = right
            } else if !right.isFinite {
                slopes[band] = left
            } else if left * right <= 0 {
                slopes[band] = 0
            } else {
                let leftWidth = xs[band] - xs[band - 1]
                let rightWidth = xs[band + 1] - xs[band]
                slopes[band] = 3 * (leftWidth + rightWidth)
                    / ((2 * rightWidth + leftWidth) / left + (rightWidth + 2 * leftWidth) / right)
            }
        }
        var curve = [Double](repeating: .nan, count: curveLogFreqs.count)
        var band = 0
        for (index, x) in curveLogFreqs.enumerated() {
            while band < last && xs[band + 1] <= x { band += 1 }
            let y0 = values[band]
            if x == xs[band] {
                curve[index] = y0
                continue
            }
            // 最後の帯域より右には隣が無い（JS は undefined が有限でないので抜ける）。
            guard band < last else { continue }
            let y1 = values[band + 1]
            if !(x > xs[band]) || !y0.isFinite || !y1.isFinite { continue }
            let width = xs[band + 1] - xs[band]
            let t = (x - xs[band]) / width
            let t2 = t * t
            let t3 = t2 * t
            curve[index] = (2 * t3 - 3 * t2 + 1) * y0 + (3 * t2 - 2 * t3) * y1
                + ((t3 - 2 * t2 + t) * slopes[band] + (t3 - t2) * slopes[band + 1]) * width
        }
        return curve
    }

    /// 帯域の値は、帯域に入る FFT ビンの電力の和なので、1 Hz あたりの密度より 10 log10(帯域幅) 大きい。
    /// その差（dB）を、サンプルレートごとに（カーネルの解析の形から）引く。ビンの無い帯域は NaN
    /// （tonalBalanceEqDensityOffsets、tonal_balance_eq.js:171-193）。
    static func densityOffsets(sampleRate: Double) -> [Double] {
        let exponent = (log2(0.085 * sampleRate) + 0.5).rounded(.down)
        let fftSize = pow(2, exponent < 6 ? 6 : (exponent > 16 ? 16 : exponent))
        let binHz = sampleRate / fftSize
        let binCount = fftSize / 2 + 1
        return bandCentres.map { centre in
            let halfWidth = 0.5 * 24.7 * (4.37 * centre / 1000 + 1)
            let begin = ((centre - halfWidth) / binHz).rounded(.up)
            let end = ((centre + halfWidth) / binHz).rounded(.up)
            let bins = (end < binCount ? end : binCount) - begin
            return bins > 0 ? 10 * log10(bins * binHz) : Double.nan
        }
    }

    // MARK: 描く曲線

    struct Curves {
        var target: [Double]
        var targetLow: [Double]
        var targetHigh: [Double]
        var measured: [Double]
        var withheldLow: [Double]
        var withheldHigh: [Double]
        var withheldEdge: [Double]
    }

    struct Display {
        var target: [Double]
        var targetLow: [Double]
        var targetHigh: [Double]
        var measured: [Double]
        var presence: [Double]
        var lift: [Double]
        var response: [Double]
        var curves: Curves
    }

    /// 1 回の読みから、描く曲線を作る（computeTonalBalanceEqView、tonal_balance_eq.js:196-292）。
    /// 密度（dB/Hz）で、目標の平均密度を 0 にそろえる。測った値は、補正の式と同じく
    /// 存在感と持続で重みを付けて目標に合わせる。`amount` は 0〜1。
    static func display(reading: Reading, range: Double, amount: Double) -> Display {
        let density = densityOffsets(sampleRate: reading.sampleRate)
        let used = hasTarget | hasLevel | inRange
        var referenceSum = 0.0, referenceCount = 0
        var presenceSum = 0.0, persistenceSum = 0.0
        for band in 0..<bands {
            if reading.bandFlags[band] & hasTarget != 0 && density[band].isFinite {
                referenceSum += reading.mu[band] - density[band]
                referenceCount += 1
            }
            if reading.bandFlags[band] & used == used {
                presenceSum += reading.presence[band]
                persistenceSum += reading.persistence[band]
            }
        }
        let reference = referenceCount > 0 ? referenceSum / Double(referenceCount) : 0
        let contentShare = persistenceSum > 0 ? presenceSum / persistenceSum : 0
        var weightSum = 0.0, offsetSum = 0.0
        for band in 0..<bands where reading.bandFlags[band] & used == used {
            let weight = persistenceSum > 0
                ? reading.presence[band] + (1 - contentShare) * reading.persistence[band] : 1
            weightSum += weight
            offsetSum += weight * (reading.mu[band] - reading.levelDb[band])
        }
        let aligned = weightSum > 0
        let offset = aligned ? offsetSum / weightSum : 0

        let blank = [Double](repeating: .nan, count: bands)
        var target = blank, targetLow = blank, targetHigh = blank
        var measured = blank, presence = blank, lift = blank
        for band in 0..<bands {
            let flags = reading.bandFlags[band]
            if flags & hasTarget != 0 {
                target[band] = reading.mu[band] - density[band] - reference
                targetLow[band] = target[band] - reading.sigma[band]
                targetHigh[band] = target[band] + reading.sigma[band]
            }
            if flags & hasLevel == 0 { continue }
            presence[band] = reading.presence[band]
            if !aligned { continue }
            measured[band] = reading.levelDb[band] + offset - density[band] - reference
            if flags & used != used { continue }
            var deficit = reading.mu[band] - reading.levelDb[band] - offset
            deficit = deficit > range ? range : (deficit < -range ? -range : deficit)
            lift[band] = amount * (1 - reading.presence[band]) * (deficit > 0 ? deficit : 0)
        }
        // 保留した持ち上げは、描いた（線形の）EQ の応答から、それに持ち上げを足した所まで。
        let liftCurve = interpolateBands(lift)
        let samples = liftCurve.count
        var withheldLow = [Double](repeating: .nan, count: samples)
        var withheldHigh = [Double](repeating: .nan, count: samples)
        var withheldEdge = [Double](repeating: .nan, count: samples)
        let response = reading.response
        for sample in 0..<samples where liftCurve[sample].isFinite {
            let position = (curveLogFreqs[sample] - gridLogMin) / gridLogSpan * Double(gridPoints - 1)
            let index = min(max(Int(position.rounded(.down)), 0), gridPoints - 2)
            let low = response[index] + (position - Double(index)) * (response[index + 1] - response[index])
            withheldLow[sample] = low
            withheldHigh[sample] = low + liftCurve[sample]
            if liftCurve[sample] > 0 { withheldEdge[sample] = withheldHigh[sample] }
        }
        let curves = Curves(target: interpolateBands(target), targetLow: interpolateBands(targetLow),
                            targetHigh: interpolateBands(targetHigh), measured: interpolateBands(measured),
                            withheldLow: withheldLow, withheldHigh: withheldHigh,
                            withheldEdge: withheldEdge)
        return Display(target: target, targetLow: targetLow, targetHigh: targetHigh, measured: measured,
                    presence: presence, lift: lift, response: response, curves: curves)
    }

    // MARK: Target adjust の応答

    struct AdjustBand: Equatable {
        var enabled: Bool
        /// 0 = pk、1 = ls、2 = hs。
        var type: Int
        var frequency: Double
        var gain: Double
        var q: Double
    }

    /// 1 本の応答（dB）。room_eq.js:680-750 の calculateBandResponse と同じ。
    /// 0.01 dB 未満は素通し。分母が 0 に近いと -∞（上流も -Infinity を返す）。
    static func bandResponseDB(frequency: Double, band: AdjustBand, sampleRate: Double) -> Double {
        let w0 = 2 * Double.pi * band.frequency / sampleRate
        let w = 2 * Double.pi * frequency / sampleRate
        let q = max(0.1, band.type != 0 ? min(band.q, 2) : band.q)
        let alpha = sin(w0) / (2 * q)
        let cosw0 = cos(w0)
        let amplitude = pow(10, band.gain / 40)
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0
        if abs(band.gain) < 0.01 {
            // 素通し。
        } else if band.type == 0 {
            b0 = 1 + alpha * amplitude
            b1 = -2 * cosw0
            b2 = 1 - alpha * amplitude
            a0 = 1 + alpha / amplitude
            a1 = -2 * cosw0
            a2 = 1 - alpha / amplitude
        } else {
            let shelfAlpha = 2 * amplitude.squareRoot() * alpha
            if band.type == 1 {
                b0 = amplitude * ((amplitude + 1) - (amplitude - 1) * cosw0 + shelfAlpha)
                b1 = 2 * amplitude * ((amplitude - 1) - (amplitude + 1) * cosw0)
                b2 = amplitude * ((amplitude + 1) - (amplitude - 1) * cosw0 - shelfAlpha)
                a0 = (amplitude + 1) + (amplitude - 1) * cosw0 + shelfAlpha
                a1 = -2 * ((amplitude - 1) + (amplitude + 1) * cosw0)
                a2 = (amplitude + 1) + (amplitude - 1) * cosw0 - shelfAlpha
            } else {
                b0 = amplitude * ((amplitude + 1) + (amplitude - 1) * cosw0 + shelfAlpha)
                b1 = -2 * amplitude * ((amplitude - 1) + (amplitude + 1) * cosw0)
                b2 = amplitude * ((amplitude + 1) + (amplitude - 1) * cosw0 - shelfAlpha)
                a0 = (amplitude + 1) - (amplitude - 1) * cosw0 + shelfAlpha
                a1 = 2 * ((amplitude - 1) - (amplitude + 1) * cosw0)
                a2 = (amplitude + 1) - (amplitude - 1) * cosw0 - shelfAlpha
            }
        }
        if abs(a0) <= 1e-8 { return 0 }
        let inverse = 1 / a0
        b0 *= inverse; b1 *= inverse; b2 *= inverse; a1 *= inverse; a2 *= inverse
        let cosw = cos(w), sinw = sin(w)
        let cos2w = 2 * cosw * cosw - 1
        let sin2w = 2 * sinw * cosw
        let numeratorReal = b0 + b1 * cosw + b2 * cos2w
        let numeratorImaginary = -b1 * sinw - b2 * sin2w
        let denominatorReal = 1 + a1 * cosw + a2 * cos2w
        let denominatorImaginary = -a1 * sinw - a2 * sin2w
        let denominator = denominatorReal * denominatorReal + denominatorImaginary * denominatorImaginary
        if denominator < 1e-18 { return -Double.infinity }
        let numerator = numeratorReal * numeratorReal + numeratorImaginary * numeratorImaginary
        return 20 * log10(max(1e-9, (numerator / denominator).squareRoot()))
    }

    /// 要求している Target adjust（dB）を adjustLogFreqs の点で。有効で 0.01 dB 以上の帯域の積
    /// （_adjustCurve、tonal_balance_eq.js:497-509）。
    static func adjustCurve(bands: [AdjustBand], sampleRate: Double) -> [Double] {
        let active = bands.filter { $0.enabled && abs($0.gain) >= 0.01 }
        return adjustLogFreqs.map { logFrequency in
            var total = 0.0
            let frequency = pow(10, logFrequency)
            for band in active { total += bandResponseDB(frequency: frequency, band: band, sampleRate: sampleRate) }
            return total
        }
    }

    // MARK: 縦軸

    /// 縦軸（dB）を 6 dB きざみで広げて、Target adjust の印と曲線、読みがあれば目標の帯・EQ の応答・
    /// 補正される帯の測定値を収める（_fitDbRange、tonal_balance_eq.js:511-545）。
    /// 縮むのは Reset と Target の変更のときだけ。
    static func fitDbRange(top inputTop: Double, bottom inputBottom: Double, view: Display?,
                           adjust: [Double], adjustBands: [AdjustBand]) -> (top: Double, bottom: Double) {
        var top = inputTop, bottom = inputBottom
        func fit(_ value: Double) {
            guard value.isFinite else { return }
            if value + 1.5 > top { top = 6 * ((value + 1.5) / 6).rounded(.up) }
            if value - 1.5 < bottom { bottom = 6 * ((value - 1.5) / 6).rounded(.down) }
        }
        for band in adjustBands where band.enabled { fit(band.gain) }
        adjust.forEach(fit)
        if let view {
            for band in 0..<Self.bands {
                fit(view.targetLow[band])
                fit(view.targetHigh[band])
                guard view.lift[band].isFinite else { continue }
                let floor = view.targetLow[band] - rangeMaximum
                let ceiling = view.targetHigh[band] + rangeMaximum
                let measured = view.measured[band]
                fit(measured < floor ? floor : (measured > ceiling ? ceiling : measured))
            }
            view.response.forEach(fit)
        }
        return (top, bottom)
    }
}
