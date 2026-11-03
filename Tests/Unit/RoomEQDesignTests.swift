//  RoomEQDesignTests.swift
//  Room EQ の設計（RoomEQDesign.swift）。**実機もエンジンも要らない。**
//
//  約束は 3 つ。
//    1. min / lin の補正 FIR（周波数特性だけの測定・インパルス応答・別レートの伸縮
//       （44.1→48kHz と、間引く側の 96→48kHz・88.2→48kHz）・Additional EQ・測定の無い枠）と、
//       遅延・分解能・注意・基準レベルが上流の designRoomEq と同じ。
//    2. full は移していないので lin に落とし、そのことを必ず知らせる。
//    3. 32MiB の枠に入るかを設計の前に判断する（checkCapacity / largestUsableTaps）。
//       latencyMode の保存値（添字）と headBlock の行き来。

import XCTest
import Foundation

final class RoomEQDesignTests: XCTestCase {

    // MARK: - latencyMode

    /// 添字 ↔ headBlock。表に無い headBlock は既定の添字 1（128）に倒す。
    func testLatencyModeRoundTrip() {
        for (index, mode) in RoomEQDesigner.allowedLatencyModes.enumerated() {
            XCTAssertEqual(RoomEQDesigner.parameterValue(forLatencyMode: mode), Float(index))
            XCTAssertEqual(RoomEQDesigner.latencyMode(fromParameterValue: Float(index)), mode)
            XCTAssertEqual(RoomEQDesigner.latencyMode(
                fromParameterValue: RoomEQDesigner.parameterValue(forLatencyMode: mode)), mode)
        }
        XCTAssertEqual(RoomEQDesigner.parameterValue(forLatencyMode: 64), 1)
        XCTAssertEqual(RoomEQDesigner.latencyMode(fromParameterValue: 2.4), 256)
        XCTAssertEqual(RoomEQDesigner.latencyMode(fromParameterValue: -0.4), 0)
        XCTAssertEqual(RoomEQDesigner.latencyMode(fromParameterValue: -0.6), 128)
        XCTAssertEqual(RoomEQDesigner.latencyMode(fromParameterValue: 5), 128)
    }

    /// 有限でない値や Int に入らない値でも落ちずに 128。
    /// 直す前は `Int(value.rounded())` が NaN・無限大・1e30 で trap していた。
    func testLatencyModeNonFiniteFallsBackTo128() {
        for value: Float in [.nan, .infinity, -.infinity, 1e30, -1e30, .greatestFiniteMagnitude] {
            XCTAssertEqual(RoomEQDesigner.latencyMode(fromParameterValue: value), 128, "\(value)")
        }
    }

    // MARK: - 持ち上げの頭打ち

    /// 上限の 1dB 手前まではそのまま、上限で止まり、そのあいだは 3 次で繋ぐ（値も傾きも続く）。
    func testSoftLimitBoost() throws {
        XCTAssertEqual(RoomEQDesigner.softLimitBoost(-3, maximum: 6), -3)
        XCTAssertEqual(RoomEQDesigner.softLimitBoost(5, maximum: 6), 5)
        XCTAssertEqual(RoomEQDesigner.softLimitBoost(6, maximum: 6), 6)
        XCTAssertEqual(RoomEQDesigner.softLimitBoost(40, maximum: 6), 6)
        XCTAssertEqual(RoomEQDesigner.softLimitBoost(1, maximum: 0), 0)
        var previous = -Double.infinity
        for step in 0...200 {
            let decibels = 4.5 + Double(step) * 0.01
            let value = RoomEQDesigner.softLimitBoost(decibels, maximum: 6)
            XCTAssertGreaterThanOrEqual(value, previous, "\(decibels)")
            XCTAssertLessThanOrEqual(value, 6)
            previous = value
        }
        // 継ぎ目の傾き: 手前は 1、上限では 0。
        let h = 1e-6
        XCTAssertEqual((RoomEQDesigner.softLimitBoost(5 + h, maximum: 6) - 5) / h, 1, accuracy: 1e-5)
        XCTAssertEqual((6 - RoomEQDesigner.softLimitBoost(6 - h, maximum: 6)) / h, 0, accuracy: 1e-5)

        let golden = try DesignersBGolden.load()
        XCTAssertGreaterThanOrEqual(golden.roomEq.softLimitBoost.count, 20)
        for entry in golden.roomEq.softLimitBoost {
            XCTAssertEqual(RoomEQDesigner.softLimitBoost(entry.decibels, maximum: entry.maximum), entry.expected,
                           accuracy: 1e-15, "\(entry.decibels) / \(entry.maximum)")
        }
    }

