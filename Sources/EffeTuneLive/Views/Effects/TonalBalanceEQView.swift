//  TonalBalanceEQView.swift
//  Tonal Balance EQ（TonalBalanceEQPlugin）。聴いている音の帯域ごとの釣り合いを学習済みの目標曲線へ
//  ゆっくり寄せる EQ。2.12.0 で増えたもの。上流は plugins/eq/tonal_balance_eq.js。
//
//  図は 41 本の ERB 帯域の中心を横に、dB を縦にとる。
//    目標（平均 ± ばらつきの帯）・Target adjust の曲線・測った値・EQ の応答・保留した持ち上げ
//  を重ねる。Target adjust は 5 本の印（pk / ls / hs）を掴んで動かす。
//  値の計算は DSP/TonalBalanceModel.swift（枠の読み・補間・曲線・縦軸の追従）。
//
//  上流との違い:
//    - 印の編集は 5Band PEQ の画面と同じ作り（印を掴む＋選んだ 1 本のスライダー）にした。
//      上流は Room EQ の Additional EQ の編集部品を借りている（plot ホスト）。
//    - 「Copy as PEQ」（測った EQ 曲線を 5Band PEQ に当てはめて貼り付け用にコピーする）は入れていない。
//      当てはめは features/measurement/peq-calculator の移植が要る。docs/notes/effetune-2.12.0.md。
//    - 凡例とカーソルの読み値は無い（指でなぞる読み値はこのアプリの他の図と同じく図の上の 1 行）。
//
//  mp（測定の一時停止）は上流の画面にも保存形式にも無く、ライブラリの bindings だけが立てる
//  実行時の旗。ETParam.runtimeOnly の印で保存にも鎖にも出ない。ここでも触らない。

import SwiftUI

struct TonalBalanceEQView: View {

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    @Environment(\.etGraphOnly) private var graphOnly
    @State private var selected = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TonalBalanceFigure(index: index, node: node, dsp: dsp, selected: $selected)
            if !graphOnly {
                bandStrip
                Divider()
                bandPanel
                Divider()
                rows
            }
        }
    }

    // MARK: つまみの行（上流の並び: Target → Slope → Corner → Amount → Range → Smoothing →
    //                    Averaging Time → Low → High → Average SPL。tonal_balance_eq.js:557-577）

    private var layout: TonalBalanceLayout { TonalBalanceLayout(node.spec) }

    private var targetIsTilt: Bool {
        Int(layout.value(node.values, "tg").rounded()) == ETTonalBalance.targets.firstIndex(of: "Tilt")
    }

    /// Amount が 0 のとき、Range / Smoothing / Low / High は何も決めない（syncControlStates）。
    private var amountIsZero: Bool { layout.value(node.values, "am") == 0 }

    @ViewBuilder private var rows: some View {
        row("tg")
        if targetIsTilt {
            row("ts")
            row("tc")
        }
        row("am")
        row("rg", disabled: amountIsZero, trimsZeros: true)
        row("sm", disabled: amountIsZero, trimsZeros: true)
        if let p = layout.param("at") {
            TonalAveragingRow(index: index, param: p, values: node.values, dsp: dsp)
        }
        row("lo", disabled: amountIsZero)
        row("hi", disabled: amountIsZero)
        row("sp")
    }

    @ViewBuilder
    private func row(_ key: String, disabled: Bool = false, trimsZeros: Bool = false) -> some View {
        if let p = layout.param(key) {
            ParameterRow(param: p, nodeIndex: index, values: node.values, dsp: dsp, trimsZeros: trimsZeros)
                .disabled(disabled)
                .opacity(disabled ? 0.45 : 1)
        }
    }

    // MARK: Target adjust のバンド

    private var bandStrip: some View {
        HStack(spacing: 6) {
            ForEach(0..<layout.adjustCount, id: \.self) { i in
                chip(i)
            }
        }
    }

    private func chip(_ i: Int) -> some View {
        let band = layout.band(node.values, i)
        let picked = selected == i
        return Button { selected = i } label: {
            Text("\(i + 1)")
                .etFont(size: 13, weight: picked ? .bold : .regular)
                .foregroundStyle(picked ? AnyShapeStyle(.white)
                                        : (band.enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)))
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(picked ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                            in: .rect(cornerRadius: ETMetrics.innerRadius, style: .continuous))
                .opacity(band.enabled ? 1 : 0.45)
                // 見た目は高さ 30 のまま、押せる面だけを 44pt まで広げる。
                // 横は隣の札との隙間（6pt）を半分ずつ使い、重ならないようにする。
                .padding(.vertical, 7)
                .padding(.horizontal, 3)
                .contentShape(.rect)
                .padding(.vertical, -7)
                .padding(.horizontal, -3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Band \(i + 1)")
        // 切ってあるバンドは不透明度だけで表しているので、VoiceOver には値として伝える。
        .accessibilityValue(band.enabled ? "" : "Off")
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    private static let typeNames = ["Peaking", "Low Shelf", "High Shelf"]

    private var bandPanel: some View {
        let i = min(selected, max(layout.adjustCount - 1, 0))
        let band = layout.band(node.values, i)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("BAND \(i + 1)")
                    .etFont(size: 10, weight: .semibold)
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { band.type }, set: { setType($0, band: i) })) {
                    ForEach(Array(Self.typeNames.indices), id: \.self) { t in
                        Text(Self.typeNames[t]).tag(t)
                    }
                }
                .pickerStyle(.menu)
                Spacer(minLength: 0)
                Toggle("Enabled", isOn: Binding(
                    get: { band.enabled },
                    set: { _ in set("ea", band: i, band.enabled ? 0 : 1) }))
                    .toggleStyle(.power)
                    .labelsHidden()
            }
            PEQ5SliderRow(title: "Freq", value: band.frequency, range: 20...20000,
                          logarithmic: true, decimals: 0, unit: "Hz") { v in
                set("fa", band: i, Float(v))
            }
            PEQ5SliderRow(title: "Gain", value: band.gain, range: -20...20,
                          logarithmic: false, decimals: 1, unit: "dB") { v in
                set("ga", band: i, Float(v))
            }
            PEQ5SliderRow(title: "Q", value: band.q,
                          range: 0.1...ETTonalBalance.maximumQ(type: band.type),
                          logarithmic: false, decimals: 2, unit: "") { v in
                set("qa", band: i, Float(v))
            }
        }
    }

    private func set(_ key: String, band: Int, _ value: Float) {
        guard let p = layout.param(key) else { return }
        dsp.setValue(value, at: index, offset: p.offset + band)
    }

    /// 型を変えたら、シェルフのときだけ Q を 2 に丸める（tonal_balance_eq.js:331-336）。
    private func setType(_ type: Int, band: Int) {
        set("ta", band: band, Float(type))
        let current = layout.band(node.values, band)
        let limit = ETTonalBalance.maximumQ(type: type)
        if current.q > limit { set("qa", band: band, Float(limit)) }
    }
}

