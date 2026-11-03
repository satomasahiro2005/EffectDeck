//  PresetStoreCore.swift
//  名前を付けた鎖の入れ物の中身。**Foundationだけ。**
//
//  PresetStore.swift から出した。あちらは画面が観測する ObservableObject（Combine は
//  Linux に無い）で、鎖の Node からショート形式を作るのと、貼られた字の読み込みを持つ。
//  こちらは入れ物（ETKeyValueStorage）と iCloud への当て方（CloudPatch）を受け取って、
//  名前の出し入れだけをする（PresetStoreTests）。
//
//  入れ物の形は `presets = { "<名前>": [ ショート形式の段 … ] }`。
//  **フォルダは名前の付け方だけで表す**（`Rock/Heavy`、ETUserPresetName）。
//
//  出力先との紐付けは端末だけに持つ。iCloudへもバックアップへも出さない
//  （uidはこの端末の機器の番号、プリセットの一覧は端末ごとに違う）。
//  入れ物は ETOutputCorrectionStoreCore（OutputCorrectionCore.swift）。ここは名前の付け替え・
//  消すに紐付けを付いていかせるだけ。

import Foundation

final class PresetStoreCore {

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

    /// PC の写しのフォルダ（mirrorFolder が作った・中を入れ替えてよいもの）を覚えておく鍵。
    ///
    /// **名前だけで「PC のもの」と決めない。**PC のホスト名と同じ名前のフォルダを人が
    /// 前から持っていたら、丸ごと入れ替えると人のプリセットが消える。写したことのある
    /// フォルダだけをここに持ち、ここに無い同じ名前のフォルダには触らない（mirrorTarget）。
    /// **iCloud へは写さない**（emptyFoldersKey と同じ）。入れ直して iCloud から戻った
    /// 写しは人のフォルダの扱いになり、次の写しは `名前 2` へ入る（消えるより良い）。
    static let remoteFoldersKey = "presetRemoteFolders"

    private let storage: ETKeyValueStorage
    private let patch: CloudPatch

    /// 出力補正の紐付け（端末だけ）。名前の付け替え・消すに付いていく。**patch は呼ばない。**
    private var corrections: ETOutputCorrectionStoreCore { ETOutputCorrectionStoreCore(storage: storage) }

    /// `storage` は手元の入れ物（アプリでは UserDefaults.standard）。
    /// `patch` は iCloud へ触った項目だけを当てる口（アプリでは CloudMirror.patch）。
    init(storage: ETKeyValueStorage, patch: @escaping CloudPatch) {
        self.storage = storage
        self.patch = patch
    }

    // MARK: - 読む

    /// 保存してある名前（並べ替え済み）。
    var names: [String] { dict().keys.sorted() }

    /// 中身の無いフォルダ（並べ替え済み）。**中身が入ったものは、もう空ではない。**
    var emptyFolders: [String] {
        let used = Set(names.map(ETUserPresetName.folder))
        return storedEmptyFolders().filter { !used.contains($0) }.sorted()
    }

    /// 保存してあるショート形式。無ければ nil。
    func form(named name: String) -> Any? { dict()[name] }

    // MARK: - フォルダ

    /// 空のフォルダを作る。**入れ子は作らない。**`/` は名前から落とす。
    func addFolder(_ name: String) {
        let clean = ETUserPresetName.clean(name)
        guard !clean.isEmpty else { return }
        var list = storedEmptyFolders()
        guard !list.contains(clean) else { return }
        list.append(clean)
        storage.set(list, forKey: Self.emptyFoldersKey)
    }

    /// その名前のフォルダが在るか（プリセットが入っているものと、空のもの）。
    func folderExists(_ name: String) -> Bool {
        names.contains { ETUserPresetName.folder($0) == name } || storedEmptyFolders().contains(name)
    }

    func removeFolder(_ name: String) {
        let list = storedEmptyFolders().filter { $0 != name }
        storage.set(list, forKey: Self.emptyFoldersKey)
        pruneRemoteFolders()
    }

