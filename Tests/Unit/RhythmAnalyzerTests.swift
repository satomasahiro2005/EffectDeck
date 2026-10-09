//  RhythmAnalyzerTests.swift
//  Rhythm Analyzer（2.12.0）の枠の読み・履歴・Min / Max BPM の規則（DSP/RhythmAnalyzerModel.swift）。
//  **実機もエンジンも要らない。**期待値は rhythm_analyzer.js の式から手で出したもの。

import XCTest

final class RhythmAnalyzerTests: XCTestCase {

    typealias R = ETRhythm

    // MARK: Min / Max BPM

    func testBPMRangeRule() {
        typealias N = ETRhythmBPMRange
        // 既定。Max だけを範囲の中の値へ（Min の 1.25 倍以上）。
        XCTAssertEqual(N.normalize(previousMin: 40, previousMax: 240, requestedMin: nil, requestedMax: 100).max, 100)
        XCTAssertEqual(N.normalize(previousMin: 40, previousMax: 240, requestedMin: nil, requestedMax: 100).min, 40)
        // Max だけを Min の 1.25 倍より下へ入れると、Min が下がる（floor(mx / 1.25)）。
        let lowered = N.normalize(previousMin: 100, previousMax: 200, requestedMin: nil, requestedMax: 60)
        XCTAssertEqual(lowered.min, 48)
        XCTAssertEqual(lowered.max, 60)
        // 範囲の下限（50）まで。Min 40 なら 50 ≥ 50 で通る。
        let floorMax = N.normalize(previousMin: 40, previousMax: 240, requestedMin: nil, requestedMax: 50)
        XCTAssertEqual(floorMax.min, 40)
        XCTAssertEqual(floorMax.max, 50)
        // Min だけを上げて Max が足りなくなると、Max が上がる（ceil(mn * 1.25)）。
        let raised = N.normalize(previousMin: 100, previousMax: 200, requestedMin: 190, requestedMax: nil)
        XCTAssertEqual(raised.min, 190)
        XCTAssertEqual(raised.max, 238)
        // 同時に来たときは Min を優先して Max が寄る。
        let both = N.normalize(previousMin: 40, previousMax: 240, requestedMin: 100, requestedMax: 50)
        XCTAssertEqual(both.min, 100)
        XCTAssertEqual(both.max, 125)
        // 範囲の外は端へ。範囲の外の Max は Min を下げない（打った先頭の字 '1' が送られても）。
        let typed = N.normalize(previousMin: 100, previousMax: 200, requestedMin: nil, requestedMax: 1)
        XCTAssertEqual(typed.min, 100, "範囲の外の Max は Min を下げない")
        XCTAssertEqual(typed.max, 125)
        XCTAssertEqual(N.normalize(previousMin: 40, previousMax: 240, requestedMin: 500, requestedMax: nil).min, 192)
        XCTAssertEqual(N.normalize(previousMin: 40, previousMax: 240, requestedMin: 500, requestedMax: nil).max, 240)
        // 数でないものは前の値のまま。
        let kept = N.normalize(previousMin: 60, previousMax: 180, requestedMin: .nan, requestedMax: .infinity)
        XCTAssertEqual(kept.min, 60)
        XCTAssertEqual(kept.max, 180)
        // どの入力でも規則を守る。
        for mn in stride(from: 40.0, through: 192, by: 13) {
            for mx in stride(from: 50.0, through: 240, by: 17) {
                for request in [(mn, nil), (nil, mx), (mn, mx)] as [(Double?, Double?)] {
                    let r = N.normalize(previousMin: 40, previousMax: 240, requestedMin: request.0,
                                        requestedMax: request.1)
                    XCTAssertGreaterThanOrEqual(r.max, r.min * 1.25 - 1e-9)
                    XCTAssertGreaterThanOrEqual(r.min, 40, "\(r)")
                    XCTAssertLessThanOrEqual(r.min, 192, "\(r)")
                    XCTAssertLessThanOrEqual(r.max, 240 + 1e-9, "\(r)")
                }
            }
        }
    }

    func testSpanSnapsToTheNearestAllowedValue() {
        XCTAssertEqual(R.spans, [4, 6, 8, 12, 16])
        XCTAssertEqual(R.nearestSpan(8), 8)
        XCTAssertEqual(R.nearestSpan(7), 6, "6 と 8 の間は近い方。同じ距離なら小さい方")
        XCTAssertEqual(R.nearestSpan(5), 4)
        XCTAssertEqual(R.nearestSpan(10), 8)
        XCTAssertEqual(R.nearestSpan(11), 12)
        XCTAssertEqual(R.nearestSpan(100), 16)
        XCTAssertEqual(R.nearestSpan(-3), 4)
        XCTAssertEqual(R.nearestSpan(.nan), 8)
    }

    func testSmallHelpers() {
        XCTAssertEqual(R.bpmPosition(30), 0, accuracy: 1e-12)
        XCTAssertEqual(R.bpmPosition(120), 0.5, accuracy: 1e-12)
        XCTAssertEqual(R.bpmPosition(480), 1, accuracy: 1e-12)
        XCTAssertEqual(R.bpmPosition(10), 0)
        XCTAssertEqual(R.bpmPosition(2000), 1)
        // 0 に丸まる値は +0。
        XCTAssertEqual(R.signed(0.4, digits: 0), "+0")
        XCTAssertEqual(R.signed(-0.4, digits: 0), "+0")
        XCTAssertEqual(R.signed(-3, digits: 0), "−3")
        XCTAssertEqual(R.signed(12.34, digits: 1), "+12.3")
        XCTAssertEqual(R.median([3, 1, 2]), 2)
        XCTAssertEqual(R.median([4, 1, 2, 3]), 2.5)
        // 32 ビットの回り込み。
        XCTAssertTrue(R.isNewerCounter(1, than: 0))
        XCTAssertTrue(R.isNewerCounter(0, than: 0xFFFF_FFFF))
        XCTAssertFalse(R.isNewerCounter(5, than: 5))
        XCTAssertFalse(R.isNewerCounter(0, than: 1))
    }

    // MARK: 枠を作る

    private struct EventSpec {
        var frame: UInt32
        var fraction: Float = 0
        var epoch: UInt32 = 1
        var beatIndex: Int32
        var beatFraction: Float = 0
        var period: Float = 0.5
        var strength: Float = 0.8
        var band: UInt8 = 1
        var flags: UInt8 = 0
    }

    private struct Fields {
        var rate: Float = 48000
        var generation: UInt32 = 1
        var hop: UInt32 = 480
        var frameCount: UInt32 = 1000
        var time: Float = 2
        var latency: Float = 0.02
        var dropped: UInt32 = 0
        var locked = true
        var epoch: UInt32 = 1
        var confidence: Float = 0.6
        var period: Float = 0.5
        var anchorFrame: UInt32 = 1050
        var anchorFraction: Float = 0.25
        var anchorIndex: UInt32 = 3
        var strongest: Float = 120
        var tempogram = [Float](repeating: 0.25, count: 192)
        var events: [EventSpec] = []
        /// 先の拍の見込み（frame, fraction, index）と周期。
        var preview: [(frame: Int32, fraction: Float, index: Int32)] = []
        var previewPeriod: Float = 0
    }

