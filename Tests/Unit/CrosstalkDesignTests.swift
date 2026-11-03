//  CrosstalkDesignTests.swift
//  Crosstalk Cancellation の設計（CrosstalkDesign.swift の CrosstalkCancellationDesigner）。
//  **実機もエンジンも要らない。**
//
//  約束は 3 つ。
//    1. 測定の検査は上流の validateCrosstalkSources と同じ順番・同じ code・同じ文面で落ちる。
//    2. 1 ビンの解（solveRegularizedCrosstalkBin）と遅延を外した平滑
//       （smoothDelayCompensatedSpectrum）は上流の export と 1e-12 で一致する。
//    3. 4 つの測定から作る 4 本の FIR（C11/C21/C12/C22）・倒した設定・診断が上流と同じ。
//       見本は 44.1kHz→48kHz と 48kHz→96kHz（リサンプラの伸ばす側）、96kHz→48kHz と
//       192kHz→44.1kHz（間引く側）、範囲外の設定、利得の頭打ちを含む。

import XCTest
import Foundation

final class CrosstalkDesignTests: XCTestCase {

    typealias Designer = CrosstalkCancellationDesigner

    // MARK: - 組み立て

    private func measurement(_ golden: DesignersBGolden.Measurement) throws -> Designer.Measurement {
        Designer.Measurement(id: golden.id,
                             data: golden.data.doubles,
                             sampleRate: golden.sampleRate,
                             trimStartSamples: golden.trimStartSamples,
                             onsetIndex: golden.onsetIndex,
                             referenceScale: golden.referenceScale,
                             timeReference: try XCTUnwrap(Designer.TimeReference(rawValue: golden.timeReference)))
    }

    private func sources(_ golden: DesignersBGolden.Sources) throws -> Designer.Sources {
        Designer.Sources(ll: try measurement(golden.ll),
                         lr: try measurement(golden.lr),
                         rl: try measurement(golden.rl),
                         rr: try measurement(golden.rr))
    }

    /// 片耳ずつ 1 回の測定（id の `::ch=` の前が同じ）で、4 枠とも別のチャンネル。
    private func validSources(rate: Int = 48000) -> Designer.Sources {
        func m(_ id: String, _ rate: Int) -> Designer.Measurement {
            Designer.Measurement(id: id, data: [0, 1, 0.5, 0], sampleRate: rate,
                                 trimStartSamples: 0, onsetIndex: 1)
        }
        return Designer.Sources(ll: m("left::ch=left", rate), lr: m("right::ch=left", rate),
                                rl: m("left::ch=right", rate), rr: m("right::ch=right", rate))
    }

    private func code(of body: () throws -> Void) -> String? {
        do {
            try body()
            return nil
        } catch let error as Designer.DesignError {
            return error.code
        } catch {
            return "unexpected \(error)"
        }
    }

    // MARK: - 測定の検査

    /// 同じチャンネルを 2 枠に割り当てると落ちる。
    func testValidateDuplicateIds() {
        var sources = validSources()
        sources.lr.id = sources.ll.id
        XCTAssertEqual(code { _ = try Designer.validate(sources) }, "duplicate-measurement-assignment")
        // 前後の空白は落としてから比べる。
        sources = validSources()
        sources.rr.id = "  " + sources.rl.id + "\n"
        XCTAssertEqual(code { _ = try Designer.validate(sources) }, "duplicate-measurement-assignment")
    }

    /// 4 枠のレートが揃っていないと落ちる。揃っていればそのレートを返す。
    func testValidateMixedRates() throws {
        var sources = validSources()
        sources.rr.sampleRate = 44100
        XCTAssertEqual(code { _ = try Designer.validate(sources) }, "sample-rate-mismatch")
        XCTAssertEqual(try Designer.validate(validSources(rate: 96000)).sampleRate, 96000)
    }

