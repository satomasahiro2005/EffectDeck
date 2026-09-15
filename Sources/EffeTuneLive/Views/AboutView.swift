//  AboutView.swift
//  版と出典。設定から分けてここへ置いてある。

import SwiftUI

struct AboutView: View {
    @ObservedObject var dsp: EffeTuneDSP

    var body: some View {
        List {
            Section {
                LabeledContent("Version", value: version)
                LabeledContent("DSP ABI", value: "\(et_abi_version())")
                LabeledContent("Effects", value: "\(dsp.available.count)")
            } footer: {
                Text("The effects are EffeTune's own DSP by Yoshiyuki Kobayashi, running unmodified.")
            }

            Section {
                NavigationLink("Open Source Licenses") { LicensesView() }
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
