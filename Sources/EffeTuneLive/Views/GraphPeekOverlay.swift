//  GraphPeekOverlay.swift
//  スクロールで図が外れたカードの値を触っているあいだ、その図の複写を上（か下）に見せる（graph peek）。
//
//  **出し入れの判断は GraphPeekGate.swift（カードごと）。ここは見せる側。**
//   - カード（EffectCardView）は、出したい間だけ `.card`（図の複写・カードの矩形・指の高さ）を preference に載せる
//   - 図は自分の矩形を `.graph` で載せる（etPeekGraphAnchor）
//   - PipelineView の chainList が overlayPreferenceValue で受け、ここで「見えているか」「どこへ置くか」を決める
//
//  **見せるだけ。**当たりは取らず（allowsHitTesting）、読み上げからも外す（accessibilityHidden）。
//  掴んで並べ替えている間・シートが出ている間・スクロールしている間は何も出さない。

import SwiftUI
import UIKit

/// 時計。GraphPeekGate は時刻を引数で受ける。ここで読む。
enum ETPeekClock {
    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// カードごとの graph peek の持ち物。**観測しない箱。**
///
/// 触りのたびに書き換わる（指の点・図の矩形・出し入れの時計）が、どれも描き直しを要らない。
/// @State に置くと、触るたびにカードの body が走り直す。描き直すのは `peekWants` が変わるときだけ。
@MainActor
final class ETPeekCardBox {
    var gate = ETGraphPeekGate()
    /// 図の矩形（カードの座標）。触りが図の上で始まったかを決める。
    private(set) var rects: [CGRect] = []
    /// 期限まで待って gate を進める。
    var task: Task<Void, Never>?

    /// 指の状態。
    var touch = ETGraphPeekTouchState()
    /// 図の複写を出したい側に変わった時刻。重ねる面が「いちばん新しく触ったカード」を選ぶのに使う。
    var armedAt: TimeInterval = 0

    // deinit は置かない。@MainActor の持ち物を非隔離の deinit から触ると言語版によって通らない
    // （BandFIRPEQDesigner と同じ）。待ちはカードの onDisappear で止める。

    /// 図の矩形を置き直す。送るのは `.graph` だけ。
    func record(_ items: [ETGraphPeekItem], in geo: GeometryProxy) {
        var next: [CGRect] = []
        for item in items {
            if case .graph(_, let anchor) = item { next.append(geo[anchor]) }
        }
        if next != rects { rects = next }
    }
}

/// カードの背面に敷く。図の矩形を箱へ写すだけで、何も描かない。
struct ETPeekRectsReader: View {
    let items: [ETGraphPeekItem]
    let box: ETPeekCardBox

