//  VisualizerPaletteTests.swift
//  Visualizer のスペクトログラムの色（VisualizerPalette）。
//
//  壊れると: Floating Meters のスペクトログラムの色が今と変わる、
//  EffeTune の Heatmap が上流の表（Spectrogram の getHeatmapLuts）とずれる。

import XCTest

final class VisualizerPaletteTests: XCTestCase {

    func testClassicHeatEnds() {
        XCTAssertEqual(ETVisualizerPalette.classicHeat(-84), 0xFF05030F)
        XCTAssertEqual(ETVisualizerPalette.classicHeat(-6), 0xFFFFE696)
    }

    func testClassicHeatClamps() {
        XCTAssertEqual(ETVisualizerPalette.classicHeat(-300), ETVisualizerPalette.classicHeat(-84))
        XCTAssertEqual(ETVisualizerPalette.classicHeat(40), ETVisualizerPalette.classicHeat(-6))
        XCTAssertEqual(ETVisualizerPalette.classicHeat(-.infinity), ETVisualizerPalette.classicHeat(-84))
    }

    func testClassicHeatIsOpaque() {
        for db in stride(from: Float(-100), through: 0, by: 7) {
            XCTAssertEqual(ETVisualizerPalette.classicHeat(db) >> 24, 0xFF)
        }
    }

    func testEffeTuneLUTEnds() {
        let lut = ETVisualizerPalette.effetuneHeat
        XCTAssertEqual(lut.count, 256)
        XCTAssertEqual(lut[0], 0xFF000000)
        // 白（255）の 0.75 倍 = 191.25 → 191。
        XCTAssertEqual(lut[255], 0xFFBFBFBF)
    }

    func testEffeTuneLUTFollowsTheUpstreamStops() {
        let lut = ETVisualizerPalette.effetuneHeat
        // 85/255 = 0.33333 は 0.333 の停止点（シアン）のすぐ先。
        XCTAssertEqual(lut[85], 0xFF00BFBF)
        // 128/255 = 0.50196 は 0.5 の停止点（緑）のすぐ先で、赤がわずかに混ざり始める。
        XCTAssertEqual(lut[128], 0xFF02BF00)
    }

    func testEffeTuneColorClampsAndRounds() {
        XCTAssertEqual(ETVisualizerPalette.effetuneColor(-1), ETVisualizerPalette.effetuneHeat[0])
        XCTAssertEqual(ETVisualizerPalette.effetuneColor(2), ETVisualizerPalette.effetuneHeat[255])
        XCTAssertEqual(ETVisualizerPalette.effetuneColor(0.5), ETVisualizerPalette.effetuneHeat[128])
    }

    func testPackBGRA() {
        XCTAssertEqual(packBGRA(1, 0, 0), 0xFFFF0000)
        XCTAssertEqual(packBGRA(0, 1, 0), 0xFF00FF00)
        XCTAssertEqual(packBGRA(0, 0, 1), 0xFF0000FF)
        XCTAssertEqual(packBGRA(2, -1, 0.5), 0xFFFF0080)
    }
}
