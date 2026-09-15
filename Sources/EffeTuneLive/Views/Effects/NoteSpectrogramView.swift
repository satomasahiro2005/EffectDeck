//  NoteSpectrogramView.swift
//  Note Spectrogram。縦が音名（ピアノの鍵）、横が時間。多重音の推定結果を流す。
//
//  解析は重い（学習済みの木を回す）が、値は DSP から出てくるので、こちらは描くだけ。
//
//  テレメトリ: frameType 24、formatVersion 3。
//  ETFrameType には 20 までしか無い（Telemetry.swift）ので、
//  Telemetry.frame(tap:type:) は使えない。latest の鍵を自分で作って読んでいる。
//  鍵の作り方は Telemetry.key(tap:type:) と同じ (tap << 16 | type)。
//  番号の出どころ: dsp/plugins/analyzer/note_spectrogram/kernel.cpp:167
//  の writer.write(24u, 3u, ...)、note_spectrogram.js:1-2 の
//  MULTI_F0_TAP_FRAME / MULTI_F0_TELEMETRY_VERSION。
//
//  ペイロードの並び。kernel.cpp:238-249 が頭を書き、同 527 と 564 が本体を書く。
//  plugins/analyzer/note_spectrogram.js:305-334 が同じ位置を読む:
//      0      f32 sampleRate     kernel.cpp:238 / note_spectrogram.js:305
//      4      f32 timeSeconds    kernel.cpp:239 / note_spectrogram.js:306
//      8      u16 pitchCount     kernel.cpp:240 / note_spectrogram.js:307  常に 440 (88*5)
//     10      u16 firstMidi      kernel.cpp:241 / note_spectrogram.js:308  常に 21
//     12      f32 hopSeconds     kernel.cpp:242 / note_spectrogram.js:309
//     16      u32 frameIndex     kernel.cpp:243 / note_spectrogram.js:310
//     20      u32 modeCode       kernel.cpp:244 / note_spectrogram.js:311  常に 5（細分）
//     24      u32 generation     kernel.cpp:245 / note_spectrogram.js:312  0 は無効
//     28 + p*4    f32 confidence kernel.cpp:527 / note_spectrogram.js:324  0〜1
//   1788 + p*4    f32 level      kernel.cpp:564 / note_spectrogram.js:330  dB（床は -240）
//  1788 = 28 + 440*4（note_spectrogram.js:13 の MULTI_F0_LEVEL_OFFSET）。
//  長さは 3548 ちょうど（同 14）。
//
//  細分は 1 半音を 5 つに割ったもの（kernel.cpp:25 の kFineDivisions）。
//  p = (midi - 21) * 5 + division。web 版の Semitone 表示はその 5 つの最大を
//  その音のものとして使う（note_spectrogram.js:828-835 の _bagConfidence）ので、
//  こちらも同じにしてある。1/60 オクターブの表示は作っていない。
//
//  列は 1 本ずつ来る。Spectrogram と同じく、固定長の輪（ETNoteBand）に入れて
//  CGImage 1〜2 枚に畳んで貼る。88×256 = 22528 個の升目を Path に積まない。
//  色は決めないので、画像は alpha だけを持たせて型抜きに使い、塗りは .tint に任せる。
//  web 版は音名ごとに色を割り当てている（note_spectrogram.js:43-61）が、そこは移していない。
//
//  取りこぼしについて。DSP は貯まった枠を writeTelemetry で全部吐く（kernel.cpp:165-172）
//  が、Telemetry は tap と種類ごとに最新の 1 枠しか残さない。読み出しは
//  PipelineView の 1/30 秒ごとの pollTelemetry で、DSP が吐くのは 60Hz
//  （EffeTuneDSP.telemetryHz）。読むたびに残っているのは最後の 1 枠だけなので、
//  実際に帯へ入るのも 1 回につき 1 列になる。
//  横軸の目盛りを置かず、見えている範囲が何秒ぶんかだけを見出しに出しているのはそのため。

import SwiftUI
import Foundation
import CoreGraphics

