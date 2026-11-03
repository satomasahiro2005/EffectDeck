//  ProtocolMigrationTests.swift
//  プロトコル名を替えた版への更新で、再起動の案内を誰に出し、いつ消すか（#12）。
//
//  壊れると: 新しく入れた人にも「再起動して」と出るか、上げた人に出ないまま繋がらない。
//  または繋がり損ねた 1.5 秒で案内が消え、繋がらないのに何も言わなくなる。

import XCTest

final class ProtocolMigrationTests: XCTestCase {

    private typealias M = ETProtocolMigration

    // MARK: - 誰に出すか

    /// 新しく入れた人（鎖がまだ無い）には出さない。
    func testFreshInstallIsNotPending() {
        let s = ETMemoryStorage()
        XCTAssertFalse(M.noteLaunch(storage: s))
        XCTAssertFalse(M.isPending(storage: s))
    }

    /// 前の版から上げた人（鎖が在って印が無い）には出す。
    func testUpdateFromOlderBuildIsPending() {
        let s = ETMemoryStorage([M.legacyKey: Data("[]".utf8)])
        XCTAssertTrue(M.noteLaunch(storage: s))
    }

    /// 新しく入れた後の起動で鎖ができても、2 回目以降は出さない。
    func testFreshInstallStaysClearAfterChainIsSaved() {
        let s = ETMemoryStorage()
        M.noteLaunch(storage: s)
        s.set(Data("[]".utf8), forKey: M.legacyKey)
        XCTAssertFalse(M.noteLaunch(storage: s))
    }

    /// 繋がるまでは起動し直しても出し続ける。
    func testPendingSurvivesRelaunch() {
        let s = ETMemoryStorage([M.legacyKey: Data("[]".utf8)])
        M.noteLaunch(storage: s)
        XCTAssertTrue(M.noteLaunch(storage: s))
    }

    /// 消したら、鎖が在っても戻らない。
    func testClearedStaysCleared() {
        let s = ETMemoryStorage([M.legacyKey: Data("[]".utf8)])
        M.noteLaunch(storage: s)
        M.clear(storage: s)
        XCTAssertFalse(M.noteLaunch(storage: s))
        XCTAssertTrue(s.rejected.isEmpty)
    }

    // MARK: - いつ消すか

    /// 0.3 秒おきの目盛りで、毎回 14400 フレーム（48 kHz の 0.3 秒）ずつ増える形を流す。
    private func run(_ audio: inout ETSustainedAudio, from start: TimeInterval, seconds: TimeInterval,
                     received: inout UInt64, peer: Bool = true, grow: Bool = true) -> Bool {
        var t = start
        var done = false
        while t < start + seconds {
            if grow { received += 14_400 }
            done = audio.observe(peer: peer, received: received, now: t) || done
            t += 0.3
        }
        return done
    }

    /// 途切れずに 10 秒続けば消す。
    func testSustainedAudioClears() {
        var a = ETSustainedAudio()
        var r: UInt64 = 0
        XCTAssertTrue(run(&a, from: 100, seconds: 10.5, received: &r))
    }

    /// 繋がり損ねた 1.5 秒の窓では消さない。それが何度来ても消さない。
    func testBriefFailedConnectionsDoNotClear() {
        var a = ETSustainedAudio()
        var r: UInt64 = 0
        var t: TimeInterval = 100
        for _ in 0..<10 {
            XCTAssertFalse(run(&a, from: t, seconds: 1.5, received: &r))
            t += 1.5
            XCTAssertFalse(run(&a, from: t, seconds: 3, received: &r, peer: false, grow: false))
            t += 3
        }
    }

    /// 繋がったままでも音が来ていなければ数えない（hasPeer だけでは消さない）。
    func testPeerWithoutAudioDoesNotClear() {
        var a = ETSustainedAudio()
        var r: UInt64 = 0
        XCTAssertFalse(run(&a, from: 100, seconds: 30, received: &r, grow: false))
    }

    /// 途中で止まったら数え直す。
    func testStallResetsTheCount() {
        var a = ETSustainedAudio()
        var r: UInt64 = 0
        XCTAssertFalse(run(&a, from: 100, seconds: 6, received: &r))
        XCTAssertFalse(run(&a, from: 106, seconds: 2, received: &r, grow: false))
        XCTAssertFalse(run(&a, from: 108, seconds: 6, received: &r))
        XCTAssertTrue(run(&a, from: 114, seconds: 5, received: &r))
    }

    /// 1 目盛りだけ増えなかったのは許す。
    func testSingleMissedTickIsTolerated() {
        var a = ETSustainedAudio()
        var r: UInt64 = 0
        XCTAssertFalse(run(&a, from: 100, seconds: 5, received: &r))
        XCTAssertFalse(a.observe(peer: true, received: r, now: 105.1))
        XCTAssertTrue(run(&a, from: 105.4, seconds: 5, received: &r))
    }
}