    /// 上流と同じ順番・code・枠・文面で落ちる。通るときは空白を落とした id とレートを返す。
    func testValidateMatchesUpstream() throws {
        let golden = try DesignersBGolden.load()
        XCTAssertGreaterThanOrEqual(golden.crosstalk.validate.count, 13)
        for entry in golden.crosstalk.validate {
            let input = try sources(entry.sources)
            let e = entry.expected
            do {
                let result = try Designer.validate(input)
                XCTAssertNil(e.code, "\(entry.name): 上流は \(e.code ?? "") で落ちる")
                XCTAssertEqual(result.sampleRate, e.sampleRate, entry.name)
                let ids = try XCTUnwrap(e.ids, entry.name)
                XCTAssertEqual(result.sources.ll.id, ids["ll"], entry.name)
                XCTAssertEqual(result.sources.lr.id, ids["lr"], entry.name)
                XCTAssertEqual(result.sources.rl.id, ids["rl"], entry.name)
                XCTAssertEqual(result.sources.rr.id, ids["rr"], entry.name)
            } catch let error as Designer.DesignError {
                XCTAssertEqual(error.code, e.code, entry.name)
                XCTAssertEqual(error.slot?.rawValue, e.slot, entry.name)
                XCTAssertEqual(error.message, e.message, entry.name)
                XCTAssertEqual(error.errorDescription, e.message, entry.name)
            }
        }
    }

    /// `::ch=` の前が測定の id。先頭に在るときは切らない（上流の lastIndexOf > 0）。
    func testBaseMeasurementId() {
        XCTAssertEqual(Designer.baseMeasurementId("abc::ch=left"), "abc")
        XCTAssertEqual(Designer.baseMeasurementId("a::ch=x::ch=y"), "a::ch=x")
        XCTAssertEqual(Designer.baseMeasurementId("::ch=left"), "::ch=left")
        XCTAssertEqual(Designer.baseMeasurementId("plain"), "plain")
        XCTAssertEqual(Designer.baseMeasurementId(""), "")
    }

    // MARK: - 1 ビンと平滑

    /// C = (H^H H + βI)^-1 H^H D。上流の export と 1e-12（相対）で一致する。
    func testSolveRegularizedBinMatchesUpstream() throws {
        let golden = try DesignersBGolden.load()
        XCTAssertGreaterThanOrEqual(golden.crosstalk.solveBin.count, 5)
        func cx(_ pair: [Double]) -> Designer.Cx { Designer.Cx(pair[0], pair[1]) }
        for entry in golden.crosstalk.solveBin {
            let solution = Designer.solveRegularizedCrosstalkBin(hLL: cx(entry.hLL), hLR: cx(entry.hLR),
                                                                  hRL: cx(entry.hRL), hRR: cx(entry.hRR),
                                                                  targetLL: cx(entry.targetLL),
                                                                  targetRR: cx(entry.targetRR),
                                                                  beta: entry.beta)
            let got = [solution.c11, solution.c21, solution.c12, solution.c22].flatMap { [$0.re, $0.im] }
            let e = entry.expected
            let want = e.c11 + e.c21 + e.c12 + e.c22
            XCTAssertLessThanOrEqual(DesignersBGolden.maxRelativeDiff(got, want), 1e-12, entry.name)
        }
    }

    /// 解の性質: β → 0 で H が逆に解け（H·C = D）、β が大きいほど解が小さくなる。
    func testSolveRegularizedBinLimits() {
        let hLL = Designer.Cx(1, 0.2), hLR = Designer.Cx(0.3, -0.1)
        let hRL = Designer.Cx(0.25, 0.05), hRR = Designer.Cx(0.9, -0.3)
        let tLL = Designer.Cx(0.7, 0.1), tRR = Designer.Cx(-0.2, 0.6)
        let exact = Designer.solveRegularizedCrosstalkBin(hLL: hLL, hLR: hLR, hRL: hRL, hRR: hRR,
                                                          targetLL: tLL, targetRR: tRR, beta: 0)
        // 行が耳、列がスピーカー: 左耳 = H_LL·C11 + H_RL·C21、右耳 = H_LR·C11 + H_RR·C21（左入力）。
        let leftEar = hLL * exact.c11 + hRL * exact.c21
        let rightEar = hLR * exact.c11 + hRR * exact.c21
        XCTAssertEqual(leftEar.re, tLL.re, accuracy: 1e-12)
        XCTAssertEqual(leftEar.im, tLL.im, accuracy: 1e-12)
        XCTAssertEqual(rightEar.re, 0, accuracy: 1e-12)
        XCTAssertEqual(rightEar.im, 0, accuracy: 1e-12)
        let damped = Designer.solveRegularizedCrosstalkBin(hLL: hLL, hLR: hLR, hRL: hRL, hRR: hRR,
                                                           targetLL: tLL, targetRR: tRR, beta: 10)
        XCTAssertLessThan(damped.c11.magnitudeSquared, exact.c11.magnitudeSquared)
    }

