//  AnalogMeterView.swift
//  Analog Meter（AnalogMeterPlugin）。VU・PPM・RMS・ピーク・ラウドネスを針の計器で見せる。
//  2.12.0 で増えたもの。上流は plugins/analyzer/analog_meter.js。
//
//  値の計算は DSP/AnalogMeterModel.swift（目盛りの写し方・枠の読み・ピークホールド）。
//  ここは並べて描くだけ。
//
//  色と目盛りは上流の暗いテーマと同じ（面は黒、赤は --et-danger、字は graph-label-soft など）。
//  並べ方だけ iOS に合わせる。
//
//  上流との違い:
//    - 行（Mode / Integration / Attack / Release / Reference / Range / PPM Scale / Peak Hold /
//      Needle / Target / Scale）は上流と同じ順で、いまのモードで効かない行は出さない
//      （analog_meter.js:415-421 の syncControlStates）。図は行の上に置く（このアプリの他の図と同じ）。
//    - 針の並びは 1 行 4 つまで、狭いとき（iPhone）は 2 つまで（同 :19-20、:366-377）。
//      幅に余りがあるときは面を中央に置く。
//    - Loudness の Program の統計（M / S / I・LRA / TP / Time）は針の中の隅ではなく、
//      空いている枠（針が 3 つで 2 列のときの 4 つ目）か、針の下の帯に 12pt で置く。
//      針の見出しの下に帯を取り、目盛りの字とぶつからないようにする。
//    - Reset（Loudness のときだけ）は et_instance_reset で、Integrated / LRA / 最大 True Peak の
//      測定を最初からにする（上流は resetPluginState、同 :268-272）。値は変えない。
//
//  Integrated などを止めても残す（上流は temporalCapability = 'stateless'、同 :246-249）点は
//  このアプリでは同じにならない。停止（AudioIO.stop）は et_engine_reset で全部の段を戻す。
//  docs/notes/effetune-2.12.0.md に書いてある。

import SwiftUI

struct AnalogMeterView: View {

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    @Environment(\.etGraphOnly) private var graphOnly

