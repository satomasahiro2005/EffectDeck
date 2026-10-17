//  VisualizerMigration.swift
//  旧い設定（ETVisualizerConfig v1。パネルの on/off と並び順、縦横比、見た目）を場面へ移す。
//  Foundation だけ（Tests/Unit/VisualizerMigrationTests.swift）。
//
//  使うのは Floating Meters の保存（pref.visualizer.floating）を読む 1 回だけ。
//  アプリの中の旧い設定は移さない（新しい既定の Studio に替わる）。

import Foundation

enum ETVisualizerMigration {

    /// 旧 pref.visualizer.floating（ETVisualizerConfig v1）を新しい形へ。
    /// 既定のままなら Classic（5:1）そのもの。それ以外は旧い並べ方（place）の矩形を割合にして写す。
    static func floating(from legacy: ETVisualizerConfig) -> ETFloatingMetersScene {
        let config = legacy.normalized(for: .floating)
        if config == ETVisualizerConfig.defaults(for: .floating) {
            return ETFloatingMetersScene(aspect: .strip, scene: ETVisualizerPresets.classic)
        }
        let aspect: ETVisualizerAspect = config.aspect == .fit ? .strip : config.aspect
        let ratio = aspect.ratio ?? 5
        let kinds = config.visibleKinds(allowsArtwork: true)

        func elements(ratio: Double) -> [ETVisualizerElement] {
            let width = ETVisualizerLayout.referenceWidth
            let height = width / ratio
            return ETVisualizerLayout.place(kinds, analogMode: config.analogMode, ratio: ratio).compactMap { placement in
                guard let kind = ETVisualizerElementKind(rawValue: placement.kind.rawValue) else { return nil }
                let r = placement.rect
                var element = ETVisualizerElement(
                    id: UUID(), kind: kind,
                    rect: ETVisualizerRect(x: r.x / width, y: r.y / height, w: r.w / width, h: r.h / height),
                    look: config.style,
                    color: ETVisualizerElement.defaultColor(kind: kind, look: config.style))
                if kind == .spectrum { element.spectrumDisplay = config.spectrumDisplay }
                if kind == .analogMeter { element.analogMode = config.analogMode }
                return element
            }
        }

        let classic = config.style == .classic
        var background = ETVisualizerBackground()
        background.color = ETVisualizerColor(classic ? 0x000000 : 0x080D1C)
        let scene = ETVisualizerScene(
            name: classic ? "Classic" : "Migrated", background: background,
            portrait: elements(ratio: ratio < 1 ? ratio : 9.0 / 16.0),
            landscape: elements(ratio: ratio >= 1 ? ratio : 16.0 / 9.0))
        return ETFloatingMetersScene(aspect: aspect, scene: scene).normalized()
    }
}
