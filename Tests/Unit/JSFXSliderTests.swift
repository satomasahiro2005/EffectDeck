//  JSFXSliderTests.swift
//  つまみの目録と曲線。設計 §8.1 / §8.2 / §8.3 / §8.4。
//
//  **綴りと番号がずれる所。**JSFX の `slider1` は index 0 で、`slider8` は
//  index 7。番号は飛んでいてよく、ETJSFX_SliderCount が返すのは「在る数」で
//  最大の番号ではない。UI は ordinal で並べて index で書くので、
//  この対応が崩れると別のつまみが動く。
//
//  曲線の形（shape）は ysfx の並び: 0 = linear, 1 = log, 2 = sqr
//  （ysfx.cpp: ysfx_normalized_to_ysfx_value の switch）。

import XCTest

final class JSFXSliderTests: XCTestCase {

    // MARK: - §8.1 目録

    func testContiguousSliderMetadata() throws {
        let host = try JSFX.load("sliders")
        let sliders = host.sliders()
        XCTAssertEqual(host.sliderCount, 4)
        XCTAssertEqual(sliders.map(\.index), [0, 1, 2, 3])
        XCTAssertEqual(sliders.map(\.name),
                       ["Linear (dB)", "Frequency (Hz)", "Enum", "Plain"])

        let decibels = sliders[0]
        XCTAssertEqual(decibels.minimum, -60)
        XCTAssertEqual(decibels.maximum, 12)
        XCTAssertEqual(decibels.step, 0.1)
        XCTAssertEqual(decibels.value, 0)
        XCTAssertEqual(decibels.shape, JSFXHost.Shape.linear.rawValue)
        XCTAssertTrue(decibels.visible)

        // enum は index で引く（ordinal ではない）。
        XCTAssertEqual(host.enumNames(index: 2), ["Off", "Low", "Mid", "High"])
        // enum でないつまみは 0 本。
        XCTAssertEqual(ETJSFX_SliderEnumCount(host.raw, 0), 0)
        XCTAssertEqual(ETJSFX_SliderEnumCount(host.raw, 3), 0)
    }

    /// 番号が飛んでいる場合と、曲線・非表示・enum の全部。
    func testSparseSliderMetadataAndShapes() throws {
        let host = try JSFX.load("slider_curves")
        let sliders = host.sliders()
        XCTAssertEqual(host.sliderCount, 4)
        // slider1 / slider3 / slider5 / slider8 → 0 / 2 / 4 / 7。
        XCTAssertEqual(sliders.map(\.index), [0, 2, 4, 7])
        XCTAssertEqual(sliders.map(\.ordinal), [0, 1, 2, 3])
        XCTAssertEqual(sliders.map(\.shape), [
            JSFXHost.Shape.log.rawValue,
            JSFXHost.Shape.square.rawValue,
            JSFXHost.Shape.linear.rawValue,
            JSFXHost.Shape.linear.rawValue,
        ])
        XCTAssertEqual(sliders.map(\.name),
                       ["Log frequency", "Square curve", "Hidden state", "Enum"])
        // 説明の頭の `-` は「初めは隠す」で、名前には残らない。
        XCTAssertEqual(sliders.map(\.visible), [true, true, false, true])
        XCTAssertEqual(sliders.map(\.value), [1000, 0.5, 0, 2])
        XCTAssertEqual(sliders.map(\.minimum), [20, 0, 0, 0])
        XCTAssertEqual(sliders.map(\.maximum), [20000, 1, 1, 3])
        XCTAssertEqual(sliders.map(\.step), [1, 0.001, 1, 1])
        XCTAssertEqual(host.enumNames(index: 7), ["Off", "Low", "Mid", "High"])
    }

    /// 在る数より先は false。UI は ordinal で回すので、ここで止まらないと
    /// 読めない名前が並ぶ。
    func testSliderInfoRejectsOrdinalsPastTheEnd() throws {
        let host = try JSFX.load("sliders")
        var index: UInt32 = 0, shape: UInt8 = 0
        var name: UnsafePointer<CChar>?
        var value = 0.0, minimum = 0.0, maximum = 0.0, step = 0.0
        var visible = false
        XCTAssertFalse(ETJSFX_SliderInfo(host.raw, host.sliderCount, &index, &name, &value,
                                         &minimum, &maximum, &step, &shape, &visible))
        // 在らない index の enum は空で、名前は nil。
        XCTAssertEqual(ETJSFX_SliderEnumCount(host.raw, 999), 0)
        XCTAssertNil(ETJSFX_SliderEnumName(host.raw, 999, 0))
        XCTAssertEqual(ETJSFX_SliderToNormalized(host.raw, 999, 0.5), 0)
        XCTAssertEqual(ETJSFX_SliderFromNormalized(host.raw, 999, 0.5), 0)
    }

    // MARK: - §8.2 正規化

    /// 101 点の往復。**曲線を足したときにここが最初に落ちる。**
    func testNormalizedRoundTripForEveryCurve() throws {
        let host = try JSFX.load("slider_curves")
        for slider in host.sliders() {
            for step in 0...100 {
                let normalized = Double(step) / 100
                let value = ETJSFX_SliderFromNormalized(host.raw, slider.index, normalized)
                let back = ETJSFX_SliderToNormalized(host.raw, slider.index, value)
                XCTAssertEqual(back, normalized, accuracy: 1e-9,
                               "index \(slider.index) shape \(slider.shape) at \(normalized)")
            }
        }
    }