    /// フォルダの名前を替える。**中のプリセットを全部付け替える。**
    /// 入れ物という実体が無いので、まとめて名前を書き替えるのがそのまま移動になる。
    ///
    /// **全部移すか、何も動かさないか。**前は 1 本ずつ rename していて、確かめる名前
    /// （`X/B/C`）と rename が書く名前（正規化した `X/B C`）が違った。`A/B/C` のような
    /// 名前（バックアップや web から入る。前の save も打ったまま入れていた）が混ざると
    /// ぶつかる相手を見落とし、何本か動かしたところで黙って止まり、それでも true を返していた。
    ///
    /// 今は先に移す先の名前を全部決め（rename と同じ ETUserPresetName.normalized）、
    /// 動かさない名前・移す先どうしのどちらかとぶつかれば何も書かずに false。
    /// ぶつからなければ手元へ 1 回、iCloud へ 1 回で書く。
    @discardableResult
    func renameFolder(_ old: String, to new: String) -> Bool {
        let target = ETUserPresetName.clean(new)
        guard !target.isEmpty, target != old else { return false }
        // **既に在るフォルダの名前へは付け替えない。**付け替えると2つのフォルダが黙って
        // 1つにまとまる（名前がぶつかるときだけ断っていた）。「その名前は使われている」で断る。
        guard !folderExists(target) else { return false }

        var d = dict()
        let moving = d.keys.filter { ETUserPresetName.folder($0) == old }.sorted()
        var moved: [(from: String, to: String, form: Any)] = []
        for full in moving {
            guard let form = d.removeValue(forKey: full) else { continue }
            let to = ETUserPresetName.normalized(target + "/" + ETUserPresetName.leaf(full))
            guard !to.isEmpty else { return false }
            moved.append((full, to, form))
        }
        // 動かさない名前（d に残っている）と、移す先どうしの両方を見る。
        // `A/B C` と `A/B/C` はどちらも `X/B C` になる。
        var taken = Set(d.keys)
        for m in moved {
            guard taken.insert(m.to).inserted else { return false }
        }

        if !moved.isEmpty {
            for m in moved { d[m.to] = m.form }
            write(d)
            patch(Self.key, moved.map { CloudChange(path: [$0.from], value: nil) }
                          + moved.map { CloudChange(path: [$0.to], value: $0.form) })
            // 出力補正の紐付けも動かした先へ付いていく。
            corrections.retarget(moved.map { (from: $0.from, to: Optional($0.to)) })
        }
        if emptyFolders.contains(old) {
            removeFolder(old)
            addFolder(target)
        }
        // 付け替えた先は人のフォルダ。前に同じ名前を写していても、もう PC のものにしない。
        releaseRemoteFolder(target)
        pruneRemoteFolders()
        return true
    }

    // MARK: - フォルダの写し

    /// PC の写しのフォルダ（並べ替え済み）。今も在るものだけ。
    var remoteFolders: [String] {
        let existing = existingFolders()
        return storedRemoteFolders().filter(existing.contains).sorted()
    }

    /// そのフォルダが PC の写しか（中が PC に入れ替えられる・PC へ送り返さない）。
    func isRemoteFolder(_ name: String) -> Bool {
        !name.isEmpty && storedRemoteFolders().contains(name) && folderExists(name)
    }

    /// PC のホスト名 `base` の写しを入れるフォルダ。**人のフォルダは選ばない。**
    ///   1. `base`・`base 2` … のうち、前に写した（PC のもの）で今も在るもの
    ///   2. 無ければ、前に写したか、まだ無いもののうち最初
    /// 同じ名前の人のフォルダが在れば `base 2` へずれる。決まらなければ nil。
    func mirrorTarget(for base: String) -> String? {
        let clean = ETUserPresetName.clean(base)
        guard !clean.isEmpty else { return nil }
        let owned = Set(storedRemoteFolders())
        let existing = existingFolders()
        let candidates = [clean] + (2...99).map { "\(clean) \($0)" }
        if let mine = candidates.first(where: { owned.contains($0) && existing.contains($0) }) {
            return mine
        }
        return candidates.first { owned.contains($0) || !existing.contains($0) }
    }

