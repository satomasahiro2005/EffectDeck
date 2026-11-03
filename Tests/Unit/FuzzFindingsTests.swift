//  FuzzFindingsTests.swift
//  Tests/Fuzz（libFuzzer）が見つけた入力を、実機なしの単体テストに固定したもの。
//  1 件ごとに、どの的（Tests/Fuzz/run.sh --target）が何で止まったかを書く。
//
//  鎖を prepare を通さずに読む口（バックアップ・pipeline.last・プリセット）は範囲へ寄せない
//  設計なので、ここで見るのは「落ちない」「NaN・無限を鎖に入れない」「書き戻せる」と、
//  値の大きさが ±ETParamCoding.magnitudeLimit の中にあること（画面の Int(_:) が落ちない）だけ。

import XCTest

final class FuzzFindingsTests: XCTestCase {

    private func parse(_ json: String) throws -> [PipelineStore.Loaded] {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return PipelineStore.parse(object, catalog: ETCatalog)
    }

    private func value(_ item: PipelineStore.Loaded, _ key: String) throws -> Float {
        let p = try XCTUnwrap(item.spec.params.first { $0.key == key }, "\(item.spec.name) に \(key) が無い")
        return item.values[p.offset]
    }

    private func defaultValue(_ item: PipelineStore.Loaded, _ key: String) throws -> Float {
        try XCTUnwrap(item.spec.params.first { $0.key == key }).defaultValue
    }

