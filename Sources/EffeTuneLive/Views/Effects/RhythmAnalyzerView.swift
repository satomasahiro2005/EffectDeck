//  RhythmAnalyzerView.swift
//  Rhythm Analyzer（RhythmAnalyzerPlugin）。テンポ・拍・グルーヴの揺れを見せる。2.12.0 で増えたもの。
//  上流は plugins/analyzer/rhythm_analyzer.js。
//
//  履歴と計算は DSP/RhythmAnalyzerModel.swift（枠の読み・拍の時計・onset の置き方・ビートレンズ）。
//  ここは並べて描くだけ。上流の drawGroove と同じ段取りで、
//    見出し（ビート LED・テンポ・×½/×2・最も強い候補・スウィング・ジッタ・凡例）
//    → Tempogram（30〜480 BPM × 20 秒の履歴と採用したテンポの線）
//    → Timing lanes（直近の Span 拍、帯域ごとの ±30ms の揺れ）
//    → Echo rows（前の Span 拍の周回、新しいものが上）
//    → Beat lens（拍の中の位置ごとの、ずれとばらつき）
//  を、使う面だけで高さを分ける。
//
//  上流との違い:
//    - 字の縁取りは無い（SwiftUI の Canvas は字を縁取れない）。重なって読めない字は、上流と同じく
//      先に書いた字を優先して外す。
//    - カーソルの読み値（GraphReadout）は無い。
//    - Tempogram の画像は 160×192 の濃淡の板（imageSmoothingEnabled は切れないので縁が少し滑らか）。
//    - 「Metronome Click」を入れるとメトロノームの 2kHz のクリックが出力へ足される（カーネルの機能）。
//
//  テレメトリは枠 1 つが「前の枠から今まで」の onset を運ぶので、最新の枠だけを見ず、
//  Telemetry.drainRhythmFrames で届いた順に全部入れる。

import SwiftUI
import CoreGraphics

/// 画面が持つ履歴。枠を入れたら画面へ知らせる。
@MainActor
final class RhythmTracker: ObservableObject {
    let state = ETRhythmState()

    /// tap ごとに 1 つ。**画面に持たせない。** カードを畳む・開くと図は別の場所の別の画面に
    /// 作り直されるので、@StateObject では開くたびに履歴が空になり、Echo rows が埋まるまで
    /// （Span × 5〜7 拍、8 拍で 20 秒ほど）上流より印が少なかった。上流は plugin が履歴を持ち、
    /// 畳んでも消えない。2 つの画面（ドラッグ中の写しなど）が同じ輪を取り合うことも無くなる。
    /// tap は作るたびに新しい番号（EffeTuneDSP.nextTap）なので、もう居ない tap の分は捨てる。
    private static var byTap: [UInt32: RhythmTracker] = [:]

    static func shared(tap: UInt32) -> RhythmTracker {
        // 0 は tap を付けられなかったもの（"Waiting for audio" のまま）。分けて持たない。
        guard tap != 0 else { return RhythmTracker() }
        if let tracker = byTap[tap] { return tracker }
        let live = Set(EffeTuneDSP.shared.nodes.map(\.tapId))
        byTap = byTap.filter { live.contains($0.key) }
        let made = RhythmTracker()
        byTap[tap] = made
        return made
    }
    private var clearCount = Telemetry.shared.clearCount
    /// Tempogram の濃淡の板。state.tempogramDirty のときだけ作り直す。
    private(set) var tempogramMask: CGImage?

    /// 溜まっている枠を全部入れる。
    func pump(tap: UInt32) {
        let telemetry = Telemetry.shared
        if clearCount != telemetry.clearCount {
            // エンジンを作り直した。世代の数え直しを新しい世代と取り違えない。
            clearCount = telemetry.clearCount
            state.resetSource()
        }
        let frames = telemetry.drainRhythmFrames(tap: tap)
        guard !frames.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        for frame in frames { state.ingest(frame, now: now) }
        objectWillChange.send()
    }

    func restart() {
        state.beginEpoch()
        tempogramMask = nil
        objectWillChange.send()
    }

    /// 濃淡の板。alpha = 濃さ^1.5（_tempogramImage、rhythm_analyzer.js:1148）。
    func mask() -> CGImage? {
        if !state.tempogramDirty, let tempogramMask { return tempogramMask }
        let columns = ETRhythm.tempogramColumns
        let bins = ETRhythm.tempogramBins
        var pixels = [UInt8](repeating: 0, count: columns * bins * 4)
        let head = state.tempogramHead
        for step in 0..<columns {
            let base = ((head + 1 + step) % columns) * bins
            for bin in 0..<bins {
                let value = Double(state.tempogram[base + bin])
                let alpha = UInt8(max(0, min(255, (value * value.squareRoot() * 255).rounded())))
                let pixel = ((bins - 1 - bin) * columns + step) * 4
                // 事前に alpha を掛けた白。形だけを持つ板で、色は描くときに付ける。
                pixels[pixel] = alpha
                pixels[pixel + 1] = alpha
                pixels[pixel + 2] = alpha
                pixels[pixel + 3] = alpha
            }
        }
        let image: CGImage? = pixels.withUnsafeBytes { raw -> CGImage? in
            guard let provider = CGDataProvider(data: Data(raw) as CFData) else { return nil }
            return CGImage(width: columns, height: bins, bitsPerComponent: 8, bitsPerPixel: 32,
                           bytesPerRow: columns * 4, space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: false,
                           intent: .defaultIntent)
        }
        tempogramMask = image
        state.tempogramDirty = false
        return image
    }
}

struct RhythmAnalyzerView: View {

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    @Environment(\.etGraphOnly) private var graphOnly
    @ObservedObject private var tracker: RhythmTracker

    // 表示だけの設定（DisplayParams の "RhythmAnalyzerPlugin"）。
    @State private var span: Double = Double(ETRhythm.defaultSpan)
    @State private var showTempogram = true
    @State private var showLanes = true
    @State private var showEcho = true
    @State private var showLens = true

