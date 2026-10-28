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
        // **iCloud から鎖を戻すより先に。**前の版から上げたかを鎖の有無で見ている
        // ので、戻した後だと新しく入れた端末まで上げた人に見える（ProtocolMigration.swift）。
        // 撮影用の起動では見ない（帯の字が変わる）。
        assert(ETProtocolMigration.legacyKey == PipelineStore.lastKey,
               "ETProtocolMigration.legacyKey が PipelineStore.lastKey と違う")
        if ETScreenshotSeed.requested == nil {
            ETProtocolMigration.noteLaunch(storage: UserDefaults.standard)
        }
        CloudMirror.onChainRestored = { EffeTuneDSP.shared.adoptSeededChain() }
        CloudMirror.seedIfEmpty()
        // どの国の店から入れたか。中国本土では ChatGPT の入口を隠す（ETStorefrontGate）。
        ETStorefrontGate.shared.start()
        // PoC: Disconnect していなければ、控えた PC の EffeTune へつなぎ直す（DSP/RemoteMirror.swift）。
        // 店の版ではつながない（ETFeatures.remoteControl）。退避の戻しだけする。
        RemoteMirror.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                // -ETProbe 1 のときは並べ替えの切り分け用の画面
                // （ReorderProbeView.swift の頭）。
                if ETScreenshotSeed.probe {
                    ETReorderProbeView()
                } else {
                    PipelineView()
                }
            }
            // **標準より小さい文字サイズでは縮めない。**図の目盛りや補足は標準で 9〜11pt と小さく作ってあり、
            // iOS の最小の設定に合わせてさらに縮めると読めなくなった（本人の設定で確かめた）。
            // 大きくする側はそのまま効かせる。
            .dynamicTypeSize(.large...)
            // ナビゲーションバーの題やメニューは UIKit が描くので、上の指定が届かない。窓ごと下限を掛ける。
            .onAppear { ETContentSizeFloor.apply() }
            .onReceive(NotificationCenter.default.publisher(for: UIContentSizeCategory.didChangeNotification)) { _ in
                ETContentSizeFloor.apply()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIScene.didActivateNotification)) { _ in
                ETContentSizeFloor.apply()
            }
        }
    }
}

/// 標準より小さい文字サイズを、UIKit が描く所（ナビゲーションバーの題・メニュー・検索欄）にも効かせない。
/// SwiftUI の .dynamicTypeSize は SwiftUI の中にしか効かず、「Available Effects」の題は iOS の最小の設定のまま縮んでいた。
/// 窓の traitOverrides で文字サイズの下限を Large にする。iOS の設定が Large 以上なら、その値をそのまま使う。
@MainActor
enum ETContentSizeFloor {
    static func apply() {
        let system = UIApplication.shared.preferredContentSizeCategory
        let floor: UIContentSizeCategory = system < .large ? .large : system
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            // **上書きを読まない。**まだ置いていない上書きを読むと UIKit が例外を出して落ちる
            // （_UITraitOverrides _objectForTraitToken: の NSAssertion、実機で落ちた）。置くだけにする。
            for window in scene.windows {
                window.traitOverrides.preferredContentSizeCategory = floor
            }
        }
    }
}
