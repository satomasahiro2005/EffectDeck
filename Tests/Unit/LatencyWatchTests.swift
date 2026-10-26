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
        XCTAssertFalse(watch.tick(now: 1, rendering: true) { _ in 100 })
    }

    func testRepublishesWhenTheLatencyMoves() {
        var watch = ETLatencyWatch()
        watch.expect(id: a, latency: 100)
        XCTAssertFalse(watch.tick(now: 1, rendering: true) { _ in 100 })
        XCTAssertTrue(watch.tick(now: 1.3, rendering: true) { _ in 6_900 })
        XCTAssertTrue(watch.isEmpty, "組み直したら覚えを消す。同じ変化で何度も組み直さない")
        XCTAssertFalse(watch.tick(now: 1.6, rendering: true) { _ in 6_900 })
    }

    func testKeepsWatchingWhileNotRendering() {
        var watch = ETLatencyWatch()
        watch.expect(id: a, latency: 100)
        // 止めていた 10 秒のあいだ、値は並んだまま。諦めない。
        var now = 0.0
        for _ in 0..<40 {
            now += 0.3
            XCTAssertFalse(watch.tick(now: now, rendering: false) { _ in 100 })
        }
        XCTAssertFalse(watch.isEmpty)
        XCTAssertTrue(watch.tick(now: now + 0.3, rendering: true) { _ in 6_900 }, "回り出したら変わる")
    }

    func testGivesUpAfterRenderingWithoutAChange() {
        var watch = ETLatencyWatch()
        watch.expect(id: a, latency: 100)
        var now = 0.0
        XCTAssertFalse(watch.tick(now: now, rendering: true) { _ in 100 })
        var ticks = 0
        while !watch.isEmpty && ticks < 100 {
            now += 0.3
            ticks += 1
            XCTAssertFalse(watch.tick(now: now, rendering: true) { _ in 100 })
        }
        XCTAssertTrue(watch.isEmpty)
        // 2 秒 ÷ 0.3 秒 = 7 回目で超える。
        XCTAssertEqual(ticks, 7)
    }

    func testLongGapsAreNotCountedAsRendering() {
        var watch = ETLatencyWatch()
        watch.expect(id: a, latency: 100)
        XCTAssertFalse(watch.tick(now: 0, rendering: true) { _ in 100 })
        // 背景に回って 1 分空いた。1 回で諦めさせない（1 秒までしか数えない）。
        XCTAssertFalse(watch.tick(now: 60, rendering: true) { _ in 100 })
        XCTAssertFalse(watch.isEmpty)
    }

    func testValueChangedAgainResetsTheClock() {
        var watch = ETLatencyWatch()
        watch.expect(id: a, latency: 100)
        var now = 0.0
        XCTAssertFalse(watch.tick(now: now, rendering: true) { _ in 100 })
        for _ in 0..<5 { now += 0.3; XCTAssertFalse(watch.tick(now: now, rendering: true) { _ in 100 }) }
        watch.expect(id: a, latency: 100)
        for _ in 0..<5 { now += 0.3; XCTAssertFalse(watch.tick(now: now, rendering: true) { _ in 100 }) }
        XCTAssertFalse(watch.isEmpty, "もう一度触ったので数え直し")
    }

    func testOneRepublishPerTickAndUnchangedEntriesStay() {
        var watch2 = ETLatencyWatch()
        watch2.expect(id: a, latency: 100)
        watch2.expect(id: b, latency: 200)
        let moved = watch2.tick(now: 0.3, rendering: true) { $0 == self.a ? 7_000 : 200 }
        XCTAssertTrue(moved, "2 段のうち 1 段が動いたら 1 度だけ組み直す")
        XCTAssertEqual(watch2.watched, [b], "動いていない段は見張りを続ける")
    }

    func testRemovedNodesAreForgotten() {
        var watch = ETLatencyWatch()
        watch.expect(id: a, latency: 100)
        XCTAssertFalse(watch.tick(now: 0.3, rendering: true) { _ in nil })
        XCTAssertTrue(watch.isEmpty)
    }
}
