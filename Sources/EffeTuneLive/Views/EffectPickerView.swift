//  EffectPickerView.swift
//  足すエフェクトを選ぶ。
//
//  EffeTune は左に Available Effects をずっと出しているが、iPhone の幅では
//  鎖と並べられないのでシートにした。
//
//  以前は横のページ送りで 1 カテゴリずつ出していたが、
//  他に何があるのかが見えず、選ぶのが難しかった。
//  今は全カテゴリを縦に並べている。上の帯は飛び先。
//
//  Section も一覧に出す。上流でも Control カテゴリの一員として並んでいる
//  （plugins/control/section.js）。

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct EffectPickerView: View {
    let onPick: (ETEffect) -> Void
    let onPickAU: (ETAUHost.Entry) -> Void
    let onPickJSFX: (ETJSFXHost.Entry) -> Void
    /// プリセットを選んだ。名前と中身を渡す。受けた側が Section に包んで挿す。
    let onPickPreset: (String, [PipelineStore.Loaded]) -> Void
    /// 上の段階のどれを出すか。**持ち主はPipelineView。**共有の拡張・「このアプリで開く」・
    /// /jのリンクでJSFXが入ったとき、あちらがPluginsを指して開く（開いていればその場で替わる）。
    /// ここに@Stateで持っていたときは、いつもEffectsで開き、入ったものを探させていた。
    @Binding var pane: Pane
    /// 取り込んだばかりのJSFX（id）。Pluginsでその作者の見出しへ送り、行を塗る。
    @Binding var fresh: String?

    @StateObject private var presets = PresetStore.shared

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @StateObject private var dsp = EffeTuneDSP.shared
    @StateObject private var au = ETAUHost.shared
    @StateObject private var jsfx = ETJSFXHost.shared
    /// PC の鎖を編集しているあいだは AU / JSFX を出さない。PC の EffeTune では鳴らせない。
    @ObservedObject private var remote = RemoteMirror.shared
    @State private var query = ""
    /// 出している提示。**1 枚しか持たない**（上の .alert を読むこと）。
    private enum Alert: Equatable {
        case link
        case failed(String)
        case shareFailed(String)
    }
    /// **書いてもその場では出さない。**出ているものが閉じてから出る（ETAlertQueue。
    /// 下の.alertの.onChangeが次の回に出す）。From LinkのImportの中で断りを立てると、
    /// 閉じる側の書き戻しが同じ回でnilにして、"That does not look like a link."が出ていなかった。
    private var alert: Alert? {
        get { alerts.current }
        nonmutating set {
            if let newValue { alerts.present(newValue) } else { alerts.dismissed() }
        }
    }
    @State private var alerts = ETAlertQueue<Alert>()
    /// 下の.alertのisPresented。書き戻しには、組んだときに出していた1枚の番号を添える
    /// （ETAlertQueue.closed）。前の1枚の書き戻しが遅れて来ても、次の1枚を消さない。
    private var alertShown: Binding<Bool> {
        let ticket = alerts.ticket
        return Binding(get: { alerts.current != nil },
                       set: { if !$0 { alerts.closed(ticket) } })
    }
    @State private var linkText = ""

    private var alertTitle: String {
        switch alert {
        case .link:        return "Import from Link"
        case .failed:      return "Could Not Import"
        case .shareFailed: return "Could Not Share"
        case nil:          return ""
        }
    }
    @State private var importingJSFX = false
    /// 消そうとしている JSFX。取り消せないので一度確かめる（IR と同じ形）。
    @State private var pendingDeleteJSFX: ETJSFXHost.Entry?
    /// ソースを開いているJSFX（行の…のView Source）。
    @State private var viewingSource: ETJSFXHost.Entry?

    /// 上の段階の切り替え。効果 / プラグイン / プリセット。
    ///
    /// プリセットの面には自分のもの（User Presets）だけを並べ、同梱のもの（System Presets）は
    /// 一覧の末尾の 1 行から押し込んだ先の画面に出す。
    /// 以前は User と Factory の 2 面だったが、探しに来た人に先にどちらかを当てさせていた。
    /// 次に 1 本の List へ縦に並べたが、群の見出し（User / System）とフォルダ・カテゴリの見出しの
    /// 2 段が 1 列に潰れて、どこからどこまでが同梱のものか読みにくかった。
    /// 呼び名は上流に合わせて System（js/locales/en.json5 の ui.title.systemPresets）。
    /// "Factory" はこちらが勝手に付けた言葉だった。
    /// rawValue はどこにも保存していない（持ち主の PipelineView は @State）ので、.user / .system からの移行は要らない。
    enum Pane: String, CaseIterable, Identifiable {
        case effects, plugins, presets
        var id: String { rawValue }
        var label: String {
            switch self {
            case .effects: return "Effects"
            case .plugins: return "Plugins"
            case .presets: return "Presets"
            }
        }
    }
    /// 検索が出ているか。**畳むために持つ。**
    /// 検索が出ている間はシートを閉じられない（下の row のコメント）ので、
    /// 先にこれを false にしてから閉じる。`.searchable(text:isPresented:)` は
    /// iOS 17 から。
    @State private var searching = false
    /// 開いたときの高さ。一覧を探すのが主な用途なので広めに取る。
    /// 半分だと一度に 4〜5 行しか見えず、カテゴリを跨ぐのに何度も擦ることになる。
    private static let opened = PresentationDetent.fraction(0.75)
    @State private var detent: PresentationDetent = Self.opened


    /// 帯を押したときの飛び先。
    /// 同じ名前を連打しても飛べるよう、回数も一緒に持つ。
    /// 同じ値を入れ直しても onChange は鳴らないため。
    private struct Jump: Equatable {
        var name = ""
        var count = 0
    }
    @State private var jump = Jump()

    /// いま画面の上にあるカテゴリ。帯の塗り分けに使う。
    /// 一覧を払うと追従し、帯を押すと一覧が飛ぶ。両方向で繋がる。
    @State private var current = ""

    /// Pluginsで帯から飛んだ後、まだ指で払っていないか。立っている間は見出しでcurrentを書き換えない。
    /// 末尾の作者は行が少なく、着いた先で下の作者の見出しも画面に入るので、押した作者の塗りが奪われていた。
    @State private var jumping = false
    /// Pluginsの一覧を、払った直後の慣性中でも飛ばす（ETScrollBrake）。
    @State private var brake = ETScrollBrake()
    /// Pluginsの一覧の枠から安全領域を除いた高さ。末尾に空ける量を決める。
    /// 行が見えるのは下の検索欄の上端までで、それよりは低い（シミュレータで284ptに対し370pt）。
    @State private var pluginListHeight: CGFloat = 0

    /// 出すもの。カーネルとして登録されている型に Section を足したもので、
    /// 中身は dsp が決めている（EffeTuneDSP.swift:142）。
    /// Section だけカーネルが無いのは、音を触らないから
    /// （上流も plugins/control/section.js の processor は `return data;` だけ）。
    private var catalog: [ETEffect] { dsp.available.filter { !Self.hiddenTypes.contains($0.type) } }

    /// カーネルは居るが、まだ選ばせない型。**カタログからは消さない**（プリセット・共有リンク・
    /// PC から届いた鎖が名指すと読めなくなる）。ここで一覧に出さないだけ。
    /// SFZ Note Player（2.13.0）は SFZ 音源の取り込みがまだ無い。資産が無いと dry（既定 20%）だけを
    /// 鳴らすので、取り込みを入れるまでは一覧に出さない。
    static let hiddenTypes: Set<String> = ["SFZNotePlayerPlugin"]

    /// 効果のカテゴリ。**Section の居る control も上流と同じく「Control」で並べる。**
    /// 一度「Grouping」と呼び替えて末尾に分けたが、EffeTune に慣れた人は Control の中を探す。
    private var categories: [String] {
        Array(Set(catalog.map(\.category))).sorted()
    }

    // MARK: - 探す
    //
    // **段の区別を越えて探す。**上の 3 つの段（効果・プラグイン・プリセット）は
    // 「並べて眺めるとき」の分け方で、名前で探すときには
    // 邪魔でしかない。探しているものがどの段に居るかを先に当てさせる作りだった。
    //
    // **当たり方で並べる。**ただ contains で拾うと、打った字を含むだけのものが
    // 名前そのものより上に来る。当たり方に順位を付けて、同じ順位の中では名前順。

    /// 当たり方。**強い順**。生の値の小ささがそのまま強さになる。
    private enum Hit: Int, Comparable {
        /// 名前がそのもの。
        case exact = 0
        /// 名前の頭から。
        case prefix = 1
        /// 名前の中の、語の頭から（"Band" が "Five Band PEQ" に当たる）。
        case word = 2
        /// 名前のどこか。
        case inside = 3
        /// 名前ではない所（作者・分類・説明）。
        case elsewhere = 4

        static func < (a: Hit, b: Hit) -> Bool { a.rawValue < b.rawValue }
    }

    /// 名前に対する当たり方。当たらなければ nil。
    private static func hit(_ name: String, _ q: String) -> Hit? {
        let n = name.lowercased()
        guard !q.isEmpty else { return .inside }
        if n == q { return .exact }
        if n.hasPrefix(q) { return .prefix }
        guard n.contains(q) else { return nil }
        // 語の頭か。区切りは空白と、括弧・ハイフンなど名前に出るもの。
        let separators = CharacterSet(charactersIn: " -_/()[]")
        for word in n.components(separatedBy: separators) where word.hasPrefix(q) {
            return .word
        }
        return .inside
    }

    /// 探した結果の 1 件。どの段のものかを持ったまま並べる。
    private enum Found: Identifiable {
        case effect(ETEffect)
        case au(ETAUHost.Entry)
        case jsfx(ETJSFXHost.Entry)
        /// 自分のプリセット。`フォルダ/名前` のまま持つ。
        case user(String)
        case system(ETSystemPreset)

        var id: String {
            switch self {
            case .effect(let e): return "e:" + e.id
            case .au(let a):     return "a:" + a.id
            case .jsfx(let j):   return "j:" + j.id
            case .user(let n):   return "u:" + n
            case .system(let p): return "s:" + p.name
            }
        }

        var sortName: String {
            switch self {
            case .effect(let e): return e.name
            case .au(let a):     return a.name
            case .jsfx(let j):   return j.name
            case .user(let n):   return ETUserPresetName.leaf(n)
            case .system(let p): return p.name
            }
        }
    }

    private var searchResults: [Found] {
        let q = query.lowercased()
        var out: [(Hit, Found)] = []

        for e in catalog {
            if let h = Self.hit(e.name, q) { out.append((h, .effect(e))); continue }
            if e.about.lowercased().contains(q) || e.category.lowercased().contains(q) {
                out.append((.elsewhere, .effect(e)))
            }
        }
        for a in au.entries where !remote.isRemote {
            if let h = Self.hit(a.name, q) { out.append((h, .au(a))); continue }
            if a.manufacturer.lowercased().contains(q) { out.append((.elsewhere, .au(a))) }
        }
        for j in jsfx.entries where !remote.isRemote {
            if let h = Self.hit(j.name, q) { out.append((h, .jsfx(j))); continue }
            if j.author.lowercased().contains(q) { out.append((.elsewhere, .jsfx(j))) }
        }
        for n in presets.names {
            // フォルダ名でも当たる。`Rock/Heavy` は "rock" でも "heavy" でも出す。
            if let h = Self.hit(ETUserPresetName.leaf(n), q) { out.append((h, .user(n))); continue }
            if ETUserPresetName.folder(n).lowercased().contains(q) {
                out.append((.elsewhere, .user(n)))
            }
        }
        for p in ETSystemPresets {
            if let h = Self.hit(p.name, q) { out.append((h, .system(p))); continue }
            if p.category.lowercased().contains(q) { out.append((.elsewhere, .system(p))) }
        }

        return out.sorted {
            $0.0 == $1.0 ? $0.1.sortName.localizedCaseInsensitiveCompare($1.1.sortName) == .orderedAscending
                         : $0.0 < $1.0
        }.map(\.1)
    }

    var body: some View {
        NavigationStack {
            Group {
                // **縮めている間も中身は消さない。**
                //
                // 前は 90pt のとき Color.clear に差し替えていた。そうすると
                // **掴んだものの絵が出たり出なかったりする。**つまんだ瞬間に
                // 高さを下げていて、絵は掴んだ行を写して作られるので、
                // 写し取る前に行が消えると空になる。速さ次第で分かれる。
                //
                // 90pt で潰れるのは題と検索の欄で、それはナビゲーションバーごと
                // 隠してある（下の .toolbar）。一覧はそのまま置いておけば
                // 切り取られるだけで済む。
                if query.isEmpty {
                    VStack(spacing: 0) {
                        // **上の段階で 3 つに分ける。**効果とプリセットは
                        // 探し方が違う。同じ一覧に混ぜると、効果を探しに来た人が
                        // プリセットまで流し見ることになる。
                        Picker("", selection: $pane) {
                            ForEach(Pane.allCases.filter { !(remote.isRemote && $0 == .plugins) }) {
                                Text($0.label).tag($0)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)

                        switch pane {
                        case .effects:
                            categoryStrip
                            Divider()
                            allSections
                        case .plugins:
                            pluginList
                        case .presets:
                            presetList
                        }
                    }
                } else {
                    // **探すときは段を分けない。**どの段に居るかを当てさせない。
                    searchList
                }
            }
            .onAppear { if current.isEmpty { current = firstCategory(for: pane) } }
            // PC の鎖を編集し始めたら Plugins の面から出す（面の選択肢から消えるため）。
            .onChange(of: remote.isRemote) { _, isRemote in
                if isRemote && pane == .plugins { pane = .effects }
            }
            .onChange(of: pane) { _, selected in
                current = firstCategory(for: selected)
                jump = Jump()
                jumping = false
            }
            .searchable(text: $query, isPresented: $searching, prompt: "Search effects")
            .navigationTitle("Available Effects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                // **右上には何も置かない。**Import JSFX の Menu は前はここ（Plugins の面のときだけ）に
                // 出していたが、「pluginsのシートの右上にボタンがあるのは変」。面ごとに右上が出たり
                // 消えたりもする。Plugins の面の一覧の頭の行へ移した（jsfxImportMenu）。
            }
            .fileImporter(isPresented: $importingJSFX,
                          allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
                do {
                    guard let url = try result.get().first else { return }
                    fresh = try jsfx.importFile(url).id
                    pane = .plugins
                } catch { alert = .failed(error.localizedDescription) }
            }
            // **提示は 1 枚だけにする。**同じ View に .alert を 2 枚積むと、
            // 先に付いたほうが出なくなる。このリポジトリで 4 度目の踏み方
            // （PresetsView.swift:148-151 に 3 度目までの記録がある）。
            // 積んだせいで取り込みの失敗が全部無言になっていた。
            .alert(alertTitle, isPresented: alertShown) {
                    if alert == .link {
                        TextField("https://github.com/…", text: $linkText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        Button("Cancel", role: .cancel) { alert = nil }
                        // fetchLinkがその場で立てる断りは、この1枚が閉じてから出る（alertの注記）。
                        Button("Import") { let text = linkText; alert = nil; fetchLink(text) }
                    } else {
                        Button("OK", role: .cancel) { alert = nil }
                    }
                } message: {
                    switch alert {
                    case .failed(let why), .shareFailed(let why):
                        Text(why)
                    case .link, nil:
                        EmptyView()
                    }
                }
            // 頼まれた1枚を出す。**出ていた1枚が消えた回に鳴り、出すのはその次の回。**
            // .alertが「閉じた」と「次の1枚」を同じ回で受けると、次の1枚が出ない（AlertQueue.swift）。
            .onChange(of: alerts.canAdvance) { _, ready in
                if ready { Task { @MainActor in alerts.advance() } }
            }
            // 一覧と検索結果の両方を覆う階層に 1 つ置く。行ごとに持たせると
            // 検索から払ったときに出ない。
            .confirmationDialog(pendingDeleteJSFX.map { "Delete “\($0.name)”?" } ?? "",
                                isPresented: Binding(
                                    get: { pendingDeleteJSFX != nil },
                                    set: { if !$0 { pendingDeleteJSFX = nil } }),
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let entry = pendingDeleteJSFX { jsfx.removeEntry(entry) }
                    pendingDeleteJSFX = nil
                }
                Button("Cancel", role: .cancel) { pendingDeleteJSFX = nil }
            } message: {
                Text("This cannot be undone.")
            }
            // 確かめと同じ理由でここに置く（一覧・検索結果のどちらの行の…からも出る）。
            .sheet(item: $viewingSource) { entry in
                JSFXSourceView(entry: entry)
            }
        }
        // **半分の高さで出す。** 全画面だと鎖が隠れて、つまんだものを
        // 落とす先が画面に無くなる。上半分に鎖を残す。
        //
        // **NavigationStack の外に付ける。**中身（根の画面）の側に付けると、何かを押し込んだ間は
        // シートが根の画面の指定を読まず、高さや背後の操作の指定が外れることがある。
        .presentationDetents([Self.opened, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: Self.opened))
    }

    /// 下の一覧への飛び先。現在地は見出しが上に張り付いて出すので、
    /// ここでは塗り分けない。
    private var categoryStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(stripNames, id: \.self) { name in
                        Button {
                            jump = Jump(name: name, count: jump.count + 1)
                        } label: {
                            Text(Self.stripLabel(name))
                                .font(.system(size: 13,
                                              weight: current == name ? .semibold : .regular))
                                .foregroundStyle(current == name ? AnyShapeStyle(.white)
                                                                 : AnyShapeStyle(.secondary))
                                .padding(.horizontal, 13)
                                .padding(.vertical, 7)
                                .frame(minHeight: ETMetrics.hitTarget)
                                .background(current == name ? AnyShapeStyle(.tint)
                                                            : AnyShapeStyle(.quaternary),
                                            in: .capsule)
                                .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                        .id("chip-" + name)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
            .onChange(of: jump) { _, now in
                guard !now.name.isEmpty else { return }
                withAnimation { proxy.scrollTo("chip-" + now.name, anchor: .center) }
            }
            .onChange(of: current) { _, now in
                guard !now.isEmpty else { return }
                withAnimation { proxy.scrollTo("chip-" + now, anchor: .center) }
            }
        }
    }

    /// 全カテゴリを縦に並べる。見出しは上に張り付くので、
    /// 払っている間もどこを見ているかが分かる。
    private var allSections: some View {
        ScrollViewReader { proxy in
            List {
                // **鎖を ChatGPT に組ませる口は、エフェクトを選ぶシートの中身に置く。**返ってくるのは
                // 内蔵のエフェクトの鎖なので、エフェクトを探しに来た所の頭が持ち主。⋯ のメニューや
                // ツールバー（右上）には置かない（「…のメニューに置くのは変」）。Presets の面には置かない
                // （返った鎖はプリセットとして保存されず、クリップボードから鎖として読み込まれる。ClipboardBanner）。
                // 説明は足さず、札だけ置く。中国本土の店では出さない（ETStorefrontGate）。
                if ETStorefrontGate.shared.allowsChatGPT {
                    Button("Build with ChatGPT…", systemImage: "sparkles") {
                        openURL(Self.buildChain)
                    }
                }
                if !newEffects.isEmpty {
                    Section {
                        ForEach(Array(newEffects.enumerated()), id: \.element.id) { offset, effect in
                            row(effect, showCategory: true)
                                .id(offset == 0 ? Self.jumpTarget(Self.newKey)
                                                : "effect-" + effect.type)
                        }
                    } header: {
                        Text("New")
                            .onScrollVisibilityChange(threshold: 0.1) { v in
                                if v { current = Self.newKey }
                            }
                    }
                }

                ForEach(categories, id: \.self) { name in
                    Section {
                        let entries = effects(in: name)
                        ForEach(Array(entries.enumerated()), id: \.element.id) { offset, effect in
                            row(effect)
                                .id(offset == 0 ? Self.jumpTarget(name)
                                                : "effect-" + effect.type)
                        }
                    } header: {
                        Text(name.categoryLabel)
                            // 見出しが画面に入ったらそこを現在地にする。
                            // 下へ払えば次の見出しで、上へ払えば前の見出しで切り替わる。
                            .onScrollVisibilityChange(threshold: 0.1) { visible in
                                if visible { current = name }
                            }
                    }
                }

            }
            .listStyle(.plain)
            .onChange(of: jump) { _, now in
                guard !now.name.isEmpty else { return }
                withAnimation { proxy.scrollTo(Self.jumpTarget(now.name), anchor: .top) }
            }
        }
    }

    /// JSFX を取り込む Menu。Plugins の面の一覧の頭の行と、空の面の表示の 2 か所で使う。
    /// 前は右上のツールバーにあったが、「pluginsのシートの右上にボタンがあるのは変」で中身の側へ移した。
    /// 押した後の fileImporter と .alert（From Link・失敗の知らせ）は body の NavigationStack の中身に
    /// 付けてあるので、どこから出しても同じものが開く。
    ///
    /// **ChatGPT に書かせる口は中に入れない。**どちらの場所にもすぐ下に
    /// Write JSFX with ChatGPT の行があるので、Menu の中にもあると同じものが画面に 2 つ並ぶ。
    /// 一覧の行（asRow）では、行の幅いっぱいを押せるようにして字を本文の色にする。
    /// Menu の札は既定では字の上だけが押せて、字も tint で塗られる。隣の Button の行
    /// （Write JSFX with ChatGPT）と押せる範囲も色も揃わなかった。
    private func jsfxImportMenu(asRow: Bool) -> some View {
        Menu {
            Button("From Files", systemImage: "folder") {
                importingJSFX = true
            }
            // **リンクからも入れられる。**GitHub の画面の URL を
            // そのまま貼れる（ETRemoteFile が raw へ読み替える）。
            Button("From Link", systemImage: "link") {
                linkText = UIPasteboard.general.string ?? ""
                alert = .link
            }
            // ChatGPTが書いたものをコピーして戻ってきたとき。
            Button("From Clipboard", systemImage: "doc.on.clipboard") {
                importClipboard()
            }
        } label: {
            if asRow {
                Label {
                    Text("Import JSFX").foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "square.and.arrow.down").foregroundStyle(Color.accentColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            } else {
                Label("Import JSFX", systemImage: "square.and.arrow.down")
            }
        }
        .tint(asRow ? Color.primary : Color.accentColor)
    }

    private var pluginList: some View {
        Group {
            if au.entries.isEmpty && jsfx.entries.isEmpty {
                ContentUnavailableView {
                    Label("No Plugins", systemImage: "waveform")
                } actions: {
                    if ETJSFXHost.isEnabled {
                        // 空のときも一覧の頭と同じ Menu（From Link・From Clipboard もここから）。
                        jsfxImportMenu(asRow: false)
                        if ETStorefrontGate.shared.allowsChatGPT {
                            Button("Write JSFX with ChatGPT", systemImage: "sparkles") {
                                openURL(Self.writeJSFX)
                            }
                        }
                    }
                }
            } else {
                ScrollViewReader { proxy in
                    VStack(spacing: 0) {
                        jumpStrip(pluginVendors)
                        Divider()
                        List {
                            if ETJSFXHost.isEnabled {
                                // **取り込む口は一覧の頭の行。**右上のツールバーには置かない（jsfxImportMenu）。
                                jsfxImportMenu(asRow: true)
                                // **書かせる道があることを、一覧の頭で見せる。**
                                // JSFXは1枚のテキストなので、ChatGPTにJSFX.mdを
                                // 読ませれば通るものが返ってくる。説明は足さず、札だけ置く。
                                if ETStorefrontGate.shared.allowsChatGPT {
                                    Button("Write JSFX with ChatGPT", systemImage: "sparkles") {
                                        openURL(Self.writeJSFX)
                                    }
                                }
                            }
                            ForEach(pluginVendors, id: \.self) { vendor in
                                Section {
                                    ForEach(audioUnits(vendor: vendor)) { auRow($0) }
                                    let scripts = jsfxEntries(vendor: vendor)
                                    ForEach(scripts) { entry in
                                        jsfxRow(entry)
                                            // **消す口。**行はButtonでonDragも付いているので、
                                            // 自前のスワイプを重ねるとタップ・ドラッグ・払いの3つが
                                            // 同じ行で競合する。swipeActionsはList側の仕組みなので競合しない。
                                            //
                                            // **.onDeleteを使わない。**あれはListが先に行を消す。見本では
                                            // onDeleteの中で弾いても行は戻らず、一覧を組み直すまで画面から
                                            // 消えていた（シミュレータ）。確かめでCancelを押したときも同じ形になる。
                                            // ボタンは確かめを出すだけで、行は消えたときにListから消える。
                                            // 押した時点では消さないのでroleは付けず、赤はtintで付ける。
                                            // 完全スワイプでは消さない（取り消しが無い。PresetsViewと同じ）。
                                            // 同梱の見本には出さない（こことremoveEntryの2か所）。
                                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                                if !entry.isDebugFixture {
                                                    Button("Delete") { pendingDeleteJSFX = entry }
                                                        .tint(.red)
                                                }
                                            }
                                    }
                                } header: {
                                    Text(vendor)
                                        .onScrollVisibilityChange(threshold: 0.1) { visible in
                                            if visible && !jumping { current = vendor }
                                        }
                                        // 流れる面の中に付ける（ETScrollBrake）。
                                        .etScrollBrake(brake)
                                        // **帯からの飛び先は見出しに付ける。**JSFXの行は頭がHStack（名前と…）で、
                                        // 頭がHStackの行に付けたidはscrollToが見つけられない（iOS 27のシミュレータで、
                                        // 画面に出ている行でも動かなかった）。chokeholdやnemut.aiのようにJSFXしか無い
                                        // 作者は飛び先がJSFXの行になるので、帯を押しても一覧が全く動かなかった。
                                        .id(Self.jumpTarget(vendor))
                                }
                            }
                        }
                        .listStyle(.plain)
                        // **末尾の作者も上端まで上がれるよう、下を空ける。**
                        // JSFXの作者（chokehold・nemut.ai）はAppleの後ろに並び、行が少ない。
                        // 一覧は下端より先へ流れないので、押しても上端まで来ず、下に居ると全く動かなかった。
                        .contentMargins(.bottom, pluginTailRoom, for: .scrollContent)
                        .onGeometryChange(for: CGFloat.self) {
                            $0.size.height - $0.safeAreaInsets.top - $0.safeAreaInsets.bottom
                        } action: { pluginListHeight = $0 }
                        .onScrollPhaseChange { _, phase in
                            if phase == .interacting { jumping = false }
                        }
                        // 検索から戻ると一覧は作り直される。立てたままだと、新しい一覧の見出しで塗りが動かない。
                        .onDisappear { jumping = false }
                    }
                    // **取り込んだばかりのJSFXの作者へ送る。**開いたときにも、開いている間に届いたときにも走る。
                    // 帯を押したときと同じ道（下のjump）を通す。行ではなく見出しへ送るのも同じ理由
                    // （見出しの.idのコメント）。面が替わった回はonChange(of: pane)がjumpを空に戻す。
                    // taskの中身は非同期で、その回を組み終えてから走るので、戻された後に入れることになる。
                    // 帯の塗りも帯を押したときと同じく先に合わせる。飛んでいる間は見出しでcurrentを
                    // 書き換えない（jumping）ので、入れないと面の最初の作者が塗られたまま残る。
                    .task(id: fresh) {
                        guard let id = fresh, let entry = jsfx.entry(id: id) else { return }
                        let vendor = jsfxVendor(entry)
                        current = vendor
                        jump = Jump(name: vendor, count: jump.count + 1)
                    }
                    .onChange(of: jump) { _, now in
                        guard !now.name.isEmpty else { return }
                        jumping = true
                        // 払った直後の慣性中はscrollToが効かない。止めてから飛ぶ。
                        brake.jump {
                            withAnimation {
                                proxy.scrollTo(Self.jumpTarget(now.name), anchor: .top)
                            }
                        }
                    }
                }
            }
        }
        // **面を開くたびに数え直す。**AU の一覧は起動直後に作ったもので、
        // その後に入れた AU は登録変更の通知が届かないと載らない（Issue #10）。
        // ここで聞き直せば、少なくとも探しに来た時点の登録は一覧に出る。
        .onAppear { au.refresh(reason: "plugins") }
    }

    private var audioUnitVendors: [String] {
        Array(Set(au.entries.map { vendorName($0) })).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private var pluginVendors: [String] {
        Array(Set(audioUnitVendors + jsfx.entries.map { jsfxVendor($0) })).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    /// Pluginsの一覧の下に空ける量。最後の作者の見出しが上端まで上がれるだけ空ける。
    /// **見積もり。**行は44pt（実際は62pt前後）で数えて見出しは数えず、pluginListHeightも
    /// 行が見える高さより低い。シミュレータ（iPhone 17・0.75の高さ）では、最後の作者が3行なら
    /// 上端まで届き、2行で10pt、1行で30ptほど手前で止まった（1行のときは前の作者の見出しが上に残る）。
    /// 一覧の高さぶん丸ごと空けると、一番下まで払ったときに画面が空になる。
    private var pluginTailRoom: CGFloat {
        guard let last = pluginVendors.last else { return 0 }
        let rows = audioUnits(vendor: last).count + jsfxEntries(vendor: last).count
        return max(0, pluginListHeight - CGFloat(rows) * ETMetrics.hitTarget)
    }

    private func vendorName(_ entry: ETAUHost.Entry) -> String {
        let name = entry.manufacturer.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Other" : name
    }

    private func audioUnits(vendor: String) -> [ETAUHost.Entry] {
        au.entries.filter { vendorName($0) == vendor }
    }

    private func jsfxVendor(_ entry: ETJSFXHost.Entry) -> String {
        let author = entry.author.trimmingCharacters(in: .whitespacesAndNewlines)
        return author.isEmpty ? "JSFX" : author
    }

    private func jsfxEntries(vendor: String) -> [ETJSFXHost.Entry] {
        jsfx.entries.filter { jsfxVendor($0) == vendor }
    }

    /// AUv3 and JSFX use the same secondary-line grammar on the Plugins page.
    /// Do not leave a separator behind when a script has no author metadata.
    private func pluginDetail(format: String, author: String) -> String {
        let author = author.trimmingCharacters(in: .whitespacesAndNewlines)
        return author.isEmpty ? format : "\(format) · \(author)"
    }

    private var pluginSearchList: some View {
        let q = query.lowercased()
        let auMatches = au.entries.filter {
            $0.name.lowercased().contains(q) || $0.manufacturer.lowercased().contains(q)
        }
        let jsfxMatches = jsfx.entries.filter {
            $0.name.lowercased().contains(q) || $0.author.lowercased().contains(q)
        }
        return Group {
            if auMatches.isEmpty && jsfxMatches.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List {
                    ForEach(auMatches) { auRow($0) }
                    ForEach(jsfxMatches) { jsfxRow($0) }
                }.listStyle(.plain)
            }
        }
    }

    private func auRow(_ entry: ETAUHost.Entry) -> some View {
        Button {
            searching = false
            Task { @MainActor in onPickAU(entry) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "waveform.badge.plus")
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    // 折り返さない（jsfxPickButtonと同じ）。
                    Text(entry.name).font(.system(size: 15)).foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(pluginDetail(format: "AUv3", author: entry.manufacturer))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .onDrag {
            dismissAfterDragBegins()
            return NSItemProvider(object: ("au:" + entry.id) as NSString)
        } preview: {
            Text(entry.name)
                .font(.system(size: 14, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.thickMaterial, in: .capsule)
        }
    }

    /// JSFXの1行。右に…を置く。**同梱の見本にも置く**（JSFXの行だと一目でわかるように）。
    private func jsfxRow(_ entry: ETJSFXHost.Entry) -> some View {
        HStack(spacing: 0) {
            jsfxPickButton(entry)
            jsfxMenu(entry)
        }
        // 取り込んだばかりの1本は塗って見せる（fresh）。
        .listRowBackground(entry.id == fresh ? Color.accentColor.opacity(0.12) : nil)
        // **両方plainにする。**Listは行の中の既定スタイルのボタンを行1つの当たりに
        // まとめるので、そのままだと…を押しても鎖へ足す側まで走りうる。
        // borderlessは不可。中の.primary・.secondaryがアクセント色の段になり、名前が青くなる。
        .buttonStyle(.plain)
    }

    private func jsfxPickButton(_ entry: ETJSFXHost.Entry) -> some View {
        Button {
            searching = false
            Task { @MainActor in onPickJSFX(entry) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "curlybraces")
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    // 折り返さない。幅が足りないときは縮める（EffectCardViewの名前と同じ）。
                    // 右の…に44pt取られるので、長い名前が2行に折れて行の高さが崩れていた。
                    Text(entry.name).font(.system(size: 15)).foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(pluginDetail(format: "JSFX", author: entry.author))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .onDrag {
            dismissAfterDragBegins()
            return NSItemProvider(object: ("plugin-jsfx:" + entry.id) as NSString)
        } preview: {
            Text(entry.name)
                .font(.system(size: 14, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.thickMaterial, in: .capsule)
        }
        // **長押しに口を置かない。**行の長押しは鎖へのドラッグ（.onDrag）が持っている。
        // 見る・写す・共有・消すは右の…から出す（jsfxMenu）。
    }

    /// JSFX1本の…。見る・写す・共有・消す。
    private func jsfxMenu(_ entry: ETJSFXHost.Entry) -> some View {
        Menu {
            Button("View Source", systemImage: "doc.text.magnifyingglass") {
                viewingSource = entry
            }
            Button("Copy Source", systemImage: "doc.on.doc") {
                // 読めなかったらクリップボードは触らない（前に写したものを消さない）。
                if let text = ETJSFXHost.sourceText(for: entry) {
                    UIPasteboard.general.string = text
                }
            }
            switch jsfx.shareURL(for: entry) {
            case .success(let url)?:
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            case .failure(let error)?:
                // 大きすぎる・読めないときも口は残し、押したら理由を出す。
                Button("Share", systemImage: "square.and.arrow.up") {
                    alert = .shareFailed(error.localizedDescription)
                }
            case nil:
                EmptyView()
            }
            // 同梱の見本は消せない（removeEntryが弾く）。共有もshareURLがnilを返して出ない。
            if !entry.isDebugFixture {
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) {
                    pendingDeleteJSFX = entry
                }
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
                // 横だけ広げる。縦に広げるとAUの行より背が高くなる。
                .frame(minWidth: ETMetrics.hitTarget, alignment: .trailing)
                .contentShape(Rectangle())
        }
        // buttonStyle(.plain)を効かせるため（jsfxRow）。
        .menuStyle(.button)
    }

    /// プリセットの面。**自分のもの（User Presets）の後に、同梱のもの（System Presets）を続けて並べる。**
    /// 上の帯で自分のフォルダと同梱のもののジャンルへ飛べる。開いたときは List の頭（User Presets の先頭）。
    private var presetList: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                // 帯は自分のフォルダ（2 つ以上のときだけ）と、同梱のもののジャンル。
                chipStrip(presetChips)
                Divider()
                List {
                    userSections
                    // **同梱のものも同じ一覧に続けて並べる。**押し込んだ先の画面に分けると、
                    // ジャンルの帯が出ず、System Presets の行も直前のフォルダの 1 件に見えた（2026-10-08）。
                    systemSections
                }
                .listStyle(.plain)
            }
            .onChange(of: jump) { _, now in
                guard !now.name.isEmpty else { return }
                withAnimation { proxy.scrollTo(Self.jumpTarget(now.name), anchor: .top) }
            }
        }
    }

    /// 自分で保存したプリセット。`/` で仕切るとフォルダごとの節にする。
    /// **空でも節は出す。**1 行だけの空の表示を置き、その下に System Presets へ進む行が続く。
    @ViewBuilder
    private var userSections: some View {
        let folders = userFolders
        if folders.isEmpty {
            Section {
                Text("No user presets")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                presetHeader(group: "User Presets", title: nil)
                    // 空の表示が見えているあいだは、帯のどれも塗らない。
                    .onScrollVisibilityChange(threshold: 0.1) { visible in
                        if visible { current = "" }
                    }
            }
        } else {
            ForEach(folders, id: \.name) { folder in
                let key = Self.userChipKey(folder.name)
                // 先頭の節にだけ群の名前。仕切っていないものは、フォルダが他にあるときだけ "Others" と呼ぶ。
                let group: String? = folder.name == folders.first?.name ? "User Presets" : nil
                let title: String? = folder.name.isEmpty ? (folders.count > 1 ? "Others" : nil)
                                                         : folder.name
                Section {
                    ForEach(Array(folder.items.enumerated()), id: \.element) { offset, name in
                        presetRow(name: ETUserPresetName.leaf(name),
                                  payload: "preset:user:" + name) {
                            PresetStore.shared.load(name)
                        }
                        .id(offset == 0 ? Self.jumpTarget(key) : "user-preset-" + name)
                    }
                } header: {
                    presetHeader(group: group, title: title)
                        .onScrollVisibilityChange(threshold: 0.1) { visible in
                            if visible { current = key }
                        }
                }
            }
        }
    }

    /// 同梱のプリセット。Presets の面で自分のものの後に続ける。上流の分け方をそのまま節の見出しにし、
    /// 先頭の節にだけ群の名前（System Presets）を付ける（自分のものの User Presets と同じ段）。
    /// 行は自分のものと同じ presetRow なので、押せば入り、つまめば鎖へ落とせる。
    @ViewBuilder
    private var systemSections: some View {
        let categories = systemCategories
        ForEach(categories, id: \.self) { category in
            let key = Self.systemChipKey(category)
            Section {
                if category == Self.debugJSFXCategory {
                    // **Debugの版だけ。**見出し（systemCategories）はDebugでしか出ないが、
                    // 呼ぶ側を囲わないとDebugPresets.swiftの鎖の字がReleaseにも入る
                    // （Scripts/check_release_binary.shのdebugonlyが見る）。
                    #if DEBUG
                    presetRow(name: "JSFX Host Test",
                              payload: "preset:debug:jsfx-host") {
                        jsfx.debugPresetItems()
                    }
                    .id(Self.jumpTarget(key))
                    // 手で組み直さずに見るための鎖（DSP/DebugPresets.swift）。
                    ForEach(Array(ETDebugPresets.all.enumerated()), id: \.offset) {
                        _, item in
                        presetRow(name: item.name,
                                  payload: "preset:debug:" + item.name) {
                            ETShareLink.parse(item.json, catalog: ETCatalog)
                        }
                    }
                    #endif
                } else {
                    let inCategory = ETSystemPresets.filter { $0.category == category }
                    ForEach(Array(inCategory.enumerated()), id: \.element.id) { offset, preset in
                        presetRow(name: preset.name,
                                  payload: "preset:system:" + preset.name) {
                            ETShareLink.parse(preset.json, catalog: ETCatalog)
                        }
                        .id(offset == 0 ? Self.jumpTarget(key) : "system-preset-" + preset.name)
                    }
                }
            } header: {
                // 先頭の節にだけ群の名前（User Presets と同じ段）。
                presetHeader(group: category == categories.first ? "System Presets" : nil,
                             title: category.categoryLabel)
                    .onScrollVisibilityChange(threshold: 0.1) { visible in
                        if visible { current = key }
                    }
            }
        }
    }

    /// プリセットの面の節の見出し。**先頭の節にだけ、群の名前（User Presets）を上に付ける。**
    /// 群の名前だけの節を別に作ると、中身の無い節が出来て飛び先も塗り分けも合わなくなる。
    private func presetHeader(group: String?, title: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let group { Text(group).font(.headline) }
            if let title { Text(title) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// プリセットの面の帯。自分のフォルダ（仕切っていなければ User Presets の 1 つ）と、同梱のもののジャンル。
    /// フォルダが 2 つ以上のとき、仕切っていないものは節の見出しと同じ "Others"。
    private var presetChips: [JumpChip] {
        let folders = userFolders
        let user: [JumpChip]
        if folders.count > 1 {
            user = folders.map { JumpChip(key: Self.userChipKey($0.name),
                                          label: $0.name.isEmpty ? "Others" : $0.name) }
        } else if let only = folders.first {
            // 仕切っていない（フォルダが 1 つ）。自分のもの全体へ飛ぶ帯を 1 つだけ出す。
            user = [JumpChip(key: Self.userChipKey(only.name), label: "User Presets")]
        } else {
            user = []
        }
        let system = systemCategories.map { JumpChip(key: Self.systemChipKey($0), label: $0.categoryLabel) }
        return user + system
    }

    /// 帯の飛び先の鍵。仕切っていないものは folder が空なので、頭に "user:" を付けて
    /// 「どれも塗らない」（current が空）と区別する。
    static func userChipKey(_ folder: String) -> String { "user:" + folder }
    /// 同梱のもののジャンルの鍵。自分のフォルダの名前とぶつからないように頭を分ける。
    static func systemChipKey(_ category: String) -> String { "system:" + category }

    /// 帯の 1 つ。key が飛び先と塗り分けの鍵（current）、label が字。
    private struct JumpChip: Identifiable {
        let key: String
        let label: String
        var id: String { key }
    }

    /// 面の上に出す飛び先の帯。効果のジャンル帯と同じ作り。
    private func jumpStrip(_ names: [String]) -> some View {
        chipStrip(names.map { JumpChip(key: $0, label: $0.categoryLabel) })
    }

    private func chipStrip(_ chips: [JumpChip]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chips) { chip in
                    Button {
                        current = chip.key
                        jump = Jump(name: chip.key, count: jump.count + 1)
                    } label: {
                        Text(chip.label)
                            .font(.system(size: 13,
                                          weight: current == chip.key ? .semibold : .regular))
                            .foregroundStyle(current == chip.key ? AnyShapeStyle(.white)
                                                                 : AnyShapeStyle(.secondary))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 7)
                            .frame(minHeight: ETMetrics.hitTarget)
                            .background(current == chip.key ? AnyShapeStyle(.tint)
                                                            : AnyShapeStyle(.quaternary),
                                        in: .capsule)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        }
    }

    private var systemCategories: [String] {
        var seen = Set<String>()
        let regular = ETSystemPresets.compactMap {
            seen.insert($0.category).inserted ? $0.category : nil
        }
        #if DEBUG
        // 見るための鎖は JSFX が無くても出す。
        return [Self.debugJSFXCategory] + regular
        #else
        return regular
        #endif
    }

    static let debugJSFXCategory = "Debug"

    /// 上の帯に並べるもの。**新しいものを先頭に置く。**
    /// 上流が増やした効果は、ジャンルに散らばると見つけられない。
    private var stripNames: [String] {
        (newEffects.isEmpty ? [] : [Self.newKey]) + categories
    }

    /// この版で増えた効果。増えるたびにここを書き替える。
    /// 「New」の節に出すもの。**上流で足されたばかりのものだけ。**
    ///
    /// 空にすると節ごと出ない（jumpKeys と allSections がどちらも
    /// `newEffects.isEmpty` を見る）。上流が新しいものを足したときに、
    /// その型をここへ並べる。**一度足したら、次の版で必ず外すこと。**
    /// いつまでも「New」と出ていると意味を失う。
    /// いまは dsp 0.13.0（EffeTune 2.13.0）で足された Adaptive Prediction。もう 1 つの SFZ Note Player は
    /// まだ一覧に出さない（hiddenTypes）ので載せない。出すときにここへも足す。
    /// dsp 0.12.0 の 3 つ（Analog Meter / Rhythm Analyzer / Tonal Balance EQ）は 2026.10.08 で外した。
    static let newTypes: [String] = [
        "AdaptivePredictionEffectPlugin",
    ]
    static let newKey = "__new"

    private var newEffects: [ETEffect] {
        Self.newTypes.compactMap { t in catalog.first { $0.type == t } }
    }

    static func stripLabel(_ name: String) -> String {
        switch name {
        case newKey: return "New"
        default:     return name.categoryLabel
        }
    }

    /// User プリセットを `/` で仕切って束ねる（ETUserPresetName）。
    private var userFolders: [(name: String, items: [String])] {
        ETUserPresetName.folders(presets.names)
    }

    /// プリセット 1 件の行。押すと入り、つまんで鎖へ落とすこともできる。
    /// `kind` は検索のときだけ渡す（User Preset / System Preset）。効果と混ざって並ぶので、
    /// 効果の行のジャンルの札（row の showCategory）と同じ札で、何の行かを示す。
    private func presetRow(name: String, payload: String, kind: String? = nil,
                           load: @escaping () -> [PipelineStore.Loaded]) -> some View {
        Button {
            searching = false
            Task { @MainActor in onPickPreset(name, load()) }
        } label: {
            HStack(spacing: 6) {
                Text(name)
                    .font(.system(size: 15))
                    .foregroundStyle(.primary)
                if let kind {
                    Text(kind)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: .capsule)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .onDrag {
            dismissAfterDragBegins()
            return NSItemProvider(object: payload as NSString)
        }
    }

    private func effects(in category: String) -> [ETEffect] {
        catalog.filter { $0.category == category }.sorted { $0.name < $1.name }
    }

    /// ChatGPTを開いて、JSFXを書く依頼を入れておく。
    ///
    /// **chatgpt.comを直に開く。**`/?q=`はChatGPTのapple-app-site-associationに
    /// 載っているので、アプリが入っていればそちらで開く。以前はeffectdeck.nemut.ai/writeを
    /// 挟んでいたが、ブラウザを1枚余計に通るうえ、長い依頼文が途中（"so keep"）で切れていた。
    /// **決め事はJSFX.mdに書き、依頼には書かない。**依頼が渡すのはアプリとDSPの版だけ。
    /// 内蔵のエフェクトで済むときは、JSFX.mdが鎖（CHAIN.md）でも組めると言わせる。
    /// **200字未満、@無し。**2026.09.22と0.12.0で192字（buildChainは194字）。
    static let writeJSFX: URL = chatGPT(
        "Write a JSFX effect for \(requestVersion). " +
        "First read https://github.com/satomasahiro2005/EffectDeck/blob/main/JSFX.md " +
        "and follow it. Then ask me what effect I want.")

    /// 同じ形で、内蔵のエフェクトの鎖を組ませる依頼（CHAIN.md）。返ってきた鎖はプリセットとして
    /// 保存されず、クリップボード経由で鎖として読み込まれる（ClipboardBanner・Presets → Import from clipboard）。
    /// なので依頼を開くボタンはプリセットの面ではなく、このシートのEffectsの面の頭（allSections）と
    /// 空の鎖の表示（PipelineViewのEmptyChainRow）に置く。⋯のメニューには置かない。
    static let buildChain: URL = chatGPT(
        "Build an effect chain for \(requestVersion). " +
        "First read https://github.com/satomasahiro2005/EffectDeck/blob/main/CHAIN.md " +
        "and follow it. Then ask me what sound I want.")

    /// 依頼に入れる版。"EffectDeck v2026.09.22 (EffeTune DSP 0.12.0)"。
    /// ビルド番号は入れない。CHAIN.mdはこの書き方で版を読み（JSFX.mdから鎖へ回るときも）、
    /// 無ければSettings → Aboutを見させる。
    private static var requestVersion: String {
        "EffectDeck v\(ETAppInfo.version) (EffeTune DSP \(ETUpstreamVersion))"
    }

    private static func chatGPT(_ request: String) -> URL {
        var c = URLComponents(string: "https://chatgpt.com/")!
        c.queryItems = [URLQueryItem(name: "q", value: request)]
        return c.url!
    }

    /// クリップボードの字をJSFXとして入れる。ChatGPTの返事をコピーして戻ってきたとき。
    /// 読むのは押したときだけ（貼り付けの許可はこの操作に対して出る）。
    private func importClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            alert = .failed("The clipboard has no text.")
            return
        }
        do {
            fresh = try jsfx.importText(text).id
            pane = .plugins
        } catch {
            alert = .failed(error.localizedDescription)
        }
    }

    /// リンクから取ってきて入れる。
    ///
    /// 取るのは ETRemoteFile、入れるのは ETInbox。**判定はどちらもしない**
    /// （音か JSFX かは取り込み先が中身の頭で決める）。ここは繋ぐだけ。
    private func fetchLink(_ text: String) {
        guard let address = ETRemoteFile.address(from: text) else {
            alert = .failed(ETRemoteFile.Failure.notAnAddress.localizedDescription)
            return
        }
        Task { @MainActor in
            do {
                let file = try await ETRemoteFile.fetch(address)
                switch ETInbox.receive(file) {
                case .jsfx(let id):
                    fresh = id
                    pane = .plugins
                case .ir:
                    // 音として入った。IR の一覧へ入るので、ここでは閉じるだけ。
                    dismiss()
                case .failed(let why):
                    alert = .failed(why)
                case .unsupported:
                    alert = .failed(ETInbox.unsupportedLink)
                }
            } catch {
                alert = .failed(error.localizedDescription)
            }
        }
    }

    private var searchList: some View {
        Group {
            if searchResults.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List(searchResults) { found in
                    switch found {
                    case .effect(let e): row(e, showCategory: true)
                    case .au(let a):     auRow(a)
                    case .jsfx(let j):   jsfxRow(j)
                    case .user(let n):
                        presetRow(name: ETUserPresetName.leaf(n),
                                  payload: "preset:user:" + n, kind: "User Preset") {
                            PresetStore.shared.load(n)
                        }
                    case .system(let p):
                        presetRow(name: p.name,
                                  payload: "preset:system:" + p.name, kind: "System Preset") {
                            ETShareLink.parse(p.json, catalog: ETCatalog)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func row(_ effect: ETEffect, showCategory: Bool = false) -> some View {
        Button {
            // **先に検索を畳む。**
            // `.searchable` は UIKit の検索コントローラをシートの上に重ねる。
            // 検索が出ている間に閉じようとすると、閉じるのは検索の方で
            // シートは残る。`dismiss()` でも、呼び手が `sheet = nil` を
            // 書いても同じ経路を通る（実機で両方とも残った）。
            searching = false
            // 畳むのが効くのは次の回。同じ回で閉じると間に合わない。
            Task { @MainActor in onPick(effect) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(effect.name)
                        .font(.system(size: 15))
                        .foregroundStyle(.primary)
                    if showCategory {
                        Text(effect.category.categoryLabel)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: .capsule)
                    }
                }
                if !effect.about.isEmpty {
                    Text(effect.about)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        // **つまんで鎖へ落とせる。** 運ぶのは型の文字列だけ。
        // 受けるのは PipelineView の段で、落ちた所へ差し込む。
        // 押して足すのは今までどおり末尾。
        //
        // **.draggable ではなく .onDrag を使う。**
        // 掴んだ瞬間に高さを下げたいが、.draggable は始まりを教えてくれない。
        // 手前に .onLongPressGesture を重ねたら、そちらが長押しを食って
        // つまめなくなった（実機で確認）。.onDrag はクロージャが
        // 掴んだ時に走るので、そこで下げる。
        //
        // **自前のプレビューを渡す。** 既定のプレビューは掴んだ行の位置に
        // 貼り付くので、直後にシートを縮めると指より下にずれる。
        // 小さな札にすれば指の下に付く。
        .onDrag {
            dismissAfterDragBegins()
            return NSItemProvider(object: effect.type as NSString)
        } preview: {
            Text(effect.name)
                .font(.system(size: 14, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.thickMaterial, in: .capsule)
        }
    }

    private static func jumpTarget(_ name: String) -> String {
        "category-target:" + name
    }

    private func firstCategory(for pane: Pane) -> String {
        switch pane {
        case .effects:    return stripNames.first ?? ""
        case .plugins:    return pluginVendors.first ?? ""
        case .presets:
            // 開くのは User Presets の頭。自分のものが無いときは空の表示が頭で、どの帯も塗らない。
            guard let first = userFolders.first else { return "" }
            return Self.userChipKey(first.name)
        }
    }

    /// `.onDrag` is called once UIKit has accepted the long press as a drag.
    /// Dismiss on the next run loop so the item provider/preview is installed
    /// before its source view disappears.
    private func dismissAfterDragBegins() {
        DispatchQueue.main.async {
            searching = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { dismiss() }
        }
    }
}
