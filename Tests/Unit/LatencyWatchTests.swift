//  LatencyWatchTests.swift
//  値を渡した直後には動かない遅れの見張り（ETLatencyWatch）。Foundation だけ。
//
//  壊れると: SFZ の Detection を Event にしても Total Delay が 140 ms 増えないまま
//  （帯の Fx と並列の段の位置合わせも古いまま）。または、音を止めている間に諦めて、
//  回り出してから動いても組み直されない。

import XCTest

final class LatencyWatchTests: XCTestCase {

    private let a = UUID()
    private let b = UUID()

    func testNothingWatchedNeverRepublishes() {
        var watch = ETLatencyWatch()
        XCTAssertFalse(watch.tick(now: 1, rendering: true, processing: { _ in true }) { _ in 100 })
    }

    func testRepublishesWhenTheLatencyMoves() {
        var watch = ETLatencyWatch()
        watch.expect(id: a, latency: 100)
        XCTAssertFalse(watch.tick(now: 1, rendering: true, processing: { _ in true }) { _ in 100 })
        XCTAssertTrue(watch.tick(now: 1.3, rendering: true, processing: { _ in true }) { _ in 6_900 })
        XCTAssertTrue(watch.isEmpty, "組み直したら覚えを消す。同じ変化で何度も組み直さない")
        XCTAssertFalse(watch.tick(now: 1.6, rendering: true, processing: { _ in true }) { _ in 6_900 })
    }

    func testKeepsWatchingWhileNotRendering() {
        var watch = ETLatencyWatch()
        watch.expect(id: a, latency: 100)
        // 止めていた 10 秒のあいだ、値は並んだまま。諦めない。
        var now = 0.0
        for _ in 0..<40 {
            now += 0.3
            XCTAssertFalse(watch.tick(now: now, rendering: false, processing: { _ in true }) { _ in 100 })
        }
        XCTAssertFalse(watch.isEmpty)
        XCTAssertTrue(watch.tick(now: now + 0.3, rendering: true, processing: { _ in true }) { _ in 6_900 }, "回り出したら変わる")
    }

    func testGivesUpAfterRenderingWithoutAChange() {
        var watch = ETLatencyWatch()
        watch.expect(id: a, latency: 100)
        var now = 0.0
        XCTAssertFalse(watch.tick(now: now, rendering: true, processing: { _ in true }) { _ in 100 })
        var ticks = 0
        while !watch.isEmpty && ticks < 100 {
            now += 0.3
            ticks += 1
            XCTAssertFalse(watch.tick(now: now, rendering: true, processing: { _ in true }) { _ in 100 })
        }
        XCTAssertTrue(watch.isEmpty)
        // 2 秒 ÷ 0.3 秒 = 7 回目で超える。
        XCTAssertEqual(ticks, 7)
    }

    func testLongGapsAreNotCountedAsRendering() {
        var watch = ETLatencyWatch()
        watch.expect(id: a, latency: 100)
        XCTAssertFalse(watch.tick(now: 0, rendering: true, processing: { _ in true }) { _ in 100 })
        // 背景に回って 1 分空いた。1 回で諦めさせない（1 秒までしか数えない）。
        XCTAssertFalse(watch.tick(now: 60, rendering: true, processing: { _ in true }) { _ in 100 })
        XCTAssertFalse(watch.isEmpty)
    }

    func testValueChangedAgainResetsTheClock() {
        var watch = ETLatencyWatch()
        watch.expect(id: a, latency: 100)
        var now = 0.0
        XCTAssertFalse(watch.tick(now: now, rendering: true, processing: { _ in true }) { _ in 100 })
        for _ in 0..<5 { now += 0.3; XCTAssertFalse(watch.tick(now: now, rendering: true, processing: { _ in true }) { _ in 100 }) }
        watch.expect(id: a, latency: 100)
        for _ in 0..<5 { now += 0.3; XCTAssertFalse(watch.tick(now: now, rendering: true, processing: { _ in true }) { _ in 100 }) }
        XCTAssertFalse(watch.isEmpty, "もう一度触ったので数え直し")
    }

