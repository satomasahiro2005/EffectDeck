//  GroupDelayEQDesignTests.swift
//  Group Delay EQ の設計（GroupDelayEQDesign）。**実機もエンジンも要らない。**
//
//  約束は 2 つ。
//    1. 目標の曲線と、有限の taps へ落とした全域通過 FIR が上流の design-core.js と同じ。
//       見本は上流の JS が吐いたもの（DesignersBGolden.swift の頭を参照）。
//    2. 遅延の頭打ち（設計の上限と、画面のスライダの 0.1ms 刻みの上限）と、
//       帯のあいだの曲線が行き過ぎないこと（Fritsch-Carlson の傾き）。

import XCTest
import Foundation

final class GroupDelayEQDesignTests: XCTestCase {

    // MARK: - 傾き

    /// Fritsch-Carlson の傾き。端は割線、山と谷と平らな所は 0、ほかは重みつきの調和平均。
    func testMonotoneSlopes() {
        // 2 点なら両端とも割線。
        XCTAssertEqual(GroupDelayEQDesign.monotoneSlopes(positions: [0, 2], values: [1, 5]), [2, 2])

        // 割線 1 と 2、等間隔: 重みはどちらも 3 なので 6 / (3/1 + 3/2) = 4/3。
        let rising = GroupDelayEQDesign.monotoneSlopes(positions: [0, 1, 2], values: [0, 1, 3])
        XCTAssertEqual(rising[0], 1, accuracy: 1e-15)
        XCTAssertEqual(rising[1], 4.0 / 3.0, accuracy: 1e-15)
        XCTAssertEqual(rising[2], 2, accuracy: 1e-15)

        // 山（符号が変わる所）は 0。
        let peak = GroupDelayEQDesign.monotoneSlopes(positions: [0, 1, 2, 3, 4], values: [0, 1, 2, 1, 0])
        XCTAssertEqual(peak[2], 0)
        XCTAssertGreaterThan(peak[1], 0)
        XCTAssertLessThan(peak[3], 0)

        // 平らな区間に接する点も 0（割線の積が 0）。
        let flat = GroupDelayEQDesign.monotoneSlopes(positions: [0, 1, 2, 3], values: [0, 1, 1, 2])
        XCTAssertEqual(flat[1], 0)
        XCTAssertEqual(flat[2], 0)

        // 不等間隔（帯は対数で並ぶ）: 重みは 2h1+h0 と h1+2h0。
        let uneven = GroupDelayEQDesign.monotoneSlopes(positions: [0, 1, 3], values: [0, 2, 3])
        let left = 2.0 * 2 + 1, right = 2.0 + 2 * 1
        XCTAssertEqual(uneven[1], (left + right) / (left / 2 + right / 0.5), accuracy: 1e-15)

        // 1 点以下は 0 が並ぶだけ（落ちない）。
        XCTAssertEqual(GroupDelayEQDesign.monotoneSlopes(positions: [1], values: [3]), [0])
        XCTAssertEqual(GroupDelayEQDesign.monotoneSlopes(positions: [], values: []), [])
    }

    /// 帯の値が単調なら、帯のあいだの曲線はその 2 つの値の外へ出ない。
    func testTargetCurveDoesNotOvershoot() {
        let values: [Double] = [1, 1, 1.5, 3, 3.2, 3.2, 3.3, 8, 8, 8.1, 9, 9, 9, 9, 9]
        let curve = GroupDelayEQDesign.makeTargetCurve(delaysMs: values, sampleRate: 48000)
        let bands = GroupDelayEQDesign.bands
        for band in 0..<(bands.count - 1) {
            let low = min(values[band], values[band + 1])
            let high = max(values[band], values[band + 1])
            for step in 0...40 {
                let frequency = bands[band] * pow(bands[band + 1] / bands[band], Double(step) / 40)
                // 16kHz より上はフェードで 0 へ落とすので、帯のあいだだけ見る。
                guard frequency <= curve.fadeStart else { continue }
                let value = curve.value(at: frequency)
                XCTAssertGreaterThanOrEqual(value, low - 1e-12, "\(frequency) Hz")
                XCTAssertLessThanOrEqual(value, high + 1e-12, "\(frequency) Hz")
            }
        }
        // 一番下の帯より下は値を保ち、フェードの終わり（0.9 Nyquist か 20kHz）から先は 0。
        XCTAssertEqual(curve.value(at: 0), values[0])
        XCTAssertEqual(curve.value(at: 10), values[0])
        XCTAssertEqual(curve.value(at: curve.fadeEnd), 0)
        XCTAssertEqual(curve.fadeEnd, 20000)
        let low = GroupDelayEQDesign.makeTargetCurve(delaysMs: values, sampleRate: 32000)
        XCTAssertEqual(low.fadeEnd, 14400, accuracy: 1e-9)
        XCTAssertEqual(low.fadeStart, 12960, accuracy: 1e-9)
    }

