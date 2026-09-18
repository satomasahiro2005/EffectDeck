//  PresetStore.swift
//  名前を付けた鎖の保管。
//
//  中身は EffeTune のユーザープリセットと同じショート形式の配列なので、
//  ここから書き出したものは web 版へそのまま持っていける。

import Foundation

@MainActor
final class PresetStore: ObservableObject {

    static let shared = PresetStore()

    /// **private ではない。** CloudMirror が iCloud 側を同じ鍵で読む
    /// （PipelineStore.lastKey と同じ理由）。
    static let key = "presets"

    /// 中身の無いフォルダを覚えておく鍵。
    ///
    /// **フォルダは名前の付け方だけで表す**（`Rock/Heavy`）ので、
    /// 中身が 1 つも無いフォルダは名前のどこにも現れない。作った直後に
    /// 消えて見えるのは分かりにくいので、空のぶんだけここに持つ。
    /// **iCloud へは写さない。**中身が入れば名前の側に現れるし、
    /// 空の入れ物を端末間で合わせる意味が薄い。
    static let emptyFoldersKey = "presetEmptyFolders"

    @Published private(set) var names: [String] = []
    /// 中身の無いフォルダ。名前から作られるぶんとは別に持つ。
    @Published private(set) var emptyFolders: [String] = []

    private init() { reload() }

    private func reload() {
        names = (dict().keys.sorted())
        let used = Set(names.map(ETUserPresetName.folder))
        // 中身が入ったものは、もう空ではない。
        emptyFolders = (UserDefaults.standard.stringArray(forKey: Self.emptyFoldersKey) ?? [])
            .filter { !used.contains($0) }
            .sorted()
    }

    /// 空のフォルダを作る。**入れ子は作らない。**`/` は名前から落とす。
    func addFolder(_ name: String) {
        let clean = ETUserPresetName.clean(name)
        guard !clean.isEmpty else { return }
        var list = UserDefaults.standard.stringArray(forKey: Self.emptyFoldersKey) ?? []
        guard !list.contains(clean) else { return }
        list.append(clean)
        UserDefaults.standard.set(list, forKey: Self.emptyFoldersKey)
        reload()
    }

    func removeFolder(_ name: String) {
        let list = (UserDefaults.standard.stringArray(forKey: Self.emptyFoldersKey) ?? [])
            .filter { $0 != name }
        UserDefaults.standard.set(list, forKey: Self.emptyFoldersKey)
        reload()
    }

    /// フォルダの名前を替える。**中のプリセットを全部付け替える。**
    /// 入れ物という実体が無いので、まとめて名前を書き替えるのがそのまま移動になる。
    @discardableResult
    func renameFolder(_ old: String, to new: String) -> Bool {
        let target = ETUserPresetName.clean(new)
        guard !target.isEmpty, target != old else { return false }
        let moving = names.filter { ETUserPresetName.folder($0) == old }
        // 移す先に同じ名前が既に在るなら、何も動かさない（半端に終わらせない）。
        for full in moving where dict()[target + "/" + ETUserPresetName.leaf(full)] != nil {
            return false
        }
        for full in moving {
            rename(full, to: target + "/" + ETUserPresetName.leaf(full))
        }
        if emptyFolders.contains(old) {
            removeFolder(old)
            addFolder(target)
        }
        reloadPublic()
        return true
    }

    /// 外から一覧を引き直す（rename を重ねたあとの締め）。
    func reloadPublic() { reload() }

    /// 名前を付け替える。**フォルダの出し入れもこれ。**
    /// 中身は動かさず鍵だけ差し替えるので、鎖は一切触らない。
    @discardableResult
    func rename(_ old: String, to new: String) -> Bool {
        let target = ETUserPresetName.normalized(new)
        guard !target.isEmpty, target != old else { return false }
        var d = dict()
        guard let form = d[old], d[target] == nil else { return false }
        d.removeValue(forKey: old)
        d[target] = form
        write(d)
        CloudMirror.patch(key: Self.key, path: [old], value: nil)
        CloudMirror.patch(key: Self.key, path: [target], value: form)
        return true
    }

    private func dict() -> [String: Any] {
        UserDefaults.standard.dictionary(forKey: Self.key) ?? [:]
    }

    /// 手元へ書いて一覧を引き直す。**iCloud へは写さない。**
    ///
    /// 写すのは触った名前だけ（CloudMirror.patch）。辞書をまるごと写すと、
    /// 手元の分が iCloud の分を置き換えて、別の端末に在るものが消える。
    private func write(_ d: [String: Any]) {
        UserDefaults.standard.set(d, forKey: Self.key)
        reload()
    }

    func save(_ name: String, chain: [EffeTuneDSP.Node]) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !chain.isEmpty else { return }
        var d = dict()
        let form = PipelineStore.shortForm(chain)
        d[trimmed] = form
        write(d)
        CloudMirror.patch(key: Self.key, path: [trimmed], value: form)
    }

    func load(_ name: String) -> [PipelineStore.Loaded] {
        guard let raw = dict()[name] else { return [] }
        return PipelineStore.parse(raw, catalog: ETCatalog)
    }

    func remove(_ name: String) {
        var d = dict()
        d.removeValue(forKey: name)
        write(d)
        CloudMirror.patch(key: Self.key, path: [name], value: nil)
    }

    func importFrom(_ text: String) -> [PipelineStore.Loaded] {
        ETShareLink.parse(text, catalog: ETCatalog)
    }

    // MARK: - ファイルとのやり取り（ETBackup）

    /// 書き出し用。入れ物の中身をそのまま返す。
    /// 上流の包み方（`{ plugins: [...] }`）は ETBackup が被せる。
    func exported() -> [String: Any] { dict() }

    /// 読み込み。**名前ごとに入れ替える。**ファイルに無い名前はそのまま残す。
    /// 返すのは入れた本数。
    @discardableResult
    func merge(_ incoming: [String: [[String: Any]]]) -> Int {
        var d = dict()
        var touched: [String: Any] = [:]
        for (name, entries) in incoming {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !entries.isEmpty else { continue }
            d[trimmed] = entries
            touched[trimmed] = entries
        }
        guard !touched.isEmpty else { return 0 }
        write(d)
        // 入れた名前だけ写す。まるごと写すと別の端末に在るものが消える。
        for (name, entries) in touched {
            CloudMirror.patch(key: Self.key, path: [name], value: entries)
        }
        return touched.count
    }
}
