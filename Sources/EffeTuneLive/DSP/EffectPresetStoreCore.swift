//  EffectPresetStoreCore.swift
//  エフェクト 1 個ぶんの設定に名前を付けた入れ物の中身。**Foundationだけ。**
//
//  EffectPresetStore.swift から出した。あちらは画面が観測する ObservableObject
//  （Combine は Linux に無い）。こちらは入れ物（ETKeyValueStorage）と iCloud への
//  当て方（CloudPatch）を受け取って、出し入れだけをする（PresetStoreTests）。
//
//  入れ物の形は上流の綴りと入れ子のまま（EffectPresetStore.swift の頭）:
//
//      effetune_plugin_presets = { "<エフェクトの表示名>": { "<プリセット名>": { params } } }

import Foundation

final class EffectPresetStoreCore {

    /// 上流と同じ綴り（plugin-preset-store.js:1）。
    /// **private ではない。** CloudMirror が iCloud 側を同じ鍵で読む
    /// （PipelineStore.lastKey と同じ理由）。
    static let key = "effetune_plugin_presets"

    /// 上流が名前として弾くもの（plugin-preset-store.js:3, 13-17）。
    /// Swift の Dictionary では害は無いが、同じ中身を web 版が読む前提なので
    /// 向こうで弾かれる名前はこちらでも作らない。
    static let reserved: Set<String> = ["__proto__", "constructor", "prototype"]

    private let storage: ETKeyValueStorage
    private let patch: CloudPatch

    /// `storage` は手元の入れ物（アプリでは UserDefaults.standard）。
    /// `patch` は iCloud へ触った項目だけを当てる口（アプリでは CloudMirror.patch）。
    init(storage: ETKeyValueStorage, patch: @escaping CloudPatch) {
        self.storage = storage
        self.patch = patch
    }

    // MARK: - 読む

    /// エフェクトの表示名 → 保存してある名前（並べ替え済み）。
    var saved: [String: [String]] {
        var out: [String: [String]] = [:]
        for (effect, value) in dict() {
            guard let presets = value as? [String: Any], !presets.isEmpty else { continue }
            out[effect] = presets.keys.sorted()
        }
        return out
    }

    /// 保存してある params。読むのは EffectPresetApply。
    func params(of effect: String, name: String) -> [String: Any]? {
        (dict()[effect] as? [String: Any])?[name] as? [String: Any]
    }

    // MARK: - 出し入れ

    /// 名前を付けて残す。同じ名前は黙って置き換わる（上流も setOwn で上書き）。
    ///
    /// **params は node から作る**（`params(for:)`）。`effect` は表示名（`node.spec.name`）。
    /// 入れたら true。
    @discardableResult
    func save(_ name: String, effect: String, params: [String: Any]) -> Bool {
        let trimmed = Self.normalize(name)
        // Section は上流も preset の UI を出さない（plugins/control/section.js の
        // hidePresetUI = true）ので、入れ物にも入れない。
        guard !trimmed.isEmpty, effect != ETSection.name else { return false }

        var all = dict()
        var mine = all[effect] as? [String: Any] ?? [:]
        mine[trimmed] = params
        all[effect] = mine
        write(all)
        patch(Self.key, [CloudChange(path: [effect, trimmed], value: params)])
        return true
    }

