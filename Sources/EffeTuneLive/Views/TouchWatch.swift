//  TouchWatch.swift
//  カードの中に指が置かれている間だけを、**何にも触らずに**見ている（graph peek の「保持」）。
//
//  スクロール・長押し・タップ・スライダーのどれにも割り込まない。
//   - 状態を `.began` にしない（立たないので、他の認識器を止めも取り消しもしない）
//   - `cancelsTouchesInView = false`、`delaysTouchesBegan` / `delaysTouchesEnded` も偽
//   - 他の認識器と同時に動き、止められも止めもしない（canPrevent / canBePrevented を偽）
//
//  付け方は DragHandle.swift と同じ。**付けるのはカードの上ではなく、カードを載せている UIScrollView。**
//  面（HoleView）は当たりを取らず、触りはカードへ素通りする。認識器は祖先なので必ず呼ばれる。
//  面の矩形に入った指だけを自分のものとして知らせる（行ごとでも鎖で 1 つでも同じに動く）。

import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

// MARK: - 共有の部品（DragHandle.swift から移した）

/// 場所を表すだけの面。**当たりは一切取らない。**
///
/// ここが当たりを取ると、重ねたカードの中のつまみもボタンも触れなくなる。
/// 認識器はこの面ではなく superview に付いているので、nil を返しても
/// 呼ばれなくなることはない（触りはカードへ行き、その祖先に認識器がいる）。
final class HoleView: UIView {
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

extension UIView {
    /// 自分を載せている UIScrollView（自分自身は数えない）。
    var etEnclosingScrollView: UIScrollView? {
        var v: UIView? = superview
        while let current = v {
            if let scroll = current as? UIScrollView { return scroll }
            v = current.superview
        }
        return nil
    }
}

// MARK: - 触りの知らせ

/// 指の置き・離しの知らせ。
struct ETTouchWatchEvent: Equatable {
    enum Phase: Equatable {
        case down
        case up
    }

    var phase: Phase
    /// 面（カード）の座標での点。
    var local: CGPoint
    /// window の座標での点。重ねる面の中の高さへは呼び手が直す。
    var window: CGPoint
    /// 置かれている指の本数。**2 以上は、1 本目の保持の最中に 2 本目が来たとき。**
    /// 続けて `.up` が来る（認識器はそこで外れ、離しの知らせを受けられなくなるため）。
    var touches: Int
}

/// 面の矩形に指が 1 本置かれてから離れるまでを渡す。**見ているだけで、何も止めない。**
///
/// `.background(ETTouchWatch { … })` のように、カードの背面へ敷く。
struct ETTouchWatch: UIViewRepresentable {
    let onEvent: (ETTouchWatchEvent) -> Void

    func makeUIView(context: Context) -> UIView {
        let v = HoleView()
        context.coordinator.anchor = v
        // **付けるのは階層に入ってから。**理由は DragHandle.swift の makeUIView と同じ。
        v.onEnterHierarchy = { [weak coordinator = context.coordinator] in
            coordinator?.attach()
        }
        return v
    }

    func updateUIView(_ v: UIView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.attach()
    }

    /// 面が外れたら認識器も外す。UIScrollView は鎖ぜんぶで 1 つなので、残すと行の数だけ溜まる。
    static func dismantleUIView(_ v: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: ETTouchWatch
        /// 自分の場所を表す面。当たりは取らない。
        weak var anchor: UIView?
        private weak var recognizer: Recognizer?

        init(_ parent: ETTouchWatch) { self.parent = parent }

        /// 認識器を **UIScrollView に** 付ける（DragHandle.swift の attach と同じ理由）。
        func attach() {
            guard recognizer == nil, let anchor else { return }
            guard let host = anchor.etEnclosingScrollView else { return }
            let g = Recognizer()
            g.anchor = anchor
            g.onEvent = { [weak self] event in self?.parent.onEvent(event) }
            g.delegate = self
            host.addGestureRecognizer(g)
            recognizer = g
        }

        func detach() {
            guard let g = recognizer else { return }
            // 指が下りたまま外れるなら、離したと知らせておく（保持が残らないように）。
            // **知らせは次の回へ回す。**ここは View の組み直しの最中で、受け手はカードの @State を書く。
            let forward = g.onEvent
            g.onEvent = { event in DispatchQueue.main.async { forward?(event) } }
            g.finishIfActive()
            g.view?.removeGestureRecognizer(g)
            recognizer = nil
        }

        // 何とでも同時に動く。
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }

    /// `.began` に進まない認識器。`.possible` のまま見て、離れたら `.failed` で降りる。
    final class Recognizer: UIGestureRecognizer {
        weak var anchor: UIView?
        var onEvent: ((ETTouchWatchEvent) -> Void)?
        /// 自分の保持が動いているか。
        private var active = false
        /// 置かれている指の本数（認識器が見ている分）。
        private var fingers = 0
        private var last: (local: CGPoint, window: CGPoint) = (.zero, .zero)

        init() {
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }

        // 他の認識器を止めも、止められもしない。
        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            super.touchesBegan(touches, with: event)
            fingers += touches.count
            guard let anchor, let touch = touches.first else { state = .failed; return }
            let local = touch.location(in: anchor)
            let window = touch.location(in: nil)
            if fingers > 1 {
                // **2 本目。**保持の最中なら、複数の指だったと知らせて降りる。
                if active {
                    active = false
                    onEvent?(ETTouchWatchEvent(phase: .down, local: local, window: window, touches: fingers))
                    onEvent?(ETTouchWatchEvent(phase: .up, local: local, window: window, touches: fingers))
                }
                state = .failed
                return
            }
            guard anchor.bounds.contains(local) else { state = .failed; return }
            active = true
            last = (local, window)
            onEvent?(ETTouchWatchEvent(phase: .down, local: local, window: window, touches: 1))
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            super.touchesMoved(touches, with: event)
            guard active, let anchor, let touch = touches.first else { return }
            last = (touch.location(in: anchor), touch.location(in: nil))
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            super.touchesEnded(touches, with: event)
            fingers = max(0, fingers - touches.count)
            finishIfActive()
            state = .failed
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            super.touchesCancelled(touches, with: event)
            fingers = max(0, fingers - touches.count)
            finishIfActive()
            state = .failed
        }

        override func reset() {
            super.reset()
            // 離しの知らせを受けずに戻された（無効にされたなど）場合の保険。
            finishIfActive()
            fingers = 0
        }

        /// 保持が動いていれば、離したと知らせる。
        func finishIfActive() {
            guard active else { return }
            active = false
            onEvent?(ETTouchWatchEvent(phase: .up, local: last.local, window: last.window, touches: 1))
        }
    }
}
