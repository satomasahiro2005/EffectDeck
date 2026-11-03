//  RemoteFileDownloadTests.swift
//  リンクから落とすところ（ETRemoteFile.download）。**網へは出ない。**StubURLProtocol が返事をする。
//
//  見張るのは 4 つ:
//    - 断る形: 2xx 以外は .http、向こうが言う大きさが上限を超えれば本文を受ける前に .tooLarge、
//      届いている途中で超えても**残りを待たずに** .tooLarge、空なら .empty。**どれでも書きかけを残さない**
//    - 名前: 飛ばされた先の末尾を先に見る。`raw` と `/` は名前にしない。置き場の外へ出る字は潰す
//    - gist: 一覧の raw_url を印で選ぶ。無ければ .noSuchFile。API に断られたら画面から引く
//    - User-Agent を付ける（GitHub は無いと断ることがある）
//  上限は小さく渡す（32 MiB を 1 バイトずつ流すと遅い）。32 MiB そのものは向こうが言う大きさで見る。

import XCTest

final class RemoteFileDownloadTests: XCTestCase {

    private var scratch: URL!
    private var session: URLSession!

    override func setUpWithError() throws {
        StubURLProtocol.reset()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFileDownloadTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        session = StubURLProtocol.session()
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: scratch)
        StubURLProtocol.reset()
    }

    // MARK: - 道具

    private func transfer(limit: Int = ETRemoteFile.limit) -> ETRemoteFile.Transfer {
        ETRemoteFile.Transfer(session: session, limit: limit, scratch: scratch)
    }

    private func download(_ address: String, limit: Int = ETRemoteFile.limit) async throws
        -> (file: URL, name: String) {
        try await ETRemoteFile.download(URL(string: address)!, via: transfer(limit: limit))
    }

    /// 投げたものを 1 語にする（Failure は Equatable でない）。
    private func failure(_ address: String, limit: Int = ETRemoteFile.limit) async -> String {
        do {
            let (file, name) = try await download(address, limit: limit)
            return "succeeded(\(name), \(file.lastPathComponent))"
        } catch let error as ETRemoteFile.Failure {
            switch error {
            case .notAnAddress: return "notAnAddress"
            case .tooLarge: return "tooLarge"
            case .http(let code): return "http(\(code))"
            case .empty: return "empty"
            case .noSuchFile: return "noSuchFile"
            }
        } catch {
            return "other(\(error))"
        }
    }

    /// 落としかけの置き場に残っているもの。
    private func leftovers() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: scratch.path).sorted()
    }

    private func body(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    }

    // MARK: - 落とす

    func testDownloadWritesTheBodyIntoScratchAndNamesItFromTheURL() async throws {
        let url = "https://raw.githubusercontent.com/u/r/main/fx/a.jsfx"
        StubURLProtocol.route(url, .init(body: Data("desc:a\n@sample\n".utf8)))
        let (file, name) = try await download(url)
        XCTAssertEqual(name, "a.jsfx")
        XCTAssertEqual(try Data(contentsOf: file), Data("desc:a\n@sample\n".utf8))
        XCTAssertEqual(file.deletingLastPathComponent().standardizedFileURL, scratch.standardizedFileURL)
        XCTAssertEqual(try leftovers(), [file.lastPathComponent])
    }

    func testUserAgentIsSet() async throws {
        let url = "https://example.com/a.wav"
        StubURLProtocol.route(url, .init(body: Data([1])))
        _ = try await download(url)
        XCTAssertEqual(StubURLProtocol.requests.last?.value(forHTTPHeaderField: "User-Agent"), "EffectDeck")
    }

    // MARK: - 断る

    func testNon2xxIsHTTPFailure() async throws {
        let url = "https://example.com/missing.wav"
        StubURLProtocol.route(url, .init(status: 404, body: Data("Not Found".utf8)))
        let got = await failure(url)
        XCTAssertEqual(got, "http(404)")
        XCTAssertEqual(try leftovers(), [])
    }

    /// 向こうが上限より大きいと言えば、本文を受ける前に断る。本文は小さくしてあるので、
    /// 大きさの申告を見ていなければ通ってしまう（下の対照で確かめる）。
    func testDeclaredLengthOverTheLimitIsRejectedBeforeWriting() async throws {
        let url = "https://example.com/huge.wav"
        StubURLProtocol.route(url, .init(body: Data("tiny".utf8),
                                         headers: ["Content-Length": String(ETRemoteFile.limit + 1)]))
        let got = await failure(url)
        XCTAssertEqual(got, "tooLarge")
        XCTAssertEqual(try leftovers(), [])
    }

    func testDeclaredLengthAtTheLimitIsAccepted() async throws {
        let url = "https://example.com/fits.wav"
        StubURLProtocol.route(url, .init(body: Data("tiny".utf8),
                                         headers: ["Content-Length": String(ETRemoteFile.limit)]))
        let (file, _) = try await download(url)
        XCTAssertEqual(try Data(contentsOf: file), Data("tiny".utf8))
    }

    /// 大きさを言わずに上限を超えて届いたら、断って書きかけを消す。
    /// 64 KiB ずつ書くので、200 000 バイトは 1 塊書いた後の 2 塊目で超える。
    /// 読み切るのを待たずに断るかは、次の試験が見る（ここは本文が終わるので、読み切ってから
    /// 大きさを見る作りでも通る）。
    func testBodyGrowingPastTheLimitIsRejectedAndThePartRemoved() async throws {
        let url = "https://example.com/stream.wav"
        StubURLProtocol.route(url, .init(body: body(200_000)))
        let got = await failure(url, limit: 100_000)
        XCTAssertEqual(got, "tooLarge")
        XCTAssertEqual(try leftovers(), [])
    }

    /// **本文が終わるのを待たずに断る。**上限を超えた分を受け続けて置き場へ書くと、終わりの無い
    /// 本文で書きかけが際限なく育つ。代役は 200 000 バイト送った後も線を閉じずに取り消しを待つ。
    /// 読み切ってから大きさを見る作りだとここで待ち続け、10 秒で代役に切られて（.timedOut）
    /// tooLarge にならない。
    func testBodyGrowingPastTheLimitIsRejectedBeforeItEnds() async throws {
        try XCTSkipIf(Self.bytesArriveOnlyWhenComplete,
                      "Linux の URLSession.bytes の代役（Tests/Linux/Shims/FoundationGaps/URLSessionBytes.swift）"
                      + "は本文を全部受けてから渡すので、途中で断るかは見られない")
        let url = "https://example.com/endless.wav"
        StubURLProtocol.route(url, .init(body: body(200_000), holdOpen: 10))
        let got = await failure(url, limit: 100_000)
        XCTAssertEqual(got, "tooLarge")
        XCTAssertEqual(try leftovers(), [])
    }

    /// Mac の URLSession.bytes は届いた順に渡す。Linux の代役は受け終えてから渡す。
    #if os(Linux)
    private static let bytesArriveOnlyWhenComplete = true
    #else
    private static let bytesArriveOnlyWhenComplete = false
    #endif

    func testBodyExactlyAtTheLimitIsAcceptedAndOneMoreByteIsNot() async throws {
        let url = "https://example.com/edge.wav"
        StubURLProtocol.route(url, .init(body: body(1000)))
        let (file, _) = try await download(url, limit: 1000)
        XCTAssertEqual(try Data(contentsOf: file), body(1000))
        try FileManager.default.removeItem(at: file)

        let got = await failure(url, limit: 999)
        XCTAssertEqual(got, "tooLarge")
        XCTAssertEqual(try leftovers(), [])
    }

    func testEmptyBodyIsEmptyFailure() async throws {
        let url = "https://example.com/empty.wav"
        StubURLProtocol.route(url, .init())
        let got = await failure(url)
        XCTAssertEqual(got, "empty")
        XCTAssertEqual(try leftovers(), [])
    }

    // MARK: - 名前

    /// gist の `/raw` は `gist.githubusercontent.com/.../raw/<sha>/<名前>` へ飛ぶ。
    /// 元の URL の末尾は "raw" なので、飛ばされた先の名前を使う。
    func testNameComesFromTheFinalURLAfterARedirect() async throws {
        let url = "https://gist.github.com/u/abc/raw"
        StubURLProtocol.route(url, .init(body: Data([1, 2]), finalURL:
            URL(string: "https://gist.githubusercontent.com/u/abc/raw/0123/dh++_4ch.wav")!))
        let (_, name) = try await download(url)
        XCTAssertEqual(name, "dh++_4ch.wav")
    }

    /// 頼んだ URL の末尾が名前らしくても、飛ばされた先の名前を使う（配布元の転送など）。
    func testFinalURLNameWinsOverTheRequestedName() async throws {
        let url = "https://example.com/dl/latest"
        StubURLProtocol.route(url, .init(body: Data([1]), finalURL:
            URL(string: "https://cdn.example.com/files/real.wav")!))
        let (_, name) = try await download(url)
        XCTAssertEqual(name, "real.wav")
    }

    func testSlashIsSkippedForTheRequestedURL() async throws {
        let url = "https://example.com/files/a.wav"
        StubURLProtocol.route(url, .init(body: Data([1]), finalURL: URL(string: "https://example.com/")!))
        let (_, name) = try await download(url)
        XCTAssertEqual(name, "a.wav")
    }

    func testRawEverywhereFallsBackToDownload() async throws {
        let url = "https://gist.github.com/u/abc/raw"
        StubURLProtocol.route(url, .init(body: Data([1])))
        let (_, name) = try await download(url)
        XCTAssertEqual(name, "download")
    }

    /// 飛ばす先は向こうが決める。頭の `.` と `:` は置き場で使えない形にしない。
    func testNameFromTheServerIsMadeSafe() async throws {
        let dotted = "https://example.com/x/.profile"
        StubURLProtocol.route(dotted, .init(body: Data([1])))
        let (_, dottedName) = try await download(dotted)
        XCTAssertEqual(dottedName, "profile")

        let colon = "https://example.com/x/a:b.wav"
        StubURLProtocol.route(colon, .init(body: Data([1])))
        let (_, colonName) = try await download(colon)
        XCTAssertEqual(colonName, "a-b.wav")
    }

    // MARK: - gist

    private let gistPage = "https://gist.github.com/u/abc"
    private let listing = "https://api.github.com/gists/abc"

    private func routeListing(_ files: [String: String]) throws {
        let json: [String: Any] = ["files": files.mapValues { ["raw_url": $0, "truncated": false] }]
        StubURLProtocol.route(listing, .init(body: try JSONSerialization.data(withJSONObject: json)))
    }

    /// 印（`#file-…`）は名前ではない。一覧の名前と突き合わせ、その raw_url を取りに行く。
    /// 置き場には落としたもの 1 本だけが残る（一覧を受けたファイルは消える）。
    func testGistAnchorPicksTheRawURLFromTheListing() async throws {
        try routeListing([
            "atmos_4ch_plain.wav": "https://gist.githubusercontent.com/u/abc/raw/1/atmos_4ch_plain.wav",
            "dh++_4ch.wav": "https://gist.githubusercontent.com/u/abc/raw/2/dh%2B%2B_4ch.wav",
        ])
        StubURLProtocol.route("https://gist.githubusercontent.com/u/abc/raw/1/atmos_4ch_plain.wav",
                              .init(body: Data("atmos".utf8)))
        StubURLProtocol.route("https://gist.githubusercontent.com/u/abc/raw/2/dh%2B%2B_4ch.wav",
                              .init(body: Data("dh".utf8)))

        let address = try XCTUnwrap(ETRemoteFile.address(from: gistPage + "#file-dh-_4ch-wav"))
        let (file, name) = try await ETRemoteFile.download(address, via: transfer())
        XCTAssertEqual(name, "dh++_4ch.wav")
        XCTAssertEqual(try Data(contentsOf: file), Data("dh".utf8))
        XCTAssertEqual(StubURLProtocol.requests.compactMap { $0.url?.host },
                       ["api.github.com", "gist.githubusercontent.com"])
        XCTAssertEqual(try leftovers(), [file.lastPathComponent])
    }

    /// 名指しの無いリンクは名前の順で最初の 1 本。README や convert.py は飛ばす。
    func testBareGistTakesTheFirstImportableFileByName() async throws {
        try routeListing([
            "README.md": "https://gist.githubusercontent.com/u/abc/raw/1/README.md",
            "convert.py": "https://gist.githubusercontent.com/u/abc/raw/1/convert.py",
            "b.wav": "https://gist.githubusercontent.com/u/abc/raw/1/b.wav",
            "a.jsfx": "https://gist.githubusercontent.com/u/abc/raw/1/a.jsfx",
        ])
        StubURLProtocol.route("https://gist.githubusercontent.com/u/abc/raw/1/a.jsfx",
                              .init(body: Data("desc:a".utf8)))
        let address = try XCTUnwrap(ETRemoteFile.address(from: gistPage))
        let (file, name) = try await ETRemoteFile.download(address, via: transfer())
        XCTAssertEqual(name, "a.jsfx")
        XCTAssertEqual(try Data(contentsOf: file), Data("desc:a".utf8))
    }

    func testMissingGistFileIsNoSuchFile() async throws {
        try routeListing(["a.wav": "https://gist.githubusercontent.com/u/abc/raw/1/a.wav"])
        let got = await failure(listing + "#file-nothing-wav")
        XCTAssertEqual(got, "noSuchFile")
        XCTAssertEqual(try leftovers(), [])
    }

    func testListingThatIsNotJSONIsNoSuchFile() async throws {
        StubURLProtocol.route(listing, .init(body: Data("<!DOCTYPE html>".utf8)))
        let got = await failure(listing)
        XCTAssertEqual(got, "noSuchFile")
        XCTAssertEqual(try leftovers(), [])
    }

    /// API に断られたら（未認証は 1 時間に 60 回まで）画面の Raw の行き先から名前を引く。
    func testRateLimitedListingFallsBackToTheGistPage() async throws {
        StubURLProtocol.route(listing, .init(status: 403, body: Data("rate limit exceeded".utf8)))
        let html = """
            <a href="/u/abc/raw/0a1b/atmos_4ch_plain.wav">Raw</a>
            <a href="/u/abc/raw/0a1b/dh%2B%2B_4ch.wav">Raw</a>
            """
        StubURLProtocol.route("https://gist.github.com/abc", .init(body: Data(html.utf8)))
        StubURLProtocol.route("https://gist.github.com/u/abc/raw/0a1b/dh%2B%2B_4ch.wav",
                              .init(body: Data("dh".utf8)))
        let (file, name) = try await download(listing + "#file-dh-_4ch-wav")
        XCTAssertEqual(name, "dh++_4ch.wav")
        XCTAssertEqual(try Data(contentsOf: file), Data("dh".utf8))
        XCTAssertEqual(try leftovers(), [file.lastPathComponent])
    }

    /// 回数切れ以外の断りは画面へ逃げずにそのまま出す。
    func testOtherListingErrorsAreReported() async throws {
        StubURLProtocol.route(listing, .init(status: 404))
        let got = await failure(listing)
        XCTAssertEqual(got, "http(404)")
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    // MARK: - fetch

    /// 「Import → From Link」の口。落としたものを一時置き場の inbox へ、向こうの名前で移す。
    func testFetchMovesTheFileIntoTheInboxUnderItsName() async throws {
        let name = "fetch-\(UUID().uuidString).wav"
        let url = "https://example.com/\(name)"
        StubURLProtocol.route(url, .init(body: Data([9, 8, 7])))
        let file = try await ETRemoteFile.fetch(URL(string: url)!, via: transfer())
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(file.lastPathComponent, name)
        XCTAssertEqual(file.deletingLastPathComponent().lastPathComponent, "inbox")
        XCTAssertEqual(try Data(contentsOf: file), Data([9, 8, 7]))
        XCTAssertEqual(try leftovers(), [])
    }
}