    init(index: Int, node: EffeTuneDSP.Node, dsp: EffeTuneDSP) {
        self.index = index
        self.node = node
        self.dsp = dsp
        _tracker = ObservedObject(wrappedValue: RhythmTracker.shared(tap: node.tapId))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RhythmFigure(index: index, tapId: node.tapId, dsp: dsp, tracker: tracker,
                         span: spanValue, showTempogram: showTempogram, showLanes: showLanes,
                         showEcho: showEcho, showLens: showLens)
            if !graphOnly { rows }
        }
        .etSaved($span, key: "sp", index: index, dsp: dsp)
        .etSaved($showTempogram, key: "vt", index: index, dsp: dsp)
        .etSaved($showLanes, key: "vm", index: index, dsp: dsp)
        .etSaved($showEcho, key: "ve", index: index, dsp: dsp)
        .etSaved($showLens, key: "vl", index: index, dsp: dsp)
        .onChange(of: spanValue) { _, new in
            tracker.state.span = new
            tracker.state.refreshNovelty()
            tracker.objectWillChange.send()
        }
        .onAppear { tracker.state.span = spanValue }
    }

    /// 4/6/8/12/16 の最寄り（setParameters、rhythm_analyzer.js:179-187）。
    private var spanValue: Int { ETRhythm.nearestSpan(span) }

    // MARK: 行（上流の並び: Min BPM → Max BPM → Metronome Click → Span → 4 つの入切）

    @ViewBuilder private var rows: some View {
        ETDisplayNumberRow(title: "Min BPM", unit: "BPM", value: bpmBinding(isMinimum: true),
                           range: ETRhythmBPMRange.minimumRange, step: 1, isInteger: true)
        ETDisplayNumberRow(title: "Max BPM", unit: "BPM", value: bpmBinding(isMinimum: false),
                           range: ETRhythmBPMRange.maximumRange, step: 1, isInteger: true)
        if let click = node.spec.params.first(where: { $0.key == "ck" }) {
            ParameterRow(param: click, nodeIndex: index, values: node.values, dsp: dsp)
        }
        ETDisplayChoiceRow(title: "Span (beats)",
                           options: ETRhythm.spans.map { (value: $0, label: String($0)) },
                           selection: Binding(get: { spanValue }, set: { span = Double($0) }))
        ETDisplayToggleRow(title: "Tempogram", isOn: $showTempogram)
        ETDisplayToggleRow(title: "Timing lanes", isOn: $showLanes)
        ETDisplayToggleRow(title: "Echo rows", isOn: $showEcho)
        ETDisplayToggleRow(title: "Beat lens", isOn: $showLens)
    }

    private func offset(_ key: String) -> Int? {
        node.spec.params.first { $0.key == key }?.offset
    }

    private func current(_ key: String, fallback: Double) -> Double {
        guard let o = offset(key), node.values.indices.contains(o) else { return fallback }
        return Double(node.values[o])
    }

    /// Min / Max の変更。**Max ≥ 1.25 × Min の規則**を ETRhythmBPMRange で掛け、
    /// 値が変わったら解析を最初から始める（上流の beginTelemetryEpoch）。
    private func bpmBinding(isMinimum: Bool) -> Binding<Double> {
        Binding(
            get: { current(isMinimum ? "mn" : "mx", fallback: isMinimum ? 40 : 240) },
            set: { requested in
                let mn = current("mn", fallback: 40), mx = current("mx", fallback: 240)
                let range = ETRhythmBPMRange.normalize(
                    previousMin: mn, previousMax: mx,
                    requestedMin: isMinimum ? requested : nil,
                    requestedMax: isMinimum ? nil : requested)
                guard range.min != mn || range.max != mx,
                      let mnOffset = offset("mn"), let mxOffset = offset("mx"),
                      node.values.indices.contains(mnOffset), node.values.indices.contains(mxOffset)
                else { return }
                var values = node.values
                values[mnOffset] = Float(range.min)
                values[mxOffset] = Float(range.max)
                // 2 本を 1 回で渡す（1 本ずつだと、カーネルが途中の範囲で Reset を 2 回走らせうる）。
                dsp.setValues(values, at: index)
                tracker.restart()
            })
    }
}

// MARK: - 図

private struct RhythmFigure: View {

    let index: Int
    let tapId: UInt32
    @ObservedObject var dsp: EffeTuneDSP
    @ObservedObject var tracker: RhythmTracker
    let span: Int
    let showTempogram: Bool
    let showLanes: Bool
    let showEcho: Bool
    let showLens: Bool

    @ETTelemetryFeed private var telemetry
    @Environment(\.etGraphOnly) private var graphOnly
    /// 畳んだカードの高さの上限（EffectCardView.collapsedGraphHeight）。nil なら開いている。
    @Environment(\.etGraphMaxHeight) private var collapsedHeight
    @State private var width: CGFloat = 320

    private static let narrowWidth: CGFloat = 500

    var body: some View {
        let isNarrow = width < Self.narrowWidth
        // 横長は 3:2（createResponsiveGraph の aspectRatio）。縦長（狭い）は上流の 3:4 より
        // 縦に伸ばして 3:5 にする。3:4 では 3 本の帯が 55pt ほどで、見出しと目盛りが印にかぶる。
        let height = max(160, width * (isNarrow ? 5.0 / 3.0 : 2.0 / 3.0))
        // 枠が来たら入れる。入れたあとの知らせで描き直す（tracker の objectWillChange）。
        let sequence = telemetry.frame(tap: tapId, type: .rhythmAnalyzer)?.sequence
        VStack(alignment: .leading, spacing: 8) {
            GraphCanvas(
                x: .blank(), y: .blank(),
                height: height,
                insets: .none,
                clipsContent: true,
                showsHeader: false,
                draw: { context, plot in
                    // 畳んだときは見出しと Timing lanes（Beats の帯）だけ。4 枚を低い高さに詰めると
                    // どれも読めない帯になる。開けば表示の設定どおりに戻る。
                    let collapsed = collapsedHeight != nil
                    let painter = RhythmPainter(
                        state: tracker.state, mask: tracker.mask(), span: span,
                        showTempogram: collapsed ? false : showTempogram,
                        showLanes: collapsed ? true : showLanes,
                        showEcho: collapsed ? false : showEcho,
                        showLens: collapsed ? false : showLens,
                        now: ProcessInfo.processInfo.systemUptime)
                    // paint は座標を動かすので、写しに描かせる（待ちの字は元の座標で描く）。
                    var painted = context
                    painter.paint(&painted, rect: plot.rect)
                    if tracker.state.snapshot == nil {
                        context.draw(Text("Waiting for audio")
                                        .font(.system(size: 12)).foregroundStyle(.secondary),
                                     at: CGPoint(x: plot.rect.midX, y: plot.rect.midY), anchor: .center)
                    }
                })
                .frame(maxWidth: 1024)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { newWidth in
                    if newWidth > 0 && abs(newWidth - width) > 0.5 { width = newWidth }
                }
            if !graphOnly {
                ETMeasurementButton(title: "Reset") {
                    dsp.resetState(at: index)
                    tracker.restart()
                }
            }
        }
        .onChange(of: sequence) { _, _ in tracker.pump(tap: tapId) }
        .onAppear { tracker.pump(tap: tapId) }
    }
}