    /// 遅延を外して 1/6 オクターブの箱で均し、遅延を戻す。上流の export と 1e-12 で一致する。
    func testSmoothDelayCompensatedMatchesUpstream() throws {
        let golden = try DesignersBGolden.load()
        XCTAssertGreaterThanOrEqual(golden.crosstalk.smooth.count, 4)
        for entry in golden.crosstalk.smooth {
            let spectrum = Designer.Spectrum(real: entry.real.doubles, imag: entry.imag.doubles)
            let result: Designer.Spectrum
            if let octaves = entry.smoothingOctaves {
                result = try Designer.smoothDelayCompensatedSpectrum(spectrum, sampleRate: entry.sampleRate,
                                                                     fftSize: entry.fftSize,
                                                                     delaySeconds: entry.delaySeconds,
                                                                     smoothingOctaves: octaves)
            } else {
                result = try Designer.smoothDelayCompensatedSpectrum(spectrum, sampleRate: entry.sampleRate,
                                                                     fftSize: entry.fftSize,
                                                                     delaySeconds: entry.delaySeconds)
            }
            XCTAssertLessThanOrEqual(DesignersBGolden.maxAbsDiff(result.real, entry.expected.real.doubles),
                                     1e-12, "\(entry.name) real")
            XCTAssertLessThanOrEqual(DesignersBGolden.maxAbsDiff(result.imag, entry.expected.imag.doubles),
                                     1e-12, "\(entry.name) imag")
        }
    }

    /// 2 の冪でない大きさ・負の遅延・長さの合わないスペクトルは invalid-smoothing で落ちる。
    func testSmoothRejectsBadArguments() {
        let good = Designer.Spectrum(real: [Double](repeating: 1, count: 33), imag: [Double](repeating: 0, count: 33))
        XCTAssertEqual(code { _ = try Designer.smoothDelayCompensatedSpectrum(good, sampleRate: 48000, fftSize: 48,
                                                                              delaySeconds: 0) },
                       "invalid-smoothing")
        XCTAssertEqual(code { _ = try Designer.smoothDelayCompensatedSpectrum(good, sampleRate: 48000, fftSize: 64,
                                                                              delaySeconds: -1) },
                       "invalid-smoothing")
        XCTAssertEqual(code { _ = try Designer.smoothDelayCompensatedSpectrum(good, sampleRate: .nan, fftSize: 64,
                                                                              delaySeconds: 0) },
                       "invalid-smoothing")
        XCTAssertEqual(code { _ = try Designer.smoothDelayCompensatedSpectrum(good, sampleRate: 48000, fftSize: 128,
                                                                              delaySeconds: 0) },
                       "invalid-smoothing")
        XCTAssertNil(code { _ = try Designer.smoothDelayCompensatedSpectrum(good, sampleRate: 48000, fftSize: 64,
                                                                            delaySeconds: 0) })
    }

    // MARK: - latencyMode

    /// params.json の lt は選択肢の添字。有限で 0〜15 の値だけ読み、表の外と NaN は 128。
    func testHeadBlockNaNNegative16() {
        let cases: [(Float, UInt32)] = [
            (0, 0), (1, 128), (2, 256), (3, 512), (4, 1024), (4.4, 1024), (1.6, 256),
            (5, 128), (15.9, 128), (16, 128), (-1, 128), (-0.4, 128),
            (.nan, 128), (.infinity, 128), (-.infinity, 128), (1e30, 128)
        ]
        for (value, want) in cases {
            XCTAssertEqual(Designer.headBlock(forLatencyMode: value), want, "\(value)")
        }
    }

    // MARK: - 設定の倒し方

    /// design-core.js の normalizeConfig と同じ倒し方。
    func testConfigNormalized() {
        var config = Designer.Config()
        config.taps = 3000
        config.sampleRate = 1000
        config.lowFrequency = 5
        config.highFrequency = 500
        config.regularization = .nan
        config.maxGainDb = 99
        config.directWindowMs = .infinity
        let normalized = config.normalized()
        XCTAssertEqual(normalized.taps, 4096)
        XCTAssertEqual(normalized.filterDelaySamples, 2048)
        XCTAssertEqual(normalized.sampleRate, 8000)
        XCTAssertEqual(normalized.lowFrequency, 20)
        XCTAssertEqual(normalized.highFrequency, 1000)
        XCTAssertEqual(normalized.regularization, 50)   // 有限でなければ既定
        XCTAssertEqual(normalized.maxGainDb, 24)
        XCTAssertEqual(normalized.directWindowMs, 8)

        config = Designer.Config()
        config.taps = 16384
        config.sampleRate = 1_000_000
        config.lowFrequency = 1500
        config.highFrequency = 1200
        let other = config.normalized()
        XCTAssertEqual(other.taps, 16384)
        XCTAssertEqual(other.sampleRate, 768000)
        XCTAssertEqual(other.highFrequency, 1500)       // 下端より下にはならない
    }

