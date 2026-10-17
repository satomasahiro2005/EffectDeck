//  SkipDetectorTests.swift
//  曲の飛ばしの検出（SkipDetector）。作った音（種を決めた乱数）で、音色が替わる所は飛んだと言い、
//  同じテンポで音量だけ替わる所は飛んでいないと言うこと。
//
//  壊れると: 曲を飛ばしても粒が出ない、曲の中のブレイクやビルドで取得中が出てアートワークが点滅する。

import XCTest

final class SkipDetectorTests: XCTestCase {

    private static let rate = 48_000.0

    /// 作った音の元。A は 120 BPM（キック・ノコギリ・低域のノイズ・裏のハット）、
    /// B は 97 BPM で位相も違う（高域のノイズ・1760Hz の矩形波・クリック）。標本の番号から決まるので位相は続く。
    private struct Source {
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        var lowpassed: Float = 0
        var highpassState: Float = 0

        mutating func noise() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: state >> 11) % 2_000_001) / 1_000_000 - 1
        }

        mutating func a(_ index: Int) -> Float {
            let t = Double(index) / SkipDetectorTests.rate
            let tau = t - (t / 0.5).rounded(.down) * 0.5
            let kick = 0.6 * exp(-tau / 0.1) * sin(2 * Double.pi * 60 * tau)
            let phase = 55 * t
            let saw = 0.15 * (2 * (phase - phase.rounded(.down)) - 1)
            lowpassed += 0.0993 * (noise() - lowpassed)
            let shifted = t - 0.25
            let hatTau = shifted - (shifted / 0.5).rounded(.down) * 0.5
            let hat = shifted >= 0 ? 0.05 * Double(noise()) * exp(-hatTau / 0.02) : 0
            return Float(kick + saw + 0.1 * Double(lowpassed) + hat)
        }

        var pad: Float = 0

        /// 打楽器だけの曲（拍を取りやすい）。キックは 120 BPM（shift 秒ずらせる）。pad は低域に寄ったノイズで、alpha が大きいほど明るい。
        mutating func d(_ index: Int, shift: Double = 0, alpha: Float, padAmp: Double = 0.3) -> Float {
            let t = Double(index) / SkipDetectorTests.rate - shift
            let tau = t - (t / 0.5).rounded(.down) * 0.5
            let kick = 0.6 * exp(-tau / 0.08) * sin(2 * Double.pi * (60 + 40 * exp(-tau / 0.03)) * tau)
            pad += alpha * (noise() - pad)
            return Float(kick + padAmp * Double(pad))
        }

        mutating func b(_ index: Int) -> Float {
            let t = Double(index) / SkipDetectorTests.rate + 0.123
            let n = noise()
            highpassState += 0.25 * (n - highpassState)
            let period = 60.0 / 97
            let tau = t - (t / period).rounded(.down) * period
            let click = 0.5 * Double(noise()) * exp(-tau / 0.003)
            let square: Double = sin(2 * Double.pi * 1760 * t) >= 0 ? 1 : -1
            return Float(0.2 * Double(n - highpassState) + 0.08 * square + click)
        }
    }

    /// 12000 標本ずつ流して、出来事を集める。
    private func run(_ signal: [Float], detector: inout ETSkipDetector) -> [ETSkipDetector.Event] {
        var events: [ETSkipDetector.Event] = []
        var index = 0
        while index < signal.count {
            let end = min(index + 12_000, signal.count)
            events += signal[index..<end].withUnsafeBufferPointer { detector.append($0) }
            index = end
        }
        return events
    }

    private func skips(_ events: [ETSkipDetector.Event]) -> [(boundary: Int64, at: Int64, stage: ETSkipDetector.Stage)] {
        events.compactMap {
            if case .skip(let boundary, let at, _, let stage) = $0 { return (boundary, at, stage) }
            return nil
        }
    }

    private func seconds(_ s: Double) -> Int { Int(s * Self.rate) }

    // MARK: 飛ぶ

    func testAbruptTimbreChangeIsInstantSkip() {
        var source = Source()
        var signal: [Float] = []
        for i in 0..<seconds(4) { signal.append(source.a(i)) }
        for i in seconds(4)..<seconds(6) { signal.append(source.b(i)) }
        var detector = ETSkipDetector()
        let found = skips(run(signal, detector: &detector))
        XCTAssertEqual(found.count, 1)
        guard let skip = found.first else { return }
        XCTAssertEqual(skip.stage, .instant)
        XCTAssertLessThanOrEqual(skip.at, Int64(Double(seconds(4)) + 0.35 * Self.rate + 1024))
        XCTAssertGreaterThanOrEqual(skip.boundary, Int64(3.85 * Self.rate))
        XCTAssertLessThanOrEqual(skip.boundary, Int64(4.10 * Self.rate))
    }

    // MARK: 飛ばない

    func testSameTempoLoudnessDropIsNotSkip() {
        var source = Source()
        var signal: [Float] = []
        for i in 0..<seconds(8) { signal.append(source.a(i) * (i < seconds(4) ? 1 : 0.25)) }
        var detector = ETSkipDetector()
        XCTAssertTrue(skips(run(signal, detector: &detector)).isEmpty)
    }

    func testBuildIsNotSkip() {
        var source = Source()
        var signal: [Float] = []
        for i in 0..<seconds(8) {
            let t = Double(i) / Self.rate
            // 3 秒から 2 秒かけて -18 dB から 0 dB へ（それまでは -18 dB）
            let db = -18 * (1 - min(max((t - 3) / 2, 0), 1))
            signal.append(source.a(i) * Float(pow(10, db / 20)))
        }
        var detector = ETSkipDetector()
        XCTAssertTrue(skips(run(signal, detector: &detector)).isEmpty)
    }

    func testSilenceAndSteadyToneProduceNothing() {
        var detector = ETSkipDetector()
        let silence = [Float](repeating: 0, count: seconds(5))
        XCTAssertTrue(run(silence, detector: &detector).isEmpty)
        let tone = (0..<seconds(5)).map { Float(0.3 * sin(2 * Double.pi * 1000 * Double($0) / Self.rate)) }
        XCTAssertTrue(run(tone, detector: &detector).isEmpty)
        XCTAssertLessThan(detector.takeMaxScore(), ETSkipDetector.confirmThreshold)
        XCTAssertEqual(detector.samplesSeen, Int64(seconds(10)))
        detector.reset()
        XCTAssertEqual(detector.samplesSeen, 0)
        XCTAssertEqual(detector.takeMaxScore(), 0)
    }

    func testRefractoryAfterSkip() {
        // 飛んだ直後 0.5 秒で戻ると、1.5 秒の不応期に入っているので 2 回目は取れない（限界の記録）。
        var source = Source()
        var signal: [Float] = []
        for i in 0..<seconds(4) { signal.append(source.a(i)) }
        for i in seconds(4)..<seconds(4.5) { signal.append(source.b(i)) }
        for i in seconds(4.5)..<seconds(8.5) { signal.append(source.a(i)) }
        var detector = ETSkipDetector()
        XCTAssertEqual(skips(run(signal, detector: &detector)).count, 1)
    }

    func testTakeMaxScoreReadsAndClears() {
        var source = Source()
        var signal: [Float] = []
        for i in 0..<seconds(4) { signal.append(source.a(i)) }
        for i in seconds(4)..<seconds(5) { signal.append(source.b(i)) }
        var detector = ETSkipDetector()
        _ = run(signal, detector: &detector)
        XCTAssertGreaterThan(detector.takeMaxScore(), ETSkipDetector.instantThreshold)
        XCTAssertEqual(detector.takeMaxScore(), 0)
    }

    func testGapBeforeNewMaterialIsFoundAndBoundaryAfterTheGap() {
        // 無音を挟んで曲が替わる。音色が替わるので飛んだと言い、境目は無音のあと。
        var source = Source()
        var signal: [Float] = []
        for i in 0..<seconds(4) { signal.append(source.a(i)) }
        signal += [Float](repeating: 0, count: seconds(0.3))
        for i in seconds(4.3)..<seconds(6.5) { signal.append(source.b(i)) }
        var detector = ETSkipDetector()
        let found = skips(run(signal, detector: &detector))
        XCTAssertEqual(found.count, 1)
        if let skip = found.first {
            XCTAssertGreaterThanOrEqual(skip.boundary, Int64(4.3 * Self.rate))
            XCTAssertLessThanOrEqual(skip.boundary, Int64(4.45 * Self.rate))
        }
    }

    // MARK: 確かめる（中くらいの点数）

    private func medium(shift: Double) -> [ETSkipDetector.Event] {
        // 4.6 秒（拍から 5 枠ずれた所）で明るさが替わる。shift が 0 なら拍は続き、0.2 なら 10 枠ずれる。
        var source = Source()
        let change = seconds(4.6)
        var signal: [Float] = []
        for i in 0..<change { signal.append(source.d(i, alpha: 0.05)) }
        for i in change..<(change + seconds(4.5)) { signal.append(source.d(i, shift: shift, alpha: 0.3)) }
        var detector = ETSkipDetector()
        return run(signal, detector: &detector)
    }

    func testMediumScoreWithContinuingBeatIsKept() {
        let events = medium(shift: 0)
        XCTAssertTrue(skips(events).isEmpty)
        let confirming = events.filter { if case .confirming = $0 { return true } else { return false } }
        XCTAssertEqual(confirming.count, 1)
        if case .confirming(_, let scores, let bpm, _)? = confirming.first {
            XCTAssertGreaterThanOrEqual(scores.score, ETSkipDetector.confirmThreshold)
            XCTAssertLessThan(scores.score, ETSkipDetector.instantThreshold)
            XCTAssertEqual(bpm, 120, accuracy: 1)
        }
        guard case .keep(_, _, let reason)? = events.last, case .aligned(let aligned, _) = reason else {
            return XCTFail("\(events)")
        }
        XCTAssertGreaterThanOrEqual(aligned, ETSkipDetector.alignedRatio)
    }

    func testMediumScoreWithShiftedBeatIsSkip() {
        let events = medium(shift: 0.2)
        let found = skips(events)
        XCTAssertEqual(found.count, 1)
        guard let skip = found.first, case .beat(let aligned, let bpm) = skip.stage else { return XCTFail("\(events)") }
        XCTAssertLessThan(aligned, ETSkipDetector.alignedRatio)
        XCTAssertEqual(bpm, 120, accuracy: 1)
        // 確かめ始めてから約 1 秒後に決まる
        guard case .confirming(let confirmedAt, _, _, _)? = events.first(where: { if case .confirming = $0 { return true } else { return false } }) else {
            return XCTFail("\(events)")
        }
        XCTAssertGreaterThan(skip.at, confirmedAt)
        XCTAssertLessThanOrEqual(skip.at - confirmedAt, Int64(1.2 * Self.rate))
    }

    // MARK: 拍の格子

    private func impulses(count: Int, every: Int, offset: Int = 0) -> [Float] {
        (0..<count).map { ($0 + offset) % every == 0 ? 1 : 0 }
    }

    func testBeatGridFindsPeriodAndPhase() throws {
        let grid = try XCTUnwrap(ETSkipDetector.beatGrid(impulses(count: 300, every: 25), firstFrame: 1000))
        XCTAssertEqual(grid.period, 25, accuracy: 0.05)
        XCTAssertEqual(grid.bpm, 120, accuracy: 0.3)
        XCTAssertGreaterThan(grid.strength, 0.9)
        XCTAssertEqual(grid.lastBeat, 1275, accuracy: 0.5)
    }

    func testBeatGridNeedsEnoughFramesAndStrength() {
        XCTAssertNil(ETSkipDetector.beatGrid(impulses(count: 149, every: 25), firstFrame: 0))
        XCTAssertNotNil(ETSkipDetector.beatGrid(impulses(count: 150, every: 25), firstFrame: 0))
        XCTAssertNil(ETSkipDetector.beatGrid([Float](repeating: 0.3, count: 300), firstFrame: 0))
        var state: UInt32 = 99
        let noise: [Float] = (0..<300).map { _ in
            state = state &* 1664525 &+ 1013904223
            return Float(state >> 16) / 65536
        }
        XCTAssertNil(ETSkipDetector.beatGrid(noise, firstFrame: 0))
    }

    func testBeatAlignmentContinuesGrid() throws {
        let grid = try XCTUnwrap(ETSkipDetector.beatGrid(impulses(count: 300, every: 25), firstFrame: 1000))
        // 格子の続き: 1300 から 25 枠おきの拍
        let post = impulses(count: 60, every: 25)
        let result = ETSkipDetector.alignment(post: post, postStart: 1300, grid: grid)
        XCTAssertGreaterThanOrEqual(result.aligned, 0.9)
        XCTAssertGreaterThan(result.best, 0)
    }

    func testBeatAlignmentShiftedGridIsMisaligned() throws {
        let grid = try XCTUnwrap(ETSkipDetector.beatGrid(impulses(count: 300, every: 25), firstFrame: 1000))
        let post = impulses(count: 60, every: 25, offset: 13)
        let result = ETSkipDetector.alignment(post: post, postStart: 1300, grid: grid)
        XCTAssertLessThan(result.aligned, 0.6)
    }

    func testBeatAlignmentWithoutOnsetsHasNoEvidence() throws {
        let grid = try XCTUnwrap(ETSkipDetector.beatGrid(impulses(count: 300, every: 25), firstFrame: 1000))
        let result = ETSkipDetector.alignment(post: [Float](repeating: 0.2, count: 60), postStart: 1300, grid: grid)
        XCTAssertLessThanOrEqual(result.best, 1e-6)
    }

    // MARK: 検出器どうしの食い違い

    func testChunkSizeDoesNotChangeTheResult() {
        var source = Source()
        var signal: [Float] = []
        for i in 0..<seconds(4) { signal.append(source.a(i)) }
        for i in seconds(4)..<seconds(5.5) { signal.append(source.b(i)) }
        var a = ETSkipDetector(), b = ETSkipDetector()
        let whole = signal.withUnsafeBufferPointer { a.append($0) }
        var pieces: [ETSkipDetector.Event] = []
        var index = 0
        while index < signal.count {
            let end = min(index + 777, signal.count)
            pieces += signal[index..<end].withUnsafeBufferPointer { b.append($0) }
            index = end
        }
        XCTAssertEqual(whole, pieces)
    }
}