    // MARK: - 枠に入るか

    /// 入る taps のうち一番大きいもの。答えは上流の maximumIrFramesForKernel
    /// （js/ir-library/ir-plugin-contract.js:241-269）に RoomEQConfig.allowedTaps を大きい順に当てて出した表で、
    /// こちらの AssetUpload を通した値ではない。32MiB の枠は 11 チャンネルまで 131072 が入り、
    /// 12 チャンネルから 65536。遅延（headBlock）はどれでも変わらない。
    func testLargestUsableTaps() {
        let symmetric = [Int](repeating: 131072, count: 11) + [Int](repeating: 65536, count: 5)
        for latency in RoomEQDesigner.allowedLatencyModes {
            let got = (1...16).map {
                RoomEQDesigner.largestUsableTaps(channelCount: $0, processingChannels: $0, latencyMode: latency)
            }
            XCTAssertEqual(got, symmetric, "lt \(latency)")
        }
        // 処理チャンネル数が効く組み合わせ（引数を取り違えると外れる）。
        let asymmetric: [(channels: Int, processing: Int, taps: Int)] = [
            (1, 16, 131072), (4, 16, 131072), (8, 16, 65536), (11, 2, 131072), (12, 2, 65536), (16, 1, 65536)
        ]
        for row in asymmetric {
            for latency: UInt32 in [0, 128, 1024] {
                XCTAssertEqual(RoomEQDesigner.largestUsableTaps(channelCount: row.channels,
                                                                processingChannels: row.processing,
                                                                latencyMode: latency),
                               row.taps, "\(row.channels)ch / \(row.processing) 処理 / lt \(latency)")
            }
        }
        // 既定の latencyMode は 128。
        XCTAssertEqual(RoomEQDesigner.largestUsableTaps(channelCount: 12, processingChannels: 12), 65536)
    }

    /// 入らないときは入る一番大きい taps を添えて落ちる。0 チャンネルは noSources。
    /// taps は倒してから見る（許されない値は 32768）。
    func testCheckCapacity() throws {
        XCTAssertNoThrow(try RoomEQDesigner.checkCapacity(config: RoomEQConfig(taps: 8192),
                                                          channelCount: 1, processingChannels: 1))
        XCTAssertThrowsError(try RoomEQDesigner.checkCapacity(config: RoomEQConfig(), channelCount: 0,
                                                              processingChannels: 2)) {
            guard case RoomEQDesignError.noSources = $0 else { return XCTFail("\($0)") }
        }
        // 16 チャンネル・headBlock 128 の枠は上流の maximumIrFramesForKernel で 86016 フレーム。
        // 131072 は入らず、入る一番大きい taps は 65536（testLargestUsableTaps の表と同じ）。
        XCTAssertThrowsError(try RoomEQDesigner.checkCapacity(config: RoomEQConfig(taps: 131072),
                                                              channelCount: 16, processingChannels: 16)) {
            guard case RoomEQDesignError.tapsExceedAssetCapacity(let taps, let maximum) = $0 else {
                return XCTFail("\($0)")
            }
            XCTAssertEqual(taps, 131072)
            XCTAssertEqual(maximum, 65536)
            XCTAssertEqual(($0 as? LocalizedError)?.errorDescription,
                           "131072 taps do not fit in the 32 MiB asset slot. Use 65536 or fewer.")
        }
        // 100000 は許されないので 32768 に倒してから見る。倒さずに見ると 86016 フレームの枠を
        // 超えて落ちる。
        XCTAssertNoThrow(try RoomEQDesigner.checkCapacity(config: RoomEQConfig(taps: 100000),
                                                          channelCount: 16, processingChannels: 16))
    }

