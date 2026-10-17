//  VisualizerPresets.swift
//  Visualizer と Floating Meters の組み込みの場面。同じ型で、どちらの面にも当てられる
//  （当てても Floating Meters の縦横比は変わらない）。Foundation だけ（Tests/Unit/VisualizerPresetsTests.swift）。
//
//  矩形は [x, y, w, h] の 0〜1。安全な余白は矩形に入れてある（縦向きは x 0.04〜0.96・y 0.07〜0.955、
//  横向きは x 0.07〜0.93・y 0.05〜0.93）。Classic は端まで使う。要素の id は固定の UUID なので、定数は毎回同じ。
//  どれも normalized() を通った形で書く（テストが縛る）。

import Foundation

struct ETVisualizerPreset: Identifiable {
    let id: String
    let scene: ETVisualizerScene
    /// 曲が無いと意味をなさない（Release では出さない）。曲の要素を含んでも、無くて成り立つものは false
    /// （Release では曲の要素を抜いて出す）。
    let usesSong: Bool
}

enum ETVisualizerPresets {

    /// 一覧の順。
    static let all: [ETVisualizerPreset] = [
        ETVisualizerPreset(id: "classic", scene: classic, usesSong: false),
        ETVisualizerPreset(id: "studio", scene: studio, usesSong: false),
        ETVisualizerPreset(id: "neon", scene: neon, usesSong: false),
        ETVisualizerPreset(id: "phosphor", scene: phosphor, usesSong: false),
        ETVisualizerPreset(id: "vintage", scene: vintage, usesSong: false),
        ETVisualizerPreset(id: "spectral", scene: spectral, usesSong: false),
        ETVisualizerPreset(id: "ncs", scene: ncs, usesSong: false),
        ETVisualizerPreset(id: "nowPlaying", scene: nowPlaying, usesSong: true),
    ]

    static func available(allowsSong: Bool) -> [ETVisualizerPreset] {
        if allowsSong { return all }
        // 曲が無くても成り立つものは、曲の要素（NCS の中のアートワーク）を抜いて出す
        return all.filter { !$0.usesSong }.map { preset in
            var scene = preset.scene
            scene.portrait = scene.portrait.filter { !$0.kind.isSong }
            scene.landscape = scene.landscape.filter { !$0.kind.isSong }
            return ETVisualizerPreset(id: preset.id, scene: scene, usesSong: false)
        }
    }

    static func scene(id: String) -> ETVisualizerScene? {
        all.first { $0.id == id }?.scene
    }

    // MARK: 組み立て

    /// 固定の UUID。preset は 1 から、element は横向き 0〜・縦向き 100〜。
    private static func uuid(_ preset: Int, _ element: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-%04X-%012X", preset, element))!
    }

    /// 1 つの要素。色を省くと見た目ごとの既定。
    private static func element(
        _ preset: Int, _ index: Int, _ kind: ETVisualizerElementKind, _ r: [Double],
        look: ETVisualizerStyle = .effetune, color: UInt32? = nil, card: Bool = false, glow: Bool = false,
        opacity: Double = 1, flipY: Bool = false, display: ETSpectrumDisplay = .line,
        meter: ETAnalogMeterChoice = .vu, bold: Bool = false, alignment: ETVisualizerAlignment = .leading
    ) -> ETVisualizerElement {
        ETVisualizerElement(
            id: uuid(preset, index), kind: kind, rect: ETVisualizerRect(x: r[0], y: r[1], w: r[2], h: r[3]),
            look: look,
            color: color.map(ETVisualizerColor.init) ?? ETVisualizerElement.defaultColor(kind: kind, look: look),
            card: card, glow: glow, opacity: opacity, flipY: flipY, spectrumDisplay: display, analogMode: meter,
            bold: bold, alignment: alignment)
    }

    private static func background(
        _ kind: ETVisualizerBackgroundKind, _ color: UInt32, _ color2: UInt32 = 0x000000,
        dim: Double = 0.5, card: UInt32 = 0x0E141E, border: UInt32 = 0x222C3B, cardOpacity: Double = 0.92
    ) -> ETVisualizerBackground {
        ETVisualizerBackground(kind: kind, color: ETVisualizerColor(color), color2: ETVisualizerColor(color2),
                               dim: dim, cardColor: ETVisualizerColor(card), cardBorder: ETVisualizerColor(border),
                               cardOpacity: cardOpacity)
    }

    // MARK: 1. Classic

    /// Floating Meters の既定。今の帯そのまま（ETVisualizerLayout.place の 5:1 を 1280×256 で割った値）。
    static let classic: ETVisualizerScene = {
        func e(_ i: Int, _ kind: ETVisualizerElementKind, _ r: [Double]) -> ETVisualizerElement {
            element(1, i, kind, r, look: .classic)
        }
        return ETVisualizerScene(
            name: "Classic", background: background(.solid, 0x000000),
            portrait: [
                e(100, .spectrogram, [0, 0, 1, 0.40]),
                e(101, .waveform, [0, 0.40, 1, 0.30]),
                e(102, .spectrum, [0, 0.70, 0.58, 0.26]),
                e(103, .stereo, [0.58, 0.70, 0.42, 0.26]),
                e(104, .levelMeter, [0, 0.96, 1, 0.04]),
            ],
            landscape: [
                e(0, .spectrogram, [0, 0, 0.234375, 1]),
                e(1, .waveform, [0.234375, 0, 0.3125, 1]),
                e(2, .spectrum, [0.546875, 0, 0.234375, 1]),
                e(3, .stereo, [0.78125, 0, 0.16875, 1]),
                e(4, .levelMeter, [0.95, 0, 0.05, 1]),
            ])
    }()