    /// 書き戻した shortForm が JSON に書けて、読み戻すと同じ字になる。
    private func assertWritesBack(_ loaded: [PipelineStore.Loaded],
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let short = PipelineStore.shortForm(loaded)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(short), "shortForm が JSON に書けない: \(short)",
                      file: file, line: line)
        guard JSONSerialization.isValidJSONObject(short) else { return }
        let first = try JSONSerialization.data(withJSONObject: short, options: [.sortedKeys])
        let again = PipelineStore.parse(try JSONSerialization.jsonObject(with: first), catalog: ETCatalog)
        let second = try JSONSerialization.data(withJSONObject: PipelineStore.shortForm(again),
                                                options: [.sortedKeys])
        XCTAssertEqual(String(decoding: second, as: UTF8.self), String(decoding: first, as: UTF8.self),
                       file: file, line: line)
    }

    // MARK: - pipelineform

    /// **Float に収まらない数（7.8e39）が無限になり、shortForm が JSON に書けなかった。**
    /// 的 pipelineform（Spatial Mapper の rm に 40 桁の数）。Darwin では共有リンクを作るところ
    /// （ETShareLink.link の JSONSerialization.data）が例外で落ち、バックアップは黙って
    /// 書き出せない（ETBackup.data の isValidJSONObject）。無限は DSP へもそのまま渡っていた。
    func testNumberBeyondFloatReadsAsDefault() throws {
        let loaded = try parse(#"[{"nm":"Volume","vl":7777777777777777777777777777777777777770}]"#)
        let item = try XCTUnwrap(loaded.first)
        XCTAssertEqual(try value(item, "vl"), try defaultValue(item, "vl"))
        try assertWritesBack(loaded)
    }

    /// 同じ穴の字の側。**Float(_:) は "nan" "inf" を NaN・無限として読む。**
    /// JSON に NaN は書けないが、字なら書ける（`"vl":"nan"`）。
    func testNaNAndInfinityStringsReadAsDefault() throws {
        for text in ["nan", "NaN", "inf", "-inf", "infinity", "1e39"] {
            let loaded = try parse(#"[{"nm":"Volume","vl":"\#(text)"}]"#)
            let item = try XCTUnwrap(loaded.first)
            XCTAssertEqual(try value(item, "vl"), try defaultValue(item, "vl"), "vl: \"\(text)\"")
            try assertWritesBack(loaded)
        }
    }

    /// **整数のパラメータに Int の外の数があると、shortForm の Int(_:) が落ちた**（アプリごと）。
    /// Hi Pass Filter の fr（isInteger）に 1e30。バックアップを読んで、次に保存・共有したところで落ちる。
    func testHugeIntegerParameterWritesWithoutTrap() throws {
        let loaded = try parse(#"[{"nm":"Hi Pass Filter","fr":1e30}]"#)
        XCTAssertEqual(loaded.count, 1)
        try assertWritesBack(loaded)
    }

    /// 選択肢も同じ。Oscilloscope の tm（Auto / Normal）に 1e30 と無限。
    func testHugeChoiceWritesWithoutTrap() throws {
        let loaded = try parse(#"[{"nm":"Oscilloscope","tm":1e30},{"nm":"Oscilloscope","tm":1e39}]"#)
        XCTAssertEqual(loaded.count, 2)
        try assertWritesBack(loaded)
    }

    /// tidy はどの Float でも落ちず、JSON に書ける値を返す。全部のパラメータ × 端の値。
    /// 鎖の値は decode のほかに画面・プリセットからも来るので、書く側だけでも閉じておく。
    func testTidyAlwaysWritesJSON() {
        let edges: [Float] = [.nan, .infinity, -.infinity, .greatestFiniteMagnitude,
                              -.greatestFiniteMagnitude, 1e30, -1e30, 0x1p53, 9.3e18, -9.3e18, -0.0]
        for effect in ETCatalog {
            for p in effect.params {
                for v in edges {
                    let out = ETParamCoding.tidy(v, p)
                    XCTAssertTrue(JSONSerialization.isValidJSONObject([out]),
                                  "\(effect.name).\(p.key) に \(v) → \(out)")
                }
            }
        }
    }

    // MARK: - 大きさ（P-Fuzz のレビュー）

    /// **Int に入らない数（1e30）が鎖に入り、画面の Int(_:) でアプリごと落ちた。**
    /// Channel Divider と FIR Crossover の bc（バンド数）。ChannelDividerView.bandCount と
    /// FIRCrossoverView の bandCountRow が生の値を Int(value.rounded()) にする。
    /// 上の直しで tidy が落ちなくなったので、その値が pipeline.last に保存されるようにもなっていた。
    func testHugeBandCountIsBoundedBeforeViews() throws {
        let limit = ETParamCoding.magnitudeLimit
        let loaded = try parse(#"[{"nm":"Channel Divider","bc":1e30},{"nm":"FIR Crossover","bc":-1e30}]"#)
        XCTAssertEqual(loaded.count, 2)
        for item in loaded {
            let v = try value(item, "bc")
            XCTAssertLessThanOrEqual(abs(v), limit, item.spec.name)
            guard abs(v) <= limit else { continue }
            // ChannelDividerView.bandCount と同じ式。上限の中なら Int(_:) は落ちない。
            XCTAssertEqual(min(max(Int(v.rounded()), 2), 4), v > 0 ? 4 : 2, item.spec.name)
        }
        try assertWritesBack(loaded)
    }

    /// catalog の全部のパラメータに ±1e30・3e9・Float の最大を入れて、書いて（encode）
    /// JSON を通して読む（decode）。どの形（添字付き・オブジェクト配列・平らな配列・単体）でも、
    /// 読んだ値は ±magnitudeLimit の中。
    func testEveryParameterReadsBounded() throws {
        let limit = ETParamCoding.magnitudeLimit
        for edge: Float in [1e30, -1e30, 3e9, -3e9, .greatestFiniteMagnitude] {
            for effect in ETCatalog where !effect.params.isEmpty {
                let values = [Float](repeating: edge, count: effect.defaults.count)
                let dict = ETParamCoding.encode(params: effect.params, values: values)
                let data = try JSONSerialization.data(withJSONObject: dict)
                let back = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                let read = ETParamCoding.decode(params: effect.params, defaults: effect.defaults,
                                                from: back, type: effect.type)
                XCTAssertEqual(read.count, effect.defaults.count)
                for p in effect.params {
                    for k in p.offset..<(p.offset + p.count) where read.indices.contains(k) {
                        XCTAssertLessThanOrEqual(abs(read[k]), limit,
                                                 "\(effect.name).\(p.key)[\(k - p.offset)] に \(edge)")
                    }
                }
            }
        }
    }

    // MARK: - NaN・無限は前の値（P-Fuzz のレビュー）

    /// **NaN・無限は catalog の既定でなく `defaults`（前の値）を残す。**
    /// エフェクトのプリセットを当てるとき（EffectPresetApply.values）は `defaults` が今の値。
    /// 上の直しで catalog の既定にしていたので、Bass Management の fc の "nan" が、上流の
    /// parseFiniteNumber（前の値。plugin-base.js:1174-1194）と違う 80Hz に落ちていた。
    func testNonFiniteKeepsPreviousValue() throws {
        let bass = try XCTUnwrap(ETCatalog.first { $0.type == "BassManagementPlugin" })
        let fc = try XCTUnwrap(bass.params.first { $0.key == "fc" })
        var current = bass.defaults
        current[fc.offset + 1] = 150
        let read = EffectPresetApply.values(for: bass, params: ["fc": [100, "nan"] as [Any]],
                                            current: current)
        XCTAssertEqual(read[fc.offset], 100)
        XCTAssertEqual(read[fc.offset + 1], 150, "fc[1] の \"nan\" は前の 150 のまま")

        let volume = try XCTUnwrap(ETCatalog.first { $0.name == "Volume" })
        let vl = try XCTUnwrap(volume.params.first { $0.key == "vl" })
        for raw: Any in ["nan", "-inf", "1e39", 1e39] {
            var now = volume.defaults
            now[vl.offset] = -12
            let v = EffectPresetApply.values(for: volume, params: ["vl": raw], current: now)
            XCTAssertEqual(v[vl.offset], -12, "vl: \(raw)")
        }
    }

    /// 範囲の中の値の書き方は変えない（整数は Int、選択肢は綴り、それ以外は Float のまま）。
    func testTidyKeepsOrdinaryValues() throws {
        let hp = try XCTUnwrap(ETCatalog.first { $0.name == "Hi Pass Filter" })
        let fr = try XCTUnwrap(hp.params.first { $0.key == "fr" })
        XCTAssertEqual(ETParamCoding.tidy(87.5, fr) as? Int, 88)
        let scope = try XCTUnwrap(ETCatalog.first { $0.name == "Oscilloscope" })
        let tm = try XCTUnwrap(scope.params.first { $0.key == "tm" })
        XCTAssertEqual(ETParamCoding.tidy(1, tm) as? String, "Normal")
        XCTAssertEqual(ETParamCoding.tidy(5, tm) as? Int, 5)
        let volume = try XCTUnwrap(ETCatalog.first { $0.name == "Volume" })
        let vl = try XCTUnwrap(volume.params.first { $0.key == "vl" })
        XCTAssertEqual(ETParamCoding.tidy(-6.5, vl) as? Float, -6.5)
    }
}
