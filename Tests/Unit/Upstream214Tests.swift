//  Upstream214Tests.swift
//  EffeTune 2.14.0（DSP 0.14.0）で変わったものの見張り。**Foundation だけ。**
//
//  - 版と目録（112 種のまま。Analog Meter・Note Spectrogram・Oscilloscope・SFZ Note Player の鍵が増えた）
//  - Analog Meter の Custom（効く行・出す行・Dial ごとの目盛り）
//  - SFZ Note Player の声の枠（型 30・版 1）と鍵の並び
//  - Note Spectrogram の枠の版 6（末尾に 88 鍵の音程のずれ）
//  - 表示の設定（Note Spectrogram の hl、SFZ の cl、Analog Meter の dc）

import XCTest

final class Upstream214Tests: XCTestCase {

    private func spec(_ type: String) throws -> ETEffect {
        try XCTUnwrap(ETCatalog.first { $0.type == type }, "\(type) が目録に無い")
    }

    // MARK: 版と目録

    /// 版の見張りは Upstream215Tests へ移った（2.15.0 は効果を足していない。112 のまま）。
    func testCatalogStillHas112Effects() {
        XCTAssertEqual(ETCatalog.count, 112)
    }

    func testNewParametersAreInTheCatalog() throws {
        let analog = try spec("AnalogMeterPlugin")
        XCTAssertEqual(analog.params.map(\.key), ["md", "de", "it", "at", "rt", "nr", "os"])
        XCTAssertEqual(analog.defaults, [0, 0, 0.3, 5, 1.5, 300, 1.25].reordered(by: analog))
        if case .enumeration(let detectors) = try XCTUnwrap(analog.params.first { $0.key == "de" }).kind {
            XCTAssertEqual(detectors, ETAnalogMeter.detectors)
        } else { XCTFail("de は選択") }

        let scope = try spec("OscilloscopePlugin")
        if case .number(_, let hi, _, _, _) = try XCTUnwrap(scope.params.first { $0.key == "dt" }).kind {
            XCTAssertEqual(hi, 10, "Display Time は 10 秒まで")
        } else { XCTFail("dt は数") }

        let sfz = try spec("SFZNotePlayerPlugin")
        XCTAssertNotNil(sfz.params.first { $0.key == "ss" && !$0.runtimeOnly }, "Sample Shift は保存する")
        XCTAssertEqual(sfz.params.filter(\.runtimeOnly).map(\.key), ["pm", "pv"], "試し弾きは保存しない")
        XCTAssertEqual(try XCTUnwrap(sfz.params.first { $0.key == "pm" }).defaultValue, -1, "-1 は鳴らさない")

        let note = try spec("NoteSpectrogramPlugin")
        XCTAssertEqual(note.params.filter(\.runtimeOnly).map(\.key), ["te"], "te は色と Highlight から決まる")
    }

    func testRuntimeOnlyKeysAreNotSaved() throws {
        let loaded = PipelineStore.parse([["nm": "SFZ Note Player", "pm": 60, "pv": 90, "ss": 2]], catalog: ETCatalog)
        let written = PipelineStore.shortForm(loaded)[0]
        XCTAssertNil(written["pm"])
        XCTAssertNil(written["pv"])
        XCTAssertEqual((written["ss"] as? NSNumber)?.doubleValue, 2)
    }

    // MARK: Analog Meter の Custom

    private func custom(detector: Int = 0, dial: Int = 0) -> ETAnalogMeter.Settings {
        var s = ETAnalogMeter.Settings()
        s.mode = ETAnalogMeter.customMode
        s.detector = detector
        s.dial = dial
        return s
    }

    func testCustomShowsEveryApplicableRowAndGatesByDetectorAndDial() {
        let s = custom()
        for key in ["de", "it", "rt", "nr", "os", "dc", "rl", "rg", "ph"] {
            XCTAssertTrue(ETAnalogMeter.isVisible(key, settings: s), key)
        }
        for key in ["at", "sc", "ln", "tg", "ls"] {
            XCTAssertFalse(ETAnalogMeter.isVisible(key, settings: s), key)
        }
        // Average Rectified では Integration も Release も効かない。
        XCTAssertFalse(ETAnalogMeter.isActive("it", settings: s))
        XCTAssertFalse(ETAnalogMeter.isActive("rt", settings: s))
        XCTAssertTrue(ETAnalogMeter.isActive("it", settings: custom(detector: 1)))
        XCTAssertTrue(ETAnalogMeter.isActive("rt", settings: custom(detector: 3)))
        // Reference は dBFS の目盛り（4）で効かない。Range は DIN・dB・dBFS だけ。
        XCTAssertFalse(ETAnalogMeter.isActive("rl", settings: custom(dial: 4)))
        XCTAssertEqual((0..<5).map { ETAnalogMeter.isActive("rg", settings: custom(dial: $0)) },
                       [false, true, false, true, true])
        XCTAssertTrue(ETAnalogMeter.holdsPeak(mode: ETAnalogMeter.customMode))
    }