    /// 2.13.0 の版 4（1496 バイト）。`locked` が false なら周期も anchor も 0（解析した拍が無い）。
    private func frame(_ f: Fields, length: Int = 1496, version: UInt16 = 4,
                       sequence: UInt32 = 1) -> ETFrame {
        var p = [UInt8](repeating: 0, count: 1496)
        func put(_ bytes: [UInt8], _ offset: Int) { TelemetryBytes.put(bytes, at: offset, into: &p) }
        put(TelemetryBytes.f32(f.rate), 0)
        put(TelemetryBytes.u32(f.generation), 4)
        put(TelemetryBytes.u32(f.hop), 8)
        put(TelemetryBytes.u32(f.frameCount), 12)
        put(TelemetryBytes.f32(f.time), 16)
        put(TelemetryBytes.f32(f.latency), 20)
        put(TelemetryBytes.u32(f.dropped), 24)
        put(TelemetryBytes.u32(UInt32(f.events.count)), 28)
        put(TelemetryBytes.u32(f.locked ? 1 : 0), 32)
        put(TelemetryBytes.u32(f.epoch), 36)
        put(TelemetryBytes.f32(f.confidence), 40)
        put(TelemetryBytes.f32(f.locked ? f.period : 0), 44)
        put(TelemetryBytes.u32(f.locked ? f.anchorFrame : 0), 48)
        put(TelemetryBytes.f32(f.locked ? f.anchorFraction : 0), 52)
        put(TelemetryBytes.u32(f.locked ? f.anchorIndex : 0), 56)
        put(TelemetryBytes.f32(f.strongest), 60)
        for (i, v) in f.tempogram.enumerated() { put(TelemetryBytes.f32(v), 64 + 4 * i) }
        for (k, e) in f.events.enumerated() {
            let base = 832 + 32 * k
            put(TelemetryBytes.u32(e.frame), base)
            put(TelemetryBytes.f32(e.fraction), base + 4)
            put(TelemetryBytes.u32(e.epoch), base + 8)
            put(TelemetryBytes.i32(e.beatIndex), base + 12)
            put(TelemetryBytes.f32(e.beatFraction), base + 16)
            put(TelemetryBytes.f32(e.period), base + 20)
            put(TelemetryBytes.f32(e.strength), base + 24)
            put([e.band], base + 28)
            put([e.flags], base + 29)
        }
        put(TelemetryBytes.u32(UInt32(f.preview.count)), 1344)
        put(TelemetryBytes.f32(f.previewPeriod), 1348)
        for (i, b) in f.preview.enumerated() {
            let base = 1352 + 12 * i
            put(TelemetryBytes.i32(b.frame), base)
            put(TelemetryBytes.f32(b.fraction), base + 4)
            put(TelemetryBytes.i32(b.index), base + 8)
        }
        return TelemetryBytes.frame(.rhythmAnalyzer, version: version, sequence: sequence,
                                    payload: Array(p.prefix(length)))
    }

    // MARK: 枠の読み

    func testParsesAFrameWithOneEvent() throws {
        var f = Fields()
        f.events = [EventSpec(frame: 990, fraction: 0.5, epoch: 4, beatIndex: 7, beatFraction: 0.25,
                              period: 0.5, strength: 0.6, band: 2)]
        let s = try XCTUnwrap(ETRhythmSnapshot.parse(frame(f, sequence: 8)))
        XCTAssertEqual(s.sampleRate, 48000)
        XCTAssertEqual(s.generation, 1)
        XCTAssertEqual(s.hop, 480)
        XCTAssertEqual(s.hopSeconds, 0.01, accuracy: 1e-12)
        XCTAssertEqual(s.frameCount, 1000)
        XCTAssertTrue(s.analysisValid)
        XCTAssertTrue(s.analysisAvailable)
        XCTAssertTrue(s.tickGateOpen)
        XCTAssertEqual(s.analysisEpoch, 1)
        XCTAssertEqual(s.periodSeconds, 0.5)
        XCTAssertEqual(s.anchorFrame, 1050)
        XCTAssertEqual(s.anchorFraction, 0.25)
        XCTAssertEqual(s.anchorIndex, 3)
        XCTAssertEqual(s.strongestBpm, 120)
        XCTAssertTrue(s.previewBeats.isEmpty)
        XCTAssertEqual(s.tempogram.count, 192)
        XCTAssertEqual(s.sequence, 8)
        let e = try XCTUnwrap(s.events.first)
        XCTAssertEqual(s.events.count, 1)
        XCTAssertTrue(e.annotated)
        XCTAssertFalse(e.provisional)
        XCTAssertEqual(e.time, 990.5 * 0.01, accuracy: 1e-9, "(frame + fraction) × hopSeconds")
        XCTAssertEqual(e.epoch, 4)
        XCTAssertEqual(e.index, 7)
        // 札は 世代:frame:fraction のビット:帯域（同じ onset が仮から確定へ変わっても変わらない）。
        XCTAssertEqual(e.identity, "1:990:" + String(Float(0.5).bitPattern) + ":2")
        XCTAssertEqual(e.position, 7.25, accuracy: 1e-9)
        XCTAssertEqual(e.band, 2)
        XCTAssertEqual(e.strength, 0.6, accuracy: 1e-6)
    }

    func testUnlockedFrameAndEvents() throws {
        var f = Fields()
        f.locked = false
        f.events = [EventSpec(frame: 10, beatIndex: 0, period: 0, flags: 1)]
        let s = try XCTUnwrap(ETRhythmSnapshot.parse(frame(f)))
        XCTAssertFalse(s.analysisValid)
        XCTAssertFalse(s.tickGateOpen)
        XCTAssertFalse(s.events[0].annotated)
        // 拍に乗っていない onset は period 0 が許される。乗っているのに 0 は落とす。
        f.events = [EventSpec(frame: 10, beatIndex: 0, period: 0, flags: 0)]
        XCTAssertNil(ETRhythmSnapshot.parse(frame(f)))
    }

