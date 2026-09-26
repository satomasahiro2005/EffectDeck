//  ETPEQTextImport.swift
//  15Band PEQ の Import。AutoEQ の ParametricEQ.txt などを 15 本のバンドへ落とす。
//
//  上流 Vendor/effetune/plugins/eq/fifteen_band_peq.js の移植:
//    ボタン            :472-508（accept='.txt'）
//    handleFileImport  :1279-1299（FileReader.readAsText）
//    parseAndImportTXT :1305-1355
//    setBand           :309-330（丸めと上下限）
//    EQ_FILTER_MAP     :34-40
//
//  上流の規則（こちらもそのまま）:
//    - **まず 15 本とも初期値に戻して切る**（:1307-1309）。
//      setBand(i, BANDS[i].freq, 0, 1.0, 'pk', false)。使わなかったバンドはこのまま残る
//    - '\n' で割って trim。'#' で始まる行・空行・'Preamp:' の行は飛ばす（:1311-1325）。
//      **Preamp は読まない。** 音量は変えない
//    - 'Filter' で始まる行だけ正規表現に掛ける（:1328-1329）。大文字小文字を区別し、
//      'ON' でない行（OFF）は当たらない。**Filter の番号は使わない。**出てきた順に詰める
//    - 型は LS/LSC→ls、PK→pk、HS/HSC→hs だけ。それ以外（LP/HP/NO/AP など）は
//      **捨てて、バンドも消費しない**（:1341-1347）
//    - 16 本目以降は捨てる（:1343 の filterIndex < 15）
//    - 値は setBand の通り: 周波数 20〜20000、ゲイン -20〜20、
//      Q はシェルフなら 0.1〜2、それ以外 0.1〜10。**丸めない。**
//      型を先に入れてから Q を切る（:313-321）
//
//  上流と違うのは 2 点:
//    - 使えるフィルタが 1 本も無かったとき、上流は全バンドを切った状態で終わる。
//      こちらは imported == 0 を返し、画面側が何も書かずに知らせる。
//    - 上流の EQ_FILTER_MAP は素の object なので、constructor・toString・__proto__ などの
//      型名も当たり、関数をそのまま型に入れてバンドを点ける（:1339-1343）。
//      **こちらは捨てて、バンドも消費しない。**
//
//  ここに SwiftUI を入れない。単体テスト（Tests/Unit/PEQTextImportTests.swift）が
//  この 1 本だけをコンパイルして照合する。

import Foundation

enum ETPEQTextImport {

    struct Band: Equatable {
        var frequency: Double
        var gain: Double
        var q: Double
        /// params.json の filterType の添字（filterTypeIDs の並び）。
        var type: Int
        var enabled: Bool
    }

    struct Result: Equatable {
        /// 常に bandCount 本。
        var bands: [Band]
        /// 実際に入ったフィルタの数。0 なら何も読めていない。
        var imported: Int
    }

    static let bandCount = 15

    /// fifteen_band_peq.js:3-19 の BANDS。
    static let defaultFrequencies: [Double] = [25, 40, 63, 100, 160, 250, 400, 630,
                                               1000, 1600, 2500, 4000, 6300, 10000, 16000]

    /// fifteen_band_peq.js:22-31 の FILTER_TYPES。params.json の enum と同じ並び。
    static let filterTypeIDs = ["pk", "lp", "hp", "ls", "hs", "bp", "no", "ap"]

    /// fifteen_band_peq.js:34-40 の EQ_FILTER_MAP。**ここに無い型は捨てる。**
    static let filterMap: [String: String] = [
        "LS": "ls", "LSC": "ls", "PK": "pk", "HS": "hs", "HSC": "hs",
    ]

    // MARK: - setBand

    /// setBand（:309-321）の丸め。型を入れてから Q を切る。
    static func band(frequency: Double, gain: Double, q: Double,
                     typeID: String, enabled: Bool) -> Band {
        let shelf = typeID == "ls" || typeID == "hs"
        return Band(frequency: max(20, min(frequency, 20000)),
                    gain: max(-20, min(gain, 20)),
                    q: max(0.1, min(q, shelf ? 2.0 : 10.0)),
                    type: filterTypeIDs.firstIndex(of: typeID) ?? 0,
                    enabled: enabled)
    }

    /// 取り込みの前に全バンドを戻す形（:1307-1309）。
    static func resetBand(_ i: Int) -> Band {
        band(frequency: defaultFrequencies[i], gain: 0, q: 1.0, typeID: "pk", enabled: false)
    }

    // MARK: - parseAndImportTXT

