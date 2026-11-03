//  IRPreparationTests.swift
//  IRの下ごしらえ（ETIRPreparation）。**実機もエンジンも要らない。**
//
//  約束は2つ。
//    1. 上流のprepareIrと同じ面を作る。見本は上流のJSそのものが吐いたもの
//       （Tests/Fixtures/IR/prepare-golden.json。作り直すときは`node Tools/ir_prepare_golden.mjs`）。
//    2. wetの大きさが上流と同じ形でレートに従う。dividerを変えても変わらず、
//       処理レートが倍になるごとに+3dB。直す前は正規化が無く、192kHz（Autoでhalf）だけ
//       48kHzより+9dB（上流は+6dB）になって割れていた。
//
//  IRPreparation.swiftと見本はこのバンドルへ直接入れてある（project.yml）。

import XCTest
import Foundation

final class IRPreparationTests: XCTestCase {

    // MARK: - 見本

    private struct Golden: Decodable {
        let inputs: [String: [String]]
        let cases: [Case]

        struct Case: Decodable {
            let name: String
            let input: String
            let sampleRate: Int
            let topology: UInt32
            let options: Options
            let expected: Expected
        }

        struct Options: Decodable {
            let directCut: Bool
            let cutOffsetMs: Double
            let decayPercent: Double
            let trimPercent: Double
        }

        struct Expected: Decodable {
            let frames: Int
            let leadingSilenceFrames: Int
            let onsetFrame: Int
            let cutFrame: Int?
            let sourceStartFrame: Int
            let truncated: Bool
            let initialGains: [Double]
            let finalGains: [Double]
            let channels: [String]
        }
    }

    private func golden() throws -> Golden {
        let file = try XCTUnwrap(TestResource.url("prepare-golden", "json"))
        return try JSONDecoder().decode(Golden.self, from: Data(contentsOf: file))
    }

    /// float32のリトルエンディアンをbase64にしたもの。
    private static func floats(_ base64: String) throws -> [Float] {
        let data = try XCTUnwrap(Data(base64Encoded: base64))
        XCTAssertEqual(data.count % 4, 0)
        let bytes = [UInt8](data)
        return (0..<bytes.count / 4).map { i in
            let bits = UInt32(bytes[4 * i])
                | UInt32(bytes[4 * i + 1]) << 8
                | UInt32(bytes[4 * i + 2]) << 16
                | UInt32(bytes[4 * i + 3]) << 24
            return Float(bitPattern: bits)
        }
    }

    /// **上流のprepareIrと同じ面になる。** 長さ・頭の無音・onset・開始・利得・全標本を1e-6以内で。
    ///
    /// 見本が見ているもの: mono / indep / True Stereo / matrix、頭の0、dcの入り切り、
    /// dt 50・200、tr 60（2048フレームの立ち下がりが一部だけかかる長さも）、coの正負と
    /// 半フレーム（Math.roundの丸め方）、0の面、全部0、64より短い、1フレーム、最後だけ鳴る。
    func testGoldenMatchesUpstream() throws {
        let g = try golden()
        XCTAssertGreaterThanOrEqual(g.cases.count, 30)
        var maxSample = 0.0
        var maxGain = 0.0
        for c in g.cases {
            let source = try XCTUnwrap(g.inputs[c.input]).map(Self.floats)
            let topology = try XCTUnwrap(ETAssetTopology(rawValue: c.topology))
            var options = ETIRPreparation.Options()
            options.directCut = c.options.directCut
            options.cutOffsetMs = c.options.cutOffsetMs
            options.decayPercent = c.options.decayPercent
            options.trimPercent = c.options.trimPercent
            let p = try ETIRPreparation.prepare(source, sampleRate: c.sampleRate,
                                                topology: topology, options: options)
            let e = c.expected
            XCTAssertEqual(p.frames, e.frames, c.name)
            XCTAssertEqual(p.leadingSilenceFrames, e.leadingSilenceFrames, c.name)
            XCTAssertEqual(p.onsetFrame, e.onsetFrame, c.name)
            XCTAssertEqual(p.cutFrame, e.cutFrame, c.name)
            XCTAssertEqual(p.sourceStartFrame, e.sourceStartFrame, c.name)
            XCTAssertEqual(p.truncated, e.truncated, c.name)
            XCTAssertEqual(p.initialGains.count, e.initialGains.count, c.name)
            XCTAssertEqual(p.finalGains.count, e.finalGains.count, c.name)
            for (a, b) in Array(zip(p.initialGains, e.initialGains)) + Array(zip(p.finalGains, e.finalGains)) {
                let diff = abs(Double(a) - b) / max(1, abs(b))
                maxGain = max(maxGain, diff)
                XCTAssertLessThanOrEqual(diff, 1e-6, "\(c.name) gain \(a) vs \(b)")
            }
            XCTAssertEqual(p.channels.count, e.channels.count, c.name)
            for (ch, encoded) in e.channels.enumerated() where ch < p.channels.count {
                let want = try Self.floats(encoded)
                XCTAssertEqual(p.channels[ch].count, want.count, "\(c.name) ch\(ch)")
                var worst = 0.0
                for (a, b) in zip(p.channels[ch], want) { worst = max(worst, abs(Double(a) - Double(b))) }
                maxSample = max(maxSample, worst)
                XCTAssertLessThanOrEqual(worst, 1e-6, "\(c.name) ch\(ch)")
            }
        }
        print("IRPreparation golden: \(g.cases.count) cases, max sample diff \(maxSample), max gain diff \(maxGain)")
    }

