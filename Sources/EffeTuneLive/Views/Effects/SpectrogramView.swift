//  SpectrogramView.swift
//  Spectrogram。縦が周波数、横が時間。新しい列が右端に入り、古い列が左へ流れる。
//
//  テレメトリ: ETFrameType.spectrogramColumn = 5、formatVersion 1
//  （kernel.cpp:21-22 の kTapSpectrogramColumn / kTelemetryVersion、
//    spectrogram.js:1-2 の SPECTROGRAM_TAP_FRAME / _TELEMETRY_VERSION）
//
//  ペイロードの並び。dsp/plugins/analyzer/spectrogram/kernel.cpp:553-556 が頭を書き、
//  同 494-495 が升目を書く。plugins/analyzer/spectrogram.js:397-411 が同じ位置を読む:
//      0             f32 sampleRate    kernel.cpp:553 / spectrogram.js:397
//      4             f32 timeSeconds   kernel.cpp:554 / spectrogram.js:398
//      8             u16 cellCount     kernel.cpp:555 / spectrogram.js:399   常に 256
//     10             u16 points        kernel.cpp:556 / spectrogram.js:400
//     12 + y         u8  intensity     kernel.cpp:494 / spectrogram.js:410
//  長さは 268 ちょうど（kernel.cpp:25 / spectrogram.js:3）。
//
//  升目 y の周波数は kernel.cpp:277-281:
//      f(y) = 10 ^ (log10(40000) - (y / 255) * (log10(40000) - log10(20)))
//  つまり y=0 が 40kHz（上）、y=255 が 20Hz（下）。20Hz〜40kHz の対数で等間隔。
//  DSP が出す升目はこの対数の並びだけで、縦軸の取り方は上流も描く側で決めている
//  （spectrogram.js:41 の this.sc、:274-280 の setFrequencyScale）。
//  Log のときは升目をそのまま縦へ引き伸ばす。Linear のときは描く前に行を読み替える
//  （spectrogram.js:15-22 の SPECTROGRAM_LINEAR_TO_CANONICAL_ROW、:224-227）。
//  読み替えた行は整数にならないので、上下の升目を混ぜる（同 229-236）。
//
//  intensity は dB ではなく 0〜255 に正規化済み（kernel.cpp:488-495）:
//      normalized = (level - dBRange) / (-dBRange) を 0..1 に丸めて *255
//  逆に読むと level = dBRange * (1 - v/255)。指で触ったときの dB はこれで戻している。
//
//  列は 1 本ずつ来る。こちら側で横に流す帯として持つ必要があるので、
//  固定長の輪（ETSpectrogramBand）に入れて、描くときは CGImage 1〜2 枚に畳んで貼る。
//  升目は 256×256 = 65536 個あるので、毎回それだけの矩形を Path に積まない。
//  **この図だけは色を持つ。**画像に配色表（ETIntensityLUT）から引いた色を入れて、
//  そのまま貼る。GraphCanvas の「色は決めない」規則からの例外で、
//  上流も同じ理由で theme-allow を付けて例外にしている（spectrogram.js:1232）。
//  表は Color（`cl`、spectrogram.js:324-330）で替える。既定の Heatmap は不透明で、
//  地を黒で塗るので、その上に乗る格子・1 秒の印・指の線も固定色で引き直す。
//  Normal は地を塗らずに透かすので、線はテーマの色のまま。
//
//  取りこぼしについて。DSP は貯まった列を writeTelemetry で全部吐く
//  （kernel.cpp:218-226）が、Telemetry は tap と種類ごとに最新の 1 枠しか残さない
//  （Telemetry.swift の poll）。読み出しは PipelineView の 1/30 秒ごとの pollTelemetry で、
//  DSP が吐くのは 60Hz（EffeTuneDSP.telemetryHz）なので、読むたびに残っているのは
//  最後の 1 列だけ。実際に帯へ入るのも 1 回につき 1 列になる。図は間引かれた時間軸になり、
//  列の幅は一定の時間を表さない。そのため横軸には目盛りを置かず、
//  いま見えている範囲が何秒ぶんかを見出しに出している。
//  1 秒の印（spectrogram.js:1031-1042）は列ごとの時刻を持っているので打てる。
//  ただし置けるのは列の境目だけで、上流のような等間隔にはならない。

import SwiftUI
import Foundation
import CoreGraphics

