//  GraphCanvas.swift
//  図の土台。目盛り・格子・軸のラベルだけを引き受けて、中身は呼ぶ側に描かせる。
//
//  軸の取り方は EffeTune の web 版に合わせてある。
//    周波数は対数（plugins/eq/five_band_peq.js:716 freqToX）
//    レベルは線形の dB（同 718 gainToY）
//    スペクトラムの表示範囲 20Hz〜40kHz（plugins/analyzer/spectrum_analyzer.js:9-10）
//
//  色は決めない。.tint / .secondary / .quaternary だけを使う。
//  テーマを移すときは ETGraphShading の 4 行を差し替えれば済む。
//
//  使う側:
//      GraphCanvas(x: .frequency(), y: .decibels(-24...24, step: 6),
//                  readout: readoutItems) { ctx, plot in
//          ctx.stroke(path(in: plot), with: ETGraphShading.curve, lineWidth: 2)
//      }

import SwiftUI
import Foundation

// MARK: - 寸法

enum ETGraphMetrics {
    /// 図の高さの目安。iPhone の幅（390pt）で 140〜200pt に収める。
    static let height: CGFloat = 170
    static let compactHeight: CGFloat = 140
    /// 上に出す値の行。掴んでいる間だけ字が入るが、高さは常に取っておく（図が跳ねないように）。
    static let readoutHeight: CGFloat = 17
    static let labelSize: CGFloat = 9
    static let readoutSize: CGFloat = 11
}

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

/// 描くときの塗り。ここだけ見れば配色が分かるようにしておく。
enum ETGraphShading {
    static var grid: GraphicsContext.Shading { .style(.quaternary) }
    static var axis: GraphicsContext.Shading { .style(.tertiary) }
    static var curve: GraphicsContext.Shading { .style(.tint) }
    static var muted: GraphicsContext.Shading { .style(.secondary) }
    /// 図に重ねるスペクトラムの線。上流の --et-graph-overlay-after は
    /// アクセント色の 55%（effetune-theme.css:95）。canvas 側の 0.85
    /// （spectrum-overlay.css:16）は描く側が context.opacity で掛ける。
    static var overlay: GraphicsContext.Shading { .style(AnyShapeStyle(.tint).opacity(0.55)) }
}

// MARK: - 軸

enum ETAxisScale {
    case linear
    case logarithmic
}

struct ETAxisTick {
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

struct ETAxis {
    var scale: ETAxisScale
    var lower: Double
    var upper: Double
    var ticks: [ETAxisTick]