    // MARK: - 正規化

    /// dcを切ると、各面のΣy²がちょうど1になる。True Stereoは4面の和が4で、利得は1つ。
    func testUnitEnergyWithoutDirectCut() throws {
        var options = ETIRPreparation.Options()
        options.directCut = false
        let mono = try ETIRPreparation.prepare([Self.decaying(frames: 3000, seed: 1, level: 0.9)],
                                               sampleRate: 48000, topology: .mono, options: options)
        XCTAssertEqual(Self.energy(mono.channels[0]), 1, accuracy: 1e-5)

        let stereo = try ETIRPreparation.prepare([Self.decaying(frames: 3000, seed: 2, level: 0.9),
                                                  Self.decaying(frames: 3000, seed: 3, level: 0.2)],
                                                 sampleRate: 48000, topology: .independent, options: options)
        // 左右の大きさの違いは均される。
        XCTAssertEqual(Self.energy(stereo.channels[0]), 1, accuracy: 1e-5)
        XCTAssertEqual(Self.energy(stereo.channels[1]), 1, accuracy: 1e-5)

        let quad = try ETIRPreparation.prepare((0..<4).map { Self.decaying(frames: 3000, seed: UInt32(10 + $0),
                                                                           level: [0.9, 0.3, 0.2, 0.7][$0]) },
                                               sampleRate: 48000, topology: .trueStereo, options: options)
        XCTAssertEqual(quad.channels.map(Self.energy).reduce(0, +), 4, accuracy: 4e-5)
        XCTAssertEqual(Set(quad.initialGains).count, 1)
        // 1つの利得なので、面ごとの大きさの差はそのまま残る。
        XCTAssertGreaterThan(Self.energy(quad.channels[0]), Self.energy(quad.channels[1]) * 4)
    }

    /// dcを入れると、利得は切る前の面（頭の無音だけ落としたもの）で測る。
    /// 切って立ち上げた分だけΣy²は1より小さい。**1へ戻さない**（上流のまま）。
    func testDirectCutMeasuresTheUncutIR() throws {
        let source = Self.decaying(frames: 3000, seed: 4, level: 0.9, lead: 25)
        let p = try ETIRPreparation.prepare([source], sampleRate: 48000, topology: .mono)
        XCTAssertEqual(p.leadingSilenceFrames, 25)
        XCTAssertEqual(p.sourceStartFrame, 26)
        let gain = Double(p.initialGains[0])
        let reference = source[25...].reduce(0.0) { $0 + (Double($1) * gain) * (Double($1) * gain) }
        XCTAssertEqual(reference, 1, accuracy: 1e-5)
        XCTAssertLessThan(Self.energy(p.channels[0]), 1)
        XCTAssertEqual(Double(p.finalGains[0]), 1, accuracy: 1e-6)
        // 立ち上がりの頭は0。
        XCTAssertEqual(p.channels[0][0], 0)
    }

    // MARK: - wetの大きさとレート

    /// kernel.cpp:634のrate_gainを写したもの。
    /// `rate_gain = rate_divider_ == 4u ? 2.0F : 1.41421356237F`。d=1はこの経路を通らない。
    /// 間のhalfbandの間引き・補間は帯域内で利得1（halfband.h:71-72）。
    private static let rateGain: [UInt32: Double] = [1: 1, 2: 2.0.squareRoot(), 4: 2]

    /// 1kHz・5kHz・10kHzでのwetの大きさ（dB）。rate_gain × |DTFT(y)|。
    /// 1点だと雑音のIRの谷に当たりうるので、中心の±10%を21点で平均した電力で見る。
    /// `bright`は20kHzより上にもエネルギーがあるIR（brightIR）。
    private static func wetLevels(sourceRate: Double, processingRate: Double, convolutionRate mode: String,
                                  bright: Bool = false) throws -> [Double] {
        let resolved = try ETIRPreparation.resolve(sampleRate: processingRate, channelCount: 1, routedChannels: 2,
                                                   channelMode: "auto", latency: "128", convolutionRate: mode)
        let source = bright ? brightIR(sampleRate: sourceRate, seed: 7) : roomIR(sampleRate: sourceRate, seed: 7)
        let staged = try ETIRPreparation.stage([source], sourceRate: sourceRate, resolved: resolved)
        XCTAssertEqual(staged.sampleRate, resolved.convolutionRate)
        let rg = try XCTUnwrap(rateGain[resolved.rateDivider])
        return [1000.0, 5000, 10000].map { center in
            10 * log10(rg * rg * bandPower(staged.channels[0], sampleRate: Double(resolved.convolutionRate), center: center))
        }
    }

