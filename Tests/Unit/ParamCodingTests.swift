//  ParamCodingTests.swift
//  保存形式の相互変換。**実機もエンジンも要らない。**
//
//  ここが在る理由は docs/connect-log.md ではなく、静的解析が出した 2 件の所見:
//    - upstream:PipelineStore.swift:38-48（shortForm が `en` を潰す）
//    - upstream:gen_catalog.py:464-465（objectArrayKey を落としている）
//  どちらも「触らずに壊れている」のに、コードを読むだけでは何度も見落とした。
//  本物の ETCatalog に対して測る。

import XCTest

final class ParamCodingTests: XCTestCase {

    func testSpatialMapperMatricesUseUpstreamFlatArrays() throws {
        let s = try spec("SpatialMapperPlugin")
        var values = s.defaults
        for key in ["dm", "fm", "rm"] {
            let p = try XCTUnwrap(s.params.first { $0.key == key })
            XCTAssertEqual(p.count, 256)
            // Output 4, input 2: output-major order, including negative gain.
            values[p.offset + 3 * 16 + 1] = -0.375
        }
        let encoded = ETParamCoding.encode(params: s.params, values: values)
        let data = try JSONSerialization.data(withJSONObject: encoded)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["dm", "fm", "rm"] {
            let matrix = try XCTUnwrap(json[key] as? [NSNumber])
            XCTAssertEqual(matrix.count, 256)
            XCTAssertEqual(matrix[49].floatValue, -0.375)
            XCTAssertNil(json[key + "0"])
        }
        XCTAssertEqual(ETParamCoding.decode(params: s.params, defaults: s.defaults, from: json), values)
    }

    func testOldSpectrumPresetsKeepHQDisabled() throws {
        for type in ["SpectrumAnalyzerPlugin", "SpectrogramPlugin"] {
            let s = try spec(type)
            let hq = try XCTUnwrap(s.params.first { $0.key == "hq" })
            let legacy = ETParamCoding.decode(params: s.params, defaults: s.defaults,
                                             from: ["dr": -120, "pt": 11])
            XCTAssertEqual(legacy[hq.offset], 0)
            let modern = ETParamCoding.decode(params: s.params, defaults: s.defaults,
                                             from: ["hq": true])
            XCTAssertEqual(modern[hq.offset], 1)
        }
    }

    private func spec(_ type: String) throws -> ETEffect {
        try XCTUnwrap(ETCatalog.first { $0.type == type }, "\(type) が catalog に無い")
    }

    // MARK: - オブジェクト配列

    /// 上流は 5Band Dynamic EQ を `"bs": [{...}×5]` と書く。
    /// 平らな `"en": [...]` で書いてはいけない（段の `en` と衝突する）。
    func testWritesObjectArrayNotFlatArray() throws {
        let s = try spec("FiveBandDynamicEQ")
        let o = ETParamCoding.encode(params: s.params, values: s.defaults)

        let rows = try XCTUnwrap(o["bs"] as? [[String: Any]], "bs が無い")
        XCTAssertEqual(rows.count, 5)
        XCTAssertNotNil(rows[0]["en"])
        XCTAssertNotNil(rows[0]["ft"])
        XCTAssertNotNil(rows[0]["f"])

        // **平らなキーを出さないこと。** 出すと shortForm の `o["en"] = enabled` と
        // 同じ場所を取り合う。
        XCTAssertNil(o["en"], "平らな en を書いている。段の入切に潰される")
        XCTAssertNil(o["ft"])
        XCTAssertNil(o["f"])
    }

    /// objectArrayKey を持つ 8 本すべてで、平らな配列を書かないこと。
    func testNoPluginWritesFlatObjectArrays() throws {
        var checked = 0
        for s in ETCatalog {
            let groups = Set(s.params.compactMap { $0.isObjectMember ? $0.objectArrayKey : nil })
            guard !groups.isEmpty else { continue }
            checked += 1
            let o = ETParamCoding.encode(params: s.params, values: s.defaults)
            for g in groups {
                XCTAssertNotNil(o[g] as? [[String: Any]], "\(s.type): \(g) がオブジェクト配列で出ていない")
            }
            for p in s.params where p.isObjectMember {
                XCTAssertNil(o[p.key], "\(s.type): 平らな \(p.key) を書いている")
            }
        }
        XCTAssertEqual(checked, 8, "objectArrayKey を持つのは params.json 8 本のはず")
    }