    init(scale: ETAxisScale = .linear, lower: Double, upper: Double, ticks: [ETAxisTick] = []) {
        self.scale = scale
        self.lower = lower
        self.upper = upper
        self.ticks = ticks
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
        return ETAxis(scale: .logarithmic, lower: lower, upper: upper, ticks: ticks)
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

// MARK: - 上に出す値

/// 掴んでいる値を図の外に出すための 1 つぶん。指の下は見えないので、ここに出す。
struct ETReadoutItem: Identifiable, Equatable {
    let label: String
    let value: String

    var id: String { label + "\u{1}" + value }

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

// MARK: - 土台

struct GraphCanvas<Overlay: View>: View {

    var x: ETAxis
    var y: ETAxis
    var height: CGFloat

    /// 畳んだカードから渡る高さの上限。nil なら height をそのまま使う。
    @Environment(\.etGraphMaxHeight) private var maxHeight
    var insets: ETGraphInsets
    /// 掴んでいる値。空なら caption を出す。
    var readout: [ETReadoutItem]
    var caption: String?
    /// 読み値の行の**右端**に出す札。印を出したいときだけ。
    var badge: String?
    /// 中身を枠で切るか。PEQ の曲線のように外へ出したいものは false。
    var clipsContent: Bool
    var draw: (inout GraphicsContext, ETPlot) -> Void
    var overlay: (ETPlot) -> Overlay

    init(x: ETAxis,
         y: ETAxis,
         height: CGFloat = ETGraphMetrics.height,
         insets: ETGraphInsets = .standard,
         readout: [ETReadoutItem] = [],
         caption: String? = nil,
         badge: String? = nil,
         clipsContent: Bool = true,
         draw: @escaping (inout GraphicsContext, ETPlot) -> Void,
         @ViewBuilder overlay: @escaping (ETPlot) -> Overlay) {
        self.x = x
        self.y = y
        self.height = height
        self.insets = insets
        self.readout = readout
        self.caption = caption
        self.badge = badge
        self.clipsContent = clipsContent
        self.draw = draw
        self.overlay = overlay
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            GeometryReader { geo in
                ZStack {
                    Canvas { context, size in
                        let plot = ETPlot(size: size, x: x, y: y, insets: insets)
                        Self.drawGrid(&context, plot)
                        if clipsContent {
                            context.drawLayer { layer in
                                layer.clip(to: Path(plot.rect.insetBy(dx: -0.5, dy: -0.5)))
                                draw(&layer, plot)
                            }
                        } else {
                            draw(&context, plot)
                        }
                    }
                    overlay(ETPlot(size: geo.size, x: x, y: y, insets: insets))
                }
            }
            .frame(height: min(height, maxHeight ?? height))
        }
    }

    /// 値の行。掴んでいないときは見出しを出す。高さは変えない。
    private var header: some View {
        HStack(spacing: 10) {
            if readout.isEmpty {
                if let caption {
                    Text(caption)
                        .font(.system(size: ETGraphMetrics.readoutSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                ForEach(readout) { item in
                    HStack(spacing: 3) {
                        if !item.label.isEmpty {
                            Text(item.label)
                                .font(.system(size: 9, weight: .semibold))
                                .tracking(0.4)
                                .foregroundStyle(.secondary)
                        }
                        Text(item.value)
                            .font(.system(size: ETGraphMetrics.readoutSize, weight: .medium,
                                          design: .monospaced))
                    }
                }
            }
            Spacer(minLength: 0)
            // 右端の札。行の高さは下で固定してあるので、出ても位置は動かない。
            if let badge {
                Text(badge)
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(0.5)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.tint, in: .capsule)
                    // 行の高さは下の frame が決めているので、
                    // 札が大きくても位置は動かない。
                    .fixedSize()
            }
        }
        .frame(height: ETGraphMetrics.readoutHeight, alignment: .leading)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    // MARK: 格子

    static func drawGrid(_ context: inout GraphicsContext, _ plot: ETPlot) {
        let rect = plot.rect

        // 縦線と、その下の字。
        for tick in plot.xAxis.ticks {
            let px = plot.x(tick.value)
            guard px >= rect.minX - 0.5, px <= rect.maxX + 0.5 else { continue }
            var line = Path()
            line.move(to: CGPoint(x: px, y: rect.minY))
            line.addLine(to: CGPoint(x: px, y: rect.maxY))
            context.stroke(line, with: tick.emphasized ? ETGraphShading.axis : ETGraphShading.grid,
                           lineWidth: tick.emphasized ? 1 : 0.5)
            if let label = tick.label {
                context.draw(Self.tickText(label),
                             at: CGPoint(x: px, y: rect.maxY + 7), anchor: .center)
            }
        }

        // 横線と、その左の字。
        for tick in plot.yAxis.ticks {
            let py = plot.y(tick.value)
            guard py >= rect.minY - 0.5, py <= rect.maxY + 0.5 else { continue }
            var line = Path()
            line.move(to: CGPoint(x: rect.minX, y: py))
            line.addLine(to: CGPoint(x: rect.maxX, y: py))
            context.stroke(line, with: tick.emphasized ? ETGraphShading.axis : ETGraphShading.grid,
                           lineWidth: tick.emphasized ? 1 : 0.5)
            if let label = tick.label {
                context.draw(Self.tickText(label),
                             at: CGPoint(x: rect.minX - 3, y: py), anchor: .trailing)
            }
        }

        context.stroke(Path(rect), with: ETGraphShading.grid, lineWidth: 1)
    }

    private static func tickText(_ s: String) -> Text {
        Text(s)
            .font(.system(size: ETGraphMetrics.labelSize, design: .monospaced))
            .foregroundStyle(.secondary)
    }
}

extension GraphCanvas where Overlay == EmptyView {
    init(x: ETAxis,
         y: ETAxis,
         height: CGFloat = ETGraphMetrics.height,
         insets: ETGraphInsets = .standard,
         readout: [ETReadoutItem] = [],
         caption: String? = nil,
         badge: String? = nil,
         clipsContent: Bool = true,
         draw: @escaping (inout GraphicsContext, ETPlot) -> Void) {
        self.init(x: x, y: y, height: height, insets: insets, readout: readout,
                  caption: caption, badge: badge, clipsContent: clipsContent, draw: draw,
                  overlay: { _ in EmptyView() })
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
