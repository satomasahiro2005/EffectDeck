//  IRLibraryFiles.swift
//  IR の置き場（IRLibrary）の鍵とファイル名の規則。
//
//  IRLibrary.swift は ObservableObject で AVFoundation にも触るので、単体テストのバンドルにも
//  Linux にも入らない。**鍵の作り方とファイル名の読み書きは Foundation と SHA-256 だけなので、
//  ここへ出して試す**（IRLibraryKeyTests・IRLibraryFilesTests）。CryptoKit は Linux では
//  Tests/Linux/Shims/CryptoKit の代役が入る。
//
//  EffeTune のプリセットは IR の中身を持たず、**鍵の参照だけ**を書く。
//  だから鍵の作り方が web 版と一致していないと、向こうで作ったプリセットを
//  こちらで開いたときに同じ IR を指せない（「Missing from the library」になる）。
//
//  鍵は sha256 の先頭 24 桁（小文字の16進）。
//  ステレオ対は左右それぞれの digest を連結して、もう一度 sha256 を取る。
//  出典: js/ir-library/ir-library-id.js。見本は Tools/golden/ir_library_id_golden.mjs が
//  上流の identifySingleIr / identifyPairedIr に作らせる（Tests/Fixtures/IR/ir-library-id-golden.json）。

import CryptoKit
import Foundation

/// 置き場の 1 本。
struct IRLibraryEntry: Identifiable, Hashable {
    let id: String        // 鍵（sha256 の先頭24桁）
    let name: String      // 取り込んだときのファイル名
    let url: URL
    let bytes: Int
}

enum IRLibraryFiles {

    /// 鍵の桁数（ir-library-id.js の IR_ID_HEX_LENGTH）。
    static let keyLength = 24

    /// web 版と同じ鍵。sha256 の先頭 24 桁。
    static func key(for data: Data) -> String {
        String(hex(SHA256.hash(data: data)).prefix(keyLength))
    }

    /// 左右で 1 つの IR を成すときの鍵。
    /// それぞれの digest を連結して、もう一度 sha256 を取る。
    static func key(left: Data, right: Data) -> String {
        var joined = Data()
        joined.append(contentsOf: SHA256.hash(data: left))
        joined.append(contentsOf: SHA256.hash(data: right))
        return key(for: joined)
    }

    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - ファイル名

    /// 置き場に書く名前。`<鍵>__<元の名前>.<拡張子>`。
    /// 元の名前は英数字の続きだけを `-` でつなぐ（鍵で引くので名前は見出しにすぎない）。
    /// 拡張子が無ければ `bin`。
    static func storedName(id: String, source: URL) -> String {
        let safe = source.deletingPathExtension().lastPathComponent
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let ext = source.pathExtension.isEmpty ? "bin" : source.pathExtension
        return "\(id)__\(safe).\(ext)"
    }

    /// 置き場のファイル 1 本を読む。**`<24字>__` で始まらないものは置き場のものではない**（nil）。
    /// 見出しは `__` より後ろと拡張子（元の名前に `__` があっても切らない）。
    static func entry(at url: URL, bytes: Int) -> IRLibraryEntry? {
        let stem = url.deletingPathExtension().lastPathComponent
        let parts = stem.components(separatedBy: "__")
        guard parts.count >= 2, parts[0].count == keyLength else { return nil }
        let name = parts.dropFirst().joined(separator: "__") + "." + url.pathExtension
        return IRLibraryEntry(id: parts[0], name: name, url: url, bytes: bytes)
    }

    /// フォルダの中身を置き場の一覧にする。**見出しの順。**読めないフォルダは空。
    static func entries(in folder: URL) -> [IRLibraryEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.compactMap { url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return entry(at: url, bytes: size)
        }
        .sorted { $0.name < $1.name }
    }
}
