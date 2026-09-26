//  BassManagementTests.swift
//  Bass Management（2.11.0）の保存形式。**実機もエンジンも要らない。**
//
//  上流は 16ch 分の ro / fc / sl / rt / ri を平らな配列で書き、ph と tp は文字列で書く
//  （plugins/basics/bass_management.js:101-118 の _ownParameters、:142-180 の setParameters）。
//  web 版から来たプリセットをそのまま読めて、こちらが書いたものを web 版が読めることを見る。
//  本物の ETCatalog に対して測る。

import XCTest

final class BassManagementTests: XCTestCase {

    private let type = "BassManagementPlugin"

    /// web 版の getParameters が返す形（キーは params.json の key）。
    private let upstreamJSON = """
        {"ph":"Linear","tp":"8192",
         "ro":[1,1,2,2,0,0,0,0,0,0,0,0,0,0,0,0],
         "fc":[80,100,80,80,80,80,80,80,80,80,80,80,80,80,80,80],
         "sl":[24,48,24,24,24,24,24,24,24,24,24,24,24,24,24,24],
         "rt":[12,4,4,8,0,0,0,0,0,0,0,0,0,0,0,0],
         "ri":[0,4,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
         "su":12,"lf":120,"ls":48,"lo":true,"bg":-3,"lg":0,"hg":-6}
        """

    // MARK: - 読む

    func testReadsUpstreamJSON() throws {
        let s = try spec()
        let dict = try upstreamDict()
        let values = ETParamCoding.decode(params: s.params, defaults: s.defaults, from: dict)
        let o = try offsets()

        // enum は選択肢の添字で持つ（ETParamCoding.number）。
        XCTAssertEqual(values[o["ph"]!], 1, "ph Linear")
        XCTAssertEqual(values[o["tp"]!], 0, "tp 8192")
        XCTAssertEqual(values[o["lo"]!], 1)
        XCTAssertEqual(values[o["su"]!], 12)
        XCTAssertEqual(values[o["lf"]!], 120)
        XCTAssertEqual(values[o["ls"]!], 48)
        XCTAssertEqual(values[o["bg"]!], -3)
        XCTAssertEqual(values[o["hg"]!], -6)

        let ro = o["ro"]!, fc = o["fc"]!, sl = o["sl"]!, rt = o["rt"]!, ri = o["ri"]!
        XCTAssertEqual(Array(values[ro..<ro + 4]), [1, 1, 2, 2])
        XCTAssertEqual(values[fc + 1], 100)
        XCTAssertEqual(values[sl + 1], 48)
        XCTAssertEqual(Array(values[rt..<rt + 4]), [12, 4, 4, 8])
        XCTAssertEqual(values[ri + 1], 4)
        // 平らな配列は添字付きの鍵（ro0 …）とは別物。書かれていない ch は既定のまま。
        XCTAssertEqual(values[ro + 15], 0)
        XCTAssertEqual(values[fc + 15], 80)
    }

    /// 型名を渡すと上流の setParameters と同じ所へ着地する（ETUpstreamNormalize）。
    /// 寄せないとカーネルが設定ごと捨てて素通しになる（kernel.cpp:41-58）。
    func testNormalizesLikeSetParameters() throws {
        let s = try spec()
        let o = try offsets()
        let dict: [String: Any] = [
            "ph": 1, "tp": 8192,
            "ro": [1, 7, "x"] as [Any], "fc": [1000, "nan", 99.6, 5] as [Any],
            "sl": [48, 30], "rt": [12, 1e20, -3], "ri": [6, 1, 0],
            "su": 1e20, "lf": "abc", "ls": 50, "bg": 99, "lg": "-inf", "hg": 3,
        ]
        let v = ETParamCoding.decode(params: s.params, defaults: s.defaults, from: dict, type: type)
        let d = s.defaults

        XCTAssertEqual(v[o["ph"]!], d[o["ph"]!], "ph は綴りだけ（:146）")
        XCTAssertEqual(v[o["tp"]!], 0, "数の 8192 も String(params.tp) で通る（:147）")
        XCTAssertEqual(Array(v[o["ro"]!..<o["ro"]! + 3]), [1, d[o["ro"]! + 1], d[o["ro"]! + 2]])
        XCTAssertEqual(Array(v[o["fc"]!..<o["fc"]! + 4]), [300, d[o["fc"]! + 1], 100, 20])
        XCTAssertEqual(Array(v[o["sl"]!..<o["sl"]! + 2]), [48, d[o["sl"]! + 1]])
        XCTAssertEqual(Array(v[o["rt"]!..<o["rt"]! + 3]), [12, d[o["rt"]! + 1], 0])
        // ri &= rt（:166-168）。
        XCTAssertEqual(Array(v[o["ri"]!..<o["ri"]! + 3]), [4, 0, 0])
        XCTAssertEqual(v[o["su"]!], d[o["su"]!])
        XCTAssertEqual(v[o["lf"]!], d[o["lf"]!])
        XCTAssertEqual(v[o["ls"]!], d[o["ls"]!])
        XCTAssertEqual(v[o["bg"]!], 12)
        XCTAssertEqual(v[o["lg"]!], d[o["lg"]!])
        XCTAssertEqual(v[o["hg"]!], 0)
    }

