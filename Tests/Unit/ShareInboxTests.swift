//  ShareInboxTests.swift
//  共有の拡張から本体へ渡す置き場（ETShareInbox）。**実機も App Group も要らない。**
//
//  見張るのは 3 つ:
//    - 置かれた順に拾う（箱の更新時刻で並べる。名前の UUID 順ではない）
//    - 書きかけ（`.` の箱）は拾わず、新しいものは消さない。古いものだけ捨てる
//    - 渡した箱は受け手の結果にかかわらず消える

import XCTest

final class ShareInboxTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareInboxTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func setStamp(_ date: Date, of file: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date],
                                              ofItemAtPath: file.deletingLastPathComponent().path)
    }

    func testDepositPutsFileInItsOwnBox() throws {
        let file = try ETShareInbox.deposit(Data("desc:x".utf8), named: "a.jsfx", in: root)
        XCTAssertEqual(file.lastPathComponent, "a.jsfx")
        XCTAssertEqual(file.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL,
                       root.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: file), Data("desc:x".utf8))
        XCTAssertEqual(ETShareInbox.pending(in: root).map(\.lastPathComponent), ["a.jsfx"])
    }

    func testDepositCopiesFile() throws {
        let source = root.appendingPathComponent("src.wav")
        try Data([1, 2, 3]).write(to: source)
        let file = try ETShareInbox.deposit(copying: source, in: root)
        XCTAssertEqual(file.lastPathComponent, "src.wav")
        XCTAssertEqual(try Data(contentsOf: file), Data([1, 2, 3]))
        // 元は残る（写すだけ）。
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testPendingIsInArrivalOrder() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let c = try ETShareInbox.deposit(Data("c".utf8), named: "c.wav", in: root)
        let a = try ETShareInbox.deposit(Data("a".utf8), named: "a.wav", in: root)
        let b = try ETShareInbox.deposit(Data("b".utf8), named: "b.wav", in: root)
        try setStamp(base.addingTimeInterval(2), of: c)
        try setStamp(base, of: a)
        try setStamp(base.addingTimeInterval(1), of: b)
        XCTAssertEqual(ETShareInbox.pending(in: root).map(\.lastPathComponent),
                       ["a.wav", "b.wav", "c.wav"])
    }

    func testDrainHandsEachFileOnceAndRemovesBoxes() throws {
        try ETShareInbox.deposit(Data("1".utf8), named: "one.wav", in: root)
        try ETShareInbox.deposit(Data("2".utf8), named: "pasted.jsfx", in: root)
        // 空の箱も片付く。
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(UUID().uuidString), withIntermediateDirectories: true)

        var seen: [String] = []
        let results = ETShareInbox.drain(in: root) { url -> Bool in
            // 渡っている間はまだ読める。
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            seen.append(url.lastPathComponent)
            return false
        }
        XCTAssertEqual(Set(seen), ["one.wav", "pasted.jsfx"])
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(ETShareInbox.pending(in: root).isEmpty)
        let left = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(left, [])
        // 2 回目は何も渡らない。
        XCTAssertEqual(ETShareInbox.drain(in: root) { $0 }.count, 0)
    }

    func testStagingBoxIsSkippedUntilStale() throws {
        let staging = root.appendingPathComponent("." + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let half = staging.appendingPathComponent("half.wav")
        try Data([0]).write(to: half)
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        try setStamp(stamp, of: half)

        XCTAssertTrue(ETShareInbox.pending(in: root).isEmpty)

        // 書いている最中（新しい）は残す。
        _ = ETShareInbox.drain(in: root, now: stamp.addingTimeInterval(10)) { $0 }
        XCTAssertTrue(FileManager.default.fileExists(atPath: half.path))

        // 古いものは捨てる。
        _ = ETShareInbox.drain(in: root,
                               now: stamp.addingTimeInterval(ETShareInbox.staleAfter + 1)) { $0 }
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testSafeName() {
        XCTAssertEqual(ETShareInbox.safeName("BRIR 01.wav"), "BRIR 01.wav")
        XCTAssertEqual(ETShareInbox.safeName("a/b.wav"), "a-b.wav")
        XCTAssertEqual(ETShareInbox.safeName("..hidden"), "hidden")
        XCTAssertEqual(ETShareInbox.safeName("  "), "download")
    }
}
