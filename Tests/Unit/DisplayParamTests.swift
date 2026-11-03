//  DisplayParamTests.swift
//  音に関わらない表示の設定（DisplayParams.swift の ETDisplayParam）。
//
//  上流がプリセットに書いている `cl` / `sc` などは params.json に席が無いので、Node に文字列で
//  持ち、保存形式では上流と同じ綴り・同じ型で書く。読み違えると web 版から来た値が往復で消える。

import XCTest

final class DisplayParamTests: XCTestCase {

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    /// 表を持つのは 6 種だけ。ほかは空。
    func testTableCoversTheSixUpstreamTypes() {
        // hl（Highlight）は 2.14.0。
        XCTAssertEqual(Set(ETDisplayParam.table(for: "NoteSpectrogramPlugin").keys),
                       ["cl", "pr", "ly", "vl", "ts", "hl", "os"])
        XCTAssertEqual(Set(ETDisplayParam.table(for: "SpectrogramPlugin").keys), ["sc", "cl", "kb"])
        XCTAssertEqual(Set(ETDisplayParam.table(for: "SpectrumAnalyzerPlugin").keys),
                       ["sc", "dm", "cl", "kb"])
        XCTAssertEqual(Set(ETDisplayParam.table(for: "PitchMeterPlugin").keys), ["ly", "cl"])
        XCTAssertEqual(Set(ETDisplayParam.table(for: "StereoMeterPlugin").keys), ["gn"])
        XCTAssertEqual(Set(ETDisplayParam.table(for: "ChromaSpiralPlugin").keys),
                       ["dm", "lo", "hi", "ft", "lr", "df"])
        XCTAssertTrue(ETDisplayParam.table(for: "VolumePlugin").isEmpty)
        XCTAssertTrue(ETDisplayParam.table(for: "").isEmpty)
        // どれもカタログに居る型。綴りを違えると表が引かれない。
        for type in ["NoteSpectrogramPlugin", "SpectrogramPlugin", "SpectrumAnalyzerPlugin",
                     "PitchMeterPlugin", "StereoMeterPlugin", "ChromaSpiralPlugin"] {
            XCTAssertTrue(ETCatalog.contains { $0.type == type }, type)
        }
    }

    /// JSON から読む。文字はそのまま、数は Double の綴り、真偽は "true" / "false"。
    /// 表に無い鍵は拾わない。
    func testReadFromUpstreamJSON() throws {
        let params = try json(#"{"cl":"Rainbow","vl":true,"ts":3,"pr":"High","zz":1,"f0":100}"#)
        XCTAssertEqual(ETDisplayParam.read(params, type: "NoteSpectrogramPlugin"),
                       ["cl": "Rainbow", "vl": "true", "ts": "3.0", "pr": "High"])
        let chroma = try json(#"{"dm":0,"lo":1.5,"hi":7}"#)
        XCTAssertEqual(ETDisplayParam.read(chroma, type: "ChromaSpiralPlugin"),
                       ["dm": "0.0", "lo": "1.5", "hi": "7.0"])
        XCTAssertEqual(ETDisplayParam.read(params, type: "VolumePlugin"), [:])
    }

    /// 型の違うものは読まずに既定のままにする。
    func testWrongTypesAreSkipped() throws {
        let params = try json(#"{"cl":5,"vl":"yes","ts":"3","kb":"true"}"#)
        XCTAssertEqual(ETDisplayParam.read(params, type: "NoteSpectrogramPlugin"), [:])
        XCTAssertEqual(ETDisplayParam.read(params, type: "SpectrogramPlugin"), [:])
    }

    /// Swift の値で直に渡された場合（書く側の辞書を JSON にせず読む）。
    func testReadFromSwiftValues() {
        let params: [String: Any] = ["gn": 6, "sc": "log", "kb": true, "dm": "bar", "cl": "Gray"]
        XCTAssertEqual(ETDisplayParam.read(params, type: "StereoMeterPlugin"), ["gn": "6.0"])
        XCTAssertEqual(ETDisplayParam.read(params, type: "SpectrumAnalyzerPlugin"),
                       ["sc": "log", "kb": "true", "dm": "bar", "cl": "Gray"])
    }

    /// 書いて JSON にして読み戻すと同じ文字列に戻る。書く型は上流のもの。
    func testWriteThenReadRoundTrips() throws {
        let cases: [(String, [String: String])] = [
            ("NoteSpectrogramPlugin", ["cl": "Instrument3", "pr": "High", "ly": "Piano", "vl": "false", "ts": "2.5",
                                       "hl": "Vocal", "os": "true"]),
            ("SpectrogramPlugin", ["sc": "linear", "cl": "Gray", "kb": "true"]),
            ("SpectrumAnalyzerPlugin", ["sc": "log-hq", "dm": "bar", "cl": "Fire", "kb": "false"]),
            ("PitchMeterPlugin", ["ly": "Guitar", "cl": "Mono"]),
            ("StereoMeterPlugin", ["gn": "12.0"]),
            ("ChromaSpiralPlugin", ["dm": "2.0", "lo": "1.0", "hi": "8.0", "ft": "0.5", "lr": "0.25", "df": "3.0"]),
        ]
        for (type, display) in cases {
            var o: [String: Any] = [:]
            ETDisplayParam.write(display, type: type, into: &o)
            XCTAssertEqual(Set(o.keys), Set(display.keys), type)
            for (key, kind) in ETDisplayParam.table(for: type) {
                switch kind {
                case .text: XCTAssertTrue(o[key] is String, "\(type).\(key)")
                case .number: XCTAssertTrue(o[key] is Double, "\(type).\(key)")
                case .flag: XCTAssertTrue(o[key] is Bool, "\(type).\(key)")
                }
            }
            let data = try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
            let back = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(ETDisplayParam.read(back, type: type), display, type)
        }
    }

    /// 表に無い鍵は書かない。数に読めない文字は 0 で書く（encode）。
    func testWriteIgnoresUnknownKeysAndCoercesNumbers() {
        var o: [String: Any] = [:]
        ETDisplayParam.write(["gn": "abc", "zz": "1"], type: "StereoMeterPlugin", into: &o)
        XCTAssertEqual(o.count, 1)
        XCTAssertEqual(o["gn"] as? Double, 0)
    }
}
