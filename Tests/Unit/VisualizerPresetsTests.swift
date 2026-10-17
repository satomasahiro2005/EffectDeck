//  VisualizerPresetsTests.swift
//  Visualizer の組み込みの場面（VisualizerPresets）。数は設計の値そのまま。
//
//  壊れると: Floating Meters の既定が今の帯から変わる、プリセットが範囲外の矩形で出る、
//  曲を使えない版で曲の要素が出る、丸めで帯に隙間が空く。

import XCTest

final class VisualizerPresetsTests: XCTestCase {

    func testCounts() {
        XCTAssertGreaterThanOrEqual(ETVisualizerPresets.available(allowsSong: false).count, 7)
        XCTAssertGreaterThanOrEqual(ETVisualizerPresets.available(allowsSong: true).count, 8)
        XCTAssertEqual(ETVisualizerPresets.all.count, 8)
        let ids = ETVisualizerPresets.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(ids, ["classic", "studio", "neon", "phosphor", "vintage", "spectral", "ncs", "nowPlaying"])
    }

    func testEveryPresetIsNormalized() {
        for preset in ETVisualizerPresets.all {
            XCTAssertEqual(preset.scene.normalized(), preset.scene, preset.id)
        }
    }

    func testEveryRectIsInsideTheStageAndBothLayoutsHaveElements() {
        for preset in ETVisualizerPresets.all {
            XCTAssertFalse(preset.scene.portrait.isEmpty, preset.id)
            XCTAssertFalse(preset.scene.landscape.isEmpty, preset.id)
            for e in preset.scene.portrait + preset.scene.landscape {
                let r = e.rect
                XCTAssertGreaterThanOrEqual(r.x, 0, preset.id)
                XCTAssertGreaterThanOrEqual(r.y, 0, preset.id)
                XCTAssertLessThanOrEqual(r.x + r.w, 1 + 1e-12, preset.id)
                XCTAssertLessThanOrEqual(r.y + r.h, 1 + 1e-12, preset.id)
                XCTAssertGreaterThanOrEqual(r.w, ETVisualizerScene.minSize, preset.id)
                XCTAssertGreaterThanOrEqual(r.h, ETVisualizerScene.minSize, preset.id)
            }
        }
    }

    func testElementIDsAreFixedAndUnique() {
        var seen = Set<UUID>()
        for preset in ETVisualizerPresets.all {
            for e in preset.scene.portrait + preset.scene.landscape {
                XCTAssertTrue(seen.insert(e.id).inserted, "\(preset.id) \(e.id)")
            }
        }
        XCTAssertEqual(ETVisualizerPresets.classic.landscape[0].id.uuidString, "00000000-0000-0000-0001-000000000000")
        XCTAssertEqual(ETVisualizerPresets.studio.portrait[0].id.uuidString, "00000000-0000-0000-0002-000000000064")
    }

    func testClassicLandscapeIsTodaysStrip() {
        let kinds: [ETVisualizerPanelKind] = [.spectrogram, .waveform, .spectrum, .stereo, .levelMeter]
        let placed = ETVisualizerLayout.place(kinds, analogMode: .vu, ratio: 5)
        let landscape = ETVisualizerPresets.classic.landscape
        XCTAssertEqual(landscape.map(\.kind.rawValue), kinds.map(\.rawValue))
        for (element, placement) in zip(landscape, placed) {
            XCTAssertEqual(element.rect.x, placement.rect.x / 1280, accuracy: 1e-12)
            XCTAssertEqual(element.rect.y, placement.rect.y / 256, accuracy: 1e-12)
            XCTAssertEqual(element.rect.w, placement.rect.w / 1280, accuracy: 1e-12)
            XCTAssertEqual(element.rect.h, placement.rect.h / 256, accuracy: 1e-12)
        }
        XCTAssertTrue(ETVisualizerPresets.classic.portrait.allSatisfy { $0.look == .classic })
        XCTAssertTrue(landscape.allSatisfy { $0.look == .classic && !$0.card })
        XCTAssertEqual(ETVisualizerPresets.classic.background.kind, .solid)
        XCTAssertEqual(ETVisualizerPresets.classic.background.color.rgb, 0)
    }

    func testClassicPixelEdgesAreTheOldIntegers() {
        let edges = ETVisualizerPresets.classic.landscape.map {
            ETVisualizerEditing.pixelEdges($0.rect, width: 1280, height: 256)
        }
        let expected = [(0, 0, 300, 256), (300, 0, 400, 256), (700, 0, 300, 256), (1000, 0, 216, 256), (1216, 0, 64, 256)]
        XCTAssertEqual(edges.count, expected.count)
        for (a, b) in zip(edges, expected) {
            XCTAssertEqual([a.0, a.1, a.2, a.3], [b.0, b.1, b.2, b.3])
        }
    }

