//  AccessibilityGallery.swift
//  実アプリの主要な画面を、文字サイズ・外観・幅を変えて撮り、添付として残す。
//
//  **何も判定しない。**人が見るための絵を作るだけで、落ちるのは起動できなかったときだけ。
//  CI（macos の a11y）が xcresult から添付を書き出して artifact に上げる。
//  画像の名前は <画面>-<組み合わせ>.png（組み合わせは A11yVariant.name）。
//  1 画面 = 1 テスト。途中で 1 枚しくじっても残りは撮れる。

import XCTest

final class AccessibilityGallery: XCTestCase {

    override func setUp() {
        continueAfterFailure = true
    }

    private func shoot(_ scene: String, seed: String, sheet: String? = nil,
                       variants: [A11yVariant], settle: TimeInterval = 6) {
        for variant in variants {
            let app = A11yLaunch.launch(seed: seed, sheet: sheet, variant: variant, settle: settle)
            let shot = XCUIScreen.main.screenshot()
            let att = XCTAttachment(screenshot: shot)
            att.name = "\(scene)-\(variant.name)"
            att.lifetime = .keepAlways
            add(att)
            print("A11Y-SHOT \(scene)-\(variant.name)")
            app.terminate()
        }
    }

    /// 鎖。Section・15Band PEQ・Stereo Meter・Gate・Compressor・Reverb が並ぶ。
    func testChain() {
        shoot("chain", seed: "demo", variants: A11yVariant.full)
    }

    /// 5 バンド PEQ。値の欄とバンドのチップが一番密な所。
    func testPEQ() {
        shoot("peq", seed: "peq", variants: A11yVariant.full)
    }

    /// 図が主役のカード。Spectrogram は埋まるまで時間が要るので長めに待つ。
    func testAnalyzers() {
        shoot("analyzers", seed: "analyzers4",
              variants: [.large, .ax3Light, .ax3Dark], settle: 10)
    }

    /// 同梱のプリセットを読んだ鎖（Compressor・Reverb など値の入ったカード）。
    func testTubeAmp() {
        shoot("tube", seed: "tube", variants: A11yVariant.short)
    }

    func testPicker() {
        shoot("picker", seed: "demo", sheet: "picker", variants: A11yVariant.short, settle: 4)
    }

    func testSettings() {
        shoot("settings", seed: "demo", sheet: "settings", variants: A11yVariant.short, settle: 4)
    }

    func testPresets() {
        shoot("presets", seed: "demo", sheet: "presets", variants: A11yVariant.short, settle: 4)
    }
}
