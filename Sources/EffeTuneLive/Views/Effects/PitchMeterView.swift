import SwiftUI

/// 線の塗り方。上流の `cl`（pitch_meter.js v2.11.0:14-18、:119-122）。
/// DSP へは送らない。
enum ETPitchColor: String, CaseIterable, Identifiable {
    // **綴りは上流のまま。**Note Colors の値は "Rainbow"（同 :17）。
    case normal = "Normal"
    case heatmap = "Heatmap"
    case rainbow = "Rainbow"

    var id: String { rawValue }

    /// 同 :15-17 の label。
    var label: String {
        switch self {
        case .normal:  return "Normal"
        case .heatmap: return "Heatmap"
        case .rainbow: return "Note Colors"
        }
    }
}

struct PitchMeterView: View {
    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP
    @Environment(\.etGraphOnly) private var graphOnly
    /// PoC: PC の鎖を編集しているあいだ（GraphCanvas と同じ。Views/RemoteScannerView.swift）。
    @Environment(\.etMeasurementDimmed) private var measurementDimmed
    /// 既定は Normal（pitch_meter.js v2.11.0:48）。
    @State private var color: ETPitchColor = .normal
    /// 既定は Horizontal（pitch_meter.js v2.11.0:47）。綴りは Note Spectrogram と同じ
    /// 'Vertical' / 'Horizontal'（同 :13）なので ETNoteLayout をそのまま使う。
    @State private var layout: ETNoteLayout = .horizontal

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PitchMeterGraph(tap: node.tapId, minimum: value("mn"), maximum: value("mx"),
                            reference: value("rf"), color: color, layout: layout)
                .etDimmedWhenMeasuring(measurementDimmed)
            if !graphOnly {
                // 上流は Color → Layout を数値の行より先に置く（pitch_meter.js v2.11.0:410-417）。
                colorPicker
                layoutPicker
                ForEach(node.spec.params) { param in
                    ParameterRow(param: param, nodeIndex: index, values: node.values, dsp: dsp)
                }
            }
        }
        // 畳むとこの View ごと消えるので鎖に持たせる。上流も `cl` をプリセットに書く（同 :104-105）。
        .etSaved($color, key: "cl", index: index, dsp: dsp)
        .etSaved($layout, key: "ly", index: index, dsp: dsp)
    }

    /// pitch_meter.js v2.11.0:410-413 の createRadioGroup に当たる。
    private var colorPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Color")
                .font(.system(size: 14))
            Picker("Color", selection: $color) {
                ForEach(ETPitchColor.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.vertical, 2)
    }

    /// pitch_meter.js v2.11.0:414-416 の createRadioGroup('Layout', …)。
    private var layoutPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Layout")
                .font(.system(size: 14))
            Picker("Layout", selection: $layout) {
                ForEach(ETNoteLayout.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.vertical, 2)
    }

    private func value(_ key: String) -> Double {
        guard let p = node.spec.params.first(where: { $0.key == key }) else { return 60 }
        return Double(node.values[p.offset])
    }
}

/// 履歴の 1 点。**音量の濃さは届いた時点の目盛りで決める。**
/// 後から目盛りが動いても塗り直さない（上流の volumeHistory と同じ）。
private struct ETPitchPoint {
    let reading: ETPitchReading
    /// 0〜1。無声なら 0。
    let volume: Double
}

private struct PitchMeterGraph: View {
    let tap: UInt32
    let minimum: Double
    let maximum: Double
    let reference: Double
    let color: ETPitchColor
    let layout: ETNoteLayout
    @ETTelemetryFeed private var telemetry
    @State private var history: [ETPitchPoint] = []
    /// Heatmap の目盛り。Note Spectrogram と同じ追従（pitch_meter.js v2.11.0:287-293）。
    @State private var level = ETLevelReference()
    @GestureState private var previewActive = false
    @Environment(\.scenePhase) private var scenePhase

    private var reading: ETPitchReading? {
        ETPitchReading(frame: telemetry.frame(tap: tap, type: .pitchMeter))
    }

