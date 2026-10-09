//  Upstream212Tests.swift
//  EffeTune 2.12.0（DSP 0.12.0）で増えた・変わったものの、保存形式まわり。**実機もエンジンも要らない。**
//
//    - 新しい 3 種（Analog Meter・Rhythm Analyzer・Tonal Balance EQ）がカタログに入っていること
//    - Oscilloscope の Trigger Mode に Off が増え、hash が変わったこと
//    - 表示だけの設定（Analog Meter の rl / rg / sc / ph / ln / tg / ls、Rhythm Analyzer の sp / vt …）が
//      プリセット・鎖・共有リンクの往復で落ちないこと
//    - Tonal Balance EQ の mp（実行時の旗）を保存形式に書かず・読まないこと
//    - 読み込みで上流の setParameters と同じ所へ着地すること（Rhythm の Min / Max、Tonal の Q）

import XCTest

final class Upstream212Tests: XCTestCase {

    private func spec(_ type: String) throws -> ETEffect {
        try XCTUnwrap(ETCatalog.first { $0.type == type }, "カタログに無い: \(type)")
    }

    private func param(_ s: ETEffect, _ key: String) throws -> ETParam {
        try XCTUnwrap(s.params.first { $0.key == key }, "\(s.type) に \(key) が無い")
    }

    // MARK: カタログ

    // 版とカタログの数は Upstream213Tests が見る（2.13.0 で 112 種）。
    func testNewEffectsAreInTheCatalog() throws {
        let analog = try spec("AnalogMeterPlugin")
        XCTAssertEqual(analog.name, "Analog Meter")
        XCTAssertEqual(analog.category, "analyzer")
        XCTAssertEqual(analog.floatCount, 4)
        XCTAssertEqual(analog.params.map(\.key), ["md", "it", "at", "rt"])
        XCTAssertEqual(analog.defaults, [0, 0.3, 5, 1.5])
        if case .enumeration(let modes) = try param(analog, "md").kind {
            XCTAssertEqual(modes, ETAnalogMeter.modes)
        } else { XCTFail("md は選択") }

        let rhythm = try spec("RhythmAnalyzerPlugin")
        XCTAssertEqual(rhythm.name, "Rhythm Analyzer")
        XCTAssertEqual(rhythm.floatCount, 3)
        XCTAssertEqual(rhythm.params.map(\.key), ["mn", "mx", "ck"])
        XCTAssertEqual(rhythm.defaults, [40, 240, 0])
        // createUI の ...定数 の spread を解いた刻みと単位（Tools/gen_catalog.py）。
        if case .number(let lo, let hi, let step, let unit, let isInteger) = try param(rhythm, "mn").kind {
            XCTAssertEqual([lo, hi, step], [40, 192, 1])
            XCTAssertEqual(unit, "BPM")
            XCTAssertTrue(isInteger)
        } else { XCTFail("mn は数") }
        if case .number(let lo, let hi, _, _, _) = try param(rhythm, "mx").kind {
            XCTAssertEqual([lo, hi], [50, 240])
        } else { XCTFail("mx は数") }

        let tonal = try spec("TonalBalanceEQPlugin")
        XCTAssertEqual(tonal.name, "Tonal Balance EQ")
        XCTAssertEqual(tonal.category, "eq")
        XCTAssertEqual(tonal.floatCount, 36)
        for key in ["ea", "ta", "fa", "ga", "qa"] { XCTAssertEqual(try param(tonal, key).count, 5, key) }
        XCTAssertEqual(try param(tonal, "fa").offset, 18)
        XCTAssertEqual(tonal.defaults[18..<23].map { $0 }, [100, 316, 1000, 3160, 10000])
        XCTAssertEqual(tonal.defaults[28..<33].map { $0 }, [0.7, 0.7, 0.7, 0.7, 0.7])
        XCTAssertEqual(try param(tonal, "tc").label, "Corner", "Slope と Corner は createUI の名前")
        XCTAssertEqual(try param(tonal, "ts").label, "Slope")
        if case .enumeration(let targets) = try param(tonal, "tg").kind {
            XCTAssertEqual(targets, ETTonalBalance.targets)
        } else { XCTFail("tg は選択") }
        // 画面は Smoothing の次に Averaging Time（createAveragingTimeControl が createUI より前にある）。
        let keys = tonal.params.map(\.key)
        XCTAssertEqual(keys.firstIndex(of: "at"), keys.firstIndex(of: "sm").map { $0 + 1 })
    }