// MARK: - 描く

/// 上流の drawGroove（rhythm_analyzer.js:918-1262）。座標は図の左上を原点にした点。
private struct RhythmPainter {

    let state: ETRhythmState
    let mask: CGImage?
    let span: Int
    let showTempogram: Bool
    let showLanes: Bool
    let showEcho: Bool
    let showLens: Bool
    let now: Double

    // 色。上流の ThemePalette の役に当たる。
    private let label = Color.secondary
    private let axis = Color.primary
    private let strongGrid = Color.secondary.opacity(0.5)
    private let subtleGrid = Color.secondary.opacity(0.18)
    private let signal = Color.accentColor

    /// 字の箱（重なり判定）。
    private struct Box { var left, right, top, bottom: CGFloat }

    private struct TextItem {
        var value: String
        var x: CGFloat
        var y: CGFloat
        var color: Color
        var align: TextAlignment = .leading
        var baseline: Baseline = .middle
        var size: CGFloat
        var rotated = false
    }

    private enum Baseline { case middle, top, alphabetic }

    // MARK: 字

    private func measure(_ context: GraphicsContext, _ value: String, size: CGFloat) -> CGFloat {
        let resolved = context.resolve(Text(value).font(.system(size: size)))
        return resolved.measure(in: CGSize(width: 10000, height: 200)).width
    }

    private func anchor(_ align: TextAlignment, _ baseline: Baseline) -> UnitPoint {
        switch (align, baseline) {
        case (.leading, .middle): return .leading
        case (.center, .middle): return .center
        case (.trailing, .middle): return .trailing
        case (.leading, .top): return .topLeading
        case (.center, .top): return .top
        case (.trailing, .top): return .topTrailing
        case (.leading, .alphabetic): return .bottomLeading
        case (.center, .alphabetic): return .bottom
        case (.trailing, .alphabetic): return .bottomTrailing
        }
    }

    private func draw(_ context: inout GraphicsContext, _ item: TextItem) {
        let text = Text(item.value).font(.system(size: item.size)).foregroundStyle(item.color)
        if item.rotated {
            var layer = context
            layer.translateBy(x: item.x, y: item.y)
            layer.rotate(by: .degrees(-90))
            layer.draw(text, at: .zero, anchor: anchor(item.align, item.baseline))
        } else {
            context.draw(text, at: CGPoint(x: item.x, y: item.y), anchor: anchor(item.align, item.baseline))
        }
    }

    // MARK: 本体

