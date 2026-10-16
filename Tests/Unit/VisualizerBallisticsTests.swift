//  VisualizerBallisticsTests.swift
//  メーターの落ち方と VU の針（VisualizerBallistics）。
//
//  壊れると: 画面が 30Hz か 60Hz かでメーターの落ちる速さが変わる、ピークの印が消える・居座る、
//  VU の針が規格の 300ms・行き過ぎ 1.25% から外れる。

import XCTest

final class VisualizerBallisticsTests: XCTestCase {

    private typealias B = ETVisualizerBallistics

    func testFallIsIndependentOfStepSize() {
        let cases: [(rate: Float, floor: Float)] = [(B.classicFall, B.classicFloor), (45, B.classicFloor),
                                                    (B.effetuneFall, B.effetuneFloor)]
        for (rate, floor) in cases {
            let twoSteps = B.fall(B.fall(-10, input: -200, rate: rate, dt: 1.0 / 60, floor: floor),
                                  input: -200, rate: rate, dt: 1.0 / 60, floor: floor)
            let oneStep = B.fall(-10, input: -200, rate: rate, dt: 1.0 / 30, floor: floor)
            XCTAssertEqual(twoSteps, oneStep, accuracy: 1e-4, "rate \(rate)")
            XCTAssertEqual(oneStep, -10 - rate / 30, accuracy: 1e-4)
        }
    }

    func testFallRisesInstantlyAndStopsAtTheFloor() {
        XCTAssertEqual(B.fall(-60, input: -3, rate: 24, dt: 0.1, floor: -120), -3)
        XCTAssertEqual(B.fall(-119, input: -200, rate: 24, dt: 1, floor: -120), -120)
        // 時間が逆行しても上がらない。
        XCTAssertEqual(B.fall(-20, input: -200, rate: 24, dt: -1, floor: -120), -20)
    }

    func testClassicHoldsThenReleases() {
        var level = B.Level(floor: B.classicFloor)
        B.classic(&level, db: -6, now: 10, dt: 0.033)
        XCTAssertEqual(level.current, -6)
        XCTAssertEqual(level.peak, -6)
        // 1.5 秒のあいだは印が動かない。棒は落ちる。
        var now = 10.0
        while now < 11.4 {
            now += 1.0 / 30
            B.classic(&level, db: -120, now: now, dt: 1.0 / 30)
        }
        XCTAssertEqual(level.peak, -6)
        XCTAssertLessThan(level.current, -6 - 24 * 1.3)
        // 過ぎたら印は棒の高さまで戻り、そこからまた 1.5 秒持つ（以前の MiniMeters と同じ）。
        while now < 11.6 {
            now += 1.0 / 30
            B.classic(&level, db: -120, now: now, dt: 1.0 / 30)
        }
        XCTAssertLessThan(level.peak, -6 - 24 * 1.4)
        XCTAssertGreaterThanOrEqual(level.peak, level.current)
    }

    func testEffeTuneHoldsOneSecondThenFallsAndNeverGoesBelowCurrent() {
        var level = B.Level(floor: B.effetuneFloor)
        B.effetune(&level, db: -6, now: 0, dt: 0.033)
        XCTAssertEqual(level.peak, -6)
        var now = 0.0
        while now < 0.95 {
            now += 1.0 / 60
            B.effetune(&level, db: -96, now: now, dt: 1.0 / 60)
            XCTAssertGreaterThanOrEqual(level.peak, level.current)
        }
        XCTAssertEqual(level.peak, -6, "1 秒までは持つ")
        let heldAt = level.peak
        while now < 1.5 {
            now += 1.0 / 60
            B.effetune(&level, db: -96, now: now, dt: 1.0 / 60)
            XCTAssertGreaterThanOrEqual(level.peak, level.current)
        }
        XCTAssertLessThan(level.peak, heldAt)
        // 20dB/秒で落ちる。1.0 秒を過ぎてから約 0.5 秒で約 10dB。
        XCTAssertEqual(Double(level.peak), -6 - 20 * (now - 1.0), accuracy: 1.0)
        // 新しい高い音が来たら即座に追いつく。
        B.effetune(&level, db: -2, now: now, dt: 1.0 / 60)
        XCTAssertEqual(level.current, -2)
        XCTAssertEqual(level.peak, -2)
    }

    func testVUNeedleStepResponse() {
        var needle = ETVUNeedle(rate: 48000)
        var peak = 0.0
        var at300ms = 0.0
        for i in 1...48000 {
            needle.step(detected: 1)
            peak = max(peak, needle.level)
            if i == 14400 { at300ms = needle.level }
        }
        XCTAssertEqual(at300ms, 0.99, accuracy: 0.005, "300ms で 99%")
        XCTAssertEqual(peak, 1.0125, accuracy: 0.002, "行き過ぎ 1.25%")
        XCTAssertEqual(needle.level, 1.0, accuracy: 1e-3, "落ち着いたら 1")
    }

    func testVUNeedleReadsASineAtItsPeak() {
        var needle = ETVUNeedle(rate: 48000)
        for i in 0..<96000 {
            needle.feed(Float(sin(2 * Double.pi * 1000 * Double(i) / 48000)))
        }
        // 満点の正弦は 0dBFS と読める（整流平均 × π/2）。
        XCTAssertEqual(needle.db, 0, accuracy: 0.1)
        needle.reset()
        XCTAssertEqual(needle.level, 0)
        XCTAssertEqual(needle.db, -240, accuracy: 1e-3)
    }
}
