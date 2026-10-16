//  SongRecognitionPolicyTests.swift
//  曲の聞き取りの間合い（SongRecognitionPolicy）。
//
//  壊れると: 無音のあいだ Apple へ指紋を送り続ける、当たったあとも聞かせ続ける、
//  外れたまま永久に聞かせる、曲が変わってもアートワークが替わらない。

import XCTest

final class SongRecognitionPolicyTests: XCTestCase {

    private let loud: Float = 0.1
    private let quiet: Float = 0

    private func started(at now: TimeInterval = 0) -> SongRecognitionPolicy {
        var p = SongRecognitionPolicy()
        XCTAssertEqual(p.audio(now: now, peak: loud), .startAndFeed)
        return p
    }

    func testSilentWhileWaitingSkips() {
        var p = SongRecognitionPolicy()
        XCTAssertEqual(p.audio(now: 0, peak: quiet), .skip)
        XCTAssertEqual(p.audio(now: 1, peak: SongRecognitionPolicy.silencePeak), .skip)
        XCTAssertEqual(p.phase, .waiting)
    }

    func testSoundStartsSession() {
        var p = SongRecognitionPolicy()
        XCTAssertEqual(p.audio(now: 5, peak: loud), .startAndFeed)
        XCTAssertEqual(p.phase, .listening(since: 5, silentSince: nil))
        XCTAssertEqual(p.audio(now: 5.5, peak: loud), .feed)
    }

    func testShortSilenceKeepsFeeding() {
        var p = started()
        XCTAssertEqual(p.audio(now: 1, peak: quiet), .feed)
        XCTAssertEqual(p.audio(now: 2.5, peak: quiet), .feed)
        // 音が戻れば無音の数えは消える。
        XCTAssertEqual(p.audio(now: 2.75, peak: loud), .feed)
        XCTAssertEqual(p.audio(now: 4.5, peak: quiet), .feed)
        XCTAssertEqual(p.audio(now: 6, peak: quiet), .feed)
    }

    func testTwoSecondsSilenceDrops() {
        var p = started()
        XCTAssertEqual(p.audio(now: 1, peak: quiet), .feed)
        XCTAssertEqual(p.audio(now: 3, peak: quiet), .drop(clear: false))
        XCTAssertEqual(p.phase, .waiting)
        // 次の音からまた始める。
        XCTAssertEqual(p.audio(now: 4, peak: loud), .startAndFeed)
    }

    /// 元のアプリが止まって音が来ない間も、呼ぶ側は peak 0 で時計を進める。
    /// 20 秒を越える空白のあとでも、絵は残して聞き直しに戻る。
    func testNoDataGapWhileListeningDropsWithoutClearing() {
        var p = started()
        XCTAssertEqual(p.audio(now: 1, peak: quiet), .feed)
        XCTAssertEqual(p.audio(now: 1.25, peak: quiet), .feed)
        XCTAssertEqual(p.audio(now: 3, peak: quiet), .drop(clear: false))
        XCTAssertEqual(p.phase, .waiting)
        // 空白が長くても、再開は新しいセッションから。
        XCTAssertEqual(p.audio(now: 40, peak: loud), .startAndFeed)
    }

    func testNoDataGapWhileRestingRearms() {
        var p = started()
        _ = p.matched(id: "a", now: 1)
        XCTAssertEqual(p.audio(now: 2, peak: quiet), .skip)
        XCTAssertEqual(p.audio(now: 4, peak: quiet), .skip)
        XCTAssertEqual(p.phase, .waiting)
        XCTAssertEqual(p.audio(now: 5, peak: loud), .startAndFeed)
    }

    func testAttemptLimitDropsAndClears() {
        var p = started()
        XCTAssertEqual(p.audio(now: 19.75, peak: loud), .feed)
        XCTAssertEqual(p.audio(now: 20, peak: loud), .drop(clear: true))
        XCTAssertEqual(p.phase, .resting(until: 50, silentSince: nil))
        XCTAssertNil(p.lastID)
        XCTAssertEqual(p.audio(now: 21, peak: loud), .skip)
    }

    func testMatchRestsAndReportsChange() {
        var p = started()
        XCTAssertTrue(p.matched(id: "a", now: 8))
        XCTAssertEqual(p.phase, .resting(until: 28, silentSince: nil))
        XCTAssertEqual(p.audio(now: 9, peak: loud), .skip)
        XCTAssertFalse(p.matched(id: "a", now: 30))
        XCTAssertTrue(p.matched(id: "b", now: 60))
        XCTAssertEqual(p.lastID, "b")
    }

    func testRestEndsAfterTimeout() {
        var p = started()
        _ = p.matched(id: "a", now: 8)
        XCTAssertEqual(p.audio(now: 27.75, peak: loud), .skip)
        XCTAssertEqual(p.audio(now: 28, peak: loud), .startAndFeed)
        XCTAssertEqual(p.lastID, "a")
    }

    func testSilenceDuringRestRearms() {
        var p = started()
        _ = p.matched(id: "a", now: 8)
        XCTAssertEqual(p.audio(now: 10, peak: quiet), .skip)
        XCTAssertEqual(p.audio(now: 11.5, peak: loud), .skip)       // 音が戻れば数え直し
        XCTAssertEqual(p.audio(now: 12, peak: quiet), .skip)
        XCTAssertEqual(p.audio(now: 14, peak: quiet), .skip)
        XCTAssertEqual(p.phase, .waiting)
        XCTAssertEqual(p.audio(now: 15, peak: loud), .startAndFeed)
    }

    func testError101RestartsImmediately() {
        var p = started()
        p.failed(code: 101, now: 5)
        XCTAssertEqual(p.phase, .waiting)
        XCTAssertEqual(p.audio(now: 5.25, peak: loud), .startAndFeed)
    }

    func testOtherErrorRests60() {
        var p = started()
        p.failed(code: 202, now: 5)
        XCTAssertEqual(p.phase, .resting(until: 65, silentSince: nil))
        XCTAssertEqual(p.audio(now: 64, peak: loud), .skip)
        XCTAssertEqual(p.audio(now: 65, peak: loud), .startAndFeed)
    }

    func testPeerLostClearsID() {
        var p = started()
        _ = p.matched(id: "a", now: 8)
        p.peerLost()
        XCTAssertEqual(p.phase, .waiting)
        XCTAssertNil(p.lastID)
        XCTAssertTrue(p.matched(id: "a", now: 10))
    }

    func testDiscontinuityKeepsID() {
        var p = started()
        _ = p.matched(id: "a", now: 8)
        p.discontinuity()
        XCTAssertEqual(p.phase, .waiting)
        XCTAssertEqual(p.lastID, "a")
    }
}
