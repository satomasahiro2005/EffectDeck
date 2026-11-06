//  NoteSpectrogramLocalKeyTests.swift
//  Note Spectrogram の音名の綴りが局所の調に従うこと（EffeTune 2.17.0 / DSP 0.17.0）。**Foundation だけ。**
//
//  2.16.0 は全体の調（overallKey）で綴りを決めていた。2.17.0 は局所の調（localKey。上流 _setNotationKey(localKey)）。
//  壊れると: 全体の調が違う曲の途中で、Lowest / Highest Note や和音名の綴り（# と ♭）が上流とずれる。
//  nil（まだ）と 24（調なし）は # の綴り。

import XCTest

final class NoteSpectrogramLocalKeyTests: XCTestCase {

    private typealias K = ETNoteChordKey

    private let sharps = ETNoteChordKey.sharpNames
    /// D♭ major（キー 1）は ♭ の綴り。F# major（キー 6）は # の綴り。
    private var flats: [String] { K.keyNoteNames[1] }

    private func chordFrame(index: UInt32, local: UInt8, overall: UInt8) -> ETFrame {
        var p = [UInt8](repeating: 0, count: 32)
        func put(_ bytes: [UInt8], _ at: Int) { TelemetryBytes.put(bytes, at: at, into: &p) }
        put(TelemetryBytes.f32(48000), 0)
        put(TelemetryBytes.f32(1), 4)
        put(TelemetryBytes.f32(0.02), 8)
        put(TelemetryBytes.u32(1), 12)
        put(TelemetryBytes.u32(index), 16)
        put([0, 0, 0, 0, 0, 0, local, overall], 20)
        put(TelemetryBytes.f32(0.9), 28)
        return ETFrame(type: ETNoteChordKey.frameType, version: ETNoteChordKey.version, tapId: 7, sequence: 1,
                       dropped: false, payload: p)
    }

    /// 枠 index を 1 枚だけ当てた帯の調（世代 1、輪は空）。
    private func track(afterLocal local: UInt8, overall: UInt8, index: UInt32 = 20) throws -> ETNoteChordTrack {
        var t = ETNoteChordTrack(columns: 64)
        let frame = try XCTUnwrap(ETNoteChordKeyFrame(chordFrame(index: index, local: local, overall: overall)))
        _ = t.apply(frame, activeGeneration: 1,
                    frames: [(generation: UInt32, index: UInt32)?](repeating: nil, count: 64), head: 0, count: 0)
        return t
    }

    func testSpellingFollowsLocalKeyNotOverallKey() throws {
        // 局所が D♭ major、全体が F# major。綴りは局所（♭）に従う。2.16.0 なら # だった。
        let t = try track(afterLocal: 1, overall: 6)
        XCTAssertEqual(t.localKey, 1)
        XCTAssertEqual(t.overallKey, 6)
        XCTAssertEqual(t.notationKey, 1)
        XCTAssertEqual(t.notationNames, flats)
        XCTAssertNotEqual(t.notationNames, K.noteNames(forKey: 6), "全体の調では綴らない")
        XCTAssertEqual(t.notationNames[1], "D\u{266D}")

        // 逆に、局所が F# major（#）で全体が D♭ major（♭）なら #。
        let u = try track(afterLocal: 6, overall: 1)
        XCTAssertEqual(u.notationNames, K.noteNames(forKey: 6))
        XCTAssertEqual(u.notationNames[6], "F#")
    }

    func testNoLocalKeyFallsBackToSharps() throws {
        // 24 は調なし。全体の調が ♭ でも # の綴り。
        let none = try track(afterLocal: 24, overall: 1)
        XCTAssertEqual(none.localKey, 24)
        XCTAssertEqual(none.notationNames, sharps)
        XCTAssertEqual(K.noteNames(forKey: 24), sharps)
        // 255 はまだ（nil）。これも # の綴り。
        let pending = try track(afterLocal: 255, overall: 1)
        XCTAssertNil(pending.localKey)
        XCTAssertNil(pending.notationKey)
        XCTAssertEqual(pending.notationNames, sharps)
        // 何も当てていない帯、clear した帯も # の綴り。
        var cleared = try track(afterLocal: 1, overall: 1)
        XCTAssertEqual(cleared.notationNames, flats)
        cleared.clear()
        XCTAssertNil(cleared.notationKey)
        XCTAssertEqual(cleared.notationNames, sharps)
        XCTAssertEqual(ETNoteChordTrack(columns: 8).notationNames, sharps)
    }

    func testLocalKeyChangeMovesTheSpelling() throws {
        var t = ETNoteChordTrack(columns: 64)
        let empty = [(generation: UInt32, index: UInt32)?](repeating: nil, count: 64)
        func feed(_ index: UInt32, local: UInt8, overall: UInt8) throws -> Bool {
            let frame = try XCTUnwrap(ETNoteChordKeyFrame(chordFrame(index: index, local: local, overall: overall)))
            return t.apply(frame, activeGeneration: 1, frames: empty, head: 0, count: 0)
        }
        // 全体は C major のまま、局所だけ D♭ major → F# major → 調なしと動く。
        XCTAssertTrue(try feed(1, local: 0, overall: 0))
        XCTAssertEqual(t.notationNames, sharps)
        XCTAssertTrue(try feed(2, local: 1, overall: 0))
        XCTAssertEqual(t.notationNames, flats, "局所だけが動いても綴りが変わる")
        XCTAssertTrue(try feed(3, local: 6, overall: 0))
        XCTAssertEqual(t.notationNames, K.noteNames(forKey: 6))
        XCTAssertTrue(try feed(4, local: 24, overall: 0))
        XCTAssertEqual(t.notationNames, sharps)
        // 局所が同じなら、全体が動いても綴りは動かない。
        XCTAssertTrue(try feed(5, local: 1, overall: 0))
        XCTAssertTrue(try feed(6, local: 1, overall: 6))
        XCTAssertEqual(t.notationNames, flats)
    }

    /// 上流の実カーネルの出力（chord-key-telemetry.bin）。最初の 15 枠は調がまだ（# の綴り）、その後は C major（# の綴り）。
    func testUpstreamFixtureSpelling() throws {
        let url = try XCTUnwrap(TestResource.url("chord-key-telemetry", "bin"),
                                "fixture が見つからない（project.yml の resources）")
        let bytes = [UInt8](try Data(contentsOf: url))
        XCTAssertEqual(bytes.count, 126 * 48)
        var t = ETNoteChordTrack(columns: 512)
        let empty = [(generation: UInt32, index: UInt32)?](repeating: nil, count: 512)
        for k in 0..<126 {
            let base = k * 48
            let frame = ETFrame(type: 32, version: 1, tapId: 206, sequence: UInt32(k), dropped: false,
                                payload: Array(bytes[(base + 16)..<(base + 48)]))
            let decoded = try XCTUnwrap(ETNoteChordKeyFrame(frame), "枠 \(k) が読めない")
            _ = t.apply(decoded, activeGeneration: decoded.generation, frames: empty, head: 0, count: 0)
            if k < 15 {
                XCTAssertNil(t.notationKey, "枠 \(k) は調がまだ")
            } else {
                XCTAssertEqual(t.notationKey, 0, "枠 \(k) は局所の調 C major")
            }
            XCTAssertEqual(t.notationNames, sharps, "枠 \(k)")
        }
        XCTAssertEqual(t.notationKey, t.localKey)
    }
}
