//  Upstream216Tests.swift
//  EffeTune 2.16.0（DSP 0.16.0）で変わったものの見張り。**Foundation だけ。**
//
//  2.16.0 が足したのは Note Spectrogram の Chords & Key（ck）と Rhythm Analyzer の Display（dm）、
//  Mastering のシステムプリセット 10 本。効果は増えていない（112 種のまま）。
//  壊れると: ck / dm が保存されない・読めない、パラメータの hash がカーネルとずれて
//  et_instance_set_params が断られる、Mastering のプリセットが並ばない。
//
//  Chords & Key の型 32 の枠（ETNoteChordKeyFrame）、調の綴り（ETNoteChordKey）、列への当て方（ETNoteChordTrack）、
//  Rhythm Analyzer の Display（ETRhythmDisplayMode。枠の読みと状態は RhythmAnalyzerTests）もここで見る。

import XCTest

final class Upstream216Tests: XCTestCase {

    private func spec(_ type: String) throws -> ETEffect {
        try XCTUnwrap(ETCatalog.first { $0.type == type }, "\(type) が目録に無い")
    }

    // MARK: 版と目録

    func testUpstreamVersionIs0_16_0() {
        XCTAssertEqual(ETUpstreamVersion, "0.16.0")
        XCTAssertEqual(ETUpstreamAppVersion, "2.16.0", "package.json の版。公式の PC との食い違いの表示に使う")
        XCTAssertEqual(ETCatalog.count, 112)
    }

    func testNoteSpectrogramChordKeyParameter() throws {
        let s = try spec("NoteSpectrogramPlugin")
        XCTAssertEqual(s.paramsHash, 0xb8518943, "カーネルの hash と食い違うと set_params が断られる")
        XCTAssertEqual(s.floatCount, 4)
        XCTAssertEqual(s.defaults, [28, 91, 0, 0])
        let ck = try XCTUnwrap(s.params.first { $0.key == "ck" })
        XCTAssertEqual(ck.name, "chordKeyEnabled")
        XCTAssertEqual(ck.label, "Chords & Key")
        XCTAssertEqual(ck.offset, 3)
        XCTAssertEqual(ck.defaultValue, 0, "既定は切る")
        XCTAssertFalse(ck.runtimeOnly, "保存する")
        guard case .toggle = ck.kind else { return XCTFail("ck は切り替え") }
        XCTAssertEqual(s.params.first?.key, "ck", "createUI の先頭")
        // 2.14.0 までの位置は動かない。
        XCTAssertEqual(try XCTUnwrap(s.params.first { $0.key == "mn" }).offset, 0)
        XCTAssertEqual(try XCTUnwrap(s.params.first { $0.key == "mx" }).offset, 1)
        XCTAssertEqual(try XCTUnwrap(s.params.first { $0.key == "te" }).offset, 2)
    }

    func testRhythmAnalyzerDisplayParameter() throws {
        let r = try spec("RhythmAnalyzerPlugin")
        XCTAssertEqual(r.paramsHash, 0xf854c585, "カーネルの hash と食い違うと set_params が断られる")
        XCTAssertEqual(r.floatCount, 4)
        XCTAssertEqual(r.defaults, [40, 240, 0, 0])
        let dm = try XCTUnwrap(r.params.first { $0.key == "dm" })
        XCTAssertEqual(dm.name, "displayMode")
        XCTAssertEqual(dm.label, "Display")
        XCTAssertEqual(dm.offset, 3)
        XCTAssertEqual(dm.defaultValue, 0, "band")
        XCTAssertFalse(dm.runtimeOnly, "保存する")
        guard case .enumeration(let options) = dm.kind else { return XCTFail("dm は選択") }
        XCTAssertEqual(options, ["band", "drums"])
        XCTAssertEqual(try XCTUnwrap(r.params.first { $0.key == "mn" }).offset, 0)
        XCTAssertEqual(try XCTUnwrap(r.params.first { $0.key == "mx" }).offset, 1)
        XCTAssertEqual(try XCTUnwrap(r.params.first { $0.key == "ck" }).offset, 2)
    }

    // MARK: 読み書き

