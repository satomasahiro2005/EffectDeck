//  EffectPickerView.swift
//  足すエフェクトを選ぶ。
//
//  EffeTune は左に Available Effects をずっと出しているが、iPhone の幅では
//  鎖と並べられないのでシートにした。見出しの並びは EffeTune と同じ。
//  数が 100 近くあるので、探す欄を上に置いてある。

import SwiftUI

struct EffectPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var dsp = EffeTuneDSP.shared
    @State private var query = ""

    private var groups: [(String, [ETEffect])] {
        let all = dsp.available
        guard !query.isEmpty else { return all.byCategory }
        let q = query.lowercased()
        return all.filter {
            $0.name.lowercased().contains(q)
                || $0.about.lowercased().contains(q)
                || $0.category.lowercased().contains(q)
        }.byCategory
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(groups, id: \.0) { category, effects in
                    Section(category.categoryLabel) {
                        ForEach(effects) { effect in
                            Button {
                                dsp.add(effect)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(effect.name)
                                        .font(.system(size: 15))
                                        .foregroundStyle(.primary)
                                    if !effect.about.isEmpty {
                                        Text(effect.about)
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search effects")
            .navigationTitle("Available Effects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .overlay {
                if groups.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text("\(dsp.available.count) effects available")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(.bar)
            }
        }
    }
}
