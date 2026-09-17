//  ETBackup.swift
//  鎖とプリセットを 1 本の JSON へ出し、同じ形を読む。
//
//  **音の設定（Preferences の pref.*、Processing rate や Latency）は入らない。**
//  入るのは下の 3 つだけ。画面のボタンもそう名乗る（SettingsView の backup）。
//
//  共有リンク（ETShareLink）は**渡す**ためのもので、こちらは**取っておく**ためのもの。
//  性質が違うので両方ある。拡張子は .json。
//
//  中身は上流の綴りのまま。独自の形にしない:
//
//      { "pipeline": [ ロング形式の段 … ],
//        "effetune_presets": { "<名前>": { "plugins": [ ショート形式の段 … ] } },
//        "effetune_plugin_presets": { "<表示名>": { "<名前>": { params } } } }
//
//    - `pipeline` は上流の `.effetune_preset` ファイルと同じ
//      （js/electron/presetIntegration.js:76-105 が JSON.parse して pipeline を見る。
//       ui-manager.js:2367-2390 の loadPreset も pipeline（:2367）か
//       plugins（:2375）しか読まないので、隣に別の鍵が載っていても素通しする）。
//      **拡張子だけは向こうが見る**（presetIntegration.js:54、
//      ui/pipeline/ui-event-handler.js:498 がどちらも .effetune_preset で絞る）ので、
//      web 版で開くときは名前を付け替える。
//    - `effetune_presets` は上流の localStorage の鍵と包み方
//      （js/ui/pipeline/preset-manager.js:98 の綴りと :216 の
//       `setOwn(presets, name, { plugins: pluginsData })`）。
//      **このアプリの入れ物（PresetStore、鍵 `presets`）は包まない生の配列**なので、
//      書くときに被せて、読むときに外す。
//    - `effetune_plugin_presets` は上流の綴りと入れ子のまま
//      （js/ui/pipeline/plugin-preset-store.js:1, 99-107）。EffectPresetStore が
//      既に同じ形で持っているので被せ物は要らない。
//
//  **IR は入らない。**数 MB あるし、zip にすると web 版が読めない。
//  鎖が持っているのは sha256 の先頭 24 桁の参照だけで（PipelineStore.swift:74-77）、
//  素材が手元に無ければカードが「Missing from the library」と言う。
//
//  読むときは**全部読めてから初めて渡す。**途中まで読めた JSON で
//  いま持っているものを潰さない。読めなかった要素は数えて返し、
//  画面が入れる前にその数を出す（SettingsView.summary）。

import Foundation

enum ETBackup {

    /// 鎖の鍵。PipelineStore.longForm が包む鍵と同じ綴り（あちらが上流のファイル形式）。
    static let pipelineKey = "pipeline"
    /// 名前を付けた鎖。上流の localStorage の鍵（preset-manager.js:98）。
    static let presetsKey = "effetune_presets"
    /// エフェクトごとのプリセット（plugin-preset-store.js:1）。
    static let effectPresetsKey = "effetune_plugin_presets"
    /// 上流がプリセット 1 本を包む鍵（preset-manager.js:216）。
    static let pluginsKey = "plugins"

    // MARK: - 書く

    /// 書き出す 1 本。空なら nil（出すものが無い）。
    ///
    /// `presets` と `effectPresets` は各 store の `exported()` をそのまま渡す。
    static func data(chain: [EffeTuneDSP.Node],
                     presets: [String: Any],
                     effectPresets: [String: Any]) -> Data? {

        // 鎖はロング形式。longForm が `{"pipeline": [...]}` を返す。
        var root: [String: Any] = chain.isEmpty ? [:] : PipelineStore.longForm(chain)

        if !presets.isEmpty {
            var wrapped: [String: Any] = [:]
            for (name, value) in presets { wrapped[name] = [pluginsKey: value] }
            root[presetsKey] = wrapped
        }

        if !effectPresets.isEmpty { root[effectPresetsKey] = effectPresets }

        guard !root.isEmpty, JSONSerialization.isValidJSONObject(root) else { return nil }
        // 人が開いて読めるように整える。上流も Electron 側は同じ（preset-manager.js:177）。
        return try? JSONSerialization.data(withJSONObject: root,
                                           options: [.prettyPrinted,
                                                     .sortedKeys,
                                                     .withoutEscapingSlashes])
    }