    // 表示だけの設定。畳むと View ごと消えるので鎖に持たせる（DisplayParams の "AnalogMeterPlugin"）。
    @State private var reference: Double = -14
    @State private var range: Double = 40
    @State private var ppmScale: Double = 0
    @State private var peakHold: Double = 1
    @State private var needle: Double = 0
    @State private var target: Double = -23
    @State private var loudnessScale: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AnalogMeterFigure(index: index, tapId: node.tapId, settings: settings, dsp: dsp)
            if !graphOnly {
                rows
            }
        }
        .etSaved($reference, key: "rl", index: index, dsp: dsp)
        .etSaved($range, key: "rg", index: index, dsp: dsp)
        .etSaved($ppmScale, key: "sc", index: index, dsp: dsp)
        .etSaved($peakHold, key: "ph", index: index, dsp: dsp)
        .etSaved($needle, key: "ln", index: index, dsp: dsp)
        .etSaved($target, key: "tg", index: index, dsp: dsp)
        .etSaved($loudnessScale, key: "ls", index: index, dsp: dsp)
    }

    // MARK: 行

    /// 上流と同じ並び（analog_meter.js:432-451）。効かない行は出さない。
    @ViewBuilder private var rows: some View {
        let s = settings
        if let mode = param("md") {
            ParameterRow(param: mode, nodeIndex: index, values: node.values, dsp: dsp)
        }
        dspRow("it", s)
        dspRow("at", s)
        dspRow("rt", s)
        if ETAnalogMeter.isActive("rl", settings: s) {
            ETDisplayNumberRow(title: "Reference", unit: "dBFS", value: $reference,
                               range: -30...0, step: 1, isInteger: true)
        }
        if ETAnalogMeter.isActive("rg", settings: s) {
            ETDisplayNumberRow(title: "Range", unit: "dB", value: $range,
                               range: 20...60, step: 1, isInteger: true)
        }
        if ETAnalogMeter.isActive("sc", settings: s) {
            ETDisplayChoiceRow(title: "PPM Scale",
                               options: ETAnalogMeter.ppmScales.enumerated().map { (value: $0.offset, label: $0.element) },
                               selection: choice($ppmScale))
        }
        if ETAnalogMeter.isActive("ph", settings: s) {
            ETDisplayNumberRow(title: "Peak Hold", unit: "s", value: $peakHold,
                               range: 0...10, step: 0.1, trimsZeros: true)
        }
        if ETAnalogMeter.isActive("ln", settings: s) {
            ETDisplayChoiceRow(title: "Needle",
                               options: [(value: 0, label: "Momentary"), (value: 1, label: "Short-term")],
                               selection: choice($needle))
        }
        if ETAnalogMeter.isActive("tg", settings: s) {
            ETDisplayNumberRow(title: "Target", unit: "LUFS", value: $target,
                               range: -36 ... -10, step: 1, isInteger: true)
        }
        if ETAnalogMeter.isActive("ls", settings: s) {
            ETDisplayChoiceRow(title: "Scale",
                               options: [(value: 0, label: "EBU +9"), (value: 1, label: "EBU +18")],
                               selection: choice($loudnessScale))
        }
    }

    @ViewBuilder
    private func dspRow(_ key: String, _ settings: ETAnalogMeter.Settings) -> some View {
        if ETAnalogMeter.isActive(key, settings: settings), let p = param(key) {
            ParameterRow(param: p, nodeIndex: index, values: node.values, dsp: dsp, trimsZeros: true)
        }
    }

    private func param(_ key: String) -> ETParam? {
        node.spec.params.first { $0.key == key }
    }

    /// 0/1/2 の選択を Double の持ち物へ戻す。
    private func choice(_ source: Binding<Double>) -> Binding<Int> {
        Binding(get: { Self.integer(source.wrappedValue) },
                set: { source.wrappedValue = Double($0) })
    }

    /// 打ち込みや取り込みで NaN・巨大な値が来ても Int(_:) で落とさない。
    static func integer(_ v: Double) -> Int {
        v.isFinite ? Int(min(max(v, -1e6), 1e6).rounded()) : 0
    }

    // MARK: 設定

    /// 上流の setParameters と同じ寄せ方で、いまの設定を作る（analog_meter.js:326-336）。
    private var settings: ETAnalogMeter.Settings {
        var s = ETAnalogMeter.Settings()
        if let p = param("md"), node.values.indices.contains(p.offset) {
            let m = Self.integer(Double(node.values[p.offset]))
            s.mode = ETAnalogMeter.modes.indices.contains(m) ? m : 0
        }
        s.reference = ETAnalogMeter.Settings.clamped(reference, -30, 0, previous: s.reference)
        s.range = ETAnalogMeter.Settings.clamped(range, 20, 60, previous: s.range)
        s.peakHold = ETAnalogMeter.Settings.clamped(peakHold, 0, 10, previous: s.peakHold)
        s.target = ETAnalogMeter.Settings.clamped(target, -36, -10, previous: s.target)
        let sc = Self.integer(ppmScale)
        s.ppmScale = ETAnalogMeter.ppmScales.indices.contains(sc) ? sc : 0
        s.needle = Self.integer(needle) == 1 ? 1 : 0
        s.loudnessScale = Self.integer(loudnessScale) == 1 ? 1 : 0
        return s
    }
}

// MARK: - 色

/// 上流の暗いテーマで針の面が読む色（analog_meter.js:597-606 の _displayPalette、
/// effetune-theme.css の :root）。面は黒の窓で、カードの色には合わせない。
private enum AnalogMeterPalette {
    /// --et-text-primary
    private static let ink = Color(red: 246 / 255, green: 248 / 255, blue: 251 / 255)
    /// --et-graph-bg-deep
    static let face = Color.black
    /// 面の外の縁取り。
    static let bezel = Color(white: 0.17)
    /// --et-graph-grid-soft（文字色の 20%）
    static let grid = ink.opacity(0.2)
    /// --et-graph-label-soft（文字色の 50%）
    static let label = ink.opacity(0.5)
    /// --et-text-primary
    static let text = ink
    /// --et-danger（暗いテーマ）
    static let danger = Color(red: 1, green: 107 / 255, blue: 107 / 255)
}