    func testOscilloscopeGainsAFreeRunTriggerMode() throws {
        let scope = try spec("OscilloscopePlugin")
        guard case .enumeration(let modes) = try param(scope, "tm").kind else { return XCTFail("tm は選択") }
        XCTAssertEqual(modes, ["Auto", "Normal", "Off"])
        XCTAssertEqual(scope.paramsHash, 0xc0b55527)
    }

    func testNewTypesArePickedAsNew() {
        // Views は Logic のバンドルに入らないので、この表は生成物のカタログで引く。
        for type in ["AnalogMeterPlugin", "RhythmAnalyzerPlugin", "TonalBalanceEQPlugin"] {
            XCTAssertTrue(ETCatalog.contains { $0.type == type }, type)
        }
    }

    // MARK: 表示だけの設定

    func testDisplayTablesForTheNewAnalyzers() {
        XCTAssertEqual(Set(ETDisplayParam.table(for: "AnalogMeterPlugin").keys),
                       ["rl", "rg", "sc", "ph", "ln", "tg", "ls"])
        XCTAssertEqual(Set(ETDisplayParam.table(for: "RhythmAnalyzerPlugin").keys),
                       ["sp", "vt", "vm", "ve", "vl"])
        for key in ["rl", "rg", "sc", "ph", "ln", "tg", "ls"] {
            XCTAssertEqual(ETDisplayParam.table(for: "AnalogMeterPlugin")[key], .number, key)
        }
        XCTAssertEqual(ETDisplayParam.table(for: "RhythmAnalyzerPlugin")["sp"], .number)
        for key in ["vt", "vm", "ve", "vl"] {
            XCTAssertEqual(ETDisplayParam.table(for: "RhythmAnalyzerPlugin")[key], .flag, key)
        }
        // 既定は ANALOG_METER_DEFAULTS / RHYTHM_ANALYZER_DEFAULTS。表の鍵と同じ集合。
        XCTAssertEqual(Set(ETDisplayParam.defaults(for: "AnalogMeterPlugin").keys),
                       Set(ETDisplayParam.table(for: "AnalogMeterPlugin").keys))
        XCTAssertEqual(Set(ETDisplayParam.defaults(for: "RhythmAnalyzerPlugin").keys),
                       Set(ETDisplayParam.table(for: "RhythmAnalyzerPlugin").keys))
        XCTAssertEqual(ETDisplayParam.defaults(for: "AnalogMeterPlugin")["rl"], "-14.0")
        XCTAssertTrue(ETDisplayParam.defaults(for: "StereoMeterPlugin").isEmpty)
    }

    /// 出荷時プリセット 17 件の表示の設定が、鎖の保存形式を往復して残る。
    /// 読まないと、web 版から来た Analog Meter の目盛りがすべて既定に戻る。
    func testAnalogMeterPresetsKeepTheirDisplaySettingsThroughAChain() throws {
        let s = try spec("AnalogMeterPlugin")
        let presets = ETEffectPresetList.filter { $0.effect == "Analog Meter" }
        XCTAssertEqual(presets.count, 17)
        for preset in presets {
            var stage = preset.params
            stage["nm"] = "Analog Meter"
            let loaded = PipelineStore.parse([stage], catalog: ETCatalog)
            let item = try XCTUnwrap(loaded.first, preset.presetId)
            XCTAssertEqual(item.spec.type, s.type)
            XCTAssertEqual(item.display, ETDisplayParam.read(preset.params, type: s.type), preset.presetId)
            XCTAssertEqual(item.display.count, 7, "\(preset.presetId): rl rg sc ph ln tg ls が全部入る")
            // 書き戻しても同じ値の数で出る（JSON を通す）。
            let written = PipelineStore.shortForm(loaded)
            let data = try JSONSerialization.data(withJSONObject: written)
            let back = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
            for key in ["rl", "rg", "sc", "ph", "ln", "tg", "ls"] {
                XCTAssertEqual((back[0][key] as? NSNumber)?.doubleValue,
                               (preset.params[key] as? NSNumber)?.doubleValue, "\(preset.presetId).\(key)")
            }
            XCTAssertEqual(back[0]["md"] as? String, preset.params["md"] as? String, preset.presetId)
        }
    }