    /// **同じ処理レートなら、dividerを変えてもwetの大きさは変わらない。** 0.1dB以内。
    /// 直す前はdを半分にするごとに-3dB動いていた（素材の値のままfcだけが変わるため）。
    ///
    /// 明るいIRも見る。帯域の切り方がdividerで変わると（素材とfcが同じなら触らない、fcが素材より
    /// 低ければfc/2で切る、など）、正規化に入る上の帯域のエネルギーが変わって帯域内が0.2〜0.4dB動く。
    /// 部屋らしいIRは20kHzより上がほぼ無いので、それだけだと見えない。
    func testDividerDoesNotChangeTheWetLevel() throws {
        let settings: [(Double, [String])] = [(88200, ["full", "half"]), (96000, ["full", "half"]),
                                              (176400, ["full", "half", "quarter"]),
                                              (192000, ["full", "half", "quarter"])]
        for bright in [false, true] {
            for sourceRate in [44100.0, 48000] {
                for (rate, modes) in settings {
                    let levels = try modes.map {
                        try Self.wetLevels(sourceRate: sourceRate, processingRate: rate, convolutionRate: $0, bright: bright)
                    }
                    for f in 0..<3 {
                        let column = levels.map { $0[f] }
                        let spread = column.max()! - column.min()!
                        XCTAssertLessThanOrEqual(spread, 0.1,
                                                 "bright \(bright) source \(sourceRate) rate \(rate) band \(f): \(column)")
                    }
                }
            }
        }
    }

    /// **Autoでのレートによる違いは上流と同じ10·log10(fs/48k)。** ±0.15dB。
    /// 192kHzで+6.02dB。直す前はここが+9.0dBだった。
    ///
    /// 44.1kHzの明るいIRも見る。48kHzでも88.2kHz（Autoでhalf、fcは素材と同じ44.1kHz）でも
    /// 同じ帯域で切るので、明るくても同じ差になる。48kHzの素材は48kHzで触らない（上流も同じ）ため
    /// 基準の帯域だけ広く、明るいIRでは差がずれるので見ない。
    func testRateDependenceMatchesUpstream() throws {
        for (sourceRate, bright) in [(44100.0, false), (48000, false), (44100, true)] {
            let base = try Self.wetLevels(sourceRate: sourceRate, processingRate: 48000, convolutionRate: "auto",
                                          bright: bright)
            for rate in [88200.0, 96000, 176400, 192000] {
                let levels = try Self.wetLevels(sourceRate: sourceRate, processingRate: rate, convolutionRate: "auto",
                                                bright: bright)
                let expected = 10 * log10(rate / 48000)
                for f in 0..<3 {
                    XCTAssertEqual(levels[f] - base[f], expected, accuracy: 0.15,
                                   "bright \(bright) source \(sourceRate) rate \(rate) band \(f)")
                }
            }
        }
    }

    /// 伸縮は上流の形（fsへ伸ばしてからd個おきに拾う）と同じ。
    ///   - 素材がfsそのもので、dが1なら触らない。dが2・4ならd個おきに拾うだけ。どちらも上流と同じ面になる
    ///   - 素材がfcと同じでもfsと違えば（192kHzのquarterに48kHz）、長さはそのままで帯域だけ切る
    func testStageFollowsUpstreamResamplingStructure() throws {
        let source = Self.brightIR(sampleRate: 48000, seed: 21)
        let at48 = try ETIRPreparation.resolve(sampleRate: 48000, channelCount: 1, routedChannels: 2,
                                               channelMode: "auto", latency: "128", convolutionRate: "auto")
        let staged = try ETIRPreparation.stage([source], sourceRate: 48000, resolved: at48)
        let direct = try ETIRPreparation.prepare([source], sampleRate: 48000, topology: .mono)
        XCTAssertEqual(staged.channels, direct.channels)

        let quarter = try ETIRPreparation.resolve(sampleRate: 192000, channelCount: 1, routedChannels: 2,
                                                  channelMode: "auto", latency: "128", convolutionRate: "quarter")
        XCTAssertEqual(quarter.convolutionRate, 48000)
        let filtered = try ETIRPreparation.stage([source], sourceRate: 48000, resolved: quarter)
        XCTAssertNotEqual(filtered.channels, direct.channels)
        XCTAssertEqual(filtered.frames, direct.frames)
        // 同じ処理レートのfullと同じ帯域（ナイキストのすぐ下が無い）。切らなければ0dB前後。
        let top = Self.bandPower(filtered.channels[0], sampleRate: 48000, center: 23_900, width: 0.004)
        let middle = Self.bandPower(filtered.channels[0], sampleRate: 48000, center: 10_000)
        XCTAssertLessThan(10 * log10(top / middle), -30)
        let untouchedTop = Self.bandPower(direct.channels[0], sampleRate: 48000, center: 23_900, width: 0.004)
        let untouchedMiddle = Self.bandPower(direct.channels[0], sampleRate: 48000, center: 10_000)
        XCTAssertGreaterThan(10 * log10(untouchedTop / untouchedMiddle), -6)

        // 96kHzの素材を96kHzのhalfで。上流はdecodeAudioDataが何もせず、OfflineAudioContextが
        // 1つおきに拾う（整数比の線形補間）。
        let high = Self.brightIR(sampleRate: 96000, seed: 22) + [0.01]
        let half = try ETIRPreparation.resolve(sampleRate: 96000, channelCount: 1, routedChannels: 2,
                                               channelMode: "auto", latency: "128", convolutionRate: "auto")
        XCTAssertEqual(half.rateDivider, 2)
        let picked = try ETIRPreparation.stage([high], sourceRate: 96000, resolved: half)
        let everyOther = stride(from: 0, to: high.count, by: 2).map { high[$0] }
        XCTAssertEqual(everyOther.count, (high.count + 1) / 2)
        let expected = try ETIRPreparation.prepare([everyOther], sampleRate: 48000, topology: .mono)
        XCTAssertEqual(picked.channels, expected.channels)
        XCTAssertEqual(ETIRPreparation.pick([[1, 2, 3, 4, 5, 6]], from: 192000, to: 48000), [[1, 5]])
    }