    var body: some View {
        GeometryReader { geo in
            // body の中で箱へ書く（観測しない箱なので、描き直しは起きない）。
            let _ = box.record(items, in: geo)
            Color.clear
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// スクロールしているか。**重ねる面の中だけが読む。**PipelineView の body は読まない。
@Observable @MainActor
final class ETGraphPeekHost {
    /// スクロールが指で動いている・流れている間。
    var scrolling = false
}

/// 出す場所の決定（ETGraphPeekSticky）を body の中から書き換えるための箱。観測しない。
@MainActor
final class ETGraphPeekPlacementBox {
    var sticky = ETGraphPeekSticky()
}

/// 重ねる面。`.overlayPreferenceValue(ETGraphPeekKey.self)` の中で作る。
struct ETGraphPeekOverlay: View {
    let items: [ETGraphPeekItem]
    let host: ETGraphPeekHost
    /// 並べ替えのために掴んでいる。
    let dragging: Bool
    /// シートが出ている。
    let blocked: Bool

    @State private var placements = ETGraphPeekPlacementBox()
    /// 測った複写の高さ（カードごと・幅ごと）。置き場所の判断（上下の反転・出せるか）に使う。
    /// 図を何枚も持つカード（マルチバンド・Tube・Bass Management）は 400pt を超えるので、見積もりでは決めない。
    @State private var heights: [MeasureKey: CGFloat] = [:]

    /// 画面の端からの距離。
    private static let edgeGap: CGFloat = 8
    /// 上の余白へ潜る向き（出る・消える動きの幅）。
    private static let slide: CGFloat = 8

    private struct MeasureKey: Hashable {
        var id: UUID
        var width: Int
    }

    private struct Entry {
        var id: UUID
        var anchor: Anchor<CGRect>
        var touchY: CGFloat?
        var armedAt: TimeInterval
        var content: AnyView
        var suppress: @MainActor () -> Void
    }

    /// **出したい側にいちばん新しく変わったカード 1 件。**同時に出すのは 1 つだけ。
    /// 下のカードの猶予が残っていても、上のカードを触り始めたらそちらが出る。同時刻なら並びの後ろ。
    private var latest: Entry? {
        var best: Entry?
        for item in items {
            guard case .card(let id, let anchor, let touchY, let armedAt, let content, let suppress) = item
            else { continue }
            if let b = best, armedAt < b.armedAt { continue }
            best = Entry(id: id, anchor: anchor, touchY: touchY, armedAt: armedAt,
                         content: content, suppress: suppress)
        }
        return best
    }

    /// そのカードの `.card`。
    private func entry(for id: UUID) -> Entry? {
        for item in items {
            if case .card(let cid, let anchor, let touchY, let armedAt, let content, let suppress) = item,
               cid == id {
                return Entry(id: cid, anchor: anchor, touchY: touchY, armedAt: armedAt,
                             content: content, suppress: suppress)
            }
        }
        return nil
    }

    private struct Shown {
        var card: Entry
        var rect: CGRect
        var placement: ETGraphPeekPlacement
    }

    /// 1 回の判断の結果。
    private struct Evaluation {
        /// 置けた（高さが測れていて、置く場所がある）。
        var shown: Shown?
        /// 高さがまだ無い。見えない描画で測る（測れたら次の描画で置く）。
        var measure: (card: Entry, width: CGFloat)?
        /// 図が見えている。
        var graphVisible = false
    }

    /// 図が見えたことを、カードの側へ知らせるための印（出したい側に変わるたびに変わる）。
    private struct SeenKey: Equatable {
        var id: UUID?
        var armedAt: TimeInterval?
        var graphVisible: Bool
    }

    var body: some View {
        let scrolling = host.scrolling
        let latest = self.latest
        return GeometryReader { geo in
            let evaluation = evaluate(latest, in: geo, scrolling: scrolling)
            let shown = evaluation.shown
            ZStack {
                if let measure = evaluation.measure {
                    // 置く前に実寸を測る。見せず、当たりも読み上げも取らない（この面ぜんたいがそう）。
                    sized(measure.card, width: measure.width)
                        .opacity(0)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                if let shown {
                    peek(shown, in: geo)
                        .transition(.opacity.combined(with: .offset(
                            y: shown.placement == .top ? -Self.slide : Self.slide)))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            // 出るときは 0.15 秒、消えるときは 0.25 秒。視差効果を減らす設定では動かさない。
            .etAnimation(shown == nil ? Animation.easeIn(duration: 0.25) : Animation.easeOut(duration: 0.15),
                         value: shown?.card.id)
            // 出したいのに図が見えている（パルスのあとにスクロールなどで見えた）なら、カードの待ちを止める。
            // 待たせておくと、あとで画面が動いただけで、触っていないのに出る。
            .onChange(of: SeenKey(id: latest?.id, armedAt: latest?.armedAt,
                                  graphVisible: evaluation.graphVisible)) { _, now in
                if now.graphVisible { latest?.suppress() }
            }
        }
        // **バーの下だけでなく画面いっぱいに敷く。**枠がすでに安全域の内側でも外側でも、
        // size は全体・safeAreaInsets は全体の内側の余白になり、バーの高さを二重に引かない。
        // キーボードは除かない（出ている間は枠がその上までになり、置ける高さの判断に効く）。
        // 実機での枠の取れ方は未確認（docs/notes の graph peek の項 4-1）。
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        // スクロールが始まる・掴む・シートが出るときは、カードの側の待ちも止める（戻って出ないように）。
        .onChange(of: scrolling) { _, now in if now { latest?.suppress() } }
        .onChange(of: dragging) { _, now in if now { latest?.suppress() } }
        .onChange(of: blocked) { _, now in if now { latest?.suppress() } }
        // 別のカードを触り始めたら、前のカードの残りを止める（同時に出すのは 1 つ。
        // 新しいほうが図が見えていて下がったとき、前のカードが戻って出てこないように）。
        .onChange(of: latest?.id) { old, new in
            guard let old, let new, old != new else { return }
            entry(for: old)?.suppress()
        }
    }

    /// 出すかどうかと、出す場所。出さないなら shown が nil。
    private func evaluate(_ card: Entry?, in geo: GeometryProxy, scrolling: Bool) -> Evaluation {
        guard let card else {
            placements.sticky.reset()
            return Evaluation()
        }
        let top = geo.safeAreaInsets.top
        let bottom = geo.safeAreaInsets.bottom
        let viewport = CGRect(x: 0, y: top, width: geo.size.width,
                              height: geo.size.height - top - bottom)
        // 図が 1 つでも 6 割見えていれば要らない。図が 1 つも報されていなければ画面の外とみなす。
        var graphs: [CGRect] = []
        for item in items {
            if case .graph(let id, let anchor) = item, id == card.id { graphs.append(geo[anchor]) }
        }
        let visible = ETGraphPeekGate.graphVisible(graphRects: graphs, viewport: viewport)
        guard !visible, !dragging, !blocked, !scrolling else {
            placements.sticky.reset()
            return Evaluation(graphVisible: visible)
        }
        let rect = geo[card.anchor]
        // 高さは実寸。測れるまでは置き場所を決めない（決めると、見積もりで決めたまま固定される）。
        guard let height = heights[MeasureKey(id: card.id, width: Int(rect.width.rounded()))] else {
            return Evaluation(measure: (card, rect.width))
        }
        let placement = placements.sticky.resolve(for: card.id) {
            ETGraphPeekGate.placement(viewport: geo.size, topInset: top, bottomInset: bottom,
                                      peekHeight: height,
                                      touchY: card.touchY.map { rect.minY + $0 })
        }
        guard let placement else { return Evaluation() }
        return Evaluation(shown: Shown(card: card, rect: rect, placement: placement))
    }

    /// 複写の中身。幅はカードと同じ、高さは中身なりの高さ。実寸を測って持つ。
    private func sized(_ card: Entry, width: CGFloat) -> some View {
        let key = MeasureKey(id: card.id, width: Int(width.rounded()))
        return card.content
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { record($0, for: key) }
    }

    private func record(_ height: CGFloat, for key: MeasureKey) {
        guard height > 0, abs((heights[key] ?? 0) - height) > 0.5 else { return }
        // カードの数だけ増えるが、組み直しで溜まらないよう上限を置く。
        if heights.count > 64 { heights.removeAll() }
        heights[key] = height
    }

    /// 置く。横の位置と幅はカードと同じ。
    private func peek(_ shown: Shown, in geo: GeometryProxy) -> some View {
        let isTop = shown.placement == .top
        let inset = (isTop ? geo.safeAreaInsets.top : geo.safeAreaInsets.bottom) + Self.edgeGap
        return sized(shown.card, width: shown.rect.width)
            // ReorderProbeView の浮いた札と同じ影。
            .shadow(color: .black.opacity(0.22), radius: 12, y: 6)
            .padding(.leading, shown.rect.minX)
            .padding(isTop ? .top : .bottom, inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: isTop ? .topLeading : .bottomLeading)
    }
}