    /// 端点は min / max ちょうど。
    func testNormalizedEndpointsHitTheRange() throws {
        let host = try JSFX.load("slider_curves")
        for slider in host.sliders() {
            let span = slider.maximum - slider.minimum
            XCTAssertEqual(ETJSFX_SliderFromNormalized(host.raw, slider.index, 0),
                           slider.minimum, accuracy: span * 1e-9, "index \(slider.index) 下端")
            XCTAssertEqual(ETJSFX_SliderFromNormalized(host.raw, slider.index, 1),
                           slider.maximum, accuracy: span * 1e-9, "index \(slider.index) 上端")
        }
    }

    /// 範囲の外は端へ寄せる（ETJSFX_SliderFromNormalized の clamp）。
    func testNormalizedInputIsClamped() throws {
        let host = try JSFX.load("slider_curves")
        for slider in host.sliders() {
            XCTAssertEqual(ETJSFX_SliderFromNormalized(host.raw, slider.index, -0.5),
                           ETJSFX_SliderFromNormalized(host.raw, slider.index, 0),
                           "index \(slider.index)")
            XCTAssertEqual(ETJSFX_SliderFromNormalized(host.raw, slider.index, 1.5),
                           ETJSFX_SliderFromNormalized(host.raw, slider.index, 1),
                           "index \(slider.index)")
        }
    }

    /// 曲線ごとの中央。**log の `=1000` は「つまみの真ん中に来る値」**で、
    /// sqr の既定は 2 乗。往復テストは形が入れ替わっていても通るので、
    /// 中央を別に見る。
    func testCurveMidpoints() throws {
        let host = try JSFX.load("slider_curves")
        XCTAssertEqual(ETJSFX_SliderFromNormalized(host.raw, 0, 0.5), 1000, accuracy: 0.01)
        XCTAssertEqual(ETJSFX_SliderFromNormalized(host.raw, 2, 0.5), 0.25, accuracy: 1e-9)
        XCTAssertEqual(ETJSFX_SliderToNormalized(host.raw, 2, 0.25), 0.5, accuracy: 1e-9)
        // linear は 0 を跨いでいても素直な比（raw 版ではない）。
        // -60..12 の 0 は 0.5 ではなく 60/72。
        let host2 = try JSFX.load("sliders")
        XCTAssertEqual(ETJSFX_SliderToNormalized(host2.raw, 0, 0), 60.0 / 72.0, accuracy: 1e-12)
        XCTAssertEqual(ETJSFX_SliderFromNormalized(host2.raw, 0, 0.5), -24, accuracy: 1e-12)
    }

    // MARK: - §8.3 値の更新

    /// S01。**process を待たずに GetSlider が返る。**UI は指を離した瞬間に
    /// 読み直すので、ここが遅れるとつまみが戻って見える。
    func testSetSliderUpdatesTheCacheImmediately() throws {
        let host = try JSFX.load("gain")
        XCTAssertEqual(host.get(0), 1)
        host.set(0, 0.25)
        XCTAssertEqual(host.get(0), 0.25)
        XCTAssertEqual(host.sliders()[0].value, 0.25)
    }

    /// **C の口は範囲を見ない。**min/max の丸めは ETJSFXHost.swift の
    /// setParameter が持っている（あちらは実機側なのでここでは測れない）。
    /// 役割の境目を固定しておく。
    func testSetSliderDoesNotClampAtTheCLayer() throws {
        let host = try JSFX.load("gain")
        host.set(0, 99)
        XCTAssertEqual(host.get(0), 99)
        host.set(0, -99)
        XCTAssertEqual(host.get(0), -99)
        // 在らない index は捨てる（ysfx_max_sliders = 256）。
        ETJSFX_SetSlider(host.raw, 1000, 1)
        XCTAssertEqual(ETJSFX_GetSlider(host.raw, 1000), 0)
    }

    // MARK: - §8.4 JSFX 側からの変更

    /// sliderchange() と slider_show() が ConsumeSliderChange に出る。
    /// **2 回目は false。**取りこぼすと画面が古いまま、立てっぱなしだと
    /// 毎回読み直して UI が固まる。
    func testSliderChangeAndVisibilityAreReportedOnce() throws {
        let host = try JSFX.load("slider_notify")
        // Create 直後は「見える状態になった」ぶんが 1 度立っている。ここで流す。
        host.run(blocks: 1)
        _ = ETJSFX_ConsumeSliderChange(host.raw)
        XCTAssertFalse(ETJSFX_ConsumeSliderChange(host.raw))

        // slider1 = 1 → @block が slider2 を書いて sliderchange する。
        host.set(0, 1)
        host.run(blocks: 1)
        XCTAssertEqual(host.get(1), 42)
        XCTAssertTrue(ETJSFX_ConsumeSliderChange(host.raw))
        XCTAssertFalse(ETJSFX_ConsumeSliderChange(host.raw))

        // slider1 = 2 → slider2 を隠す。見え方の変化も同じ口から出る。
        host.set(0, 2)
        host.run(blocks: 1)
        XCTAssertTrue(ETJSFX_ConsumeSliderChange(host.raw))
        XCTAssertFalse(ETJSFX_ConsumeSliderChange(host.raw))
        XCTAssertEqual(host.sliders().map(\.visible), [true, false])
    }
}
