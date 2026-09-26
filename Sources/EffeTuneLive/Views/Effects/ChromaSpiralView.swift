//  ChromaSpiralView.swift
//  Chroma Spiral。スペクトルを音名（角度）とオクターブ（半径）の渦巻きに並べる。
//  上流は plugins/analyzer/chroma_spiral.js（v2.11.0 で増えたもの）。
//
//  DSP のパラメータは 0 個（dsp/plugins/analyzer/chroma_spiral/params.json の fields が空）。
//  カーネルは Spectrum Analyzer の HQ と同じ SpectrumHqSink を回すだけ
//  （chroma_spiral/kernel.cpp:26-58）なので、テレメトリは型 4・版 2 で来る。
//  **枠は ETSpectrumReading がそのまま解く。**こちらで足す門は 2 つだけ:
//    - 版 2（HQ）以外は捨てる。
//    - points が automaticPoints(rate) と違う枠は捨てる（chroma_spiral.js:199）。
//  頭の残り（hop・generation・frameIndex・時刻・有効な升の数）は
//  ETSpectrumReading が門で確かめたあとの位置をここで読む
//  （並びは HQSpectrumHeader.swift と multires-spectrum.js:59-88）。
//
//  表示の 6 つ（dm / lo / hi / ft / lr / df）は DSP へ送らない。上流は getParameters で
//  プリセットに書く（chroma_spiral.js:92-96）ので、鎖に持たせる（.etSaved）。
//
//  **渦巻きの描き方はこの画面から切り離してある。**
//  ETChromaSpiralSettings・ETChromaSpiralMeter・ETChromaSpiralGeometry・ETChromaSpiral.draw は
//  カードを知らない。Visualizer の chroma 項目が透明な全画面の Canvas に同じものを描く。

import SwiftUI
import Foundation

// MARK: - 表示だけの切り替え

/// 塗り分け。chroma_spiral.js:229-232 の createRadioGroup('Color')。
/// **値は上流の数のまま**（dm は 0 / 1 / 2 で書かれる。同 :103）。
enum ETChromaColor: Int, CaseIterable, Identifiable {
    case normal = 0
    case normal2 = 1
    case noteColors = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .normal:     return "Normal"
        case .normal2:    return "Normal 2"
        case .noteColors: return "Note Colors"
        }
    }
}

/// 表示の 6 つ。**生の値を持ち、使うときに挟む。**
/// web 版から来たプリセットには範囲外や大小の逆転が入りうるので、
/// 挟み方は上流の setParameters（chroma_spiral.js:98-122）に合わせる。
/// 既定は同 :9-14。
struct ETChromaSpiralSettings: Equatable {
    /// dm。
    var mode: Double = 0
    /// lo。1〜8。
    var lowest: Double = 1
    /// hi。1〜9。
    var highest: Double = 7
    /// ft（dB/oct）。-6〜6。
    var tilt: Double = 3
    /// lr（dB）。6〜96。
    var range: Double = 24
    /// df（dB）。-120〜-24。
    var floor: Double = -60

    /// 0 / 1 / 2 のどれでもなければ Normal（上流は元の値を残すが、既定は 0）。
    var color: ETChromaColor {
        mode == 1 ? .normal2 : (mode == 2 ? .noteColors : .normal)
    }

    /// **大小は逆転させない。**上流は lo を先に入れて hi を押し上げ、
    /// そのあと hi を入れて lo を押し下げる（同 :104-111）。両方が一度に来たときは
    /// hi が勝つので、lo を hi へ寄せる。
    var octaves: (lo: Int, hi: Int) {
        let lo = Int(Self.clamp(lowest, 1...8, 1).rounded())
        let hi = Int(Self.clamp(highest, 1...9, 7).rounded())
        return (min(lo, hi), hi)
    }

    var levelRange: Double { Self.clamp(range, 6...96, 24) }
    var displayFloor: Double { Self.clamp(floor, -120...(-24), -60) }
    var frequencyTilt: Double { Self.clamp(tilt, -6...6, 3) }

    /// 升の作り直しに効くもの。変わったら目盛りも追い直す（同 :115-118）。
    var cellKey: [Double] {
        let o = octaves
        return [Double(o.lo), Double(o.hi), frequencyTilt]
    }

