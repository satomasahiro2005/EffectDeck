//  SFZLibraryView.swift
//  SFZ の置き場（2.14.0 の上流の SFZ Library。js/sfz/browser.js と js/ui/asset-library-browser.js）。
//
//  上流は 2.14.0 で、SFZ Note Player のカードにあった選択欄・Import Folder…・Remove を、この一覧 1 枚に
//  まとめた。カードには SFZ Library… と選んでいる名前と Clear だけが残る（SFZNotePlayerView.swift）。
//
//  - 取り込みはフォルダを選ぶと**中の SFZ を全部**置き場へ入れる（上流の importFiles と同じ。段には入れない）
//  - 名前で探す・名前順と新しい順で並べる（上流の list の query と sort）
//  - 押すとその段のバンクにして閉じる
//  - 消すのはどの段も使っていないものだけ（上流の status.inUse）
//  - 行の小さい字は 大きさ · Files · Regions（上流の formatBadge）。2.13.0 で入れたものは Regions だけ

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
                        Text("No matching SFZ instruments.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name)
                                .font(.system(size: 15))
                                .lineLimit(2)
                            Text(badge(entry))
                                .font(.system(size: 11))
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
            .searchable(text: $query, prompt: "Search SFZ instruments")
            .navigationTitle("SFZ Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
                guard case .success(let url) = result else { return }
                Task { report = await loader.importToLibrary(folder: url) }
            }
            .confirmationDialog("Delete “\(pendingDelete?.name ?? "")” from the library?",
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
            report = "This SFZ is in use by an effect pipeline and cannot be deleted."
            return
        }
        do {
            try library.remove(id: entry.id)
            report = "SFZ deleted."
        } catch {
            report = "The SFZ could not be deleted."
        }
    }

    /// 大きさ · Files: n · Regions: n（上流の formatBadge）。
    private func badge(_ entry: ETSFZLibraryEntry) -> String {
        var parts: [String] = []
        if let size = entry.size {
            parts.append(size >= 1_048_576 ? String(format: "%.1f MiB", Double(size) / 1_048_576)
                         : size >= 1024 ? String(format: "%.1f KiB", Double(size) / 1024) : "\(size) B")
        } else {
            parts.append("size unknown")
        }
        if let files = entry.fileCount { parts.append("Files: \(files)") }
        parts.append("Regions: \(entry.regionCount)")
        return parts.joined(separator: " · ")
    }
}
