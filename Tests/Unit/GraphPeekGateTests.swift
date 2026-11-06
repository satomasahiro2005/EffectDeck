//  GraphPeekGateTests.swift
//  graph peek の出し入れの判断（Views/GraphPeekGate.swift）。
//  **時計は引数で進める。** 実機も UIKit も要らない（Linux の swift test でも走る）。
import XCTest

final class GraphPeekGateTests: XCTestCase {

    /// 開いてから 0.6 秒の静かな間を過ぎた所から始める（appeared は時刻 0）。
    private func settled(_ type: String = "FiveBandPEQPlugin") -> ETGraphPeekGate {
        var g = ETGraphPeekGate(typeName: type)
        g.appeared(now: 0)
        return g
    }

    private let t0: TimeInterval = 10

    private func down(_ g: inout ETGraphPeekGate, at now: TimeInterval, inGraph: Bool = false, touches: Int = 1) {
        g.touchDown(point: CGPoint(x: 50, y: 300), inGraph: inGraph, touches: touches, now: now)
    }

    // MARK: - 保持

    func testScrollOnlyTouchNeverShows() {
        var g = settled()
        down(&g, at: t0)
        XCTAssertFalse(g.wantsPeek)
        g.touchUp(now: t0 + 0.5)
        g.tick(now: t0 + 2)
        XCTAssertFalse(g.wantsPeek)
        XCTAssertNil(g.deadline)
    }

    func testChangeDuringHoldShowsAndStaysWhileHeld() {
        var g = settled()
        down(&g, at: t0)
        g.valuesChanged(now: t0 + 0.1)
        XCTAssertTrue(g.wantsPeek)
        XCTAssertNil(g.deadline, "指が下りている間は期限を持たない")
        g.tick(now: t0 + 30)
        XCTAssertTrue(g.wantsPeek)
    }

    func testLingersFor08SecondsAfterLiftThenHides() {
        var g = settled()
        down(&g, at: t0)
        g.valuesChanged(now: t0 + 0.1)
        g.touchUp(now: t0 + 1)
        XCTAssertTrue(g.wantsPeek)
        XCTAssertEqual(g.deadline ?? -1, t0 + 1.8, accuracy: 1e-9)
        g.tick(now: t0 + 1.79)
        XCTAssertTrue(g.wantsPeek)
        g.tick(now: t0 + 1.8)
        XCTAssertFalse(g.wantsPeek)
        XCTAssertNil(g.deadline)
    }

    func testChangeDuringLingerRearms() {
        var g = settled()
        down(&g, at: t0)
        g.valuesChanged(now: t0 + 0.1)
        g.touchUp(now: t0 + 1)
        g.valuesChanged(now: t0 + 1.5)
        XCTAssertEqual(g.deadline ?? -1, t0 + 2.3, accuracy: 1e-9)
        g.tick(now: t0 + 1.9)
        XCTAssertTrue(g.wantsPeek)
        g.tick(now: t0 + 2.3)
        XCTAssertFalse(g.wantsPeek)
    }

    func testChangeJustAfterFadeStartCancelsTheFade() {
        var g = settled()
        down(&g, at: t0)
        g.valuesChanged(now: t0 + 0.1)
        g.touchUp(now: t0 + 1)
        g.tick(now: t0 + 1.8)
        XCTAssertFalse(g.wantsPeek)
        g.valuesChanged(now: t0 + 1.8 + 0.2)
        XCTAssertTrue(g.wantsPeek, "消え始めの 0.25 秒の間の変化は取り消して残す")
    }

    func testChangeAfterFadeDoesNotShow() {
        var g = settled()
        down(&g, at: t0)
        g.valuesChanged(now: t0 + 0.1)
        g.touchUp(now: t0 + 1)
        g.tick(now: t0 + 1.8)
        g.valuesChanged(now: t0 + 1.8 + 0.3)
        XCTAssertFalse(g.wantsPeek)
    }

