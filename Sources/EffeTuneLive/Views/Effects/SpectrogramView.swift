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
//  色は決めないので、画像は alpha だけを持たせて型抜きに使い、塗りは .tint に任せる。
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
    case log
    case logHQ
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

struct SpectrogramView: View {

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    /// 図だけ出す指定。ParameterRow は自分で消える（ParameterRow.swift:128-135）が、
    /// ここで足したボタンは消えないので自分で見る。
    @Environment(\.etGraphOnly) private var graphOnly

    @State private var scale: ETSpectrogramScale = .log

    private var effectiveScale: ETSpectrogramScale {
        let hq = node.spec.params.first(where: { $0.key == "hq" })
        return hq.map { node.values[$0.offset] >= 0.5 } == true ? .logHQ : (scale == .logHQ ? .log : scale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SpectrogramGraph(tapId: node.tapId, floorDB: floorDB, scale: effectiveScale)
            // 上流は DB Range・Points・Frequency Scale の順に並べている
            // （spectrogram.js:631-678）。同じ順にする。
            ForEach(node.spec.params.filter { $0.key != "hq" }) { param in
                ParameterRow(param: param, nodeIndex: index, values: node.values, dsp: dsp)
            }
            if !graphOnly { scalePicker }
        }
    }

    /// spectrogram.js:670-678 の createRadioGroup に当たる。Menu にはしない。
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

    @ObservedObject private var telemetry = Telemetry.shared
    @StateObject private var band = ETSpectrogramBand()

    @State private var probe: ETSpectrogramProbe?

    var body: some View {
        // 枠を読むのは 1 回だけ。指で触っている間も body は回るので、
        // 268 バイトの解きほぐしを 1 回の描き直しに何度もやらない。
        let column = self.column
        let axis = self.axis
        return GraphCanvas(
            x: .blank(),
            y: axis,
            height: ETGraphMetrics.height,
            insets: ETGraphInsets(leading: 28, trailing: 6, top: 6, bottom: 6),
            readout: readout,
            caption: caption(column),
            clipsContent: true,
            draw: { context, plot in
                let pieces = band.pieces(in: plot.rect)
                if !pieces.isEmpty {
                    // 画像は alpha だけを持つ。それで型を抜いて .tint を流し込む。
                    context.drawLayer { layer in
                        layer.clipToLayer { mask in
                            for piece in pieces {
                                mask.draw(Image(decorative: piece.image, scale: 1),
                                          in: piece.rect)
                            }
                        }
                        layer.fill(Path(plot.rect), with: ETGraphShading.curve)
                    }
                }
                // 1 秒の印。spectrogram.js:1031-1042 は下端から 16px 上げた所から引いている。
                for markX in band.secondMarks(in: plot.rect) {
                    var mark = Path()
                    mark.move(to: CGPoint(x: markX, y: plot.rect.maxY - 8))
                    mark.addLine(to: CGPoint(x: markX, y: plot.rect.maxY))
                    context.stroke(mark, with: ETGraphShading.axis, lineWidth: 1.5)
                }
                if let hover = probe {
                    var line = Path()
                    let y = plot.y(hover.hz)
                    line.move(to: CGPoint(x: plot.rect.minX, y: y))
                    line.addLine(to: CGPoint(x: plot.rect.maxX, y: y))
                    context.stroke(line, with: ETGraphShading.axis,
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
                push(column)
            }
            .onChange(of: column?.sequence) { _, _ in push(column) }
            .onChange(of: scale) { _, new in band.scale = new }
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
    /// （spectrogram.js:282-291 の repaintSpectrogramHistory）。
    var scale: ETSpectrogramScale = .log {
        didSet {
            guard scale != oldValue else { return }
            for column in 0..<Self.columns { paint(column: column) }
            image = makeImage()
            revision &+= 1
        }
    }

    private(set) var image: CGImage?
    private(set) var count = 0

    private var head = 0
    private var lastSequence: UInt32?
    /// 来たままの升目。行は対数で等間隔。[row * columns + column]。
    private var canonical = [UInt8](repeating: 0,
                                    count: ETSpectrogramBand.columns * ETSpectrogramBand.rows)
    /// 描く用。RGBA、前乗算。白の前乗算なので 4 バイトとも同じ値が入る。使うのは alpha だけ。
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

    /// 1 列ぶんを描く用の並びに写す。
    private func paint(column: Int) {
        for row in 0..<Self.rows {
            let value = displayValue(row: row, column: column)
            let offset = (row * Self.columns + column) * 4
            pixels[offset] = value
            pixels[offset + 1] = value
            pixels[offset + 2] = value
            pixels[offset + 3] = value
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
