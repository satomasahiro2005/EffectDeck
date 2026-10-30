//  Upstream215Tests.swift
//  EffeTune 2.15.0（DSP 0.15.0）で変わったものの見張り。**Foundation だけ。**
//
//  2.15.0 が足したのは SFZ Note Player の Detection（dt）。効果は増えていない（112 種のまま）。
//  壊れると: Detection が保存されない・読めない（Event の鎖が Classic で開く）、
//  SFZ のパラメータの hash がカーネルとずれて et_instance_set_params が全部断られる。

import XCTest

final class Upstream215Tests: XCTestCase {

    private func spec(_ type: String) throws -> ETEffect {
        try XCTUnwrap(ETCatalog.first { $0.type == type }, "\(type) が目録に無い")
    }

    // MARK: 版と目録

    /// 版の見張りは Upstream216Tests へ移った（2.16.0 も効果を足していない。112 のまま）。
    func testCatalogStillHas112Effects() {
        XCTAssertEqual(ETCatalog.count, 112)
    }

    func testSFZDetectionParameter() throws {
        let sfz = try spec("SFZNotePlayerPlugin")
        XCTAssertEqual(sfz.paramsHash, 0xdfb4bbc5, "カーネルの hash と食い違うと set_params が断られる")
        XCTAssertEqual(sfz.floatCount, 20)
        XCTAssertEqual(sfz.defaults.count, 20)
        let dt = try XCTUnwrap(sfz.params.first { $0.key == "dt" })
        XCTAssertEqual(dt.name, "detection")
        XCTAssertEqual(dt.label, "Detection")
        XCTAssertEqual(dt.offset, 19)
        XCTAssertEqual(dt.defaultValue, 0, "Classic")
        XCTAssertFalse(dt.runtimeOnly, "保存する")
        guard case .enumeration(let options) = dt.kind else { return XCTFail("dt は選択") }
        XCTAssertEqual(options, ["Classic", "Event"])
        XCTAssertEqual(sfz.params.first?.key, "dt", "createUI では Detection が bankRow の次")
        // 2.14.0 の試し弾きの位置は動かない。
        XCTAssertEqual(try XCTUnwrap(sfz.params.first { $0.key == "pm" }).offset, 17)
        XCTAssertEqual(try XCTUnwrap(sfz.params.first { $0.key == "pv" }).offset, 18)
    }

    // MARK: 読み書き

    func testChainWithoutDetectionLoadsAsClassic() throws {
        let sfz = try spec("SFZNotePlayerPlugin")
        let loaded = PipelineStore.parse([["nm": "SFZ Note Player", "hi": true]], catalog: ETCatalog)
        let dt = try XCTUnwrap(sfz.params.first { $0.key == "dt" })
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].values[dt.offset], 0)
        let written = PipelineStore.shortForm(loaded)[0]
        XCTAssertEqual(written["dt"] as? String, "Classic", "既定でも書く（上流の getParameters と同じ）")
    }

    func testEventRoundTrips() throws {
        let sfz = try spec("SFZNotePlayerPlugin")
        let dt = try XCTUnwrap(sfz.params.first { $0.key == "dt" })
        let loaded = PipelineStore.parse([["nm": "SFZ Note Player", "dt": "Event"]], catalog: ETCatalog)
        XCTAssertEqual(loaded[0].values[dt.offset], 1)
        let written = PipelineStore.shortForm(loaded)[0]
        XCTAssertEqual(written["dt"] as? String, "Event")
        let again = PipelineStore.parse([written], catalog: ETCatalog)
        XCTAssertEqual(again[0].values[dt.offset], 1)
    }

    /// 'Classic' / 'Event' 以外の字。上流は捨てていまの値のまま（sfz_note_player.js:80）だが、こちらは選択肢の
    /// 読み方が全部の効果で同じ（ETParamCoding.number: 読めない字は catalog の既定）。Classic になる。
    /// 書き出す側は必ず 'Classic' / 'Event' なので、ここへ来るのは手で書いた字だけ。
    func testUnknownDetectionFallsBackToTheCatalogDefault() throws {
        let sfz = try spec("SFZNotePlayerPlugin")
        let dt = try XCTUnwrap(sfz.params.first { $0.key == "dt" })
        var current = sfz.defaults
        current[dt.offset] = 1
        let loaded = ETParamCoding.decode(params: sfz.params, defaults: current, from: ["dt": "Turbo"], type: sfz.type)
        XCTAssertEqual(loaded[dt.offset], 0)
        // 鍵が無いときはいまの値のまま（プリセットを当てるときの defaults はいまの値）。
        let absent = ETParamCoding.decode(params: sfz.params, defaults: current, from: [:], type: sfz.type)
        XCTAssertEqual(absent[dt.offset], 1)
    }

    // MARK: Threshold と Retrigger Drop

    /// Event の間は止める（ETParamGate。ParamGateTests が表の全部を見る）。値は残る。
    func testEventStopsOnlyThresholdAndRetriggerDrop() throws {
        let sfz = try spec("SFZNotePlayerPlugin")
        func gated(_ key: String, dt: Float) -> Bool {
            ETParamGate.isDisabled(type: sfz.type, key: key) { $0 == "dt" ? dt : nil }
        }
        XCTAssertTrue(gated("th", dt: 1))
        XCTAssertTrue(gated("rd", dt: 1))
        XCTAssertFalse(gated("th", dt: 0))
        XCTAssertFalse(gated("rd", dt: 0))
    }
}
