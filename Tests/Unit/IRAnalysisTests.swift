//  IRAnalysisTests.swift
//  IR Reverb の EDC グラフの数字（ETIRAnalysis / ETIRGraph）。**実機もエンジンも要らない。**
//
//  約束は2つ。
//    1. 上流の analyze と同じ答えになる。見本は上流の prepareIr → emitPreparedIr が吐いたもの
//       （Tests/Fixtures/IR/analysis-golden.json。作り直すときは `node Tools/ir_analysis_golden.mjs`）。
//       Original（ETIRPreparation.Prepared.originalChannels を解析したもの）が上流の
//       analysis.original と合うので、**originalChannels を取る点**（最初の利得の後、dt / tr / 最後の利得の前）も
//       ここで固定される。点を間違えると dt・tr を動かした見本（c・d・f・k）が落ちる。
//    2. 印の位置・段・字の x・秒の目盛り・指の値・時間の字は、上流の式（ir_reverb.js の行を各テストに書いた）のまま。
//
//  IRAnalysis.swift・IRPreparation.swift と見本はこのバンドルへ直接入れてある（project.yml）。

import XCTest
import Foundation

final class IRAnalysisTests: XCTestCase {

    // MARK: - 見本

    private struct Golden: Decodable {
        let inputs: [String: [String]]
        let cases: [Case]

        struct Case: Decodable {
            let name: String
            let input: String
            let sampleRate: Int
            let topology: UInt32
            let assetChannels: Int?
            let emitMaxFrames: Int
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
            let onsetFrame: Int
            let cutFrame: Int?
            let sourceStartFrame: Int
            let original: Series
            let current: Series
        }

        struct Series: Decodable {
            let frames: Int
            let sampleFrames: [Int]
            let envelope: String
            let edcDb: String
            let rt60Seconds: Double?
        }
    }

