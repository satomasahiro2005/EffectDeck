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
    @StateObject private var store = PresetStore.shared

    @State private var newName = ""

    /// 押されたものをここで束ねる。ユーザーのものと EffeTune のものを
    /// 同じ経路へ流すため。
    private enum Pending {
        case user(String)
        case system(ETSystemPreset)

        var name: String {
            switch self {
            case .user(let name):    return name
            case .system(let preset): return preset.name
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
            case .overwrite(let name): return "overwrite:" + name
            case .loadUser(let name): return "load:" + name
            case .confirmDelete(let name): return "delete:" + name
            }
        }

        var title: String {
            switch self {
            case .importClipboard, .emptyClipboard: return "Import chain"
            case .failed:                           return "Could not load"
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
            case .failed(let why):
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
    @State private var dialog: Dialog?

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
    /// 1 本も残らなかったときは黙って閉じずに理由を出す。
    /// 共有リンクの取り込みだけは**置き換え**。鎖まるごとの写しなので、
    /// 足すと二重になる（上流も読み込みは置き換え）。
    private func importChain(_ text: String) {
        let loaded = store.importFrom(text)
        if loaded.isEmpty {
            dialog = .failed("Nothing readable on the clipboard.")
        } else {
            dsp.replaceChain(with: loaded)
            dismiss()
        }
    }

    private func load(_ what: Pending) {
        let loaded: [PipelineStore.Loaded]
        switch what {
        case .user(let name):     loaded = store.load(name)
        case .system(let preset): loaded = ETShareLink.parse(preset.json, catalog: ETCatalog)
        }
        guard !loaded.isEmpty else {
            dialog = .failed("“\(what.name)” could not be read. "
                              + "None of its effects are available here.")
            return
        }
        // **読み方が 2 通りある。**同じ経路に流してはいけない。
        //
        //   ユーザー … 鎖そのものを保存したもの。読んだら**置き換える**。
        //   同梱     … 鎖の一部として足すもの。名前の付いた Section に包んで**足す**
        //              （EffeTune の ui.pluginPresets と同じ扱い）。
        //
        // 以前は両方 addPreset に流していたので、自分で保存した鎖を読んでも
        // いまの鎖の後ろに Section として積まれ、置き換わらなかった。
        switch what {
        case .user:   dsp.replaceChain(with: loaded)
        case .system: dsp.addPreset(named: what.name, items: loaded)
        }
        dismiss()
    }

    var body: some View {
        NavigationStack {
            List {
                saveSection
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
                   isPresented: Binding(get: { dialog != nil },
                                        set: { if !$0 { dialog = nil } }),
                   presenting: dialog) { what in
                switch what {
                case .importClipboard(let text):
                    Button("Cancel", role: .cancel) {}
                    Button("Import") { importChain(text) }
                case .emptyClipboard, .failed:
                    Button("OK", role: .cancel) {}
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
        }
    }

    // MARK: - 節

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
            // 押せないボタンだけ置くと、壊れているのか条件があるのか読めない。
            // 同じ名前で保存すると前のものが黙って消えるので、押す前に言う。
            if dsp.chain.isEmpty {
                Text("There is nothing to save yet. Add an effect first.")
            } else if !trimmedName.isEmpty && store.names.contains(trimmedName) {
                Text("A preset named “\(trimmedName)” already exists. Saving replaces it.")
            }
        }
    }

    private var userSection: some View {
        Section {
            if store.names.isEmpty {
                // 空でも 1 行出す。上流も空のときに言う（ui.pluginPresets.noUserPresets）。
                Text("No saved presets")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.names, id: \.self) { name in
                    Button {
                        request(.user(name))
                    } label: {
                        Text(name).foregroundStyle(.primary)
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
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Delete", role: .destructive) { dialog = .confirmDelete(name) }
                        Button("Overwrite") { dialog = .overwrite(name) }
                            .tint(.blue)
                    }
                }
            }
        } header: {
            Text("User Presets")
        }
    }

    private var systemSection: some View {
        Section {
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
        } footer: {
            Text("Adds to the end of the current chain instead of replacing it.")
        }
    }

    private var webSection: some View {
        Section {
            if let url = ETShareLink.url(for: dsp.chain) {
                ShareLink(item: url) {
                    Label("Share this chain", systemImage: "square.and.arrow.up")
                }
            }
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
            Text("EffeTune on the web")
        } footer: {
            Text("A shared chain opens in EffeTune, and one made there opens here.")
        }
    }
}
