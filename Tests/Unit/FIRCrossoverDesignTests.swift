//  FIRCrossoverDesignTests.swift
//  FIR Crossoverの設計（FIRCrossoverDesign.swift）を上流のdesign-core.js・design-worker.jsと照合し、
//  画面側の値の丸め（FIRCrossoverSettings）を固める。**実機もエンジンも要らない。**
//  見本はTools/golden/designers_a_golden.mjsが上流に作らせたもの（読み方はDesignersAGolden.swift）。

import XCTest

final class FIRCrossoverDesignTests: XCTestCase {

    // MARK: - 正規化

    /// sampleRate・taps・帯の数・周波数の並び・傾きの丸めが上流のnormalizeConfigと同じ。
    /// 周波数の上限は**8000〜768000へ収める前の**sampleRateの0.48倍（design-core.js:31-33と:49）。
    func testNormalize() throws {
        for (index, entry) in try DesignersAGolden.load().firCrossover.normalize.enumerated() {
            let input = entry.input
            let config = FIRCrossoverDesignCore.normalize(
                sampleRate: input.sampleRate ?? .nan,
                taps: input.taps,
                phase: try XCTUnwrap(FIRCrossoverPhase(rawValue: input.phase)),
                bandCount: input.bandCount,
                frequencies: input.frequencies.map { $0 ?? .nan },
                slopes: input.slopes)
            assertConfig(config, entry.config, "normalize[\(index)] sr=\(String(describing: input.sampleRate))")
        }
    }

    /// 無限大のsampleRateは上流と同じく頭打ちに寄る（Number(Infinity) || 48000はInfinityのまま）。
    /// 周波数の上限も無限大なので、周波数は40000より上でもそのまま残る。
    func testNormalizeInfiniteRateLikeUpstream() {
        let up = FIRCrossoverDesignCore.normalize(sampleRate: .infinity, taps: 8192, phase: .minimum,
                                                  bandCount: 2, frequencies: [50000, 60000, 70000],
                                                  slopes: [24, 24, 24])
        XCTAssertEqual(up.sampleRate, 768000)
        XCTAssertEqual(up.frequencies, [50000, 60000, 70000])
        let down = FIRCrossoverDesignCore.normalize(sampleRate: -.infinity, taps: 8192, phase: .minimum,
                                                    bandCount: 2, frequencies: [50000, 60000, 70000],
                                                    slopes: [24, 24, 24])
        XCTAssertEqual(down.sampleRate, 8000)
        XCTAssertEqual(down.frequencies, [10, 10, 10])
    }

    // MARK: - 帯の重み

    func testLowWeightMatchesUpstream() throws {
        for entry in try DesignersAGolden.load().firCrossover.lowWeight {
            let actual = FIRCrossoverDesignCore.lowWeight(frequency: entry.frequency, cutoff: entry.cutoff,
                                                          slope: entry.slope)
            XCTAssertTrue(DesignerMatch.close(actual, entry.weight, relative: 1e-12, absolute: 1e-300),
                          "f=\(entry.frequency) fc=\(entry.cutoff) s=\(entry.slope): \(actual)、上流は \(entry.weight)")
        }
    }

    /// 帯ごとの重みが上流のcrossoverBandMagnitudesと一致し、足すと1になる。
    func testBandMagnitudesMatchUpstream() throws {
        for entry in try DesignersAGolden.load().firCrossover.bandMagnitudes {
            let config = try makeConfig(entry.config)
            for (frequency, expected) in zip(entry.frequencies, entry.magnitudes) {
                let actual = FIRCrossoverDesignCore.bandMagnitudes(config, frequency: frequency)
                XCTAssertEqual(actual.count, expected.count, "f=\(frequency)")
                for (band, (a, e)) in zip(actual, expected).enumerated() {
                    XCTAssertTrue(DesignerMatch.close(a, e, relative: 1e-12, absolute: 1e-300),
                                  "\(config.bandCount)帯 f=\(frequency) 帯\(band): \(a)、上流は \(e)")
                }
                XCTAssertEqual(actual.reduce(0, +), 1, accuracy: 1e-12, "f=\(frequency) の和")
            }
        }
    }