    func testRhythmDisplaySettingsRoundTrip() throws {
        let stage: [String: Any] = ["nm": "Rhythm Analyzer", "mn": 80, "mx": 180, "ck": true,
                                    "sp": 12, "vt": false, "vm": true, "ve": false, "vl": true]
        let loaded = PipelineStore.parse([stage], catalog: ETCatalog)
        let item = try XCTUnwrap(loaded.first)
        XCTAssertEqual(item.display, ["sp": "12.0", "vt": "false", "vm": "true", "ve": "false", "vl": "true"])
        let written = PipelineStore.shortForm(loaded)
        XCTAssertEqual(written[0]["sp"] as? Double, 12)
        XCTAssertEqual(written[0]["vt"] as? Bool, false)
        XCTAssertEqual(written[0]["mn"] as? Int, 80)
        XCTAssertEqual(written[0]["ck"] as? Bool, true)
    }

    /// Mode 以外が全部表示の設定の違いなので、一致の判定は表示の設定も見る。
    func testPresetMatchingSeesDisplaySettings() throws {
        let s = try spec("AnalogMeterPlugin")
        var seen: Set<String> = []
        for preset in ETEffectPresetList where preset.effect == "Analog Meter" {
            let applied = EffectPresetApply.values(for: s, params: preset.params, current: s.defaults)
            let display = ETDisplayParam.read(preset.params, type: s.type)
            XCTAssertEqual(EffectPresetApply.matchingPresetId(for: s, current: applied, display: display),
                           preset.presetId)
            seen.insert(preset.presetId)
        }
        XCTAssertEqual(seen.count, 17)
        // 表示の設定を渡さないと、触っていない（既定）と読む。Hot VU が既定と同じ。
        XCTAssertEqual(EffectPresetApply.matchingPresetId(for: s, current: s.defaults), "hot-vu")
        // Reference を動かせば一致しない。
        XCTAssertEqual(EffectPresetApply.matchingPresetId(for: s, current: s.defaults, display: ["rl": "-15.0"]), "")
        // Studio VU の Reference は -18。
        XCTAssertEqual(EffectPresetApply.matchingPresetId(for: s, current: s.defaults, display: ["rl": "-18.0"]),
                       "studio-vu")
    }

    func testDisplayMatchSkipsKeysWithoutADefault() {
        // 既定を持たない型・鍵は比べない（比べられないものを不一致にしない）。
        XCTAssertTrue(ETDisplayParam.matches(["cl": "Rainbow"], display: [:], type: "NoteSpectrogramPlugin"))
        XCTAssertTrue(ETDisplayParam.matches(["rl": -14], display: [:], type: "AnalogMeterPlugin"))
        XCTAssertFalse(ETDisplayParam.matches(["rl": -18], display: [:], type: "AnalogMeterPlugin"))
        XCTAssertTrue(ETDisplayParam.matches(["rl": -18], display: ["rl": "-18.0"], type: "AnalogMeterPlugin"))
        // 2.13.0: Tempogram（vt）と Echo rows（ve）は既定で隠す。Timing lanes（vm）と Beat lens（vl）は出す。
        XCTAssertFalse(ETDisplayParam.matches(["vt": true], display: [:], type: "RhythmAnalyzerPlugin"))
        XCTAssertTrue(ETDisplayParam.matches(["vt": false], display: [:], type: "RhythmAnalyzerPlugin"))
        XCTAssertFalse(ETDisplayParam.matches(["ve": true], display: [:], type: "RhythmAnalyzerPlugin"))
        XCTAssertTrue(ETDisplayParam.matches(["vm": true, "vl": true], display: [:], type: "RhythmAnalyzerPlugin"))
    }