    func paint(_ context: inout GraphicsContext, rect: CGRect) {
        context.translateBy(x: rect.minX, y: rect.minY)
        let width = rect.width, height = rect.height
        let isNarrow = width < 500
        let fontSize: CGFloat = isNarrow ? 11 : 12
        let axisFont: CGFloat = isNarrow ? 13 : 14
        let pad: CGFloat = 6
        let spanBeats = Double(span)
        let lens = state.displayedLens(state.lensSummary(), now: now)
        let signalColor = signal

        // 字が互いにぶつかるときは、先に書いたほうを残す（上流の writeAll）。
        let labelGap = 1.05 * fontSize
        var written: [Box] = []
        func box(_ item: TextItem, _ context: GraphicsContext) -> Box {
            let length = measure(context, item.value, size: item.size)
            let start = (item.align == .center ? -length / 2 : (item.align == .trailing ? -length : 0))
                - 0.1 * item.size
            let end = start + length + 0.2 * item.size
            let middle = item.baseline == .alphabetic ? -0.35 * item.size : 0
            let half = labelGap / fontSize * item.size / 2
            return item.rotated
                ? Box(left: item.x + middle - half, right: item.x + middle + half,
                      top: item.y - end, bottom: item.y - start)
                : Box(left: item.x + start, right: item.x + end,
                      top: item.y + middle - half, bottom: item.y + middle + half)
        }
        func writeAll(_ items: [TextItem], _ context: inout GraphicsContext) {
            let boxes = items.map { box($0, context) }
            let blocked = items.indices.contains { i in
                items[i].size < 0.8 * fontSize || written.contains { other in
                    boxes[i].left < other.right && other.left < boxes[i].right
                        && boxes[i].top < other.bottom && other.top < boxes[i].bottom
                }
            }
            if blocked { return }
            written.append(contentsOf: boxes)
            for item in items { draw(&context, item) }
        }
        func write(_ value: String, _ x: CGFloat, _ y: CGFloat, _ color: Color,
                   align: TextAlignment = .leading, baseline: Baseline = .middle,
                   size: CGFloat? = nil, rotated: Bool = false, _ context: inout GraphicsContext) {
            writeAll([TextItem(value: value, x: x, y: y, color: color, align: align,
                               baseline: baseline, size: size ?? fontSize, rotated: rotated)], &context)
        }
        func fitted(_ value: String, _ size: CGFloat, room: CGFloat, _ context: GraphicsContext) -> CGFloat {
            let natural = measure(context, value, size: size)
            return natural > room ? size * room / natural : size
        }
        func caption(_ value: String, _ x: CGFloat, _ y: CGFloat, room: CGFloat, _ context: inout GraphicsContext) {
            write(value, x, y, label, size: fitted(value, fontSize, room: room, context), &context)
        }
        func axisName(_ value: String, _ x: CGFloat, _ y: CGFloat, room: CGFloat, rotated: Bool = false,
                      _ context: inout GraphicsContext) {
            write(value, x, y, axis, align: .center, baseline: .alphabetic,
                  size: fitted(value, axisFont, room: room, context), rotated: rotated, &context)
        }
        let nameX: CGFloat = isNarrow ? 18 : 20
        func tickRight(_ left: CGFloat, _ labels: [String], _ context: GraphicsContext) -> CGFloat {
            left + nameX + 0.25 * axisFont + pad
                + (labels.map { measure(context, $0, size: fontSize) }.max() ?? 0)
        }
        func separate(_ r: CGRect, rows: Int, _ context: inout GraphicsContext) {
            var path = Path()
            if rows > 1 {
                for row in 1..<rows {
                    let y = r.minY + CGFloat(row) * r.height / CGFloat(rows)
                    path.move(to: CGPoint(x: r.minX, y: y))
                    path.addLine(to: CGPoint(x: r.maxX, y: y))
                }
            }
            context.stroke(path, with: .color(label), lineWidth: 1)
        }
        func bandLabels(_ left: CGFloat, _ yOf: (Int) -> CGFloat, _ context: inout GraphicsContext) {
            for (row, band) in ETRhythm.bandOrder.enumerated() {
                write(ETRhythm.bandNames[band], left + pad, yOf(row), label, &context)
            }
        }

        // 見出し。
        var top = pad
        let header = headerItems(lens: lens, markerColor: signalColor)
        let placed = layoutHeader(context, header, width: width, pad: pad, fontSize: fontSize)
        for entry in placed.entries {
            var x = entry.left
            for (i, part) in entry.item.enumerated() {
                if part.lamp {
                    drawBeatLed(&context, level: part.level, color: part.color, left: x, top: entry.top,
                                size: fontSize * entry.scale, lineWidth: 1)
                } else {
                    draw(&context, TextItem(value: part.text, x: x, y: entry.top, color: part.color,
                                            align: .leading, baseline: .top, size: fontSize * entry.scale))
                }
                x += (entry.widths[i] + 0.8 * fontSize) * entry.scale
            }
        }
        top = placed.bottom + pad

        let captionRow = 1.3 * fontSize
        // レンズの軸の名前の行（スロットの字の下）。
        let nameRow = axisFont + 8
        let lensLabelHeight = captionRow + nameRow + (1.4 / 0.15) * fontSize
        let stacked = width < height
        let besideLens = !stacked && showLens && (showLanes || showEcho)
        let laneRight = besideLens ? 0.72 * width : width

        struct Panel {
            var key: String
            var share: CGFloat
            var right: CGFloat
            var caption: Bool
            var minimum: CGFloat = 0
            var height: CGFloat?
        }
        var column: [Panel] = []
        if showTempogram { column.append(Panel(key: "strip", share: stacked ? 0.15 : 0.2, right: width, caption: false, minimum: 90)) }
        if showLanes { column.append(Panel(key: "main", share: stacked ? 0.25 : 0.3, right: laneRight, caption: true)) }
        if showEcho { column.append(Panel(key: "echo", share: stacked ? 0.33 : 0.5, right: laneRight, caption: true)) }
        if showLens && !besideLens {
            column.append(Panel(key: "lens", share: stacked ? 0.27 : 0.8, right: width, caption: true,
                                minimum: lensLabelHeight))
        }

        var free = height - pad - top
        var shares: CGFloat = 0
        for (i, panel) in column.enumerated() {
            free -= (i > 0 ? pad : 0) + (panel.caption ? captionRow : 0)
            shares += panel.share
        }
        guard free > 0, !column.isEmpty || besideLens else { return }
        // 狭いと Tempogram は 90pt、レンズは字が収まる高さを守り、残りで他を分ける。
        let minimums = column.reduce(0) { $0 + $1.minimum }
        let minimumScale: CGFloat = minimums > 2.0 / 3.0 * free ? 2.0 / 3.0 * free / minimums : 1
        var rest = free
        var restShares = shares
        var sharing = column.count
        var fixing = isNarrow
        while fixing {
            fixing = false
            for i in column.indices {
                let minimum = min(column[i].minimum * minimumScale, free / 2)
                if column[i].height == nil && sharing > 1 && rest * column[i].share / restShares < minimum {
                    column[i].height = minimum
                    rest -= minimum
                    restShares -= column[i].share
                    sharing -= 1
                    fixing = true
                }
            }
        }
        var rects: [String: CGRect] = [:]
        var y = top
        for (i, panel) in column.enumerated() {
            y += (i > 0 ? pad : 0) + (panel.caption ? captionRow : 0)
            let h = panel.height ?? rest * panel.share / restShares
            rects[panel.key] = CGRect(x: 0, y: y, width: panel.right, height: h)
            y += h
        }
        if besideLens, let first = rects["main"] ?? rects["echo"], let last = rects["echo"] ?? rects["main"] {
            rects["lens"] = CGRect(x: laneRight + 2 * pad, y: first.minY,
                                   width: width - 2 * pad - laneRight, height: last.maxY - first.minY)
        }
        let strip = rects["strip"], main = rects["main"], echo = rects["echo"], lensRect = rects["lens"]

        var views: [ETRhythmState.LaneView] = []
        if let main {
            views.append(.init(left: main.minX, top: main.minY, width: main.width, height: main.height,
                               uRight: state.beatClock, span: span, echo: false))
        }
        var rowCount = 0
        var echoRows = 0
        if let echo {
            rowCount = Int((echo.height / 22).rounded(.down))
            echoRows = rowCount < 4 ? 4 : (rowCount > 6 ? 6 : rowCount)
        }
        // タイミングの行が最新の窓を出すので、Echo はその 1 つ前から。
        let firstWindow = main != nil ? 1 : 0
        if let echo {
            for row in 0..<echoRows {
                views.append(.init(left: echo.minX, top: echo.minY + CGFloat(row) * echo.height / CGFloat(echoRows),
                                   width: echo.width, height: echo.height / CGFloat(echoRows),
                                   uRight: state.beatClock - Double(row + firstWindow) * spanBeats,
                                   span: span, echo: true))
            }
        }
        let scroll = state.tempogramScroll(now: now)

        if let strip {
            drawTempogram(&context, strip, scroll: scroll, fontSize: fontSize, pad: pad, nameX: nameX,
                          axisName: { v, x, y, room, rotated, ctx in axisName(v, x, y, room: room, rotated: rotated, &ctx) },
                          tickRight: { l, labels, ctx in tickRight(l, labels, ctx) },
                          write: { v, x, y, color, align, ctx in write(v, x, y, color, align: align, &ctx) })
        }
        for view in views {
            drawLane(&context, view, signalColor: signalColor,
                     write: { v, x, y, color, align, ctx in write(v, x, y, color, align: align, &ctx) })
        }
        if let main { separate(main, rows: 3, &context) }
        if let echo { separate(echo, rows: echoRows, &context) }
        if let lensRect {
            drawLens(&context, lensRect, lens: lens, signalColor: signalColor, fontSize: fontSize,
                     captionRow: captionRow, fullNameRow: nameRow, lensLabelHeight: lensLabelHeight,
                     axisName: { v, x, y, room, ctx in axisName(v, x, y, room: room, &ctx) },
                     write: { v, x, y, color, align, ctx in write(v, x, y, color, align: align, &ctx) },
                     bandLabels: { left, yOf, ctx in bandLabels(left, yOf, &ctx) })
        }
        if let main {
            caption("Last \(span) beats", main.minX + pad, main.minY - captionRow / 2,
                    room: main.width - 2 * pad, &context)
            axisName("Timing (ms)", main.minX + nameX, main.midY, room: main.height - pad, rotated: true, &context)
            axisName("Beats", main.midX, main.maxY - 8, room: main.width, &context)
            // 帯域の名前と、右にずれの目盛り（上 = 遅れ）。+20/−20 の組は、レーンが低くて 2 つが
            // 離れないとき・別の字に触れるときは、組ごと出さない。
            let lane = main.height / 3
            let guide = CGFloat(ETRhythm.guideMS / ETRhythm.deviationMS * 0.45) * lane
            let late = ETRhythm.signed(ETRhythm.guideMS, digits: 0)
            let early = ETRhythm.signed(-ETRhythm.guideMS, digits: 0)
            let nameRight = tickRight(main.minX, ETRhythm.bandNames, context)
            let valueRight = nameRight + pad + max(measure(context, late, size: fontSize),
                                                  measure(context, early, size: fontSize))
            for (row, band) in ETRhythm.bandOrder.enumerated() {
                write(ETRhythm.bandNames[band], nameRight, main.minY + (CGFloat(row) + 0.5) * lane, label,
                      align: .trailing, &context)
            }
            if !(2 * guide < labelGap) {
                for row in [0, 2, 1] {
                    let center = main.minY + (CGFloat(row) + 0.5) * lane
                    writeAll([TextItem(value: late, x: valueRight, y: center - guide, color: label, align: .trailing, size: fontSize),
                              TextItem(value: early, x: valueRight, y: center + guide, color: label, align: .trailing, size: fontSize)],
                             &context)
                }
            }
        }
        if let echo {
            caption("\(main != nil ? "Previous" : "Recent") \(span)-beat cycles, newest on top",
                    echo.minX + pad, echo.minY - captionRow / 2, room: echo.width - 2 * pad, &context)
            axisName("Cycles ago", echo.minX + nameX, echo.midY, room: echo.height - pad, rotated: true, &context)
            axisName("Beats", echo.midX, echo.maxY - 8, room: echo.width, &context)
            // 各行に、何周前かを書く。
            let echoViews = views.filter { $0.echo }
            let x = tickRight(echo.minX, [String(echoRows - 1 + firstWindow)], context)
            for (row, view) in echoViews.enumerated() {
                write(String(row + firstWindow), x, view.top + view.height / 2, label, align: .trailing, &context)
            }
            // 行が無いとき、最新の行が帯域の名前を持つ。
            if main == nil, let newest = echoViews.first {
                bandLabels(x, { row in newest.top + (0.5 + CGFloat(row - 1) * 0.28) * newest.height }, &context)
            }
        }
        if let lensRect {
            caption("Beat lens: offset ± spread, last \(Int(ETRhythm.lensBeats)) beats",
                    lensRect.minX + pad, lensRect.minY - captionRow / 2, room: lensRect.width - 2 * pad, &context)
        }
    }