    /// parseFiniteNumber。数でなければ fallback、範囲の外は端へ。
    private static func clamp(_ v: Double, _ r: ClosedRange<Double>, _ fallback: Double) -> Double {
        guard v.isFinite else { return fallback }
        return min(max(v, r.lowerBound), r.upperBound)
    }
}

// MARK: - 画面

struct ChromaSpiralView: View {

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    @Environment(\.etGraphOnly) private var graphOnly
    @State private var settings = ETChromaSpiralSettings()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ChromaSpiralFigure(tapId: node.tapId, settings: settings)
            // 上流 :229-242 の並びは Color → Lowest Octave → Highest Octave →
            // Frequency Tilt → Level Range → Display Floor。
            if !graphOnly { controls }
            ForEach(node.spec.params) { param in
                ParameterRow(param: param, nodeIndex: index, values: node.values, dsp: dsp)
            }
        }
        // **鎖に残す。**畳むと View ごと消えるので @State だけでは既定へ戻る。
        // 上流はこの 6 つをプリセットに書く（chroma_spiral.js:92-96）。
        .etSaved($settings.mode, key: "dm", index: index, dsp: dsp)
        .etSaved($settings.lowest, key: "lo", index: index, dsp: dsp)
        .etSaved($settings.highest, key: "hi", index: index, dsp: dsp)
        .etSaved($settings.tilt, key: "ft", index: index, dsp: dsp)
        .etSaved($settings.range, key: "lr", index: index, dsp: dsp)
        .etSaved($settings.floor, key: "df", index: index, dsp: dsp)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            colorPicker
            ETChromaSliderRow(title: "Lowest Octave", label: "Lowest Octave",
                              value: Binding(
                                get: { Double(settings.octaves.lo) },
                                set: { v in
                                    // 上流 :104-107。下を上げたら上も押し上げる。
                                    settings.lowest = v
                                    if v > Double(settings.octaves.hi) { settings.highest = v }
                                }),
                              range: 1...8, step: 1)
            ETChromaSliderRow(title: "Highest Octave", label: "Highest Octave",
                              value: Binding(
                                get: { Double(settings.octaves.hi) },
                                set: { v in
                                    // 同 :108-111。上を下げたら下も押し下げる。
                                    settings.highest = v
                                    if v < Double(settings.octaves.lo) { settings.lowest = v }
                                }),
                              range: 1...9, step: 1)
            ETChromaSliderRow(title: "Frequency Tilt (dB/oct)", label: "Frequency Tilt",
                              value: Binding(get: { settings.frequencyTilt },
                                             set: { settings.tilt = $0 }),
                              range: -6...6, step: 0.5)
            ETChromaSliderRow(title: "Level Range (dB)", label: "Level Range",
                              value: Binding(get: { settings.levelRange },
                                             set: { settings.range = $0 }),
                              range: 6...96, step: 1)
            ETChromaSliderRow(title: "Display Floor (dB)", label: "Display Floor",
                              value: Binding(get: { settings.displayFloor },
                                             set: { settings.floor = $0 }),
                              range: -120...(-24), step: 1)
        }
    }

    /// 上流 :229-232。形は ParameterRow の選択肢の行と同じ（標準の Picker）。
    private var colorPicker: some View {
        HStack {
            Text("Color").font(.system(size: 14))
            Spacer(minLength: 8)
            Picker("Color", selection: Binding(
                get: { settings.color },
                set: { settings.mode = Double($0.rawValue) })
            ) {
                ForEach(ETChromaColor.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - つまみの 1 行

/// createParameterControl（chroma_spiral.js:233-242）に当たる。
/// 単位は名前の側に付ける（ParameterRow と同じ。plugin-base.js:1305）。
private struct ETChromaSliderRow: View {

    let title: String
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                ETValueField(text: text, label: label,
                             editText: { ETNumberText.draft(value) }) { typed in
                    value = snapped(typed)
                }
            }
            Slider(value: $value, in: range, step: step)
                .accessibilityLabel(label)
                .accessibilityValue(text)
        }
        .padding(.vertical, 2)
    }

    private var text: String {
        step < 1 ? String(format: "%.1f", value) : String(Int(value.rounded()))
    }

    /// 打たれた数を範囲と刻みに寄せる。
    private func snapped(_ v: Double) -> Double {
        let clamped = min(max(v, range.lowerBound), range.upperBound)
        return (clamped / step).rounded() * step
    }
}

// MARK: - 図

/// 図の一番内側。**Telemetry を見るのはここだけ**にしてある。
/// カード全体で観測すると 30Hz で作り直されて、下のつまみが固まる。
private struct ChromaSpiralFigure: View {

    let tapId: UInt32
    let settings: ETChromaSpiralSettings

    @ObservedObject private var telemetry = Telemetry.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var meter = ETChromaSpiralMeter()
    @State private var side: CGFloat = ETGraphMetrics.height
    /// 指の下の音（MIDI、端数あり）。鳴らしている間だけ入る。
    @State private var probe: Double?
    @GestureState private var previewActive = false

    /// 上流の図の幅の上限（chroma_spiral.js:244 の maxWidth 640）。縦横は 1:1。
    private static let maxSide: CGFloat = 640

    var body: some View {
        let frame = telemetry.frame(tap: tapId, type: .spectrum)
        let octaves = settings.octaves
        let style = ETChromaSpiralStyle(color: settings.color)
        return GraphCanvas(
            x: .blank(), y: .blank(),
            height: side,
            insets: .none,
            readout: readout,
            caption: meter.caption ?? "Waiting for audio",
            clipsContent: true,
            draw: { context, plot in
                let geometry = ETChromaSpiralGeometry(rect: plot.rect, lo: octaves.lo, hi: octaves.hi)
                ETChromaSpiral.draw(&context, geometry: geometry, bounds: plot.rect,
                                    meter: meter, settings: settings, style: style)
                // 鳴らしている所。渦巻きの上の点に輪を置く。
                if let probe, geometry.outer > 0 {
                    let p = geometry.point(midi: probe)
                    context.stroke(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5,
                                                          width: 10, height: 10)),
                                   with: ETGraphShading.axis, lineWidth: 1.5)
                }
            },
            overlay: { plot in
                // 触って鳴らすだけなので、一覧の縦スクロールと同時に効かせる。
                // GraphCanvas の試聴は直交軸しか扱えないので自前で持つ（PitchMeterView と同じ形）。
                Color.clear
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .updating($previewActive) { _, active, _ in active = true }
                            .onChanged { touch in
                                let geometry = ETChromaSpiralGeometry(rect: plot.rect,
                                                                      lo: octaves.lo, hi: octaves.hi)
                                if let midi = geometry.midi(at: touch.location) {
                                    probe = midi
                                    ETPreviewTone_SetFrequency(ETChromaSpiral.frequency(midi: midi))
                                } else {
                                    probe = nil
                                    ETPreviewTone_SetFrequency(0)
                                }
                            }
                            .onEnded { _ in
                                probe = nil
                                ETPreviewTone_SetFrequency(0)
                            })
            })
            .frame(maxWidth: Self.maxSide)
            // 上流は aspectRatio '1 / 1'（同 :244）。幅を測って高さに使う。
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                if width > 0 { side = width }
            }
            .onAppear { push(frame) }
            .onChange(of: frame?.sequence) { _, _ in
                push(telemetry.frame(tap: tapId, type: .spectrum))
            }
            .onChange(of: settings.cellKey) { _, _ in meter.refresh(settings: settings) }
            // **止める口は 3 つとも自分で持つ。**指を離す（上の onEnded と下の previewActive）、
            // 画面から消える、裏へ回る。
            .onChange(of: previewActive) { _, active in
                if !active {
                    probe = nil
                    ETPreviewTone_SetFrequency(0)
                }
            }
            .onDisappear { ETPreviewTone_SetFrequency(0) }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { ETPreviewTone_SetFrequency(0) }
            }
    }

    private var readout: [ETReadoutItem] {
        guard let probe else { return [] }
        return [ETReadoutItem("NOTE", ETNoteBand.name(Int(probe.rounded()))),
                ETReadoutItem("FREQ", ETFormat.hz(ETChromaSpiral.frequency(midi: probe)))]
    }

    /// 受けた枠だけ @State へ書き戻す。同じ枠で描き直しを起こさない。
    private func push(_ frame: ETFrame?) {
        guard let decoded = ETChromaSpiralFrame(frame: frame) else { return }
        var next = meter
        if next.push(decoded, settings: settings) { meter = next }
    }
}