    // MARK: - 読む

    /// 読めたもの。**渡す前に全部揃っている。**
    struct Contents {
        var chain: [PipelineStore.Loaded] = []
        /// 保存の形（包みは外してある）。PresetStore.merge へそのまま渡せる。
        var presets: [String: [[String: Any]]] = [:]
        var effectPresets: [String: [String: [String: Any]]] = [:]

        /// 鎖に載っていたのに、こちらに無くて落ちた段の数。
        /// 入れると鎖はこの数だけ短くなる。押す前に言う。
        var chainDropped: Int = 0
        /// 読めずに飛ばしたプリセットの数。
        var skipped: Int = 0

        var isEmpty: Bool { chain.isEmpty && presets.isEmpty && effectPresets.isEmpty }
        /// 入れたエフェクトのプリセットの本数（エフェクトの種類ではない）。
        var effectPresetCount: Int { effectPresets.values.reduce(0) { $0 + $1.count } }
    }

    /// Result の失敗側に置くので Error に合わせてある（投げはしない）。
    enum Failure: Error {
        /// JSON として読めない。
        case notJSON
        /// JSON ではあるが、この形ではない。
        case notBackup
        /// 鎖は載っているが、こちらに在るエフェクトが 1 つも無い。
        case noEffects
        /// 形は合っているが、読めた中身が 1 つも残らなかった。
        case nothingUsable

        /// 画面に出す 1 行。
        var message: String {
            switch self {
            case .notJSON:       return "That file is not JSON."
            case .notBackup:     return "That file is not an EffeTune settings file."
            case .noEffects:     return "None of the effects in that file are available here."
            case .nothingUsable: return "Nothing in that file could be used."
            }
        }
    }

    static func read(_ data: Data, catalog: [ETEffect]) -> Result<Contents, Failure> {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            return .failure(.notJSON)
        }

        var out = Contents()

        // 根が配列なら鎖だけ。上流の古い形（presetIntegration.js:87-95 が同じ扱い）で、
        // 共有リンクの中身もこれ。
        if let list = json as? [[String: Any]] {
            let loaded = PipelineStore.parse(list, catalog: catalog)
            guard !loaded.isEmpty else { return .failure(list.isEmpty ? .notBackup : .noEffects) }
            out.chain = loaded
            out.chainDropped = list.count - loaded.count
            return .success(out)
        }

        guard let root = json as? [String: Any] else { return .failure(.notBackup) }

        // **`plugins` が根に在る形も鎖として受ける。**
        // 上流がプリセット 1 本を持つ形そのもので（preset-manager.js:216）、
        // 読む側も同じ（ui-manager.js:2375 の `preset.plugins && Array.isArray`）。
        // 受けないと、web 版の保管庫から 1 本取り出したファイルを
        // 「EffeTune のファイルではない」と断ることになり、行き来が片道になる。
        //
        // `??` で 1 行にしない。Any? どうしの ?? はどちらの多重定義が選ばれるか
        // 読みにくく、片方は Any へ潰れる。
        var chainRaw = root[pipelineKey]
        if chainRaw == nil { chainRaw = root[pluginsKey] }

        if let raw = chainRaw {
            guard let list = raw as? [[String: Any]] else { return .failure(.notBackup) }
            let loaded = PipelineStore.parse(list, catalog: catalog)
            // 中身が在るのに 1 本も読めないのは、知らないエフェクトばかりのとき。
            // 空の鎖で置き換えるくらいなら、何もせず理由を出す。
            guard !(loaded.isEmpty && !list.isEmpty) else { return .failure(.noEffects) }
            out.chain = loaded
            out.chainDropped = list.count - loaded.count
        }

        if let raw = root[presetsKey] {
            guard let d = raw as? [String: Any] else { return .failure(.notBackup) }
            let parsed = presets(from: d, catalog: catalog)
            out.presets = parsed.kept
            out.skipped += parsed.skipped
        }

