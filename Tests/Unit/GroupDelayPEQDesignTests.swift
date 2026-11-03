//  GroupDelayPEQDesignTests.swift
//  Group Delay PEQ の設計（GroupDelayPEQDesign.swift）。**実機もエンジンも要らない。**
//
//  約束は 2 つ。
//    1. 目標の曲線（4 つの形の和・±限界での頭打ち・Nyquist 手前のフェード）と、
//       有限の taps へ落とした全域通過 FIR が上流の design-core.js と同じ。
//    2. 設定の側の決まり: 限界は 0.1ms 刻みの切り捨て、taps やレートを変えたら切り詰める、
//       latency と処理幅だけの変化では設計し直さない、headBlock は受け付ける値へ寄せる。

import XCTest
import Foundation

final class GroupDelayPEQDesignTests: XCTestCase {

    private func settings(taps: Int = 16384,
                          latency: Int = 128,
                          sampleRate: Double = 48000,
                          bands: [GroupDelayPEQBand] = GroupDelayPEQSettings.defaultBands,
                          channels: Int = 2) -> GroupDelayPEQSettings {
        GroupDelayPEQSettings(bands: bands, taps: taps, latencySamples: latency,
                              sampleRate: sampleRate, processingChannels: channels)
    }

    // MARK: - 設定の決まり

    /// taps/2 - taps/16 をミリ秒にして 0.1ms に切り捨てる（丸めない）。
    func testDelayLimitRoundsDown0_1ms() {
        XCTAssertEqual(settings(taps: 4096).delayLimitMs, 37.3)                        // 37.33…
        XCTAssertEqual(settings(taps: 8192).delayLimitMs, 74.6)                        // 74.66…（74.7 ではない）
        XCTAssertEqual(settings(taps: 16384, sampleRate: 44100).delayLimitMs, 162.5)   // 162.53…
        XCTAssertEqual(settings(taps: 32768, sampleRate: 96000).delayLimitMs, 149.3)   // 149.33…
        // 設計が言う限界（design の limitMs）と同じ数。
        for taps in GroupDelayPEQDesignCore.tapsChoices {
            let values = GroupDelayPEQDesignCore.targetMs(
                bands: [GroupDelayPEQBand(frequency: 100, delayMs: 1e9)],
                taps: taps, sampleRate: 48000, frequencies: [100])
            XCTAssertEqual(values[0], settings(taps: taps).delayLimitMs, accuracy: 1e-12, "\(taps)")
        }
    }

    /// 限界の外の遅延だけを ±限界へ寄せる。切ってあるバンドも寄せる（あとで入れ直したときのため）。
    func testClampingToLimit() {
        let bands = [
            GroupDelayPEQBand(frequency: 100, delayMs: 50),
            GroupDelayPEQBand(frequency: 316, delayMs: -50),
            GroupDelayPEQBand(frequency: 1000, delayMs: 37.3),
            GroupDelayPEQBand(frequency: 3160, delayMs: -2.5),
            GroupDelayPEQBand(frequency: 10000, delayMs: 99, enabled: false)
        ]
        let clamped = settings(taps: 4096, bands: bands).clampingDelaysToLimit()
        XCTAssertEqual(clamped.bands.map(\.delayMs), [37.3, -37.3, 37.3, -2.5, 37.3])
        XCTAssertEqual(clamped.bands.map(\.frequency), bands.map(\.frequency))
        XCTAssertEqual(clamped.bands.map(\.enabled), bands.map(\.enabled))
        // 他の設定は触らない。
        XCTAssertEqual(clamped.taps, 4096)
        XCTAssertEqual(clamped.latencySamples, 128)
    }

