//  SFZVorbisReaderTests.swift
//  SF3 の標本のページ（DSP/SFZStream/ETSFZVorbisReader）。ETVorbis.c（stb_vorbis）の復号を、標本の表（ETSFZSampleSource の
//  .vorbis）から 4096 フレームのページで読む道を通して、ffmpeg の復号（Tests/Fixtures/SFZ/vorbis の .s16）と 1.5 LSB 以内で
//  合うことを見る。入れ物のファイルの中の位置（baseOffset + dataOffset）・使う範囲（firstFrame）・覚える量の上限と
//  復号器の数・壊れた入力を断ることも。
//  C の橋（ETVorbis.h）が要るので Apple のプラットフォームだけ（Linux ではこのファイルは空）。
//  復号そのものの試験は Tests/Native/vorbis.c（ASan/UBSan、壊れた入力を数万通り）。

#if canImport(Darwin)
import XCTest

final class SFZVorbisReaderTests: XCTestCase {

    private struct Fixture {
        var name: String
        var rate: Int
        var frames: Int
        var ogg: Data
        var reference: [Float]
    }

    private static let table: [(String, Int, Int)] = [("tone-44100", 44100, 12000), ("rate-22050", 22050, 9000),
                                                      ("tiny-48000", 48000, 300), ("long-44100", 44100, 70000)]