    // MARK: - 伸縮

    /// 帯域内の正弦波は大きさを保つ。18kHzまで±0.05dB、それ以外（鏡像・誤差）は-60dBより下。
    func testResamplerKeepsTonesAndRejectsImages() {
        let pairs: [(Double, Double)] = [(44100, 48000), (44100, 96000), (48000, 96000), (96000, 48000)]
        for (from, to) in pairs {
            for frequency in [100.0, 1000, 5000, 10000, 15000, 18000] {
                let input = Self.sine(frequency: frequency, sampleRate: from, frames: 4096, amplitude: 0.5)
                let output = ETIRPreparation.resample(input, from: from, to: to)
                let fit = Self.fitTone(output, frequency: frequency, sampleRate: to, skip: 256)
                let levelDb = 20 * log10(fit.amplitude / 0.5)
                XCTAssertEqual(levelDb, 0, accuracy: 0.05, "\(from)→\(to) \(frequency)Hz")
                let residualDb = 20 * log10(fit.residualRMS / (fit.amplitude / 2.0.squareRoot()))
                XCTAssertLessThan(residualDb, -60, "\(from)→\(to) \(frequency)Hz")
            }
        }
    }

    /// 落とす側では、行き先のナイキストより上の音は折り返さずに消える。-60dBより下。
    func testResamplerRejectsOutOfBandTonesWhenDownsampling() {
        for (from, to, frequency) in [(96000.0, 48000.0, 30000.0), (96000, 48000, 40000), (192000, 48000, 50000),
                                      (88200, 44100, 26000)] {
            let input = Self.sine(frequency: frequency, sampleRate: from, frames: 8192, amplitude: 0.5)
            let output = ETIRPreparation.resample(input, from: from, to: to)
            let middle = output[256..<(output.count - 256)]
            let rms = (middle.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(middle.count)).squareRoot()
            XCTAssertLessThan(20 * log10(rms / (0.5 / 2.0.squareRoot())), -60, "\(from)→\(to) \(frequency)Hz")
        }
    }

    /// 直流はそのまま通る（位相ごとに係数の和を1へ揃えてある）。値を保つので、スケールしない。
    func testResamplerPassesDCUnscaled() {
        for (from, to) in [(44100.0, 48000.0), (44100, 96000), (48000, 96000), (96000, 48000), (192000, 44100)] {
            let output = ETIRPreparation.resample([Float](repeating: 1, count: 3000), from: from, to: to)
            for i in 300..<(output.count - 300) {
                XCTAssertEqual(output[i], 1, accuracy: 1e-5, "\(from)→\(to) at \(i)")
            }
        }
    }

    /// 長さは上流の_resamplePcmと同じmax(1, round(n·fc/f0))（ir_reverb.js:1510）。
    func testResamplerFrameCount() {
        let cases: [(Int, Double, Double, Int)] = [
            (1000, 44100, 48000, 1088),     // 1088.435
            (441, 44100, 48000, 480),
            (1000, 48000, 96000, 2000),
            (1001, 96000, 48000, 501),      // 500.5は上へ
            (3, 96000, 48000, 2),           // 1.5
            (1, 96000, 48000, 1),           // 0.5
            (5, 192000, 48000, 1),          // 1.25
            (1000, 44100, 192000, 4354),    // 4353.74
        ]
        for (frames, from, to, expected) in cases {
            let output = ETIRPreparation.resample([Float](repeating: 0.25, count: frames), from: from, to: to)
            XCTAssertEqual(output.count, expected, "\(frames) \(from)→\(to)")
        }
    }

    /// 丸めて同じレートなら触らない（ir_reverb.js:1508）。
    func testResamplerLeavesMatchingRatesAlone() {
        let input = Self.decaying(frames: 500, seed: 9, level: 0.7)
        XCTAssertEqual(ETIRPreparation.resample(input, from: 48000, to: 48000), input)
        XCTAssertEqual(ETIRPreparation.resample(input, from: 48000.3, to: 48000), input)
        XCTAssertEqual(ETIRPreparation.resampleChannels([input, input], from: 44100, to: 44100), [input, input])
    }

    /// 大きく落とすと係数が長くなるので、表が上限を超えないよう位相を減らす。それでも直流はそのまま通る。
    /// 999983Hz（素数）から1000Hzだと係数は10万本。比の分子どおり位相を1000持つと表は1億個（400MB）になる。
    func testResamplerCapsTheTableForExtremeRatios() {
        let output = ETIRPreparation.resample([Float](repeating: 1, count: 300_000), from: 999_983, to: 1000)
        XCTAssertEqual(output.count, 300)
        for i in 60..<240 {
            XCTAssertEqual(output[i], 1, accuracy: 1e-4, "at \(i)")
        }
    }

    /// 整数でないレートは位相を量子化する経路を通る。それでも大きさを保つ。
    func testResamplerHandlesNonIntegerRates() {
        let input = Self.sine(frequency: 1000, sampleRate: 44100.5, frames: 4096, amplitude: 0.5)
        let output = ETIRPreparation.resample(input, from: 44100.5, to: 48000)
        let fit = Self.fitTone(output, frequency: 1000, sampleRate: 48000, skip: 256)
        XCTAssertEqual(20 * log10(fit.amplitude / 0.5), 0, accuracy: 0.05)
        XCTAssertLessThan(20 * log10(fit.residualRMS / (fit.amplitude / 2.0.squareRoot())), -60)
    }

