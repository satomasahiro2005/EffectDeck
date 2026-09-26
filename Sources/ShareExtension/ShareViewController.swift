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

    /// 落としている最中の仕事。Cancel で止める。
    private var work: Task<Void, Never>?

    func load(_ providers: [NSItemProvider]) {
        Task {
            do {
                item = try await Self.resolve(providers)
                if item == nil { error = ETRemoteFile.Failure.empty.localizedDescription }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// **落としている最中でも止める。**止めずに閉じると、拡張が片付けられる前に
    /// 落とし終えて Inbox へ置き、取り消したものが本体に入る。
    func cancel() {
        work?.cancel()
        finish(false)
    }

    func add() {
        guard let item, !busy else { return }
        busy = true
        error = nil
        work = Task {
            do {
                guard let root = ETShareInbox.root else { throw CocoaError(.fileWriteNoPermission) }
                switch item {
                case .web(let url):
                    guard let address = ETRemoteFile.address(from: url.absoluteString) else {
                        throw ETRemoteFile.Failure.notAnAddress
                    }
                    let (part, name) = try await ETRemoteFile.download(address)
                    do {
                        try Task.checkCancellation()
                        try ETShareInbox.deposit(moving: part, named: name, in: root)
                    } catch {
                        try? FileManager.default.removeItem(at: part)
                        throw error
                    }
                case .file(let url):
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    try Self.checkSize(of: url)
                    try Task.checkCancellation()
                    try ETShareInbox.deposit(copying: url, in: root)
                case .text(let text):
                    try Task.checkCancellation()
                    try ETShareInbox.deposit(Data(text.utf8), named: "pasted.jsfx", in: root)
                }
                finish(true)
            } catch {
                if Task.isCancelled { return }
                self.error = error.localizedDescription
                busy = false
            }
        }
    }

    /// 置く前に見る。**ファイルだけ、上限まで。**フォルダや大きさの分からない
    /// ものは写し始めると止まらない。
    nonisolated private static func checkSize(of url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize else {
            throw CocoaError(.fileReadUnknown)
        }
        guard size <= ETRemoteFile.limit else { throw ETRemoteFile.Failure.tooLarge }
    }

    /// 渡されたものから 1 つ選ぶ。**URL を先に見る。**Safari は URL と字の両方を
    /// 載せてくることがあり、字を先に取るとページの題名を JSFX として置いてしまう。
    private static func resolve(_ providers: [NSItemProvider]) async throws -> Item? {
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
            if let copy = try await copyFile(from: p) { return .file(copy) }
        }
        return nil
    }

    /// **渡された一時ファイルは受け取りの関数を抜けると消える。**その中で写しておく。
    /// 上限を超えるものは写さない（写してから断ると、その間ずっと書き続ける）。
    private static func copyFile(from provider: NSItemProvider) async throws -> URL? {
        try await withCheckedThrowingContinuation { done in
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.data.identifier) { url, _ in
                guard let url else { done.resume(returning: nil); return }
                do { try checkSize(of: url) } catch { done.resume(throwing: error); return }
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
