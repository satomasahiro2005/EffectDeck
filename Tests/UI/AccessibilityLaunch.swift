//  AccessibilityLaunch.swift
//  AccessibilityAudit と AccessibilityGallery が共有する起動の道具。
//
//  実アプリを -ETSeed の鎖で起こし、文字サイズ・外観・幅を起動の引数で変える。
//  引数は Scripts/shoot_*.sh や SiteShots と同じ系統（ScreenshotSeed.swift が読む）。
//  シミュレータでは拡張が動かないので音は来ないが、画面は同じものが出る。

import XCTest

/// 起動の組み合わせ 1 つ。名前は画像のファイル名にそのまま入る。
struct A11yVariant {
    let name: String
    /// UIContentSizeCategory の生の名前。nil なら既定（Large）。
    let size: String?
    let dark: Bool
    /// true なら iPad の幅そのままで 2 列（左に一覧）。false なら撮影の既定（iPhone の幅 393pt）。
    let wide: Bool

    // 文字サイズの生の名前。AX1 = AccessibilityM、AX3 = AccessibilityXL、AX5 = AccessibilityXXXL。
    static let xxxl = "UICTContentSizeCategoryXXXL"
    static let ax3 = "UICTContentSizeCategoryAccessibilityXL"
    static let ax5 = "UICTContentSizeCategoryAccessibilityXXXL"

    static let large = A11yVariant(name: "L-light", size: nil, dark: false, wide: false)
    static let ax3Light = A11yVariant(name: "AX3-light", size: ax3, dark: false, wide: false)
    static let ax3Dark = A11yVariant(name: "AX3-dark", size: ax3, dark: true, wide: false)

    /// 画面ごとに全部並べる組。外観・文字サイズ・幅の代表だけ（組み合わせを全部は撮らない）。
    static let full: [A11yVariant] = [
        large,
        A11yVariant(name: "L-dark", size: nil, dark: true, wide: false),
        A11yVariant(name: "XXXL-light", size: xxxl, dark: false, wide: false),
        ax3Light,
        ax3Dark,
        A11yVariant(name: "AX5-light", size: ax5, dark: false, wide: false),
        A11yVariant(name: "L-wide-light", size: nil, dark: false, wide: true),
        A11yVariant(name: "AX3-wide-light", size: ax3, dark: false, wide: true),
    ]

    /// シートなど、数を絞りたい画面向け。
    static let short: [A11yVariant] = [large, ax3Light, ax3Dark]
}

enum A11yLaunch {

    /// 起動して、本画面（ナビゲーションバー）が出るまで待つ。
    /// **ボタンの名前では待たない。**文字を大きくするとツールバーが畳まれて名前が変わりうる。
    ///
    /// `freezeLive` は監査用。図・メーター・帯の数字の更新を止めて起動する（-ETFreezeLive）。
    /// 絵を撮るほう（Gallery）は動いている図を撮りたいので既定は false。
    static func launch(seed: String, sheet: String? = nil, variant: A11yVariant,
                       settle: TimeInterval = 6, freezeLive: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["-ETMock", "1", "-ETMockMode", "music", "-ETSeed", seed]
        args += ["-ETWidth", variant.wide ? "0" : "393"]
        if variant.wide { args += ["-ETLayout", "wide"] }
        if let sheet { args += ["-ETSheet", sheet] }
        if freezeLive { args += ["-ETFreezeLive", "1"] }
        if let size = variant.size { args += ["-UIPreferredContentSizeCategoryName", size] }
        app.launchArguments = args
        // **外観は起動の引数でなくシミュレータ本体に設定する。**-AppleInterfaceStyle は macOS の設定で、
        // iOS の UIKit は起動の引数から読まない（暗い名前の絵が明るいまま出る）。
        // 組ごとに毎回設定し直し、暗い回が次の組へ残らないようにする。
        XCUIDevice.shared.appearance = variant.dark ? .dark : .light
        // 外観の切り替えは設定した直後には反映が終わっていないことがある。
        // 終わる前に起動すると暗い回が明るいまま撮れた（-dark の全画面が -light と同じ絵だった）。
        // 起動より前に 1 回だけ待つ（起動後の待ち settle とは別）。
        Thread.sleep(forTimeInterval: 1.5)
        app.launch()
        _ = app.navigationBars.firstMatch.waitForExistence(timeout: 60)
        // 図は描き出すまで少しかかる（Spectrogram は埋まるまで）。
        Thread.sleep(forTimeInterval: settle)
        return app
    }
}
