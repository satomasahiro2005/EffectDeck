//  SiteShots.swift
//  effectdeck.nemut.ai のガイドに載せる画面を iPhone のシミュレータで撮る。
//
//  撮った絵は SITESHOTS（既定 ~/work/siteshots）へ <名前>.png で書く。名前はサイトの枠の名前
//  （site/src/guide.js の shots の id）。撮れなかったときに追えるよう、木も tree-<名前>.txt で残す。
//  ファイル App に置く見本（AutoEq の補正・ASH の BRIR・JSFX）は ~/work/siteshots_run.sh が先に置く。
//  **1 枚ずつ別のテストにする。**途中で 1 枚しくじっても残りは撮れる。

import XCTest
import UIKit

final class SiteShots: XCTestCase {

    private var dir: String {
        ProcessInfo.processInfo.environment["SITESHOTS"] ?? "/Users/satoumasahiro/work/siteshots"
    }

    override func setUp() {
        continueAfterFailure = true
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // 前のテストのリンクが残っていると、起動のたびに「A link is on the clipboard」の帯が写る
        UIPasteboard.general.items = []
    }

    // MARK: - 道具

    private func snap(_ name: String, _ app: XCUIApplication? = nil) {
        Thread.sleep(forTimeInterval: 1.2)
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
        if let app {
            let t = URL(fileURLWithPath: dir).appendingPathComponent("tree-\(name).txt")
            try? app.debugDescription.write(to: t, atomically: true, encoding: .utf8)
        }
        print("SITESHOT \(name)")
    }