    var body: some View {
        let current = reading
        VStack(alignment: .leading, spacing: 4) {
            Text(current?.label ?? "Waiting for audio").font(.system(.caption, design: .monospaced))
            Canvas { screen, size in
                // 描くのは x が時間（右が新しい）、y が音の高さ（上が高い）の面。
                // Horizontal は上流と同じく面ごと 90 度回す（pitch_meter.js v2.11.0:526-534）。
                // 画面では x が音の高さ（右が高い）、y が時間（下が新しい）になる。
                let frame = rollFrame(size)
                var context = screen
                frame.apply(&context)
                let width = frame.width, height = frame.height
                let lo = min(minimum, maximum), hi = max(minimum + 1, maximum)
                for note in Int(lo)...Int(hi) {
                    let y = height * (1 - (Double(note) - lo) / (hi - lo))
                    if [1, 3, 6, 8, 10].contains(note % 12) {
                        context.fill(Path(CGRect(x: 0, y: y - height / (hi - lo) / 2,
                                                 width: width, height: height / (hi - lo))),
                                     with: .color(.secondary.opacity(0.12)))
                    }
                    if note % 12 == 0 {
                        // 字は回さない。上流も Horizontal では字だけ戻して立てる（同 :587-594）。
                        screen.draw(Text("C\(note / 12 - 1)").font(.system(size: 9)),
                                    at: frame.point(12, y))
                    }
                }
                guard let last = history.last?.reading else { return }
                func point(_ sample: ETPitchReading) -> CGPoint {
                    CGPoint(x: width * (1 - (last.time - sample.time) / 2),
                            y: height * (1 - (sample.midi - lo) / (hi - lo)))
                }
                // **Normal は前のまま**、濃さを付けない 1 色の 1 本の線。
                if color == .normal {
                    var path = Path()
                    var connected = false
                    var previousTime: Double?
                    for sample in history.map(\.reading) {
                        guard sample.voiced else { connected = false; continue }
                        if connected, let previousTime, sample.time - previousTime < 0.15 {
                            path.addLine(to: point(sample))
                        } else { path.move(to: point(sample)) }
                        previousTime = sample.time
                        connected = true
                    }
                    context.stroke(path, with: .color(.accentColor), lineWidth: 2)
                    return
                }
                // **Heatmap と Note Colors は区間ごとに引く。**色と濃さが区間ごとに変わるので
                // 1 本の Path にできない。色は両端の平均、不透明度は 0.2 + 0.8 × 確からしさの平均
                // （同 :625-629）。
                for i in history.indices.dropFirst() {
                    let a = history[i - 1], b = history[i]
                    guard a.reading.voiced, b.reading.voiced,
                          b.reading.time - a.reading.time < 0.15 else { continue }
                    var segment = Path()
                    segment.move(to: point(a.reading))
                    segment.addLine(to: point(b.reading))
                    var layer = context
                    layer.opacity = 0.2 + 0.8 * (a.reading.confidence + b.reading.confidence) / 2
                    layer.stroke(segment,
                                 with: .color(lineColor(midi: (a.reading.midi + b.reading.midi) / 2,
                                                        volume: (a.volume + b.volume) / 2)),
                                 lineWidth: 2)
                }
            }
            .frame(height: ETGraphMetrics.height).clipped()
            .overlay {
                GeometryReader { geometry in
                    Color.clear.contentShape(Rectangle())
                        // etOwnsDrag-exempt: 試聴の音を出すだけで何も動かさない。行の掴みと払いは止めず、縦スクロールと同時に効かせる
                        .simultaneousGesture(DragGesture(minimumDistance: 0)
                            .updating($previewActive) { _, active, _ in active = true }
                            .onChanged { touch in
                                // 音の高さは描く面の y。Horizontal では画面の x に乗っている。
                                let frame = rollFrame(geometry.size)
                                let local = frame.local(touch.location)
                                let t = min(1, max(0, 1 - local.y / max(1, frame.height)))
                                let midi = minimum + Double(t) * max(1, maximum - minimum)
                                ETPreviewTone_SetFrequency(reference * pow(2, (midi - 69) / 12))
                            }
                            .onEnded { _ in ETPreviewTone_SetFrequency(0) })
                }
            }
        }
        .onDisappear { ETPreviewTone_SetFrequency(0) }
        .onChange(of: previewActive) { _, active in
            if !active { ETPreviewTone_SetFrequency(0) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { ETPreviewTone_SetFrequency(0) }
        }
        .onChange(of: telemetry.frame(tap: tap, type: .pitchMeter)?.sequence) { _, _ in
            guard let sample = reading else { return }
            // 最初の枠は 1 hop ぶん進める（pitch_meter.js v2.11.0:290-291）。
            var elapsed = sample.hop
            if let last = history.last?.reading {
                // **履歴を捨てるときは目盛りも追い直す。**上流の clearHistory（同 :255-271）。
                // 2 秒以上空いたときも上流は捨てる（同 :283-286）。
                if last.generation != sample.generation || sample.time < last.time
                    || sample.time - last.time >= 2 {
                    history.removeAll()
                    level.reset()
                } else {
                    elapsed = sample.time - last.time
                }
            }
            // 目盛りを上げるのは確からしさ 0.5 以上の有声だけ（同 :288-289）。
            level.update(peak: sample.voiced && sample.confidence >= 0.5
                             ? sample.levelDb : ETLevelReference.floor,
                         elapsed: elapsed)
            let volume = sample.voiced ? level.normalized(sample.levelDb) : 0
            history.append(ETPitchPoint(reading: sample, volume: volume))
            history.removeAll { $0.reading.time < sample.time - 2 }
            if history.count > 600 { history.removeFirst(history.count - 600) }
        }
    }

    private func rollFrame(_ size: CGSize) -> ETNoteRollFrame {
        ETNoteRollFrame(rect: CGRect(origin: .zero, size: size),
                        horizontal: layout == .horizontal)
    }

    /// pitch_meter.js v2.11.0:514-520 の _lineColor。
    /// Heatmap は Spectrogram の不透明な表（getHeatmapLuts().rgbColors）、
    /// Note Colors は **EffectDeck の ETNoteKeyboard.noteColors** を半音の間で混ぜる
    /// （混ぜ方は note_spectrogram.js:58-68 の multiF0NoteColor）。
    private func lineColor(midi: Double, volume: Double) -> Color {
        switch color {
        case .normal:
            return .accentColor
        case .heatmap:
            return ETPitchColoring.heatmap[min(max(Int((volume * 255).rounded()), 0), 255)]
        case .rainbow:
            let lowerMidi = Int(midi.rounded(.down))
            let fraction = midi - Double(lowerMidi)
            let lower = ETNoteKeyboard.noteColors[((lowerMidi % 12) + 12) % 12]
            let upper = ETNoteKeyboard.noteColors[(((lowerMidi + 1) % 12) + 12) % 12]
            return Color(red: (lower.r + (upper.r - lower.r) * fraction) / 255,
                         green: (lower.g + (upper.g - lower.g) * fraction) / 255,
                         blue: (lower.b + (upper.b - lower.b) * fraction) / 255)
        }
    }
}

/// 表は形が変わらないので 1 度だけ Color にする。
private enum ETPitchColoring {
    static let heatmap: [Color] = (0...255).map { ETIntensityLUT.heatmap.color($0) }
}

struct ETPitchReading {
    let time: Double
    /// 1 枠の間隔（秒）。
    let hop: Double
    let generation: UInt32
    let frequency: Double
    let midi: Double
    let cents: Double
    /// 0〜1。無声なら 0。
    let confidence: Double
    /// 倍音の和の dB。下限 -240（kernel.cpp v2.11.0 の pitchLevel）。
    let levelDb: Double
    let voiced: Bool

