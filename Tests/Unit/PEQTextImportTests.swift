//  PEQTextImportTests.swift
//  15Band PEQ の Import（DSP/ETPEQTextImport.swift）。**実機もエンジンも要らない。**
//
//  期待値は上流 Vendor/effetune/plugins/eq/fifteen_band_peq.js の規則から手で出したもので、
//  こちらの実装から出したものではない:
//      取り込み前に全バンドを setBand(i, BANDS[i].freq, 0, 1.0, 'pk', false)   :1307-1309
//      '#'・空行・'Preamp:' は飛ばす                                           :1316-1325
//      /Filter\s+(\d+):\s+ON\s+(\w+)\s+Fc\s+(\d+(?:\.\d+)?)\s+Hz\s+Gain\s+
//       ([-+]?\d+(?:\.\d+)?)\s+dB\s+Q\s+(\d+(?:\.\d+)?)/                      :1329
//      LS/LSC→ls、PK→pk、HS/HSC→hs。他は捨てて番号も進めない。15 本まで        :34-40, :1341-1347
//      f: 20〜20000、g: -20〜20、Q: シェルフ 0.1〜2 / 他 0.1〜10。丸めない     :309-321
//
//  型の添字は FILTER_TYPES（:22-31）の並び: pk=0 lp=1 hp=2 ls=3 hs=4 bp=5 no=6 ap=7。

import XCTest
import Foundation

final class PEQTextImportTests: XCTestCase {

    private typealias Band = ETPEQTextImport.Band

    private static let pk = 0, ls = 3, hs = 4

    /// 取り込みで触られなかったバンド。BANDS[i].freq / 0dB / Q1 / Peaking / 切。
    private static let untouched: [Band] = [25, 40, 63, 100, 160, 250, 400, 630, 1000,
                                            1600, 2500, 4000, 6300, 10000, 16000].map {
        Band(frequency: $0, gain: 0, q: 1, type: 0, enabled: false)
    }

    private func on(_ f: Double, _ g: Double, _ q: Double, _ t: Int) -> Band {
        Band(frequency: f, gain: g, q: q, type: t, enabled: true)
    }

    // MARK: 実物

    /// AutoEQ の結果をそのまま（全 11 行）。
    /// https://github.com/jaakkopasanen/AutoEq/blob/7ae0f56d53074872b028649617a22bbb4232feb7/
    ///   results/crinacle/711 in-ear/Apple AirPods Pro/Apple AirPods Pro ParametricEQ.txt
    private static let airPodsPro = """
        Preamp: -6.0 dB
        Filter 1: ON LSC Fc 105 Hz Gain 2.6 dB Q 0.70
        Filter 2: ON PK Fc 514 Hz Gain -4.4 dB Q 0.68
        Filter 3: ON PK Fc 8903 Hz Gain 6.0 dB Q 1.66
        Filter 4: ON PK Fc 183 Hz Gain 2.0 dB Q 0.77
        Filter 5: ON PK Fc 4613 Hz Gain 3.4 dB Q 2.46
        Filter 6: ON HSC Fc 10000 Hz Gain -0.5 dB Q 0.70
        Filter 7: ON PK Fc 1517 Hz Gain -1.0 dB Q 2.33
        Filter 8: ON PK Fc 929 Hz Gain 1.2 dB Q 2.75
        Filter 9: ON PK Fc 44 Hz Gain -0.5 dB Q 2.16
        Filter 10: ON PK Fc 618 Hz Gain -0.5 dB Q 2.86

        """

    /// 10 本がファイルの順に 1〜10 へ。残り 5 本は初期値で切。**Preamp は読まない。**
    func testAutoEQAirPodsPro() {
        let r = ETPEQTextImport.parse(Self.airPodsPro)
        XCTAssertEqual(r.imported, 10)
        var expected = Self.untouched
        expected[0] = on(105, 2.6, 0.70, Self.ls)
        expected[1] = on(514, -4.4, 0.68, Self.pk)
        expected[2] = on(8903, 6.0, 1.66, Self.pk)
        expected[3] = on(183, 2.0, 0.77, Self.pk)
        expected[4] = on(4613, 3.4, 2.46, Self.pk)
        expected[5] = on(10000, -0.5, 0.70, Self.hs)
        expected[6] = on(1517, -1.0, 2.33, Self.pk)
        expected[7] = on(929, 1.2, 2.75, Self.pk)
        expected[8] = on(44, -0.5, 2.16, Self.pk)
        expected[9] = on(618, -0.5, 2.86, Self.pk)
        XCTAssertEqual(r.bands, expected)
    }