    private func launch(_ args: [String], wait: TimeInterval = 7) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ETWidth", "0", "-ETMock", "1", "-ETMockMode", "music"] + args
        app.launch()
        Thread.sleep(forTimeInterval: wait)
        return app
    }

    /// ラベルで引く。完全一致→前方一致。画面に出ているもの（hittable）を先に返す。
    private func find(_ app: XCUIApplication, _ label: String, type: XCUIElement.ElementType = .any,
                      below y: CGFloat = 0) -> XCUIElement? {
        for pred in [NSPredicate(format: "label == %@", label),
                     NSPredicate(format: "identifier == %@", label),
                     NSPredicate(format: "label BEGINSWITH %@", label)] {
            let all = app.descendants(matching: type).matching(pred).allElementsBoundByIndex
                .filter { $0.exists && $0.frame.minY >= y }
            if let e = all.first(where: { $0.isHittable }) ?? all.first { return e }
        }
        return nil
    }

    /// 見えるまで上へ送ってから押す。
    @discardableResult
    private func tap(_ app: XCUIApplication, _ label: String, type: XCUIElement.ElementType = .any,
                     below y: CGFloat = 0, swipes: Int = 8, timeout: TimeInterval = 8) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let e = find(app, label, type: type, below: y) {
                var n = 0
                while !e.isHittable && n < swipes { app.swipeUp(velocity: .slow); n += 1 }
                if e.isHittable { e.tap(); Thread.sleep(forTimeInterval: 1.0); return true }
                e.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                Thread.sleep(forTimeInterval: 1.0)
                return true
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        print("SITESHOT-MISS \(label)")
        return false
    }

    /// 要素が画面の上の方に来るまで送る（撮る前の位置合わせ）。
    private func bringUp(_ app: XCUIApplication, _ label: String, to fraction: CGFloat = 0.3, type: XCUIElement.ElementType = .any) {
        let h = app.frame.height
        for _ in 0..<12 {
            guard let e = find(app, label, type: type) else { app.swipeUp(velocity: .slow); continue }
            if e.frame.minY < h * fraction + 40 && e.frame.minY > 90 { return }
            if e.frame.minY < 90 { app.swipeDown(velocity: .slow) } else {
                let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                let dy = min(e.frame.minY - h * fraction, h * 0.6)
                let to = from.withOffset(CGVector(dx: 0, dy: -dy))
                from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.3)
            }
        }
    }

    /// カードの電源（identifier power.circle.fill、label はエフェクトの名前）。左上の Effects は全体のバイパスなので押さない。
    private func cardPower(_ app: XCUIApplication, _ name: String) {
        let sw = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH 'power' AND label == %@", name)).firstMatch
        if sw.waitForExistence(timeout: 4) { sw.tap(); Thread.sleep(forTimeInterval: 1.5) } else { print("SITESHOT-MISS power \(name)") }
    }

    /// 行全体が Switch になっているトグルは、右端のつまみを押す。
    private func toggleOff(_ app: XCUIApplication, _ label: String) {
        let sw = app.switches.matching(NSPredicate(format: "label == %@", label)).firstMatch
        guard sw.waitForExistence(timeout: 4) else { print("SITESHOT-MISS switch \(label)"); return }
        if (sw.value as? String) == "1" {
            let knob = sw.switches.firstMatch
            if knob.exists { knob.tap() } else { sw.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap() }
        }
        Thread.sleep(forTimeInterval: 1)
    }

    /// 上の端まで戻す。カードの外（左の余白）を引くので、図やつまみを動かさない。
    private func scrollTop(_ app: XCUIApplication) {
        for _ in 0..<4 {
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.25))
            from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: 600)), withVelocity: .fast, thenHoldForDuration: 0.1)
        }
        Thread.sleep(forTimeInterval: 1)
    }

    /// キーボードが出たままだと変換候補まで写る。改行で閉じる（名前の欄は改行で確定するだけ）。
    private func dismissKeyboard(_ app: XCUIApplication) {
        if app.keyboards.firstMatch.exists {
            for l in ["完了", "確定", "改行", "Return", "Done"] where app.keyboards.buttons[l].exists {
                app.keyboards.buttons[l].tap(); Thread.sleep(forTimeInterval: 1); break
            }
        }
        if app.keyboards.firstMatch.exists { app.typeText("\n"); Thread.sleep(forTimeInterval: 1) }
    }

    private func typeName(_ app: XCUIApplication, _ text: String) {
        let field = app.textFields.firstMatch
        if field.waitForExistence(timeout: 5) { field.tap(); Thread.sleep(forTimeInterval: 0.8); field.typeText(text) }
        else { print("SITESHOT-MISS text field") }
    }

    /// 長押しで出る「ペースト」の許可を通す。
    private func allowPaste() {
        let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow Paste", "ペーストを許可", "Paste", "ペースト"] {
            let b = sb.buttons[label]
            if b.waitForExistence(timeout: 2) { b.tap(); return }
        }
    }

    /// ファイルの選び手でファイルを押す（「このiPhone内」まで降りる）。
    private func pickFile(_ app: XCUIApplication, _ name: String, shot: String? = nil) {
        Thread.sleep(forTimeInterval: 2)
        if find(app, name) == nil {
            if !tap(app, "ブラウズ", timeout: 3) { tap(app, "Browse", timeout: 2) }
            if !tap(app, "このiPhone内", timeout: 4) { tap(app, "On My iPhone", timeout: 2) }
        }
        Thread.sleep(forTimeInterval: 1.5)
        if let shot { snap(shot, app) }
        tap(app, name, timeout: 6)
        Thread.sleep(forTimeInterval: 2)
        // 開くボタンが出る選び手もある
        for l in ["開く", "Open"] { if let open = find(app, l, type: .button), open.isHittable { open.tap(); break } }
        Thread.sleep(forTimeInterval: 2)
    }

    /// 鎖を共有リンクにしてクリップボードへ置き、起ち上げ直して帯の Paste で貼る。帯は撮らない。
    private func pasteChain(_ link: String, args: [String]) -> XCUIApplication {
        UIPasteboard.general.string = "https://effectdeck.nemut.ai/?p=" + link
        let app = launch(args, wait: 6)
        let paste = app.buttons["Paste"].firstMatch
        if paste.waitForExistence(timeout: 6) { paste.tap() } else { print("SITESHOT-MISS banner Paste") }
        allowPaste()
        for l in ["Replace chain", "Import", "Paste"] {
            let ok = app.buttons[l].firstMatch
            if ok.waitForExistence(timeout: 2), ok.isHittable { ok.tap(); break }
        }
        Thread.sleep(forTimeInterval: 2)
        UIPasteboard.general.items = []
        return app
    }

    /// 鎖を文字で取り込む（Presets → Import from clipboard）。
    private func importChain(_ app: XCUIApplication, _ json: String, shot: String? = nil) {
        UIPasteboard.general.string = json
        tap(app, "Presets", type: .button)
        Thread.sleep(forTimeInterval: 1.5)
        bringUp(app, "Import from clipboard", to: 0.45)
        if let shot { snap(shot, app) }
        tap(app, "Import from clipboard")
        allowPaste()
        Thread.sleep(forTimeInterval: 1)
        for l in ["Replace chain", "Import"] {
            let ok = app.buttons[l].firstMatch
            if ok.waitForExistence(timeout: 3) { ok.tap(); break }
        }
        Thread.sleep(forTimeInterval: 1.5)
        if app.buttons["Done"].exists { app.buttons["Done"].firstMatch.tap() }
        Thread.sleep(forTimeInterval: 1.5)
    }

    private func searchPicker(_ app: XCUIApplication, _ text: String) {
        let field = app.searchFields["Search effects"].firstMatch
        if field.waitForExistence(timeout: 5) { field.tap(); field.typeText(text); Thread.sleep(forTimeInterval: 1.5) }
    }

    private func openPicker(_ app: XCUIApplication) {
        tap(app, "Add Effect", type: .button)
        Thread.sleep(forTimeInterval: 1.5)
    }

    /// シートの中の区切り（Effects / Plugins / Presets）。ツールバーの Presets と名前が同じなので下側を押す。
    private func pane(_ app: XCUIApplication, _ label: String) {
        tap(app, label, type: .button, below: 300)
    }

    // MARK: - connect

    func test_connect_4() {
        let app = launch(["-ETSeed", "analyzers4", "-ETCollapsed", "1"], wait: 14)
        snap("g-connect-4", app)
    }

    // MARK: - correction

    func test_correction_2_autoeq() {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.launch()
        XCUIDevice.shared.system.open(URL(string: "https://autoeq.app/")!)
        Thread.sleep(forTimeInterval: 10)
        let field = safari.webViews.searchFields.firstMatch.exists ? safari.webViews.searchFields.firstMatch : safari.webViews.textFields.firstMatch
        if field.waitForExistence(timeout: 8) {
            field.tap()
            field.typeText("Sennheiser HD 600")
            Thread.sleep(forTimeInterval: 3)
        }
        snap("g-correction-2", safari)
        safari.terminate()
    }

    func test_files() {
        let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        files.launch()
        Thread.sleep(forTimeInterval: 3)
        for l in ["ブラウズ", "Browse"] where files.buttons[l].exists { files.buttons[l].tap(); Thread.sleep(forTimeInterval: 1); break }
        if let e = find(files, "このiPhone内") ?? find(files, "On My iPhone") { e.tap(); Thread.sleep(forTimeInterval: 2) }
        snap("g-correction-3", files)
        snap("g-brir-4", files)
        files.terminate()
    }

    func test_correction_4_5() {
        let app = launch(["-ETSeed", "FifteenBandPEQPlugin"])
        bringUp(app, "Import", to: 0.55, type: .button)
        snap("g-correction-4", app)
        app.terminate()
        let after = pasteChain("W3sibm0iOiIxNUJhbmQgUEVRIiwiZW4iOnRydWUsImYwIjoxMDUsImcwIjo2LjUsInEwIjowLjcsInQwIjoibHMiLCJlMCI6dHJ1ZSwiZjEiOjEyNSwiZzEiOi0yLjcsInExIjowLjU1LCJ0MSI6InBrIiwiZTEiOnRydWUsImYyIjo4NDQ1LCJnMiI6My4zLCJxMiI6MS42MSwidDIiOiJwayIsImUyIjp0cnVlLCJmMyI6NTIyLCJnMyI6MC43LCJxMyI6MS4wMiwidDMiOiJwayIsImUzIjp0cnVlLCJmNCI6MTI5OCwiZzQiOi0xLjIsInE0IjoyLjE0LCJ0NCI6InBrIiwiZTQiOnRydWUsImY1IjoxMDAwMCwiZzUiOi0zLjEsInE1IjowLjcsInQ1IjoiaHMiLCJlNSI6dHJ1ZSwiZjYiOjMxNTgsImc2IjotMS44LCJxNiI6My42NywidDYiOiJwayIsImU2Ijp0cnVlLCJmNyI6MjE2NiwiZzciOjAuOSwicTciOjMuMzIsInQ3IjoicGsiLCJlNyI6dHJ1ZSwiZjgiOjY2MzksImc4IjoyLjIsInE4Ijo1LjgyLCJ0OCI6InBrIiwiZTgiOnRydWUsImY5Ijo1NDMzLCJnOSI6LTEuMiwicTkiOjUuNywidDkiOiJwayIsImU5Ijp0cnVlLCJmMTAiOjI1MDAsImcxMCI6MCwicTEwIjoxLCJ0MTAiOiJwayIsImUxMCI6ZmFsc2UsImYxMSI6NDAwMCwiZzExIjowLCJxMTEiOjEsInQxMSI6InBrIiwiZTExIjpmYWxzZSwiZjEyIjo2MzAwLCJnMTIiOjAsInExMiI6MSwidDEyIjoicGsiLCJlMTIiOmZhbHNlLCJmMTMiOjEwMDAwLCJnMTMiOjAsInExMyI6MSwidDEzIjoicGsiLCJlMTMiOmZhbHNlLCJmMTQiOjE2MDAwLCJnMTQiOjAsInExNCI6MSwidDE0IjoicGsiLCJlMTQiOmZhbHNlfV0", args: ["-ETSeed", "none"])
        snap("g-correction-5", after)
    }

    func test_correction_6_7() {
        let app = pasteChain("W3sibm0iOiJWb2x1bWUiLCJlbiI6dHJ1ZSwidmwiOi02fSx7Im5tIjoiMTVCYW5kIFBFUSIsImVuIjp0cnVlLCJmMCI6MTA1LCJnMCI6Ni41LCJxMCI6MC43LCJ0MCI6ImxzIiwiZTAiOnRydWUsImYxIjoxMjUsImcxIjotMi43LCJxMSI6MC41NSwidDEiOiJwayIsImUxIjp0cnVlLCJmMiI6ODQ0NSwiZzIiOjMuMywicTIiOjEuNjEsInQyIjoicGsiLCJlMiI6dHJ1ZSwiZjMiOjUyMiwiZzMiOjAuNywicTMiOjEuMDIsInQzIjoicGsiLCJlMyI6dHJ1ZSwiZjQiOjEyOTgsImc0IjotMS4yLCJxNCI6Mi4xNCwidDQiOiJwayIsImU0Ijp0cnVlLCJmNSI6MTAwMDAsImc1IjotMy4xLCJxNSI6MC43LCJ0NSI6ImhzIiwiZTUiOnRydWUsImY2IjozMTU4LCJnNiI6LTEuOCwicTYiOjMuNjcsInQ2IjoicGsiLCJlNiI6dHJ1ZSwiZjciOjIxNjYsImc3IjowLjksInE3IjozLjMyLCJ0NyI6InBrIiwiZTciOnRydWUsImY4Ijo2NjM5LCJnOCI6Mi4yLCJxOCI6NS44MiwidDgiOiJwayIsImU4Ijp0cnVlLCJmOSI6NTQzMywiZzkiOi0xLjIsInE5Ijo1LjcsInQ5IjoicGsiLCJlOSI6dHJ1ZSwiZjEwIjoyNTAwLCJnMTAiOjAsInExMCI6MSwidDEwIjoicGsiLCJlMTAiOmZhbHNlLCJmMTEiOjQwMDAsImcxMSI6MCwicTExIjoxLCJ0MTEiOiJwayIsImUxMSI6ZmFsc2UsImYxMiI6NjMwMCwiZzEyIjowLCJxMTIiOjEsInQxMiI6InBrIiwiZTEyIjpmYWxzZSwiZjEzIjoxMDAwMCwiZzEzIjowLCJxMTMiOjEsInQxMyI6InBrIiwiZTEzIjpmYWxzZSwiZjE0IjoxNjAwMCwiZzE0IjowLCJxMTQiOjEsInQxNCI6InBrIiwiZTE0IjpmYWxzZX0seyJubSI6IkxldmVsIE1ldGVyIiwiZW4iOnRydWV9XQ", args: ["-ETSeed", "none"])
        snap("g-correction-6", app)
        bringUp(app, "Level Meter", to: 0.2)
        Thread.sleep(forTimeInterval: 3)
        snap("g-correction-7", app)
    }

    /// 補正だけの鎖を保存し、Output Correction で出力先に割り当てるまで。共有の 2 枚もここで撮る。
    func test_correction_9_to_14() {
        let first = launch(["-ETSeed", "vinyl", "-ETCollapsed", "1"])
        tap(first, "Presets", type: .button)
        bringUp(first, "Import from clipboard", to: 0.45)
        snap("g-correction-9", first)
        first.terminate()
        let app = pasteChain("W3sibm0iOiIxNUJhbmQgUEVRIiwiZW4iOnRydWUsImYwIjoxMDUsImcwIjo2LjUsInEwIjowLjcsInQwIjoibHMiLCJlMCI6dHJ1ZSwiZjEiOjEyNSwiZzEiOi0yLjcsInExIjowLjU1LCJ0MSI6InBrIiwiZTEiOnRydWUsImYyIjo4NDQ1LCJnMiI6My4zLCJxMiI6MS42MSwidDIiOiJwayIsImUyIjp0cnVlLCJmMyI6NTIyLCJnMyI6MC43LCJxMyI6MS4wMiwidDMiOiJwayIsImUzIjp0cnVlLCJmNCI6MTI5OCwiZzQiOi0xLjIsInE0IjoyLjE0LCJ0NCI6InBrIiwiZTQiOnRydWUsImY1IjoxMDAwMCwiZzUiOi0zLjEsInE1IjowLjcsInQ1IjoiaHMiLCJlNSI6dHJ1ZSwiZjYiOjMxNTgsImc2IjotMS44LCJxNiI6My42NywidDYiOiJwayIsImU2Ijp0cnVlLCJmNyI6MjE2NiwiZzciOjAuOSwicTciOjMuMzIsInQ3IjoicGsiLCJlNyI6dHJ1ZSwiZjgiOjY2MzksImc4IjoyLjIsInE4Ijo1LjgyLCJ0OCI6InBrIiwiZTgiOnRydWUsImY5Ijo1NDMzLCJnOSI6LTEuMiwicTkiOjUuNywidDkiOiJwayIsImU5Ijp0cnVlLCJmMTAiOjI1MDAsImcxMCI6MCwicTEwIjoxLCJ0MTAiOiJwayIsImUxMCI6ZmFsc2UsImYxMSI6NDAwMCwiZzExIjowLCJxMTEiOjEsInQxMSI6InBrIiwiZTExIjpmYWxzZSwiZjEyIjo2MzAwLCJnMTIiOjAsInExMiI6MSwidDEyIjoicGsiLCJlMTIiOmZhbHNlLCJmMTMiOjEwMDAwLCJnMTMiOjAsInExMyI6MSwidDEzIjoicGsiLCJlMTMiOmZhbHNlLCJmMTQiOjE2MDAwLCJnMTQiOjAsInExNCI6MSwidDE0IjoicGsiLCJlMTQiOmZhbHNlfV0", args: ["-ETSeed", "none"])

        // 保存
        tap(app, "Presets", type: .button)
        typeName(app, "Air Pro 4")
        snap("g-correction-10", app)
        tap(app, "Save", type: .button, below: 150)
        Thread.sleep(forTimeInterval: 1.5)
        dismissKeyboard(app)
        snap("g-correction-11", app)

        // 割り当て
        tap(app, "Output Correction")
        Thread.sleep(forTimeInterval: 1.5)
        snap("g-correction-12", app)
        tap(app, "Speaker")
        Thread.sleep(forTimeInterval: 1.5)
        snap("g-correction-13", app)
        tap(app, "Air Pro 4")
        Thread.sleep(forTimeInterval: 1.5)
        for _ in 0..<2 where app.navigationBars.buttons.firstMatch.exists && !app.staticTexts["Save current chain"].exists {
            app.navigationBars.buttons.firstMatch.tap(); Thread.sleep(forTimeInterval: 1.2)
        }

        // 共有（補正がかかっているので、鎖だけか補正込みかを選ぶ形になる）
        bringUp(app, "Share this chain", to: 0.5)
        tap(app, "Share this chain")
        Thread.sleep(forTimeInterval: 1.5)
        snap("g-share-4", app)
        app.swipeDown(velocity: .fast)
        if app.buttons["Done"].exists { app.buttons["Done"].firstMatch.tap() }
        Thread.sleep(forTimeInterval: 1.5)

        // 演奏中の鎖は Vinyl に替えて、補正は鎖の下に残っている姿
        app.terminate()
        let app2 = XCUIApplication()
        app2.launchArguments = ["-ETWidth", "0", "-ETMock", "1", "-ETMockMode", "music", "-ETSeed", "vinyl", "-ETCollapsed", "1"]
        app2.launch()
        Thread.sleep(forTimeInterval: 7)
        bringUp(app2, "Output Correction", to: 0.6)
        snap("g-correction-14", app2)
    }

    // MARK: - effects

    func test_effects_1() {
        let app = launch(["-ETSeed", "vinyl", "-ETCollapsed", "1", "-ETSheet", "picker"])
        pane(app, "Presets")
        snap("g-effects-1", app)
    }

    func test_effects_2() {
        let app = launch(["-ETSeed", "vinyl", "-ETCollapsed", "1", "-ETSheet", "presets"])
        bringUp(app, "System Presets", to: 0.2)
        tap(app, "Lo-Fi")
        snap("g-effects-2", app)
    }

    func test_effects_3_4_5() {
        for (seed, name) in [("vinyl", "g-effects-3"), ("tube", "g-effects-4"), ("fmradio", "g-effects-5")] {
            let app = launch(["-ETSeed", seed, "-ETCollapsed", "1"], wait: 9)
            snap(name, app)
            app.terminate()
        }
    }

    func test_effects_cards() {
        for (seed, name) in [("store", "g-effects-6"), ("compressor", "g-effects-7"), ("RSReverbPlugin", "g-effects-8"),
                             ("StereoBlendPlugin", "g-effects-9"), ("peq-spectrum", "g-effects-10")] {
            let app = launch(["-ETSeed", seed], wait: 9)
            snap(name, app)
            app.terminate()
        }
    }

    func test_effects_11_12() {
        let app = launch(["-ETSeed", "SaturationPlugin,LevelMeterPlugin", "-ETCollapsed", "1"], wait: 9)
        // Saturation の電源を切る → 入れる
        cardPower(app, "Saturation")
        Thread.sleep(forTimeInterval: 2)
        snap("g-effects-11", app)
        cardPower(app, "Saturation")
        Thread.sleep(forTimeInterval: 2)
        snap("g-effects-12", app)
    }

    func test_effects_13() {
        let app = launch(["-ETSeed", "vinyl", "-ETCollapsed", "1", "-ETSheet", "picker"])
        searchPicker(app, "EQ")
        snap("g-effects-13", app)
    }

    func test_effects_15() {
        let app = launch(["-ETSeed", "chain", "-ETCollapsed", "1"], wait: 8)
        cardPower(app, "Compressor")
        snap("g-effects-15", app)
    }

    func test_effects_16() {
        let app = launch(["-ETSeed", "FiveBandPEQPlugin,SaturationPlugin", "-ETCollapsed", "1"], wait: 8)
        snap("g-effects-16", app)
    }

    /// 名前の付いた Section。エフェクト一覧の Presets から System Presets を足すと Section に包んで挿す。
    func test_effects_17_18() {
        let app = pasteChain("W3sibm0iOiJWb2x1bWUiLCJlbiI6dHJ1ZX0seyJubSI6IlNlY3Rpb24iLCJjbSI6Ildhcm10aCIsImVuIjp0cnVlfSx7Im5tIjoiU2F0dXJhdGlvbiIsImVuIjp0cnVlfSx7Im5tIjoiVG9uZSBDb250cm9sIiwiZW4iOnRydWV9LHsibm0iOiJTZWN0aW9uIiwiY20iOiJTcGFjZSIsImVuIjp0cnVlfSx7Im5tIjoiUlMgUmV2ZXJiIiwiZW4iOnRydWV9LHsibm0iOiJMZXZlbCBNZXRlciIsImVuIjp0cnVlfV0", args: ["-ETSeed", "none", "-ETCollapsed", "1"])
        // 畳む（撮影の引数では畳めないので、各カードの頭を押す）
        snap("g-effects-17", app)
        let section = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH 'power' AND label CONTAINS 'Warmth'")).firstMatch
        if section.waitForExistence(timeout: 4) { section.tap() } else { print("SITESHOT-MISS section power") }
        Thread.sleep(forTimeInterval: 1.5)
        snap("g-effects-18", app)
    }

    // MARK: - brir

    func test_brir_5() {
        let app = launch(["-ETSeed", "vinyl", "-ETCollapsed", "1", "-ETSheet", "picker"])
        searchPicker(app, "Reverb")
        snap("g-brir-5", app)
    }

    func test_brir_6_to_10() {
        let app = pasteChain("W3sibm0iOiJJUiBSZXZlcmIiLCJlbiI6dHJ1ZSwiZGUiOmZhbHNlLCJkYyI6ZmFsc2V9LHsibm0iOiJMZXZlbCBNZXRlciIsImVuIjp0cnVlfV0", args: ["-ETSeed", "none"])
        tap(app, "IR Reverb", type: .staticText)  // 畳んで出るので開く（label が同じ電源のスイッチは押さない）
        tap(app, "Import file…")
        pickFile(app, "BRIR_R01_C1_True_Stereo", shot: "g-brir-6")
        scrollTop(app)
        snap("g-brir-7", app)
        bringUp(app, "Dry", to: 0.35, type: .switch)
        toggleOff(app, "Dry")
        toggleOff(app, "Direct Cut")
        Thread.sleep(forTimeInterval: 1)
        bringUp(app, "Wet Level", to: 0.15)
        snap("g-brir-8", app)
        bringUp(app, "Pre Delay", to: 0.25)
        snap("g-brir-9", app)
        bringUp(app, "Level Meter", to: 0.45)
        Thread.sleep(forTimeInterval: 3)
        snap("g-brir-10", app)
    }

    // MARK: - chatgpt

    func test_chatgpt_1() {
        let app = launch(["-ETSeed", "vinyl", "-ETCollapsed", "1", "-ETSheet", "picker"])
        snap("g-chatgpt-1", app)
    }

    func test_chatgpt_3_5_6() {
        let app = launch(["-ETSeed", "vinyl", "-ETCollapsed", "1", "-ETSheet", "picker"])
        pane(app, "Plugins")
        snap("g-chatgpt-3", app)
        tap(app, "Import JSFX")
        Thread.sleep(forTimeInterval: 1)
        snap("g-chatgpt-5", app)
        tap(app, "From Files", type: .button)
        pickFile(app, "Stereo Width")
        Thread.sleep(forTimeInterval: 2)
        // 取り込んだ JSFX は Plugins に出る。押して鎖へ
        tap(app, "Stereo Width", below: 300)
        Thread.sleep(forTimeInterval: 2)
        bringUp(app, "Stereo Width", to: 0.25)
        snap("g-chatgpt-6", app)
    }

    // MARK: - share

    func test_share_1_2_3_5() {
        let app = launch(["-ETSeed", "vinyl", "-ETCollapsed", "1"])
        tap(app, "Presets", type: .button)
        typeName(app, "Late Night Vinyl")
        snap("g-share-1", app)
        tap(app, "Save", type: .button, below: 150)
        Thread.sleep(forTimeInterval: 1.5)
        dismissKeyboard(app)
        snap("g-share-2", app)
        bringUp(app, "Share this chain", to: 0.5)
        snap("g-share-3", app)
        tap(app, "Share this chain")
        Thread.sleep(forTimeInterval: 3)
        snap("g-share-5", app)
    }

    /// コピーした鎖を EffectDeck が見つけて出す帯。
    func test_share_8() {
        UIPasteboard.general.string = "https://effectdeck.nemut.ai/?p=W3sibm0iOiJWb2x1bWUiLCJlbiI6dHJ1ZSwidmwiOjB9LHsibm0iOiJTYXR1cmF0aW9uIiwiZW4iOnRydWV9LHsibm0iOiJSUyBSZXZlcmIiLCJlbiI6dHJ1ZX1d"
        let app = launch(["-ETSeed", "vinyl", "-ETCollapsed", "1"], wait: 5)
        allowPaste()
        Thread.sleep(forTimeInterval: 2)
        snap("g-share-8", app)
    }

    func test_share_7_safari() {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.launch()
        XCUIDevice.shared.system.open(URL(string: "https://effectdeck.nemut.ai/?p=W3sibm0iOiJWb2x1bWUiLCJlbiI6dHJ1ZSwidmwiOjB9LHsibm0iOiJTYXR1cmF0aW9uIiwiZW4iOnRydWV9LHsibm0iOiJSUyBSZXZlcmIiLCJlbiI6dHJ1ZX1d")!)
        Thread.sleep(forTimeInterval: 8)
        snap("g-share-7", safari)
        safari.terminate()
    }
}
