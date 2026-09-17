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

import OSLog
import SwiftUI
import UIKit

private let handleLog = Logger(subsystem: "ai.nemut.effetune", category: "handle")

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
        /// 付ける試みを何回ログに出したか。黙って失敗されると分からない。
        private static var reports = 0

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
            guard let host = Self.enclosingScrollView(of: anchor) else {
                if Self.reports < 6 {
                    Self.reports += 1
                    handleLog.notice("付け先なし superview=\(String(describing: anchor.superview.map { type(of: $0) }), privacy: .public)")
                }
                return
            }
            let g = UILongPressGestureRecognizer(target: self, action: #selector(handle(_:)))
            g.minimumPressDuration = 0.4
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
            if Self.reports < 6 {
                Self.reports += 1
                handleLog.notice("付けた先=\(String(describing: type(of: host)), privacy: .public)")
            }
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
            guard let anchor, let window = anchor.window else { return }
            switch g.state {
            case .began:
                // **自分の行の上か。**付けた先が鎖ぜんぶで 1 つだった場合、
                // 同じ認識器が全部の行のぶん立つ。ここで自分のぶんだけ通す。
                let p = g.location(in: anchor)
                guard anchor.bounds.contains(p) else { mine = false; return }
                mine = true
                origin = g.location(in: window)
                lockScroll(from: anchor)
                handleLog.notice("began lock=\(self.lockedScrollView != nil, privacy: .public)")
                parent.began()
            case .changed:
                guard mine else { return }
                let now = g.location(in: window)
                parent.moved(CGSize(width: now.x - origin.x,
                                    height: now.y - origin.y))
            case .ended, .cancelled, .failed:
                guard mine else { return }
                mine = false
                handleLog.notice("ended state=\(g.state.rawValue, privacy: .public)")
                unlockScroll()
                parent.ended()
            default:
                break
            }
        }

        /// 掴んでいる間はスクロールを止める。**相手を覚えて必ず戻す。**
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
            guard let pan = g as? UIPanGestureRecognizer, pan === panRecognizer,
                  let anchor else { return true }
            guard anchor.bounds.contains(pan.location(in: anchor)) else { return false }
            let v = pan.velocity(in: anchor)
            return abs(v.x) > abs(v.y) * 1.5
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
