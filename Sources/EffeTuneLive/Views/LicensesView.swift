//  LicensesView.swift
//  取り込んでいるものの出典と、その本文。
//
//  外へリンクを張らず本文を同梱する。配布物の中身と表示が食い違わないようにするため。
//  About の直下に並べると「EffeTune」「PFFFT」が何なのか分からないので、ここへまとめてある。

import SwiftUI

struct LicensesView: View {
    var body: some View {
        List {
            Section {
                ForEach(ETLicenses) { item in
                    NavigationLink {
                        LicenseTextView(item: item)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name)
                                .font(.system(size: 15, weight: .medium))
                            Text("\(item.license) · \(item.author)")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("The effects are EffeTune's own DSP by Yoshiyuki Kobayashi, running unmodified.")
            }
        }
        .navigationTitle("Open Source Licenses")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LicenseTextView: View {
    let item: ETLicense

    var body: some View {
        ScrollView {
            Text(item.text)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