    // MARK: - 頭打ち

    /// taps の半分から guard（taps/16）を引いた分まで。無い帯・NaN・無限大は 0 に落ち、
    /// それは「切った」に数えない。ちょうど上限は切らない。
    func testClampDelays() {
        let limit = (2048.0 - 256) * 1000 / 48000
        let clamped = GroupDelayEQDesign.clampDelays([50, -50, .nan, .infinity, 10, limit],
                                                     taps: 4096, sampleRate: 48000)
        XCTAssertEqual(clamped.limitMs, limit, accuracy: 1e-12)
        XCTAssertTrue(clamped.clamped)
        XCTAssertEqual(clamped.valuesMs.count, 15)
        XCTAssertEqual(Array(clamped.valuesMs.prefix(6)), [limit, -limit, 0, 0, 10, limit])
        XCTAssertEqual(Array(clamped.valuesMs.suffix(9)), [Double](repeating: 0, count: 9))

        let inside = GroupDelayEQDesign.clampDelays([.nan, limit, -limit, 1], taps: 4096, sampleRate: 48000)
        XCTAssertFalse(inside.clamped)
        XCTAssertEqual(Array(inside.valuesMs.prefix(4)), [0, limit, -limit, 1])

        // 長い配列の 16 本目以降は見ない。
        let long = GroupDelayEQDesign.clampDelays([Double](repeating: 1, count: 15) + [1000],
                                                  taps: 4096, sampleRate: 48000)
        XCTAssertFalse(long.clamped)
    }

    /// 画面の上限は 0.1ms に切り捨て。設計の上限を超えない。
    func testUIDelayLimitMs() {
        XCTAssertEqual(GroupDelayEQDesign.uiDelayLimitMs(taps: 4096, sampleRate: 48000), 37.3)
        XCTAssertEqual(GroupDelayEQDesign.uiDelayLimitMs(taps: 8192, sampleRate: 48000), 74.6)   // 74.66…
        XCTAssertEqual(GroupDelayEQDesign.uiDelayLimitMs(taps: 16384, sampleRate: 44100), 162.5) // 162.53…
        XCTAssertEqual(GroupDelayEQDesign.uiDelayLimitMs(taps: 32768, sampleRate: 96000), 149.3)
        for taps in GroupDelayEQDesign.tapsChoices {
            for rate in [44100.0, 48000, 88200, 96000, 192000] {
                let ui = GroupDelayEQDesign.uiDelayLimitMs(taps: taps, sampleRate: rate)
                let design = GroupDelayEQDesign.clampDelays([], taps: taps, sampleRate: rate).limitMs
                XCTAssertLessThanOrEqual(ui, design, "\(taps) @ \(rate)")
                XCTAssertGreaterThan(ui, design - 0.1, "\(taps) @ \(rate)")
            }
        }
    }

    // MARK: - 上流の見本

    /// 目標の群遅延（groupDelayTargetMs）。FFT を通らないので 1e-12 で一致する。
    func testTargetMsMatchesUpstream() throws {
        let golden = try DesignersBGolden.load()
        XCTAssertGreaterThanOrEqual(golden.groupDelayEq.targets.count, 4)
        for target in golden.groupDelayEq.targets {
            let values = GroupDelayEQDesign.targetMs(delaysMs: target.delaysMs,
                                                     taps: target.taps,
                                                     sampleRate: target.sampleRate,
                                                     frequencies: target.frequencies?.doubles)
            let diff = DesignersBGolden.maxAbsDiff(values, target.expected.doubles)
            XCTAssertLessThanOrEqual(diff, 1e-12, target.name)
        }
    }

