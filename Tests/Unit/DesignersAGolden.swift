//  DesignersAGolden.swift
//  5Band FIR PEQ・FIR Crossover・Bass Managementの見本（Tests/Fixtures/Designers/designers-a-golden.json）を
//  読む型と、係数を見本の要約と照合する道具。見本はTools/golden/designers_a_golden.mjsが上流に作らせる:
//
//    root=$(bash Tools/golden/extract_pin.sh)
//    EFFETUNE_ROOT="$root" node Tools/golden/designers_a_golden.mjs
//
//  見本のFFTはDoubleの基数2（上流のset*FftBackendで差し替え）なので、Swift（FIRDesign.RealFFT）とは
//  Doubleの丸めの差しか無い。係数はどちらもFloatへ落としてから比べるので、許す幅は
//  「Floatの2ulp」か「最大の係数の1e-12」の大きいほう。
//  応答の曲線は線形の振幅で比べる（深い阻止域ではFloatの1ulpの差がdBで大きく見えるため）。
//  帯域1本の式と5Band FIR PEQの狙いの曲線（Doubleのまま）は対数で比べる。libmの1ulpの差が
//  桁落ちとslope/12乗で膨らむため（BandFIRPEQDesignTests.testRBJPerTypeMatchesUpstream・
//  testDesignMatchesUpstream）。最大誤差はFloatの係数の丸めで動く分を許す（同じ試験の注）。

import XCTest

struct DesignersAGolden: Decodable {
    let bandFirPeq: BandFIRPEQ
    let firCrossover: Crossover
    let bassManagement: Bass

    /// 係数の要約（見本は全部を書かない）。頭48個・真ん中48個・等間隔48点と和。
    struct ChannelStats: Decodable {
        let taps: Int
        let head: [Double]
        let midStart: Int
        let mid: [Double]
        let stride: Int
        let strided: [Double]
        let sum: Double
        let sumAbs: Double
        let sumSquares: Double
        let peakIndex: Int
        let peak: Double
    }

    // MARK: 5Band FIR PEQ

    struct BandFIRPEQ: Decodable {
        let magnitude: [Magnitude]
        let designs: [Design]

        struct Magnitude: Decodable {
            let type: String
            let sampleRate: Double
            let center: Double
            let gain: Double
            let q: Double
            let slope: Double
            let frequencies: [Double]
            let magnitudes: [Double]
        }

        struct Band: Decodable {
            let enabled: Bool
            let type: String
            let frequency: Double
            let gain: Double
            let q: Double
            let slope: Double
        }

        struct Input: Decodable {
            let name: String
            let sampleRate: Double
            let taps: Int
            let phase: String
            let bands: [Band]
        }

        struct Config: Decodable {
            let sampleRate: Int
            let taps: Int
            let phase: String
            let eqBands: [Band]
        }

        struct Response: Decodable {
            let indices: [Int]
            let frequencies: [Double]
            let targetDb: [Double]
            let realizedDb: [Double]
        }

        struct Design: Decodable {
            let input: Input
            let config: Config
            let filterDelaySamples: Int
            let resolutionHz: Double
            let qualityWarnings: [String]
            /// 上流の戻り値には無い。見本の生成器がdesign-core.jsを評価し直して控えた値。
            let maximumErrorDb: Double
            let responsePointCount: Int
            let response: Response
            let channel: ChannelStats
        }
    }

    // MARK: FIR Crossover

    struct Crossover: Decodable {
        let lowWeight: [LowWeight]
        let normalize: [Normalize]
        let bandMagnitudes: [BandMagnitudes]
        let designs: [Design]
        let analyze: [Analyze]

        struct LowWeight: Decodable {
            let frequency: Double
            let cutoff: Double
            let slope: Double
            let weight: Double
        }

        /// 上流が正規化した後の形（normalizeConfigの戻り値）。
        struct Config: Decodable {
            let sampleRate: Int
            let taps: Int
            let phase: String
            let bandCount: Int
            let frequencies: [Double]
            let slopes: [Int]
        }

        /// 正規化の前。nullはNaN（JSONにNaNを書けないため）。
        struct Input: Decodable {
            let sampleRate: Double?
            let taps: Int
            let phase: String
            let bandCount: Int
            let frequencies: [Double?]
            let slopes: [Int]
        }

