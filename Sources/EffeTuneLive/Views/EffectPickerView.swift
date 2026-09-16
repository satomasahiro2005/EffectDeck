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

struct EffectPickerView: View {
    let onPick: (ETEffect) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var dsp = EffeTuneDSP.shared
    @State private var query = ""
    /// 検索が出ているか。**畳むために持つ。**
    /// 検索が出ている間はシートを閉じられない（下の row のコメント）ので、
    /// 先にこれを false にしてから閉じる。`.searchable(text:isPresented:)` は
    /// iOS 17 から。
    @State private var searching = false
    /// つまんでいる間の高さ。**見出しの行だけを残す。**
    /// 掴んだものは指に付いたままなので、一覧が隠れても運べる。
    /// 鎖を隠さないのが目的なので、これ以上は残さない。
    private static let lifted = PresentationDetent.height(90)
    /// 開いたときの高さ。一覧を探すのが主な用途なので広めに取る。
    /// 半分だと一度に 4〜5 行しか見えず、カテゴリを跨ぐのに何度も擦ることになる。
    private static let opened = PresentationDetent.fraction(0.75)
    /// いまのシートの高さ。つまんだら lifted まで下げる。
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

    private var categories: [String] {
        Array(Set(catalog.map(\.category))).sorted()
    }

    private var searchResults: [ETEffect] {
        let q = query.lowercased()
        return catalog
            .filter {
                $0.name.lowercased().contains(q)
                    || $0.about.lowercased().contains(q)
                    || $0.category.lowercased().contains(q)
            }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            Group {
                // **縮めている間は中身を出さない。**
                // 90pt にタイトル・検索・カテゴリの帯を全部入れようとすると
                // 重なって潰れる。つまんで運んでいる最中なので、中身は要らない。
                if detent == Self.lifted {
                    Color.clear
                } else if query.isEmpty {
                    VStack(spacing: 0) {
                        categoryStrip
                        Divider()
                        allSections
                    }
                } else {
                    searchList
                }
            }
            .onAppear { if current.isEmpty { current = categories.first ?? "" } }
            .searchable(text: $query, isPresented: $searching, prompt: "Search effects")
            .navigationTitle("Available Effects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            // **半分の高さで出す。** 全画面だと鎖が隠れて、つまんだものを
            // 落とす先が画面に無くなる。上半分に鎖を残す。
            .presentationDetents([Self.lifted, Self.opened, .large], selection: $detent)
            .presentationBackgroundInteraction(.enabled(upThrough: Self.opened))
        }
    }

    /// 下の一覧への飛び先。現在地は見出しが上に張り付いて出すので、
    /// ここでは塗り分けない。
    private var categoryStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(categories, id: \.self) { name in
                        Button {
                            jump = Jump(name: name, count: jump.count + 1)
                        } label: {
                            Text(name.categoryLabel)
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
                ForEach(categories, id: \.self) { name in
                    Section {
                        ForEach(effects(in: name)) { effect in
                            row(effect)
                        }
                    } header: {
                        Text(name.categoryLabel)
                            // 見出しが画面に入ったらそこを現在地にする。
                            // 下へ払えば次の見出しで、上へ払えば前の見出しで切り替わる。
                            .onScrollVisibilityChange(threshold: 0.1) { visible in
                                if visible { current = name }
                            }
                    }
                    .id(name)
                }
            }
            .listStyle(.plain)
            .onChange(of: jump) { _, now in
                guard !now.name.isEmpty else { return }
                withAnimation { proxy.scrollTo(now.name, anchor: .top) }
            }
        }
    }

    private func effects(in category: String) -> [ETEffect] {
        catalog.filter { $0.category == category }.sorted { $0.name < $1.name }
    }

    private var searchList: some View {
        Group {
            if searchResults.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List(searchResults) { effect in
                    row(effect, showCategory: true)
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
            if detent != Self.lifted {
                DispatchQueue.main.async {
                    withAnimation(.snappy(duration: 0.2)) { detent = Self.lifted }
                }
            }
            return NSItemProvider(object: effect.type as NSString)
        } preview: {
            Text(effect.name)
                .font(.system(size: 14, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.thickMaterial, in: .capsule)
        }
    }
}
