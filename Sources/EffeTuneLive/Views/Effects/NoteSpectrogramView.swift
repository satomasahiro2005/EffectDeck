//  NoteSpectrogramView.swift
//  Note Spectrogram。音名と時間の面に多重音の推定結果を流し、端に鍵盤を置く。
//
//  解析は重い（学習済みの木を回す）が、値は DSP から出てくるので、こちらは描くだけ。
//
//  テレメトリ: frameType 24、formatVersion 6（2.14.0）。枠の並びと読みは
//  DSP/NoteSpectrogramFrame.swift（ETNoteSnapshot。Foundation だけで試せる）。
//  確からしさは 32 + p*4、dB は 1792 + p*4、末尾に 88 鍵の音程のずれ（セント）、長さは 9192。
//  さらに 2・4・8 枠前の確からしさの直しを運ぶ。
//
//  **音色（2.14.0）。**Color の Instrument (3) / (9) と Highlight は、音ごとの音色の判定（型 31、
//  ETNoteTimbreEvent）で塗る。判定は音が始まってしばらくしてから届くので、それまでの列は灰色で、
//  届いたらその音が鳴っていた列を全部塗り直す（3 回の描き直しで灰色から移す）。判定を DSP に走らせる
//  te は保存しない値で、Color か Highlight か Onsets が要るときだけ立てる（上流 noteEventsEnabled）。
//  Onsets は音の始まりに三角の印。High では帯の位置を DSP の音程のずれ（セント）で決める。
//
//  細分は 1 半音を 5 つに割ったもの（kernel.cpp:25 の kFineDivisions）。
//  p = (midi - 21) * 5 + division で、division は 0 が一番低い。
//  Pitch Resolution が 1/12 のときは 5 つの最大をその音のものとして使う
//  （note_spectrogram.js:828-835 の _bagConfidence）。High のときは 5 つを別々の行にする。
//
//  列は 1 本ずつ来る。Spectrogram と同じく、固定長の輪（ETNoteBand）に入れて
//  CGImage 1〜2 枚に畳んで貼る。88×512 の升目を Path に積まない。
//  Color が Normal のときは画像に alpha だけを持たせて型抜きに使い、塗りは .tint に任せる。
//  Note Colors のときだけ note_spectrogram.js:43-61 の色を前乗算で画像に入れて直に貼る。
//
//  取りこぼしについて。DSP は 20 ms ごと（50 fps）に枠を吐き、PipelineView の pollTelemetry は 30Hz。
//  最新の 1 枠だけだと 4 割が落ちて、前の枠の列を直す枠の番号（frameIndex - age）の当て先が無くなる。
//  なので Telemetry は種類 24 の枠を畳まずに溜め（Telemetry.drainFrames）、帯へ届いた順に全部入れる。
//  列は 512 本で、Time Span 10 秒（500 列）が収まる。1 回の入れ直しで画像は 1 度だけ組む。
//  列の間隔は一定の時間とは限らない（取りこぼしや止まっている間）ので、Time Span は
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
    case instrument3 = "Instrument3"
    case instrument9 = "Instrument9"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .normal:  return "Normal"
        case .rainbow: return "Note Colors"
        case .instrument3: return "Instrument (3)"
        case .instrument9: return "Instrument (9)"
        }
    }

    var isInstrument: Bool { self == .instrument3 || self == .instrument9 }
}

/// 音色で強調する（2.14.0、上流 MULTI_F0_HIGHLIGHTS）。強調しない音は灰色へ寄せる。
enum ETNoteHighlight: String, CaseIterable, Identifiable {
    case none = "None", vocal = "Vocal", bass = "Bass", other3 = "Other3"
    case guitar = "Guitar", piano = "Piano", strings = "Strings", wind = "Wind", synth = "Synth", organ = "Organ"
    case other9 = "Other9"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .other3: return "Other (3)"
        case .other9: return "Other (9)"
        default: return rawValue
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
        case .high:     return "High"
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
/// 既定は上流（同 :125-127）にそろえてある。ly は Horizontal、vl は true、ts は 2。
struct ETNoteDisplay: Equatable {
    var color: ETNoteColor = .normal
    var resolution: ETNoteResolution = .semitone
    var layout: ETNoteLayout = .horizontal
    var volume: Bool = true
    /// 秒。上流 :726-729 の 1〜10、刻み 1。
    var timeSpan: Double = 2
    /// 2.14.0。
    var highlight: ETNoteHighlight = .none
    var onsets: Bool = false

    /// 音色の判定で塗るか（上流 timbreEnabled）。
    var timbreEnabled: Bool { color.isInstrument || highlight != .none }
    /// 音の始まりと終わりの知らせが要るか（上流 noteEventsEnabled）。DSP の te はこれ。
    var noteEventsEnabled: Bool { onsets || timbreEnabled }
    /// 帯で描くか（上流 _usesBarHistory）。2.14.0 から High も帯で、位置を音程のずれで決める。
    var usesBars: Bool { volume || resolution == .high }

    /// 画像を作り直す必要があるか。向きと時間の幅は画像に関わらない。
    var repaintKey: String { "\(color.rawValue)/\(resolution.rawValue)/\(volume)/\(highlight.rawValue)" }
}

/// 鍵盤の寸法。上流 2.12.0 は実物のピアノの比（白鍵の幅 23.5mm・長さ 150mm・黒鍵 95mm、
/// 長さは実物の半分）で決める（plugins/frequency-axis.js:39-57 の keyboardDepths）。
/// 2.11.0 までは 28 × 1.6 = 44.8 の固定だった。
enum ETNoteKeyboard {
    /// 1 オクターブの長さに対する鍵盤の深さ。150 / (7 × 23.5) / 2。
    static let depthPerOctave: CGFloat = 150 / (7 * 23.5) / 2
    /// 白鍵の深さに対する黒鍵の深さ。95 / 150。
    static let blackDepthRatio: CGFloat = 95 / 150

    /// 鍵盤の深さと黒鍵の深さ。深さは図の短い側（交差する軸）の半分で頭を打つ
    /// （拡大しすぎても図が残るように）。
    static func depths(octaveLength: CGFloat, crossLength: CGFloat) -> (gutter: CGFloat, blackDepth: CGFloat) {
        let depth = octaveLength * depthPerOctave
        let gutter = depth < crossLength / 2 ? depth : crossLength / 2
        return (gutter, gutter * blackDepthRatio)
    }

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