    /// 設計した FIR・うねり・群遅延の曲線が上流と同じ。
    /// 係数は Float へ落ちた値で比べる（1 ulp ぶんの違いは FFT の実装の違いで出る）。
    func testDesignMatchesUpstream() throws {
        let golden = try DesignersBGolden.load()
        XCTAssertGreaterThanOrEqual(golden.groupDelayEq.designs.count, 3)
        var worst = (ir: 0.0, ripple: 0.0, curve: 0.0)
        for entry in golden.groupDelayEq.designs {
            let filter = try GroupDelayEQDesign.design(delaysMs: entry.delaysMs,
                                                       taps: entry.taps,
                                                       sampleRate: entry.sampleRate)
            let e = entry.expected
            XCTAssertEqual(filter.taps, entry.taps, entry.name)
            XCTAssertEqual(filter.bulkDelaySamples, e.bulkDelaySamples, entry.name)
            XCTAssertEqual(filter.clamped, e.clamped, entry.name)
            XCTAssertEqual(filter.limitMs, e.limitMs, accuracy: 1e-12, entry.name)

            let ir = DesignersBGolden.maxAbsDiff(filter.ir, e.ir.floats)
            XCTAssertLessThanOrEqual(ir, 1e-6, "\(entry.name) ir")
            let ripple = abs(filter.rippleDb - e.rippleDb)
            XCTAssertLessThanOrEqual(ripple, 1e-5, "\(entry.name) ripple \(filter.rippleDb) vs \(e.rippleDb)")

            XCTAssertLessThanOrEqual(DesignersBGolden.maxAbsDiff(filter.response.frequencies, e.frequencies.doubles),
                                     1e-9, "\(entry.name) frequencies")
            XCTAssertLessThanOrEqual(DesignersBGolden.maxAbsDiff(filter.response.targetMs, e.targetMs.doubles),
                                     1e-12, "\(entry.name) target")
            let curve = DesignersBGolden.maxAbsDiff(filter.response.realizedMs, e.realizedMs.doubles)
            XCTAssertLessThanOrEqual(curve, 1e-5, "\(entry.name) realized")
            worst = (max(worst.ir, ir), max(worst.ripple, ripple), max(worst.curve, curve))
        }
        print("GroupDelayEQ golden: ir \(worst.ir), ripple \(worst.ripple) dB, realized \(worst.curve) ms")
    }

    // MARK: - 入口の検査

    func testDesignRejectsBadInput() {
        XCTAssertThrowsError(try GroupDelayEQDesign.design(delaysMs: [1], taps: 1000)) {
            guard case GroupDelayEQDesignError.unsupportedTaps = $0 else { return XCTFail("\($0)") }
        }
        for rate in [0.0, -48000, .nan, .infinity] {
            XCTAssertThrowsError(try GroupDelayEQDesign.design(delaysMs: [1], taps: 4096, sampleRate: rate)) {
                guard case GroupDelayEQDesignError.invalidSampleRate = $0 else { return XCTFail("\($0)") }
            }
        }
        XCTAssertThrowsError(try GroupDelayEQDesign.design(delaysMs: [1], taps: 4096,
                                                           isCancelled: { true })) {
            guard case GroupDelayEQDesignError.cancelled = $0 else { return XCTFail("\($0)") }
        }
    }

    /// 全部 0 ms なら taps/2 の位置の単位インパルス（純粋な遅延）になる。
    func testZeroDelaysGiveCenteredImpulse() throws {
        let filter = try GroupDelayEQDesign.design(delaysMs: [Double](repeating: 0, count: 15),
                                                   taps: 4096, sampleRate: 48000)
        XCTAssertEqual(filter.ir.count, 4096)
        XCTAssertEqual(filter.ir[2048], 1, accuracy: 1e-6)
        var rest = 0.0
        for (index, value) in filter.ir.enumerated() where index != 2048 { rest = max(rest, abs(Double(value))) }
        XCTAssertLessThan(rest, 1e-6)
        XCTAssertLessThan(filter.rippleDb, 1e-6)
        XCTAssertFalse(filter.clamped)
    }

    // MARK: - 注意書き

    /// 切った注意が先、うねり 0.3dB を超えたらその次。どちらでもなければ無い。
    func testQualityWarning() {
        func filter(clamped: Bool, ripple: Double) -> GroupDelayEQDesign.Filter {
            GroupDelayEQDesign.Filter(ir: [], bulkDelaySamples: 0, clamped: clamped, limitMs: 37.333,
                                      rippleDb: ripple,
                                      response: .init(frequencies: [], targetMs: [], realizedMs: []),
                                      taps: 4096, sampleRate: 48000)
        }
        XCTAssertEqual(GroupDelayEQDesign.qualityWarning(for: filter(clamped: true, ripple: 5)),
                       "This Taps setting cannot reach the requested delay. The filter uses up to 37.3 ms.")
        XCTAssertEqual(GroupDelayEQDesign.qualityWarning(for: filter(clamped: false, ripple: 0.31)),
                       "The filter cannot follow these settings closely. "
                       + "Increase Taps or reduce the difference between neighbouring bands.")
        XCTAssertNil(GroupDelayEQDesign.qualityWarning(for: filter(clamped: false, ripple: 0.3)))
    }
}
