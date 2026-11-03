//  BassManagementDesignTests.swift
//  Bass ManagementのLinear位相の設計（BassManagementDesign.swift）。**実機もエンジンも要らない。**
//  形（ペイロードの頭・経路・応答の点）を固め、上流のdesignBassManagementとdesign-worker.jsの
//  組み立てに作らせた見本（Tools/golden/designers_a_golden.mjs）と照合する。

import XCTest

final class BassManagementDesignTests: XCTestCase {

    // MARK: - 形

    /// ETA1の頭（matrix・経路の数・taps・丸めたレート）と、入力ごとの{ch, ch, 何本目}の経路、
    /// その後ろにFloatの係数がchannel-majorで並ぶ。応答は入力ごとに160点。
    func testOutputShape() throws {
        var s = BassManagementSettings()
        s.linear = true
        s.tapsIndex = 0
        s.roles = [1, 0, 1, 2] + [Int](repeating: 3, count: 12)
        s.frequencies[0] = 70
        s.frequencies[2] = 110
        s.lfeLowpass = true
        let key = s.designKey(sampleRate: 48000.4, width: 4)
        XCTAssertEqual(key.filters.map(\.channel), [0, 2, 3])

        let design = try BassManagementDesignCore.design(key)
        let n = key.filters.count
        let taps = 8192
        XCTAssertEqual(design.key, key)
        XCTAssertEqual(design.inputChannels, [0, 2, 3])
        XCTAssertEqual(design.payload.count, 32 + 12 * n + 4 * taps * n)

        let header = (0..<8).map { word(design.payload, $0 * 4) }
        XCTAssertEqual(header, [0x3141_5445, UInt32(n), UInt32(taps), 48000, 4, UInt32(n), 0, 0])
        for (index, channel) in design.inputChannels.enumerated() {
            let base = 32 + index * 12
            XCTAssertEqual([word(design.payload, base), word(design.payload, base + 4), word(design.payload, base + 8)],
                           [UInt32(channel), UInt32(channel), UInt32(index)], "経路\(index)")
        }

        XCTAssertEqual(design.responses.count, n)
        XCTAssertEqual(design.responses.map(\.count), [160, 160, 160])
        XCTAssertEqual(design.responseFrequencies.count, 160)
        XCTAssertEqual(design.responseFrequencies.first ?? 0, 10, accuracy: 1e-9)
        XCTAssertEqual(design.responseFrequencies.last ?? 0, 20000, accuracy: 1e-9)

        // 低域の線形位相なので、係数は真ん中（taps/2）で最大、DCの利得は1。
        let first = DesignerMatch.floats(in: design.payload, from: 32 + 12 * n, count: taps)
        let peak = first.indices.max { abs(first[$0]) < abs(first[$1]) }
        XCTAssertEqual(peak, taps / 2)
        XCTAssertEqual(first.reduce(0.0) { $0 + Double($1) }, 1, accuracy: 1e-4)
        XCTAssertEqual(Double(design.responses[0][0]), 1, accuracy: 1e-3, "10Hzは通す")
        XCTAssertLessThan(design.responses[0][159], 1e-3, "20kHzは落とす")
    }

    /// 応答の点は10Hzからmin(20kHz, 0.48·sr)までの対数（design-core.js:52-58）。
    func testResponseFrequenciesTopAtLowRate() {
        let low = BassManagementDesignCore.responseFrequencies(sampleRate: 8000)
        XCTAssertEqual(low.count, 160)
        XCTAssertEqual(low.last ?? 0, 3840, accuracy: 1e-9)
        let single = BassManagementDesignCore.responseFrequencies(sampleRate: 48000, count: 1)
        XCTAssertEqual(single.count, 1)
        XCTAssertEqual(single.first ?? 0, 10, accuracy: 1e-12)
        XCTAssertEqual(BassManagementDesignCore.responseFrequencies(sampleRate: 48000, count: 0), [])
    }

    // MARK: - 上流との照合

