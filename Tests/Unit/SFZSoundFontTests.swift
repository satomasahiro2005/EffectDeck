//  SFZSoundFontTests.swift
//  SoundFont（SF2）を読み込む側の Foundation だけの部品（DSP/SFZStream/SFZSoundFont）。
//  Preset の選択欄（上流 sfz-instrument.js の validatePreparedSfzBank と _renderPresetSelection）、JS が返す標本の置き場所の
//  読みと ETSFZSampleSource への組み、取り込む拡張子。置き場所の値そのものは Tools/sfzjs/glue.test.mjs が上流の SF2 の読み手と
//  突き合わせている（ここは受け取った値を正しく使えること）。

import XCTest

final class SFZSoundFontTests: XCTestCase {

    // MARK: Preset の選択欄

    private func preset(_ bank: Int, _ program: Int, _ name: String) -> ETSFZPreset {
        ETSFZPreset(bank: bank, program: program, name: name)
    }

    func testMenuStartsWithDefaultThenBankAndProgram() {
        let items = ETSFZPresetMenu.items([preset(0, 0, "Piano"), preset(128, 0, "Standard Kit")])
        XCTAssertEqual(items.map(\.key), [-1, 0, 128 * 128])
        XCTAssertEqual(items.map(\.label), ["Default", "Bank 0 · 1. Piano", "Bank 128 · 1. Standard Kit"])
    }

    func testMenuLabelCountsProgramsFromOne() {
        XCTAssertEqual(ETSFZPresetMenu.label(of: preset(3, 127, "Last")), "Bank 3 · 128. Last")
        XCTAssertEqual(preset(3, 127, "Last").key, 3 * 128 + 127)
    }

    func testMenuDropsBanksAboveOneTwentyEightAndProgramsAboveOneTwentySeven() {
        let list = [preset(129, 0, "A"), preset(0, 128, "B"), preset(128, 127, "C"), preset(0, 0, "D")]
        XCTAssertEqual(ETSFZPresetMenu.eligible(list).map(\.name), ["C", "D"])
        XCTAssertEqual(ETSFZPresetMenu.items(list).map(\.key), [-1, 128 * 128 + 127, 0])
    }

    func testMenuKeepsTheFirstOfDuplicatePresets() {
        let items = ETSFZPresetMenu.items([preset(0, 5, "First"), preset(0, 5, "Second"), preset(1, 5, "Other")])
        XCTAssertEqual(items.map(\.label), ["Default", "Bank 0 · 6. First", "Bank 1 · 6. Other"])
    }

    func testMenuIsEmptyWhenNothingIsSelectable() {
        // 空なら欄ごと隠す（SFZ のバンク・Preset を持たない音源）。
        XCTAssertTrue(ETSFZPresetMenu.items([]).isEmpty)
        XCTAssertTrue(ETSFZPresetMenu.items([preset(200, 0, "Out of range")]).isEmpty)
    }

    func testSelectionFallsBackToDefaultWhenThePresetIsGone() {
        let list = [preset(0, 0, "A"), preset(1, 2, "B")]
        XCTAssertEqual(ETSFZPresetMenu.validatedSelection(current: Float(1 * 128 + 2), presets: list), Float(1 * 128 + 2))
        XCTAssertEqual(ETSFZPresetMenu.validatedSelection(current: 0, presets: list), 0)
        XCTAssertEqual(ETSFZPresetMenu.validatedSelection(current: 5, presets: list), -1)
        XCTAssertEqual(ETSFZPresetMenu.validatedSelection(current: -1, presets: list), -1)
        XCTAssertEqual(ETSFZPresetMenu.validatedSelection(current: 0.5, presets: list), -1)
        XCTAssertEqual(ETSFZPresetMenu.validatedSelection(current: .nan, presets: list), -1)
        // SFZ のバンク（Preset なし）では、残っていた値も -1 に戻る。
        XCTAssertEqual(ETSFZPresetMenu.validatedSelection(current: 3, presets: []), -1)
    }

    func testSelectionIgnoresPresetsAboveTheRange() {
        // 範囲外の Preset を選んだままにしない（欄にも出ない）。
        XCTAssertEqual(ETSFZPresetMenu.validatedSelection(current: Float(129 * 128), presets: [preset(129, 0, "X")]), -1)
    }

