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
//  nm / en / ib / ob / ch を足す（PipelineForm.swift の shortForm）。
//  カードごとのプリセットは鎖ではないので、混ぜると上流で読めないものになる。
//
//  **出し入れの中身は EffectPresetStoreCore.swift**（Foundationだけで、単体テストに入る）。
//  ここは画面が観測する一覧だけを持つ。

import Foundation

@MainActor
final class EffectPresetStore: ObservableObject {

    static let shared = EffectPresetStore()

    /// **private ではない。** CloudMirror が iCloud 側を同じ鍵で読む。
    /// 綴りは EffectPresetStoreCore が持つ（上流と同じ plugin-preset-store.js:1）。
    static let key = EffectPresetStoreCore.key

    /// エフェクトの表示名 → 保存してある名前（並べ替え済み）。
    /// 画面がこれを観測する。
    @Published private(set) var saved: [String: [String]] = [:]

    private let core: EffectPresetStoreCore

    /// アプリは shared（UserDefaults.standard と CloudMirror.patch）を使う。
    init(storage: ETKeyValueStorage = UserDefaults.standard,
         patch: @escaping CloudPatch = CloudMirror.patch(key:changes:)) {
        core = EffectPresetStoreCore(storage: storage, patch: patch)
        reload()
    }

    /// 入れ物を読み直す。init と、全部消したあと（ETFactoryReset）。
    func reload() {
        saved = core.saved
    }

    /// そのエフェクトに保存してある名前。
    func names(of effect: String) -> [String] { saved[effect] ?? [] }

    // MARK: - 出し入れ

    /// 名前を付けて残す。同じ名前は黙って置き換わる（上流も setOwn で上書き）。
    /// Section は入れない（EffectPresetStoreCore.save）。
    func save(_ name: String, of node: EffeTuneDSP.Node) {
        guard !node.isSection else { return }
        core.save(name, effect: node.spec.name, params: EffectPresetStoreCore.params(for: node))
        reload()
    }

    /// 保存してある params。読むのは EffectPresetApply。
    func params(of effect: String, name: String) -> [String: Any]? {
        core.params(of: effect, name: name)
    }

    func remove(_ name: String, of effect: String) {
        core.remove(name, of: effect)
        reload()
    }

    // MARK: - ファイルとのやり取り（ETBackup）

    /// 書き出し用。入れ物の中身をそのまま返す。
    func exported() -> [String: Any] { core.exported() }

    /// 読み込み。**プリセット名ごとに入れ替える。**ファイルに無い名前はそのまま残す。
    /// 返すのは入れた本数。
    @discardableResult
    func merge(_ incoming: [String: [String: [String: Any]]]) -> Int {
        defer { reload() }
        return core.merge(incoming)
    }

    // 上流には名前を付け替える口もある（plugin-preset-dialog.js:152-154 の ✎）が、
    // こちらには置いていない。打ち込む欄を出すには提示をもう 1 枚重ねることになり、
    // 同じビューに提示を重ねて後ろが出なくなる踏み方をこのリポジトリで 3 度している
    // （PresetsView.swift:145-148）。同じ名前で保存し直せば置き換わるので、
    // 付け替えは「保存して古いほうを消す」で足りる。
}
