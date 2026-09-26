//  JSFXSourceSyntaxTests.swift
//  ソース表示の行分けと色分け。**ホストもエンジンも要らない。**
//
//  色の範囲は行の中のUTF-8オフセットなので、期待値は字を数えて手で書く。

import XCTest
import Foundation

final class JSFXSourceSyntaxTests: XCTestCase {

    private func kinds(_ doc: JSFXSourceDocument, _ line: Int) -> [JSFXTokenKind] {
        doc.tokens[line].map(\.kind)
    }

    private func texts(_ doc: JSFXSourceDocument, _ line: Int) -> [String] {
        let bytes = Array(doc.lines[line].utf8)
        return doc.tokens[line].map { String(decoding: bytes[$0.range], as: UTF8.self) }
    }

    func testLinesSplitOnLFAndCRLFWithoutTrailingEmptyLine() {
        let doc = JSFXSourceDocument(source: "a\r\nb\n\nc\n")
        XCTAssertEqual(doc.lines, ["a", "b", "", "c"])
    }

    func testEmptySourceIsOneEmptyLine() {
        XCTAssertEqual(JSFXSourceDocument(source: "").lines, [""])
    }

    /// BOMが残ると1行目の`desc:`が読めない。
    func testDescSkipsBOM() {
        let doc = JSFXSourceDocument(source: "\u{FEFF}desc: My Gain\n@init\n")
        XCTAssertEqual(doc.desc, "My Gain")
        XCTAssertEqual(doc.lines[0], "desc: My Gain")
    }

    /// 既知の節だけを拾う。**節の頭の後ろ（`@gfx 400 300`）の数も色を付ける。**
    func testSectionsAreKnownNamesAtColumnZero() {
        let doc = JSFXSourceDocument(source: "desc:x\n@init\n@unknown\n  @sample\n@gfx 400 300\n")
        XCTAssertEqual(doc.sections.map(\.name), ["@init", "@gfx"])
        XCTAssertEqual(doc.sections.map(\.line), [1, 4])
        XCTAssertEqual(kinds(doc, 4), [.section, .number, .number])
        XCTAssertEqual(texts(doc, 4), ["@gfx", "400", "300"])
    }

    /// 頭の部分は説明の字を字句として読まない。`Don't`の`'`で文字列を始めない。
    func testHeaderColorsOnlySliderAndCommentLines() {
        let doc = JSFXSourceDocument(source: "desc:Don't 1 http://x\nslider12:0<-60,24,0.1>Gain\n// note\n@init\n")
        XCTAssertEqual(kinds(doc, 0), [])
        XCTAssertEqual(texts(doc, 1), ["slider12:"])
        XCTAssertEqual(kinds(doc, 2), [.comment])
    }

    func testCodeTokens() {
        let doc = JSFXSourceDocument(source: "@sample\nx1 = 0.5 * $pi + 0x1F; s = \"a\\\"b\"; // done\n")
        XCTAssertEqual(kinds(doc, 1), [.number, .number, .number, .string, .comment])
        XCTAssertEqual(texts(doc, 1), ["0.5", "$pi", "0x1F", "\"a\\\"b\"", "// done"])
    }

    /// `/* */`は行をまたぐ。節の頭で切れる。
    func testBlockCommentSpansLinesAndResetsAtSection() {
        let doc = JSFXSourceDocument(source: "@init\na = 1; /* one\ntwo\nthree */ b = 2;\n/* open\n@sample\nc = 3;\n")
        XCTAssertEqual(kinds(doc, 1), [.number, .comment])
        XCTAssertEqual(texts(doc, 2), ["two"])
        XCTAssertEqual(texts(doc, 3), ["three */", "2"])
        XCTAssertEqual(kinds(doc, 4), [.comment])
        XCTAssertEqual(kinds(doc, 6), [.number])
    }

    /// タブは4桁ごとに展開する。全角は2桁。
    func testTabsExpandAndWideColumnsCount() {
        let doc = JSFXSourceDocument(source: "@init\n\tx=1;\nab\tc\n// あい\n")
        XCTAssertEqual(doc.lines[1], "    x=1;")
        XCTAssertEqual(doc.lines[2], "ab  c")
        XCTAssertEqual(doc.maxColumns, 8)
        XCTAssertEqual(texts(doc, 3), ["// あい"])
    }

    func testLargeSourceSkipsHighlightingButKeepsSections() {
        let filler = String(repeating: "x = 1;\n", count: JSFXSourceDocument.highlightLimit / 7 + 1)
        let doc = JSFXSourceDocument(source: "desc:big\n@init\n" + filler + "@sample\n")
        XCTAssertFalse(doc.highlighted)
        XCTAssertTrue(doc.tokens.allSatisfy(\.isEmpty))
        XCTAssertEqual(doc.sections.map(\.name), ["@init", "@sample"])
        XCTAssertEqual(doc.desc, "big")
    }

    func testMatchingLinesIsCaseInsensitive() {
        let doc = JSFXSourceDocument(source: "desc:Gain\n@init\ngain = 1;\nx = 2;\n")
        XCTAssertEqual(doc.matchingLines("GAIN"), [0, 2])
        XCTAssertEqual(doc.matchingLines(""), [])
    }
}
