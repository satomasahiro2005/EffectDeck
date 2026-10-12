//  IRReverbDecayGraph.swift
//  IR Reverb の EDC（エネルギー減衰）グラフ。上流の _drawEdcGraph（ir_reverb.js:1787-1953）を
//  GraphCanvas の上に写したもの。数字の計算は DSP/IRAnalysis.swift（Linux のテストが上流の答えと照合する）、
//  置き場は DSP/IRGraphStore.swift。ここは描くところだけ。
//
//  --- 何を描くか（上流のまま） ---
//  縦は 0 から -90 dB の線形で、0 / -30 / -60 / -90 に横線。横は秒（0 から durationSeconds）。
//  縦の格子は無く、1 秒ごとの目盛りだけを枠の下に出し、右下に「Time」。
//    塗り     Current の包絡（ピークで割った dB）。不透明度 0.18
//    点線     Original の EDC（decay・trim の前）。幅 2、[5,5]
//    実線     Current の EDC（カーネルへ送った面）。幅 2
//    縦線     onset / cut / pre-delay / trim / RT60。字は上の 3 段へ、描いた順に回して置く
//  pd は pre-delay の線と横軸の長さにだけ効き、解析し直さない。dc の入り切りは cut の線に即効く
//  （曲線のほうは下ごしらえをやり直して資産が届いてから変わる。上流も同じ）。
//  IR が無いときは枠だけ（上流も canvas を消して何も描かない。説明文は足さない）。
//
//  --- 色（上流 → GraphCanvas の語彙） ---
//    graph-trace            → .tint
//    graph-trace-tertiary   → .secondary   （文字色の 46%。.tertiary は約 30% で点線が薄すぎるので替えた）
//    text-primary           → .primary
//    graph-marker           → Color.red    （上流の既定テーマは危険色 #ff3333）
//    graph-label / graph-grid → GraphCanvas の目盛りと格子
//  **graph-bg-deep の黒塗りはしない。**ほかの GraphCanvas の図と同じく背景は透明で、枠は GraphCanvas が引く。
//  字は 11/12px の Arial ではなく GraphCanvas の目盛りと同じ 9pt。段の幅もそれに合わせた（上 45pt）。
//
//  --- 触ったときの値 ---
//  上流は指（カーソル）の位置の Original と Current を GraphReadout で出す（:1955-1983, :2085-2098）。
//  ほかの図と同じく、触っている間だけ上の行に出し、図の中に縦線と点を引く。

import SwiftUI

struct IRReverbDecayGraph: View {

    let nodeID: UUID
    /// Pre Delay（ms）。生きた値。解析には入らない。
    let preDelayMs: Double
    /// Direct Cut の生きた値。cut の線にだけ効く。
    let directCut: Bool

    @ObservedObject private var store = ETIRGraphStore.shared
    /// 指で触っている時刻（秒）。
    @State private var probe: Double?

    /// 上流の labelTop / labelLineHeight / 余白（:1799-1805）を、9pt の字に合わせたもの。
    private static let labelTop: CGFloat = 5
    private static let labelLine: CGFloat = ETGraphMetrics.labelSize + 3
    private static let insets = ETGraphInsets(
        leading: 26, trailing: 8,
        top: labelTop + CGFloat(ETIRAnalysis.markerLabelRows) * labelLine + 4,
        bottom: 18)

    private static let decibelRange: ClosedRange<Double> = -90...0

