//  AlertQueueTests.swift
//  警告を出す順番と、鎖を取り込んだ後に出すもの（Views/AlertQueue.swift）。**画面も実機も要らない。**
//
//  見張るのは2つ:
//    - 警告のボタンの中で頼んだ次の1枚が、閉じる側の書き戻しで消えないこと。
//      SwiftUIが書き戻しとボタンのどちらを先に呼んでも同じになること。
//      前の1枚の書き戻しが次の1枚を出した後に遅れて来ても同じになること
//    - 貼った鎖が1本も置けなかったとき、控えがあれば「読めない」ではなく控えを出すこと
//      （"Not found: JSFX tape wobble."）
//  鎖の読み取りは本物（ETShareLink.parseChecked）を通す。ETShareLinkとETChainTextは
//  このバンドルへ直接入れてある（project.yml）。

import XCTest

final class AlertQueueTests: XCTestCase {

    private enum Box: Equatable { case confirm, report(String) }

    // MARK: - 順番

    /// 何も出ていないときに頼んだものも、その場では出さない。次の回に出す。
    func testPresentWaitsForAdvance() {
        var q = ETAlertQueue<Box>()
        q.present(.confirm)
        XCTAssertNil(q.current)
        XCTAssertTrue(q.canAdvance)
        q.advance()
        XCTAssertEqual(q.current, .confirm)
        XCTAssertFalse(q.canAdvance)
    }

    /// ボタンが先、書き戻しが後。書き戻しが次の1枚を消さない（前はこれで控えが消えていた）。
    func testNextSurvivesDismissalThatComesAfterTheButton() {
        var q = shown(.confirm)
        let confirm = q.ticket                  // .alertを組んだときの番号
        q.present(.report("Not found: Tape Warmth."))
        // まだ閉じていない。出ている1枚を押しのけない。
        XCTAssertFalse(q.canAdvance)
        q.advance()
        XCTAssertEqual(q.current, .confirm)
        q.closed(confirm)
        XCTAssertNil(q.current)
        XCTAssertTrue(q.canAdvance)
        q.advance()
        XCTAssertEqual(q.current, .report("Not found: Tape Warmth."))
    }

    /// 書き戻しが先、ボタンが後。こちらでも同じに出る。
    func testNextSurvivesDismissalThatComesBeforeTheButton() {
        var q = shown(.confirm)
        q.closed(q.ticket)
        XCTAssertFalse(q.canAdvance)
        q.present(.report("That does not look like a link."))
        XCTAssertTrue(q.canAdvance)
        q.advance()
        XCTAssertEqual(q.current, .report("That does not look like a link."))
    }

    /// 書き戻しが2度来ても（ボタンの中のnilと.alertの書き戻し）、待っているものは残る。
    func testRepeatedDismissalKeepsTheWaitingItem() {
        var q = shown(.confirm)
        let confirm = q.ticket
        q.dismissed()
        q.present(.report("x"))
        q.closed(confirm)
        q.closed(confirm)
        q.advance()
        XCTAssertEqual(q.current, .report("x"))
    }

    /// **前の1枚の書き戻しが、次の1枚を出した後に遅れて来ても消さない。**
    /// 閉じ終わりでもう1度書かれると、番号を見ていなかったときは次の1枚が消えていた。
    func testLateDismissalOfThePreviousItemKeepsTheNext() {
        var q = shown(.confirm)
        let confirm = q.ticket
        q.present(.report("Not found: JSFX tape wobble."))
        q.closed(confirm)
        q.advance()
        XCTAssertEqual(q.current, .report("Not found: JSFX tape wobble."))
        q.closed(confirm)
        XCTAssertEqual(q.current, .report("Not found: JSFX tape wobble."), "遅れた書き戻しが次の1枚を消した")
        // 次の1枚そのものの書き戻しは効く。
        q.closed(q.ticket)
        XCTAssertNil(q.current)
    }