    /// 書いて読んで、値が戻ること。
    func testObjectArrayRoundTrip() throws {
        let s = try spec("FiveBandDynamicEQ")
        var v = s.defaults
        let en = try XCTUnwrap(s.params.first { $0.memberKey == "en" })
        let freq = try XCTUnwrap(s.params.first { $0.memberKey == "f" })
        // バンド 1,3,5 を入、2,4 を切。周波数も全部違う値に。
        for i in 0..<5 { v[en.offset + i] = (i % 2 == 0) ? 1 : 0 }
        for (i, f) in [111, 222, 333, 444, 555].enumerated() { v[freq.offset + i] = Float(f) }

        let back = ETParamCoding.decode(params: s.params, defaults: s.defaults,
                                        from: ETParamCoding.encode(params: s.params, values: v))
        for i in 0..<5 {
            XCTAssertEqual(back[en.offset + i], v[en.offset + i], "バンド\(i + 1) の en")
            XCTAssertEqual(back[freq.offset + i], v[freq.offset + i], "バンド\(i + 1) の f")
        }
    }

    /// **これが元の欠陥。**
    /// `shortForm` は `encode` の結果へ後から `o["en"] = 段の入切` を足す。
    /// バンドの en が `bs` の中に居れば、そこは潰れない。
    func testStageEnabledDoesNotEatBandEnables() throws {
        let s = try spec("FiveBandDynamicEQ")
        let en = try XCTUnwrap(s.params.first { $0.memberKey == "en" })
        var v = s.defaults
        for i in 0..<5 { v[en.offset + i] = (i == 2) ? 1 : 0 }   // 3 本目だけ入

        var o = ETParamCoding.encode(params: s.params, values: v)
        o["en"] = false                                          // 段を切る（shortForm と同じ）

        let back = ETParamCoding.decode(params: s.params, defaults: s.defaults, from: o)
        XCTAssertEqual(back[en.offset + 2], 1, "バンド3 が段の入切に潰されている")
        for i in [0, 1, 3, 4] {
            XCTAssertEqual(back[en.offset + i], 0, "バンド\(i + 1) が既定へ戻っている")
        }
    }

    /// 上流が書いた形（オブジェクト配列）を読めること。
    /// 同梱のシステムプリセットはこの形で入っている。
    func testReadsUpstreamObjectArray() throws {
        let s = try spec("FiveBandDynamicEQ")
        let json: [String: Any] = ["bs": [
            [:],
            [:],
            ["en": true, "ft": "hs", "f": 2517.85, "q": 0.82, "mg": 1.0],
            [:],
            [:],
        ]]
        let v = ETParamCoding.decode(params: s.params, defaults: s.defaults, from: json)
        let en = try XCTUnwrap(s.params.first { $0.memberKey == "en" })
        let ft = try XCTUnwrap(s.params.first { $0.memberKey == "ft" })
        let f = try XCTUnwrap(s.params.first { $0.memberKey == "f" })

        XCTAssertEqual(v[en.offset + 2], 1)
        XCTAssertEqual(v[f.offset + 2], 2517.85, accuracy: 0.01)
        // "hs" は選択肢 ["pk","ls","hs"] の 2 番
        XCTAssertEqual(v[ft.offset + 2], 2)
        // 触っていないバンドは既定のまま
        XCTAssertEqual(v[f.offset + 0], s.defaults[f.offset + 0])
    }

    /// 平らな配列で書かれた古い保存も読めること（作った鎖を失わない）。
    func testStillReadsOldFlatArrays() throws {
        let s = try spec("FiveBandDynamicEQ")
        let f = try XCTUnwrap(s.params.first { $0.memberKey == "f" })
        let v = ETParamCoding.decode(params: s.params, defaults: s.defaults,
                                     from: ["f": [11, 22, 33, 44, 55]])
        for (i, want) in [11, 22, 33, 44, 55].enumerated() {
            XCTAssertEqual(v[f.offset + i], Float(want))
        }
    }

