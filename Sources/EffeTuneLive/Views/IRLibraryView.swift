//  IRLibraryView.swift
//  IR ファイルの出し入れ。
//
//  プリセットは IR の中身を持たず鍵の参照だけを書くので、
//  web 版で作ったプリセットをこちらで開くには、同じ IR がここに入っている必要がある。
//  鍵は sha256 の先頭24桁で、web 版と同じ作り方をしている。
//
//  取り込みの結果は上流に合わせてある（js/locales/en.json5 の irLibrary.status.importResult）。
//  削除の確認は見出しだけ上流（irLibrary.confirm.delete）に寄せ、本文は戻せないことだけ言う。
//  importFile は読めない・書けないときに nil を返すだけで何も言わない。
//  同じ中身のものは既にある鍵を返して一覧が変わらない。
//  どちらも呼びっぱなしだと「選んだのに増えない」が理由なしで起きる。

import SwiftUI
import UniformTypeIdentifiers

struct IRLibraryView: View {

    /// 1 本選ばれたら呼ぶ。nil なら押しても何も起きない
    /// （ツールバーから開いたときは一覧を眺めるだけ）。
    var onPick: ((IRLibrary.Entry) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var library = IRLibrary.shared
    @State private var picking = false

    /// 取り込みの結果。出したままにせず、次の取り込みで置き換える。
    @State private var importReport: String?

    /// 消す前に確かめる。消したものは戻せない。
    @State private var pendingDelete: IRLibrary.Entry?

    /// 確認の見出し。Text ではなく String で渡す（どの初期化子か迷わせない）。
    private var deleteTitle: String {
        "Delete “\(pendingDelete?.name ?? "")”?"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        picking = true
                    } label: {
                        Label("Import audio file", systemImage: "square.and.arrow.down")
                    }
                    if let importReport {
                        Text(importReport)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if library.entries.isEmpty {
                    Section {
                        Text("No impulse responses yet")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ForEach(library.entries) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name)
                                    .font(.system(size: 15))
                                    .lineLimit(2)
                                // 鍵は web 版と突き合わせるためのもの。
                                // 24 桁を裸で出しても何の数か読めないので名前を付ける。
                                Text("Key \(entry.id) · \(size(entry.bytes))")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            }
                            // **.onDelete を使わない。**（PresetsView に理由を書いた）
                            // 位置ではなく身元で受け取る。消すのは確認を通ってから。
                            .swipeActions(edge: .trailing) {
                                Button("Delete", role: .destructive) {
                                    pendingDelete = entry
                                }
                            }
                            // **Button で包まない。** swipeActions と重ねると
                            // スワイプが取られて消せなくなる。当たり判定だけ広げる。
                            .contentShape(.rect)
                            .onTapGesture {
                                guard let onPick else { return }
                                onPick(entry)
                                dismiss()
                            }
                        }

                    } header: {
                        Text("Impulse responses")
                    }
                }
            }
            .navigationTitle("IR Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .fileImporter(isPresented: $picking,
                          allowedContentTypes: [.item],
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): report(importing: urls)
                case .failure(let error): importReport = error.localizedDescription
                }
            }
            .confirmationDialog(deleteTitle,
                                isPresented: Binding(get: { pendingDelete != nil },
                                                     set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible,
                                presenting: pendingDelete) { entry in
                Button("Delete", role: .destructive) { library.remove(entry) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                // 戻せないことだけ言う。「使用中」は言えない（IR を指す側を数えていない）。
                Text("This cannot be undone.")
            }
        }
    }

    /// 取り込んで、何本入って何本落ちたかを出す。
    /// 同じ中身のものは importFile が既にある鍵を返すだけなので、
    /// 「増えなかった」理由として別に数える。
    private func report(importing urls: [URL]) {
        // 一度に同じ中身を 2 本選ばれても 1 本は「既にある」側に数えたいので、
        // 取り込んだ鍵をその場で足していく。
        var seen = Set(library.entries.map(\.id))
        var added = 0, duplicate = 0, failed = 0

        for url in urls {
            guard let id = library.importFile(at: url) else { failed += 1; continue }
            if seen.insert(id).inserted { added += 1 } else { duplicate += 1 }
        }

        var parts: [String] = []
        if added > 0 { parts.append(added == 1 ? "1 imported" : "\(added) imported") }
        if duplicate > 0 { parts.append("\(duplicate) already in the library") }
        if failed > 0 { parts.append("\(failed) could not be read") }
        importReport = parts.isEmpty ? nil : parts.joined(separator: ", ") + "."
    }

    private func size(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1_048_576
        return mb >= 1 ? String(format: "%.1f MB", mb)
                       : String(format: "%.0f KB", Double(bytes) / 1024)
    }
}