    /// ボタンの中で自分から閉じた（From LinkのImport）後の書き戻しも同じ。
    func testLateDismissalAfterExplicitCloseKeepsTheNext() {
        var q = shown(.confirm)
        let confirm = q.ticket
        q.dismissed()
        q.present(.report("That does not look like a link."))
        q.advance()
        q.closed(confirm)
        XCTAssertEqual(q.current, .report("That does not look like a link."))
    }

    /// 何も出ていないときに組んだ.alertの書き戻し（番号なし）は何も下ろさない。
    func testDismissalWithoutTicketIsIgnored() {
        var q = shown(.confirm)
        q.closed(nil)
        XCTAssertEqual(q.current, .confirm)
    }

    /// 番号は出すたびに変わる。同じものを2度出しても前の番号では閉じない。
    func testTicketChangesEveryTime() {
        var q = shown(.confirm)
        let first = q.ticket
        q.closed(first)
        q.present(.confirm)
        q.advance()
        XCTAssertNotNil(q.ticket)
        XCTAssertNotEqual(q.ticket, first)
        q.closed(first)
        XCTAssertEqual(q.current, .confirm)
    }

    /// 待っているものは1つだけ。後から頼んだものが勝つ。
    func testLaterRequestWins() {
        var q = ETAlertQueue<Box>()
        q.present(.report("a"))
        q.present(.report("b"))
        q.advance()
        XCTAssertEqual(q.current, .report("b"))
        q.closed(q.ticket)
        XCTAssertFalse(q.canAdvance)
    }

    /// 何も待っていなければ、閉じた後に何も出ない。
    func testNothingWaitingNothingShown() {
        var q = shown(.confirm)
        q.closed(q.ticket)
        XCTAssertNil(q.ticket)
        XCTAssertFalse(q.canAdvance)
        q.advance()
        XCTAssertNil(q.current)
    }

    private func shown(_ item: Box) -> ETAlertQueue<Box> {
        var q = ETAlertQueue<Box>()
        q.present(item)
        q.advance()
        return q
    }

    // MARK: - 鎖を取り込んだ後

    private let unreadable = "Nothing readable on the clipboard."

    private func result(_ text: String, jsfx: [(id: String, name: String)] = []) -> ETChainImportResult {
        let checked = ETShareLink.parseChecked(text, catalog: ETCatalog,
                                               jsfx: ETChainText.jsfxResolver(jsfx))
        return .of(loaded: checked.items.count, report: checked.report, unreadable: unreadable)
    }

    /// 直したものが無ければ黙って閉じる。
    func testCleanChainClosesQuietly() {
        XCTAssertEqual(result(#"[{"nm":"Volume","vl":-3}]"#), .done)
    }

    /// 直したもの・落としたものがあれば、入れ替えた上で1行出す。
    func testFixedChainIsReported() {
        XCTAssertEqual(result(#"[{"nm":"Volume","vl":99},{"nm":"Tape Warmth"}]"#),
                       .imported("Not found: Tape Warmth. Limited: Volume.vl."))
    }

    /// 取り込んでいないJSFXだけの鎖は、「読めない」ではなく置けなかった段を名指しする。
    func testOnlyMissingJSFXNamesIt() {
        XCTAssertEqual(result(#"[{"jsfx":"tape wobble"}]"#),
                       .failed("Not found: JSFX tape wobble."))
    }

    /// 取り込んであれば置ける（控えは空）。
    func testImportedJSFXResolves() {
        XCTAssertEqual(result(#"[{"jsfx":"tape wobble"}]"#,
                              jsfx: [(id: "jsfx:abc", name: "Tape Wobble")]),
                       .done)
    }

    /// 段が全部知らない名前でも同じ。
    func testOnlyUnknownEffectsNamesThem() {
        XCTAssertEqual(result(#"[{"nm":"Tape Warmth"},{"nm":"Spring Box"}]"#),
                       .failed("Not found: Tape Warmth, Spring Box."))
    }

    /// 字から鎖が見つからなければ、控えは空なので「読めない」。
    func testNoChainAtAllIsUnreadable() {
        XCTAssertEqual(result("hello"), .failed(unreadable))
        XCTAssertEqual(result(""), .failed(unreadable))
    }
}