    // MARK: - 設計まるごと

    /// 4 本の FIR・倒した設定・診断が上流と同じ。
    func testDesignMatchesUpstream() throws {
        let golden = try DesignersBGolden.load()
        XCTAssertGreaterThanOrEqual(golden.crosstalk.designs.count, 3)
        var worst = 0.0
        for entry in golden.crosstalk.designs {
            let c = entry.config
            let config = Designer.Config(sampleRate: c.sampleRate, taps: c.taps, regularization: c.regularization,
                                         maxGainDb: c.maxGainDb, lowFrequency: c.lowFrequency,
                                         highFrequency: c.highFrequency, directWindowMs: c.directWindowMs)
            let design = try Designer.design(config: config, sources: try sources(entry.sources))
            let e = entry.expected

            XCTAssertEqual(design.config.sampleRate, e.config.sampleRate, entry.name)
            XCTAssertEqual(design.config.taps, e.config.taps, entry.name)
            XCTAssertEqual(design.config.filterDelaySamples, e.config.filterDelaySamples, entry.name)
            XCTAssertEqual(design.config.regularization, e.config.regularization, entry.name)
            XCTAssertEqual(design.config.maxGainDb, e.config.maxGainDb, entry.name)
            XCTAssertEqual(design.config.lowFrequency, e.config.lowFrequency, entry.name)
            XCTAssertEqual(design.config.highFrequency, e.config.highFrequency, entry.name)
            XCTAssertEqual(design.config.directWindowMs, e.config.directWindowMs, entry.name)

            XCTAssertEqual(design.channels.count, 4, entry.name)
            XCTAssertEqual(e.channels.count, 4, entry.name)
            for (index, (got, want)) in zip(design.channels, e.channels).enumerated() {
                let wanted = want.floats
                XCTAssertEqual(got.count, wanted.count, "\(entry.name) \(Designer.firChannelOrder[index])")
                let diff = DesignersBGolden.maxRelativeDiff(got.map { Double($0) }, wanted.map { Double($0) })
                worst = max(worst, diff)
                XCTAssertLessThanOrEqual(diff, 1e-6, "\(entry.name) \(Designer.firChannelOrder[index])")
            }

            let d = design.diagnostics, w = e.diagnostics
            XCTAssertEqual(d.fftSize, w.fftSize, entry.name)
            XCTAssertEqual(d.measurementSampleRate, w.measurementSampleRate, entry.name)
            XCTAssertEqual(d.maxGainLinear, w.maxGainLinear, accuracy: 1e-9 * max(1, w.maxGainLinear), entry.name)
            XCTAssertEqual(d.maxGainDb, w.maxGainDb, accuracy: 1e-8, entry.name)
            XCTAssertEqual(d.maxGainLimitDb, w.maxGainLimitDb, entry.name)
            XCTAssertEqual(d.gainLimitActive, w.gainLimitActive, entry.name)
            XCTAssertEqual(d.gainLimitedBins, w.gainLimitedBins, entry.name)
            XCTAssertEqual(d.outOfWindowEnergyRatio, w.outOfWindowEnergyRatio,
                           accuracy: 1e-9 * max(1e-3, w.outOfWindowEnergyRatio), entry.name)
            XCTAssertEqual(d.outOfWindowWarningThreshold, w.outOfWindowWarningThreshold, entry.name)
            XCTAssertEqual(d.tapsWarning, w.tapsWarning, entry.name)
            XCTAssertEqual(d.requestedLowFrequency, w.requestedLowFrequency, entry.name)
            XCTAssertEqual(d.effectiveLowFrequency, w.effectiveLowFrequency, entry.name)
            XCTAssertEqual(d.lowFrequencyClamped, w.lowFrequencyClamped, entry.name)
            XCTAssertEqual(d.effectiveHighFrequency, w.effectiveHighFrequency, entry.name)
            XCTAssertEqual(d.normalizationScale, w.normalizationScale, accuracy: 1e-9 * w.normalizationScale,
                           entry.name)
        }
        print("Crosstalk golden: worst channel diff \(worst) of peak")
    }
}
