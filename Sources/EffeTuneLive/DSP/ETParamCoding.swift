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
    ///
    /// `type` は上流のプラグイン名。ETAllowedValues を引くのに使う。
    /// **許されない値は捨てて `defaults` の値を残す。** 上流の
    /// isAllowedEnum(value, allowed, previous)（plugins/plugin-base.js:1196-1198）と同じ。
    static func decode(params: [ETParam], defaults: [Float],
                       from dict: [String: Any], type: String = "") -> [Float] {
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
                let v = number(raw, p)
                if let allowed = ETAllowedValues.upstream(type: type, key: p.key),
                   !allowed.contains(v) {
                    continue
                }
                values[p.offset] = v
            }
        }
        return ETUpstreamNormalize.apply(type: type, params: params, previous: defaults,
                                         values: values, from: dict)
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

/// 決まった値しか取らない数。`型名.key` で引く。
///
/// **kind は .number のまま。** .enumeration にすると DSP へ選択肢の添字が渡り、
/// JSON には文字列が書かれる（上の tidy）。上流は数のまま書き、数のまま読む。
/// EffectCatalog.swift は生成物なので印を足せない。ETSliderScale と同じく表をここに持つ。
///
/// 置き場所が ParameterRow.swift でないのは、decode がこの表を引くから。
/// 単体テストのバンドルはこのファイルを直に建てるが、ParameterRow は入っていない。
///
/// Oversampling はどれも 1x が先頭。許されない値はカーネルが黙って 1x で処理する
/// （dsp/include/effetune/dsp/oversampled_shaper.h:16-22、
///  brickwall_limiter/kernel.cpp:209-211）。
enum ETAllowedValues {
    static func upstream(type: String, key: String) -> [Float]? {
        table[type + "." + key]
    }

    private static let table: [String: [Float]] = [
        // plugins/saturation/*.js の setParameters が isAllowedEnum で通す値。
        // saturation.js:112、dynamic_saturation.js:165、exciter.js:172、
        // harmonic_distortion.js:132、multiband_saturation.js:435。
        "SaturationPlugin.os": [1, 2, 4, 8],
        "DynamicSaturationPlugin.os": [1, 2, 4, 8],
        "ExciterPlugin.os": [1, 2, 4, 8],
        "HarmonicDistortionPlugin.os": [1, 2, 4, 8],
        "MultibandSaturationPlugin.os": [1, 2, 4, 8],
        // hard_clipping.js:167。カーネルも factor(os, 16) で 16 まで取る。
        "HardClippingPlugin.os": [1, 2, 4, 8, 16],
        // brickwall_limiter.js:735-738（他の値は例外で弾く）。
        // カーネルの normalizedOversampling も 2/4/8 以外は 1。
        "BrickwallLimiterPlugin.os": [1, 2, 4, 8],
    ]
}

/// 上流の setParameters が読み込みのときに直す値。型名で引く。
///
/// decode は保存形式の数をそのまま並べるが、上流は setParameters で範囲へ寄せたり
/// 前の値へ戻したりしてからカーネルへ渡す。**カーネルが値 1 つで設定ごと捨てる型**
/// （Bass Management は素通しになる。dsp/plugins/basics/bass_management/kernel.cpp:41-58）
/// だけ、ここで上流と同じ所へ着地させる。`previous` は decode の `defaults`。
enum ETUpstreamNormalize {
    static func apply(type: String, params: [ETParam], previous: [Float],
                      values: [Float], from dict: [String: Any]) -> [Float] {
        switch type {
        case "BassManagementPlugin":
            return bassManagement(params: params, previous: previous, values: values, from: dict)
        default:
            return values
        }
    }

    /// plugins/basics/bass_management.js:142-179 の setParameters。
    private static func bassManagement(params: [ETParam], previous: [Float],
                                       values input: [Float],
                                       from dict: [String: Any]) -> [Float] {
        var values = input
        func param(_ key: String) -> ETParam? { params.first { $0.key == key } }
        func old(_ k: Int) -> Float { previous.indices.contains(k) ? previous[k] : 0 }
        /// 各位置を直す。nil なら前の値（_validatedArray の previous）。
        func fix(_ key: String, _ normalize: (Float) -> Float?) {
            guard let p = param(key) else { return }
            for k in p.offset..<(p.offset + p.count) where values.indices.contains(k) {
                values[k] = normalize(values[k]) ?? old(k)
            }
        }
        /// parseFiniteNumber（plugin-base.js:1174-1194）。数でなければ前の値、外なら端。
        func finite(_ low: Float, _ high: Float) -> (Float) -> Float? {
            { $0.isFinite ? min(max($0, low), high) : nil }
        }
        let slopes: Set<Float> = [24, 48, 96]
        let slope: (Float) -> Float? = { v in
            let r = v.rounded()
            return slopes.contains(r) ? r : nil
        }
        /// Number.isSafeInteger（|x| ≤ 2^53 - 1）を通れば 0〜65535 に寄せる。
        let mask: (Float) -> Float? = { v in
            let r = v.rounded()
            return r.isFinite && abs(r) < 0x1p53 ? min(max(r, 0), 65535) : nil
        }

        // ph は綴りだけ（:146）。tp は String(params.tp) で引くので、数の 8192 も通る（:147）。
        for (key, acceptsNumbers) in [("ph", false), ("tp", true)] {
            guard let p = param(key), case .enumeration(let options) = p.kind,
                  values.indices.contains(p.offset), let raw = dict[key] else { continue }
            var spelled = raw as? String
            if spelled == nil, acceptsNumbers, !(raw is Bool), let n = raw as? NSNumber {
                let d = n.doubleValue
                if d.isFinite, d == d.rounded(), abs(d) < 1e15 { spelled = String(Int64(d)) }
            }
            if let spelled, let i = options.firstIndex(of: spelled) {
                values[p.offset] = Float(i)
            } else {
                values[p.offset] = old(p.offset)
            }
        }
        fix("ro") { v in
            let r = v.rounded()
            return r >= 0 && r <= 3 ? r : nil
        }
        fix("fc") { finite(20, 300)($0)?.rounded() }
        fix("sl", slope)
        fix("rt", mask)
        fix("ri", mask)
        // :166-168。位相を返す bit は送り先の部分集合に限る。
        if let rt = param("rt"), let ri = param("ri") {
            for ch in 0..<min(rt.count, ri.count)
            where values.indices.contains(rt.offset + ch) && values.indices.contains(ri.offset + ch) {
                let bits = { (v: Float) -> Int in v.isFinite ? Int(min(max(v, 0), 65535)) : 0 }
                values[ri.offset + ch] = Float(bits(values[ri.offset + ch]) & bits(values[rt.offset + ch]))
            }
        }
        fix("su", mask)
        fix("lf") { finite(20, 300)($0)?.rounded() }
        fix("ls", slope)
        fix("bg", finite(-24, 12))
        fix("lg", finite(-24, 12))
        fix("hg", finite(-24, 0))
        return values
    }
}
