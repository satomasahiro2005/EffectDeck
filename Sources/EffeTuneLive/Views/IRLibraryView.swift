//  IRLibraryView.swift
//  IR ファイルの出し入れ。
//
//  プリセットは IR の中身を持たず鍵の参照だけを書くので、
//  web 版で作ったプリセットをこちらで開くには、同じ IR がここに入っている必要がある。
//  鍵は sha256 の先頭24桁で、web 版と同じ作り方をしている。

import SwiftUI
import UniformTypeIdentifiers

struct IRLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var library = IRLibrary.shared
    @State private var picking = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        picking = true
                    } label: {
                        Label("Import audio file", systemImage: "square.and.arrow.down")
                    }
                } footer: {
                    Text("""
                         WAV and FLAC both work. Files are kept under this app's Documents \
                         folder, so you can also drop them in with the Files app.
                         """)
                }

                if library.entries.isEmpty {
                    Section {
                        Text("Nothing here yet.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Impulse responses") {
                        ForEach(library.entries) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name).font(.system(size: 15))
                                Text("\(entry.id) · \(size(entry.bytes))")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .onDelete { offsets in
                            for i in offsets { library.remove(library.entries[i]) }
                        }
                    }
                }
            }
            .navigationTitle("IR Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .fileImporter(isPresented: $picking,
                          allowedContentTypes: [.audio, .wav, .aiff, .mpeg4Audio, .data],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    for url in urls { library.importFile(at: url) }
                }
            }
        }
    }

    private func size(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1_048_576
        return mb >= 1 ? String(format: "%.1f MB", mb)
                       : String(format: "%.0f KB", Double(bytes) / 1024)
    }
}
