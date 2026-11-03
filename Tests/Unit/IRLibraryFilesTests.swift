//  IRLibraryFilesTests.swift
//  IR の置き場のファイル名（IRLibraryFiles）。取り込むと `<鍵>__<元の名前>.<拡張子>` で書き、
//  一覧（IRLibrary.reload）はその名前から鍵と見出しを読む。書いた名前が読めなければ、
//  取り込んだ IR が一覧に出ない。

import XCTest

final class IRLibraryFilesTests: XCTestCase {

    private let id = "0123456789abcdef01234567"
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("IRLibraryFilesTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func source(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/somewhere").appendingPathComponent(name)
    }

    // MARK: - 書く名前

    func testStoredNameJoinsAlphanumericRunsWithDashes() {
        XCTAssertEqual(IRLibraryFiles.storedName(id: id, source: source("My IR (Hall) #2.wav")),
                       "\(id)__My-IR-Hall-2.wav")
    }

    func testStoredNameWithoutExtensionUsesBin() {
        XCTAssertEqual(IRLibraryFiles.storedName(id: id, source: source("impulse")), "\(id)__impulse.bin")
    }

    func testStoredNameKeepsTheOriginalExtension() {
        XCTAssertEqual(IRLibraryFiles.storedName(id: id, source: source("dh++_4ch.FLAC")),
                       "\(id)__dh-4ch.FLAC")
    }

    // MARK: - 読む名前

    func testEntryReadsWhatStoredNameWrote() throws {
        let url = folder.appendingPathComponent(IRLibraryFiles.storedName(id: id, source: source("Hall 2.wav")))
        let entry = try XCTUnwrap(IRLibraryFiles.entry(at: url, bytes: 42))
        XCTAssertEqual(entry.id, id)
        XCTAssertEqual(entry.name, "Hall-2.wav")
        XCTAssertEqual(entry.bytes, 42)
        XCTAssertEqual(entry.url, url)
    }

    /// 見出しは最初の `__` より後ろ全部。元の名前の `__` は切らない。
    func testEntryKeepsDoubleUnderscoresInTheName() throws {
        let entry = try XCTUnwrap(IRLibraryFiles.entry(at: folder.appendingPathComponent("\(id)__a__b.wav"),
                                                       bytes: 0))
        XCTAssertEqual(entry.name, "a__b.wav")
    }

    func testEntryIgnoresFilesThatAreNotTheLibrarys() {
        for name in ["notes.txt", "short__x.wav", "\(id).wav", "\(id)x__y.wav"] {
            XCTAssertNil(IRLibraryFiles.entry(at: folder.appendingPathComponent(name), bytes: 0), name)
        }
    }

    // MARK: - 一覧

    func testEntriesListTheFolderByNameWithSizes() throws {
        let other = "fedcba9876543210fedcba98"
        try Data(count: 5).write(to: folder.appendingPathComponent("\(id)__zeta.wav"))
        try Data(count: 3).write(to: folder.appendingPathComponent("\(other)__alpha.flac"))
        try Data(count: 1).write(to: folder.appendingPathComponent("stray.wav"))
        let entries = IRLibraryFiles.entries(in: folder)
        XCTAssertEqual(entries.map(\.name), ["alpha.flac", "zeta.wav"])
        XCTAssertEqual(entries.map(\.id), [other, id])
        XCTAssertEqual(entries.map(\.bytes), [3, 5])
    }

    func testEntriesOfAMissingFolderAreEmpty() {
        XCTAssertEqual(IRLibraryFiles.entries(in: folder.appendingPathComponent("missing")), [])
    }
}