    func testRejectsMalformedFrames() {
        XCTAssertNil(ETRhythmSnapshot.parse(nil))
        XCTAssertNil(ETRhythmSnapshot.parse(frame(Fields(), length: 1495)))
        XCTAssertNil(ETRhythmSnapshot.parse(frame(Fields(), length: 1344)), "2.12.0 の長さ")
        XCTAssertNil(ETRhythmSnapshot.parse(frame(Fields(), version: 1)), "2.12.0 の版")
        func mutate(_ change: (inout Fields) -> Void) -> ETRhythmSnapshot? {
            var f = Fields()
            change(&f)
            return ETRhythmSnapshot.parse(frame(f))
        }
        XCTAssertNotNil(mutate { _ in })
        XCTAssertNil(mutate { $0.generation = 0 })
        XCTAssertNil(mutate { $0.hop = 0 })
        XCTAssertNil(mutate { $0.rate = 0 })
        XCTAssertNil(mutate { $0.rate = .nan })
        XCTAssertNil(mutate { $0.time = -1 })
        XCTAssertNil(mutate { $0.confidence = -0.1 })
        XCTAssertNotNil(mutate { $0.period = 0 }, "版 4 では周期 0 は「解析した拍が無い」")
        XCTAssertNil(mutate { $0.confidence = 1.1 }, "版 4 の確からしさは 0〜1")
        XCTAssertNil(mutate { $0.anchorFraction = 1 })
        XCTAssertNil(mutate { $0.strongest = -1 })
        XCTAssertNil(mutate { $0.tempogram[5] = 1.5 })
        XCTAssertNil(mutate { $0.tempogram[5] = -0.1 })
        XCTAssertNil(mutate { $0.tempogram[5] = .nan })
        XCTAssertNil(mutate { $0.events = [EventSpec(frame: 1, beatIndex: 0, band: 3)] })
        XCTAssertNil(mutate { $0.events = [EventSpec(frame: 1, beatIndex: 0, strength: 0)] })
        XCTAssertNil(mutate { $0.events = [EventSpec(frame: 1, fraction: 1, beatIndex: 0)] })
        XCTAssertNil(mutate { $0.events = [EventSpec(frame: 1, beatIndex: 0, strength: 1.5)] })
        XCTAssertNil(mutate { $0.events = [EventSpec(frame: 1, beatIndex: 0, flags: 6)] })
        // 拍（2・4・5）は band 0・beatFraction 0。
        XCTAssertNil(mutate { $0.events = [EventSpec(frame: 1, beatIndex: 0, flags: 2)] }, "band 1 の拍")
        XCTAssertNil(mutate { $0.events = [EventSpec(frame: 1, beatIndex: 0, beatFraction: 0.5, band: 0, flags: 5)] })
        XCTAssertNotNil(mutate { $0.events = [EventSpec(frame: 1, beatIndex: 0, strength: 0, band: 0, flags: 4)] },
                        "拍の強さは 0 でもよい")
        // 先の拍の見込み: 12 個まで、時刻も番号も 1 つずつ増える、周期が要る。
        XCTAssertNil(mutate { $0.preview = [(10, 0, 1)]; $0.previewPeriod = 0 })
        XCTAssertNil(mutate { $0.preview = [(10, 0, 1), (60, 0, 3)]; $0.previewPeriod = 0.5 })
        XCTAssertNil(mutate { $0.preview = [(60, 0, 1), (10, 0, 2)]; $0.previewPeriod = 0.5 })
        XCTAssertNil(mutate { $0.preview = [(10, 1, 1)]; $0.previewPeriod = 0.5 })
        XCTAssertNil(mutate { $0.preview = Array(repeating: (10, 0, 1), count: 13); $0.previewPeriod = 0.5 })
        XCTAssertNil(ETRhythmSnapshot.parse(TelemetryBytes.frame(.rhythmAnalyzer, version: 2,
                                                                 payload: [UInt8](repeating: 0, count: 1496))))
        XCTAssertNil(ETRhythmSnapshot.parse(TelemetryBytes.frame(.level, version: 4,
                                                                 payload: [UInt8](repeating: 0, count: 1496))))
    }

    func testSortsBeatsAndPreviewOutOfTheItems() throws {
        var f = Fields()
        f.events = [
            EventSpec(frame: 990, beatIndex: 7, period: 0.5, strength: 0.6, band: 2, flags: 3),
            EventSpec(frame: 1000, beatIndex: 8, period: 0.5, strength: 0.9, band: 0, flags: 2),
            EventSpec(frame: 1050, beatIndex: 9, period: 0.5, strength: 0.4, band: 0, flags: 4),
            EventSpec(frame: UInt32(bitPattern: -5), beatIndex: -1, period: 0.5, strength: 1, band: 0, flags: 5),
        ]
        f.preview = [(1100, 0.5, 10), (1150, 0.5, 11)]
        f.previewPeriod = 0.5
        let s = try XCTUnwrap(ETRhythmSnapshot.parse(frame(f)))
        XCTAssertEqual(s.events.count, 1)
        XCTAssertTrue(s.events[0].provisional)
        XCTAssertFalse(s.events[0].annotated)
        XCTAssertEqual(s.forwardBeats.map(\.index), [8, 9])
        XCTAssertEqual(s.shownBeats.map(\.index), [8])
        XCTAssertEqual(s.shownBeats[0].strength, 0.9, accuracy: 1e-6)
        XCTAssertEqual(s.analysisBeats.count, 1)
        XCTAssertEqual(s.analysisBeats[0].time, -5 * 0.01, accuracy: 1e-9, "確定した拍の frame は符号付き")
        XCTAssertEqual(s.previewBeats.map(\.index), [10, 11])
        XCTAssertEqual(s.previewBeats[1].time, 1150.5 * 0.01, accuracy: 1e-9)
        XCTAssertEqual(s.previewPeriodSeconds, 0.5)
    }

    func testAnalysisIsOnlyAvailableAtTheKernelsRates() throws {
        for rate: Float in [48000, 96000, 192000] {
            var f = Fields()
            f.rate = rate
            XCTAssertTrue(try XCTUnwrap(ETRhythmSnapshot.parse(frame(f))).analysisAvailable, "\(rate)")
        }
        for rate: Float in [44100, 88200, 32000] {
            var f = Fields()
            f.rate = rate
            XCTAssertFalse(try XCTUnwrap(ETRhythmSnapshot.parse(frame(f))).analysisAvailable, "\(rate)")
        }
    }

    // MARK: 履歴

    /// 確定した拍（flags 5）。frame は符号付き。
    private func committedBeat(frame: Int32, index: Int32, epoch: UInt32 = 1, period: Float = 0.5,
                               strength: Float = 0.6) -> EventSpec {
        EventSpec(frame: UInt32(bitPattern: frame), epoch: epoch, beatIndex: index, period: period,
                  strength: strength, band: 0, flags: 5)
    }

    /// 先の拍。shown なら見せる拍（flags 2）、でなければ見せない拍（flags 4）。
    private func forwardBeat(frame: UInt32, index: Int32, epoch: UInt32 = 1, period: Float = 0.5,
                             strength: Float = 1, shown: Bool = true) -> EventSpec {
        EventSpec(frame: frame, epoch: epoch, beatIndex: index, period: period, strength: strength,
                  band: 0, flags: shown ? 2 : 4)
    }

