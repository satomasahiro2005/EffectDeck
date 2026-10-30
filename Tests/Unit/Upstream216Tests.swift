//  Upstream216Tests.swift
//  EffeTune 2.16.0（DSP 0.16.0）で変わったものの見張り。**Foundation だけ。**
//
//  2.16.0 が足したのは Note Spectrogram の Chords & Key（ck）と Rhythm Analyzer の Display（dm）、
//  Mastering のシステムプリセット 10 本。効果は増えていない（112 種のまま）。
//  壊れると: ck / dm が保存されない・読めない、パラメータの hash がカーネルとずれて
//  et_instance_set_params が断られる、Mastering のプリセットが並ばない。

import XCTest

final class Upstream216Tests: XCTestCase {

    private func spec(_ type: String) throws -> ETEffect {
        try XCTUnwrap(ETCatalog.first { $0.type == type }, "\(type) が目録に無い")
    }

    // MARK: 版と目録

    func testUpstreamVersionIs0_16_0() {
        XCTAssertEqual(ETUpstreamVersion, "0.16.0")
        XCTAssertEqual(ETUpstreamAppVersion, "2.16.0", "package.json の版。公式の PC との食い違いの表示に使う")
        XCTAssertEqual(ETCatalog.count, 112)
    }

    func testNoteSpectrogramChordKeyParameter() throws {
        let s = try spec("NoteSpectrogramPlugin")
        XCTAssertEqual(s.paramsHash, 0xb8518943, "カーネルの hash と食い違うと set_params が断られる")
        XCTAssertEqual(s.floatCount, 4)
        XCTAssertEqual(s.defaults, [28, 91, 0, 0])
        let ck = try XCTUnwrap(s.params.first { $0.key == "ck" })
        XCTAssertEqual(ck.name, "chordKeyEnabled")
        XCTAssertEqual(ck.label, "Chords & Key")
        XCTAssertEqual(ck.offset, 3)
        XCTAssertEqual(ck.defaultValue, 0, "既定は切る")
        XCTAssertFalse(ck.runtimeOnly, "保存する")
        guard case .toggle = ck.kind else { return XCTFail("ck は切り替え") }
        XCTAssertEqual(s.params.first?.key, "ck", "createUI の先頭")
        // 2.14.0 までの位置は動かない。
        XCTAssertEqual(try XCTUnwrap(s.params.first { $0.key == "mn" }).offset, 0)
        XCTAssertEqual(try XCTUnwrap(s.params.first { $0.key == "mx" }).offset, 1)
        XCTAssertEqual(try XCTUnwrap(s.params.first { $0.key == "te" }).offset, 2)
    }

    func testRhythmAnalyzerDisplayParameter() throws {
        let r = try spec("RhythmAnalyzerPlugin")
        XCTAssertEqual(r.paramsHash, 0xf854c585, "カーネルの hash と食い違うと set_params が断られる")
        XCTAssertEqual(r.floatCount, 4)
        XCTAssertEqual(r.defaults, [40, 240, 0, 0])
        let dm = try XCTUnwrap(r.params.first { $0.key == "dm" })
        XCTAssertEqual(dm.name, "displayMode")
        XCTAssertEqual(dm.label, "Display")
        XCTAssertEqual(dm.offset, 3)
        XCTAssertEqual(dm.defaultValue, 0, "band")
        XCTAssertFalse(dm.runtimeOnly, "保存する")
        guard case .enumeration(let options) = dm.kind else { return XCTFail("dm は選択") }
        XCTAssertEqual(options, ["band", "drums"])
        XCTAssertEqual(try XCTUnwrap(r.params.first { $0.key == "mn" }).offset, 0)
        XCTAssertEqual(try XCTUnwrap(r.params.first { $0.key == "mx" }).offset, 1)
        XCTAssertEqual(try XCTUnwrap(r.params.first { $0.key == "ck" }).offset, 2)
    }

    // MARK: 読み書き

    func testOldChainsLoadWithTheNewDefaults() throws {
        let s = try spec("NoteSpectrogramPlugin")
        let r = try spec("RhythmAnalyzerPlugin")
        let loaded = PipelineStore.parse([["nm": "Note Spectrogram", "mn": 40, "mx": 80],
                                          ["nm": "Rhythm Analyzer", "mn": 60, "mx": 180]],
                                         catalog: ETCatalog)
        XCTAssertEqual(loaded.count, 2)
        let ck = try XCTUnwrap(s.params.first { $0.key == "ck" })
        XCTAssertEqual(loaded[0].values[ck.offset], 0)
        XCTAssertEqual(Array(loaded[0].values.prefix(2)), [40, 80])
        let dm = try XCTUnwrap(r.params.first { $0.key == "dm" })
        XCTAssertEqual(loaded[1].values[dm.offset], 0)
        XCTAssertEqual(Array(loaded[1].values.prefix(2)), [60, 180])
    }

    func testDrumsAndChordKeyRoundTrip() throws {
        let s = try spec("NoteSpectrogramPlugin")
        let r = try spec("RhythmAnalyzerPlugin")
        let ck = try XCTUnwrap(s.params.first { $0.key == "ck" })
        let dm = try XCTUnwrap(r.params.first { $0.key == "dm" })
        let loaded = PipelineStore.parse([["nm": "Note Spectrogram", "ck": true],
                                          ["nm": "Rhythm Analyzer", "dm": "drums"]],
                                         catalog: ETCatalog)
        XCTAssertEqual(loaded[0].values[ck.offset], 1)
        XCTAssertEqual(loaded[1].values[dm.offset], 1)
        let written = PipelineStore.shortForm(loaded)
        XCTAssertEqual(written[0]["ck"] as? Bool, true)
        XCTAssertEqual(written[1]["dm"] as? String, "drums")
        let again = PipelineStore.parse(written, catalog: ETCatalog)
        XCTAssertEqual(again[0].values[ck.offset], 1)
        XCTAssertEqual(again[1].values[dm.offset], 1)
    }

    // MARK: Mastering

    func testMasteringSystemPresetsExist() {
        let mastering = ETSystemPresets.filter { $0.category == "Mastering" }
        XCTAssertEqual(mastering.count, 10)
        XCTAssertEqual(Set(mastering.map(\.name)).count, 10, "名前が重ならない")
        XCTAssertTrue(ETSystemPresets.filter { $0.category == "mastering" }.isEmpty, "見出しは大文字で始める")
        XCTAssertEqual(ETSystemPresets.count, 28)
    }
}
