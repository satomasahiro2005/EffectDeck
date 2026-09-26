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
            // **どのファイルかは `#file-...` に入っている。**gist に 2 本以上
            // 置いてあるとき、印を捨てて /raw だけ足すと先頭の 1 本が落ちてくる。
            // 印の綴りは名前の記号を `-` にしたもの（`a.jsfx` → `file-a-jsfx`）。
            let wanted = comps.fragment.flatMap { f -> String? in
                guard f.hasPrefix("file-") else { return nil }
                return String(f.dropFirst("file-".count))
            }
            if parts.last != "raw" {
                parts.append("raw")
            }
            if let wanted { parts.append(wanted) }
            comps.path = "/" + parts.joined(separator: "/")
            comps.fragment = nil
            return comps.url
        }

        return comps.url
    }

    /// 落として、端末の一時置き場へ書く。**名前は向こうが言うものを使う。**
    /// 拡張子で振り分けてはいないが、取り込み先が複製の名前に使う。
    static func fetch(_ address: URL) async throws -> URL {
        let (part, name) = try await download(address)

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
    static func download(_ address: URL) async throws -> (file: URL, name: String) {
        var request = URLRequest(url: address)
        // GitHub は User-Agent が無いと断ることがある。
        request.setValue("EffectDeck", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            bytes.task.cancel()
            throw Failure.http(http.statusCode)
        }
        // 向こうが大きさを言っているなら、本文を受ける前に断る。
        if response.expectedContentLength > Int64(limit) {
            bytes.task.cancel()
            throw Failure.tooLarge
        }

        let fm = FileManager.default
        let part = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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
                guard total <= limit else { throw Failure.tooLarge }
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
            total += buffer.count
            guard total <= limit else { throw Failure.tooLarge }
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
