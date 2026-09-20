//  JSFXSourceTests.swift
//  読み込みの門。docs/jsfx-host-test-design.md §4.1（C01/C10-C17）と §22。
//
//  **ここが緩むと、あとの層が全部無意味になる。**import / include / file slider は
//  ファイルシステムと外部資源への口で、EffectDeck はそれを持たないと言って
//  出している（JSFX.md）。だから「拒否した」だけでなく「何を言って拒否したか」も
//  見る。文面は ETJSFXHost.cpp の forbiddenSource が作っているので、
//  行番号まで決まっている。

import XCTest

final class JSFXSourceTests: XCTestCase {

    /// C01。通る側を 1 本置いておかないと、全部落ちる実装でも赤くならない。
    func testMinimalSourceLoads() throws {
        let host = try JSFX.load("passthrough")
        XCTAssertEqual(String(cString: ETJSFX_Name(host.raw)), "Passthrough")
        XCTAssertEqual(String(cString: ETJSFX_Author(host.raw)), "nemut.ai")
        XCTAssertTrue(host.isRunning)
        XCTAssertEqual(host.diagnostic, "")
    }

    /// C10。
    func testNullPathFails() {
        let result = JSFX.open(path: nil)
        XCTAssertNil(result.raw)
        XCTAssertEqual(result.message, "Invalid JSFX path or block size.")
    }

    /// C11。
    func testEmptyPathFails() {
        let result = JSFX.open(path: "")
        XCTAssertNil(result.raw)
        XCTAssertEqual(result.message, "Invalid JSFX path or block size.")
    }

    /// C12。
    func testMissingFileFails() throws {
        let missing = try JSFX.path("passthrough") + ".not-here"
        let result = JSFX.open(path: missing)
        XCTAssertNil(result.raw)
        XCTAssertEqual(result.message, "Could not open JSFX source.")
    }

    /// C13。ブロック長 0 は path より先に落ちる。
    func testZeroMaxFramesFails() throws {
        let result = try JSFX.open("passthrough", maxFrames: 0)
        XCTAssertNil(result.raw)
        XCTAssertEqual(result.message, "Invalid JSFX path or block size.")
    }

    /// C15。文面は ysfx のコンパイルログなので中身は問わない。**空でないこと**だけ見る。
    /// ここが空だと、画面には「読み込めません」としか出ない。
    func testSyntaxErrorFailsWithDiagnostic() throws {
        let result = try JSFX.open("bad_syntax")
        XCTAssertNil(result.raw)
        XCTAssertFalse(result.message.isEmpty)
    }

    /// C16。file slider は compile まで通ってから弾かれる（ETJSFXHost.cpp の
    /// ysfx_slider_is_path ループ）。文面はそこで作っている。
    func testFileSliderRejected() throws {
        let result = try JSFX.open("file_slider")
        XCTAssertNil(result.raw)
        XCTAssertEqual(result.message, "File sliders are not supported.")
    }

    /// C17。行番号まで見る。forbiddenSource の数え方が 1 ずれても赤くなる。
    func testImportRejectedWithLineNumber() throws {
        let result = try JSFX.open("forbidden_import")
        XCTAssertNil(result.raw)
        XCTAssertEqual(result.message, "Unsupported import at line 3.")
    }

    /// C18。include() はファイルシステムへの口なので、コンパイルより前に断る。
    func testIncludeRejectedWithLineNumber() throws {
        let result = try JSFX.open("forbidden_include")
        XCTAssertNil(result.raw)
        XCTAssertEqual(result.message, "Unsupported include() at line 5.")
    }

    /// C19。`filename:` は外部資源の宣言。`data:` も同じ文面で断る。
    func testExternalResourceHeaderRejected() throws {
        let result = try JSFX.open("forbidden_filename")
        XCTAssertNil(result.raw)
        XCTAssertEqual(result.message, "Unsupported external resource at line 3.")
    }