    // MARK: - 設計

    /// 係数・遅延・分解能が上流のdesignFIRCrossoverと、経路とペイロードの頭が
    /// design-worker.js＋buildIrAssetPayloadと一致する。
    func testDesignMatchesUpstream() throws {
        for design in try DesignersAGolden.load().firCrossover.designs {
            let input = design.input
            let label = input.name
            let config = FIRCrossoverDesignCore.normalize(
                sampleRate: input.sampleRate, taps: input.taps,
                phase: try XCTUnwrap(FIRCrossoverPhase(rawValue: input.phase)),
                bandCount: input.bandCount, frequencies: input.frequencies, slopes: input.slopes)
            assertConfig(config, design.config, label)

            let result = try FIRCrossoverDesignCore.design(config)
            XCTAssertEqual(result.channels.count, design.channels.count, "\(label) 帯の数")
            for (band, (channel, stats)) in zip(result.channels, design.channels).enumerated() {
                DesignerMatch.assertChannel(channel, matches: stats, "\(label) 帯\(band)")
            }
            XCTAssertEqual(result.latencyInfo.filterDelaySamples, design.latencyInfo.filterDelaySamples, label)
            XCTAssertEqual(result.latencyInfo.resolutionHz, design.latencyInfo.resolutionHz, accuracy: 1e-12, label)

            let paths = FIRCrossoverDesignCore.paths(bandCount: config.bandCount)
            XCTAssertEqual(paths.map(\.inputSlot), design.paths.map(\.inputSlot), "\(label) 経路の入力")
            XCTAssertEqual(paths.map(\.outputSlot), design.paths.map(\.outputSlot), "\(label) 経路の出力")
            XCTAssertEqual(paths.map(\.irChannel), design.paths.map(\.irChannel), "\(label) 経路のIR")

            let payload = try AssetUpload.makePayload(channels: result.channels,
                                                      sampleRate: result.config.sampleRate,
                                                      topology: .matrix, paths: paths)
            XCTAssertEqual(payload.count, design.payloadBytes, "\(label) ペイロードの大きさ")
            XCTAssertEqual(Array(payload.prefix(design.payloadHead.count)), design.payloadHead,
                           "\(label) ペイロードの頭と経路")
        }
    }

    /// 線形位相は足すと遅延taps/2の単位インパルスに戻る（最後の帯を「インパルス－他の帯」で作る）。
    func testLinearPhaseBandsSumToDelayedImpulse() throws {
        let config = FIRCrossoverDesignCore.normalize(sampleRate: 48000, taps: 8192, phase: .linear,
                                                      bandCount: 4, frequencies: [200, 2000, 9000],
                                                      slopes: [48, 96, 384])
        let result = try FIRCrossoverDesignCore.design(config)
        var maximumError = 0.0
        for index in 0..<config.taps {
            // 上流と同じくDoubleで引いてからFloatへ落としているので、足し戻しはFloatの丸めの内側。
            let total = result.channels.reduce(0.0) { $0 + Double($1[index]) }
            let expected = index == config.taps / 2 ? 1.0 : 0.0
            maximumError = max(maximumError, abs(total - expected))
        }
        XCTAssertLessThan(maximumError, 1e-6)
    }

    /// analyzeFIR（上流のanalyzeFIRAtFrequencies）: 2倍に0を詰めて変換し、binの間は線形に補う。
    /// 0Hzより下とNyquistより上は端のbinに寄る。
    func testAnalyzeFIRMatchesUpstream() throws {
        for entry in try DesignersAGolden.load().firCrossover.analyze {
            let response = try FIRCrossoverDesignCore.analyzeFIR(entry.impulse, sampleRate: entry.sampleRate,
                                                                 frequencies: entry.frequencies)
            XCTAssertEqual(response.count, entry.response.count)
            for (index, (a, e)) in zip(response, entry.response).enumerated() {
                XCTAssertTrue(DesignerMatch.coefficientClose(a, Double(e), peak: 1),
                              "f=\(entry.frequencies[index]): \(a)、上流は \(e)")
            }
        }
    }