    /// 小数の midi の色（隣の音名の色を混ぜる）。High の帯の Note Colors。
    static func interpolatedColor(midi: Double) -> (r: Double, g: Double, b: Double) {
        let lowerMidi = Int(midi.rounded(.down))
        let fraction = midi - Double(lowerMidi)
        let lower = noteColors[((lowerMidi % 12) + 12) % 12]
        let upper = noteColors[(((lowerMidi + 1) % 12) + 12) % 12]
        return (lower.r + (upper.r - lower.r) * fraction,
                lower.g + (upper.g - lower.g) * fraction,
                lower.b + (upper.b - lower.b) * fraction)
    }

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

// MARK: - 音量の目盛り（共有）

/// dB を 0〜1 の濃さへ写す目盛り。**上端はピークを追い、1 秒持ってから 20dB/s で落とす。**
/// note_spectrogram.js v2.11.0:89-112 の normalizedLevel / updateLevelReference。
/// 上流は Chroma Spiral もこれを借りている（chroma_spiral.js:210-220, :328）。
///
/// 幅（lr）と床（df）は呼ぶ側が渡す。Note Spectrogram は上流と同じく既定のまま使う。
/// 既定の床 -60 は MULTI_F0_LEVEL_CEILING_DB − RANGE（同 :16-17）。
struct ETLevelReference: Equatable {
    /// MULTI_F0_LEVEL_FLOOR（同 :15）。枠が無いときの上端。
    static let floor: Double = -240
    /// MULTI_F0_LEVEL_RANGE_DB（同 :16）。
    static let defaultRange: Double = 24
    /// MULTI_F0_LEVEL_CEILING_DB − MULTI_F0_LEVEL_RANGE_DB（同 :17, :90）。
    static let defaultFloor: Double = -60
    /// 同 :18-19。
    static let releaseDBPerSecond: Double = 20
    static let holdSeconds: Double = 1

    private(set) var reference: Double = ETLevelReference.floor
    private(set) var hold: Double = 0

    init() {}

    /// 追い直す。上流が levelReference を null に戻す所（chroma_spiral.js:116, :205）。
    mutating func reset() {
        reference = Self.floor
        hold = 0
    }

    /// 1 枠ぶん進める。同 :97-112。
    mutating func update(peak: Double, elapsed: Double) {
        if peak >= reference {
            reference = peak
            hold = Self.holdSeconds
        } else {
            let decay = max(0, elapsed - hold)
            hold = max(0, hold - elapsed)
            reference = max(peak, reference - Self.releaseDBPerSecond * decay)
        }
    }

