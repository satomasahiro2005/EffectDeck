//  ETShareInbox.swift
//  共有の拡張（EffectDeckShare）から本体へ渡す置き場。
//
//  Safari で gist の raw を開いて共有すると、渡るのは URL だけ。
//  「このアプリで開く」（ETInbox）はファイルしか受けないので、拡張が先に落として
//  App Group の `Inbox/<uuid>/<名前>` へ置き、本体が次に前へ出たときに拾う。
//
//  **ここは置く・並べる・消すだけ。**音か JSFX かは本体の ETInbox.receive が
//  中身で決める。拡張は DSP も IRLibrary も持たないので判定できない。
//
//  **書きかけを拾わせない。**拡張は `.<uuid>` に書いてから `<uuid>` へ名前を変える。
//  名前の変更は同じボリューム内で一度に起きるので、本体に見えるのは書き終えた箱だけ。
//  Foundation だけなので、拡張・本体・単体テストの 3 か所へ同じものを入れる。

import Foundation

enum ETShareInbox {

    static let group = "group.ai.nemut.effetune"

    /// 書きかけの箱をどれだけ置いておくか。拡張が落ちたときの残りを捨てるため。
    static let staleAfter: TimeInterval = 60 * 60

    /// App Group の中の置き場。entitlement が無いと nil。
    static var root: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("Inbox", isDirectory: true)
    }

    // MARK: - 拡張の側

    /// 中身を置く。戻りは置いたファイル。
    @discardableResult
    static func deposit(_ data: Data, named name: String, in root: URL) throws -> URL {
        try stage(named: name, in: root) { try data.write(to: $0) }
    }

    /// ファイルを写して置く。
    @discardableResult
    static func deposit(copying file: URL, named name: String? = nil, in root: URL) throws -> URL {
        try stage(named: name ?? file.lastPathComponent, in: root) {
            try FileManager.default.copyItem(at: file, to: $0)
        }
    }

    /// 置き場で使う名前。**IR の一覧に出るのはこの名前**なので、元の名前はなるべく残す。
    /// パスの区切りと頭の `.`（書きかけの印と区別が付かなくなる）だけ落とす。
    static func safeName(_ raw: String) -> String {
        var name = raw.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        return name.isEmpty ? "download" : name
    }

    private static func stage(named name: String, in root: URL,
                              _ write: (URL) throws -> Void) throws -> URL {
        let fm = FileManager.default
        let id = UUID().uuidString
        let staging = root.appendingPathComponent("." + id, isDirectory: true)
        let done = root.appendingPathComponent(id, isDirectory: true)
        let leaf = safeName(name)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            try write(staging.appendingPathComponent(leaf))
            try fm.moveItem(at: staging, to: done)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        return done.appendingPathComponent(leaf)
    }

    // MARK: - 本体の側

    /// 拾うべきファイル。**置かれた順**（箱を作った時刻、同じなら名前）。
    /// 書きかけ（`.` で始まる箱）と、空の箱は含めない。
    static func pending(in root: URL) -> [URL] {
        boxes(in: root).compactMap { firstFile(in: $0.url) }
    }

    /// 置かれた順に 1 本ずつ渡し、渡し終えた箱を消す。戻りは渡した結果の列。
    /// 受け手が失敗しても消す（**同じものを毎回出し直さない**）。
    /// 最後に空の箱と、古い書きかけを捨てる。
    static func drain<T>(in root: URL, now: Date = Date(), _ receive: (URL) -> T) -> [T] {
        let fm = FileManager.default
        var results: [T] = []
        for box in boxes(in: root) {
            if let file = firstFile(in: box.url) { results.append(receive(file)) }
            try? fm.removeItem(at: box.url)
        }
        sweepStale(in: root, now: now)
        return results
    }

    /// **時刻は箱の更新時刻。**箱の中身が変わるのは拡張がファイルを書いたとき
    /// だけなので、それが置かれた時刻になる。作成時刻は Linux で書き換えられず
    /// 試しにくいので使わない。
    private struct Box { let url: URL; let stamp: Date }

    private static func boxes(in root: URL) -> [Box] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        let items = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: keys)) ?? []
        return items.compactMap { url -> Box? in
            guard !url.lastPathComponent.hasPrefix("."),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isDirectory == true else { return nil }
            return Box(url: url, stamp: values.contentModificationDate ?? .distantPast)
        }
        .sorted {
            $0.stamp != $1.stamp ? $0.stamp < $1.stamp
                                     : $0.url.lastPathComponent < $1.url.lastPathComponent
        }
    }

    private static func firstFile(in box: URL) -> URL? {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: box, includingPropertiesForKeys: [.isRegularFileKey],
            options: .skipsHiddenFiles)) ?? []
        return items
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
    }

    /// 拡張が書いている最中の箱は残す。**古いものだけ**捨てる。
    private static func sweepStale(in root: URL, now: Date) {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in items where url.lastPathComponent.hasPrefix(".") {
            let created = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            if now.timeIntervalSince(created) > staleAfter { try? fm.removeItem(at: url) }
        }
    }
}
