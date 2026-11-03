//  PowerGateTests.swift
//  無音で演算を休む判断（PowerGate / ETPowerMode）。
//
//  壊れると: 静かな箇所でエフェクトが止まる（休むのが早すぎる）か、
//  いつまでも止まらずに電池を食う（休まない）。音のスレッドでしか動かないので、
//  実機で気づくのは「なんとなく電池が減る」まで遅れる。

import XCTest

final class PowerGateTests: XCTestCase {

    private func gate(idle: Double, threshold: Float = 0.0001) -> PowerGate {
        var g = PowerGate()
        g.idleSeconds = idle
        g.thresholdLinear = threshold
        return g
    }

    // MARK: - 休む

    /// 無音がちょうど idleSeconds 溜まったブロックで休む（>= で比べている）。
    func testRestsAtExactlyIdleSeconds() {
        var g = gate(idle: 1.0)
        XCTAssertTrue(g.update(peak: 0, seconds: 0.25))
        XCTAssertTrue(g.update(peak: 0, seconds: 0.25))
        XCTAssertTrue(g.update(peak: 0, seconds: 0.25))
        XCTAssertFalse(g.resting)
        XCTAssertFalse(g.update(peak: 0, seconds: 0.25), "1.0 秒ちょうどで休む")
        XCTAssertTrue(g.resting)
    }

    /// 実際のブロック（512 フレーム / 48kHz）で数える。1 秒を跨いだブロックで休む。
    func testRestsOnTheBlockThatCrossesIdleSeconds() {
        var g = gate(idle: 1.0)
        let block = 512.0 / 48000.0
        var blocks = 0
        while g.update(peak: 0, seconds: block) { blocks += 1 }
        // 1 / (512/48000) = 93.75 → 94 本目で休む。
        XCTAssertEqual(blocks + 1, 94)
    }

    /// 休んだあとも無音なら休んだまま。
    func testStaysRestingWhileSilent() {
        var g = gate(idle: 0.5)
        _ = g.update(peak: 0, seconds: 0.5)
        for _ in 0..<1000 { XCTAssertFalse(g.update(peak: 0, seconds: 0.01)) }
    }

    // MARK: - 起きる

    /// 休んでいても、閾値を超えた最初のブロックで起きる。
    func testWakesOnTheFirstLoudBlock() {
        var g = gate(idle: 0.5)
        _ = g.update(peak: 0, seconds: 1)
        XCTAssertTrue(g.resting)
        XCTAssertTrue(g.update(peak: 0.5, seconds: 0.01))
        XCTAssertFalse(g.resting)
    }

    /// 音が来たら無音の積み上げは 0 に戻る。次に休むにはもう 1 回 idleSeconds 要る。
    func testLoudBlockRestartsTheCount() {
        var g = gate(idle: 1.0)
        _ = g.update(peak: 0, seconds: 0.75)
        _ = g.update(peak: 0.5, seconds: 0.01)
        XCTAssertTrue(g.update(peak: 0, seconds: 0.75), "0.75 秒ではまだ休まない")
        XCTAssertFalse(g.update(peak: 0, seconds: 0.25))
    }

    /// 閾値ちょうどは無音（> で比べている）。わずかに上なら音。
    func testThresholdIsExclusive() {
        var g = gate(idle: 0.1, threshold: 0.01)
        XCTAssertFalse(g.update(peak: 0.01, seconds: 0.1), "閾値ちょうどは無音として数える")
        XCTAssertTrue(g.update(peak: 0.0101, seconds: 0.01))
    }

    // MARK: - 例外の値

    /// .continuous は idleSeconds が無限なので、どれだけ無音が続いても休まない。
    func testContinuousNeverRests() {
        var g = gate(idle: ETPowerMode.continuous.idleSeconds)
        for _ in 0..<10_000 { XCTAssertTrue(g.update(peak: 0, seconds: 3600)) }
        XCTAssertFalse(g.resting)
    }

