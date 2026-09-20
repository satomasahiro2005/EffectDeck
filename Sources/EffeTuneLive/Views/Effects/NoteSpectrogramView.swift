//  NoteSpectrogramView.swift
//  Note Spectrogram。音名と時間の面に多重音の推定結果を流し、端に鍵盤を置く。
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
//  p = (midi - 21) * 5 + division で、division は 0 が一番低い。
//  Pitch Resolution が 1/12 のときは 5 つの最大をその音のものとして使う
//  （note_spectrogram.js:828-835 の _bagConfidence）。High のときは 5 つを別々の行にする。
//
//  列は 1 本ずつ来る。Spectrogram と同じく、固定長の輪（ETNoteBand）に入れて
//  CGImage 1〜2 枚に畳んで貼る。88×256 の升目を Path に積まない。
//  Color が Normal のときは画像に alpha だけを持たせて型抜きに使い、塗りは .tint に任せる。
//  Note Colors のときだけ note_spectrogram.js:43-61 の色を前乗算で画像に入れて直に貼る。
//
//  取りこぼしについて。DSP は貯まった枠を writeTelemetry で全部吐く（kernel.cpp:165-172）
//  が、Telemetry は tap と種類ごとに最新の 1 枠しか残さない。読み出しは
//  PipelineView の 1/30 秒ごとの pollTelemetry で、DSP が吐くのは 60Hz
//  （EffeTuneDSP.telemetryHz）。読むたびに残っているのは最後の 1 枠だけなので、
//  実際に帯へ入るのも 1 回につき 1 列になる。列の幅は一定の時間を表さない。
//  Time Span は上流のように列の間隔を時間で決められないので、
//  溜まっている列の平均の間隔から「何列ぶんを横幅いっぱいに並べるか」を出している。

import SwiftUI
import Foundation
import CoreGraphics

// MARK: - 表示だけの切り替え

/// 塗り分け。note_spectrogram.js:20-23 の MULTI_F0_COLORS。
enum ETNoteColor: String, CaseIterable, Identifiable {
    // **綴りは上流のまま。**保存形式にそのまま載せるので
    // （note_spectrogram.js:20-23 の MULTI_F0_COLORS の value）。
    case normal = "Normal"
    case rainbow = "Rainbow"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .normal:  return "Normal"
        case .rainbow: return "Note Colors"
        }
    }
}

/// 縦の細かさ。note_spectrogram.js:24-27 の MULTI_F0_RESOLUTIONS。
enum ETNoteResolution: String, CaseIterable, Identifiable {
    // 同 :24-27 の MULTI_F0_RESOLUTIONS の value。
    case semitone = "Semitone"
    case high = "High"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .semitone: return "1/12 Octave"
        case .high:     return "High (1/60 Octave)"
        }
    }
}

/// 向き。note_spectrogram.js:28 の MULTI_F0_LAYOUTS。
/// Horizontal は上流と同じく面ごと 90 度回す（同 :1063-1065）。
/// 音の高さが横、時間が縦に流れ、鍵盤は下に来る。
enum ETNoteLayout: String, CaseIterable, Identifiable {
    // 同 :28 の MULTI_F0_LAYOUTS。
    case vertical = "Vertical"
    case horizontal = "Horizontal"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .vertical:   return "Vertical"
        case .horizontal: return "Horizontal"
        }
    }
}

/// 図の描き方。上流は cl / pr / ly / vl / ts をプリセットに書くが
/// （note_spectrogram.js:160-164）、DSP のパラメータではないので params.json に無い。
/// こちらは画面の @State で持つだけで、保存も DSP への送信もしない。
///
/// 既定は上流（同 :86-90）と 3 つ違う。上流は ly が Horizontal、vl が true、ts が 2。
/// 向きと Volume は初手の見た目が大きく変わるので、いまの姿のまま Vertical・切にしてある。
struct ETNoteDisplay: Equatable {
    var color: ETNoteColor = .normal
    var resolution: ETNoteResolution = .semitone
    var layout: ETNoteLayout = .vertical
    var volume: Bool = false
    /// 秒。上流 :726-729 の 1〜10、刻み 1。
    var timeSpan: Double = 2

    /// 画像を作り直す必要があるか。向きと時間の幅は画像に関わらない。
    var repaintKey: String { "\(color.rawValue)/\(resolution.rawValue)/\(volume)" }
}

/// 鍵盤の寸法。note_spectrogram.js:29-30。
enum ETNoteKeyboard {
    /// 鍵盤の帯の幅（css px）。28 × 1.6。
    static let gutter: CGFloat = 44.8
    /// 黒鍵の深さに対する帯の幅の比。
    static let blackRatio: CGFloat = 1.6
    /// 白鍵の音名。note_spectrogram.js:33。
    static let whiteClasses = [0, 2, 4, 5, 7, 9, 11]
    /// 黒鍵の音名。同 :32。
    static let blackClasses: Set<Int> = [1, 3, 6, 8, 10]
    /// 彩度を上げる。上流の表は灰色に寄っていて、升目が小さいと色が読めない。
    /// 明るさ（Rec.709 の輝度）を軸に外へ広げ、少し持ち上げる。
    private static func vivid(_ c: (r: Double, g: Double, b: Double))
        -> (r: Double, g: Double, b: Double) {
        let y = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
        let gain = 1.55, lift = 1.12
        func f(_ v: Double) -> Double { min(255, max(0, (y + (v - y) * gain) * lift)) }
        return (f(c.r), f(c.g), f(c.b))
    }

    /// 音名ごとの色。同 :43-56 を vivid で広げたもの。Note Colors のときだけ使う。
    static let noteColors: [(r: Double, g: Double, b: Double)] = rawNoteColors.map(vivid)

    private static let rawNoteColors: [(r: Double, g: Double, b: Double)] = [
        (170, 98, 86), (161, 105, 57), (140, 115, 42), (109, 124, 55),
        (69, 130, 84), (19, 132, 116), (0, 130, 146), (56, 123, 167),
        (96, 115, 175), (129, 107, 168), (153, 99, 148), (167, 96, 119)
    ]

    /// 細分 1 つぶんの色。note_spectrogram.js:58-70 と同じ混ぜ方。
    static func fineColor(pitch: Int) -> (r: Double, g: Double, b: Double) {
        let midi = Double(ETNoteBand.firstMidi)
            + (Double(pitch) - Double(ETNoteBand.divisions / 2)) / Double(ETNoteBand.divisions)
        let lowerMidi = Int(midi.rounded(.down))
        let fraction = midi - Double(lowerMidi)
        let lower = noteColors[((lowerMidi % 12) + 12) % 12]
        let upper = noteColors[(((lowerMidi + 1) % 12) + 12) % 12]
        return (lower.r + (upper.r - lower.r) * fraction,
                lower.g + (upper.g - lower.g) * fraction,
                lower.b + (upper.b - lower.b) * fraction)
    }
}