// MARK: - 1 枠

/// 型 4・版 2 の枠のうち、Chroma Spiral が受けるもの。
/// multires-spectrum.js:59-107 の decode と chroma_spiral.js:199 の門。
struct ETChromaSpiralFrame {

    let spectrum: ETSpectrumReading
    let hopSamples: Int
    let generation: UInt32
    let frameIndex: UInt32
    /// captureEndSample / sampleRate（multires-spectrum.js:69, :92）。
    let time: Double
    let firstValid: Int
    let validCount: Int

    init?(frame: ETFrame?) {
        // 頭の門は ETSpectrumReading（HQSpectrumHeader）が通してある。
        guard let frame, let spectrum = ETSpectrumReading(frame: frame), spectrum.highQuality,
              spectrum.points == ETChromaSpiral.automaticPoints(sampleRate: spectrum.sampleRate)
            else { return nil }
        let p = frame.payloadView
        guard let hop = p.u32(at: 8), let generation = p.u32(at: 12),
              let low = p.u32(at: 16), let high = p.u32(at: 20),
              let index = p.u32(at: 24),
              let first = p.u32(at: 40), let valid = p.u32(at: 44),
              Int(first) + Int(valid) <= spectrum.current.count else { return nil }
        self.spectrum = spectrum
        hopSamples = Int(hop)
        self.generation = generation
        frameIndex = index
        time = Double(UInt64(high) << 32 | UInt64(low)) / spectrum.sampleRate
        firstValid = Int(first)
        validCount = Int(valid)
    }
}