    func testOldChainsLoadWithTheNewDefaults() throws {
        let s = try spec("NoteSpectrogramPlugin")
        let r = try spec("RhythmAnalyzerPlugin")
        let loaded = PipelineStore.parse([["nm": "Note Spectrogram", "mn": 40, "mx": 80],
                                          ["nm": "Rhythm Analyzer", "mn": 60, "mx": 180]],
                                         catalog: ETCatalog)
        XCTAssertEqual(loaded.count, 2)
        let ck = try XCTUnwrap(s.params.first { $0.key == "ck" })
        XCTAssertEqual(loaded[0].values[ck.offset], 0)
        XCTAssertEqual(Array(loaded[0].values.prefix(2)), [40, 80])
        let dm = try XCTUnwrap(r.params.first { $0.key == "dm" })
        XCTAssertEqual(loaded[1].values[dm.offset], 0)
        XCTAssertEqual(Array(loaded[1].values.prefix(2)), [60, 180])
    }

    func testDrumsAndChordKeyRoundTrip() throws {
        let s = try spec("NoteSpectrogramPlugin")
        let r = try spec("RhythmAnalyzerPlugin")
        let ck = try XCTUnwrap(s.params.first { $0.key == "ck" })
        let dm = try XCTUnwrap(r.params.first { $0.key == "dm" })
        let loaded = PipelineStore.parse([["nm": "Note Spectrogram", "ck": true],
                                          ["nm": "Rhythm Analyzer", "dm": "drums"]],
                                         catalog: ETCatalog)
        XCTAssertEqual(loaded[0].values[ck.offset], 1)
        XCTAssertEqual(loaded[1].values[dm.offset], 1)
        let written = PipelineStore.shortForm(loaded)
        XCTAssertEqual(written[0]["ck"] as? Bool, true)
        XCTAssertEqual(written[1]["dm"] as? String, "drums")
        let again = PipelineStore.parse(written, catalog: ETCatalog)
        XCTAssertEqual(again[0].values[ck.offset], 1)
        XCTAssertEqual(again[1].values[dm.offset], 1)
    }

    // MARK: Mastering

    func testMasteringSystemPresetsExist() {
        let mastering = ETSystemPresets.filter { $0.category == "Mastering" }
        XCTAssertEqual(mastering.count, 10)
        XCTAssertEqual(Set(mastering.map(\.name)).count, 10, "名前が重ならない")
        XCTAssertTrue(ETSystemPresets.filter { $0.category == "mastering" }.isEmpty, "見出しは大文字で始める")
        XCTAssertEqual(ETSystemPresets.count, 28)
    }

    // MARK: Rhythm Analyzer の Display（保存形式）

    func testDisplayModeLoadAndWrite() throws {
        let r = try spec("RhythmAnalyzerPlugin")
        let dm = try XCTUnwrap(r.params.first { $0.key == "dm" })
        // dm を持たない鎖と、知らない綴りは band。
        let loaded = PipelineStore.parse([["nm": "Rhythm Analyzer", "mn": 60],
                                          ["nm": "Rhythm Analyzer", "dm": "bogus"],
                                          ["nm": "Rhythm Analyzer", "dm": "band"]],
                                         catalog: ETCatalog)
        XCTAssertEqual(loaded.map { $0.values[dm.offset] }, [0, 0, 0])
        // 書くときはいつも綴りで書く（上流 getParameters と同じ）。
        let written = PipelineStore.shortForm(loaded)
        XCTAssertEqual(written.map { $0["dm"] as? String }, ["band", "band", "band"])
        XCTAssertEqual(ETRhythmDisplayMode.from(value: loaded[0].values[dm.offset]), .band)
    }

    // MARK: Note Spectrogram の Chords & Key

    /// 型 32・版 1・32 バイトの枠を作る。
    private func chordFrame(index: UInt32 = 10, generation: UInt32 = 1, rate: Float = 48000, time: Float = 1,
                            hop: Float = 0.02,
                            immediate: (UInt8, UInt8, UInt8) = (0, 0, 0),
                            confirmed: (UInt8, UInt8, UInt8) = (0, 0, 0),
                            local: UInt8 = 0, overall: UInt8 = 0, probability: Float = 0.9,
                            version: UInt16 = 1, length: Int = 32) -> ETFrame {
        var p = [UInt8](repeating: 0, count: 32)
        func put(_ bytes: [UInt8], _ at: Int) { TelemetryBytes.put(bytes, at: at, into: &p) }
        put(TelemetryBytes.f32(rate), 0)
        put(TelemetryBytes.f32(time), 4)
        put(TelemetryBytes.f32(hop), 8)
        put(TelemetryBytes.u32(generation), 12)
        put(TelemetryBytes.u32(index), 16)
        put([immediate.0, immediate.1, immediate.2, confirmed.0, confirmed.1, confirmed.2, local, overall], 20)
        put(TelemetryBytes.f32(probability), 28)
        let payload = length <= 32 ? Array(p.prefix(length)) : p + [UInt8](repeating: 0, count: length - 32)
        return ETFrame(type: ETNoteChordKey.frameType, version: version, tapId: 7, sequence: 1,
                       dropped: false, payload: payload)
    }

