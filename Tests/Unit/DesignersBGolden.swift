//  DesignersBGolden.swift
//  Group Delay EQ / Group Delay PEQ / Crosstalk / Room EQ の設計と onset の見本を読む。
//
//  見本は Tests/Fixtures/Designers/designers-b-golden.json。上流の design-core.js そのものが
//  吐いたもので、作り直すときは
//      root=$(bash Tools/golden/extract_pin.sh)
//      EFFETUNE_ROOT="$root" node Tools/golden/designers_b_golden.mjs
//  上流の FFT は回転因子を Float32Array に持つが、見本を作るときだけ同じ式の double に
//  差し替えてある（生成器の頭を参照）。だから FFT を通る設計も 1e-7 より細かく比べられる。
//
//  数の並びは {"f32": base64} か {"f64": base64}（リトルエンディアン）で入っている。

import XCTest
import Foundation

struct DesignersBGolden: Decodable {

    // MARK: - 並び

    /// {"f32": ...} か {"f64": ...}。どちらでも Double / Float で取り出せる。
    struct Numbers: Decodable {
        let f32: String?
        let f64: String?

        var doubles: [Double] {
            if let f64 { return Self.decode(f64, width: 8).map { Double(bitPattern: $0) } }
            if let f32 { return Self.decode(f32, width: 4).map { Double(Float(bitPattern: UInt32($0))) } }
            return []
        }

        var floats: [Float] {
            if let f32 { return Self.decode(f32, width: 4).map { Float(bitPattern: UInt32($0)) } }
            return doubles.map { Float($0) }
        }

        private static func decode(_ base64: String, width: Int) -> [UInt64] {
            guard let data = Data(base64Encoded: base64) else { return [] }
            let bytes = [UInt8](data)
            return (0..<bytes.count / width).map { index in
                var bits: UInt64 = 0
                for byte in 0..<width {
                    bits |= UInt64(bytes[index * width + byte]) << (8 * UInt64(byte))
                }
                return bits
            }
        }
    }

    // MARK: - Group Delay EQ / PEQ

    struct GroupDelayResult: Decodable {
        let ir: Numbers
        let bulkDelaySamples: Double
        let clamped: Bool
        let limitMs: Double
        let rippleDb: Double
        let frequencies: Numbers
        let targetMs: Numbers
        let realizedMs: Numbers
    }

    struct GroupDelayEQTarget: Decodable {
        let name: String
        let delaysMs: [Double]
        let taps: Int
        let sampleRate: Double
        let frequencies: Numbers?
        let expected: Numbers
    }

    struct GroupDelayEQDesignCase: Decodable {
        let name: String
        let delaysMs: [Double]
        let taps: Int
        let sampleRate: Double
        let expected: GroupDelayResult
    }

    struct GroupDelayEQSet: Decodable {
        let targets: [GroupDelayEQTarget]
        let designs: [GroupDelayEQDesignCase]
    }

    struct PEQBand: Decodable {
        let type: String
        let frequency: Double
        let delayMs: Double
        let q: Double
        let enabled: Bool
    }

    struct GroupDelayPEQTarget: Decodable {
        let name: String
        let bands: [PEQBand]
        let taps: Int
        let sampleRate: Double
        let frequencies: Numbers?
        let expected: Numbers
    }

    struct GroupDelayPEQDesignCase: Decodable {
        let name: String
        let bands: [PEQBand]
        let taps: Int
        let sampleRate: Double
        let expected: GroupDelayResult
    }

    struct GroupDelayPEQSet: Decodable {
        let targets: [GroupDelayPEQTarget]
        let designs: [GroupDelayPEQDesignCase]
    }

    // MARK: - Crosstalk

    struct SolveCase: Decodable {
        struct Solution: Decodable {
            let c11: [Double]
            let c21: [Double]
            let c12: [Double]
            let c22: [Double]
        }
        let name: String
        let hLL: [Double]
        let hLR: [Double]
        let hRL: [Double]
        let hRR: [Double]
        let targetLL: [Double]
        let targetRR: [Double]
        let beta: Double
        let expected: Solution
    }

    struct SmoothCase: Decodable {
        struct Spectrum: Decodable {
            let real: Numbers
            let imag: Numbers
        }
        let name: String
        let fftSize: Int
        let sampleRate: Double
        let delaySeconds: Double
        let smoothingOctaves: Double?
        let real: Numbers
        let imag: Numbers
        let expected: Spectrum
    }

    struct Measurement: Decodable {
        let id: String
        let data: Numbers
        let sampleRate: Int
        let trimStartSamples: Int
        let onsetIndex: Int
        let referenceScale: Double
        let timeReference: String
    }

    struct Sources: Decodable {
        let ll: Measurement
        let lr: Measurement
        let rl: Measurement
        let rr: Measurement
    }

    struct ValidateCase: Decodable {
        struct Expected: Decodable {
            let code: String?
            let slot: String?
            let message: String?
            let sampleRate: Int?
            let ids: [String: String]?
        }
        let name: String
        let sources: Sources
        let expected: Expected
    }

