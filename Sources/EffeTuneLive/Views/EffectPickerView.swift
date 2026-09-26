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

    @StateObject private var presets = PresetStore.shared

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @StateObject private var dsp = EffeTuneDSP.shared
    @StateObject private var au = ETAUHost.shared
    @StateObject private var jsfx = ETJSFXHost.shared
    @State private var query = ""
    /// 出している提示。**1 枚しか持たない**（上の .alert を読むこと）。
    private enum Alert: Equatable {
        case link
        case failed(String)
        case shareFailed(String)
    }
    @State private var alert: Alert?
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

    /// 上の段階の切り替え。効果 / 自分のプリセット / 同梱のプリセット。
    enum Pane: String, CaseIterable, Identifiable {
        case effects, plugins, user, system
        var id: String { rawValue }
        var label: String {
            switch self {
            case .effects: return "Effects"
            case .plugins: return "Plugins"
            case .user:    return "User"
            case .system:  return "Factory"
            }
        }
    }
    @State private var pane: Pane = .effects
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

    /// 出すもの。カーネルとして登録されている型に Section を足したもので、
    /// 中身は dsp が決めている（EffeTuneDSP.swift:142）。
    /// Section だけカーネルが無いのは、音を触らないから
    /// （上流も plugins/control/section.js の processor は `return data;` だけ）。
    private var catalog: [ETEffect] { dsp.available }

    /// 効果のカテゴリ。**Section の居る control も上流と同じく「Control」で並べる。**
    /// 一度「Grouping」と呼び替えて末尾に分けたが、EffeTune に慣れた人は Control の中を探す。
    private var categories: [String] {
        Array(Set(catalog.map(\.category))).sorted()
    }

    // MARK: - 探す
    //
    // **段の区別を越えて探す。**上の 4 つの段（効果・プラグイン・自分のプリセット・
    // 出荷時のプリセット）は「並べて眺めるとき」の分け方で、名前で探すときには
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
        for a in au.entries {
            if let h = Self.hit(a.name, q) { out.append((h, .au(a))); continue }
            if a.manufacturer.lowercased().contains(q) { out.append((.elsewhere, .au(a))) }
        }
        for j in jsfx.entries {
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
                            ForEach(Pane.allCases) { Text($0.label).tag($0) }
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
                        case .user:
                            userPresetList
                        case .system:
                            systemPresetList
                        }
                    }
                } else {
                    // **探すときは段を分けない。**どの段に居るかを当てさせない。
                    searchList
                }
            }
            .onAppear { if current.isEmpty { current = firstCategory(for: pane) } }
            .onChange(of: pane) { _, selected in
                current = firstCategory(for: selected)
                jump = Jump()
            }
            .searchable(text: $query, isPresented: $searching, prompt: "Search effects")
            .navigationTitle("Available Effects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if pane == .plugins && ETJSFXHost.isEnabled {
                    ToolbarItem(placement: .primaryAction) {
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
                            Divider()
                            Button("Write JSFX with ChatGPT", systemImage: "sparkles") {
                                openURL(Self.writeJSFX)
                            }
                        } label: {
                            Label("Import JSFX", systemImage: "square.and.arrow.down")
                        }
                    }
                }
            }
            .fileImporter(isPresented: $importingJSFX,
                          allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
                do {
                    guard let url = try result.get().first else { return }
                    _ = try jsfx.importFile(url)
                    pane = .plugins
                } catch { alert = .failed(error.localizedDescription) }
            }
            // **提示は 1 枚だけにする。**同じ View に .alert を 2 枚積むと、
            // 先に付いたほうが出なくなる。このリポジトリで 4 度目の踏み方
            // （PresetsView.swift:148-151 に 3 度目までの記録がある）。
            // 積んだせいで取り込みの失敗が全部無言になっていた。
            .alert(alertTitle, isPresented: Binding(
                get: { alert != nil }, set: { if !$0 { alert = nil } })) {
                    if alert == .link {
                        TextField("https://github.com/…", text: $linkText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        Button("Cancel", role: .cancel) { alert = nil }
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
            // 一覧と検索結果の両方を覆う階層に 1 つ置く。行ごとに持たせると
            // 検索から払ったときに出ない。
            .confirmationDialog(pendingDeleteJSFX.map { "Remove “\($0.name)”?" } ?? "",
                                isPresented: Binding(
                                    get: { pendingDeleteJSFX != nil },
                                    set: { if !$0 { pendingDeleteJSFX = nil } }),
                                titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    if let entry = pendingDeleteJSFX { jsfx.removeEntry(entry) }
                    pendingDeleteJSFX = nil
                }
                Button("Cancel", role: .cancel) { pendingDeleteJSFX = nil }
            } message: {
                Text("This cannot be undone.")
            }
            // **半分の高さで出す。** 全画面だと鎖が隠れて、つまんだものを
            // 落とす先が画面に無くなる。上半分に鎖を残す。
            .presentationDetents([Self.opened, .large], selection: $detent)
            .presentationDragIndicator(.visible)
            .presentationBackgroundInteraction(.enabled(upThrough: Self.opened))
        }
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

    private var pluginList: some View {
        Group {
            if au.entries.isEmpty && jsfx.entries.isEmpty {
                ContentUnavailableView {
                    Label("No Plugins", systemImage: "waveform")
                } actions: {
                    if ETJSFXHost.isEnabled {
                        Button("Import JSFX", systemImage: "square.and.arrow.down") {
                            importingJSFX = true
                        }
                        Button("Write JSFX with ChatGPT", systemImage: "sparkles") {
                            openURL(Self.writeJSFX)
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
                                Button("Import JSFX", systemImage: "square.and.arrow.down") {
                                    importingJSFX = true
                                }
                                // **書かせる道があることを、一覧の頭で見せる。**
                                // JSFXは1枚のテキストなので、ChatGPTにJSFX.mdを
                                // 読ませれば通るものが返ってくる。説明は足さず、札だけ置く。
                                Button("Write JSFX with ChatGPT", systemImage: "sparkles") {
                                    openURL(Self.writeJSFX)
                                }
                            }
                            ForEach(pluginVendors, id: \.self) { vendor in
                                Section {
                                    let entries = audioUnits(vendor: vendor)
                                    ForEach(Array(entries.enumerated()), id: \.element.id) {
                                        offset, entry in
                                        auRow(entry)
                                            .id(offset == 0 ? Self.jumpTarget(vendor)
                                                            : "au-entry-" + entry.id)
                                    }
                                    let scripts = jsfxEntries(vendor: vendor)
                                    ForEach(Array(scripts.enumerated()), id: \.element.id) {
                                        offset, entry in
                                        jsfxRow(entry)
                                            .id(entries.isEmpty && offset == 0
                                                ? Self.jumpTarget(vendor)
                                                : "jsfx-entry-" + entry.id)
                                    }
                                    // **消す口。**行は Button で onDrag も付いているので、
                                    // 自前のスワイプを重ねるとタップ・ドラッグ・払いの 3 つが
                                    // 同じ行で競合する。List の onDelete なら List 側の
                                    // 仕組みなので競合しない。
                                    // 同梱の見本は消させない（removeEntry が弾く）。
                                    .onDelete { offsets in
                                        pendingDeleteJSFX = offsets
                                            .compactMap { scripts.indices.contains($0) ? scripts[$0] : nil }
                                            .first { !$0.isDebugFixture }
                                    }
                                } header: {
                                    Text(vendor)
                                        .onScrollVisibilityChange(threshold: 0.1) { visible in
                                            if visible { current = vendor }
                                        }
                                }
                            }
                        }
                        .listStyle(.plain)
                    }
                    .onChange(of: jump) { _, now in
                        guard !now.name.isEmpty else { return }
                        withAnimation {
                            proxy.scrollTo(Self.jumpTarget(now.name), anchor: .top)
                        }
                    }
                }
            }
        }
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
                    Text(entry.name).font(.system(size: 15)).foregroundStyle(.primary)
                    Text(pluginDetail(format: "AUv3", author: entry.manufacturer))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
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

    private func jsfxRow(_ entry: ETJSFXHost.Entry) -> some View {
        Button {
            searching = false
            Task { @MainActor in onPickJSFX(entry) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "curlybraces")
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.system(size: 15)).foregroundStyle(.primary)
                    Text(pluginDetail(format: "JSFX", author: entry.author))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
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
        // 共有（jsfx.shareURL）は JSFX の詳細画面から出す。
    }

    /// 自分で保存したプリセット。`/` で仕切るとフォルダに束ねる。
    private var userPresetList: some View {
        Group {
            if presets.names.isEmpty {
                ContentUnavailableView("No user presets", systemImage: "square.stack")
            } else {
                ScrollViewReader { proxy in
                VStack(spacing: 0) {
                // フォルダが 1 つだけ（＝仕切っていない）なら帯は出さない。
                if userFolders.count > 1 {
                    jumpStrip(userFolders.map(\.name).map { $0.isEmpty ? Self.looseKey : $0 })
                    Divider()
                }
                List {
                    ForEach(userFolders, id: \.name) { folder in
                        Section {
                            ForEach(Array(folder.items.enumerated()), id: \.element) {
                                offset, name in
                                presetRow(name: ETUserPresetName.leaf(name),
                                          payload: "preset:user:" + name) {
                                    PresetStore.shared.load(name)
                                }
                                .id(offset == 0
                                    ? Self.jumpTarget(folder.name.isEmpty
                                                        ? Self.looseKey : folder.name)
                                    : "user-preset-" + name)
                            }
                        } header: {
                            Text(folder.name.isEmpty ? "Others" : folder.name)
                                .onScrollVisibilityChange(threshold: 0.1) { visible in
                                    if visible {
                                        current = folder.name.isEmpty ? Self.looseKey : folder.name
                                    }
                                }
                        }
                    }
                }
                .listStyle(.plain)
                }
                .onChange(of: jump) { _, now in
                    guard !now.name.isEmpty else { return }
                    withAnimation {
                        proxy.scrollTo(Self.jumpTarget(now.name), anchor: .top)
                    }
                }
                }
            }
        }
    }

    /// 同梱のプリセット。上流の分け方をそのまま見出しにする。
    private var systemPresetList: some View {
        ScrollViewReader { proxy in
        VStack(spacing: 0) {
        jumpStrip(systemCategories)
        Divider()
        List {
            ForEach(systemCategories, id: \.self) { category in
                Section {
                    if category == Self.debugJSFXCategory {
                        presetRow(name: "JSFX Host Test",
                                  payload: "preset:debug:jsfx-host") {
                            jsfx.debugPresetItems()
                        }
                        .id(Self.jumpTarget(category))
                        // 手で組み直さずに見るための鎖（DSP/DebugPresets.swift）。
                        ForEach(Array(ETDebugPresets.all.enumerated()), id: \.offset) {
                            _, item in
                            presetRow(name: item.name,
                                      payload: "preset:debug:" + item.name) {
                                ETShareLink.parse(item.json, catalog: ETCatalog)
                            }
                        }
                    } else {
                        let presets = ETSystemPresets.filter { $0.category == category }
                        ForEach(Array(presets.enumerated()), id: \.element.id) { offset, preset in
                            presetRow(name: preset.name,
                                      payload: "preset:system:" + preset.name) {
                                ETShareLink.parse(preset.json, catalog: ETCatalog)
                            }
                            .id(offset == 0 ? Self.jumpTarget(category)
                                            : "system-preset-" + preset.name)
                        }
                    }
                } header: {
                    Text(category.categoryLabel)
                        .onScrollVisibilityChange(threshold: 0.1) { visible in
                            if visible { current = category }
                        }
                }
            }
        }
        .listStyle(.plain)
        }
        .onChange(of: jump) { _, now in
            guard !now.name.isEmpty else { return }
            withAnimation { proxy.scrollTo(Self.jumpTarget(now.name), anchor: .top) }
        }
        }
    }

    /// 仕切っていないプリセットをまとめる見出しの鍵。
    static let looseKey = "__loose"

    /// 面の上に出す飛び先の帯。効果のジャンル帯と同じ作り。
    private func jumpStrip(_ names: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(names, id: \.self) { name in
                    Button {
                        current = name
                        jump = Jump(name: name, count: jump.count + 1)
                    } label: {
                        Text(name == Self.looseKey ? "Others" : name.categoryLabel)
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

    /// 一覧に出すプリセットの見出し用の鍵。カテゴリ名と衝突しない字にする。
    static let userKey = "__user_presets"
    static let systemKey = "__system_presets"

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
    /// 直前に居たのは dsp 0.10.0 で足された 3 つ（Pitch Meter /
    /// TV Audio Simulator / Spatial Mapper）。もう新しくないので外した。
    static let newTypes: [String] = []
    static let newKey = "__new"

    private var newEffects: [ETEffect] {
        Self.newTypes.compactMap { t in catalog.first { $0.type == t } }
    }

    static func stripLabel(_ name: String) -> String {
        switch name {
        case newKey:    return "New"
        case userKey:   return "User Presets"
        case systemKey: return "System Presets"
        default:        return name.categoryLabel
        }
    }

    /// User プリセットを `/` で仕切って束ねる（ETUserPresetName）。
    private var userFolders: [(name: String, items: [String])] {
        ETUserPresetName.folders(presets.names)
    }

    /// プリセット 1 件の行。押すと入り、つまんで鎖へ落とすこともできる。
    private func presetRow(name: String, payload: String,
                           load: @escaping () -> [PipelineStore.Loaded]) -> some View {
        Button {
            searching = false
            Task { @MainActor in onPickPreset(name, load()) }
        } label: {
            Text(name)
                .font(.system(size: 15))
                .foregroundStyle(.primary)
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

    /// JSFXをChatGPTに書かせるページ。
    ///
    /// **依頼の文面と有料版の案内はページ側に置く。**アプリには札だけ置き、
    /// 説明を持ち込まない。文面を直すのにアプリを出し直さなくて済む。
    static let writeJSFX = URL(string: "https://effectdeck.nemut.ai/write")!

    /// クリップボードの字をJSFXとして入れる。ChatGPTの返事をコピーして戻ってきたとき。
    /// 読むのは押したときだけ（貼り付けの許可はこの操作に対して出る）。
    private func importClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            alert = .failed("The clipboard has no text.")
            return
        }
        do {
            _ = try jsfx.importText(text)
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
                case .jsfx:
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
                                  payload: "preset:user:" + n) {
                            PresetStore.shared.load(n)
                        }
                    case .system(let p):
                        presetRow(name: p.name,
                                  payload: "preset:system:" + p.name) {
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
        case .user:
            guard let first = userFolders.first?.name else { return "" }
            return first.isEmpty ? Self.looseKey : first
        case .system:     return systemCategories.first ?? ""
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