    func testChangeJustAfterLiftCountsButLaterDoesNot() {
        // Toggle やチップは、離した時に値が変わる。
        var a = settled()
        down(&a, at: t0)
        a.touchUp(now: t0 + 0.1)
        a.valuesChanged(now: t0 + 0.1 + 0.2)
        XCTAssertTrue(a.wantsPeek)
        XCTAssertEqual(a.deadline ?? -1, t0 + 0.3 + 0.8, accuracy: 1e-9)

        var b = settled()
        down(&b, at: t0)
        b.touchUp(now: t0 + 0.1)
        b.valuesChanged(now: t0 + 0.1 + 0.5)
        XCTAssertFalse(b.wantsPeek)
    }

    func testChangeWithNoFingerAndNoPulseNeverShows() {
        // 遠隔の鏡・プリセット・取り消し・デザイナー。
        var g = settled()
        g.valuesChanged(now: t0)
        XCTAssertFalse(g.wantsPeek)
    }

    func testHoldStartingInGraphNeverShows() {
        var g = settled()
        down(&g, at: t0, inGraph: true)
        g.valuesChanged(now: t0 + 0.1)
        XCTAssertFalse(g.wantsPeek)
        g.touchUp(now: t0 + 0.5)
        g.valuesChanged(now: t0 + 0.6)
        XCTAssertFalse(g.wantsPeek, "離した直後の猶予も無い")
        // 次の保持は図の外なら出る。
        down(&g, at: t0 + 3)
        g.valuesChanged(now: t0 + 3.1)
        XCTAssertTrue(g.wantsPeek)
    }

    func testMultiTouchIsIgnored() {
        var g = settled()
        down(&g, at: t0, touches: 3)
        g.valuesChanged(now: t0 + 0.1)
        XCTAssertFalse(g.wantsPeek)
        g.touchUp(now: t0 + 0.2)
        g.valuesChanged(now: t0 + 0.3)
        XCTAssertFalse(g.wantsPeek)
    }

    func testSecondFingerWhileShowingHidesIt() {
        var g = settled()
        down(&g, at: t0)
        g.valuesChanged(now: t0 + 0.1)
        XCTAssertTrue(g.wantsPeek)
        down(&g, at: t0 + 0.2, touches: 2)
        XCTAssertFalse(g.wantsPeek)
    }

    // MARK: - パルス

    func testPulseShowsFor12Seconds() {
        var g = settled()
        g.pulse(now: t0)
        XCTAssertTrue(g.wantsPeek)
        XCTAssertEqual(g.deadline ?? -1, t0 + 1.2, accuracy: 1e-9)
        g.tick(now: t0 + 1.19)
        XCTAssertTrue(g.wantsPeek)
        g.tick(now: t0 + 1.2)
        XCTAssertFalse(g.wantsPeek)
    }

    func testChangeRightAfterPulseDoesNotShortenIt() {
        // ParameterRow.set() はパルスを立てた直後に値を書く。
        var g = settled()
        g.pulse(now: t0)
        g.valuesChanged(now: t0)
        XCTAssertEqual(g.deadline ?? -1, t0 + 1.2, accuracy: 1e-9)
    }

    func testPulseDuringHoldKeepsUntilLiftAndPulseEnd() {
        var g = settled()
        down(&g, at: t0)
        g.pulse(now: t0 + 0.1)
        XCTAssertTrue(g.wantsPeek)
        XCTAssertNil(g.deadline)
        g.touchUp(now: t0 + 0.2)
        XCTAssertEqual(g.deadline ?? -1, t0 + 1.3, accuracy: 1e-9, "離して 0.8 秒より、パルスの残りが長ければそちら")
    }

    func testPulseDuringBlockedHoldNeverShows() {
        // スライダーの値の書き込みもパルスを呼ぶ。出さないと決めた保持では出さない。
        var a = settled()
        down(&a, at: t0, inGraph: true)
        a.pulse(now: t0 + 0.1)
        XCTAssertFalse(a.wantsPeek)

        var b = settled()
        down(&b, at: t0, touches: 2)
        b.pulse(now: t0 + 0.1)
        XCTAssertFalse(b.wantsPeek)

        var c = settled()
        down(&c, at: t0)
        c.suppress()
        c.pulse(now: t0 + 0.1)
        XCTAssertFalse(c.wantsPeek)
        c.touchUp(now: t0 + 0.2)
        XCTAssertFalse(c.wantsPeek)
    }

