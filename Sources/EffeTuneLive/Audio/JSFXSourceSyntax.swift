//  JSFXSourceSyntax.swift
//  ソース表示の下ごしらえ。行分け・節・色分け・検索。
//  **Foundationだけ。**SwiftUIに触らないので実機なしで照合できる（JSFXSourceSyntaxTests）。
//
//  字句はバイト列で1回だけ舐める。**1 MBのスクリプトでも行をStringで
//  回さない**（Character単位は書記素の区切りを毎回計算するので遅い）。
//  語の一覧はREAPERのJSFXリファレンス（reaper.fm/sdk/js/）に合わせる。

import Foundation

enum JSFXTokenKind: Equatable, Hashable, Sendable, CaseIterable {
    /// 頭の部分（最初の節より前）。`desc:`と`My Gain`。
    case headerKey, headerValue
    /// `slider1:gain=0<-60,24,0.1:log>Gain`を部品ごとに。`<>`と`,`は区切り。
    case sliderKey, sliderVariable, sliderDefault, sliderRange, sliderEnum, sliderPath, sliderLabel
    case section
    case comment
    /// `"..."`・`'c'`と`$'c'`・`#name`と`#`。
    case string, character, stringName
    /// `0x1F` `1e-3` `$x1F` `$~7`と、`$pi` `$e` `$phi`。
    case number, constant
    case keyword
    /// リファレンスにある関数（`(`が続くときだけ）と特殊変数。
    case builtinFunction, builtinVariable
    /// `function`の直後の名前と、それ以外の`名前(`。
    case functionDefinition, functionCall
    case `operator`, punctuation
}

struct JSFXToken: Equatable, Sendable {
    let kind: JSFXTokenKind
    /// 行の中のUTF-8オフセット。
    let range: Range<Int>
}

/// 行をまたぐ字句。**節の頭で切る。**節は別々にコンパイルされる。
enum JSFXContinuation: Equatable, Sendable {
    case none, blockComment, string
}

struct JSFXSourceSection: Hashable, Sendable, Identifiable {
    /// `@init`など。
    let name: String
    /// 0始まりの行番号。
    let line: Int
    var id: Int { line }
}

struct JSFXSourceDocument: Sendable {
    /// **これを超えたら色を付けない。**行分けと節だけにする。
    static let highlightLimit = 256 * 1024
    static let tabWidth = 4
    static let sectionNames: Set<String> = ["@init", "@slider", "@block", "@sample", "@serialize", "@gfx"]

    /// タブは展開済み。改行は含まない。
    let lines: [String]
    /// 行ごとの色。色を付けないときは全部空。
    let tokens: [[JSFXToken]]
    let sections: [JSFXSourceSection]
    let desc: String?
    let highlighted: Bool
    /// 最も長い行の桁数。全角は2桁で数える。
    let maxColumns: Int

    init(source: String) {
        var bytes = Array(source.utf8)
        // BOMは見せない。1行目の`desc:`も読めなくなる。
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        let highlight = bytes.count <= Self.highlightLimit

        var lines: [String] = []
        var tokens: [[JSFXToken]] = []
        var sections: [JSFXSourceSection] = []
        var desc: String?
        var maxColumns = 0
        var inHeader = true
        var state = JSFXContinuation.none

        var start = 0
        while start <= bytes.count {
            // 末尾の改行の後ろに空の行を作らない。
            if start == bytes.count && start > 0 { break }
            var end = start
            while end < bytes.count && bytes[end] != 0x0A { end += 1 }
            var lineEnd = end
            if lineEnd > start && bytes[lineEnd - 1] == 0x0D { lineEnd -= 1 }
            let (line, columns) = Self.expandTabs(bytes[start..<lineEnd])
            let index = lines.count
            lines.append(String(decoding: line, as: UTF8.self))
            maxColumns = max(maxColumns, columns)

            var lineTokens: [JSFXToken] = []
            if let name = Self.sectionName(line) {
                inHeader = false
                state = .none
                sections.append(JSFXSourceSection(name: name, line: index))
                if highlight {
                    lineTokens.append(JSFXToken(kind: .section, range: 0..<name.utf8.count))
                    lineTokens += Self.codeTokens(line, from: name.utf8.count, state: &state)
                }
            } else if inHeader {
                if desc == nil, let d = Self.value(line, key: "desc:") { desc = d }
                if highlight { lineTokens = Self.headerTokens(line, state: &state) }
            } else if highlight {
                lineTokens = Self.codeTokens(line, from: 0, state: &state)
            }
            tokens.append(lineTokens)

            if end == bytes.count { break }
            start = end + 1
        }

        self.lines = lines
        self.tokens = tokens
        self.sections = sections
        self.desc = desc
        self.highlighted = highlight
        self.maxColumns = maxColumns
    }

