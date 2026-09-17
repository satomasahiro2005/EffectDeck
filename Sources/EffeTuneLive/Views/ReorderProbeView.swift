//  ReorderProbeView.swift
//  **切り分け専用。**`-ETProbe 1` で起動するとこれが出る。
//
//  鎖の画面で並べ替えが振動し、掴み上げた瞬間に落ちる:
//    SwiftUICore/Logging.swift:232: Fatal error:
//      Unexpected identifier type. Expected UUID, got UUID
//    DragContainerStorage.payload<A>(for:) → _assertionFailure
//
//  箱だけの最小再現では落ちなかった（振動はした）。本体との差は
//  「ETSectionBracket で包んでいる」ことと「カードの中に Menu / Toggle /
//  Slider がある」こと。**1 回のビルドで両方を試せるように**、画面の上の
//  セグメントで中身を差し替える形にしてある。
//
//  器はどれも ScrollView + VStack + reorderable（公式の例と同じ）。
//  変えるのは行の中身だけ。

import SwiftUI

struct ETReorderProbeView: View {

    enum Stage: Int, CaseIterable, Identifiable {
        case box, bracket, card
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .box:     return "箱"
            case .bracket: return "括り"
            case .card:    return "カード"
            }
        }
    }

    /// **Apple のサンプルと同じ形。**（SwiftUI-Reorderable の CardValue）
    ///   - 自分自身が id（id: Self { self }）
    ///   - Hashable かつ Sendable
    ///   - ForEach の id にこの型を使い、reorderContainer にも同じ型を渡す
    /// 前は Row（要素の型）を渡し、その ID が UUID だったので食い違って
    /// 「Expected UUID, got UUID」で落ちていた。
    nonisolated struct Item: Hashable, Sendable, Identifiable {
        var id: Self { self }
        let key: UUID
        let n: Int
        var height: CGFloat { n % 3 == 0 ? 180 : (n % 3 == 1 ? 60 : 110) }
    }

    @StateObject private var dsp = EffeTuneDSP.shared
    @State private var stage: Stage = .box
    @State private var items: [Item] = (0..<6).map { Item(key: UUID(), n: $0) }
    /// 掴んでいるもの。
    @State private var dragging: UUID?
    /// **掴んだ時点の矩形。**入れ替えても動かさない。
    @State private var anchorRect: CGRect = .zero
    /// 指の移動量。
    @State private var shift: CGFloat = 0
    /// 行ごとの矩形。落とし先の判定に使う。
    @State private var rects: [UUID: CGRect] = [:]

    private static let space = "boxes"

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $stage) {
                    ForEach(Stage.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

                switch stage {
                case .box:     boxes
                case .bracket: brackets
                case .card:    cards
                }
            }
            .navigationTitle("Probe")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: 0 · 箱だけ（Shortcuts と同じ、矩形の重なりで判定）

    private var boxes: some View {
        // **掴んだものは別の層に描く。**行の中に重ねると、はみ出したぶんが
        // 切られて位置もずれる。Shortcuts も overlayHost という別の層を持つ
        // （ScrollableTableView.OverlayLayer.State に dragFormationRect と
        //  dropItemRects を置いている）。
        ZStack(alignment: .topLeading) {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(items, id: \.self) { item in
                        plate(item)
                            .onGeometryChange(for: CGRect.self) {
                                $0.frame(in: .named(Self.space))
                            } action: { rects[item.key] = $0 }
                            // 掴んでいる行は場所だけ空ける。
                            .opacity(dragging == item.key ? 0 : 1)
                            .animation(.snappy(duration: 0.22), value: items)
                            .gesture(drag(item))
                    }
                }
                .padding(.horizontal, 14)
            }

            // 掴んでいるもの。指について動く。
            if let id = dragging, let item = items.first(where: { $0.key == id }) {
                // 掴むと少し縮んで浮く。Shortcuts も initialWidth と
                // destinationWidth を別に持っていて、掴んだ側を縮めている。
                plate(item)
                    .frame(width: anchorRect.width, height: anchorRect.height)
                    .scaleEffect(0.97)
                    .shadow(color: .black.opacity(0.22), radius: 12, y: 6)
                    .offset(x: anchorRect.minX, y: anchorRect.minY + shift)
                    .allowsHitTesting(false)
                    .transition(.identity)
            }
        }
        .coordinateSpace(name: Self.space)
    }

    private func drag(_ item: Item) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(coordinateSpace: .named(Self.space)))
            .onChanged { value in
                switch value {
                case .first:
                    guard dragging != item.key else { return }
                    dragging = item.key
                    // **掴んだ時点の矩形を確保する。**Shortcuts の
                    // EditorDragItem が height / initialWidth を持ち回るのと同じ。
                    anchorRect = rects[item.key] ?? .zero
                    shift = 0
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                case .second(_, let d):
                    guard let d else { return }
                    shift = d.translation.height
                    settle(item.key)
                }
            }
            .onEnded { _ in
                withAnimation(.snappy(duration: 0.22)) {
                    dragging = nil
                    shift = 0
                }
            }
    }

    /// 落とし先を決める。**点ではなく矩形の重なりで見る。**
    ///
    /// Shortcuts は OverlayLayer.State に dragFormationRect（掴んでいるものの矩形）と
    /// dropItemRects（候補ごとの矩形）を持ち、矩形どうしを当てている。
    /// UIKit の drag & drop は指の点しか渡さないので、掴んだものが相手より
    /// 大きいと中心とのズレぶん判定が早く反転して振動する。面で見れば起きない。
    private func settle(_ id: UUID) {
        guard let at = items.firstIndex(where: { $0.key == id }) else { return }
        // 掴んでいるものの矩形を、いまの位置へ平行移動したもの。
        let moving = anchorRect.offsetBy(dx: 0, dy: shift)

        if at > 0, let above = rects[items[at - 1].key] {
            // 相手の矩形と、どれだけ重なっているか。半分を越えたら入れ替える。
            let overlap = moving.intersection(above).height
            if moving.minY < above.minY || overlap > above.height / 2 {
                withAnimation(.snappy(duration: 0.22)) { items.swapAt(at, at - 1) }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                return
            }
        }
        if at < items.count - 1, let below = rects[items[at + 1].key] {
            let overlap = moving.intersection(below).height
            if moving.maxY > below.maxY || overlap > below.height / 2 {
                withAnimation(.snappy(duration: 0.22)) { items.swapAt(at, at + 1) }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
    }

    // MARK: 1 · 括りで包む

    private var brackets: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(items, id: \.self) { item in
                    ETSectionBracket(active: item.n % 3 != 0,
                                     extendsUp: item.n % 3 == 2,
                                     extendsDown: item.n % 3 == 1) {
                        plate(item)
                    }
                }
                .reorderable()
            }
            .reorderContainer(for: Item.self) { difference in apply(difference) }
            .padding(.horizontal, 14)
        }
    }

    // MARK: 2 · 本物のカード

    private var cards: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(Array(dsp.chain.prefix(6).enumerated()), id: \.element.id) { at, node in
                    EffectCardView(
                        index: at,
                        node: node,
                        dsp: dsp,
                        isExpanded: dsp.expanded.contains(node.id),
                        isCollapsedFully: dsp.collapsedFully.contains(node.id),
                        toggleExpanded: {},
                        moveUp: {}, moveDown: {},
                        canMoveUp: at > 0,
                        canMoveDown: at < min(dsp.chain.count, 6) - 1,
                        block: .alone)
                }
                .reorderable()
            }
            .reorderContainer(for: EffeTuneDSP.Node.self) { _ in }
            .padding(.horizontal, 14)
        }
    }

    // MARK: 部品

    private func plate(_ item: Item) -> some View {
        RoundedRectangle(cornerRadius: ETMetrics.cardRadius, style: .continuous)
            .fill(.regularMaterial)
            .frame(height: item.height)
            .overlay(Text("\(item.n) · \(Int(item.height))pt").font(.headline))
    }

    private func apply(_ difference: ReorderDifference<Item.ID, ReorderableSingleCollectionIdentifier>) {
        let ids = difference.sources
        let from = IndexSet(items.indices.filter { ids.contains(items[$0]) })
        guard !from.isEmpty else { return }
        let to: Int
        switch difference.destination.position {
        case .before(let id):
            to = items.firstIndex { $0 == id } ?? items.count
        default:
            to = items.count
        }
        items.move(fromOffsets: from, toOffset: to)
    }
}
