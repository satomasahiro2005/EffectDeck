//  MenuProbe.swift
//  画面の当たり判定を機械で確かめる。目で見て判断しないための道具。

import XCTest

final class MenuProbe: XCTestCase {

    /// Analyzer の「図だけ」が本当にパラメータを畳むか。
    func testGraphOnlyHidesParameters() {
        let app = XCUIApplication()
        app.launchArguments = ["-ETSeed", "spectrum"]
        app.launch()
        Thread.sleep(forTimeInterval: 6)

        let before = app.sliders.count + app.textFields.count
        let toggle = app.buttons["Graph only"]
        print("PROBE before sliders+fields=\(before) toggleExists=\(toggle.exists)")
        XCTAssertTrue(toggle.waitForExistence(timeout: 15), "Graph only のボタンが無い")

        toggle.tap()
        Thread.sleep(forTimeInterval: 2)
        let after = app.sliders.count + app.textFields.count
        print("PROBE after sliders+fields=\(after) backToggle=\(app.buttons["Show controls"].exists)")

        XCTAssertLessThan(after, before, "図だけにしてもパラメータが残っている")
    }

    /// ツールバーの Menu。ToolbarItemGroup の中だと死ぬのかを見る。
    func testToolbarMenuActuallyWorks() {
        let app = XCUIApplication()
        app.launchArguments = ["-ETSeed", "none"]
        app.launch()

        let menu = app.buttons["moreMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 20), "moreMenu が出ない")
        menu.tap()
        Thread.sleep(forTimeInterval: 2)

        // IR Library は ⋯ から外れた（IR Reverb のカードから開く）。
        // 無い項目を押していたので、固まるかどうかを判定できていなかった。
        let item = app.buttons["Settings"]
        print("PROBE item exists=\(item.exists) enabled=\(item.isEnabled) hittable=\(item.isHittable) frame=\(item.frame)")

        // **項目が出ること自体を判定する。**
        // Menu が固まるときは UIDeferredMenuElement が「読み込み中」のまま留まり、
        // 中身が 1 つも生えない。ここを見ないと、固まっていても通ってしまう。
        XCTAssertTrue(item.waitForExistence(timeout: 10),
                      "⋯ を開いても中身が出ない（Menu が固まっている）")

        item.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        // **開いたことを判定する。**
        // 以前はここが print だけで、押しても何も起きない状態を素通りさせていた。
        // このテストは「Menu が効くか」を見るために在るので、判定が無いと用をなさない。
        let sheet = app.navigationBars["Settings"]
        let opened = sheet.waitForExistence(timeout: 10)
        print("PROBE sheet opened=\(opened)")
        XCTAssertTrue(opened, "Settings を押しても開かない")
    }
}
