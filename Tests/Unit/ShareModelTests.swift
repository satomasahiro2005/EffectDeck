//  ShareModelTests.swift
//  共有の拡張が受けたものを選んで Inbox へ置くところ（ShareModel.swift）。
//
//  ShareItem（受けたものの形と見出し）と ShareIntake（大きさの門・写しの名前・置き方）は
//  Foundation だけで、Linux でも走る。リンクは StubURLProtocol が返事をするので網へは出ない。
//  NSItemProvider から選ぶ試験（`#if canImport(UniformTypeIdentifiers)`）は Mac だけ。

import XCTest
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

final class ShareModelTests: XCTestCase {

    private var root: URL!
    private var scratch: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareModelTests-" + UUID().uuidString, isDirectory: true)
        root = base.appendingPathComponent("Inbox", isDirectory: true)
        scratch = base.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        StubURLProtocol.reset()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        StubURLProtocol.reset()
    }

    /// 大きさだけ持つファイル（中身は書かない。32 MiB を実際に書かずに済む）。
    private func sparseFile(_ name: String, size: Int) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
        return url
    }

    private func sizeFailure(_ url: URL, limit: Int = ETRemoteFile.limit) -> String {
        do {
            try ShareIntake.checkSize(of: url, limit: limit)
            return "ok"
        } catch ETRemoteFile.Failure.tooLarge {
            return "tooLarge"
        } catch {
            return "refused"
        }
    }

    // MARK: - 受けたものの形

    func testURLsSplitIntoFilesAndLinks() {
        let file = URL(fileURLWithPath: "/tmp/a.wav")
        let link = URL(string: "https://example.com/a.jsfx")!
        XCTAssertEqual(ShareItem(url: file), .file(file))
        XCTAssertEqual(ShareItem(url: link), .web(link))
    }

    /// メモやメッセージから来るリンクだけの字はリンクとして扱う（前後の空白と改行は見ない）。
    func testTextThatIsOnlyALinkBecomesAWebItem() {
        XCTAssertEqual(ShareItem(text: "  https://gist.github.com/u/abc \n"),
                       .web(URL(string: "https://gist.github.com/u/abc")!))
    }

    /// リンクを含む文章や、リンクでない字は字のまま（JSFX として置く）。
    func testOtherTextStaysText() {
        let sentence = "see https://example.com/a.jsfx"
        XCTAssertEqual(ShareItem(text: sentence), .text(sentence))
        let source = "desc:gain\n@sample\nspl0*=2;\n"
        XCTAssertEqual(ShareItem(text: source), .text(source))
        XCTAssertEqual(ShareItem(text: "ftp://example.com/a.jsfx"), .text("ftp://example.com/a.jsfx"))
    }

    func testEmptyTextIsNothing() {
        XCTAssertNil(ShareItem(text: ""))
    }

    // MARK: - 見出し

    func testNameForEachKind() {
        XCTAssertEqual(ShareItem.web(URL(string: "https://example.com/fx/a.jsfx?plain=1")!).name, "a.jsfx")
        XCTAssertEqual(ShareItem.web(URL(string: "https://example.com/")!).name, "example.com")
        XCTAssertEqual(ShareItem.web(URL(string: "https://example.com")!).name, "example.com")
        XCTAssertEqual(ShareItem.file(URL(fileURLWithPath: "/tmp/dir/Hall 2.wav")).name, "Hall 2.wav")
        XCTAssertEqual(ShareItem.text("\n\n   desc:My Gain  \n@sample\n").name, "desc:My Gain")
        XCTAssertEqual(ShareItem.text("   \n  ").name, "")
    }

    func testTextNameIsCutAt80Characters() {
        let long = String(repeating: "あ", count: 100)
        XCTAssertEqual(ShareItem.text(long).name, String(repeating: "あ", count: 80))
    }

    // MARK: - 大きさの門

    func testCheckSizeAcceptsAFileUpToTheLimit() throws {
        XCTAssertEqual(sizeFailure(try sparseFile("fits.wav", size: ETRemoteFile.limit)), "ok")
        XCTAssertEqual(sizeFailure(try sparseFile("small.wav", size: 3)), "ok")
    }

    func testCheckSizeRejectsAnythingOver32MiB() throws {
        XCTAssertEqual(ETRemoteFile.limit, 32 * 1024 * 1024)
        XCTAssertEqual(sizeFailure(try sparseFile("big.wav", size: ETRemoteFile.limit + 1)), "tooLarge")
    }

    /// フォルダは写し始めると止まらないので、大きさを見る前に断る。
    func testCheckSizeRejectsFolders() throws {
        let dir = scratch.appendingPathComponent("folder.wav", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertEqual(sizeFailure(dir), "refused")
        XCTAssertEqual(sizeFailure(scratch.appendingPathComponent("missing.wav")), "refused")
    }

    // MARK: - 写しの名前

    func testCopyNameUsesTheSuggestedNameAndAddsTheExtension() {
        let temp = URL(fileURLWithPath: "/tmp/x/0B5E-1234.wav")
        XCTAssertEqual(ShareIntake.copyName(suggested: "Hall", file: temp), "Hall.wav")
        XCTAssertEqual(ShareIntake.copyName(suggested: "Hall.wav", file: temp), "Hall.wav")
        XCTAssertEqual(ShareIntake.copyName(suggested: nil, file: temp), "0B5E-1234.wav")
        XCTAssertEqual(ShareIntake.copyName(suggested: "Hall", file: URL(fileURLWithPath: "/tmp/x/blob")), "Hall")
    }

    /// 渡された一時ファイルは受け取りの関数を抜けると消えるので、自分の置き場へ写す。
    /// 名前は ETShareInbox.safeName を通す（`/` `:` と頭の `.` を落とす）。
    func testScratchCopyUsesTheSafeSuggestedName() throws {
        let temp = try sparseFile("provider.wav", size: 10)
        let copy = try XCTUnwrap(ShareIntake.scratchCopy(of: temp, suggestedName: ".My:IR/2",
                                                         scratch: scratch))
        XCTAssertEqual(copy.lastPathComponent, "My-IR-2.wav")
        XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: temp))
        XCTAssertEqual(copy.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL,
                       scratch.standardizedFileURL)
    }

    func testScratchCopyRefusesOversizeWithoutCopying() throws {
        let temp = try sparseFile("huge.wav", size: 11)
        XCTAssertThrowsError(try ShareIntake.scratchCopy(of: temp, suggestedName: nil, limit: 10,
                                                         scratch: scratch))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), ["huge.wav"])
    }

    // MARK: - 置く

    func testTextIsDepositedAsPastedJSFX() async throws {
        let source = "desc:gain\n@sample\nspl0*=2;\n"
        let placed = try await ShareIntake.deposit(.text(source), in: root)
        XCTAssertEqual(placed.lastPathComponent, "pasted.jsfx")
        XCTAssertEqual(try Data(contentsOf: placed), Data(source.utf8))
        XCTAssertEqual(ETShareInbox.pending(in: root).map(\.lastPathComponent), ["pasted.jsfx"])
    }

    func testFileIsCopiedIntoTheInbox() async throws {
        let file = scratch.appendingPathComponent("Hall.wav")
        try Data([1, 2, 3]).write(to: file)
        let placed = try await ShareIntake.deposit(.file(file), in: root)
        XCTAssertEqual(placed.lastPathComponent, "Hall.wav")
        XCTAssertEqual(try Data(contentsOf: placed), Data([1, 2, 3]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testOversizeFileIsNotDeposited() async throws {
        let file = try sparseFile("big.wav", size: 11)
        let transfer = ETRemoteFile.Transfer(session: .shared, limit: 10, scratch: scratch)
        do {
            try await ShareIntake.deposit(.file(file), in: root, via: transfer)
            XCTFail("deposited an oversize file")
        } catch ETRemoteFile.Failure.tooLarge {
        }
        XCTAssertEqual(ETShareInbox.pending(in: root), [])
    }

    /// リンクは「Import → From Link」と同じ道（読み替え → 落とす → 移す）。
    func testLinkIsDownloadedAndMovedIntoTheInbox() async throws {
        let session = StubURLProtocol.session()
        defer { session.invalidateAndCancel() }
        StubURLProtocol.route("https://raw.githubusercontent.com/u/r/main/fx/a.jsfx",
                              .init(body: Data("desc:a".utf8)))
        let transfer = ETRemoteFile.Transfer(session: session, limit: ETRemoteFile.limit, scratch: scratch)
        let placed = try await ShareIntake.deposit(
            .web(URL(string: "https://github.com/u/r/blob/main/fx/a.jsfx")!), in: root, via: transfer)
        XCTAssertEqual(placed.lastPathComponent, "a.jsfx")
        XCTAssertEqual(try Data(contentsOf: placed), Data("desc:a".utf8))
        // 落としたものは写さずに移す。一時置き場には残らない。
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), [])
    }

    /// 取り消したら置かない。落とし終えていれば、落としたものも捨てる（Linux の代役は取り消しを
    /// 見ずに受け終えるので、置く直前の確かめまで進む。Mac の URLSession は受ける前に止まる）。
    func testCancelledLinkIsNotDepositedAndThePartIsRemoved() async throws {
        let session = StubURLProtocol.session()
        defer { session.invalidateAndCancel() }
        StubURLProtocol.route("https://example.com/a.wav", .init(body: Data([1, 2])))
        let transfer = ETRemoteFile.Transfer(session: session, limit: ETRemoteFile.limit, scratch: scratch)
        let rootURL = root!
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ShareIntake.deposit(.web(URL(string: "https://example.com/a.wav")!),
                                                 in: rootURL, via: transfer)
        }
        let result = await task.result
        XCTAssertThrowsError(try result.get())
        XCTAssertEqual(ETShareInbox.pending(in: root), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), [])
    }

    /// ファイルも取り消したら写さない（add の Task が走り出す前に Cancel を押した場合）。
    func testCancelledFileIsNotCopied() async throws {
        let file = scratch.appendingPathComponent("Hall.wav")
        try Data([1, 2, 3]).write(to: file)
        let rootURL = root!
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ShareIntake.deposit(.file(file), in: rootURL)
        }
        let result = await task.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(ETShareInbox.pending(in: root), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    /// 字も取り消したら pasted.jsfx を置かない。
    func testCancelledTextIsNotDeposited() async throws {
        let rootURL = root!
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ShareIntake.deposit(.text("desc:gain\n"), in: rootURL)
        }
        let result = await task.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(ETShareInbox.pending(in: root), [])
    }

    #if canImport(UniformTypeIdentifiers)
    // MARK: - NSItemProvider から選ぶ（Mac だけ）

    /// Safari は URL と字（ページの題名）の両方を載せてくる。字を先に取ると題名を JSFX として置く。
    /// URL は共有元がするように `init(item:typeIdentifier:)` で載せる。`init(object:)` で載せると
    /// `loadItem` が NSURL でなく Data を返すことがあり、`as? URL` が外れて字の方へ落ちる。
    func testURLBeatsText() async throws {
        let link = URL(string: "https://github.com/u/r/blob/main/a.jsfx")!
        let title = NSItemProvider(object: "Page Title" as NSString)
        let url = NSItemProvider(item: link as NSURL, typeIdentifier: UTType.url.identifier)
        let item = try await ShareModel.resolve([title, url])
        XCTAssertEqual(item, .web(link))
    }

    func testFileURLBecomesAFile() async throws {
        let file = scratch.appendingPathComponent("Hall.wav")
        try Data([1]).write(to: file)
        let provider = NSItemProvider(item: file as NSURL, typeIdentifier: UTType.fileURL.identifier)
        let item = try await ShareModel.resolve([provider])
        guard case .file(let got) = item else { return XCTFail("\(String(describing: item))") }
        XCTAssertEqual(got.standardizedFileURL, file.standardizedFileURL)
    }

    func testTextThatIsOnlyALinkResolvesToAWebItem() async throws {
        let item = try await ShareModel.resolve([NSItemProvider(object: " https://gist.github.com/u/abc\n" as NSString)])
        XCTAssertEqual(item, .web(URL(string: "https://gist.github.com/u/abc")!))
    }

    func testPlainTextResolvesToText() async throws {
        let source = "desc:gain\n@sample\n"
        let item = try await ShareModel.resolve([NSItemProvider(object: source as NSString)])
        XCTAssertEqual(item, .text(source))
    }

    /// 名前の無いデータは一時ファイルを写す。名前は向こうが示したものに拡張子を足し、safeName を通す。
    func testDataIsCopiedWithTheSafeSuggestedNameAndExtension() async throws {
        let source = scratch.appendingPathComponent("payload.wav")
        try Data([4, 5, 6]).write(to: source)
        let provider = NSItemProvider()
        provider.registerFileRepresentation(forTypeIdentifier: UTType.data.identifier,
                                            fileOptions: [], visibility: .all) { done in
            done(source, false, nil)
            return nil
        }
        provider.suggestedName = "My:IR"
        let item = try await ShareModel.resolve([provider])
        guard case .file(let copy) = item else { return XCTFail("\(String(describing: item))") }
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        // 拡張子は付くとは限らない。OSが写す一時ファイルは示された名前（My:IR）で作られ、
        // 元の.wavを持たないことがある（macOSで実測）。足す規則そのものはtestCopyNameで見ている。
        XCTAssertEqual(copy.deletingPathExtension().lastPathComponent, "My-IR")
        XCTAssertEqual(try Data(contentsOf: copy), Data([4, 5, 6]))
    }

    func testNothingUsableResolvesToNil() async throws {
        let item = try await ShareModel.resolve([NSItemProvider()])
        XCTAssertNil(item)
    }
    #endif
}
