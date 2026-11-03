//  RouteRebuildRuleTests.swift
//  レートや本数が組んだときと食い違ったときに組み直す判断（ETRouteRebuildRule）。
//
//  壊れると: 組み直しが早すぎれば engine.start() 直後の揺れで stop→start を毎秒
//  繰り返して音が切れ続け、遅すぎれば（あるいは組み直さなければ）イヤホンや IF を
//  挿し替えたあと速さのずれた音か、別のスピーカーへ行く音が出続ける。

import XCTest

final class RouteRebuildRuleTests: XCTestCase {

    /// 3 目盛り続いた食い違いで組み直す。2 目盛りでは組み直さない。
    func testRebuildsOnTheThirdMismatchedTick() {
        var r = ETRouteRebuildRule()
        XCTAssertFalse(r.observe(mismatch: true, now: 10.0, lastStart: 0))
        XCTAssertFalse(r.observe(mismatch: true, now: 10.3, lastStart: 0))
        XCTAssertTrue(r.observe(mismatch: true, now: 10.6, lastStart: 0))
    }

    /// 組み直したら数え直す。続けて食い違っていても、次はまた 3 目盛り後。
    func testCountRestartsAfterRebuild() {
        var r = ETRouteRebuildRule()
        for t in [10.0, 10.3] { _ = r.observe(mismatch: true, now: t, lastStart: 0) }
        XCTAssertTrue(r.observe(mismatch: true, now: 10.6, lastStart: 0))
        XCTAssertEqual(r.mismatchTicks, 0)
        XCTAssertFalse(r.observe(mismatch: true, now: 10.9, lastStart: 0))
        XCTAssertFalse(r.observe(mismatch: true, now: 11.2, lastStart: 0))
        XCTAssertTrue(r.observe(mismatch: true, now: 11.5, lastStart: 0))
    }

    /// 一瞬の食い違い（1〜2 目盛り）は忘れる。途中で合えば 0 から。
    func testTransientMismatchIsForgotten() {
        var r = ETRouteRebuildRule()
        _ = r.observe(mismatch: true, now: 10.0, lastStart: 0)
        _ = r.observe(mismatch: true, now: 10.3, lastStart: 0)
        XCTAssertFalse(r.observe(mismatch: false, now: 10.6, lastStart: 0))
        XCTAssertEqual(r.mismatchTicks, 0)
        XCTAssertFalse(r.observe(mismatch: true, now: 10.9, lastStart: 0))
        XCTAssertFalse(r.observe(mismatch: true, now: 11.2, lastStart: 0))
        XCTAssertTrue(r.observe(mismatch: true, now: 11.5, lastStart: 0))
    }

    /// start() から 1 秒経つまでは組み直さない。その間も数えは続け、
    /// 1 秒経った最初の目盛りで組み直す。
    func testWaitsOneSecondAfterStart() {
        var r = ETRouteRebuildRule()
        let start = 100.0
        XCTAssertFalse(r.observe(mismatch: true, now: 100.1, lastStart: start))
        XCTAssertFalse(r.observe(mismatch: true, now: 100.4, lastStart: start))
        XCTAssertFalse(r.observe(mismatch: true, now: 100.7, lastStart: start), "3 目盛りでも 1 秒前")
        XCTAssertEqual(r.mismatchTicks, 3)
        XCTAssertTrue(r.observe(mismatch: true, now: 101.0, lastStart: start), "ちょうど 1 秒で組み直す")
    }

    /// 1 秒待つ間に食い違いが消えたら組み直さない。
    func testMismatchClearingDuringSettleCancels() {
        var r = ETRouteRebuildRule()
        let start = 100.0
        for t in [100.1, 100.4, 100.7] { _ = r.observe(mismatch: true, now: t, lastStart: start) }
        XCTAssertFalse(r.observe(mismatch: false, now: 101.0, lastStart: start))
        XCTAssertFalse(r.observe(mismatch: true, now: 101.3, lastStart: start))
    }

    // MARK: - 食い違いの判定

    func testRateMismatch() {
        XCTAssertTrue(ETRouteRebuildRule.rateMismatch(running: true, built: 48000, hardware: 44100))
        XCTAssertTrue(ETRouteRebuildRule.rateMismatch(running: true, built: 48000, hardware: 47999))
        XCTAssertFalse(ETRouteRebuildRule.rateMismatch(running: true, built: 48000, hardware: 48000.5),
                       "1Hz 未満の揺れは同じレート")
        XCTAssertFalse(ETRouteRebuildRule.rateMismatch(running: true, built: 48000, hardware: 48000))
    }

    /// 走っていない・組んでいない・ハードウェアがレートを名乗っていない（0 や NaN）ときは
    /// 食い違いと見ない。見ると止まっている間に組み直しを撃つ。
    func testRateMismatchNeedsRunningBuiltAndPositiveRate() {
        XCTAssertFalse(ETRouteRebuildRule.rateMismatch(running: false, built: 48000, hardware: 44100))
        XCTAssertFalse(ETRouteRebuildRule.rateMismatch(running: true, built: nil, hardware: 44100))
        XCTAssertFalse(ETRouteRebuildRule.rateMismatch(running: true, built: 48000, hardware: 0))
        XCTAssertFalse(ETRouteRebuildRule.rateMismatch(running: true, built: 48000, hardware: -1))
        XCTAssertFalse(ETRouteRebuildRule.rateMismatch(running: true, built: 48000, hardware: .nan))
    }

    func testChannelMismatch() {
        XCTAssertTrue(ETRouteRebuildRule.channelMismatch(running: true, built: 2, actual: 8))
        XCTAssertTrue(ETRouteRebuildRule.channelMismatch(running: true, built: 8, actual: 2))
        XCTAssertFalse(ETRouteRebuildRule.channelMismatch(running: true, built: 2, actual: 2))
        XCTAssertFalse(ETRouteRebuildRule.channelMismatch(running: false, built: 2, actual: 8))
        XCTAssertFalse(ETRouteRebuildRule.channelMismatch(running: true, built: nil, actual: 8))
    }

    /// モノラルの出力へ移っても、処理の本数（2）で比べるので組み直さない。
    func testMonoOutputIsNotAChannelMismatch() {
        let actual = ETAudioSessionRules.processingChannels(forOutputChannels: 1)
        XCTAssertFalse(ETRouteRebuildRule.channelMismatch(running: true, built: 2, actual: actual))
    }

    /// AudioIO.tick の並び: 3.3Hz の tick で、イヤホンを挿して 44.1kHz に変わったあと
    /// 何本目の tick で組み直すか。start() は 5 秒前。組み直すと built と lastStart が
    /// 新しくなる（AudioIO.rebuild → start）。
    func testTickSequenceForAHeadphoneRateChange() {
        var r = ETRouteRebuildRule()
        var lastStart = 0.0
        var built = 48000.0
        var fired: [Int] = []
        for tick in 0..<20 {
            let now = 5.0 + Double(tick) * 0.3
            let hardware = tick < 2 ? 48000.0 : 44100.0
            let mismatch = ETRouteRebuildRule.rateMismatch(running: true, built: built, hardware: hardware)
            if r.observe(mismatch: mismatch, now: now, lastStart: lastStart) {
                fired.append(tick)
                built = hardware
                lastStart = now
            }
        }
        XCTAssertEqual(fired, [4], "変わってから 3 本目の tick で 1 回だけ")
    }
}