    static func parse(_ content: String) -> Result {
        var bands = (0..<bandCount).map(resetBand)
        var filterIndex = 0

        // **'\n' で割る。**Swift の Character だと "\r\n" が 1 字になって割れないので、
        // スカラーで割る。'\r' は trim が落とす（上流と同じ）。
        for raw in content.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = trimJS(raw)
            if line.isEmpty || line.starts(with: "#".unicodeScalars) { continue }
            if line.starts(with: "Preamp:".unicodeScalars) { continue }
            guard line.starts(with: "Filter".unicodeScalars) else { continue }

            let text = String(Substring(line))
            let ns = text as NSString
            guard let m = filterLine.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
            else { continue }

            let type = ns.substring(with: m.range(at: 2))
            guard let mapped = filterMap[type], filterIndex < bandCount else { continue }
            bands[filterIndex] = band(frequency: number(ns.substring(with: m.range(at: 3))),
                                      gain: number(ns.substring(with: m.range(at: 4))),
                                      q: number(ns.substring(with: m.range(at: 5))),
                                      typeID: mapped, enabled: true)
            filterIndex += 1
        }
        return Result(bands: bands, imported: filterIndex)
    }

    // MARK: - 読み込み

    /// FileReader.readAsText（:1298）と同じ読み方。既定は UTF-8 で、BOM があればそちらに従う。
    /// 壊れたバイトは U+FFFD にするだけで失敗にしない（上流も onerror に行かない）。
    static func decode(_ data: Data) -> String {
        let head = [UInt8](data.prefix(3))
        if head.count >= 3, head[0] == 0xEF, head[1] == 0xBB, head[2] == 0xBF {
            return String(decoding: data.dropFirst(3), as: UTF8.self)
        }
        if head.count >= 2, head[0] == 0xFF, head[1] == 0xFE {
            return utf16(data.dropFirst(2), littleEndian: true)
        }
        if head.count >= 2, head[0] == 0xFE, head[1] == 0xFF {
            return utf16(data.dropFirst(2), littleEndian: false)
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - 中身

    /// JS の \s と String.prototype.trim が落とす字（WhiteSpace + LineTerminator）。
    /// ICU の \s とは U+FEFF などがずれるので、字の組を自前で書く。
    private static let jsSpaces: Set<Unicode.Scalar> = {
        var s: Set<Unicode.Scalar> = ["\t", "\n", "\u{0B}", "\u{0C}", "\r", " ", "\u{A0}",
                                      "\u{1680}", "\u{2028}", "\u{2029}", "\u{202F}",
                                      "\u{205F}", "\u{3000}", "\u{FEFF}"]
        for v in 0x2000...0x200A { s.insert(Unicode.Scalar(UInt32(v))!) }
        return s
    }()

    /// jsSpaces を正規表現の字の組にしたもの。**見えない字をソースに置かない**ので \x{...} で組む。
    private static let jsSpaceClass =
        "[" + jsSpaces.sorted().map { "\\x{" + String($0.value, radix: 16) + "}" }.joined() + "]"

    /// fifteen_band_peq.js:1329 の正規表現。JS は \d と \w が ASCII だけなので、そこも書き下す。
    /// **行頭に固定しない**（上流の match も固定していない）。
    private static let filterLine: NSRegularExpression = {
        let s = jsSpaceClass + "+"
        let num = "([0-9]+(?:\\.[0-9]+)?)"
        let pattern = "Filter" + s + "([0-9]+):" + s + "ON" + s + "([A-Za-z0-9_]+)" + s
            + "Fc" + s + num + s + "Hz" + s
            + "Gain" + s + "([-+]?[0-9]+(?:\\.[0-9]+)?)" + s + "dB" + s
            + "Q" + s + num
        return try! NSRegularExpression(pattern: pattern)
    }()

    private static func trimJS(_ s: Substring.UnicodeScalarView) -> Substring.UnicodeScalarView {
        var slice = s
        while let f = slice.first, jsSpaces.contains(f) { slice.removeFirst() }
        while let l = slice.last, jsSpaces.contains(l) { slice.removeLast() }
        return slice
    }

    /// parseFloat。正規表現を通った字なので、失敗するのは桁あふれだけ（parseFloat は ±Infinity）。
    private static func number(_ s: String) -> Double {
        if let v = Double(s) { return v }
        return s.hasPrefix("-") ? -.infinity : .infinity
    }

    /// 奇数バイトで終わったら、WHATWG の decoder と同じく最後に U+FFFD を 1 つ出す。
    private static func utf16(_ bytes: Data, littleEndian: Bool) -> String {
        let b = [UInt8](bytes)
        var units = [UInt16]()
        units.reserveCapacity(b.count / 2)
        var i = 0
        while i + 1 < b.count {
            units.append(littleEndian ? UInt16(b[i]) | UInt16(b[i + 1]) << 8
                                      : UInt16(b[i]) << 8 | UInt16(b[i + 1]))
            i += 2
        }
        var s = String(decoding: units, as: UTF16.self)
        if b.count % 2 == 1 { s.append("\u{FFFD}") }
        return s
    }
}
