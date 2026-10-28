//  RoomEQResponseGraph.swift
//  Room EQ の応答の図（RoomEQView の下に置く）。
//
//  上流は Graph の選択肢で 5 つの図を切り替える（plugins/eq/room_eq.js:2419-2628, :2773-2817）:
//      Frequency           測定・補正・補正後の周波数特性（:709-823 の updateResponse）
//      Phase               補正の前後の位相（:2944-2976）
//      Min Group Delay     最小位相の群遅延の前後（:3003-3044）
//      Excess Group Delay  過剰群遅延の前後（同上。縦は ±100ms 固定）
//      Impulse             補正の前後の時間波形（:3105-3190）
//  材料は設計が一緒に作る previews（DSP/Designers/RoomEQPreview.swift）。
//  軸・目盛り・色の割り当ては上流の図と room_eq.css:282-409 に合わせてある。
//
//  上流の図はマウスを載せると値を読める（:2711-2755）が、ここでは付けていない。
//  指で触ると一覧のスクロールと取り合うので、読み値の行は使わず見出しに軸の名前を出す。

import SwiftUI

/// Graph の選択肢（room_eq.js:2423-2442）。rawValue は上流の値そのもの。
/// 上流はこれを getParameters() に書かない（:1067-1112）ので、鎖には残さない。
enum RoomEQResponseView: String, CaseIterable, Identifiable {
    case frequency
    case phase
    case minimumGroupDelay
    case excessGroupDelay
    case impulse

    var id: String { rawValue }

    var label: String {
        switch self {
        case .frequency: return "Frequency"
        case .phase: return "Phase"
        case .minimumGroupDelay: return "Min Group Delay"
        case .excessGroupDelay: return "Excess Group Delay"
        case .impulse: return "Impulse"
        }
    }

    /// 軸の名前（room_eq.js:2797-2803）。縦 over 横 の形で見出しに出す
    /// （BassManagementView の見出しと同じ書き方）。
    var caption: String {
        switch self {
        case .frequency: return "Level (dB) over Frequency (Hz)"
        case .phase: return "Phase (°) over Frequency (Hz)"
        case .minimumGroupDelay, .excessGroupDelay: return "Delay (ms) over Frequency (Hz)"
        case .impulse: return "Amplitude over Time (ms)"
        }
    }
}

struct RoomEQResponseGraph: View {

    let view: RoomEQResponseView
    let preview: RoomEQPreview
    let config: RoomEQConfig

    /// 描く線 1 本。
    private struct Line {
        enum Content {
            /// 値の並び。有限でない所で切れる。
            case points([(x: Double, y: Double)])
            /// 時間波形。横は startMs〜endMs に並べ、縦は peak で割る。
            case waveform([Float], startMs: Double, endMs: Double, peak: Double)
        }
        let label: String
        let style: AnyShapeStyle
        let content: Content
        /// 隣との差がこれを越えたら繋がない（位相の ±180 の折り返し。room_eq.js:2884, :2892）。0 なら見ない。
        var breakStep: Double = 0
    }

    private struct Figure {
        var x: ETAxis
        var y: ETAxis
        var insets: ETGraphInsets = .standard
        var lines: [Line] = []
        /// 補正する帯域の端（room_eq.js:809-822）。周波数特性の図だけ。
        var boundaries: [Double] = []
    }

    var body: some View {
        let layout = figure
        VStack(alignment: .leading, spacing: 6) {
            GraphCanvas(x: layout.x,
                        y: layout.y,
                        height: ETGraphMetrics.height,
                        insets: layout.insets,
                        caption: view.caption,
                        clipsContent: true,
                        draw: { context, plot in
                            for hz in layout.boundaries {
                                var line = Path()
                                line.move(to: CGPoint(x: plot.x(hz), y: plot.rect.minY))
                                line.addLine(to: CGPoint(x: plot.x(hz), y: plot.rect.maxY))
                                context.stroke(line, with: .style(.primary),
                                               style: StrokeStyle(lineWidth: 1, lineCap: .round,
                                                                  dash: [2, 3]))
                            }
                            for line in layout.lines {
                                context.stroke(path(line, in: plot), with: .style(line.style),
                                               style: StrokeStyle(lineWidth: 1.5, lineCap: .round,
                                                                  lineJoin: .round))
                            }
                        })
            legend(layout.lines)
        }
    }