    private func golden() throws -> Golden {
        let file = try XCTUnwrap(TestResource.url("analysis-golden", "json"))
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

    private func check(_ got: ETIRSeries, _ want: Golden.Series, _ label: String) throws {
        XCTAssertEqual(got.frames, want.frames, label)
        XCTAssertEqual(got.sampleFrames, want.sampleFrames, label)
        // 絶対値は丸めが入らないので、包絡はビットまで合う。
        let envelope = try Self.floats(want.envelope)
        XCTAssertEqual(got.envelope.count, envelope.count, label)
        XCTAssertEqual(got.envelope.map(\.bitPattern), envelope.map(\.bitPattern), "\(label) envelope")
        // log10 は V8 と Darwin / glibc の libm で1ulp違いうる。Float へ丸めた後で 1e-4 dB 以内。
        let edc = try Self.floats(want.edcDb)
        XCTAssertEqual(got.edcDb.count, edc.count, label)
        var worst = 0.0
        for (a, b) in zip(got.edcDb, edc) { worst = max(worst, abs(Double(a) - Double(b))) }
        XCTAssertLessThanOrEqual(worst, 1e-4, "\(label) edcDb")
        switch (got.rt60Seconds, want.rt60Seconds) {
        case (nil, nil): break
        case let (a?, b?):
            XCTAssertLessThanOrEqual(abs(a - b) / max(abs(b), 1e-12), 1e-9, "\(label) rt60 \(a) vs \(b)")
        default:
            XCTFail("\(label) rt60 \(String(describing: got.rt60Seconds)) vs \(String(describing: want.rt60Seconds))")
        }
    }

    /// **上流の analyze と同じ答えになる。** Current は送った面（selectChannels と truncate の後）、
    /// Original は originalChannels。長さ・点・包絡・EDC・RT60 を照合する。
    func testGoldenMatchesUpstream() throws {
        let g = try golden()
        XCTAssertGreaterThanOrEqual(g.cases.count, 10)
        var sawFiniteRt60 = false
        var sawNilRt60 = false
        for c in g.cases {
            let source = try XCTUnwrap(g.inputs[c.input]).map(Self.floats)
            let topology = try XCTUnwrap(ETAssetTopology(rawValue: c.topology))
            var options = ETIRPreparation.Options()
            options.directCut = c.options.directCut
            options.cutOffsetMs = c.options.cutOffsetMs
            options.decayPercent = c.options.decayPercent
            options.trimPercent = c.options.trimPercent
            let prepared = try ETIRPreparation.prepare(source, sampleRate: c.sampleRate,
                                                       topology: topology, options: options)
            let selected = try ETIRPreparation.selectChannels(prepared.channels, topology: topology,
                                                              assetChannels: c.assetChannels ?? source.count)
            let emitted = ETIRPreparation.truncate(selected, maxFrames: c.emitMaxFrames)
            let e = c.expected

            XCTAssertEqual(emitted.channels[0].count, e.frames, c.name)
            XCTAssertEqual(prepared.onsetFrame, e.onsetFrame, c.name)
            XCTAssertEqual(prepared.cutFrame, e.cutFrame, c.name)
            XCTAssertEqual(prepared.sourceStartFrame, e.sourceStartFrame, c.name)

            let graph = ETIRGraph(ETIRGraphSource(originalChannels: prepared.originalChannels,
                                                  emittedChannels: emitted.channels,
                                                  sampleRate: c.sampleRate,
                                                  onsetFrame: prepared.onsetFrame,
                                                  cutFrame: prepared.cutFrame,
                                                  sourceStartFrame: prepared.sourceStartFrame))
            try check(graph.original, e.original, "\(c.name) original")
            try check(graph.current, e.current, "\(c.name) current")
            if e.current.rt60Seconds == nil { sawNilRt60 = true } else { sawFiniteRt60 = true }
        }
        XCTAssertTrue(sawFiniteRt60 && sawNilRt60, "見本に RT60 が出るものと出ないものの両方が要る")
    }

    /// Original は dt / tr の前、Current は後ろ。違いが無い見本ばかりだと取る点を間違えても通るので、
    /// dt・tr を動かした見本で2本が実際に違うことを見ておく。
    func testOriginalAndCurrentDifferWhenDecayAndTrimMove() throws {
        let g = try golden()
        for name in ["c_ts_dt200_tr60", "d_ts_dt50_tr60_dc", "k_stereo_co_plus2ms_dt200"] {
            let c = try XCTUnwrap(g.cases.first { $0.name == name })
            XCTAssertNotEqual(c.expected.original.edcDb, c.expected.current.edcDb, name)
        }
    }

    // MARK: - 形

    private func graph(frames: Int = 8000, originalFrames: Int = 9000, sampleRate: Int = 8000,
                       rt60: Double? = 0.8, onset: Int = 40, cut: Int? = 40, start: Int = 41) -> ETIRGraph {
        func series(_ n: Int, _ rt: Double?) -> ETIRSeries {
            ETIRSeries(frames: n, sampleFrames: [0, n / 2], envelope: [1, 0.5], edcDb: [0, -60], rt60Seconds: rt)
        }
        var g = ETIRGraph(ETIRGraphSource(originalChannels: [[0.5]], emittedChannels: [[0.5]],
                                          sampleRate: sampleRate, onsetFrame: onset, cutFrame: cut,
                                          sourceStartFrame: start))
        g.frames = frames
        g.original = series(originalFrames, nil)
        g.current = series(frames, rt60)
        return g
    }

    /// ir_reverb.js:1684-1717。durationSeconds は frames / original.frames / pd / 0.001 の最大。
    func testLayoutDuration() {
        let g = graph()
        XCTAssertEqual(g.layout(preDelayMs: 0, directCut: true).duration, 9000.0 / 8000, accuracy: 1e-12)
        // pd のほうが長いとき。
        XCTAssertEqual(g.layout(preDelayMs: 2500, directCut: true).duration, 2.5, accuracy: 1e-12)
        // どれも0に近いときの下限。
        var tiny = graph(frames: 1, originalFrames: 1)
        tiny.frames = 1
        XCTAssertEqual(tiny.layout(preDelayMs: 0, directCut: true).duration, 0.001, accuracy: 1e-12)
    }

    /// 印の位置。onset は max(0, onset - start)、cut は live の dc と cutFrame に依る、predelay は pd/1000、
    /// trim は送った長さ、rt60 は Current の値。並びは上流のオブジェクトの順。
    func testLayoutMarkers() {
        let g = graph()
        let on = g.layout(preDelayMs: 500, directCut: true)
        XCTAssertEqual(on.markers.map(\.kind), [.onset, .cut, .preDelay, .trim, .rt60])
        // onset 40 < start 41 は負になるので 0 に丸める（dc ありの形）。
        XCTAssertEqual(on.markers[0].seconds, 0)
        XCTAssertEqual(on.markers[1].seconds, 0)
        XCTAssertEqual(on.markers[2].seconds, 0.5)
        XCTAssertEqual(on.markers[3].seconds, 1.0)
        XCTAssertEqual(on.markers[4].seconds, 0.8)

        // dc が切れていれば、cutFrame があっても cut は無い。
        XCTAssertNil(g.layout(preDelayMs: 0, directCut: false).markers[1].seconds)
        // cutFrame が無ければ dc があっても無い。
        XCTAssertNil(graph(cut: nil).layout(preDelayMs: 0, directCut: true).markers[1].seconds)

        // dc なしの onset は正になる（開始が onset より前）。
        let off = graph(onset: 120, cut: nil, start: 20).layout(preDelayMs: 0, directCut: false)
        XCTAssertEqual(off.markers[0].seconds ?? -1, 100.0 / 8000, accuracy: 1e-15)
    }

    func testRt60Label() {
        XCTAssertEqual(graph(rt60: 0.7979).layout(preDelayMs: 0, directCut: true).rt60Label, "RT60 0.80 s")
        XCTAssertEqual(graph(rt60: nil).layout(preDelayMs: 0, directCut: true).rt60Label, "RT60 unavailable")
    }

    /// 段は描いたものだけを数えて3で回す（ir_reverb.js:1893-1913）。
    func testMarkerRows() {
        let all = graph().layout(preDelayMs: 500, directCut: true)
        XCTAssertEqual(all.drawnMarkers.map(\.row), [0, 1, 2, 0, 1])
        XCTAssertNil(all.trailingRt60Row)

        // cut が無いと後ろの段が1つ前へ詰まる。
        let noCut = graph().layout(preDelayMs: 500, directCut: false)
        XCTAssertEqual(noCut.drawnMarkers.map(\.kind), [.onset, .preDelay, .trim, .rt60])
        XCTAssertEqual(noCut.drawnMarkers.map(\.row), [0, 1, 2, 0])

        // rt60 が無いときは、字だけを次の段の右端に出す。
        let noRt60 = graph(rt60: nil).layout(preDelayMs: 500, directCut: true)
        XCTAssertEqual(noRt60.drawnMarkers.map(\.kind), [.onset, .cut, .preDelay, .trim])
        XCTAssertEqual(noRt60.trailingRt60Row, 1)

        // duration を超える印（rt60 が長さの外）は描かない。
        let outside = graph(rt60: 5).layout(preDelayMs: 0, directCut: true)
        XCTAssertFalse(outside.drawnMarkers.contains { $0.kind == .rt60 })
        XCTAssertNotNil(outside.trailingRt60Row)
    }

    /// ir_reverb.js:1906-1915。
    func testMarkerLabelX() {
        // 普通は右へ4。
        XCTAssertEqual(ETIRAnalysis.markerLabelX(px: 100, textWidth: 30, plotLeft: 42, plotRight: 300), 104)
        // 右端にはみ出すなら左へ折り返す。
        XCTAssertEqual(ETIRAnalysis.markerLabelX(px: 290, textWidth: 30, plotLeft: 42, plotRight: 300), 256)
        // 左の枠の外へ出る分は枠に留める。
        XCTAssertEqual(ETIRAnalysis.markerLabelX(px: 20, textWidth: 30, plotLeft: 42, plotRight: 300), 42)
        // 右端ちょうど（rt60 を描かなかったときの px = 右端）も折り返す。
        XCTAssertEqual(ETIRAnalysis.markerLabelX(px: 300, textWidth: 60, plotLeft: 42, plotRight: 300), 236)
    }

    func testSecondTicks() {
        XCTAssertEqual(ETIRAnalysis.secondTicks(duration: 0.5), [])
        XCTAssertEqual(ETIRAnalysis.secondTicks(duration: 1), [1])
        XCTAssertEqual(ETIRAnalysis.secondTicks(duration: 3.7), [1, 2, 3])
    }

    /// graph-readout.js の seriesValueAt。
    func testSeriesValue() {
        let xs = [0, 10, 10, 20]
        let ys: [Float] = [0, -10, -20, -40]
        XCTAssertEqual(ETIRAnalysis.seriesValue(xs: xs, ys: ys, at: 5) ?? 99, -5, accuracy: 1e-12)
        XCTAssertEqual(ETIRAnalysis.seriesValue(xs: xs, ys: ys, at: 15) ?? 99, -30, accuracy: 1e-12)
        XCTAssertEqual(ETIRAnalysis.seriesValue(xs: xs, ys: ys, at: 0) ?? 99, 0, accuracy: 1e-12)
        XCTAssertEqual(ETIRAnalysis.seriesValue(xs: xs, ys: ys, at: 20) ?? 99, -40, accuracy: 1e-12)
        // 範囲の外。
        XCTAssertNil(ETIRAnalysis.seriesValue(xs: xs, ys: ys, at: -1))
        XCTAssertNil(ETIRAnalysis.seriesValue(xs: xs, ys: ys, at: 21))
        XCTAssertNil(ETIRAnalysis.seriesValue(xs: [], ys: [], at: 0))
        // 非有限の隣。
        XCTAssertNil(ETIRAnalysis.seriesValue(xs: [0, 10], ys: [0, .nan], at: 5))
        // 1点だけ。
        XCTAssertEqual(ETIRAnalysis.seriesValue(xs: [4], ys: [-7], at: 4) ?? 99, -7, accuracy: 1e-12)
    }

    func testReadoutUsesSeconds() {
        let g = graph()
        // current は sampleFrames [0, 4000]、edc [0, -60]。0.25 s × 8000 = 2000 フレームは中点で -30。
        XCTAssertEqual(g.readout(seconds: 0.25).current ?? 99, -30, accuracy: 1e-9)
        // original は [0, 4500]、[0, -60]。2000 フレームで -26.666…
        XCTAssertEqual(g.readout(seconds: 0.25).original ?? 99, -60.0 * 2000 / 4500, accuracy: 1e-9)
        // current の最後（4000 フレーム）を超えると nil。
        XCTAssertNil(g.readout(seconds: 0.55).current)
        XCTAssertNotNil(g.readout(seconds: 0.55).original)
    }

    /// graph-readout.js の format.time。桁の丸めで閾値を跨いでも枝は丸める前の値で決まる。
    func testTimeText() {
        XCTAssertEqual(ETIRAnalysis.timeText(ms: 5), "5.00 ms")
        XCTAssertEqual(ETIRAnalysis.timeText(ms: 123.45), "123.5 ms")
        XCTAssertEqual(ETIRAnalysis.timeText(ms: 1500), "1.50 s")
        XCTAssertEqual(ETIRAnalysis.timeText(ms: 999.96), "1000.0 ms")
        XCTAssertEqual(ETIRAnalysis.timeText(ms: .nan), "—")
    }

    /// 包絡の塗り。ピークで割った dB。ピークが0なら塗らない。0の点は -90。
    func testEnvelopeDb() {
        let loud = ETIRGraph(ETIRGraphSource(originalChannels: [[1, 0, 0.5, 0, 0, 0, 0, 0.25]],
                                             emittedChannels: [[1, 0, 0.5, 0, 0, 0, 0, 0.25]],
                                             sampleRate: 8, onsetFrame: 0, cutFrame: nil,
                                             sourceStartFrame: 0))
        let db = try! XCTUnwrap(loud.envelopeDb)
        XCTAssertEqual(db.count, 8)
        XCTAssertEqual(db[0], 0, accuracy: 1e-12)
        XCTAssertEqual(db[1], -90)
        XCTAssertEqual(db[2], 20 * log10(0.5), accuracy: 1e-12)

        let silent = ETIRGraph(ETIRGraphSource(originalChannels: [[0, 0, 0]], emittedChannels: [[0, 0, 0]],
                                               sampleRate: 8, onsetFrame: 0, cutFrame: nil,
                                               sourceStartFrame: 0))
        XCTAssertNil(silent.envelopeDb)
        // 全部0なら EDC は -120 のまま、RT60 は無い（ir-preparation.js:315-316, :167-189）。
        XCTAssertEqual(silent.current.edcDb, [-120, -120, -120])
        XCTAssertNil(silent.current.rt60Seconds)
    }
}