/// 縦軸の取り方。上流の `sc`（spectrogram.js:41、:274-280）に当たる。
/// DSP へは送らない。升目は常に対数で来るので、描く側だけの切り替えになる。
enum ETSpectrogramScale: String, CaseIterable, Identifiable {
    // **綴りは上流のまま**（spectrogram.js の `sc`）。保存形式にそのまま載せる。
    case log
    case logHQ = "log-hq"
    case linear

    var id: String { rawValue }

    /// spectrogram.js:672-675 の label。
    var label: String {
        switch self {
        case .log:    return "Log"
        case .logHQ:  return "Log (HQ)"
        case .linear: return "Linear"
        }
    }
}

/// 塗り方。上流の `cl`（spectrogram.js:47、:324-330）。
/// Spectrum Analyzer と違って Note Colors は無い（同 :325 が 'Rainbow' を弾く）。
enum ETSpectrogramColor: String, CaseIterable, Identifiable {
    // **綴りは上流のまま。**保存形式にそのまま載せる。
    case normal = "Normal"
    case heatmap = "Heatmap"

    var id: String { rawValue }

    /// spectrogram.js:763-767 の label。
    var label: String { rawValue }
}

struct SpectrogramView: View {

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    /// 図だけ出す指定。ParameterRow は自分で消える（ParameterRow.swift:128-135）が、
    /// ここで足したボタンは消えないので自分で見る。
    @Environment(\.etGraphOnly) private var graphOnly
    /// Normal の色を引くため。
    @Environment(\.self) private var environment

    @State private var scale: ETSpectrogramScale = .log
    /// 既定は Heatmap（spectrogram.js:47）。
    @State private var color: ETSpectrogramColor = .heatmap
    /// 全画面を出しているか。
    @State private var fullScreen = false
    /// 横へ回し終わるのを待っている間。
    @State private var movingToFullScreen = false
    /// 列の履歴。**@State で参照だけ持つ。**@StateObject や @ObservedObject にすると
    /// 30Hz で body が作り直されて下のボタンが固まる。図の中だけで観測する。
    /// ここに置くのは、全画面と元の図で同じ履歴を見せるため（図の側に持たせると、
    /// 全画面を開いた瞬間に空から流れ直す）。
    @State private var band = ETSpectrogramBand()

