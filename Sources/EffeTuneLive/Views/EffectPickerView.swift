//  EffectPickerView.swift
//  足すエフェクトを選ぶ。
//
//  EffeTune は左に Available Effects をずっと出しているが、iPhone の幅では
//  鎖と並べられないのでシートにした。
//  カテゴリは横のページ送りで切り替える。上の帯が現在地を出し、押せば直接飛べる。
//  探すときは検索に切り替わり、ページ送りをやめて全カテゴリを縦に並べる。

import SwiftUI

struct EffectPickerView: View {
    let onPick: (ETEffect) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var dsp = EffeTuneDSP.shared
    @State private var query = ""
    @State private var category = ""

    private var categories: [String] {
        Array(Set(dsp.available.map(\.category))).sorted()
    }

    private var searchResults: [ETEffect] {
        let q = query.lowercased()
        return dsp.available
            .filter {
                $0.name.lowercased().contains(q)
                    || $0.about.lowercased().contains(q)
                    || $0.category.lowercased().contains(q)
            }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            Group {
                if query.isEmpty {
                    VStack(spacing: 0) {
                        categoryStrip
                        Divider()
                        pages
                    }
                } else {
                    searchList
                }
            }
            .searchable(text: $query, prompt: "Search effects")
            .navigationTitle("Available Effects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear { if category.isEmpty { category = categories.first ?? "" } }
        }
    }

    /// 現在地を出し、押せば直接飛べる帯。
    private var categoryStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(categories, id: \.self) { name in
                        Button {
                            withAnimation(.snappy(duration: 0.25)) { category = name }
                        } label: {
                            Text(name.categoryLabel)
                                .font(.system(size: 13, weight: category == name ? .semibold : .regular))
                                .foregroundStyle(category == name ? AnyShapeStyle(.white)
                                                                  : AnyShapeStyle(.secondary))
                                .padding(.horizontal, 13)
                                .padding(.vertical, 7)
                                .background(category == name ? AnyShapeStyle(.tint)
                                                             : AnyShapeStyle(.quaternary),
                                            in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .id(name)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
            .onChange(of: category) { _, new in
                withAnimation { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }

    /// 横に払うとカテゴリが変わる。
    private var pages: some View {
        TabView(selection: $category) {
            ForEach(categories, id: \.self) { name in
                List(dsp.available.filter { $0.category == name }.sorted { $0.name < $1.name }) { effect in
                    row(effect)
                }
                .listStyle(.plain)
                .tag(name)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    private var searchList: some View {
        Group {
            if searchResults.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List(searchResults) { effect in
                    row(effect, showCategory: true)
                }
                .listStyle(.plain)
            }
        }
    }

    private func row(_ effect: ETEffect, showCategory: Bool = false) -> some View {
        Button {
            onPick(effect)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(effect.name)
                        .font(.system(size: 15))
                        .foregroundStyle(.primary)
                    if showCategory {
                        Text(effect.category.categoryLabel)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
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