    /// 字を含む行。大文字小文字は区別しない。
    func matchingLines(_ query: String) -> [Int] {
        guard !query.isEmpty else { return [] }
        var out: [Int] = []
        for (i, line) in lines.enumerated() where line.range(of: query, options: .caseInsensitive) != nil {
            out.append(i)
        }
        return out
    }

    // MARK: - 行

    private static func expandTabs(_ raw: ArraySlice<UInt8>) -> ([UInt8], Int) {
        var out: [UInt8] = []
        out.reserveCapacity(raw.count)
        var column = 0
        for b in raw {
            if b == 0x09 {
                let pad = tabWidth - column % tabWidth
                out.append(contentsOf: repeatElement(0x20, count: pad))
                column += pad
                continue
            }
            out.append(b)
            // 続きのバイトは数えない。3バイト以上の字（CJKなど）は2桁。
            if b & 0xC0 != 0x80 { column += b >= 0xE0 ? 2 : 1 }
        }
        return (out, column)
    }

    /// 1桁目の`@名前`が既知の節なら、その名前。
    private static func sectionName(_ line: [UInt8]) -> String? {
        guard line.first == UInt8(ascii: "@") else { return nil }
        var end = 1
        while end < line.count && isIdent(line[end]) { end += 1 }
        let name = String(decoding: line[0..<end], as: UTF8.self)
        return sectionNames.contains(name) ? name : nil
    }

    private static func value(_ line: [UInt8], key: String) -> String? {
        let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix(key) else { return nil }
        let v = text.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }

    // MARK: - 頭の部分

    /// `desc:`などの鍵。`import`だけは`:`を取らない。
    static let headerKeys: Set<String> = [
        "desc", "tags", "author", "version", "changelog", "about", "provides", "link", "screenshot",
        "donation", "metapackage", "noindex", "in_pin", "out_pin", "options", "filename", "config",
    ]

    /// 最初の節より前。鍵の行・`sliderN:`の宣言・注釈だけ。
    /// **説明の字（`Don't`やURL）をEEL2の字句として読まない。**
    private static func headerTokens(_ line: [UInt8], state: inout JSFXContinuation) -> [JSFXToken] {
        let n = line.count
        if state != .none {
            // 頭の部分に文字列は無い。残っているのは`/* */`だけ。
            guard let e = closeBlock(line, from: 0) else { return n > 0 ? [JSFXToken(kind: .comment, range: 0..<n)] : [] }
            state = .none
            return [JSFXToken(kind: .comment, range: 0..<e)]
        }
        var i = 0
        while i < n && line[i] == 0x20 { i += 1 }
        guard i < n else { return [] }
        if line[i] == UInt8(ascii: "/") && i + 1 < n {
            if line[i + 1] == UInt8(ascii: "/") { return [JSFXToken(kind: .comment, range: i..<n)] }
            if line[i + 1] == UInt8(ascii: "*") {
                if let e = closeBlock(line, from: i + 2) { return [JSFXToken(kind: .comment, range: i..<e)] }
                state = .blockComment
                return [JSFXToken(kind: .comment, range: i..<n)]
            }
        }
        var j = i
        while j < n && (isLetter(line[j]) || line[j] == UInt8(ascii: "_")) { j += 1 }
        let key = String(decoding: line[i..<j], as: UTF8.self).lowercased()
        if key == "slider" {
            var k = j
            while k < n && isDigit(line[k]) { k += 1 }
            if k > j && k < n && line[k] == UInt8(ascii: ":") { return sliderTokens(line, key: i..<(k + 1)) }
            return []
        }
        if key == "import" && (j == n || line[j] == 0x20) {
            return [JSFXToken(kind: .headerKey, range: i..<j)] + headerValue(line, from: j)
        }
        if j < n && line[j] == UInt8(ascii: ":") && headerKeys.contains(key) {
            return [JSFXToken(kind: .headerKey, range: i..<(j + 1))] + headerValue(line, from: j + 1)
        }
        return []
    }