    // MARK: - 経路

    /// kernel.cpp:355-364が並びまで見る: 帯bの入力iは{i, 2b+i, b}。
    func testPaths() {
        for bandCount in 2...4 {
            let paths = FIRCrossoverDesignCore.paths(bandCount: bandCount)
            XCTAssertEqual(paths.count, bandCount * 2)
            for band in 0..<bandCount {
                for input in 0..<2 {
                    let path = paths[band * 2 + input]
                    XCTAssertEqual(path.inputSlot, UInt32(input))
                    XCTAssertEqual(path.outputSlot, UInt32(band * 2 + input))
                    XCTAssertEqual(path.irChannel, UInt32(band))
                }
            }
        }
        XCTAssertTrue(FIRCrossoverDesignCore.paths(bandCount: 0).isEmpty)
    }

    /// 係数の絶対値の和の最大をdBで。1（0dB）を下回らない（fir_crossover.js:349-366）。
    func testPowerGainUpperBound() {
        XCTAssertEqual(FIRCrossoverDesignCore.powerGainUpperBoundDecibels([]), 0)
        XCTAssertEqual(FIRCrossoverDesignCore.powerGainUpperBoundDecibels([[0.1, -0.2]]), 0)
        XCTAssertEqual(FIRCrossoverDesignCore.powerGainUpperBoundDecibels([[0.5, -0.5], [1, -1]]),
                       20 * log10(2.0), accuracy: 1e-12)
    }

    // MARK: - 丸め

    /// JSのMath.roundはfloor(x+0.5)。Swiftのrounded()と違って半分は常に上へ（-0.5は0、-1.5は-1）。
    func testJsRoundMinusHalf() {
        XCTAssertEqual(FIRCrossoverDesignCore.jsRound(-0.5), 0)
        XCTAssertEqual(FIRCrossoverDesignCore.jsRound(-1.5), -1)
        XCTAssertEqual(FIRCrossoverDesignCore.jsRound(-2.5), -2)
        XCTAssertEqual(FIRCrossoverDesignCore.jsRound(2.5), 3)
        XCTAssertEqual(FIRCrossoverDesignCore.jsRound(-0.49), 0)
        XCTAssertEqual(FIRCrossoverDesignCore.jsRound(44100.5), 44101)
        XCTAssertTrue(FIRCrossoverDesignCore.jsRound(.nan).isNaN)
        XCTAssertEqual(FIRCrossoverDesignCore.jsRound(.infinity), .infinity)
    }

    // MARK: - 画面側の値

    /// fir_crossover.js:133-159と同じ順で丸める: 帯の数2〜4、tapsは5択、周波数は10〜40000で
    /// 使う分だけ昇順に1Hzずつ離す、傾きは負の8択（外れは-24）、遅延の添字は0〜4。
    func testClamp() {
        var settings = FIRCrossoverSettings()
        settings.bandCount = 9
        settings.taps = 1000
        settings.latencyModeIndex = 7
        settings.frequencies = [50000, .nan, 3]
        settings.slopes = [24, -48, -50]
        settings.clamp()
        XCTAssertEqual(settings.bandCount, 4)
        XCTAssertEqual(settings.taps, 32768)
        XCTAssertEqual(settings.latencyModeIndex, 4)
        XCTAssertEqual(settings.headBlock, 1024)
        // 帯4つ＝境目3つ: [0]は上限40000-2、[1]は[0]+1以上、[2]は[1]+1以上で40000まで。
        XCTAssertEqual(settings.frequencies, [39998, 39999, 40000])
        XCTAssertEqual(settings.slopes, [-24, -48, -24])

        var two = FIRCrossoverSettings()
        two.bandCount = -3
        two.frequencies = [5, 7]
        two.slopes = []
        two.latencyModeIndex = -1
        two.clamp()
        XCTAssertEqual(two.bandCount, 2)
        // 使う境目は1つだけ。残りは10〜40000に寄せるだけで並べ替えない。
        XCTAssertEqual(two.frequencies, [10, 10, 8000])
        XCTAssertEqual(two.slopes, [-24, -24, -24])
        XCTAssertEqual(two.latencyModeIndex, 0)
        XCTAssertEqual(two.headBlock, 0)

        var fine = FIRCrossoverSettings()
        fine.clamp()
        XCTAssertEqual(fine, FIRCrossoverSettings(), "既定値は丸めても変わらない")
    }