    func testChordKeyFrameType() {
        XCTAssertEqual(ETFrameType.noteChordKey.rawValue, 32)
        // Telemetry.queuedTypes（50 fps の枠を畳まない）は os に触るので、このバンドルには入らない。実機で見る。
    }

    func testDecodesAChordKeyFrame() throws {
        let f = try XCTUnwrap(ETNoteChordKeyFrame(chordFrame(
            index: 77, generation: 3, rate: 44100, time: 2.5, hop: 0.02,
            immediate: (7, 6, 11), confirmed: (9, 1, 9), local: 14, overall: 255, probability: 0.75)))
        XCTAssertEqual(f.sampleRate, 44100)
        XCTAssertEqual(f.time, 2.5)
        XCTAssertEqual(f.hopSeconds, Double(Float(0.02)))
        XCTAssertEqual(f.generation, 3)
        XCTAssertEqual(f.frameIndex, 77)
        XCTAssertEqual(f.immediateName, "G7/B")
        XCTAssertEqual(f.confirmedName, "Am")
        XCTAssertEqual(f.confirmedRoot, 9)
        XCTAssertEqual(f.localKey, 14)
        XCTAssertNil(f.overallKey, "255 はまだ")
        XCTAssertEqual(f.confirmedProbability, 0.75)
        // 和音なしは (255, 255, 255)。
        let none = try XCTUnwrap(ETNoteChordKeyFrame(chordFrame(immediate: (255, 255, 255), confirmed: (255, 255, 255),
                                                                local: 24, overall: 23)))
        XCTAssertEqual(none.immediateName, "")
        XCTAssertEqual(none.confirmedName, "")
        XCTAssertNil(none.confirmedRoot)
        XCTAssertEqual(none.localKey, 24, "24 は調なし（255 のまだとは別）")
        XCTAssertEqual(none.overallKey, 23)
    }

    func testRejectsMalformedChordKeyFrames() {
        func ok(_ frame: ETFrame) -> Bool { ETNoteChordKeyFrame(frame) != nil }
        XCTAssertTrue(ok(chordFrame()))
        XCTAssertFalse(ok(chordFrame(confirmed: (12, 0, 0))), "root 12")
        XCTAssertFalse(ok(chordFrame(confirmed: (0, 11, 0))), "quality 11")
        XCTAssertFalse(ok(chordFrame(confirmed: (0, 0, 12))), "bass 12")
        XCTAssertFalse(ok(chordFrame(immediate: (255, 0, 0))), "255 は 3 つそろったときだけ")
        XCTAssertFalse(ok(chordFrame(confirmed: (255, 255, 0))))
        XCTAssertTrue(ok(chordFrame(local: 24)))
        XCTAssertTrue(ok(chordFrame(local: 255)))
        XCTAssertFalse(ok(chordFrame(local: 25)))
        XCTAssertFalse(ok(chordFrame(local: 254)))
        XCTAssertTrue(ok(chordFrame(overall: 23)))
        XCTAssertFalse(ok(chordFrame(overall: 24)))
        XCTAssertFalse(ok(chordFrame(probability: .nan)))
        XCTAssertFalse(ok(chordFrame(probability: -0.01)))
        XCTAssertFalse(ok(chordFrame(probability: 1.01)))
        XCTAssertTrue(ok(chordFrame(probability: 1)))
        XCTAssertFalse(ok(chordFrame(length: 31)))
        XCTAssertFalse(ok(chordFrame(length: 33)))
        XCTAssertFalse(ok(chordFrame(version: 2)))
        XCTAssertFalse(ok(chordFrame(generation: 0)))
        XCTAssertFalse(ok(chordFrame(rate: 0)))
        XCTAssertFalse(ok(chordFrame(rate: .nan)))
        XCTAssertFalse(ok(chordFrame(hop: 0)))
        XCTAssertFalse(ok(chordFrame(hop: -0.02)))
        XCTAssertFalse(ok(chordFrame(time: -1)))
        XCTAssertFalse(ok(chordFrame(time: .infinity)))
        var wrongType = chordFrame()
        wrongType = ETFrame(type: 31, version: 1, tapId: 7, sequence: 1, dropped: false, payload: wrongType.payload)
        XCTAssertFalse(ok(wrongType))
    }