    func testPixelEdgesShareSeams() {
        // 隣り合う矩形は同じ辺を共有する（隙間も重なりも出ない）。どの大きさでも。
        for width in [786.0, 1704.0, 1535.0, 2048.0] {
            let landscape = ETVisualizerPresets.classic.landscape
            let edges = landscape.map { ETVisualizerEditing.pixelEdges($0.rect, width: width, height: 256) }
            for i in 1..<edges.count {
                XCTAssertEqual(edges[i - 1].0 + edges[i - 1].2, edges[i].0, "width \(width) seam \(i)")
            }
        }
    }

    func testStudioIsTheInAppDefault() {
        XCTAssertEqual(ETVisualizerPresets.studio.name, "Studio")
        XCTAssertEqual(ETVisualizerPresets.scene(id: "studio"), ETVisualizerPresets.studio)
        XCTAssertNil(ETVisualizerPresets.scene(id: "nope"))
        XCTAssertTrue((ETVisualizerPresets.studio.portrait + ETVisualizerPresets.studio.landscape).allSatisfy(\.card))
    }

    func testReleasePresetsHaveNoSong() {
        for preset in ETVisualizerPresets.available(allowsSong: false) {
            XCTAssertFalse(preset.usesSong, preset.id)
            XCTAssertFalse(preset.scene.portrait.contains { $0.kind.isSong }, preset.id)
            XCTAssertFalse(preset.scene.landscape.contains { $0.kind.isSong }, preset.id)
            XCTAssertNotEqual(preset.scene.background.kind, .artwork, preset.id)
        }
        // 曲が無いと成り立たないものは、そう申告している。曲の要素を抜いても残るものは false でよい。
        for preset in ETVisualizerPresets.all {
            let uses = preset.scene.usesSong(.portrait) || preset.scene.usesSong(.landscape)
            if preset.usesSong {
                XCTAssertTrue(uses, preset.id)
            } else {
                for layout in ETVisualizerLayoutKey.allCases {
                    XCTAssertFalse(preset.scene.elements(layout, allowsSong: false).isEmpty, preset.id)
                }
                XCTAssertNotEqual(preset.scene.background.kind, .artwork, preset.id)
            }
        }
        XCTAssertEqual(ETVisualizerPresets.all.filter(\.usesSong).map(\.id), ["nowPlaying"])
    }

    func testNCSPresetCentresArtworkInSphere() throws {
        let scene = try XCTUnwrap(ETVisualizerPresets.scene(id: "ncs"))
        for layout in ETVisualizerLayoutKey.allCases {
            let ncs = try XCTUnwrap(scene[layout].first { $0.kind == .ncs })
            let art = try XCTUnwrap(scene[layout].first { $0.kind == .artwork })
            XCTAssertEqual(ncs.rect.x + ncs.rect.w / 2, art.rect.x + art.rect.w / 2, accuracy: 1e-12)
            XCTAssertEqual(ncs.rect.y + ncs.rect.h / 2, art.rect.y + art.rect.h / 2, accuracy: 1e-12)
            XCTAssertEqual(ncs.color, ETNCSConstants.defaultColor)
        }
        let release = try XCTUnwrap(ETVisualizerPresets.available(allowsSong: false).first { $0.id == "ncs" })
        for layout in ETVisualizerLayoutKey.allCases {
            XCTAssertEqual(release.scene[layout].map(\.kind), [.ncs])
        }
    }

    func testNoPresetHasJSFX() {
        for preset in ETVisualizerPresets.all {
            for layout in ETVisualizerLayoutKey.allCases {
                XCTAssertEqual(preset.scene[layout].filter { $0.kind == .jsfx }.count, 0, preset.id)
            }
        }
    }

    func testNeonMirrorsTheSpectrumWithAFlippedCopy() {
        for layout in ETVisualizerLayoutKey.allCases {
            let spectra = ETVisualizerPresets.neon[layout].filter { $0.kind == .spectrum }
            XCTAssertEqual(spectra.count, 2)
            XCTAssertTrue(spectra[1].flipY)
            XCTAssertEqual(spectra[1].opacity, 0.3)
            XCTAssertEqual(spectra[0].rect.y + spectra[0].rect.h, spectra[1].rect.y, accuracy: 1e-12)
        }
    }
}