// MARK: - 升と目盛り

/// 渦巻きに載せる 1 升。
struct ETChromaCell: Equatable {
    /// 端数のある MIDI 番号。
    let midi: Double
    /// dB。傾き（ft）を足したあと。
    let level: Double
}

/// 枠を受けて、描く升と目盛りの上端を持つ。chroma_spiral.js:196-220。
/// **カードを知らない。**Visualizer も同じものを持つ。
struct ETChromaSpiralMeter {

    private(set) var cells: [ETChromaCell] = []
    private(set) var level = ETLevelReference()
    private(set) var frame: ETChromaSpiralFrame?

    init() {}

    /// 図の上に出す見出し。枠が無ければ nil。
    var caption: String? { frame?.spectrum.caption }

    /// 枠を 1 つ受ける。受けなかったら false。
    /// 順番の判定は multires-spectrum.js:47-56 の FrameReceiver.accept。
    /// 送り手（producer）は tap で決まっているので、ここでは generation だけで切り替わりを見る。
    mutating func push(_ next: ETChromaSpiralFrame, settings: ETChromaSpiralSettings) -> Bool {
        if let previous = frame,
           next.generation < previous.generation
            || (next.generation == previous.generation && next.frameIndex <= previous.frameIndex) {
            return false
        }
        let streamChanged = frame.map { $0.generation != next.generation } ?? true
        // chroma_spiral.js:202-205。
        let elapsed = streamChanged
            ? Double(next.hopSamples) / next.spectrum.sampleRate
            : max(0, next.time - (frame?.time ?? next.time))
        if streamChanged { level.reset() }
        frame = next
        update(settings: settings, elapsed: elapsed)
        return true
    }

    /// 範囲か傾きが変わった。目盛りを追い直して、いまの枠で升を作り直す（同 :115-118）。
    mutating func refresh(settings: ETChromaSpiralSettings) {
        level.reset()
        guard frame != nil else { return }
        update(settings: settings, elapsed: 0)
    }

    /// 同 :210-220。
    private mutating func update(settings: ETChromaSpiralSettings, elapsed: Double) {
        guard let frame else { return }
        let octaves = settings.octaves
        cells = ETChromaSpiral.cells(frame, lo: octaves.lo, hi: octaves.hi,
                                     tilt: settings.frequencyTilt)
        var peak = ETLevelReference.floor
        for cell in cells where cell.level > peak { peak = cell.level }
        level.update(peak: peak, elapsed: elapsed)
    }

    /// 0〜1 の濃さ。chroma_spiral.js:328, :349。
    func intensity(_ cell: ETChromaCell, settings: ETChromaSpiralSettings) -> Double {
        level.normalized(cell.level, range: settings.levelRange, floor: settings.displayFloor)
    }
}

// MARK: - 形