    // MARK: - 32MiBに収める切り詰め

    /// 末尾2048フレームを0.5 + 0.5·cosで落とす。前は触らず、正規化もし直さない。
    func testTruncationFadesTheLast2048FramesWithoutRenormalizing() {
        let a = (0..<5000).map { Float(0.5 + 0.0001 * Double($0 % 100)) }
        let b = (0..<5000).map { Float(-0.25 + 0.00002 * Double($0)) }
        let (out, truncated) = ETIRPreparation.truncate([a, b], maxFrames: 3000)
        XCTAssertTrue(truncated)
        XCTAssertEqual(out.map(\.count), [3000, 3000])
        let fadeStart = 3000 - 2048
        XCTAssertEqual(Array(out[0][0..<fadeStart]), Array(a[0..<fadeStart]))
        XCTAssertEqual(Array(out[1][0..<fadeStart]), Array(b[0..<fadeStart]))
        for index in [0, 1, 700, 1023, 1500, 2046, 2047] {
            let phase = Double(index) / 2047
            let gain = 0.5 + 0.5 * cos(Double.pi * phase)
            XCTAssertEqual(out[0][fadeStart + index], Float(Double(a[fadeStart + index]) * gain))
            XCTAssertEqual(out[1][fadeStart + index], Float(Double(b[fadeStart + index]) * gain))
        }
        XCTAssertEqual(out[0][2999], 0)
    }

    /// 2048より短く切るときは、残す全体が立ち下がりになる。収まっていれば触らない。
    func testTruncationShorterThanTheFadeAndNoOp() {
        let a = [Float](repeating: 0.5, count: 1000)
        let (short, cut) = ETIRPreparation.truncate([a], maxFrames: 700)
        XCTAssertTrue(cut)
        XCTAssertEqual(short[0].count, 700)
        XCTAssertEqual(short[0][0], 0.5)
        XCTAssertEqual(short[0][699], 0)
        XCTAssertEqual(Double(short[0][349]), 0.5 * (0.5 + 0.5 * cos(Double.pi * 349 / 699)), accuracy: 1e-7)

        let (same, notCut) = ETIRPreparation.truncate([a], maxFrames: 1000)
        XCTAssertFalse(notCut)
        XCTAssertEqual(same[0], a)
        XCTAssertFalse(ETIRPreparation.truncate([a], maxFrames: 5000).truncated)
    }

    // MARK: - 端

    /// 全部0でも落ちない。頭の無音もonsetも0、利得は1、出るのは0だけ。
    func testAllZeroIR() throws {
        let p = try ETIRPreparation.prepare([[Float](repeating: 0, count: 200)], sampleRate: 48000, topology: .mono)
        XCTAssertEqual(p.leadingSilenceFrames, 0)
        XCTAssertEqual(p.onsetFrame, 0)
        XCTAssertEqual(p.initialGains, [1])
        XCTAssertEqual(p.finalGains, [1])
        XCTAssertEqual(p.frames, 199)
        XCTAssertTrue(p.channels[0].allSatisfy { $0 == 0 })
    }

    /// 0の面は利得1のまま（割らない）。もう一方の面はふつうに正規化される。
    func testZeroEnergyChannelKeepsGainOne() throws {
        var options = ETIRPreparation.Options()
        options.directCut = false
        let p = try ETIRPreparation.prepare([Self.decaying(frames: 800, seed: 5, level: 0.6),
                                             [Float](repeating: 0, count: 800)],
                                            sampleRate: 48000, topology: .independent, options: options)
        XCTAssertEqual(p.initialGains[1], 1)
        XCTAssertEqual(p.finalGains[1], 1)
        XCTAssertTrue(p.channels[1].allSatisfy { $0 == 0 })
        XCTAssertEqual(Self.energy(p.channels[0]), 1, accuracy: 1e-5)
    }

    /// 64フレームより短いIRは、残り全体が立ち上がりになる（頭は0、最後は利得1）。
    func testIRShorterThanTheDirectCutFade() throws {
        let source: [Float] = [0, 0, 0.9] + (0..<20).map { Float(0.3 * exp(-Double($0) / 5)) }
        let p = try ETIRPreparation.prepare([source], sampleRate: 48000, topology: .mono)
        XCTAssertEqual(p.sourceStartFrame, 3)
        XCTAssertEqual(p.frames, 20)
        XCTAssertEqual(p.channels[0][0], 0)
        XCTAssertEqual(Double(p.channels[0][19]), Double(source[22] * p.initialGains[0] * p.finalGains[0]), accuracy: 1e-6)
    }

    /// 1フレームだけのIR。開始は長さの内側へ押し戻され、そのまま1フレーム残る。
    func testSingleFrameIR() throws {
        let p = try ETIRPreparation.prepare([[0.5]], sampleRate: 48000, topology: .mono)
        XCTAssertEqual(p.frames, 1)
        XCTAssertEqual(p.sourceStartFrame, 0)
        XCTAssertEqual(p.channels[0], [1])
    }

