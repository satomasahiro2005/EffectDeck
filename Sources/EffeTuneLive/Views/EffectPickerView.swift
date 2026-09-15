//  EffectPickerView.swift
//  鎖に足すエフェクトを選ぶ。一覧は EffectCatalog.swift の生成物。

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
                    Section(category) {
                        ForEach(effects) { effect in
                            Button {
                                dsp.add(effect)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(effect.name).foregroundStyle(.primary)
                                    if !effect.about.isEmpty {
                                        Text(effect.about)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "エフェクトを探す")
            .navigationTitle("エフェクト")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("やめる") { dismiss() } }
            }
            .overlay {
                if groups.isEmpty {
                    ContentUnavailableView("見つからない", systemImage: "magnifyingglass")
                }
            }
        }
    }
}
