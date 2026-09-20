//  DragHandle.swift
//  長押しから離すまでを 1 本で受ける。
//
//  **SwiftUI のジェスチャでは足りなかった。**
//  LongPressGesture.sequenced(before: DragGesture) は、
//    - onEnded が来ないことがある（掴んだままになり、scrollDisabled が解けず操作不能）
//    - .gesture だとカードの onTapGesture を奪う
//    - .simultaneousGesture にすると今度はタップでも掴みが立つ
//  という噛み合わせが直らない。
//
//  UIKit の UILongPressGestureRecognizer なら began / changed / ended / cancelled /
//  failed が必ず来る。掴んでいる間だけスクロールを止めるのも、
//  同じ認識器から親の UIScrollView を触れば確実に戻せる。
//
//  **付ける先はカードの上ではなく、その上の View。**
//  最初はカードに重ねた面へ付けていた。UIView は既定で自分の矩形の当たりを
//  全部取るので、カードの中のつまみもボタンも一切触れなくなっていた
//  （実機、2026-09-17）。かといって面が hitTest で nil を返すと、今度は
//  自分がタッチの列に入らず認識器が呼ばれない。
//  だから **面は当たりを取らず（nil）、認識器は面の上の View に付ける。**
//  触りはカードへ素通りし、認識器は祖先なので必ず呼ばれる。
//
//  上の View が行ごとに別なのか、鎖ぜんぶで 1 つなのかは SwiftUI の都合で
//  決まっていて、こちらからは分からない。**推測しない。**
//  掴んだ点が自分の矩形に入っているかを began で見て、入っていなければ
//  何もしない。行ごとでも共有でも同じに動く。

import SwiftUI
import UIKit

/// 長押しで掴み、指について動かし、離すまでを渡す。
struct ETDragHandle: UIViewRepresentable {
    /// 掴んだ。
    let began: () -> Void
    /// 指が動いた。渡すのは掴んだ時点からの移動量。**縦だけでなく横も渡す。**
    /// 並べ替えの判定は縦しか見ないが、掴んだものは指について両方向へ動く
    /// （Shortcuts も同じ。指から離れた絵は掴んでいる感じがしない）。
    let moved: (CGSize) -> Void
    /// 離した（取り消しも含む）。
    let ended: () -> Void
    /// 横へ払い始めた。
    let swipeBegan: () -> Void
    /// **横へ払っている最中。**渡すのは払い始めからの横の移動量（左へなら負）。
    let swiped: (CGFloat) -> Void
    /// 払い終えた。渡すのは横の移動量と速さ。
    let swipeEnded: (CGFloat, CGFloat) -> Void

    func makeUIView(context: Context) -> UIView {
        let v = HoleView()
        context.coordinator.anchor = v
        // **付けるのは階層に入ってから。**makeUIView も updateUIView も
        // superview がまだ無い時点で走ることがあり、そこで諦めると
        // 二度と呼ばれずに認識器が付かないままになる（実機で確認、
        // ログに「付けた先」が 1 行も出なかった）。View 側から呼ばせる。
        v.onEnterHierarchy = { [weak coordinator = context.coordinator] in
            coordinator?.attach()
        }
        return v
    }

