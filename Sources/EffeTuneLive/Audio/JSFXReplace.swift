//  JSFXReplace.swift
//  取り込み直したJSFXで前の版を置き換える規則。**Foundationだけ**（JSFXReplaceTests）。
//
//  idはソースのsha256（ETJSFXHost.ownedCopyの置き場の名前）なので、ChatGPTに直させた版を
//  入れ直すたびに別の1本として並び、Pluginsの一覧が際限なく伸びていた。
//  `desc:`と`author:`が同じなら同じ1本の新しい版とみなし、前の版を置き場（JSFX/Replaced）へ
//  移して「前のid → 新しいid」の付け替えを残す。鎖・プリセット・バックアップ・共有リンクは
//  前のidのまま書かれているので、引くときにこの付け替えを辿る（ETJSFXHost.entry(id:)）。
//  **前の版は新しい版が1度建つまで消さない。**建たなければ（コンパイルできない・時間切れ）
//  前の版を一覧へ戻し、付け替えも戻す（Aliases.rollBack）。
//
//  ここにあるのは判定と付け替えの表と保存の形と置き場の見直し方だけ。ファイルを動かす・
//  段を建て直すのはETJSFXHost（importFile・commitReplacement・rollBackReplacement）。

import Foundation

enum JSFXReplace {

    // MARK: - 頭の読み方

