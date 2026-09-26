//  FXDLinkTests.swift
//  共有リンク（ETFXDLink）。作るのは effectdeck.nemut.ai だけで、別名の fxd.nemut.ai は読むだけ。
//
//  **約束は site/test-vector.json。**サイトの復号（site/test.mjs）も同じファイルを読む。
//  ここで戻せてサイトで戻せない、またはその逆が起きたら、アプリの無い人に見える
//  中身とアプリが取り込む中身が食い違う。
//
//  ETFXDLink.swift と test-vector.json はこのバンドルへ直接入れてある（project.yml）。

import XCTest

final class FXDLinkTests: XCTestCase {

    private struct Vector: Decodable {
        let source: String
        let payload: String
        let url: String
    }

    private func vector() throws -> Vector {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-vector", withExtension: "json"))
        return try JSONDecoder().decode(Vector.self, from: Data(contentsOf: file))
    }

    // MARK: - 共有の見本

    /// **サイトと同じ payload を同じソースへ戻す。**
    /// 見本は node の zlib で作った。書く側が Apple の圧縮器でなくても読めること。
    func testDecodesSharedVector() throws {
        let v = try vector()
        XCTAssertEqual(try ETFXDLink.decode(v.payload), v.source)
        XCTAssertEqual(ETFXDLink.route(try XCTUnwrap(URL(string: v.url))), .jsfx(v.source))
    }

    /// 見本は `-` と `_` の両方を含むように選んである。置換を通らずに済む見本だと意味が無い。
    func testVectorExercisesURLSafeAlphabet() throws {
        let v = try vector()
        XCTAssertTrue(v.payload.contains("-"))
        XCTAssertTrue(v.payload.contains("_"))
        XCTAssertEqual(v.url, "https://effectdeck.nemut.ai/j#" + v.payload)
    }

    // MARK: - 往復

    func testRoundTrip() throws {
        let sources = [
            "desc:x\n@sample\nspl0=spl0;\n",
            "desc:音量\r\n//author: 誰か\r\n@sample\r\nspl0 *= 0.5;\r\n",
            "desc:emoji 🎛️\n@init\n",
            (0..<2000).map { "// line \($0) \(($0 * 7919) % 104729)\n" }.joined(),
        ]
        for source in sources {
            let payload = try ETFXDLink.encode(source)
            XCTAssertNil(payload.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")), payload)
            XCTAssertEqual(try ETFXDLink.decode(payload), source)
        }
    }

    func testURLShape() throws {
        let source = "desc:x\n@sample\n"
        let url = try ETFXDLink.jsfxURL(source: source)
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "effectdeck.nemut.ai")
        XCTAssertEqual(url.path, "/j")
        XCTAssertNil(url.query)
        XCTAssertEqual(url.fragment, try ETFXDLink.encode(source))
        XCTAssertEqual(ETFXDLink.route(url), .jsfx(source))
    }

    // MARK: - 落とす

    func testRejectsGarbage() throws {
        let v = try vector()
        let bad = [
            "",
            "!!!!",
            "abcde",                                    // 長さが 4n+1
            v.payload + "=",                            // 素の base64 の埋め
            v.payload.replacingOccurrences(of: "-", with: "+"),
            ETFXDLink.base64url(Data("hello".utf8)),    // DEFLATE ではない
            String(v.payload.dropLast(12)),             // 途中で切れた
            ETFXDLink.base64url(try XCTUnwrap(ETFXDLink.deflate(Data("   \n".utf8)))), // 空白だけ
            ETFXDLink.base64url(try XCTUnwrap(ETFXDLink.deflate(Data([0xff, 0xfe, 0x00])))), // UTF-8 ではない
        ]
        for payload in bad {
            XCTAssertThrowsError(try ETFXDLink.decode(payload), payload)
        }
    }

    func testCapsSize() throws {
        let over = String(repeating: "a", count: ETFXDLink.sourceLimit + 1)
        XCTAssertThrowsError(try ETFXDLink.encode(over)) {
            XCTAssertEqual($0 as? ETFXDLink.Failure, .tooLarge)
        }
        // ちょうど上限は通る。
        let at = String(repeating: "a", count: ETFXDLink.sourceLimit)
        XCTAssertEqual(try ETFXDLink.decode(try ETFXDLink.encode(at)), at)

        // **膨らむ payload を戻さない。**10 MB の `a` は十数 KB の payload になる。
        let bomb = ETFXDLink.base64url(try XCTUnwrap(ETFXDLink.deflate(Data(repeating: 0x61, count: 10_000_000))))
        XCTAssertLessThan(bomb.count, ETFXDLink.payloadLimit)
        XCTAssertThrowsError(try ETFXDLink.decode(bomb))

        XCTAssertThrowsError(try ETFXDLink.decode(String(repeating: "A", count: ETFXDLink.payloadLimit + 4)))
    }

    // MARK: - 行き先

    func testRoutes() throws {
        func route(_ s: String) -> ETFXDLink.Route? { ETFXDLink.route(URL(string: s)!) }
        let v = try vector()

        XCTAssertEqual(route("https://fxd.nemut.ai/?p=W10%3D"), .chain("https://fxd.nemut.ai/?p=W10%3D"))
        XCTAssertEqual(route("https://effectdeck.nemut.ai/?p=W10="), .chain("https://effectdeck.nemut.ai/?p=W10="))
        XCTAssertEqual(route("https://effetune.frieve.com/effetune.html?p=W10="),
                       .chain("https://effetune.frieve.com/effetune.html?p=W10="))
        XCTAssertEqual(route("https://FXD.nemut.ai/?p=W10="), .chain("https://FXD.nemut.ai/?p=W10="))
        // サイトのバナー（app-argument）は今の URL を字のまま渡すので、lang が付いて届く。
        XCTAssertEqual(route("https://effectdeck.nemut.ai/?p=W10%3D&lang=ja"),
                       .chain("https://effectdeck.nemut.ai/?p=W10%3D&lang=ja"))

        XCTAssertEqual(route("https://effectdeck.nemut.ai/j#" + v.payload), .jsfx(v.source))
        XCTAssertEqual(route("https://effectdeck.nemut.ai/j/#" + v.payload), .jsfx(v.source))
        // /j のバナーは location.href なので、lang は # の前に残る。
        XCTAssertEqual(route("https://effectdeck.nemut.ai/j?lang=ja#" + v.payload), .jsfx(v.source))
        // 別名の fxd は作らないが、届いたら読む。
        XCTAssertEqual(route("https://fxd.nemut.ai/j#" + v.payload), .jsfx(v.source))
        XCTAssertEqual(route("https://fxd.nemut.ai/j/#" + v.payload), .jsfx(v.source))
        XCTAssertEqual(route("https://fxd.nemut.ai/j"), .failed(.unreadableLink))
        XCTAssertEqual(route("https://fxd.nemut.ai/j#!!!!"), .failed(.unreadableLink))
        // frieve には JSFX の口は無い。
        XCTAssertEqual(route("https://effetune.frieve.com/j#" + v.payload), .ignored)

        XCTAssertEqual(route("https://effectdeck.nemut.ai/"), .ignored)
        XCTAssertEqual(route("https://effectdeck.nemut.ai/privacy"), .ignored)

        XCTAssertNil(route("https://example.com/?p=W10="))
        XCTAssertNil(route("https://nemut.ai/j#" + v.payload))
        XCTAssertNil(route("file:///tmp/x.jsfx"))
    }
}
