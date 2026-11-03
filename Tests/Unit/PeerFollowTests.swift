//  PeerFollowTests.swift
//  AudioIO.followPeer が start() を呼ぶかどうか（ETAudioSessionRules.shouldStart）。
//
//  壊れると: 中断（着信など）から戻っても音が永久に戻らない（running が true のまま
//  残って条件が成り立たない）か、中断中に setActive を 3.3Hz で叩き続ける。
//  **拡張が繋がっているかは見ない**（見ると繋がらなくなる。issue #5）。

import XCTest

final class PeerFollowTests: XCTestCase {

    private func should(running: Bool = false, engine: Bool = false, interrupted: Bool = false,
                        now: TimeInterval = 100, last: TimeInterval = 0) -> Bool {
        ETAudioSessionRules.shouldStart(running: running, engineRunning: engine,
                                        interrupted: interrupted, now: now, lastStartAttempt: last)
    }

    /// 止まっていれば鳴らし始める。相手が居なくても（無音を出して背景で生き続けるため）。
    func testStartsWhenStoppedEvenWithoutPeer() {
        XCTAssertTrue(should())
    }

    /// 走っていて engine も回っていれば何もしない。
    func testDoesNothingWhenAlive() {
        XCTAssertFalse(should(running: true, engine: true))
    }

    /// **中断で OS が engine を止めた形。** running は true のまま残るが、engine は止まっている。
    /// running だけを見ていたら永久に戻らなかった。
    func testRestartsWhenEngineDiedUnderUs() {
        XCTAssertTrue(should(running: true, engine: false))
    }

    /// engine だけ回っていて running が false（stop の途中など）も組み直す。
    func testRestartsWhenNotRunningButEngineUp() {
        XCTAssertTrue(should(running: false, engine: true))
    }

    /// 中断中は呼ばない（setActive(true) が失敗するだけ）。
    func testDoesNotStartWhileInterrupted() {
        XCTAssertFalse(should(interrupted: true))
        XCTAssertFalse(should(running: true, engine: false, interrupted: true))
    }

    /// 前回から 1 秒は空ける。ちょうど 1 秒なら呼ぶ。
    func testWaitsOneSecondBetweenAttempts() {
        XCTAssertFalse(should(now: 100.5, last: 100))
        XCTAssertFalse(should(now: 100.999, last: 100))
        XCTAssertTrue(should(now: 101, last: 100))
    }

    /// 3.3Hz の tick で失敗し続けても、呼ぶのは 1 秒に 1 回まで。
    func testRetryRateIsBoundedAt1Hz() {
        var last = 0.0
        var calls = 0
        var t = 100.0
        while t < 110 {
            if should(now: t, last: last) { calls += 1; last = t }
            t += 0.3
        }
        XCTAssertLessThanOrEqual(calls, 10)
        XCTAssertGreaterThanOrEqual(calls, 8)
    }

    /// 起動直後（lastStartAttempt = 0、systemUptime は起動からの秒）でもすぐ呼ぶ。
    /// mediaServicesWereReset のあとも 0 に戻してから呼んでいる。
    func testFirstAttemptIsImmediate() {
        XCTAssertTrue(should(now: 1.0, last: 0))
    }
}
