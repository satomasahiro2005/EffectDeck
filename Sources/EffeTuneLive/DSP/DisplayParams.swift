//  DisplayParams.swift
//  音に関わらない表示の設定で、**上流がプリセットに書いているもの**。
//
//  上流は getParameters() でこれらを返している（v2.11.0 の行）:
//      note_spectrogram.js:190-204   cl / pr / ly / vl / ts
//      spectrogram.js:364-376        cl / kb / sc
//      spectrum_analyzer.js:295-308  kb / sc / dm / cl
//      pitch_meter.js:96-107         ly / cl
//      stereo_meter.js:271-279       gn
//      chroma_spiral.js:92-96        dm / lo / hi / ft / lr / df
//      analog_meter.js:295-311       rl / rg / sc / ph / ln / tg / ls（v2.12.0）
//      rhythm_analyzer.js:164-178    sp / vt / vm / ve / vl（v2.12.0。mn / mx / ck は DSP 側。2.13.0 は vt / ve の既定が false）
//  **画面で使っていないもの（kb）も表に入れる。**
//  入れないと web 版から来た値が往復で消える。
//
//  DSP のパラメータではないので params.json に席が無く、こちらの values
//  （float の並び）にも載らない。Section の名前（`cm`）や IR の鍵（`ir`）と
//  同じ立場なので、同じように Node 側へ文字列で持ち、保存形式では
//  **上流と同じ綴り**で書く。だからプリセットにも共有リンクにも乗り、
//  web 版と行き来しても消えない。
//
//  **上流が書いていないものはここに入れない。**バンドの選択などは
//  端末の中だけの覚えなので ETCardSelection のまま（あちらは畳んでも消えないが、
//  アプリを終うと消える。上流に席が無いので、それで筋が通る）。
//
//  値は文字列で持つ。float に載らないものを運ぶのが目的なので、
//  型は書き出すときにだけ上流のものへ戻す。

import Foundation

enum ETDisplayParam {

    /// 上流の JSON でどの型で書かれているか。
    enum Kind {
        case text
        case number
        case flag
    }

    /// その型が持つ表示の設定。持たないものは空。
    static func table(for type: String) -> [String: Kind] {
        switch type {
        case "NoteSpectrogramPlugin":
            return ["cl": .text, "pr": .text, "ly": .text, "vl": .flag, "ts": .number]
        case "SpectrogramPlugin":
            return ["sc": .text, "cl": .text, "kb": .flag]
        case "SpectrumAnalyzerPlugin":
            return ["sc": .text, "dm": .text, "cl": .text, "kb": .flag]
        case "PitchMeterPlugin":
            return ["ly": .text, "cl": .text]
        case "StereoMeterPlugin":
            return ["gn": .number]
        case "ChromaSpiralPlugin":
            // dm はここでは数（0/1/2）。上流は `=== 0` で比べる（chroma_spiral.js:103）。
            return ["dm": .number, "lo": .number, "hi": .number,
                    "ft": .number, "lr": .number, "df": .number]
        case "AnalogMeterPlugin":
            // 全部数。sc（PPM Scale 0/1/2）・ln（Needle 0/1）・ls（Scale 0/1）は
            // 上流が数のまま持つ（analog_meter.js:14-16、:323-336 の Number.isInteger・=== 0/1）。
            // 保存形式で文字にすると上流は読まない。
            return ["rl": .number, "rg": .number, "sc": .number, "ph": .number,
                    "ln": .number, "tg": .number, "ls": .number]
        case "RhythmAnalyzerPlugin":
            // sp は 4/6/8/12/16 のどれか（上流は最寄りへ寄せる、rhythm_analyzer.js:10・:179-187）。
            return ["sp": .number, "vt": .flag, "vm": .flag, "ve": .flag, "vl": .flag]
        default:
            return [:]
        }
    }

    /// 上流の既定（constructor の値）。**プリセットとの一致を見るために持つ**
    /// （display に鍵が無いのは「触っていない＝既定」）。持つのは、プリセットが表示の設定を運ぶ型だけ。
    /// Analog Meter の 17 個の出荷時プリセットは、Mode のほかは全部この表示の設定の違い
    /// （analog_meter.js:15-17 の ANALOG_METER_DEFAULTS と 26-46 の analogMeterPreset）。
    static func defaults(for type: String) -> [String: String] {
        switch type {
        case "AnalogMeterPlugin":
            return ["rl": "-14.0", "rg": "40.0", "sc": "0.0", "ph": "1.0",
                    "ln": "0.0", "tg": "-23.0", "ls": "0.0"]
        case "RhythmAnalyzerPlugin":
            // 2.13.0 で Tempogram と Echo rows は既定で隠す（rhythm_analyzer.js の RHYTHM_ANALYZER_DEFAULTS）。
            return ["sp": "8.0", "vt": "false", "vm": "true", "ve": "false", "vl": "true"]
        default:
            return [:]
        }
    }

    /// プリセットの表示の設定が、いまの display と一致するか。
    /// 上流の一致は「プリセットが書いた鍵だけ」を比べる（plugin-preset-dialog.js:64-72）。
    /// 既定を持たない型・鍵は比べない（比べられないものを不一致にしない）。
    static func matches(_ presetParams: [String: Any], display: [String: String], type: String) -> Bool {
        let fallback = defaults(for: type)
        for (key, kind) in table(for: type) {
            guard let raw = presetParams[key], let want = decode(raw, kind: kind),
                  let have = display[key] ?? fallback[key] else { continue }
            switch kind {
            case .number:
                guard let a = Double(want), let b = Double(have), abs(a - b) < 1e-9 else { return false }
            default:
                if want != have { return false }
            }
        }
        return true
    }

    /// 持っている文字列を、上流の型へ。
    static func encode(_ raw: String, kind: Kind) -> Any {
        switch kind {
        case .text:   return raw
        case .number: return Double(raw) ?? 0
        case .flag:   return raw == "true"
        }
    }

    /// 上流の JSON から文字列へ。読めないものは nil にして、既定のままにする。
    static func decode(_ any: Any, kind: Kind) -> String? {
        switch kind {
        case .text:
            return any as? String
        case .number:
            if let d = any as? Double { return String(d) }
            if let i = any as? Int { return String(Double(i)) }
            if let n = any as? NSNumber { return String(n.doubleValue) }
            return nil
        case .flag:
            if let b = any as? Bool { return b ? "true" : "false" }
            if let n = any as? NSNumber { return n.boolValue ? "true" : "false" }
            return nil
        }
    }

    /// 保存形式へ足す。
    static func write(_ display: [String: String], type: String,
                      into o: inout [String: Any]) {
        for (key, kind) in table(for: type) {
            guard let raw = display[key] else { continue }
            o[key] = encode(raw, kind: kind)
        }
    }

    /// 保存形式から読む。
    static func read(_ params: [String: Any], type: String) -> [String: String] {
        var out: [String: String] = [:]
        for (key, kind) in table(for: type) {
            guard let any = params[key], let raw = decode(any, kind: kind) else { continue }
            out[key] = raw
        }
        return out
    }
}