    func testOneRepublishPerTickAndUnchangedEntriesStay() {
        var watch2 = ETLatencyWatch()
        watch2.expect(id: a, latency: 100)
        watch2.expect(id: b, latency: 200)
        let moved = watch2.tick(now: 0.3, rendering: true, processing: { _ in true }) { $0 == self.a ? 7_000 : 200 }
        XCTAssertTrue(moved, "2 段のうち 1 段が動いたら 1 度だけ組み直す")
        XCTAssertEqual(watch2.watched, [b], "動いていない段は見張りを続ける")
    }

    func testRemovedNodesAreForgotten() {
        var watch = ETLatencyWatch()
        watch.expect(id: a, latency: 100)
        XCTAssertFalse(watch.tick(now: 0.3, rendering: true, processing: { _ in true }) { _ in nil })
        XCTAssertTrue(watch.isEmpty)
    }

    // MARK: - 処理されていない段（マスターのバイパス・段の切・Section の OFF）

    func testIsProcessedMatchesTheEngineSkipRules() {
        func p(_ bypass: Bool = false, _ enabled: Bool = true, _ ch: Bool = false, _ gate: UInt8 = 1) -> Bool {
            ETLatencyWatch.isProcessed(masterBypass: bypass, enabled: enabled, channelBypassed: ch, sectionGate: gate)
        }
        XCTAssertTrue(p())
        XCTAssertFalse(p(true), "マスターのバイパスは先頭で全部返る")
        XCTAssertFalse(p(false, false), "段の切")
        XCTAssertFalse(p(false, true, true), "上流が受けない Ch は切で渡る")
        XCTAssertFalse(p(false, true, false, 0), "Section の OFF")
    }

    func testDoesNotGiveUpWhileTheStageIsNotProcessed() {
        var watch = ETLatencyWatch()
        watch.expect(id: a, latency: 100)
        // エンジンは回っているが、この段は飛ばされている（バイパス・切・Section の OFF）。10 秒たっても諦めない。
        var now = 0.0
        for _ in 0..<40 {
            now += 0.3
            XCTAssertFalse(watch.tick(now: now, rendering: true, processing: { _ in false }) { _ in 100 })
        }
        XCTAssertFalse(watch.isEmpty)
        // 戻したら最初の処理でカーネルが受け取り、遅れが動く。
        XCTAssertTrue(watch.tick(now: now + 0.3, rendering: true, processing: { _ in true }) { _ in 6_900 })
    }

    func testProcessedTimeIsCountedPerStage() {
        var watch = ETLatencyWatch()
        watch.expect(id: a, latency: 100)
        watch.expect(id: b, latency: 200)
        var now = 0.0
        XCTAssertFalse(watch.tick(now: now, rendering: true, processing: { $0 == self.a }) { $0 == self.a ? 100 : 200 })
        for _ in 0..<7 {
            now += 0.3
            XCTAssertFalse(watch.tick(now: now, rendering: true, processing: { $0 == self.a }) { $0 == self.a ? 100 : 200 })
        }
        XCTAssertEqual(watch.watched, [b], "処理されていた a だけ諦める。飛ばされていた b は残る")
    }

    // MARK: - 空のあいだの lastTick

    func testFirstTickAfterAnIdleGapCountsNothing() {
        var watch = ETLatencyWatch()
        // 見張りが空のまま時間が過ぎる（tick は呼ばれても isEmpty で早く返るので lastTick は更新されない想定）。
        XCTAssertFalse(watch.tick(now: 0, rendering: true, processing: { _ in true }) { _ in 100 })
        watch.expect(id: a, latency: 100)
        // 1 時間後の最初の見直し。前の lastTick から 1 秒（上限）を数えてはいけない。
        XCTAssertFalse(watch.tick(now: 3_600, rendering: true, processing: { _ in true }) { _ in 100 })
        var now = 3_600.0
        var ticks = 0
        while !watch.isEmpty && ticks < 100 {
            now += 0.3
            ticks += 1
            XCTAssertFalse(watch.tick(now: now, rendering: true, processing: { _ in true }) { _ in 100 })
        }
        XCTAssertEqual(ticks, 7, "2 秒をまるまる数える。最初の見直しで半分が消えない")
    }
}