// MARK: - packed float 配列での位置

/// 名前は params.json と生成された TonalBalanceEQPluginParams.h で揃っている。
struct TonalBalanceLayout {
    let spec: ETEffect

    init(_ spec: ETEffect) { self.spec = spec }

    func param(_ key: String) -> ETParam? { spec.params.first { $0.key == key } }

    func value(_ values: [Float], _ key: String, band: Int = 0) -> Double {
        guard let p = param(key), values.indices.contains(p.offset + band) else { return 0 }
        return Double(values[p.offset + band])
    }

    var adjustCount: Int { param("fa")?.count ?? ETTonalBalance.adjustFrequencies.count }

    func band(_ values: [Float], _ i: Int) -> ETTonalBalance.AdjustBand {
        let type = Int(value(values, "ta", band: i).rounded())
        return ETTonalBalance.AdjustBand(
            enabled: value(values, "ea", band: i) >= 0.5,
            type: min(max(type, 0), ETTonalBalance.adjustTypes.count - 1),
            frequency: value(values, "fa", band: i),
            gain: value(values, "ga", band: i),
            q: value(values, "qa", band: i))
    }

    func bands(_ values: [Float]) -> [ETTonalBalance.AdjustBand] {
        (0..<adjustCount).map { band(values, $0) }
    }
}

// MARK: - Averaging Time

/// 対数のスライダーで、一番上が ∞（Reset からの全部の平均）。上流の createAveragingTimeControl
/// （tonal_balance_eq.js:483-536）。打ち込みは秒。100 は ∞。
private struct TonalAveragingRow: View {
    let index: Int
    let param: ETParam
    let values: [Float]
    @ObservedObject var dsp: EffeTuneDSP

