//  EffectPresetStore.swift
//  エフェクト 1 個ぶんの設定に名前を付けて残す。
//
//  **鎖ぜんぶを残す PresetStore とは別物。** 上流も別の入れ物を使っていて、
//  鍵の綴りも入れ子もそちらに合わせてある:
//
//      effetune_plugin_presets = { "<エフェクトの表示名>": { "<プリセット名>": { params } } }
//
//  （js/ui/pipeline/plugin-preset-store.js:1-2 と :99-107。外側の鍵が
//    this.plugin.name ＝**表示名**なのは plugin-preset-dialog.js:94, 111, 149）
//
//  中身は ETParamCoding.encode が出す辞書そのもの。上流が saveUserPreset で
//  消している enabled / ib / ob / ch（plugin-preset-dialog.js:142-150）は、
//  こちらの encode がもともと書かない。`en` を key に持つ ETParam は 3 本あるが、
//  全部 objectArrayKey 付きで外側（bs / rs / regions）の中にしか出ない
//  （EffectCatalog.swift:433, 1232, 1594）。
//
//  **PipelineStore.shortForm を流用しないこと。** あれは鎖の形式で、
//  nm / en / ib / ob / ch を足す（PipelineStore.swift:38-48）。
//  カードごとのプリセットは鎖ではないので、混ぜると上流で読めないものになる。

import Foundation

@MainActor
final class EffectPresetStore: ObservableObject {

    static let shared = EffectPresetStore()

    /// 上流と同じ綴り（plugin-preset-store.js:1）。
    /// **private ではない。** CloudMirror が iCloud 側を同じ鍵で読む
    /// （PipelineStore.lastKey と同じ理由）。
    static let key = "effetune_plugin_presets"

    /// 上流が名前として弾くもの（plugin-preset-store.js:3, 13-17）。
    /// Swift の Dictionary では害は無いが、同じ中身を web 版が読む前提なので
    /// 向こうで弾かれる名前はこちらでも作らない。
    private static let reserved: Set<String> = ["__proto__", "constructor", "prototype"]

    /// エフェクトの表示名 → 保存してある名前（並べ替え済み）。
    /// 画面がこれを観測する。
    @Published private(set) var saved: [String: [String]] = [:]

    private init() { reload() }

    private func reload() {
        var out: [String: [String]] = [:]
        for (effect, value) in dict() {
            guard let presets = value as? [String: Any], !presets.isEmpty else { continue }
            out[effect] = presets.keys.sorted()
        }
        saved = out
    }

    private func dict() -> [String: Any] {
        UserDefaults.standard.dictionary(forKey: Self.key) ?? [:]
    }

    /// 手元へ書いて一覧を引き直す。**iCloud へは写さない。**
    ///
    /// 写すのは触った項目だけ（CloudMirror.patch）。理由は PresetStore.write と同じ。
    private func write(_ all: [String: Any]) {
        UserDefaults.standard.set(all, forKey: Self.key)
        reload()
    }

    /// そのエフェクトに保存してある名前。
    func names(of effect: String) -> [String] { saved[effect] ?? [] }

    // MARK: - 出し入れ

    /// 名前を付けて残す。同じ名前は黙って置き換わる（上流も setOwn で上書き）。
    func save(_ name: String, of node: EffeTuneDSP.Node) {
        let trimmed = Self.normalize(name)
        // Section は上流も preset の UI を出さない（plugins/control/section.js の
        // hidePresetUI = true）ので、入れ物にも入れない。
        guard !trimmed.isEmpty, !node.isSection else { return }

        var params = ETParamCoding.encode(params: node.spec.params, values: node.values)
        // IR Reverb の素材は float に載らないので鍵で運ぶ。綴りは上流に合わせて `ir`
        // （plugins/reverb/ir_reverb.js:163 の `ir: this.ir`）。
        // PipelineStore.swift:74-77 が鎖でやっているのと同じ扱い。
        if !node.irId.isEmpty { params[ETIRLoader.presetKey] = node.irId }

        var all = dict()
        var mine = all[node.spec.name] as? [String: Any] ?? [:]
        mine[trimmed] = params
        all[node.spec.name] = mine
        write(all)
        CloudMirror.patch(key: Self.key, path: [node.spec.name, trimmed], value: params)
    }

    /// 保存してある params。読むのは EffectPresetApply。
    func params(of effect: String, name: String) -> [String: Any]? {
        (dict()[effect] as? [String: Any])?[name] as? [String: Any]
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
        CloudMirror.patch(key: Self.key, path: [effect, name], value: nil)
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
            // save() が絶対に作らない形が入れ物に残る（上の :34-37 の方針に反する）。
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
        for (effect, name, params) in touched {
            CloudMirror.patch(key: Self.key, path: [effect, name], value: params)
        }
        return count
    }

    // 上流には名前を付け替える口もある（plugin-preset-dialog.js:152-154 の ✎）が、
    // こちらには置いていない。打ち込む欄を出すには提示をもう 1 枚重ねることになり、
    // 同じビューに提示を重ねて後ろが出なくなる踏み方をこのリポジトリで 3 度している
    // （PresetsView.swift:145-148）。同じ名前で保存し直せば置き換わるので、
    // 付け替えは「保存して古いほうを消す」で足りる。

    /// 名前を整える。空白を落とし、上流が弾く名前は空を返す。
    private static func normalize(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return reserved.contains(trimmed) ? "" : trimmed
    }
}
