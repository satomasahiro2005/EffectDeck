//  ETRemoteFile.swift
//  リンクからファイルを取ってくる。
//
//  取り込みの口はファイルだけだったので、GitHub などに置いてあるものを入れるには
//  一度端末へ落としてから選び直す必要があった。リンクをそのまま渡せるようにする。
//
//  **人が貼るのは見ているページの URL。**GitHub の `blob` は HTML の画面で、
//  そのまま取ると `<!DOCTYPE html>` が落ちてくる。生のファイルは
//  `raw.githubusercontent.com` にあるので、こちらで読み替える。
//  gist も同じ（`/raw` を足す。1 本を名指ししたリンクは API で名前を引く）。
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
        case noSuchFile

        var errorDescription: String? {
            switch self {
            case .notAnAddress: return "That does not look like a link."
            case .tooLarge:     return "The file is too large."
            case .http(let c):  return "The server answered \(c)."
            case .empty:        return "The link had nothing in it."
            case .noSuchFile:   return "That file is not in the gist."
            }
        }
    }

    /// 人が貼った字から、取りに行く先を決める。
    ///
    /// - `https://github.com/u/r/blob/main/a.jsfx` → `raw.githubusercontent.com/u/r/main/a.jsfx`
    /// - `https://github.com/u/r/raw/main/a.jsfx`  → 同じ（GitHub 自身が飛ばすが、先に直す）
    /// - `https://gist.github.com/u/<id>`          → `<同じ>/raw`（先頭の 1 本）
    /// - `https://gist.github.com/u/<id>#file-a-jsfx` → `api.github.com/gists/<id>#file-a-jsfx`（fetch が名前を引く）
    /// - `https://gist.github.com/u/<id>/raw/…`    → そのまま
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
            // 既に生のファイルを指している（Raw を押した先）。触らない。
            if parts.contains("raw") {
                comps.fragment = nil
                return comps.url
            }
            // /<user>/<id> か /<id>
            guard let id = parts.count >= 2 ? parts[1] : parts.first else { return nil }

            // **どのファイルかは `#file-...` に入っている。**gist に 2 本以上
            // 置いてあるとき、印を捨てて /raw だけ足すと先頭の 1 本が落ちてくる。
            //
            // **印はファイル名ではない。**GitHub が名前の記号を `-` に潰したもの
            // （`dh++_4ch.wav` → `file-dh-_4ch-wav`）で、戻す手が無い。以前は印を
            // そのまま /raw/ の後ろに付けていて、`.` を含む名前は全部 404 だった。
            // 本当の名前は API の一覧にしか無いので、そちらを指しておき、
            // fetch で印と突き合わせる。印は fragment に残す（送られない）。
            if let f = comps.fragment, f.hasPrefix("file-"), f.count > "file-".count {
                var api = URLComponents()
                api.scheme = "https"
                api.host = "api.github.com"
                api.path = "/gists/" + id
                api.fragment = f
                return api.url
            }
            parts.append("raw")
            comps.path = "/" + parts.joined(separator: "/")
            comps.fragment = nil
            return comps.url
        }

        return comps.url
    }

    /// gist のページが各ファイルに振る印（`id="file-…"` の `file-` より後ろ）。
    /// 小文字にして、英数字と `_` 以外を `-` にし、続いた `-` を 1 つにまとめる。
    /// 実物の照合: `dh++_4ch_ffmpeg.wav` → `dh-_4ch_ffmpeg-wav`、`convert.py` → `convert-py`。
    static func gistAnchor(for name: String) -> String {
        var out = ""
        for ch in name.lowercased() {
            let keep = ch == "_" || (ch.isASCII && (ch.isLetter || ch.isNumber))
            if keep {
                out.append(ch)
            } else if out.last != "-" {
                out.append("-")
            }
        }
        return out
    }

    /// 印の規則が外れたときの逃げ道。英数字だけで比べる。
    private static func looseKey(_ s: String) -> String {
        String(s.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
    }

    /// gist の一覧から、印に合う 1 本の名前を選ぶ。**当たりが 2 本以上なら選ばない。**
    static func gistFile(named anchor: String, among names: [String]) -> String? {
        let exact = names.filter { gistAnchor(for: $0) == anchor }
        if exact.count == 1 { return exact[0] }
        let loose = names.filter { looseKey($0) == looseKey(anchor) }
        return loose.count == 1 ? loose[0] : nil
    }

    /// 落として、端末の一時置き場へ書く。**名前は向こうが言うものを使う。**
    /// 拡張子で振り分けてはいないが、取り込み先が複製の名前に使う。
    static func fetch(_ address: URL) async throws -> URL {
        // gist の中の 1 本。一覧を引いて、印に合う名前の raw_url を取りに行く。
        // 一覧の `content` は大きいと切られる（truncated）ので使わない。
        if address.host == "api.github.com", address.path.hasPrefix("/gists/"),
           let anchor = address.fragment?.dropFirst("file-".count), !anchor.isEmpty {
            let listing = try await get(address)
            guard let root = try? JSONSerialization.jsonObject(with: listing) as? [String: Any],
                  let files = root["files"] as? [String: [String: Any]],
                  let name = gistFile(named: String(anchor), among: Array(files.keys)),
                  let raw = (files[name]?["raw_url"] as? String).flatMap(URL.init(string:))
            else { throw Failure.noSuchFile }
            return try save(try await get(raw), as: name)
        }
        return try save(try await get(address), as: address.lastPathComponent)
    }

    private static func get(_ address: URL) async throws -> Data {
        var request = URLRequest(url: address)
        // GitHub は User-Agent が無いと断ることがある。
        request.setValue("EffectDeck", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw Failure.http(http.statusCode)
        }
        guard !data.isEmpty else { throw Failure.empty }
        guard data.count <= limit else { throw Failure.tooLarge }
        return data
    }

    private static func save(_ data: Data, as suggested: String) throws -> URL {
        // 名前は URL の末尾。無ければ付ける（取り込み先は中身で判じるので、
        // 名前が当てにならなくても困らない）。
        var name = suggested
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
