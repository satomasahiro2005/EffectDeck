//  Upstream217Tests.swift
//  EffeTune 2.17.0（DSP 0.17.0）で変わったものの見張り。**Foundation だけ。**
//
//  2.17.0 が足したのは、SFZ Note Player の SoundFont Note Player への改名と Preset（sp0）、
//  MIDI の曲を鳴らす SoundFont Player（SoundFontPlayerPlugin）。効果は 112 から 113 種になった。
//  壊れると: sp0 の位置がずれてカーネルの float が 1 つずれる、hash が食い違って set_params が断られる、
//  SoundFont Player の Interpolation が上流と違う既定（Linear）で始まる、
//  曲を渡す入口が無い型を音量の追従に載せる。
//
//  一覧から外す hiddenTypes は SwiftUI の EffectPickerView の中なので、ここでは見られない
//  （Tests/Tools/test_picker_hidden.py が字で見張る）。

import XCTest

final class Upstream217Tests: XCTestCase {

    private func spec(_ type: String) throws -> ETEffect {
        try XCTUnwrap(ETCatalog.first { $0.type == type }, "\(type) が目録に無い")
    }

    // MARK: 版と目録

    func testUpstreamVersionIs0_17_0() {
        XCTAssertEqual(ETUpstreamVersion, "0.17.0")
        XCTAssertEqual(ETUpstreamAppVersion, "2.17.0", "package.json の版。公式の PC との食い違いの表示に使う")
        XCTAssertEqual(ETCatalog.count, 113)
        XCTAssertEqual(ETCatalog.reduce(0) { $0 + $1.params.count }, 726)
    }

    // MARK: SoundFont Note Player の Preset

    func testNotePlayerPresetParameter() throws {
        let s = try spec("SFZNotePlayerPlugin")
        XCTAssertEqual(s.name, "SoundFont Note Player", "型の名前は SFZ のまま・見せる名前だけが変わった")
        XCTAssertEqual(s.paramsHash, 0x3785c6ed, "カーネルの hash と食い違うと set_params が断られる")
        XCTAssertEqual(s.floatCount, 21)
        XCTAssertEqual(s.defaults.count, 21)
        let sp0 = try XCTUnwrap(s.params.first { $0.key == "sp0" })
        XCTAssertEqual(sp0.name, "preset")
        XCTAssertEqual(sp0.label, "Preset")
        XCTAssertEqual(sp0.offset, 20, "2.15.0 までの位置（dt は 19）は動かない")
        XCTAssertEqual(sp0.defaultValue, -1, "-1 は音源の先頭")
        XCTAssertFalse(sp0.runtimeOnly, "保存する")
        XCTAssertEqual(s.defaults[sp0.offset], -1)
        guard case .number(let lo, let hi, _, _, let isInteger) = sp0.kind else { return XCTFail("sp0 は数") }
        XCTAssertEqual([lo, hi], [-1, 8388607])
        XCTAssertTrue(isInteger)
        XCTAssertEqual(Array(s.params.map(\.key).prefix(2)), ["dt", "sp0"], "createUI では Detection の次")
    }

    func testNotePlayerPresetRoundTrips() throws {
        let s = try spec("SFZNotePlayerPlugin")
        let sp0 = try XCTUnwrap(s.params.first { $0.key == "sp0" })
        let loaded = PipelineStore.parse([["nm": "SoundFont Note Player", "sp0": 4_194_305]], catalog: ETCatalog)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].values[sp0.offset], 4_194_305)
        let written = PipelineStore.shortForm(loaded)[0]
        XCTAssertEqual((written["sp0"] as? NSNumber)?.doubleValue, 4_194_305)
        let none = PipelineStore.parse([["nm": "SoundFont Note Player", "hi": true]], catalog: ETCatalog)
        XCTAssertEqual(none[0].values[sp0.offset], -1, "書いていない鎖は先頭（今までの動き）")
    }

    // MARK: SoundFont Player

    func testSoundFontPlayerIsInTheCatalog() throws {
        let s = try spec("SoundFontPlayerPlugin")
        XCTAssertEqual(s.name, "SoundFont Player")
        XCTAssertEqual(s.category, "others")
        XCTAssertEqual(s.paramsHash, 0x844a0998)
        XCTAssertEqual(s.floatCount, 4)
        XCTAssertEqual(s.params.sorted { $0.offset < $1.offset }.map(\.key), ["mc", "pl", "og", "sq"])
    }

    func testSoundFontPlayerInterpolationDefaultsToFIR32() throws {
        // params.json は 0（Linear）のまま。上流の soundfont_player.js は sq = 1 で始める。
        let s = try spec("SoundFontPlayerPlugin")
        let sq = try XCTUnwrap(s.params.first { $0.key == "sq" })
        XCTAssertEqual(sq.offset, 3)
        XCTAssertEqual(sq.defaultValue, 1)
        XCTAssertEqual(s.defaults, [0, 64, 0, 1])
        guard case .number(let lo, let hi, _, _, let isInteger) = sq.kind else { return XCTFail("sq は数") }
        XCTAssertEqual([lo, hi], [0, 2])
        XCTAssertTrue(isInteger)
        // 書いていない鎖は上流の setParameters と同じく既定（1）。保存した 0 / 2 は残る。
        let loaded = PipelineStore.parse([["nm": "SoundFont Player", "mc": 2]], catalog: ETCatalog)
        XCTAssertEqual(loaded[0].values[sq.offset], 1)
        for choice in [0, 1, 2] {
            let one = PipelineStore.parse([["nm": "SoundFont Player", "sq": choice]], catalog: ETCatalog)
            XCTAssertEqual(one[0].values[sq.offset], Float(choice))
            let written = PipelineStore.shortForm(one)[0]
            XCTAssertEqual((written["sq"] as? NSNumber)?.intValue, choice)
        }
    }

    func testSoundFontPlayerIsNotAutomatable() throws {
        XCTAssertTrue(ETAutomation.excludedTypes.contains("SoundFontPlayerPlugin"))
        XCTAssertFalse(ETAutomation.isAutomatable(try spec("SoundFontPlayerPlugin")))
        XCTAssertFalse(ETAutomation.isAutomatable(try spec("SFZNotePlayerPlugin")))
    }
}