    // MARK: 2. Studio

    /// アプリの中の既定。Mastering Console 風。
    static let studio: ETVisualizerScene = {
        func e(_ i: Int, _ kind: ETVisualizerElementKind, _ r: [Double], color: UInt32? = nil,
               meter: ETAnalogMeterChoice = .vu) -> ETVisualizerElement {
            element(2, i, kind, r, color: color, card: true, meter: meter)
        }
        return ETVisualizerScene(
            name: "Studio", background: background(.solid, 0x070A10),
            portrait: [
                e(100, .stereo, [0.04, 0.07, 0.45, 0.20], color: 0x4FD1FF),
                e(101, .analogMeter, [0.51, 0.07, 0.45, 0.20], color: 0xFFB547, meter: .loudness),
                e(102, .spectrum, [0.04, 0.285, 0.92, 0.28], color: 0x4FD1FF),
                e(103, .spectrogram, [0.04, 0.58, 0.92, 0.28]),
                e(104, .levelMeter, [0.04, 0.875, 0.92, 0.08], color: 0x34D1FF),
            ],
            landscape: [
                e(0, .spectrum, [0.07, 0.05, 0.56, 0.50], color: 0x4FD1FF),
                e(1, .spectrogram, [0.07, 0.57, 0.56, 0.25]),
                e(2, .stereo, [0.645, 0.05, 0.285, 0.40], color: 0x4FD1FF),
                e(3, .analogMeter, [0.645, 0.47, 0.285, 0.35], color: 0xFFB547, meter: .loudness),
                e(4, .levelMeter, [0.07, 0.84, 0.86, 0.09], color: 0x34D1FF),
            ])
    }()

    // MARK: 3. Neon

    static let neon: ETVisualizerScene = {
        func e(_ i: Int, _ kind: ETVisualizerElementKind, _ r: [Double], color: UInt32, glow: Bool = false,
               opacity: Double = 1, flipY: Bool = false, display: ETSpectrumDisplay = .line) -> ETVisualizerElement {
            element(3, i, kind, r, color: color, glow: glow, opacity: opacity, flipY: flipY, display: display)
        }
        return ETVisualizerScene(
            name: "Neon", background: background(.gradient, 0x04040B, 0x1A0B3A),
            portrait: [
                e(100, .oscilloscope, [0.04, 0.10, 0.92, 0.18], color: 0x18C8FF, glow: true, opacity: 0.8),
                e(101, .spectrum, [0.04, 0.33, 0.92, 0.32], color: 0xFF1F8F, glow: true, display: .bar),
                e(102, .spectrum, [0.04, 0.65, 0.92, 0.16], color: 0xFF1F8F, opacity: 0.3, flipY: true, display: .bar),
                e(103, .levelMeter, [0.04, 0.88, 0.92, 0.04], color: 0x7A3CFF),
            ],
            landscape: [
                e(0, .oscilloscope, [0.07, 0.08, 0.86, 0.22], color: 0x18C8FF, glow: true, opacity: 0.8),
                e(1, .spectrum, [0.07, 0.32, 0.86, 0.36], color: 0xFF1F8F, glow: true, display: .bar),
                e(2, .spectrum, [0.07, 0.68, 0.86, 0.18], color: 0xFF1F8F, opacity: 0.3, flipY: true, display: .bar),
                e(3, .levelMeter, [0.07, 0.88, 0.86, 0.05], color: 0x7A3CFF),
            ])
    }()

    // MARK: 4. Phosphor

    static let phosphor: ETVisualizerScene = {
        func e(_ i: Int, _ kind: ETVisualizerElementKind, _ r: [Double], color: UInt32,
               glow: Bool = false) -> ETVisualizerElement {
            element(4, i, kind, r, color: color, card: true, glow: glow)
        }
        return ETVisualizerScene(
            name: "Phosphor", background: background(.solid, 0x010302, card: 0x06110A, border: 0x0F2A18),
            portrait: [
                e(100, .oscilloscope, [0.04, 0.07, 0.92, 0.30], color: 0x6DFF9E, glow: true),
                e(101, .stereo, [0.04, 0.385, 0.92, 0.30], color: 0x3DDC76, glow: true),
                e(102, .waveform, [0.04, 0.70, 0.92, 0.255], color: 0x47B872),
            ],
            landscape: [
                e(0, .oscilloscope, [0.07, 0.05, 0.56, 0.56], color: 0x6DFF9E, glow: true),
                e(1, .stereo, [0.645, 0.05, 0.285, 0.56], color: 0x3DDC76, glow: true),
                e(2, .waveform, [0.07, 0.64, 0.86, 0.29], color: 0x47B872),
            ])
    }()