    /// 上流の実カーネルの出力（Tests/Fixtures/NoteSpectrogram に写した fixtures/chord-key-telemetry.bin）。126 枠 × (16 バイトの頭 + 32 バイト)。
    func testUpstreamChordKeyFixture() throws {
        let url = try XCTUnwrap(TestResource.url("chord-key-telemetry", "bin"),
                                "fixture が見つからない（project.yml の resources）")
        let bytes = [UInt8](try Data(contentsOf: url))
        XCTAssertEqual(bytes.count, 126 * 48)
        var frames: [ETNoteChordKeyFrame] = []
        for k in 0..<126 {
            let base = k * 48
            func u16(_ at: Int) -> UInt16 { UInt16(bytes[base + at]) | UInt16(bytes[base + at + 1]) << 8 }
            func u32(_ at: Int) -> UInt32 {
                (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[base + at + $1]) << (8 * UInt32($1)) }
            }
            XCTAssertEqual(u16(0), 32)
            XCTAssertEqual(u16(2), 1)
            XCTAssertEqual(u32(4), 206, "tap")
            XCTAssertEqual(u16(12), 32, "payload の長さ")
            let frame = ETFrame(type: u16(0), version: u16(2), tapId: u32(4), sequence: u32(8), dropped: false,
                                payload: Array(bytes[(base + 16)..<(base + 48)]))
            frames.append(try XCTUnwrap(ETNoteChordKeyFrame(frame), "枠 \(k) が読めない"))
        }
        for (k, f) in frames.enumerated() {
            XCTAssertEqual(f.generation, 2)
            XCTAssertEqual(f.frameIndex, UInt32(k), "連番")
            let confirmed = k < 10 ? "" : (k < 60 ? "C" : (k < 85 ? "G7" : "Am"))
            XCTAssertEqual(f.confirmedName, confirmed, "枠 \(k) の確定した和音")
            if k < 15 {
                XCTAssertNil(f.localKey, "最初の 15 枠は調がまだ")
                XCTAssertNil(f.overallKey)
            } else {
                XCTAssertEqual(f.localKey, 0, "枠 \(k) の局所の調は C major")
                XCTAssertEqual(f.overallKey, 0)
            }
        }
        XCTAssertEqual(frames[1].immediateName, "C")
    }

    func testKeyAndChordNames() {
        typealias K = ETNoteChordKey
        XCTAssertEqual(K.keyName(0), "C major")
        XCTAssertEqual(K.keyName(1), "D\u{266D} major")
        XCTAssertEqual(K.keyName(6), "F# major")
        XCTAssertEqual(K.keyName(15), "D# minor")
        XCTAssertEqual(K.keyName(22), "B\u{266D} minor")
        XCTAssertEqual(K.keyName(20), "G# minor")
        XCTAssertEqual(K.keyName(12), "C minor")
        XCTAssertEqual(K.keyName(24), "\u{2014}")
        XCTAssertEqual(K.keyNoteNames.count, 24)
        XCTAssertTrue(K.keyNoteNames.allSatisfy { $0.count == 12 })
        // 平たい調は全部同じ表。
        let flat = ["C", "D\u{266D}", "D", "E\u{266D}", "E", "F", "G\u{266D}", "G", "A\u{266D}", "A", "B\u{266D}", "B"]
        for key in [1, 3, 5, 8, 10, 12 + 0, 12 + 2, 12 + 5, 12 + 7, 12 + 10] {
            XCTAssertEqual(K.keyNoteNames[key], flat, "key \(key)")
        }
        // F# major と D# minor は # の綴りで F が E#。
        XCTAssertEqual(K.noteNames(forKey: 6)[5], "E#")
        XCTAssertEqual(K.noteNames(forKey: 15)[5], "E#")
        var sharp = K.sharpNames
        sharp[5] = "E#"
        XCTAssertEqual(K.noteNames(forKey: 6), sharp)
        // それ以外の # の調は普通の # の綴り。
        XCTAssertEqual(K.noteNames(forKey: 0), K.sharpNames)
        XCTAssertEqual(K.noteNames(forKey: 11), K.sharpNames, "B major")
        XCTAssertEqual(K.noteNames(forKey: 20), K.sharpNames, "G# minor")
        XCTAssertEqual(K.noteNames(forKey: nil), K.sharpNames)
        XCTAssertEqual(K.noteNames(forKey: 24), K.sharpNames)
        // 和音の名前。
        XCTAssertEqual(K.chordName(root: 0, quality: 4, bass: 4), "Cmaj7/E")
        XCTAssertEqual(K.chordName(root: 7, quality: 6, bass: 7), "G7")
        XCTAssertEqual(K.chordName(root: 255, quality: 255, bass: 255), "")
        XCTAssertNil(K.chordName(root: 12, quality: 0, bass: 0))
        XCTAssertEqual(K.chordName(root: 1, quality: 8, bass: 8), "C#m7b5/G#")
        // 表示では根音とスラッシュの後ろだけ綴りを変える。m7b5 の b5 は触らない。
        XCTAssertEqual(K.displayChordName("C#m7b5/G#", names: K.noteNames(forKey: 3)),
                       "D\u{266D}m7b5/A\u{266D}")
        XCTAssertEqual(K.displayChordName("C#m7b5/G#", names: K.sharpNames), "C#m7b5/G#")
        XCTAssertEqual(K.displayChordName("F", names: K.noteNames(forKey: 6)), "E#")
        XCTAssertEqual(K.displayChordName("Fmaj7/A", names: K.noteNames(forKey: 6)), "E#maj7/A")
        XCTAssertEqual(K.displayChordName("", names: K.noteNames(forKey: 3)), "")
        XCTAssertEqual(K.displayChordName("A#sus4", names: K.noteNames(forKey: 3)), "B\u{266D}sus4")
        XCTAssertEqual(K.noteName(midi: 61, names: K.noteNames(forKey: 3)), "D\u{266D}4")
        XCTAssertEqual(K.noteName(midi: 60, names: K.sharpNames), "C4")
        XCTAssertEqual(K.root(of: "C#m"), 1)
        XCTAssertEqual(K.root(of: "G7/B"), 7)
        XCTAssertNil(K.root(of: ""))
    }

    // MARK: 列への当て方

    /// n 列ぶんの枠（世代 1、番号 0..<n）が溜まった輪を作る。
    private func ring(columns: Int, written: Int, generation: UInt32 = 1)
        -> (frames: [(generation: UInt32, index: UInt32)?], head: Int, count: Int) {
        var frames = [(generation: UInt32, index: UInt32)?](repeating: nil, count: columns)
        var head = 0
        for i in 0..<written {
            frames[head] = (generation, UInt32(i))
            head = (head + 1) % columns
        }
        return (frames, head, min(written, columns))
    }

    private func chordKey(_ index: UInt32, _ confirmed: (UInt8, UInt8, UInt8), generation: UInt32 = 1,
                          local: UInt8 = 255, overall: UInt8 = 255) throws -> ETNoteChordKeyFrame {
        try XCTUnwrap(ETNoteChordKeyFrame(chordFrame(index: index, generation: generation, confirmed: confirmed,
                                                     local: local, overall: overall)))
    }

    func testConfirmedChordLabelsTheColumnElevenFramesBack() throws {
        XCTAssertEqual(ETNoteChordKey.confirmedLag, 11)
        var track = ETNoteChordTrack(columns: 64)
        let r = ring(columns: 64, written: 40)
        // 枠 25 の確定は、枠 14 の列に付く。その列だけ。
        XCTAssertTrue(try track.apply(chordKey(25, (0, 0, 0)), activeGeneration: 1, frames: r.frames,
                                      head: r.head, count: r.count))
        for column in 0..<40 {
            XCTAssertEqual(track.chords[column], column == 14 ? "C" : nil, "列 \(column)")
        }
        // 折り返しの輪でも当たる。
        var wrapped = ETNoteChordTrack(columns: 16)
        let w = ring(columns: 16, written: 20)   // 枠 4..19 が残る。枠 4 は列 4。
        XCTAssertTrue(try wrapped.apply(chordKey(19, (7, 6, 7)), activeGeneration: 1, frames: w.frames,
                                        head: w.head, count: w.count))
        XCTAssertEqual(wrapped.chords[8], "G7", "枠 8 は列 8")
    }

    func testStaleFramesAndOtherGenerationsAreIgnored() throws {
        var track = ETNoteChordTrack(columns: 64)
        let r = ring(columns: 64, written: 40)
        XCTAssertTrue(try track.apply(chordKey(25, (0, 0, 0), local: 0, overall: 0), activeGeneration: 1,
                                      frames: r.frames, head: r.head, count: r.count))
        XCTAssertEqual(track.localKey, 0)
        XCTAssertEqual(track.overallKey, 0)
        // 古い枠（番号が戻る）と同じ番号は無視。
        XCTAssertFalse(try track.apply(chordKey(24, (9, 1, 9), local: 3), activeGeneration: 1, frames: r.frames,
                                       head: r.head, count: r.count))
        XCTAssertFalse(try track.apply(chordKey(25, (9, 1, 9), local: 3), activeGeneration: 1, frames: r.frames,
                                       head: r.head, count: r.count))
        XCTAssertEqual(track.chords[13], nil)
        XCTAssertEqual(track.localKey, 0)
        // 世代が違う枠・世代が決まっていない帯は無視。
        XCTAssertFalse(try track.apply(chordKey(30, (9, 1, 9), generation: 2), activeGeneration: 1,
                                       frames: r.frames, head: r.head, count: r.count))
        XCTAssertFalse(try track.apply(chordKey(31, (9, 1, 9)), activeGeneration: nil, frames: r.frames,
                                       head: r.head, count: r.count))
        // 番号の折り返し（0xfffffffe の次が 3）は新しい。
        var wrap = ETNoteChordTrack(columns: 64)
        XCTAssertFalse(try wrap.apply(chordKey(0xFFFF_FFFE, (0, 0, 0)), activeGeneration: 1, frames: r.frames,
                                      head: r.head, count: r.count))
        XCTAssertTrue(try wrap.apply(chordKey(3, (0, 0, 0), local: 5), activeGeneration: 1, frames: r.frames,
                                     head: r.head, count: r.count))
        XCTAssertEqual(wrap.localKey, 5)
        // clear で全部戻る。
        track.clear()
        XCTAssertTrue(track.chords.allSatisfy { $0 == nil })
        XCTAssertNil(track.localKey)
        XCTAssertNil(track.overallKey)
        XCTAssertTrue(try track.apply(chordKey(25, (0, 0, 0)), activeGeneration: 1, frames: r.frames,
                                      head: r.head, count: r.count), "clear の後は同じ番号でも受ける")
        // 列を書き直すと和音は消える。
        track.clearColumn(14)
        XCTAssertNil(track.chords[14])
    }

    func testChordRunsSplitOnGapsAndNoChord() throws {
        var track = ETNoteChordTrack(columns: 64)
        let r = ring(columns: 64, written: 40)
        // 目的の列 t = 枠 - 11。t0-3 C、t4-5 和音なし、t6-8 C、t9-14 G7、t15 は届かない、t16-20 Am。
        func confirmed(_ t: Int) -> (UInt8, UInt8, UInt8)? {
            switch t {
            case 0...3, 6...8: return (0, 0, 0)
            case 4...5: return (255, 255, 255)
            case 9...14: return (7, 6, 7)
            case 16...20: return (9, 1, 9)
            default: return nil
            }
        }
        for t in 0...20 {
            guard let c = confirmed(t) else { continue }
            _ = try track.apply(chordKey(UInt32(t + 11), c), activeGeneration: 1, frames: r.frames, head: r.head,
                                count: r.count)
        }
        XCTAssertEqual(track.chords[4], "", "和音なしと確定")
        XCTAssertNil(track.chords[15], "届かない列はまだ分からない")
        let runs = track.runs(start: 0, shown: 40)
        XCTAssertEqual(runs, [
            ETNoteChordTrack.Run(start: 0, end: 4, name: "C", root: 0),
            ETNoteChordTrack.Run(start: 6, end: 9, name: "C", root: 0),
            ETNoteChordTrack.Run(start: 9, end: 15, name: "G7", root: 7),
            ETNoteChordTrack.Run(start: 16, end: 21, name: "Am", root: 9),
        ])
        // 左から数えた列で引く。
        XCTAssertEqual(track.chord(displayColumn: 2, start: 0, shown: 40), "C")
        XCTAssertEqual(track.chord(displayColumn: 4, start: 0, shown: 40), "")
        XCTAssertNil(track.chord(displayColumn: 15, start: 0, shown: 40))
        XCTAssertNil(track.chord(displayColumn: 40, start: 0, shown: 40), "出している列の外")
        // 輪の途中から数える（start が 60 で shown 8 なら、列 60..63, 0..3）。
        let tail = track.runs(start: 60, shown: 8)
        XCTAssertEqual(tail, [ETNoteChordTrack.Run(start: 4, end: 8, name: "C", root: 0)])
        XCTAssertTrue(track.runs(start: 0, shown: 0).isEmpty)
    }
}
