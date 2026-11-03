//  Support.swift（Tests/Fuzz）
//  的が共有する道具。バイトを前から読む、JSON を比べられる形にする、鎖の往復を見張る。

import Foundation

/// 入力のバイトを前から読む。**尽きたら 0 を返し続ける**（的は短い入力でも最後まで走る）。
struct FuzzBytes {
    private let bytes: [UInt8]
    private var index = 0

    init(_ raw: UnsafeRawBufferPointer) { bytes = Array(raw) }

    var remaining: Int { bytes.count - index }

    mutating func u8() -> UInt8 {
        guard index < bytes.count else { return 0 }
        defer { index += 1 }
        return bytes[index]
    }

    mutating func u16() -> Int { Int(u8()) | Int(u8()) << 8 }

    mutating func u32() -> UInt32 {
        UInt32(u8()) | UInt32(u8()) << 8 | UInt32(u8()) << 16 | UInt32(u8()) << 24
    }

    mutating func bool() -> Bool { u8() & 1 == 1 }

    /// `list` から 1 つ。空の一覧は渡さない。
    mutating func pick<T>(_ list: [T]) -> T { list[Int(u8()) % list.count] }

    /// 残り全部。
    mutating func rest() -> [UInt8] {
        defer { index = bytes.count }
        return Array(bytes[min(index, bytes.count)...])
    }
}