    private static func headerValue(_ line: [UInt8], from start: Int) -> [JSFXToken] {
        let r = trimmed(line, start..<line.count)
        return r.isEmpty ? [] : [JSFXToken(kind: .headerValue, range: r)]
    }

    /// `sliderN:[名前=]既定値[<最小,最大,刻み[:log=中央]{項目,...}>]ラベル`と、
    /// `sliderN:/フォルダ:既定値:ラベル`。
    private static func sliderTokens(_ b: [UInt8], key: Range<Int>) -> [JSFXToken] {
        let n = b.count
        var out = [JSFXToken(kind: .sliderKey, range: key)]
        func add(_ kind: JSFXTokenKind, _ r: Range<Int>) {
            let t = trimmed(b, r)
            if !t.isEmpty { out.append(JSFXToken(kind: kind, range: t)) }
        }
        var p = key.upperBound
        while p < n && b[p] == 0x20 { p += 1 }

        // 名前付き（`gain=0`）。
        if p < n && isIdentStart(b[p]) && b[p] != UInt8(ascii: "#") {
            var q = p
            while q < n && isWord(b[q]) { q += 1 }
            if q < n && b[q] == UInt8(ascii: "=") {
                add(.sliderVariable, p..<q)
                add(.punctuation, q..<(q + 1))
                p = q + 1
            }
        }

        // ファイルを選ぶ形。
        if p < n && b[p] == UInt8(ascii: "/") {
            var q = p
            while q < n && b[q] != UInt8(ascii: ":") { q += 1 }
            add(.sliderPath, p..<q)
            guard q < n else { return out }
            add(.punctuation, q..<(q + 1))
            var r = q + 1
            while r < n && b[r] != UInt8(ascii: ":") { r += 1 }
            add(.sliderDefault, (q + 1)..<r)
            guard r < n else { return out }
            add(.punctuation, r..<(r + 1))
            add(.sliderLabel, (r + 1)..<n)
            return out
        }

        var q = p
        while q < n && isSliderNumber(b[q]) { q += 1 }
        add(.sliderDefault, p..<q)
        p = q

        if p < n && b[p] == UInt8(ascii: "<") {
            add(.punctuation, p..<(p + 1))
            p += 1
            var inEnum = false
            var run = p
            var closed = false
            while p < n {
                let c = b[p]
                let isSeparator: Bool
                if inEnum {
                    isSeparator = c == UInt8(ascii: ",") || c == UInt8(ascii: "}")
                } else {
                    isSeparator = c == UInt8(ascii: ",") || c == UInt8(ascii: ":") || c == UInt8(ascii: "=")
                        || c == UInt8(ascii: "{") || c == UInt8(ascii: ">")
                }
                guard isSeparator else { p += 1; continue }
                add(inEnum ? .sliderEnum : .sliderRange, run..<p)
                add(.punctuation, p..<(p + 1))
                if c == UInt8(ascii: "{") { inEnum = true }
                if c == UInt8(ascii: "}") { inEnum = false }
                p += 1
                run = p
                if c == UInt8(ascii: ">") && !inEnum { closed = true; break }
            }
            if !closed {
                add(inEnum ? .sliderEnum : .sliderRange, run..<n)
                return out
            }
        }
        add(.sliderLabel, p..<n)
        return out
    }

    // MARK: - EEL2

    static let keywords: Set<String> = [
        "function", "local", "static", "instance", "global", "globals", "this", "_global", "loop", "while",
    ]

