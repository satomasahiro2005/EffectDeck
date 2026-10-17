//  VisualizerSnapshot.swift
//  Debug だけ。`-ETVisualizerDump 1` で起こすと、組み込みの場面を端末の大きさごとに、Floating Meters の Classic を
//  縦横比ごとに PNG へ書き出す（Library/Caches/vis-dump/）。シミュレータでは PiP を押して出せないので、
//  描き手の絵だけを確かめるための口。Visualizer のカバーが出ているあいだに撮る
//  （解析はカバーの描き面が回す。`-ETSheet visualizer -ETMock 1` と一緒に使う）。
//
//  scene-<id>-<大きさ>.png: 大きさは phone-portrait 786×1704・phone-landscape 1704×786・
//  pad-portrait 1536×2048・pad-landscape 2048×1536（画素。倍率は短い辺 / 720）。
//  floating-classic-<縦横比>.png: PiP の器の大きさ（長い辺 1280）で倍率 1。
//  編集画面と同じく仮の字を出し（placeholders）、JSFX と NCS の絵は無し。

#if DEBUG
import CoreGraphics
import ImageIO
import UIKit
import UniformTypeIdentifiers
import os

@MainActor
enum ETVisualizerSnapshot {

    private static let log = Logger(subsystem: "ai.nemut.effetune", category: "visualizer")
    private static var started = false
    private final class Holder {}
    private static let holder = Holder()

    private static let sizes: [(label: String, width: Int, height: Int)] = [
        ("phone-portrait", 786, 1704), ("phone-landscape", 1704, 786),
        ("pad-portrait", 1536, 2048), ("pad-landscape", 2048, 1536),
    ]

    static func runIfRequested() {
        guard UserDefaults.standard.bool(forKey: "ETVisualizerDump"), !started else { return }
        started = true
        // どの組み合わせでも描けるよう、解析に全部頼んでおく。
        var all: ETVisualizerNeedsSet = [.classicSpectrogram, .effetuneSpectrogram, .classicSpectrum,
                                         .effetuneSpectrum, .loudness, .vu, .stereoEnvelope]
        for preset in ETVisualizerPresets.all {
            for layout in ETVisualizerLayoutKey.allCases { all.formUnion(preset.scene.needs(layout, allowsSong: true)) }
        }
        ETVisualizerAnalysis.shared.register(holder, needs: all)
        Task { @MainActor in
            // ぼかしは主でない列で作るので、先に頼んでおく。
            _ = ETVisualizerArtworkBlur.shared.image(for: ETSongRecognizer.shared.artwork)
            try? await Task.sleep(for: .seconds(8))
            dump()
            ETVisualizerAnalysis.shared.unregister(holder)
        }
    }

    private static func frame() -> ETVisualizerFrame {
        let recognizer = ETSongRecognizer.shared
        let artwork = recognizer.artwork
        var song: ETVisualizerSongText?
        if let current = recognizer.current {
            song = ETVisualizerSongText(title: current.title, artist: current.artist ?? "")
        }
        return ETVisualizerFrame(
            analysis: ETVisualizerAnalysis.shared, artwork: artwork,
            blurredArtwork: ETVisualizerArtworkBlur.shared.image(for: artwork), song: song, jsfxImages: [:],
            ncsImages: [:], identifying: 0, allowsSong: true, placeholders: true)
    }

    private static func render(_ scene: ETVisualizerScene, layout: ETVisualizerLayoutKey, width: Int, height: Int,
                               unit: Double, to url: URL) {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ETVisualizerRenderer.draw(scene: scene, layout: layout, frame: frame(), in: ctx,
                                  pixelSize: CGSize(width: width, height: height), unit: CGFloat(unit))
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    private static func dump() {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let dir = caches.appendingPathComponent("vis-dump")
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        for preset in ETVisualizerPresets.all {
            for size in sizes {
                let layout = ETVisualizerLayoutKey.of(width: Double(size.width), height: Double(size.height))
                let unit = ETVisualizerUnit.inApp(pixelWidth: Double(size.width), pixelHeight: Double(size.height))
                render(preset.scene, layout: layout, width: size.width, height: size.height, unit: unit,
                       to: dir.appendingPathComponent("scene-\(preset.id)-\(size.label).png"))
            }
        }
        for aspect in ETVisualizerAspect.choices(for: .floating) {
            let ratio = aspect.ratio ?? 5
            let (w, h) = ETVisualizerLayout.pipPixelSize(ratio)
            let floating = ETFloatingMetersScene(aspect: aspect, scene: ETVisualizerPresets.classic)
            let unit = ETVisualizerUnit.floating(pixelWidth: Double(w), pixelHeight: Double(h))
            let name = "floating-classic-\(aspect.rawValue.replacingOccurrences(of: ":", with: "x")).png"
            render(floating.scene, layout: floating.layout, width: w, height: h, unit: unit,
                   to: dir.appendingPathComponent(name))
        }
        log.notice("visualizer dump written to \(dir.path, privacy: .public)")
    }
}
#endif
