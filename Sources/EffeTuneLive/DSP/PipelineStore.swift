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
//  こちらが置いた終端（rootReset）は`Section(cm: "")`に`"rr": true`を付けて書く
//  （ETSection.rootResetKey）。effetune.frieve.comへ渡すリンクでは外す。
//
//  出典: js/utils/serialization-utils.js:13-106、plugins/control/section.js
//
//  書く・読むの中身はPipelineForm.swift、鎖の段（Node）からの写しはChainEditing.swift
//  （どちらもFoundationだけで、単体テストに入る）。ここは端末への書き込みだけ。

import Foundation

extension PipelineStore {

    // 書く中身はPipelineForm.swiftのLoaded版だけ。Nodeの鎖はChainEditing.swiftで
    // Loadedへ写してから渡す（shortForm(_: [ETChainNode])）。前はNode版とLoaded版が同じことを
    // 別々に書いていて、終端の扱いはNode版にしか無かった。

    // MARK: - 端末に残す

    /// **private ではない。** CloudMirror が iCloud 側を同じ鍵で読む。
    /// 綴りを 2 か所に書くと、片方だけ直したときに黙って別の鍵になる。
    static let lastKey = "pipeline.last"

    /// 鎖を書く列。**JSON にするのと UserDefaults へ書くのはメインでやらない。**
    ///
    /// JSFX の @serialize は 16 MB まで来る。base64 で 21 MB になった鎖を
    /// JSON にし、前の中身と比べ、UserDefaults へ書くのを、つまみを離すたびに
    /// メインで回していた。直列なので書く順は呼んだ順のまま。
    private static let writer = DispatchQueue(label: "ai.nemut.effectdeck.store.last", qos: .utility)
    /// 書くよう頼んだことがあるか。列の先で書き終える前に hasSaved が偽を返さないため。
    /// saveLast と hasSaved はメインからしか呼ばれない。
    private static var requested = false

    static func saveLast(_ chain: [EffeTuneDSP.Node]) {
        // Node は鎖の型なのでここで辞書へ降ろす。重い所（JSON・比較・書き込み）は列の先。
        let form = shortForm(chain)
        requested = true
        writer.async {
            // **鍵の並びを固定する。**下の「同じなら書かない」が字面の比較なので、
            // 起動ごとに並びが変わると毎回「違う」と出る。
            guard let data = try? JSONSerialization.data(withJSONObject: form,
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
    }

    static func loadLast(catalog: [ETEffect]) -> [Loaded]? {
        // 書きかけが在れば待つ。読むのは起動と iCloud から降りてきたときだけ。
        writer.sync {}
        guard let data = UserDefaults.standard.data(forKey: lastKey),
              let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return parse(json, catalog: catalog)
    }

    /// 列に積んだ書き込みを書き切るまで待つ（ETFactoryReset）。
    static func flush() {
        writer.sync {}
    }

    static var hasSaved: Bool {
        requested || UserDefaults.standard.data(forKey: lastKey) != nil
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