    func updateUIView(_ v: UIView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.attach()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: ETDragHandle
        /// 自分の場所を表す面。当たりは取らない。
        weak var anchor: UIView?
        private weak var recognizer: UILongPressGestureRecognizer?
        private weak var panRecognizer: UIPanGestureRecognizer?
        /// いま動いている払いが自分のものか。
        private var mineSwipe = false
        /// いま動いている掴みが自分のものか。
        private var mine = false
        /// 掴んだ時点の指の位置（window 座標）。
        private var origin: CGPoint = .zero
        /// 掴んでいる間だけスクロールを止めた相手。必ず戻す。
        private weak var lockedScrollView: UIScrollView?
        /// 掴んでいる間、送るのを預かっている相手。**必ず戻す。**
        private weak var heldScrollView: UIScrollView?

        init(_ parent: ETDragHandle) { self.parent = parent }

        /// 認識器を **UIScrollView に** 付ける。
        ///
        /// superview に付けていたときは 1 度も呼ばれなかった。SwiftUI は
        /// 中身を UIView で作るとは限らないので、面の真上に何が来るかは
        /// 分からず、来た先がカードの祖先である保証も無い。
        /// UIScrollView なら鎖ぜんぶの祖先だと実測で分かっている
        /// （scroll を止める処理が `lock=true` を返していた＝辿り着けている）。
        /// そこに付ければ、カードのどこを触っても祖先として必ず呼ばれる。
        func attach() {
            guard recognizer == nil, let anchor else { return }
            guard let host = Self.enclosingScrollView(of: anchor) else { return }
            let g = UILongPressGestureRecognizer(target: self, action: #selector(handle(_:)))
            // **持ち上がるまで。**0.4 秒は待たされる。
            // 短くしすぎると軽く触れただけで掴んでしまうが、下限はタップが
            // 決まる長さ（指を置いて離すまで。普通は 0.2 秒に収まる）で、
            // そこを越えていれば取り合いにならない。
            // 払いと送りは別の口で見ているので、ここを詰めても取られない
            // （gestureRecognizerShouldBegin で送っている最中は立てない）。
            g.minimumPressDuration = 0.25
            // 長押しの判定中に指がぶれても外さない。掴んだ後は自由に動かす。
            // つまみを動かしている最中（10pt 以上動いた）は立たない。
            g.allowableMovement = 10
            // 立つまでは触りをそのまま流す。立ったら下の View の触りは
            // 取り消される（既定）。タップは 0.4 秒より前に終わるので奪わない。
            g.delaysTouchesBegan = false
            // **他のジェスチャと同時に動かす。**タップ（カードの開閉）や
            // スクロールを殺さないため。
            g.delegate = self
            host.addGestureRecognizer(g)
            recognizer = g

            // **横へ払う。**縦のスクロールと喧嘩しないよう、
            // 立つかどうかを向きで決める（gestureRecognizerShouldBegin）。
            let pan = UIPanGestureRecognizer(target: self, action: #selector(swipe(_:)))
            pan.delegate = self
            host.addGestureRecognizer(pan)
            panRecognizer = pan
        }

        /// 横へ払う。長押しと同じく、自分の行の上のぶんだけ通す。
        @objc func swipe(_ g: UIPanGestureRecognizer) {
            guard let anchor else { return }
            switch g.state {
            case .began:
                mineSwipe = anchor.bounds.contains(g.location(in: anchor))
                guard mineSwipe else { return }
                lockScroll(from: anchor)
                parent.swipeBegan()
            case .changed:
                guard mineSwipe else { return }
                parent.swiped(g.translation(in: anchor).x)
            case .ended, .cancelled, .failed:
                guard mineSwipe else { return }
                mineSwipe = false
                unlockScroll()
                parent.swipeEnded(g.translation(in: anchor).x,
                                  g.velocity(in: anchor).x)
            default:
                break
            }
        }

        /// 自分を載せている UIScrollView。
        private static func enclosingScrollView(of view: UIView) -> UIScrollView? {
            var v: UIView? = view.superview
            while let current = v {
                if let scroll = current as? UIScrollView { return scroll }
                v = current.superview
            }
            return nil
        }

        @objc func handle(_ g: UILongPressGestureRecognizer) {
            // **window は入口で要求しない。**
            // 掴んでいる行の面が階層から外れると（Section の挿入や行の削除で面が
            // 作り直される）window が nil になり、この guard で .ended ごと取りこぼす。
            // すると holdScroll が止めた送りが戻らず、
            // **スクロールが死んだまま残る。**window が要るのは .changed の座標だけ。
            guard let anchor else { return }
            switch g.state {
            case .began:
                // **自分の行の上か。**付けた先が鎖ぜんぶで 1 つだった場合、
                // 同じ認識器が全部の行のぶん立つ。ここで自分のぶんだけ通す。
                let p = g.location(in: anchor)
                guard anchor.bounds.contains(p) else { mine = false; return }
                // つまみの上で止まっていただけでカードを掴まない。
                guard !ownsDrag(under: g) else { mine = false; return }
                guard let window = anchor.window else { mine = false; return }
                mine = true
                origin = Self.finger(g, in: window)
                holdScroll(from: anchor)
                parent.began()
            case .changed:
                guard mine, let window = anchor.window else { return }
                let now = Self.finger(g, in: window)
                parent.moved(CGSize(width: now.x - origin.x,
                                    height: now.y - origin.y))
            case .ended, .cancelled, .failed:
                guard mine else { return }
                mine = false
                releaseScroll()
                parent.ended()
            default:
                break
            }
        }

        /// 掴んでいる間、**掴んだ指では送らず、残った指で送れるようにする。**
        ///
        /// `isScrollEnabled = false` だけにすると、掴んだままどちらの指でも送れない。
        /// 画面の外へ運べないのがこれ。手本（Shortcuts）は掴んだまま送れる。
        ///
        /// 一度 `panGestureRecognizer.minimumNumberOfTouches = 2` で解こうとしたが、
        /// **実機で効かなかった。**元から付いている認識器は掴んでいる指を既に握って
        /// いるので、こちらが途中で本数を変えても素直には立ち直らない。
        ///
        /// そこで元の pan は止めたまま、**掴んだあとに自前の pan を足す。**
        /// 認識器は足した時点で既に触れている指を拾わないので、ここへ来るのは
        /// **新しく置いた指だけ**になる。掴んでいる指は決して届かない。
        private func holdScroll(from view: UIView) {
            var v: UIView? = view
            while let current = v {
                if let scroll = current as? UIScrollView {
                    // **送りは器に任せる。**止めてしまうと、こちらで contentOffset を
                    // 動かすほかなくなり、慣性も跳ね返りも自前の作り物になる。
                    // 掴んでいる 1 本で動かないよう、送りに指 2 本を要求するだけにする。
                    scroll.panGestureRecognizer.minimumNumberOfTouches = 2
                    heldScrollView = scroll
                    return
                }
                v = current.superview
            }
        }

        private func releaseScroll() {
            heldScrollView?.panGestureRecognizer.minimumNumberOfTouches = 1
            heldScrollView = nil
        }

        /// 掴んでいる指の位置。`location(in:)` は触りの重心なので、送るために指を足すと
        /// 札が指の間へ寄ってしまう。最初の指だけを見る。
        private static func finger(_ g: UIGestureRecognizer, in view: UIView) -> CGPoint {
            g.numberOfTouches > 0 ? g.location(ofTouch: 0, in: view) : g.location(in: view)
        }

        /// 払っている間はスクロールを止める。**相手を覚えて必ず戻す。**
        /// こちらは横向きの一瞬なので、止める形のままでよい。
        private func lockScroll(from view: UIView) {
            var v: UIView? = view
            while let current = v {
                if let scroll = current as? UIScrollView {
                    scroll.isScrollEnabled = false
                    lockedScrollView = scroll
                    return
                }
                v = current.superview
            }
        }

        private func unlockScroll() {
            lockedScrollView?.isScrollEnabled = true
            lockedScrollView = nil
        }

        // タップもスクロールも殺さない。
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        /// **払いは横向きのときだけ立てる。**
        ///
        /// 付けている先は鎖を載せている UIScrollView なので、向きを見ずに
        /// 立てると縦のスクロールを全部奪う。指が出た向きで決める。
        /// 長押しのほうはここで落とさない（向きを持たないので）。
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            // **いま払っている最中なら掴みは立てない。**
            //
            // 長押しの閾値は 0.4 秒 / 10pt。指を置いたまま 0.4 秒のあいだに 10pt
            // 動かさず、そこからゆっくりスクロールを始めた回はこれを満たす。
            // 立ってしまうと、その touch のあいだ holdScroll が送りを止めるので
            // **スクロールが死ぬ**（掴むつもりが無かったのに止まる）。
            //
            // 見るのは isDragging だけ。isDecelerating まで見ると、惰性が止まり
            // きるまで掴めない（勢いよく送った直後に掴もうとすると無反応になる）。
            // まだ払い始めていない（指がほぼ止まっている）ときは isDragging が
            // 偽なので、press-and-hold の掴み方は今のまま変わらない。
            if g === recognizer, let host = g.view as? UIScrollView, host.isDragging {
                return false
            }
            guard let pan = g as? UIPanGestureRecognizer, pan === panRecognizer,
                  let anchor else { return true }
            guard anchor.bounds.contains(pan.location(in: anchor)) else { return false }
            let v = pan.velocity(in: anchor)
            guard abs(v.x) > abs(v.y) * 1.5 else { return false }
            return !ownsDrag(under: pan)
        }

        /// **指の下に、自分でドラッグを受けるものが居るか。**
        ///
        /// 掴みも払いも、鎖ぜんぶを載せている UIScrollView に付けてある。
        /// 祖先なのでカードのどこを触っても呼ばれる代わりに、カードの中の
        /// つまみを横に引いたときまで立ってしまう（実機で「スライダーを
        /// 動かしたいのに削除が出てくる」、2026-09-18）。
        ///
        /// SwiftUI の Slider は本物の UISlider で、UIControl として、
        /// 自前の UIPanGestureRecognizer を持った別の View として居る。
        /// 実機で当たりの連なりを出して確かめた:
        ///
        ///     [_UILiquidLensView][_UISliderGlassVisualElement]
        ///     [UISlider!UIControl g=UIPanGestureRecognizer,UILongPressGestureRecognizer]
        ///     [UIKitPlatformViewHost<PlatformViewRepresentableAdaptor<SystemSlider>>]
        ///     [PlatformGroupContainer][HostingScrollView …]
        ///
        /// だから「当たった所から器まで遡って、UIControl か、自前の pan を
        /// 持つものが居たら譲る」で足りる。つまみに限らず、後から足した
        /// 何かが自分でドラッグを受けるなら同じように譲る。
        ///
        /// **止まるのは自分が付いている器だけ。**「UIScrollView を見たら
        /// 器まで来た」と書いていたら、Matrix のように横へスクロールする
        /// 入れ子の器が全部「誰も居ない」扱いになり、横スクロールを
        /// 奪っていた（2026-09-18）。入れ子の器こそ譲る相手。
        private func ownsDrag(under g: UIGestureRecognizer) -> Bool {
            guard let anchor, let window = anchor.window else { return false }
            let host = panRecognizer?.view ?? recognizer?.view
            var v = window.hitTest(g.location(in: window), with: nil)
            while let cur = v {
                // 自分が付いている器まで来た＝間に誰も居なかった。
                // ここで止めないと、器自身が持っている pan を見て必ず譲る。
                if cur === host { return false }
                // 入れ子の器（Matrix の横スクロールなど）。
                if cur is UIScrollView { return true }
                if cur is UIControl { return true }
                if (cur.gestureRecognizers ?? []).contains(where: { $0 is UIPanGestureRecognizer }) {
                    return true
                }
                v = cur.superview
            }
            return false
        }
    }

    /// 場所を表すだけの面。**当たりは一切取らない。**
    ///
    /// ここが当たりを取ると、重ねたカードの中のつまみもボタンも触れなくなる。
    /// 認識器はこの面ではなく superview に付いているので、nil を返しても
    /// 呼ばれなくなることはない（触りはカードへ行き、その祖先に認識器がいる）。
    private final class HoleView: UIView {
        /// superview か window に入った。認識器を付ける頃合い。
        var onEnterHierarchy: (() -> Void)?

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            if superview != nil { onEnterHierarchy?() }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { onEnterHierarchy?() }
        }

        /// 階層に入った合図を取りこぼしても、置き直しのたびに試す。
        /// 付いていれば attach() の頭の guard で素通りする。
        override func layoutSubviews() {
            super.layoutSubviews()
            if window != nil { onEnterHierarchy?() }
        }
    }
}
