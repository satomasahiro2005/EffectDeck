//  PipelineStore.swift
//  鎖の保存と読み込み。EffeTune と同じ形式で書く。
//
//  EffeTune には2つの形式がある。
//
//  ロング形式（`.effetune_preset` ファイル、Electron の pipeline-state.json）:
//      { "pipeline": [ { "name": "5Band PEQ", "enabled": true,
//                        "parameters": { "f0": 100, ... },
//                        "inputBus": 1, "outputBus": 2, "channel": "L" } ] }
//
//  ショート形式（共有リンク `?p=`、クリップボード、ユーザープリセット）:
//      [ { "f0": 100, ..., "nm": "5Band PEQ", "en": true, "ib": 1, "ob": 2, "ch": "L" } ]
//      パラメータがトップレベルへ直接展開され、配列そのものが根になる。
//
//  どちらも:
//    - `name` / `nm` は**表示名**（空白入り）。クラス名ではない
//    - パラメータのキーは params.json の `key`（`vl` など）。C++ のメンバ名ではない
//    - `inputBus` / `outputBus` / `channel` は null のとき**キーごと出さない**
//
//  出典: js/utils/serialization-utils.js:13-106

import Foundation
import os

enum PipelineStore {

    private static let log = Logger(subsystem: "ai.nemut.effetune", category: "store")

    // MARK: - 書く

    /// ショート形式。共有リンクとプリセットに使う。
    static func shortForm(_ chain: [EffeTuneDSP.Node]) -> [[String: Any]] {
        chain.map { node in
            var o: [String: Any] = parameters(of: node)
            o["nm"] = node.spec.name
            o["en"] = node.enabled
            if node.inputBus  != 0 { o["ib"] = Int(node.inputBus) }
            if node.outputBus != 0 { o["ob"] = Int(node.outputBus) }
            if let ch = ETChannel.channel(from: node.channelSpec) { o["ch"] = ch }
            return o
        }
    }

    /// ロング形式。ファイルに書き出すときに使う。
    static func longForm(_ chain: [EffeTuneDSP.Node]) -> [String: Any] {
        let list: [[String: Any]] = chain.map { node in
            var o: [String: Any] = [
                "name": node.spec.name,
                "enabled": node.enabled,
                "parameters": parameters(of: node),
            ]
            if node.inputBus  != 0 { o["inputBus"] = Int(node.inputBus) }
            if node.outputBus != 0 { o["outputBus"] = Int(node.outputBus) }
            if let ch = ETChannel.channel(from: node.channelSpec) { o["channel"] = ch }
            return o
        }
        return ["pipeline": list]
    }

    /// パラメータを保存形式へ。キーは params.json の `key`。
    /// 配列は EffeTune 側の持ち方に合わせきれていないので、いまは先頭だけ書く
    /// （読み込み側も同じ扱いなので往復はする）。
    private static func parameters(of node: EffeTuneDSP.Node) -> [String: Any] {
        var o: [String: Any] = [:]
        for p in node.spec.params {
            guard node.values.indices.contains(p.offset) else { continue }
            if p.isArray {
                let slice = (0..<p.count).compactMap { i -> Float? in
                    let k = p.offset + i
                    return node.values.indices.contains(k) ? node.values[k] : nil
                }
                o[p.key] = slice.map { tidy($0, p) }
            } else {
                o[p.key] = tidy(node.values[p.offset], p)
            }
        }
        return o
    }

    /// enum は選択肢の文字列、bool は真偽、整数は Int で書く。
    /// EffeTune はそう書いているので、数値のまま書くと web 版で読めない。
    private static func tidy(_ v: Float, _ p: ETParam) -> Any {
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

    struct Loaded {
        let spec: ETEffect
        var values: [Float]
        var enabled: Bool
        var inputBus: UInt8
        var outputBus: UInt8
        var channelSpec: Int8
    }

    /// ロングでもショートでも受ける。根が配列ならショート、
    /// 辞書で `pipeline` を持っていればロング。
    static func parse(_ json: Any, catalog: [ETEffect]) -> [Loaded] {
        let list: [[String: Any]]
        if let a = json as? [[String: Any]] {
            list = a
        } else if let d = json as? [String: Any], let a = d["pipeline"] as? [[String: Any]] {
            list = a
        } else {
            return []
        }

        let byName = Dictionary(catalog.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [Loaded] = []

        for entry in list {
            let isLong = entry["name"] != nil
            let name = (entry["name"] ?? entry["nm"]) as? String ?? ""
            guard let spec = byName[name] else {
                log.notice("知らないエフェクト \(name, privacy: .public)")
                continue
            }

            let params: [String: Any] = isLong
                ? (entry["parameters"] as? [String: Any] ?? [:])
                : entry

            var values = spec.defaults
            for p in spec.params {
                guard let raw = params[p.key] else { continue }
                if p.isArray, let arr = raw as? [Any] {
                    for (i, item) in arr.enumerated() where i < p.count {
                        let k = p.offset + i
                        if values.indices.contains(k) { values[k] = number(item, p) }
                    }
                } else if values.indices.contains(p.offset) {
                    values[p.offset] = number(raw, p)
                }
            }

            let ch = (entry["channel"] ?? entry["ch"]) as? String
            out.append(Loaded(
                spec: spec,
                values: values,
                enabled: (entry["enabled"] ?? entry["en"]) as? Bool ?? true,
                inputBus: UInt8(clamping: (entry["inputBus"] ?? entry["ib"]) as? Int ?? 0),
                outputBus: UInt8(clamping: (entry["outputBus"] ?? entry["ob"]) as? Int ?? 0),
                channelSpec: ETChannel.spec(from: ch)))
        }
        return out
    }

    private static func number(_ raw: Any, _ p: ETParam) -> Float {
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

    // MARK: - 端末に残す

    private static let lastKey = "pipeline.last"

    static func saveLast(_ chain: [EffeTuneDSP.Node]) {
        guard let data = try? JSONSerialization.data(withJSONObject: shortForm(chain)) else { return }
        UserDefaults.standard.set(data, forKey: lastKey)
    }

    static func loadLast(catalog: [ETEffect]) -> [Loaded]? {
        guard let data = UserDefaults.standard.data(forKey: lastKey),
              let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return parse(json, catalog: catalog)
    }

    static var hasSaved: Bool {
        UserDefaults.standard.data(forKey: lastKey) != nil
    }
}
