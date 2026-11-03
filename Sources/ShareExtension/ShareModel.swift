//  ShareModel.swift
//  共有の拡張が受けたものを 1 つ選び、App Group の Inbox へ置くまで（画面は ShareViewController.swift）。
//
//  **判定はしない。**音か JSFX かは本体の ETInbox.receive が中身で決める
//  （拡張は DSP も IRLibrary も持たない）。本体は前へ出たときに Inbox を拾う
//  （ETShareInbox.drain）。
//
//  **リンクは「Import → From Link」と同じ道で落とす。**読み替え（blob → raw、
//  gist → 一覧）も大きさの上限も ETRemoteFile を共有しているので、ずれない。
//
//  単体テストのバンドルにも入れる（ShareModelTests）。受けたものの形（ShareItem）と、置き方・
//  大きさの門・写しの名前（ShareIntake）は Foundation だけで、Linux（Tests/Linux/run.sh）でも走る。
//  NSItemProvider から選ぶところ（ShareModel）は UniformTypeIdentifiers と Combine が要るので
//  `#if canImport(UniformTypeIdentifiers)` の中に置き、Mac だけで試す。

import Foundation
#if canImport(UniformTypeIdentifiers)
import Combine
import UniformTypeIdentifiers
#endif

/// 共有で受けた 1 つ。
enum ShareItem: Equatable {
    case web(URL)
    case file(URL)
    case text(String)

    /// URL で来たもの。file の URL はファイル、それ以外はリンク。
    init(url: URL) {
        self = url.isFileURL ? .file(url) : .web(url)
    }

    /// 字で来たもの。空なら nil（次の候補を見る）。
    /// **リンクだけの字はリンクとして扱う**（メモやメッセージから来る形）。前後の空白と改行は
    /// 見ないが、中に空白があればリンクを含む文章として字のまま置く。
    init?(text: String) {
        guard !text.isEmpty else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains(where: \.isWhitespace), ETRemoteFile.address(from: trimmed) != nil,
           let url = URL(string: trimmed) {
            self = .web(url)
        } else {
            self = .text(text)
        }
    }

    /// 見出し。ファイルは名前、リンクは末尾（無ければホスト）、字は空でない 1 行目の先頭 80 字。
    var name: String {
        switch self {
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
        }
    }

    /// security scope を開く相手。ファイルだけ。
    var fileURL: URL? {
        if case .file(let url) = self { return url }
        return nil
    }
}

/// 受けたものを Inbox へ置く手順。Foundation だけ。
enum ShareIntake {

    /// 字で来たものを置くときの名前。本体は中身で判じるので、拡張子は見出しにすぎない。
    static let pastedName = "pasted.jsfx"