// MARK: - 図

/// 針の計器を並べた面。テレメトリを観測するのはこの中だけ（つまみの行を 30Hz で作り直さない）。
private struct AnalogMeterFigure: View {

    let index: Int
    let tapId: UInt32
    let settings: ETAnalogMeter.Settings
    @ObservedObject var dsp: EffeTuneDSP

    @ETTelemetryFeed private var telemetry
    @Environment(\.etGraphOnly) private var graphOnly
    @Environment(\.etGraphMaxHeight) private var maxHeight

    @State private var holds: [ETAnalogMeter.Hold] = []
    /// 最後に読めた枠のチャンネル数。枠が途切れても並びを変えない（analog_meter.js:350-358）。
    @State private var channelCount = 2
    @State private var width: CGFloat = 320

    /// 針の幅（上流の ANALOG_METER_ARC_DEGREES）。
    private static let arc = ETAnalogMeter.arcDegrees * Double.pi / 180
    /// 針が狭いとき 2 列にする幅（pt）。上流は CSS の mobile 幅。
    private static let narrowWidth: CGFloat = 520
    /// 統計の字（pt）。iPhone でも 11pt を下回らない。
    private static let statsSize: CGFloat = 12
    private static let statsLine: CGFloat = 17
    /// 針の下に取る統計の帯（3 行 + 上下の余白）。
    private static let statsBand: CGFloat = 3 * statsLine + 16
    private static let bezelWidth: CGFloat = 3

    /// 針 1 つの縦の寸法。広い図は上流どおり 4:3。狭い図の 2 列では 1 つが 165pt ほどしかなく
    /// 4:3 だと弧が痩せるので、幅の限りの半径と高さがちょうど合う高さ（見出しの帯 + 目盛りの字 +
    /// 半径 + 読み値）を幾何から出す。見出しと目盛りの字のあいだに空きの帯が出ない。
    /// 比はおよそ VU 1.2 : 1、Loudness 1.1 : 1。
    private func cellHeight(cellWidth: CGFloat, _ layout: ETAnalogMeter.Grid) -> CGFloat {
        guard width < Self.narrowWidth && layout.columns > 1 else { return cellWidth * 3 / 4 }
        let scale = ETAnalogMeter.scale(mode: ETAnalogMeter.modes[settings.mode], settings: settings)
        let m = cellMetrics(boxWidth: cellWidth, scale: scale,
                            loudness: settings.mode == ETAnalogMeter.loudnessMode)
        return m.topOffset + m.widthRadius + m.bottomOffset
    }

    /// 針 1 つの寸法のうち、枠の幅と目盛りだけで決まるもの。描くとき（drawCell）と
    /// 高さを出すとき（cellHeight）で同じ式を使う。
    private struct CellMetrics {
        var fontSize: CGFloat
        var programReadout: CGFloat
        /// 枠の上端から、弧の頂点の字の上端までの距離（見出しの帯 + 字の高さ）。
        var topOffset: CGFloat
        /// 軸の根元から枠の下端までの距離（読み値の背丈 + 余白）。
        var bottomOffset: CGFloat
        /// 幅の限りの半径。端の字が枠からはみ出さないところまで。
        var widthRadius: CGFloat
    }

