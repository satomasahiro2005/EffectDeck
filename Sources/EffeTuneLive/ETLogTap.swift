//  ETLogTap.swift
//  報告に添える用の、アプリの中に残るログ。
//
//  **なぜ自前で持つのか。**
//  ログは 87 か所すべて Logger / os_log へ直接出していて、出した先から読み返す口が
//  無い（`OSLogStore` の使用例はこの木に 0 件）。ETConsoleLog は `-ETConsole 1` の
//  ときだけ print するもので、どこにも残らない。
//  つまり「どこに置くか」ではなく「作る」話だった。
//
//  OSLogStore を先に測って決めなかったのは、.info と .debug が端末内にどれだけ残るか、
//  1 時間ぶんの取得に何秒かかるかがコードからは決まらないため。当てが外れると
//  作り直しになる。**測って良ければ後からこちらを差し替えればよい。**
//
//  **入れる場所は、既に文字列を組み立てている所だけ。**
//  状態の遷移と経路の記録がそこに集まっている（AudioIO の経路と接続、
//  AssetUpload の送り込み、EffeTuneDSP の鎖の作り直し）。報告に要るのはほぼこれ。
//  87 か所を全部通すには os_log の補間を捨てて String を先に作ることになり、
//  privacy の指定を 1 か所で決め直す必要があるので、それは別の話にする。
//
//  **拡張のぶんは入らない。**別プロセスなので、この輪には本体の行しか乗らない。
//
//  量: tick の行が約 200 バイトで 6 秒に 1 本、2 KB/分・120 KB/時。
//  上限 1 MB はおよそ 8 時間ぶん。実際の報告は数十〜数百 KB になる。

import Foundation

enum ETLogTap {

    /// 1 MB。古い行から捨てる。
    static let limit = 1_000_000

    private static let lock = NSLock()
    private static var lines: [(when: Date, text: String)] = []
    private static var bytes = 0

    /// 1 行足す。**音のスレッドからは呼ばない。**（ロックを取るので）
    /// 呼んでいるのはどれも main か、状態が変わったときだけ通る場所。
    static func record(_ line: String) {
        let cost = line.utf8.count + 25   // 時刻の前置きぶん
        lock.lock()
        defer { lock.unlock() }
        lines.append((Date(), line))
        bytes += cost
        while bytes > limit, let first = lines.first {
            bytes -= first.text.utf8.count + 25
            lines.removeFirst()
        }
    }

    /// 溜まっている行。古い順。
    static var text: String {
        lock.lock()
        let snapshot = lines
        lock.unlock()
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return snapshot.map { stamp.string(from: $0.when) + " " + $0.text }
            .joined(separator: "\n")
    }

    /// いま何バイト溜まっているか。画面に出す用。
    static var byteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }

    /// 添付できるファイルにして返す。**一時置き場に書く。**
    /// 同じ名前で上書きするので溜まらない。書けなければ nil。
    static func writeAttachment() -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EffectDeck-log.txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}