    struct CrosstalkConfig: Decodable {
        let sampleRate: Int
        let taps: Int
        let regularization: Double
        let maxGainDb: Double
        let lowFrequency: Double
        let highFrequency: Double
        let directWindowMs: Double
        let filterDelaySamples: Int?
    }

    struct CrosstalkDiagnostics: Decodable {
        let fftSize: Int
        let measurementSampleRate: Int
        let maxGainLinear: Double
        let maxGainDb: Double
        let maxGainLimitDb: Double
        let gainLimitActive: Bool
        let gainLimitedBins: Int
        let outOfWindowEnergyRatio: Double
        let outOfWindowWarningThreshold: Double
        let tapsWarning: Bool
        let requestedLowFrequency: Double
        let effectiveLowFrequency: Double
        let lowFrequencyClamped: Bool
        let effectiveHighFrequency: Double
        let normalizationScale: Double
    }

    struct CrosstalkDesignCase: Decodable {
        struct Expected: Decodable {
            let channels: [Numbers]
            let config: CrosstalkConfig
            let diagnostics: CrosstalkDiagnostics
        }
        let name: String
        let config: CrosstalkConfig
        let sources: Sources
        let expected: Expected
    }

    struct CrosstalkSet: Decodable {
        let solveBin: [SolveCase]
        let smooth: [SmoothCase]
        let validate: [ValidateCase]
        let designs: [CrosstalkDesignCase]
    }

    // MARK: - Room EQ

    struct SoftLimitCase: Decodable {
        let decibels: Double
        let maximum: Double
        let expected: Double
    }

    struct RoomBand: Decodable {
        let enabled: Bool
        let type: String
        let frequency: Double
        let gain: Double
        let q: Double
    }

    struct RoomConfig: Decodable {
        let sampleRate: Int
        let taps: Int
        let phase: String?
        let smoothing: Double
        let lowFrequency: Double
        let highFrequency: Double
        let maxBoostDb: Double
        let correctionAmount: Double
        let eqBands: [RoomBand]?
    }

    struct RoomImpulse: Decodable {
        let data: Numbers
        let sampleRate: Int
        let onsetIndex: Int
        let referenceScale: Double
    }

    struct RoomPoint: Decodable {
        let frequency: Double
        let decibels: Double
    }

    struct RoomSource: Decodable {
        let impulses: [RoomImpulse]
        let frequencyResponse: [RoomPoint]
    }

    struct RoomDesignCase: Decodable {
        struct Expected: Decodable {
            let channels: [Numbers]
            let filterDelaySamples: Int
            let resolutionHz: Double
            let supportsFullPhase: Bool
            let qualityWarnings: [String]
            let referenceLevelDb: [Double?]
            let previews: [RoomPreview?]
            let config: RoomConfig
        }
        let name: String
        let config: RoomConfig
        let sources: [RoomSource?]
        let expected: Expected
    }

    /// 画面の曲線（design-core.js の previews）。
    struct RoomPreview: Decodable {
        struct Curves: Decodable {
            let before: Numbers
            let after: Numbers
        }
        struct Impulse: Decodable {
            let startMs: Double
            let durationMs: Double
            let before: Numbers
            let after: Numbers
        }
        let frequencyCount: Int
        let measuredDb: Numbers
        let baseCorrectionDb: Numbers
        let predictedBaseDb: Numbers
        let phase: Curves?
        let minimumGroupDelay: Curves?
        let excessGroupDelay: Curves?
        let impulse: Impulse?
    }

    struct RoomEQSet: Decodable {
        let softLimitBoost: [SoftLimitCase]
        let designs: [RoomDesignCase]
    }

    // MARK: - onset

    struct OnsetCase: Decodable {
        let name: String
        let samples: Numbers
        let sampleRate: Int
        let expected: Int
    }

    // MARK: - 中身

    let upstreamVersion: String
    let groupDelayEq: GroupDelayEQSet
    let groupDelayPeq: GroupDelayPEQSet
    let crosstalk: CrosstalkSet
    let roomEq: RoomEQSet
    let onset: [OnsetCase]

    /// 1 回だけ読んで使い回す（50 万字ほどある）。
    private static let cached: Result<DesignersBGolden, Error> = Result {
        guard let url = TestResource.url("designers-b-golden", "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(DesignersBGolden.self, from: Data(contentsOf: url))
    }

    static func load() throws -> DesignersBGolden {
        try cached.get()
    }

    // MARK: - 比べる

    /// 差の絶対値の最大。長さが違えば無限大。
    static func maxAbsDiff(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count else { return .infinity }
        var worst = 0.0
        for (x, y) in zip(a, b) {
            if x.isNaN || y.isNaN {
                if x.isNaN != y.isNaN { return .infinity }
                continue
            }
            worst = max(worst, abs(x - y))
        }
        return worst
    }

    static func maxAbsDiff(_ a: [Float], _ b: [Float]) -> Double {
        maxAbsDiff(a.map { Double($0) }, b.map { Double($0) })
    }

    /// 最大値で割った差。値の大きさが桁で違う並び（係数・スペクトル）に使う。
    static func maxRelativeDiff(_ a: [Double], _ b: [Double]) -> Double {
        let scale = max(b.map { abs($0) }.max() ?? 0, 1e-300)
        return maxAbsDiff(a, b) / scale
    }
}