    // MARK: - 設定の倒し方

    func testConfigNormalized() {
        var config = RoomEQConfig(sampleRate: -1, taps: 12345, smoothing: 0, lowFrequency: 1, highFrequency: 1e6,
                                  maxBoostDb: -3, correctionAmount: 7)
        config.phaseSmoothing = nil
        config.referencePoint = -4
        let normalized = config.normalized()
        XCTAssertEqual(normalized.taps, 32768)
        XCTAssertEqual(normalized.sampleRate, 48000)
        XCTAssertEqual(normalized.smoothing, 0.02)
        XCTAssertEqual(normalized.phaseSmoothing, 0.02)   // 自動は振幅の平滑化と同じ
        XCTAssertEqual(normalized.lowFrequency, 20)
        XCTAssertEqual(normalized.highFrequency, 20000)
        XCTAssertEqual(normalized.maxBoostDb, 0)
        XCTAssertEqual(normalized.correctionAmount, 1)
        XCTAssertEqual(normalized.referencePoint, 0)
        XCTAssertEqual(RoomEQConfig(sampleRate: 44099).normalized().sampleRate, 44099)
    }

    // MARK: - 上流の見本

    private func config(_ golden: DesignersBGolden.RoomConfig) throws -> RoomEQConfig {
        var config = RoomEQConfig()
        config.sampleRate = golden.sampleRate
        config.taps = golden.taps
        config.phase = try XCTUnwrap(RoomEQPhase(rawValue: golden.phase ?? "min"))
        config.smoothing = golden.smoothing
        config.lowFrequency = golden.lowFrequency
        config.highFrequency = golden.highFrequency
        config.maxBoostDb = golden.maxBoostDb
        config.correctionAmount = golden.correctionAmount
        config.bands = try (golden.eqBands ?? []).map { band in
            RoomEQBand(enabled: band.enabled,
                       type: try XCTUnwrap(RoomEQBandType(rawValue: band.type)),
                       frequency: band.frequency, gain: band.gain, q: band.q)
        }
        return config
    }

    private func source(_ golden: DesignersBGolden.RoomSource?) -> RoomEQSource? {
        guard let golden else { return nil }
        return RoomEQSource(
            impulses: golden.impulses.map {
                RoomEQImpulse(data: $0.data.floats, sampleRate: $0.sampleRate, onsetIndex: $0.onsetIndex,
                              referenceScale: $0.referenceScale)
            },
            frequencyResponse: golden.frequencyResponse.map {
                RoomEQResponsePoint(frequency: $0.frequency, decibels: $0.decibels)
            })
    }