    private var seconds: Double {
        values.indices.contains(param.offset) ? Double(values[param.offset]) : 30
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Averaging Time (s)")
                    .etFont(size: 14)
                    .etRowTitle()
                Spacer(minLength: 4)
                ETValueField(text: ETTonalBalance.formatAveragingTime(seconds),
                             label: "Averaging Time",
                             editText: { ETNumberText.draft(seconds) }) { typed in
                    // "inf" は Double に読める。100 以上は ∞。
                    commit(typed.isNaN ? seconds : min(max(typed, ETTonalBalance.averagingTimeMinimum),
                                                       ETTonalBalance.averagingTimeInfinite))
                }
            }
            Slider(value: Binding(
                get: { min(max(ETTonalBalance.averagingTimeToSliderPosition(seconds), 0), 100) },
                set: { commit(ETTonalBalance.sliderPositionToAveragingTime($0)) }),
                   in: 0...100, step: 0.1)
                .accessibilityLabel("Averaging Time")
                .accessibilityValue(ETTonalBalance.formatAveragingTime(seconds))
        }
        .padding(.vertical, 2)
    }

    private func commit(_ v: Double) {
        dsp.setValue(Float(v), at: index, offset: param.offset)
    }
}

// MARK: - 図

/// 図と印。テレメトリを観測するのはこの中だけ（つまみの行を 30Hz で作り直さない）。
private struct TonalBalanceFigure: View {

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP
    @Binding var selected: Int

    @ETTelemetryFeed private var telemetry
    @Environment(\.etGraphOnly) private var graphOnly
    /// 「色以外で区別」。目標・測定値・応答の 3 本を色だけで見分けている人のために、
    /// 目標を破線、測定値を点線にする。普段の見た目は変えない。
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    /// 縦軸（dB）。6 dB きざみで広がり、縮むのは Reset と Target の変更のときだけ。
    @State private var dbTop = ETTonalBalance.defaultDbRange
    @State private var dbBottom = -ETTonalBalance.defaultDbRange
    @State private var dragging: Int?
    @State private var dragged: ETFreqPoint?

    private var layout: TonalBalanceLayout { TonalBalanceLayout(node.spec) }

    /// EQ の応答の線と、保留した持ち上げの色（上流の --et-graph-trace）。測った線は tint なので、
    /// 交わる所でも見分けがつく。
    private static let traceGreen = Color(red: 0, green: 1, blue: 0)

    private var targetIndex: Int {
        min(max(Int(layout.value(node.values, "tg").rounded()), 0), ETTonalBalance.targets.count - 1)
    }

    /// 前の Target を描いた枠は、カーネルが追いつくまで捨てる（handleTelemetry、:451-454）。
    private var reading: ETTonalBalance.Reading? {
        guard let r = ETTonalBalance.parse(telemetry.frame(tap: node.tapId, type: .tonalBalance)),
              r.targetIndex == targetIndex else { return nil }
        return r
    }

    /// 音が通るレート。枠が届く前は DSP を回しているレート（上流は 48000 へ落とす）。
    private func sampleRate(_ r: ETTonalBalance.Reading?) -> Double {
        if let r { return r.sampleRate }
        let rate = AudioIO.shared.processingRate
        return rate > 0 ? rate : 48000
    }

    private static let figureHeight: CGFloat = 230

    var body: some View {
        let r = reading
        let bands = layout.bands(node.values)
        let amount = layout.value(node.values, "am") / 100
        let range = layout.value(node.values, "rg")
        let low = layout.value(node.values, "lo")
        let high = layout.value(node.values, "hi")
        let display = r.map { ETTonalBalance.display(reading: $0, range: range, amount: amount) }
        let adjust = ETTonalBalance.adjustCurve(bands: bands, sampleRate: sampleRate(r))
        let top = dbTop, bottom = dbBottom
        let span = top - bottom
        let step: Double = span <= 36 ? 6 : (span <= 72 ? 12 : 24)

        let lower = pow(10, ETTonalBalance.logMin)
        let upper = pow(10, ETTonalBalance.logMin + ETTonalBalance.logSpan)
        let ticks = ETTonalBalance.freqTicks
            .filter { $0 >= lower && $0 <= upper && $0 >= 50 && $0 <= 10000 }
            .map { ETAxisTick($0, ETFormat.hzTick($0)) }
        let xAxis = ETAxis(scale: .logarithmic, lower: lower, upper: upper, ticks: ticks)

        VStack(alignment: .leading, spacing: 8) {
            GraphCanvas(
                x: xAxis, y: .decibels(bottom...top, step: step),
                height: Self.figureHeight,
                readout: readout(r),
                caption: nil,
                clipsContent: true,
                draw: { context, plot in
                    drawFigure(&context, plot, display: display, adjust: adjust,
                               low: low, high: high, top: top, bottom: bottom,
                               dashed: differentiateWithoutColor)
                },
                overlay: { plot in
                    markersOverlay(plot, bands: bands)
                })
            if !graphOnly {
                // 手元の音の平均を消す。PC の鎖を編集しているあいだは出さない（上流 2.14.0）。
                ETMeasurementButton(title: "Reset") {
                    dsp.resetState(at: index)
                    dbTop = ETTonalBalance.defaultDbRange
                    dbBottom = -ETTonalBalance.defaultDbRange
                }
                .etLocalAudioOnly()
            }
        }
        .onAppear { updateRange() }
        .onChange(of: r?.sequence) { _, _ in updateRange() }
        .onChange(of: bands) { _, _ in updateRange() }
        .onChange(of: targetIndex) { _, _ in
            dbTop = ETTonalBalance.defaultDbRange
            dbBottom = -ETTonalBalance.defaultDbRange
        }
    }

