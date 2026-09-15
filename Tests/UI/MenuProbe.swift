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

        let item = app.buttons["IR Library"]
        print("PROBE item exists=\(item.exists) enabled=\(item.isEnabled) hittable=\(item.isHittable) frame=\(item.frame)")
        item.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 3)
        print("PROBE sheet opened=\(app.navigationBars["IR Library"].exists)")
    }
}