    /// 係数・応答・経路・ペイロードの頭と大きさが上流と一致する（3通り: 5.1で1つの設計を使い回す、
    /// 4chで(fc, slope)が全部違う、2chでfcとLFEの周波数が範囲の外）。
    func testDesignMatchesUpstream() throws {
        for golden in try DesignersAGolden.load().bassManagement.designs {
            let input = golden.input
            let label = input.name
            var s = BassManagementSettings()
            s.linear = true
            s.tapsIndex = input.tapsIndex
            for (ch, role) in input.roles.enumerated() { s.roles[ch] = role }
            for (ch, frequency) in input.frequencies.enumerated() { s.frequencies[ch] = frequency }
            for (ch, slope) in input.slopes.enumerated() { s.slopes[ch] = slope }
            s.lfeLowpass = input.lfeLowpass
            s.lfeFrequency = input.lfeFrequency
            s.lfeSlope = input.lfeSlope

            let key = s.designKey(sampleRate: input.sampleRate, width: input.width)
            XCTAssertEqual(key.sampleRate, golden.sampleRate, "\(label) sampleRate")
            XCTAssertEqual(key.taps, golden.taps, "\(label) taps")
            let design = try BassManagementDesignCore.design(key)
            XCTAssertEqual(design.inputChannels, golden.inputChannels, "\(label) 入力")

            XCTAssertEqual(design.responseFrequencies.count, golden.responseFrequencies.count, label)
            for (a, e) in zip(design.responseFrequencies, golden.responseFrequencies) {
                XCTAssertTrue(DesignerMatch.close(a, e, relative: 1e-12), "\(label) 応答の点 \(a)、上流は \(e)")
            }
            XCTAssertEqual(design.responses.count, golden.responses.count, "\(label) 応答の本数")
            for (index, (response, expected)) in zip(design.responses, golden.responses).enumerated() {
                XCTAssertEqual(response.count, expected.count)
                for (point, (a, e)) in zip(response, expected).enumerated()
                where !DesignerMatch.magnitudeClose(Double(a), Double(e)) {
                    XCTFail("\(label) 入力\(index) 応答[\(point)] \(a)、上流は \(e)")
                }
            }

            XCTAssertEqual(design.payload.count, golden.payloadBytes, "\(label) ペイロードの大きさ")
            XCTAssertEqual(Array(design.payload.prefix(golden.payloadHead.count)), golden.payloadHead,
                           "\(label) ペイロードの頭と経路")
            let bodyStart = 32 + 12 * golden.inputChannels.count
            for (index, stats) in golden.channels.enumerated() {
                let channel = DesignerMatch.floats(in: design.payload, from: bodyStart + index * key.taps * 4,
                                                   count: key.taps)
                DesignerMatch.assertChannel(channel, matches: stats, "\(label) IR\(index)")
            }
        }
    }

    // MARK: - 使い回し

    /// (fc, slope)が同じ入力は同じ係数を使う（design-core.js:73-97）。違えば別に作る。
    func testSameCutoffSlopeSharesCoefficients() throws {
        let key = BassManagementDesignKey(sampleRate: 48000, width: 3, taps: 8192, filters: [
            .init(channel: 0, cutoff: 80, slope: 24),
            .init(channel: 1, cutoff: 90, slope: 24),
            .init(channel: 2, cutoff: 80, slope: 24),
        ])
        let design = try BassManagementDesignCore.design(key)
        let body = 32 + 12 * 3
        let irs = (0..<3).map { DesignerMatch.floats(in: design.payload, from: body + $0 * 8192 * 4, count: 8192) }
        XCTAssertEqual(irs[0], irs[2])
        XCTAssertNotEqual(irs[0], irs[1])
        XCTAssertEqual(design.responses[0], design.responses[2])
    }

    /// 図は設計したときと同じ(cutoff, slope, レート)のときだけ応答を引ける。
    func testResponseLookup() throws {
        let key = BassManagementDesignKey(sampleRate: 48000, width: 2, taps: 8192, filters: [
            .init(channel: 1, cutoff: 100, slope: 48),
        ])
        let design = try BassManagementDesignCore.design(key)
        XCTAssertEqual(design.response(channel: 1, cutoff: 100, slope: 48, sampleRate: 48000), design.responses[0])
        XCTAssertNil(design.response(channel: 0, cutoff: 100, slope: 48, sampleRate: 48000))
        XCTAssertNil(design.response(channel: 1, cutoff: 101, slope: 48, sampleRate: 48000))
        XCTAssertNil(design.response(channel: 1, cutoff: 100, slope: 24, sampleRate: 48000))
        XCTAssertNil(design.response(channel: 1, cutoff: 100, slope: 48, sampleRate: 44100))
    }

    /// LPの掛かる入力が無い鍵では設計しない（空の資産は作れない）。designerはその前に
    /// .linearWithoutFiltersで止まる。上流のWorkerもペイロードを作らずに返す。
    func testEmptyKeyThrows() {
        let key = BassManagementDesignKey(sampleRate: 48000, width: 2, taps: 8192, filters: [])
        XCTAssertThrowsError(try BassManagementDesignCore.design(key))
    }

    // MARK: - 道具

    private func word(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return .max }
        return UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }
}
