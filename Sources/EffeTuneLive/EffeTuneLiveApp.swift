//  EffeTuneLiveApp.swift
//  EffectDeck — 他のアプリの音を受けて、EffeTune のエフェクトを通して出し直す。

import SwiftUI
import UIKit

final class ETAppDelegate: NSObject, UIApplicationDelegate {
    static var supportedOrientations: UIInterfaceOrientationMask = .all

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?)
        -> UIInterfaceOrientationMask {
        Self.supportedOrientations
    }
}

@main
struct EffeTuneLiveApp: App {

    @UIApplicationDelegateAdaptor(ETAppDelegate.self) private var appDelegate

    /// iCloud に写してあるものを、この端末がまだ空のときだけ戻す。
    /// **ここでなければ間に合わない。** 鎖を読むのは EffeTuneDSP.restore() で、
    /// それは下の body が PipelineView を作った時点（AudioIO の init）から来る。
    /// 詳しくは CloudMirror.seedIfEmpty の注記。
    ///
    /// 鎖だけは遅れて降りてくることがある（入れ直した直後）。そのとき画面へ
    /// 入れるのは DSP の担当なので、口を先に渡してから seed する。
    init() {
        // -ETBenchJSFX 1（Debug・Beta だけ）は JSFX の速さを測って終わる（JSFXBench.swift）。
        // **ほかの起動の仕事より先に分ける。**iCloud から鎖を戻す・店の国を見る・
        // 音の経路を作る（PipelineView）のどれもしない。
        if ETJSFXBenchMode.requested {
            #if DEBUG || ET_BETA
            ETJSFXBenchMode.start()
            #endif
            return
        }
        CloudMirror.onChainRestored = { EffeTuneDSP.shared.adoptSeededChain() }
        CloudMirror.seedIfEmpty()
        // どの国の店から入れたか。中国本土では ChatGPT の入口を隠す（ETStorefrontGate）。
        ETStorefrontGate.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            // -ETProbe 1 のときは並べ替えの切り分け用の画面
            // （ReorderProbeView.swift の頭）。
            if ETJSFXBenchMode.requested {
                Color.black.ignoresSafeArea()
            } else if ETScreenshotSeed.probe {
                ETReorderProbeView()
            } else {
                PipelineView()
            }
        }
    }
}
