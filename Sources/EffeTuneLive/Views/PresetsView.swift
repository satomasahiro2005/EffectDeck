//  PresetsView.swift
//  名前を付けた鎖の出し入れと、共有リンクのやり取り。
//
//  保存する中身は EffeTune のユーザープリセットと同じショート形式なので、
//  ここで作ったものを共有リンクにして web 版で開けるし、逆もできる。
//
//  見出しは上流の呼び方に合わせる。上流は「System Presets」「User Presets」で
//  （js/locales/en.json5 の ui.title.systemPresets / ui.title.userPresets）、
//  "Built-in" はこちらが勝手に付けていた言葉だった。

import SwiftUI
import UIKit

struct PresetsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var dsp: EffeTuneDSP
    /// PC の鎖を編集している間（PipelineView が渡す）。Output Correction の画面へそのまま渡す。
    var isRemote: Bool = false
    @StateObject private var store = PresetStore.shared

    @State private var newName = ""

    /// 押されたものをここで束ねる。ユーザーのものと EffeTune のものを
    /// 同じ経路へ流すため。
    private enum Pending {
        case user(String)
        case system(ETSystemPreset)
        /// 同梱の JSFX を全部並べた鎖。**json では書けない**（鍵は取り込んだ
        /// ファイルの sha なので、固定の字にできない）。その場で組む。
        case debugJSFX

        var name: String {
            switch self {
            case .user(let name):    return name
            case .system(let preset): return preset.name
            case .debugJSFX:         return "JSFX Host Test"
            }
        }
    }
    /// 出している 1 枚。**重ねないために 1 つの状態にまとめてある。**
    /// 読めなかったことを List の末尾の節で知らせる形だと、押した行が上の方に
    /// あるぶん画面の外に出て、何も起きなかったようにしか見えない。
    private enum Dialog: Identifiable {
        case importClipboard(String)
        case emptyClipboard
        case failed(String)
        /// 読めたが、直したもの・落としたものがある（ETChainText.Report.message）。
        /// 鎖はもう入れ替えてあり、OKで閉じる。**黙って直さない。**
        case imported(String)
        /// いまの鎖で、この名前のプリセットを置き換える。
        case overwrite(String)
        /// 読むと鎖が置き換わる（ユーザープリセットのみ）。
        case loadUser(String)
        /// 消す。取り消しが無いので必ず聞く。
        case confirmDelete(String)

        var id: String {
            switch self {
            case .importClipboard: return "import"
            case .emptyClipboard:  return "empty"
            case .failed(let why): return "failed:" + why
            case .imported(let note): return "imported:" + note
            case .overwrite(let name): return "overwrite:" + name
            case .loadUser(let name): return "load:" + name
            case .confirmDelete(let name): return "delete:" + name
            }
        }

        var title: String {
            switch self {
            case .importClipboard, .emptyClipboard: return "Import chain"
            case .failed:                           return "Could not load"
            case .imported:                         return "Chain imported"
            case .overwrite(let name):              return "Overwrite “\(name)”?"
            case .loadUser(let name):               return "“\(name)”"
            case .confirmDelete(let name):          return "Delete “\(name)”?"
            }
        }

        var message: String {
            switch self {
            case .importClipboard:
                return "Replace the current chain with what is on the clipboard?"
            case .emptyClipboard:
                return "The clipboard is empty."
            case .failed(let why), .imported(let why):
                return why
            case .overwrite:
                return "The saved preset is overwritten with the chain you have now."
            case .loadUser:
                return "Load it into the chain, or overwrite it with the chain you have now?"
            case .confirmDelete:
                return "This cannot be undone, and it removes the preset from your other devices too."
            }
        }
    }
    /// 出している1枚。**書いてもその場では出さない。**出ているものが閉じてから出る
    /// （ETAlertQueue。下の.alertの.onChangeが次の回に出す）。
    /// 取り込みの確認のImportの中で控えや断りを立てると、閉じる側の書き戻しが同じ回で
    /// nilにして、何も出ていなかった。名前を打たせる.alertのSaveから出す断りも同じ道を通す。
    private var dialog: Dialog? {
        get { dialogs.current }
        nonmutating set {
            if let newValue { dialogs.present(newValue) } else { dialogs.dismissed() }
        }
    }
    @State private var dialogs = ETAlertQueue<Dialog>()
    /// 下の.alertのisPresented。書き戻しには、組んだときに出していた1枚の番号を添える
    /// （ETAlertQueue.closed）。前の1枚の書き戻しが遅れて来ても、次の1枚を消さない。
    private var dialogShown: Binding<Bool> {
        let ticket = dialogs.ticket
        return Binding(get: { dialogs.current != nil },
                       set: { if !$0 { dialogs.closed(ticket) } })
    }
    /// 名前を打たせているもの。Rename と新しいフォルダで使い回す。
    @State private var naming: Naming?
    @State private var typed = ""

    /// 名前を打たせる用件。
    private enum Naming: Identifiable {
        case rename(String)
        case renameFolder(String)
        case newFolder
        var id: String {
            switch self {
            case .rename(let n):       return "rename:" + n
            case .renameFolder(let n): return "folder:" + n
            case .newFolder:           return "folder"
            }
        }
        var title: String {
            switch self {
            case .rename:       return "Rename preset"
            case .renameFolder: return "Rename folder"
            case .newFolder:    return "New folder"
            }
        }
    }

    /// 手で組み直さずに見るための鎖（DSP/DebugPresets.swift）。**Debug ビルドだけ。**
    ///
    /// 出す形は出荷時のものと同じにしてある（ETSystemPreset に包む）ので、
    /// 選んだあとの道は 1 本で済む。category は下の見出しに使う。
    private var debugPresets: [ETSystemPreset] {
        #if DEBUG
        return ETDebugPresets.all.map {
            ETSystemPreset(category: "Debug", name: $0.name,
                           effectCount: ETShareLink.parse($0.json, catalog: ETCatalog).count,
                           json: $0.json)
        }
        #else
        return []
        #endif
    }

    /// 同梱の JSFX が何本あるか。0 本なら札を出さない。
    private var jsfxFixtureCount: String {
        let n = ETJSFXHost.shared.debugPresetItems().count
        return n == 0 ? "" : countLabel(n)
    }

    private var systemCategories: [String] {
        var seen = Set<String>()
        return ETSystemPresets.compactMap { seen.insert($0.category).inserted ? $0.category : nil }
    }

    private func systemPresets(in category: String) -> [ETSystemPreset] {
        ETSystemPresets.filter { $0.category == category }
    }

    private var trimmedName: String {
        newName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && !dsp.chain.isEmpty
    }

    private func countLabel(_ count: Int) -> String {
        count == 1 ? "1 effect" : "\(count) effects"
    }

    // MARK: - 読み込み

    /// **ユーザープリセットは先に聞く。**読むと鎖が置き換わるので、
    /// いま組んでいるものが消える。同梱のほうは足すだけなので何も壊れず、
    /// 確認を出すと押す回数が増えるだけ。
    private func request(_ what: Pending) {
        switch what {
        case .user(let name): dialog = .loadUser(name)
        case .system:         load(what)
        case .debugJSFX:      load(what)
        }
    }

    /// **鎖を置き換えない。いまの鎖へ足す。**
    ///
    /// 上流 preset-manager.js:78 addPresetToPipeline がそうしている。
    /// プリセット名を付けた Section で包んで挿入するので、何も壊れない。
    /// だから確認も要らない（以前はここで確認を出していたが、同じ View に
    /// .alert と .confirmationDialog が 3 枚重なり、後ろの .alert が
    /// 出なくなっていた。このリポジトリで 3 度目の踏み方）。
    ///
    /// 知らないエフェクトが混じっていれば PipelineStore.parse が黙って落とすので、
    /// 1 本も残らなかったときは黙って閉じずに理由を出す。置けなかった段があれば
    /// それを名指しする（"Not found: JSFX tape wobble."。ETChainImportResult）。
    /// 共有リンクの取り込みだけは**置き換え**。鎖まるごとの写しなので、
    /// 足すと二重になる（上流も読み込みは置き換え）。
    ///
    /// 取り込みの確認のImportから呼ぶ。出す1枚は確認が閉じてから出る（dialogの注記）。
    private func importChain(_ text: String) {
        let (loaded, report) = store.importFrom(text)
        switch ETChainImportResult.of(loaded: loaded.count, report: report,
                                      unreadable: "Nothing readable on the clipboard.") {
        case .failed(let why):
            dialog = .failed(why)
        case .done:
            dsp.replaceChain(with: loaded)
            dismiss()
        case .imported(let note):
            // 直したもの・落としたものがあれば、閉じる前に1行だけ出す（ChatGPTに組ませた鎖）。
            dsp.replaceChain(with: loaded)
            dialog = .imported(note)
        }
    }

    private func load(_ what: Pending) {
        let loaded: [PipelineStore.Loaded]
        switch what {
        case .user(let name):     loaded = store.load(name)
        case .system(let preset): loaded = ETShareLink.parse(preset.json, catalog: ETCatalog)
        case .debugJSFX:          loaded = ETJSFXHost.shared.debugPresetItems()
        }
        guard !loaded.isEmpty else {
            dialog = .failed("“\(what.name)” could not be read. "
                              + "None of its effects are available here.")
            return
        }
        // **この画面から選んだものは、どちらも置き換える。**
        //
        // 足すほうはエフェクト一覧の側に移した（末尾の User Presets /
        // System Presets）。あちらは名前の付いた Section に包んで挿す。
        // 同じ操作が 2 か所で違う意味になると、どちらを押したのか
        // 分からなくなるので、画面ごとに 1 つの意味に寄せる。
        //
        //   この画面     … 鎖ごと置き換える
        //   エフェクト一覧 … 組として足す
        dsp.replaceChain(with: loaded)
        dismiss()
    }

    var body: some View {
        NavigationStack {
            List {
                saveSection
                outputCorrectionSection
                userSection
                systemSection
                webSection
                // 持ち出す / 戻す（BackupSection.swift）。**Settings ではなくここ。**
                // 扱っているのは設定ではなく、この画面と同じ「保存した鎖」。
                ETBackupSection()
            }
            .navigationTitle("Presets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            // **提示は 1 枚だけ。** 同じ View に .alert や .confirmationDialog を
            // 重ねると、後ろに付けたものが出なくなる。このリポジトリで 3 度踏んでいる
            // （PipelineView.swift:27-30 と IRReverbView.swift:79-80 に記録がある）。
            // 取り込みの確認と、読めなかったときの知らせを 1 つの .alert に束ねる。
            .alert(dialog?.title ?? "",
                   isPresented: dialogShown,
                   presenting: dialog) { what in
                switch what {
                case .importClipboard(let text):
                    Button("Cancel", role: .cancel) {}
                    Button("Import") { importChain(text) }
                case .emptyClipboard, .failed:
                    Button("OK", role: .cancel) {}
                case .imported:
                    Button("OK", role: .cancel) { dismiss() }
                case .overwrite(let name):
                    Button("Cancel", role: .cancel) {}
                    Button("Overwrite", role: .destructive) {
                        store.save(name, chain: dsp.chain)
                    }
                case .loadUser(let name):
                    Button("Cancel", role: .cancel) {}
                    // **両方ここに出す。**上書きはスワイプの中にしか無く、
                    // 見つけられなかった。押すのが一番自然な操作なので、
                    // 向きの選択もそこで済ませる。名前は打たせない。
                    // **赤は 1 つだけ。**両方赤だと差が出ない。
                    // 読むのは戻せる（もう一度読めばいい）。
                    // 上書きは保存したものが消えて戻せないので、そちらを赤にする。
                    Button("Load") { load(.user(name)) }
                    Button("Overwrite", role: .destructive) {
                        store.save(name, chain: dsp.chain)
                    }
                case .confirmDelete(let name):
                    Button("Cancel", role: .cancel) {}
                    Button("Delete", role: .destructive) { store.remove(name) }
                }
            } message: { what in
                Text(what.message)
            }
            // 頼まれた1枚を出す。**出ていた1枚が消えた回に鳴り、出すのはその次の回。**
            // .alertが「閉じた」と「次の1枚」を同じ回で受けると、次の1枚が出ない（AlertQueue.swift）。
            .onChange(of: dialogs.canAdvance) { _, ready in
                if ready { Task { @MainActor in dialogs.advance() } }
            }
            // **名前を打たせるのは別の提示にする。**同じ .alert に混ぜると
            // 用件ごとにボタンの並びが変わって読みにくい。出す条件が
            // 重ならないので、2 枚目でも潰し合わない。
            .alert(naming?.title ?? "",
                   isPresented: Binding(get: { naming != nil },
                                        set: { if !$0 { naming = nil } }),
                   presenting: naming) { what in
                TextField("Name", text: $typed)
                    .textInputAutocapitalization(.words)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    switch what {
                    case .rename(let old):
                        // 入れ物はそのまま、名前だけ替える。
                        let folder = ETUserPresetName.folder(old)
                        let leaf = ETUserPresetName.clean(typed)
                        guard !leaf.isEmpty else { return }
                        let target = folder.isEmpty ? leaf : folder + "/" + leaf
                        if !store.rename(old, to: target) {
                            dialog = .failed("There is already a preset called “\(target)”.")
                        }
                    case .renameFolder(let old):
                        if !store.renameFolder(old, to: typed) {
                            dialog = .failed("That folder name is already taken.")
                        }
                    case .newFolder:
                        store.addFolder(typed)
                    }
                }
            }
        }
    }

    // MARK: - 節

    /// 出力補正への入口。**押して別の画面へ進むだけで、ここでは何も読み込まない。**
    /// 前はこの画面の節で直に選ばせていて、プリセットの行を押すと鎖ごと読み込まれる
    /// （この画面の本来の動き）ので、補正を選ぶつもりで使う人の鎖を置き換えてしまった。
    /// 選ぶ所は OutputCorrectionList（OutputCorrectionView.swift）で、main の鎖には触らない。
    /// 補正の中身はユーザープリセットなので、口はプリセットのシートに置く（⋯ のメニューではなく）。
    /// 紐付けが無いと鎖の下の出力補正の行が出ないので、最初の紐付けはここから始める。
    /// Save のすぐ下に、自分だけの節で置く（プリセットの一覧に混ぜると、押すと読み込む行に見える）。
    private var outputCorrectionSection: some View {
        Section {
            NavigationLink {
                OutputCorrectionList(isRemote: isRemote)
            } label: {
                Label("Output Correction", systemImage: "headphones")
            }
        }
    }

    private var saveSection: some View {
        Section {
            HStack {
                TextField("Preset name", text: $newName)
                    .textInputAutocapitalization(.words)
                Button("Save") {
                    store.save(trimmedName, chain: dsp.chain)
                    newName = ""
                }
                .disabled(!canSave)
            }
        } header: {
            Text("Save current chain")
        } footer: {
            // 同じ名前で保存すると前のものが黙って消えるので、押す前に言う。
            if !dsp.chain.isEmpty && !trimmedName.isEmpty && store.names.contains(trimmedName) {
                Text("A preset named “\(trimmedName)” already exists. Saving replaces it.")
            }
        }
    }

    private var userSection: some View {
        Section {
            if store.names.isEmpty && store.emptyFolders.isEmpty {
                // 空でも 1 行出す。上流も空のときに言う（ui.pluginPresets.noUserPresets）。
                Text("No saved presets")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                // **見出しも中身も 1 本の ForEach に混ぜる。**並べ替えは
                // ForEach ごとに閉じているので、フォルダをまたいで動かすには
                // 動かす範囲が 1 つでないといけない。
                //
                // **落とし先は自分で作らない。**dropDestination も onDrop も
                // onInsert も、同じ List の中で完結する drag では受け取らない
                // （実機で測ってある。掴んだ足跡は出るのに受け側が 0 件）。
                // List が元から持っている並べ替えに乗せて、**落ちた位置の直上の
                // 行から入る先を引く。**長押しでそのまま掴めるので、先に
                // 編集モードへ入る必要は無い。
                //
                // 順番そのものは保存しない。保存は名前をキーにした辞書で、
                // 並びは辞書順に決まる。ここで見ているのは落ちた場所だけ。
                ForEach(entries) { entry in
                    switch entry.kind {
                    case .folder:
                        // **見出しは動かさない。**フォルダの並びは名前で決まり、
                        // 未分類は常に先頭。掴めてしまうと、動かせるのに何も
                        // 起きない形になる。
                        folderHeader(folderNamed(entry.name))
                            .moveDisabled(true)
                    case .preset:
                        presetRow(entry.name, in: entry.folder)
                    case .placeholder:
                        // **空のフォルダにも行を 1 つ置く。**見出しの下が空だと
                        // List はそこへ挿し込む位置を作らず、とくに最下部の
                        // 空フォルダには入れようがなかった。
                        // **ここは moveDisabled にしない。**動かせない行が並びの
                        // 末尾にあると、その後ろへ落とす位置が作られない。
                        // 最下部の空フォルダにだけ入れられなかったのがこれ。
                        // 掴めてしまうが、moveEntry が中身以外を無視する。
                        Text("Move a preset here")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 20)
                    }
                }
                .onMove { source, destination in
                    moveEntry(source, to: destination)
                }
            }
        } header: {
            HStack(spacing: 14) {
                Text("User Presets")
                Spacer()
                // **Edit は置かない。**長押しでそのまま掴めるので、
                // 先にモードへ入る必要が無い。
                Button("New Folder") { typed = ""; naming = .newFolder }
                    .font(.footnote)
                    .textCase(nil)
            }
        }
    }

    /// プリセット 1 行。
    private func presetRow(_ name: String, in folder: String) -> some View {
        Button {
            request(.user(name))
        } label: {
            Text(ETUserPresetName.leaf(name))
                .foregroundStyle(.primary)
                // フォルダの中は字下げする。線を引かずに所属を出す。
                .padding(.leading, folder.isEmpty ? 0 : 20)
        }
        // **.onDelete を使わない。** あれは消す相手を
        // 「ForEach の何番目か」という位置で渡し、行を消す
        // アニメーションを List が自分で先に走らせる。前の削除が
        // 終わる前に次を払うと、List が抱えている行の集合が
        // ForEach へ渡した配列より短くなったまま戻らず、
        // 位置がその短い並びの中で数えられて**別の行が消える**。
        // 鎖の側で同じ壊れ方を捕まえてある（PipelineView の remove(_:)）。
        // 身元（名前）で消せば List の内部状態に左右されない。
        // **上書きに名前を打たせない。** 同じ名前を入力欄へ
        // 打ち直す形だと、保存するたびに綴りを合わせる作業が要る。
        // 消すのと同じ場所に置けば、新しい作法を覚えなくて済む。
        // **完全スワイプで消さない**（allowsFullSwipe: false）。
        // 払い切っただけで消えるうえ、取り消しが無く、iCloud 経由で
        // 他の端末からも消える。押して選ばせる。
        //
        // **先に書いたものが端に近い側へ出る。**画面の左から
        // Rename / Overwrite / Delete と読めるよう逆から書く。
        // 壊す操作は指がいちばん届く端に置かない。
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Delete", role: .destructive) { dialog = .confirmDelete(name) }
            Button("Overwrite") { dialog = .overwrite(name) }
                .tint(.blue)
            Button("Rename") {
                typed = ETUserPresetName.leaf(name)
                naming = .rename(name)
            }
            .tint(.indigo)
        }
    }

    /// フォルダの見出し。**入れ物だと分かる形にする。**
    @ViewBuilder
    private func folderHeader(_ folder: (name: String, items: [String])) -> some View {
        if folder.name.isEmpty {
            // フォルダが 1 つも無いうちは、仕切りを出す意味が無い。
            if orderedFolders.count > 1 {
                Label("Uncategorized", systemImage: "tray")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        } else {
            Label {
                HStack(spacing: 6) {
                    Text(folder.name).font(.system(size: 13, weight: .semibold))
                    if folder.items.isEmpty {
                        Text("empty").font(.caption).foregroundStyle(.tertiary)
                    }
                }
            } icon: {
                Image(systemName: "folder")
            }
            .foregroundStyle(.secondary)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                // 中身が残っていても消せる。**プリセットは消さない。**
                Button("Delete Folder", role: .destructive) {
                    deleteFolder(folder.name, items: folder.items)
                }
                Button("Rename") {
                    typed = folder.name
                    naming = .renameFolder(folder.name)
                }
                .tint(.indigo)
            }
        }
    }

    /// 画面に出す 1 行。見出しも中身も同じ並びに入れる。
    private struct Entry: Identifiable {
        enum Kind { case folder, preset, placeholder }
        let kind: Kind
        /// 見出しと受け皿はフォルダ名、中身はプリセットのフルネーム。
        let name: String
        /// この行が属するフォルダ。未分類は空。
        let folder: String

        var id: String {
            switch kind {
            case .folder:      return "f:" + name
            case .preset:      return "p:" + name
            case .placeholder: return "e:" + name
            }
        }
    }

    private var entries: [Entry] {
        var out: [Entry] = []
        for f in orderedFolders {
            out.append(Entry(kind: .folder, name: f.name, folder: f.name))
            for item in f.items {
                out.append(Entry(kind: .preset, name: item, folder: f.name))
            }
            if f.items.isEmpty && !f.name.isEmpty {
                out.append(Entry(kind: .placeholder, name: f.name, folder: f.name))
            }
        }
        return out
    }

    private func folderNamed(_ name: String) -> (name: String, items: [String]) {
        orderedFolders.first { $0.name == name } ?? (name, [])
    }

    /// 並べ替えの着地から、入る先のフォルダを決める。
    ///
    /// **順番は保存しない。**保存しているのは名前をキーにした辞書で、並びは
    /// 辞書順に決まる。ここで見ているのは「どこへ落ちたか」だけで、落ちた
    /// 位置の直上にある行のフォルダが、入る先になる。見出しのすぐ下なら
    /// そのフォルダ、誰かの下ならその人と同じフォルダ、いちばん上なら未分類。
    private func moveEntry(_ source: IndexSet, to destination: Int) {
        let list = entries
        guard let from = source.first, from < list.count else { return }
        let moved = list[from]
        // 動かせるのは中身だけ。見出しも受け皿も並びを持たない。
        guard moved.kind == .preset else { return }

        // destination は**抜く前**の並びでの挿し込み位置なので、直上は
        // そのまま destination - 1。動かしている本人は数えずに上へ辿る。
        var folder = ""
        var i = destination - 1
        while i >= 0 {
            if i != from, i < list.count {
                folder = list[i].kind == .folder ? list[i].name : list[i].folder
                break
            }
            i -= 1
        }
        withAnimation { move(moved.name, into: folder) }
    }

    /// `/` の前でフォルダに束ねる。**中身の無いフォルダも出す。**
    /// 作った直後に画面から消えると、作れたのかどうか分からない。
    private var userFolders: [(name: String, items: [String])] {
        var out = ETUserPresetName.folders(store.names)
        for empty in store.emptyFolders where !out.contains(where: { $0.name == empty }) {
            out.append((empty, []))
        }
        return out
    }

    /// 画面に出す順。**未分類が先頭。**名前の辞書順に混ぜると、フォルダの
    /// あいだに挟まって「どこにも入っていないもの」に見えなくなる。
    private var orderedFolders: [(name: String, items: [String])] {
        userFolders.sorted { a, b in
            if a.name.isEmpty != b.name.isEmpty { return a.name.isEmpty }
            return a.name < b.name
        }
    }

    /// フォルダを消す。**中身のプリセットは消さない。**
    /// 入れ物だけ無くして、中身は未分類へ出す。取り返しが付く形にしておく。
    private func deleteFolder(_ name: String, items: [String]) {
        for full in items { move(full, into: "") }
        store.removeFolder(name)
    }

    /// フォルダへ入れる／出す。**名前を付け替えるだけ。**
    private func move(_ name: String, into folder: String) {
        let leaf = ETUserPresetName.leaf(name)
        let target = folder.isEmpty ? leaf : folder + "/" + leaf
        guard target != name else { return }
        if !store.rename(name, to: target) {
            dialog = .failed("There is already a preset called “\(target)”.")
        }
    }

    private var systemSection: some View {
        Section {
            // 見るための鎖を先に置く（Debug ビルドだけ空でない）。
            if !debugPresets.isEmpty || !jsfxFixtureCount.isEmpty {
                DisclosureGroup("Debug") {
                    // **同梱の JSFX を全部載せた鎖。**上の 3 本は EffeTune の
                    // エフェクトだけなので、JSFX を見るにはこちらが要る。
                    if !jsfxFixtureCount.isEmpty {
                        Button {
                            request(.debugJSFX)
                        } label: {
                            HStack {
                                Text("JSFX Host Test").foregroundStyle(.primary)
                                Spacer(minLength: 8)
                                Text(jsfxFixtureCount)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    ForEach(debugPresets) { preset in
                        Button {
                            request(.system(preset))
                        } label: {
                            HStack {
                                Text(preset.name).foregroundStyle(.primary)
                                Spacer(minLength: 8)
                                Text(countLabel(preset.effectCount))
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            ForEach(systemCategories, id: \.self) { category in
                DisclosureGroup(category) {
                    ForEach(systemPresets(in: category)) { preset in
                        Button {
                            request(.system(preset))
                        } label: {
                            HStack {
                                Text(preset.name).foregroundStyle(.primary)
                                Spacer(minLength: 8)
                                // 数字だけ置かない。何を数えたのか読めない。
                                Text(countLabel(preset.effectCount))
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        } header: {
            Text("System Presets")
        }
    }

    private var webSection: some View {
        // 出力補正が入っていれば（入切が切・リモート中は空）、鎖だけか補正込みかを選ばせる。
        let corrected = !dsp.correction.isEmpty
        let mainExternal = dsp.chain.lazy.filter(\.isExternal).count
        let externalCount = mainExternal + (corrected ? dsp.correction.lazy.filter(\.isExternal).count : 0)
        return Section {
            HStack {
                Text("Compatibility")
                Spacer()
                HStack(spacing: 5) {
                    Image(systemName: externalCount == 0 ? "checkmark.circle.fill"
                                                           : "exclamationmark.triangle.fill")
                    Text(externalCount == 0 ? "EffeTune" : "EffectDeck only")
                        .font(.subheadline.weight(.medium))
                }
                .foregroundStyle(externalCount == 0 ? Color.green : Color.orange)
            }
            // **共有はいつも effectdeck.nemut.ai のリンク。**アプリが入っていれば Universal Link で
            // そのまま開き、入っていなければ鎖の中身と App Store へのページになる。
            // PC の EffeTune で開く人には、そのページが AU と JSFX を落とした EffeTune のリンクを出す
            // （site/src/parse.js の effeTuneLink。落とし方は ETShareLink.effeTuneForm と同じ）。
            // 以前は内蔵だけの鎖を effetune.frieve.com のリンクで出していたので、iPhone で押すと
            // EffeTune の Web 版が開き、EffectDeck へはコピーして戻るしかなかった。
            if corrected {
                correctedShareRows()
            } else if let deck = ETShareLink.deckURL(for: dsp.chain) {
                ShareLink(item: deck) {
                    Label("Share this chain", systemImage: "square.and.arrow.up")
                }
            }
            // 鎖を ChatGPT に組ませる口（Build with ChatGPT…）はプリセットの口ではない。結果は
            // プリセットとして保存されず、クリップボード経由で鎖として読み込まれる（ClipboardBanner）ので、
            // エフェクト一覧（Available Effects）の Effects の面の頭と、空の鎖の表示に置いてある。
            // ここは共有するための節で、デスクトップの EffeTune へもリンクのページから渡せるので "Share" と呼ぶ。
            Button {
                // **@State を立てるだけで終わっていた。** それを読む View が無く、
                // 押しても確認も知らせも出ないまま何も起きなかった。
                // 下の .alert（提示は 1 枚だけ）へ流す。
                let text = UIPasteboard.general.string ?? ""
                dialog = text.isEmpty ? .emptyClipboard : .importClipboard(text)
            } label: {
                Label("Import from clipboard", systemImage: "doc.on.clipboard")
            }
        } header: {
            Text("Share")
        }
    }

    /// 出力補正が入っているときの共有の行。「鎖だけ」と「鎖＋出力補正」の 2 つから選ぶ Menu にする。
    /// 補正込みは main・終端・補正を 1 本の普通の鎖に平らげたもの（ETOutputCorrectionForm.flatten）で、
    /// 受け手には出力先の身元は付かない。
    @ViewBuilder
    private func correctedShareRows() -> some View {
        let flat = ETOutputCorrectionForm.flatten(main: dsp.chain.map { PipelineStore.Loaded($0) },
                                                  correction: dsp.correction.map { PipelineStore.Loaded($0) })
        Menu {
            if let deck = ETShareLink.deckURL(for: dsp.chain) {
                ShareLink("Chain", item: deck)
            }
            if let deck = ETShareLink.deckURL(for: flat) {
                ShareLink("Chain + Output Correction", item: deck)
            }
        } label: {
            Label("Share this chain", systemImage: "square.and.arrow.up")
        }
    }
}
