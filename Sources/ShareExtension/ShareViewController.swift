//  ShareViewController.swift
//  共有シートの EffectDeck。受けたものを App Group の Inbox へ置くだけ。
//
//  **判定はしない。**音か JSFX かは本体の ETInbox.receive が中身で決める
//  （拡張は DSP も IRLibrary も持たない）。本体は前へ出たときに Inbox を拾う
//  （ETShareInbox.drain）。
//
//  **リンクは「Import → From Link」と同じ道で落とす。**読み替え（blob → raw、
//  gist → /raw）も大きさの上限も ETRemoteFile を共有しているので、ずれない。

import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {

    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.finish = { [weak self] added in
            guard let context = self?.extensionContext else { return }
            if added {
                context.completeRequest(returningItems: nil)
            } else {
                context.cancelRequest(withError: CocoaError(.userCancelled))
            }
        }

        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        model.load(providers)
    }
}

@MainActor
final class ShareModel: ObservableObject {

    enum Item {
        case web(URL)
        case file(URL)
        case text(String)
    }

    @Published private(set) var item: Item?
    @Published private(set) var busy = false
    @Published private(set) var error: String?

    var finish: (Bool) -> Void = { _ in }

    /// 見出し。ファイルは名前、リンクは末尾、字は 1 行目。
    var name: String {
        switch item {
        case .web(let url):
            let leaf = url.lastPathComponent
            return leaf.isEmpty || leaf == "/" ? (url.host ?? url.absoluteString) : leaf
        case .file(let url):
            return url.lastPathComponent
        case .text(let text):
            let line = text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty } ?? ""
            return String(line.prefix(80))
        case nil:
            return ""
        }
    }

    func load(_ providers: [NSItemProvider]) {
        Task {
            item = await Self.resolve(providers)
            if item == nil { error = ETRemoteFile.Failure.empty.localizedDescription }
        }
    }

    func cancel() { finish(false) }

    func add() {
        guard let item, !busy else { return }
        busy = true
        error = nil
        Task {
            do {
                guard let root = ETShareInbox.root else { throw CocoaError(.fileWriteNoPermission) }
                switch item {
                case .web(let url):
                    guard let address = ETRemoteFile.address(from: url.absoluteString) else {
                        throw ETRemoteFile.Failure.notAnAddress
                    }
                    let (data, name) = try await ETRemoteFile.download(address)
                    try ETShareInbox.deposit(data, named: name, in: root)
                case .file(let url):
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    guard size <= ETRemoteFile.limit else { throw ETRemoteFile.Failure.tooLarge }
                    try ETShareInbox.deposit(copying: url, in: root)
                case .text(let text):
                    try ETShareInbox.deposit(Data(text.utf8), named: "pasted.jsfx", in: root)
                }
                finish(true)
            } catch {
                self.error = error.localizedDescription
                busy = false
            }
        }
    }

    /// 渡されたものから 1 つ選ぶ。**URL を先に見る。**Safari は URL と字の両方を
    /// 載せてくることがあり、字を先に取るとページの題名を JSFX として置いてしまう。
    private static func resolve(_ providers: [NSItemProvider]) async -> Item? {
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = try? await p.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                return url.isFileURL ? .file(url) : .web(url)
            }
        }
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            let value = try? await p.loadItem(forTypeIdentifier: UTType.plainText.identifier)
            if let url = value as? URL { return url.isFileURL ? .file(url) : .web(url) }
            let text = (value as? String) ?? (value as? Data).map { String(decoding: $0, as: UTF8.self) }
            guard let text, !text.isEmpty else { continue }
            // リンクだけの字はリンクとして扱う（メモやメッセージから来る形）。
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.contains(where: \.isWhitespace), ETRemoteFile.address(from: trimmed) != nil,
               let url = URL(string: trimmed) {
                return .web(url)
            }
            return .text(text)
        }
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
            if let copy = await copyFile(from: p) { return .file(copy) }
        }
        return nil
    }

    /// **渡された一時ファイルは受け取りの関数を抜けると消える。**その中で写しておく。
    private static func copyFile(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { done in
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.data.identifier) { url, _ in
                guard let url else { done.resume(returning: nil); return }
                let fm = FileManager.default
                let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                let name = provider.suggestedName.map { name -> String in
                    let ext = url.pathExtension
                    return ext.isEmpty || name.hasSuffix("." + ext) ? name : name + "." + ext
                } ?? url.lastPathComponent
                let copy = dir.appendingPathComponent(ETShareInbox.safeName(name))
                do {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    try fm.copyItem(at: url, to: copy)
                    done.resume(returning: copy)
                } catch {
                    done.resume(returning: nil)
                }
            }
        }
    }
}

struct ShareView: View {
    @ObservedObject var model: ShareModel

    var body: some View {
        NavigationStack {
            Form {
                Text(model.name)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if let error = model.error {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("EffectDeck")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.busy {
                        ProgressView()
                    } else {
                        Button("Add") { model.add() }
                            .disabled(model.item == nil)
                    }
                }
            }
        }
    }
}
