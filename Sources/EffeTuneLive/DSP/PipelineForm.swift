//  PipelineForm.swift
//  鎖を渡す形（ショート・ロング）へ書く・渡す形から読む。**Foundationだけ。**
//
//  PipelineStore.swiftから出した。あちらは鎖のNode（EffeTuneDSP）と端末への書き込みを持ち、
//  AVFoundationとSwiftUIを連れてくるので単体テストに入れられない。
//  書く側と読む側をどちらもここに置き、往復を実機なしで試す（PipelineStoreTests）。
//  **書くのはここだけ。**NodeからはPipelineStore.Loadedへ写してから書く（ChainEditing.swift）。
//  形そのものの説明はPipelineStore.swiftの頭。
//
//  **Sectionの終端（rootReset）には印を付ける（ETSection.rootResetKey）。**
//  渡す形では終端も`Section(cm: "")`になるので、印が無いと読み戻したときに
//  名前の無いSectionとして戻り、下の段を組に呑む。しかも畳んだまま戻る
//  （開いている段は位置で覚えていて、終端は開かない）ので、組から出した段と
//  その下が画面から消えていた。印の無い空Sectionは推測せず普通のSectionとして読む
//  （PipelineAnalysis.swiftの頭）。

import Foundation
import os

enum PipelineStore {

    private static let log = Logger(subsystem: "ai.nemut.effetune", category: "store")

    /// 段の素材の鍵（IR は `ir`、SFZ は `sf`）。SFZ の鍵は 24 桁の小文字の 16 進だけ（上流の setParameters と同じ。
    /// 外れた字は空にする）。
    private static func assetID(_ params: [String: Any], type: String) -> String {
        let value = params[ETChainText.assetKey(forType: type)] as? String ?? ""
        return type == ETChainText.sfzType && !ETSFZ.isValidID(value) ? "" : value
    }