    /// Windows で保存し直すと CRLF と BOM が付く。どちらも結果を変えない。
    func testCRLFAndBOM() {
        let crlf = Self.airPodsPro.replacingOccurrences(of: "\n", with: "\r\n")
        let data = Data([0xEF, 0xBB, 0xBF]) + Data(crlf.utf8)
        let r = ETPEQTextImport.parse(ETPEQTextImport.decode(data))
        XCTAssertEqual(r, ETPEQTextImport.parse(Self.airPodsPro))
        XCTAssertEqual(r.imported, 10)
    }

    /// FileReader は UTF-16 の BOM にも従う。
    func testUTF16LEWithBOM() {
        let text = "Filter 1: ON PK Fc 1000 Hz Gain 3.0 dB Q 1.41\n"
        var data = Data([0xFF, 0xFE])
        for u in text.utf16 { data.append(UInt8(u & 0xFF)); data.append(UInt8(u >> 8)) }
        let r = ETPEQTextImport.parse(ETPEQTextImport.decode(data))
        XCTAssertEqual(r.imported, 1)
        XCTAssertEqual(r.bands[0], on(1000, 3.0, 1.41, Self.pk))
    }

    // MARK: 型

    /// LS と HS も LSC / HSC と同じ。LP/HP/NO/AP/BP/LPQ は捨てて、**番号も進めない**。
    func testUnsupportedTypesAreSkippedWithoutTakingABand() {
        let text = """
            Filter 1: ON LP Fc 18000 Hz Gain 0.0 dB Q 0.71
            Filter 2: ON LS Fc 80 Hz Gain 4.0 dB Q 0.71
            Filter 3: ON HP Fc 20 Hz Gain 0.0 dB Q 0.71
            Filter 4: ON NO Fc 3000 Hz Gain 0.0 dB Q 5.00
            Filter 5: ON AP Fc 500 Hz Gain 0.0 dB Q 1.00
            Filter 6: ON BP Fc 500 Hz Gain 0.0 dB Q 1.00
            Filter 7: ON LPQ Fc 500 Hz Gain 0.0 dB Q 1.00
            Filter 8: ON HS Fc 8000 Hz Gain -2.0 dB Q 0.71
            """
        let r = ETPEQTextImport.parse(text)
        XCTAssertEqual(r.imported, 2)
        var expected = Self.untouched
        expected[0] = on(80, 4.0, 0.71, Self.ls)
        expected[1] = on(8000, -2.0, 0.71, Self.hs)
        XCTAssertEqual(r.bands, expected)
    }

    /// 正規表現に i が無い。小文字の型は EQ_FILTER_MAP に無く、小文字の on は当たらない。
    func testCaseSensitive() {
        let text = """
            Filter 1: ON pk Fc 100 Hz Gain 1.0 dB Q 1.0
            Filter 2: on PK Fc 100 Hz Gain 1.0 dB Q 1.0
            filter 3: ON PK Fc 100 Hz Gain 1.0 dB Q 1.0
            """
        let r = ETPEQTextImport.parse(text)
        XCTAssertEqual(r.imported, 0)
        XCTAssertEqual(r.bands, Self.untouched)
    }

