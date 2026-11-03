//  PresetStore.swift
//  名前を付けた鎖の保管。
//
//  中身は EffeTune のユーザープリセットと同じショート形式の配列なので、
//  ここから書き出したものは web 版へそのまま持っていける。
//
//  **出し入れの中身は PresetStoreCore.swift**（Foundationだけで、単体テストに入る）。
//  ここは画面が観測する一覧と、鎖の Node からショート形式を作るのと、
//  貼られた字の読み込みだけを持つ。

import Foundation

@MainActor
final class PresetStore: ObservableObject {

    static let shared = PresetStore()

    /// **private ではない。** CloudMirror が iCloud 側を同じ鍵で読む
    /// （PipelineStore.lastKey と同じ理由）。綴りは PresetStoreCore が持つ。
    static let key = PresetStoreCore.key

    @Published private(set) var names: [String] = []
    /// 中身の無いフォルダ。名前から作られるぶんとは別に持つ。
    @Published private(set) var emptyFolders: [String] = []

    private let core: PresetStoreCore

    /// アプリは shared（UserDefaults.standard と CloudMirror.patch）を使う。
    init(storage: ETKeyValueStorage = UserDefaults.standard,
         patch: @escaping CloudPatch = CloudMirror.patch(key:changes:)) {
        core = PresetStoreCore(storage: storage, patch: patch)
        reload()
    }

    /// 入れ物を読み直す。init と、全部消したあと（ETFactoryReset）。
    func reload() {
        names = core.names
        emptyFolders = core.emptyFolders
    }

    /// 中身が変わった。一覧を読み直して、出力補正に知らせる（紐付けたプリセットの上書き・付け替え・削除。
    /// 読み直すかは OutputCorrection.presetsChanged が決める）。init からは呼ばない。
    private func changed() {
        reload()
        OutputCorrection.shared.presetsChanged()
    }

    /// 空のフォルダを作る。**入れ子は作らない。**`/` は名前から落とす。
    func addFolder(_ name: String) {
        core.addFolder(name)
        changed()
    }

    func removeFolder(_ name: String) {
        core.removeFolder(name)
        changed()
    }

    /// フォルダの名前を替える。**全部移すか、何も動かさないか。**
    @discardableResult
    func renameFolder(_ old: String, to new: String) -> Bool {
        defer { changed() }
        return core.renameFolder(old, to: new)
    }

    /// 名前を付け替える。**フォルダの出し入れもこれ。**
    @discardableResult
    func rename(_ old: String, to new: String) -> Bool {
        defer { changed() }
        return core.rename(old, to: new)
    }

    func save(_ name: String, chain: [EffeTuneDSP.Node]) {
        guard !chain.isEmpty else { return }
        core.save(name, form: PipelineStore.shortForm(chain))
        changed()
    }

    /// PC のホスト名のフォルダを PC のプリセットの写しにする（PresetStoreCore.mirrorFolder。DSP/RemoteMirror.swift）。
    /// 同じ名前の人のフォルダには触らず `名前 2` へ入れる。返すのは入れたフォルダと変えた本数。
    @discardableResult
    func mirrorFolder(_ hostName: String, incoming: [String: [[String: Any]]],
                      unreadable: Set<String> = []) -> (folder: String, written: Int, deleted: Int) {
        defer { changed() }
        return core.mirrorFolder(hostName, incoming: incoming, unreadable: unreadable)
    }

    /// そのフォルダが PC の写しか（PC へ送り返さない）。
    func isRemoteFolder(_ name: String) -> Bool { core.isRemoteFolder(name) }

    /// save が書く名前（空になるなら nil）。押す前の「もう在る」はこれで確かめる。
    /// save は名前を整えるので、打ったままの名前では在るものを見落とす。
    func savedName(for name: String) -> String? { core.savedName(for: name) }

    func load(_ name: String) -> [PipelineStore.Loaded] {
        guard let raw = core.form(named: name) else { return [] }
        return PipelineStore.parse(raw, catalog: ETCatalog)
    }

    func remove(_ name: String) {
        core.remove(name)
        changed()
    }

    /// 貼られた字から鎖を読む。直したもの・落としたもの（ETChainText.Report）も返す。
    /// JSFXをdesc:の名前で指した段は、取り込んであるJSFXで引く（CHAIN.md）。
    func importFrom(_ text: String) -> (items: [PipelineStore.Loaded], report: ETChainText.Report) {
        ETShareLink.parseChecked(text, catalog: ETCatalog, jsfx: ETJSFXHost.shared.chainResolver())
    }

    // MARK: - ファイルとのやり取り（ETBackup）

    /// 書き出し用。入れ物の中身をそのまま返す。
    /// 上流の包み方（`{ plugins: [...] }`）は ETBackup が被せる。
    func exported() -> [String: Any] { core.exported() }

    /// 読み込み。**名前ごとに入れ替える。**ファイルに無い名前はそのまま残す。
    /// 返すのは入れた本数。
    @discardableResult
    func merge(_ incoming: [String: [[String: Any]]]) -> Int {
        defer { changed() }
        return core.merge(incoming)
    }
}