    /// 帯ごとにステレオ1対を吐くので、出口は4〜16の偶数でないと成り立たない（fir_crossover.js:76-78）。
    func testMaximumBandCount() {
        let expected: [Int: Int] = [0: 0, 1: 0, 2: 0, 3: 0, 4: 2, 5: 0, 6: 3, 7: 0, 8: 4,
                                    10: 4, 12: 4, 14: 4, 15: 0, 16: 4, 17: 0, 18: 0, -4: 0]
        for (channels, bands) in expected {
            XCTAssertEqual(FIRCrossoverSettings.maximumBandCount(processingChannels: channels), bands,
                           "\(channels)ch")
        }
    }

    func testEffectiveBandCount() {
        var settings = FIRCrossoverSettings()
        settings.bandCount = 4
        XCTAssertEqual(settings.effectiveBandCount(processingChannels: 2), 0)
        XCTAssertEqual(settings.effectiveBandCount(processingChannels: 4), 2)
        XCTAssertEqual(settings.effectiveBandCount(processingChannels: 6), 3)
        XCTAssertEqual(settings.effectiveBandCount(processingChannels: 8), 4)
        XCTAssertEqual(settings.effectiveBandCount(processingChannels: 16), 4)
        settings.bandCount = 3
        XCTAssertEqual(settings.effectiveBandCount(processingChannels: 16), 3)
        XCTAssertEqual(settings.effectiveBandCount(processingChannels: 7), 0)
    }

    /// 出口の幅が足りなければnil。足りれば帯の数を幅で切ってから正規化する（fir_crossover.js:187-199）。
    func testConfigNil() throws {
        var settings = FIRCrossoverSettings()
        settings.bandCount = 4
        settings.frequencies = [100, 1000, 10000]
        settings.slopes = [-48, -96, -384]
        settings.phase = .linear
        settings.taps = 16384
        XCTAssertNil(settings.config(sampleRate: 48000, processingChannels: 2))
        XCTAssertNil(settings.config(sampleRate: 48000, processingChannels: 5))
        let config = try XCTUnwrap(settings.config(sampleRate: 48000, processingChannels: 6))
        XCTAssertEqual(config.bandCount, 3)
        XCTAssertEqual(config.slopes, [48, 96, 384])
        XCTAssertEqual(config.frequencies, [100, 1000, 10000])
        XCTAssertEqual(config.taps, 16384)
        XCTAssertEqual(config.phase, .linear)
        XCTAssertEqual(config.sampleRate, 48000)
    }

    // MARK: - 道具

    private func makeConfig(_ golden: DesignersAGolden.Crossover.Config) throws -> FIRCrossoverConfig {
        FIRCrossoverConfig(sampleRate: golden.sampleRate, taps: golden.taps,
                           phase: try XCTUnwrap(FIRCrossoverPhase(rawValue: golden.phase)),
                           bandCount: golden.bandCount, frequencies: golden.frequencies, slopes: golden.slopes)
    }

    private func assertConfig(_ config: FIRCrossoverConfig,
                              _ expected: DesignersAGolden.Crossover.Config,
                              _ label: String,
                              file: StaticString = #filePath,
                              line: UInt = #line) {
        XCTAssertEqual(config.sampleRate, expected.sampleRate, "\(label) sampleRate", file: file, line: line)
        XCTAssertEqual(config.taps, expected.taps, "\(label) taps", file: file, line: line)
        XCTAssertEqual(config.phase.rawValue, expected.phase, "\(label) phase", file: file, line: line)
        XCTAssertEqual(config.bandCount, expected.bandCount, "\(label) bandCount", file: file, line: line)
        XCTAssertEqual(config.frequencies, expected.frequencies, "\(label) frequencies", file: file, line: line)
        XCTAssertEqual(config.slopes, expected.slopes, "\(label) slopes", file: file, line: line)
    }
}