    private func cellMetrics(boxWidth: CGFloat, scale: ETAnalogMeter.Scale, loudness: Bool) -> CellMetrics {
        let inset = Self.frameInset
        // 狭い図（iPhone）では 9pt まで落とさず 11pt を下限にする。目盛りの字は 0.85 倍で約 9.4pt。
        let fontFloor: CGFloat = width < Self.narrowWidth ? 11 : 9
        let fontSize = max(fontFloor, min(14, boxWidth / 22))
        let programReadout = min(22, max(15, boxWidth * 0.11))
        // 軸の根元と半径は、同じ図の中でいちばん大きい読み値（Loudness は Program）で決める。
        let pivotReadout: CGFloat = loudness ? programReadout : max(fontSize, 11)
        // 見出しの帯。目盛りの字の上端が見出しの下に収まるところまで弧を下げる。
        let titleBottom = inset * 2 + fontSize * 1.25
        let labelRise = 9 + fontSize * 0.85 * 1.25
        let redExtra: CGFloat = scale.redFrom == nil ? 0 : 2
        // 端の字は目盛りの外へ横に張り出すので、いちばん長い字の幅ぶんを幅の限りから引く。
        let longestLabel = scale.ticks.map { $0.label.count }.max() ?? 0
        let sideRoom = CGFloat(longestLabel) * fontSize * 0.85 * 0.6 + 9 * CGFloat(sin(Self.arc)) + inset
        return CellMetrics(
            fontSize: fontSize, programReadout: programReadout,
            topOffset: titleBottom + 3 + labelRise + redExtra,
            bottomOffset: inset + 5 + pivotReadout * 0.75 + fontSize * 0.9,
            widthRadius: max(8, (boxWidth / 2 - inset - sideRoom) / CGFloat(sin(Self.arc))))
    }

    /// 前のモードの枠は捨てる（applyReading、analog_meter.js:350）。
    private var reading: ETAnalogMeter.Reading? {
        guard let r = ETAnalogMeter.parse(telemetry.frame(tap: tapId, type: .analogMeter)),
              r.mode == settings.mode else { return nil }
        return r
    }

    private var grid: ETAnalogMeter.Grid {
        let cells = ETAnalogMeter.cellCount(mode: settings.mode, channelCount: channelCount)
        return ETAnalogMeter.grid(cells: cells,
                                  maxColumns: width < Self.narrowWidth ? ETAnalogMeter.mobileColumns
                                                                       : ETAnalogMeter.maxColumns)
    }