    /// 置く前に見る。**ファイルだけ、上限まで。**フォルダや大きさの分からない
    /// ものは写し始めると止まらない。
    static func checkSize(of url: URL, limit: Int = ETRemoteFile.limit) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize else {
            throw CocoaError(.fileReadUnknown)
        }
        guard size <= limit else { throw ETRemoteFile.Failure.tooLarge }
    }

    /// 渡された一時ファイルを写すときの名前。向こうが名前を示していればそれを使い、
    /// 一時ファイルの拡張子が付いていなければ足す。示していなければ一時ファイルの名前。
    /// 置き場の名前にするのは ETShareInbox.safeName を通してから。
    static func copyName(suggested: String?, file: URL) -> String {
        guard let name = suggested else { return file.lastPathComponent }
        let ext = file.pathExtension
        return ext.isEmpty || name.hasSuffix("." + ext) ? name : name + "." + ext
    }

    /// **渡された一時ファイルは受け取りの関数を抜けると消える。**その中で写しておく。
    /// 上限を超えるものは写さない（写してから断ると、その間ずっと書き続ける）。
    /// 大きさの門で断ったときは投げ、写せなかったときは nil（次の候補を見る）。
    static func scratchCopy(of url: URL, suggestedName: String?,
                            limit: Int = ETRemoteFile.limit,
                            scratch: URL = FileManager.default.temporaryDirectory) throws -> URL? {
        try checkSize(of: url, limit: limit)
        let fm = FileManager.default
        let dir = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let copy = dir.appendingPathComponent(
            ETShareInbox.safeName(copyName(suggested: suggestedName, file: url)))
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.copyItem(at: url, to: copy)
            return copy
        } catch {
            return nil
        }
    }

    /// 選んだものを Inbox へ置く。戻りは置いたファイル。
    ///
    /// **取り消しは置く直前まで見る。**止めずに閉じると、拡張が片付けられる前に
    /// 落とし終えて Inbox へ置き、取り消したものが本体に入る（ShareModel.cancel）。
    /// ファイルの security scope は呼ぶ側が開く（ShareModel.add）。
    ///
    /// **呼んだ側の actor の上で走る**（`isolation`）。拡張は MainActor から呼ぶので、落とす間
    /// （ETRemoteFile.download）のほかは前と同じく MainActor で写し、置く。
    @discardableResult
    static func deposit(_ item: ShareItem, in root: URL,
                        via transfer: ETRemoteFile.Transfer = ETRemoteFile.Transfer(),
                        isolation: isolated (any Actor)? = #isolation) async throws -> URL {
        switch item {
        case .web(let url):
            guard let address = ETRemoteFile.address(from: url.absoluteString) else {
                throw ETRemoteFile.Failure.notAnAddress
            }
            let (part, name) = try await ETRemoteFile.download(address, via: transfer)
            do {
                try Task.checkCancellation()
                return try ETShareInbox.deposit(moving: part, named: name, in: root)
            } catch {
                try? FileManager.default.removeItem(at: part)
                throw error
            }
        case .file(let url):
            try checkSize(of: url, limit: transfer.limit)
            try Task.checkCancellation()
            return try ETShareInbox.deposit(copying: url, in: root)
        case .text(let text):
            try Task.checkCancellation()
            return try ETShareInbox.deposit(Data(text.utf8), named: pastedName, in: root)
        }
    }
}

#if canImport(UniformTypeIdentifiers)
@MainActor
final class ShareModel: ObservableObject {

    typealias Item = ShareItem

    @Published private(set) var item: Item?
    @Published private(set) var busy = false
    @Published private(set) var error: String?

    var finish: (Bool) -> Void = { _ in }

    /// 見出し。ファイルは名前、リンクは末尾、字は 1 行目（ShareItem.name）。
    var name: String { item?.name ?? "" }

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
                let file = item.fileURL
                let scoped = file?.startAccessingSecurityScopedResource() ?? false
                do {
                    defer { if scoped { file?.stopAccessingSecurityScopedResource() } }
                    try await ShareIntake.deposit(item, in: root)
                }
                finish(true)
            } catch {
                if Task.isCancelled { return }
                self.error = error.localizedDescription
                busy = false
            }
        }
    }

    /// 渡されたものから 1 つ選ぶ。**URL を先に見る。**Safari は URL と字の両方を
    /// 載せてくることがあり、字を先に取るとページの題名を JSFX として置いてしまう。
    static func resolve(_ providers: [NSItemProvider]) async throws -> Item? {
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = try? await p.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                return ShareItem(url: url)
            }
        }
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            let value = try? await p.loadItem(forTypeIdentifier: UTType.plainText.identifier)
            if let url = value as? URL { return ShareItem(url: url) }
            let text = (value as? String) ?? (value as? Data).map { String(decoding: $0, as: UTF8.self) }
            guard let text, let item = ShareItem(text: text) else { continue }
            return item
        }
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
            if let copy = try await copyFile(from: p) { return .file(copy) }
        }
        return nil
    }

    /// **渡された一時ファイルは受け取りの関数を抜けると消える。**その中で写しておく
    /// （ShareIntake.scratchCopy）。
    static func copyFile(from provider: NSItemProvider) async throws -> URL? {
        try await withCheckedThrowingContinuation { done in
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.data.identifier) { url, _ in
                guard let url else { done.resume(returning: nil); return }
                do {
                    done.resume(returning: try ShareIntake.scratchCopy(of: url,
                                                                       suggestedName: provider.suggestedName))
                } catch {
                    done.resume(throwing: error)
                }
            }
        }
    }
}
#endif
