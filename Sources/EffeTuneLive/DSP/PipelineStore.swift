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
//  Section も同じ形で入る。表示名は "Section"、パラメータはセクション名の `cm` ひとつ:
//      ショート  { "cm": "Drums", "nm": "Section", "en": true }
//      ロング    { "name": "Section", "enabled": true, "parameters": { "cm": "Drums" } }
//  上流は `cm` を常に書く（plugins/control/section.js の getParameters）ので、
//  空でもキーごと落とさない。ib/ob/ch は Section が持たないので出ない。
//
//  出典: js/utils/serialization-utils.js:13-106、plugins/control/section.js

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

    /// パラメータを保存形式へ。中身は ETParamCoding が持つ。
    ///
    /// **EffeTuneDSP に触らない形で切り出してある。** オブジェクト配列の扱いを
    /// 何度も読み違えたので、Tests/Unit/ParamCodingTests.swift が実機なしで見張る。
    private static func parameters(of node: EffeTuneDSP.Node) -> [String: Any] {
        // Section は ETParam を持たない。名前は Node 側の文字列なのでここで出す。
        if node.isSection { return [ETSection.commentKey: node.sectionName] }
        var o = ETParamCoding.encode(params: node.spec.params, values: node.values)
        // IR Reverb の素材は float に載らないので、鍵をここで足す。
        // 綴りは上流に合わせて `ir`（ir_reverb.js:866）。
        if !node.irId.isEmpty { o[ETIRLoader.presetKey] = node.irId }
        return o
    }

    // MARK: - 読む

    struct Loaded {
        let spec: ETEffect
        var values: [Float]
        var enabled: Bool
        var inputBus: UInt8
        var outputBus: UInt8
        var channelSpec: Int8
        /// Section の名前（`cm`）。Section 以外では空。
        var sectionName: String = ""
        /// IR Reverb の素材の鍵（`ir`）。それ以外では空。
        var irId: String = ""
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

            let params: [String: Any] = isLong
                ? (entry["parameters"] as? [String: Any] ?? [:])
                : entry

            // Section はカーネルが無いので catalog に載っていない。名前で拾う。
            // ここで落とすと、web 版で作った鎖を取り込んだときに区切りだけ消えて
            // 配下が別のセクションに繰り上がる（次の Section まで、が変わる）。
            if name == ETSection.name {
                out.append(Loaded(
                    spec: ETSection.spec,
                    values: [],
                    enabled: (entry["enabled"] ?? entry["en"]) as? Bool ?? true,
                    inputBus: 0,
                    outputBus: 0,
                    channelSpec: -1,
                    sectionName: params[ETSection.commentKey] as? String ?? ""))
                continue
            }

            guard let spec = byName[name] else {
                log.notice("知らないエフェクト \(name, privacy: .public)")
                continue
            }

            let values = ETParamCoding.decode(params: spec.params,
                                              defaults: spec.defaults,
                                              from: params)

            let ch = (entry["channel"] ?? entry["ch"]) as? String
            out.append(Loaded(
                spec: spec,
                values: values,
                enabled: (entry["enabled"] ?? entry["en"]) as? Bool ?? true,
                inputBus: UInt8(clamping: (entry["inputBus"] ?? entry["ib"]) as? Int ?? 0),
                outputBus: UInt8(clamping: (entry["outputBus"] ?? entry["ob"]) as? Int ?? 0),
                channelSpec: ETChannel.spec(from: ch),
                sectionName: "",
                irId: params[ETIRLoader.presetKey] as? String ?? ""))
        }
        return out
    }

    // MARK: - 端末に残す

    private static let lastKey = "pipeline.last"

    static func saveLast(_ chain: [EffeTuneDSP.Node]) {
        guard let data = try? JSONSerialization.data(withJSONObject: shortForm(chain)) else { return }
        if ETConsoleLog.on {
            let ir = chain.filter { !$0.irId.isEmpty }.count
            let hasKey = String(data: data, encoding: .utf8)?.contains("\"ir\"") ?? false
            print("saveLast bytes=\(data.count) irNodes=\(ir) jsonHasIR=\(hasKey)")
        }
        UserDefaults.standard.set(data, forKey: lastKey)
    }

    static func loadLast(catalog: [ETEffect]) -> [Loaded]? {
        guard let data = UserDefaults.standard.data(forKey: lastKey),
              let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let out = parse(json, catalog: catalog)
        if ETConsoleLog.on {
            let hasKey = String(data: data, encoding: .utf8)?.contains("\"ir\"") ?? false
            print("loadLast bytes=\(data.count) jsonHasIR=\(hasKey) 読めた=\(out.filter { !$0.irId.isEmpty }.count)")
        }
        return out
    }

    static var hasSaved: Bool {
        UserDefaults.standard.data(forKey: lastKey) != nil
    }

    // MARK: - 開いている段

    private static let expandedKey = "pipeline.expanded"

    /// 開いている段を鎖の位置で残す。UUID は起動のたびに作り直されるので使えない。
    /// shortForm には混ぜない。あれは EffeTune の共有リンクと同じ形なので、
    /// 見た目の話を足すと他所で読めなくなる。
    static func saveExpanded(_ indices: [Int]) {
        UserDefaults.standard.set(indices, forKey: expandedKey)
    }

    static func loadExpanded() -> [Int] {
        UserDefaults.standard.array(forKey: expandedKey) as? [Int] ?? []
    }
}
