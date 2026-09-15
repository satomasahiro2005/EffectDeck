//  IRLibrary.swift
//  IR Reverb が使う音の素材（インパルス応答）の置き場。
//
//  EffeTune のプリセットは IR の中身を持たず、**鍵の参照だけ**を書く。
//  だから鍵の作り方が web 版と一致していないと、向こうで作ったプリセットを
//  こちらで開いたときに同じ IR を指せない。
//
//  鍵は sha256 の先頭 24 桁（小文字の16進）。
//  ステレオ対は左右それぞれの digest を連結して、もう一度 sha256 を取る。
//  出典: js/ir-library/ir-library-id.js
//
//  取り込んだファイルはアプリの Documents に鍵の名前で置く。
//  Documents に置くのは、ファイルアプリから見えて中身を差し替えられるようにするため。

import CryptoKit
import Foundation
import os

@MainActor
final class IRLibrary: ObservableObject {

    static let shared = IRLibrary()

    private let log = Logger(subsystem: "ai.nemut.effetune", category: "ir")

    struct Entry: Identifiable, Hashable {
        let id: String        // 鍵（sha256 の先頭24桁）
        let name: String      // 取り込んだときのファイル名
        let url: URL
        let bytes: Int
    }

    @Published private(set) var entries: [Entry] = []

    private var root: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("IR", isDirectory: true)
    }

    private init() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
    }

    // MARK: - 鍵

    /// web 版と同じ鍵。sha256 の先頭 24 桁。
    static func key(for data: Data) -> String {
        String(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(24))
    }

    /// 左右で 1 つの IR を成すときの鍵。
    /// それぞれの digest を連結して、もう一度 sha256 を取る。
    static func key(left: Data, right: Data) -> String {
        var joined = Data()
        joined.append(contentsOf: SHA256.hash(data: left))
        joined.append(contentsOf: SHA256.hash(data: right))
        return key(for: joined)
    }

    // MARK: - 出し入れ

    func reload() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: root,
                                                 includingPropertiesForKeys: [.fileSizeKey])) ?? []
        entries = files.compactMap { url in
            // 名前は <鍵>__<元のファイル名> にしてある。
            let stem = url.deletingPathExtension().lastPathComponent
            let parts = stem.components(separatedBy: "__")
            guard parts.count >= 2, parts[0].count == 24 else { return nil }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let name = parts.dropFirst().joined(separator: "__") + "." + url.pathExtension
            return Entry(id: parts[0], name: name, url: url, bytes: size)
        }
        .sorted { $0.name < $1.name }
    }

    /// ファイルを取り込む。すでに同じ中身があれば、その鍵を返すだけ。
    @discardableResult
    func importFile(at source: URL) -> String? {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: source) else {
            log.error("読めない \(source.lastPathComponent, privacy: .public)")
            return nil
        }
        let id = Self.key(for: data)
        if let existing = entries.first(where: { $0.id == id }) { return existing.id }

        // 名前に使えない文字を落とす。鍵で引くので名前は見出しにすぎない。
        let safe = source.deletingPathExtension().lastPathComponent
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let ext = source.pathExtension.isEmpty ? "bin" : source.pathExtension
        let dest = root.appendingPathComponent("\(id)__\(safe).\(ext)")

        do {
            try data.write(to: dest, options: .atomic)
        } catch {
            log.error("書けない \(error.localizedDescription, privacy: .public)")
            return nil
        }
        reload()
        log.notice("取り込んだ \(id, privacy: .public) \(data.count) bytes")
        return id
    }

    func remove(_ entry: Entry) {
        try? FileManager.default.removeItem(at: entry.url)
        reload()
    }

    func entry(id: String) -> Entry? {
        entries.first { $0.id == id }
    }

    func data(id: String) -> Data? {
        guard let e = entry(id: id) else { return nil }
        return try? Data(contentsOf: e.url)
    }
}