    var body: some View {
        let graph = store.graphs[nodeID]
        let layout = graph?.layout(preDelayMs: preDelayMs, directCut: directCut)
        let probeValues = probe.flatMap { seconds in graph.map { (seconds, $0.readout(seconds: seconds)) } }

        return GraphCanvas(
            x: Self.timeAxis(layout),
            y: Self.decibelAxis(graph != nil),
            height: ETGraphMetrics.height,
            insets: Self.insets,
            readout: Self.readout(probeValues),
            clipsContent: false,
            draw: { context, plot in
                guard let graph, let layout else { return }
                Self.draw(&context, plot, graph: graph, layout: layout, probe: probeValues)
            },
            overlay: { plot in
                if let layout {
                    // 動かすものが無いので、一覧の縦スクロールと同時に効かせる（EarphoneCableSimView と同じ）。
                    Color.clear
                        .contentShape(Rectangle())
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { touch in
                                    probe = plot.xAxis.clamp(plot.xValue(at: touch.location.x))
                                }
                                .onEnded { _ in probe = nil })
                }
            })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Impulse response energy decay graph")
    }

    // MARK: 軸

    /// 横は秒。1 秒ごとの目盛りは縦線でなく下の短い印なので、GraphCanvas の目盛りは使わず自分で描く。
    private static func timeAxis(_ layout: ETIRGraphLayout?) -> ETAxis {
        guard let layout else { return .blank() }
        return ETAxis(scale: .linear, lower: 0, upper: layout.duration)
    }

    /// 縦は 0 から -90 dB の線形。0 / -30 / -60 / -90 に横線と字。図が無いときは線も字も無い。
    private static func decibelAxis(_ hasGraph: Bool) -> ETAxis {
        guard hasGraph else { return .blank(decibelRange) }
        return ETAxis(scale: .linear, lower: decibelRange.lowerBound, upper: decibelRange.upperBound,
                      ticks: [0, -30, -60, -90].map { ETAxisTick(Double($0), "\($0)") })
    }

    // MARK: 上の値

    private static func readout(_ probe: (Double, (original: Double?, current: Double?))?) -> [ETReadoutItem] {
        guard let (seconds, values) = probe else { return [] }
        return [ETReadoutItem("TIME", ETIRAnalysis.timeText(ms: seconds * 1000)),
                ETReadoutItem("ORIGINAL", values.original.map { ETFormat.db($0) } ?? "—"),
                ETReadoutItem("CURRENT", values.current.map { ETFormat.db($0) } ?? "—")]
    }

    // MARK: 色

    private static let currentStyle = AnyShapeStyle(.tint)
    private static let originalStyle = AnyShapeStyle(.secondary)
    private static let primaryStyle = AnyShapeStyle(.primary)

    private static func style(_ kind: ETIRMarkerKind) -> AnyShapeStyle {
        switch kind {
        case .onset:    return primaryStyle
        case .cut:      return AnyShapeStyle(Color.red)
        case .preDelay: return originalStyle
        case .trim:     return currentStyle
        case .rt60:     return primaryStyle
        }
    }

    // MARK: 描く

    private static func draw(_ context: inout GraphicsContext, _ plot: ETPlot,
                             graph: ETIRGraph, layout: ETIRGraphLayout,
                             probe: (Double, (original: Double?, current: Double?))?) {
        let rect = plot.rect
        let fs = Double(graph.sampleRate)
        let yAxis = plot.yAxis

        // 枠の中。はみ出す線（pd が長さの外にあるときの縦線など）は切る。
        context.drawLayer { layer in
            layer.clip(to: Path(rect.insetBy(dx: -0.5, dy: -0.5)))

            // Current の包絡（:1849-1866）。左下 → 各点 → 右下で閉じる。
            if let envelope = graph.envelopeDb {
                var fill = Path()
                fill.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                for (index, db) in envelope.enumerated() {
                    fill.addLine(to: CGPoint(x: plot.x(Double(graph.current.sampleFrames[index]) / fs),
                                             y: plot.y(yAxis.clamp(db))))
                }
                fill.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                fill.closeSubpath()
                layer.fill(fill, with: .style(AnyShapeStyle(.tint).opacity(0.18)))
            }

            // EDC。Original の点線が先、Current の実線が後（:1868-1883）。
            layer.stroke(edc(graph.original, fs: fs, plot: plot), with: .style(originalStyle),
                         style: StrokeStyle(lineWidth: 2, dash: [5, 5]))
            layer.stroke(edc(graph.current, fs: fs, plot: plot), with: .style(currentStyle),
                         style: StrokeStyle(lineWidth: 2))

            // 縦の印（:1894-1904）。描かないものは drawnMarkers が外している。
            for marker in layout.drawnMarkers {
                var line = Path()
                let px = plot.x(marker.seconds)
                line.move(to: CGPoint(x: px, y: rect.minY))
                line.addLine(to: CGPoint(x: px, y: rect.maxY))
                layer.stroke(line, with: .style(style(marker.kind)), lineWidth: 1)
            }

            // 触っている所。
            if let (seconds, values) = probe {
                let px = plot.x(seconds)
                var line = Path()
                line.move(to: CGPoint(x: px, y: rect.minY))
                line.addLine(to: CGPoint(x: px, y: rect.maxY))
                layer.stroke(line, with: ETGraphShading.grid, style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                for (value, shading) in [(values.original, originalStyle), (values.current, currentStyle)] {
                    guard let value else { continue }
                    let py = plot.y(yAxis.clamp(value))
                    layer.stroke(Path(ellipseIn: CGRect(x: px - 5, y: py - 5, width: 10, height: 10)),
                                 with: .style(shading), lineWidth: 2)
                }
            }
        }

        // 枠の外。字は切らない。
        // 印の字（:1906-1941）。段は描いた印を数えて 3 で回す。
        func markerText(_ text: String, _ style: AnyShapeStyle) -> GraphicsContext.ResolvedText {
            context.resolve(Text(text).font(.system(size: ETGraphMetrics.labelSize)).foregroundStyle(style))
        }
        func drawLabel(_ resolved: GraphicsContext.ResolvedText, px: Double, row: Int) {
            let width = resolved.measure(in: CGSize(width: 1000, height: 100)).width
            let x = ETIRAnalysis.markerLabelX(px: px, textWidth: Double(width),
                                              plotLeft: Double(rect.minX), plotRight: Double(rect.maxX))
            context.draw(resolved,
                         at: CGPoint(x: x, y: labelTop + labelLine * CGFloat(row + 1) - 2),
                         anchor: .bottomLeading)
        }
        for marker in layout.drawnMarkers {
            drawLabel(markerText(layout.label(marker.kind), style(marker.kind)),
                      px: Double(plot.x(marker.seconds)), row: marker.row)
        }
        if let row = layout.trailingRt60Row {
            drawLabel(markerText(layout.rt60Label, primaryStyle), px: Double(rect.maxX), row: row)
        }

        // 下。「Time」を右下に置き、1 秒ごとの印と字は「Time」にぶつかるものを飛ばす（:1822-1846）。
        let labelY = rect.maxY + 11
        let time = context.resolve(Text("Time")
            .font(.system(size: ETGraphMetrics.labelSize, design: .monospaced))
            .foregroundStyle(primaryStyle))
        let timeWidth = min(time.measure(in: CGSize(width: 1000, height: 100)).width, rect.width)
        let timeLeft = rect.maxX - timeWidth
        for second in ETIRAnalysis.secondTicks(duration: layout.duration) {
            let px = plot.x(Double(second))
            let label = context.resolve(Text("\(second) s")
                .font(.system(size: ETGraphMetrics.labelSize, design: .monospaced))
                .foregroundStyle(.secondary))
            let width = label.measure(in: CGSize(width: 1000, height: 100)).width
            if px + width / 2 + 4 >= timeLeft { continue }
            var tick = Path()
            tick.move(to: CGPoint(x: px, y: rect.maxY))
            tick.addLine(to: CGPoint(x: px, y: rect.maxY + 4))
            context.stroke(tick, with: ETGraphShading.axis, lineWidth: 1)
            context.draw(label, at: CGPoint(x: px, y: labelY), anchor: .center)
        }
        context.draw(time, at: CGPoint(x: rect.maxX, y: labelY), anchor: .trailing)
    }

    /// EDC の折れ線。点は (sampleFrames / fs, edcDb)。縦は軸の範囲に留める（上流の y() の clamp）。
    private static func edc(_ series: ETIRSeries, fs: Double, plot: ETPlot) -> Path {
        var path = Path()
        for index in series.edcDb.indices {
            let point = CGPoint(x: plot.x(Double(series.sampleFrames[index]) / fs),
                                y: plot.y(plot.yAxis.clamp(Double(series.edcDb[index]))))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}