/// 渦巻きの寸法。chroma_spiral.js:85-90 の getSpiralGeometry。
/// 上流は canvas の画素で dpr を掛けているが、こちらは pt なので dpr = 1 の式になる。
struct ETChromaSpiralGeometry {

    let center: CGPoint
    let outer: CGFloat
    let inner: CGFloat
    /// 1 オクターブぶんの半径の伸び。
    let pitch: CGFloat
    let lo: Int
    let hi: Int
    let midiLow: Double
    let midiEnd: Double

    init(rect: CGRect, lo: Int, hi: Int) {
        center = CGPoint(x: rect.midX, y: rect.midY)
        outer = min(rect.width, rect.height) / 2 - 32
        inner = max(14, outer * 0.1)
        pitch = (outer - inner) / CGFloat(hi - lo + 2)
        self.lo = lo
        self.hi = hi
        midiLow = Double((lo + 1) * 12)
        midiEnd = Double((hi + 2) * 12) - 0.5
    }

    /// 角度。C を真上に置いて時計回り。chroma_spiral.js:80。
    func angle(midi: Double) -> Double {
        (midi - 60) * .pi / 6
    }

    /// 同 :79-83 の spiralPoint を、図の座標で返す。
    func point(midi: Double) -> CGPoint {
        let a = angle(midi: midi)
        let radius = Double(inner) + (midi - midiLow) / 12 * Double(pitch)
        return CGPoint(x: center.x + CGFloat(sin(a) * radius),
                       y: center.y - CGFloat(cos(a) * radius))
    }

    /// 指の位置の音。frequency-axis.js v2.11.0:91-110 の pointToFreq（周波数にする手前まで）。
    /// その角度で一番近い巻きを選ぶので、音と音の間でも音の高さは途切れない。
    func midi(at location: CGPoint) -> Double? {
        guard pitch > 0 else { return nil }
        let dx = Double(location.x - center.x)
        let dy = Double(location.y - center.y)
        let phase = (atan2(dx, -dy) / (2 * .pi) + 1).truncatingRemainder(dividingBy: 1)
        // Math.round は 0.5 を上へ丸める。Swift の rounded() は 0 から遠ざけるので、
        // 負の側で 1 巻きずれる。
        let turn = ((hypot(dx, dy) - Double(inner)) / Double(pitch) - phase + 0.5).rounded(.down)
        return min(max(midiLow + (turn + phase) * 12, midiLow - 0.5), midiEnd)
    }
}

/// 描き方の差し替え口。カードは color だけを変える。
/// 残りは Visualizer 用で、上流の displayOptions（chroma_spiral.js:315-385）に当たる。
struct ETChromaSpiralStyle {
    var color: ETChromaColor = .normal
    /// 放射線と渦巻きの案内線（showAxes）。
    var showsAxes = true
    /// 音名とオクターブ番号（showAxisNumbers）。
    var showsLabels = true
    /// 1 色で塗るときの色（graph-trace / spiralFillStyle）。
    var trace: GraphicsContext.Shading = ETGraphShading.curve
    /// 音ごとの色（noteColor）。Normal と Note Colors の点で、濃さは intensity を掛ける。
    var noteColor: ((Double) -> Color)? = nil
    /// 音と濃さから色を決める（signalColor）。**これがあれば濃さは掛けない**（同 :333）。
    /// nil を返した所は描かない（alpha 0 と同じ扱い。同 :361）。
    var signalColor: ((Double, Double) -> Color?)? = nil
    /// 字の大きさ。見た目だけで、出すかどうかの判定には使わない（ETChromaSpiral.fitSize）。
    var labelSize: CGFloat = 10
}

// MARK: - 描く

enum ETChromaSpiral {

    /// 字を出すかどうかを決める大きさ。chroma_spiral.js:296 の fontSize（12 CSS px）。
    /// **字の見た目（labelSize）とは別に持つ。**小さい字にしても、オクターブ番号が出る
    /// 巻きの間隔（:399）と音名のはみ出し（:396-397）は上流と同じ所で切り替える。
    static let fitSize: CGFloat = 12

    /// chroma_spiral.js:40-44。DSP 側（chroma_spiral/kernel.cpp:12-18）と同じ式。
    static func automaticPoints(sampleRate: Double) -> Int {
        var points = 8
        while points < 14 && sampleRate / (4 * Double(1 << points)) > 1.5 { points += 1 }
        return points
    }