// MARK: - 画面

struct NoteSpectrogramView: View {

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    @Environment(\.etGraphOnly) private var graphOnly
    @State private var display = ETNoteDisplay()
    /// 全画面を出しているか。
    @State private var fullScreen = false
    /// 横へ回し終わるのを待っている間。
    @State private var movingToFullScreen = false
    /// 升目の履歴。**@State で参照だけ持つ**（@StateObject にすると 30Hz で body が
    /// 作り直されて下のボタンが固まる）。ここに置くのは、全画面と元の図で同じ履歴を
    /// 見せるため。図の側に持たせると、開いた瞬間に空から流れ直す。
    @State private var band = ETNoteBand()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // **全画面の口は AU と同じ形にする。**図の右上に丸い札を重ね、
            // 押したら横へ回してから開く。**1/60（5x）の線が細いのはここで解く。**
            // 61 音 × 5 = 305 行をカードの高さに詰めると 1 行が 1〜2 画素にしかならない。
            // 横に倒して画面いっぱいに使えば、行に見合う高さが渡る。
            ZStack(alignment: .topTrailing) {
                NoteSpectrogramGraph(tapId: node.tapId, display: display,
                                     range: midiRange, band: band)
                if !graphOnly {
                    Button {
                        movingToFullScreen = true
                        Task { @MainActor in
                            // 先に回す。縦のまま出してから倒すと、図が 1 枚
                            // 縦の姿で描かれてから横へ跳ねる。
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
            // 上流 :748-755 の並びは Color → Pitch Resolution → Layout → Volume →
            // Time Span → Regular Note Limit → Lowest Note → Highest Note。
            if !graphOnly { controls }
            ForEach(node.spec.params) { param in
                parameterRow(param)
            }
        }
        // **鎖に残す。**カードを畳むと View ごと木から消えるので @State では
        // 開き直すたびに既定へ戻り、端末の中だけの覚えではアプリを終うと消える。
        // 上流はこの 5 つをプリセットに書いている（note_spectrogram.js:155-169）ので、
        // 同じ綴りで鎖へ持たせる。プリセットにも共有リンクにも乗る。
        .etSaved($display.color, key: "cl", index: index, dsp: dsp)
        .etSaved($display.resolution, key: "pr", index: index, dsp: dsp)
        .etSaved($display.layout, key: "ly", index: index, dsp: dsp)
        .etSaved($display.volume, key: "vl", index: index, dsp: dsp)
        .etSaved($display.timeSpan, key: "ts", index: index, dsp: dsp)
        .fullScreenCover(isPresented: $fullScreen, onDismiss: {
            ETInterfaceOrientation.request(.portrait)
            movingToFullScreen = false
        }) {
            NoteSpectrogramFullScreen(tapId: node.tapId, display: display,
                                      range: midiRange, band: band,
                                      isPresented: $fullScreen)
        }
    }

    /// DSP に送らない 5 つ。上流 :711-729。
    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            ETNoteChoiceRow(title: "Color",
                            options: ETNoteColor.allCases,
                            text: { $0.label },
                            selection: $display.color)
            ETNoteChoiceRow(title: "Pitch Resolution",
                            options: ETNoteResolution.allCases,
                            text: { $0.label },
                            selection: $display.resolution)
            ETNoteChoiceRow(title: "Layout",
                            options: ETNoteLayout.allCases,
                            text: { $0.label },
                            selection: $display.layout)
            Toggle(isOn: $display.volume) {
                Text("Volume").font(.system(size: 14))
            }
            .padding(.vertical, 2)
            timeSpanRow
        }
    }

    /// 上流 :726-729 の createParameterControl('Time Span', 1, 10, 1, …, 's', 'ts')。
    private var timeSpanRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Time Span (s)")
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                ETValueField(text: "\(Int(display.timeSpan.rounded())) s",
                             label: "Time Span",
                             editText: { ETNumberText.draft(display.timeSpan.rounded()) }) { typed in
                    display.timeSpan = min(max(typed.rounded(), 1), 10)
                }
            }
            Slider(value: $display.timeSpan, in: 1...10, step: 1)
                .accessibilityLabel("Time Span")
                .accessibilityValue("\(Int(display.timeSpan.rounded())) seconds")
        }
        .padding(.vertical, 2)
    }

    /// 音の高さの 2 本だけ、値を音名で出す（上流 :675 と :693 の multiF0NoteName）。
    @ViewBuilder
    private func parameterRow(_ param: ETParam) -> some View {
        if param.name == "minimumMidi" || param.name == "maximumMidi" {
            ETNoteRangeRow(param: param, nodeIndex: index, values: node.values, dsp: dsp)
        } else {
            ParameterRow(param: param, nodeIndex: index, values: node.values, dsp: dsp)
        }
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
}

// MARK: - 選ぶ 1 行

/// createRadioGroup（note_spectrogram.js:711-722）に当たる並び。Menu にはしない。
private struct ETNoteChoiceRow<Option: Hashable & Identifiable>: View {