    /// NaN のピークは無音として数える（起こさない）。起きている間に NaN が来ても
    /// 無音の積み上げが進み、idleSeconds で休む。
    func testNaNCountsAsSilence() {
        var g = gate(idle: 0.5)
        XCTAssertTrue(g.update(peak: .nan, seconds: 0.25))
        XCTAssertFalse(g.update(peak: .nan, seconds: 0.25))
        XCTAssertTrue(g.resting)
        XCTAssertFalse(g.update(peak: .nan, seconds: 0.01), "NaN では起きない")
    }

    // MARK: - モード

    func testModeIdleSeconds() {
        XCTAssertEqual(ETPowerMode.continuous.idleSeconds, .infinity)
        XCTAssertEqual(ETPowerMode.balanced.idleSeconds, 3.0)
        XCTAssertEqual(ETPowerMode.maximum.idleSeconds, 1.0)
    }

    /// 保存値（Preferences の pref.power）が変わると既定の Balanced に戻ってしまう。
    func testModeRawValuesAreStable() {
        XCTAssertEqual(ETPowerMode.allCases.map(\.rawValue), ["continuous", "balanced", "maximum"])
        for m in ETPowerMode.allCases {
            XCTAssertEqual(ETPowerMode(rawValue: m.rawValue), m)
            XCTAssertEqual(m.id, m.rawValue)
            XCTAssertFalse(m.label.isEmpty)
            XCTAssertFalse(m.note.isEmpty)
        }
    }

    /// 画面の選択肢は秒そのもの。idleSeconds と食い違わないこと。
    func testLabelsMatchSeconds() {
        XCTAssertEqual(ETPowerMode.balanced.label, "3 s")
        XCTAssertEqual(ETPowerMode.maximum.label, "1 s")
        XCTAssertEqual(ETPowerMode.continuous.label, "Never")
    }

    // MARK: - AudioIO が組むときの値

    func testLinearThreshold() {
        XCTAssertEqual(PowerGate.linearThreshold(decibels: -80), 0.0001, accuracy: 1e-9)
        XCTAssertEqual(PowerGate.linearThreshold(decibels: -20), 0.1, accuracy: 1e-7)
        XCTAssertEqual(PowerGate.linearThreshold(decibels: 0), 1)
        XCTAssertEqual(PowerGate().thresholdLinear, PowerGate.linearThreshold(decibels: -80),
                       accuracy: 1e-9, "既定は -80dB")
    }

    /// 外部処理の尾が選んだ秒数より長ければそちらに合わせる（リバーブの残響を切らない）。
    func testExternalTailExtendsIdle() {
        XCTAssertEqual(PowerGate.idleSeconds(mode: .maximum, externalTail: 0), 1)
        XCTAssertEqual(PowerGate.idleSeconds(mode: .maximum, externalTail: 5), 5)
        XCTAssertEqual(PowerGate.idleSeconds(mode: .balanced, externalTail: 2), 3)
        XCTAssertEqual(PowerGate.idleSeconds(mode: .continuous, externalTail: 5), .infinity)
        XCTAssertEqual(PowerGate.idleSeconds(mode: .balanced, externalTail: .nan), 3,
                       "尾が NaN なら選んだ秒数のまま")
    }

    /// 休んでいて入力が厳密に 0 のときだけ、ブロックを丸ごと 0 で済ませる。
    /// 閾値以下の弱音は素通しで聴こえているので、ピークで抜けると消える。
    func testSkipOnlyWhenRestingAndExactlyZero() {
        XCTAssertTrue(PowerGate.canSkipBlock(awake: false, inputPeak: 0))
        XCTAssertFalse(PowerGate.canSkipBlock(awake: false, inputPeak: 1e-7))
        XCTAssertFalse(PowerGate.canSkipBlock(awake: true, inputPeak: 0))
        XCTAssertFalse(PowerGate.canSkipBlock(awake: true, inputPeak: 0.5))
    }
}
