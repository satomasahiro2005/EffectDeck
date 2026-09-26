//  ETScrollBrake.swift
//  慣性で流れている一覧を止めてから飛ぶ。
//
//  払った一覧が慣性で流れている間は、ScrollViewProxy.scrollToを呼んでも動かない。
//  SwiftUIには流れを止める口が無いので、下のUIScrollViewを掴んで止める。
//  **今の位置へanimated:falseで置き直すと慣性が止まる。**UIKitの定石。
//
//  ScrollPositionへは移さなかった。流れている最中に効くかを確かめられていない。
//  こちらは止めるのがUIKitなので、飛ぶ側の作りに依らない。
//
//  使い方:
//
//      @State private var brake = ETScrollBrake()
//
//      ScrollView {
//          LazyVStack { … }
//              .etScrollBrake(brake)
//      }
//
//      brake.jump { proxy.scrollTo(id, anchor: .top) }
//
//  **付けるのは流れる面の中。**祖先をたどって一番近いUIScrollViewを掴むので、外に付けると掴めない。
//  ScrollViewなら中のLazyVStack、Listなら行か見出しに付ける。
//  縦横に流れるScrollView（JSFXSourceView）も1つのUIScrollViewとして扱い、止めるときは縦横とも範囲に収める。
//  中身がUIScrollViewの子孫に居ることはDragHandle.swiftが実機で確かめている。

import SwiftUI
import UIKit

/// 流れている一覧を止める。飛ぶときは`jump`を通す。
@MainActor
final class ETScrollBrake {
    /// 止める相手。`etScrollBrake`を付けた面がwindowに入ったときに覚える。
    /// 読むだけなら外からもできる（2列の右で読んでいる位置を保つETReadingKeeperが使う）。
    fileprivate(set) weak var scrollView: UIScrollView?

    /// **流れていれば止めて、飛ぶのは次の回に回す。**止まっていればその場で`scroll`を呼ぶ。
    ///
    /// 止めたことがSwiftUIの側にいつ伝わるかは外から見えない。
    /// 同じ回で続けてscrollToを呼ぶと、まだ流れているとみなされて捨てられる恐れが残る。
    /// 次の回へ回せば、止めたときに積まれた後始末より後ろに並ぶ。
    func jump(_ scroll: @escaping () -> Void) {
        guard let view = scrollView, view.isDecelerating else {
            scroll()
            return
        }
        view.setContentOffset(Self.clamped(view), animated: false)
        Task { @MainActor in scroll() }
    }

    /// 今の位置を動ける範囲に収めたもの。縦横とも収める。
    /// **端で跳ね返っている最中に止めると、はみ出したまま残る。**
    /// 飛び先が見つからずscrollが何もしなかった回に戻らなくなるので、範囲の中で止める。
    private static func clamped(_ view: UIScrollView) -> CGPoint {
        let inset = view.adjustedContentInset
        let content = view.contentSize
        let frame = view.bounds.size
        let minX = -inset.left
        let minY = -inset.top
        let maxX = max(minX, content.width - frame.width + inset.right)
        let maxY = max(minY, content.height - frame.height + inset.bottom)
        var p = view.contentOffset
        p.x = min(max(p.x, minX), maxX)
        p.y = min(max(p.y, minY), maxY)
        return p
    }
}

extension View {
    /// `brake`に、これを載せているUIScrollViewを覚えさせる。**流れる面の中に付ける。**
    func etScrollBrake(_ brake: ETScrollBrake) -> some View {
        background(ETScrollBrakeAnchor(brake: brake))
    }
}

/// 場所を知らせるだけの面。当たりは取らない（DragHandle.swiftのHoleViewと同じ）。
private struct ETScrollBrakeAnchor: UIViewRepresentable {
    let brake: ETScrollBrake

    func makeUIView(context: Context) -> Probe { Probe(brake: brake) }

    func updateUIView(_ view: Probe, context: Context) { view.brake = brake }

    final class Probe: UIView {
        weak var brake: ETScrollBrake?

        init(brake: ETScrollBrake) {
            self.brake = brake
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

        /// **windowに入ってから探す。**makeUIViewの時点では上がまだ繋がっていないことがある
        /// （DragHandle.swiftで実機確認済み）。付けた行や見出しが流れて画面から外れても、
        /// 覚えた相手は手放さない。外れた後に飛ぶのがこの修正の本題なので。
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            var v = superview
            while let current = v {
                if let scroll = current as? UIScrollView {
                    brake?.scrollView = scroll
                    return
                }
                v = current.superview
            }
        }
    }
}