struct NoteSpectrogramView: View {

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    @ObservedObject private var telemetry = Telemetry.shared
    @StateObject private var band = ETNoteBand()

    @State private var probe: ETNoteProbe?

    var body: some View {
        // 枠を読むのは 1 回だけ。指で触っている間も body は回るので、
        // 3548 バイトの解きほぐしを 1 回の描き直しに何度もやらない。
        let snapshot = self.snapshot
        return VStack(alignment: .leading, spacing: 12) {
            graph(snapshot)
            ForEach(node.spec.params) { param in
                ParameterRow(param: param, nodeIndex: index, values: node.values, dsp: dsp)
            }
        }
        .onAppear { if let latest = snapshot { band.push(latest) } }
        .onChange(of: snapshot?.frameIndex) { _, _ in
            if let latest = snapshot { band.push(latest) }
        }
    }

    private func graph(_ snapshot: ETNoteSnapshot?) -> some View {
        let range = midiRange
        return GraphCanvas(
            x: .blank(),
            y: ETAxis.linear((Double(range.lowerBound) - 0.5)...(Double(range.upperBound) + 0.5),
                             ticks: Self.noteTicks(range),
                             label: { ETNoteBand.name(Int($0.rounded())) }),
            height: ETGraphMetrics.height,
            insets: ETGraphInsets(leading: 30, trailing: 6, top: 6, bottom: 6),
            readout: readout,
            caption: caption(snapshot),
            clipsContent: true,
            draw: { context, plot in
                let pieces = band.pieces(in: plot.rect, midi: range)
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
                if let hover = probe {
                    var line = Path()
                    let y = plot.y(Double(hover.midi))
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
                            .onChanged { touch in
                                probe = sample(at: touch.location, plot: plot, midi: range)
                            }
                            .onEnded { _ in probe = nil })
            })
    }

    // MARK: 触った所

    private func sample(at location: CGPoint, plot: ETPlot,
                        midi range: ClosedRange<Int>) -> ETNoteProbe {
        let raw = plot.yAxis.clamp(plot.yValue(at: location.y))
        let midi = min(max(Int(raw.rounded()), range.lowerBound), range.upperBound)

        let columnWidth = plot.rect.width / CGFloat(ETNoteBand.columns)
        var confidence: Double?
        var level: Double?
        if columnWidth > 0 {
            let slot = Int(((location.x - (plot.rect.maxX - CGFloat(band.count) * columnWidth))
                            / columnWidth).rounded(.down))
            if let cell = band.cell(displayColumn: slot, midi: midi) {
                confidence = Double(cell.confidence)
                level = cell.confidence > 0 ? Double(cell.level) : nil
            }
        }
        return ETNoteProbe(midi: midi, confidence: confidence, level: level)
    }

    private var readout: [ETReadoutItem] {
        guard let probe = probe else { return [] }
        var items = [ETReadoutItem("NOTE", ETNoteBand.name(probe.midi))]
        if let confidence = probe.confidence {
            items.append(ETReadoutItem("CONF", String(format: "%.0f%%", confidence * 100)))
        }
        if let level = probe.level, level > -200 {
            items.append(ETReadoutItem("LEVEL", ETFormat.db(level)))
        }
        return items
    }

    private func caption(_ snapshot: ETNoteSnapshot?) -> String {
        guard band.count > 0 else { return "Waiting for audio" }
        var text = "\(band.count) col"
        if let span = band.span {
            text += String(format: " · %.1f s", span)
        }
        if let snapshot = snapshot {
            text += String(format: " · hop %.0f ms", snapshot.hopSeconds * 1000)
        }
        return text
    }

    /// 出す音の範囲。params.json の minimumMidi / maximumMidi（21〜108）。
    private var midiRange: ClosedRange<Int> {
        let low = Int(value("minimumMidi", 28).rounded())
        let high = Int(value("maximumMidi", 91).rounded())
        let lower = min(max(min(low, high), ETNoteBand.firstMidi), ETNoteBand.lastMidi)
        let upper = min(max(max(low, high), ETNoteBand.firstMidi), ETNoteBand.lastMidi)
        // 1 音だけになると軸が潰れるので、最低 1 オクターブは見せる。
        if upper - lower >= 11 { return lower...upper }
        let top = min(ETNoteBand.lastMidi, lower + 11)
        return min(lower, top - 11)...top
    }