    /// 上流が弾くものは弾く。
    func testPrepareRejectsWhatUpstreamRejects() {
        let ok = Self.decaying(frames: 100, seed: 6, level: 0.5)
        XCTAssertThrowsError(try ETIRPreparation.prepare([], sampleRate: 48000, topology: .mono))
        XCTAssertThrowsError(try ETIRPreparation.prepare([[]], sampleRate: 48000, topology: .mono))
        XCTAssertThrowsError(try ETIRPreparation.prepare([ok, Array(ok.prefix(50))], sampleRate: 48000, topology: .independent))
        XCTAssertThrowsError(try ETIRPreparation.prepare([ok + [.nan]], sampleRate: 48000, topology: .mono))
        XCTAssertThrowsError(try ETIRPreparation.prepare([ok, ok, ok], sampleRate: 48000, topology: .trueStereo))
        XCTAssertThrowsError(try ETIRPreparation.prepare([ok], sampleRate: 0, topology: .mono))
        XCTAssertThrowsError(try ETIRPreparation.prepare([ok], sampleRate: 48000, topology: .unspecified))
        // 測った範囲が非正規化数だけだと、利得がFloatを溢れてinfになる。上流はbuildIrAssetPayloadが
        // 非有限で投げる（ir-asset-payload.js:28）。monoで選ばない2面目でも同じ（上流は全部の面を見る）。
        let subnormal = [Float](repeating: .leastNonzeroMagnitude, count: 100)
        var noDirectCut = ETIRPreparation.Options()
        noDirectCut.directCut = false
        XCTAssertThrowsError(try ETIRPreparation.prepare([subnormal], sampleRate: 48000, topology: .mono,
                                                         options: noDirectCut))
        XCTAssertThrowsError(try ETIRPreparation.prepare([ok, subnormal], sampleRate: 48000, topology: .mono))
        for (key, value) in [("co", -21.0), ("co", 51), ("dt", 9), ("dt", 401), ("tr", 0.5), ("tr", 101)] {
            var options = ETIRPreparation.Options()
            switch key {
            case "co": options.cutOffsetMs = value
            case "dt": options.decayPercent = value
            default: options.trimPercent = value
            }
            XCTAssertThrowsError(try ETIRPreparation.prepare([ok], sampleRate: 48000, topology: .mono, options: options),
                                 "\(key)=\(value)")
        }
    }

    /// 既定は上流と同じ（ir_reverb.js:37-40）。
    func testDefaultsMatchUpstream() {
        let d = ETIRPreparation.Options.upstreamDefaults
        XCTAssertTrue(d.directCut)
        XCTAssertEqual(d.cutOffsetMs, 0)
        XCTAssertEqual(d.decayPercent, 100)
        XCTAssertEqual(d.trimPercent, 100)
    }

    // MARK: - 面の選び方

    /// emitPreparedIr（ir-preparation.js:462-474）と同じ選び方。
    func testChannelSelection() throws {
        let chs: [[Float]] = [[1], [2], [3], [4]]
        XCTAssertEqual(try ETIRPreparation.selectChannels(chs, topology: .mono, assetChannels: 1), [[1]])
        XCTAssertEqual(try ETIRPreparation.selectChannels(chs, topology: .independent, assetChannels: 2), [[1], [2]])
        XCTAssertEqual(try ETIRPreparation.selectChannels(chs, topology: .trueStereo, assetChannels: 4), chs)
        XCTAssertEqual(try ETIRPreparation.selectChannels(chs, topology: .matrix, assetChannels: 4), chs)
        XCTAssertThrowsError(try ETIRPreparation.selectChannels([[1]], topology: .independent, assetChannels: 2))
    }

    /// stageは伸縮して下ごしらえしてから選ぶ。レートは畳み込みのレート、面は送る分だけ。
    func testStageResamplesPreparesAndSelects() throws {
        let resolved = try ETIRPreparation.resolve(sampleRate: 192000, channelCount: 2, routedChannels: 1,
                                                   channelMode: "auto", latency: "128", convolutionRate: "auto")
        XCTAssertEqual(resolved.topology, .matrix)
        XCTAssertEqual(resolved.convolutionRate, 96000)
        let left = Self.decaying(frames: 4410, seed: 12, level: 0.8, lead: 30)
        let right = Self.decaying(frames: 4410, seed: 13, level: 0.4, lead: 30)
        let staged = try ETIRPreparation.stage([left, right], sourceRate: 44100, resolved: resolved)
        XCTAssertEqual(staged.sampleRate, 96000)
        // matrixは素材の面を全部送る。
        XCTAssertEqual(staged.channels.count, 2)
        // 伸縮後の長さはround(4410·96000/44100) = 9600。そこから頭を落とす。
        XCTAssertEqual(staged.frames, 9600 - staged.sourceStartFrame)

        let mono = try ETIRPreparation.resolve(sampleRate: 48000, channelCount: 2, routedChannels: 2,
                                               channelMode: "mono", latency: "128", convolutionRate: "auto")
        let one = try ETIRPreparation.stage([left, right], sourceRate: 44100, resolved: mono)
        XCTAssertEqual(one.channels.count, 1)
        // 下ごしらえは2面でやっている（上流もonsetを全部の面で見る）。
        XCTAssertEqual(one.initialGains.count, 2)
    }

