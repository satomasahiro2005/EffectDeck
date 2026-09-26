//  OversamplingTests.swift
//  Oversampling（os）の保存形式。**実機もエンジンも要らない。**
//
//  os は kind が .number のまま、許される値だけを ETAllowedValues の表で持つ。
//  見張るのは 4 つ:
//    - 数のまま書いて数のまま読む（web 版と同じ。添字や文字列にしない）
//    - os が無い古い鎖（2.10.0 以前）は 1 で読む
//    - 許されない値は捨てて、その前の値を残す（上流の isAllowedEnum）
//    - 表と catalog が食い違っていない
//  本物の ETCatalog に対して測る。

import XCTest

final class OversamplingTests: XCTestCase {

    /// 表に載っている型と、それぞれの最大。
    private let maxima: [String: Float] = [
        "SaturationPlugin": 8,
        "DynamicSaturationPlugin": 8,
        "ExciterPlugin": 8,
        "HarmonicDistortionPlugin": 8,
        "MultibandSaturationPlugin": 8,
        "HardClippingPlugin": 16,
        "BrickwallLimiterPlugin": 8,
    ]

    private func spec(_ type: String) throws -> ETEffect {
        try XCTUnwrap(ETCatalog.first { $0.type == type }, "\(type) が catalog に無い")
    }

    private func os(_ s: ETEffect) throws -> ETParam {
        try XCTUnwrap(s.params.first { $0.key == "os" }, "\(s.type) に os が無い")
    }

    /// JSON を 1 度通す。共有リンクや iCloud と同じく NSNumber で戻ってくる形で読む。
    private func throughJSON(_ o: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: o)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - 表と catalog

    /// **os を数で持つものは全部表に載っている。**
    /// 載っていないと 1〜8（16）のスライダーになり、3/5/6/7 を選べてしまう。
    /// Tube Simulator の os は Output Circuit の enum なので対象外。
    func testEveryNumericOversamplingIsInTheTable() {
        for s in ETCatalog {
            for p in s.params where p.key == "os" {
                guard case .number = p.kind else { continue }
                XCTAssertNotNil(ETAllowedValues.upstream(type: s.type, key: "os"),
                                "\(s.type).os が ETAllowedValues に無い")
            }
        }
    }

    /// 表の値は catalog の範囲の中にあり、両端が一致する。既定は 1x。
    func testTableMatchesCatalogRange() throws {
        for (type, top) in maxima {
            let s = try spec(type)
            let p = try os(s)
            let allowed = try XCTUnwrap(ETAllowedValues.upstream(type: type, key: "os"))
            guard case .number(let lo, let hi, _, _, let isInteger) = p.kind else {
                XCTFail("\(type).os が数でない"); continue
            }
            XCTAssertTrue(isInteger, type)
            XCTAssertEqual(allowed.first, lo, type)
            XCTAssertEqual(allowed.last, hi, type)
            XCTAssertEqual(hi, top, type)
            XCTAssertEqual(p.defaultValue, 1, type)
            XCTAssertEqual(allowed.first, 1, type)
        }
    }

    /// 表に無い組み合わせは nil。Tube Simulator の os（enum）を巻き込まない。
    func testTableIsKeyedByTypeAndKey() {
        XCTAssertNil(ETAllowedValues.upstream(type: "TubeSimulatorPlugin", key: "os"))
        XCTAssertNil(ETAllowedValues.upstream(type: "SaturationPlugin", key: "dr"))
        XCTAssertNil(ETAllowedValues.upstream(type: "", key: "os"))
    }

    // MARK: - 往復

    /// **数のまま書く。** 上流は `os: 4` と書き、Number(params.os) で読む。
    func testAllowedValuesRoundTripAsNumbers() throws {
        for type in maxima.keys {
            let s = try spec(type)
            let p = try os(s)
            let allowed = try XCTUnwrap(ETAllowedValues.upstream(type: type, key: "os"))
            for v in allowed {
                var values = s.defaults
                values[p.offset] = v
                let json = try throughJSON(ETParamCoding.encode(params: s.params, values: values))
                let written = try XCTUnwrap(json["os"] as? NSNumber, "\(type) os=\(v)")
                XCTAssertEqual(written.intValue, Int(v), "\(type) os=\(v)")
                XCTAssertFalse(json["os"] is String, "\(type) os を文字列で書いている")
                XCTAssertEqual(ETParamCoding.decode(params: s.params, defaults: s.defaults,
                                                    from: json, type: type),
                               values, "\(type) os=\(v)")
            }
        }
    }

    /// Hard Clipping だけ 16x を持つ。
    func testHardClippingKeeps16x() throws {
        let s = try spec("HardClippingPlugin")
        let p = try os(s)
        let v = ETParamCoding.decode(params: s.params, defaults: s.defaults,
                                     from: ["os": 16], type: s.type)
        XCTAssertEqual(v[p.offset], 16)
    }

    // MARK: - 古い鎖

    /// **os が無い鎖（2.10.0 以前の保存・web 版の古いプリセット）は 1 で読む。**
    /// 1 は v2.10.0 と同じ出力（上流の golden が変わっていない）。
    func testLegacyChainWithoutOversamplingReadsOne() throws {
        for type in maxima.keys {
            let s = try spec(type)
            let p = try os(s)
            var legacy = ETParamCoding.encode(params: s.params, values: s.defaults)
            legacy["os"] = nil
            let v = ETParamCoding.decode(params: s.params, defaults: s.defaults,
                                         from: try throughJSON(legacy), type: type)
            XCTAssertEqual(v[p.offset], 1, type)
            XCTAssertEqual(v, s.defaults, type)
        }
    }

    // MARK: - 許されない値

    /// **許されない値は捨てて、前の値を残す。**
    /// 鎖を読むときの「前」は既定なので 1 になる。
    func testDisallowedValueFallsBackToDefault() throws {
        for type in maxima.keys {
            let s = try spec(type)
            let p = try os(s)
            var bad: [Any] = [3, 5, 6, 7, 0, -2, 2.5, 32, "3", "fast"]
            if type != "HardClippingPlugin" { bad.append(16) }
            for raw in bad {
                let v = ETParamCoding.decode(params: s.params, defaults: s.defaults,
                                             from: try throughJSON(["os": raw]), type: type)
                XCTAssertEqual(v[p.offset], 1, "\(type) os=\(raw)")
            }
        }
    }

    /// **プリセットを当てるときの「前」は今の値。** 4x で動いている段に os: 3 の
    /// プリセットを当てても 4x のまま。ほかの鍵は当たる。
    func testDisallowedValueInPresetKeepsCurrent() throws {
        let s = try spec("SaturationPlugin")
        let p = try os(s)
        let drive = try XCTUnwrap(s.params.first { $0.key == "dr" })
        var current = s.defaults
        current[p.offset] = 4
        let out = EffectPresetApply.values(for: s, params: ["os": 3, "dr": 7], current: current)
        XCTAssertEqual(out[p.offset], 4)
        XCTAssertEqual(out[drive.offset], 7)

        let allowed = EffectPresetApply.values(for: s, params: ["os": 8], current: current)
        XCTAssertEqual(allowed[p.offset], 8)
    }

    /// 文字列で来た数も数として読む（上流の Number(params.os) と同じ）。
    func testNumericStringIsAccepted() throws {
        let s = try spec("ExciterPlugin")
        let p = try os(s)
        let v = ETParamCoding.decode(params: s.params, defaults: s.defaults,
                                     from: ["os": "4"], type: s.type)
        XCTAssertEqual(v[p.offset], 4)
    }
}