    let title: String
    let options: [Option]
    let text: (Option) -> String
    @Binding var selection: Option

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 14))
            HStack(spacing: 6) {
                ForEach(options) { option in
                    let isSelected = selection == option
                    Button {
                        selection = option
                    } label: {
                        Text(text(option))
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
                    .accessibilityLabel("\(text(option)) \(title)")
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 音名で読ませる 1 行

/// 上流 createNoteRangeControl（note_spectrogram.js:645-699）に当たる。
/// 値の欄は打ち込ませない（上流も :673 で readOnly）。動かすのはつまみだけ。
private struct ETNoteRangeRow: View {

    let param: ETParam
    let nodeIndex: Int
    let values: [Float]

    @ObservedObject var dsp: EffeTuneDSP
    @Environment(\.etGraphOnly) private var graphOnly

    var body: some View {
        if graphOnly {
            EmptyView()
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(param.label)
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                ValueBox(text: ETNoteBand.name(midi))
            }
            Slider(value: Binding(get: { Double(midi) },
                                  set: { dsp.setValue(Float($0.rounded()),
                                                      at: nodeIndex, offset: param.offset) }),
                   in: Double(bounds.lo)...Double(bounds.hi), step: 1)
                .accessibilityLabel(param.label)
                .accessibilityValue(ETNoteBand.name(midi))
        }
        .padding(.vertical, 2)
    }

    /// つまみの端。上流 :663-664 は 21〜108 で固定。
    private var bounds: (lo: Int, hi: Int) {
        guard case .number(let lo, let hi, _, _, _) = param.kind else {
            return (ETNoteBand.firstMidi, ETNoteBand.lastMidi)
        }
        return (Int(lo.rounded()), Int(hi.rounded()))
    }

    private var midi: Int {
        guard values.indices.contains(param.offset) else { return bounds.lo }
        let v = values[param.offset]
        guard v.isFinite else { return bounds.lo }
        return min(max(Int(v.rounded()), bounds.lo), bounds.hi)
    }
}

// MARK: - 図の中の置き方

/// draw 空間は x が時間（右が新しい）、y が音の高さ（上が高い）。
/// Horizontal では上流と同じく全体を 90 度回す（note_spectrogram.js:1063-1065）ので、
/// 画面では x が音の高さ（右が高い）、y が時間（下が新しい）になる。
struct ETNoteRollFrame {

    let rect: CGRect
    let horizontal: Bool

    /// 時間の側の長さ。
    var width: CGFloat { horizontal ? rect.height : rect.width }
    /// 音の高さの側の長さ。
    var height: CGFloat { horizontal ? rect.width : rect.height }

    /// draw 空間の点を画面へ。
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        horizontal ? CGPoint(x: rect.minX + rect.width - y, y: rect.minY + x)
                   : CGPoint(x: rect.minX + x, y: rect.minY + y)
    }

    /// 画面の点を draw 空間へ。指の位置を読むのに使う。
    func local(_ p: CGPoint) -> CGPoint {
        horizontal ? CGPoint(x: p.y - rect.minY, y: rect.minX + rect.width - p.x)
                   : CGPoint(x: p.x - rect.minX, y: p.y - rect.minY)
    }

    /// 以降の描画を draw 空間で書けるようにする。
    func apply(_ context: inout GraphicsContext) {
        if horizontal {
            context.translateBy(x: rect.minX + rect.width, y: rect.minY)
            context.rotate(by: .degrees(90))
        } else {
            context.translateBy(x: rect.minX, y: rect.minY)
        }
    }
}

// MARK: - 図

/// 図の一番内側。**Telemetry を見るのはここだけ**にしてある。
/// カード全体で観測すると 30Hz で作り直されて、下のボタンが固まる。
private struct NoteSpectrogramGraph: View {

    let tapId: UInt32
    let display: ETNoteDisplay
    let range: ClosedRange<Int>
    /// 履歴は親が持つ。全画面と元の図で同じものを見せるため。
    @ObservedObject var band: ETNoteBand
    /// 図の高さ。全画面では画面いっぱいまで渡す。
    var height: CGFloat?

    @ObservedObject private var telemetry = Telemetry.shared
    /// 図の高さを画素で測るのに要る。行の複製はこれで決める。
    @Environment(\.displayScale) private var displayScale

    @State private var probe: ETNoteProbe?
    @GestureState private var previewActive = false

    /// 図の高さ。**細分 1 行に画素を 1 つ以上渡す。**
    ///
    /// 上流は細分の行を並べた画像を、まず**補間なし**で表示の高さへ縦に拡大し、
    /// そのあと横だけ平滑化する（note_spectrogram.js:1077 と :1094）。
    /// つまり細分 1 行が画素 1 つ以上になっている前提の描き方。
    ///
    /// こちらは高さを ETGraphMetrics.height で決め打ちにしていたので、
    /// 5x（1/60）では 61 音 × 5 = 305 行が 190pt に入り、1 行 0.62pt。
    /// @2x でも 1.2 画素しかなく、線が髪の毛になっていた。
    /// 行数から高さを決めれば上流と同じ形になる。
    ///
    /// **Horizontal では高くしない。**あちらは音の高さが幅に乗るので
    /// （ETNoteRollFrame.height が rect.width を返す）、高さを増やしても効かない。
    private var graphHeight: CGFloat {
        // 全画面から渡されたらそれを使う。
        if let height { return height }
        return ETGraphMetrics.height
    }

    var body: some View {
        // 枠を読むのは 1 回だけ。指で触っている間も body は回るので、
        // 3548 バイトの解きほぐしを 1 回の描き直しに何度もやらない。
        let snapshot = self.snapshot
        let slots = band.slots(forSpan: display.timeSpan)
        return GraphCanvas(
            x: .blank(),
            y: .blank(),
            height: graphHeight,
            insets: ETGraphInsets(leading: 6, trailing: 6, top: 6, bottom: 6),
            readout: readout,
            caption: caption(snapshot, slots: slots),
            clipsContent: true,
            draw: { context, plot in
                let frame = ETNoteRollFrame(rect: plot.rect,
                                            horizontal: display.layout == .horizontal)
                // 鍵盤の帯。上流は 44.8pt で固定だが、Horizontal では時間の側が
                // 170pt しかなく帯だけで 1/4 を超えるので、そこで頭を打つ。
                let gutter = min(ETNoteKeyboard.gutter, frame.width * 0.25)
                let rollWidth = frame.width - gutter
                guard rollWidth > 0, frame.height > 0 else { return }
                let rowHeight = frame.height / CGFloat(range.count)

                context.drawLayer { layer in
                    frame.apply(&layer)
                    drawBands(&layer, frame: frame, rollWidth: rollWidth, rowHeight: rowHeight)
                    drawGrid(&layer, frame: frame, rollWidth: rollWidth, rowHeight: rowHeight)
                    drawRoll(&layer, frame: frame, rollWidth: rollWidth, slots: slots)
                    drawKeys(&layer, frame: frame, rollWidth: rollWidth,
                             gutter: gutter, rowHeight: rowHeight)
                    if let hover = probe {
                        var line = Path()
                        let y = frame.height
                            - (CGFloat(hover.midi - range.lowerBound) + 0.5) * rowHeight
                        line.move(to: CGPoint(x: 0, y: y))
                        line.addLine(to: CGPoint(x: rollWidth, y: y))
                        layer.stroke(line, with: ETGraphShading.axis,
                                     style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    }
                }
                // 字は回さない。上流も Horizontal では 90 度戻している（:1222-1227）。
                drawOctaveLabels(&context, frame: frame, rollWidth: rollWidth,
                                 gutter: gutter, rowHeight: rowHeight)
            },
            overlay: { plot in
                // 触って値を読むだけなので、一覧の縦スクロールと同時に効かせる。
                Color.clear
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .updating($previewActive) { _, active, _ in active = true }
                            .onChanged { touch in
                                probe = sample(at: touch.location, plot: plot, slots: slots)
                                if let probe {
                                    ETPreviewTone_SetFrequency(440 * pow(2, Double(probe.midi - 69) / 12))
                                }
                            }
                            .onEnded { _ in
                                probe = nil
                                ETPreviewTone_SetFrequency(0)
                            })
            })
            .onChange(of: previewActive) { _, active in
                if !active { ETPreviewTone_SetFrequency(0) }
            }
            .onAppear {
                band.display = display
                // **縦の引き伸ばしを画像へ持たせる**（ETNoteBand.rowScale）。
                // 全画面では図がずっと高くなるので、開くたびに測り直す。
                band.fit(height: graphHeight * displayScale)
                if let latest = snapshot { band.push(latest) }
            }
            .onChange(of: graphHeight) { _, h in band.fit(height: h * displayScale) }
            .onChange(of: snapshot?.frameIndex) { _, _ in
                if let latest = snapshot { band.push(latest) }
            }
            .onChange(of: display) { _, now in band.display = now }
    }

    // MARK: 描く

    /// 横の罫。C は濃く、F は細く。上流 :1188-1202。
    /// 線は音の行の下の境目に来る。Horizontal では鍵盤に掛からない（同 :1199）。
    private func drawGrid(_ context: inout GraphicsContext, frame: ETNoteRollFrame,
                          rollWidth: CGFloat, rowHeight: CGFloat) {
        var strong = Path()
        var subtle = Path()
        let end = frame.horizontal ? rollWidth : frame.width
        for midi in range where midi >= 24 && (midi % 12 == 0 || midi % 12 == 5) {
            let y = CGFloat(range.upperBound - midi + 1) * rowHeight
            guard y > 0, y < frame.height else { continue }
            if midi % 12 == 0 {
                strong.move(to: CGPoint(x: 0, y: y))
                strong.addLine(to: CGPoint(x: end, y: y))
            } else {
                subtle.move(to: CGPoint(x: 0, y: y))
                subtle.addLine(to: CGPoint(x: end, y: y))
            }
        }
        context.stroke(subtle, with: ETGraphShading.grid, lineWidth: 0.5)
        context.stroke(strong, with: ETGraphShading.axis, lineWidth: 1)
    }

    private func drawRoll(_ context: inout GraphicsContext, frame: ETNoteRollFrame,
                          rollWidth: CGFloat, slots: Int) {
        let rect = CGRect(x: 0, y: 0, width: rollWidth, height: frame.height)
        let pieces = band.pieces(in: rect, midi: range, slots: slots)
        guard !pieces.isEmpty else { return }
        // **最近傍で貼る。**
        // 画像は 88 列（半音 1 つが 1 列）しか無く、画面の幅まで引き伸ばす。
        // 既定の平滑化が掛かると半音の境目と、音が始まった／終わった縦の線が
        // ぼやける。升目の絵なので拡大は最近傍でよい。
        //
        // **`interpolation` は `GraphicsContext` ではなく `Image` の修飾子。**
        // `context.interpolation = .none` は通らない（has no member）。
        // **滑らかに貼る。**縦は fit(height:) が行を図の高さまで複製してあるので、
        // 拡大率がほぼ 1 になって動かない。動くのは横（時間の向き）だけで、
        // そこは上流も平滑化している（note_spectrogram.js:1094）。
        // 一発で最近傍に貼っていたころは、1/60 の 305 行が潰れて髪の毛になっていた。
        func tile(_ image: CGImage) -> Image {
            Image(decorative: image, scale: 1)
                .interpolation(.high)
                .antialiased(false)
        }
        // **どちらの塗り分けでも画像が色を持つ**（noteColor が常に返す）ので、
        // 型抜きして 1 色を流す枝は要らない。そのまま貼る。
        for piece in pieces {
            context.draw(tile(piece.image), in: piece.rect)
        }
    }

    /// 鍵の地の帯。**画像には入れない。**
    ///
    /// 上流は地色を升目そのものへ焼き込む（note_spectrogram.js:436-443 の _writePixels）。
    /// 同じことをすると、こちらは**画像を横へ流す**作りなので**地色まで一緒に流れる**。
    /// 上流は canvas を毎回描き直すので流れない。地は動かないものなので、
    /// 静止した層としてここで敷き、画像はトレースだけを持たせる。
    private func drawBands(_ context: inout GraphicsContext, frame: ETNoteRollFrame,
                           rollWidth: CGFloat, rowHeight: CGFloat) {
        var black = Path()
        for midi in range
        where ETNoteKeyboard.blackClasses.contains(((midi % 12) + 12) % 12) {
            let y = CGFloat(range.upperBound - midi) * rowHeight
            guard y + rowHeight > 0, y < frame.height else { continue }
            black.addRect(CGRect(x: 0, y: y, width: rollWidth, height: rowHeight))
        }
        context.fill(black, with: ETGraphShading.grid)
    }

    /// 鍵盤。白鍵は帯いっぱい、黒鍵は手前だけ。最新の列の confidence で光らせる。
    /// 上流 :1125-1183。色は決めないので、消灯は .quaternary と .secondary、
    /// 点灯は .tint の濃さで出す。
    private func drawKeys(_ context: inout GraphicsContext, frame: ETNoteRollFrame,
                          rollWidth: CGFloat, gutter: CGFloat, rowHeight: CGFloat) {
        let blackDepth = gutter / ETNoteKeyboard.blackRatio
        let whiteHeight = 12 * rowHeight / 7
        var white = Path()
        var black = Path()
        var separators = Path()
        // 光っている鍵は帯を塗り直す。白鍵は黒鍵の下に置く（上流も白→黒の順）。
        var whiteGlow: [(rect: CGRect, midi: Int, value: Double)] = []
        var blackGlow: [(rect: CGRect, midi: Int, value: Double)] = []

        for midi in ETNoteBand.firstMidi...ETNoteBand.lastMidi {
            let pitchClass = ((midi % 12) + 12) % 12
            guard let whiteIndex = ETNoteKeyboard.whiteClasses.firstIndex(of: pitchClass)
                else { continue }
            // 白鍵は半音の行ではなく、1 オクターブを 7 等分した位置に置く。
            let cBoundary = CGFloat(midi - pitchClass - range.lowerBound) * rowHeight
            let center = cBoundary + (CGFloat(whiteIndex) + 0.5) * whiteHeight
            let top = max(center - whiteHeight / 2, 0)
            let bottom = min(center + whiteHeight / 2, frame.height)
            if top < bottom {
                let rect = CGRect(x: rollWidth, y: frame.height - bottom,
                                  width: gutter, height: bottom - top)
                white.addRect(rect)
                let value = band.latestConfidence(midi: midi)
                if value > 0.01 { whiteGlow.append((rect, midi, value)) }
            }
            // 鍵の境。上流 :1152-1165。
            let boundary = cBoundary + CGFloat(whiteIndex) * whiteHeight
            if boundary > 0, boundary < frame.height {
                separators.move(to: CGPoint(x: rollWidth, y: frame.height - boundary))
                separators.addLine(to: CGPoint(x: frame.width, y: frame.height - boundary))
            }
        }

        for midi in range where ETNoteKeyboard.blackClasses.contains(((midi % 12) + 12) % 12) {
            let rect = CGRect(x: rollWidth, y: CGFloat(range.upperBound - midi) * rowHeight,
                              width: blackDepth, height: rowHeight)
            black.addRect(rect)
            let value = band.latestConfidence(midi: midi)
            if value > 0.01 { blackGlow.append((rect, midi, value)) }
        }

        context.fill(white, with: ETGraphShading.grid)
        light(&context, whiteGlow)
        context.stroke(separators, with: ETGraphShading.axis, lineWidth: 0.5)
        context.fill(black, with: ETGraphShading.muted)
        light(&context, blackGlow)
        var edge = Path()
        edge.move(to: CGPoint(x: rollWidth, y: 0))
        edge.addLine(to: CGPoint(x: rollWidth, y: frame.height))
        context.stroke(edge, with: ETGraphShading.axis, lineWidth: 1)
    }

    /// 鳴っている鍵を .tint で塗り直す。濃さが確からしさ。
    /// 光っている鍵を塗る。**音名ごとの色を使う。**
    ///
    /// 上流は Normal のとき trace（1 色）で光らせる（note_spectrogram.js:1148）が、
    /// それだと 88 鍵が同じ青で光るだけで、どの音かは鍵の位置を数えないと分からない。
    /// 色を持たせれば、光った所を見ただけで音名が分かる。
    /// 配色は Note Colors と同じ表（ETNoteKeyboard.noteColors）を使うので、
    /// 図の塗り分けを Note Colors にしたときに鍵と升目の色が揃う。
    private func light(_ context: inout GraphicsContext,
                       _ keys: [(rect: CGRect, midi: Int, value: Double)]) {
        for key in keys {
            let c = ETNoteKeyboard.noteColors[((key.midi % 12) + 12) % 12]
            var lamp = context
            lamp.opacity = key.value
            lamp.fill(Path(key.rect),
                      with: .color(Color(red: c.r / 255, green: c.g / 255, blue: c.b / 255)))
        }
    }

    /// C の字を鍵の上に置く。上流 :1203-1212。白鍵の真ん中に来る。
    private func drawOctaveLabels(_ context: inout GraphicsContext, frame: ETNoteRollFrame,
                                  rollWidth: CGFloat, gutter: CGFloat, rowHeight: CGFloat) {
        let blackDepth = gutter / ETNoteKeyboard.blackRatio
        let x = rollWidth + (blackDepth + gutter) / 2
        let whiteHeight = 12 * rowHeight / 7
        for midi in range where midi >= 24 && midi % 12 == 0 {
            let y = frame.height
                - (CGFloat(midi - range.lowerBound) * rowHeight + whiteHeight / 2)
            guard y >= 0, y <= frame.height else { continue }
            context.draw(Text("C\(midi / 12 - 1)")
                            .font(.system(size: ETGraphMetrics.labelSize, design: .monospaced))
                            .foregroundStyle(.secondary),
                         at: frame.point(x, y), anchor: .center)
        }
    }

    // MARK: 触った所

    private func sample(at location: CGPoint, plot: ETPlot, slots: Int) -> ETNoteProbe {
        let frame = ETNoteRollFrame(rect: plot.rect, horizontal: display.layout == .horizontal)
        let local = frame.local(location)
        let gutter = min(ETNoteKeyboard.gutter, frame.width * 0.25)
        let rollWidth = frame.width - gutter
        let rowHeight = frame.height / CGFloat(range.count)

        let row = rowHeight > 0 ? Int((local.y / rowHeight).rounded(.down)) : 0
        let midi = min(max(range.upperBound - row, range.lowerBound), range.upperBound)

        var confidence: Double?
        var level: Double?
        let columnWidth = rollWidth / CGFloat(max(slots, 1))
        if columnWidth > 0, rollWidth > 0 {
            let shown = min(band.count, slots)
            let left = rollWidth - CGFloat(shown) * columnWidth
            let slot = Int(((local.x - left) / columnWidth).rounded(.down))
            if let cell = band.cell(displayColumn: slot, midi: midi, slots: slots) {
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

    private func caption(_ snapshot: ETNoteSnapshot?, slots: Int) -> String {
        guard band.count > 0 else { return "Waiting for audio" }
        var text = "\(min(band.count, slots)) col"
        if let span = band.span(slots: slots) {
            text += String(format: " · %.1f s", span)
        }
        if let snapshot = snapshot {
            text += String(format: " · hop %.0f ms", snapshot.hopSeconds * 1000)
        }
        return text
    }

    // MARK: 枠を読む

    private var snapshot: ETNoteSnapshot? {
        // frameType 24 は ETFrameType に無いので、鍵を自分で組む。
        ETNoteSnapshot(telemetry.latest[UInt64(tapId) << 16 | 24])
    }
}

// MARK: - 1 枠

struct ETNoteSnapshot {

    let sampleRate: Double
    let time: Double
    let hopSeconds: Double
    let frameIndex: UInt32
    /// 細分ごとの確からしさ。440 個（note_spectrogram.js:321-332）。
    let confidence: [Float]
    /// 同じ並びの dB（床は -240）。
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
              pitchCount == UInt16(ETNoteBand.pitches),
              firstMidi == UInt16(ETNoteBand.firstMidi),
              hop.isFinite, hop > 0, modeCode == UInt32(ETNoteBand.divisions),
              generation != 0 else { return nil }

        guard let fineConfidence = payload.floats(at: 28, count: ETNoteBand.pitches),
              let fineLevel = payload.floats(at: 1788, count: ETNoteBand.pitches)
            else { return nil }
        // 同 :324-331。1 つでも外れていたら枠ごと捨てる。
        for pitch in 0..<ETNoteBand.pitches {
            let value = fineConfidence[pitch]
            guard value.isFinite, value >= 0, value <= 1,
                  fineLevel[pitch].isFinite else { return nil }
        }

        sampleRate = Double(rate)
        time = Double(seconds)
        hopSeconds = Double(hop)
        frameIndex = index
        confidence = fineConfidence
        level = fineLevel
    }
}

struct ETNoteProbe {
    let midi: Int
    let confidence: Double?
    let level: Double?
}

// MARK: - 横に流す帯

/// 細分ごとの確からしさを固定長の輪で持つ。新しい列は右端、古い列は左へ。
/// 描く用の並びは表示の切り替えで作り直す。
final class ETNoteBand: ObservableObject {

    static let columns = 256
    /// 88 鍵。note_spectrogram.js:4 の MULTI_F0_NOTE_COUNT。
    static let notes = 88
    /// 1 半音を割る数。同 :5 の MULTI_F0_FINE_DIVISIONS。
    static let divisions = 5
    /// 440。同 :7 の MULTI_F0_PITCH_COUNT。
    static let pitches = notes * divisions
    static let firstMidi = 21
    static let lastMidi = firstMidi + notes - 1
    /// 音量の目盛りの幅。同 :16-17 の MULTI_F0_LEVEL_RANGE_DB / _CEILING_DB。
    static let levelRangeDB: Double = 24
    static let levelCeilingDB: Double = -36
    /// 目盛りの上端の落とし方。同 :18-19。
    static let levelReleaseDBPerSecond: Double = 20
    static let levelHoldSeconds: Double = 1

    @Published private(set) var revision: UInt32 = 0

    private(set) var image: CGImage?
    private(set) var count = 0
    /// 画像が 1 音に使う行数。解像度（1 か 5）× 引き伸ばし（rowScale）。
    private(set) var rowsPerNote = 1

    /// 1 行を何行に写すか。**縦の引き伸ばしを画像のほうへ持たせる。**
    ///
    /// 上流は伸ばすのを 2 段に分けている（note_spectrogram.js:1064-1103）。
    /// まず縦だけを平滑化なしで図の高さまで広げ、そのあと横だけを平滑化して貼る。
    /// 縦を平滑化すると隣の音を拾うから、という理由がそのままコメントに書いてある。
    ///
    /// こちらは一発で最近傍に貼っていたので、**1/60 では 305 行が図の高さへ潰れて
    /// 1 行 1〜2 画素にしかならず、髪の毛になっていた。**
    /// 貼る前に伸ばすと 30Hz で 2MB の面を組み直すことになるので、
    /// **画像を作る時点で行を複製しておく。**行数が図の高さに追いつけば、
    /// 貼るときの縦の拡大率がほぼ 1 になり、平滑化しても縦は動かない。
    /// だから横だけを滑らかにできる（上流と同じ絵になる）。
    private(set) var rowScale = 1

    /// 図の高さ（画素）に合わせて行の複製を決める。**描く前に呼ぶ。**
    func fit(height: CGFloat) {
        let base = (display.resolution == .high || display.volume) ? Self.divisions : 1
        // 上限を置く。88 音 × 5 細分 × 8 = 3520 行までで、それ以上は要らない
        // （iPhone の縦は @3x でも 2800 画素ほど）。
        let want = min(8, max(1, Int(height) / max(1, Self.notes * base)))
        guard want != rowScale else { return }
        rowScale = want
        allocate()
        for column in 0..<Self.columns { paint(column: column) }
        image = makeImage()
        revision &+= 1
    }

    /// 表示の切り替え。変えると溜めてある列を全部描き直す。
    var display = ETNoteDisplay() {
        didSet {
            guard display.repaintKey != oldValue.repaintKey else { return }
            allocate()
            for column in 0..<Self.columns { paint(column: column) }
            image = makeImage()
            revision &+= 1
        }
    }

    private var head = 0
    private var lastIndex: UInt32?
    /// 来たままの確からしさ。[pitch * columns + column]、0〜255。
    private var fine = [UInt8](repeating: 0, count: ETNoteBand.pitches * ETNoteBand.columns)
    /// 音ごとの、一番強い細分の dB。触った所を読むのに使う。[note * columns + column]
    private var levels = [Float](repeating: -240,
                                 count: ETNoteBand.notes * ETNoteBand.columns)
    /// 同じ位置を 0〜255 に直したもの。Volume の太さに使う。
    private var loudness = [UInt8](repeating: 0,
                                   count: ETNoteBand.notes * ETNoteBand.columns)
    private var times = [Double](repeating: .nan, count: ETNoteBand.columns)
    /// RGBA、前乗算。Normal では 4 バイトとも同じ値（使うのは alpha だけ）。
    private var pixels: [UInt8] = []

    /// 音量の目盛りの上端。note_spectrogram.js:501-516。
    private var levelReference: Double = -240
    private var levelHold: Double = 0
    private var lastTime: Double?

    init() {
        allocate()
    }

    static func name(_ midi: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let pitchClass = ((midi % 12) + 12) % 12
        return names[pitchClass] + "\(midi / 12 - 1)"
    }

    private var rows: Int { Self.notes * rowsPerNote }

    private func allocate() {
        // Volume は太さを細分の行で出すので、半音表示でも 5 行いる。
        let base = (display.resolution == .high || display.volume) ? Self.divisions : 1
        let needed = base * rowScale
        let bytes = Self.notes * needed * Self.columns * 4
        guard rowsPerNote != needed || pixels.count != bytes else { return }
        rowsPerNote = needed
        pixels = [UInt8](repeating: 0, count: bytes)
    }

    func push(_ snapshot: ETNoteSnapshot) {
        guard snapshot.confidence.count == Self.pitches,
              snapshot.level.count == Self.pitches else { return }
        // 同じ枠を 2 度入れない。描き直しのたびに列が増えてしまう。
        if let previous = lastIndex, previous == snapshot.frameIndex { return }
        lastIndex = snapshot.frameIndex

        let elapsed = max(0, snapshot.time - (lastTime ?? snapshot.time))
        lastTime = snapshot.time
        updateLevelReference(snapshot, elapsed: elapsed)

        let column = head
        for pitch in 0..<Self.pitches {
            fine[pitch * Self.columns + column] = Self.byte(snapshot.confidence[pitch])
        }
        for note in 0..<Self.notes {
            let best = Self.best(in: snapshot.confidence, note: note)
            let db = Double(snapshot.level[best])
            levels[note * Self.columns + column] = snapshot.level[best]
            loudness[note * Self.columns + column] = Self.byte(Float(normalized(level: db)))
        }
        times[column] = snapshot.time
        paint(column: column)

        head = (head + 1) % Self.columns
        if count < Self.columns { count += 1 }
        image = makeImage()
        revision &+= 1
    }

    /// 最新の列のその音の確からしさ。鍵盤を光らせるのに使う。
    func latestConfidence(midi: Int) -> Double {
        guard count > 0, midi >= Self.firstMidi, midi <= Self.lastMidi else { return 0 }
        let column = (head - 1 + Self.columns) % Self.columns
        let first = (midi - Self.firstMidi) * Self.divisions
        var value: UInt8 = 0
        for division in 0..<Self.divisions {
            let v = fine[(first + division) * Self.columns + column]
            if v > value { value = v }
        }
        return Double(value) / 255
    }

    /// 時間の幅から、横幅いっぱいに並べる列の数。
    /// 列の間隔は一定ではないので、溜まっている列の平均で割る。
    func slots(forSpan span: Double) -> Int {
        guard count > 1 else { return Self.columns }
        let oldest = times[(head - count + Self.columns) % Self.columns]
        let newest = times[(head - 1 + Self.columns) % Self.columns]
        guard oldest.isFinite, newest.isFinite, newest > oldest else { return Self.columns }
        let period = (newest - oldest) / Double(count - 1)
        guard period > 0 else { return Self.columns }
        return min(Self.columns, max(1, Int((span / period).rounded())))
    }

    /// いま出している列が何秒ぶんか。
    func span(slots: Int) -> Double? {
        let shown = min(count, slots)
        guard shown > 1 else { return nil }
        let oldest = times[(head - shown + Self.columns) % Self.columns]
        let newest = times[(head - 1 + Self.columns) % Self.columns]
        guard oldest.isFinite, newest.isFinite, newest > oldest else { return nil }
        return newest - oldest
    }

    /// 左から右へ、古い順に並べた切れ端。輪が一周していると 2 枚になる。
    /// 縦は midi の範囲だけを切り出す。
    func pieces(in rect: CGRect, midi range: ClosedRange<Int>,
                slots: Int) -> [(image: CGImage, rect: CGRect)] {
        guard count > 0, rect.width > 0, rect.height > 0, slots > 0,
              let image = image else { return [] }
        let top = (Self.lastMidi - range.upperBound) * rowsPerNote
        let height = range.count * rowsPerNote
        guard top >= 0, height > 0, top + height <= rows else { return [] }

        let shown = min(count, slots)
        let columnWidth = rect.width / CGFloat(slots)
        let left = rect.maxX - CGFloat(shown) * columnWidth
        let start = (head - shown + Self.columns) % Self.columns
        let firstRun = min(shown, Self.columns - start)

        var out: [(image: CGImage, rect: CGRect)] = []
        if let older = image.cropping(to: CGRect(x: CGFloat(start), y: CGFloat(top),
                                                 width: CGFloat(firstRun),
                                                 height: CGFloat(height))) {
            out.append((older, CGRect(x: left, y: rect.minY,
                                      width: CGFloat(firstRun) * columnWidth,
                                      height: rect.height)))
        }
        if firstRun < shown,
           let newer = image.cropping(to: CGRect(x: 0, y: CGFloat(top),
                                                 width: CGFloat(shown - firstRun),
                                                 height: CGFloat(height))) {
            out.append((newer, CGRect(x: left + CGFloat(firstRun) * columnWidth, y: rect.minY,
                                      width: CGFloat(shown - firstRun) * columnWidth,
                                      height: rect.height)))
        }
        return out
    }

    /// 左から数えた列と音の中身。触った所の値を読むのに使う。
    func cell(displayColumn: Int, midi: Int,
              slots: Int) -> (confidence: Float, level: Float)? {
        let shown = min(count, slots)
        guard displayColumn >= 0, displayColumn < shown,
              midi >= Self.firstMidi, midi <= Self.lastMidi else { return nil }
        let start = (head - shown + Self.columns) % Self.columns
        let column = (start + displayColumn) % Self.columns
        let note = midi - Self.firstMidi
        let first = note * Self.divisions
        var value: UInt8 = 0
        for division in 0..<Self.divisions {
            let v = fine[(first + division) * Self.columns + column]
            if v > value { value = v }
        }
        return (Float(value) / 255, levels[note * Self.columns + column])
    }

    // MARK: 描く用の並びへ

    private func paint(column: Int) {
        if display.volume {
            clear(column: column)
            paintVolume(column: column)
        } else {
            paintConfidence(column: column)
        }
    }

    private func clear(column: Int) {
        for row in 0..<rows {
            let offset = (row * Self.columns + column) * 4
            pixels[offset] = 0
            pixels[offset + 1] = 0
            pixels[offset + 2] = 0
            pixels[offset + 3] = 0
        }
    }

    /// 確からしさをそのまま升目に置く。上流 _writePixels（:422-452）に当たる。
    private func paintConfidence(column: Int) {
        // **1 行を rowScale 行へ写す。**縦の引き伸ばしを画像に持たせるため
        // （rowScale の説明を読むこと）。rowScale が 1 なら今までと同じ。
        let base = rowsPerNote / rowScale
        for note in 0..<Self.notes {
            let first = note * Self.divisions
            if base == 1 {
                // 1/12 は細分 5 つの最大をその音のものにする（上流 :828-835）。
                var value: UInt8 = 0
                for division in 0..<Self.divisions {
                    let v = fine[(first + division) * Self.columns + column]
                    if v > value { value = v }
                }
                let top = (Self.notes - 1 - note) * rowScale
                for k in 0..<rowScale {
                    write(row: top + k, column: column, value: value,
                          color: noteColor(note: note))
                }
            } else {
                for division in 0..<Self.divisions {
                    let value = fine[(first + division) * Self.columns + column]
                    let top = ((Self.notes - 1 - note) * Self.divisions
                               + (Self.divisions - 1 - division)) * rowScale
                    for k in 0..<rowScale {
                        write(row: top + k, column: column, value: value,
                              color: fineColor(pitch: first + division))
                    }
                }
            }
        }
    }

    /// Volume。音量を線の太さにする。上流 _paintVolumeBar（:860-897）。
    /// 上流は図の高さの画素で太さを取るが、こちらは細分の行を単位にする。
    /// 上流の下限 rowHeight/5 が 1 行、上限 rowHeight-1 が 5 行に当たる。
    private func paintVolume(column: Int) {
        for note in 0..<Self.notes {
            let first = note * Self.divisions
            var best = 0
            var value: UInt8 = 0
            for division in 0..<Self.divisions {
                let v = fine[(first + division) * Self.columns + column]
                if v > value {
                    value = v
                    best = division
                }
            }
            guard value > 0 else { continue }
            let level = Double(loudness[note * Self.columns + column]) / 255
            let thickness = min(Self.divisions,
                                max(1, Int((1 + Double(Self.divisions - 1) * level).rounded())))
            // 1/60 では一番強い細分の位置、1/12 では行の真ん中に置く（上流 :881-885）。
            let center = (Self.notes - 1 - note) * Self.divisions
                + (display.resolution == .high ? (Self.divisions - 1 - best)
                                               : Self.divisions / 2)
            let start = center - (thickness - 1) / 2
            // 細分の行も rowScale 倍に写す（paintConfidence と同じ理由）。
            for row in start..<(start + thickness) {
                for k in 0..<rowScale {
                    let at = row * rowScale + k
                    guard at >= 0, at < rows else { continue }
                    write(row: at, column: column, value: value,
                          color: display.resolution == .high
                              ? fineColor(pitch: first + best)
                              : noteColor(note: note))
                }
            }
        }
    }

    /// **どちらの塗り分けでも色を持つ。**
    ///
    /// 前は Normal で nil を返し、画像を型抜きにして .tint 一色を流していた。
    /// 88 鍵ぶんが同じ青で光るだけなので、どの音が鳴っているかは位置を数えないと
    /// 分からなかった。音名ごとの色にすれば見ただけで分かる。
    /// Note Colors との違いは、あちらが細分ごとに色を混ぜる（fineColor）ことに残る。
    private func noteColor(note: Int) -> (r: Double, g: Double, b: Double)? {
        ETNoteKeyboard.noteColors[((Self.firstMidi + note) % 12 + 12) % 12]
    }

    /// 細分 1 つぶんの色。**Note Colors のときだけ混ぜる。**
    /// Normal はその音の色をそのまま使うので、5 細分が同じ色になる。
    private func fineColor(pitch: Int) -> (r: Double, g: Double, b: Double)? {
        guard display.color == .rainbow else {
            let note = pitch / Self.divisions
            return ETNoteKeyboard.noteColors[((Self.firstMidi + note) % 12 + 12) % 12]
        }
        return ETNoteKeyboard.fineColor(pitch: pitch)
    }

    /// 確からしさを濃さへ写す表。
    ///
    /// そのまま alpha にすると、模型が返す中くらいの値が一面に薄く乗って
    /// 音の形が沈む。**下を切って上を伸ばす。**
    /// 0.12 未満は消す（背景が澄む）、0.80 で上限に当てる。
    /// 指数 0.75 は弱い音を見失わないためのわずかな持ち上げ。
    /// 上流（note_spectrogram.js）は素通しなので、ここだけ形が違う。
    private static let shaped: [UInt8] = (0...255).map { v in
        let x = Double(v) / 255
        let lo = 0.12, hi = 0.80
        let t = min(max((x - lo) / (hi - lo), 0), 1)
        return UInt8((pow(t, 0.75) * 255).rounded())
    }

    /// 1 升を塗る。**画像はトレースだけを持つ。**
    ///
    /// 一度、上流の `_writePixels`（note_spectrogram.js:436-443）をそのまま写して
    /// 地色を焼き込んだことがある。**あれは上流だから成り立つ形だった。**
    /// 上流は canvas を毎フレーム描き直すが、こちらは画像を横へ流すので、
    /// 地色を入れると地色まで流れる。地は `drawBands` が静止した層として敷く。
    private func write(row: Int, column: Int, value raw: UInt8,
                       color: (r: Double, g: Double, b: Double)?) {
        let value = Self.shaped[Int(raw)]
        let offset = (row * Self.columns + column) * 4
        if let color = color {
            // 前乗算なので、確からしさを掛けた色を置く。
            let alpha = Double(value) / 255
            pixels[offset] = UInt8(min(255, max(0, (color.r * alpha).rounded())))
            pixels[offset + 1] = UInt8(min(255, max(0, (color.g * alpha).rounded())))
            pixels[offset + 2] = UInt8(min(255, max(0, (color.b * alpha).rounded())))
            pixels[offset + 3] = value
        } else {
            pixels[offset] = value
            pixels[offset + 1] = value
            pixels[offset + 2] = value
            pixels[offset + 3] = value
        }
    }

    // MARK: 音量の目盛り

    /// 上端は確からしさ 0.5 以上の中の最大。1 秒持ってから 20dB/s で落とす。
    /// note_spectrogram.js:501-516。
    private func updateLevelReference(_ snapshot: ETNoteSnapshot, elapsed: Double) {
        var peak = -240.0
        for pitch in 0..<Self.pitches where snapshot.confidence[pitch] >= 0.5 {
            let db = Double(snapshot.level[pitch])
            if db > peak { peak = db }
        }
        if peak >= levelReference {
            levelReference = peak
            levelHold = Self.levelHoldSeconds
        } else {
            let decay = max(0, elapsed - levelHold)
            levelHold = max(0, levelHold - elapsed)
            levelReference = max(peak, levelReference - Self.levelReleaseDBPerSecond * decay)
        }
    }

    /// dB を 0〜1 へ。note_spectrogram.js:492-499。
    private func normalized(level: Double) -> Double {
        let upper = max(levelReference, Self.levelCeilingDB)
        let value = (level - (upper - Self.levelRangeDB)) / Self.levelRangeDB
        return min(max(value, 0), 1)
    }

    // MARK: 細々

    private static func best(in confidence: [Float], note: Int) -> Int {
        let first = note * divisions
        var best = first
        for division in 1..<divisions where confidence[first + division] > confidence[best] {
            best = first + division
        }
        return best
    }

    private static func byte(_ value: Float) -> UInt8 {
        let scaled = (Double(value) * 255).rounded()
        return UInt8(min(255, max(0, scaled)))
    }

    private func makeImage() -> CGImage? {
        guard let data = CFDataCreate(nil, pixels, pixels.count),
              let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: Self.columns,
                       height: rows,
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

// MARK: - 全画面

/// 図だけを画面いっぱいに出す。
///
/// **1/60（5x）はここで読めるようになる。**61 音 × 5 = 305 行を 190pt に詰めると
/// 1 行が 1〜2 画素しか無い。上流は細分の行を補間なしで表示の高さへ拡大する形なので、
/// 行数に見合う高さを与えるのが筋で、カードの中では足りない。
///
/// **帯（履歴）は親から受ける。**図の側に持たせると、開いた瞬間に空から流れ直して
/// 直前まで見ていたものが消える。同じ列を二度押し込むが、帯は世代で弾くので増えない。
private struct NoteSpectrogramFullScreen: View {

    let tapId: UInt32
    let display: ETNoteDisplay
    let range: ClosedRange<Int>
    @ObservedObject var band: ETNoteBand
    @Binding var isPresented: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            GeometryReader { geo in
                NoteSpectrogramGraph(tapId: tapId, display: display, range: range,
                                     band: band,
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
