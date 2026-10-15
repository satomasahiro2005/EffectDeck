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
//  **鍵とファイル名の規則は IRLibraryFiles.swift。**Foundation だけで単体テストに入り、
//  鍵は上流が作った見本と照合している。ここは置き場の出し入れと画面への公開だけ。
//
//  取り込んだファイルはアプリの Documents に鍵の名前で置く。
//  Documents に置くのは、ファイルアプリから見えて中身を差し替えられるようにするため。

import Combine
import Foundation
import os

@MainActor
final class IRLibrary: ObservableObject {

    static let shared = IRLibrary()

    private let log = Logger(subsystem: "ai.nemut.effetune", category: "ir")

    typealias Entry = IRLibraryEntry

    @Published private(set) var entries: [Entry] = []

    /// 置き場のフォルダ。ふつうは Documents/IR（documentsFolder）。
    /// **差し替えられるようにしてある**のは、本物の Documents を汚さずに出し入れを試すため。
    private let root: URL

    nonisolated static var documentsFolder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("IR", isDirectory: true)
    }

    init(root: URL = IRLibrary.documentsFolder) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
    }

    // MARK: - 出し入れ

    /// 名前は <鍵>__<元のファイル名> にしてある（IRLibraryFiles.entry）。
    func reload() {
        entries = IRLibraryFiles.entries(in: root)
    }

    /// 取り込んだ IR を全部消す（ETFactoryReset）。
    func eraseAll() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
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
        // **音かどうかは、読む当人に訊く。**ここは読めさえすれば何でも受けていた
        // （拡張子は名前に使うだけで判定していない）ので、共有シートから来た
        // JSFX まで IR として取り込まれていた。
        //
        // **頭の印で振ってはいけない。**一度 RIFF/FORM/fLaC/caff の 4 つで見たが、
        // 実際に読むのは AVAudioFile 一本（ETIRLoader.load）で、m4a・mp3・ALAC も
        // 扱える。印で振ると、**選べるのに取り込めない**形ができる。
        guard Self.looksLikeAudio(at: source) else {
            log.notice("音ではない \(source.lastPathComponent, privacy: .public)")
            return nil
        }
        let id = IRLibraryFiles.key(for: data)
        if let existing = entries.first(where: { $0.id == id }) { return existing.id }

        // 名前に使えない文字を落とす。鍵で引くので名前は見出しにすぎない。
        let dest = root.appendingPathComponent(IRLibraryFiles.storedName(id: id, source: source))

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

    /// 音のファイルか。**開けるかどうかで決める。**読むのと同じ AVAudioFile に訊く
    /// （ETIRDecode.canOpen。m4a や mp3 は先頭が印にならないので、頭では振らない）。
    static func looksLikeAudio(at url: URL) -> Bool {
        ETIRDecode.canOpen(url)
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
