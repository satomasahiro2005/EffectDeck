//  VisualizerMigrationTests.swift
//  旧い Floating Meters の設定（v1）を場面へ移す（VisualizerMigration）。
//
//  壊れると: 既定のまま使っていた人の帯が Classic から変わる、替えていた人の縦横比・見た目・パネルが消える、
//  縦長の窓で縦向きの並びが作られず空になる。

import XCTest

final class VisualizerMigrationTests: XCTestCase {

    private func config(aspect: ETVisualizerAspect, style: ETVisualizerStyle, on: [ETVisualizerPanelKind],
                        display: ETSpectrumDisplay = .line, mode: ETAnalogMeterChoice = .vu) -> ETVisualizerConfig {
        var c = ETVisualizerConfig.defaults(for: .floating)
        c.aspect = aspect
        c.style = style
        c.spectrumDisplay = display
        c.analogMode = mode
        c.panels = on.map { ETVisualizerPanel(kind: $0, isOn: true) }
            + ETVisualizerPanelKind.allCases.filter { !on.contains($0) }.map { ETVisualizerPanel(kind: $0, isOn: false) }
        return c
    }

    func testDefaultLegacyConfigIsClassicAtStrip() {
        let result = ETVisualizerMigration.floating(from: ETVisualizerConfig.defaults(for: .floating))
        XCTAssertEqual(result, ETFloatingMetersScene(aspect: .strip, scene: ETVisualizerPresets.classic))
        XCTAssertEqual(result.scene.name, "Classic")
    }

    func testWideEffeTuneCarriesFieldsAndGeometry() {
        let kinds: [ETVisualizerPanelKind] = [.spectrum, .analogMeter, .levelMeter, .stereo]
        let legacy = config(aspect: .wide, style: .effetune, on: kinds, display: .bar, mode: .loudness)
        let result = ETVisualizerMigration.floating(from: legacy)
        XCTAssertEqual(result.aspect, .wide)
        XCTAssertEqual(result.layout, .landscape)
        XCTAssertEqual(result.scene.name, "Migrated")
        XCTAssertEqual(result.scene.background.kind, .solid)
        XCTAssertEqual(result.scene.background.color.rgb, 0x080D1C)

        let placed = ETVisualizerLayout.place(kinds, analogMode: .loudness, ratio: 16.0 / 9.0)
        let landscape = result.scene.landscape
        XCTAssertEqual(landscape.map(\.kind.rawValue), kinds.map(\.rawValue))
        for (element, placement) in zip(landscape, placed) {
            XCTAssertEqual(element.rect.x, placement.rect.x / 1280, accuracy: 1e-9)
            XCTAssertEqual(element.rect.y, placement.rect.y / 720, accuracy: 1e-9)
            XCTAssertEqual(element.rect.w, placement.rect.w / 1280, accuracy: 1e-9)
            XCTAssertEqual(element.rect.h, placement.rect.h / 720, accuracy: 1e-9)
            XCTAssertEqual(element.look, .effetune)
            XCTAssertFalse(element.card)
            XCTAssertEqual(element.color, ETVisualizerElement.defaultColor(kind: element.kind, look: .effetune))
        }
        XCTAssertEqual(landscape.first { $0.kind == .spectrum }?.spectrumDisplay, .bar)
        XCTAssertEqual(landscape.first { $0.kind == .analogMeter }?.analogMode, .loudness)
        XCTAssertFalse(result.scene.portrait.isEmpty)
    }

    func testTallBuildsThePortraitListFromTheTallRatio() {
        let kinds: [ETVisualizerPanelKind] = [.spectrogram, .spectrum, .stereo]
        let result = ETVisualizerMigration.floating(from: config(aspect: .tall, style: .classic, on: kinds))
        XCTAssertEqual(result.aspect, .tall)
        XCTAssertEqual(result.layout, .portrait)
        XCTAssertEqual(result.scene.name, "Classic")
        XCTAssertEqual(result.scene.background.color.rgb, 0)
        let ratio = 9.0 / 16.0
        let placed = ETVisualizerLayout.place(kinds, analogMode: .vu, ratio: ratio)
        let height = 1280 / ratio
        for (element, placement) in zip(result.scene.portrait, placed) {
            // 高さが整数でない（1280 / (9/16)）ので、旧い丸めで最後の行が 1 画素未満はみ出す。normalized が枠の中へ寄せる。
            XCTAssertEqual(element.rect.y, placement.rect.y / height, accuracy: 1e-3)
            XCTAssertEqual(element.rect.h, placement.rect.h / height, accuracy: 1e-9)
            XCTAssertEqual(element.look, .classic)
        }
        // 縦長のときの横向きの並びは 16:9 で作る。
        let wide = ETVisualizerLayout.place(kinds, analogMode: .vu, ratio: 16.0 / 9.0)
        XCTAssertEqual(result.scene.landscape.count, wide.count)
    }

    func testFitMigratesToStrip() {
        var legacy = config(aspect: .fit, style: .effetune, on: [.spectrum, .waveform])
        legacy.aspect = .fit
        let result = ETVisualizerMigration.floating(from: legacy)
        XCTAssertEqual(result.aspect, .strip)
    }

    func testMigratedSceneIsNormalized() {
        let result = ETVisualizerMigration.floating(
            from: config(aspect: .square, style: .effetune, on: [.artwork, .spectrum, .stereo, .analogMeter]))
        XCTAssertEqual(result.normalized(), result)
        // アートワークは写す（描くときに版で止める）。
        XCTAssertTrue(result.scene.landscape.contains { $0.kind == .artwork })
    }
}
