//  AudioLifecycleTests.swift
//  中断の通知と start() の試みが、followPeer の判断へどう効くか（ETAudioLifecycle）。
//
//  壊れると: 中断（着信など）から戻っても音が永久に戻らないか、中断中に setActive を
//  3.3Hz で叩き続ける。どちらも実機の着信でしか見えなかった。
//  判断そのもの（ETAudioSessionRules.shouldStart）の表は PeerFollowTests にある。
//  ここは AudioIO と同じ順で出来事を流し、状態の出入りを見る。

import XCTest

final class AudioLifecycleTests: XCTestCase {

    private typealias L = ETAudioLifecycle

    /// AudioIO の running と engine.isRunning の代わり。start() の成否は呼ぶ側が決める。
    private struct Sim {
        var life = L()
        var running = false
        var engine = false
        var starts: [TimeInterval] = []

        /// AudioIO.start()。入口で時刻を押し、成功したら started()。
        mutating func start(at now: TimeInterval, succeeds: Bool = true) {
            life.startAttempted(at: now)
            running = false
            engine = false
            starts.append(now)
            if succeeds {
                running = true
                engine = true
                life.started()
            }
        }

        /// AudioIO.tick → followPeer。
        mutating func tick(at now: TimeInterval, succeeds: Bool = true) {
            if life.shouldStart(running: running, engineRunning: engine, now: now) {
                start(at: now, succeeds: succeeds)
            }
        }

        /// AudioIO.handleInterruption。
        mutating func interruption(_ event: L.Interruption, at now: TimeInterval,
                                   startSucceeds: Bool = true) -> L.Response {
            let response = life.interruption(event, running: running)
            if response.stop { running = false; engine = false }
            if response.start { start(at: now, succeeds: startSucceeds) }
            return response
        }
    }

    // MARK: - 初期状態

    func testFreshStateIsNotInterruptedAndMayStartAtOnce() {
        let life = L()
        XCTAssertFalse(life.interrupted)
        XCTAssertEqual(life.lastStartAttempt, 0)
        XCTAssertTrue(life.shouldStart(running: false, engineRunning: false, now: 100))
    }

    // MARK: - 中断の通知ごとの応え

    /// 走っているときに中断が来たら止めて "Interrupted" にする。
    /// 止めないと engine は死んでいるのに running が true のまま残る。
    func testBeganWhileRunningStopsAndMarks() {
        var life = L()
        XCTAssertEqual(life.interruption(.began, running: true),
                       L.Response(stop: true, markInterrupted: true, start: false))
        XCTAssertTrue(life.interrupted)
    }

    /// 走っていなくても印は付ける（stop は呼ばない）。
    func testBeganWhileStoppedMarksWithoutStopping() {
        var life = L()
        XCTAssertEqual(life.interruption(.began, running: false),
                       L.Response(stop: false, markInterrupted: true, start: false))
        XCTAssertTrue(life.interrupted)
    }

    /// shouldResume が付いていればすぐ start()。
    func testEndedWithResumeStartsNow() {
        var life = L()
        _ = life.interruption(.began, running: true)
        XCTAssertEqual(life.interruption(.ended(shouldResume: true), running: false),
                       L.Response(stop: false, markInterrupted: false, start: true))
        XCTAssertFalse(life.interrupted)
    }

    /// 付いていなければ何もしない。中断は解けるので、followPeer が拾う。
    func testEndedWithoutResumeOnlyClearsTheInterruption() {
        var life = L()
        _ = life.interruption(.began, running: true)
        XCTAssertEqual(life.interruption(.ended(shouldResume: false), running: false), L.Response())
        XCTAssertFalse(life.interrupted)
        XCTAssertTrue(life.shouldStart(running: false, engineRunning: false, now: 100))
    }

    /// 知らない種類でも中断は解く。解かないと followPeer が永久に止まる。
    func testUnknownClearsTheInterruptionAndDoesNothingElse() {
        var life = L()
        _ = life.interruption(.began, running: true)
        XCTAssertEqual(life.interruption(.unknown, running: false), L.Response())
        XCTAssertFalse(life.interrupted)
    }

    /// began の無い ended（取りこぼし）は害が無い。
    func testEndedWithoutBeganIsHarmless() {
        var life = L()
        XCTAssertEqual(life.interruption(.ended(shouldResume: false), running: true), L.Response())
        XCTAssertFalse(life.interrupted)
        XCTAssertFalse(life.shouldStart(running: true, engineRunning: true, now: 100))
    }

    /// 中断の通知は start() の時刻に触らない（1 秒の間隔は start() の試みから数える）。
    func testInterruptionsDoNotTouchLastStartAttempt() {
        var life = L()
        life.startAttempted(at: 42)
        _ = life.interruption(.began, running: true)
        _ = life.interruption(.ended(shouldResume: false), running: false)
        _ = life.interruption(.unknown, running: false)
        XCTAssertEqual(life.lastStartAttempt, 42)
    }

    // MARK: - 中断中

