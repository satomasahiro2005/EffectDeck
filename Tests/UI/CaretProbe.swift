//  CaretProbe.swift
//  数値欄に打った字が「どこへ」入るかを、**押す位置だけを変えて**測る。
//
//  欄の読み上げ値は確定値（ParameterRow.swift の .accessibilityValue(displayValue)）
//  なので、打っている途中は見えない。Return で確定させた後の値だけで判定する。
//
//  ここで見たいこと:
//    - 同じ欄・同じ打鍵で、押した位置を変えると結果が変わるか
//      （変わるなら「キャレットは押した所に立つ」＝ふつうの文字欄の動き）
//    - 整数でない欄でも同じことが起きるか
//      （Frequency4 は isInteger:false・既定 8000 なので字は "8000"）

import XCTest

final class CaretProbe: XCTestCase {

    private func launch(_ args: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = args
        app.launch()
        XCTAssertTrue(app.navigationBars.buttons["Add Effect"].waitForExistence(timeout: 60),
                      "本画面が出ない")
        return app
    }

    private func field(_ app: XCUIApplication, _ prefix: String) -> XCUIElement {
        app.textFields.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    private func value(_ app: XCUIApplication, _ prefix: String) -> String {
        let e = field(app, prefix)
        return e.exists ? ((e.value as? String) ?? "nil") : "(欄が無い)"
    }

    private func allFields(_ app: XCUIApplication) -> [String] {
        app.textFields.allElementsBoundByIndex.map { "\($0.label)=\(String(describing: $0.value))" }
    }

    /// 欄の横幅のうち割合 dx の所を押して掴む。掴めなければ同じ所をもう一度押す。
    @discardableResult
    private func grab(_ app: XCUIApplication, _ prefix: String, dx: CGFloat, _ tag: String) -> Bool {
        for attempt in 0..<4 {
            let e = field(app, prefix)
            guard e.waitForExistence(timeout: 10) else {
                print("PROBE[\(tag)] 欄が無い attempt=\(attempt)")
                return false
            }
            let f = e.frame
            e.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 1.8)
            if app.keyboards.count > 0 {
                print("PROBE[\(tag)] 掴んだ dx=\(dx) attempt=\(attempt) frame=\(f) "
                      + "押した x=\(f.minX + f.width * dx)")
                return true
            }
            print("PROBE[\(tag)] キーボードが出ない attempt=\(attempt)")
        }
        return false
    }

    private func submit(_ app: XCUIApplication) {
        app.typeText("\n")
        Thread.sleep(forTimeInterval: 2.0)
    }

    private func chip(_ app: XCUIApplication, _ i: Int) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", "Balance \(i)")).firstMatch
    }

    /// 押す位置を右端・真ん中・左端と変えて、同じ 1 打を入れる。
    func test30WhereTheDigitLands() {
        print("PROBE CARET BEGIN")
        let app = launch(["-ETSeed", "MultibandBalancePlugin"])
        Thread.sleep(forTimeInterval: 3)
        print("PROBE fields at start = \(allFields(app))")

        // ---- (1) 整数の欄（Balance 1・既定 0）の **右端** を押して "7" ----
        guard grab(app, "Balance 1", dx: 0.92, "b1-right") else { print("PROBE ABORT b1"); return }
        app.typeText("7")
        Thread.sleep(forTimeInterval: 0.6)
        submit(app)
        print("PROBE (1) Balance1 整数 右端を押して 7 -> \(value(app, "Balance 1"))")

        // ---- (2) 同じ形の欄の **真ん中**（XCUITest の既定の当たり方）----
        chip(app, 2).tap()
        Thread.sleep(forTimeInterval: 1.5)
        guard grab(app, "Balance 2", dx: 0.5, "b2-center") else { print("PROBE ABORT b2"); return }
        app.typeText("7")
        Thread.sleep(forTimeInterval: 0.6)
        submit(app)
        print("PROBE (2) Balance2 整数 真ん中を押して 7 -> \(value(app, "Balance 2"))")

        // ---- (3) 同じ形の欄の **左端** ----
        chip(app, 3).tap()
        Thread.sleep(forTimeInterval: 1.5)
        guard grab(app, "Balance 3", dx: 0.06, "b3-left") else { print("PROBE ABORT b3"); return }
        app.typeText("7")
        Thread.sleep(forTimeInterval: 0.6)
        submit(app)
        print("PROBE (3) Balance3 整数 左端を押して 7 -> \(value(app, "Balance 3"))")

        // ---- (4) **整数でない** 欄（Frequency4・isInteger:false・既定 8000）の真ん中 ----
        // delete を 10 回してから 1500。キャレットが末尾なら全部消えて 1500、
        // 途中に立っていたら左の字しか消えず "150000" になって 20000 へ丸まる。
        print("PROBE f4 before = \(value(app, "Frequency4"))")
        guard grab(app, "Frequency4", dx: 0.5, "f4-center") else { print("PROBE ABORT f4c"); return }
        for _ in 0..<10 { app.typeText(XCUIKeyboardKey.delete.rawValue) }
        app.typeText("1500")
        Thread.sleep(forTimeInterval: 0.6)
        submit(app)
        print("PROBE (4) Frequency4 小数 真ん中 delete10+1500 -> \(value(app, "Frequency4"))")

        // ---- (5) 同じ欄の右端で同じこと ----
        guard grab(app, "Frequency4", dx: 0.92, "f4-right") else { print("PROBE ABORT f4r"); return }
        for _ in 0..<10 { app.typeText(XCUIKeyboardKey.delete.rawValue) }
        app.typeText("1500")
        Thread.sleep(forTimeInterval: 0.6)
        submit(app)
        print("PROBE (5) Frequency4 小数 右端 delete10+1500 -> \(value(app, "Frequency4"))")

        // ---- (6)(7) 字 1 つぶんの中で、左右 2pt ずらして押す ----
        // 68pt の欄に "0" が 1 字（13pt の等幅 = 7.8pt）。真ん中に置かれるので
        // 字の中心は欄の中心と重なる。dx=0.47 は字の左半分、0.53 は右半分。
        chip(app, 4).tap()
        Thread.sleep(forTimeInterval: 1.5)
        guard grab(app, "Balance 4", dx: 0.47, "b4-glyph-left") else { print("PROBE ABORT b4"); return }
        app.typeText("7")
        Thread.sleep(forTimeInterval: 0.6)
        submit(app)
        print("PROBE (6) Balance4 字の左半分(dx=0.47) 7 -> \(value(app, "Balance 4"))")

        chip(app, 5).tap()
        Thread.sleep(forTimeInterval: 1.5)
        guard grab(app, "Balance 5", dx: 0.53, "b5-glyph-right") else { print("PROBE ABORT b5"); return }
        app.typeText("7")
        Thread.sleep(forTimeInterval: 0.6)
        submit(app)
        print("PROBE (7) Balance5 字の右半分(dx=0.53) 7 -> \(value(app, "Balance 5"))")

        // ---- 後始末: 5 つの札を順に見て、どこに何が入ったか ----
        for i in 1...5 {
            chip(app, i).tap()
            Thread.sleep(forTimeInterval: 1.2)
            print("PROBE final Balance\(i) = \(value(app, "Balance \(i)"))")
        }
        print("PROBE fields at end = \(allFields(app))")
        print("PROBE CARET END")
    }
}