    /// 素材や畳み込みのレートが上流の幅（1000〜999999Hz）の外なら読まない
    /// （ir-library-limits.js:29-40）。壊れたヘッダの何GHzを通すと、伸縮の係数の表で落ちる。
    func testStageRejectsRatesOutsideTheUpstreamRange() throws {
        let resolved = try ETIRPreparation.resolve(sampleRate: 48000, channelCount: 1, routedChannels: 2,
                                                   channelMode: "auto", latency: "128", convolutionRate: "auto")
        let source = Self.decaying(frames: 100, seed: 14, level: 0.5)
        for rate in [4_294_967_295.0, 1e300, 1_000_000, 999, 0.5, .infinity, .nan] {
            XCTAssertThrowsError(try ETIRPreparation.stage([source], sourceRate: rate, resolved: resolved), "\(rate)") { error in
                guard case ETIRLoadError.unsupportedRate = error else { return XCTFail("\(rate): \(error)") }
                // 文はInt(_:)の範囲外の値でも落ちずに作れる。
                XCTAssertNotNil((error as? LocalizedError)?.errorDescription)
            }
        }
        XCTAssertNoThrow(try ETIRPreparation.stage([source], sourceRate: 1000, resolved: resolved))
        XCTAssertNoThrow(try ETIRPreparation.stage([source], sourceRate: 999_999, resolved: resolved))
        // 処理レートが低すぎて畳み込みのレートが1000Hzを切るときも同じ。
        let low = try ETIRPreparation.resolve(sampleRate: 1500, channelCount: 1, routedChannels: 2,
                                              channelMode: "auto", latency: "128", convolutionRate: "half")
        XCTAssertEqual(low.convolutionRate, 750)
        XCTAssertThrowsError(try ETIRPreparation.stage([source], sourceRate: 48000, resolved: low))
    }

    // MARK: - 解決

    /// ir-plugin-contract.js:104-206の規則。
    func testResolveRateRules() throws {
        func resolve(_ rate: Double, _ mode: String = "auto", latency: String = "128") throws -> ETIRPreparation.Resolved {
            try ETIRPreparation.resolve(sampleRate: rate, channelCount: 2, routedChannels: 2,
                                        channelMode: "auto", latency: latency, convolutionRate: mode)
        }
        // Autoは88.2kHz以上でhalf。
        XCTAssertEqual(try resolve(44100).rateDivider, 1)
        XCTAssertEqual(try resolve(48000).rateDivider, 1)
        XCTAssertEqual(try resolve(48000).convolutionRate, 48000)
        for rate in [88200.0, 96000, 176400, 192000] {
            let r = try resolve(rate)
            XCTAssertEqual(r.rateDivider, 2, "\(rate)")
            XCTAssertEqual(r.rateMode, "half")
            XCTAssertEqual(r.convolutionRate, Int(rate / 2))
        }
        // Latency 0はfullしか取らない。
        for mode in ["auto", "half", "quarter"] {
            XCTAssertEqual(try resolve(192000, mode, latency: "0").rateDivider, 1, mode)
        }
        // quarterは176.4kHz以上だけ。
        XCTAssertThrowsError(try resolve(96000, "quarter"))
        XCTAssertThrowsError(try resolve(176399, "quarter"))
        XCTAssertEqual(try resolve(176400, "quarter").rateDivider, 4)
        XCTAssertEqual(try resolve(176400, "quarter").convolutionRate, 44100)
        XCTAssertEqual(try resolve(192000, "quarter").convolutionRate, 48000)
        XCTAssertEqual(try resolve(96000, "full").convolutionRate, 96000)
        XCTAssertEqual(try resolve(192000, "quarter").processingRate, 192000)
        // 丸めはMath.round（0.5は上へ）。
        XCTAssertEqual(try resolve(88201, "half").convolutionRate, 44101)
        // 知らない綴りは弾く。
        XCTAssertThrowsError(try resolve(48000, "double"))
        XCTAssertThrowsError(try resolve(48000, latency: "64"))
        XCTAssertThrowsError(try resolve(0))
        XCTAssertThrowsError(try resolve(.nan))
    }

    func testResolveChannelRules() throws {
        func resolve(_ channels: Int, _ routed: Int, _ mode: String = "auto") throws -> ETIRPreparation.Resolved {
            try ETIRPreparation.resolve(sampleRate: 48000, channelCount: channels, routedChannels: routed,
                                        channelMode: mode, latency: "128", convolutionRate: "auto")
        }
        let mono = try resolve(1, 2)
        XCTAssertEqual(mono.topology, .mono)
        XCTAssertEqual(mono.assetChannels, 1)
        let ts = try resolve(4, 2)
        XCTAssertEqual(ts.topology, .trueStereo)
        XCTAssertEqual(ts.assetChannels, 4)
        let indep = try resolve(2, 2)
        XCTAssertEqual(indep.topology, .independent)
        XCTAssertEqual(indep.assetChannels, 2)
        let multi = try resolve(3, 2)
        XCTAssertEqual(multi.topology, .matrix)
        XCTAssertEqual(multi.assetChannels, 3)
        XCTAssertEqual(multi.paths.map(\.irChannel), [0, 1])
        XCTAssertEqual(multi.paths.map(\.inputSlot), [0, 1])
        XCTAssertEqual(multi.paths.map(\.outputSlot), [0, 1])
        // indepは処理幅ぶんの面が要る。多ければ先頭から。
        XCTAssertThrowsError(try resolve(1, 2, "indep"))
        XCTAssertEqual(try resolve(4, 2, "indep").assetChannels, 2)
        // True Stereoは4面と2chの組だけ。
        XCTAssertThrowsError(try resolve(2, 2, "true"))
        XCTAssertThrowsError(try resolve(4, 1, "true"))
        XCTAssertThrowsError(try resolve(2, 2, "stereo"))
        XCTAssertThrowsError(try resolve(0, 2))
        XCTAssertThrowsError(try resolve(17, 2))
        XCTAssertThrowsError(try resolve(2, 0))
    }