    /// 並びは pitch_meter.js v2.11.0:214-225。**門は同 :228-243 と同じ。**
    /// 上流が捨てる枠は読みの行にも線にも使わない。
    init?(frame: ETFrame?) {
        guard let frame, frame.version == 1, frame.payload.count == 44 else { return nil }
        let p = frame.payloadView
        guard let sampleRate = p.f32(at: 0), let time = p.f32(at: 4), let hop = p.f32(at: 8),
              let generation = p.u32(at: 16),
              let frequency = p.f32(at: 20), let midi = p.f32(at: 24),
              let cents = p.f32(at: 28), let confidence = p.f32(at: 32),
              let levelDb = p.f32(at: 36), let flags = p.u16(at: 40), let reserved = p.u16(at: 42),
              sampleRate.isFinite, sampleRate > 0,
              time.isFinite, time >= 0, hop.isFinite, hop > 0,
              generation != 0, flags <= 1, reserved == 0,
              frequency.isFinite, midi.isFinite, cents.isFinite,
              confidence.isFinite, confidence >= 0, confidence <= 1,
              levelDb.isFinite else { return nil }
        // 有声は A0〜C8 の ±0.5 半音・±50 cent の内、無声は数が全部 0（同 :236-242）。
        if flags & 1 != 0 {
            guard frequency > 0, midi >= 20.5, midi <= 108.5,
                  cents >= -50, cents <= 50 else { return nil }
        } else {
            guard frequency == 0, midi == 0, cents == 0, confidence == 0 else { return nil }
        }
        self.time = Double(time)
        self.hop = Double(hop)
        self.generation = generation
        self.frequency = Double(frequency)
        self.midi = Double(midi)
        self.cents = Double(cents)
        self.confidence = Double(confidence)
        self.levelDb = Double(levelDb)
        voiced = flags & 1 != 0
    }

    var label: String {
        guard voiced else { return "No pitch detected" }
        let note = Int(midi.rounded())
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        return "\(names[note % 12])\(note / 12 - 1)  " + String(format: "%+.1f cents · %.1f Hz", cents, frequency)
    }
}