    func testCustomDialPicksTheScale() {
        let units = (0..<5).map { ETAnalogMeter.scale(mode: "Custom", settings: custom(dial: $0)).unit }
        XCTAssertEqual(units, ["VU", "dB", "", "dB", "dBFS"])
        XCTAssertEqual(ETAnalogMeter.scale(mode: "Custom", settings: custom(detector: 3, dial: 4)).unit, "dBTP")
        // dB の目盛りは RMS と同じ（上端は -Reference）。
        let rms = ETAnalogMeter.scale(mode: "Custom", settings: custom(dial: 3))
        XCTAssertEqual(rms.max, 14)
    }

    func testCustomFramesAreRead() {
        var p: [UInt8] = [6, 1, 0, 0]
        p += TelemetryBytes.f32(-20) + TelemetryBytes.f32(-10)
        let frame = ETFrame(type: 27, version: 1, tapId: 1, sequence: 1, dropped: false, payload: p)
        XCTAssertEqual(ETAnalogMeter.parse(frame)?.mode, ETAnalogMeter.customMode)
    }

    func testNewPresetsCarryTheDial() throws {
        let presets = ETEffectPresetList.filter { $0.effect == "Analog Meter" }
        let byId = Dictionary(uniqueKeysWithValues: presets.map { ($0.presetId, $0) })
        for id in ["bouncy-vu", "slow-rms", "fast-peak"] { XCTAssertNotNil(byId[id], id) }
        let fast = try XCTUnwrap(byId["fast-peak"])
        XCTAssertEqual(ETDisplayParam.read(fast.params, type: "AnalogMeterPlugin")["dc"].flatMap(Double.init), 4)
    }

    // MARK: SFZ Note Player の声