    // MARK: - 道具

    /// 決まった乱数（LCG）。-1〜1。
    private struct Random {
        var state: UInt32
        mutating func next() -> Double {
            state = state &* 1_664_525 &+ 1_013_904_223
            return Double(state) / 4_294_967_296 * 2 - 1
        }
    }

    /// 頭にlead個の0、直接音、減衰する雑音。
    private static func decaying(frames: Int, seed: UInt32, level: Double, lead: Int = 0) -> [Float] {
        var random = Random(state: seed)
        var out = [Float](repeating: 0, count: frames)
        guard lead < frames else { return out }
        out[lead] = Float(level)
        for i in (lead + 1)..<frames {
            out[i] = Float(0.4 * level * random.next() * exp(-Double(i - lead) / 400))
        }
        return out
    }

    /// 部屋らしいIR。0.3秒。頭に10フレームの0、直接音、5ms空けて、4kHzの1次を4段通した
    /// 減衰する雑音（RT60 0.3秒）。20kHzより上はほとんど無い（実際の部屋のIRもそう）。
    /// Direct Cutの立ち上がり（fcで64フレーム）に残響が掛からないよう、直接音の後を空けてある。
    private static func roomIR(sampleRate: Double, seed: UInt32) -> [Float] {
        let frames = Int(0.3 * sampleRate)
        let lead = 10
        let start = lead + Int(0.005 * sampleRate)
        var random = Random(state: seed)
        var out = [Float](repeating: 0, count: frames)
        out[lead] = 0.5
        let a = 1 - exp(-2 * Double.pi * 4000 / sampleRate)
        var stages = [Double](repeating: 0, count: 4)
        for i in 0..<frames {
            var x = random.next()
            for s in 0..<4 {
                stages[s] += a * (x - stages[s])
                x = stages[s]
            }
            if i >= start {
                let t = Double(i - start) / sampleRate
                out[i] = Float(0.8 * x * exp(-6.907755 * t / 0.3))
            }
        }
        return out
    }

    /// 明るいIR。roomIRと同じ形で、雑音を低域に通さない（ナイキストまで平ら）。
    /// 合成したリバーブや、SerumのCrystal Hallのように高域が残るIRの代わり。
    private static func brightIR(sampleRate: Double, seed: UInt32) -> [Float] {
        let frames = Int(0.3 * sampleRate)
        let lead = 10
        let start = lead + Int(0.005 * sampleRate)
        var random = Random(state: seed)
        var out = [Float](repeating: 0, count: frames)
        out[lead] = 0.5
        for i in start..<frames {
            let t = Double(i - start) / sampleRate
            out[i] = Float(0.3 * random.next() * exp(-6.907755 * t / 0.3))
        }
        return out
    }

    private static func energy(_ x: [Float]) -> Double {
        x.reduce(0.0) { $0 + Double($1) * Double($1) }
    }

    private static func sine(frequency: Double, sampleRate: Double, frames: Int, amplitude: Double) -> [Float] {
        (0..<frames).map { Float(amplitude * sin(2 * Double.pi * frequency * Double($0) / sampleRate)) }
    }

    /// centerの±width（既定10%）を21点。|Σ y[n]·e^{-jωn}|²の平均。
    private static func bandPower(_ y: [Float], sampleRate: Double, center: Double, width: Double = 0.1) -> Double {
        let points = 21
        var total = 0.0
        for k in 0..<points {
            let f = center * (1 - width + 2 * width * Double(k) / Double(points - 1))
            let w = 2 * Double.pi * f / sampleRate
            let c = cos(w)
            let s = sin(w)
            var re = 0.0
            var im = 0.0
            var pr = 1.0
            var pi = 0.0
            for v in y {
                re += Double(v) * pr
                im -= Double(v) * pi
                (pr, pi) = (pr * c - pi * s, pr * s + pi * c)
            }
            total += re * re + im * im
        }
        return total / Double(points)
    }

    /// 両端skip個を除いてa·cos + b·sinを最小二乗で当てる。振幅と、当てた後の残りのRMS。
    private static func fitTone(_ y: [Float], frequency: Double, sampleRate: Double, skip: Int) -> (amplitude: Double, residualRMS: Double) {
        let range = skip..<(y.count - skip)
        var cc = 0.0, ss = 0.0, cs = 0.0, yc = 0.0, ys = 0.0
        for i in range {
            let phase = 2 * Double.pi * frequency * Double(i) / sampleRate
            let c = cos(phase), s = sin(phase), v = Double(y[i])
            cc += c * c; ss += s * s; cs += c * s; yc += v * c; ys += v * s
        }
        let det = cc * ss - cs * cs
        let a = (yc * ss - ys * cs) / det
        let b = (ys * cc - yc * cs) / det
        var residual = 0.0
        for i in range {
            let phase = 2 * Double.pi * frequency * Double(i) / sampleRate
            let r = Double(y[i]) - (a * cos(phase) + b * sin(phase))
            residual += r * r
        }
        return ((a * a + b * b).squareRoot(), (residual / Double(range.count)).squareRoot())
    }
}
