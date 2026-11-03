//  JSFXTextFuzz.swift（Tests/Fuzz）
//  的 jsfxtext: JSFX を取り込む前に字を読むところのうち、Foundation だけのもの。
//    - 貼られた返事から囲いを外す（ETCodeBlock。ETJSFXHost.importText が使う）
//    - 頭の desc: と author:（JSFXReplace.metadata / Identity。置き換えの判定と一覧の名前）
//    - 付け替えの表のファイル（JSFXReplace.Aliases(data:)）、生の表から作る口、redirect
//    - 列挙つまみの添字（ETJSFXLoader.enumIndex）
//  ETJSFXHost.looksLikeJSFX は private で、ETJSFXHost.swift は Linux で建たないので入らない。
//  C++ 側の門（forbiddenSource / sourceWithinBudgets / sourceUsesTrigger）は
//  Tests/Fuzz/Native/jsfx_source_gate.cpp が叩く。
//
//  約束:
//    - first(in:) は all(in:) の先頭と同じ
//    - desc: が読めたら Identity が作れ、名前は空でない
//    - 付け替えの表は辿り終えた形（値がキーに無い・自分を指さない・resolve がその値を返す）で、
//      書いて読み直すと同じ表。redirect のあとも同じ形を保つ
//    - enumIndex は 0..<count（count が 0 以下なら 0）

import Foundation

enum JSFXTextFuzz {
    static func run(_ data: UnsafeRawBufferPointer) {
        var input = FuzzBytes(data)
        let text = Fuzz.text(data)

        let blocks = ETCodeBlock.all(in: text)
        Fuzz.oracle(ETCodeBlock.first(in: text) == blocks.first?.body, "first(in:) と all(in:) の先頭が違う")

        let meta = JSFXReplace.metadata(text)
        let identity = JSFXReplace.Identity(source: text)
        if let name = meta.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            Fuzz.oracle(identity?.name == name, "desc: が読めたのに Identity が違う")
        } else {
            Fuzz.oracle(identity == nil, "desc: が無いのに Identity ができた")
        }

        if let aliases = JSFXReplace.Aliases(data: Data(data)) {
            checkAliases(aliases, "Aliases(data:)")
        }

        // 表を書き換える操作。id は小さい字の組から選び、輪ができやすくする。
        // 生の表（輪・自分を指すもの・空の字を含む）から作る口と、redirect を混ぜる。
        let ids = ["jsfx:a", "jsfx:b", "jsfx:c", "jsfx:d", "jsfx:e", ""]
        var raw: [String: String] = [:]
        var aliases = JSFXReplace.Aliases()
        for _ in 0..<min(64, input.remaining / 2) {
            let op = input.u8()
            let a = ids[Int(op >> 4) % ids.count], b = ids[Int(op & 0x0F) % ids.count]
            if input.bool() {
                aliases.redirect(from: a, to: b)
                checkAliases(aliases, "redirect")
            } else {
                raw[a] = b
                checkAliases(JSFXReplace.Aliases(raw), "init")
            }
        }

        var numbers = FuzzBytes(data)
        let bits = UInt64(numbers.u32()) | UInt64(numbers.u32()) << 32
        let count = Int(Int8(bitPattern: numbers.u8()))
        let index = ETJSFXLoader.enumIndex(Double(bitPattern: bits), count: count)
        Fuzz.oracle(count > 0 ? (0..<count).contains(index) : index == 0,
                    "enumIndex(\(Double(bitPattern: bits)), \(count)) = \(index)")
    }

    private static func checkAliases(_ aliases: JSFXReplace.Aliases, _ context: String) {
        for (key, value) in aliases.map {
            Fuzz.oracle(!key.isEmpty && !value.isEmpty && key != value, "\(context): \(key) → \(value)")
            Fuzz.oracle(aliases.map[value] == nil, "\(context): 辿り終えていない \(key) → \(value) → …")
            Fuzz.oracle(aliases.resolve(key) == value, "\(context): resolve(\(key)) ≠ \(value)")
        }
        Fuzz.oracle(JSFXReplace.Aliases(data: aliases.encoded()) == aliases, "\(context): 書いて読み直すと違う表")
    }
}
