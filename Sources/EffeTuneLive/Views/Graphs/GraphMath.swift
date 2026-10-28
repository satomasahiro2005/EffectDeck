//  GraphMath.swift
//  図の軸・位置の換算・値の書き方。
//
//  GraphCanvas.swiftから分けてあるのは、Foundationだけで試験のバンドルに入れるため。
//  GraphCanvasはSwiftUIとプレビュー音（ETPreviewTone_SetFrequency）に触る。
//  軸の取り方（周波数は対数、レベルは線形のdB）はGraphCanvas.swiftの頭を読むこと。

import Foundation
// iOSではCGRectの型だけFoundationから見え、init(x:y:width:height:)・minX・insetByはCoreGraphicsにある。
// 同じモジュールの別ファイルがSwiftUIやXCTestを読んでいるので今は建つが、それに頼らない。
// LinuxのFoundationは全部持っていてCoreGraphicsが無いので、ここは読まない。
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - 余白

/// 目盛りのラベルを置くための余白。
struct ETGraphInsets: Equatable {
    var leading: CGFloat
    var trailing: CGFloat
    var top: CGFloat
    var bottom: CGFloat

    init(leading: CGFloat = 26, trailing: CGFloat = 8, top: CGFloat = 6, bottom: CGFloat = 14) {
        self.leading = leading
        self.trailing = trailing
        self.top = top
        self.bottom = bottom
    }

    /// 左に dB、下に周波数を出す普通の形。
    static let standard = ETGraphInsets()
    /// 下だけラベルを出す形（メーターなど）。
    static let bottomOnly = ETGraphInsets(leading: 8, trailing: 8, top: 4, bottom: 14)
    /// ラベル無し。
    static let none = ETGraphInsets(leading: 2, trailing: 2, top: 2, bottom: 2)
}

// MARK: - 軸

enum ETAxisScale {
    case linear
    case logarithmic
}

struct ETAxisTick: Equatable {
    let value: Double
    /// nil なら線だけ引いて字は出さない。
    let label: String?
    /// 0 dB の線のように、他より濃く引きたいもの。
    let emphasized: Bool

    init(_ value: Double, _ label: String? = nil, emphasized: Bool = false) {
        self.value = value
        self.label = label
        self.emphasized = emphasized
    }
}

/// Equatable は GraphCanvas の格子の層が「前と同じ軸か」を比べるため。同じなら格子を描き直さない。
struct ETAxis: Equatable {
    var scale: ETAxisScale
    var lower: Double
    var upper: Double
    var ticks: [ETAxisTick]
    var isFrequency: Bool

    init(scale: ETAxisScale = .linear, lower: Double, upper: Double, ticks: [ETAxisTick] = [], isFrequency: Bool = false) {
        self.scale = scale
        self.lower = lower
        self.upper = upper
        self.ticks = ticks
        self.isFrequency = isFrequency
    }

    /// 0（下端・左端）から 1（上端・右端）へ。範囲の外もそのまま返す。
    /// web 版は PEQ の曲線を枠の外まで伸ばしているので、ここでも丸めない。
    func normalized(_ value: Double) -> Double {
        switch scale {
        case .linear:
            guard upper != lower else { return 0 }
            return (value - lower) / (upper - lower)
        case .logarithmic:
            let lo = max(lower, 1e-9)
            let hi = max(upper, lo * 1.000001)
            let v = max(value, 1e-9)
            return (log10(v) - log10(lo)) / (log10(hi) - log10(lo))
        }
    }

    func value(atNormalized t: Double) -> Double {
        switch scale {
        case .linear:
            return lower + t * (upper - lower)
        case .logarithmic:
            let lo = max(lower, 1e-9)
            let hi = max(upper, lo * 1.000001)
            return pow(10, log10(lo) + t * (log10(hi) - log10(lo)))
        }
    }

    func clamp(_ value: Double) -> Double {
        min(max(value, min(lower, upper)), max(lower, upper))
    }

    // MARK: 出来合いの軸

    /// 20Hz〜20kHz を対数で。線は 10 本、字は詰まらないよう 4 つだけ。
    static func frequency(_ lower: Double = 20, _ upper: Double = 20000,
                          labelsEverywhere: Bool = false) -> ETAxis {
        let decades: [Double] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000, 40000]
        let named: Set<Double> = [20, 100, 1000, 10000]
        let ticks = decades
            .filter { $0 >= lower && $0 <= upper }
            .map { hz -> ETAxisTick in
                let show = labelsEverywhere || named.contains(hz) || hz == upper
                return ETAxisTick(hz, show ? ETFormat.hzTick(hz) : nil)
            }
        return ETAxis(scale: .logarithmic, lower: lower, upper: upper, ticks: ticks, isFrequency: true)
    }

    /// dB を線形で。0 の線だけ濃くする。
    static func decibels(_ range: ClosedRange<Double>, step: Double = 6,
                         unit: Bool = false) -> ETAxis {
        var ticks: [ETAxisTick] = []
        if step > 0 {
            var v = (range.lowerBound / step).rounded(.up) * step
            while v <= range.upperBound + 0.0001 {
                let text = unit ? "\(Int(v.rounded()))dB" : "\(Int(v.rounded()))"
                ticks.append(ETAxisTick(v, text, emphasized: abs(v) < 0.0001))
                v += step
            }
        }
        return ETAxis(scale: .linear, lower: range.lowerBound, upper: range.upperBound, ticks: ticks)
    }

    /// 目盛りを自分で並べる線形の軸。
    static func linear(_ range: ClosedRange<Double>, ticks: [Double] = [],
                       label: (Double) -> String = { ETFormat.number($0) }) -> ETAxis {
        ETAxis(scale: .linear, lower: range.lowerBound, upper: range.upperBound,
               ticks: ticks.map { ETAxisTick($0, label($0)) })
    }

    /// 線も字も無い軸。行を並べるだけのとき（メーターの縦）に使う。
    static func blank(_ range: ClosedRange<Double> = 0...1) -> ETAxis {
        ETAxis(scale: .linear, lower: range.lowerBound, upper: range.upperBound)
    }
}

