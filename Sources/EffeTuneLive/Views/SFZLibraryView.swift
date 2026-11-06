//  SFZLibraryView.swift
//  SF2・SFZ の置き場（上流の SoundFont Library。2.17.0 で SFZ Library から改名。js/sfz/browser.js と js/ui/asset-library-browser.js）。
//
//  上流は 2.14.0 で、SFZ Note Player のカードにあった選択欄・Import Folder…・Remove を、この一覧 1 枚に
//  まとめた。カードには SoundFont Library… と選んでいる名前と Clear だけが残る（SFZNotePlayerView.swift）。
//
//  - 取り込みはフォルダを選ぶと**中の SFZ と SoundFont（SF2）を全部**置き場へ入れる（上流の importFiles と同じ。段には入れない）。
//    SoundFont はファイル 1 本を選んでもよい（ファイル選択は .folder と SF2 の型。SF3 は Vorbis を読める段で足す）
//  - 名前で探す・名前順と新しい順で並べる（上流の list の query と sort）
//  - 押すとその段のバンクにして閉じる
//  - 消すのはどの段も使っていないものだけ（上流の status.inUse）
//  - 行の小さい字は 大きさ · SF2 · Files · Regions（上流の formatBadge。ETSFZMessages.libraryBadge。SF2・SF3 は SoundFont のときだけ）。
//    2.13.0 で入れたものは Regions だけ
//  - 文面は ETSFZMessages（上流の sfzLibrary.*）

import SwiftUI
import UniformTypeIdentifiers

struct SFZLibraryView: View {

    /// 1 つ選ばれたら呼ぶ。
    var onPick: (ETSFZLibraryEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var library = SFZLibrary.shared
    @ObservedObject private var loader = SFZLoader.shared

    private enum Sort: String, CaseIterable, Identifiable {
        case filename, recent
        var id: String { rawValue }
        var label: String { self == .filename ? "Name" : "Recent" }
    }

    @State private var query = ""
    @State private var sort: Sort = .filename
    @State private var picking = false
    @State private var report: String?
    @State private var pendingDelete: ETSFZLibraryEntry?

    private var entries: [ETSFZLibraryEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let found = library.entries.filter { needle.isEmpty || $0.name.lowercased().contains(needle) }
        let byName: (ETSFZLibraryEntry, ETSFZLibraryEntry) -> Bool = {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        switch sort {
        case .filename: return found.sorted(by: byName)
        case .recent:
            return found.sorted { a, b in
                let ta = a.importedAt ?? "", tb = b.importedAt ?? ""
                return ta != tb ? ta > tb : byName(a, b)
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        report = nil
                        picking = true
                    } label: {
                        Label(loader.libraryImport == nil ? "Import Folder…" : "Importing…",
                              systemImage: "square.and.arrow.down")
                            .font(.body)
                    }
                    .disabled(loader.libraryImport != nil)
                    if let progress = loader.libraryImport {
                        ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))) {
                            Text("\(progress.done) / \(progress.total)").font(.footnote).monospacedDigit()
                        }
                    } else if let report {
                        Text(report).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    if entries.isEmpty {
                        Text(ETSFZMessages.libraryEmpty)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name)
                                .font(.body)
                                .lineLimit(2)
                            Text(badge(entry))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        // IRLibraryView と同じく、Button で包まない（swipeActions を取られる）。
                        .contentShape(.rect)
                        .onTapGesture {
                            onPick(entry)
                            dismiss()
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", role: .destructive) { pendingDelete = entry }
                        }
                    }
                } header: {
                    Picker("Sort", selection: $sort) {
                        ForEach(Sort.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .textCase(nil)
                }
            }
            .searchable(text: $query, prompt: ETSFZMessages.librarySearchPrompt)
            .etNavigationTitle(ETSFZMessages.libraryTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: Self.importTypes) { result in
                guard case .success(let url) = result else { return }
                Task { report = await loader.importToLibrary(picked: url) }
            }
            .confirmationDialog(ETSFZMessages.libraryConfirmDelete(pendingDelete?.name ?? ""),
                                isPresented: Binding(get: { pendingDelete != nil },
                                                     set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible,
                                presenting: pendingDelete) { entry in
                Button("Delete", role: .destructive) { delete(entry) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This cannot be undone.")
            }
        }
    }

    private func delete(_ entry: ETSFZLibraryEntry) {
        let inUse = EffeTuneDSP.shared.nodes.contains {
            $0.spec.type == ETChainText.sfzType && $0.irId == entry.id
        }
        guard !inUse else {
            report = ETSFZMessages.libraryInUse
            return
        }
        do {
            try library.remove(id: entry.id)
            report = ETSFZMessages.libraryDeleted
        } catch {
            report = ETSFZMessages.libraryDeleteFailed
        }
    }

    /// 選べるもの。フォルダと、SoundFont のファイル（拡張子から作る型。システムが知らない拡張子でも選べる）。
    private static var importTypes: [UTType] {
        [.folder] + ETSFZSoundFormats.soundFontExtensions.compactMap { UTType(filenameExtension: $0) }
    }

    /// 大きさ · SF2 · Files: n · Regions: n（上流の formatBadge）。
    private func badge(_ entry: ETSFZLibraryEntry) -> String {
        ETSFZMessages.libraryBadge(size: entry.size, format: entry.format, fileCount: entry.fileCount,
                                   regionCount: entry.regionCount)
    }
}
