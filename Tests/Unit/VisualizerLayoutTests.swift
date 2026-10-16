//  VisualizerLayoutTests.swift
//  Visualizer のパネルの置き場（VisualizerLayout）。数は設計の値そのまま。
//
//  壊れると: Floating Meters の帯が今と 1 ピクセルでも変わる、パネルの間に隙間や重なりが出る、
//  縦長で Level Meter が細い棒のまま残る、PiP の窓が縦横比と違う形で開く。

import XCTest

final class VisualizerLayoutTests: XCTestCase {

    private func rects(_ placements: [ETVisualizerPlacement]) -> [[Double]] {
        placements.map { [$0.rect.x, $0.rect.y, $0.rect.w, $0.rect.h] }
    }

    func testStripIsTodaysStrip() {
        let kinds: [ETVisualizerPanelKind] = [.spectrogram, .waveform, .spectrum, .stereo, .levelMeter]
        let result = ETVisualizerLayout.place(kinds, analogMode: .vu, ratio: 5)
        XCTAssertEqual(result.map(\.kind), kinds)
        XCTAssertEqual(rects(result), [
            [0, 0, 300, 256],
            [300, 0, 400, 256],
            [700, 0, 300, 256],
            [1000, 0, 216, 256],
            [1216, 0, 64, 256],
        ])
        XCTAssertEqual(result.map(\.horizontal), [false, false, false, false, false])
    }

    func testWideTwoRows() {
        let kinds: [ETVisualizerPanelKind] = [.artwork, .spectrum, .spectrogram, .stereo, .analogMeter, .levelMeter]
        let result = ETVisualizerLayout.place(kinds, analogMode: .vu, ratio: 16.0 / 9.0)
        XCTAssertEqual(rects(result), [
            [0, 0, 383, 381],
            [383, 0, 448, 381],
            [831, 0, 449, 381],
            [0, 381, 287, 339],
            [287, 381, 908, 339],
            [1195, 381, 85, 339],
        ])
        XCTAssertEqual(result.map(\.horizontal), [false, false, false, false, false, false])
    }

    func testTallStacksAndLevelMeterTurnsHorizontal() {
        let kinds: [ETVisualizerPanelKind] = [.spectrum, .spectrogram, .stereo, .analogMeter, .levelMeter]
        let result = ETVisualizerLayout.place(kinds, analogMode: .vu, ratio: 9.0 / 16.0)
        XCTAssertEqual(rects(result), [
            [0, 0, 1280, 1087],
            [0, 1087, 744, 631],
            [744, 1087, 536, 631],
            [0, 1718, 1280, 478],
            [0, 2196, 1280, 80],
        ])
        XCTAssertEqual(result.map(\.horizontal), [false, false, false, false, true])
    }

    func testEmptyAndSingle() {
        XCTAssertEqual(ETVisualizerLayout.place([], analogMode: .vu, ratio: 2), [])
        let one = ETVisualizerLayout.place([.stereo], analogMode: .vu, ratio: 16.0 / 9.0)
        XCTAssertEqual(rects(one), [[0, 0, 1280, 720]])
        XCTAssertFalse(one[0].horizontal)
        // 1 つだけの Level Meter は横向き。
        XCTAssertTrue(ETVisualizerLayout.place([.levelMeter], analogMode: .vu, ratio: 5)[0].horizontal)
    }

    /// どんな組み合わせ・縦横比でも舞台を隙間なく、重ならずに埋める。
    func testPanelsTileTheStageExactly() {
        let all = ETVisualizerPanelKind.allCases
        let ratios = ETVisualizerAspect.allCases.compactMap(\.ratio) + [0.7, 1.9]
        for count in 1...all.count {
            for ratio in ratios {
                let result = ETVisualizerLayout.place(Array(all.prefix(count)), analogMode: .loudness, ratio: ratio)
                let height = (1280 / ratio).rounded()
                var area = 0.0
                for p in result {
                    XCTAssertGreaterThan(p.rect.w, 0, "\(count) \(ratio)")
                    XCTAssertGreaterThan(p.rect.h, 0, "\(count) \(ratio)")
                    XCTAssertGreaterThanOrEqual(p.rect.x, 0)
                    XCTAssertLessThanOrEqual(p.rect.x + p.rect.w, 1280)
                    XCTAssertLessThanOrEqual(p.rect.y + p.rect.h, height + 0.5)
                    area += p.rect.w * p.rect.h
                }
                XCTAssertEqual(area, 1280 * height, accuracy: 1280, "\(count) \(ratio)")
            }
        }
    }

    func testPipPixelSizes() {
        func size(_ aspect: ETVisualizerAspect) -> [Int] {
            let s = ETVisualizerLayout.pipPixelSize(aspect.ratio!)
            return [s.0, s.1]
        }
        XCTAssertEqual(size(.strip), [1280, 256])
        XCTAssertEqual(size(.ultraWide), [1280, 548])
        XCTAssertEqual(size(.wide), [1280, 720])
        XCTAssertEqual(size(.standard), [1280, 960])
        XCTAssertEqual(size(.square), [1280, 1280])
        XCTAssertEqual(size(.tall), [720, 1280])
    }

    func testFitRatioClamps() {
        XCTAssertEqual(ETVisualizerLayout.fitRatio(width: 800, height: 600), 4.0 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(ETVisualizerLayout.fitRatio(width: 100, height: 1000), 9.0 / 16.0, accuracy: 1e-12)
        XCTAssertEqual(ETVisualizerLayout.fitRatio(width: 1000, height: 100), 21.0 / 9.0, accuracy: 1e-12)
        XCTAssertEqual(ETVisualizerLayout.fitRatio(width: 0, height: 100), 16.0 / 9.0, accuracy: 1e-12)
    }
}
