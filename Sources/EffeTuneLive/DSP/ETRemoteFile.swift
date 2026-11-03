//  ETRemoteFile.swift
//  リンクからファイルを取ってくる。
//
//  取り込みの口はファイルだけだったので、GitHub などに置いてあるものを入れるには
//  一度端末へ落としてから選び直す必要があった。リンクをそのまま渡せるようにする。
//
//  **人が貼るのは見ているページの URL。**GitHub の `blob` は HTML の画面で、
//  そのまま取ると `<!DOCTYPE html>` が落ちてくる。生のファイルは
//  `raw.githubusercontent.com` にあるので、こちらで読み替える。
//  gistはAPIの一覧から名前を引く（名指しが無ければ名前の順で最初の1本）。
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
    /// - `https://gist.github.com/u/<id>`          → `api.github.com/gists/<id>`（downloadが名前の順で最初の1本を取る）
    /// - `https://gist.github.com/u/<id>#file-a-jsfx` → `api.github.com/gists/<id>#file-a-jsfx`（downloadが名前を引く）
    /// - `https://gist.github.com/u/<id>/raw/…`    → そのまま
    /// - それ以外はそのまま
    static func address(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var comps = URLComponents(string: trimmed),
              let scheme = comps.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = comps.host?.lowercased() else { return nil }

        let parts = comps.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

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
            // downloadで印と突き合わせる。印はfragmentに残す（送られない）。
            //
            // **名指しの無いリンクも一覧から引く。**`<gist>/raw`は画面の先頭の1本を返すと
            // 思っていたが違った。キットのgistでは画面の先頭はatmos_4ch_ffmpeg.wavなのに
            // convert.pyが落ちてきて、「音でもJSFXでもない」と断っていた。
            var api = URLComponents()
            api.scheme = "https"
            api.host = "api.github.com"
            api.path = "/gists/" + id
            if let f = comps.fragment, f.hasPrefix("file-"), f.count > "file-".count {
                api.fragment = f
            }
            return api.url
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

    /// 名指しの無いgistのリンクで取る1本。**名前の順で最初のもの**（gistの画面の並び）。
    /// 一覧の`files`はJSONの辞書で、JSONSerializationが並びを落とすので自分で並べる。
    /// 比べ方は文字の値の順（大文字が小文字より先）。
    ///
    /// **添え物は飛ばす。**`README.md`や`convert.py`が名前の順で先に来ると、音やJSFXが後ろに
    /// あっても「音でもJSFXでもない」と断ることになる。全部が添え物なら先頭を返す（断るのはETInbox）。
    static func firstGistFile(among names: [String]) -> String? {
        let sorted = names.sorted()
        return sorted.first { !isAccompanying($0) } ?? sorted.first
    }

    /// 取り込めないと名前だけで分かるもの。JSFXは拡張子が決まっていない（`.txt`や無しもある）ので、
    /// 決め打ちできるものだけ挙げる。
    private static let accompanyingExtensions: Set<String> = [
        "md", "markdown", "rst", "py", "sh", "ps1", "js", "json", "yml", "yaml",
        "html", "htm", "css", "png", "jpg", "jpeg", "gif", "svg", "pdf", "zip",
    ]

    private static func isAccompanying(_ name: String) -> Bool {
        let dot = name.lastIndex(of: ".")
        let ext = dot.map { name[name.index(after: $0)...].lowercased() } ?? ""
        if accompanyingExtensions.contains(ext) { return true }
        let stem = (dot.map { String(name[..<$0]) } ?? name).uppercased()
        return stem == "README" || stem == "LICENSE"
    }

    /// gistの画面が各ファイルに付けるRawの行き先（`/<持ち主>/<id>/raw/<版>/<名前>`）。
    /// **画面の並びのまま**、同じ名前は1つにして返す。APIに断られたときの逃げ道（download）。
    static func gistRawLinks(inPage html: String, id: String) -> [(name: String, raw: URL)] {
        let pattern = #"href="(?:https://gist\.github\.com)?(/[^/"]+/"#
            + NSRegularExpression.escapedPattern(for: id)
            + #"/raw/[0-9a-f]+/([^"/]+))""#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        var out: [(name: String, raw: URL)] = []
        for m in re.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let pathRange = Range(m.range(at: 1), in: html),
                  let nameRange = Range(m.range(at: 2), in: html) else { continue }
            // 属性の中なので`&`は`&amp;`で来る。名前は%で包まれている（空白など）。
            let path = unescapeAttribute(html[pathRange])
            guard let name = unescapeAttribute(html[nameRange]).removingPercentEncoding,
                  !out.contains(where: { $0.name == name }),
                  let raw = URL(string: "https://gist.github.com" + path) else { continue }
            out.append((name, raw))
        }
        return out
    }

    private static func unescapeAttribute(_ s: Substring) -> String {
        s.replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// gist の一覧から、印に合う 1 本の名前を選ぶ。**当たりが 2 本以上なら選ばない。**
    static func gistFile(named anchor: String, among names: [String]) -> String? {
        let exact = names.filter { gistAnchor(for: $0) == anchor }
        if exact.count == 1 { return exact[0] }
        let loose = names.filter { looseKey($0) == looseKey(anchor) }
        return loose.count == 1 ? loose[0] : nil
    }

    /// 網へ出る口と、上限と、落としかけを書く場所。**本体と共有の拡張は既定のまま使う。**
    /// 単体テスト（RemoteFileDownloadTests）は網の代わり（URLProtocol を差した session）、
    /// 小さい上限、空のフォルダを渡し、断ったときに書きかけが残らないことまで見る。
    struct Transfer {
        var session: URLSession = .shared
        var limit: Int = ETRemoteFile.limit
        var scratch: URL = FileManager.default.temporaryDirectory
    }

    /// 落として、端末の一時置き場へ書く。**名前は向こうが言うものを使う。**
    /// 拡張子で振り分けてはいないが、取り込み先が複製の名前に使う。
    static func fetch(_ address: URL, via transfer: Transfer = Transfer()) async throws -> URL {
        let (part, name) = try await download(address, via: transfer)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: part, to: file)
        log.notice("取ってきた \(name, privacy: .public)")
        return file
    }

    /// 落とすだけ。戻りは一時置き場のファイルと名前。置く場所は呼ぶ側が決める
    /// （共有の拡張は App Group へ移す）。
    ///
    /// **溜めずにファイルへ流す。上限は届いている途中で切る。**
    /// 共有の拡張は 120 MB ほどで OS に落とされる。全部を Data に溜めてから
    /// 大きさを見る形だと、上限を超えるものを渡されたときに判定の前に落ちる。
    static func download(_ address: URL,
                         via transfer: Transfer = Transfer()) async throws -> (file: URL, name: String) {
        // gistの中の1本。一覧を引いて、印に合う名前（印が無ければ名前の順で最初）の
        // raw_urlを取りに行く。一覧の`content`は大きいと切られる（truncated）ので使わない。
        // **共有の拡張もここを通るので、fetch ではなくこちらで引く。**
        if address.host == "api.github.com", address.path.hasPrefix("/gists/") {
            let anchor = address.fragment.flatMap {
                $0.hasPrefix("file-") ? String($0.dropFirst("file-".count)) : nil
            } ?? ""
            let files: [(name: String, raw: URL)]
            do {
                files = try await gistListing(address, via: transfer)
            } catch Failure.http(let code) where code == 403 || code == 429 {
                // **APIに断られたら画面から引く。**未認証のAPIは1つのIPから1時間に60回までで、
                // 同じIPを大勢で使う回線では自分が呼んでいなくても尽きている（開発機でも
                // `403 rate limit exceeded`が返った）。画面のRawの行き先にも本当の名前が載っている。
                // `<gist>/raw`へは逃げない。持ち主の名前の無いリンクだと404で、あっても先頭の1本ではない。
                files = try await gistPageListing(id: address.lastPathComponent, via: transfer)
            }
            let names = files.map { $0.name }
            guard let name = anchor.isEmpty ? firstGistFile(among: names)
                                            : gistFile(named: anchor, among: names),
                  let raw = files.first(where: { $0.name == name })?.raw
            else { throw Failure.noSuchFile }
            let (part, _) = try await stream(raw, via: transfer)
            return (part, ETShareInbox.safeName(name))
        }
        return try await stream(address, via: transfer)
    }

    /// APIの一覧から名前とraw_urlを引く。
    private static func gistListing(_ address: URL,
                                    via transfer: Transfer) async throws -> [(name: String, raw: URL)] {
        let (file, _) = try await stream(address, via: transfer)
        defer { try? FileManager.default.removeItem(at: file) }
        let listing = try Data(contentsOf: file)
        guard let root = try? JSONSerialization.jsonObject(with: listing) as? [String: Any],
              let files = root["files"] as? [String: [String: Any]]
        else { throw Failure.noSuchFile }
        return files.compactMap { name, info in
            (info["raw_url"] as? String).flatMap(URL.init(string:)).map { (name, $0) }
        }
    }

    /// gistの画面から引く。`gist.github.com/<id>`は持ち主の名前の付いた先へ飛ばされる。
    private static func gistPageListing(id: String,
                                        via transfer: Transfer) async throws -> [(name: String, raw: URL)] {
        var page = URLComponents()
        page.scheme = "https"
        page.host = "gist.github.com"
        page.path = "/" + id
        guard let url = page.url else { throw Failure.noSuchFile }
        let (file, _) = try await stream(url, via: transfer)
        defer { try? FileManager.default.removeItem(at: file) }
        let data = try Data(contentsOf: file)
        let html = String(decoding: data, as: UTF8.self)
        return gistRawLinks(inPage: html, id: id)
    }

    private static func stream(_ address: URL, via transfer: Transfer) async throws -> (file: URL, name: String) {
        var request = URLRequest(url: address)
        // GitHub は User-Agent が無いと断ることがある。
        request.setValue("EffectDeck", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await transfer.session.bytes(for: request)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            bytes.task.cancel()
            throw Failure.http(http.statusCode)
        }
        // 向こうが大きさを言っているなら、本文を受ける前に断る。
        if response.expectedContentLength > Int64(transfer.limit) {
            bytes.task.cancel()
            throw Failure.tooLarge
        }

        let fm = FileManager.default
        let part = transfer.scratch.appendingPathComponent(UUID().uuidString)
        guard fm.createFile(atPath: part.path, contents: nil) else {
            bytes.task.cancel()
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let handle = try FileHandle(forWritingTo: part)
            defer { try? handle.close() }
            let chunk = 64 * 1024
            var buffer = Data()
            buffer.reserveCapacity(chunk)
            var total = 0
            for try await byte in bytes {
                buffer.append(byte)
                guard buffer.count == chunk else { continue }
                total += buffer.count
                guard total <= transfer.limit else { throw Failure.tooLarge }
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
            total += buffer.count
            guard total <= transfer.limit else { throw Failure.tooLarge }
            guard total > 0 else { throw Failure.empty }
            try handle.write(contentsOf: buffer)
        } catch {
            bytes.task.cancel()
            try? fm.removeItem(at: part)
            throw error
        }

        // 名前は URL の末尾。無ければ付ける（取り込み先は中身で判じるので、
        // 名前が当てにならなくても困らない）。
        // **飛ばされた先の末尾を先に見る。**gist の `/raw` は
        // `gist.githubusercontent.com/.../raw/<sha>/<名前>` へ飛ぶので、
        // 元の URL だと名前が "raw" になり IR の一覧に download.bin で並ぶ。
        // **飛ばす先は向こうが決める。**末尾は `..` や（%2F が解かれて）`/` を
        // 含みうるので、ETShareInbox.safeName で置き場の外へ出ない名前にする。
        for candidate in [response.url, address].compactMap({ $0 }) {
            let name = candidate.lastPathComponent
            if !name.isEmpty, name != "/", name != "raw" {
                return (part, ETShareInbox.safeName(name))
            }
        }
        return (part, "download")
    }
}