    /// 係数が変わるのはバンド・taps・レートだけ。latency と処理幅は送り直しで済む。
    func testRequiresRedesign() {
        let base = settings()
        XCTAssertFalse(base.requiresRedesign(comparedTo: base))
        XCTAssertFalse(settings(latency: 512).requiresRedesign(comparedTo: base))
        XCTAssertFalse(settings(channels: 1).requiresRedesign(comparedTo: base))
        XCTAssertTrue(settings(taps: 8192).requiresRedesign(comparedTo: base))
        XCTAssertTrue(settings(sampleRate: 44100).requiresRedesign(comparedTo: base))
        var band = base
        band.bands[2].q = 2
        XCTAssertTrue(band.requiresRedesign(comparedTo: base))
        var off = base
        off.bands[0].enabled = false
        XCTAssertTrue(off.requiresRedesign(comparedTo: base))
    }

    /// headBlock は 0/128/256/512/1024 だけ。外れた値は 128 に寄せる（カーネルが弾くので）。
    func testHeadBlockFallback() {
        for value in GroupDelayPEQDesignCore.latencyChoices {
            XCTAssertEqual(settings(latency: value).headBlock, UInt32(value))
        }
        for value in [-1, 1, 64, 127, 2048] {
            XCTAssertEqual(settings(latency: value).headBlock, 128, "\(value)")
        }
    }

    /// 送る処理幅は 1〜16 に収める。申告する遅延は latency + taps/2。
    func testProcessingChannelsAndReportedLatency() {
        XCTAssertEqual(settings(channels: 0).assetProcessingChannels, 1)
        XCTAssertEqual(settings(channels: 2).assetProcessingChannels, 2)
        XCTAssertEqual(settings(channels: 17).assetProcessingChannels, 16)
        XCTAssertEqual(settings(taps: 8192, latency: 256).reportedLatencySamples, 256 + 4096)
    }

    /// 遅延を頼んでいるのは「有効で 0 でない」バンドがあるときだけ。
    func testHasDelay() {
        XCTAssertFalse(settings().hasDelay)
        XCTAssertFalse(settings(bands: [GroupDelayPEQBand(frequency: 100, delayMs: 3, enabled: false)]).hasDelay)
        XCTAssertTrue(settings(bands: [GroupDelayPEQBand(frequency: 100, delayMs: -0.1)]).hasDelay)
    }

    // MARK: - 上流の見本

    private func bands(_ golden: [DesignersBGolden.PEQBand]) throws -> [GroupDelayPEQBand] {
        try golden.map { band in
            let shape = try XCTUnwrap(GroupDelayPEQBand.Shape(rawValue: band.type), band.type)
            return GroupDelayPEQBand(shape: shape, frequency: band.frequency, delayMs: band.delayMs,
                                     q: band.q, enabled: band.enabled)
        }
    }

    /// 目標の群遅延（groupDelayPeqTargetMs）。FFT を通らないので 1e-12 で一致する。
    /// 見本は 4 つの形、Q が 1/√3 の上下の FilterGD、範囲外の周波数と Q、限界を超える遅延、
    /// 和が限界を超える重なり、0 ms、切ってあるバンド、0 Hz とフェードの前後を含む。
    func testTargetMsMatchesUpstream() throws {
        let golden = try DesignersBGolden.load()
        XCTAssertGreaterThanOrEqual(golden.groupDelayPeq.targets.count, 3)
        for target in golden.groupDelayPeq.targets {
            let values = GroupDelayPEQDesignCore.targetMs(bands: try bands(target.bands),
                                                          taps: target.taps,
                                                          sampleRate: target.sampleRate,
                                                          frequencies: target.frequencies?.doubles)
            let diff = DesignersBGolden.maxAbsDiff(values, target.expected.doubles)
            XCTAssertLessThanOrEqual(diff, 1e-12, target.name)
        }
    }

