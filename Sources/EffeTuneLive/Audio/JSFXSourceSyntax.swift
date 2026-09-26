//  JSFXSourceSyntax.swift
//  ソース表示の下ごしらえ。行分け・節・色分け・検索。
//  **Foundationだけ。**SwiftUIに触らないので実機なしで照合できる（JSFXSourceSyntaxTests）。
//
//  字句はバイト列で1回だけ舐める。**1 MBのスクリプトでも行をStringで
//  回さない**（Character単位は書記素の区切りを毎回計算するので遅い）。

import Foundation

enum JSFXTokenKind: Equatable, Sendable {
    case section, slider, comment, string, number
}

struct JSFXToken: Equatable, Sendable {
    let kind: JSFXTokenKind
    /// 行の中のUTF-8オフセット。
    let range: Range<Int>
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
        var inBlock = false

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
                // **節の頭で注釈の状態を切る。**節は別々にコンパイルされる。
                inHeader = false
                inBlock = false
                sections.append(JSFXSourceSection(name: name, line: index))
                if highlight {
                    lineTokens.append(JSFXToken(kind: .section, range: 0..<name.utf8.count))
                    lineTokens += Self.codeTokens(line, from: name.utf8.count, inBlock: &inBlock)
                }
            } else if inHeader {
                if desc == nil, let d = Self.value(line, key: "desc:") { desc = d }
                if highlight { lineTokens = Self.headerTokens(line) }
            } else if highlight {
                lineTokens = Self.codeTokens(line, from: 0, inBlock: &inBlock)
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

    // MARK: - 字句

    /// 最初の節より前。`sliderN:`の宣言と、`//`で始まる行だけ。
    /// **説明の字（`Don't`やURL）を字句として読まない。**
    private static func headerTokens(_ line: [UInt8]) -> [JSFXToken] {
        var i = 0
        while i < line.count && line[i] == 0x20 { i += 1 }
        if i + 1 < line.count && line[i] == UInt8(ascii: "/") && line[i + 1] == UInt8(ascii: "/") {
            return [JSFXToken(kind: .comment, range: i..<line.count)]
        }
        let slider = Array("slider".utf8)
        guard line[i...].starts(with: slider) else { return [] }
        var j = i + slider.count
        let digits = j
        while j < line.count && isDigit(line[j]) { j += 1 }
        guard j > digits, j < line.count, line[j] == UInt8(ascii: ":") else { return [] }
        return [JSFXToken(kind: .slider, range: i..<(j + 1))]
    }

    /// EEL2の本体。`inBlock`は行をまたぐ`/* */`。
    static func codeTokens(_ b: [UInt8], from start: Int, inBlock: inout Bool) -> [JSFXToken] {
        let n = b.count
        var out: [JSFXToken] = []
        var i = start

        func closeBlock(from j: Int) -> Int? {
            var k = j
            while k + 1 < n {
                if b[k] == UInt8(ascii: "*") && b[k + 1] == UInt8(ascii: "/") { return k + 2 }
                k += 1
            }
            return nil
        }

        if inBlock {
            if let e = closeBlock(from: i) {
                out.append(JSFXToken(kind: .comment, range: i..<e))
                inBlock = false
                i = e
            } else {
                if i < n { out.append(JSFXToken(kind: .comment, range: i..<n)) }
                return out
            }
        }

        while i < n {
            let c = b[i]
            let next: UInt8 = i + 1 < n ? b[i + 1] : 0
            if c == UInt8(ascii: "/") && next == UInt8(ascii: "/") {
                out.append(JSFXToken(kind: .comment, range: i..<n))
                break
            }
            if c == UInt8(ascii: "/") && next == UInt8(ascii: "*") {
                if let e = closeBlock(from: i + 2) {
                    out.append(JSFXToken(kind: .comment, range: i..<e))
                    i = e
                    continue
                }
                out.append(JSFXToken(kind: .comment, range: i..<n))
                inBlock = true
                break
            }
            if c == UInt8(ascii: "\"") || c == UInt8(ascii: "'") {
                var j = i + 1
                while j < n {
                    if b[j] == UInt8(ascii: "\\") { j += 2; continue }
                    if b[j] == c { j += 1; break }
                    j += 1
                }
                j = min(j, n)
                out.append(JSFXToken(kind: .string, range: i..<j))
                i = j
                continue
            }
            if isDigit(c) || (c == UInt8(ascii: ".") && isDigit(next)) {
                var j = i
                if c == UInt8(ascii: "0") && (next | 0x20) == UInt8(ascii: "x") {
                    j = i + 2
                    while j < n && isHex(b[j]) { j += 1 }
                } else {
                    while j < n && (isDigit(b[j]) || b[j] == UInt8(ascii: ".")) { j += 1 }
                    if j < n && (b[j] | 0x20) == UInt8(ascii: "e") {
                        var k = j + 1
                        if k < n && (b[k] == UInt8(ascii: "+") || b[k] == UInt8(ascii: "-")) { k += 1 }
                        if k < n && isDigit(b[k]) {
                            j = k
                            while j < n && isDigit(b[j]) { j += 1 }
                        }
                    }
                }
                out.append(JSFXToken(kind: .number, range: i..<j))
                i = j
                continue
            }
            // `$x1F` `$pi` `$'A'`
            if c == UInt8(ascii: "$") && (isIdent(next) || next == UInt8(ascii: "'")) {
                var j = i + 2
                if next == UInt8(ascii: "'") {
                    while j < n && b[j] != UInt8(ascii: "'") { j += 1 }
                    j = min(j + 1, n)
                } else {
                    while j < n && isIdent(b[j]) { j += 1 }
                }
                out.append(JSFXToken(kind: .number, range: i..<j))
                i = j
                continue
            }
            // **名前は丸ごと飛ばす。**`x1`や`this.y2`の数字を数として拾わない。
            if isIdent(c) {
                while i < n && isIdent(b[i]) { i += 1 }
                continue
            }
            i += 1
        }
        return out
    }

    private static func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
    private static func isHex(_ c: UInt8) -> Bool { isDigit(c) || ((c | 0x20) >= 0x61 && (c | 0x20) <= 0x66) }
    private static func isIdent(_ c: UInt8) -> Bool {
        isDigit(c) || (c | 0x20) >= 0x61 && (c | 0x20) <= 0x7A || c == UInt8(ascii: "_")
            || c == UInt8(ascii: ".") || c == UInt8(ascii: "#") || c >= 0x80
    }
}
