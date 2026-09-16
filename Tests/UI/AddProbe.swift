//  AddProbe.swift
//  **無音の間に足したエフェクトが効かない**を機械で捕まえる。
//
//  欠陥そのもの: et_pipeline_configure を呼ぶのは ETPipeline_Process の中だけで、
//  その Process は AudioIO のレンダーブロックが `if awake` の内側でしか呼ばない。
//  PowerGate が無音で休んでいる間は Process ごと飛ぶので、ETPipeline_Publish が
//  置いた descriptor は gPending に積まれたまま消費されない。
//
//  **1 回通ったことを直った証拠にしない。**
//  この症状は「音が来ているかどうか」で分岐するので、鳴らしながら試すと
//  たまたま直って見える。だから**無音を作ってから**足す。
//  直っていなければ active が上がらないので、必ず落ちる。
//
//  読むのは LiveStatusStrip の diag（-ETDiag 1 のときだけ読み上げの木に出る）:
//      active=N chain=N cfg=S
//  active は configure が反映した有効ノード数、chain は UI が持っている段の数。
//  **ずれていたら descriptor が拾われていない。**

import XCTest

final class AddProbe: XCTestCase {

    /// diag の行から数字を 1 つ取り出す。
    private func value(_ app: XCUIApplication, _ key: String) -> Int? {
        let label = app.staticTexts["diag"].label
        guard let r = label.range(of: "\(key)=") else { return nil }
        let rest = label[r.upperBound...].prefix { $0.isNumber || $0 == "-" }
        return Int(rest)
    }

    /// **無音のまま足して、効いているか。**
    ///
    /// -ETMock を付けない＝作り物の音も流さないので PowerGate は休んだままになる。
    /// その状態で 1 本足し、active が chain に追いつくのを待つ。
    func testAddWhileSilentTakesEffect() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ETSeed", "none", "-ETDiag", "1"]
        app.launch()

        let diag = app.staticTexts["diag"]
        XCTAssertTrue(diag.waitForExistence(timeout: 30),
                      "diag が出ない（-ETDiag の配線か、io.running が false）")

        let before = value(app, "active") ?? -1
        let beforeChain = value(app, "chain") ?? -1
        print("PROBE ADD before active=\(before) chain=\(beforeChain) label=\(diag.label)")

        // **ツールバーの方を名指しする。** 同じラベルのボタンが 2 つある
        // （PipelineView.swift:429 のツールバーと :553 の空状態の行）。
        // `-ETSeed none` だと空状態の行が必ず出るので毎回衝突して tap できない。
        let add = app.navigationBars.buttons["Add Effect"]
        XCTAssertTrue(add.waitForExistence(timeout: 20), "Add Effect が出ない")
        add.tap()

        let search = app.searchFields.firstMatch
        if search.waitForExistence(timeout: 10) {
            search.tap()
            search.typeText("Volume")
        }
        // **前方一致で引く。** ピッカーの行は Button の中に Text が 3 枚
        // （名前・カテゴリ・説明）入っていて、ラベルが合成される:
        //   "Volume, Basics, Adjusts the volume of the audio signal"
        // 完全一致では引けない（実測）。
        let pick = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH[c] %@", "Volume")).firstMatch
        XCTAssertTrue(pick.waitForExistence(timeout: 10), "ピッカーに Volume が出ない")
        pick.tap()

        // configure は次のオーディオブロックで走る。数ブロックぶん待てば足りるが、
        // 画面の更新も挟むので余裕を見る。
        var active = -1
        var chain = -1
        for _ in 0..<40 {
            Thread.sleep(forTimeInterval: 0.5)
            active = value(app, "active") ?? -1
            chain = value(app, "chain") ?? -1
            if active >= chain && chain > beforeChain { break }
        }
        print("PROBE ADD after active=\(active) chain=\(chain) label=\(diag.label)")

        XCTAssertGreaterThan(chain, beforeChain, "そもそも足せていない")
        XCTAssertEqual(active, chain,
                       "無音の間に足した段が configure に反映されていない"
                       + "（active=\(active) chain=\(chain)）。"
                       + "ETPipeline_ApplyPending がゲートの外で呼ばれているか見ること")
    }

    /// 対照。音が流れていれば古いコードでも通るので、こちらが通って
    /// 上が落ちるなら「無音のときだけ壊れる」が確定する。
    func testAddWhileAudioFlowsTakesEffect() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ETSeed", "none", "-ETMock", "1", "-ETDiag", "1"]
        app.launch()

        let diag = app.staticTexts["diag"]
        XCTAssertTrue(diag.waitForExistence(timeout: 30), "diag が出ない")
        let beforeChain = value(app, "chain") ?? -1

        // **ツールバーの方を名指しする。** 同じラベルのボタンが 2 つある
        // （PipelineView.swift:429 のツールバーと :553 の空状態の行）。
        // `-ETSeed none` だと空状態の行が必ず出るので毎回衝突して tap できない。
        let add = app.navigationBars.buttons["Add Effect"]
        XCTAssertTrue(add.waitForExistence(timeout: 20), "Add Effect が出ない")
        add.tap()
        let search = app.searchFields.firstMatch
        if search.waitForExistence(timeout: 10) {
            search.tap()
            search.typeText("Volume")
        }
        // **前方一致で引く。** ピッカーの行は Button の中に Text が 3 枚
        // （名前・カテゴリ・説明）入っていて、ラベルが合成される:
        //   "Volume, Basics, Adjusts the volume of the audio signal"
        // 完全一致では引けない（実測）。
        let pick = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH[c] %@", "Volume")).firstMatch
        XCTAssertTrue(pick.waitForExistence(timeout: 10), "ピッカーに Volume が出ない")
        pick.tap()

        var active = -1
        var chain = -1
        for _ in 0..<40 {
            Thread.sleep(forTimeInterval: 0.5)
            active = value(app, "active") ?? -1
            chain = value(app, "chain") ?? -1
            if active >= chain && chain > beforeChain { break }
        }
        print("PROBE ADD(mock) after active=\(active) chain=\(chain)")
        XCTAssertEqual(active, chain, "音が流れていても反映されない（別の欠陥）")
    }
}