    /// 古い保存の平らな `en` は **Bool** で入っている（段の入切が潰したもの）。
    /// これをバンド1へ入れてはいけない。
    func testIgnoresScalarValueForObjectMember() throws {
        let s = try spec("FiveBandDynamicEQ")
        let en = try XCTUnwrap(s.params.first { $0.memberKey == "en" })
        let v = ETParamCoding.decode(params: s.params, defaults: s.defaults, from: ["en": true])
        for i in 0..<5 {
            XCTAssertEqual(v[en.offset + i], s.defaults[en.offset + i],
                           "バンド\(i + 1) に段の入切が入った")
        }
    }

    // MARK: - 添字付きの配列

    /// **上流は配列を `f0 f1 f2 …` と書く。** 平らな `"f": [...]` では読めない。
    /// これを書いていたせいで、同梱プリセットの 5Band PEQ が既定のまま載り、
    /// 曲線が平坦になっていた。
    func testWritesIndexedKeysForPlainArrays() throws {
        let s = try spec("FiveBandPEQPlugin")
        let o = ETParamCoding.encode(params: s.params, values: s.defaults)
        for i in 0..<5 {
            XCTAssertNotNil(o["f\(i)"], "f\(i) が無い")
            XCTAssertNotNil(o["g\(i)"], "g\(i) が無い")
        }
        XCTAssertNil(o["f"] as? [Any], "平らな配列を書いている")
        XCTAssertNil(o["g"] as? [Any], "平らな配列を書いている")
    }

    /// 上流が書いた形を読めること。Old R2r Dac のゲインをそのまま使う。
    func testReadsIndexedKeys() throws {
        let s = try spec("FiveBandPEQPlugin")
        let g = try XCTUnwrap(s.params.first { $0.key == "g" })
        let f = try XCTUnwrap(s.params.first { $0.key == "f" })
        let json: [String: Any] = [
            "f0": 20, "g0": 0, "q0": 0.16, "t0": "ap", "e0": true,
            "f1": 316, "g1": -9.40909, "f2": 1000, "g2": 1.63636,
            "f3": 3160, "g3": 5.56363, "f4": 10000, "g4": 9.16363,
        ]
        let v = ETParamCoding.decode(params: s.params, defaults: s.defaults, from: json)
        XCTAssertEqual(v[g.offset + 1], -9.40909, accuracy: 0.001)
        XCTAssertEqual(v[g.offset + 4], 9.16363, accuracy: 0.001)
        XCTAssertEqual(v[f.offset + 0], 20, accuracy: 0.001)
        XCTAssertEqual(v[f.offset + 4], 10000, accuracy: 0.001)
    }

    /// 書いて読んで戻ること。
    func testIndexedRoundTrip() throws {
        let s = try spec("FiveBandPEQPlugin")
        let g = try XCTUnwrap(s.params.first { $0.key == "g" })
        var v = s.defaults
        for (i, x) in [-12, -3, 0, 6, 15].enumerated() { v[g.offset + i] = Float(x) }
        let back = ETParamCoding.decode(params: s.params, defaults: s.defaults,
                                        from: ETParamCoding.encode(params: s.params, values: v))
        for i in 0..<5 { XCTAssertEqual(back[g.offset + i], v[g.offset + i], "バンド\(i + 1)") }
    }

    /// 配列を持つプラグインはすべて object か添字付きで書くこと。平らは 1 つも無い。
    func testNoPluginWritesFlatArrays() {
        for s in ETCatalog {
            let o = ETParamCoding.encode(params: s.params, values: s.defaults)
            for p in s.params where p.isArray {
                XCTAssertNil(o[p.key] as? [Any], "\(s.type).\(p.key) を平らな配列で書いている")
            }
        }
    }