    /// **上流と意図してずらした所。**上流は EQ_FILTER_MAP が素の object なので、
    /// constructor などが Object.prototype から当たって関数を型に入れたバンドを 5 本点ける。
    /// こちらは捨てて番号も進めない。
    func testObjectPrototypeNamesAreNotTypes() {
        let text = ["constructor", "toString", "__proto__", "valueOf", "hasOwnProperty"]
            .map { "Filter 1: ON \($0) Fc 1000 Hz Gain 3 dB Q 5" }
            .joined(separator: "\n") + "\nFilter 6: ON PK Fc 200 Hz Gain 1.0 dB Q 1.0"
        let r = ETPEQTextImport.parse(text)
        XCTAssertEqual(r.imported, 1)
        var expected = Self.untouched
        expected[0] = on(200, 1.0, 1.0, Self.pk)
        XCTAssertEqual(r.bands, expected)
    }

    // MARK: 空白

    /// 区切りは JS の \s（WhiteSpace + LineTerminator）。trim も同じ字を落とす。
    /// U+200B・U+0085・U+180E は JS では空白ではない（ICU の \s は U+0085 を含む）。
    func testJSWhitespace() {
        let text = [
            "\u{FEFF}Filter\u{A0}1:\u{3000}ON\u{2003}PK\u{1680}Fc\u{202F}100\u{205F}Hz\u{2028}"
                + "Gain\u{2029}1.0\u{0B}dB\u{FEFF}Q\u{0C}\u{200A}1.0\u{2000}",
            "Filter\u{200B}2: ON PK Fc 200 Hz Gain 1.0 dB Q 1.0",
            "Filter 3:\u{85}ON PK Fc 300 Hz Gain 1.0 dB Q 1.0",
            "Filter 4: ON PK Fc 400 Hz Gain 1.0 dB Q\u{180E}1.0",
        ].joined(separator: "\n")
        let r = ETPEQTextImport.parse(text)
        XCTAssertEqual(r.imported, 1)
        var expected = Self.untouched
        expected[0] = on(100, 1.0, 1.0, Self.pk)
        XCTAssertEqual(r.bands, expected)
    }

    // MARK: 数と順

    /// Filter の番号は見ない。OFF の行は当たらない。
    func testFileOrderNotFilterNumberAndOffIsIgnored() {
        let text = """
            Filter 9: ON PK Fc 300 Hz Gain -1.0 dB Q 2.0
            Filter 2: OFF PK Fc 400 Hz Gain -2.0 dB Q 2.0
            Filter 1: ON PK Fc 500 Hz Gain -3.0 dB Q 2.0
            """
        let r = ETPEQTextImport.parse(text)
        XCTAssertEqual(r.imported, 2)
        XCTAssertEqual(r.bands[0], on(300, -1.0, 2.0, Self.pk))
        XCTAssertEqual(r.bands[1], on(500, -3.0, 2.0, Self.pk))
        XCTAssertEqual(Array(r.bands[2...]), Array(Self.untouched[2...]))
    }

    /// 16 本目からは捨てる。
    func testOnlyFirstFifteenAreTaken() {
        let text = (1...20).map { "Filter \($0): ON PK Fc \($0 * 100) Hz Gain 1.0 dB Q 1.0" }
            .joined(separator: "\n")
        let r = ETPEQTextImport.parse(text)
        XCTAssertEqual(r.imported, 15)
        for i in 0..<15 {
            XCTAssertEqual(r.bands[i], on(Double((i + 1) * 100), 1.0, 1.0, Self.pk), "band \(i)")
        }
    }

    // MARK: 丸めと上下限

    /// 上下限だけ掛けて丸めない。Q の上限はシェルフだけ 2。
    func testClampingWithoutRounding() {
        let text = """
            Filter 1: ON PK Fc 5 Hz Gain -25.0 dB Q 0
            Filter 2: ON PK Fc 30000 Hz Gain +24.5 dB Q 12.5
            Filter 3: ON LSC Fc 105.37 Hz Gain 2.55 dB Q 3.0
            Filter 4: ON HS Fc 9000 Hz Gain -0.04 dB Q 2.5
            Filter 5: ON PK Fc 1234.5 Hz Gain 0.123 dB Q 0.707
            """
        let r = ETPEQTextImport.parse(text)
        XCTAssertEqual(r.imported, 5)
        XCTAssertEqual(r.bands[0], on(20, -20, 0.1, Self.pk))
        XCTAssertEqual(r.bands[1], on(20000, 20, 10, Self.pk))
        XCTAssertEqual(r.bands[2], on(105.37, 2.55, 2.0, Self.ls))
        XCTAssertEqual(r.bands[3], on(9000, -0.04, 2.0, Self.hs))
        XCTAssertEqual(r.bands[4], on(1234.5, 0.123, 0.707, Self.pk))
    }

