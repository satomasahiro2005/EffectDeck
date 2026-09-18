import SwiftUI

struct PitchMeterView: View {
    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP
    @Environment(\.etGraphOnly) private var graphOnly

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PitchMeterGraph(tap: node.tapId, minimum: value("mn"), maximum: value("mx"), reference: value("rf"))
            if !graphOnly {
                Text("Monophonic input only").font(.caption).foregroundStyle(.secondary)
                ForEach(node.spec.params) { param in
                    ParameterRow(param: param, nodeIndex: index, values: node.values, dsp: dsp)
                }
            }
        }
    }

    private func value(_ key: String) -> Double {
        guard let p = node.spec.params.first(where: { $0.key == key }) else { return 60 }
        return Double(node.values[p.offset])
    }
}

private struct PitchMeterGraph: View {
    let tap: UInt32
    let minimum: Double
    let maximum: Double
    let reference: Double
    @ObservedObject private var telemetry = Telemetry.shared
    @State private var history: [ETPitchReading] = []
    @GestureState private var previewActive = false
    @Environment(\.scenePhase) private var scenePhase

    private var reading: ETPitchReading? {
        ETPitchReading(frame: telemetry.frame(tap: tap, type: .pitchMeter))
    }

    var body: some View {
        let current = reading
        VStack(alignment: .leading, spacing: 4) {
            Text(current?.label ?? "Waiting for audio").font(.system(.caption, design: .monospaced))
            Canvas { context, size in
                let lo = min(minimum, maximum), hi = max(minimum + 1, maximum)
                for note in Int(lo)...Int(hi) {
                    let y = size.height * (1 - (Double(note) - lo) / (hi - lo))
                    if [1, 3, 6, 8, 10].contains(note % 12) {
                        context.fill(Path(CGRect(x: 0, y: y - size.height / (hi - lo) / 2,
                                                 width: size.width, height: size.height / (hi - lo))),
                                     with: .color(.secondary.opacity(0.12)))
                    }
                    if note % 12 == 0 {
                        context.draw(Text("C\(note / 12 - 1)").font(.system(size: 9)),
                                     at: CGPoint(x: 12, y: y))
                    }
                }
                guard let last = history.last else { return }
                var path = Path()
                var connected = false
                var previousTime: Double?
                for sample in history {
                    guard sample.voiced else { connected = false; continue }
                    let point = CGPoint(x: size.width * (1 - (last.time - sample.time) / 2),
                                        y: size.height * (1 - (sample.midi - lo) / (hi - lo)))
                    if connected, let previousTime, sample.time - previousTime < 0.15 {
                        path.addLine(to: point)
                    } else { path.move(to: point) }
                    previousTime = sample.time
                    connected = true
                }
                context.stroke(path, with: .color(.accentColor), lineWidth: 2)
            }
            .frame(height: ETGraphMetrics.height).clipped()
            .overlay {
                GeometryReader { geometry in
                    Color.clear.contentShape(Rectangle())
                        .simultaneousGesture(DragGesture(minimumDistance: 0)
                            .updating($previewActive) { _, active, _ in active = true }
                            .onChanged { touch in
                                let t = min(1, max(0, 1 - touch.location.y / max(1, geometry.size.height)))
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
            if let last = history.last, last.generation != sample.generation || sample.time < last.time {
                history.removeAll()
            }
            history.append(sample)
            history.removeAll { $0.time < sample.time - 2 }
            if history.count > 600 { history.removeFirst(history.count - 600) }
        }
    }
}

struct ETPitchReading {
    let time: Double
    let generation: UInt32
    let frequency: Double
    let midi: Double
    let cents: Double
    let voiced: Bool

    init?(frame: ETFrame?) {
        guard let frame, frame.version == 1, frame.payload.count == 44 else { return nil }
        let p = frame.payloadView
        guard let time = p.f32(at: 4), let generation = p.u32(at: 16),
              let frequency = p.f32(at: 20), let midi = p.f32(at: 24),
              let cents = p.f32(at: 28), let flags = p.u16(at: 40),
              time.isFinite, frequency.isFinite, midi.isFinite, cents.isFinite,
              time >= 0, generation != 0, flags & ~UInt16(1) == 0 else { return nil }
        self.time = Double(time)
        self.generation = generation
        self.frequency = Double(frequency)
        self.midi = Double(midi)
        self.cents = Double(cents)
        voiced = flags & 1 != 0 && frequency > 0 && midi >= 0 && midi <= 127
    }

    var label: String {
        guard voiced else { return "No pitch detected" }
        let note = Int(midi.rounded())
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        return "\(names[note % 12])\(note / 12 - 1)  " + String(format: "%+.1f cents · %.1f Hz", cents, frequency)
    }
}