    // MARK: 見出し

    private struct HeaderPart {
        var text = ""
        var slot: String?
        var color: Color
        var lamp = false
        var level: Double?
    }

    private func headerItems(lens: ETRhythmLens?, markerColor: Color) -> [[HeaderPart]] {
        let snapshot = state.snapshot
        let locked = snapshot?.analysisValid == true
        let period: Double? = locked ? snapshot?.periodSeconds : state.heldPeriod
        let bpm: Double = (period ?? 0) > 0 ? 60 / period! : .nan
        func value(_ number: Double, _ text: String) -> String { number.isFinite ? text : ETRhythm.dash }
        let tempo: String
        if locked { tempo = String(format: "%.1f BPM  LOCKED", bpm) }
        else if bpm.isFinite { tempo = String(format: "(%.0f BPM held)  searching", bpm) }
        else { tempo = "searching" }
        let comb = (snapshot?.strongestBpm ?? 0) > 0 ? snapshot!.strongestBpm : Double.nan
        let swing = lens?.swing ?? .nan
        let jitter = lens?.jitter ?? .nan
        return [
            [HeaderPart(color: locked ? markerColor : strongGrid, lamp: true, level: locked ? state.ledLevel : nil),
             HeaderPart(text: tempo, slot: "(000 BPM held)  searching", color: locked ? markerColor : label)],
            [HeaderPart(text: "×½ \(value(bpm, String(format: "%.0f", bpm / 2)))", slot: "×½ 000", color: label),
             HeaderPart(text: "×2 \(value(bpm, String(format: "%.0f", bpm * 2)))", slot: "×2 0000", color: label)],
            [HeaderPart(text: "strongest \(value(comb, String(format: "%.0f BPM", comb)))", slot: "strongest 000 BPM", color: label)],
            [HeaderPart(text: "swing \(value(swing, String(format: "%.2f:1", swing)))", slot: "swing 0.00:1", color: label)],
            [HeaderPart(text: "jitter \(value(jitter, String(format: "%.1f ms", jitter)))", slot: "jitter 000.0 ms", color: label)],
            [HeaderPart(text: "○ no beat lock", color: label),
             HeaderPart(text: "◎ new vs \(span) / \(2 * span) beats ago", color: label),
             HeaderPart(text: "┆ beat re-aligned", color: markerColor)],
        ]
    }

