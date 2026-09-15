//  SettingsView.swift
//  右上から出す設定。EffeTune も設定は右上に置いてある。
//
//  項目は EffeTune の Audio Configuration に合わせてある。
//  違うのは、こちらは拡張から来る音が 48kHz 固定なので、
//  Sample Rate は「DSP を何 Hz で回すか」だけを指す点。

import SwiftUI
import AVFoundation

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    /// **io は観測しない（@ObservedObject にしない）。**
    /// tick() が 3.3Hz で publish するので、観測すると List ごと作り直され、
    /// 上のピッカー（iOS では中身が Menu）が提示を終えられなくなる。
    /// 本画面の ⋯ が "Loading…" で固まっていたのと同じ形。
    /// io を読む節は、下の小さなビューに閉じ込めてある。
    let io: AudioIO
    @StateObject private var prefs = Preferences.shared
    @StateObject private var dsp = EffeTuneDSP.shared

    var body: some View {
        NavigationStack {
            List {
                audio
                SignalSection(io: io)
                LoadSection(io: io, dsp: dsp)
                about
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private var audio: some View {
        Section {
            Picker("Sample Rate", selection: $prefs.processingRate) {
                ForEach(ETProcessingRate.allCases) { r in
                    Text(r.label).tag(r)
                }
            }
            Picker("Latency", selection: $prefs.latency) {
                ForEach(ETLatency.allCases) { l in
                    Text(l.label).tag(l)
                }
            }
            Picker("Power saving", selection: $prefs.powerMode) {
                ForEach(ETPowerMode.allCases) { m in
                    Text(m.label).tag(m)
                }
            }
            if prefs.powerMode != .continuous {
                LabeledContent("Silence below") {
                    Text("\(Int(prefs.silenceThresholdDb)) dB").foregroundStyle(.secondary)
                }
            }
            Toggle("Keep screen awake", isOn: $prefs.keepScreenAwake)
        } header: {
            Text("Audio")
        } footer: {
            Text("\(prefs.processingRate.note) \(prefs.latency.note) "
                 + "Changing these restarts the audio, so it stops for a moment.")
        }
    }

    private var about: some View {
        Section {
            Link(destination: URL(string: "https://github.com/Frieve-A/effetune")!) {
                LabeledContent("EffeTune") { Text("MIT").foregroundStyle(.secondary) }
            }
            Link(destination: URL(string: "https://github.com/marton78/pffft")!) {
                LabeledContent("PFFFT") { Text("BSD").foregroundStyle(.secondary) }
            }
            LabeledContent("Version", value: version)
            LabeledContent("DSP ABI", value: "\(et_abi_version())")
            LabeledContent("Effects", value: "\(dsp.available.count)")
        } header: {
            Text("About")
        } footer: {
            Text("The effects are EffeTune's own DSP by Yoshiyuki Kobayashi, running unmodified.")
        }
    }

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
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
            LabeledContent("Effects running", value: "\(io.applied) of \(dsp.chain.count)")
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