    // MARK: 行の形

    /// 字下げ・コメント・Preamp・形の違う行。
    func testLineShapes() {
        let text = """
            # comment
               Preamp: -3.0 dB
            \tFilter 1: ON PK Fc 100 Hz Gain 1.0 dB Q 1.0\t
            Filter: ON PK Fc 200 Hz Gain 1.0 dB Q 1.0
            Filter 3: ON PK Fc 300 Hz Gain 1.0 dB
            Filter 4: ON PK Fc 1e3 Hz Gain 1.0 dB Q 1.0
            Filter 5: ON PK Fc 500 Hz Gain .5 dB Q 1.0
            Note Filter 6: ON PK Fc 600 Hz Gain 1.0 dB Q 1.0
            Filter note Filter 7: ON PK Fc 700 Hz Gain 1.0 dB Q 1.0
            Filter 8:  ON   PK  Fc  800  Hz  Gain  -1  dB  Q  2  extra
            """
        let r = ETPEQTextImport.parse(text)
        // 当たるのは 1、7（'Filter' で始まり、正規表現は行頭に固定されていない）、8。
        //   Filter: は番号が無い / 3 は Q が無い / 1e3 と .5 は数の形が合わない /
        //   6 は 'Filter' で始まらない
        XCTAssertEqual(r.imported, 3)
        XCTAssertEqual(r.bands[0], on(100, 1.0, 1.0, Self.pk))
        XCTAssertEqual(r.bands[1], on(700, 1.0, 1.0, Self.pk))
        XCTAssertEqual(r.bands[2], on(800, -1, 2, Self.pk))
    }

    /// GraphicEQ.txt のような別の形は 1 本も当たらない。
    func testNothingToImport() {
        let r = ETPEQTextImport.parse("GraphicEQ: 20 -6.2; 21 -6.2; 22 -6.1\n")
        XCTAssertEqual(r.imported, 0)
        XCTAssertEqual(r.bands, Self.untouched)
        XCTAssertEqual(ETPEQTextImport.parse("").imported, 0)
    }

    // MARK: カタログと揃っているか

    /// 型の添字・初期周波数・値の範囲が params.json（生成されたカタログ）と同じ。
    func testMatchesCatalog() throws {
        let spec = try XCTUnwrap(ETCatalog.first { $0.type == "FifteenBandPEQPlugin" })
        let byName = Dictionary(uniqueKeysWithValues: spec.params.map { ($0.name, $0) })

        guard case .enumeration(let ids) = try XCTUnwrap(byName["filterType"]).kind else {
            return XCTFail("filterType が enumeration でない")
        }
        XCTAssertEqual(ids, ETPEQTextImport.filterTypeIDs)

        let f = try XCTUnwrap(byName["frequency"])
        XCTAssertEqual(f.count, ETPEQTextImport.bandCount)
        XCTAssertEqual(spec.defaults[f.offset..<f.offset + f.count].map { Double($0) },
                       ETPEQTextImport.defaultFrequencies)

        // カタログは Float で持っている。
        func range(_ name: String) throws -> (Float, Float) {
            guard case .number(let lo, let hi, _, _, _) = try XCTUnwrap(byName[name]).kind else {
                XCTFail("\(name) が number でない"); return (0, 0)
            }
            return (lo, hi)
        }
        let fr = try range("frequency"), gr = try range("gain"), qr = try range("q")
        XCTAssertEqual(fr.0, 20); XCTAssertEqual(fr.1, 20000)
        XCTAssertEqual(gr.0, -20); XCTAssertEqual(gr.1, 20)
        XCTAssertEqual(qr.0, 0.1); XCTAssertEqual(qr.1, 10)
    }
}