    private struct PlacedItem {
        var item: [HeaderPart]
        var widths: [CGFloat]
        var scale: CGFloat
        var left: CGFloat
        var top: CGFloat
    }

    /// 左から右へ並べ、行からはみ出すものは次の行へ。1 行より広いものは縮める。
    /// 値を持つ部品は、最悪の字（slot）の幅を取るので、値が変わっても並びが動かない。
    private func layoutHeader(_ context: GraphicsContext, _ items: [[HeaderPart]], width: CGFloat,
                              pad: CGFloat, fontSize: CGFloat) -> (entries: [PlacedItem], bottom: CGFloat) {
        let gap = 1.5 * fontSize
        let partGap = 0.8 * fontSize
        let lineHeight = 1.35 * fontSize
        let available = width - 2 * pad
        var x = pad
        var top = pad
        var placed: [PlacedItem] = []
        for item in items {
            let widths = item.map { $0.lamp ? fontSize : measure(context, $0.slot ?? $0.text, size: fontSize) }
            let natural = widths.reduce(0, +) + partGap * CGFloat(item.count - 1)
            let scale: CGFloat = natural > available ? available / natural : 1
            let itemWidth = natural * scale
            if x > pad && x + itemWidth > width - pad {
                x = pad
                top += lineHeight
            }
            placed.append(PlacedItem(item: item, widths: widths, scale: scale, left: x, top: top))
            x += itemWidth + gap
        }
        return (placed, top + lineHeight)
    }

    /// ヘッダ 1 行の大きさの LED。level があれば濃さで塗り、無ければ空の輪（_drawBeatLed）。
    private func drawBeatLed(_ context: inout GraphicsContext, level: Double?, color: Color,
                             left: CGFloat, top: CGFloat, size: CGFloat, lineWidth: CGFloat) {
        let circle = CGRect(x: left + size / 2 - 0.38 * size, y: top + 0.55 * size - 0.38 * size,
                            width: 0.76 * size, height: 0.76 * size)
        if let level {
            let minimum = 0.15
            var layer = context
            layer.opacity = minimum + (1 - minimum) * level
            layer.fill(Path(ellipseIn: circle), with: .color(color))
        }
        context.stroke(Path(ellipseIn: circle), with: .color(color), lineWidth: lineWidth)
    }

    // MARK: レーン（タイミング・エコー）