    /// 0.1 秒（10 ホップ）ごとの枠。拍は 0.5 秒（50 ホップ）おきで、拍 n は 50n ホップ。
    /// 本物のカーネルと同じく、最新の確定した拍（anchor）を毎回運び、次の拍を見せる先の拍として運ぶ。
    /// `beats` は拍の頭の onset を持つ拍の番号、`midBeats` は 0.52 拍目の onset を持つ拍の番号。
    private func gridFrame(_ k: Int, generation: UInt32 = 1, epoch: UInt32 = 1, onsetsOn beats: [Int] = [],
                           midBeats: [Int] = []) -> ETFrame {
        var f = Fields()
        f.generation = generation
        f.epoch = epoch
        f.frameCount = UInt32(10 * k)
        f.time = Float(Double(k) * 0.1)
        let n = Int(f.frameCount) / 50
        f.anchorIndex = UInt32(n)
        f.anchorFrame = UInt32(50 * n)
        f.anchorFraction = 0
        var events = [committedBeat(frame: Int32(50 * n), index: Int32(n), epoch: epoch),
                      forwardBeat(frame: UInt32(50 * (n + 1)), index: Int32(n + 1), epoch: epoch)]
        events += beats.map { EventSpec(frame: UInt32(50 * $0), epoch: epoch, beatIndex: Int32($0)) }
        // 拍の途中（0.52 拍）の onset は +10ms 遅れ。
        events += midBeats.map {
            EventSpec(frame: UInt32(50 * $0 + 26), epoch: epoch, beatIndex: Int32($0), beatFraction: 0.52)
        }
        f.events = events
        return frame(f, sequence: UInt32(k))
    }

    private func feed(_ state: ETRhythmState, frames range: ClosedRange<Int>, generation: UInt32 = 1,
                      epoch: UInt32 = 1, onsets: [Int: [Int]] = [:], mids: [Int: [Int]] = [:]) {
        for k in range {
            state.ingest(gridFrame(k, generation: generation, epoch: epoch, onsetsOn: onsets[k] ?? [],
                                   midBeats: mids[k] ?? []), now: Double(k) * 0.1)
        }
    }

    func testTempogramColumnsAdvanceWithAnalysedTime() {
        let state = ETRhythmState()
        XCTAssertEqual(state.tempogramHead, 159)
        state.ingest(gridFrame(1), now: 0)
        XCTAssertEqual(state.tempogramHead, 0, "最初の枠は 1 列進める")
        XCTAssertEqual(state.tempogramConfidence[0], 0.6, accuracy: 1e-6)
        XCTAssertEqual(state.tempogramAdopted[0], 0, "いまの列は、採用したテンポで埋めない（外挿しない）")
        // 確定した拍（時刻 0）は、原点（0.1 秒）より前の 1 つ前の列に当たる。
        XCTAssertEqual(state.tempogramAdopted[159], 120, "採用したテンポ = 60 / 周期。解析した時刻の列に入る")
        state.ingest(gridFrame(2), now: 0.1)
        XCTAssertEqual(state.tempogramHead, 0, "0.1 秒 < 1 列（0.125 秒）: 同じ列を書き直す")
        XCTAssertEqual(state.columnPhase, 0.8, accuracy: 1e-9)
        state.ingest(gridFrame(3), now: 0.2)
        XCTAssertEqual(state.tempogramHead, 1)
        XCTAssertEqual(state.columnPhase, 0.6, accuracy: 1e-9)
        XCTAssertEqual(state.tempogramScroll(now: 0.2), 0.6, accuracy: 1e-9)
        // 枠が止まっても、壁時計で 2 列までしか進めない。
        XCTAssertEqual(state.tempogramScroll(now: 100), 0.6 + 2, accuracy: 1e-9)
    }

    /// 上流 rhythm-analyzer-display.test.mjs の「delayed adopted history」。
    func testDelayedAdoptedHistoryUsesTheOriginalAudioTimeBucket() {
        let state = ETRhythmState()
        for frameCount in 10...197 {
            var f = Fields()
            f.hop = 512
            f.frameCount = UInt32(frameCount)
            f.time = Float(frameCount) * 512 / 48000
            if frameCount == 197 {
                f.period = 0.5
                f.anchorFrame = 90
                f.anchorFraction = 0
                f.anchorIndex = 0
            } else {
                f.locked = false
            }
            f.confidence = 0.3
            state.ingest(frame(f, sequence: UInt32(frameCount)), now: Double(frameCount) * 0.01)
        }
        XCTAssertEqual(state.tempogramHead, 15)
        XCTAssertEqual(state.tempogramAdopted[6], 120, "90 フレームは最初の 10 フレームから数えて 6 番目の列")
        XCTAssertEqual(state.tempogramAdopted[5], 0, "隣の古い列には触らない")
        XCTAssertEqual(state.tempogramAdopted[15], 0, "いまの確定していない列は埋めない")
        XCTAssertEqual(state.tempogramConfidence[6], 0.3, accuracy: 1e-6)
    }

    func testBeatClockFollowsTheCommittedBeats() throws {
        let state = ETRhythmState()
        feed(state, frames: 1...60)
        let segment = try XCTUnwrap(state.openSegment)
        XCTAssertEqual(state.segments.count, 1)
        XCTAssertEqual(segment.epoch, 1)
        // 最初の確定した拍が番号 0 で、時計は 0。以後は拍の番号どおりに進む（0.5 秒 = 1 拍）。
        XCTAssertEqual(segment.offset, 0, accuracy: 1e-9)
        XCTAssertEqual(state.beatClock, 12, accuracy: 1e-9, "枠 60 は 6.0 秒。最新の確定した拍は 12")
        XCTAssertEqual(state.heldPeriod, 0.5)
        XCTAssertEqual(state.snapshot?.frameCount, 600)
        XCTAssertEqual(state.clockAnchor?.index, 12)
        // 履歴からの補間（確定した拍の間）。
        XCTAssertEqual(state.clockAt(3.0), 6, accuracy: 1e-9)
        XCTAssertEqual(state.clockAt(3.25), 6.5, accuracy: 1e-9)
        // 最新の確定した拍より先は、先の拍の尾をたどり、尾の先は最後の周期で伸ばす。
        XCTAssertEqual(state.clockAt(6.5), 13, accuracy: 1e-9)
        XCTAssertEqual(state.clockAt(7.0), 14, accuracy: 1e-9)
        XCTAssertEqual(state.clockPosition(7.0).period, 0.5, accuracy: 1e-9)
        // 同じ確定した拍は 1 度だけ入る。
        XCTAssertEqual(state.clockCount, 13)
    }

    func testUnlockedFramesKeepTheCommittedClockAndHeldPeriod() {
        let state = ETRhythmState()
        feed(state, frames: 1...5)
        let before = state.beatClock
        var f = Fields()
        f.locked = false
        f.frameCount = 60
        f.time = 0.6
        state.ingest(frame(f), now: 0.6)
        XCTAssertEqual(state.beatClock, before, "解析した拍が無い間、時計は進めない")
        XCTAssertNil(state.openSegment)
        XCTAssertEqual(state.heldPeriod, 0.5)
        XCTAssertEqual(state.ledLevel, 0)
    }