    // MARK: 凡例

    /// 上流の凡例（room_eq.js:2518-2614）。その図に出る線だけ。
    private func legend(_ lines: [Line]) -> some View {
        HStack(spacing: 12) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(spacing: 4) {
                    Capsule()
                        .fill(line.style)
                        .frame(width: 14, height: 2)
                    Text(line.label)
                        .etFont(size: 10)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: 図ごとの組み立て

    /// 色は room_eq.css:282-409 の割り当て。
    ///   Before   --et-graph-trace-secondary（0.7）。Impulse では --et-graph-tone-50
    ///   After    Frequency は --et-text-primary、ほかは --et-graph-trace
    ///   Room EQ  --et-success（0.65）
    ///   Total EQ --et-graph-trace
    private static var before: AnyShapeStyle { AnyShapeStyle(HierarchicalShapeStyle.secondary.opacity(0.7)) }
    private static var trace: AnyShapeStyle { AnyShapeStyle(.tint) }

    private var figure: Figure {
        switch view {
        case .frequency: return frequencyFigure
        case .phase: return phaseFigure
        case .minimumGroupDelay, .excessGroupDelay: return groupDelayFigure
        case .impulse: return impulseFigure
        }
    }

    /// 横軸は上流の freqToX と同じ 10Hz〜40kHz の対数（room_eq.js:535-539）。
    /// 線は ROOM_EQ_GRAPH_FREQUENCY_TICKS（:11-12）、字は詰まらないよう 4 つだけ。
    private static let frequencyAxis: ETAxis = {
        let labeled: Set<Double> = [20, 100, 1000, 10000]
        let ticks = [20.0, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000].map { hz in
            ETAxisTick(hz, labeled.contains(hz) ? ETFormat.hzTick(hz) : nil)
        }
        return ETAxis(scale: .logarithmic, lower: 10, upper: 40000, ticks: ticks)
    }()

    /// Frequency。room_eq.js:709-823。縦は ±20dB（:548-550 の gainToY）、線は 6dB ごと（:212）。
    /// 測定と補正後は基準レベルを 0dB に合わせて描く（:782-806 の normalizationGainDb）。
    private var frequencyFigure: Figure {
        var layout = Figure(x: Self.frequencyAxis, y: .decibels(-20...20, step: 6))
        let p = preview
        let count = p.frequencies.count
        guard count > 1,
              p.measuredDb.count == count,
              p.baseCorrectionDb.count == count,
              p.predictedBaseDb.count == count,
              p.equalizerDb.count == count else { return layout }
        let level = p.referenceLevelDb.isFinite ? p.referenceLevelDb : 0
        let total = (0..<count).map { p.baseCorrectionDb[$0] + p.equalizerDb[$0] }
        let after = (0..<count).map { p.predictedBaseDb[$0] - level + p.equalizerDb[$0] }
        // 上流と同じ重ね順（:786-806）。後に描いたものが上に来る。
        layout.lines = [
            Line(label: "Before", style: Self.before,
                 content: .points(extended(p.measuredDb.map { $0 - level }))),
            Line(label: "Room EQ", style: AnyShapeStyle(Color.green.opacity(0.65)),
                 content: .points(extended(p.baseCorrectionDb))),
            Line(label: "Total EQ", style: Self.trace, content: .points(extended(total))),
            Line(label: "After", style: AnyShapeStyle(.primary), content: .points(extended(after))),
        ]
        layout.boundaries = [config.lowFrequency, config.highFrequency].filter(\.isFinite)
        return layout
    }

    /// 上流は 10Hz〜40kHz の格子へ補間し、設計の格子の外は端の値で延ばす（room_eq.js:737-752）。
    /// 対数の補間なので、設計の格子の点をそのまま結び、両端に延ばした点を足せば同じ線になる。
    private func extended(_ values: [Double]) -> [(x: Double, y: Double)] {
        let f = preview.frequencies
        guard f.count > 1, values.count == f.count, let first = values.first, let last = values.last
        else { return [] }
        var points: [(x: Double, y: Double)] = []
        points.reserveCapacity(f.count + 2)
        if f[0] > 10 { points.append((x: 10, y: first)) }
        for index in 0..<f.count { points.append((x: f[index], y: values[index])) }
        if f[f.count - 1] < 40000 { points.append((x: 40000, y: last)) }
        return points
    }

    /// Phase。room_eq.js:2944-2976。縦は ±180 度、線は 90 度ごと（:2949-2950）。
    private var phaseFigure: Figure {
        let ticks = [180.0, 90, 0, -90, -180].map {
            ETAxisTick($0, String(Int($0)), emphasized: $0 == 0)
        }
        var layout = Figure(x: Self.frequencyAxis,
                            y: ETAxis(scale: .linear, lower: -180, upper: 180, ticks: ticks))
        guard let phase = preview.phase,
              let before = curve(phase.before), let after = curve(phase.after) else { return layout }
        layout.lines = [
            Line(label: "Before", style: Self.before, content: .points(before), breakStep: 180),
            Line(label: "After", style: Self.trace, content: .points(after), breakStep: 180),
        ]
        return layout
    }

    /// Min / Excess Group Delay。room_eq.js:3003-3044。
    /// 縦は Excess なら ±100ms、Min は曲線に合わせた切りのいい幅（:2980-2997 の _groupDelayLimit）。
    private var groupDelayFigure: Figure {
        let curves = view == .minimumGroupDelay ? preview.minimumGroupDelay : preview.excessGroupDelay
        let before = curves.flatMap { curve($0.before) }
        let after = curves.flatMap { curve($0.after) }
        let hasPreview = before != nil && after != nil
        let limit: Double
        if view == .excessGroupDelay {
            limit = Self.excessGroupDelayLimitMs
        } else if hasPreview, let curves {
            limit = Self.groupDelayLimit([curves.before, curves.after])
        } else {
            limit = Self.minimumGroupDelayLimitMs
        }
        let ticks = [limit, limit / 2, 0, -limit / 2, -limit].map {
            ETAxisTick($0, Self.delayTick($0), emphasized: $0 == 0)
        }
        var layout = Figure(x: Self.frequencyAxis,
                            y: ETAxis(scale: .linear, lower: -limit, upper: limit, ticks: ticks),
                            insets: ETGraphInsets(leading: 32))
        guard let before, let after else { return layout }
        layout.lines = [
            Line(label: "Before", style: Self.before, content: .points(before)),
            Line(label: "After", style: Self.trace, content: .points(after)),
        ]
        return layout
    }

    /// room_eq.js:9-10。
    private static let minimumGroupDelayLimitMs = 1.0
    private static let excessGroupDelayLimitMs = 100.0

    /// room_eq.js:2980-2997 の _groupDelayLimit。有限な値の最大の 1.05 倍を 1・2・5 の刻みへ切り上げる。
    static func groupDelayLimit(_ curves: [[Double]]) -> Double {
        var maximum = 0.0
        for values in curves {
            for value in values where value.isFinite { maximum = max(maximum, abs(value)) }
        }
        if maximum <= minimumGroupDelayLimitMs { return minimumGroupDelayLimitMs }
        let padded = maximum * 1.05
        let power = pow(10, floor(log10(padded)))
        let normalized = padded / power
        let step: Double = normalized <= 1 ? 1 : normalized <= 2 ? 2 : normalized <= 5 ? 5 : 10
        return step * power
    }

    /// `${Number(value.toFixed(1))}`（room_eq.js:3023）。単位は見出しに出す。
    private static func delayTick(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.1f", rounded)
    }

    /// 周波数の格子と組にする。長さが合わなければ描かない（上流の hasPreview）。
    private func curve(_ values: [Double]) -> [(x: Double, y: Double)]? {
        let f = preview.frequencies
        guard f.count > 1, values.count == f.count else { return nil }
        return (0..<f.count).map { (x: f[$0], y: values[$0]) }
    }

    /// Impulse。room_eq.js:3105-3190。横は startMs〜durationMs の ms、縦は前後の大きい方の山で割る。
    private var impulseFigure: Figure {
        let impulse = preview.impulse
        // 上流は材料が無いとき -2ms〜max(5, dw) にする（:3120-3121）。dw は directWindowMs。
        let start = impulse?.startMs ?? -2
        let end = impulse.map { $0.durationMs > 0 ? $0.durationMs : max(5, config.directWindowMs) }
            ?? max(5, config.directWindowMs)
        let (interval, times) = Self.impulseTimeTicks(start: start, end: end)
        let digits = interval < 1 ? 1 : 0
        let xTicks = times.map { ETAxisTick($0, String(format: "%.\(digits)f", $0)) }
        // :3145-3159。0.5 / 0 / -0.5 の 3 本。
        let yTicks = [0.5, 0, -0.5].map { ETAxisTick($0, $0 == 0 ? "0" : String($0), emphasized: $0 == 0) }
        var layout = Figure(x: ETAxis(scale: .linear, lower: start, upper: end, ticks: xTicks),
                            y: ETAxis(scale: .linear, lower: -1, upper: 1, ticks: yTicks))
        guard let impulse, impulse.before.count > 1, impulse.before.count == impulse.after.count
        else { return layout }
        var peak: Float = 0
        for value in impulse.before { peak = max(peak, abs(value)) }
        for value in impulse.after { peak = max(peak, abs(value)) }
        let scale = peak > 1e-12 ? Double(peak) : 1
        layout.lines = [
            Line(label: "Before", style: AnyShapeStyle(.secondary),
                 content: .waveform(impulse.before, startMs: start, endMs: end, peak: scale)),
            Line(label: "After", style: Self.trace,
                 content: .waveform(impulse.after, startMs: start, endMs: end, peak: scale)),
        ]
        return layout
    }

    /// room_eq.js:3092-3103 の _impulseTimeTicks。10 本以下になる一番細かい刻み。
    static func impulseTimeTicks(start: Double, end: Double) -> (interval: Double, ticks: [Double]) {
        let span = end - start
        let intervals = [0.5, 1, 5, 10]
        let interval = intervals.first { span / $0 <= 10 } ?? intervals[intervals.count - 1]
        var ticks: [Double] = []
        var index = Int(floor(start / interval)) + 1
        while Double(index) * interval < end {
            ticks.append(Double(index) * interval)
            index += 1
        }
        return (interval, ticks)
    }

    // MARK: 線

    private func path(_ line: Line, in plot: ETPlot) -> Path {
        switch line.content {
        case .points(let points):
            var path = Path()
            var previous: Double?
            for point in points {
                guard point.x.isFinite, point.y.isFinite else {
                    previous = nil
                    continue
                }
                let at = plot.point(point.x, point.y)
                if let last = previous, !(line.breakStep > 0 && abs(point.y - last) > line.breakStep) {
                    path.addLine(to: at)
                } else {
                    path.move(to: at)
                }
                previous = point.y
            }
            return path
        case .waveform(let samples, let start, let end, let peak):
            return waveformPath(samples, start: start, end: end, peak: peak, in: plot)
        }
    }

    /// room_eq.js:3046-3090 の _waveformPath。点が画面の列の 2 倍を越えたら、列ごとに
    /// 最小と最大を出てきた順に結ぶ（山を落とさずに間引く）。
    private func waveformPath(_ samples: [Float], start: Double, end: Double, peak: Double,
                              in plot: ETPlot) -> Path {
        var path = Path()
        guard samples.count > 0, peak > 0 else { return path }
        let columns = max(1, Int(plot.rect.width.rounded(.down)))
        func time(_ position: Double) -> Double { start + position * (end - start) }
        func add(_ t: Double, _ value: Float) {
            let at = plot.point(t, Double(value) / peak)
            if path.isEmpty { path.move(to: at) } else { path.addLine(to: at) }
        }
        if samples.count <= columns * 2 {
            for index in 0..<samples.count {
                let position = samples.count == 1 ? 0 : Double(index) / Double(samples.count - 1)
                add(time(position), samples[index])
            }
            return path
        }
        for column in 0..<columns {
            let first = column * samples.count / columns
            let last = max(first + 1, (column + 1) * samples.count / columns)
            var minimum = samples[first]
            var maximum = samples[first]
            var minimumIndex = first
            var maximumIndex = first
            if first + 1 < last {
                for index in (first + 1)..<last {
                    let value = samples[index]
                    if value < minimum { minimum = value; minimumIndex = index }
                    if value > maximum { maximum = value; maximumIndex = index }
                }
            }
            let position = columns == 1 ? 0 : Double(column) / Double(columns - 1)
            let ordered = minimumIndex < maximumIndex ? [minimum, maximum] : [maximum, minimum]
            for value in ordered { add(time(position), value) }
        }
        return path
    }
}