    /// 設計した FIR・暴れ・群遅延の曲線と、切ったかどうか（和の頭打ちも数える）が上流と同じ。
    func testDesignMatchesUpstream() throws {
        let golden = try DesignersBGolden.load()
        XCTAssertGreaterThanOrEqual(golden.groupDelayPeq.designs.count, 2)
        var worst = (ir: 0.0, ripple: 0.0, curve: 0.0)
        for entry in golden.groupDelayPeq.designs {
            let input = settings(taps: entry.taps, sampleRate: entry.sampleRate, bands: try bands(entry.bands))
            let design = try GroupDelayPEQDesignCore.design(settings: input)
            let e = entry.expected
            XCTAssertEqual(Double(design.bulkDelaySamples), e.bulkDelaySamples, entry.name)
            XCTAssertEqual(design.clamped, e.clamped, entry.name)
            XCTAssertEqual(design.limitMs, e.limitMs, entry.name)

            let ir = DesignersBGolden.maxAbsDiff(design.ir, e.ir.floats)
            XCTAssertLessThanOrEqual(ir, 1e-6, "\(entry.name) ir")
            let ripple = abs(design.rippleDb - e.rippleDb)
            XCTAssertLessThanOrEqual(ripple, 1e-5, "\(entry.name) ripple \(design.rippleDb) vs \(e.rippleDb)")
            XCTAssertLessThanOrEqual(DesignersBGolden.maxAbsDiff(design.response.frequencies, e.frequencies.doubles),
                                     1e-9, "\(entry.name) frequencies")
            XCTAssertLessThanOrEqual(DesignersBGolden.maxAbsDiff(design.response.targetMs, e.targetMs.doubles),
                                     1e-12, "\(entry.name) target")
            let curve = DesignersBGolden.maxAbsDiff(design.response.realizedMs, e.realizedMs.doubles)
            XCTAssertLessThanOrEqual(curve, 1e-5, "\(entry.name) realized")
            worst = (max(worst.ir, ir), max(worst.ripple, ripple), max(worst.curve, curve))
        }
        print("GroupDelayPEQ golden: ir \(worst.ir), ripple \(worst.ripple) dB, realized \(worst.curve) ms")
    }

    /// 図の横軸は 10Hz〜min(40kHz, 0.45fs) の 128 点。
    func testResponseFrequencies() {
        let grid = GroupDelayPEQDesignCore.responseFrequencies(sampleRate: 48000)
        XCTAssertEqual(grid.count, 128)
        XCTAssertEqual(grid[0], 10, accuracy: 1e-12)
        XCTAssertEqual(grid[127], 21600, accuracy: 1e-9)
        XCTAssertEqual(GroupDelayPEQDesignCore.responseFrequencies(sampleRate: 192000)[127], 40000, accuracy: 1e-9)
    }

    // MARK: - 入口の検査

    func testDesignRejectsBadInput() {
        XCTAssertThrowsError(try GroupDelayPEQDesignCore.design(settings: settings(taps: 1000))) {
            guard case GroupDelayPEQDesignError.unsupportedTaps(1000) = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try GroupDelayPEQDesignCore.design(settings: settings(sampleRate: .nan))) {
            guard case GroupDelayPEQDesignError.invalidSampleRate = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try GroupDelayPEQDesignCore.design(settings: settings(taps: 4096),
                                                                shouldStop: { true })) {
            guard case GroupDelayPEQDesignError.cancelled = $0 else { return XCTFail("\($0)") }
        }
    }

    // MARK: - 注意書き

    func testQualityWarning() {
        func design(clamped: Bool, ripple: Double) -> GroupDelayPEQDesign {
            GroupDelayPEQDesign(ir: [], bulkDelaySamples: 2048, clamped: clamped, limitMs: 37.3,
                                rippleDb: ripple,
                                response: .init(frequencies: [], targetMs: [], realizedMs: []))
        }
        XCTAssertEqual(GroupDelayPEQDesignCore.qualityWarning(for: design(clamped: true, ripple: 9)),
                       "This tap count cannot reach the requested delay. The filter uses up to 37.3 ms.")
        XCTAssertEqual(GroupDelayPEQDesignCore.qualityWarning(for: design(clamped: false, ripple: 0.4)),
                       "The filter cannot follow these settings closely. Increase the tap count or reduce Q.")
        XCTAssertNil(GroupDelayPEQDesignCore.qualityWarning(for: design(clamped: false, ripple: 0.3)))
    }
}