    /// PC のホスト名 `base` のフォルダを丸ごと `incoming` の写しにする（PC の EffeTune のプリセット。
    /// DSP/RemoteMirror.swift）。入れる先は mirrorTarget（**同じ名前の人のフォルダには触らない**）。
    /// 中身はそのフォルダの中だけ足す・上書き・消す。**ほかのフォルダと直下には触らない。**
    /// 決め方は PresetFolderMirror.plan。手元へ 1 回、iCloud へは変わった名前だけ 1 本ずつ当てる。
    /// 返すのは入れたフォルダ（入れなかったら空）と変えた本数（入れ替えた・足した / 消した）。
    @discardableResult
    func mirrorFolder(_ base: String, incoming: [String: [[String: Any]]],
                      unreadable: Set<String> = []) -> (folder: String, written: Int, deleted: Int) {
        guard let folder = mirrorTarget(for: base) else { return ("", 0, 0) }
        claimRemoteFolder(folder)
        var d = dict()
        let plan = PresetFolderMirror.plan(folder: folder, incoming: incoming, existing: d,
                                           unreadable: unreadable)
        if !plan.write.isEmpty || !plan.delete.isEmpty {
            for name in plan.delete { d.removeValue(forKey: name) }
            for (name, form) in plan.write { d[name] = form }
            write(d)
            if !plan.delete.isEmpty {
                patch(Self.key, plan.delete.sorted().map { CloudChange(path: [$0], value: nil) })
                // PC から消えたものに紐付けた出力補正は外す。
                corrections.retarget(plan.delete.map { (from: $0, to: nil) })
            }
            // 1 本ずつ当てる（merge と同じ。まとめると、大きさの上限に当たったときに 1 本も写らない）。
            for name in plan.write.keys.sorted() {
                patch(Self.key, [CloudChange(path: [name], value: plan.write[name])])
            }
        }
        // 空の PC でもフォルダは見えるようにする（中身が入れば名前の側に現れる）。
        if !folderExists(folder) { addFolder(folder) }
        return (folder, plan.write.count, plan.delete.count)
    }

    // MARK: - 1 本ずつ

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
        patch(Self.key, [CloudChange(path: [old], value: nil),
                         CloudChange(path: [target], value: form)])
        corrections.retarget([(from: old, to: target)])
        pruneRemoteFolders()
        return true
    }

    /// 名前を付けて残す。同じ名前は置き換わる。
    /// 返すのは入れた名前（入れなかったら nil）。
    ///
    /// **名前は `フォルダ/名前` の形に整えてから入れる**（rename と同じ
    /// ETUserPresetName.normalized）。前は打ったまま入れていたので `A/B/C` が入り、
    /// フォルダの付け替えが確かめ損ねる名前の元になっていた。
    ///
    /// **既に在る名前そのものなら、その名前へ上書きする。**一覧から選んだプリセットの
    /// 上書き（PresetsView の Overwrite）は保存してある名前をそのまま渡す。前の版や
    /// バックアップが入れた `A/B/C` を整えてから書くと、上書きのつもりが `A/B C` という
    /// 別の 1 本になり、元の 1 本も残る。
    @discardableResult
    func save(_ name: String, form: [[String: Any]]) -> String? {
        var d = dict()
        guard let key = savedName(for: name, in: d), !form.isEmpty else { return nil }
        d[key] = form
        write(d)
        patch(Self.key, [CloudChange(path: [key], value: form)])
        return key
    }

    /// save が書く名前。空になる名前は nil。
    ///
    /// **押す前に「もう在る」を言うのはこれで確かめる。**save は名前を整えるので、
    /// 打ったままの名前で確かめると `Live/ Set 1` は在ると言われないまま
    /// `Live/Set 1` を上書きする。
    func savedName(for name: String) -> String? {
        savedName(for: name, in: dict())
    }

    private func savedName(for name: String, in d: [String: Any]) -> String? {
        let key = d[name] != nil ? name : ETUserPresetName.normalized(name)
        return key.isEmpty ? nil : key
    }

    func remove(_ name: String) {
        var d = dict()
        d.removeValue(forKey: name)
        write(d)
        patch(Self.key, [CloudChange(path: [name], value: nil)])
        corrections.retarget([(from: name, to: nil)])
        pruneRemoteFolders()
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
        // **1 本ずつ当てる。**まとめると、大きさの上限に当たったときに 1 本も写らない。
        for (name, entries) in touched {
            patch(Self.key, [CloudChange(path: [name], value: entries)])
        }
        return touched.count
    }

    // MARK: - 入れ物

    private func dict() -> [String: Any] {
        storage.dictionary(forKey: Self.key) ?? [:]
    }

    private func storedEmptyFolders() -> [String] {
        storage.object(forKey: Self.emptyFoldersKey) as? [String] ?? []
    }

    /// 在るフォルダ全部（プリセットが入っているものと、空のもの）。
    private func existingFolders() -> Set<String> {
        Set(names.map(ETUserPresetName.folder)).subtracting([""]).union(storedEmptyFolders())
    }

    private func storedRemoteFolders() -> [String] {
        storage.object(forKey: Self.remoteFoldersKey) as? [String] ?? []
    }

    private func claimRemoteFolder(_ name: String) {
        var list = storedRemoteFolders()
        guard !list.contains(name) else { return }
        list.append(name)
        storage.set(list, forKey: Self.remoteFoldersKey)
    }

    private func releaseRemoteFolder(_ name: String) {
        let list = storedRemoteFolders()
        guard list.contains(name) else { return }
        storage.set(list.filter { $0 != name }, forKey: Self.remoteFoldersKey)
    }

    /// 消えたフォルダを PC のものから外す。**後で人が同じ名前のフォルダを作っても、
    /// それを PC の写しと取り違えて入れ替えない。**
    private func pruneRemoteFolders() {
        let list = storedRemoteFolders()
        guard !list.isEmpty else { return }
        let existing = existingFolders()
        let kept = list.filter(existing.contains)
        if kept.count != list.count { storage.set(kept, forKey: Self.remoteFoldersKey) }
    }

    /// 手元へ書く。**iCloud へは写さない。**
    ///
    /// 写すのは触った名前だけ（patch）。辞書をまるごと写すと、
    /// 手元の分が iCloud の分を置き換えて、別の端末に在るものが消える。
    private func write(_ d: [String: Any]) {
        storage.set(d, forKey: Self.key)
    }
}