    /// 同 :60-62。100Hz から上を 1 オクターブごとに tilt dB 持ち上げる。
    static func octaveCorrection(frequency: Double, tilt: Double) -> Double {
        tilt * log2((frequency > 100 ? frequency : 100) / 100)
    }

    static func frequency(midi: Double) -> Double {
        440 * pow(2, (midi - 69) / 12)
    }

    /// 同 :64-77 の spectrumCells。
    static func cells(_ frame: ETChromaSpiralFrame, lo: Int, hi: Int,
                      tilt: Double) -> [ETChromaCell] {
        let midiLow = Double((lo + 1) * 12) - 0.5
        let midiHigh = Double((hi + 2) * 12) - 0.5
        let current = frame.spectrum.current
        let count = current.count
        guard count > 1 else { return [] }
        // 升は 20Hz〜40kHz の対数に等間隔（multires-spectrum.js:91 の min/maxFrequency）。
        let logRange = log(40000.0 / 20.0)
        var out: [ETChromaCell] = []
        out.reserveCapacity(frame.validCount)
        let end = min(frame.firstValid + frame.validCount, count)
        for i in frame.firstValid..<end {
            let frequency = 20 * exp(Double(i) * logRange / Double(count - 1))
            let midi = 69 + 12 * log2(frequency / 440)
            if midi < midiLow || midi >= midiHigh { continue }
            // 数でない値は床に落とす。升を抜くと Normal 2 の輪郭が欠ける。
            let raw = Double(current[i])
            let db = raw.isFinite ? raw : ETLevelReference.floor
            out.append(ETChromaCell(midi: midi,
                                    level: db + octaveCorrection(frequency: frequency, tilt: tilt)))
        }
        return out
    }

    /// 全部描く。同 :290-407 の drawGraph（地の塗りを除く。地は描く側が持つ）。
    static func draw(_ context: inout GraphicsContext, geometry: ETChromaSpiralGeometry,
                     bounds: CGRect, meter: ETChromaSpiralMeter,
                     settings: ETChromaSpiralSettings, style: ETChromaSpiralStyle) {
        guard geometry.outer > 0 else { return }
        if style.showsAxes { drawGuides(&context, geometry: geometry) }
        drawSignal(&context, geometry: geometry, meter: meter, settings: settings, style: style)
        if style.showsLabels {
            drawLabels(&context, geometry: geometry, bounds: bounds, style: style)
        }
    }

    /// 12 本の放射線と、1/8 半音刻みの渦巻き。同 :307-322。
    static func drawGuides(_ context: inout GraphicsContext, geometry g: ETChromaSpiralGeometry) {
        var radial = Path()
        for pc in 0..<12 {
            let a = Double(pc) * .pi / 6
            radial.move(to: CGPoint(x: g.center.x + CGFloat(sin(a)) * g.inner,
                                    y: g.center.y - CGFloat(cos(a)) * g.inner))
            radial.addLine(to: CGPoint(x: g.center.x + CGFloat(sin(a)) * g.outer,
                                       y: g.center.y - CGFloat(cos(a)) * g.outer))
        }
        context.stroke(radial, with: ETGraphShading.grid, lineWidth: 1)

        var spiral = Path()
        var midi = g.midiLow
        spiral.move(to: g.point(midi: midi))
        midi += 0.125
        while midi <= g.midiEnd {
            spiral.addLine(to: g.point(midi: midi))
            midi += 0.125
        }
        context.stroke(spiral, with: ETGraphShading.grid, lineWidth: 1)
    }

