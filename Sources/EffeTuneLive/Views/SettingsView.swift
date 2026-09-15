//  SettingsView.swift
//  右上から出す設定。EffeTune の web 版も設定は右上に置いてある。
//
//  いまは見るだけのものが多い。サンプルレートのように、
//  こちらから頼んでも OS が別の値を返すものがあるので、
//  「頼んだ値」ではなく「実際に動いている値」を出している。

import SwiftUI
import AVFoundation

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var io: AudioIO
    @StateObject private var dsp = EffeTuneDSP.shared
    @StateObject private var telemetry = Telemetry.shared

    var body: some View {
        NavigationStack {
            List {
                Section("Audio") {
                    LabeledContent("Sample rate", value: io.running ? "\(Int(io.sampleRate)) Hz" : "—")
                    LabeledContent("Output", value: io.route)
                    LabeledContent("Block size",
                                   value: io.blockFrames > 0 ? "\(io.blockFrames) samples" : "—")
                }

                Section {
                    LabeledContent("Source") {
                        Text(io.hasPeer ? "Connected" : "Not connected")
                            .foregroundStyle(io.hasPeer ? .primary : .secondary)
                    }
                    LabeledContent("Received", value: "\(io.received) frames")
                    LabeledContent("Queued", value: latency)
                } header: {
                    Text("Capture")
                } footer: {
                    Text("""
                         Audio arrives from the extension in EffeTune Live Bridge over a local \
                         connection. Queued frames sit between the two apps and add to the delay \
                         you hear.
                         """)
                }

                Section("Load") {
                    LabeledContent("DSP", value: String(format: "%.0f %%", io.load * 100))
                    LabeledContent("Effects running", value: "\(io.applied) of \(dsp.chain.count)")
                    LabeledContent("Telemetry dropped", value: "\(telemetry.droppedFrames)")
                }

                Section("Acknowledgements") {
                    Link(destination: URL(string: "https://github.com/Frieve-A/effetune")!) {
                        LabeledContent("EffeTune") { Text("MIT").foregroundStyle(.secondary) }
                    }
                    Link(destination: URL(string: "https://github.com/marton78/pffft")!) {
                        LabeledContent("PFFFT") { Text("BSD").foregroundStyle(.secondary) }
                    }
                    Text("""
                         The effects are EffeTune's own DSP by Yoshiyuki Kobayashi, running \
                         unmodified.
                         """)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                Section {
                    LabeledContent("Version", value: version)
                    LabeledContent("DSP ABI", value: "\(et_abi_version())")
                    LabeledContent("Effects", value: "\(dsp.available.count)")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private var latency: String {
        guard io.sampleRate > 0 else { return "—" }
        let ms = Double(io.bufferedFrames) / io.sampleRate * 1000
        return String(format: "%u samples (%.0f ms)", io.bufferedFrames, ms)
    }

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