    /// 縦軸を広げる。印を掴んでいる間は動かさない（指の下で図がずれる）。離したときに合わせ直す。
    private func updateRange() {
        guard dragging == nil else { return }
        let r = reading
        let bands = layout.bands(node.values)
        let display = r.map {
            ETTonalBalance.display(reading: $0, range: layout.value(node.values, "rg"),
                                   amount: layout.value(node.values, "am") / 100)
        }
        let adjust = ETTonalBalance.adjustCurve(bands: bands, sampleRate: sampleRate(r))
        let fitted = ETTonalBalance.fitDbRange(top: dbTop, bottom: dbBottom, view: display,
                                               adjust: adjust, adjustBands: bands)
        if fitted.top != dbTop { dbTop = fitted.top }
        if fitted.bottom != dbBottom { dbBottom = fitted.bottom }
    }

    private func readout(_ r: ETTonalBalance.Reading?) -> [ETReadoutItem] {
        if let p = dragged, let id = dragging {
            return [ETReadoutItem("BAND", "\(id + 1)"),
                    ETReadoutItem("FREQ", ETFormat.hz(p.hz)),
                    ETReadoutItem("GAIN", ETFormat.gain(p.db))]
        }
        guard let r else { return [] }
        var items = [ETReadoutItem("MAKE-UP", ETFormat.gain(r.makeup))]
        if r.loudnessIsValid {
            items.append(ETReadoutItem("LOUDNESS", String(format: "%.1f LKFS", r.loudness)))
        }
        return items
    }

    // MARK: 描く

