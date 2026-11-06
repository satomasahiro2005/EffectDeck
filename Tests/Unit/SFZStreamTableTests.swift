//  SFZStreamTableTests.swift
//  流し込みの SFZ（load_* を持つ SFZ・予算を超える SFZ）を読み込む側の Foundation だけの部品（DSP/SFZStream/SFZStreamTable）。
//  payload の標本の表と resident のページ、標本の読み口（WAV・AIFF は入れ物の中のまま、FLAC などと JS が作った標本は単体のファイルへ）。
//  見本は Tools/sfzjs/stream_table_golden.mjs が、置いてある束ねと glue（上流の prepareStreamedSfzBank）で作った
//  入れ物・payload・標本の置き場所（Tests/Fixtures/SFZ/stream-table-golden.json）。
//  実機もエンジンも要らない。engine 側の受け渡しは Tests/Native/sample_stream.c が見る。

import XCTest

final class SFZStreamTableTests: XCTestCase {

    // MARK: 見本

    private struct Case {
        var name: String
        var id: String
        var bank: Data
        var payload: Data
        var raw: [[String: Any]]
        var inline: [Int: Data]

        var samples: [ETSFZStreamSample] {
            ETSFZStreamTable.parse(raw, inline: { inline[$0] }) ?? []
        }
    }

    private static var cached: [Case]?