    /// 古い保存（平らな配列）も読めること。作った鎖を失わない。
    func testStillReadsOldFlatArraysForIndexed() throws {
        let s = try spec("FiveBandPEQPlugin")
        let g = try XCTUnwrap(s.params.first { $0.key == "g" })
        let v = ETParamCoding.decode(params: s.params, defaults: s.defaults,
                                     from: ["g": [1, 2, 3, 4, 5]])
        for i in 0..<5 { XCTAssertEqual(v[g.offset + i], Float(i + 1)) }
    }

    // MARK: - 表示と保存がずれるもの

    /// Tilt EQ の Pivot は自然対数で持っている。画面には Hz を出す。
    func testTiltEQPivotShowsHertz() throws {
        let s = try spec("TiltEQPlugin")
        let p = try XCTUnwrap(s.params.first { $0.name == "pivotExponent" })
        // **既定値は丸めてある。** params.json の default は 6.91 で、
        // ln(1000) = 6.907755 ではない。exp(6.91) = 1002.25 なので、
        // 1000 ちょうどを期待すると落ちる（一度それで落とした）。
        // 見るのは「exp を通しているか」であって既定値の丸めではない。
        XCTAssertEqual(p.display(Float(log(1000.0))), 1000, accuracy: 0.5)
        XCTAssertEqual(p.store(1000), Float(log(1000.0)), accuracy: 0.001)
        XCTAssertEqual(p.display(6.91), 1002.25, accuracy: 0.5, "既定の 6.91 は約 1002Hz")
        // 往復
        XCTAssertEqual(p.display(p.store(440)), 440, accuracy: 0.5)
        // 1000 と打って上限 9.9 に挟まれていた（約 19930Hz へ飛ぶ）のが元の欠陥
        XCTAssertLessThan(p.store(1000), 9.9)
    }

    /// **触って外すだけで値が壊れないこと。**
    ///
    /// 打ち込み欄は focus した瞬間に「画面に出ている数」を文字にして入れ、
    /// blur で commit() が `store()` を通して戻す。ここが片側だけ生値だと、
    /// Tilt EQ の Pivot で 1000 が 6.91 に見えたうえ、何も打たずに外すと
    /// ln(6.91)≈1.93 が下限 3.0 に挟まれてピボットが約 20Hz に落ちる。
    /// 実際に一度そう壊した（ParameterRow.swift:306 が生値を渡していた）。
    func testFocusAndBlurKeepsValue() throws {
        let s = try spec("TiltEQPlugin")
        let p = try XCTUnwrap(s.params.first { $0.name == "pivotExponent" })

        // 欄に入る文字は displayValue と同じ作り方をする。
        func text(_ raw: Float) -> String {
            let v = p.display(raw)
            return v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
        }

        for raw in stride(from: Float(3.0), through: 9.9, by: 0.3) {
            let typed = try XCTUnwrap(Float(text(raw)))
            let back = min(max(p.store(typed), 3.0), 9.9)
            XCTAssertEqual(back, raw, accuracy: 0.01,
                           "raw=\(raw) → 欄 \"\(text(raw))\" → \(back) とずれる")
        }
    }

    /// 10 の指数で見せるもの（Bit Error Rate）は変換しないこと。
    /// 上流のラベルが "10^x" なので、指数のまま出すのが正しい。
    func testBitErrorExponentsAreNotConverted() throws {
        for type in ["DigitalErrorEmulatorPlugin", "G726ADPCMSimulatorPlugin"] {
            guard let s = ETCatalog.first(where: { $0.type == type }) else { continue }
            for p in s.params where p.name.hasSuffix("Exponent") {
                XCTAssertEqual(p.display(-6), -6, "\(type).\(p.name) を変換している")
            }
        }
    }

    /// scale を持つのは Tilt EQ の 1 本だけ。増えたら意図した変更か確かめる。
    func testOnlyOneScaledParam() {
        var scaled: [String] = []
        for s in ETCatalog {
            for p in s.params where p.display(1) != 1 || p.display(2) != 2 {
                scaled.append("\(s.type).\(p.name)")
            }
        }
        XCTAssertEqual(scaled, ["TiltEQPlugin.pivotExponent"])
    }
}