    /// 上流の「v3 clock shares the producer boundary, tie, reset and duplicate-time cases」から。
    func testClockPositionFollowsTheForwardTailAndTheAnchor() throws {
        func state(anchor: (frame: Int32, period: Float, index: Int32)?,
                   forward: [(frame: UInt32, period: Float, index: Int32)], epoch: UInt32 = 1,
                   forwardEpoch: UInt32 = 1, into existing: ETRhythmState? = nil) -> ETRhythmState {
            let s = existing ?? ETRhythmState()
            var f = Fields()
            f.locked = false
            f.epoch = epoch
            f.frameCount = 1000
            var events: [EventSpec] = []
            if let anchor {
                events.append(committedBeat(frame: anchor.frame, index: anchor.index, epoch: epoch,
                                            period: anchor.period, strength: 0))
            }
            events += forward.map { forwardBeat(frame: $0.frame, index: $0.index, epoch: forwardEpoch,
                                                period: $0.period, strength: 0, shown: false) }
            f.events = events
            s.ingest(frame(f), now: 0)
            // 上流のテストと同じく、区間の offset は 0 に揃える。
            for segment in s.segments.values { segment.offset = 0 }
            return s
        }
        func near(_ s: ETRhythmState, _ time: Double, _ position: Double, _ period: Double? = nil,
                  line: UInt = #line) {
            let actual = s.clockPosition(time)
            XCTAssertEqual(actual.position, position, accuracy: 1e-6, "t=\(time) U", line: line)
            if let period { XCTAssertEqual(actual.period, period, accuracy: 1e-6, "t=\(time) period", line: line) }
        }
        // 先の拍だけ。
        var s = state(anchor: nil, forward: [(100, 0.5, 7), (160, 0.6, 8)])
        near(s, 0.75, 6.5, 0.5)
        near(s, 1.3, 7.5, 0.6)
        near(s, 2.2, 9, 0.6)
        XCTAssertEqual(ETRhythmState().clockPosition(0).period, 0)
        // anchor と先の拍。anchor と半拍以内で重なる先の拍は尾に入れない。
        s = state(anchor: (102, 0.5, 10), forward: [(100, 0.5, 7), (160, 0.6, 8), (210, 0.5, 9)])
        near(s, 1.31, 10.5, 0.58)
        near(s, 2.35, 12.5, 0.5)
        s = state(anchor: (100, 0.5, 10), forward: [(102, 0.5, 7), (150, 0.5, 8)])
        near(s, 1.25, 10.5, 0.5)
        // 周期が違うと、小さいほうが重なりの幅になる。
        s = state(anchor: (100, 1, 10), forward: [(75, 1, 7), (125, 1, 8)])
        near(s, 1.25, 11, 0.25)
        s = state(anchor: (100, 0.2, 10), forward: [(115, 0.5, 7)])
        near(s, 1.15, 11, 0.15)
        // 周期 0 の anchor（最初の確定した拍）は、先の拍の周期で重なりを見る。
        s = state(anchor: (100, 0, 0), forward: [(102, 0.5, 7), (150, 0.5, 8)])
        near(s, 1.25, 0.5, 0.5)
        // 時刻が同じ先の拍は 1 つに畳む。
        s = state(anchor: nil, forward: [(100, 0.5, 0), (100, 0.5, 1), (150, 0.5, 2)])
        near(s, 1.25, 0.5, 0.5)
        let history = s.forwardBeats.count
        _ = state(anchor: nil, forward: [], into: s)
        XCTAssertEqual(s.forwardBeats.count, history, "先の拍が無い枠で、目標を捨てない")
        s.clearHistory()
        XCTAssertEqual(s.clockPosition(2).period, 0)
    }

