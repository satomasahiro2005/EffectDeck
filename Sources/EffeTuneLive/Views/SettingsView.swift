//  SettingsView.swift
//  右上から出す設定。EffeTune も設定は右上に置いてある。
//
//  ここに置くのは**変えるものだけ**。
//  信号の様子や負荷、版やライセンスは読むだけなので Status / About へ移した。
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

                // 読むだけのものはここに置かない。
                // 設定は「変えるもの」だけにする。
                Section {
                    NavigationLink("Status") { StatusView(io: io, dsp: dsp) }
                    NavigationLink("About") { AboutView(dsp: dsp) }
                }
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

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}