    func testUserPresetKeepsDisplaySettings() throws {
        let s = try spec("AnalogMeterPlugin")
        var node = ETChainNode(spec: s, values: s.defaults)
        // 触っていなければ上流の既定で書く。
        var params = EffectPresetStoreCore.params(for: node)
        XCTAssertEqual((params["rl"] as? Double), -14)
        XCTAssertEqual((params["tg"] as? Double), -23)
        node.display["rl"] = "-20.0"
        params = EffectPresetStoreCore.params(for: node)
        XCTAssertEqual((params["rl"] as? Double), -20)
        XCTAssertEqual(params["md"] as? String, "VU")
        // 持たない型は何も足さない。
        let volume = try spec("VolumePlugin")
        XCTAssertNil(EffectPresetStoreCore.params(for: ETChainNode(spec: volume, values: volume.defaults))["rl"])
    }

    // MARK: Tonal Balance EQ の mp

    func testMeasurementPausedIsRuntimeOnly() throws {
        let s = try spec("TonalBalanceEQPlugin")
        let mp = try param(s, "mp")
        XCTAssertTrue(mp.runtimeOnly)
        XCTAssertEqual(mp.offset, 35)
        XCTAssertEqual(s.params.filter(\.runtimeOnly).map(\.key), ["mp"])
        // 立てても保存形式に出ない。
        var values = s.defaults
        values[mp.offset] = 1
        let encoded = ETParamCoding.encode(params: s.params, values: values)
        XCTAssertNil(encoded["mp"])
        // 5 本の帯域は添字付きで書く（上流の getParameters と同じ）。
        for band in 0..<5 {
            XCTAssertEqual(encoded["ea\(band)"] as? Bool, true)
            XCTAssertEqual(encoded["ta\(band)"] as? String, "pk")
            XCTAssertNotNil(encoded["fa\(band)"])
            XCTAssertNotNil(encoded["ga\(band)"])
            XCTAssertNotNil(encoded["qa\(band)"])
        }
        XCTAssertEqual(encoded["tg"] as? String, "All")
        XCTAssertEqual(encoded["at"] as? Float, 30)
        // 読まない。保存形式に mp が入っていても既定のまま。
        let decoded = ETParamCoding.decode(params: s.params, defaults: s.defaults,
                                           from: ["mp": true], type: s.type)
        XCTAssertEqual(decoded[mp.offset], 0)
        // 鎖の語彙（chain/）にも出ない（ChainTextTests.testVocabularyMatchesCatalog）。
    }

    func testTonalBalanceRoundTrip() throws {
        let s = try spec("TonalBalanceEQPlugin")
        let params: [String: Any] = [
            "tg": "Tilt", "am": 80, "rg": 9, "sm": 0.75, "at": 100, "lo": 40, "hi": 12000, "sp": 85.5,
            "ts": -4.5, "tc": 300,
            "ea0": false, "ta0": "ls", "fa0": 80, "ga0": 3.5, "qa0": 1.2,
            "ea4": true, "ta4": "hs", "fa4": 12000, "ga4": -2, "qa4": 0.9,
        ]
        let values = ETParamCoding.decode(params: s.params, defaults: s.defaults, from: params, type: s.type)
        let encoded = ETParamCoding.encode(params: s.params, values: values)
        for (key, raw) in params {
            if let want = raw as? Double { XCTAssertEqual((encoded[key] as? NSNumber)?.doubleValue ?? .nan, want, accuracy: 1e-6, key) }
            else if let want = raw as? Int { XCTAssertEqual((encoded[key] as? NSNumber)?.intValue, want, key) }
            else if let want = raw as? String { XCTAssertEqual(encoded[key] as? String, want, key) }
            else if let want = raw as? Bool { XCTAssertEqual(encoded[key] as? Bool, want, key) }
        }
    }