    /// 補正 FIR・遅延・分解能・full の可否・注意・基準レベル・倒した設定が上流と同じ。
    func testDesignMatchesUpstream() throws {
        let golden = try DesignersBGolden.load()
        XCTAssertGreaterThanOrEqual(golden.roomEq.designs.count, 3)
        var worst = 0.0
        for entry in golden.roomEq.designs {
            let design = RoomEQDesigner.design(config: try config(entry.config),
                                               sources: entry.sources.map(source))
            let e = entry.expected
            XCTAssertFalse(design.phaseFallback, entry.name)
            XCTAssertEqual(design.filterDelaySamples, e.filterDelaySamples, entry.name)
            XCTAssertEqual(design.resolutionHz, e.resolutionHz, accuracy: 1e-12, entry.name)
            XCTAssertEqual(design.supportsFullPhase, e.supportsFullPhase, entry.name)
            XCTAssertEqual(design.qualityWarnings.map(\.rawValue), e.qualityWarnings, entry.name)
            XCTAssertEqual(design.config.sampleRate, e.config.sampleRate, entry.name)
            XCTAssertEqual(design.config.taps, e.config.taps, entry.name)
            XCTAssertEqual(design.config.smoothing, e.config.smoothing, entry.name)
            XCTAssertEqual(design.config.lowFrequency, e.config.lowFrequency, entry.name)
            XCTAssertEqual(design.config.highFrequency, e.config.highFrequency, entry.name)
            XCTAssertEqual(design.config.maxBoostDb, e.config.maxBoostDb, entry.name)
            XCTAssertEqual(design.config.correctionAmount, e.config.correctionAmount, entry.name)

            XCTAssertEqual(design.referenceLevelDb.count, e.referenceLevelDb.count, entry.name)
            for (got, want) in zip(design.referenceLevelDb, e.referenceLevelDb) {
                XCTAssertEqual(got == nil, want == nil, entry.name)
                if let got, let want { XCTAssertEqual(got, want, accuracy: 1e-9, entry.name) }
            }

            XCTAssertEqual(design.channels.count, e.channels.count, entry.name)
            for (index, (got, want)) in zip(design.channels, e.channels).enumerated() {
                let wanted = want.floats
                XCTAssertEqual(got.count, wanted.count, "\(entry.name) ch\(index)")
                let diff = DesignersBGolden.maxRelativeDiff(got.map { Double($0) }, wanted.map { Double($0) })
                worst = max(worst, diff)
                XCTAssertLessThanOrEqual(diff, 1e-6, "\(entry.name) ch\(index)")
            }
        }
        print("RoomEQ golden: worst channel diff \(worst) of peak")
    }

    // MARK: - 画面の曲線

    /// 周波数特性・位相・群遅延・インパルスの曲線が上流の previews と同じ（RoomEQPreview.swift）。
    /// 上流は Float32Array に入れて返すので、許す差はその丸めに合わせる。
    /// 位相は ±180 に畳んだ角度なので、差も畳んでから測る。
    func testPreviewsMatchUpstream() throws {
        let golden = try DesignersBGolden.load()
        var worst: [String: Double] = [:]
        func note(_ key: String, _ value: Double) { worst[key] = max(worst[key] ?? 0, value) }

        for entry in golden.roomEq.designs {
            let design = RoomEQDesigner.design(config: try config(entry.config),
                                               sources: entry.sources.map(source))
            let expected = entry.expected.previews
            XCTAssertEqual(design.previews.count, expected.count, entry.name)
            for (channel, (got, want)) in zip(design.previews, expected).enumerated() {
                let label = "\(entry.name) ch\(channel)"
                XCTAssertEqual(got == nil, want == nil, label)
                guard let got, let want else { continue }
                XCTAssertEqual(got.channel, channel, label)
                XCTAssertEqual(got.frequencies.count, want.frequencyCount, label)

                for (name, a, b) in [("measuredDb", got.measuredDb, want.measuredDb),
                                     ("baseCorrectionDb", got.baseCorrectionDb, want.baseCorrectionDb),
                                     ("predictedBaseDb", got.predictedBaseDb, want.predictedBaseDb)] {
                    let diff = DesignersBGolden.maxAbsDiff(a, b.doubles)
                    note(name, diff)
                    XCTAssertLessThanOrEqual(diff, 1e-3, "\(label) \(name)")
                }

                XCTAssertEqual(got.phase == nil, want.phase == nil, label)
                if let phase = got.phase, let wanted = want.phase {
                    for (name, a, b) in [("phase.before", phase.before, wanted.before.doubles),
                                         ("phase.after", phase.after, wanted.after.doubles)] {
                        XCTAssertEqual(a.count, b.count, "\(label) \(name)")
                        var diff = 0.0
                        for (x, y) in zip(a, b) {
                            var d = (x - y).truncatingRemainder(dividingBy: 360)
                            if d > 180 { d -= 360 } else if d < -180 { d += 360 }
                            diff = max(diff, abs(d))
                        }
                        note(name, diff)
                        XCTAssertLessThanOrEqual(diff, 0.05, "\(label) \(name)")
                    }
                }

                for (name, a, b) in [("minimumGroupDelay", got.minimumGroupDelay, want.minimumGroupDelay),
                                     ("excessGroupDelay", got.excessGroupDelay, want.excessGroupDelay)] {
                    XCTAssertEqual(a == nil, b == nil, "\(label) \(name)")
                    guard let a, let b else { continue }
                    for (part, x, y) in [("before", a.before, b.before.doubles),
                                         ("after", a.after, b.after.doubles)] {
                        let diff = DesignersBGolden.maxAbsDiff(x, y)
                        note("\(name).\(part)", diff)
                        XCTAssertLessThanOrEqual(diff, 1e-3, "\(label) \(name).\(part)")
                    }
                }

                XCTAssertEqual(got.impulse == nil, want.impulse == nil, label)
                if let impulse = got.impulse, let wanted = want.impulse {
                    XCTAssertEqual(impulse.startMs, wanted.startMs, accuracy: 1e-12, label)
                    XCTAssertEqual(impulse.durationMs, wanted.durationMs, accuracy: 1e-12, label)
                    for (name, a, b) in [("impulse.before", impulse.before, wanted.before.floats),
                                         ("impulse.after", impulse.after, wanted.after.floats)] {
                        XCTAssertEqual(a.count, b.count, "\(label) \(name)")
                        let peak = b.reduce(Float(0)) { max($0, abs($1)) }
                        XCTAssertGreaterThan(peak, 0, "\(label) \(name)")
                        let diff = DesignersBGolden.maxAbsDiff(a, b) / Double(max(peak, 1e-12))
                        note(name, diff)
                        XCTAssertLessThanOrEqual(diff, 1e-5, "\(label) \(name)")
                    }
                }
            }
        }
        print("RoomEQ previews golden: worst \(worst.sorted { $0.key < $1.key })")
    }