    private var effectiveScale: ETSpectrogramScale {
        let hq = node.spec.params.first(where: { $0.key == "hq" })
        return hq.map { node.values[$0.offset] >= 0.5 } == true ? .logHQ : (scale == .logHQ ? .log : scale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // **全画面の口は AU と同じ形。**図の右上に丸い札を重ね、
            // 押したら横へ回してから開く。
            ZStack(alignment: .topTrailing) {
                SpectrogramGraph(tapId: node.tapId, floorDB: floorDB,
                                 scale: effectiveScale, lut: lut, band: band)
                if !graphOnly {
                    Button {
                        movingToFullScreen = true
                        Task { @MainActor in
                            await Task.yield()
                            ETInterfaceOrientation.request(.landscapeRight)
                            for _ in 0..<40 where !ETInterfaceOrientation.isLandscape {
                                try? await Task.sleep(nanoseconds: 20_000_000)
                            }
                            fullScreen = true
                        }
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(.glass(.regular.interactive()))
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .accessibilityLabel("Full Screen")
                    .padding(8)
                }
            }
            // 上流は DB Range・Points・Color・Frequency Scale の順に並べている
            // （spectrogram.js:724-781）。同じ順にする。
            ForEach(node.spec.params.filter { $0.key != "hq" }) { param in
                ParameterRow(param: param, nodeIndex: index, values: node.values, dsp: dsp)
            }
            if !graphOnly { colorPicker }
            if !graphOnly { scalePicker }
        }
        // **畳むとこの View ごと消える。**開き直すたびに Log へ戻っていたのがこれ。
        // 上流も `sc` と `cl` をプリセットに書く（spectrogram.js:364-376）ので鎖へ持たせる。
        .etSaved($scale, key: "sc", index: index, dsp: dsp)
        .etSaved($color, key: "cl", index: index, dsp: dsp)
        .fullScreenCover(isPresented: $fullScreen, onDismiss: {
            ETInterfaceOrientation.request(.portrait)
            movingToFullScreen = false
        }) {
            SpectrogramFullScreen(tapId: node.tapId, floorDB: floorDB,
                                  scale: effectiveScale, lut: lut, band: band,
                                  isPresented: $fullScreen)
        }
    }

    /// Color に応じた表。Normal の trace はアクセント色（上流の graph-trace）。
    private var lut: ETIntensityLUT {
        switch color {
        case .heatmap: return .heatmap
        case .normal:  return .normal(trace: Color.accentColor.resolve(in: environment))
        }
    }

    /// spectrogram.js:762-770 の createRadioGroup に当たる。
    private var colorPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Color")
                .font(.system(size: 14))
            Picker("Color", selection: $color) {
                ForEach(ETSpectrogramColor.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.vertical, 2)
    }

    /// spectrogram.js:772-780 の createRadioGroup に当たる。Menu にはしない。
    private var scalePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Frequency Scale")
                .font(.system(size: 14))
            HStack(spacing: 6) {
                ForEach(ETSpectrogramScale.allCases) { option in
                    let isSelected = effectiveScale == option
                    Button {
                        scale = option
                        if let hq = node.spec.params.first(where: { $0.key == "hq" }) {
                            dsp.setValue(option == .logHQ ? 1 : 0, at: index, offset: hq.offset)
                        }
                    } label: {
                        Text(option.label)
                            .font(.system(size: 13, weight: isSelected ? .bold : .regular))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundStyle(isSelected ? AnyShapeStyle(.white)
                                                        : AnyShapeStyle(.secondary))
                            .frame(maxWidth: .infinity, minHeight: ETMetrics.hitTarget)
                            .background(isSelected ? AnyShapeStyle(.tint)
                                                   : AnyShapeStyle(.quaternary),
                                        in: .rect(cornerRadius: ETMetrics.innerRadius,
                                                  style: .continuous))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(option.label) frequency scale")
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// 縦の下端。params.json の dBRange（-144〜-48、既定 -96）。
    private var floorDB: Double {
        guard let param = node.spec.params.first(where: { $0.name == "dBRange" }),
              node.values.indices.contains(param.offset) else { return -96 }
        let v = Double(node.values[param.offset])
        guard v.isFinite else { return -96 }
        return min(-48, max(-144, v))
    }
}

// MARK: - 図

/// 図の一番内側。**Telemetry を見るのはここだけ**にしてある。
/// カード全体で観測すると 30Hz で作り直されて、下のボタンが固まる。
private struct SpectrogramGraph: View {

    let tapId: UInt32
    let floorDB: Double
    let scale: ETSpectrogramScale
    /// 帯へ渡す配色表。変わると帯が溜めた列ごと塗り直す。
    let lut: ETIntensityLUT

    /// 履歴は親が持つ。全画面と元の図で同じものを見せるため。
    @ObservedObject var band: ETSpectrogramBand
    /// 図の高さ。全画面では画面いっぱいまで渡す。
    var height: CGFloat = ETGraphMetrics.height

    @ObservedObject private var telemetry = Telemetry.shared

    @State private var probe: ETSpectrogramProbe?

    var body: some View {
        // 枠を読むのは 1 回だけ。指で触っている間も body は回るので、
        // 268 バイトの解きほぐしを 1 回の描き直しに何度もやらない。
        let column = self.column
        let axis = self.axis
        return GraphCanvas(
            x: .blank(),
            y: axis,
            height: height,
            insets: ETGraphInsets(leading: 28, trailing: 6, top: 6, bottom: 6),
            readout: readout,
            caption: caption(column),
            clipsContent: true,
            previewsFrequency: true,
            draw: { context, plot in
                // **地を配色表の 0 番で塗る。**上流 spectrogram.js:1231-1235 と同じ順。
                // 透かすと表の下半分（黒〜青）が薄れて、色を入れた意味が消える。
                // 透ける表（Normal）は 0 番が透明なので塗らない。カードの地がそのまま地になる。
                let opaque = band.lut.isOpaque
                if let floor = band.lut.floorColor {
                    context.fill(Path(plot.rect), with: .color(floor))
                }
                let gridShading: GraphicsContext.Shading =
                    opaque ? .color(ETSpectrogramBand.gridColor) : ETGraphShading.grid
                let markShading: GraphicsContext.Shading =
                    opaque ? .color(ETSpectrogramBand.markColor) : ETGraphShading.axis

                // 画像は色を持っているので、そのまま貼る。
                for piece in band.pieces(in: plot.rect) {
                    context.draw(Image(decorative: piece.image, scale: 1), in: piece.rect)
                }

                // **格子は画像の上。**GraphCanvas は drawGrid をこのクロージャより
                // 先に走らせる（GraphCanvas.swift:296）ので、地を塗った時点で横線 11 本は
                // 下敷きになって消える。ここで引き直すが、**画像より後でなければ
                // 同じことが起きる**（画像が覆う）。1 秒の印と指の線と同じ層に置く。
                // 形は GraphCanvas.drawGrid の横線（:398-405）に揃える。
                for tick in plot.yAxis.ticks {
                    let y = plot.y(tick.value)
                    guard y >= plot.rect.minY - 0.5, y <= plot.rect.maxY + 0.5 else { continue }
                    var line = Path()
                    line.move(to: CGPoint(x: plot.rect.minX, y: y))
                    line.addLine(to: CGPoint(x: plot.rect.maxX, y: y))
                    context.stroke(line, with: gridShading,
                                   lineWidth: tick.emphasized ? 1 : 0.5)
                }
                // 1 秒の印。spectrogram.js:1031-1042 は下端から 16px 上げた所から引いている。
                // 地が黒のときは、テーマの .tertiary ではなく固定の明るい色にする。
                for markX in band.secondMarks(in: plot.rect) {
                    var mark = Path()
                    mark.move(to: CGPoint(x: markX, y: plot.rect.maxY - 8))
                    mark.addLine(to: CGPoint(x: markX, y: plot.rect.maxY))
                    context.stroke(mark, with: markShading, lineWidth: 1.5)
                }
                if let hover = probe {
                    var line = Path()
                    let y = plot.y(hover.hz)
                    line.move(to: CGPoint(x: plot.rect.minX, y: y))
                    line.addLine(to: CGPoint(x: plot.rect.maxX, y: y))
                    context.stroke(line, with: markShading,
                                   style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                }
            },
            overlay: { plot in
                // 触って値を読むだけなので、一覧の縦スクロールと同時に効かせる。
                Color.clear
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { touch in probe = sample(at: touch.location, plot: plot) }
                            .onEnded { _ in probe = nil })
            })
            .onAppear {
                band.scale = scale
                band.lut = lut
                push(column)
            }
            .onChange(of: column?.sequence) { _, _ in push(column) }
            .onChange(of: scale) { _, new in band.scale = new }
            .onChange(of: lut) { _, new in band.lut = new }
    }

    /// Log は升目の並びそのまま。Linear の目盛りは spectrogram.js:995-1000 の狭い方を写す。
    private var axis: ETAxis {
        switch scale {
        case .log, .logHQ:
            return ETAxis.frequency(ETSpectrogramBand.minHz, ETSpectrogramBand.maxHz)
        case .linear:
            var axis = ETAxis.linear(ETSpectrogramBand.minHz...ETSpectrogramBand.maxHz,
                                 ticks: [20, 10000, 20000, 30000, 40000],
                                 label: { ETFormat.hzTick($0) })
            axis.isFrequency = true
            return axis
        }
    }

    // MARK: 触った所

    private func sample(at location: CGPoint, plot: ETPlot) -> ETSpectrogramProbe {
        let hz = plot.yAxis.clamp(plot.yValue(at: location.y))
        // 升目は縦軸の取り方に関わらず対数なので、周波数から行を出す。
        let row = ETSpectrogramBand.canonicalRow(forHz: hz)

        let columnWidth = plot.rect.width / CGFloat(ETSpectrogramBand.columns)
        let left = plot.rect.maxX - CGFloat(band.count) * columnWidth
        var db: Double?
        if columnWidth > 0 {
            let slot = Int(((location.x - left) / columnWidth).rounded(.down))
            if let v = band.intensity(displayColumn: slot, canonicalRow: row) {
                db = floorDB * (1 - Double(v) / 255)
            }
        }
        return ETSpectrogramProbe(hz: hz, db: db)
    }

    private var readout: [ETReadoutItem] {
        guard let probe = probe else { return [] }
        return [ETReadoutItem("FREQ", ETFormat.hz(probe.hz)),
                ETReadoutItem("LEVEL", probe.db.map { ETFormat.db($0) } ?? "--")]
    }

    private func caption(_ column: ETSpectrogramColumn?) -> String {
        guard band.count > 0 else { return "Waiting for audio" }
        var text = "\(band.count) col"
        if let span = band.span {
            text += String(format: " · %.1f s", span)
        }
        if let column = column { text += " · FFT \(1 << column.points)" }
        return text
    }

    // MARK: 枠を読む

    private func push(_ column: ETSpectrogramColumn?) {
        guard let column = column else { return }
        band.push(cells: column.cells, time: column.time, sequence: column.sequence)
    }

    private var column: ETSpectrogramColumn? {
        ETSpectrogramColumn(telemetry.frame(tap: tapId, type: .spectrogramColumn))
    }
}

// MARK: - 1 列

struct ETSpectrogramColumn {

    let sampleRate: Double
    let time: Double
    let points: Int
    let cells: [UInt8]
    let sequence: UInt32

    init?(_ frame: ETFrame?) {
        if let frame, frame.version == 2 {
            guard let hq = ETHQSpectrumHeader(frame: frame, spectrum: false) else { return nil }
            sampleRate = hq.rate
            time = hq.time
            points = hq.points
            cells = Array(frame.payload[48...])
            sequence = frame.sequence
            return
        }
        guard let frame = frame, frame.matches(version: 1), frame.hasPayload(bytes: 268) else { return nil }

        let payload = frame.payloadView
        guard let rate = payload.f32(at: 0),
              let seconds = payload.f32(at: 4),
              let cellCount = payload.u16(at: 8),
              let rawPoints = payload.u16(at: 10) else { return nil }

        // spectrogram.js:401-406 と同じ門。
        guard rate.isFinite, rate > 0, seconds.isFinite, seconds >= 0,
              cellCount == UInt16(ETSpectrogramBand.rows),
              rawPoints >= 8, rawPoints <= 14 else { return nil }

        sampleRate = Double(rate)
        time = Double(seconds)
        points = Int(rawPoints)
        cells = Array(payload.bytes[12..<268])
        sequence = frame.sequence
    }
}

struct ETSpectrogramProbe {
    let hz: Double
    let db: Double?
}

// MARK: - 横に流す帯

/// 列を固定長の輪で持つ。新しい列は右端、古い列は左へ。
/// 来た升目（対数）はそのまま canonical に置き、縦軸の取り方に合わせて
/// 描く用の pixels を作る。触った値は canonical から読むので、読み替えの影響を受けない。
/// 升目ごとに矩形を描くと 65536 個になるので、そこは通らない。
final class ETSpectrogramBand: ObservableObject {

    /// 横に持てる列の数。iPhone の幅（390pt）だと 1 列が 1pt 強になる。
    static let columns = 256
    /// 1 列の升目。DSP が 256 個で出す（kernel.cpp:24 の kCellCount）。
    static let rows = 256

    /// 表示する周波数の範囲。spectrogram.js:7-8。
    static let minHz: Double = 20
    static let maxHz: Double = 40000

    /// Linear の表示行 → 升目の行。spectrogram.js:15-22 と同じ式。
    /// 行 0 が 40kHz、行 255 が 20Hz なので、周波数は上から下へ等差で降りる。
    private static let linearToCanonicalRow: [Double] = {
        let logMin = log10(minHz)
        let logMax = log10(maxHz)
        let hzSpan = maxHz - minHz
        return (0..<rows).map { row in
            let position = Double(row) / Double(rows - 1)
            let frequency = maxHz - position * hzSpan
            return Double(rows - 1) * (logMax - log10(frequency)) / (logMax - logMin)
        }
    }()

    /// 周波数から升目の行。spectrogram.js:198-222 の freqToY の log 側と同じ。
    static func canonicalRow(forHz hz: Double) -> Int {
        let logMin = log10(minHz)
        let logMax = log10(maxHz)
        let clamped = min(max(hz, minHz), maxHz)
        let row = Double(rows - 1) * (logMax - log10(clamped)) / (logMax - logMin)
        return min(max(Int(row.rounded()), 0), rows - 1)
    }

    /// 中身が変わったことだけを知らせる。配列そのものは publish しない。
    @Published private(set) var revision: UInt32 = 0

    /// 縦軸の取り方。変えると溜めてある列を全部描き直す
    /// （spectrogram.js:340 の repaintSpectrogramHistory）。
    var scale: ETSpectrogramScale = .log {
        didSet {
            guard scale != oldValue else { return }
            repaintAll()
        }
    }

    /// 配色表。**外から渡す。**変えると溜めてある列を全部塗り直す
    /// （spectrogram.js:324-330 の setColor も同じく履歴ごと塗り直す）。
    var lut: ETIntensityLUT {
        didSet {
            guard lut != oldValue else { return }
            repaintAll()
        }
    }

    init(lut: ETIntensityLUT = .heatmap) {
        self.lut = lut
    }

    private(set) var image: CGImage?
    private(set) var count = 0

    private var head = 0
    private var lastSequence: UInt32?
    /// 来たままの升目。行は対数で等間隔。[row * columns + column]。
    private var canonical = [UInt8](repeating: 0,
                                    count: ETSpectrogramBand.columns * ETSpectrogramBand.rows)

    /// 黒地の上に引く線の色。上流 spectrogram.js:33-36 の `#888` / `#ccc` に倣った固定色。
    /// **テーマに従わせない。**地が固定なので、地に対して読める色でなければならない。
    /// 不透明な表のときだけ使う。
    static let gridColor = Color(red: 0.53, green: 0.53, blue: 0.53)
    static let markColor = Color(red: 0.80, green: 0.80, blue: 0.80)

    /// 描く用。RGBA、前乗算。表の値をそのまま入れる。
    private var pixels = [UInt8](repeating: 0,
                                 count: ETSpectrogramBand.columns * ETSpectrogramBand.rows * 4)
    private var times = [Double](repeating: .nan, count: ETSpectrogramBand.columns)

    func push(cells: [UInt8], time: Double, sequence: UInt32) {
        guard cells.count == Self.rows else { return }
        // 同じ枠を 2 度入れない。描き直しのたびに列が増えてしまう。
        if let previous = lastSequence, previous == sequence { return }
        lastSequence = sequence

        let column = head
        for row in 0..<Self.rows {
            canonical[row * Self.columns + column] = cells[row]
        }
        times[column] = time
        paint(column: column)

        head = (head + 1) % Self.columns
        if count < Self.columns { count += 1 }
        image = makeImage()
        revision &+= 1
    }

    /// 表示している範囲の秒数。列の間隔は一定でないので、端の時刻の差で出す。
    var span: Double? {
        guard count > 1 else { return nil }
        let oldest = times[(head - count + Self.columns) % Self.columns]
        let newest = times[(head - 1 + Self.columns) % Self.columns]
        guard oldest.isFinite, newest.isFinite, newest > oldest else { return nil }
        return newest - oldest
    }

    /// 左から右へ、古い順に並べた切れ端。輪が一周していると 2 枚になる。
    func pieces(in rect: CGRect) -> [(image: CGImage, rect: CGRect)] {
        guard count > 0, rect.width > 0, rect.height > 0, let image = image else { return [] }
        let columnWidth = rect.width / CGFloat(Self.columns)
        let left = rect.maxX - CGFloat(count) * columnWidth
        let start = (head - count + Self.columns) % Self.columns
        let firstRun = min(count, Self.columns - start)

        var out: [(image: CGImage, rect: CGRect)] = []
        if let older = image.cropping(to: CGRect(x: CGFloat(start), y: 0,
                                                 width: CGFloat(firstRun),
                                                 height: CGFloat(Self.rows))) {
            out.append((older, CGRect(x: left, y: rect.minY,
                                      width: CGFloat(firstRun) * columnWidth,
                                      height: rect.height)))
        }
        if firstRun < count,
           let newer = image.cropping(to: CGRect(x: 0, y: 0,
                                                 width: CGFloat(count - firstRun),
                                                 height: CGFloat(Self.rows))) {
            out.append((newer, CGRect(x: left + CGFloat(firstRun) * columnWidth, y: rect.minY,
                                      width: CGFloat(count - firstRun) * columnWidth,
                                      height: rect.height)))
        }
        return out
    }

    /// 1 秒をまたいだ列の境目の x。
    /// 印を置けるのは列と列の間だけなので、間隔は上流のような等分にはならない。
    /// 列が飛んで 2 秒以上空いたときも境目は 1 本しか無いので、印も 1 本になる。
    func secondMarks(in rect: CGRect) -> [CGFloat] {
        guard count > 1, rect.width > 0 else { return [] }
        let columnWidth = rect.width / CGFloat(Self.columns)
        let left = rect.maxX - CGFloat(count) * columnWidth
        let start = (head - count + Self.columns) % Self.columns

        var out: [CGFloat] = []
        var previous = times[start]
        for slot in 1..<count {
            let time = times[(start + slot) % Self.columns]
            defer { previous = time }
            guard previous.isFinite, time.isFinite, time > previous else { continue }
            if time.rounded(.down) > previous.rounded(.down) {
                out.append(left + CGFloat(slot) * columnWidth)
            }
        }
        return out
    }

    /// 左から数えた列と、升目の行の中身。触った所の値を読むのに使う。
    func intensity(displayColumn: Int, canonicalRow row: Int) -> UInt8? {
        guard displayColumn >= 0, displayColumn < count,
              row >= 0, row < Self.rows else { return nil }
        let start = (head - count + Self.columns) % Self.columns
        let column = (start + displayColumn) % Self.columns
        return canonical[row * Self.columns + column]
    }

    /// 溜めてある列を全部塗り直す。縦軸か配色表が変わったとき。
    private func repaintAll() {
        for column in 0..<Self.columns { paint(column: column) }
        image = makeImage()
        revision &+= 1
    }

    /// 1 列ぶんを描く用の並びに写す。
    ///
    /// **色を入れる。**配色表の 4 バイト（前乗算）をそのまま置く。
    private func paint(column: Int) {
        let table = lut.rgba
        for row in 0..<Self.rows {
            let source = Int(displayValue(row: row, column: column)) * 4
            let offset = (row * Self.columns + column) * 4
            pixels[offset] = table[source]
            pixels[offset + 1] = table[source + 1]
            pixels[offset + 2] = table[source + 2]
            pixels[offset + 3] = table[source + 3]
        }
    }

    private func displayValue(row: Int, column: Int) -> UInt8 {
        switch scale {
        case .log, .logHQ:
            return canonical[row * Self.columns + column]
        case .linear:
            // 読み替えた行は整数にならない。spectrogram.js:229-236 と同じく上下を混ぜる。
            let source = Self.linearToCanonicalRow[row]
            let first = min(max(Int(source.rounded(.down)), 0), Self.rows - 1)
            let second = min(first + 1, Self.rows - 1)
            let fraction = source - Double(first)
            let low = Double(canonical[first * Self.columns + column])
            let high = Double(canonical[second * Self.columns + column])
            let mixed = low + (high - low) * fraction
            return UInt8(min(max(mixed.rounded(), 0), 255))
        }
    }

    private func makeImage() -> CGImage? {
        guard let data = CFDataCreate(nil, pixels, pixels.count),
              let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: Self.columns,
                       height: Self.rows,
                       bitsPerComponent: 8,
                       bitsPerPixel: 32,
                       bytesPerRow: Self.columns * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}

// MARK: - 配色表

/// 濃さ 0〜255 に対する色。256 段の RGBA を**前乗算**で持つ（[v * 4 + channel]）。
/// 帯の画像にそのまま書ける形にしてある。
///
/// **表は使う側が選んで渡す。**Spectrogram のカードは Color で Heatmap と Normal を替え、
/// Spectrum Analyzer の Heatmap は透ける版をグラデーションにして使う。
/// 上流も表を 1 か所（SpectrogramPlugin.getHeatmapLuts）に置いて他から借りている
/// （spectrum_analyzer.js:1115）。
struct ETIntensityLUT: Equatable {

    let rgba: [UInt8]

    /// 0 番が不透明か。不透明な表は図の地を 0 番で塗る。
    var isOpaque: Bool { rgba[3] == 255 }

    /// 図の地。透ける表では nil（塗らずに下を見せる）。
    var floorColor: Color? {
        guard isOpaque else { return nil }
        return Color(red: Double(rgba[0]) / 255, green: Double(rgba[1]) / 255,
                     blue: Double(rgba[2]) / 255)
    }

    /// v 番の色。前乗算を外して Color にする。
    func color(_ v: Int) -> Color {
        let o = min(max(v, 0), 255) * 4
        let alpha = Double(rgba[o + 3]) / 255
        guard alpha > 0 else { return .clear }
        return Color(.sRGB,
                     red: min(1, Double(rgba[o]) / 255 / alpha),
                     green: min(1, Double(rgba[o + 1]) / 255 / alpha),
                     blue: min(1, Double(rgba[o + 2]) / 255 / alpha),
                     opacity: alpha)
    }

    /// 0 番から 255 番へのグラデーション。256 段をそのまま止まりにする
    /// （spectrum_analyzer.js:1116-1121 と同じ）。
    var gradient: Gradient {
        Gradient(stops: (0...255).map { Gradient.Stop(color: color($0), location: Double($0) / 255) })
    }

    // MARK: 表

    /// Heatmap の段。spectrogram.js:23-32 の SPECTROGRAM_COLOR_STOPS と BRIGHTNESS。
    /// 256 段への線形補間と丸めは同 :911-937 の getHeatmapLuts と同じ。
    private static let heatmapRGB: [(r: UInt8, g: UInt8, b: UInt8)] = {
        let stops: [(pos: Double, r: Double, g: Double, b: Double)] = [
            (0.000, 0, 0, 0),
            (0.166, 0, 0, 255),
            (0.333, 0, 255, 255),
            (0.500, 0, 255, 0),
            (0.666, 255, 255, 0),
            (0.833, 255, 0, 0),
            (1.000, 255, 255, 255)]
        let brightness = 0.75
        return (0...255).map { v -> (r: UInt8, g: UInt8, b: UInt8) in
            let t = Double(v) / 255
            var lo = stops[0]
            var hi = stops[stops.count - 1]
            for i in 0..<(stops.count - 1) where t >= stops[i].pos && t <= stops[i + 1].pos {
                lo = stops[i]
                hi = stops[i + 1]
                break
            }
            let span = hi.pos - lo.pos
            let p = span == 0 ? 0 : (t - lo.pos) / span
            func channel(_ a: Double, _ b: Double) -> UInt8 {
                UInt8(min(max(((a + (b - a) * p) * brightness).rounded(), 0), 255))
            }
            return (channel(lo.r, hi.r), channel(lo.g, hi.g), channel(lo.b, hi.b))
        }
    }()

    /// Heatmap。不透明（getHeatmapLuts().rgb）。Spectrogram の既定。
    static let heatmap = ETIntensityLUT(rgba: heatmapRGB.flatMap { [$0.r, $0.g, $0.b, 255] })

    /// Heatmap の透ける版（getHeatmapLuts().rgba、spectrogram.js:939-947）。
    /// alpha は一番明るい成分 / (255 × BRIGHTNESS)。黒〜青の区間だけが透け、
    /// 前乗算にすると色の値は不透明版と同じになる。
    static let heatmapTranslucent = ETIntensityLUT(rgba: heatmapRGB.flatMap { c -> [UInt8] in
        let peak = Double(max(c.r, c.g, c.b))
        let alpha = min(1, peak / (255 * 0.75))
        let a = UInt8((alpha * 255).rounded())
        return [min(c.r, a), min(c.g, a), min(c.b, a), a]
    })

    /// Normal。上流は地の色から trace の色へ線形に混ぜる
    /// （spectrogram.js:954-970 の createSpectrogramColorLut）。
    /// こちらは地を持たず、trace を濃さで透かす。下の地の上に置けば同じ混ぜ方になり、
    /// 明暗のテーマにも付いてくる。
    static func normal(trace: Color.Resolved) -> ETIntensityLUT {
        let r = Double(min(max(trace.red, 0), 1))
        let g = Double(min(max(trace.green, 0), 1))
        let b = Double(min(max(trace.blue, 0), 1))
        var rgba = [UInt8](repeating: 0, count: 256 * 4)
        for v in 0...255 {
            let a = Double(v)
            rgba[v * 4] = UInt8((r * a).rounded())
            rgba[v * 4 + 1] = UInt8((g * a).rounded())
            rgba[v * 4 + 2] = UInt8((b * a).rounded())
            rgba[v * 4 + 3] = UInt8(v)
        }
        return ETIntensityLUT(rgba: rgba)
    }
}

// MARK: - 全画面

/// 図だけを画面いっぱいに出す。
///
/// **帯（履歴）は親から受ける。**図の側に持たせると、開いた瞬間に空から流れ直して
/// 直前まで見ていたものが消える。同じ物を渡せば続きが見える。
/// 同じ列を二度押し込むことになるが、帯は sequence で弾くので増えない。
///
/// 縦軸の切り替えは元のカードに置いたまま。ここは見るためだけの画面にする。
private struct SpectrogramFullScreen: View {

    let tapId: UInt32
    let floorDB: Double
    let scale: ETSpectrogramScale
    let lut: ETIntensityLUT
    @ObservedObject var band: ETSpectrogramBand
    @Binding var isPresented: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            GeometryReader { geo in
                SpectrogramGraph(tapId: tapId, floorDB: floorDB, scale: scale,
                                 lut: lut, band: band,
                                 height: max(200, geo.size.height - 16))
                    .padding(.horizontal, 12)
            }
            Button { isPresented = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
            }
            .buttonStyle(.glass(.regular.interactive()))
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .accessibilityLabel("Close")
            .padding(.top, 8)
            .padding(.trailing, 12)
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
    }
}