extension Fuzz {
    /// 並べた鍵で書いた JSON。書けなければ nil。**Darwin は書けないものを渡すと例外で落ちる**
    /// （NSJSONSerialization は投げずに NSInvalidArgumentException を上げる）ので、
    /// isValidJSONObject を先に見る。Linux は投げるだけなので、ここで同じ判定にそろえる。
    static func canonical(_ object: Any) -> Data? {
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// 2 つの JSON の字が同じ中身か。**数は値で比べる**（-0 と 0 は同じ）。
    /// 字のまま比べると、-0.0 の Float が "-0" と書かれ、読み戻すと整数の 0 になって
    /// 次は "0" と書かれる（音も表示も変わらない）のを破れと取り違える。
    static func sameJSON(_ a: Data, _ b: Data) -> Bool {
        guard let x = try? JSONSerialization.jsonObject(with: a, options: [.fragmentsAllowed]),
              let y = try? JSONSerialization.jsonObject(with: b, options: [.fragmentsAllowed]) else { return a == b }
        return same(x, y)
    }

    private static func same(_ x: Any, _ y: Any) -> Bool {
        if let a = x as? [Any], let b = y as? [Any] {
            return a.count == b.count && zip(a, b).allSatisfy { same($0, $1) }
        }
        if let a = x as? [String: Any], let b = y as? [String: Any] {
            return a.count == b.count && a.allSatisfy { key, value in b[key].map { same(value, $0) } ?? false }
        }
        if (x is Bool) != (y is Bool) { return false }
        if let a = x as? Bool, let b = y as? Bool { return a == b }
        if let a = x as? NSNumber, let b = y as? NSNumber { return a.doubleValue == b.doubleValue }
        if let a = x as? String, let b = y as? String { return a == b }
        return x is NSNull && y is NSNull
    }

    /// JSON の中に NaN・無限の数があるか。**Darwin の JSONSerialization は 1e400 のような
    /// 数を読まない**が、Linux は無限として読むことがある。アプリが Darwin で受け取れない値を
    /// 約束の破れと取り違えないよう、そういう入力は的の入口で捨てる。
    static func hasNonFinite(_ json: Any) -> Bool {
        if let list = json as? [Any] { return list.contains(where: hasNonFinite) }
        if let dict = json as? [String: Any] { return dict.values.contains(where: hasNonFinite) }
        if let number = json as? NSNumber, !(json is Bool) { return !number.doubleValue.isFinite }
        return false
    }

    /// 的が使う JSFX の一覧（ETChainText.jsfxResolver に渡す）。名前は種の返事と同じ綴り。
    static let jsfxLibrary: [(id: String, name: String)] = [
        (id: "jsfx:" + String(repeating: "a", count: 64), name: "Chat Soft Clip"),
        (id: "jsfx:" + String(repeating: "b", count: 64), name: "Gain"),
    ]
}

/// 読んだ鎖（PipelineStore.Loaded）が書き戻せることの見張り。
///
/// 約束は 3 つ:
///   1. shortForm / longForm / effeTuneForm は JSON として書ける（NaN・無限・Data が混じらない）。
///      書けないと Darwin では共有リンクを作るところで落ちる（ETShareLink.link）
///   2. shortForm → JSON → parse → shortForm が同じ字に戻る（1 往復目で丸めたあとは動かない）
///   3. こちらのリンク（deckURL）に書いて読み戻すと段の数が同じ
enum FormOracle {
    static func check(_ loaded: [PipelineStore.Loaded], _ context: String) {
        // 範囲は見ないが、大きさは見る。上限の外は画面の Int(_:) が落とす（ETParamCoding.decode）。
        for item in loaded {
            Fuzz.oracle(item.values.allSatisfy { abs($0) <= ETParamCoding.magnitudeLimit },
                        "\(context): \(item.spec.name) の値が ±\(ETParamCoding.magnitudeLimit) の外: \(item.values)")
        }
        let short = PipelineStore.shortForm(loaded)
        guard let first = Fuzz.canonical(short) else {
            Fuzz.oracle(false, "\(context): shortForm が JSON に書けない: \(short)")
            return
        }
        Fuzz.oracle(Fuzz.canonical(PipelineStore.longForm(loaded)) != nil,
                    "\(context): longForm が JSON に書けない")
        let upstream = ETShareLink.effeTuneForm(loaded)
        Fuzz.oracle(Fuzz.canonical(upstream) != nil, "\(context): effeTuneForm が JSON に書けない")
        Fuzz.oracle(!upstream.contains { $0["external"] != nil },
                    "\(context): effeTuneForm に外部の段が残った")

        guard let reread = try? JSONSerialization.jsonObject(with: first) else {
            Fuzz.oracle(false, "\(context): 書いた shortForm が読めない")
            return
        }
        let again = PipelineStore.parse(reread, catalog: ETCatalog)
        Fuzz.oracle(again.count == loaded.count,
                    "\(context): shortForm を読み戻すと段の数が変わる \(loaded.count) → \(again.count)")
        let second = Fuzz.canonical(PipelineStore.shortForm(again))
        Fuzz.oracle(second.map { Fuzz.sameJSON($0, first) } ?? false,
                    "\(context): shortForm → parse → shortForm が戻らない\n"
                    + "1: \(String(decoding: first, as: UTF8.self))\n"
                    + "2: \(second.map { String(decoding: $0, as: UTF8.self) } ?? "nil")")

        let long = PipelineStore.parse(PipelineStore.longForm(loaded), catalog: ETCatalog)
        Fuzz.oracle(long.count == loaded.count,
                    "\(context): longForm を読み戻すと段の数が変わる \(loaded.count) → \(long.count)")

        guard !loaded.isEmpty else { return }
        guard let deck = ETShareLink.deckURL(for: loaded) else {
            Fuzz.oracle(false, "\(context): deckURL が作れない")
            return
        }
        let back = ETShareLink.parse(deck.absoluteString, catalog: ETCatalog)
        Fuzz.oracle(back.count == loaded.count,
                    "\(context): deckURL を読み戻すと段の数が変わる \(loaded.count) → \(back.count)")
        _ = ETShareLink.url(for: loaded)
    }

    /// 値が有限で、数のパラメータは範囲の中か。**ETChainText.prepare を通った鎖にだけ使う。**
    /// バックアップと pipeline.last は prepare を通らず、範囲の外の値もそのまま読む（設計どおり）。
    static func checkRanges(_ loaded: [PipelineStore.Loaded], _ context: String) {
        for item in loaded where item.externalID.isEmpty && !ETSection.isSection(item.spec) {
            Fuzz.oracle(item.values.count == item.spec.defaults.count,
                        "\(context): \(item.spec.name) の値の数 \(item.values.count) ≠ \(item.spec.defaults.count)")
            for p in item.spec.params {
                for k in p.offset..<(p.offset + max(1, p.count)) where item.values.indices.contains(k) {
                    let v = item.values[k]
                    Fuzz.oracle(v.isFinite, "\(context): \(item.spec.name).\(p.key)[\(k)] = \(v)")
                    if case .number(let lo, let hi, _, _, _) = p.kind {
                        Fuzz.oracle(v >= lo && v <= hi,
                                    "\(context): \(item.spec.name).\(p.key)[\(k)] = \(v) が \(lo)...\(hi) の外")
                    }
                }
            }
        }
    }
}
