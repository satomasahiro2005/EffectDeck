//  JSFXSourceSyntaxTests.swift
//  ソース表示の行分けと色分け。**ホストもエンジンも要らない。**
//
//  色の範囲は行の中のUTF-8オフセット。期待値は字句の字と種類の組で書く。

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

    /// 字と種類の組。**演算子と区切りは落とす**（別の照合で見る）。
    private func pairs(_ doc: JSFXSourceDocument, _ line: Int, keepMuted: Bool = false) -> [Pair] {
        zip(texts(doc, line), kinds(doc, line))
            .filter { keepMuted || ($0.1 != .operator && $0.1 != .punctuation) }
            .map { Pair($0.0, $0.1) }
    }

    /// 1行だけのコード。`@init`の次の行として読む。
    private func code(_ line: String, keepMuted: Bool = false) -> [Pair] {
        pairs(JSFXSourceDocument(source: "@init\n" + line + "\n"), 1, keepMuted: keepMuted)
    }

    private func header(_ line: String, keepMuted: Bool = true) -> [Pair] {
        pairs(JSFXSourceDocument(source: line + "\n@init\n"), 0, keepMuted: keepMuted)
    }

    struct Pair: Equatable, CustomStringConvertible {
        let text: String
        let kind: JSFXTokenKind
        init(_ text: String, _ kind: JSFXTokenKind) { self.text = text; self.kind = kind }
        var description: String { "\(kind)(\(text))" }
    }

    // MARK: - 行

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

    /// 字句の範囲は昇順で重ならない。表示側はこれを前提に区間を繋ぐ。
    func testTokensAreOrderedAndDisjoint() {
        let src = """
        desc:Test
        slider1:gain=0<-60,24,0.1:log=0{a,b}>Gain
        @init
        function f(x) local(y) ( y = x * $pi; #s = "a//b"; 'ab' ~= 0x1F; /* c */ gfx_r = spl0 >= 1e-3; );
        """
        let doc = JSFXSourceDocument(source: src)
        for (i, line) in doc.tokens.enumerated() {
            var pos = 0
            for t in line {
                XCTAssertGreaterThanOrEqual(t.range.lowerBound, pos, "line \(i)")
                XCTAssertLessThan(t.range.lowerBound, t.range.upperBound, "line \(i)")
                XCTAssertLessThanOrEqual(t.range.upperBound, doc.lines[i].utf8.count, "line \(i)")
                pos = t.range.upperBound
            }
        }
    }

    // MARK: - 節

    /// 既知の節だけを拾う。**節の頭の後ろ（`@gfx 400 300`）の数も色を付ける。**
    func testSectionsAreKnownNamesAtColumnZero() {
        let doc = JSFXSourceDocument(source: "desc:x\n@init\n@unknown\n  @sample\n@gfx 400 300\n")
        XCTAssertEqual(doc.sections.map(\.name), ["@init", "@gfx"])
        XCTAssertEqual(doc.sections.map(\.line), [1, 4])
        XCTAssertEqual(pairs(doc, 4), [Pair("@gfx", .section), Pair("400", .number), Pair("300", .number)])
    }

    // MARK: - 頭の部分

    func testHeaderKeysAndValues() {
        XCTAssertEqual(header("desc: My Gain "), [Pair("desc:", .headerKey), Pair("My Gain", .headerValue)])
        XCTAssertEqual(header("tags:utility gain"), [Pair("tags:", .headerKey), Pair("utility gain", .headerValue)])
        XCTAssertEqual(header("in_pin:left input"), [Pair("in_pin:", .headerKey), Pair("left input", .headerValue)])
        XCTAssertEqual(header("out_pin:none"), [Pair("out_pin:", .headerKey), Pair("none", .headerValue)])
        XCTAssertEqual(header("options:gmem=foo want_all_kb"),
                       [Pair("options:", .headerKey), Pair("gmem=foo want_all_kb", .headerValue)])
        XCTAssertEqual(header("filename:0,img/knob.png"),
                       [Pair("filename:", .headerKey), Pair("0,img/knob.png", .headerValue)])
        XCTAssertEqual(header("author: someone"), [Pair("author:", .headerKey), Pair("someone", .headerValue)])
        XCTAssertEqual(header("version: 1.2"), [Pair("version:", .headerKey), Pair("1.2", .headerValue)])
        XCTAssertEqual(header("provides: lib/*.jsfx-inc"),
                       [Pair("provides:", .headerKey), Pair("lib/*.jsfx-inc", .headerValue)])
        XCTAssertEqual(header("import cookdsp.jsfx-inc"),
                       [Pair("import", .headerKey), Pair("cookdsp.jsfx-inc", .headerValue)])
        XCTAssertEqual(header("desc:"), [Pair("desc:", .headerKey)])
    }

    /// 頭の部分は説明の字を字句として読まない。`Don't`の`'`で文字列を始めない。
    func testHeaderFreeTextIsNotCode() {
        let doc = JSFXSourceDocument(source: "desc:Don't 1 http://x\nThis is free text (1 + 2)\nfoo: bar\nimporter x\n@init\n")
        XCTAssertEqual(pairs(doc, 0), [Pair("desc:", .headerKey), Pair("Don't 1 http://x", .headerValue)])
        XCTAssertEqual(kinds(doc, 1), [])
        XCTAssertEqual(kinds(doc, 2), [])
        XCTAssertEqual(kinds(doc, 3), [])
    }

    func testHeaderComments() {
        let doc = JSFXSourceDocument(source: "// note\n/* one\ntwo */\n/* a */\ndesc:x\n@init\n")
        XCTAssertEqual(pairs(doc, 0), [Pair("// note", .comment)])
        XCTAssertEqual(pairs(doc, 1), [Pair("/* one", .comment)])
        XCTAssertEqual(pairs(doc, 2), [Pair("two */", .comment)])
        XCTAssertEqual(pairs(doc, 3), [Pair("/* a */", .comment)])
        XCTAssertEqual(pairs(doc, 4), [Pair("desc:", .headerKey), Pair("x", .headerValue)])
    }

    // MARK: - スライダー

    func testSliderRangeAndLabel() {
        XCTAssertEqual(header("slider12:0<-60,24,0.1>Gain (dB)"), [
            Pair("slider12:", .sliderKey), Pair("0", .sliderDefault),
            Pair("<", .punctuation), Pair("-60", .sliderRange), Pair(",", .punctuation),
            Pair("24", .sliderRange), Pair(",", .punctuation), Pair("0.1", .sliderRange), Pair(">", .punctuation),
            Pair("Gain (dB)", .sliderLabel),
        ])
    }

    func testSliderEnumList() {
        XCTAssertEqual(header("slider1:0<0,2,1{Low, Mid,High}>Mode"), [
            Pair("slider1:", .sliderKey), Pair("0", .sliderDefault),
            Pair("<", .punctuation), Pair("0", .sliderRange), Pair(",", .punctuation), Pair("2", .sliderRange),
            Pair(",", .punctuation), Pair("1", .sliderRange), Pair("{", .punctuation),
            Pair("Low", .sliderEnum), Pair(",", .punctuation), Pair("Mid", .sliderEnum), Pair(",", .punctuation),
            Pair("High", .sliderEnum), Pair("}", .punctuation), Pair(">", .punctuation),
            Pair("Mode", .sliderLabel),
        ])
    }

    /// 名前付き・曲線（`:log=100`）・隠し（`-`）。
    func testSliderVariableShapeAndHiddenLabel() {
        XCTAssertEqual(header("slider2:freq=1000<20,20000,1:log=100>-Freq"), [
            Pair("slider2:", .sliderKey), Pair("freq", .sliderVariable), Pair("=", .punctuation),
            Pair("1000", .sliderDefault), Pair("<", .punctuation), Pair("20", .sliderRange), Pair(",", .punctuation),
            Pair("20000", .sliderRange), Pair(",", .punctuation), Pair("1", .sliderRange), Pair(":", .punctuation),
            Pair("log", .sliderRange), Pair("=", .punctuation), Pair("100", .sliderRange), Pair(">", .punctuation),
            Pair("-Freq", .sliderLabel),
        ])
    }

    func testSliderFileForm() {
        XCTAssertEqual(header("slider3:/impulses:none.wav:Impulse"), [
            Pair("slider3:", .sliderKey), Pair("/impulses", .sliderPath), Pair(":", .punctuation),
            Pair("none.wav", .sliderDefault), Pair(":", .punctuation), Pair("Impulse", .sliderLabel),
        ])
    }

    func testSliderWithoutRangeAndUnterminated() {
        XCTAssertEqual(header("slider4:1.5e-3 Time"),
                       [Pair("slider4:", .sliderKey), Pair("1.5e-3", .sliderDefault), Pair("Time", .sliderLabel)])
        XCTAssertEqual(header("slider5:0<0,1"), [
            Pair("slider5:", .sliderKey), Pair("0", .sliderDefault), Pair("<", .punctuation),
            Pair("0", .sliderRange), Pair(",", .punctuation), Pair("1", .sliderRange),
        ])
        XCTAssertEqual(header("sliderX:0<0,1>No"), [])
    }

    // MARK: - 注釈

    func testLineAndBlockComments() {
        XCTAssertEqual(code("x = 1; // done"), [Pair("1", .number), Pair("// done", .comment)])
        XCTAssertEqual(code("a /* b */ c"), [Pair("/* b */", .comment)])
    }

    /// `/* */`は行をまたぐ。節の頭で切れる。
    func testBlockCommentSpansLinesAndResetsAtSection() {
        let doc = JSFXSourceDocument(source: "@init\na = 1; /* one\ntwo\nthree */ b = 2;\n/* open\n@sample\nc = 3;\n")
        XCTAssertEqual(pairs(doc, 1), [Pair("1", .number), Pair("/* one", .comment)])
        XCTAssertEqual(pairs(doc, 2), [Pair("two", .comment)])
        XCTAssertEqual(pairs(doc, 3), [Pair("three */", .comment), Pair("2", .number)])
        XCTAssertEqual(pairs(doc, 4), [Pair("/* open", .comment)])
        XCTAssertEqual(pairs(doc, 6), [Pair("3", .number)])
    }

    /// 注釈の中の`"`で文字列を始めない。
    func testQuoteInsideCommentDoesNotOpenString() {
        let doc = JSFXSourceDocument(source: "@init\n/* don't \"x\n*/ y = 1;\n")
        XCTAssertEqual(pairs(doc, 2), [Pair("*/", .comment), Pair("1", .number)])
    }

    // MARK: - 文字列

    /// 文字列の中の`//`と`/*`は注釈にしない。`\"`で閉じない。
    func testStringsContainingCommentMarkers() {
        XCTAssertEqual(code(#"s = "http://x /* y"; z = 1;"#),
                       [Pair(#""http://x /* y""#, .string), Pair("1", .number)])
        XCTAssertEqual(code(#"s = "a\"b"; // c"#), [Pair(#""a\"b""#, .string), Pair("// c", .comment)])
    }

    /// 文字列は行をまたげる（リファレンスに明記）。節の頭で切れる。
    func testStringSpansLines() {
        let doc = JSFXSourceDocument(source: "@init\ns = \"one\ntwo // not\nthree\"; x = 2;\ns2 = \"open\n@sample\ny = 3;\n")
        XCTAssertEqual(pairs(doc, 1), [Pair("\"one", .string)])
        XCTAssertEqual(pairs(doc, 2), [Pair("two // not", .string)])
        XCTAssertEqual(pairs(doc, 3), [Pair("three\"", .string), Pair("2", .number)])
        XCTAssertEqual(pairs(doc, 6), [Pair("3", .number)])
    }

    func testCharacterConstants() {
        XCTAssertEqual(code("c = 'A'; m = 'abcd'; q = '\\''; d = $'z';"), [
            Pair("'A'", .character), Pair("'abcd'", .character), Pair("'\\''", .character), Pair("$'z'", .character),
        ])
    }

    func testStringNames() {
        XCTAssertEqual(code(#"#name = "x"; strcpy(#, #name);"#), [
            Pair("#name", .stringName), Pair(#""x""#, .string), Pair("strcpy", .builtinFunction),
            Pair("#", .stringName), Pair("#name", .stringName),
        ])
    }

    // MARK: - 数

    func testNumbers() {
        XCTAssertEqual(code("a = 0.5 + .25 + 10 + 1e-3 + 2.5E+10 + 0x1F + 0XfF;"), [
            Pair("0.5", .number), Pair(".25", .number), Pair("10", .number), Pair("1e-3", .number),
            Pair("2.5E+10", .number), Pair("0x1F", .number), Pair("0XfF", .number),
        ])
    }

    func testDollarConstants() {
        XCTAssertEqual(code("a = $pi * $E + $phi + $x1F + $~7 + $foo;"), [
            Pair("$pi", .constant), Pair("$E", .constant), Pair("$phi", .constant),
            Pair("$x1F", .number), Pair("$~7", .number),
        ])
    }

    /// **名前の中の数字は数ではない。**
    func testDigitsInsideNamesAreNotNumbers() {
        XCTAssertEqual(code("x1 = this.y2 + a.b3;"), [Pair("this", .keyword)])
    }

    // MARK: - 語

    func testKeywords() {
        XCTAssertEqual(code("loop(4, i += 1); while(x > 0) (x -= 1);"),
                       [Pair("loop", .keyword), Pair("4", .number), Pair("1", .number),
                        Pair("while", .keyword), Pair("0", .number), Pair("1", .number)])
        XCTAssertEqual(code("function f() local(a) static(b) instance(c) globals(d) global(e) ( this.a = _global.x; );"), [
            Pair("function", .keyword), Pair("f", .functionDefinition), Pair("local", .keyword),
            Pair("static", .keyword), Pair("instance", .keyword), Pair("globals", .keyword), Pair("global", .keyword),
            Pair("this", .keyword), Pair("_global", .keyword),
        ])
    }

    /// EEL2の名前は大文字小文字を区別しない。
    func testNamesAreCaseInsensitive() {
        XCTAssertEqual(code("LOOP(2, SIN(Spl0));"),
                       [Pair("LOOP", .keyword), Pair("2", .number), Pair("SIN", .builtinFunction), Pair("Spl0", .builtinVariable)])
    }

    func testFunctionDefinitionAndCalls() {
        XCTAssertEqual(code("function lpf.init(f) ( this.a = f; );"),
                       [Pair("function", .keyword), Pair("lpf.init", .functionDefinition), Pair("this", .keyword)])
        XCTAssertEqual(code("lp.init(1000); this.tick (x); mine();"), [
            Pair("lp.init", .functionCall), Pair("1000", .number), Pair("this", .keyword), Pair("tick", .functionCall),
            Pair("mine", .functionCall),
        ])
    }

    /// **組み込み関数は`(`が付いたときだけ。**`min`や`match`は変数名にもよく使う。
    func testBuiltinFunctions() {
        let names = ["sin", "cos", "tan", "asin", "acos", "atan", "atan2", "sqr", "sqrt", "pow", "exp", "log", "log10",
                     "abs", "min", "max", "sign", "rand", "floor", "ceil", "invsqrt", "memset", "memcpy", "freembuf",
                     "mem_get_values", "mem_set_values", "stack_push", "stack_pop", "strlen", "strcpy", "strcat",
                     "sprintf", "match", "matchi", "midirecv", "midisend", "midisend_buf", "file_open", "file_var",
                     "gfx_rect", "gfx_drawstr", "gfx_measurestr", "spl", "slider", "sliderchange", "slider_automate",
                     "fft", "convolve_c", "time_precise", "__memtop"]
        for name in names {
            XCTAssertEqual(code("x = \(name)(1);"), [Pair(name, .builtinFunction), Pair("1", .number)], name)
        }
        XCTAssertEqual(code("min = max + match;"), [])
    }

    func testBuiltinVariables() {
        let names = ["spl0", "spl63", "srate", "samplesblock", "tempo", "play_state", "play_position", "beat_position",
                     "num_ch", "pdc_delay", "pdc_bot_ch", "pdc_top_ch", "ext_noinit", "ext_tail_size", "slider1",
                     "slider256", "trigger", "ts_num", "ts_denom", "mouse_x", "mouse_y", "mouse_cap", "mouse_wheel",
                     "gfx_r", "gfx_w", "gfx_x", "gfx_texth", "gmem", "reg00", "reg99", "midi_bus"]
        for name in names {
            XCTAssertEqual(code("\(name) = 1;"), [Pair(name, .builtinVariable), Pair("1", .number)], name)
        }
        for name in ["spl64", "slider0", "slider257", "reg100", "splx", "gain"] {
            XCTAssertEqual(code("\(name) = 1;"), [Pair("1", .number)], name)
        }
    }

    // MARK: - 演算子

    func testOperatorsAreGreedy() {
        let ops = ["=", "==", "===", "!=", "!==", "<", ">", "<=", ">=", "&&", "||", "<<", ">>", "+", "-", "*", "/",
                   "%", "^", "|", "&", "~", "+=", "-=", "*=", "/=", "%=", "^=", "|=", "&=", "~="]
        for op in ops {
            XCTAssertEqual(code("a \(op) b", keepMuted: true), [Pair(op, .operator)], op)
        }
        XCTAssertEqual(code("!a ? b : c", keepMuted: true),
                       [Pair("!", .operator), Pair("?", .operator), Pair(":", .operator)])
    }

    func testPunctuation() {
        XCTAssertEqual(code("buf[i] = (a, b);", keepMuted: true), [
            Pair("[", .punctuation), Pair("]", .punctuation), Pair("=", .operator), Pair("(", .punctuation),
            Pair(",", .punctuation), Pair(")", .punctuation), Pair(";", .punctuation),
        ])
    }

    /// 普通の名前には色を付けない。
    func testPlainNamesStayUncolored() {
        XCTAssertEqual(code("gain = level;", keepMuted: true), [Pair("=", .operator), Pair(";", .punctuation)])
    }
}