    /// シェルフ（ls / hs）の Q は 2 まで。peaking は 10 まで（tonal_balance_eq.js:331-336）。
    func testTonalBalanceShelfQIsCappedOnLoad() throws {
        let s = try spec("TonalBalanceEQPlugin")
        let qa = try param(s, "qa")
        let values = ETParamCoding.decode(
            params: s.params, defaults: s.defaults,
            from: ["ta0": "ls", "qa0": 5, "ta1": "pk", "qa1": 5, "ta2": "hs", "qa2": 1.5, "ta3": "pk", "qa3": 50,
                   "ta4": "pk", "qa4": 0.01],
            type: s.type)
        XCTAssertEqual(values[qa.offset], 2)
        XCTAssertEqual(values[qa.offset + 1], 5)
        XCTAssertEqual(values[qa.offset + 2], 1.5)
        XCTAssertEqual(values[qa.offset + 3], 10)
        XCTAssertEqual(values[qa.offset + 4], 0.1)
    }

    // MARK: Rhythm Analyzer の Min / Max

    func testRhythmRangeRuleOnLoad() throws {
        let s = try spec("RhythmAnalyzerPlugin")
        let mn = try param(s, "mn"), mx = try param(s, "mx")
        func load(_ dict: [String: Any], current: [Float]? = nil) -> (Float, Float) {
            let v = ETParamCoding.decode(params: s.params, defaults: current ?? s.defaults, from: dict, type: s.type)
            return (v[mn.offset], v[mx.offset])
        }
        // どちらも書いてあれば、Min が先で、足りなければ Max が上がる。
        XCTAssertTrue(load(["mn": 100, "mx": 110]) == (100, 125))
        // Max だけ。範囲の中で Min の 1.25 倍に届かないなら Min が下がる。
        var current = s.defaults
        current[mn.offset] = 100
        current[mx.offset] = 200
        XCTAssertTrue(load(["mx": 120], current: current) == (96, 120))
        // 範囲の外の Max は Min を下げず、Max が上がる。
        XCTAssertTrue(load(["mx": 10], current: current) == (100, 125))
        // Min だけ。Max が足りなければ上がる。
        XCTAssertTrue(load(["mn": 190], current: current) == (190, 238))
        // 何も書いていなければ今のまま。
        XCTAssertTrue(load([:], current: current) == (100, 200))
    }

    func testRhythmNeverLeavesTheKernelAnInvalidRange() throws {
        let s = try spec("RhythmAnalyzerPlugin")
        let mn = try param(s, "mn"), mx = try param(s, "mx")
        for a in stride(from: 0.0, through: 300, by: 23) {
            for b in stride(from: 0.0, through: 300, by: 29) {
                let v = ETParamCoding.decode(params: s.params, defaults: s.defaults,
                                             from: ["mn": a, "mx": b], type: s.type)
                XCTAssertGreaterThanOrEqual(v[mx.offset], v[mn.offset] * 1.25 - 1e-4, "mn \(a) mx \(b)")
                XCTAssertLessThanOrEqual(v[mx.offset], 240)
                XCTAssertGreaterThanOrEqual(v[mn.offset], 40)
            }
        }
    }

    // MARK: 新しい枠の種類

    func testFrameTypeNumbersMatchUpstream() {
        XCTAssertEqual(ETFrameType.analogMeter.rawValue, 27)
        XCTAssertEqual(ETFrameType.rhythmAnalyzer.rawValue, 28)
        XCTAssertEqual(ETFrameType.tonalBalance.rawValue, 29)
    }
}