    /// 信号。同 :324-384。
    /// Normal と Note Colors は升ごとの点（半径は √濃さ × 巻きの半分、濃さを alpha に）。
    /// Normal 2 は渦巻きから外へ伸ばした線と渦巻きの間を塗る。
    static func drawSignal(_ context: inout GraphicsContext, geometry g: ETChromaSpiralGeometry,
                           meter: ETChromaSpiralMeter, settings: ETChromaSpiralSettings,
                           style: ETChromaSpiralStyle) {
        let cells = meter.cells
        guard !cells.isEmpty else { return }
        if style.color != .normal2 {
            for cell in cells {
                let intensity = meter.intensity(cell, settings: settings)
                guard intensity > 0 else { continue }
                let p = g.point(midi: cell.midi)
                let radius = CGFloat(intensity.squareRoot()) * g.pitch / 2
                let dot = Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius,
                                                 width: radius * 2, height: radius * 2))
                if let signalColor = style.signalColor {
                    guard let color = signalColor(cell.midi, intensity) else { continue }
                    context.fill(dot, with: .color(color))
                    continue
                }
                var layer = context
                layer.opacity = intensity
                if let noteColor = style.noteColor {
                    layer.fill(dot, with: .color(noteColor(cell.midi)))
                } else if style.color == .noteColors {
                    // 同 :339。音名は丸めた MIDI から取る。
                    let c = ETNoteKeyboard.noteColors[(Int(cell.midi.rounded()) % 12 + 12) % 12]
                    layer.fill(dot, with: .color(Color(red: c.r / 255, green: c.g / 255,
                                                       blue: c.b / 255)))
                } else {
                    layer.fill(dot, with: style.trace)
                }
            }
            return
        }

        // Normal 2。同 :347-380。
        struct Spoke { let base: CGPoint; let tip: CGPoint; let midi: Double; let intensity: Double }
        let spokes = cells.map { cell -> Spoke in
            let base = g.point(midi: cell.midi)
            let a = g.angle(midi: cell.midi)
            let intensity = meter.intensity(cell, settings: settings)
            let length = CGFloat(intensity) * g.pitch
            return Spoke(base: base,
                         tip: CGPoint(x: base.x + CGFloat(sin(a)) * length,
                                      y: base.y - CGFloat(cos(a)) * length),
                         midi: cell.midi, intensity: intensity)
        }
        if let signalColor = style.signalColor {
            for i in spokes.indices.dropFirst() {
                let before = spokes[i - 1], after = spokes[i]
                guard let color = signalColor((before.midi + after.midi) / 2,
                                              (before.intensity + after.intensity) / 2) else { continue }
                var quad = Path()
                quad.move(to: before.base)
                quad.addLine(to: before.tip)
                quad.addLine(to: after.tip)
                quad.addLine(to: after.base)
                quad.closeSubpath()
                context.fill(quad, with: .color(color))
            }
            return
        }
        // 外の縁をなぞってから、渦巻きに沿って戻る。巻きごとに塗りが追従する（同 :375-376）。
        var area = Path()
        area.move(to: spokes[0].tip)
        for spoke in spokes.dropFirst() { area.addLine(to: spoke.tip) }
        for spoke in spokes.reversed() { area.addLine(to: spoke.base) }
        area.closeSubpath()
        context.fill(area, with: style.trace)
    }

    /// 音名とオクターブ番号。同 :385-405。
    /// 音名は外周の 16pt 外、図からはみ出すものは出さない。
    /// オクターブ番号は C の放射線の左に、巻きの間隔が字より広いときだけ。
    static func drawLabels(_ context: inout GraphicsContext, geometry g: ETChromaSpiralGeometry,
                           bounds: CGRect, style: ETChromaSpiralStyle) {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let font = Font.system(size: style.labelSize, design: .monospaced)
        let halfWidth = bounds.width / 2
        let halfHeight = bounds.height / 2
        for pc in 0..<12 {
            let a = Double(pc) * .pi / 6
            let x = CGFloat(sin(a)) * (g.outer + 16)
            let y = -CGFloat(cos(a)) * (g.outer + 16)
            let text = context.resolve(Text(names[pc]).font(font).foregroundStyle(.secondary))
            let width = text.measure(in: CGSize(width: CGFloat.infinity,
                                                height: CGFloat.infinity)).width
            guard abs(x) + width / 2 <= halfWidth,
                  abs(y) + fitSize / 2 <= halfHeight else { continue }
            context.draw(text, at: CGPoint(x: g.center.x + x, y: g.center.y + y), anchor: .center)
        }
        guard g.pitch >= fitSize + 2, g.lo <= g.hi else { return }
        for octave in g.lo...g.hi {
            let y = g.center.y - g.inner - CGFloat(octave - g.lo) * g.pitch
            context.draw(Text("\(octave)").font(font).foregroundStyle(.secondary),
                         at: CGPoint(x: g.center.x - 6, y: y), anchor: .trailing)
        }
    }
}