    var body: some View {
        let current = reading
        let layout = grid
        let loudness = settings.mode == ETAnalogMeter.loudnessMode
        // 統計は空いている枠に置く。無ければ針の下に帯を足す（畳んだ図には足さない）。
        let band: CGFloat = loudness && !ETAnalogMeter.hasEmptySlot(layout) && !graphOnly ? Self.statsBand : 0
        let plotHeight = max(60, cellHeight(cellWidth: width / CGFloat(layout.columns), layout) * CGFloat(layout.rows)) + band
        VStack(alignment: .leading, spacing: 8) {
            Canvas { context, size in
                draw(&context, CGRect(origin: .zero, size: size), reading: current, grid: layout, band: band)
            }
            .frame(height: min(plotHeight, maxHeight ?? plotHeight))
            .background(AnalogMeterPalette.face)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { newWidth in
                if newWidth > 0 && abs(newWidth - width) > 0.5 { width = newWidth }
            }
            .padding(Self.bezelWidth)
            .background(AnalogMeterPalette.bezel, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            // 幅に余りがあれば中央に置く（針の数ぶんの幅で止め、左に寄せない）。
            .frame(maxWidth: min(CGFloat(layout.columns) * 320, 1024) + Self.bezelWidth * 2)
            .frame(maxWidth: .infinity)
            if loudness && !graphOnly {
                ETMeasurementButton(title: "Reset") {
                    dsp.resetState(at: index)
                    holds = []
                }
            }
        }
        .onChange(of: current?.sequence) { _, _ in advance() }
        .onChange(of: settings.mode) { _, _ in holds = [] }
    }

    /// 新しい枠が来たときだけ、保持を進める。
    private func advance() {
        guard let r = reading else { return }
        if r.channelCount != channelCount {
            channelCount = r.channelCount
            holds = []
        }
        guard ETAnalogMeter.holdsPeak(mode: r.mode) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var next = holds
        while next.count < r.channelCount {
            next.append(ETAnalogMeter.Hold(db: .nan, time: now, overTime: nil))
        }
        for (i, channel) in r.channels.enumerated() {
            next[i] = ETAnalogMeter.updateHold(next[i], db: channel.maxDB, now: now,
                                               holdSeconds: settings.peakHold)
        }
        holds = next
    }

    // MARK: 描く

    private func draw(_ context: inout GraphicsContext, _ rect: CGRect,
                      reading: ETAnalogMeter.Reading?, grid: ETAnalogMeter.Grid, band: CGFloat) {
        let cells = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(0, rect.height - band))
        let cellWidth = cells.width / CGFloat(grid.columns)
        let cellHeight = cells.height / CGFloat(grid.rows)
        let modeName = ETAnalogMeter.modes[settings.mode]
        let scale = ETAnalogMeter.scale(mode: modeName, settings: settings)
        let loudness = settings.mode == ETAnalogMeter.loudnessMode
        let now = ProcessInfo.processInfo.systemUptime
        func box(_ cell: Int) -> CGRect {
            CGRect(x: cells.minX + CGFloat(cell % grid.columns) * cellWidth,
                   y: cells.minY + CGFloat(cell / grid.columns) * cellHeight,
                   width: cellWidth, height: cellHeight)
        }
        for cell in 0..<grid.cells {
            drawCell(&context, scale: scale, box: box(cell), channel: loudness ? cell - 1 : cell,
                     reading: reading, now: now)
        }
        guard loudness else { return }
        // 読みが無いときも表は出す（空の枠にしない・読みが来ても大きさが変わらない）。
        let rows: [(label: String, value: String)]
        if let reading, let program = reading.program {
            rows = ETAnalogMeter.statRows(program: program, integratedValid: reading.integratedValid,
                                          lraValid: reading.lraValid)
        } else {
            rows = ETAnalogMeter.emptyStatRows
        }
        if ETAnalogMeter.hasEmptySlot(grid) {
            let slot = box(grid.cells)
            drawFrame(&context, slot)
            drawStats(&context, rows: [rows], in: slot)
        } else if band > 0 {
            let strip = CGRect(x: rect.minX, y: cells.maxY, width: rect.width, height: band)
            drawFrame(&context, strip)
            drawStats(&context, rows: [Array(rows[0..<3]), Array(rows[3..<6])], in: strip)
        }
    }

    private static let frameInset: CGFloat = 4

    private func drawFrame(_ context: inout GraphicsContext, _ box: CGRect) {
        context.stroke(Path(box.insetBy(dx: Self.frameInset, dy: Self.frameInset)),
                       with: .color(AnalogMeterPalette.grid), lineWidth: 1)
    }

    private func text(_ context: inout GraphicsContext, _ s: String, size: CGFloat,
                      at point: CGPoint, anchor: UnitPoint, color: Color,
                      weight: Font.Weight = .regular, monospaced: Bool = false) {
        let font: Font = monospaced ? .system(size: size, weight: weight, design: .monospaced)
                                    : .system(size: size, weight: weight)
        context.draw(Text(s).font(font).foregroundStyle(color), at: point, anchor: anchor)
    }

    /// 字の底（ベースライン）を `baseline` に置いて描く。大きさの違う字を同じ線に並べるのに使う。
    /// `alignX` は 0 で左端、0.5 で中央、1 で右端を `x` に合わせる。描いた字の幅を返す。
    @discardableResult
    private func baselineText(_ context: inout GraphicsContext, _ s: String, size: CGFloat,
                              x: CGFloat, baseline: CGFloat, alignX: CGFloat, color: Color,
                              weight: Font.Weight = .regular, monospaced: Bool = false) -> CGFloat {
        let font: Font = monospaced ? .system(size: size, weight: weight, design: .monospaced)
                                    : .system(size: size, weight: weight)
        let resolved = context.resolve(Text(s).font(font).foregroundStyle(color))
        let room = CGSize(width: 10_000, height: 10_000)
        let width = resolved.measure(in: room).width
        let ascent = resolved.firstBaseline(in: room)
        context.draw(resolved, at: CGPoint(x: x - width * alignX, y: baseline - ascent), anchor: .topLeading)
        return width
    }