    private func drawLane(_ context: inout GraphicsContext, _ view: ETRhythmState.LaneView, signalColor: Color,
                          write: (String, CGFloat, CGFloat, Color, TextAlignment, inout GraphicsContext) -> Void) {
        let left = CGFloat(view.left), top = CGFloat(view.top)
        let width = CGFloat(view.width), height = CGFloat(view.height)
        let spanBeats = Double(view.span)
        let from = view.uRight - spanBeats
        let to = view.uRight
        func xOf(_ u: Double) -> CGFloat { left + CGFloat((u - from) / spanBeats) * width }

        // ロックの区間に無い所は、探していた所。
        var cursor = from
        var widest: (start: Double, end: Double)?
        func shade(_ start: Double, _ end: Double, _ context: inout GraphicsContext) {
            guard end > start + 1e-6 else { return }
            var layer = context
            layer.opacity = 0.45
            layer.fill(Path(CGRect(x: xOf(start), y: top, width: xOf(end) - xOf(start), height: height)),
                       with: .color(subtleGrid))
            if widest == nil || end - start > widest!.end - widest!.start { widest = (start, end) }
        }
        let ordered = state.segmentOrder.compactMap { state.segments[$0] }
        for segment in ordered {
            if segment.endU <= cursor { continue }
            if segment.startU >= to { break }
            shade(cursor, segment.startU, &context)
            cursor = segment.endU
        }
        shade(cursor, to, &context)
        if !view.echo, let widest, widest.end - widest.start > 0.12 * spanBeats {
            write("searching", xOf((widest.start + widest.end) / 2), top + height / 2, label, .center, &context)
        }
        let step = view.echo ? 1.0 : 0.5
        for segment in ordered {
            let low = segment.startU > from ? segment.startU : from
            let high = segment.endU < to ? segment.endU : to
            if high < low { continue }
            var q = ((low - segment.offset) / step).rounded(.up)
            while q * step + segment.offset <= high {
                let beat = q * step == (q * step).rounded(.down)
                let x = xOf(q * step + segment.offset)
                var line = Path()
                line.move(to: CGPoint(x: x, y: top))
                line.addLine(to: CGPoint(x: x, y: top + height))
                context.stroke(line, with: .color(beat ? strongGrid : subtleGrid), lineWidth: beat ? 1 : 0.5)
                q += 1
            }
            if segment.reanchor && segment.startU >= from && segment.startU <= to {
                let x = xOf(segment.startU)
                var line = Path()
                line.move(to: CGPoint(x: x, y: top))
                line.addLine(to: CGPoint(x: x, y: top + height))
                context.stroke(line, with: .color(signalColor),
                               style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
        }
        // 各レーンの中心線（0 ms）の ±20 ms に点線。
        let lane = height / 3
        if !view.echo {
            let guide = CGFloat(ETRhythm.guideMS / ETRhythm.deviationMS * 0.45) * lane
            var path = Path()
            for row in 0..<3 {
                let center = top + (CGFloat(row) + 0.5) * lane
                for y in [center - guide, center + guide] {
                    path.move(to: CGPoint(x: left, y: y))
                    path.addLine(to: CGPoint(x: left + width, y: y))
                }
            }
            var layer = context
            layer.opacity = 0.6
            layer.stroke(path, with: .color(signalColor), style: StrokeStyle(lineWidth: 1, dash: [1, 3]))
        }
        // onset。
        var layer = context
        layer.clip(to: Path(CGRect(x: left, y: top, width: width, height: height)))
        for point in state.points(for: view) {
            let r = CGFloat(min(max(point.radius, 1.5), 3.5))
            let px = CGFloat(point.x), py = CGFloat(point.y)
            let circle = CGRect(x: px - r, y: py - r, width: 2 * r, height: 2 * r)
            if !point.timed {
                // 拍に乗っていないものは輪。
                var hollow = layer
                hollow.opacity = 0.75
                hollow.stroke(Path(ellipseIn: circle), with: .color(signalColor), lineWidth: 0.9)
                continue
            }
            if !view.echo {
                // レーンの中心（0 ms）からの棒で、ずれが一目で読める。
                var stem = Path()
                stem.move(to: CGPoint(x: px, y: top + (CGFloat(ETRhythm.bandRows[point.band]) + 0.5) * lane))
                stem.addLine(to: CGPoint(x: px, y: py))
                var faint = layer
                faint.opacity = 0.6
                faint.stroke(stem, with: .color(signalColor), lineWidth: 1)
            }
            var dot = layer
            dot.opacity = 0.95
            dot.fill(Path(ellipseIn: circle), with: .color(signalColor))
            if point.novel {
                let ring = r + 2
                layer.stroke(Path(ellipseIn: CGRect(x: px - ring, y: py - ring, width: 2 * ring, height: 2 * ring)),
                             with: .color(label), lineWidth: 1)
            }
        }
    }

    // MARK: Tempogram

    private func drawTempogram(_ context: inout GraphicsContext, _ strip: CGRect, scroll: Double,
                               fontSize: CGFloat, pad: CGFloat, nameX: CGFloat,
                               axisName: (String, CGFloat, CGFloat, CGFloat, Bool, inout GraphicsContext) -> Void,
                               tickRight: (CGFloat, [String], GraphicsContext) -> CGFloat,
                               write: (String, CGFloat, CGFloat, Color, TextAlignment, inout GraphicsContext) -> Void) {
        let columns = ETRhythm.tempogramColumns
        func yOf(_ bpm: Double) -> CGFloat { strip.minY + CGFloat(1 - ETRhythm.bpmPosition(bpm)) * strip.height }
        func xOf(_ step: Double) -> CGFloat {
            strip.minX + CGFloat((step + 0.5 - scroll) / Double(columns)) * strip.width
        }
        func clampY(_ y: CGFloat) -> CGFloat {
            y < strip.minY + fontSize / 2 ? strip.minY + fontSize / 2
                : (y > strip.maxY - fontSize / 2 ? strip.maxY - fontSize / 2 : y)
        }
        var grid = Path()
        for bpm in ETRhythm.bpmTicks {
            grid.move(to: CGPoint(x: strip.minX, y: yOf(bpm)))
            grid.addLine(to: CGPoint(x: strip.maxX, y: yOf(bpm)))
        }
        context.stroke(grid, with: .color(subtleGrid), lineWidth: 0.5)

        let head = state.tempogramHead
        func columnAt(_ step: Int) -> Int { (head + 1 + step) % columns }
        func alphaOf(_ confidence: Double) -> Double { confidence < 0.15 ? 0.15 : (confidence > 1 ? 1 : confidence) }
        let right = strip.maxX
        let shift = CGFloat(scroll / Double(columns)) * strip.width

        var layer = context
        layer.clip(to: Path(strip))
        if let image = mask {
            // 履歴は整数の位置で切り、最新の列はそこから右端まで伸ばす（2 回の描画が重ならず、縁が出ない）。
            let edge = (right - shift).rounded(.down)
            let history = CGRect(x: strip.minX - shift, y: strip.minY, width: strip.width, height: strip.height)
            var past = layer
            past.clip(to: Path(CGRect(x: strip.minX, y: strip.minY, width: edge - strip.minX, height: strip.height)))
            past.clipToLayer { target in
                target.draw(Image(decorative: image, scale: 1), in: history)
            }
            past.fill(Path(strip), with: .color(label))
            if right > edge,
               let newest = image.cropping(to: CGRect(x: columns - 1, y: 0, width: 1,
                                                      height: ETRhythm.tempogramBins)) {
                var held = layer
                let area = CGRect(x: edge, y: strip.minY, width: right - edge, height: strip.height)
                held.clipToLayer { target in
                    target.draw(Image(decorative: newest, scale: 1), in: area)
                }
                held.fill(Path(strip), with: .color(label))
            }
        }
        // 採用したテンポと、その半分と 2 倍（破線の候補）。
        for (factor, lineWidth, opacity) in [(1.0, 2.0, 1.0), (2.0, 0.8, 0.6), (0.5, 0.8, 0.6)] {
            for step in 1...columns {
                let column = columnAt(step < columns ? step : columns - 1)
                let previous = Double(state.tempogramAdopted[columnAt(step - 1)]) * factor
                let current = Double(state.tempogramAdopted[column]) * factor
                guard previous > 0, current > 0 else { continue }
                var line = Path()
                line.move(to: CGPoint(x: xOf(Double(step - 1)), y: yOf(previous)))
                line.addLine(to: CGPoint(x: step < columns ? xOf(Double(step)) : right, y: yOf(current)))
                var stroke = layer
                stroke.opacity = opacity * alphaOf(Double(state.tempogramConfidence[column]))
                stroke.stroke(line, with: .color(signal),
                              style: StrokeStyle(lineWidth: lineWidth, dash: factor == 1 ? [] : [2, 2]))
            }
        }
        axisName("Time", strip.midX, strip.maxY - 8, strip.width, false, &context)
        axisName("Tempo (BPM)", strip.minX + nameX, strip.midY, strip.height - pad, true, &context)
        let tickX = tickRight(strip.minX, ["480"], context)
        for bpm in ETRhythm.bpmTicks {
            write(String(Int(bpm)), tickX, clampY(yOf(bpm)), label, .trailing, &context)
        }
        // 最新の採用したテンポとその候補を、右端の線のすぐ上に名指しする。
        let adopted = Double(state.tempogramAdopted[columnAt(columns - 1)])
        guard adopted > 0 else { return }
        for (bpm, name) in [(adopted, "adopted"), (adopted * 2, "×2"), (adopted / 2, "×½")]
        where bpm > ETRhythm.minimumBPM && bpm < 480 {
            write(name, strip.maxX - pad, clampY(yOf(bpm) - 0.6 * fontSize), signal, .trailing, &context)
        }
    }

    // MARK: ビートレンズ

    private func drawLens(_ context: inout GraphicsContext, _ rect: CGRect, lens: ETRhythmLens?,
                          signalColor: Color, fontSize: CGFloat, captionRow: CGFloat, fullNameRow: CGFloat,
                          lensLabelHeight: CGFloat,
                          axisName: (String, CGFloat, CGFloat, CGFloat, inout GraphicsContext) -> Void,
                          write: (String, CGFloat, CGFloat, Color, TextAlignment, inout GraphicsContext) -> Void,
                          bandLabels: (CGFloat, (Int) -> CGFloat, inout GraphicsContext) -> Void) {
        let columns = ETRhythm.slotLabels.count
        let columnWidth = rect.width / CGFloat(columns)
        // 本体の下にスロットの字、その下に軸の名前。低すぎて本体が取れないときは、名前、字の順に落とす。
        let nameRow = rect.height > captionRow + fullNameRow ? fullNameRow : 0
        let labelRow = rect.height > captionRow ? captionRow : 0
        let body = rect.height - labelRow - nameRow
        guard body > 0 else { return }
        func centerX(_ slot: Int) -> CGFloat { rect.minX + (CGFloat(slot) + 0.5) * columnWidth }
        let msScale = 0.42 * columnWidth / CGFloat(ETRhythm.deviationMS)
        let scaleY = rect.minY + (0.1 * body > 2 ? 0.1 * body : 2)
        func rowY(_ row: Int) -> CGFloat { rect.minY + (0.32 + 0.27 * CGFloat(row)) * body }
        for slot in 0..<columns {
            let x = centerX(slot)
            var guide = Path()
            guide.move(to: CGPoint(x: x, y: scaleY))
            guide.addLine(to: CGPoint(x: x, y: rect.minY + body))
            context.stroke(guide, with: .color(subtleGrid), lineWidth: 0.5)
            var scale = Path()
            scale.move(to: CGPoint(x: x - CGFloat(ETRhythm.deviationMS) * msScale, y: scaleY))
            scale.addLine(to: CGPoint(x: x + CGFloat(ETRhythm.deviationMS) * msScale, y: scaleY))
            for tick in [-ETRhythm.guideMS, ETRhythm.guideMS] {
                scale.move(to: CGPoint(x: x + CGFloat(tick) * msScale, y: scaleY - 2))
                scale.addLine(to: CGPoint(x: x + CGFloat(tick) * msScale, y: scaleY + 2))
            }
            context.stroke(scale, with: .color(strongGrid), lineWidth: 0.8)
        }
        if labelRow > 0 {
            for (slot, name) in ETRhythm.slotLabels.enumerated() {
                write(name, centerX(slot), rect.minY + body + labelRow / 2, label, .center, &context)
            }
        }
        if nameRow > 0 {
            axisName("Position in beat", rect.midX, rect.maxY - 8, rect.width, &context)
        }
        // 帯域の名前は、行に余裕があれば印の少し上、無ければ行の上。印より先に書く。
        let labelY: (Int) -> CGFloat = rect.height >= lensLabelHeight
            ? { row in rowY(row) - 0.06 * body - 0.7 * fontSize } : { row in rowY(row) }
        bandLabels(rect.minX, labelY, &context)
        guard let lens else {
            write("waiting for a steady beat", rect.midX, rowY(1), label, .center, &context)
            return
        }
        guard !lens.rows.isEmpty else { return }
        let maxCount = lens.rows.map(\.count).max() ?? 1
        let barHeight = 0.06 * body
        let limit = ETRhythm.deviationMS
        let valueSize = 0.85 * fontSize
        let valueClearsMark = 0.05 * body >= 0.5 * valueSize
        var layer = context
        layer.clip(to: Path(rect))
        for row in lens.rows {
            let y = rowY(ETRhythm.bandRows[row.band])
            let offset = min(max(row.offset, -limit), limit)
            let x = centerX(row.slot) + CGFloat(offset) * msScale
            let alpha = 0.35 + 0.65 * Double(row.count) / Double(maxCount)
            var bar = layer
            bar.opacity = 0.3 * alpha
            bar.fill(Path(CGRect(x: x - CGFloat(row.sd) * msScale, y: y - barHeight / 2,
                                 width: 2 * CGFloat(row.sd) * msScale, height: barHeight)),
                     with: .color(signalColor))
            var tick = layer
            tick.opacity = alpha
            var line = Path()
            line.move(to: CGPoint(x: x, y: y - 0.06 * body))
            line.addLine(to: CGPoint(x: x, y: y + 0.06 * body))
            tick.stroke(line, with: .color(signalColor), lineWidth: 2)
        }
        for row in lens.rows {
            let y = rowY(ETRhythm.bandRows[row.band])
            let offset = min(max(row.offset, -limit), limit)
            let x = centerX(row.slot) + CGFloat(offset) * msScale
            if valueClearsMark && abs(row.offset) >= ETRhythm.labelMinimumMS {
                write(ETRhythm.signed(row.offset, digits: 0), x, y + 0.11 * body, signalColor, .center, &context)
            }
        }
    }
}
