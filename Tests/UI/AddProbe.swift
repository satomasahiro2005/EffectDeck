//  AddProbe.swift
//  **足した直後に効かない**を機械で捕まえる。
//
//  症状: エフェクトを足しても音が変わらず、段のスイッチを切って入れ直すと効く。
//  足すのも入切も publish() を呼ぶだけなので、**1 回目の publish が
//  音のスレッドに拾われていない**という筋を疑っている。ここはその確認。
//
//  見るのは画面ではなくログ。EffeTuneDSP.publish() が
//      publish nodes=N chain=N sections=N dead=N active=N gated=N types=…
//  を出し、AudioIO.tick() が 6 秒ごとに
//      tick out=… applied=N active=N chain=N …
//  を出す。`applied` は ETPipeline_ActiveNodes()＝configure が通ったときの
//  有効ノード数なので、**publish の active と tick の applied がずれていれば
//  descriptor が拾われていない。**
//
//  走らせ方（ログは別に取る）:
//      xcodebuild test -scheme EffeTuneLive -only-testing:EffeTuneLiveUITests/AddProbe
//      xcrun simctl spawn booted log show --last 2m \
//        --predicate 'subsystem == "ai.nemut.effetune"' | grep -E "publish |tick "

import XCTest

final class AddProbe: XCTestCase {

    /// 足して、しばらく待って、切って入れて、また待つ。
    /// ログ側で applied の推移を読む。
    func testAddThenToggle() {
        let app = XCUIApplication()
        // 作り物の音を流す。無音だと PowerGate が休んで
        // ETPipeline_Process ごと呼ばれず、descriptor が拾われない。
        // それ自体が原因の候補なので、まず音がある状態で測る。
        app.launchArguments = ["-ETSeed", "none", "-ETMock", "1"]
        app.launch()

        let add = app.buttons["Add Effect"]
        XCTAssertTrue(add.waitForExistence(timeout: 30), "Add Effect が出ない")

        print("PROBE ADD phase=before")
        add.tap()

        // ピッカーから 1 本選ぶ。名前で引く（検索欄に打つと候補が絞れる）。
        let search = app.searchFields.firstMatch
        if search.waitForExistence(timeout: 10) {
            search.tap()
            search.typeText("Volume")
        }
        let pick = app.buttons["Volume"].firstMatch
        XCTAssertTrue(pick.waitForExistence(timeout: 10), "ピッカーに Volume が出ない")
        pick.tap()

        // tick は 6 秒ごとなので 2 本ぶん待つ。
        print("PROBE ADD phase=added")
        Thread.sleep(forTimeInterval: 14)

        // 段のスイッチを切って入れる。これで直るなら 1 回目の publish が拾われていない。
        let sw = app.switches.firstMatch
        if sw.waitForExistence(timeout: 10) {
            print("PROBE ADD phase=toggling")
            sw.tap()
            Thread.sleep(forTimeInterval: 2)
            sw.tap()
        } else {
            print("PROBE ADD phase=no-switch")
        }

        print("PROBE ADD phase=toggled")
        Thread.sleep(forTimeInterval: 14)
        print("PROBE ADD phase=end")
    }
}
