//  EffeTuneLiveApp.swift
//  EffectDeck — 他のアプリの音を受けて、EffeTune のエフェクトを通して出し直す。

import SwiftUI

@main
struct EffeTuneLiveApp: App {

    /// iCloud に写してあるものを、この端末がまだ空のときだけ戻す。
    /// **ここでなければ間に合わない。** 鎖を読むのは EffeTuneDSP.restore() で、
    /// それは下の body が PipelineView を作った時点（AudioIO の init）から来る。
    /// 詳しくは CloudMirror.seedIfEmpty の注記。
    ///
    /// 鎖だけは遅れて降りてくることがある（入れ直した直後）。そのとき画面へ
    /// 入れるのは DSP の担当なので、口を先に渡してから seed する。
    init() {
        CloudMirror.onChainRestored = { EffeTuneDSP.shared.adoptSeededChain() }
        CloudMirror.seedIfEmpty()
    }

    var body: some Scene {
        WindowGroup { PipelineView() }
    }
}