    private func cases() throws -> [Case] {
        if let cached = Self.cached { return cached }
        let url = try XCTUnwrap(TestResource.url("stream-table-golden", "json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let list = try XCTUnwrap(root["cases"] as? [[String: Any]])
        let result = try list.map { item -> Case in
            var inline: [Int: Data] = [:]
            for (key, value) in item["inline"] as? [String: String] ?? [:] {
                inline[try XCTUnwrap(Int(key))] = try XCTUnwrap(Data(base64Encoded: value))
            }
            return Case(name: try XCTUnwrap(item["name"] as? String), id: try XCTUnwrap(item["id"] as? String),
                        bank: try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(item["bank"] as? String))),
                        payload: try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(item["control"] as? String))),
                        raw: try XCTUnwrap(item["streamSamples"] as? [[String: Any]]), inline: inline)
        }
        Self.cached = result
        return result
    }

    private func named(_ name: String) throws -> Case {
        try XCTUnwrap(try cases().first { $0.name == name })
    }

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("SFZStreamTableTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func staging() -> ETSFZStreamStaging {
        ETSFZStreamStaging(root: scratch.appendingPathComponent("staging", isDirectory: true))
    }

    private func writeBank(_ item: Case, _ bytes: Data? = nil) throws -> URL {
        let url = scratch.appendingPathComponent("\(item.id).sfzbank")
        try (bytes ?? item.bank).write(to: url)
        return url
    }

    private func word(_ payload: Data, _ index: Int) -> Int {
        let at = payload.startIndex + 32 + index * 4
        return Int(UInt32(payload[at]) | UInt32(payload[at + 1]) << 8 | UInt32(payload[at + 2]) << 16 | UInt32(payload[at + 3]) << 24)
    }

    private func withWord(_ payload: Data, _ index: Int, _ value: UInt32) -> Data {
        var copy = payload
        let at = copy.startIndex + 32 + index * 4
        for k in 0..<4 { copy[at + k] = UInt8(truncatingIfNeeded: value >> (8 * UInt32(k))) }
        return copy
    }

    private func assertPrepareError(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual((error as? ETSFZError)?.code, .prepare, file: file, line: line)
        }
    }

    // MARK: payload の表

    func testRowsAreTheSamplesInPayloadOrder() throws {
        for item in try cases() {
            let rows = try ETSFZStreamTable.rows(payload: item.payload)
            let samples = item.samples
            XCTAssertEqual(rows.count, samples.count, item.name)
            for (index, row) in rows.enumerated() {
                XCTAssertEqual(row.frames, samples[index].frames, "\(item.name) \(index)")
                XCTAssertEqual(row.channels, samples[index].channels)
                XCTAssertEqual(row.sampleRate, samples[index].sampleRate)
                XCTAssertEqual(row.mode, samples[index].mode)
            }
        }
        // load_mode=1 の標本は 16 bit の保存形式（mode 1）で、別の番号
        XCTAssertEqual(try ETSFZStreamTable.rows(payload: named("streamed-load-opcodes").payload).map(\.mode), [1, 0])
    }

    func testResidentPagesFollowLoadStartAndEffectImpulses() throws {
        // load_start=10 load_end=300（600 フレームの標本 0）は頭の 1 ページ
        let opcodes = try ETSFZStreamTable.residentPages(payload: named("streamed-load-opcodes").payload)
        XCTAssertEqual(opcodes.map { [$0.sample, Int($0.page)] }, [[0, 0]])
        // 効果の IR（ir.wav = 標本 1、64 フレーム）は全体
        let effects = try ETSFZStreamTable.residentPages(payload: named("streamed-effects").payload)
        XCTAssertEqual(effects.map { [$0.sample, Int($0.page)] }, [[1, 0]])
        // 発生源（*sine。標本 0、4095 フレーム）も全体が resident（周期は常に要る）。load_mode だけの標本 1 は持たない
        let generators = try ETSFZStreamTable.residentPages(payload: named("streamed-generators").payload)
        XCTAssertEqual(generators.map { [$0.sample, Int($0.page)] }, [[0, 0]])
    }

    func testResidentPagesSplitLongRangesIntoPages() throws {
        // 標本 0 の resident の範囲を [0, 600) から、frames を超えない大きな範囲に書き換えて、ページが 4096 ごとに数えられること
        let item = try named("streamed-load-opcodes")
        var payload = item.payload
        let table = word(payload, 12), residentAt = word(payload, 17)
        // 標本 0 の frames を 10000 にして（表と JS の値の食い違いは sources が見る。ここは読みだけ）、範囲を [4096, 9001)
        payload = withWord(payload, table, 10000)
        payload = withWord(payload, residentAt, 4096)
        payload = withWord(payload, residentAt + 2, 9001)
        let pages = try ETSFZStreamTable.residentPages(payload: payload)
        XCTAssertEqual(pages.map { [$0.sample, Int($0.page)] }, [[0, 1], [0, 2]])
    }

    func testBrokenPayloadsAreRejected() throws {
        let item = try named("streamed-load-opcodes")
        assertPrepareError { _ = try ETSFZStreamTable.rows(payload: Data(item.payload.prefix(40))) }
        // 外枠の印が違う
        var wrongMagic = item.payload
        wrongMagic[wrongMagic.startIndex] ^= 0xff
        assertPrepareError { _ = try ETSFZStreamTable.rows(payload: wrongMagic) }
        // 表の版が常駐（7）・SoundFont（9）は、流し込みの SFZ の表として読まない
        for version: UInt32 in [7, 9] {
            assertPrepareError { _ = try ETSFZStreamTable.rows(payload: withWord(item.payload, 1, version)) }
        }
        // 標本の数が payload からはみ出す
        assertPrepareError { _ = try ETSFZStreamTable.rows(payload: withWord(item.payload, 13, 100000)) }
        assertPrepareError { _ = try ETSFZStreamTable.rows(payload: withWord(item.payload, 13, 0)) }
        // resident の範囲が frames を超える
        let residentAt = word(item.payload, 17)
        assertPrepareError { _ = try ETSFZStreamTable.residentPages(payload: withWord(item.payload, residentAt + 2, 100000)) }
        // 範囲が空（first == end）
        assertPrepareError { _ = try ETSFZStreamTable.residentPages(payload: withWord(item.payload, residentAt + 2, 0)) }
        // 範囲の数が表の行の数と合わない
        assertPrepareError { _ = try ETSFZStreamTable.residentPages(payload: withWord(item.payload, 18, 3)) }
    }

    // MARK: 標本の置き場所の JSON

    func testParseReadsTheGlueShape() throws {
        let item = try named("streamed-generators")
        let samples = item.samples
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples[0].index, 0)
        XCTAssertEqual(samples[0].mode, 1)
        XCTAssertEqual(samples[0].frames, 4095)
        XCTAssertNil(samples[0].offset)
        XCTAssertEqual(samples[0].inline?.count, Int(samples[0].size))
        XCTAssertNotNil(samples[1].offset)
        XCTAssertNil(samples[1].inline)
    }

    func testParseRejectsMalformedLists() throws {
        let item = try named("streamed-load-opcodes")
        XCTAssertNil(ETSFZStreamTable.parse(nil, inline: { _ in nil }))
        XCTAssertNil(ETSFZStreamTable.parse([[String: Any]](), inline: { _ in nil }))
        // 番号が連番でない
        var skipped = item.raw
        skipped[1]["index"] = 5
        XCTAssertNil(ETSFZStreamTable.parse(skipped, inline: { _ in nil }))
        // 位置が無い
        var noOffset = item.raw
        noOffset[0]["offset"] = NSNull()
        XCTAssertNil(ETSFZStreamTable.parse(noOffset, inline: { _ in nil }))
        // inline なのにバイト列が無い・大きさが違う
        var inline = item.raw
        inline[0]["inline"] = true
        XCTAssertNil(ETSFZStreamTable.parse(inline, inline: { _ in nil }))
        XCTAssertNil(ETSFZStreamTable.parse(inline, inline: { _ in Data([1, 2, 3]) }))
        // 範囲外の値
        var bad = item.raw
        bad[0]["channels"] = 3
        XCTAssertNil(ETSFZStreamTable.parse(bad, inline: { _ in nil }))
        bad = item.raw
        bad[0]["mode"] = 2
        XCTAssertNil(ETSFZStreamTable.parse(bad, inline: { _ in nil }))
        bad = item.raw
        bad[0]["sampleRate"] = 0
        XCTAssertNil(ETSFZStreamTable.parse(bad, inline: { _ in nil }))
    }

    func testRequireConsistentTiesTheTableVersionToTheSources() throws {
        try ETSFZStreamTable.requireConsistent(tableVersion: 10, hasSoundFont: false, hasStreamSources: true)
        try ETSFZStreamTable.requireConsistent(tableVersion: 8, hasSoundFont: false, hasStreamSources: true)
        try ETSFZStreamTable.requireConsistent(tableVersion: 9, hasSoundFont: true, hasStreamSources: false)
        try ETSFZStreamTable.requireConsistent(tableVersion: 7, hasSoundFont: false, hasStreamSources: false)
        try ETSFZStreamTable.requireConsistent(tableVersion: 6, hasSoundFont: false, hasStreamSources: false)
        assertPrepareError { try ETSFZStreamTable.requireConsistent(tableVersion: 10, hasSoundFont: false, hasStreamSources: false) }
        assertPrepareError { try ETSFZStreamTable.requireConsistent(tableVersion: 10, hasSoundFont: true, hasStreamSources: true) }
        assertPrepareError { try ETSFZStreamTable.requireConsistent(tableVersion: 9, hasSoundFont: false, hasStreamSources: true) }
        assertPrepareError { try ETSFZStreamTable.requireConsistent(tableVersion: 7, hasSoundFont: false, hasStreamSources: true) }
        assertPrepareError { try ETSFZStreamTable.requireConsistent(tableVersion: 7, hasSoundFont: true, hasStreamSources: false) }
    }

    // MARK: 標本の読み口

    private func sources(_ item: Case, bank: URL, bankBytes: UInt64? = nil, samples: [ETSFZStreamSample]? = nil,
                         payload: Data? = nil) throws -> [ETSFZSampleSource] {
        try ETSFZStreamTable.sources(samples: samples ?? item.samples, payload: payload ?? item.payload, bank: bank,
                                     bankBytes: bankBytes ?? UInt64(item.bank.count), bankID: item.id, staging: staging())
    }

    private func firstPage(_ source: ETSFZSampleSource) throws -> [Float] {
        let renderer = ETSFZPageRenderer()
        defer { renderer.close() }
        var out = [Float](repeating: 0, count: ETSFZPageDecode.pageFrames * 2)
        let result = try out.withUnsafeMutableBufferPointer {
            try renderer.render(source, page: 0, into: $0.baseAddress!, capacity: $0.count)
        }
        return Array(out.prefix(result.frames * result.channels))
    }

    func testWavInsideTheContainerIsReadInPlace() throws {
        let item = try named("streamed-load-opcodes")
        let bank = try writeBank(item)
        let made = try sources(item, bank: bank)
        XCTAssertEqual(made.count, 2)
        for (index, source) in made.enumerated() {
            let sample = item.samples[index]
            XCTAssertEqual(source.url, bank, "入れ物の中のまま読む（写し出さない）")
            XCTAssertEqual(source.baseOffset, sample.offset)
            XCTAssertEqual(source.frames, sample.frames)
            XCTAssertEqual(source.channels, sample.channels)
            XCTAssertEqual(source.sampleRate, sample.sampleRate)
            guard case .pcm = source.format else { return XCTFail("標本 \(index) は pcm") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging().root.path), "写し出しは起きない")
        // 頭のページは、入れ物の中の WAV の 16 bit を 2^-15 倍した値
        let sample = item.samples[0]
        let at = Int(sample.offset!) + 44
        let expected = (0..<Int(min(sample.frames, 4096))).map { frame -> Float in
            let raw = UInt16(item.bank[at + frame * 2]) | UInt16(item.bank[at + frame * 2 + 1]) << 8
            return Float(Double(Int16(bitPattern: raw)) / 32768.0)
        }
        let page = try firstPage(made[0])
        XCTAssertEqual(page.map(\.bitPattern), expected.map(\.bitPattern))
    }

    func testGeneratedSampleIsStagedAsAStandaloneFile() throws {
        let item = try named("streamed-generators")
        let bank = try writeBank(item)
        let made = try sources(item, bank: bank)
        let generated = made[0]
        let inline = try XCTUnwrap(item.samples[0].inline)
        XCTAssertNotEqual(generated.url, bank)
        XCTAssertTrue(generated.url.path.hasPrefix(staging().root.path))
        XCTAssertEqual(generated.url.deletingLastPathComponent().lastPathComponent, item.id)
        XCTAssertEqual(generated.url.pathExtension, "wav")
        XCTAssertEqual(generated.baseOffset, 0)
        XCTAssertEqual(try Data(contentsOf: generated.url), inline)
        XCTAssertEqual(generated.frames, 4095)
        guard case .pcm(let layout) = generated.format else { return XCTFail("float の WAV は pcm") }
        XCTAssertTrue(layout.float)
        XCTAssertEqual(layout.bitsPerSample, 32)
        // *sine の頭は 0。ページは 4095 フレームの全部
        let page = try firstPage(generated)
        XCTAssertEqual(page.count, 4095)
        XCTAssertEqual(page[0], 0, accuracy: 1e-6)
        XCTAssertTrue(page.contains { $0 > 0.9 })
        // 入れ物の中の標本（c.wav = 標本 1）は入れ物のまま
        XCTAssertEqual(made[1].url, bank)
    }

    func testFlacLikeSampleIsExtractedFromTheContainer() throws {
        // 標本 1 の WAV のバイトを fLaC で始まるものに差し替える（中身は読まれない。AVAudioFile に開かせる単体のファイルになること）
        let item = try named("streamed-load-opcodes")
        let sample = item.samples[1]
        var bytes = item.bank
        let offset = Int(sample.offset!)
        let replaced = Data("fLaC".utf8) + Data((0..<(Int(sample.size) - 4)).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        bytes.replaceSubrange(offset..<(offset + Int(sample.size)), with: replaced)
        let bank = try writeBank(item, bytes)
        let made = try sources(item, bank: bank, bankBytes: UInt64(bytes.count))
        let flac = made[1]
        guard case .audioFile = flac.format else { return XCTFail("fLaC は audioFile") }
        XCTAssertEqual(flac.baseOffset, 0)
        XCTAssertEqual(flac.url.pathExtension, "flac")
        XCTAssertEqual(flac.url.deletingLastPathComponent().lastPathComponent, item.id)
        XCTAssertEqual(try Data(contentsOf: flac.url), replaced, "入れ物の範囲がそのまま単体のファイルになる")
        XCTAssertEqual(flac.frames, sample.frames)
        XCTAssertEqual(flac.channels, sample.channels)
        // 標本 0 は WAV のまま入れ物の中
        XCTAssertEqual(made[0].url, bank)
        // 2 度目は写し直さない（同じ大きさのファイルがあれば使い回す）
        let stamp = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: flac.url.path)[.modificationDate] as? Date)
        Thread.sleep(forTimeInterval: 0.05)
        let again = try sources(item, bank: bank, bankBytes: UInt64(bytes.count))
        XCTAssertEqual(again[1].url, flac.url)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: flac.url.path)[.modificationDate] as? Date, stamp)
        // バンクを消すと写し出しも消える
        staging().remove(bank: item.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: flac.url.path))
    }

    func testMismatchedTablesAreRejected() throws {
        let item = try named("streamed-load-opcodes")
        let bank = try writeBank(item)
        // 標本の数が payload の表と違う
        assertPrepareError { _ = try self.sources(item, bank: bank, samples: Array(item.samples.dropLast())) }
        // frames・channels・rate・mode が JS と payload で違う
        var frames = item.samples
        frames[0].frames += 1
        assertPrepareError { _ = try self.sources(item, bank: bank, samples: frames) }
        var channels = item.samples
        channels[0].channels = 2
        assertPrepareError { _ = try self.sources(item, bank: bank, samples: channels) }
        var rate = item.samples
        rate[0].sampleRate = 44100
        assertPrepareError { _ = try self.sources(item, bank: bank, samples: rate) }
        var mode = item.samples
        mode[0].mode = 0
        assertPrepareError { _ = try self.sources(item, bank: bank, samples: mode) }
        // WAV の頭が見つけた長さと、JS が見た長さが違う（payload も合わせて書き換えた場合でも、ファイルが正）
        var lie = item.samples
        lie[0].frames = 601
        let table = word(item.payload, 12)
        assertPrepareError { _ = try self.sources(item, bank: bank, samples: lie, payload: self.withWord(item.payload, table, 601)) }
        // 入れ物の外へ出る位置
        var outside = item.samples
        outside[1].offset = UInt64(item.bank.count) - 10
        assertPrepareError { _ = try self.sources(item, bank: bank, samples: outside) }
        var overflow = item.samples
        overflow[1].offset = UInt64.max - 5
        assertPrepareError { _ = try self.sources(item, bank: bank, samples: overflow) }
        // 入れ物が短くなっている（置き場の入れ物が JS の見たものと違う）
        assertPrepareError { _ = try self.sources(item, bank: bank, bankBytes: UInt64(item.bank.count) - 100) }
        // 入れ物のファイルが消えている
        try FileManager.default.removeItem(at: bank)
        assertPrepareError { _ = try self.sources(item, bank: bank) }
    }

    func testStagingRejectsNamesThatCouldEscapeTheFolder() throws {
        let store = staging()
        assertPrepareError { _ = try store.stage(Data([1]), bank: "../etc", index: 0, ext: "wav") }
        assertPrepareError { _ = try store.stage(Data([1]), bank: "a0a1a2a3a4a5a6a7a8a9aaab", index: 0, ext: "../x") }
        assertPrepareError { _ = try store.stage(Data([1]), bank: "a0a1a2a3a4a5a6a7a8a9aaab", index: -1, ext: "wav") }
        let url = try store.stage(Data([1, 2]), bank: "a0a1a2a3a4a5a6a7a8a9aaab", index: 3, ext: "wav")
        XCTAssertEqual(url.lastPathComponent, "3.wav")
        XCTAssertEqual(try Data(contentsOf: url), Data([1, 2]))
        store.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.path))
    }
}
