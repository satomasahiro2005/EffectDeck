//  SFZLibraryBackendTests.swift
//  SFZ・SoundFont の置き場の入れ物（DSP/SFZLibraryBackend）。上流の SfzLibraryService が呼ぶ 6 つの口と、
//  index.json の往復（知らない鍵を落とさない）、部分の並びからの入れ物の書き込み（元のファイルの範囲を流す）。
//  Foundation だけ。

import XCTest

final class SFZLibraryBackendTests: XCTestCase {

    private var root: URL!
    private var backend: ETSFZLibraryBackend!

    private let idA = "0123456789abcdef01234567"
    private let idB = "89abcdef0123456789abcdef"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sfz-backend-" + UUID().uuidString)
        backend = ETSFZLibraryBackend(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func pattern(_ count: Int, seed: Int = 0) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: ($0 &* 31) &+ ($0 >> 8) &+ seed) })
    }

    // MARK: 名前

    func testNameWhitelist() {
        XCTAssertTrue(ETSFZLibraryBackend.isValidName("index.json"))
        XCTAssertTrue(ETSFZLibraryBackend.isValidName(idA + ".sfzbank"))
        for bad in ["", "../index.json", "a/b.sfzbank", "ABCDEF0123456789abcdef01.sfzbank", idA + ".sfzbank.tmp",
                    String(idA.dropLast()) + ".sfzbank", idA + ".wav", "index.json/", "x.tmp"] {
            XCTAssertFalse(ETSFZLibraryBackend.isValidName(bad), bad)
            XCTAssertThrowsError(try backend.read(bad)) { XCTAssertEqual($0 as? ETSFZBackendError, .invalidItem) }
            XCTAssertThrowsError(try backend.writeAtomic(bad, Data([1]))) { XCTAssertEqual($0 as? ETSFZBackendError, .invalidItem) }
            XCTAssertThrowsError(try backend.remove(bad)) { XCTAssertEqual($0 as? ETSFZBackendError, .invalidItem) }
        }
        // index.json は readSfzBankFile では開けない。
        XCTAssertThrowsError(try backend.readSfzBankFile("index.json")) { XCTAssertEqual($0 as? ETSFZBackendError, .invalidItem) }
    }

    // MARK: read / writeAtomic / remove

    func testReadMissingIsNilAndAtomicWriteReplaces() throws {
        XCTAssertNil(try backend.read("index.json"))
        XCTAssertNil(try backend.readSfzBankFile(idA + ".sfzbank"))
        try backend.writeAtomic("index.json", Data("one".utf8))
        try backend.writeAtomic("index.json", Data("two!".utf8))
        XCTAssertEqual(try backend.read("index.json"), Data("two!".utf8))
        let bank = pattern(70_000)
        try backend.writeAtomic(idA + ".sfzbank", bank)
        XCTAssertEqual(try backend.read(idA + ".sfzbank"), bank)
        let file = try XCTUnwrap(try backend.readSfzBankFile(idA + ".sfzbank"))
        XCTAssertEqual(file.size, 70_000)
        // 一時ファイルは残らない。
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        XCTAssertEqual(names, [idA + ".sfzbank", "index.json"])
    }

    func testRemoveIsIdempotent() throws {
        try backend.writeAtomic(idA + ".sfzbank", pattern(100))
        try backend.remove(idA + ".sfzbank")
        try backend.remove(idA + ".sfzbank")
        XCTAssertNil(try backend.read(idA + ".sfzbank"))
        XCTAssertNoThrow(try ETSFZLibraryBackend(root: root.appendingPathComponent("nothing")).remove("index.json"))
    }

    func testCleanupTemporaryRemovesOnlyTemporaries() throws {
        try backend.writeAtomic("index.json", Data("{}".utf8))
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("deadbeef.tmp"))
        try Data([1, 2, 3]).write(to: root.appendingPathComponent(UUID().uuidString.lowercased() + ".tmp"))
        try backend.cleanupTemporary()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["index.json"])
        // フォルダが無くても落ちない。
        XCTAssertNoThrow(try ETSFZLibraryBackend(root: root.appendingPathComponent("nothing")).cleanupTemporary())
    }

    // MARK: index.json

    /// 今の（2.13〜2.16 の ETSFZLibraryFiles.writeIndex の）書き方。鍵は id・name・regionCount と size・fileCount・importedAt。
    private var todaysIndex: String {
        "{\"version\":1,\"entries\":[" +
        "{\"id\":\"\(idA)\",\"name\":\"Piano.sfz\",\"regionCount\":88,\"size\":1234567,\"fileCount\":12,\"importedAt\":\"2026-10-01T09:30:00.000Z\"}," +
        "{\"id\":\"\(idB)\",\"name\":\"日本語 \\\"quoted\\\".sfz\",\"regionCount\":3}" +
        "]}"
    }

    func testTodaysIndexOpens() throws {
        try backend.writeAtomic("index.json", Data(todaysIndex.utf8))
        let index = try backend.readIndex()
        XCTAssertEqual(index.entries.map(\.id), [idA, idB])
        XCTAssertEqual(index.entries[0].name, "Piano.sfz")
        XCTAssertEqual(index.entries[0].regionCount, 88)
        XCTAssertEqual(index.entries[0].size, 1_234_567)
        XCTAssertEqual(index.entries[0].fileCount, 12)
        XCTAssertEqual(index.entries[0].importedAt, "2026-10-01T09:30:00.000Z")
        XCTAssertFalse(index.entries[0].streamedSource)
        XCTAssertNil(index.entries[1].size)
        XCTAssertEqual(index.entries[1].name, "日本語 \"quoted\".sfz")
        // 読んで書き直すだけで字が変わらない（JSON.stringify と同じ形）。
        XCTAssertEqual(String(decoding: index.serialized(), as: UTF8.self), todaysIndex)
    }

    func testEmptyAndMissingIndex() throws {
        XCTAssertEqual(try backend.readIndex(), ETSFZLibraryIndex())
        XCTAssertEqual(String(decoding: ETSFZLibraryIndex().serialized(), as: UTF8.self), "{\"version\":1,\"entries\":[]}")
    }

    func testIndexRoundTripKeepsUnknownKeys() throws {
        let text = "{\"version\":1,\"entries\":[" +
            "{\"id\":\"\(idA)\",\"name\":\"Grand.sf2\",\"regionCount\":5,\"size\":9,\"fileCount\":1,\"streamedSource\":true," +
            "\"importedAt\":\"2026-11-01T00:00:00.000Z\",\"format\":\"sf2\",\"future\":{\"a\":[1,2.50,-0,1e3,null,true],\"b\":\"x\"}}," +
            "{\"id\":\"\(idB)\",\"name\":\"B.sfz\",\"regionCount\":2,\"streamedSource\":false}" +
            "],\"note\":\"keep me\"}"
        try backend.writeAtomic("index.json", Data(text.utf8))
        var index = try backend.readIndex()
        XCTAssertTrue(index.entries[0].streamedSource)
        XCTAssertEqual(index.entries[0].format, "sf2")
        XCTAssertEqual(index.entries[0].fields["future"], .object(ETSFZJSONObject(members: [
            ETSFZJSONMember(key: "a", value: .array([.number("1"), .number("2.50"), .number("-0"), .number("1e3"), .null, .bool(true)])),
            ETSFZJSONMember(key: "b", value: .string("x"))])))
        XCTAssertFalse(index.entries[1].streamedSource)
        // そのまま書く → 同じ字。
        try backend.writeIndex(index)
        XCTAssertEqual(String(decoding: try XCTUnwrap(try backend.read("index.json")), as: UTF8.self), text)
        // 1 件外しても残りの知らない鍵は残る。上位の鍵も。
        index = index.removing(id: idB)
        try backend.writeIndex(index)
        let again = try backend.readIndex()
        XCTAssertEqual(again.entries.count, 1)
        XCTAssertEqual(again.entries[0].fields["future"], index.entries[0].fields["future"])
        XCTAssertEqual(again.otherFields["note"], .string("keep me"))
    }

    func testUpsertKeepsSortedAndReplacesSameID() throws {
        let one = ETSFZLibraryIndexEntry(id: idB, name: "B", regionCount: 1, size: 5, fileCount: 1, importedAt: "t")
        let two = ETSFZLibraryIndexEntry(id: idA, name: "A", regionCount: 2, size: 6, fileCount: 1, streamedSource: true,
                                         importedAt: "t", format: "sf3")
        var index = ETSFZLibraryIndex().upserting(one).upserting(two)
        XCTAssertEqual(index.entries.map(\.id), [idA, idB])
        index = index.upserting(ETSFZLibraryIndexEntry(id: idB, name: "B2", regionCount: 4))
        XCTAssertEqual(index.entries.map(\.name), ["A", "B2"])
        // 鍵の並びは上流（importFolderFiles / _storeStreamedSource）と同じ。
        XCTAssertEqual(String(decoding: index.serialized(), as: UTF8.self),
                       "{\"version\":1,\"entries\":[{\"id\":\"\(idA)\",\"name\":\"A\",\"regionCount\":2,\"size\":6,\"fileCount\":1," +
                       "\"streamedSource\":true,\"importedAt\":\"t\",\"format\":\"sf3\"},{\"id\":\"\(idB)\",\"name\":\"B2\",\"regionCount\":4}]}")
    }

    func testInvalidIndexesAreRejected() throws {
        let bad = [
            "", "{", "[]", "{\"version\":2,\"entries\":[]}", "{\"version\":1}", "{\"version\":1,\"entries\":{}}",
            "{\"version\":1,\"entries\":[{\"id\":\"XYZ\",\"name\":\"a\",\"regionCount\":1}]}",
            "{\"version\":1,\"entries\":[{\"id\":\"\(idA)\",\"name\":1,\"regionCount\":1}]}",
            "{\"version\":1,\"entries\":[{\"id\":\"\(idA)\",\"name\":\"a\",\"regionCount\":0}]}",
            "{\"version\":1,\"entries\":[{\"id\":\"\(idA)\",\"name\":\"a\",\"regionCount\":1.5}]}",
            "{\"version\":1,\"entries\":[{\"id\":\"\(idA)\",\"name\":\"a\",\"regionCount\":1,\"streamedSource\":1}]}",
            "{\"version\":1,\"entries\":[]} trailing", "{\"version\":1,\"entries\":[],}"
        ]
        for text in bad {
            XCTAssertNil(ETSFZLibraryIndex(data: Data(text.utf8)), text)
            try backend.writeAtomic("index.json", Data(text.utf8))
            XCTAssertThrowsError(try backend.readIndex(), text)
        }
        XCTAssertNil(ETSFZLibraryIndex(data: Data([0x7B, 0xFF, 0x7D])))
        // BOM は外す（TextDecoder と同じ）。
        XCTAssertNotNil(ETSFZLibraryIndex(data: Data([0xEF, 0xBB, 0xBF]) + Data("{\"version\":1,\"entries\":[]}".utf8)))
        // 件数の上限 10000。
        let entries = (0..<10001).map { String(format: "{\"id\":\"%024x\",\"name\":\"a\",\"regionCount\":1}", $0) }
        XCTAssertNil(ETSFZLibraryIndex(data: Data(("{\"version\":1,\"entries\":[" + entries.joined(separator: ",") + "]}").utf8)))
    }

    func testJSONStringEscapesAndSurrogates() throws {
        let text = "{\"version\":1,\"entries\":[{\"id\":\"\(idA)\",\"name\":\"\\u0001\\u00e9\\ud83c\\udfb9\\/\\n\",\"regionCount\":1}]}"
        let index = try XCTUnwrap(ETSFZLibraryIndex(data: Data(text.utf8)))
        XCTAssertEqual(index.entries[0].name, "\u{01}é🎹/\n")
        XCTAssertEqual(String(decoding: index.serialized(), as: UTF8.self),
                       "{\"version\":1,\"entries\":[{\"id\":\"\(idA)\",\"name\":\"\\u0001é🎹/\\n\",\"regionCount\":1}]}")
    }

    // MARK: writeSfzBankFile

    func testMultiPartWriteMatchesConcatenation() throws {
        // 接頭・メタデータ（バイト列）と、2 つの元ファイルの範囲を混ぜる。元ファイルは 1 MiB を跨ぐ。
        let sourceDir = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let first = pattern(2_500_000, seed: 3), second = pattern(1_048_576 + 17, seed: 9)
        let firstURL = sourceDir.appendingPathComponent("a.wav"), secondURL = sourceDir.appendingPathComponent("b.flac")
        try first.write(to: firstURL)
        try second.write(to: secondURL)
        let prefix = pattern(12, seed: 1), meta = pattern(300, seed: 2), tail = Data()
        let parts: [ETSFZBackendPart] = [
            .bytes(prefix), .bytes(meta),
            .fileRange(url: firstURL, offset: 0, length: UInt64(first.count)),
            .fileRange(url: secondURL, offset: 5, length: UInt64(second.count - 5 - 3)),
            .bytes(tail), .bytes(pattern(3, seed: 7)),
            .fileRange(url: firstURL, offset: 100, length: 0)
        ]
        var expected = prefix + meta + first + second.subdata(in: 5..<(second.count - 3)) + pattern(3, seed: 7)
        var progress: [(UInt64, UInt64)] = []
        try backend.writeSfzBankFile(idA + ".sfzbank", parts: parts, isCurrent: { true }) { progress.append(($0, $1)) }
        XCTAssertEqual(try backend.read(idA + ".sfzbank"), expected)
        let file = try XCTUnwrap(try backend.readSfzBankFile(idA + ".sfzbank"))
        XCTAssertEqual(file.size, UInt64(expected.count))
        XCTAssertEqual(progress.last?.0, UInt64(expected.count))
        XCTAssertTrue(progress.allSatisfy { $0.1 == UInt64(expected.count) })
        XCTAssertEqual(progress.map(\.0), progress.map(\.0).sorted())
        XCTAssertTrue(progress.count >= 5)   // 1 MiB ずつ
        // 範囲の読み。
        XCTAssertEqual(try backend.readRange(file, offset: 1_000_000, length: 4096),
                       expected.subdata(in: 1_000_000..<1_004_096))
        XCTAssertThrowsError(try backend.readRange(file, offset: file.size - 1, length: 2))
        // 書き直しは差し替え（古い中身が残らない）。
        expected = pattern(40, seed: 5)
        try backend.writeSfzBankFile(idA + ".sfzbank", parts: [.bytes(expected)])
        XCTAssertEqual(try backend.read(idA + ".sfzbank"), expected)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), [idA + ".sfzbank", "src"])
    }

    func testWriteRejectsBadInput() throws {
        XCTAssertThrowsError(try backend.writeSfzBankFile("index.json", parts: [.bytes(pattern(20))])) {
            XCTAssertEqual($0 as? ETSFZBackendError, .invalidItem)
        }
        // 12 バイト未満（上流の file.size < 12）。
        XCTAssertThrowsError(try backend.writeSfzBankFile(idA + ".sfzbank", parts: [.bytes(pattern(11))])) {
            XCTAssertEqual($0 as? ETSFZBackendError, .invalidItem)
        }
        XCTAssertThrowsError(try backend.writeSfzBankFile(idA + ".sfzbank", parts: [])) {
            XCTAssertEqual($0 as? ETSFZBackendError, .invalidItem)
        }
        // 上限 1 GiB 超（読まずに断る）。
        let missing = root.appendingPathComponent("nothing.bin")
        XCTAssertThrowsError(try backend.writeSfzBankFile(idA + ".sfzbank", parts: [
            .fileRange(url: missing, offset: 0, length: UInt64(ETSFZLibraryBackend.maxBankBytes) + 1)])) {
            XCTAssertEqual($0 as? ETSFZBackendError, .tooLarge)
        }
        XCTAssertThrowsError(try backend.writeSfzBankFile(idA + ".sfzbank", parts: [
            .fileRange(url: missing, offset: UInt64.max, length: 20)])) {
            XCTAssertEqual($0 as? ETSFZBackendError, .invalidItem)
        }
        XCTAssertNil(try backend.read(idA + ".sfzbank"))
    }

    func testShrunkenSourceFailsAndLeavesNothing() throws {
        let source = root.appendingPathComponent("short.bin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try pattern(1000).write(to: source)
        try backend.writeAtomic(idA + ".sfzbank", pattern(50, seed: 4))
        XCTAssertThrowsError(try backend.writeSfzBankFile(idA + ".sfzbank", parts: [
            .bytes(pattern(12)), .fileRange(url: source, offset: 0, length: 5000)])) {
            guard case .io = $0 as? ETSFZBackendError else { return XCTFail("\($0)") }
        }
        // 失敗しても元の入れ物は壊れず、一時ファイルも残らない。
        XCTAssertEqual(try backend.read(idA + ".sfzbank"), pattern(50, seed: 4))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), [idA + ".sfzbank", "short.bin"])
    }

    func testCancelledWriteRemovesTemporary() throws {
        let source = root.appendingPathComponent("big.bin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try pattern(3_000_000).write(to: source)
        var calls = 0
        XCTAssertThrowsError(try backend.writeSfzBankFile(idB + ".sfzbank", parts: [
            .bytes(pattern(12)), .fileRange(url: source, offset: 0, length: 3_000_000)],
            isCurrent: { calls += 1; return calls < 3 })) {
            XCTAssertEqual($0 as? ETSFZBackendError, .cancelled)
        }
        XCTAssertNil(try backend.read(idB + ".sfzbank"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["big.bin"])
        // 最後の確認（閉じる前）でも取り消せる。
        var checks = 0
        XCTAssertThrowsError(try backend.writeSfzBankFile(idB + ".sfzbank", parts: [.bytes(pattern(20))],
                                                          isCurrent: { checks += 1; return checks < 2 })) {
            XCTAssertEqual($0 as? ETSFZBackendError, .cancelled)
        }
        XCTAssertNil(try backend.read(idB + ".sfzbank"))
    }
}
