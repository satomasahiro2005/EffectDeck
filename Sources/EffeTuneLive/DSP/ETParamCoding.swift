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
            guard values.indices.contains(p.offset), !p.runtimeOnly else { continue }

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
    ///
    /// **どの Float でも落ちず、JSON に書ける値を返す。**
    /// - NaN・無限は JSON に書けない（Darwin の JSONSerialization は投げずに例外で落ちる。
    ///   共有リンクを作る ETShareLink.link がそこを通る）。既定の値を書く
    /// - Int(_:) は Int の外で落ちる。Int にするのは JS の安全な整数（2^53 未満）までで、
    ///   その外は数のまま書く（上流の JS は整数と小数を分けない）
    /// Tests/Fuzz の pipelineform が見つけた（FuzzFindingsTests）。
    static func tidy(_ v: Float, _ p: ETParam) -> Any {
        guard v.isFinite else { return p.defaultValue.isFinite ? tidy(p.defaultValue, p) : 0 }
        let r = v.rounded()
        let whole: Any = abs(r) < 0x1p53 ? Int(r) : r
        switch p.kind {
        case .toggle:
            return v >= 0.5
        case .enumeration(let values):
            if let i = whole as? Int, values.indices.contains(i) { return values[i] }
            return whole
        case .number(_, _, _, _, let isInteger):
            return isInteger ? whole : v
        }
    }

    // MARK: - 読む

    /// 保存形式の辞書 → float の並び。無い項目は `defaults` のまま残す。
    ///
    /// `type` は上流のプラグイン名。ETAllowedValues を引くのに使う。
    /// **許されない値は捨てて `defaults` の値を残す。** 上流の
    /// isAllowedEnum(value, allowed, previous)（plugins/plugin-base.js:1196-1198）と同じ。
    /// NaN・無限も同じく捨てる（number が nil を返す）。
    ///
    /// **返す値はどれも ±magnitudeLimit の中に収める**（最後の bounded）。
    /// 範囲の外の数は寄せない設計だが、Int に入らない大きさ（1e30）まで通すと、
    /// 画面が生の値を Int(_:) にしたところでアプリごと落ちる（ChannelDividerView の bandCount、
    /// ParameterRow の選択肢・整数の表示など）。tidy は落ちないので、その値は保存にも残る。
    /// 寄せるのは ETUpstreamNormalize の後。Bass Management の rt・ri・su は
    /// 2^53 以上を「前の値」に戻す（上流の Number.isSafeInteger）ので、先に寄せると変わる。
    static func decode(params: [ETParam], defaults: [Float],
                       from dict: [String: Any], type: String = "") -> [Float] {
        var values = defaults

        for p in params {
            if p.runtimeOnly { continue }
            if let key = p.flatArrayKey {
                if let array = dict[key] as? [Any] {
                    for (i, item) in array.prefix(p.count).enumerated() {
                        let k = p.offset + i
                        if values.indices.contains(k), let v = number(item, p) { values[k] = v }
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
                    if values.indices.contains(k), let v = number(item, p) { values[k] = v }
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
                    if values.indices.contains(k), let v = number(item, p) { values[k] = v }
                }
                if hit { continue }
            }

            guard let raw = dict[p.key] else { continue }

            if p.isArray, let arr = raw as? [Any] {
                // 古い保存（平らな配列で書いていた頃）だけがここへ来る。
                // 読めなくして作った鎖を失わないために残す。書くのはもうしない。
                for (i, item) in arr.enumerated() where i < p.count {
                    let k = p.offset + i
                    if values.indices.contains(k), let v = number(item, p) { values[k] = v }
                }
            } else if p.isObjectMember {
                // **単体の値は取らない。**
                // `en` の平らな値は**段の入切**であってバンドの入切ではない。
                // 入れるとバンド 1 だけが段の値に化け、残りが既定へ戻る。
                continue
            } else if values.indices.contains(p.offset) {
                guard let v = number(raw, p) else { continue }
                if let allowed = ETAllowedValues.upstream(type: type, key: p.key),
                   !allowed.contains(v) {
                    continue
                }
                values[p.offset] = v
            }
        }
        return ETUpstreamNormalize.apply(type: type, params: params, previous: defaults,
                                         values: values, from: dict).map(bounded)
    }

    /// decode が返す値の大きさの上限。2^24。
    /// Float が整数をすべて正確に持てる上限で、catalog の範囲の端でいちばん大きい
    /// 100000 の 160 倍余り。これより内なら、画面が Int(_:) にして何倍かしても落ちない。
    static let magnitudeLimit: Float = 0x1p24

    /// ±magnitudeLimit へ寄せる。
    static func bounded(_ v: Float) -> Float {
        min(max(v, -magnitudeLimit), magnitudeLimit)
    }

    /// 保存形式の値 → float。enum は選択肢の添字、bool は 0/1。
    ///
    /// **順番を変えないこと。** Darwin では NSNumber(0/1) が `as? Bool` に通るので、
    /// Bool を先に見る。逆にすると toggle が 0/1 のまま素通りする。
    ///
    /// **NaN・無限は nil**（decode はその位置に `defaults` の値を残す）。Float に収まらない数
    /// （1e39）は floatValue で無限になり、Float(_:) は "nan" "inf" の字を NaN・無限として読む。
    /// そのまま鎖に入ると DSP へ渡り、書き戻す shortForm が JSON に書けなくなっていた
    /// （Tests/Fuzz の pipelineform。FuzzFindingsTests）。
    /// catalog の既定でなく `defaults` を残すのは、プリセットを当てるとき（EffectPresetApply）
    /// の `defaults` が今の値だから。上流の parseFiniteNumber（plugin-base.js:1174-1194）も
    /// 数でないものは前の値に戻す。
    /// 数と読めない字・型は今までどおり catalog の既定。範囲の外の有限の数もそのまま
    /// （寄せるのは貼られた字だけ。ETChainText.prepare。大きさの上限は decode の bounded）。
    static func number(_ raw: Any, _ p: ETParam) -> Float? {
        let v: Float
        if let b = raw as? Bool { return b ? 1 : 0 }
        if let n = raw as? NSNumber {
            v = n.floatValue
        } else if let s = raw as? String {
            if case .enumeration(let values) = p.kind, let i = values.firstIndex(of: s) {
                return Float(i)
            }
            guard let f = Float(s) else { return p.defaultValue }
            v = f
        } else {
            return p.defaultValue
        }
        return v.isFinite ? v : nil
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
        case "RhythmAnalyzerPlugin":
            return rhythmAnalyzer(params: params, previous: previous, values: values, from: dict)
        case "TonalBalanceEQPlugin":
            return tonalBalance(params: params, previous: previous, values: values)
        case "AdaptivePredictionEffectPlugin":
            return adaptivePrediction(params: params, values: values, from: dict)
        case "SFZNotePlayerPlugin":
            return sfzNotePlayer(params: params, values: values)
        default:
            return values
        }
    }

    /// plugins/resonator/adaptive_prediction_effect.js:110-130 の setParameters（Weight Decay）。
    /// 0 は無限大（減衰しない）で、0 より大きく 0.5 未満は 0.5 にする。画面の目盛りも 0.5 から。
    /// resetToken は runtimeOnly なので decode が読まない（Reset を押すたびに変わる実行時の数）。
    private static func adaptivePrediction(params: [ETParam], values input: [Float],
                                           from dict: [String: Any]) -> [Float] {
        var values = input
        guard dict["weightDecay"] != nil,
              let p = params.first(where: { $0.key == "weightDecay" }),
              values.indices.contains(p.offset) else { return values }
        let v = values[p.offset]
        if v.isFinite, v > 0, v < 0.5 { values[p.offset] = 0.5 }
        return values
    }

    /// plugins/others/sfz_note_player.js:45-60 の setParameters。各鍵を params.json の範囲へ寄せ
    /// （parseFiniteNumber の min / max）、Lowest / Highest Note・Max Voices・Octave は整数に丸め、
    /// そのあとで Highest Note は Lowest Note より下にせず、Velocity 127 Level は Velocity 1 Level より
    /// 1 dB 以上上にする。寄せる前に比べると、範囲の外の値で上流と違う所に着地する
    /// （vf: 5, vc: -10 は、上流は vf を 0 に寄せてから vc を 1 にする）。
    /// ほかの鍵が来なくても毎回かける（上流と同じ）。
    private static func sfzNotePlayer(params: [ETParam], values input: [Float]) -> [Float] {
        var values = input
        for key in ["mn", "mx", "pl", "os", "vf", "vc"] {
            guard let p = params.first(where: { $0.key == key }), values.indices.contains(p.offset),
                  values[p.offset].isFinite else { continue }
            var v = values[p.offset]
            if case .number(let lo, let hi, _, _, _) = p.kind { v = min(max(v, lo), hi) }
            // **Int(_:) にしない。**ここの値は bounded の前で、1e30 も来る（Int の外で落ちる）。
            // 丸めは JS の Math.round（.5 は +∞ 側。-1.5 は -1）。
            if key != "vf", key != "vc" { v = (v + 0.5).rounded(.down) }
            values[p.offset] = v
        }
        return sfzCrossRules(params: params, values: values)
    }

    /// SFZ Note Player の鍵どうしの規則だけ（sfz_note_player.js:59-60）。画面からの編集にも同じものをかける
    /// （上流は slider を動かすたびに setParameters を通る）。
    static func sfzCrossRules(params: [ETParam], values input: [Float]) -> [Float] {
        var values = input
        func index(_ key: String) -> Int? {
            guard let p = params.first(where: { $0.key == key }),
                  values.indices.contains(p.offset) else { return nil }
            return p.offset
        }
        if let mn = index("mn"), let mx = index("mx"), values[mn] > values[mx] {
            values[mx] = values[mn]
        }
        if let vf = index("vf"), let vc = index("vc"), values[vc] < values[vf] + 1 {
            values[vc] = values[vf] + 1
        }
        return values
    }

    /// plugins/analyzer/rhythm_analyzer.js:167-178 の setParameters（Min / Max BPM）。
    /// 規則は ETRhythmBPMRange（RhythmAnalyzerModel.swift）が持つ。カーネルも同じ規則で
    /// 狭すぎる範囲を捨てる（kMinimumSpan = 1.25）ので、読み込みの時点で上流と同じ所へ着地させる。
    private static func rhythmAnalyzer(params: [ETParam], previous: [Float],
                                       values input: [Float],
                                       from dict: [String: Any]) -> [Float] {
        var values = input
        guard let mn = params.first(where: { $0.key == "mn" }),
              let mx = params.first(where: { $0.key == "mx" }),
              values.indices.contains(mn.offset), values.indices.contains(mx.offset),
              previous.indices.contains(mn.offset), previous.indices.contains(mx.offset) else {
            return values
        }
        let range = ETRhythmBPMRange.normalize(
            previousMin: Double(previous[mn.offset]), previousMax: Double(previous[mx.offset]),
            requestedMin: dict["mn"] == nil ? nil : Double(values[mn.offset]),
            requestedMax: dict["mx"] == nil ? nil : Double(values[mx.offset]))
        values[mn.offset] = Float(range.min)
        values[mx.offset] = Float(range.max)
        return values
    }

    /// plugins/eq/tonal_balance_eq.js:326-337 の setParameters。**シェルフ（ls / hs）の Q は
    /// 2 までで、型を変えれば寄せ直す。** peaking だけが 10 まで。カーネルも同じ上限で寄せる。
    /// 数でない値は前の値のまま（parseFiniteNumber）。
    private static func tonalBalance(params: [ETParam], previous: [Float],
                                     values input: [Float]) -> [Float] {
        var values = input
        guard let type = params.first(where: { $0.key == "ta" }),
              let q = params.first(where: { $0.key == "qa" }) else { return values }
        for band in 0..<min(type.count, q.count) {
            let t = type.offset + band, k = q.offset + band
            guard values.indices.contains(t), values.indices.contains(k) else { continue }
            // **Int(_:) にしない。**ここの値は bounded の前で、1e30 も来る（Int の外で落ちる）。
            // 0 = pk、それ以外 = ls / hs。
            let shelf = values[t].rounded() != 0
            let old = previous.indices.contains(k) ? previous[k] : q.defaultValue
            values[k] = values[k].isFinite ? min(max(values[k], 0.1), shelf ? 2 : 10) : old
        }
        return values
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