        if let raw = root[effectPresetsKey] {
            guard let d = raw as? [String: Any] else { return .failure(.notBackup) }
            let parsed = effectPresets(from: d)
            out.effectPresets = parsed.kept
            out.skipped += parsed.skipped
        }

        guard !out.isEmpty else {
            // 形は合っていたのに何も残らなかったのなら、ファイルの種類ではなく
            // 中身の問題。理由を取り違えて「EffeTune のファイルではない」と
            // 言わないために分けてある。
            return .failure(out.skipped > 0 ? .nothingUsable : .notBackup)
        }
        return .success(out)
    }

    /// 名前を付けた鎖。上流の包み（`plugins`）も、こちらの生の配列も、
    /// ロング形式（`pipeline`）も受ける。上流も読む側で両方見ている
    /// （preset-manager.js:108-126 の getPresetPluginStates）。
    ///
    /// **ロング形式はここでショート形式へ直す。**入れ物（PresetStore、鍵 `presets`）
    /// はショート形式と決まっていて、書き出すときに ETBackup.data がそれに
    /// `plugins` を被せる。上流の `plugins` の読み手は `nm` しか見ない
    /// （preset-manager.js:120-122）ので、ロング形式のまま入れて書き出すと
    /// 名前が空文字になり、isPresetLoadable が false（同 :135-138）、
    /// filterLoadablePresets（同 :152-156）が一覧から黙って落とす。
    /// 人のプリセットが往復 1 回で web 版から消える。
    ///
    /// **ショート形式は読み直さない。**通すと、この版が知らないパラメータが
    /// ETParamCoding の往復で落ちる。直すのは壊れる側だけにする。
    ///
    /// **中身は見る。**鎖と同じく PipelineStore.parse を通し、こちらに在る
    /// エフェクトが 1 本も残らない名前は入れない。入れると、名前だけ残った
    /// 空のプリセットが中身のあるプリセットを上書きする。
    ///
    /// 読めない要素は飛ばして残りを入れる。1 本の取りこぼしでファイルごと
    /// 捨てると、同じファイルに載っている鎖まで道連れになる。
    private static func presets(from d: [String: Any],
                                catalog: [ETEffect])
    -> (kept: [String: [[String: Any]]], skipped: Int) {

        var out: [String: [[String: Any]]] = [:]
        var skipped = 0

        for (name, value) in d {
            var list: [[String: Any]]?
            var isLong = false
            if let bare = value as? [[String: Any]] {
                list = bare
            } else if let wrapper = value as? [String: Any] {
                list = wrapper[pluginsKey] as? [[String: Any]]
                if list == nil, let long = wrapper[pipelineKey] as? [[String: Any]] {
                    list = long
                    isLong = true
                }
            }
            guard let list else { skipped += 1; continue }

            let loaded = PipelineStore.parse(list, catalog: catalog)
            guard !loaded.isEmpty else { skipped += 1; continue }

            let entries = isLong ? PipelineStore.shortForm(loaded) : list
            guard isStorable(entries) else { skipped += 1; continue }
            out[name] = entries
        }
        return (out, skipped)
    }

    /// エフェクトごとのプリセット。表示名 → プリセット名 → params。
    /// 予約名（`__proto__` ほか）を弾くのは EffectPresetStore.merge の担当。
    private static func effectPresets(from d: [String: Any])
    -> (kept: [String: [String: [String: Any]]], skipped: Int) {

        var out: [String: [String: [String: Any]]] = [:]
        var skipped = 0

        for (effect, value) in d {
            guard let presets = value as? [String: Any] else { skipped += 1; continue }
            var mine: [String: [String: Any]] = [:]
            for (name, params) in presets {
                guard let params = params as? [String: Any], isStorable(params) else {
                    skipped += 1
                    continue
                }
                mine[name] = params
            }
            if mine.isEmpty { continue }
            out[effect] = mine
        }
        return (out, skipped)
    }

    /// UserDefaults へ入れられるか。
    ///
    /// JSON の `null` は NSNull になり、plist に入らない。素通しさせると
    /// 書き込みの時点で落ちるので、渡す前にここで弾く。
    private static func isStorable(_ value: Any) -> Bool {
        PropertyListSerialization.propertyList(value, isValidFor: .binary)
    }
}