    /// 1 段の値を、入れ物に入れる形（ETParamCoding.encode の辞書）にする。
    ///
    /// IR Reverb の素材は float に載らないので鍵で運ぶ。綴りは上流に合わせて `ir`
    /// （plugins/reverb/ir_reverb.js:163 の `ir: this.ir`）。鎖でも同じ扱い
    /// （PipelineForm.swift の irKey）。
    static func params(for node: ETChainNode) -> [String: Any] {
        var params = ETParamCoding.encode(params: node.spec.params, values: node.values)
        if !node.irId.isEmpty { params[ETChainText.assetKey(forType: node.spec.type)] = node.irId }
        // designerの材料（5Band FIR PEQの帯域など）も同じ綴りで入れる。上流のプリセットは
        // getSerializableParametersの中身そのものなので、これらも入っている
        // （plugin-preset-dialog.js:145）。入れないとlt / fdしか残らない。
        ETDesignParam.write(node.design, type: node.spec.type, into: &params)
        // 表示の設定（Analog Meter の rl / rg など）も入れる。上流のプリセットは getParameters の中身で、
        // 表示の設定もそこに入っている。入れないと、保存して戻したときに針の目盛りが既定へ戻る。
        // 触っていない鍵は上流の既定で書く（持つ型だけ。ETDisplayParam.defaults）ので、戻したときに
        // 「保存したときの表示」へ戻る。
        let display = ETDisplayParam.defaults(for: node.spec.type).merging(node.display) { _, mine in mine }
        ETDisplayParam.write(display, type: node.spec.type, into: &params)
        return params
    }

    func remove(_ name: String, of effect: String) {
        var all = dict()
        guard var mine = all[effect] as? [String: Any] else { return }
        mine.removeValue(forKey: name)
        // そのエフェクトのものが無くなったら鍵ごと消す（plugin-preset-store.js:159）。
        if mine.isEmpty {
            all.removeValue(forKey: effect)
        } else {
            all[effect] = mine
        }
        write(all)
        patch(Self.key, [CloudChange(path: [effect, name], value: nil)])
    }

    // MARK: - ファイルとのやり取り（ETBackup）

    /// 書き出し用。入れ物の中身をそのまま返す。
    /// 上流の入れ子（表示名 → プリセット名 → params）で既に入っているので被せ物は要らない。
    func exported() -> [String: Any] { dict() }

    /// 読み込み。**プリセット名ごとに入れ替える。**ファイルに無い名前はそのまま残す。
    /// 返すのは入れた本数。
    @discardableResult
    func merge(_ incoming: [String: [String: [String: Any]]]) -> Int {
        var all = dict()
        var count = 0
        var touched: [(String, String, [String: Any])] = []
        for (effect, presets) in incoming {
            // **エフェクトの名前も normalize に通す。**上流は外側の鍵にも
            // normalizeName を掛けている（plugin-preset-store.js:94 の
            // `const pluginKey = normalizeName(pluginName);`）。プリセット名だけ
            // 通していると、ファイル由来の `__proto__` が外側の鍵として入り、
            // save() が絶対に作らない形が入れ物に残る（上の reserved の方針に反する）。
            let key = Self.normalize(effect)
            // Section は上流も preset の UI を出さない（save の注記）。
            guard !key.isEmpty, key != ETSection.name else { continue }
            var mine = all[key] as? [String: Any] ?? [:]
            for (name, params) in presets {
                let trimmed = Self.normalize(name)
                guard !trimmed.isEmpty else { continue }
                mine[trimmed] = params
                touched.append((key, trimmed, params))
                count += 1
            }
            if !mine.isEmpty { all[key] = mine }
        }
        guard count > 0 else { return 0 }
        write(all)
        // 入れた項目だけ写す。まるごと写すと別の端末に在るものが消える。
        // **1 本ずつ当てる。**まとめると、大きさの上限に当たったときに 1 本も写らない。
        for (effect, name, params) in touched {
            patch(Self.key, [CloudChange(path: [effect, name], value: params)])
        }
        return count
    }

    /// 名前を整える。空白を落とし、上流が弾く名前は空を返す。
    static func normalize(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return reserved.contains(trimmed) ? "" : trimmed
    }

    // MARK: - 入れ物

    private func dict() -> [String: Any] {
        storage.dictionary(forKey: Self.key) ?? [:]
    }

    /// 手元へ書く。**iCloud へは写さない。**写すのは触った項目だけ（patch）。
    /// 理由は PresetStoreCore.write と同じ。
    private func write(_ all: [String: Any]) {
        storage.set(all, forKey: Self.key)
    }
}