    // MARK: - 読んだ1段

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
        /// 音に関わらない表示の設定（`cl` / `sc` など）。DisplayParams.swift を読むこと。
        var display: [String: String] = [:]
        /// designerで作る型の設計の材料（`pm` / `tp` / `f0`など）。DesignParams.swiftを読むこと。
        var design: [String: String] = [:]
        var externalID: String = ""
        var externalInstanceID: String = ""
        var externalState: Data? = nil
        /// **自分で置いた終端。**Sectionではない（EffeTuneDSP.Node.isRootReset）。
        /// specはETSection.specのまま持ち、書くと`Section(cm: "")`に印を付けたものになる。
        var isRootReset: Bool = false
    }

    // MARK: - 書く

    /// ショート形式。共有リンクとプリセットとpipeline.lastに使う。
    static func shortForm(_ loaded: [Loaded]) -> [[String: Any]] {
        loaded.map { item in
            var o = parameters(of: item)
            if !item.externalID.isEmpty {
                o["external"] = item.externalID
                o["externalInstance"] = item.externalInstanceID
                if let state = item.externalState {
                    o["externalState"] = state.base64EncodedString()
                }
            }
            o["nm"] = item.spec.name
            o["en"] = item.enabled
            if item.inputBus  != 0 { o["ib"] = Int(item.inputBus) }
            if item.outputBus != 0 { o["ob"] = Int(item.outputBus) }
            if let ch = ETChannel.channel(from: item.channelSpec) { o["ch"] = ch }
            if item.isRootReset { o[ETSection.rootResetKey] = true }
            return o
        }
    }

    /// ロング形式。ファイルに書き出すときに使う（ETBackup）。
    /// 終端の印は`parameters`の中ではなく段の鍵として置く（`name`の隣）。
    static func longForm(_ loaded: [Loaded]) -> [String: Any] {
        let list: [[String: Any]] = loaded.map { item in
            var o: [String: Any] = [
                "name": item.spec.name,
                "enabled": item.enabled,
                "parameters": parameters(of: item),
            ]
            if !item.externalID.isEmpty {
                o["external"] = item.externalID
                o["externalInstance"] = item.externalInstanceID
                if let state = item.externalState {
                    o["externalState"] = state.base64EncodedString()
                }
            }
            if item.inputBus  != 0 { o["inputBus"] = Int(item.inputBus) }
            if item.outputBus != 0 { o["outputBus"] = Int(item.outputBus) }
            if let ch = ETChannel.channel(from: item.channelSpec) { o["channel"] = ch }
            if item.isRootReset { o[ETSection.rootResetKey] = true }
            return o
        }
        return ["pipeline": list]
    }

    /// 上流（effetune.frieve.com）へ渡す1段。**終端の印を外す。**
    ///
    /// 外すと素の`Section("")`になり、上流が組の終わりに使うのと同じ形になる
    /// （preset-manager.js:149-161）。上流は知らない鍵を読まないので残しても害は無いが、
    /// EffectDeckの外へ出る形にこちらだけの鍵を載せない（外部の段を落とすのと同じ。
    /// ETShareLink.effeTuneForm）。
    static func upstreamEntry(_ entry: [String: Any]) -> [String: Any] {
        var o = entry
        o.removeValue(forKey: ETSection.rootResetKey)
        return o
    }

    /// パラメータを保存形式へ。中身は ETParamCoding が持つ。
    ///
    /// オブジェクト配列の扱いを何度も読み違えたので、Tests/Unit/ParamCodingTests.swiftが
    /// 実機なしで見張る。
    private static func parameters(of item: Loaded) -> [String: Any] {
        // **rootReset はここで Section("") に化ける。**渡す形に終端が無いので、
        // 上流と同じ代用品に落とす（preset-manager.js:149-161 も同じことをする）。
        // 印（rootResetKey）は段の鍵として呼び手が足す。
        if item.isRootReset { return [ETSection.commentKey: ""] }
        // SectionはETParamを持たない。名前は文字列で持っているのでここで出す。
        if ETSection.isSection(item.spec) { return [ETSection.commentKey: item.sectionName] }
        var o = ETParamCoding.encode(params: item.spec.params, values: item.values)
        // IR Reverb の素材は float に載らないので、鍵をここで足す。
        // 綴りは上流に合わせて `ir`（ir_reverb.js:866）。
        if !item.irId.isEmpty { o[ETChainText.assetKey(forType: item.spec.type)] = item.irId }
        // 図の見せ方（float に載らない）。綴りは上流のまま。
        let shown = ETDisplayParam.writesDefaultsInChain(item.spec.type)
            ? ETDisplayParam.defaults(for: item.spec.type).merging(item.display) { _, mine in mine }
            : item.display
        ETDisplayParam.write(shown, type: item.spec.type, into: &o)
        // designerの材料（floatに載らない）。綴りは上流のまま。
        ETDesignParam.write(item.design, type: item.spec.type, into: &o)
        return o
    }

    // MARK: - 読む

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
                let spec = ETEffect.external(type: "External:\(externalID)", name: name,
                                              category: externalID.hasPrefix("jsfx:") ? "JSFX" : "Audio Units")
                let instanceID = entry["externalInstance"] as? String ?? UUID().uuidString
                let state = (entry["externalState"] as? String).flatMap {
                    Data(base64Encoded: $0)
                }
                out.append(Loaded(spec: spec, values: [],
                                   enabled: (entry["enabled"] ?? entry["en"]) as? Bool ?? true,
                                   inputBus: bus(entry["inputBus"] ?? entry["ib"]),
                                   outputBus: bus(entry["outputBus"] ?? entry["ob"]),
                                   channelSpec: ETChannel.spec(from: (entry["channel"] ?? entry["ch"]) as? String),
                                   externalID: externalID,
                                   externalInstanceID: instanceID,
                                   externalState: state))
                continue
            }

            let params: [String: Any] = isLong
                ? (entry["parameters"] as? [String: Any] ?? [:])
                : entry

            // Section はカーネルが無いので catalog に載っていない。名前で拾う。
            // ここで落とすと、web 版で作った鎖を取り込んだときに区切りだけ消えて
            // 配下が別のセクションに繰り上がる（次の Section まで、が変わる）。
            if name == ETSection.name {
                let enabled = (entry["enabled"] ?? entry["en"]) as? Bool ?? true
                let sectionName = params[ETSection.commentKey] as? String ?? ""
                // **印が付いていて、書いたときの形のままのものだけを終端に戻す。**
                // 名前が付いている・切ってあるものは、上流が読むのと同じ普通のSectionにする。
                // 終端にすると名前が消え、切ってあれば止まっていた段が鳴り出す。
                // 名前が空で入っているSectionなら、終端と読んでも音は変わらない。
                let marked = entry[ETSection.rootResetKey] as? Bool ?? false
                out.append(Loaded(
                    spec: ETSection.spec,
                    values: [],
                    enabled: enabled,
                    inputBus: 0,
                    outputBus: 0,
                    channelSpec: -1,
                    sectionName: sectionName,
                    isRootReset: marked && sectionName.isEmpty && enabled))
                continue
            }

            guard let spec = byName[name] else {
                log.notice("知らないエフェクト \(name, privacy: .public)")
                continue
            }

            let values = ETParamCoding.decode(params: spec.params,
                                              defaults: spec.defaults,
                                              from: params,
                                              type: spec.type)

            let ch = (entry["channel"] ?? entry["ch"]) as? String
            out.append(Loaded(
                spec: spec,
                values: values,
                enabled: (entry["enabled"] ?? entry["en"]) as? Bool ?? true,
                inputBus: bus(entry["inputBus"] ?? entry["ib"]),
                outputBus: bus(entry["outputBus"] ?? entry["ob"]),
                channelSpec: ETChannel.spec(from: ch),
                sectionName: "",
                irId: assetID(params, type: spec.type),
                display: ETDisplayParam.legacyRead(params, type: spec.type),
                design: ETDesignParam.read(params, type: spec.type)))
        }
        return out
    }

    /// バスの番号。**0...4に寄せる。**エンジンは5以上が1本でもあると鎖ごと拒む
    /// （engine.cpp:674-678）。貼られた字はETChainText.prepareが先に寄せるが、
    /// バックアップとpipeline.lastはそこを通らずにここへ来る。
    private static func bus(_ raw: Any?) -> UInt8 {
        UInt8(clamping: min(ETChainText.busLimit, raw as? Int ?? 0))
    }
}