    private func fixture(_ index: Int) throws -> Fixture {
        let (name, rate, frames) = Self.table[index]
        let ogg = try Data(contentsOf: try XCTUnwrap(TestResource.url(name, "ogg", subdirectory: "vorbis")))
        let raw = try Data(contentsOf: try XCTUnwrap(TestResource.url(name, "s16", subdirectory: "vorbis")))
        XCTAssertEqual(raw.count, frames * 2, name)
        let reference = (0..<frames).map { i -> Float in
            Float(Int16(bitPattern: UInt16(raw[i * 2]) | UInt16(raw[i * 2 + 1]) << 8)) / 32768
        }
        return Fixture(name: name, rate: rate, frames: frames, ogg: ogg, reference: reference)
    }

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("SFZVorbisReaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// 入れ物（先頭に baseOffset 分、各標本の前に隙間、後ろに余り）を作り、標本ごとの ETSFZSampleSource を返す。
    /// 入れ物の中の位置は baseOffset + dataOffset（SoundFont の頭 + SoundFont の中の Ogg の位置）。
    private func makeBank(_ fixtures: [Fixture], firstFrames: [Int]? = nil, trimFrames: [Int]? = nil) throws
        -> (url: URL, sources: [ETSFZSampleSource]) {
        let base = 13, gap = 29
        var bytes = [UInt8](repeating: 0xEE, count: base)
        var sources: [ETSFZSampleSource] = []
        for (index, fixture) in fixtures.enumerated() {
            let dataOffset = bytes.count - base + gap
            bytes += [UInt8](repeating: 0xDD, count: gap)
            bytes += [UInt8](fixture.ogg)
            let first = firstFrames?[index] ?? 0
            let frames = fixture.frames - first - (trimFrames?[index] ?? 0)
            let layout = ETSFZVorbisLayout(dataOffset: UInt64(dataOffset), dataBytes: UInt64(fixture.ogg.count),
                                           firstFrame: UInt64(first), sourceFrames: UInt64(fixture.frames))
            sources.append(ETSFZSampleSource(url: URL(fileURLWithPath: "/unset"), baseOffset: UInt64(base), format: .vorbis(layout),
                                             frames: UInt64(frames), channels: 1, sampleRate: fixture.rate))
        }
        bytes += [UInt8](repeating: 0xCC, count: 40)
        let url = scratch.appendingPathComponent("bank-\(UUID().uuidString).sfzbank")
        try Data(bytes).write(to: url)
        for index in sources.indices { sources[index].url = url }
        return (url, sources)
    }

    private func layout(_ source: ETSFZSampleSource) throws -> ETSFZVorbisLayout {
        guard case .vorbis(let layout) = source.format else { throw ETSFZPageError.format }
        return layout
    }

    private func readPage(_ reader: ETSFZVorbisReader, _ source: ETSFZSampleSource, _ page: UInt64) throws -> [Float] {
        let capacity = ETSFZPageDecode.pageFrames * 2
        let out = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        defer { out.deallocate() }
        let result = try reader.read(source, layout: try layout(source), page: page, into: out, capacity: capacity)
        XCTAssertEqual(result.channels, 1)
        return Array(UnsafeBufferPointer(start: out, count: result.frames))
    }

    private func assertPage(_ page: [Float], matches reference: [Float], from start: Int, _ message: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(page.isEmpty, message, file: file, line: line)
        for (index, value) in page.enumerated() {
            let error = abs(value - reference[start + index]) * 32768
            if error > 1.5 {
                XCTFail("\(message): フレーム \(start + index) が答えと \(error) LSB ずれた", file: file, line: line)
                return
            }
        }
    }

    // MARK: 復号

    func testEveryPageOfEveryFixtureMatchesTheReference() throws {
        let fixtures = try (0..<Self.table.count).map { try fixture($0) }
        let bank = try makeBank(fixtures)
        let reader = ETSFZVorbisReader()
        defer { reader.close() }
        for (index, fixture) in fixtures.enumerated() {
            let source = bank.sources[index]
            let pages = (fixture.frames + ETSFZPageDecode.pageFrames - 1) / ETSFZPageDecode.pageFrames
            for page in 0..<pages {
                let samples = try readPage(reader, source, UInt64(page))
                let expected = min(ETSFZPageDecode.pageFrames, fixture.frames - page * ETSFZPageDecode.pageFrames)
                XCTAssertEqual(samples.count, expected, "\(fixture.name) ページ \(page)")
                assertPage(samples, matches: fixture.reference, from: page * ETSFZPageDecode.pageFrames, "\(fixture.name) ページ \(page)")
            }
            // 範囲の外のページは range。
            XCTAssertThrowsError(try readPage(reader, source, UInt64(pages))) { XCTAssertEqual($0 as? ETSFZPageError, .range) }
        }
    }

    func testTheSampleWindowStartsAtFirstFrameAndEndsBeforeTheTrim() throws {
        let fixture = try fixture(0)   // 12000 フレーム
        // 復号後の 1000 フレーム目から、末尾 500 を使わない（標本は 10500 フレーム）。
        let bank = try makeBank([fixture], firstFrames: [1000], trimFrames: [500])
        let source = bank.sources[0]
        XCTAssertEqual(source.frames, 10500)
        let reader = ETSFZVorbisReader()
        defer { reader.close() }
        let pages = (10500 + ETSFZPageDecode.pageFrames - 1) / ETSFZPageDecode.pageFrames
        for page in 0..<pages {
            let samples = try readPage(reader, source, UInt64(page))
            XCTAssertEqual(samples.count, min(ETSFZPageDecode.pageFrames, 10500 - page * ETSFZPageDecode.pageFrames))
            assertPage(samples, matches: fixture.reference, from: 1000 + page * ETSFZPageDecode.pageFrames, "ページ \(page)")
        }
        XCTAssertThrowsError(try readPage(reader, source, UInt64(pages))) { XCTAssertEqual($0 as? ETSFZPageError, .range) }
    }

    // MARK: 覚える量

    func testRandomPagesAcrossSamplesStayCorrectWithATinyBudgetAndOneOpenDecoder() throws {
        let fixtures = try (0..<Self.table.count).map { try fixture($0) }
        let bank = try makeBank(fixtures)
        // 上限は 4 本の Ogg を合わせた量より小さい（外して復号し直すことになる）。復号器は 1 本だけ開いたまま。
        let reader = ETSFZVorbisReader(budget: 400_000, openDecoders: 1)
        defer { reader.close() }
        var state: UInt32 = 2024
        func next() -> Int { state = state &* 1664525 &+ 1013904223; return Int(state >> 8) }
        for round in 0..<150 {
            let index = next() % fixtures.count
            let fixture = fixtures[index]
            let pages = (fixture.frames + ETSFZPageDecode.pageFrames - 1) / ETSFZPageDecode.pageFrames
            let page = next() % pages
            let samples = try readPage(reader, bank.sources[index], UInt64(page))
            assertPage(samples, matches: fixture.reference, from: page * ETSFZPageDecode.pageFrames, "\(round) 回目 \(fixture.name) ページ \(page)")
            XCTAssertLessThanOrEqual(reader.openDecoderCount, 1, "復号器は 1 本まで")
        }
        reader.close()
        XCTAssertEqual(reader.cachedCount, 0)
    }

    func testRepeatedPagesDoNotReopenTheStream() throws {
        let fixture = try fixture(3)
        let bank = try makeBank([fixture])
        let reader = ETSFZVorbisReader()
        defer { reader.close() }
        _ = try readPage(reader, bank.sources[0], 0)
        XCTAssertEqual(reader.cachedCount, 1)
        // 入れ物を消しても、覚えているページは読める（Ogg は写しを持つ）。
        try FileManager.default.removeItem(at: bank.url)
        assertPage(try readPage(reader, bank.sources[0], 0), matches: fixture.reference, from: 0, "消した後の同じページ")
        assertPage(try readPage(reader, bank.sources[0], 1), matches: fixture.reference, from: 4096, "消した後の続き")
    }

    // MARK: 断る

    func testRefusesWrongShapesAndDamagedOrMissingFiles() throws {
        let fixture = try fixture(0)
        let bank = try makeBank([fixture])
        let good = bank.sources[0]
        let reader = ETSFZVorbisReader()
        defer { reader.close() }
        // モノでない。
        var stereo = good
        stereo.channels = 2
        XCTAssertThrowsError(try readPage(reader, stereo, 0)) { XCTAssertEqual($0 as? ETSFZPageError, .format) }
        // レートが SHDR と違う（Ogg の識別ヘッダーのレートと合わない）。
        var wrongRate = good
        wrongRate.sampleRate = fixture.rate + 1
        XCTAssertThrowsError(try readPage(reader, wrongRate, 0)) { XCTAssertEqual($0 as? ETSFZPageError, .format) }
        // 最後の granule と sourceFrames が合わない。
        var wrongFrames = try layout(good)
        wrongFrames.sourceFrames += 1
        var shifted = good
        shifted.format = .vorbis(wrongFrames)
        XCTAssertThrowsError(try readPage(reader, shifted, 0)) { XCTAssertEqual($0 as? ETSFZPageError, .format) }
        // 形が不正（範囲が復号後の外）。
        var outside = try layout(good)
        outside.firstFrame = UInt64(fixture.frames)
        var bad = good
        bad.format = .vorbis(outside)
        XCTAssertThrowsError(try readPage(reader, bad, 0)) { XCTAssertEqual($0 as? ETSFZPageError, .format) }
        XCTAssertEqual(reader.cachedCount, 0, "断った標本は覚えない")
        // 壊れた Ogg（CRC が合わない）。
        let damagedURL = scratch.appendingPathComponent("damaged.bin")
        var damaged = try Data(contentsOf: bank.url)
        damaged[13 + 29 + 200] ^= 0x10
        try damaged.write(to: damagedURL)
        var damagedSource = good
        damagedSource.url = damagedURL
        XCTAssertThrowsError(try readPage(reader, damagedSource, 0)) { XCTAssertEqual($0 as? ETSFZPageError, .format) }
        // ファイルが縮んだ（Ogg が最後まで読めない）・無い。
        let shortURL = scratch.appendingPathComponent("short.bin")
        try Data(contentsOf: bank.url).prefix(13 + 29 + 100).write(to: shortURL)
        var shortSource = good
        shortSource.url = shortURL
        XCTAssertThrowsError(try readPage(reader, shortSource, 0)) { XCTAssertEqual($0 as? ETSFZPageError, .changed) }
        var missing = good
        missing.url = scratch.appendingPathComponent("none.bin")
        XCTAssertThrowsError(try readPage(reader, missing, 0)) { XCTAssertEqual($0 as? ETSFZPageError, .changed) }
        // 正しい標本は、断られたあとも読める。
        assertPage(try readPage(reader, good, 0), matches: fixture.reference, from: 0, "断ったあと")
    }
}
#endif