    private func drawFigure(_ context: inout GraphicsContext, _ plot: ETPlot,
                            display: ETTonalBalance.Display?, adjust: [Double],
                            low: Double, high: Double, top: Double, bottom: Double,
                            dashed: Bool) {
        let rect = plot.rect
        let span = top - bottom
        func toX(_ logFrequency: Double) -> CGFloat {
            rect.minX + CGFloat((logFrequency - ETTonalBalance.logMin) / ETTonalBalance.logSpan) * rect.width
        }
        func toY(_ db: Double) -> CGFloat {
            rect.minY + CGFloat((top - db) / span) * rect.height
        }

        // Low–High の外の帯域は端の補正を持つだけなので、薄く覆う。
        let veil = Color.secondary.opacity(0.14)
        let lowX = min(max(toX(log10(max(low, 1))), rect.minX), rect.maxX)
        let highX = min(max(toX(log10(max(high, 1))), rect.minX), rect.maxX)
        context.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: lowX - rect.minX, height: rect.height)),
                     with: .color(veil))
        context.fill(Path(CGRect(x: highX, y: rect.minY, width: rect.maxX - highX, height: rect.height)),
                     with: .color(veil))

        func stroke(_ logFrequencies: [Double], _ values: [Double], _ shading: GraphicsContext.Shading,
                    width: CGFloat, dash: [CGFloat] = [], in context: inout GraphicsContext) {
            var path = Path()
            var drawing = false
            for (i, value) in values.enumerated() {
                guard value.isFinite else { drawing = false; continue }
                let p = CGPoint(x: toX(logFrequencies[i]), y: toY(value))
                if drawing { path.addLine(to: p) } else { path.move(to: p) }
                drawing = true
            }
            context.stroke(path, with: shading,
                           style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: dash))
        }

        /// 有限な点が続く所ごとに、low と high に挟まれた面を塗る。
        func fillRuns(_ lowValues: [Double], _ highValues: [Double], _ shading: GraphicsContext.Shading,
                      in context: inout GraphicsContext) {
            let xs = ETTonalBalance.curveLogFreqs
            var start = 0
            while start < xs.count {
                guard lowValues[start].isFinite else { start += 1; continue }
                var end = start
                while end + 1 < xs.count && lowValues[end + 1].isFinite { end += 1 }
                var path = Path()
                for i in start...end {
                    let p = CGPoint(x: toX(xs[i]), y: toY(highValues[i]))
                    if i == start { path.move(to: p) } else { path.addLine(to: p) }
                }
                for i in stride(from: end, through: start, by: -1) {
                    path.addLine(to: CGPoint(x: toX(xs[i]), y: toY(lowValues[i])))
                }
                path.closeSubpath()
                context.fill(path, with: shading)
                start = end + 1
            }
        }

        if let display {
            let c = display.curves
            let xs = ETTonalBalance.curveLogFreqs
            fillRuns(c.targetLow, c.targetHigh, .color(Color.secondary.opacity(0.22)), in: &context)
            // 保留した持ち上げは薄い。上の縁だけ 1 本引いて見えるようにする。
            fillRuns(c.withheldLow, c.withheldHigh, .color(Self.traceGreen.opacity(0.15)), in: &context)
            stroke(xs, c.withheldEdge, .color(Self.traceGreen.opacity(0.8)), width: 1, in: &context)
            stroke(xs, c.target, ETGraphShading.overlayCompare, width: 1.5,
                   dash: dashed ? [5, 4] : [], in: &context)
            stroke(xs, c.measured, ETGraphShading.overlay, width: 1.5,
                   dash: dashed ? [1, 3] : [], in: &context)
            for band in 0..<ETTonalBalance.bands where display.measured[band].isFinite {
                let center = CGPoint(x: toX(ETTonalBalance.bandLogFreqs[band]), y: toY(display.measured[band]))
                context.fill(Path(ellipseIn: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)),
                             with: ETGraphShading.overlay)
            }
            stroke(ETTonalBalance.gridLogFreqs, display.response, .color(Self.traceGreen), width: 2, in: &context)
        } else {
            // 0 dB の線の上。既定の印と Target adjust の曲線が居る所の上。
            context.draw(Text("Play audio to start measuring")
                            .font(.system(size: 12)).foregroundStyle(.secondary),
                         at: CGPoint(x: rect.midX, y: rect.minY + rect.height / 4), anchor: .center)
        }
        stroke(ETTonalBalance.adjustLogFreqs, adjust, ETGraphShading.muted, width: 1, in: &context)
    }

    // MARK: 印

    @ViewBuilder
    private func markersOverlay(_ plot: ETPlot, bands: [ETTonalBalance.AdjustBand]) -> some View {
        if !graphOnly {
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(drag(in: plot, bands: bands))
                    .etOwnsDrag()
                ForEach(Array(bands.enumerated()), id: \.offset) { i, band in
                    badge(i, band)
                        .position(plot.clampedPoint(band.frequency, band.gain))
                        .allowsHitTesting(false)
                        // 印は指でつかむ絵。VoiceOver ではバンドの札と下のスライダーが操作の道なので、
                        // 数字だけの要素を並べて邪魔しない。
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private func badge(_ i: Int, _ band: ETTonalBalance.AdjustBand) -> some View {
        let held = dragging == i
        let active = band.enabled
        return Text("\(i + 1)")
            // 22pt の丸に収まる字なので文字サイズ設定には追従させない（軸の目盛りと同じ扱い）。
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .frame(width: 22, height: 22)
            .background(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: Circle())
            .overlay(Circle().stroke(.tint, lineWidth: held ? 2 : 0).scaleEffect(held ? 1.4 : 1))
    }

    private func drag(in plot: ETPlot, bands: [ETTonalBalance.AdjustBand]) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragging == nil {
                    // 掴んだ位置にいちばん近い印を選ぶ。
                    let nearest = bands.indices.min { a, b in
                        distance(value.startLocation, plot.clampedPoint(bands[a].frequency, bands[a].gain))
                            < distance(value.startLocation, plot.clampedPoint(bands[b].frequency, bands[b].gain))
                    }
                    dragging = nearest
                    if let nearest { selected = nearest }
                }
                guard let id = dragging else { return }
                let v = plot.values(at: value.location)
                dragged = ETFreqPoint(v.x, v.y)
                move(id, hz: v.x, db: v.y)
            }
            .onEnded { _ in
                dragging = nil
                dragged = nil
                // 掴んでいる間は縦軸を動かさない。離したときに合わせ直す。
                updateRange()
            }
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)
    }

    /// 周波数とゲインが同時に動く（fa は 20〜20000、ga は -20〜20。TONAL_BALANCE_EQ_RANGES）。
    private func move(_ i: Int, hz: Double, db: Double) {
        guard let f = layout.param("fa"), let g = layout.param("ga"), i >= 0, i < f.count else { return }
        dsp.setValue(Float(min(max(hz, 20), 20000)), at: index, offset: f.offset + i)
        dsp.setValue(Float(min(max(db, -20), 20)), at: index, offset: g.offset + i)
    }
}