    static let builtinFunctions: Set<String> = [
        // 数学
        "sin", "cos", "tan", "asin", "acos", "atan", "atan2", "sqr", "sqrt", "pow", "exp", "log", "log10",
        "abs", "min", "max", "sign", "rand", "floor", "ceil", "invsqrt",
        // 時刻
        "time", "time_precise",
        // FFT・MDCT・畳み込み
        "mdct", "imdct", "fft", "ifft", "fft_real", "ifft_real", "fft_permute", "fft_ipermute", "convolve_c",
        // メモリ・スタック・アトミック
        "freembuf", "memcpy", "memset", "mem_set_values", "mem_get_values", "mem_multiply_sum",
        "mem_insert_shuffle", "__memtop", "stack_push", "stack_pop", "stack_peek", "stack_exch",
        "atomic_setifequal", "atomic_exch", "atomic_add", "atomic_set", "atomic_get",
        // スライダー・ピン・ホスト
        "spl", "slider", "slider_next_chg", "sliderchange", "slider_automate", "slider_show",
        "export_buffer_to_project", "get_host_numchan", "set_host_numchan", "get_pin_mapping",
        "set_pin_mapping", "get_pinmapper_flags", "set_pinmapper_flags", "get_host_placement",
        // 文字列
        "strlen", "strcpy", "strcat", "strcmp", "stricmp", "strncmp", "strnicmp", "strncpy", "strncat",
        "strcpy_from", "strcpy_substr", "str_getchar", "str_setchar", "strcpy_fromslider", "sprintf",
        "match", "matchi",
        // MIDI
        "midisend", "midisend_buf", "midisend_str", "midirecv", "midirecv_buf", "midirecv_str", "midisyx",
        // ファイル
        "file_open", "file_close", "file_rewind", "file_var", "file_mem", "file_avail", "file_riff",
        "file_text", "file_string",
        // 描画
        "gfx_set", "gfx_lineto", "gfx_line", "gfx_rectto", "gfx_rect", "gfx_setpixel", "gfx_getpixel",
        "gfx_drawnumber", "gfx_drawchar", "gfx_drawstr", "gfx_measurestr", "gfx_setfont", "gfx_getfont",
        "gfx_printf", "gfx_blurto", "gfx_blit", "gfx_blitext", "gfx_getimgdim", "gfx_setimgdim",
        "gfx_loadimg", "gfx_gradrect", "gfx_muladdrect", "gfx_deltablit", "gfx_transformblit", "gfx_circle",
        "gfx_roundrect", "gfx_arc", "gfx_triangle", "gfx_getchar", "gfx_showmenu", "gfx_setcursor",
    ]

    static let builtinVariables: Set<String> = [
        "srate", "num_ch", "samplesblock", "tempo", "play_state", "play_position", "beat_position",
        "ts_num", "ts_denom", "trigger", "pdc_delay", "pdc_bot_ch", "pdc_top_ch", "pdc_midi", "midi_bus",
        "gmem", "mouse_x", "mouse_y", "mouse_cap", "mouse_wheel", "mouse_hwheel",
    ]