    /// dB を 0〜1 へ。**下端は max(上端 − 幅, 床)。**同 :89-95。
    func normalized(_ level: Double, range: Double = ETLevelReference.defaultRange,
                    floor: Double = ETLevelReference.defaultFloor) -> Double {
        guard range > 0 else { return 0 }
        let lower = max(reference - range, floor)
        return min(max((level - lower) / range, 0), 1)
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
    /// 全画面を閉じたら増やす。カードの図が行数を測り直す（NoteSpectrogramGraph.refitToken）。
    @State private var cardRefit = 0
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
                                     range: midiRange, band: band,
                                     refitToken: cardRefit)
                if !graphOnly {
                    Button {
                        movingToFullScreen = true
                        Task { @MainActor in
                            // 先に回す。縦のまま出してから倒すと、図が 1 枚
                            // 縦の姿で描かれてから横へ跳ねる。
                            await Task.yield()
                            await ETInterfaceOrientation.turnLandscape()
                            fullScreen = true
                        }
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .etFont(size: 14, weight: .semibold)
                    }
                    .buttonStyle(.glass(.regular.interactive()))
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .accessibilityLabel("Full Screen")
                    .padding(8)
                }
            }
            // 上流の並びは Color → Pitch Resolution → Layout → Volume →
            // Time Span → Lowest Note → Highest Note（2.13.0 で Regular Note Limit が無くなった）。
            if !graphOnly { controls }
            // te（Timbre Enabled）は保存しない値で、行を出さない。Color・Highlight・Onsets から決まる。
            ForEach(node.spec.params.filter { !$0.runtimeOnly }) { param in
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
        .etSaved($display.highlight, key: "hl", index: index, dsp: dsp)
        .etSaved($display.onsets, key: "os", index: index, dsp: dsp)
        .onAppear { syncTimbre(display.noteEventsEnabled) }
        .onChange(of: display.noteEventsEnabled) { _, on in syncTimbre(on) }
        .fullScreenCover(isPresented: $fullScreen, onDismiss: {
            ETInterfaceOrientation.request(.portrait)
            movingToFullScreen = false
            cardRefit += 1
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
            ETDisplayChoiceRow(title: "Highlight",
                               options: ETNoteHighlight.allCases.map { (value: $0, label: $0.label) },
                               selection: $display.highlight, style: .menu)
            ETNoteChoiceRow(title: "Pitch Resolution",
                            options: ETNoteResolution.allCases,
                            text: { $0.label },
                            selection: $display.resolution)
            ETNoteChoiceRow(title: "Layout",
                            options: ETNoteLayout.allCases,
                            text: { $0.label },
                            selection: $display.layout)
            Toggle(isOn: $display.volume) {
                Text("Volume").etFont(size: 14)
            }
            .padding(.vertical, 2)
            Toggle(isOn: $display.onsets) {
                Text("Onsets").etFont(size: 14)
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
                    .etFont(size: 14)
                    .etRowTitle()
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

    /// 音色の判定を DSP に走らせるか（te）。保存しない値なので、表示から毎回決めて送る。
    private func syncTimbre(_ on: Bool) {
        guard let te = node.spec.params.first(where: { $0.key == "te" }),
              node.values.indices.contains(te.offset) else { return }
        let want: Float = on ? 1 : 0
        if node.values[te.offset] != want { dsp.setValue(want, at: index, offset: te.offset) }
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
                .etFont(size: 14)
            HStack(spacing: 6) {
                ForEach(options) { option in
                    let isSelected = selection == option
                    Button {
                        selection = option
                    } label: {
                        Text(text(option))
                            .etFont(size: 13, weight: isSelected ? .bold : .regular)
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
struct ETNoteRangeRow: View {

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
                    .etFont(size: 14)
                    .etRowTitle()
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

// MARK: - 図の色

/// 鍵盤と地の色。**どれも不透明。**
///
/// 上流は canvas に最初に地（graph-bg-deep）を全面に塗り、鍵は不透明な rgb で塗る
/// （note_spectrogram.js:1753 と :1875-1883）。こちらは以前 .quaternary / .secondary
/// （前景色に不透明度を掛けた階層スタイル）で塗っていたので、カードの材質や罫が鍵の裏に透けた。
/// 値は上流 _displayPalette（:858-872）と、既定テーマの graph-bg-deep（暗い #000、paper #fff）、
/// graph-base-soft（paper の #fafafa に文字色 #1a1a1a を 4% 混ぜた 241）から。
private struct ETNotePalette {
    let dark: Bool
    /// 「コントラストを上げる」が入っているとき。見た目を変えるのはこのときだけ。
    let increasedContrast: Bool

    init(_ scheme: ColorScheme, contrast: ColorSchemeContrast = .standard) {
        dark = scheme == .dark
        increasedContrast = contrast == .increased
    }

    var background: Color { dark ? .black : .white }
    /// 黒鍵の高さの帯。暗い外観は地 + 8（MULTI_F0_BLACK_KEY_BACKGROUND）。
    var blackBand: Color { Color(white: (dark ? 8 : 241) / 255) }
    var whiteKey: Double { dark ? 238 : 255 }
    var blackKey: Double { 17 }
    /// 鍵の境と縁の線（graph-label）。
    static let line = Color(white: 0x66 / 255)
    /// 鍵の上の字。上流は #111 固定。
    static let keyText = Color(white: 0x11 / 255)
    /// 凡例の字。上流は graph-label（#666）固定だが、黒い地では約 3.7:1 で読みにくい。
    /// 見た目を変えないため、暗い外観で「コントラストを上げる」のときだけ明るくする
    /// （明るい外観の白地では #666 のまま 5.7:1 ある）。
    var legendText: Color { dark && increasedContrast ? Color(white: 0.62) : Self.line }

    /// 鍵の地の値（0〜255）から音の色へ confidence で寄せた、不透明な色。上流 :1875 の式。
    func lit(from base: Double, to color: (r: Double, g: Double, b: Double), by value: Double) -> Color {
        func channel(_ target: Double) -> Double { (base + (target - base) * value).rounded() / 255 }
        return Color(red: channel(color.r), green: channel(color.g), blue: channel(color.b))
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
    /// 音の高さの軸を画素で測るのに要る（Horizontal は幅、Vertical は高さ）。行の複製はこれで決める。
    @Environment(\.displayScale) private var displayScale
    /// 地と鍵の色を決める（ETNotePalette）。
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    /// 全画面を閉じたとき、カードの図に行数の測り直しを頼む鍵。
    /// 帯は全画面と共有なので、全画面で増えた行数がカードに残る（fit は大きさが変わらないと呼ばれない）。
    var refitToken = 0

    /// いまの図の大きさ。音の高さの軸の画素数を出すのに使う。
    @State private var canvasSize: CGSize = .zero
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
                // 鍵盤の帯。上流 2.12.0 と同じ比（ETNoteKeyboard.depths）。音の行の高さから決まり、
                // 狭い面では図の半分で頭を打つ。
                let rowHeight = frame.height / CGFloat(range.count)
                let gutter = ETNoteKeyboard.depths(octaveLength: 12 * rowHeight,
                                                   crossLength: frame.width).gutter
                let rollWidth = frame.width - gutter
                guard rollWidth > 0, frame.height > 0 else { return }

                let palette = ETNotePalette(colorScheme, contrast: contrast)
                context.drawLayer { layer in
                    frame.apply(&layer)
                    // 不透明な地を最初に敷く（上流 :1753）。鍵盤や音の裏に、カードの材質や
                    // 枠が透けないようにする。
                    layer.fill(Path(CGRect(x: 0, y: 0, width: frame.width, height: frame.height)),
                               with: .color(palette.background))
                    drawBands(&layer, frame: frame, rollWidth: rollWidth, rowHeight: rowHeight,
                              palette: palette)
                    drawGrid(&layer, frame: frame, rollWidth: rollWidth, rowHeight: rowHeight)
                    drawRoll(&layer, frame: frame, rollWidth: rollWidth, slots: slots)
                    if display.onsets {
                        drawOnsets(&layer, frame: frame, rollWidth: rollWidth, rowHeight: rowHeight, slots: slots)
                    }
                    drawKeys(&layer, frame: frame, rollWidth: rollWidth,
                             gutter: gutter, rowHeight: rowHeight, palette: palette)
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
                drawLegend(&context, in: plot.rect, palette: palette)
            },
            overlay: { plot in
                // 触って値を読むだけなので、一覧の縦スクロールと同時に効かせる。
                Color.clear
                    .contentShape(Rectangle())
                    // etOwnsDrag-exempt: 試聴の音と目印を出すだけで何も動かさない。行の掴みと払いは止めず、縦スクロールと同時に効かせる
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
                refit()
                ingest()
            }
            // **縦の引き伸ばしを画像へ持たせる**（ETNoteBand.rowScale）。
            // 音の高さの軸の画素数は、大きさ・向き・音の範囲のどれが変わっても変わる。
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                canvasSize = size
                refit()
            }
            .onChange(of: display.layout) { _, _ in refit() }
            .onChange(of: range) { _, _ in refit() }
            .onChange(of: refitToken) { _, _ in refit() }
            .onChange(of: latestSequence) { _, _ in ingest() }
            // 手元と PC で時計が違う。入れ替わったら溜めた列を捨てる（残すと Time Span の列数が狂う）。
            .onChange(of: display) { _, now in band.display = now }
    }

    /// 音の高さの軸の画素数に合わせて、帯の行の複製を決め直す。
    /// 軸は Horizontal では図の幅、Vertical では高さ（ETNoteRollFrame）。
    /// canvasSize は GraphCanvas 全体なので、Vertical は上の値の行と余白（上下 6pt）を引く。
    private func refit() {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return }
        // 帯は表示の切り替えで 1 音の行数が変わる。先に渡しておく。
        band.display = display
        let along = display.layout == .horizontal
            ? canvasSize.width - 12
            : canvasSize.height - ETGraphMetrics.readoutHeight - 4 - 12
        band.fit(pitchPixels: max(0, along) * displayScale, notes: range.count)
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
        // **縦は貼る画像の行数がほぼ画素数**（fit(pitchPixels:notes:) が合わせる）なので、
        // 拡大率は 1 前後。動くのは横（時間の向き）だけ。
        //
        // **列が 1 画素より広いときは最近傍で貼る。**
        // 上流は時間を 1024 列に割って 1 列がほぼ 1 画素なので、平滑化しても縁がにじまない。
        // こちらは 1 枠が 1 列で、Time Span 2 秒では約 100 列を 300 画素以上に引き伸ばす。
        // そこで平滑化すると、音の縁と鳴り始め・鳴り終わりが数画素の勾配になってぼける。
        // 列が 1 画素以下なら縮めるだけなので平滑化のほうが荒れない。
        //
        // **`interpolation` は `GraphicsContext` ではなく `Image` の修飾子。**
        // `context.interpolation = .none` は通らない（has no member）。
        let columnPixels = rollWidth / CGFloat(max(slots, 1)) * displayScale
        let smoothing: Image.Interpolation = columnPixels > 1 ? .none : .high
        func tile(_ image: CGImage) -> Image {
            Image(decorative: image, scale: 1)
                .interpolation(smoothing)
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
                           rollWidth: CGFloat, rowHeight: CGFloat, palette: ETNotePalette) {
        var black = Path()
        for midi in range
        where ETNoteKeyboard.blackClasses.contains(((midi % 12) + 12) % 12) {
            let y = CGFloat(range.upperBound - midi) * rowHeight
            guard y + rowHeight > 0, y < frame.height else { continue }
            black.addRect(CGRect(x: 0, y: y, width: rollWidth, height: rowHeight))
        }
        // 白い帯は地そのもの（上流の whiteBand = graph-bg-deep）。黒い帯だけ不透明な色で塗る。
        context.fill(black, with: .color(palette.blackBand))
    }

    /// 鍵盤。白鍵は帯いっぱい、黒鍵は手前だけ。最新の列の confidence で光らせる。
    /// 上流 :1125-1183。鍵は上流と同じ不透明な色で塗り（ETNotePalette）、裏の材質や罫を透かさない。
    /// 光る鍵は上流 :1875 と同じく、鍵の色から音の色へ confidence で寄せた不透明な色にする。
    private func drawKeys(_ context: inout GraphicsContext, frame: ETNoteRollFrame,
                          rollWidth: CGFloat, gutter: CGFloat, rowHeight: CGFloat,
                          palette: ETNotePalette) {
        let blackDepth = gutter * ETNoteKeyboard.blackDepthRatio
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

        // **鍵は全部不透明な色で塗る**（ETNotePalette）。光る鍵も opacity を掛けず、
        // 消灯の色から音の色へ寄せた不透明な色で塗り直す。
        context.fill(white, with: .color(Color(white: palette.whiteKey / 255)))
        light(&context, whiteGlow, base: palette.whiteKey, palette: palette)
        context.stroke(separators, with: .color(ETNotePalette.line), lineWidth: 0.5)
        context.fill(black, with: .color(Color(white: palette.blackKey / 255)))
        light(&context, blackGlow, base: palette.blackKey, palette: palette)
        outline(&context, blackGlow, rollWidth: rollWidth, blackDepth: blackDepth, rowHeight: rowHeight,
                horizontal: frame.horizontal)
        var edge = Path()
        edge.move(to: CGPoint(x: rollWidth, y: 0))
        edge.addLine(to: CGPoint(x: rollWidth, y: frame.height))
        context.stroke(edge, with: .color(ETNotePalette.line), lineWidth: 1)
    }

    /// 光っている黒鍵の縁取り（上流 2.15.0。note_spectrogram.js の outlineTint）。
    /// 白を鍵の色へ 0.2 だけ寄せた色で、濃さは鍵と同じ（confidence）。太さは行の高さと黒鍵の深さの小さいほうの 1 割。
    /// **奥の辺は開けておく**（上流は Horizontal で上、Vertical で右。draw 空間では x = rollWidth と
    /// rollWidth + blackDepth）。ETNoteRollFrame の回し方は上流と同じなので式はそのまま。
    private func outline(_ context: inout GraphicsContext,
                         _ keys: [(rect: CGRect, midi: Int, value: Double)],
                         rollWidth: CGFloat, blackDepth: CGFloat, rowHeight: CGFloat, horizontal: Bool) {
        let width = min(rowHeight, blackDepth) * 0.1
        guard width > 0 else { return }
        let inset = width / 2
        let back = rollWidth + (horizontal ? inset : blackDepth - inset)
        let front = rollWidth + (horizontal ? blackDepth - inset : inset)
        for key in keys where key.value > 0 {
            let c = band.keyColor(midi: key.midi)
            func tint(_ channel: Double) -> Double { (255 + (channel - 255) * 0.2) / 255 }
            var path = Path()
            path.move(to: CGPoint(x: back, y: key.rect.minY + inset))
            path.addLine(to: CGPoint(x: front, y: key.rect.minY + inset))
            path.addLine(to: CGPoint(x: front, y: key.rect.maxY - inset))
            path.addLine(to: CGPoint(x: back, y: key.rect.maxY - inset))
            var pen = context
            pen.opacity = key.value
            pen.stroke(path, with: .color(Color(red: tint(c.r), green: tint(c.g), blue: tint(c.b))),
                       lineWidth: width)
        }
    }

    /// 光っている鍵を塗る。**音名ごとの色を使う。**
    ///
    /// 上流は Normal のとき trace（1 色）で光らせる（note_spectrogram.js:1148）が、
    /// それだと 88 鍵が同じ青で光るだけで、どの音かは鍵の位置を数えないと分からない。
    /// 色を持たせれば、光った所を見ただけで音名が分かる。
    /// 配色は Note Colors と同じ表（ETNoteKeyboard.noteColors）を使うので、
    /// 図の塗り分けを Note Colors にしたときに鍵と升目の色が揃う。
    ///
    /// 濃さ（確からしさ）は opacity でなく色の寄せ方で出す（上流 :1875-1883）。
    /// opacity で重ねると鍵の裏が透ける。
    private func light(_ context: inout GraphicsContext,
                       _ keys: [(rect: CGRect, midi: Int, value: Double)],
                       base: Double, palette: ETNotePalette) {
        for key in keys {
            // 音色で塗っているときは判定の色（上流は Instrument のときだけ鍵に Highlight も掛ける）。
            let c = band.keyColor(midi: key.midi)
            context.fill(Path(key.rect), with: .color(palette.lit(from: base, to: c, by: key.value)))
        }
    }

    /// C の字を鍵の上に置く。上流 :1203-1212。白鍵の真ん中に来る。
    private func drawOctaveLabels(_ context: inout GraphicsContext, frame: ETNoteRollFrame,
                                  rollWidth: CGFloat, gutter: CGFloat, rowHeight: CGFloat) {
        let blackDepth = gutter * ETNoteKeyboard.blackDepthRatio
        // 白鍵の見える部分（黒鍵の奥）が字より狭いなら書かない。2.12.0 の鍵盤は浅く、iPhone の幅では
        // 数 pt になる。
        guard gutter - blackDepth >= ETGraphMetrics.labelSize * 1.5 else { return }
        let x = rollWidth + (blackDepth + gutter) / 2
        let whiteHeight = 12 * rowHeight / 7
        for midi in range where midi >= 24 && midi % 12 == 0 {
            let y = frame.height
                - (CGFloat(midi - range.lowerBound) * rowHeight + whiteHeight / 2)
            guard y >= 0, y <= frame.height else { continue }
            context.draw(Text("C\(midi / 12 - 1)")
                            .font(.system(size: ETGraphMetrics.labelSize, design: .monospaced))
                            // 白鍵の上の字は上流も #111 固定。
                            .foregroundStyle(ETNotePalette.keyText),
                         at: frame.point(x, y), anchor: .center)
        }
    }

    // MARK: 触った所

    private func sample(at location: CGPoint, plot: ETPlot, slots: Int) -> ETNoteProbe {
        let frame = ETNoteRollFrame(rect: plot.rect, horizontal: display.layout == .horizontal)
        let local = frame.local(location)
        let rowHeight = frame.height / CGFloat(range.count)
        let gutter = ETNoteKeyboard.depths(octaveLength: 12 * rowHeight, crossLength: frame.width).gutter
        let rollWidth = frame.width - gutter

        let row = rowHeight > 0 ? Int((local.y / rowHeight).rounded(.down)) : 0
        let midi = min(max(range.upperBound - row, range.lowerBound), range.upperBound)

        var confidence: Double?
        var level: Double?
        var timbre: String?
        let columnWidth = rollWidth / CGFloat(max(slots, 1))
        if columnWidth > 0, rollWidth > 0 {
            let shown = min(band.count, slots)
            let left = rollWidth - CGFloat(shown) * columnWidth
            let slot = Int(((local.x - left) / columnWidth).rounded(.down))
            if let cell = band.cell(displayColumn: slot, midi: midi, slots: slots) {
                confidence = Double(cell.confidence)
                level = cell.confidence > 0 ? Double(cell.level) : nil
            }
            timbre = band.timbreName(displayColumn: slot, midi: midi, slots: slots)
        }
        return ETNoteProbe(midi: midi, confidence: confidence, level: level, timbre: timbre)
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
        // 楽器の色は似た色が多く、凡例と見比べないと読めない。名前でも出して、色に頼らず確かめられるようにする。
        if let timbre = probe.timbre {
            items.append(ETReadoutItem("CLASS", timbre))
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
        ETNoteSnapshot(telemetry.frame(tap: tapId, type: .noteSpectrogram))
    }

    /// 最新の枠の通し番号。変わったら溜まっている枠を取りに行く。
    private var latestSequence: UInt32? {
        telemetry.frame(tap: tapId, type: .noteSpectrogram)?.sequence
    }

    /// 溜まっている枠を届いた順に全部帯へ入れる。**最新の 1 枠だけだと 50 fps の 4 割が落ち**、
    /// 2・4・8 枠前の確からしさの直しの当て先の列が無くなる。全画面と元の図は同じ帯を見るので、
    /// 先に取った側が入れれば足りる。
    private func ingest() {
        let frames = telemetry.drainFrames(tap: tapId, type: ETFrameType.noteSpectrogram.rawValue)
        band.push(contentsOf: frames.compactMap { ETNoteSnapshot($0) })
        // 音色の知らせは同じ tap に型 31 で来る。音の枠の後に入れる（列の番号で当てるので）。
        let timbre = telemetry.drainFrames(tap: tapId, type: ETNoteTimbreEvent.frameType)
        band.push(timbre: timbre.compactMap { ETNoteTimbreEvent($0) })
    }

    /// 音の始まりの印（上流 _drawOnsets）。右向きの三角。Horizontal では面ごと回るので下向きになる。
    private func drawOnsets(_ context: inout GraphicsContext, frame: ETNoteRollFrame,
                            rollWidth: CGFloat, rowHeight: CGFloat, slots: Int) {
        let columnWidth = rollWidth / CGFloat(max(slots, 1))
        let shown = min(band.count, slots)
        let left = rollWidth - CGFloat(shown) * columnWidth
        let size = min(rowHeight * 0.75, 10)
        var layer = context
        layer.clip(to: Path(CGRect(x: 0, y: 0, width: rollWidth, height: frame.height)))
        for mark in band.onsets(slots: slots) where range.contains(mark.midi) {
            let x = left + CGFloat(mark.displayColumn) * columnWidth
            let y = frame.height - (CGFloat(mark.pitch - Double(range.lowerBound)) + 0.5) * rowHeight
            var path = Path()
            path.move(to: CGPoint(x: x, y: y - size / 2))
            path.addLine(to: CGPoint(x: x, y: y + size / 2))
            path.addLine(to: CGPoint(x: x + size, y: y))
            path.closeSubpath()
            layer.fill(path, with: .color(Color(red: mark.color.r / 255, green: mark.color.g / 255,
                                                blue: mark.color.b / 255)))
            layer.stroke(path, with: .color(.black.opacity(0.6)), lineWidth: 1)
        }
    }

    /// 音色の凡例（上流 _drawTimbreLegend）。左上から並べ、入らなければ折り返す。
    /// 地は図の地（graph-bg-deep）、字は graph-label（#666）で上流と同じ。外観に依らず黒い地に .secondary の字だと、
    /// 明るい外観で暗い地に濃い灰色が乗って読めなかった。
    private func drawLegend(_ context: inout GraphicsContext, in rect: CGRect, palette: ETNotePalette) {
        var labels: [String] = []
        switch display.color {
        case .instrument3: labels = ["Vocal", "Bass", "Other"]
        case .instrument9: labels = ETNoteTimbre.classes
        default: break
        }
        if display.highlight != .none { labels.append("Highlight: \(display.highlight.label)") }
        guard !labels.isEmpty else { return }
        let padding: CGFloat = 6, line: CGFloat = 20, swatch: CGFloat = 14
        var x = rect.minX + padding, y = rect.minY + padding
        for label in labels {
            let index = ETNoteTimbre.classes.firstIndex(of: label)
            let text = context.resolve(Text(label).font(.system(size: 12)).foregroundStyle(palette.legendText))
            let width = text.measure(in: CGSize(width: 1000, height: line)).width + (index == nil ? 0 : swatch)
                + 2 * padding
            if x > rect.minX + padding && x + width > rect.maxX - padding { x = rect.minX + padding; y += line }
            guard y + line <= rect.maxY else { break }
            context.fill(Path(CGRect(x: x, y: y, width: width, height: line)), with: .color(palette.background))
            if let index {
                let c = ETNoteTimbre.colors[index]
                context.fill(Path(CGRect(x: x + padding, y: y + 5, width: 10, height: 10)),
                             with: .color(Color(red: c.r / 255, green: c.g / 255, blue: c.b / 255)))
            }
            context.draw(text, at: CGPoint(x: x + padding + (index == nil ? 0 : swatch), y: y + line / 2),
                         anchor: .leading)
            x += width
        }
    }
}

// MARK: - 1 枠
//
// ETNoteSnapshot（枠の読み）は DSP/NoteSpectrogramFrame.swift。Foundation だけで試せるように外へ出した。

struct ETNoteProbe {
    let midi: Int
    let confidence: Double?
    let level: Double?
    /// 触った音の楽器の名前。判定がまだ無い音・音色を見ない設定では nil。
    let timbre: String?
}

// MARK: - 横に流す帯

/// 細分ごとの確からしさを固定長の輪で持つ。新しい列は右端、古い列は左へ。
/// 描く用の並びは表示の切り替えで作り直す。
final class ETNoteBand: ObservableObject {

    /// 512 列。2.13.0 は枠を全部入れる（50 fps）ので、Time Span 10 秒が 500 列になる。
    static let columns = 512
    /// 数は枠の読みと同じもの（ETNoteFrameLayout、NoteSpectrogramFrame.swift）。
    static let notes = ETNoteFrameLayout.notes
    static let divisions = ETNoteFrameLayout.divisions
    static let pitches = ETNoteFrameLayout.pitches
    static let firstMidi = ETNoteFrameLayout.firstMidi
    static let lastMidi = firstMidi + notes - 1

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
    /// **画像の行数を、音の高さの軸の画素数にほぼ合わせる。**
    /// 行数が画素数に近ければ、貼るときの縦の拡大率が 1 前後で、縁がにじまない。
    /// 数えるのは**いま見せている音の数**（88 音全部ではない）と、**音の高さの側の
    /// 画素**（Horizontal では幅、Vertical では高さ）。以前は 88 音全部と図の高さで
    /// 数えていたので、既定の 64 音・Horizontal では行が足りず、約 3 倍に滑らかに
    /// 引き伸ばされて音の縁がぼやけていた。
    /// 貼る前に伸ばすと 30Hz で 2MB の面を組み直すことになるので、
    /// **画像を作る時点で行を複製しておく。**
    private(set) var rowScale = 1

    /// 最後に頼まれた、音の高さの軸の画素数と見せている音の数。
    /// Volume / High の切り替えで 1 音の行数（base）が変わると rowScale も決め直しになるので、覚えておく。
    private var fitPixels: CGFloat = 0
    private var fitNotes = ETNoteBand.notes

    /// 画像が持つ行数の上限（88 音 × base × rowScale）。メモリ（512 列 × 4 バイト）が 8MB ほどで頭を打つ。
    private static let maxImageRows = 3600

    private func wantedRowScale() -> Int {
        let base = display.usesBars ? Self.divisions : 1
        let ideal = fitPixels / CGFloat(max(1, fitNotes * base))
        let cap = max(1, min(16, Self.maxImageRows / (Self.notes * base)))
        return min(cap, max(1, Int(ideal.rounded())))
    }

    /// 音の高さの軸の画素数に合わせて行の複製を決める。**描く前に呼ぶ。**
    /// - Parameters:
    ///   - pixels: 音の高さの軸の長さ（画素）。Horizontal では図の幅、Vertical では高さ。
    ///   - notes: いま見せている音の数（Lowest / Highest Note の範囲）。
    func fit(pitchPixels pixels: CGFloat, notes: Int) {
        fitPixels = pixels
        fitNotes = notes
        let want = wantedRowScale()
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
            // Volume / High で 1 音の行数が変わるので、複製数も決め直す。
            rowScale = wantedRowScale()
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
    /// その列に入れた枠（generation, frameIndex）。後の枠が運ぶ直しの当て先を探すのに使う。
    private var frames = [(generation: UInt32, index: UInt32)?](repeating: nil,
                                                                count: ETNoteBand.columns)
    /// RGBA、前乗算。Normal では 4 バイトとも同じ値（使うのは alpha だけ）。
    private var pixels: [UInt8] = []
    /// 鍵ごとの音程のずれ（セント）。[note * columns + column]。High の帯の位置。
    private var cents = [Float](repeating: 0, count: ETNoteBand.notes * ETNoteBand.columns)

    // MARK: 音色（2.14.0）

    private struct TimbreNote {
        let noteId: UInt32
        let midi: Int
        let start: UInt32
        var end: UInt32
        var probabilities: [Float]?
        var fade = 0
    }
    /// いま見えている音の音色。noteId で引く。
    private var timbreNotes: [UInt32: TimbreNote] = [:]
    /// 鍵ごとの noteId（始まりの順）。
    private var timbreByPitch = [[UInt32]](repeating: [], count: ETNoteBand.notes)
    /// 塗り直す枠の範囲 [start, end)。end が 0xffffffff はまだ続いている。
    private var dirtyRanges: [(start: UInt32, end: UInt32)] = []
    /// 音の枠の世代。違う世代の音色は捨てる。
    private var activeGeneration: UInt32?

    /// 音量の目盛り。幅と床は上流の既定のまま（lr 24 / df -60）。
    private var levelReference = ETLevelReference()
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
        let base = display.usesBars ? Self.divisions : 1
        let needed = base * rowScale
        let bytes = Self.notes * needed * Self.columns * 4
        guard rowsPerNote != needed || pixels.count != bytes else { return }
        rowsPerNote = needed
        pixels = [UInt8](repeating: 0, count: bytes)
    }

    /// 届いた枠を全部入れる。画像の組み直しは最後に 1 回だけ。
    func push(contentsOf snapshots: [ETNoteSnapshot]) {
        var added = false
        for snapshot in snapshots where append(snapshot) { added = true }
        // 判定が付いたばかりの音は、灰色から 3 回で色へ移す。
        for (id, note) in timbreNotes where note.probabilities != nil && note.fade < ETNoteTimbre.fadeSteps {
            timbreNotes[id]?.fade += 1
            dirtyRanges.append((note.start, note.end))
        }
        let repainted = repaintDirty()
        guard added || repainted else { return }
        image = makeImage()
        revision &+= 1
    }

    /// 音色の知らせを入れる（上流 handleTimbreTelemetry）。塗り直しは次の push でまとめる。
    func push(timbre events: [ETNoteTimbreEvent]) {
        guard display.noteEventsEnabled, !events.isEmpty else { return }
        for event in events where event.generation == activeGeneration {
            let slot = event.midi - Self.firstMidi
            guard slot >= 0, slot < Self.notes else { continue }
            if var note = timbreNotes[event.noteId] {
                guard note.midi == event.midi, note.start == event.startFrameIndex else { continue }
                if event.endFrameIndex != ETNoteTimbreEvent.openEnd, note.end != event.endFrameIndex {
                    if note.probabilities != nil { dirtyRanges.append((event.endFrameIndex, note.end)) }
                    note.end = event.endFrameIndex
                }
                if let p = event.probabilities {
                    if note.probabilities == nil { note.fade = 0 }
                    note.probabilities = p
                    dirtyRanges.append((note.start, note.end))
                }
                timbreNotes[event.noteId] = note
            } else {
                // 鳴り直しは、終わりの知らせを落としていても前の音を閉じる。
                for id in timbreByPitch[slot] {
                    guard var previous = timbreNotes[id], previous.end == ETNoteTimbreEvent.openEnd,
                          Self.newer(event.startFrameIndex, than: previous.start) else { continue }
                    if previous.probabilities != nil { dirtyRanges.append((event.startFrameIndex, previous.end)) }
                    previous.end = event.startFrameIndex
                    timbreNotes[id] = previous
                }
                var note = TimbreNote(noteId: event.noteId, midi: event.midi, start: event.startFrameIndex,
                                      end: event.endFrameIndex, probabilities: event.probabilities)
                if note.probabilities != nil { dirtyRanges.append((note.start, note.end)) }
                note.fade = 0
                timbreNotes[event.noteId] = note
                timbreByPitch[slot].append(event.noteId)
                timbreByPitch[slot].sort { (timbreNotes[$0]?.start ?? 0) < (timbreNotes[$1]?.start ?? 0) }
            }
        }
    }

    private static func newer(_ candidate: UInt32, than current: UInt32) -> Bool {
        let delta = candidate &- current
        return delta != 0 && delta < 0x8000_0000
    }

    private static func covers(_ frame: UInt32, start: UInt32, end: UInt32) -> Bool {
        let age = frame &- start
        return age < 0x8000_0000 && (end == ETNoteTimbreEvent.openEnd || age < end &- start)
    }

    /// 塗り直す範囲にかかる列を描き直す。描き直したら true。
    private func repaintDirty() -> Bool {
        guard !dirtyRanges.isEmpty else { return false }
        let ranges = dirtyRanges
        dirtyRanges.removeAll()
        var any = false
        for column in 0..<Self.columns {
            guard let frame = frames[column]?.index else { continue }
            if ranges.contains(where: { Self.covers(frame, start: $0.start, end: $0.end) }) {
                paint(column: column)
                any = true
            }
        }
        return any
    }

    /// 一番古い列より前に終わった音を捨てる。
    private func pruneTimbre() {
        guard count == Self.columns, let oldest = frames[head]?.index else { return }
        for slot in 0..<Self.notes {
            while let id = timbreByPitch[slot].first, let note = timbreNotes[id],
                  note.end != ETNoteTimbreEvent.openEnd, oldest &- note.end < 0x8000_0000 {
                timbreNotes.removeValue(forKey: id)
                timbreByPitch[slot].removeFirst()
            }
        }
    }

    private func clearTimbre() {
        timbreNotes.removeAll()
        for slot in timbreByPitch.indices { timbreByPitch[slot].removeAll() }
        dirtyRanges.removeAll()
    }

    /// 触った所の楽器の名前（確からしさがいちばん高い分類）。3 分類のときは Bass・Vocal・Other の 3 つ。
    /// 色でしか楽器を見分けられない人のための読み値。判定がまだ届いていない音は nil。
    func timbreName(displayColumn: Int, midi: Int, slots: Int) -> String? {
        let shown = min(count, slots)
        guard display.timbreEnabled, displayColumn >= 0, displayColumn < shown else { return nil }
        let start = (head - shown + Self.columns) % Self.columns
        let column = (start + displayColumn) % Self.columns
        guard let p = timbre(column: column, midi: midi)?.probabilities, p.count >= 9 else { return nil }
        // 3 分類の色と強調は Other を 1〜7 番の合計として扱う。読み値も合計で比べないと、
        // Other の色で描いた音を Bass と読み上げて食い違う。
        if display.color == .instrument3 {
            let other = p[1..<8].reduce(0, +)
            if other > p[0] && other > p[8] { return "Other" }
            return p[8] > p[0] ? ETNoteTimbre.classes[8] : ETNoteTimbre.classes[0]
        }
        var best = 0
        for category in 1..<9 where p[category] > p[best] { best = category }
        return ETNoteTimbre.classes[best]
    }

    /// その列でその鍵に鳴っていた音（上流 _timbreForColumn）。
    private func timbre(column: Int, midi: Int) -> TimbreNote? {
        guard let frame = frames[column]?.index else { return nil }
        let slot = midi - Self.firstMidi
        guard slot >= 0, slot < Self.notes else { return nil }
        for id in timbreByPitch[slot].reversed() {
            if let note = timbreNotes[id], Self.covers(frame, start: note.start, end: note.end) { return note }
        }
        return nil
    }

    /// 音の色（上流 _noteDisplayColor）。`base` は Normal と Note Colors のときの色。
    private func displayColor(column: Int, midi: Int, base: (r: Double, g: Double, b: Double),
                              applyHighlight: Bool = true) -> (r: Double, g: Double, b: Double) {
        guard display.timbreEnabled else { return base }
        let note = timbre(column: column, midi: midi)
        let p = note?.probabilities
        var color = base
        if display.color.isInstrument {
            color = p.map { ETNoteTimbre.color($0, threeClass: display.color == .instrument3) }
                ?? ETNoteTimbre.unclassified
        }
        let highlighted = display.highlight != .none && applyHighlight
        if highlighted {
            let w = ETNoteTimbre.highlightProbability(p, target: display.highlight.rawValue)
            let g = ETNoteTimbre.unclassified
            color = (w * color.r + (1 - w) * g.r, w * color.g + (1 - w) * g.g, w * color.b + (1 - w) * g.b)
        }
        if let note, note.probabilities != nil, note.fade < ETNoteTimbre.fadeSteps {
            let from = highlighted || display.color.isInstrument ? ETNoteTimbre.unclassified : base
            let t = Double(note.fade) / Double(ETNoteTimbre.fadeSteps)
            color = (from.r + (color.r - from.r) * t, from.g + (color.g - from.g) * t, from.b + (color.b - from.b) * t)
        }
        return color
    }

    /// 鍵盤を光らせる色。最新の列の音色。Highlight は Instrument のときだけ鍵に掛ける（上流と同じ）。
    func keyColor(midi: Int) -> (r: Double, g: Double, b: Double) {
        let base = ETNoteKeyboard.noteColors[((midi % 12) + 12) % 12]
        guard count > 0 else { return base }
        let column = (head - 1 + Self.columns) % Self.columns
        return displayColor(column: column, midi: midi, base: base, applyHighlight: display.color.isInstrument)
    }

    /// 音の始まりの印（左から数えた列・音の高さ・色）。
    func onsets(slots: Int) -> [(displayColumn: Int, midi: Int, pitch: Double, color: (r: Double, g: Double, b: Double))] {
        let shown = min(count, slots)
        guard shown > 0 else { return [] }
        let start = (head - shown + Self.columns) % Self.columns
        var byFrame: [UInt32: Int] = [:]
        for display in 0..<shown {
            let column = (start + display) % Self.columns
            if let frame = frames[column]?.index, byFrame[frame] == nil { byFrame[frame] = display }
        }
        var out: [(Int, Int, Double, (r: Double, g: Double, b: Double))] = []
        for note in timbreNotes.values {
            guard let displayColumn = byFrame[note.start] else { continue }
            let column = (start + displayColumn) % Self.columns
            let slot = note.midi - Self.firstMidi
            let pitch = display.resolution == .high
                ? Double(note.midi) + Double(cents[slot * Self.columns + column]) / 100 : Double(note.midi)
            let base = display.color == .rainbow ? ETNoteKeyboard.interpolatedColor(midi: pitch)
                : ETNoteKeyboard.noteColors[((note.midi % 12) + 12) % 12]
            out.append((displayColumn, note.midi, pitch, displayColor(column: column, midi: note.midi, base: base)))
        }
        return out
    }

    func push(_ snapshot: ETNoteSnapshot) {
        push(contentsOf: [snapshot])
    }

    /// 1 枠を列にして描く。入れたら true。
    private func append(_ snapshot: ETNoteSnapshot) -> Bool {
        guard snapshot.confidence.count == Self.pitches,
              snapshot.level.count == Self.pitches else { return false }
        // 同じ枠を 2 度入れない。描き直しのたびに列が増えてしまう。
        if let previous = lastIndex, previous == snapshot.frameIndex { return false }
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
            loudness[note * Self.columns + column] = Self.byte(Float(levelReference.normalized(db)))
        }
        times[column] = snapshot.time
        frames[column] = (snapshot.generation, snapshot.frameIndex)
        if snapshot.pitchCents.count == Self.notes {
            for note in 0..<Self.notes { cents[note * Self.columns + column] = snapshot.pitchCents[note] }
        }
        if activeGeneration != snapshot.generation {
            activeGeneration = snapshot.generation
            clearTimbre()
        }
        paint(column: column)

        head = (head + 1) % Self.columns
        if count < Self.columns { count += 1 }
        pruneTimbre()
        for fix in snapshot.revisions {
            revise(generation: snapshot.generation, index: snapshot.frameIndex &- fix.age,
                   confidence: fix.confidence)
        }
        return true
    }

    /// 前の枠の確からしさを直す（2.13.0。上流 _applyFrameRevision、note_spectrogram.js:760-781）。
    /// 当て先は最新から age 枠までの列だけを探す。無い（取りこぼした、もう流れた）なら何もしない。
    /// dB（Volume）は直さない。上流も volumeLevelHistory はそのまま。
    private func revise(generation: UInt32, index: UInt32, confidence: [Float]) {
        guard confidence.count == Self.pitches,
              let column = ETNoteFrameLayout.revisionColumn(frames: frames, head: head, count: count,
                                                       generation: generation, index: index)
        else { return }
        for pitch in 0..<Self.pitches {
            fine[pitch * Self.columns + column] = Self.byte(confidence[pitch])
        }
        paint(column: column)
    }

    /// 溜めた列を全部捨てる。枠の出どころ（手元・PC）が替わったとき。音量の目盛りも既定へ戻す。
    func reset() {
        head = 0
        count = 0
        lastIndex = nil
        lastTime = nil
        levelReference = ETLevelReference()
        for i in fine.indices { fine[i] = 0 }
        for i in levels.indices { levels[i] = -240 }
        for i in loudness.indices { loudness[i] = 0 }
        for i in times.indices { times[i] = .nan }
        for i in frames.indices { frames[i] = nil }
        for i in pixels.indices { pixels[i] = 0 }
        for i in cents.indices { cents[i] = 0 }
        activeGeneration = nil
        clearTimbre()
        image = nil
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
        if display.usesBars {
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
                let color = noteColor(note: note).map {
                    displayColor(column: column, midi: Self.firstMidi + note, base: $0)
                }
                for k in 0..<rowScale {
                    write(row: top + k, column: column, value: value, color: color)
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
            _ = best
            let level = Double(loudness[note * Self.columns + column]) / 255
            // Volume が切なら一番細い帯（上流 _volumeBarShape の thickness）。
            let thickness = display.volume
                ? min(Self.divisions, max(1, Int((1 + Double(Self.divisions - 1) * level).rounded()))) : 1
            // 1/12 は行の真ん中。High（2.14.0）は DSP が出した音程のずれ（セント）の位置。
            // 位置は細分の行の単位の小数で持ち、rowScale 倍した行へ写す。
            let rowTop = Double((Self.notes - 1 - note) * Self.divisions)
            let pitch = display.resolution == .high
                ? Double(Self.firstMidi + note) + Double(cents[note * Self.columns + column]) / 100
                : Double(Self.firstMidi + note)
            let centerRows = rowTop + Double(Self.divisions) / 2
                - (pitch - Double(Self.firstMidi + note)) * Double(Self.divisions)
            let scaledThickness = thickness * rowScale
            let start = Int((centerRows * Double(rowScale) - Double(scaledThickness) / 2).rounded())
            let base = display.color == .rainbow && display.resolution == .high
                ? ETNoteKeyboard.interpolatedColor(midi: pitch)
                : ETNoteKeyboard.noteColors[((Self.firstMidi + note) % 12 + 12) % 12]
            let color = displayColor(column: column, midi: Self.firstMidi + note, base: base)
            // 細分の行も rowScale 倍に写す（paintConfidence と同じ理由）。
            for at in start..<(start + scaledThickness) {
                guard at >= 0, at < rows else { continue }
                write(row: at, column: column, value: value, color: color)
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

    /// 上端は確からしさ 0.5 以上の中の最大。追い方は ETLevelReference。
    /// note_spectrogram.js v2.11.0:541-548。
    private func updateLevelReference(_ snapshot: ETNoteSnapshot, elapsed: Double) {
        var peak = ETLevelReference.floor
        for pitch in 0..<Self.pitches where snapshot.confidence[pitch] >= 0.5 {
            let db = Double(snapshot.level[pitch])
            if db > peak { peak = db }
        }
        levelReference.update(peak: peak, elapsed: elapsed)
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
                    .etFont(size: 15, weight: .bold)
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
