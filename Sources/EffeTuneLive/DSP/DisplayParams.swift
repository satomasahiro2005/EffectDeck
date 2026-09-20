//  DisplayParams.swift
//  音に関わらない表示の設定で、**上流がプリセットに書いているもの**。
//
//  上流は getParameters() でこれらを返している:
//      note_spectrogram.js:155-169   cl / pr / ly / vl / ts
//      spectrogram.js:345-356        sc
//      spectrum_analyzer.js:276-288  sc / dm
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
            return ["sc": .text]
        case "SpectrumAnalyzerPlugin":
            return ["sc": .text, "dm": .text]
        default:
            return [:]
        }
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
