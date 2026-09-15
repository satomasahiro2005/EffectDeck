//  StatusView.swift
//  いまの信号と負荷。読むだけのものを設定から分けてここへ置いてある。
//
//  io を画面全体で観測しない。tick() が 3.3Hz、Telemetry は 30Hz で publish するので、
//  全体で受けると List ごと作り直され、Menu が「読み込み中」のまま固まる。
//  観測は下の小さなビューに閉じ込めてある。

import SwiftUI
import AVFoundation

struct StatusView: View {
    let io: AudioIO
    @ObservedObject var dsp: EffeTuneDSP

    var body: some View {
        List {
            SignalSection(io: io)
            LoadSection(io: io, dsp: dsp)
        }
        .navigationTitle("Status")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// io を読む節。ここだけが io を観測する。
/// 3.3Hz で作り直されるが、中は文字だけなので提示の途中のものが無い。
private struct SignalSection: View {
    @ObservedObject var io: AudioIO

    var body: some View {
        Section {
            LabeledContent("Source") {
                Text(io.hasPeer ? "Connected" : "Not connected")
                    .foregroundStyle(io.hasPeer ? .primary : .secondary)
            }
            LabeledContent("Incoming", value: "48 kHz · 32-bit float · 2 ch")
            LabeledContent("Processing", value: "\(Int(io.processingRate / 1000)) kHz")
            // 端末が実際に回っているレート。リンクは 48kHz 固定なので、
            // ここが 48000 でないときは速さと音程がずれる。
            LabeledContent("Device", value: deviceRate)
            LabeledContent("Going to", value: io.running ? io.route : "—")
            LabeledContent("State", value: io.status)
            if rateMismatch {
                Label("""
                      This device is running at \(Int(io.sampleRate)) Hz, but the audio \
                      arrives at 48 kHz. Pitch and speed will be off. Another app is \
                      holding the hardware rate: stop it, then reconnect.
                      """, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Signal")
        } footer: {
            Text("""
                 Audio arrives from the extension inside EffeTune Live Bridge over a local \
                 connection, always at 48 kHz. Sample Rate above only changes the rate the \
                 effects run at.
                 """)
        }
    }

    /// いま組んであるレート。48kHz から外れていたら下に警告を出す。
    private var deviceRate: String {
        io.sampleRate > 0 ? String(format: "%.0f Hz", io.sampleRate) : "—"
    }

    private var rateMismatch: Bool {
        io.running && io.sampleRate > 0 && abs(io.sampleRate - 48000) >= 1
    }
}

/// 負荷と遅延。こちらも io を読むので分けてある。
private struct LoadSection: View {
    @ObservedObject var io: AudioIO
    @ObservedObject var dsp: EffeTuneDSP

    var body: some View {
        Section {
            LabeledContent("DSP") {
                Text(io.resting ? "resting" : String(format: "%.0f %%", io.load * 100))
                    .foregroundStyle(io.resting ? .secondary : .primary)
            }
            // Section は descriptor に入らないので分母から外す。
            // 分子の io.applied は ETPipeline_ActiveNodes() で、こちらは含まない。
            LabeledContent("Effects running",
                           value: "\(io.applied) of \(dsp.chain.filter { !$0.isSection }.count)")
            LabeledContent("Output", value: io.outputRoute)
            if io.loopback {
                Label("""
                      Output is going back into EffeTune, so the sound never reaches \
                      a speaker and the level climbs on its own. Pick a real output \
                      for this device.
                      """, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            LabeledContent("Block", value: io.blockFrames > 0 ? "\(io.blockFrames) samples" : "—")
            LabeledContent("Queued from Bridge", value: queued)
            LabeledContent("Added by resampling", value: resampling)
            DroppedFramesRow()
        } header: {
            Text("Load and delay")
        } footer: {
            Text("Queued frames sit between the two apps and are the delay this app adds "
                 + "on top of what iOS already costs.")
        }
    }

    private var queued: String {
        guard io.sampleRate > 0 else { return "—" }
        let ms = Double(io.bufferedFrames) / io.sampleRate * 1000
        return String(format: "%u samples (%.1f ms)", io.bufferedFrames, ms)
    }

    private var resampling: String {
        guard io.resamplerLatency > 0, io.sampleRate > 0 else { return "none" }
        let ms = Double(io.resamplerLatency) / io.sampleRate * 1000
        return String(format: "%d samples (%.2f ms)", io.resamplerLatency, ms)
    }
}

/// Telemetry は analyzer を鎖に入れている間 30Hz で publish する。
/// Settings 全体で観測すると List ごと 30Hz で作り直されるので、この 1 行に閉じ込める。
private struct DroppedFramesRow: View {
    @ObservedObject private var telemetry = Telemetry.shared

    var body: some View {
        if telemetry.droppedFrames > 0 {
            LabeledContent("Telemetry dropped", value: "\(telemetry.droppedFrames)")
        }
    }
}
