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
    @ObservedObject var io: AudioIO
    @StateObject private var prefs = Preferences.shared
    @StateObject private var dsp = EffeTuneDSP.shared
    @StateObject private var telemetry = Telemetry.shared

    var body: some View {
        NavigationStack {
            List {
                audio
                capture
                loadSection
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

    private var capture: some View {
        Section {
            LabeledContent("Source") {
                Text(io.hasPeer ? "Connected" : "Not connected")
                    .foregroundStyle(io.hasPeer ? .primary : .secondary)
            }
            LabeledContent("Incoming", value: "48 kHz · 32-bit float · 2 ch")
            LabeledContent("Processing", value: "\(Int(io.processingRate / 1000)) kHz")
            LabeledContent("Going to", value: io.running ? io.route : "—")
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

    private var loadSection: some View {
        Section {
            LabeledContent("DSP") {
                Text(io.resting ? "resting" : String(format: "%.0f %%", io.load * 100))
                    .foregroundStyle(io.resting ? .secondary : .primary)
            }
            LabeledContent("Effects running", value: "\(io.applied) of \(dsp.chain.count)")
            LabeledContent("Block", value: io.blockFrames > 0 ? "\(io.blockFrames) samples" : "—")
            LabeledContent("Queued from Bridge", value: queued)
            LabeledContent("Added by resampling", value: resampling)
            if telemetry.droppedFrames > 0 {
                LabeledContent("Telemetry dropped", value: "\(telemetry.droppedFrames)")
            }
        } header: {
            Text("Load and delay")
        } footer: {
            Text("Queued frames sit between the two apps and are the delay this app adds "
                 + "on top of what iOS already costs.")
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

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
