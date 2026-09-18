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
            if let externalID = node.externalID { o["external"] = externalID }
            if node.inputBus  != 0 { o["ib"] = Int(node.inputBus) }
            if node.outputBus != 0 { o["ob"] = Int(node.outputBus) }
            if let ch = ETChannel.channel(from: node.channelSpec) { o["ch"] = ch }
            return o
        }
    }

    /// 読み込んだ鎖をショート形式へ戻す。取り込みでロング形式のプリセットを
    /// 受けたときに使う（ETBackup.presets(from:catalog:)）。
    ///
    /// 上の `shortForm(_ chain:)` と同じものを出すが、入口が Node ではなく Loaded。
    /// Node を作るには instance が要り、鎖に載せずに作ることはできない。
    static func shortForm(_ loaded: [Loaded]) -> [[String: Any]] {
        loaded.map { item in
            var o: [String: Any]
            if ETSection.isSection(item.spec) {
                // Section は ETParam を持たない（parameters(of:) と同じ扱い）。
                o = [ETSection.commentKey: item.sectionName]
            } else {
                o = ETParamCoding.encode(params: item.spec.params, values: item.values)
                if !item.irId.isEmpty { o[ETIRLoader.presetKey] = item.irId }
            }
            if !item.externalID.isEmpty { o["external"] = item.externalID }
            o["nm"] = item.spec.name
            o["en"] = item.enabled
            if item.inputBus  != 0 { o["ib"] = Int(item.inputBus) }
            if item.outputBus != 0 { o["ob"] = Int(item.outputBus) }
            if let ch = ETChannel.channel(from: item.channelSpec) { o["ch"] = ch }
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
            if let externalID = node.externalID { o["external"] = externalID }
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
        var externalID: String = ""
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
            let externalID = entry["external"] as? String ?? ""

            if !externalID.isEmpty {
                let spec = ETEffect.external(type: "External:(externalID)", name: name,
                                              category: externalID.hasPrefix("jsfx:") ? "JSFX" : "Audio Units")
                out.append(Loaded(spec: spec, values: [],
                                   enabled: (entry["enabled"] ?? entry["en"]) as? Bool ?? true,
                                   inputBus: UInt8(clamping: (entry["inputBus"] ?? entry["ib"]) as? Int ?? 0),
                                   outputBus: UInt8(clamping: (entry["outputBus"] ?? entry["ob"]) as? Int ?? 0),
                                   channelSpec: ETChannel.spec(from: (entry["channel"] ?? entry["ch"]) as? String),
                                   externalID: externalID))
                continue
            }

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

    /// **private ではない。** CloudMirror が iCloud 側を同じ鍵で読む。
    /// 綴りを 2 か所に書くと、片方だけ直したときに黙って別の鍵になる。
    static let lastKey = "pipeline.last"

    static func saveLast(_ chain: [EffeTuneDSP.Node]) {
        // **鍵の並びを固定する。**下の「同じなら書かない」が字面の比較なので、
        // 起動ごとに並びが変わると毎回「違う」と出る。
        guard let data = try? JSONSerialization.data(withJSONObject: shortForm(chain),
                                                     options: [.sortedKeys]) else { return }

        // **同じ中身なら書かない。**
        // restore() も rebuildAll() も publish() を通り、publish() の末尾は
        // persist() なので、読んだままの鎖がそのまま書き戻される。手元では
        // 何も変わらないが、iCloud では「最後に編集した端末」ではなく
        // 「最後に起動した端末」が勝つ形になる。半年触っていない端末を
        // 1 度開くだけで、別の端末のその日の編集が消える。
        guard UserDefaults.standard.data(forKey: lastKey) != data else { return }

        UserDefaults.standard.set(data, forKey: lastKey)
        // 正はいま書いた UserDefaults の側。iCloud へは写すだけ（CloudMirror）。
        CloudMirror.mirror(data, forKey: lastKey)
    }

    static func loadLast(catalog: [ETEffect]) -> [Loaded]? {
        guard let data = UserDefaults.standard.data(forKey: lastKey),
              let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return parse(json, catalog: catalog)
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