        struct Normalize: Decodable {
            let input: Input
            let config: Config
        }

        struct BandMagnitudes: Decodable {
            let config: Config
            let frequencies: [Double]
            let magnitudes: [[Double]]
        }

        struct LatencyInfo: Decodable {
            let filterDelaySamples: Int
            let resolutionHz: Double
        }

        struct Path: Decodable {
            let inputSlot: UInt32
            let outputSlot: UInt32
            let irChannel: UInt32
        }

        struct DesignInput: Decodable {
            let name: String
            let sampleRate: Double
            let taps: Int
            let phase: String
            let bandCount: Int
            let frequencies: [Double]
            let slopes: [Int]
        }

        struct Design: Decodable {
            let input: DesignInput
            let config: Config
            let latencyInfo: LatencyInfo
            let channels: [ChannelStats]
            let paths: [Path]
            let payloadBytes: Int
            let payloadHead: [UInt8]
        }

        struct Analyze: Decodable {
            let impulse: [Float]
            let sampleRate: Double
            let frequencies: [Double]
            let response: [Float]
        }
    }

    // MARK: Bass Management

    struct Bass: Decodable {
        let configurationError: [ErrorCase]
        let routeSummary: [RouteCase]
        let subOutput: [SubOutputCase]
        let linearInputs: [LinearInputsCase]
        let designRates: [RateCase]
        let designs: [Design]

        struct ErrorCase: Decodable {
            let roles: [Int]
            let routes: [Int]
            let inversions: [Int]
            let subs: Int
            let width: Int
            let message: String
        }

        struct RouteCase: Decodable {
            let roles: [Int]
            let routes: [Int]
            let subs: Int
            let width: Int
            let text: String
        }

        struct Routing: Decodable {
            let roles: [Int]
            let routes: [Int]
            let inversions: [Int]
            let subs: Int
        }

        struct SubOutputCase: Decodable {
            let before: Routing
            let width: Int
            let channel: Int
            let enabled: Bool
            let after: Routing
        }

        struct LinearInputsCase: Decodable {
            let roles: [Int]
            let lfeLowpass: Bool
            let width: Int
            let inputs: [Int]
        }

        struct RateCase: Decodable {
            let sampleRate: Double
            let normalized: Int
        }

        struct DesignInput: Decodable {
            let name: String
            let sampleRate: Double
            let width: Int
            let tapsIndex: Int
            let roles: [Int]
            let frequencies: [Double]
            let slopes: [Int]
            let lfeLowpass: Bool
            let lfeFrequency: Double
            let lfeSlope: Int
        }

        struct LatencyInfo: Decodable {
            let filterDelaySamples: Int
            let blockDelaySamples: Int
            let totalDelaySamples: Int
            let resolutionHz: Double
        }

        struct Design: Decodable {
            let input: DesignInput
            let sampleRate: Int
            let taps: Int
            let inputChannels: [Int]
            let responseFrequencies: [Double]
            let responses: [[Float]]
            let latencyInfo: LatencyInfo
            let payloadBytes: Int
            let payloadHead: [UInt8]
            let channels: [ChannelStats]
        }
    }

    // MARK: 読む

    private static let lock = NSLock()
    private static var cached: DesignersAGolden?

    static func load(file: StaticString = #filePath, line: UInt = #line) throws -> DesignersAGolden {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let url = try XCTUnwrap(TestResource.url("designers-a-golden", "json", subdirectory: nil),
                                "Tests/Fixtures/Designers/designers-a-golden.json が無い", file: file, line: line)
        let golden = try JSONDecoder().decode(DesignersAGolden.self, from: Data(contentsOf: url))
        cached = golden
        return golden
    }
}

// MARK: - 照合の道具

enum DesignerMatch {

    /// 相対と絶対の大きいほうで許す。
    static func close(_ a: Double, _ b: Double, relative: Double, absolute: Double = 0) -> Bool {
        if a == b { return true }
        guard a.isFinite, b.isFinite else { return false }
        return abs(a - b) <= max(absolute, relative * max(abs(a), abs(b)))
    }