    // MARK: JSON

    private func json(_ text: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    private let sample = #"{"base":106,"dataOffset":70,"lowByteOffset":298,"frames":64,"sampleRate":48000,"compressed":false}"#

    func testParseReadsPresetsAndSamples() throws {
        let value = try json(#"""
        {"format":"sf2","presets":[{"bank":0,"program":1,"name":"Piano"},{"bank":128,"program":0,"name":"Kit"}],
         "samples":[\#(sample),{"base":106,"dataOffset":9000000000,"lowByteOffset":null,"frames":10,"sampleRate":22050}]}
        """#)
        let info = try XCTUnwrap(ETSFZSoundFontInfo.parse(value))
        XCTAssertEqual(info.format, "sf2")
        XCTAssertEqual(info.presets, [ETSFZPreset(bank: 0, program: 1, name: "Piano"), ETSFZPreset(bank: 128, program: 0, name: "Kit")])
        XCTAssertEqual(info.samples.count, 2)
        XCTAssertEqual(info.samples[0], ETSFZSoundFontSample(baseOffset: 106, dataOffset: 70, lowByteOffset: 298, frames: 64,
                                                             sampleRate: 48000, compressed: false))
        // 4 GiB を越える位置も UInt64 のまま。sm24 が無ければ nil。
        XCTAssertEqual(info.samples[1].dataOffset, 9_000_000_000)
        XCTAssertNil(info.samples[1].lowByteOffset)
    }

    func testParseRejectsMalformedValues() throws {
        XCTAssertNil(ETSFZSoundFontInfo.parse(nil))
        XCTAssertNil(ETSFZSoundFontInfo.parse(NSNull()))
        XCTAssertNil(ETSFZSoundFontInfo.parse(try json(#"{"format":"sf2","presets":[],"samples":[{"base":-1,"dataOffset":0,"frames":1,"sampleRate":1}]}"#)))
        XCTAssertNil(ETSFZSoundFontInfo.parse(try json(#"{"format":"sf2","presets":[],"samples":[{"base":0,"dataOffset":0.5,"frames":1,"sampleRate":1}]}"#)))
        XCTAssertNil(ETSFZSoundFontInfo.parse(try json(#"{"format":"sf2","presets":[],"samples":[{"base":0,"dataOffset":0,"frames":1,"sampleRate":900000}]}"#)))
        XCTAssertNil(ETSFZSoundFontInfo.parse(try json(#"{"format":"sf2","presets":[{"bank":-1,"program":0,"name":"x"}],"samples":[]}"#)))
        XCTAssertNil(ETSFZSoundFontInfo.parse(try json(#"{"format":"sf2","presets":[]}"#)))
    }

    // MARK: 標本の表

    private func info(_ samples: [ETSFZSoundFontSample]) -> ETSFZSoundFontInfo {
        ETSFZSoundFontInfo(format: "sf2", presets: [], samples: samples)
    }

    func testSourcesMapEachSampleToAnSF2ReadWithTheBankOffset() throws {
        let bank = URL(fileURLWithPath: "/tmp/bank.sfzbank")
        let sources = try info([
            ETSFZSoundFontSample(baseOffset: 106, dataOffset: 70, lowByteOffset: 298, frames: 64, sampleRate: 48000),
            ETSFZSoundFontSample(baseOffset: 106, dataOffset: 250, lowByteOffset: nil, frames: 100, sampleRate: 22050),
        ]).sources(bank: bank)
        XCTAssertEqual(sources.count, 2)
        XCTAssertEqual(sources[0], ETSFZSampleSource(url: bank, baseOffset: 106, format: .sf2PCM(dataOffset: 70, lowByteOffset: 298),
                                                     frames: 64, channels: 1, sampleRate: 48000))
        XCTAssertEqual(sources[1].format, .sf2PCM(dataOffset: 250, lowByteOffset: nil))
        XCTAssertEqual(sources[1].channels, 1)
    }

    private func compressed(frames: UInt64 = 8, dataOffset: UInt64 = 70, dataBytes: UInt64 = 400, firstFrame: UInt64 = 0,
                            sourceFrames: UInt64 = 8) -> ETSFZSoundFontSample {
        ETSFZSoundFontSample(baseOffset: 100, dataOffset: dataOffset, lowByteOffset: nil, frames: frames, sampleRate: 44100,
                             compressed: true, dataBytes: dataBytes, firstFrame: firstFrame, sourceFrames: sourceFrames)
    }

    func testSourcesMapACompressedSampleToAVorbisRead() throws {
        let bank = URL(fileURLWithPath: "/tmp/bank.sfzbank")
        let sources = try info([compressed(frames: 6, firstFrame: 2, sourceFrames: 10)]).sources(bank: bank, bankBytes: 570)
        XCTAssertEqual(sources, [ETSFZSampleSource(
            url: bank, baseOffset: 100,
            format: .vorbis(ETSFZVorbisLayout(dataOffset: 70, dataBytes: 400, firstFrame: 2, sourceFrames: 10)),
            frames: 6, channels: 1, sampleRate: 44100)])
    }

    func testCompressedSampleRangeIsCheckedAgainstTheBankAndTheLimits() {
        let bank = URL(fileURLWithPath: "/x")
        // Ogg は 170..<570。
        XCTAssertNoThrow(try info([compressed()]).sources(bank: bank, bankBytes: 570))
        XCTAssertThrowsError(try info([compressed()]).sources(bank: bank, bankBytes: 569)) { error in
            XCTAssertEqual((error as? ETSFZError)?.message, ETSFZSoundFontInfo.invalidMessage)
        }
        let bad: [ETSFZSoundFontSample] = [
            compressed(frames: 9, sourceFrames: 8),                         // 使う範囲が復号後の外へ出る
            compressed(frames: 4, firstFrame: 5, sourceFrames: 8),
            compressed(frames: 1, firstFrame: UInt64.max, sourceFrames: 8), // 足すとあふれる
            compressed(sourceFrames: 0),
            compressed(frames: 8, sourceFrames: ETSFZVorbisLayout.maxFrames + 1),
            compressed(dataBytes: ETSFZVorbisLayout.minBytes - 1),
            compressed(dataBytes: ETSFZVorbisLayout.maxBytes + 1),
        ]
        for sample in bad {
            XCTAssertThrowsError(try info([sample]).sources(bank: bank), "\(sample)") { error in
                XCTAssertEqual((error as? ETSFZError)?.message, ETSFZSoundFontInfo.invalidMessage)
            }
        }
        let overflow = compressed(dataOffset: UInt64.max - 8, dataBytes: 400)
        XCTAssertThrowsError(try info([overflow]).sources(bank: bank, bankBytes: UInt64.max))
        // 上限ちょうどは通る。
        XCTAssertNoThrow(try info([compressed(frames: ETSFZVorbisLayout.maxFrames, dataBytes: ETSFZVorbisLayout.maxBytes,
                                              sourceFrames: ETSFZVorbisLayout.maxFrames)]).sources(bank: bank))
    }

    func testParseReadsTheCompressedFieldsAndRequiresAllThree() throws {
        let value = try json(#"""
        {"format":"sf3","presets":[],"samples":[{"base":106,"dataOffset":70,"lowByteOffset":null,"frames":6,"sampleRate":44100,
         "compressed":true,"dataBytes":400,"firstFrame":2,"sourceFrames":10}]}
        """#)
        let parsed = try XCTUnwrap(ETSFZSoundFontInfo.parse(value))
        XCTAssertEqual(parsed.format, "sf3")
        XCTAssertEqual(parsed.samples[0], ETSFZSoundFontSample(baseOffset: 106, dataOffset: 70, lowByteOffset: nil, frames: 6,
                                                               sampleRate: 44100, compressed: true, dataBytes: 400, firstFrame: 2,
                                                               sourceFrames: 10))
        // 圧縮標本で 3 つのどれかが欠ける・負・小数なら、SoundFont として扱わない。
        for missing in ["dataBytes", "firstFrame", "sourceFrames"] {
            var fields: [String: Any] = ["base": 0, "dataOffset": 0, "frames": 1, "sampleRate": 44100, "compressed": true,
                                         "dataBytes": 400, "firstFrame": 0, "sourceFrames": 1]
            fields[missing] = nil
            let data = try JSONSerialization.data(withJSONObject: ["format": "sf3", "presets": [], "samples": [fields]] as [String: Any])
            XCTAssertNil(ETSFZSoundFontInfo.parse(try JSONSerialization.jsonObject(with: data)), missing)
        }
        XCTAssertNil(ETSFZSoundFontInfo.parse(try json(#"""
        {"format":"sf3","presets":[],"samples":[{"base":0,"dataOffset":0,"frames":1,"sampleRate":44100,"compressed":true,
         "dataBytes":400,"firstFrame":-1,"sourceFrames":1}]}
        """#)))
        // 圧縮でない標本には要らない（あっても読まない）。
        XCTAssertNotNil(ETSFZSoundFontInfo.parse(try json(#"{"format":"sf2","presets":[],"samples":[\#(sample)]}"#)))
    }

    func testSourcesRefuseAnEmptySampleAndABadRate() {
        let bank = URL(fileURLWithPath: "/x")
        XCTAssertThrowsError(try info([ETSFZSoundFontSample(baseOffset: 0, dataOffset: 0, lowByteOffset: nil, frames: 0, sampleRate: 44100)])
            .sources(bank: bank))
        XCTAssertThrowsError(try info([ETSFZSoundFontSample(baseOffset: 0, dataOffset: 0, lowByteOffset: nil, frames: 8, sampleRate: 0)])
            .sources(bank: bank))
    }

    func testSourcesCheckTheRangeAgainstTheBankSize() throws {
        let bank = URL(fileURLWithPath: "/x")
        let sample = ETSFZSoundFontSample(baseOffset: 100, dataOffset: 50, lowByteOffset: 400, frames: 10, sampleRate: 44100)
        // smpl は 150..<170、sm24 は 500..<510。
        XCTAssertNoThrow(try info([sample]).sources(bank: bank, bankBytes: 510))
        XCTAssertThrowsError(try info([sample]).sources(bank: bank, bankBytes: 509))
        XCTAssertThrowsError(try info([sample]).sources(bank: bank, bankBytes: 169)) { error in
            XCTAssertEqual((error as? ETSFZError)?.message, ETSFZSoundFontInfo.invalidMessage)
        }
        let huge = ETSFZSoundFontSample(baseOffset: UInt64.max - 4, dataOffset: 10, lowByteOffset: nil, frames: 1, sampleRate: 44100)
        XCTAssertThrowsError(try info([huge]).sources(bank: bank, bankBytes: UInt64.max))
    }

    /// 組んだ表でページを読むと、SF2 の (high × 256 + low) / 8388608 になる（入れ物の頭の分だけずれた位置から）。
    func testRenderingThroughTheMappedSourcesReadsTheSF2Pool() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("SFZSoundFontTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let frames = 5
        let high: [Int16] = [0, 1000, -1000, 32767, -32768]
        let low: [UInt8] = [0, 255, 7, 128, 1]
        // 入れ物の頭（base 分）+ SF2 の頭（dataOffset 分）+ smpl + 隙間 + sm24。
        let base = 12, dataOffset = 20, lowOffset = 60
        var bytes = [UInt8](repeating: 0xEE, count: base + lowOffset + frames + 4)
        for (index, value) in high.enumerated() {
            let raw = UInt16(bitPattern: value)
            bytes[base + dataOffset + index * 2] = UInt8(raw & 0xFF)
            bytes[base + dataOffset + index * 2 + 1] = UInt8(raw >> 8)
        }
        for (index, value) in low.enumerated() { bytes[base + lowOffset + index] = value }
        let url = scratch.appendingPathComponent("bank.sfzbank")
        try Data(bytes).write(to: url)

        let sources = try info([
            ETSFZSoundFontSample(baseOffset: UInt64(base), dataOffset: UInt64(dataOffset), lowByteOffset: UInt64(lowOffset),
                                 frames: UInt64(frames), sampleRate: 44100),
            ETSFZSoundFontSample(baseOffset: UInt64(base), dataOffset: UInt64(dataOffset), lowByteOffset: nil,
                                 frames: UInt64(frames), sampleRate: 44100),
        ]).sources(bank: url, bankBytes: UInt64(bytes.count))
        let renderer = ETSFZPageRenderer()
        defer { renderer.close() }
        let out = UnsafeMutablePointer<Float>.allocate(capacity: ETSFZPageDecode.pageFrames * 2)
        defer { out.deallocate() }

        let withLow = try renderer.render(sources[0], page: 0, into: out, capacity: ETSFZPageDecode.pageFrames * 2)
        XCTAssertEqual(withLow.frames, frames)
        XCTAssertEqual(withLow.channels, 1)
        for index in 0..<frames {
            let expected = Float(Double(Int(high[index]) * 256 + Int(low[index])) / 8388608.0)
            XCTAssertEqual(out[index].bitPattern, expected.bitPattern, "24 bit の \(index) 番目")
        }
        let highOnly = try renderer.render(sources[1], page: 0, into: out, capacity: ETSFZPageDecode.pageFrames * 2)
        XCTAssertEqual(highOnly.frames, frames)
        for index in 0..<frames {
            XCTAssertEqual(out[index].bitPattern, Float(Double(high[index]) / 32768.0).bitPattern, "16 bit の \(index) 番目")
        }
        // 範囲の外のページは range。
        XCTAssertThrowsError(try renderer.render(sources[0], page: 1, into: out, capacity: ETSFZPageDecode.pageFrames * 2))
    }

    // MARK: 拡張子

    func testInstrumentExtensions() {
        XCTAssertTrue(ETSFZSoundFormats.isInstrument(path: "Banks/Piano.SFZ"))
        XCTAssertTrue(ETSFZSoundFormats.isInstrument(path: "GM.sf2"))
        XCTAssertTrue(ETSFZSoundFormats.isInstrument(path: "GM.SF2"))
        XCTAssertFalse(ETSFZSoundFormats.isInstrument(path: "sample.wav"))
        XCTAssertTrue(ETSFZSoundFormats.isSoundFont(path: "a.sf3"))
        // SF3（Vorbis）も取り込む。
        XCTAssertTrue(ETSFZSoundFormats.isInstrument(path: "a.sf3"))
        XCTAssertTrue(ETSFZSoundFormats.isInstrument(path: "A.SF3"))
        XCTAssertEqual(ETSFZSoundFormats.soundFontExtensions, ["sf2", "sf3"])
    }

    /// SF3 のページは Foundation の読み手では作らない（ETVorbis.c の側）。unsupported を返して振り分ける。
    func testRendererLeavesVorbisSamplesToTheVorbisReader() {
        let layout = ETSFZVorbisLayout(dataOffset: 0, dataBytes: 400, firstFrame: 0, sourceFrames: 8)
        let source = ETSFZSampleSource(url: URL(fileURLWithPath: "/x"), baseOffset: 0, format: .vorbis(layout), frames: 8,
                                       channels: 1, sampleRate: 44100)
        let renderer = ETSFZPageRenderer()
        let out = UnsafeMutablePointer<Float>.allocate(capacity: ETSFZPageDecode.pageFrames * 2)
        defer { out.deallocate() }
        XCTAssertThrowsError(try renderer.render(source, page: 0, into: out, capacity: ETSFZPageDecode.pageFrames * 2)) { error in
            XCTAssertEqual(error as? ETSFZPageError, .unsupported)
        }
    }

    func testReadAllCollectsChunksAndChecksTheLimit() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("SFZSoundFontTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        // 1 回の読みの上限（1 MiB）をまたぐ長さ。
        let length = ETSFZPageDecode.maxReadBytes * 2 + 123
        let bytes = (0..<length).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ ($0 >> 8)) }
        let url = scratch.appendingPathComponent("file.bin")
        try Data(bytes).write(to: url)
        let reader = ETSFZFileReader()
        defer { reader.closeAll() }
        let all = try reader.readAll(url: url, offset: 5, length: UInt64(length - 10), limit: 64 * 1024 * 1024)
        XCTAssertEqual([UInt8](all), Array(bytes[5..<(length - 5)]))
        XCTAssertEqual(try reader.readAll(url: url, offset: 0, length: 0, limit: 10).count, 0)
        // 上限を超える・ファイルの外へ出る。
        XCTAssertThrowsError(try reader.readAll(url: url, offset: 0, length: 11, limit: 10)) { XCTAssertEqual($0 as? ETSFZPageError, .range) }
        XCTAssertThrowsError(try reader.readAll(url: url, offset: UInt64(length - 4), length: 8, limit: 100)) {
            XCTAssertEqual($0 as? ETSFZPageError, .changed)
        }
    }
}