// MARK: - 位置の換算

/// 図の中の座標と値を行き来する。Canvas の中でも外（指の位置）でも同じ式を使う。
struct ETPlot {
    let rect: CGRect
    let xAxis: ETAxis
    let yAxis: ETAxis

    init(size: CGSize, x: ETAxis, y: ETAxis, insets: ETGraphInsets) {
        let w = max(1, size.width - insets.leading - insets.trailing)
        let h = max(1, size.height - insets.top - insets.bottom)
        rect = CGRect(x: insets.leading, y: insets.top, width: w, height: h)
        xAxis = x
        yAxis = y
    }

    func x(_ value: Double) -> CGFloat {
        rect.minX + CGFloat(xAxis.normalized(value)) * rect.width
    }

    func y(_ value: Double) -> CGFloat {
        rect.maxY - CGFloat(yAxis.normalized(value)) * rect.height
    }

    func point(_ xValue: Double, _ yValue: Double) -> CGPoint {
        CGPoint(x: x(xValue), y: y(yValue))
    }

    /// 枠からはみ出す点を縁に留めた位置。指で掴む印を描くときに使う。
    func clampedPoint(_ xValue: Double, _ yValue: Double) -> CGPoint {
        CGPoint(x: min(max(x(xValue), rect.minX), rect.maxX),
                y: min(max(y(yValue), rect.minY), rect.maxY))
    }

    func xValue(at px: CGFloat) -> Double {
        xAxis.value(atNormalized: Double((px - rect.minX) / rect.width))
    }

    func yValue(at py: CGFloat) -> Double {
        yAxis.value(atNormalized: Double((rect.maxY - py) / rect.height))
    }

    /// 指の位置から、軸の範囲に収めた値を取る。
    func values(at location: CGPoint) -> (x: Double, y: Double) {
        (xAxis.clamp(xValue(at: location.x)), yAxis.clamp(yValue(at: location.y)))
    }

    func contains(_ location: CGPoint) -> Bool {
        rect.insetBy(dx: -12, dy: -12).contains(location)
    }
}

// MARK: - 値の書き方

enum ETFormat {

    /// 目盛りの字。1000 以上は k に畳む。
    static func hzTick(_ hz: Double) -> String {
        hz >= 1000 ? "\(Int((hz / 1000).rounded()))k" : "\(Int(hz.rounded()))"
    }

    /// 上に出す周波数。掴んでいる間はこちらを使う。
    static func hz(_ hz: Double) -> String {
        if hz >= 10000 { return String(format: "%.1f kHz", hz / 1000) }
        if hz >= 1000  { return String(format: "%.2f kHz", hz / 1000) }
        if hz >= 100   { return String(format: "%.0f Hz", hz) }
        return String(format: "%.1f Hz", hz)
    }

    /// dB。符号を必ず出す（+4.5 / -12.0）。
    static func gain(_ db: Double, decimals: Int = 1) -> String {
        String(format: "%+.\(decimals)f dB", db)
    }

    /// dB。符号は負のときだけ（レベル表示向け）。
    static func db(_ db: Double, decimals: Int = 1) -> String {
        if !db.isFinite { return "-inf dB" }
        return String(format: "%.\(decimals)f dB", db)
    }

    static func number(_ v: Double) -> String {
        abs(v) >= 100 ? String(format: "%.0f", v)
            : abs(v) >= 10 ? String(format: "%.1f", v)
            : String(format: "%.2f", v)
    }
}

/// 振幅・電力から dB へ。テレメトリは線形で来るものが多い
/// （例: dsp/plugins/analyzer/level_meter/kernel.cpp:168 の peak と rms は線形の振幅）。
enum ETdB {
    static let floor: Double = -144

    static func fromAmplitude(_ amplitude: Double, floor: Double = ETdB.floor) -> Double {
        guard amplitude > 0, amplitude.isFinite else { return floor }
        return max(floor, 20 * log10(amplitude))
    }

    static func fromAmplitude(_ amplitude: Float, floor: Double = ETdB.floor) -> Double {
        fromAmplitude(Double(amplitude), floor: floor)
    }

    static func fromPower(_ power: Double, floor: Double = ETdB.floor) -> Double {
        guard power > 0, power.isFinite else { return floor }
        return max(floor, 10 * log10(power))
    }

    static func amplitude(_ db: Double) -> Double {
        pow(10, db / 20)
    }

    /// NaN や -inf を軸の下端に落とす。描く直前に通す。
    static func finite(_ db: Double, floor: Double) -> Double {
        db.isFinite ? max(db, floor) : floor
    }
}