    func testBlockedHoldLeavesLingeringPeekTimerRunning() {
        var g = settled()
        g.pulse(now: t0)
        XCTAssertEqual(g.deadline ?? -1, t0 + 1.2, accuracy: 1e-9)
        down(&g, at: t0 + 0.5, inGraph: true)
        XCTAssertEqual(g.deadline ?? -1, t0 + 1.2, accuracy: 1e-9, "図の上の保持は、出ている図を押さえない")
        g.tick(now: t0 + 1.2)
        XCTAssertFalse(g.wantsPeek, "保持が続いていても期限で消える")
    }

    // MARK: - 開いた直後

    func testNothingShowsWithin06SecondsOfAppearing() {
        var g = ETGraphPeekGate(typeName: "BassManagementPlugin")
        g.appeared(now: t0)
        down(&g, at: t0 + 0.1)
        g.valuesChanged(now: t0 + 0.2)
        XCTAssertFalse(g.wantsPeek)
        g.pulse(now: t0 + 0.3)
        XCTAssertFalse(g.wantsPeek)
        g.valuesChanged(now: t0 + 0.6)
        XCTAssertTrue(g.wantsPeek, "0.6 秒を過ぎれば（指が下りていれば）出る")
    }

    func testPulseAfterQuietPeriodShows() {
        var g = ETGraphPeekGate(typeName: "BassManagementPlugin")
        g.appeared(now: t0)
        g.pulse(now: t0 + 0.6)
        XCTAssertTrue(g.wantsPeek)
    }

    // MARK: - 除外と中断

    func testExcludedTypesNeverShow() {
        for type in ["NoteSpectrogramPlugin", "RhythmAnalyzerPlugin", "SpectrogramPlugin"] {
            var g = settled(type)
            XCTAssertTrue(g.isExcluded)
            down(&g, at: t0)
            g.valuesChanged(now: t0 + 0.1)
            g.pulse(now: t0 + 0.2)
            XCTAssertFalse(g.wantsPeek, type)
            g.touchUp(now: t0 + 0.3)
            g.valuesChanged(now: t0 + 0.4)
            XCTAssertFalse(g.wantsPeek, type)
        }
        XCTAssertFalse(settled("FiveBandPEQPlugin").isExcluded)
    }

    func testSuppressHidesAtOnce() {
        var g = settled()
        down(&g, at: t0)
        g.valuesChanged(now: t0 + 0.1)
        XCTAssertTrue(g.wantsPeek)
        g.suppress()
        XCTAssertFalse(g.wantsPeek)
        XCTAssertNil(g.deadline)
        // 同じ保持の続きでは出さない。
        g.valuesChanged(now: t0 + 0.2)
        XCTAssertFalse(g.wantsPeek)
        g.touchUp(now: t0 + 0.3)
        g.valuesChanged(now: t0 + 0.4)
        XCTAssertFalse(g.wantsPeek)
    }

    func testSuppressHidesALingeringPeek() {
        var g = settled()
        g.pulse(now: t0)
        g.suppress()
        XCTAssertFalse(g.wantsPeek)
        g.tick(now: t0 + 5)
        XCTAssertFalse(g.wantsPeek)
    }

    func testScrollStartingAfterTouchDownNeverShows() {
        var g = settled()
        down(&g, at: t0)
        g.suppress()   // スクロールが始まった
        g.valuesChanged(now: t0 + 0.5)
        g.touchUp(now: t0 + 1)
        g.valuesChanged(now: t0 + 1.1)
        XCTAssertFalse(g.wantsPeek)
    }

    // MARK: - 置き場所