    /// 1 つの針（drawCell、analog_meter.js:577-720）。
    private func drawCell(_ context: inout GraphicsContext, scale: ETAnalogMeter.Scale, box: CGRect,
                          channel: Int, reading: ETAnalogMeter.Reading?, now: Double) {
        let inset = Self.frameInset
        let arc = Self.arc
        let grid = AnalogMeterPalette.grid
        let label = AnalogMeterPalette.label
        let primary = AnalogMeterPalette.text
        let danger = AnalogMeterPalette.danger
        let loudness = settings.mode == ETAnalogMeter.loudnessMode

        // 枠。
        drawFrame(&context, box)

        let metrics = cellMetrics(boxWidth: box.width, scale: scale, loudness: loudness)
        let fontSize = metrics.fontSize
        // 読み値。Loudness の Program だけは主役なので大きく、他の針も 11pt を下回らない。
        let programReadout = metrics.programReadout
        let readoutSize: CGFloat = loudness && channel < 0 ? programReadout : max(fontSize, 11)
        // 読み値の字の底（ベースライン）は同じ行の針で共通にする。大きい Program の読みも
        // 小さい針の読みも、-∞ も、同じ線に乗る。軸の根元は読みの背丈ぶんだけ上に置くので、
        // 大きい読み値の空きを取るのは Program の針だけ。
        let readoutBaseline = box.maxY - inset - 5
        let pivotX = box.minX + box.width / 2
        // 軸の根元と半径は、同じ図の中でいちばん大きい読み値（Loudness は Program）で決める。
        // 針ごとに変えると、同じ行の軸と針の長さがそろわない（上流は全セル同じ形）。
        let pivotY = box.maxY - metrics.bottomOffset
        let topLimit = box.minY + metrics.topOffset
        let radius = max(8, min(metrics.widthRadius, pivotY - topLimit))

        func angle(_ position: Double) -> Double { -arc + 2 * arc * position }
        func point(_ position: Double, _ distance: CGFloat) -> CGPoint {
            let a = angle(position)
            return CGPoint(x: pivotX + CGFloat(sin(a)) * distance,
                           y: pivotY - CGFloat(cos(a)) * distance)
        }
        func arcPath(_ from: Double, _ to: Double, _ distance: CGFloat) -> Path {
            var path = Path()
            let steps = 48
            for i in 0...steps {
                let p = point(from + (to - from) * Double(i) / Double(steps), distance)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            return path
        }

        // 弧と赤い帯と目盛り。
        context.stroke(arcPath(0, 1, radius), with: .color(label), lineWidth: 1)
        if let red = scale.redFrom {
            context.stroke(arcPath(scale.valuePosition(red), 1, radius + 2),
                           with: .color(danger), lineWidth: 3)
        }
        // 隣の字がぶつかるときは、基準から数えて 1 つおきにする（analog_meter.js:849-860）。
        let labelRadius = radius + 9
        let labeled = scale.ticks.filter { !$0.label.isEmpty }
        var widest: CGFloat = 0
        var spacing = CGFloat.infinity
        for (i, tick) in labeled.enumerated() {
            let w = CGFloat(tick.label.count) * fontSize * 0.85 * 0.6
            widest = max(widest, w)
            guard i > 0 else { continue }
            let step = abs(scale.valuePosition(tick.value) - scale.valuePosition(labeled[i - 1].value))
            // 2.13.0 は隣の字の点の間の弦で測る（弧の長さでなく。analog_meter.js:857 の hypot）。
            spacing = min(spacing, CGFloat(2 * Double(labelRadius) * sin(arc * step)))
        }
        let kept: Set<Double>? = spacing < widest + fontSize * 0.3 ? ETAnalogMeter.sparseLabels(scale) : nil
        for tick in scale.ticks {
            let position = scale.valuePosition(tick.value)
            let major = !tick.label.isEmpty
            let emphasized = ETAnalogMeter.isEmphasized(tick.value, in: scale)
            var mark = Path()
            mark.move(to: point(position, radius))
            mark.addLine(to: point(position, radius + (major ? 7 : 4)))
            context.stroke(mark, with: .color(emphasized ? primary : label),
                           lineWidth: emphasized ? 2 : 1)
            if !major { continue }
            if let kept, !kept.contains(tick.value) { continue }
            // 字の箱は目盛りの向きに外へ張り出す位置で止める。端の字が自分の目盛りに乗らない。
            let a = angle(position)
            let anchor = UnitPoint(x: 0.5 - 0.5 * sin(a), y: 0.5 + 0.5 * cos(a))
            text(&context, tick.label, size: fontSize * 0.85, at: point(position, labelRadius),
                 anchor: anchor, color: emphasized ? primary : label)
        }

        // 見出しとモード。
        let holdMode = ETAnalogMeter.holdsPeak(mode: settings.mode)
        let channelCount = reading?.channelCount ?? self.channelCount
        let title = ETAnalogMeter.cellTitle(channel: channel, mode: settings.mode, channelCount: channelCount)
        text(&context, title, size: fontSize, at: CGPoint(x: box.minX + inset * 2, y: box.minY + inset * 2),
             anchor: .topLeading, color: primary, weight: .bold)
        let modeLabel: String
        if loudness {
            modeLabel = settings.needle == 1 ? "Short-term" : "Momentary"
        } else if ETAnalogMeter.modes[settings.mode] == "PPM" {
            modeLabel = "PPM \(ETAnalogMeter.ppmScales[settings.ppmScale])"
        } else {
            modeLabel = ETAnalogMeter.modes[settings.mode]
        }
        // 狭い針では見出しとぶつかるので、入らないときはモードを出さない。
        let lampWidth = holdMode ? fontSize * 1.2 : 0
        let titleWidth = CGFloat(title.count) * fontSize * 0.62
        let modeWidth = CGFloat(modeLabel.count) * fontSize * 0.85 * 0.55
        if titleWidth + modeWidth + lampWidth + inset * 4 + fontSize <= box.width {
            text(&context, modeLabel, size: fontSize * 0.85,
                 at: CGPoint(x: box.maxX - inset * 2 - lampWidth, y: box.minY + inset * 2),
                 anchor: .topTrailing, color: label)
        }

        // ピークホールドと 0 dBFS を越えたときのランプ。
        let hold: ETAnalogMeter.Hold? = channel >= 0 && holds.indices.contains(channel) ? holds[channel] : nil
        if holdMode {
            let lampRadius = fontSize * 0.4
            let lamp = CGRect(x: box.maxX - inset * 2 - lampRadius * 2,
                              y: box.minY + inset * 2 + fontSize * 0.5 - lampRadius,
                              width: lampRadius * 2, height: lampRadius * 2)
            if ETAnalogMeter.isOverLit(hold, now: now, holdSeconds: settings.peakHold) {
                context.fill(Path(ellipseIn: lamp), with: .color(danger))
            } else {
                context.stroke(Path(ellipseIn: lamp), with: .color(grid), lineWidth: 1)
            }
            if settings.peakHold > 0, let hold, hold.db.isFinite, hold.db > ETAnalogMeter.silenceDB {
                let position = scale.dbPosition(hold.db)
                var mark = Path()
                mark.move(to: point(position, radius * 0.86))
                mark.addLine(to: point(position, radius))
                context.stroke(mark, with: .color(danger), lineWidth: 3)
            }
        }

        // 針。届いた値のまま（バリスティクスは DSP が済ませている）。
        let db = ETAnalogMeter.cellReading(channel: channel, reading: reading,
                                           mode: settings.mode, needle: settings.needle)
        let needlePosition = db.map { scale.dbPosition($0) } ?? 0
        var needle = Path()
        needle.move(to: CGPoint(x: pivotX, y: pivotY))
        needle.addLine(to: point(needlePosition, radius * 1.02))
        context.stroke(needle, with: .color(primary), lineWidth: 2)
        context.fill(Path(ellipseIn: CGRect(x: pivotX - 3, y: pivotY - 3, width: 6, height: 6)),
                     with: .color(primary))

        // 読み値。
        let readout = db.map { scale.readout($0) } ?? "---"
        let readoutWeight: Font.Weight = loudness && channel < 0 ? .semibold : .regular
        if readout.contains("∞") {
            // 等幅の ∞ は数字の半分の高さで細い。通常の書体で 1.3 倍にして数字の背丈にそろえる。
            baselineText(&context, readout, size: readoutSize * 1.3, x: pivotX, baseline: readoutBaseline,
                         alignX: 0.5, color: primary, weight: readoutWeight)
        } else {
            baselineText(&context, readout, size: readoutSize, x: pivotX, baseline: readoutBaseline,
                         alignX: 0.5, color: primary, weight: readoutWeight, monospaced: true)
        }
    }

    /// Program の統計。上流の drawProgramStats（:722-766）は針の下の両隅だが、狭いと
    /// 読めないので、空いた枠か針の下の帯に固定の大きさで出す。見本の幅で組むので、
    /// 値が変わっても表は動かない。
    /// `rows` が 1 つなら 6 行の表を枠の中央に、2 つなら 3 行ずつを横に並べて中央に置く。
    private func drawStats(_ context: inout GraphicsContext,
                           rows tables: [[(label: String, value: String)]], in box: CGRect) {
        let size = Self.statsSize
        func measure(_ s: String) -> CGFloat { CGFloat(s.count) * size * 0.6 }
        let lineHeight = min(Self.statsLine, (box.height - Self.frameInset * 2) / (CGFloat(tables[0].count) + 0.6))
        let labelWidth = measure("Time")
        let valueWidth = measure("-88.8 LUFS")
        let gap = size * 0.7
        let tableWidth = labelWidth + gap + valueWidth
        let spacing = size * 2.4
        let total = tableWidth * CGFloat(tables.count) + spacing * CGFloat(tables.count - 1)
        var left = box.midX - total / 2
        for rows in tables {
            let top = box.midY - lineHeight * CGFloat(rows.count) / 2
            for (row, entry) in rows.enumerated() {
                let y = top + (CGFloat(row) + 0.5) * lineHeight
                // 行の字の底は 1 本に。大きい ∞ も数字と同じ線に乗る。
                let baseline = y + size * 0.35
                baselineText(&context, entry.label, size: size, x: left, baseline: baseline,
                             alignX: 0, color: AnalogMeterPalette.label, monospaced: true)
                drawStatValue(&context, entry.value, size: size, right: left + tableWidth, baseline: baseline)
            }
            left += tableWidth + spacing
        }
    }

    /// 統計の値を右端 `right` にそろえて描く。"-∞ LUFS" は ∞ だけ通常の書体の 1.3 倍にして、
    /// 単位は等幅のまま（読み値の ∞ と同じ扱い）。
    private func drawStatValue(_ context: inout GraphicsContext, _ value: String,
                               size: CGFloat, right: CGFloat, baseline: CGFloat) {
        let color = AnalogMeterPalette.text
        guard let infinity = value.firstIndex(of: "∞") else {
            baselineText(&context, value, size: size, x: right, baseline: baseline,
                         alignX: 1, color: color, monospaced: true)
            return
        }
        let split = value.index(after: infinity)
        let head = String(value[..<split])
        let tail = String(value[split...])
        let tailWidth = tail.isEmpty ? 0
            : baselineText(&context, tail, size: size, x: right, baseline: baseline,
                           alignX: 1, color: color, monospaced: true)
        baselineText(&context, head, size: size * 1.3, x: right - tailWidth, baseline: baseline,
                     alignX: 1, color: color)
    }
}