    /// ソースの頭80行から`desc:`と`author:`を読む。**同じ行が2つあれば後のほう。**
    ///
    /// 一覧に出る名前（ETJSFXHost.metadata）もこれで読む。置き換えの判定と一覧の名前が
    /// 別々の読み方をすると、一覧では同じ名前なのに置き換わらない形になる。
    static func metadata(_ source: String) -> (name: String?, author: String?) {
        var name: String?, author: String?
        for raw in source.split(whereSeparator: { $0.isNewline }).prefix(80) {
            // **見えない字も落とす。**ETJSFXHost.looksLikeJSFXと同じ扱いにしないと、
            // BOM付きの`.txt`は取り込めるのに1行目の`desc:`が読めず、
            // 一覧に題ではなくファイル名が並ぶ。U+FEFFは空白ではないので
            // .whitespacesだけでは落ちない。
            let line = raw.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}\u{200B}"))
            if line.hasPrefix("desc:") { name = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
            if line.hasPrefix("author:") { author = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        }
        return (name, author)
    }

    // MARK: - 同じ1本か

    /// 同じ1本かを決める鍵。`desc:`と`author:`を前後の空白を落として比べる。
    /// **大文字小文字は区別する。**違う綴りは違う1本として並べる（消すほうへ倒さない）。
    struct Identity: Hashable, Sendable {
        let name: String
        let author: String

        init(name: String, author: String) {
            self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            self.author = author.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// **`desc:`が無い・空ならnil（置き換えない）。**名前が無いものは一覧でファイル名になり、
        /// 貼り付けたものはどれも同じ仮の名前（pasted）になるので、名前で束ねると別物を消す。
        /// `author:`は無くても空でもよく、どちらも空として比べる。
        init?(source: String) {
            self.init(metadata: JSFXReplace.metadata(source))
        }

        /// 読み終えた頭（metadata）から作る。一覧を作るときに1度読んだものを使い回す
        /// （ETJSFXHost.Entry.identity。取り込むたびに全部のソースを読み直さない）。
        init?(metadata: (name: String?, author: String?)) {
            guard let name = metadata.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return nil }
            self.init(name: name, author: metadata.author ?? "")
        }
    }

    /// 取り込んである1本。置き換える相手を選ぶために渡す。
    struct Candidate: Equatable, Sendable {
        let id: String
        /// 頭が読めない・`desc:`が無いものはnil。置き換えの相手にならない。
        let identity: Identity?
        /// 同梱の見本（ETJSFXHost.Entry.isDebugFixture）。
        let isBundled: Bool
    }

    /// `newID`を取り込んだときに置き換える（置き場へ移して付け替える）もの。一覧の順のまま返す。
    ///
    /// - 人が入れたものだけ。**同梱の見本は置き換えない。**同じ名前で入れたものは今までどおり
    ///   別の1本として並ぶ。
    /// - 同じidは中身も同じ（sha256）なので相手にしない。同じ中身を入れ直したときは
    ///   今までどおり取り込んだ時刻が進むだけ。
    /// - **前からあった重複もまとめて片付ける。**この規則より前に並んだv1とv2は、
    ///   v3を入れたときにどちらもv3へ付け替わる。
    static func replaced(by newID: String, identity: Identity?, among candidates: [Candidate]) -> [String] {
        guard let identity else { return [] }
        return candidates
            .filter { !$0.isBundled && $0.id != newID && $0.identity == identity }
            .map(\.id)
    }

    // MARK: - つまみの持ち越し

    /// 新しい版のつまみ1本の範囲。
    struct SliderRange: Equatable, Sendable {
        let index: UInt32
        let minimum: Double
        let maximum: Double
    }

    /// 前の版のつまみ1本と、いまの値。
    struct Slider: Equatable, Sendable {
        let index: UInt32
        let minimum: Double
        let maximum: Double
        let value: Double

        var range: SliderRange { SliderRange(index: index, minimum: minimum, maximum: maximum) }
    }

    /// 鳴っている段を新しい版へ載せ替えるときに持ち越す値。
    ///
    /// **数と範囲（番号・最小・最大）が全部同じときだけ。**1本でも違えば空（新しい版の既定から）。
    /// 番号をずらしたり範囲を変えたりした版に前の値を入れると、別のつまみや範囲の外の値になる。
    /// 並び順は問わない。NaNと無限は持ち越さない（スクリプトはslider変数に何でも書ける）。
    static func carriedSliderValues(from previous: [Slider],
                                    to fresh: [SliderRange]) -> [(index: UInt32, value: Double)] {
        let before = previous.map(\.range).sorted { $0.index < $1.index }
        let after = fresh.sorted { $0.index < $1.index }
        guard before == after else { return [] }
        return previous.sorted { $0.index < $1.index }
            .filter { $0.value.isFinite }
            .map { (index: $0.index, value: $0.value) }
    }

    // MARK: - 付け替えの表

    /// 前のid → いまのid。**いつも辿った先へ潰して持つ**（v1→v2→v3ならv1→v3、v2→v3）。
    ///
    /// 輪になるもの（a→b→a）と、辿ると輪に入るものは持たない。前の版を入れ直したとき
    /// （v1→v2のあとにv1を入れてv2を置き換えた）はredirectが輪を作らずに付け直す。
    struct Aliases: Equatable, Sendable {
        /// 辿り終えた表。キーは生きた1本ではない。
        private(set) var map: [String: String]

        init() { map = [:] }

        /// どんな表からでも作れる。潰して、輪と空の字と自分を指すものを落とす。
        init(_ raw: [String: String]) { map = Self.normalized(raw) }

        var isEmpty: Bool { map.isEmpty }

        /// 付け替えを辿った先。付け替えが無い・輪になっているならnil。
        func resolve(_ id: String) -> String? { Self.resolve(id, in: map) }

        /// `old`を`new`で置き換えた。`old`へ付け替えていたものも`new`へ。
        /// **`new`から出ている付け替えは消す**（`new`はいま生きた1本）。
        mutating func redirect(from old: String, to new: String) {
            guard !old.isEmpty, !new.isEmpty, old != new else { return }
            var next = map
            next[new] = nil
            for (key, value) in next where value == old { next[key] = new }
            next[old] = new
            map = Self.normalized(next)
        }

        /// `target`での置き換えを戻した。`restored`は置き場から一覧へ戻した前の版で、**新しい順**。
        ///
        /// - `restored`の鍵は外す（いま生きた1本）。
        /// - ほかに`target`へ付け替えていたもの（もっと前に置き換え終えた版）は、戻した中で
        ///   いちばん新しい版へ。表は潰して持つので、どの版を経て来たかは残っていない。
        /// - `target`から出ている付け替えは元から無い（生きた1本）。`restored`が空なら何もしない。
        mutating func rollBack(target: String, restored: [String]) {
            guard let newest = restored.first else { return }
            let back = Set(restored)
            var next = map
            for (key, value) in map where value == target {
                next[key] = back.contains(key) ? nil : newest
            }
            map = Self.normalized(next)
        }

        private static func resolve(_ id: String, in map: [String: String]) -> String? {
            var seen: Set<String> = [id]
            var current = id
            while let next = map[current] {
                guard seen.insert(next).inserted else { return nil }
                current = next
            }
            return current == id ? nil : current
        }

        private static func normalized(_ raw: [String: String]) -> [String: String] {
            let clean = raw.filter { !$0.key.isEmpty && !$0.value.isEmpty && $0.key != $0.value }
            var out: [String: String] = [:]
            for key in clean.keys {
                if let target = resolve(key, in: clean) { out[key] = target }
            }
            return out
        }

        // MARK: 保存の形

        /// `{"aliases":{"jsfx:<前>":"jsfx:<いま>"},"version":1}`。
        /// 鍵は並べて書く（同じ表なら同じ字になる）。
        private struct File: Codable {
            var version: Int
            var aliases: [String: String]
        }

        static let version = 1

        func encoded() -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return (try? encoder.encode(File(version: Self.version, aliases: map))) ?? Data()
        }

        /// 読めなければnil。**版の数は見ない。**先の版が書いた表でも付け替えは付け替えで、
        /// 断ると次の保存で表ごと消える。知らない鍵は無視する。
        init?(data: Data) {
            guard let file = try? JSONDecoder().decode(File.self, from: data) else { return nil }
            self.init(file.aliases)
        }
    }

    // MARK: - 置き場の見直し

    /// 置き場（JSFX/Replaced）に残っている前の版をどうするか。起動のときに決める。
    enum ShelfFate: Equatable, Sendable {
        /// 新しい版（行き先のid）が建つのを待たせる。
        case waiting(String)
        /// 消してよい。同じ中身が一覧に居る（前の版を入れ直した）か、行き先を消した。
        case discard
        /// 一覧へ戻す。付け替えが無いので、置き場に置いたままだと誰からも引けない。
        case restore
    }

    /// `id`の前の版の行き先。`live`は一覧（JSFX/Sources）に在る1本のid。
    ///
    /// **行き先の分からないものは消さずに戻す。**付け替えの表が読めなかった・戻す途中で
    /// 落ちたときがこれで、消すと人が入れたものが黙って無くなる。戻すと一覧に同じ名前が
    /// 2本並ぶが、次に取り込んだときにまとまる。
    static func shelfFate(of id: String, aliases: Aliases, live: Set<String>) -> ShelfFate {
        if live.contains(id) { return .discard }
        guard let target = aliases.resolve(id) else { return .restore }
        return live.contains(target) ? .waiting(target) : .discard
    }
}