    /// 振幅を対数（dBと同じ尺度）で比べる: |ln a − ln b| ≤ tolerance。
    /// 0以下や有限でない値が混ざるときは完全一致だけを通す。
    static func logClose(_ a: Double, _ b: Double, tolerance: Double) -> Bool {
        if a == b { return true }
        guard a > 0, b > 0, a.isFinite, b.isFinite else { return false }
        return abs(log(a) - log(b)) <= tolerance
    }

    /// Floatへ落とした係数1つ。2ulpか、最大の係数の1e-12の大きいほう。
    static func coefficientClose(_ a: Float, _ b: Double, peak: Double) -> Bool {
        let expected = Float(b)
        let slack = max(2 * Double(expected.ulp), 1e-12 * max(1, abs(peak)))
        return abs(Double(a) - b) <= slack
    }

    /// 係数をまるごと見本の要約と照合する。
    static func assertChannel(_ channel: [Float],
                              matches stats: DesignersAGolden.ChannelStats,
                              _ label: String,
                              file: StaticString = #filePath,
                              line: UInt = #line) {
        XCTAssertEqual(channel.count, stats.taps, "\(label) taps", file: file, line: line)
        guard channel.count == stats.taps, stats.taps > 0 else { return }

        func check(_ index: Int, _ expected: Double, _ part: String) {
            guard channel.indices.contains(index) else {
                return XCTFail("\(label) \(part)[\(index)] が範囲外", file: file, line: line)
            }
            if !coefficientClose(channel[index], expected, peak: stats.peak) {
                XCTFail("\(label) \(part) h[\(index)] = \(channel[index])、上流は \(expected)", file: file, line: line)
            }
        }
        for (offset, expected) in stats.head.enumerated() { check(offset, expected, "head") }
        for (offset, expected) in stats.mid.enumerated() { check(stats.midStart + offset, expected, "mid") }
        for (k, expected) in stats.strided.enumerated() { check(k * stats.stride, expected, "strided") }

        var sum = 0.0
        var sumAbs = 0.0
        var sumSquares = 0.0
        var peakIndex = 0
        for (index, value) in channel.enumerated() {
            let v = Double(value)
            sum += v
            sumAbs += abs(v)
            sumSquares += v * v
            if abs(value) > abs(channel[peakIndex]) { peakIndex = index }
        }
        // 和は全部の係数の丸めの差が積もる。1本あたり最大の係数の1e-12として数える。
        let scale = 1e-12 * Double(stats.taps) * max(1, abs(stats.peak)) + 1e-9 * stats.sumAbs
        XCTAssertEqual(sum, stats.sum, accuracy: scale, "\(label) Σh", file: file, line: line)
        XCTAssertEqual(sumAbs, stats.sumAbs, accuracy: scale, "\(label) Σ|h|", file: file, line: line)
        XCTAssertEqual(sumSquares, stats.sumSquares, accuracy: scale, "\(label) Σh²", file: file, line: line)
        XCTAssertEqual(peakIndex, stats.peakIndex, "\(label) 最大の位置", file: file, line: line)
        XCTAssertTrue(coefficientClose(channel[peakIndex], stats.peak, peak: stats.peak),
                      "\(label) 最大 \(channel[peakIndex])、上流は \(stats.peak)", file: file, line: line)
    }

    /// 振幅（線形）。Floatの係数の1ulpの差がFFTの全binへ広がる分（~1e-7）を許す。
    static func magnitudeClose(_ a: Double, _ b: Double) -> Bool {
        close(a, b, relative: 1e-9, absolute: 1e-6)
    }

    /// ペイロードのfloat32（リトルエンディアン）を読む。
    static func floats(in payload: [UInt8], from offset: Int, count: Int) -> [Float] {
        guard offset >= 0, count >= 0, offset + count * 4 <= payload.count else { return [] }
        return (0..<count).map { index in
            let base = offset + index * 4
            let bits = UInt32(payload[base])
                | (UInt32(payload[base + 1]) << 8)
                | (UInt32(payload[base + 2]) << 16)
                | (UInt32(payload[base + 3]) << 24)
            return Float(bitPattern: bits)
        }
    }
}
