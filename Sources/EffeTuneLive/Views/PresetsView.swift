//  PresetsView.swift
//  名前を付けた鎖の出し入れと、共有リンクのやり取り。
//
//  保存する中身は EffeTune のユーザープリセットと同じショート形式なので、
//  ここで作ったものを共有リンクにして web 版で開けるし、逆もできる。

import SwiftUI
import UIKit

struct PresetsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var dsp: EffeTuneDSP
    @StateObject private var store = PresetStore.shared

    @State private var newName = ""
    @State private var pasted = ""
    @State private var showPaste = false
    @State private var message: String?

    private var builtinCategories: [String] {
        var seen = Set<String>()
        return ETBuiltinPresets.compactMap { seen.insert($0.category).inserted ? $0.category : nil }
    }

    private func builtin(in category: String) -> [ETBuiltinPreset] {
        ETBuiltinPresets.filter { $0.category == category }
    }

    /// 読み込む経路はユーザーが保存したものと同じ。
    /// 知らないエフェクトが混じっていれば PipelineStore.parse が黙って落とすので、
    /// 何本読めたかを出す。
    private func apply(_ preset: ETBuiltinPreset) {
        let loaded = ETShareLink.parse(preset.json, catalog: ETCatalog)
        guard !loaded.isEmpty else {
            message = "Could not read \(preset.name)."
            return
        }
        dsp.replaceChain(with: loaded)
        dismiss()
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Preset name", text: $newName)
                            .textInputAutocapitalization(.words)
                        Button("Save") {
                            store.save(newName, chain: dsp.chain)
                            newName = ""
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty
                                  || dsp.chain.isEmpty)
                    }
                } header: {
                    Text("Save current chain")
                }

                if !store.names.isEmpty {
                    Section("Presets") {
                        ForEach(store.names, id: \.self) { name in
                            Button {
                                let loaded = store.load(name)
                                guard !loaded.isEmpty else { return }
                                dsp.replaceChain(with: loaded)
                                dismiss()
                            } label: {
                                Text(name).foregroundStyle(.primary)
                            }
                        }
                        .onDelete { offsets in
                            for i in offsets { store.remove(store.names[i]) }
                        }
                    }
                }

                Section {
                    ForEach(builtinCategories, id: \.self) { category in
                        DisclosureGroup(category) {
                            ForEach(builtin(in: category)) { preset in
                                Button {
                                    apply(preset)
                                } label: {
                                    HStack {
                                        Text(preset.name).foregroundStyle(.primary)
                                        Spacer()
                                        Text("\(preset.effectCount)")
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text("Built-in")
                } footer: {
                    Text("The presets that ship with EffeTune. Loading one replaces the current chain.")
                }

                Section {
                    if let url = ETShareLink.url(for: dsp.chain) {
                        ShareLink(item: url) {
                            Label("Share this chain", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button {
                        pasted = UIPasteboard.general.string ?? ""
                        showPaste = true
                    } label: {
                        Label("Import from clipboard", systemImage: "doc.on.clipboard")
                    }
                } header: {
                    Text("EffeTune on the web")
                } footer: {
                    Text("""
                         A shared chain is the same format the web version uses, so a link made \
                         here opens there and a link made there opens here.
                         """)
                }

                if let message {
                    Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Presets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .alert("Import chain", isPresented: $showPaste) {
                Button("Cancel", role: .cancel) {}
                Button("Import") {
                    let loaded = store.importFrom(pasted)
                    if loaded.isEmpty {
                        message = "Nothing readable on the clipboard."
                    } else {
                        dsp.replaceChain(with: loaded)
                        dismiss()
                    }
                }
            } message: {
                Text(pasted.isEmpty
                     ? "The clipboard is empty."
                     : "Replace the current chain with what is on the clipboard?")
            }
        }
    }
}