    func testANewEpochReanchorsWithoutMovingTheClockBack() throws {
        let state = ETRhythmState()
        feed(state, frames: 1...60)
        let before = state.beatClock
        let oldEnd = try XCTUnwrap(state.segments[1]).endU
        // 新しい epoch は拍の番号を 100 から数え、時計は戻らない。
        for k in 61...70 {
            var f = Fields()
            f.epoch = 2
            f.frameCount = UInt32(10 * k)
            f.time = Float(Double(k) * 0.1)
            let n = Int(f.frameCount) / 50
            f.anchorIndex = UInt32(100 + n)
            f.anchorFrame = UInt32(50 * n)
            f.anchorFraction = 0
            f.events = [committedBeat(frame: Int32(50 * n), index: Int32(100 + n), epoch: 2)]
            state.ingest(frame(f, sequence: UInt32(k)), now: Double(k) * 0.1)
        }
        let segment = try XCTUnwrap(state.segments[2])
        XCTAssertTrue(segment.reanchor)
        XCTAssertEqual(segment.startU, oldEnd, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(state.beatClock, before)
        XCTAssertEqual(state.segmentOrder, [1, 2])
        XCTAssertEqual(try XCTUnwrap(state.lensSummary()).rows.count, 0, "新しい epoch のレンズは空から")
    }

    func testOnsetsAreStoredAndPlacedOnTheBeatClock() throws {
        let state = ETRhythmState()
        // 拍 n の onset は拍 n の時刻（frame 50n）の後に届く（5n フレーム目）。
        var onsets: [Int: [Int]] = [:]
        for n in 1...12 { onsets[5 * n] = [n] }
        feed(state, frames: 1...60, onsets: onsets)
        XCTAssertEqual(state.eventSerial, 12)
        var count = 0
        state.forEachEvent(from: -100, to: 100) { _ in count += 1 }
        XCTAssertEqual(count, 12)
        let lens = try XCTUnwrap(state.lensSummary())
        // 拍の頭だけ。帯域 1（Mid）のスロット 0 に 12 個、揺れは 0。
        XCTAssertEqual(lens.rows.count, 1)
        XCTAssertEqual(lens.rows[0].band, 1)
        XCTAssertEqual(lens.rows[0].slot, 0)
        XCTAssertEqual(lens.rows[0].count, 12)
        XCTAssertEqual(lens.rows[0].mean, 0, accuracy: 1e-5)
        XCTAssertEqual(lens.rows[0].sd, 0, accuracy: 1e-5)
        XCTAssertEqual(lens.jitter, 0, accuracy: 1e-5)
        XCTAssertTrue(lens.swing.isNaN, "0.4〜0.8 拍の onset が無い")
    }

    func testSwingAndSlotsFromMidBeatOnsets() throws {
        let state = ETRhythmState()
        var onsets: [Int: [Int]] = [:]
        var mids: [Int: [Int]] = [:]
        for n in 1...12 {
            onsets[5 * n] = [n]
            // 拍 n の 0.52 拍目は frame 50n + 26。それを越える 10 フレームごとの枠（5n + 3 枠目）で届く。
            mids[5 * n + 3, default: []].append(n)
        }
        feed(state, frames: 1...66, onsets: onsets, mids: mids)
        XCTAssertEqual(state.eventSerial, 24)
        let lens = try XCTUnwrap(state.lensSummary())
        XCTAssertEqual(Set(lens.rows.map(\.slot)), [0, 3], "拍の頭と 8 分の裏（straight の 3 番）")
        XCTAssertEqual(lens.swing, 0.52 / 0.48, accuracy: 1e-3, "中央値 0.52 → 0.52 : 0.48")
        let mid = try XCTUnwrap(lens.rows.first { $0.slot == 3 })
        XCTAssertEqual(mid.count, 12)
    }

    func testAnEpochOnTheTripletGridSwitchesTheSnap() throws {
        let state = ETRhythmState()
        // 拍の 1/3 と 2/3 に乗る onset を、拍ごとに 2 つ。
        for k in 1...80 {
            var f = Fields()
            f.frameCount = UInt32(10 * k)
            f.time = Float(Double(k) * 0.1)
            let n = Int(f.frameCount) / 50
            f.anchorIndex = UInt32(n)
            f.anchorFrame = UInt32(50 * n)
            f.anchorFraction = 0
            var events = [committedBeat(frame: Int32(50 * n), index: Int32(n))]
            if k % 5 == 3 {
                let b = k / 5
                events.append(EventSpec(frame: UInt32(50 * b + 17), beatIndex: Int32(b), beatFraction: 1 / 3 + 0.004))
                events.append(EventSpec(frame: UInt32(50 * b + 33), beatIndex: Int32(b), beatFraction: 2 / 3 - 0.004))
            }
            f.events = events
            state.ingest(frame(f, sequence: UInt32(k)), now: Double(k) * 0.1)
        }
        let lens = try XCTUnwrap(state.lensSummary())
        XCTAssertEqual(Set(lens.rows.map(\.slot)), [2, 4], "3 連の格子のスロット")
        XCTAssertGreaterThan(try XCTUnwrap(state.openSegment).triplet, try XCTUnwrap(state.openSegment).straight)
    }

    func testPointsForLaneViewsAreOldestFirstAndInsideTheWindow() {
        let state = ETRhythmState()
        var onsets: [Int: [Int]] = [:]
        for n in 1...12 { onsets[5 * n] = [n] }
        feed(state, frames: 1...60, onsets: onsets)
        state.prepareRender(now: 6.0)
        let view = ETRhythmState.LaneView(left: 0, top: 0, width: 400, height: 90,
                                          uRight: state.beatClock, span: 4, echo: false)
        let points = state.points(for: view)
        XCTAssertGreaterThanOrEqual(points.count, 4)
        XCTAssertEqual(points.map(\.x), points.map(\.x).sorted(), "古い順")
        // 帯域 1（Mid）の行の中心（上から 2 行目の中央）。揺れ 0 ms。
        for p in points where p.located {
            XCTAssertEqual(p.y, 90.0 / 3 * 1.5, accuracy: 1e-3)
            XCTAssertGreaterThanOrEqual(p.radius, 1.5)
            XCTAssertLessThanOrEqual(p.radius, 3.5)
        }
        // Echo は帯域ごとの行の高さ（中央の行は 0.5 の位置）。
        let echo = ETRhythmState.LaneView(left: 0, top: 0, width: 400, height: 22,
                                          uRight: state.beatClock, span: 4, echo: true)
        for p in state.points(for: echo) { XCTAssertEqual(p.y, 11, accuracy: 1e-9) }
    }

    // MARK: 仮の onset

    private func provisionalFrame(count: UInt32, anchorFrame: UInt32, anchorIndex: UInt32, events: [EventSpec],
                                  preview: [(frame: Int32, fraction: Float, index: Int32)] = [],
                                  generation: UInt32 = 1) -> ETFrame {
        var f = Fields()
        f.generation = generation
        f.frameCount = count
        f.time = Float(Double(count) * 0.01)
        f.anchorFrame = anchorFrame
        f.anchorFraction = 0
        f.anchorIndex = anchorIndex
        f.events = [committedBeat(frame: Int32(anchorFrame), index: Int32(anchorIndex))] + events
        f.preview = preview
        f.previewPeriod = preview.isEmpty ? 0 : 0.5
        return frame(f)
    }

    func testProvisionalOnsetAppearsAtOnceAndACommittedResendCorrectsTheSamePoint() throws {
        let state = ETRhythmState()
        let onset = EventSpec(frame: 100, beatIndex: 1, beatFraction: 0.02, band: 1, flags: 3)
        state.ingest(provisionalFrame(count: 100, anchorFrame: 50, anchorIndex: 0, events: [onset]), now: 0)
        XCTAssertEqual(state.eventSerial, 1)
        XCTAssertEqual(state.pendingOnsets.count, 1)
        var info = state.eventInfo(0)
        XCTAssertTrue(info.located)
        XCTAssertFalse(info.timed)
        XCTAssertEqual(try XCTUnwrap(state.lensSummary()).rows.count, 0, "仮の点のずれはレンズに入れない")
        let before = state.displayedEvent(0, wall: 1)

        var committed = onset
        committed.flags = 0
        committed.beatFraction = 0.98 // 拍の手前（番号 0 の 0.98）に置き直される
        committed.beatIndex = 0
        state.ingest(provisionalFrame(count: 200, anchorFrame: 150, anchorIndex: 2, events: [committed]), now: 1)
        XCTAssertEqual(state.eventSerial, 1, "確定の出し直しは 2 つ目の点を足さない")
        XCTAssertTrue(state.pendingOnsets.isEmpty)
        info = state.eventInfo(0)
        XCTAssertTrue(info.timed)
        XCTAssertEqual(info.time, 1.0, accuracy: 1e-9, "解析した時刻は変えない")
        // 表示は連続（同じ壁時計では、補正の前と同じ位置）。
        let after = state.displayedEvent(0, wall: 1)
        XCTAssertEqual(after.u, before.u, accuracy: 1e-9)
        XCTAssertEqual(after.deviation, before.deviation, accuracy: 1e-9)
        // 100 ms 後には、補正の差が e^-1 に縮み、十分後には確定した位置に着く。
        let moving = state.displayedEvent(0, wall: 1.1)
        XCTAssertLessThan(abs(moving.u - info.u), abs(before.u - info.u))
        XCTAssertEqual(state.displayedEvent(0, wall: 5).u, info.u, accuracy: 1e-6)
        // 確定した点は動かさない。
        committed.beatIndex = 0
        committed.beatFraction = 0.8
        state.ingest(provisionalFrame(count: 200, anchorFrame: 150, anchorIndex: 2, events: [committed]), now: 2)
        XCTAssertEqual(state.eventInfo(0).u, info.u)
        XCTAssertEqual(state.eventInfo(0).deviation, info.deviation)
    }

    func testFreshPathsCorrectAPendingOnsetBeforeItCommits() throws {
        let state = ETRhythmState()
        let onset = EventSpec(frame: 100, beatIndex: 1, band: 1, flags: 3)
        func path(_ middle: Int32, _ events: [EventSpec] = []) -> ETFrame {
            provisionalFrame(count: 150, anchorFrame: 50, anchorIndex: 0, events: events,
                             preview: [(50, 0, 0), (middle, 0, 1), (middle + 50, 0, 2)])
        }
        state.ingest(path(100, [onset]), now: 0)
        let original = state.displayedEvent(0, wall: 0)
        XCTAssertEqual(original.u, 1, accuracy: 1e-9)
        state.ingest(path(120), now: 0.017)
        // 0.5 秒（拍 0）から 1.2 秒（拍 1）の間の 1.0 秒は 5/7 拍。
        XCTAssertEqual(state.eventInfo(0).u, 5.0 / 7, accuracy: 1e-7, "出し直し無しで、新しい経路が仮の点を直す")
        XCTAssertEqual(state.displayedEvent(0, wall: 0.017).u, original.u, accuracy: 1e-9, "補正は連続して始まる")
        XCTAssertEqual(state.eventSerial, 1)
        XCTAssertEqual(state.eventInfo(0).time, 1, accuracy: 1e-9)
        XCTAssertFalse(state.eventInfo(0).timed)
        let target = state.eventInfo(0).u
        XCTAssertLessThan(abs(state.displayedEvent(0, wall: 0.117).u - target), abs(original.u - target))
        state.ingest(path(110), now: 0.03)
        XCTAssertGreaterThan(state.eventInfo(0).u, target, "次の経路が同じ点をさらに直す")
        var committed = onset
        committed.flags = 0
        state.ingest(provisionalFrame(count: 200, anchorFrame: 150, anchorIndex: 2, events: [committed],
                                      preview: [(150, 0, 2), (200, 0, 3)]), now: 0.05)
        XCTAssertTrue(state.eventInfo(0).timed)
        XCTAssertTrue(state.pendingOnsets.isEmpty)
        let fixed = state.eventInfo(0).u
        state.ingest(provisionalFrame(count: 210, anchorFrame: 150, anchorIndex: 2, events: [],
                                      preview: [(150, 0, 2), (210, 0, 3)]), now: 0.06)
        XCTAssertEqual(state.eventInfo(0).u, fixed)
        XCTAssertEqual(state.eventSerial, 1)
    }

    // MARK: 世代の柵

    func testGenerationFence() throws {
        let state = ETRhythmState()
        feed(state, frames: 1...3, generation: 5)
        XCTAssertEqual(state.activeGeneration, 5)
        XCTAssertNotNil(state.snapshot)

        // 同じ世代の途中で、古い世代が混じっても捨てる。
        state.ingest(gridFrame(4, generation: 4), now: 0)
        XCTAssertEqual(state.activeGeneration, 5)
        XCTAssertEqual(state.snapshot?.frameCount, 30)

        // Reset: 解析を捨てる。前の世代の取り残しの枠は受けず、新しい世代から始める。
        state.beginEpoch()
        XCTAssertNil(state.activeGeneration)
        XCTAssertNil(state.snapshot)
        XCTAssertEqual(state.tempogramHead, 159)
        feed(state, frames: 4...5, generation: 5)
        XCTAssertNil(state.snapshot, "前の世代の枠は受けない")
        XCTAssertNil(state.activeGeneration)
        feed(state, frames: 6...7, generation: 6)
        XCTAssertEqual(state.activeGeneration, 6)
        XCTAssertEqual(state.snapshot?.frameCount, 70)
    }

    /// 2.13.0: カーネルの解析のやり直し（新しい世代）は履歴を捨てず、枠の番号と epoch を続ける。
    func testANewerGenerationKeepsTheHistoryAndContinuesFramesAndEpochs() throws {
        let state = ETRhythmState()
        var onsets: [Int: [Int]] = [:]
        for n in 1...12 { onsets[5 * n] = [n] }
        feed(state, frames: 1...60, generation: 5, onsets: onsets)
        let stored = state.eventSerial
        let clock = state.beatClock
        // 古い世代は捨てる。
        state.ingest(gridFrame(61, generation: 4), now: 6.1)
        XCTAssertEqual(state.eventSerial, stored)
        XCTAssertEqual(state.snapshot?.frameCount, 600)
        // 新しい世代は枠の番号が 0 近くから始まる。続きとして 600 を足す。epoch 1 は別の区間になる。
        var f = Fields()
        f.generation = 6
        f.frameCount = 3
        f.time = 0.03
        f.locked = false
        f.events = [EventSpec(frame: 1, epoch: 1, beatIndex: 0, beatFraction: 0.5, band: 0)]
        state.ingest(frame(f), now: 6.2)
        XCTAssertEqual(state.activeGeneration, 6)
        XCTAssertEqual(state.frameBase, 600)
        XCTAssertEqual(state.epochBase, 1 << 32)
        XCTAssertEqual(state.snapshot?.frameCount, 603)
        XCTAssertEqual(state.eventSerial, stored + 1)
        XCTAssertGreaterThanOrEqual(state.beatClock, clock)
        XCTAssertEqual(state.snapshot?.events.first?.epoch, (1 << 32) + 1)
        XCTAssertEqual(state.snapshot?.events.first?.time ?? 0, 6.01, accuracy: 1e-9, "時刻も続ける")
        // 新しい世代の最初の拍は、別の区間として作られる。
        var g = Fields()
        g.generation = 6
        g.frameCount = 53
        g.time = 0.53
        g.anchorFrame = 50
        g.anchorFraction = 0
        g.anchorIndex = 0
        g.events = [committedBeat(frame: 50, index: 0)]
        state.ingest(frame(g), now: 6.7)
        XCTAssertEqual(state.segments.count, 2)
        XCTAssertNotNil(state.segments[(1 << 32) + 1])
        XCTAssertEqual(state.segmentOrder, [1, (1 << 32) + 1])
    }

    func testSourceChangeAcceptsRestartedGenerations() {
        let state = ETRhythmState()
        feed(state, frames: 1...3, generation: 9)
        // エンジンを作り直すと世代が 1 から数え直しになる。
        feed(state, frames: 1...2, generation: 1)
        XCTAssertEqual(state.activeGeneration, 9, "出どころが替わったと知らなければ古い世代と見て捨てる")
        state.resetSource()
        feed(state, frames: 1...2, generation: 1)
        XCTAssertEqual(state.activeGeneration, 1)
        XCTAssertNotNil(state.snapshot)
        XCTAssertEqual(state.frameBase, 0, "出どころが替わったら番号の続きも捨てる")
    }

    // MARK: ビート LED

    func testBeatLedLightsOnShownBeatsAndFades() throws {
        let state = ETRhythmState()
        feed(state, frames: 1...4)
        // 拍 1 は 0.5 秒。0.4 秒の枠まではまだ点いていない。
        XCTAssertEqual(state.ledLevel, 0)
        feed(state, frames: 5...5)
        // 0.5 秒の枠で拍 1 を越える。ちょうど越えた直後は最大（強さ 1）。
        XCTAssertGreaterThan(state.ledLevel, 0.99)
        feed(state, frames: 6...6)
        // 0.1 秒後は 0.09 秒の減衰を過ぎて消える。
        XCTAssertEqual(state.ledLevel, 0)
    }

    /// 上流の「shown beats flash once at their time…」。
    func testShownBeatsFlashOnceAndQueuedBeatsFlashBetweenFrames() {
        let state = ETRhythmState()
        func at(_ count: UInt32, _ events: [EventSpec], gate: Bool = true, epoch: UInt32 = 1, now: Double = 0) {
            var f = Fields()
            f.frameCount = count
            f.time = Float(Double(count) * 0.01)
            f.locked = gate
            f.epoch = epoch
            f.period = 0
            f.events = events
            state.ingest(frame(f), now: now)
        }
        let shown = forwardBeat(frame: 60, index: 7, epoch: 3, strength: 0.8)
        at(55, [shown], now: 0)
        XCTAssertEqual(state.eventSerial, 0, "拍の項目は onset の行に入らない")
        XCTAssertEqual(state.ledLevel, 0, "先の拍は待ちに入れるだけで、点けない")
        at(57, [shown], gate: false, epoch: 2, now: 0.02)
        // 壁時計が進むと、待っている拍がその時刻に点く（枠の間でも）。
        state.prepareRender(now: 0.0505)
        XCTAssertEqual(state.ledLevel, 0.8, accuracy: 0.01, "0.57 + 0.0305 = 0.6005 秒で点く")
        state.prepareRender(now: 0.02 + 0.075)
        XCTAssertEqual(state.ledLevel, 0.4, accuracy: 1e-3, "0.045 / 0.09 を消費")
        at(70, [shown], gate: false, now: 0.1)
        XCTAssertEqual(state.ledLevel, 0, "同じ札の拍は 2 度点けない")
    }

    func testLateShownBeatStartsWhenReceivedAndSilenceClearsTheQueue() {
        let state = ETRhythmState()
        var f = Fields()
        f.frameCount = 80
        f.period = 0.5
        f.events = [forwardBeat(frame: 10, index: 2, epoch: 4, strength: 0.6)]
        state.ingest(frame(f, sequence: 1), now: 0)
        XCTAssertEqual(state.ledLevel, 0.6, accuracy: 1e-6, "過ぎた拍は受け取った時に点く")
        f.frameCount = 81
        state.ingest(frame(f, sequence: 2), now: 0.01)
        XCTAssertLessThan(state.ledLevel, 0.6)
        // 解析の確からしさも最強候補も 0（無音）。待っている拍と札を捨てる。
        f.frameCount = 100
        f.events = [forwardBeat(frame: 150, index: 3, epoch: 4)]
        state.ingest(frame(f, sequence: 3), now: 0.02)
        f.frameCount = 101
        f.confidence = 0
        f.strongest = 0
        f.events = []
        state.ingest(frame(f, sequence: 4), now: 0.03)
        XCTAssertEqual(state.ledLevel, 0)
        // 捨てたので、同じ番号の拍が改めて受け取られる。
        f.frameCount = 200
        f.confidence = 0.6
        f.strongest = 120
        f.events = [forwardBeat(frame: 150, index: 3, epoch: 4)]
        state.ingest(frame(f, sequence: 5), now: 0.04)
        XCTAssertGreaterThan(state.ledLevel, 0)
    }

    func testMetronomeClickOffClearsTheLed() {
        let state = ETRhythmState()
        var f = Fields()
        f.frameCount = 100
        f.events = [forwardBeat(frame: 100, index: 2, strength: 0.5)]
        state.ingest(frame(f, sequence: 1), now: 0)
        XCTAssertEqual(state.ledLevel, 0.5, accuracy: 1e-9)
        state.clearBeatLed()
        XCTAssertEqual(state.ledLevel, 0)
    }

    // MARK: 止まっている間の表示

    func testIdleLanesKeepScrollingAtTheLastPeriod() throws {
        let state = ETRhythmState()
        feed(state, frames: 1...60)
        state.prepareRender(now: 6.0)
        let initial = try XCTUnwrap(state.displayU)
        let lastCount = try XCTUnwrap(state.snapshot).frameCount
        let committedClock = state.beatClock
        // 無音の枠（周期 0・確からしさ 0・最強候補 0）が来て、そのあと枠は来ない。
        var f = Fields()
        f.locked = false
        f.frameCount = UInt32(lastCount + 1)
        f.confidence = 0
        f.strongest = 0
        state.ingest(frame(f), now: 6.0)
        XCTAssertTrue(state.idleScroll)
        state.prepareRender(now: 6.1)
        let first = try XCTUnwrap(state.displayU)
        state.prepareRender(now: 6.2)
        let second = try XCTUnwrap(state.displayU)
        XCTAssertGreaterThan(first, initial)
        XCTAssertGreaterThan(second, first)
        XCTAssertEqual(second - first, 0.1 / 0.5, accuracy: 1e-9, "最後の周期（0.5 秒）で流れる")
        state.prepareRender(now: 66.2)
        XCTAssertEqual(try XCTUnwrap(state.displayU) - second, 60 / 0.5, accuracy: 1e-6)
        XCTAssertEqual(state.beatClock, committedClock, "止まっている間の描画は解析の履歴を変えない")
        // 枠が戻る。止まっていた間の時間は表示に残り、時計は後ろに戻らない。
        state.ingest(gridFrame(62, generation: 1), now: 66.3)
        XCTAssertFalse(state.idleScroll)
        let resumed = state.displayClock(state.audioNow(66.3), wall: 66.3)
        XCTAssertEqual(resumed, state.displayU ?? 0, accuracy: 1e-6)
        XCTAssertGreaterThan(resumed, second)
    }

    func testSegmentsAreCappedAtSixtyFour() {
        let state = ETRhythmState()
        for epoch in 1...70 {
            var f = Fields()
            f.epoch = UInt32(epoch)
            f.frameCount = UInt32(10 * epoch)
            f.anchorFrame = f.frameCount + 20
            f.anchorFraction = 0
            f.anchorIndex = UInt32(epoch)
            state.ingest(frame(f, sequence: UInt32(epoch)), now: 0)
        }
        XCTAssertEqual(state.segments.count, 64)
        XCTAssertEqual(state.segmentOrder.count, 64)
        XCTAssertNil(state.segments[1], "古い方から捨てる")
        XCTAssertNotNil(state.segments[70])
    }
}