    /// `spl0`〜`spl63`・`slider1`〜`slider256`・`reg00`〜`reg99`・`ext_*`・`gfx_*`。
    static func isBuiltinVariable(_ name: String) -> Bool {
        if builtinVariables.contains(name) || name.hasPrefix("ext_") || name.hasPrefix("gfx_") { return true }
        func number(after prefix: String) -> Int? {
            guard name.hasPrefix(prefix) else { return nil }
            let digits = name.dropFirst(prefix.count)
            guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), digits.count <= 3 else { return nil }
            return Int(digits)
        }
        if let v = number(after: "spl"), v <= 63 { return true }
        if let v = number(after: "slider"), (1...256).contains(v) { return true }
        if let v = number(after: "reg"), name.count == 5, v <= 99 { return true }
        return false
    }

    /// 長いものから。`===`を`==`と`=`に割らない。
    private static let operators: [[UInt8]] = [
        "===", "!==", "==", "!=", "<=", ">=", "&&", "||", "<<", ">>",
        "+=", "-=", "*=", "/=", "%=", "^=", "|=", "&=", "~=",
        "=", "<", ">", "!", "?", ":", "+", "-", "*", "/", "%", "^", "|", "&", "~",
    ].map { Array($0.utf8) }

    /// EEL2の本体。`state`は行をまたぐ`/* */`と`"..."`。
    static func codeTokens(_ b: [UInt8], from start: Int, state: inout JSFXContinuation) -> [JSFXToken] {
        let n = b.count
        var out: [JSFXToken] = []
        func add(_ kind: JSFXTokenKind, _ r: Range<Int>) { out.append(JSFXToken(kind: kind, range: r)) }
        var i = start

        switch state {
        case .blockComment:
            guard let e = closeBlock(b, from: i) else {
                if i < n { add(.comment, i..<n) }
                return out
            }
            add(.comment, i..<e)
            state = .none
            i = e
        case .string:
            let (e, closed) = scanQuoted(b, from: i, quote: UInt8(ascii: "\""))
            if e > i { add(.string, i..<e) }
            guard closed else { return out }
            state = .none
            i = e
        case .none:
            break
        }

        var expectFunctionName = false
        while i < n {
            let c = b[i]
            let next: UInt8 = i + 1 < n ? b[i + 1] : 0
            if c == 0x20 { i += 1; continue }
            if !isIdentStart(c) { expectFunctionName = false }

            if c == UInt8(ascii: "/") && next == UInt8(ascii: "/") {
                add(.comment, i..<n)
                break
            }
            if c == UInt8(ascii: "/") && next == UInt8(ascii: "*") {
                guard let e = closeBlock(b, from: i + 2) else {
                    add(.comment, i..<n)
                    state = .blockComment
                    break
                }
                add(.comment, i..<e)
                i = e
                continue
            }
            // **文字列は行をまたげる**（リファレンスに明記）。
            if c == UInt8(ascii: "\"") {
                let (e, closed) = scanQuoted(b, from: i + 1, quote: c)
                add(.string, i..<e)
                if !closed { state = .string; break }
                i = e
                continue
            }
            // `'c'`は数。4字まで。行はまたがない。
            if c == UInt8(ascii: "'") {
                let (e, _) = scanQuoted(b, from: i + 1, quote: c)
                add(.character, i..<e)
                i = e
                continue
            }
            if isDigit(c) || (c == UInt8(ascii: ".") && isDigit(next)) {
                let e = scanNumber(b, from: i)
                add(.number, i..<e)
                i = e
                continue
            }
            if c == UInt8(ascii: "$") {
                if next == UInt8(ascii: "'") {
                    let (e, _) = scanQuoted(b, from: i + 2, quote: next)
                    add(.character, i..<e)
                    i = e
                    continue
                }
                if next == UInt8(ascii: "~") {
                    var e = i + 2
                    while e < n && isDigit(b[e]) { e += 1 }
                    add(.number, i..<e)
                    i = e
                    continue
                }
                var e = i + 1
                while e < n && isWord(b[e]) { e += 1 }
                let name = String(decoding: b[(i + 1)..<e], as: UTF8.self).lowercased()
                if name == "pi" || name == "e" || name == "phi" {
                    add(.constant, i..<e)
                } else if name.count > 1 && name.first == "x" && name.dropFirst().allSatisfy(\.isHexDigit) {
                    add(.number, i..<e)
                }
                i = max(e, i + 1)
                continue
            }
            // **名前は丸ごと読む。**`x1`や`this.y2`の数字を数として拾わない。
            if isIdentStart(c) {
                var e = i
                while e < n && isIdent(b[e]) { e += 1 }
                classifyName(b, i..<e, expectFunctionName: &expectFunctionName, into: &out)
                i = e
                continue
            }
            if let op = operators.first(where: { b[i...].starts(with: $0) }) {
                add(.operator, i..<(i + op.count))
                i += op.count
                continue
            }
            if isPunctuation(c) { add(.punctuation, i..<(i + 1)) }
            i += 1
        }
        return out
    }

    /// **EEL2の名前は大文字小文字を区別しない。**`SIN(`も`Spl0`も同じ。
    private static func classifyName(_ b: [UInt8], _ r: Range<Int>, expectFunctionName: inout Bool,
                                     into out: inout [JSFXToken]) {
        func add(_ kind: JSFXTokenKind, _ r: Range<Int>) { out.append(JSFXToken(kind: kind, range: r)) }
        if expectFunctionName {
            expectFunctionName = false
            add(.functionDefinition, r)
            return
        }
        if b[r.lowerBound] == UInt8(ascii: "#") {
            add(.stringName, r)
            return
        }
        let name = String(decoding: b[r], as: UTF8.self).lowercased()
        let calls = nextNonSpace(b, from: r.upperBound) == UInt8(ascii: "(")
        if keywords.contains(name) {
            add(.keyword, r)
            expectFunctionName = name == "function"
            return
        }
        // `this.x` `this..x` `_global.x`は頭だけ語。
        if let dot = b[r].firstIndex(of: UInt8(ascii: ".")), dot > r.lowerBound,
           keywords.contains(String(decoding: b[r.lowerBound..<dot], as: UTF8.self).lowercased()) {
            add(.keyword, r.lowerBound..<dot)
            var rest = dot
            while rest < r.upperBound && b[rest] == UInt8(ascii: ".") { rest += 1 }
            if calls && rest < r.upperBound { add(.functionCall, rest..<r.upperBound) }
            return
        }
        if calls {
            // **組み込み関数は`(`が付いたときだけ。**`min`や`match`は変数名にもよく使う。
            let builtin = builtinFunctions.contains(name) || name.hasPrefix("gfx_") || name.hasPrefix("file_")
            add(builtin ? .builtinFunction : .functionCall, r)
        } else if isBuiltinVariable(name) {
            add(.builtinVariable, r)
        }
    }

    // MARK: - 下請け

    private static func closeBlock(_ b: [UInt8], from j: Int) -> Int? {
        var k = j
        while k + 1 < b.count {
            if b[k] == UInt8(ascii: "*") && b[k + 1] == UInt8(ascii: "/") { return k + 2 }
            k += 1
        }
        return nil
    }

    /// 閉じの後ろの位置と、閉じたかどうか。`\`は次の字を飛ばす。
    private static func scanQuoted(_ b: [UInt8], from j: Int, quote: UInt8) -> (Int, Bool) {
        var k = j
        while k < b.count {
            if b[k] == UInt8(ascii: "\\") { k += 2; continue }
            if b[k] == quote { return (k + 1, true) }
            k += 1
        }
        return (b.count, false)
    }

    private static func scanNumber(_ b: [UInt8], from i: Int) -> Int {
        let n = b.count
        var j = i
        if b[i] == UInt8(ascii: "0") && i + 1 < n && (b[i + 1] | 0x20) == UInt8(ascii: "x") {
            j = i + 2
            while j < n && isHex(b[j]) { j += 1 }
            return j
        }
        while j < n && (isDigit(b[j]) || b[j] == UInt8(ascii: ".")) { j += 1 }
        if j < n && (b[j] | 0x20) == UInt8(ascii: "e") {
            var k = j + 1
            if k < n && (b[k] == UInt8(ascii: "+") || b[k] == UInt8(ascii: "-")) { k += 1 }
            if k < n && isDigit(b[k]) {
                j = k
                while j < n && isDigit(b[j]) { j += 1 }
            }
        }
        return j
    }

    private static func nextNonSpace(_ b: [UInt8], from i: Int) -> UInt8? {
        var k = i
        while k < b.count && b[k] == 0x20 { k += 1 }
        return k < b.count ? b[k] : nil
    }

    private static func trimmed(_ b: [UInt8], _ r: Range<Int>) -> Range<Int> {
        var lo = r.lowerBound, hi = r.upperBound
        while lo < hi && b[lo] == 0x20 { lo += 1 }
        while hi > lo && b[hi - 1] == 0x20 { hi -= 1 }
        return lo..<hi
    }

    private static func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
    private static func isLetter(_ c: UInt8) -> Bool { (c | 0x20) >= 0x61 && (c | 0x20) <= 0x7A }
    private static func isHex(_ c: UInt8) -> Bool { isDigit(c) || ((c | 0x20) >= 0x61 && (c | 0x20) <= 0x66) }
    private static func isWord(_ c: UInt8) -> Bool { isDigit(c) || isLetter(c) || c == UInt8(ascii: "_") }
    private static func isIdentStart(_ c: UInt8) -> Bool {
        isLetter(c) || c == UInt8(ascii: "_") || c == UInt8(ascii: "#") || c >= 0x80
    }
    private static func isIdent(_ c: UInt8) -> Bool {
        isWord(c) || c == UInt8(ascii: ".") || c == UInt8(ascii: "#") || c >= 0x80
    }
    private static func isPunctuation(_ c: UInt8) -> Bool {
        switch c {
        case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "["), UInt8(ascii: "]"),
             UInt8(ascii: "{"), UInt8(ascii: "}"), UInt8(ascii: ","), UInt8(ascii: ";"), UInt8(ascii: "."):
            return true
        default:
            return false
        }
    }
    private static func isSliderNumber(_ c: UInt8) -> Bool {
        isDigit(c) || c == UInt8(ascii: ".") || c == UInt8(ascii: "-") || c == UInt8(ascii: "+")
            || (c | 0x20) == UInt8(ascii: "e")
    }
}
