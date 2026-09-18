//  ETParamCoding.swift
//  ETParam の並びと、EffeTune の保存形式（JSON の辞書）の相互変換。
//
//  **ここは EffeTuneDSP にも AVFoundation にも触らない。**
//  入力は `[ETParam]` と `[Float]` と `[String: Any]` だけなので、
//  シミュレータでもエンジン抜きで測れる（Tests/Unit/ParamCodingTests.swift）。
//
//  切り出した理由。ここに 2 つ欠陥があって、どちらも静的に読んだだけでは
//  何度も見落とし、実際に壊れている画面を見るまで気づけなかった:
//
//    0. 配列を平らな `"f": [...]` で書いていた。**上流にその形は 1 つも無い。**
//       params.json の配列 77 個を数えると、57 個がオブジェクト配列
//       （objectArrayKey）、残り 20 個が添字付き（`f0 f1 f2 …`）で、平らは 0 個。
//       5Band PEQ / 15Band PEQ / 15Band GEQ / MultiChannel Panel /
//       Earphone Cable Sim が添字付きの側。読めないので既定のまま載り、
//       PEQ の曲線が平坦になっていた。
//    1. オブジェクト配列を平らな配列で書いていた。上流は 5Band Dynamic EQ を
//       `"bs": [{"en":…,"ft":…}, …]` と書くのに `"en": [...]` と書いていたので、
//       (a) 段の入切も `en` なので shortForm の上書きで潰れ、
//       (b) 同梱プリセットも web 版も読めなかった。
//       objectArrayKey を持つのは params.json 8 本・57 フィールド。
//    2. 保存値と表示値がずれるもの（Tilt EQ の Pivot は自然対数）が素通しだった。
//       こちらは ETParamScale が持つ。
//
//  形式の出典: js/utils/serialization-utils.js:13-106

import Foundation

enum ETParamCoding {

    // MARK: - 書く

    /// float の並び → 保存形式の辞書。キーは params.json の `key`。
    ///
    /// objectArrayKey を持つものは外側の名前でまとめて
    /// `[{member: value, …}, …]` の形にする。
    static func encode(params: [ETParam], values: [Float]) -> [String: Any] {
        var o: [String: Any] = [:]
        // 外側の名前ごとに、要素 i の辞書を積む。
        var objects: [String: [[String: Any]]] = [:]

        for p in params {
            guard values.indices.contains(p.offset) else { continue }

            if p.isObjectMember, let group = p.objectArrayKey, let member = p.memberKey {
                var rows = objects[group] ?? []
                if rows.count < p.count {
                    rows.append(contentsOf: Array(repeating: [:], count: p.count - rows.count))
                }
                for i in 0..<p.count {
                    let k = p.offset + i
                    guard values.indices.contains(k) else { continue }
                    rows[i][member] = tidy(values[k], p)
                }
                objects[group] = rows
            } else if let key = p.flatArrayKey {
                o[key] = (0..<p.count).map { i in
                    let k = p.offset + i
                    return tidy(values.indices.contains(k) ? values[k] : p.defaultValue, p)
                }
            } else if p.isArray {
                // **添字を付けて 1 本ずつ書く。** `"f": [...]` ではなく `f0 f1 f2 …`。
                // 上流は params['f' + i] で書き、同じ形でしか読まない
                // （plugins/eq/five_band_peq.js:321-329 の getParameters）。
                // 平らな配列で書いていたので、同梱プリセットも共有リンクも
                // 一つも読めず、5Band PEQ が既定のまま＝曲線が平坦になっていた。
                for i in 0..<p.count {
                    let k = p.offset + i
                    guard values.indices.contains(k) else { continue }
                    o[p.key + String(i)] = tidy(values[k], p)
                }
            } else {
                o[p.key] = tidy(values[p.offset], p)
            }
        }

        for (group, rows) in objects { o[group] = rows }
        return o
    }

    /// enum は選択肢の文字列、bool は真偽、整数は Int で書く。
    /// EffeTune はそう書いているので、数値のまま書くと web 版で読めない。
    static func tidy(_ v: Float, _ p: ETParam) -> Any {
        switch p.kind {
        case .toggle:
            return v >= 0.5
        case .enumeration(let values):
            let i = Int(v.rounded())
            return values.indices.contains(i) ? values[i] : i
        case .number(_, _, _, _, let isInteger):
            return isInteger ? Int(v.rounded()) : v
        }
    }

    // MARK: - 読む

    /// 保存形式の辞書 → float の並び。無い項目は `defaults` のまま残す。
    static func decode(params: [ETParam], defaults: [Float],
                       from dict: [String: Any]) -> [Float] {
        var values = defaults

        for p in params {
            if let key = p.flatArrayKey {
                if let array = dict[key] as? [Any] {
                    for (i, item) in array.prefix(p.count).enumerated() {
                        let k = p.offset + i
                        if values.indices.contains(k) { values[k] = number(item, p) }
                    }
                }
                continue
            }
            // オブジェクト配列。上流・同梱プリセット・いまの保存形式はこちら。
            if p.isObjectMember, let group = p.objectArrayKey, let member = p.memberKey,
               let rows = dict[group] as? [[String: Any]] {
                for (i, row) in rows.enumerated() where i < p.count {
                    guard let item = row[member] else { continue }
                    let k = p.offset + i
                    if values.indices.contains(k) { values[k] = number(item, p) }
                }
                continue
            }

            // 添字付き。上流・同梱プリセット・共有リンクはこの形。
            if p.isArray, !p.isObjectMember {
                var hit = false
                for i in 0..<p.count {
                    guard let item = dict[p.key + String(i)] else { continue }
                    hit = true
                    let k = p.offset + i
                    if values.indices.contains(k) { values[k] = number(item, p) }
                }
                if hit { continue }
            }

            guard let raw = dict[p.key] else { continue }

            if p.isArray, let arr = raw as? [Any] {
                // 古い保存（平らな配列で書いていた頃）だけがここへ来る。
                // 読めなくして作った鎖を失わないために残す。書くのはもうしない。
                for (i, item) in arr.enumerated() where i < p.count {
                    let k = p.offset + i
                    if values.indices.contains(k) { values[k] = number(item, p) }
                }
            } else if p.isObjectMember {
                // **単体の値は取らない。**
                // `en` の平らな値は**段の入切**であってバンドの入切ではない。
                // 入れるとバンド 1 だけが段の値に化け、残りが既定へ戻る。
                continue
            } else if values.indices.contains(p.offset) {
                values[p.offset] = number(raw, p)
            }
        }
        return values
    }

    /// 保存形式の値 → float。enum は選択肢の添字、bool は 0/1。
    ///
    /// **順番を変えないこと。** Darwin では NSNumber(0/1) が `as? Bool` に通るので、
    /// Bool を先に見る。逆にすると toggle が 0/1 のまま素通りする。
    static func number(_ raw: Any, _ p: ETParam) -> Float {
        if let b = raw as? Bool { return b ? 1 : 0 }
        if let n = raw as? NSNumber { return n.floatValue }
        if let s = raw as? String {
            if case .enumeration(let values) = p.kind, let i = values.firstIndex(of: s) {
                return Float(i)
            }
            return Float(s) ?? p.defaultValue
        }
        return p.defaultValue
    }
}
