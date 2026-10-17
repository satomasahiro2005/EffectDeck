//  SongRecognitionPolicyTests.swift
//  曲の聞き取りの間合い（SongRecognitionPolicy）。
//
//  壊れると: 無音のあいだ Apple へ指紋を送り続ける、鳴っているのに聞くのを止める、
//  曲が変わってもアートワークが替わらない。

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

    func testKeepsFeedingWhilePlaying() {
        var p = started()
        for t in stride(from: 0.25, through: 600, by: 0.25) {
            XCTAssertEqual(p.audio(now: t, peak: loud), .feed)
        }
    }

    func testMatchKeepsListeningAndReportsChange() {
        var p = started()
        XCTAssertTrue(p.matched(id: "a"))                // 何も出ていなければすぐ出す
        XCTAssertEqual(p.phase, .listening(since: 0, silentSince: nil))
        XCTAssertEqual(p.audio(now: 9, peak: loud), .feed)
        XCTAssertFalse(p.matched(id: "a"))
        XCTAssertFalse(p.matched(id: "b", skew: 0.001))               // 替わり目の 1 回だけでは替えない
        XCTAssertEqual(p.lastID, "a")
        XCTAssertTrue(p.matched(id: "b", skew: 0.001))
        XCTAssertEqual(p.lastID, "b")
    }

    /// 替わり目で 1 回だけ違う曲に当たり、また元の曲に戻ったら替えない（10-17 の Shinedown）。
    func testOneOffWrongMatchIsIgnored() {
        var p = started()
        XCTAssertTrue(p.matched(id: "a"))
        XCTAssertFalse(p.matched(id: "wrong", skew: 0.001))
        XCTAssertFalse(p.matched(id: "a"))
        XCTAssertNil(p.pendingID)
        XCTAssertFalse(p.matched(id: "wrong", skew: 0.001))
        XCTAssertFalse(p.matched(id: "c", skew: 0.001))               // 候補が替われば数え直し
        XCTAssertEqual(p.lastID, "a")
        XCTAssertTrue(p.matched(id: "c", skew: 0.001))
    }

    func testSilenceDuringErrorRestRearms() {
        var p = started()
        p.failed(code: 202, now: 8)
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

    /// skew がほぼ無い当たりは 1 回で替える（替わるのを 2 秒待たせない）。
    func testTrustedSkewSwitchesAtOnce() {
        var p = started()
        XCTAssertTrue(p.matched(id: "a"))
        XCTAssertTrue(p.matched(id: "b", skew: -0.00012))
        XCTAssertEqual(p.lastID, "b")
        XCTAssertFalse(p.matched(id: "c", skew: 0.0010))
        XCTAssertEqual(p.lastID, "b")
    }

    func testPeerLostClearsID() {
        var p = started()
        _ = p.matched(id: "a")
        p.peerLost()
        XCTAssertEqual(p.phase, .waiting)
        XCTAssertNil(p.lastID)
        XCTAssertTrue(p.matched(id: "a"))
    }

    func testDiscontinuityKeepsID() {
        var p = started()
        _ = p.matched(id: "a")
        p.discontinuity()
        XCTAssertEqual(p.phase, .waiting)
        XCTAssertEqual(p.lastID, "a")
    }
}