    private func value(_ name: String, _ fallback: Float) -> Float {
        guard let param = node.spec.params.first(where: { $0.name == name }),
              node.values.indices.contains(param.offset) else { return fallback }
        let v = node.values[param.offset]
        return v.isFinite ? v : fallback
    }

    /// 縦の目盛りは C の音に置く。範囲が狭くて 2 本に届かないときは両端も足す。
    private static func noteTicks(_ range: ClosedRange<Int>) -> [Double] {
        var ticks = range.filter { $0 % 12 == 0 }.map { Double($0) }
        if ticks.count < 2 {
            ticks = [Double(range.lowerBound), Double(range.upperBound)]
        }
        return ticks
    }

    // MARK: 枠を読む

    private var snapshot: ETNoteSnapshot? {
        // frameType 24 は ETFrameType に無いので、鍵を自分で組む。
        ETNoteSnapshot(telemetry.latest[UInt64(node.tapId) << 16 | 24])
    }
}

// MARK: - 1 枠

struct ETNoteSnapshot {

    let sampleRate: Double
    let time: Double
    let hopSeconds: Double
    let frameIndex: UInt32
    /// 音ごとの確からしさ。細分 5 つの最大（note_spectrogram.js:828-835）。
    let confidence: [Float]
    /// その最大を出した細分の dB（note_spectrogram.js:522-534）。
    let level: [Float]

    init?(_ frame: ETFrame?) {
        guard let frame = frame, frame.matches(version: 3),
              frame.hasPayload(bytes: 3548) else { return nil }

        let payload = frame.payloadView
        guard let rate = payload.f32(at: 0),
              let seconds = payload.f32(at: 4),
              let pitchCount = payload.u16(at: 8),
              let firstMidi = payload.u16(at: 10),
              let hop = payload.f32(at: 12),
              let index = payload.u32(at: 16),
              let modeCode = payload.u32(at: 20),
              let generation = payload.u32(at: 24) else { return nil }

        // note_spectrogram.js:313-319 と同じ門。
        guard rate.isFinite, rate > 0, seconds.isFinite, seconds >= 0,
              pitchCount == 440, firstMidi == UInt16(ETNoteBand.firstMidi),
              hop.isFinite, hop > 0, modeCode == 5, generation != 0 else { return nil }

        guard let fineConfidence = payload.floats(at: 28, count: 440),
              let fineLevel = payload.floats(at: 1788, count: 440) else { return nil }

        var bagged = [Float](repeating: 0, count: ETNoteBand.notes)
        var levels = [Float](repeating: -240, count: ETNoteBand.notes)
        for note in 0..<ETNoteBand.notes {
            let first = note * 5
            var best = first
            for division in 1..<5 where fineConfidence[first + division] > fineConfidence[best] {
                best = first + division
            }
            let value = fineConfidence[best]
            guard value.isFinite, value >= 0, value <= 1,
                  fineLevel[best].isFinite else { return nil }
            bagged[note] = value
            levels[note] = fineLevel[best]
        }

        sampleRate = Double(rate)
        time = Double(seconds)
        hopSeconds = Double(hop)
        frameIndex = index
        confidence = bagged
        level = levels
    }
}

struct ETNoteProbe {
    let midi: Int
    let confidence: Double?
    let level: Double?
}

// MARK: - 横に流す帯

/// 音ごとの確からしさを固定長の輪で持つ。新しい列は右端、古い列は左へ。
/// 中身は alpha だけの RGBA として持ち、CGImage に畳んでから貼る。
final class ETNoteBand: ObservableObject {

    static let columns = 256
    /// 88 鍵。note_spectrogram.js:4 の MULTI_F0_NOTE_COUNT。
    static let notes = 88
    static let firstMidi = 21
    static let lastMidi = firstMidi + notes - 1

    @Published private(set) var revision: UInt32 = 0