    // MARK: 5. Vintage VU

    static let vintage: ETVisualizerScene = {
        func e(_ i: Int, _ kind: ETVisualizerElementKind, _ r: [Double],
               meter: ETAnalogMeterChoice = .vu) -> ETVisualizerElement {
            element(5, i, kind, r, color: 0xE6C886, card: true, meter: meter)
        }
        return ETVisualizerScene(
            name: "Vintage VU",
            background: background(.gradient, 0x1A1009, 0x0A0604, card: 0x2A1D12, border: 0x4A3420, cardOpacity: 1),
            portrait: [
                e(100, .analogMeter, [0.04, 0.07, 0.92, 0.36]),
                e(101, .analogMeter, [0.04, 0.445, 0.92, 0.40], meter: .loudness),
                e(102, .levelMeter, [0.04, 0.86, 0.92, 0.095]),
            ],
            landscape: [
                e(0, .analogMeter, [0.07, 0.05, 0.86, 0.58]),
                e(1, .analogMeter, [0.07, 0.66, 0.42, 0.27], meter: .loudness),
                e(2, .levelMeter, [0.51, 0.66, 0.42, 0.27]),
            ])
    }()

    // MARK: 6. Spectral

    static let spectral: ETVisualizerScene = {
        func e(_ i: Int, _ kind: ETVisualizerElementKind, _ r: [Double], color: UInt32? = nil) -> ETVisualizerElement {
            element(6, i, kind, r, color: color, card: true)
        }
        return ETVisualizerScene(
            name: "Spectral", background: background(.solid, 0x07060A, card: 0x100C14, border: 0x2A2030),
            portrait: [
                e(100, .spectrogram, [0.04, 0.07, 0.92, 0.52]),
                e(101, .spectrum, [0.04, 0.605, 0.92, 0.18], color: 0xFB8861),
                e(102, .stereo, [0.04, 0.80, 0.45, 0.155], color: 0xB63679),
                e(103, .levelMeter, [0.51, 0.80, 0.45, 0.155], color: 0xFB8861),
            ],
            landscape: [
                e(0, .spectrogram, [0.07, 0.05, 0.62, 0.88]),
                e(1, .spectrum, [0.705, 0.05, 0.225, 0.42], color: 0xFB8861),
                e(2, .stereo, [0.705, 0.49, 0.225, 0.44], color: 0xB63679),
            ])
    }()

    // MARK: 7. NCS

    /// 球の真ん中にアートワーク。球の静止時の半径は辺の約 0.255 倍で、アートワークは辺の約 26% に収まる。
    /// Release では曲の要素（アートワーク）が抜けて、球だけが残る。
    static let ncs: ETVisualizerScene = {
        func e(_ i: Int, _ kind: ETVisualizerElementKind, _ r: [Double]) -> ETVisualizerElement {
            element(8, i, kind, r)
        }
        return ETVisualizerScene(
            name: "NCS", background: background(.solid, 0x05060A),
            portrait: [
                e(100, .ncs, [0, 0.2, 1, 0.6]),
                e(101, .artwork, [0.37, 0.44, 0.26, 0.12]),
            ],
            landscape: [
                e(0, .ncs, [0.1, 0, 0.8, 1]),
                e(1, .artwork, [0.44, 0.37, 0.12, 0.26]),
            ])
    }()

    // MARK: 8. Now Playing

    static let nowPlaying: ETVisualizerScene = {
        func e(_ i: Int, _ kind: ETVisualizerElementKind, _ r: [Double], color: UInt32? = nil,
               opacity: Double = 1, display: ETSpectrumDisplay = .line, bold: Bool = false,
               alignment: ETVisualizerAlignment = .leading) -> ETVisualizerElement {
            element(7, i, kind, r, color: color, opacity: opacity, display: display, bold: bold, alignment: alignment)
        }
        return ETVisualizerScene(
            name: "Now Playing",
            background: background(.artwork, 0x06070A, dim: 0.5, card: 0x000000, border: 0x000000, cardOpacity: 0.45),
            portrait: [
                e(100, .artwork, [0.12, 0.12, 0.76, 0.351]),
                e(101, .title, [0.06, 0.50, 0.88, 0.05], color: 0xFFFFFF, bold: true, alignment: .center),
                e(102, .artist, [0.06, 0.555, 0.88, 0.035], color: 0xECEFF5, opacity: 0.8, alignment: .center),
                e(103, .spectrum, [0.06, 0.62, 0.88, 0.22], color: 0xFFFFFF, opacity: 0.9, display: .bar),
            ],
            landscape: [
                e(0, .artwork, [0.10, 0.14, 0.32, 0.70]),
                e(1, .title, [0.47, 0.20, 0.46, 0.12], color: 0xFFFFFF, bold: true),
                e(2, .artist, [0.47, 0.33, 0.46, 0.08], color: 0xECEFF5, opacity: 0.8),
                e(3, .spectrum, [0.47, 0.50, 0.46, 0.34], color: 0xFFFFFF, opacity: 0.9, display: .bar),
            ])
    }()
}
