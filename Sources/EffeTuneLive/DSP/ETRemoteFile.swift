//  ETRemoteFile.swift
//  リンクからファイルを取ってくる。
//
//  取り込みの口はファイルだけだったので、GitHub などに置いてあるものを入れるには
//  一度端末へ落としてから選び直す必要があった。リンクをそのまま渡せるようにする。
//
//  **人が貼るのは見ているページの URL。**GitHub の `blob` は HTML の画面で、
//  そのまま取ると `<!DOCTYPE html>` が落ちてくる。生のファイルは
//  `raw.githubusercontent.com` にあるので、こちらで読み替える。
//  gist も同じ（`/raw` を足す）。
//
//  **中身の判定はしない。**落としたものを ETInbox に渡すだけで、音か JSFX かは
//  あちらが頭の印と中身で決める。ここは「取ってくる」だけを持つ。

import Foundation
import OSLog

enum ETRemoteFile {

    private static let log = Logger(subsystem: "ai.nemut.effetune", category: "remote")

    /// 落としてよい大きさ。JSFX は 1 MB で切っているが、IR は数 MB になる。
    static let limit = 32 * 1024 * 1024

    enum Failure: LocalizedError {
        case notAnAddress
        case tooLarge
        case http(Int)
        case empty

        var errorDescription: String? {
            switch self {
            case .notAnAddress: return "That does not look like a link."
            case .tooLarge:     return "The file is too large."
            case .http(let c):  return "The server answered \(c)."
            case .empty:        return "The link had nothing in it."
            }
        }
    }

    /// 人が貼った字から、取りに行く先を決める。
    ///
    /// - `https://github.com/u/r/blob/main/a.jsfx` → `raw.githubusercontent.com/u/r/main/a.jsfx`
    /// - `https://github.com/u/r/raw/main/a.jsfx`  → 同じ（GitHub 自身が飛ばすが、先に直す）
    /// - `https://gist.github.com/u/<id>`          → `<同じ>/raw`
    /// - それ以外はそのまま
    static func address(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var comps = URLComponents(string: trimmed),
              let scheme = comps.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = comps.host?.lowercased() else { return nil }

        var parts = comps.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        if host == "github.com" || host == "www.github.com" {
            // /<user>/<repo>/(blob|raw)/<ref>/<path...>
            if parts.count >= 5, parts[2] == "blob" || parts[2] == "raw" {
                let user = parts[0], repo = parts[1]
                let rest = parts[3...].joined(separator: "/")
                comps.host = "raw.githubusercontent.com"
                comps.path = "/" + user + "/" + repo + "/" + rest
                // `?plain=1` のような画面向けの飾りは落とす。
                comps.query = nil
                comps.fragment = nil
                return comps.url
            }
        }

        if host == "gist.github.com" {
            // 既に /raw で終わっていなければ足す。
            if parts.last != "raw" {
                parts.append("raw")
                comps.path = "/" + parts.joined(separator: "/")
            }
            comps.fragment = nil
            return comps.url
        }

        return comps.url
    }

    /// 落として、端末の一時置き場へ書く。**名前は向こうが言うものを使う。**
    /// 拡張子で振り分けてはいないが、取り込み先が複製の名前に使う。
    static func fetch(_ address: URL) async throws -> URL {
        var request = URLRequest(url: address)
        // GitHub は User-Agent が無いと断ることがある。
        request.setValue("EffectDeck", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw Failure.http(http.statusCode)
        }
        guard !data.isEmpty else { throw Failure.empty }
        guard data.count <= limit else { throw Failure.tooLarge }

        // 名前は URL の末尾。無ければ付ける（取り込み先は中身で判じるので、
        // 名前が当てにならなくても困らない）。
        var name = address.lastPathComponent
        if name.isEmpty || name == "/" || name == "raw" { name = "download" }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: file)
        try data.write(to: file, options: .atomic)
        log.notice("取ってきた \(name, privacy: .public) \(data.count) bytes")
        return file
    }
}