    private func voicePayload(total: Int, limit: Int, voices: [(midi: Int, count: Int, velocity: Float)]) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: ETSFZVoiceFrame.byteCount)
        func put(_ b: [UInt8], _ o: Int) { for (i, v) in b.enumerated() { p[o + i] = v } }
        put([UInt8(total & 0xff), UInt8(total >> 8)], 0)
        put([UInt8(limit & 0xff), UInt8(limit >> 8)], 2)
        for v in voices {
            put([UInt8(v.count & 0xff), UInt8(v.count >> 8)], 4 + v.midi * 8)
            put(TelemetryBytes.f32(v.velocity), 8 + v.midi * 8)
        }
        return p
    }

    func testVoiceFrameIsRead() throws {
        let p = voicePayload(total: 3, limit: 32, voices: [(60, 2, 0.8), (64, 1, 0.5)])
        let frame = try XCTUnwrap(ETSFZVoiceFrame.parse(type: 30, version: 1, payload: p))
        XCTAssertEqual(frame.total, 3)
        XCTAssertEqual(frame.counts[60], 2)
        XCTAssertEqual(frame.velocities[64], 0.5)

        var display = ETSFZVoiceDisplay()
        display.accept(frame, now: 10)
        XCTAssertEqual(display.velocity(60, now: 11), 0.8 * Float(exp(-1.0)), accuracy: 1e-6)
        // 次の枠で鳴りやんだ鍵は、前の強さを経った秒だけ落として残る。
        display.accept(try XCTUnwrap(ETSFZVoiceFrame.parse(type: 30, version: 1,
                                                            payload: voicePayload(total: 0, limit: 32, voices: []))),
                       now: 10.5)
        XCTAssertEqual(display.velocity(60, now: 10.5), 0.8 * Float(exp(-0.5)), accuracy: 1e-6)
        XCTAssertEqual(display.counts[60], 0)
    }

    func testVoiceFrameRejectsBadCounts() {
        XCTAssertNil(ETSFZVoiceFrame.parse(type: 30, version: 2, payload: voicePayload(total: 0, limit: 1, voices: [])))
        XCTAssertNil(ETSFZVoiceFrame.parse(type: 30, version: 1, payload: voicePayload(total: 0, limit: 0, voices: [])))
        XCTAssertNil(ETSFZVoiceFrame.parse(type: 30, version: 1,
                                           payload: voicePayload(total: 2, limit: 32, voices: [(60, 1, 0.5)])),
                     "数の合計が total と違う")
        XCTAssertNil(ETSFZVoiceFrame.parse(type: 30, version: 1,
                                           payload: voicePayload(total: 0, limit: 32, voices: [(60, 0, 0.5)])),
                     "鳴っていない鍵に強さ")
        XCTAssertNil(ETSFZVoiceFrame.parse(type: 30, version: 1, payload: [UInt8](repeating: 0, count: 1027)))
    }

    /// frequency-axis.js の noteAxisKeys と同じ並び。C4〜B4 を 120pt に置く。
    func testNoteAxisKeys() throws {
        let keys = ETNoteAxisKey.keys(lowest: 60, highest: 71, length: 120)
        XCTAssertEqual(keys.filter(\.black).map(\.midi), [61, 63, 66, 68, 70])
        // 72 は幅が 0 なので入らない（上流も whiteEnd <= whiteStart を落とす）。
        XCTAssertEqual(keys.filter { !$0.black }.map(\.midi), [60, 62, 64, 65, 67, 69, 71])
        let c = try XCTUnwrap(keys.first { $0.midi == 60 })
        XCTAssertEqual(c.whiteStart, 0, accuracy: 1e-9)
        XCTAssertEqual(c.whiteEnd, 120.0 / 7, accuracy: 1e-9)
        // 黒鍵の深さまでは黒鍵が先、その奥は白鍵。
        XCTAssertEqual(ETNoteAxisKey.hit(keys, along: 15, across: 5, gutter: 30, blackDepth: 19)?.midi, 61)
        XCTAssertEqual(ETNoteAxisKey.hit(keys, along: 15, across: 25, gutter: 30, blackDepth: 19)?.midi, 60)
        XCTAssertNil(ETNoteAxisKey.hit(keys, along: 15, across: 31, gutter: 30, blackDepth: 19))
    }

    // MARK: Note Spectrogram の枠（版 6）

    private func noteFrame(version: UInt16, bytes: Int, cents: Float = 12.5) -> ETFrame {
        var p = [UInt8](repeating: 0, count: bytes)
        func put(_ b: [UInt8], _ o: Int) { for (i, v) in b.enumerated() where o + i < p.count { p[o + i] = v } }
        put(TelemetryBytes.f32(48000), 0)
        put(TelemetryBytes.f32(1.5), 4)
        put([UInt8(440 & 0xff), UInt8(440 >> 8)], 8)
        put([21, 0], 10)
        put(TelemetryBytes.f32(0.02), 12)
        put(TelemetryBytes.u32(7), 16)
        put(TelemetryBytes.u32(5), 20)
        put(TelemetryBytes.u32(1), 24)
        for i in 0..<440 { put(TelemetryBytes.f32(-60), 1792 + 4 * i) }
        if bytes >= 9192 { for i in 0..<88 { put(TelemetryBytes.f32(cents), 8840 + 4 * i) } }
        return ETFrame(type: 24, version: version, tapId: 1, sequence: 1, dropped: false, payload: p)
    }

    func testNoteSpectrogramVersion6CarriesPitchCents() throws {
        XCTAssertEqual(ETNoteFrameLayout.payloadBytes, 9192)
        let s = try XCTUnwrap(ETNoteSnapshot(noteFrame(version: 6, bytes: 9192)))
        XCTAssertEqual(s.pitchCents.count, 88)
        XCTAssertEqual(s.pitchCents[0], 12.5)
        let old = try XCTUnwrap(ETNoteSnapshot(noteFrame(version: 5, bytes: 8840)))
        XCTAssertEqual(old.pitchCents, [Float](repeating: 0, count: 88))
        XCTAssertNil(ETNoteSnapshot(noteFrame(version: 6, bytes: 8840)), "版 6 の長さでない")
        XCTAssertNil(ETNoteSnapshot(noteFrame(version: 5, bytes: 9192)), "版 5 の長さでない")
        XCTAssertNil(ETNoteSnapshot(noteFrame(version: 6, bytes: 9192, cents: .nan)))
    }

    // MARK: Note Spectrogram の音色（型 31）

    private func timbreFrame(event: UInt32, probabilities: [Float]? = nil, midi: UInt32 = 60,
                             noteId: UInt32 = 5, tail: UInt32 = 0) -> ETFrame {
        var p = [UInt8](repeating: 0, count: 80)
        func put(_ b: [UInt8], _ o: Int) { for (i, v) in b.enumerated() { p[o + i] = v } }
        put(TelemetryBytes.f32(48000), 0)
        put(TelemetryBytes.f32(2), 4)
        put(TelemetryBytes.f32(0.02), 8)
        put(TelemetryBytes.u32(1), 12)
        put(TelemetryBytes.u32(120), 16)
        put(TelemetryBytes.u32(noteId), 20)
        put(TelemetryBytes.u32(midi), 24)
        put(TelemetryBytes.u32(event), 28)
        put(TelemetryBytes.u32(100), 32)
        put(TelemetryBytes.u32(0xffff_ffff), 36)
        for (i, v) in (probabilities ?? []).enumerated() { put(TelemetryBytes.f32(v), 40 + i * 4) }
        put(TelemetryBytes.u32(tail), 76)
        return ETFrame(type: 31, version: 1, tapId: 1, sequence: 1, dropped: false, payload: p)
    }

    func testTimbreEventsAreRead() throws {
        let start = try XCTUnwrap(ETNoteTimbreEvent(timbreFrame(event: 1)))
        XCTAssertEqual(start.kind, .start)
        XCTAssertNil(start.probabilities)
        XCTAssertEqual(start.endFrameIndex, ETNoteTimbreEvent.openEnd)
        let p: [Float] = [0.1, 0, 0, 0, 0, 0, 0, 0.2, 0.7]
        let result = try XCTUnwrap(ETNoteTimbreEvent(timbreFrame(event: 2, probabilities: p)))
        XCTAssertEqual(result.probabilities, p)
        XCTAssertNil(ETNoteTimbreEvent(timbreFrame(event: 2, probabilities: [0.5])), "合計が 1 でない")
        XCTAssertNil(ETNoteTimbreEvent(timbreFrame(event: 4)))
        XCTAssertNil(ETNoteTimbreEvent(timbreFrame(event: 1, midi: 20)))
        XCTAssertNil(ETNoteTimbreEvent(timbreFrame(event: 1, noteId: 0)))
        XCTAssertNil(ETNoteTimbreEvent(timbreFrame(event: 1, tail: 1)))
    }

    func testTimbreColorsAndHighlight() {
        // Vocal だけなら Vocal の色、3 分類では Bass と Vocal 以外は Other の色に寄る。
        let vocal: [Float] = [0, 0, 0, 0, 0, 0, 0, 0, 1]
        XCTAssertTrue(ETNoteTimbre.color(vocal, threeClass: false) == ETNoteTimbre.colors[8])
        let guitar: [Float] = [0, 1, 0, 0, 0, 0, 0, 0, 0]
        XCTAssertTrue(ETNoteTimbre.color(guitar, threeClass: true) == ETNoteTimbre.colors[7])
        XCTAssertEqual(ETNoteTimbre.highlightProbability(guitar, target: "Other3"), 1)
        XCTAssertEqual(ETNoteTimbre.highlightProbability(guitar, target: "Guitar"), 1)
        XCTAssertEqual(ETNoteTimbre.highlightProbability(guitar, target: "Other9"), 0)
        XCTAssertEqual(ETNoteTimbre.highlightProbability(nil, target: "Vocal"), 0)
        XCTAssertEqual(ETNoteTimbre.highlights.map(\.value),
                       ["None", "Vocal", "Bass", "Other3", "Guitar", "Piano", "Strings", "Wind", "Synth", "Organ",
                        "Other9"])
    }

    // MARK: 表示の設定

    func testDisplayTables() {
        XCTAssertEqual(ETDisplayParam.table(for: "NoteSpectrogramPlugin")["hl"], .text)
        XCTAssertEqual(ETDisplayParam.table(for: "NoteSpectrogramPlugin")["os"], .flag)
        XCTAssertEqual(ETDisplayParam.table(for: "SFZNotePlayerPlugin"), ["cl": .text])
        XCTAssertEqual(ETDisplayParam.table(for: "AnalogMeterPlugin")["dc"], .number)
        XCTAssertEqual(ETDisplayParam.defaults(for: "AnalogMeterPlugin")["dc"], "0.0")
    }
}

private extension Array where Element == Float {
    /// 既定値を目録の並び（offset の順）で比べるための並べ直し。引数は md, de, it, at, rt, nr, os の順。
    func reordered(by spec: ETEffect) -> [Float] {
        let keys = ["md", "de", "it", "at", "rt", "nr", "os"]
        var out = [Float](repeating: .nan, count: spec.floatCount)
        for (i, key) in keys.enumerated() {
            if let p = spec.params.first(where: { $0.key == key }), out.indices.contains(p.offset) { out[p.offset] = self[i] }
        }
        return out
    }
}
