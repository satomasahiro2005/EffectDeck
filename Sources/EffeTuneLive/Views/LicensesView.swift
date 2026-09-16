//  LicensesView.swift
//  取り込んでいるものの出典と、その本文。
//
//  外へリンクを張らず本文を同梱する。配布物の中身と表示が食い違わないようにするため。
//
//  **本文をさらに push しない。** ここはシートの中で、Settings から数えて 1 回目の
//  push に当たる。ここからもう 1 回潜ると、戻り方が分からなくなる（HIG Modality）。
//  代わりに行をその場で開く。開くのは階層ではないので、戻る場所を失わない。
//
//  法務の文書だけを残して押させているのは、iOS 自身も Legal を別の行に置いているから。

import SwiftUI

struct LicensesView: View {
    var body: some View {
        List {
            Section {
                ForEach(ETLicenses) { item in
                    DisclosureGroup {
                        Text(item.text)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
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
                Text("Full text as it ships inside the app.")
            }
        }
        .navigationTitle("Licenses")
        .navigationBarTitleDisplayMode(.inline)
    }
}
