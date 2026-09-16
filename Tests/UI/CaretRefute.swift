//  CaretRefute.swift
//  「整数のパラメータだと打った数字が前へ入る」という所見の対照。
//  変数が isInteger なのか、押した場所（キャレット）なのかを切り分ける。
//  診断用なので Sources には何も足さない。

import XCTest

final class CaretRefute: XCTestCase {

    @discardableResult
    private func launch(_ args: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = args
        app.launch()
        XCTAssertTrue(app.navigationBars.buttons["Add Effect"].waitForExistence(timeout: 60),
                      "本画面が出ない")
        return app
    }

    /// 掴めるまで押す。押す場所を dx で指定する（XCUIElement.tap() は必ず中心）。
    private func focus(_ app: XCUIApplication, _ e: XCUIElement, dx: CGFloat, _ tag: String) -> Bool {
        for attempt in 0..<4 {
            e.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 1.8)
            if app.keyboards.count > 0 {
                print("PROBE[\(tag)] focused dx=\(dx) attempt=\(attempt)")
                return true
            }
            print("PROBE[\(tag)] キーボードが出ない dx=\(dx) attempt=\(attempt)")
        }
        return false
    }

    // MARK: - 対照 1. 同じ欄・同じ打鍵で、押す場所だけ変える

    /// 所見は「欄の左半分を押す」と書いてある。XCUIElement.tap() は中心を押す。
    /// 右半分を押して同じ 1 打をすれば、値がどう入るかで
    /// 「整数だから化ける」のか「押した場所の通りに入っている」のかが決まる。
    func test01BalanceRightHalfTap() {
        let app = launch(["-ETSeed", "MultibandBalancePlugin"])
        Thread.sleep(forTimeInterval: 3)

        func balance() -> XCUIElement {
            app.textFields.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Balance 1")).firstMatch
        }
        let b = balance()
        XCTAssertTrue(b.waitForExistence(timeout: 20), "Balance の欄が無い")
        print("PROBE frame balance=\(b.frame) value=\(String(describing: b.value))")

        // (A) 右端寄りを押す = 字の右。
        XCTAssertTrue(focus(app, b, dx: 0.90, "balance-right"), "掴めない")
        print("PROBE right 掴んだ直後 -> \(String(describing: balance().value))")
        app.typeText("7")
        Thread.sleep(forTimeInterval: 0.8)
        print("PROBE right 7 を打った直後（確定前の欄）-> \(String(describing: balance().value))")
        app.typeText("\n")
        Thread.sleep(forTimeInterval: 2.0)
        print("PROBE right 確定 -> \(String(describing: balance().value))")

        // (B) 左端寄りを押す = 字の左。いま欄には (A) の結果が入っている。
        let b2 = balance()
        XCTAssertTrue(focus(app, b2, dx: 0.10, "balance-left"), "掴めない（2 回目）")
        print("PROBE left 掴んだ直後 -> \(String(describing: balance().value))")
        app.typeText("1")
        Thread.sleep(forTimeInterval: 0.8)
        print("PROBE left 1 を打った直後（確定前の欄）-> \(String(describing: balance().value))")
        app.typeText("\n")
        Thread.sleep(forTimeInterval: 2.0)
        print("PROBE left 確定 -> \(String(describing: balance().value))")
    }

    // MARK: - 対照 2. 小数のパラメータで、綴りが変わらないもの

    /// Multiband Balance の Frequency4 は isInteger: false・既定 8000
    /// （EffectCatalog.swift:1582）。
    ///   displayValue: abs(v) >= 100 なので "%.0f" -> "8000"
    ///   trimmed:      v == v.rounded() なので String(Int(v)) -> "8000"
    /// 綴りが同じになる。所見の原因の当たりが正しければ、
    /// **小数のパラメータでも同じことが起きる**はず。
    /// 起きれば「整数のパラメータで起きる」は変数の取り違え。
    func test02NonIntegerSameSpelling() {
        let app = launch(["-ETSeed", "MultibandBalancePlugin"])
        Thread.sleep(forTimeInterval: 3)

        func f4() -> XCUIElement {
            app.textFields.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Frequency4")).firstMatch
        }
        let f = f4()
        XCTAssertTrue(f.waitForExistence(timeout: 20), "Frequency4 の欄が無い")
        print("PROBE frame f4=\(f.frame) value=\(String(describing: f.value))")

        // 所見と同じ当たり方（中心）。
        XCTAssertTrue(focus(app, f, dx: 0.5, "f4-center"), "掴めない")
        print("PROBE f4 掴んだ直後 -> \(String(describing: f4().value))")
        app.typeText("7")
        Thread.sleep(forTimeInterval: 0.8)
        print("PROBE f4 7 を打った直後（確定前の欄）-> \(String(describing: f4().value))")
        app.typeText("\n")
        Thread.sleep(forTimeInterval: 2.0)
        print("PROBE f4 確定 -> \(String(describing: f4().value))")

        // 比較。Volume は "0.00" -> "0" で綴りが変わる側。
        let v = XCUIApplication()
        v.launchArguments = ["-ETSeed", "VolumePlugin"]
        v.launch()
        XCTAssertTrue(v.navigationBars.buttons["Add Effect"].waitForExistence(timeout: 60),
                      "Volume の画面が出ない")
        Thread.sleep(forTimeInterval: 3)
        let vf = v.textFields["Volume (dB)"]
        XCTAssertTrue(vf.waitForExistence(timeout: 20), "Volume の欄が無い")
        print("PROBE frame volume=\(vf.frame) value=\(String(describing: vf.value))")
        XCTAssertTrue(focus(v, vf, dx: 0.10, "volume-left"), "掴めない")
        print("PROBE volume 左端を押して掴んだ直後 -> \(String(describing: v.textFields["Volume (dB)"].value))")
        v.typeText("7")
        Thread.sleep(forTimeInterval: 0.8)
        print("PROBE volume 7 を打った直後（確定前の欄）-> \(String(describing: v.textFields["Volume (dB)"].value))")
        v.typeText("\n")
        Thread.sleep(forTimeInterval: 2.0)
        print("PROBE volume 確定 -> \(String(describing: v.textFields["Volume (dB)"].value))")
    }
}