    private(set) var image: CGImage?
    private(set) var count = 0

    private var head = 0
    private var lastIndex: UInt32?
    /// RGBA、前乗算。使うのは alpha だけ。上の行ほど高い音。
    private var pixels = [UInt8](repeating: 0,
                                 count: ETNoteBand.columns * ETNoteBand.notes * 4)
    private var levels = [Float](repeating: -240,
                                 count: ETNoteBand.columns * ETNoteBand.notes)
    private var times = [Double](repeating: .nan, count: ETNoteBand.columns)

    static func name(_ midi: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let pitchClass = ((midi % 12) + 12) % 12
        return names[pitchClass] + "\(midi / 12 - 1)"
    }

    /// midi から画像の行へ。行 0 が一番高い音。
    private static func row(midi: Int) -> Int {
        (notes - 1) - (midi - firstMidi)
    }

    func push(_ snapshot: ETNoteSnapshot) {
        guard snapshot.confidence.count == Self.notes,
              snapshot.level.count == Self.notes else { return }
        // 同じ枠を 2 度入れない。描き直しのたびに列が増えてしまう。
        if let previous = lastIndex, previous == snapshot.frameIndex { return }
        lastIndex = snapshot.frameIndex

        let column = head
        for note in 0..<Self.notes {
            let value = UInt8(min(max(snapshot.confidence[note], 0), 1) * 255)
            let offset = (Self.row(midi: Self.firstMidi + note) * Self.columns + column) * 4
            pixels[offset] = value
            pixels[offset + 1] = value
            pixels[offset + 2] = value
            pixels[offset + 3] = value
            levels[note * Self.columns + column] = snapshot.level[note]
        }
        times[column] = snapshot.time

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
    /// 縦は midi の範囲だけを切り出す。
    func pieces(in rect: CGRect,
                midi range: ClosedRange<Int>) -> [(image: CGImage, rect: CGRect)] {
        guard count > 0, rect.width > 0, rect.height > 0, let image = image else { return [] }
        let top = Self.row(midi: range.upperBound)
        let height = range.upperBound - range.lowerBound + 1
        guard top >= 0, height > 0, top + height <= Self.notes else { return [] }

        let columnWidth = rect.width / CGFloat(Self.columns)
        let left = rect.maxX - CGFloat(count) * columnWidth
        let start = (head - count + Self.columns) % Self.columns
        let firstRun = min(count, Self.columns - start)

        var out: [(image: CGImage, rect: CGRect)] = []
        if let older = image.cropping(to: CGRect(x: CGFloat(start), y: CGFloat(top),
                                                 width: CGFloat(firstRun),
                                                 height: CGFloat(height))) {
            out.append((older, CGRect(x: left, y: rect.minY,
                                      width: CGFloat(firstRun) * columnWidth,
                                      height: rect.height)))
        }
        if firstRun < count,
           let newer = image.cropping(to: CGRect(x: 0, y: CGFloat(top),
                                                 width: CGFloat(count - firstRun),
                                                 height: CGFloat(height))) {
            out.append((newer, CGRect(x: left + CGFloat(firstRun) * columnWidth, y: rect.minY,
                                      width: CGFloat(count - firstRun) * columnWidth,
                                      height: rect.height)))
        }
        return out
    }

    /// 左から数えた列と音の中身。触った所の値を読むのに使う。
    func cell(displayColumn: Int, midi: Int) -> (confidence: Float, level: Float)? {
        guard displayColumn >= 0, displayColumn < count,
              midi >= Self.firstMidi, midi <= Self.lastMidi else { return nil }
        let start = (head - count + Self.columns) % Self.columns
        let column = (start + displayColumn) % Self.columns
        let note = midi - Self.firstMidi
        let alpha = pixels[(Self.row(midi: midi) * Self.columns + column) * 4 + 3]
        return (Float(alpha) / 255, levels[note * Self.columns + column])
    }

    private func makeImage() -> CGImage? {
        guard let data = CFDataCreate(nil, pixels, pixels.count),
              let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: Self.columns,
                       height: Self.notes,
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
