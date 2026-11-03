//  SimChecklistFlingProbe.swift
//  確認リストの「払って流れている最中に節を選んでも飛ぶ」を叩く。
//
//  SimChecklistProbe の swipe は 500 px/s で引いて離すだけなので、慣性がほとんど付かない。
//  ここは速く払い、離した直後に Sections を開いて節を選ぶ。
//  判定はここで決め切らない。撮った絵（とホストの連写）で決める（SimChecklistProbe と同じ）。
//
//  前提: テストキットの source_view_600KB.jsfx を取り込んであり、Plugins に
//  「Source View 600 KB」が居る。端末は iPad Pro 13-inch (M5)。

import XCTest

final class SimChecklistFlingProbe: XCTestCase {

    private var shotDir: String {
        ProcessInfo.processInfo.environment["SIMCHECK_SHOTS"]
            ?? "/Users/satoumasahiro/work/b0shots"
    }

    private func snap(_ name: String) {
        let img = XCUIScreen.main.screenshot()
        let url = URL(fileURLWithPath: shotDir).appendingPathComponent("ui-\(name).png")
        try? img.pngRepresentation.write(to: url)
        print("SIMCHECK-SNAP \(url.path)")
    }

    /// 選ぶ節は SIMCHECK_SECTIONS（, 区切り）。既定は @gfx と @serialize。
    func testFlingThenJumpToSection() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ETSheet", "picker"]
        app.launch()

        let plugins = app.buttons["Plugins"]
        XCTAssertTrue(plugins.waitForExistence(timeout: 15))
        plugins.tap()
        let kit = app.buttons["EffectDeck test kit"]
        if kit.waitForExistence(timeout: 5) { kit.tap() }

        // 行の … は行と同じ高さに居る More。
        let row = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Source View 600 KB")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let more = app.buttons.matching(NSPredicate(format: "label == %@", "More"))
            .allElementsBoundByIndex.filter { $0.isHittable }
            .min { abs($0.frame.midY - row.frame.midY) < abs($1.frame.midY - row.frame.midY) }
        try XCTUnwrap(more).tap()
        app.buttons["View Source"].tap()

        let sections = app.buttons["Sections"]
        XCTAssertTrue(sections.waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 1)
        snap("fling-0-open")

        let names = (ProcessInfo.processInfo.environment["SIMCHECK_SECTIONS"] ?? "@gfx,@serialize")
            .split(separator: ",").map(String.init)
        for (k, name) in names.enumerated() {
            // シートの中ほどを速く上へ払い、指を止めずに離す。
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.66))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.32))
            print("SIMCHECK-FLING \(name)")
            start.press(forDuration: 0.02, thenDragTo: end,
                        withVelocity: XCUIGestureVelocity(rawValue: 8000), thenHoldForDuration: 0)
            snap("fling-\(k + 1)a-released")
            sections.tap()
            app.buttons[name].tap()
            snap("fling-\(k + 1)b-picked")
            Thread.sleep(forTimeInterval: 2.5)
            snap("fling-\(k + 1)c-\(name.dropFirst())")
        }
    }
}
