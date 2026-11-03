//  UndoShakeResponder.swift
//  振って取り消す（shake to undo）ための、見えない first responder。
//
//  振るのは first responder の undoManager にしか届かない。鎖の画面は字を打って
//  いないとき first responder が誰も居ないので、3 本指と ⌘Z は効くのに
//  振っても「取り消す」が出なかった（実機、2026-11-03）。
//  そこで面を 1 枚敷き、**誰も first responder を持っていないときだけ**取る。
//  打っている欄や JSFX の鍵盤の面（EffectCardView の JSFXKeyboardCapture）からは奪わない。
//  そちらが持っている間も、undoManager は器を遡って同じものに届く。

import SwiftUI
import UIKit

struct ETUndoShakeResponder: UIViewRepresentable {
    func makeUIView(context: Context) -> ETUndoShakeView {
        let view = ETUndoShakeView()
        // 背面に敷くだけ。触りは受けない（first responder になるのに触りは要らない）。
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: ETUndoShakeView, context: Context) {}
}

final class ETUndoShakeView: UIView {
    private var observers: [NSObjectProtocol] = []

    override var canBecomeFirstResponder: Bool { true }

    /// 鎖の取り消しを積んでいる先（EffeTuneDSP.undoManager）。
    override var undoManager: UndoManager? {
        EffeTuneDSP.shared.undoManager ?? super.undoManager
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard window != nil else { return }
        // 取り直す時: 1 手積んだとき（振って出るのは積んだ後だけなので、ここが本命）、
        // キーボードが降りたとき（欄が手放した）、前面へ戻ったとき。
        let names: [Notification.Name] = [
            .NSUndoManagerDidCloseUndoGroup,
            UIResponder.keyboardDidHideNotification,
            UIApplication.didBecomeActiveNotification,
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in self?.claim()
            }
        }
        claim()
    }

    /// 誰も持っていないときだけ取る。
    private func claim() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil, !self.isFirstResponder else { return }
            ETFirstResponderProbe.found = nil
            UIApplication.shared.sendAction(#selector(UIResponder.et_findFirstResponder(_:)),
                                            to: nil, from: nil, for: nil)
            guard ETFirstResponderProbe.found == nil else { return }
            _ = self.becomeFirstResponder()
        }
    }
}