    /// 誤検知防止（§4.1）。**コメントの中の import と include は拒否してはいけない。**
    /// 拒否すると、JSFX 作者が説明のために書いた 1 行で音が出なくなる。
    func testCommentedImportAndIncludeAreAccepted() throws {
        let host = try JSFX.load("comment_import")
        XCTAssertEqual(String(cString: ETJSFX_Name(host.raw)), "Comment Import")
    }

    /// **現仕様の可視化**（§4.1 の「要確認」）。
    /// forbiddenSource は `include(` を行内で探すので、文字列の中の `include(` も
    /// 拒否される。設計書はこれを誤検知の可能性として挙げていて、直すかどうかは
    /// 決まっていない。直したらこのテストが赤くなる＝そのとき判断すればよい。
    /// **通っている側（コメント）の testCommentedImportAndIncludeAreAccepted と
    /// 対で読むこと。**
    func testStringLiteralIncludeIsRejectedToday() throws {
        let result = try JSFX.open("string_include")
        XCTAssertNil(result.raw)
        XCTAssertTrue(result.message.hasPrefix("Unsupported include()"),
                      "unexpected message: \(result.message)")
    }

    // MARK: - 大きさの上限（§4.1 C14 / C20-C24）

    /// 上限を試す source は fixture にしない（1 MiB のファイルを置くことになる）。
    /// その場で作って、その場で消す。
    private func temporarySource(_ text: String) throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jsfx-limit-\(UUID().uuidString).jsfx")
        try Data(text.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    /// C14。1 MiB を超える source は読まずに断る。
    func testOversizedSourceRejected() throws {
        let path = try temporarySource(String(repeating: "a", count: 1024 * 1024 + 1))
        let result = JSFX.open(path: path)
        XCTAssertNil(result.raw)
        XCTAssertEqual(result.message, "JSFX source exceeds the 1 MB limit.")
    }

    /// C20。`data:` も外部資源。
    func testDataHeaderRejected() throws {
        let path = try temporarySource("desc:Data\ndata:0,blob\n\n@sample\n")
        let result = JSFX.open(path: path)
        XCTAssertNil(result.raw)
        XCTAssertEqual(result.message, "Unsupported external resource at line 2.")
    }

    /// C21。括弧の深さ。**どれも EEL2 を走らせる前に断る**ので、
    /// 解析器を深く潜らせて落とすことができない。
    func testDeepNestingRejected() throws {
        let path = try temporarySource("desc:Nested\n\n@init\nx = "
                                       + String(repeating: "(", count: 257) + "1"
                                       + String(repeating: ")", count: 257) + ";\n")
        let result = JSFX.open(path: path)
        XCTAssertNil(result.raw)
        XCTAssertEqual(result.message, "Source nesting exceeds 256 levels.")
    }

    /// C22。埋め込み EEL ブロック（`<?`）の数。
    func testTooManyInlineBlocksRejected() throws {
        let path = try temporarySource("desc:Inline\n\n@init\n"
                                       + String(repeating: "<?1?>\n", count: 1025))
        let result = JSFX.open(path: path)
        XCTAssertNil(result.raw)
        XCTAssertEqual(result.message, "Too many inline EEL blocks.")
    }

    /// C23。文字列 1 本の長さ。
    func testOversizedStringLiteralRejected() throws {
        let path = try temporarySource("desc:Literal\n\n@init\n#text = \""
                                       + String(repeating: "x", count: 64 * 1024 + 1) + "\";\n")
        let result = JSFX.open(path: path)
        XCTAssertNil(result.raw)
        XCTAssertEqual(result.message, "String literal exceeds the 64 KiB limit.")
    }

    /// C24。閉じていない文字列。
    func testUnterminatedStringRejected() throws {
        let path = try temporarySource("desc:Open\n\n@init\n#text = \"never closed;\n")
        let result = JSFX.open(path: path)
        XCTAssertNil(result.raw)
        XCTAssertEqual(result.message, "Unterminated string literal.")
    }
}
