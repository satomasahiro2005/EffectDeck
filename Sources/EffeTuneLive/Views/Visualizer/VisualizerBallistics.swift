//  VisualizerBallistics.swift
//  メーターの落ち方と、VU の針。Foundation だけ（Tests/Unit/VisualizerBallisticsTests.swift）。
//
//  **落ちる速さは時間（dt）で決める。**画面が 30Hz でも 60Hz でも同じ速さで落ちる
//  （1/60 秒を 2 回と 1/30 秒を 1 回は同じ）。以前は 1 回ごとに 1.5dB 落としていた。
//
//  VU の針は上流の analog_meter/kernel.cpp（designNeedle・advanceNeedle）の写し。

import Foundation

enum ETVisualizerBallistics {

    /// 値が落ちていく。入力のほうが高ければ入力へ、低ければ `rate`（dB/秒）で `dt` 秒ぶん落ちる。床より下へは行かない。
    static func fall(_ value: Float, input: Float, rate: Float, dt: Float, floor: Float) -> Float {
        max(input, value - rate * max(dt, 0), floor)
    }

    /// 1 つのメーターの状態。`current` は棒の高さ、`peak` は印（ホールドして落ちる）。
    struct Level: Equatable {
        var current: Float
        var peak: Float
        var holdUntil: Double = 0

        init(floor: Float) {
            current = floor
            peak = floor
        }
    }

    // MARK: Classic（Floating Meters の今の動き）

    static let classicFall: Float = 24
    static let classicHold = 1.5
    static let classicFloor: Float = -120

    /// 24dB/秒で落ち、印は 1.5 秒持ってから今の高さへ戻る（以前の MiniMeters と同じ）。
    static func classic(_ level: inout Level, db: Float, now: Double, dt: Float) {
        level.current = fall(level.current, input: db, rate: classicFall, dt: dt, floor: classicFloor)
        if db >= level.peak || now > level.holdUntil {
            level.peak = max(db, level.current)
            level.holdUntil = now + classicHold
        }
    }

    // MARK: EffeTune（上流の Level Meter）

    static let effetuneFall: Float = 20
    static let effetuneHold = 1.0
    static let effetuneFloor: Float = -96

    /// 上がるのは即座、落ちるのは 20dB/秒。印は 1 秒持ってから 20dB/秒で落ち、今の高さより下へは行かない。
    static func effetune(_ level: inout Level, db: Float, now: Double, dt: Float) {
        level.current = fall(level.current, input: db, rate: effetuneFall, dt: dt, floor: effetuneFloor)
        if level.current >= level.peak {
            level.peak = level.current
            level.holdUntil = now + effetuneHold
        } else if now > level.holdUntil {
            level.peak = max(level.peak - effetuneFall * max(dt, 0), level.current, effetuneFloor)
        }
    }
}

/// VU の針（IEC 60268-17。ステップ応答が 300ms で 99%、行き過ぎは 1.25%）。
/// 2 次系で、減衰比が行き過ぎを、正規化した 99% 時間が固有周波数を決める。
/// 入力は整流して π/2 を掛ける（整流平均 × 正弦の波形率で、正弦の最大値どおりに読める）。
struct ETVUNeedle {

    static let damping = 0.81271698642867751
    static let normalized99 = 4.0535737687598132
    static let riseTime = 0.3

    private var a1 = 0.0
    private var a2 = 0.0
    private var gain = 1.0
    private var y1 = 0.0
    private var y2 = 0.0

    init(rate: Double) {
        design(rate: rate)
    }

    /// kernel.cpp の designNeedle。
    private mutating func design(rate: Double) {
        let period = 1.0 / rate
        let natural = Self.normalized99 / Self.riseTime
        let radius = exp(-Self.damping * natural * period)
        a1 = -2.0 * radius * cos(natural * (1.0 - Self.damping * Self.damping).squareRoot() * period)
        a2 = radius * radius
        gain = 1.0 + a1 + a2
    }

    mutating func reset() {
        y1 = 0
        y2 = 0
    }

    /// kernel.cpp の advanceNeedle。`detected` は整流して π/2 を掛けたあとの値。
    mutating func step(detected: Double) {
        let y = gain * detected - a1 * y1 - a2 * y2
        y2 = y1
        y1 = y
    }

    /// 標本を 1 つ聞かせる。
    mutating func feed(_ sample: Float) {
        step(detected: Double(abs(sample)) * Double.pi / 2)
    }

    /// 針の位置（線形）。
    var level: Double { y1 }

    /// 針の dBFS（-240 より下は切る）。
    var db: Float { Float(20 * log10(max(y1, 1e-12))) }
}