    func testPlacementTopBottomOrNowhere() {
        let size = CGSize(width: 390, height: 800)
        // 指が下の方なら上。
        XCTAssertEqual(ETGraphPeekGate.placement(viewport: size, topInset: 100, bottomInset: 34,
                                                 peekHeight: 160, touchY: 500), .top)
        // 上の帯（topInset + peekHeight + 24 = 284 より上）なら下。
        XCTAssertEqual(ETGraphPeekGate.placement(viewport: size, topInset: 100, bottomInset: 34,
                                                 peekHeight: 160, touchY: 283), .bottom)
        XCTAssertEqual(ETGraphPeekGate.placement(viewport: size, topInset: 100, bottomInset: 34,
                                                 peekHeight: 160, touchY: 284), .top)
        // 指が無い（パルス）は上。
        XCTAssertEqual(ETGraphPeekGate.placement(viewport: size, topInset: 100, bottomInset: 34,
                                                 peekHeight: 160, touchY: nil), .top)
        // 横向き（使える高さ 390 - 70 = 320 < 368）は出さない。
        XCTAssertNil(ETGraphPeekGate.placement(viewport: CGSize(width: 800, height: 390), topInset: 50,
                                               bottomInset: 20, peekHeight: 160, touchY: 200))
        // ちょうど 2 * 160 + 48 = 368 は出す。1 足りなければ出さない。
        XCTAssertNotNil(ETGraphPeekGate.placement(viewport: CGSize(width: 390, height: 368 + 100 + 34),
                                                  topInset: 100, bottomInset: 34, peekHeight: 160, touchY: nil))
        XCTAssertNil(ETGraphPeekGate.placement(viewport: CGSize(width: 390, height: 367 + 100 + 34),
                                               topInset: 100, bottomInset: 34, peekHeight: 160, touchY: nil))
    }

    // MARK: - 見えているか

    func testGraphVisibleThresholdSplitsAt60Percent() {
        let viewport = CGRect(x: 0, y: 100, width: 390, height: 600)
        // 高さ 100 の図で、見えているのが 59 と 60。
        let at59 = CGRect(x: 0, y: 100 - 41, width: 390, height: 100)
        let at60 = CGRect(x: 0, y: 100 - 40, width: 390, height: 100)
        XCTAssertFalse(ETGraphPeekGate.graphVisible(graphRects: [at59], viewport: viewport))
        XCTAssertTrue(ETGraphPeekGate.graphVisible(graphRects: [at60], viewport: viewport))
        // 下側からも同じ。
        let bottom59 = CGRect(x: 0, y: 700 - 59, width: 390, height: 100)
        let bottom60 = CGRect(x: 0, y: 700 - 60, width: 390, height: 100)
        XCTAssertFalse(ETGraphPeekGate.graphVisible(graphRects: [bottom59], viewport: viewport))
        XCTAssertTrue(ETGraphPeekGate.graphVisible(graphRects: [bottom60], viewport: viewport))
    }

    func testGraphVisibleAnyOneOfSeveralIsEnough() {
        let viewport = CGRect(x: 0, y: 100, width: 390, height: 600)
        let off = CGRect(x: 0, y: -300, width: 390, height: 132)
        let on = CGRect(x: 0, y: 300, width: 390, height: 132)
        XCTAssertFalse(ETGraphPeekGate.graphVisible(graphRects: [off], viewport: viewport))
        XCTAssertTrue(ETGraphPeekGate.graphVisible(graphRects: [off, on], viewport: viewport))
    }

    func testNoReportedGraphCountsAsOffscreen() {
        let viewport = CGRect(x: 0, y: 100, width: 390, height: 600)
        XCTAssertFalse(ETGraphPeekGate.graphVisible(graphRects: [], viewport: viewport))
        XCTAssertFalse(ETGraphPeekGate.graphVisible(graphRects: [CGRect(x: 0, y: 200, width: 390, height: 0)],
                                                    viewport: viewport))
    }

    func testPointInAnyGraph() {
        let rects = [CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 0, y: 200, width: 100, height: 100)]
        XCTAssertTrue(ETGraphPeekGate.point(CGPoint(x: 50, y: 250), inAny: rects))
        XCTAssertFalse(ETGraphPeekGate.point(CGPoint(x: 50, y: 150), inAny: rects))
        XCTAssertFalse(ETGraphPeekGate.point(CGPoint(x: 50, y: 150), inAny: []))
    }
}