    // MARK: - 移していない所

    /// full は lin で設計し、phaseFallback と fullPhaseNotPorted で知らせる。
    /// 周波数特性だけの測定なら impulseResponseRequired も付く（上流と同じ注意）。
    func testFullFallsBackToLinearAndSaysSo() {
        var config = RoomEQConfig(taps: 8192)
        config.phase = .full
        let source = RoomEQSource(frequencyResponse: [RoomEQResponsePoint(frequency: 100, decibels: 3),
                                                      RoomEQResponsePoint(frequency: 1000, decibels: -2)])
        let design = RoomEQDesigner.design(config: config, sources: [source])
        XCTAssertTrue(design.phaseFallback)
        XCTAssertEqual(design.appliedPhase, .linear)
        XCTAssertEqual(design.config.phase, .linear)
        XCTAssertEqual(design.filterDelaySamples, 4096)
        XCTAssertFalse(design.supportsFullPhase)
        XCTAssertEqual(design.qualityWarnings, [.fullPhaseNotPorted, .impulseResponseRequired])
    }

    /// 測定の無い枠は素通し: min は頭、lin は真ん中の単位インパルス。遅延は min 0、lin taps/2。
    func testMissingSourceIsUnitImpulse() {
        for phase in [RoomEQPhase.minimum, .linear] {
            var config = RoomEQConfig(taps: 8192)
            config.phase = phase
            let design = RoomEQDesigner.design(config: config, sources: [nil, nil])
            XCTAssertEqual(design.channels.count, 2)
            let at = phase == .minimum ? 0 : 4096
            for channel in design.channels {
                XCTAssertEqual(channel.count, 8192)
                XCTAssertEqual(channel[at], 1)
                XCTAssertEqual(channel.reduce(0) { $0 + abs($1) }, 1)
            }
            XCTAssertEqual(design.referenceLevelDb.count, 2)
            XCTAssertTrue(design.referenceLevelDb.allSatisfy { $0 == nil })
            XCTAssertEqual(design.filterDelaySamples, phase == .minimum ? 0 : 4096)
            XCTAssertTrue(design.supportsFullPhase)
            XCTAssertEqual(design.qualityWarnings, [])
        }
    }
}