/// フォルダを PC の写しにするときの決め方。**入れ物に触らない純粋な関数**（PresetStoreTests）。
enum PresetFolderMirror {

    struct Plan {
        /// 書く名前（`フォルダ/名前`）→ ショート形式。変わらないものは入れない。
        var write: [String: [[String: Any]]] = [:]
        /// 消す名前（`フォルダ/名前`）。フォルダの中だけ。
        var delete: [String] = []
    }

    /// 入れ物に入る名前。`フォルダ/名前` の名前の側は `/` を落とす（入れ子は作らない）。
    /// 名前が空になるものは nil。
    static func storeName(folder: String, leaf: String) -> String? {
        let name = ETUserPresetName.clean(leaf)
        return name.isEmpty ? nil : ETUserPresetName.normalized(folder + "/" + name)
    }

    /// - Parameters:
    ///   - folder: フォルダの名前（整えてあるもの。空なら何もしない）
    ///   - incoming: PC のプリセット（PC の名前 → ショート形式）
    ///   - existing: 入れ物の中身（名前 → ショート形式。全部）
    ///   - unreadable: 一覧には在ったが読めなかった PC の名前。**今ある写しを消さずに残す**
    ///
    /// 入れ物の名前が重なる PC の名前（`A/B` と `A B` はどちらも `PC/A B`）は、並びの先のほうだけ入れる。
    /// 中身が同じなら書かない（iCloud へ無駄に当てない）。
    static func plan(folder: String, incoming: [String: [[String: Any]]], existing: [String: Any],
                     unreadable: Set<String> = []) -> Plan {
        var plan = Plan()
        guard !folder.isEmpty else { return plan }
        var keep = Set<String>()
        for leaf in unreadable {
            if let name = storeName(folder: folder, leaf: leaf) { keep.insert(name) }
        }
        var target = Set<String>()
        for leaf in incoming.keys.sorted() {
            guard let form = incoming[leaf], !form.isEmpty,
                  let name = storeName(folder: folder, leaf: leaf),
                  target.insert(name).inserted else { continue }
            if let there = existing[name], same(there, form) { continue }
            plan.write[name] = form
        }
        plan.delete = existing.keys
            .filter { ETUserPresetName.folder($0) == folder && !target.contains($0) && !keep.contains($0) }
            .sorted()
        return plan
    }

    /// 中身が同じか。鍵の順を固定した JSON で比べる（NSNumber の型の違いは値で見る）。
    private static func same(_ a: Any, _ b: Any) -> Bool {
        guard JSONSerialization.isValidJSONObject(a), JSONSerialization.isValidJSONObject(b),
              let x = try? JSONSerialization.data(withJSONObject: a, options: [.sortedKeys]),
              let y = try? JSONSerialization.data(withJSONObject: b, options: [.sortedKeys]) else { return false }
        return x == y
    }
}