    /// 上流形式を読んで書き戻すと、同じ JSON の形に戻る。
    func testUpstreamJSONRoundTrip() throws {
        let s = try spec()
        let dict = try upstreamDict()
        let values = ETParamCoding.decode(params: s.params, defaults: s.defaults, from: dict)
        let encoded = ETParamCoding.encode(params: s.params, values: values)

        XCTAssertEqual(encoded["ph"] as? String, "Linear")
        XCTAssertEqual(encoded["tp"] as? String, "8192")
        XCTAssertEqual(encoded["lo"] as? Bool, true)
        XCTAssertEqual(encoded["su"] as? Int, 12)
        for key in ["ro", "fc", "sl", "rt", "ri"] {
            let written = try XCTUnwrap(encoded[key] as? [Any], "\(key) が平らな配列で書かれていない")
            let original = try XCTUnwrap(dict[key] as? [NSNumber])
            XCTAssertEqual(written.count, 16)
            for (i, item) in written.enumerated() {
                XCTAssertEqual((item as? NSNumber)?.doubleValue, original[i].doubleValue, "\(key)[\(i)]")
            }
            XCTAssertNil(encoded[key + "0"], "\(key) を添字付きで書いている")
        }

        // もう一度読んでも値は変わらない。
        let data = try JSONSerialization.data(withJSONObject: encoded)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(ETParamCoding.decode(params: s.params, defaults: s.defaults, from: json), values)
    }

    // MARK: - 書く

    /// ロールと bit の配列、su / lf / ls は整数で書く。web 版の setParameters は
    /// Math.round してから範囲を見る（:148-175）ので 1.0 でも読めるが、
    /// 上流が書く形（整数）に揃える。
    func testIntegerArraysAreWrittenAsInt() throws {
        let s = try spec()
        let o = try offsets()
        var values = s.defaults
        values[o["ro"]! + 2] = 2
        values[o["sl"]! + 2] = 96
        values[o["rt"]! + 2] = 65535
        values[o["ri"]! + 2] = 32768
        values[o["su"]!] = 4
        let encoded = ETParamCoding.encode(params: s.params, values: values)

        for key in ["ro", "sl", "rt", "ri"] {
            let ints = try XCTUnwrap(encoded[key] as? [Int], "\(key) が Int の配列ではない")
            XCTAssertEqual(ints.count, 16)
        }
        XCTAssertEqual((encoded["ro"] as? [Int])?[2], 2)
        XCTAssertEqual((encoded["sl"] as? [Int])?[2], 96)
        XCTAssertEqual((encoded["rt"] as? [Int])?[2], 65535)
        XCTAssertEqual((encoded["ri"] as? [Int])?[2], 32768)
        XCTAssertEqual(encoded["su"] as? Int, 4)
        XCTAssertEqual(encoded["lf"] as? Int, 120)
        XCTAssertEqual(encoded["ls"] as? Int, 24)

        // JSON の字面でも小数点が付かない。
        let data = try JSONSerialization.data(withJSONObject: encoded, options: [.sortedKeys])
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"ro\":[0,0,2,0,0,0,0,0,0,0,0,0,0,0,0,0]"), text)
        XCTAssertTrue(text.contains("\"rt\":[0,0,65535,0,0,0,0,0,0,0,0,0,0,0,0,0]"), text)
        XCTAssertTrue(text.contains("\"su\":4"), text)
        XCTAssertTrue(text.contains("\"tp\":\"16384\""), text)
        XCTAssertTrue(text.contains("\"ph\":\"IIR\""), text)
    }

    // MARK: - catalog の形

    /// BassManagementSettings.Layout が key から位置を引く。1 つでも欠けると画面も designer も動かない。
    func testCatalogCarriesEveryKey() throws {
        let s = try spec()
        for key in ["ph", "tp", "su", "lf", "ls", "lo", "bg", "lg", "hg"] {
            let p = try XCTUnwrap(s.params.first { $0.key == key }, key)
            XCTAssertEqual(p.count, 1, key)
        }
        for key in ["ro", "fc", "sl", "rt", "ri"] {
            let p = try XCTUnwrap(s.params.first { $0.key == key }, key)
            XCTAssertEqual(p.count, 16, key)
            XCTAssertEqual(p.flatArrayKey, key, key)
        }
        XCTAssertEqual(s.floatCount, 89)
        // 選択肢は上流の並び（bass_management.js:9 と params.json）。値はこの添字。
        let tp = try XCTUnwrap(s.params.first { $0.key == "tp" })
        guard case .enumeration(let taps) = tp.kind else { return XCTFail("tp が enum ではない") }
        XCTAssertEqual(taps, ["8192", "16384", "32768"])
        let ph = try XCTUnwrap(s.params.first { $0.key == "ph" })
        guard case .enumeration(let phases) = ph.kind else { return XCTFail("ph が enum ではない") }
        XCTAssertEqual(phases, ["IIR", "Linear"])
    }

    // MARK: - 道具

    private func spec() throws -> ETEffect {
        try XCTUnwrap(ETCatalog.first { $0.type == type }, "\(type) が catalog に無い")
    }

    /// 14 個の key → float の並びの位置。欠けていれば落とす。
    private func offsets() throws -> [String: Int] {
        let s = try spec()
        var result: [String: Int] = [:]
        for key in ["ph", "tp", "ro", "fc", "sl", "rt", "ri", "su", "lf", "ls", "lo", "bg", "lg", "hg"] {
            result[key] = try XCTUnwrap(s.params.first { $0.key == key }?.offset, key)
        }
        return result
    }

    private func upstreamDict() throws -> [String: Any] {
        let data = try XCTUnwrap(upstreamJSON.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