    /// 中断中は、engine が死んでいても、何秒経っても start() しない。
    func testNeverStartsWhileInterrupted() {
        var life = L()
        _ = life.interruption(.began, running: true)
        for now in stride(from: 1.0, through: 3600, by: 7.3) {
            XCTAssertFalse(life.shouldStart(running: false, engineRunning: false, now: now))
            XCTAssertFalse(life.shouldStart(running: true, engineRunning: false, now: now))
        }
    }

    /// engine が上がったら中断の印は残さない。
    func testStartedClearsTheInterruption() {
        var life = L()
        _ = life.interruption(.began, running: true)
        life.started()
        XCTAssertFalse(life.interrupted)
    }

    // MARK: - 試みの間隔

    /// 入口で押した時刻から 1 秒は試さない。ちょうど 1 秒で試す。
    func testStartAttemptThrottlesForOneSecond() {
        var life = L()
        life.startAttempted(at: 50)
        XCTAssertFalse(life.shouldStart(running: false, engineRunning: false, now: 50))
        XCTAssertFalse(life.shouldStart(running: false, engineRunning: false, now: 50.999))
        XCTAssertTrue(life.shouldStart(running: false, engineRunning: false, now: 51))
    }

    /// メディアサービスの作り直しは中断を解き、間隔も待たずに試せるようにする。
    func testMediaServicesResetAllowsAnImmediateRetry() {
        var life = L()
        life.startAttempted(at: 100)
        _ = life.interruption(.began, running: true)
        life.mediaServicesReset()
        XCTAssertFalse(life.interrupted)
        XCTAssertEqual(life.lastStartAttempt, 0)
        XCTAssertTrue(life.shouldStart(running: false, engineRunning: false, now: 100.1))
    }

    // MARK: - 流れで見る

    /// 着信: 走っている → began → 中断中は 1 回も試さない → ended（shouldResume 無し）→
    /// 次の tick で鳴らし直す。**永久に戻らない**の形を塞いでいるのがこれ。
    func testCallWithoutResumeComesBackOnTheNextTick() {
        var sim = Sim()
        sim.tick(at: 10)
        XCTAssertEqual(sim.starts, [10])
        XCTAssertTrue(sim.running)

        _ = sim.interruption(.began, at: 20)
        XCTAssertFalse(sim.running)
        for now in stride(from: 20.3, to: 30, by: 0.3) { sim.tick(at: now) }
        XCTAssertEqual(sim.starts, [10], "中断中に start() した")

        XCTAssertEqual(sim.interruption(.ended(shouldResume: false), at: 30), L.Response())
        sim.tick(at: 30.3)
        XCTAssertEqual(sim.starts, [10, 30.3])
        XCTAssertTrue(sim.running)
    }

    /// shouldResume 付きなら通知のその場で鳴らし直し、次の tick では重ねて試さない。
    func testCallWithResumeRestartsImmediately() {
        var sim = Sim()
        sim.tick(at: 10)
        _ = sim.interruption(.began, at: 20)
        _ = sim.interruption(.ended(shouldResume: true), at: 30)
        XCTAssertEqual(sim.starts, [10, 30])
        sim.tick(at: 30.3)
        XCTAssertEqual(sim.starts, [10, 30])
    }

    /// 再開が失敗し続けても 1 秒に 1 回までしか試さない（3.3Hz で叩かない）。
    func testFailingResumeRetriesAtMostOncePerSecond() {
        var sim = Sim()
        sim.tick(at: 10)
        _ = sim.interruption(.began, at: 20)
        _ = sim.interruption(.ended(shouldResume: true), at: 30, startSucceeds: false)
        for step in 1...20 { sim.tick(at: 30 + Double(step) * 0.3, succeeds: false) }
        // 30 から 36 秒までで、試みは 30 と、その後は前の試みから 1 秒以上空いた最初の tick
        // （0.3 秒刻みなので 1.2 秒ごと）の 5 回だけ。
        let gaps = zip(sim.starts.dropFirst(), sim.starts.dropFirst(2)).map { $1 - $0 }
        XCTAssertTrue(gaps.allSatisfy { $0 >= 1 - 1e-9 }, "間隔 \(gaps)")
        XCTAssertEqual(sim.starts.count, 1 + 1 + 5, "試み \(sim.starts)")
    }

    /// 通知の無いまま OS が engine を止めた形（running は true のまま）も拾う。
    func testEngineDiedWithoutANotificationIsRestarted() {
        var sim = Sim()
        sim.tick(at: 10)
        sim.engine = false
        sim.tick(at: 12)
        XCTAssertEqual(sim.starts, [10, 12])
    }

    /// 中断中にメディアサービスが作り直されたら、中断は解けて、前の試みから 1 秒
    /// 経っていなくてもその場で試す（handleMediaServicesReset はすぐ followPeer を呼ぶ）。
    func testMediaServicesResetDuringAnInterruption() {
        var sim = Sim()
        sim.tick(at: 10)
        _ = sim.interruption(.began, at: 10.5)
        sim.life.mediaServicesReset()
        sim.tick(at: 10.6)
        XCTAssertEqual(sim.starts, [10, 10.6])
        XCTAssertTrue(sim.running)
    }
}
