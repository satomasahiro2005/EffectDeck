//  VisualizerSnapshot.swift
//  Debug だけ。`-ETVisualizerDump 1` で起こすと、Floating Meters と画面内の Visualizer を
//  縦横比と見た目ごとに PNG へ書き出す（Library/Caches/vis-dump/）。シミュレータでは PiP を
//  押して出せないので、描き手の絵だけを確かめるための口。Visualizer のシートが出ているあいだに撮る
//  （解析はシートの描き面が回す。-ETSheet visualizer -ETMock 1 と一緒に使う）。

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

    static func runIfRequested() {
        guard UserDefaults.standard.bool(forKey: "ETVisualizerDump"), !started else { return }
        started = true
        // どの組み合わせでも描けるよう、解析に全部頼んでおく。
        var all: ETVisualizerNeedsSet = []
        for style in ETVisualizerStyle.allCases {
            var config = ETVisualizerConfig.defaults(for: .inApp)
            config.style = style
            config.panels = config.panels.map { ETVisualizerPanel(kind: $0.kind, isOn: true) }
            all.formUnion(config.needs(allowsArtwork: true))
        }
        ETVisualizerAnalysis.shared.register(holder, needs: all)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            dump()
            ETVisualizerAnalysis.shared.unregister(holder)
        }
    }

    private static func dump() {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let dir = caches.appendingPathComponent("vis-dump")
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let artwork = ETSongRecognizer.shared.artwork
        for surface in ETVisualizerSurface.allCases {
            for style in ETVisualizerStyle.allCases {
                for aspect in ETVisualizerAspect.choices(for: surface) where aspect != .fit {
                    var config = ETVisualizerConfig.defaults(for: surface)
                    config.style = style
                    config.aspect = aspect
                    let ratio = aspect.ratio ?? 16.0 / 9.0
                    let (w, h) = ETVisualizerLayout.pipPixelSize(ratio)
                    let placements = ETVisualizerLayout.place(config.visibleKinds(allowsArtwork: true),
                                                              analogMode: config.analogMode, ratio: Double(w) / Double(h))
                    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                  | CGBitmapInfo.byteOrder32Little.rawValue) else { continue }
                    ctx.translateBy(x: 0, y: CGFloat(h))
                    ctx.scaleBy(x: 1, y: -1)
                    ETVisualizerRenderer.draw(config: config, placements: placements,
                                              analysis: ETVisualizerAnalysis.shared, artwork: artwork,
                                              in: ctx, pixelSize: CGSize(width: w, height: h))
                    guard let image = ctx.makeImage() else { continue }
                    let name = "\(surface.rawValue)-\(style.rawValue)-\(aspect.rawValue.replacingOccurrences(of: ":", with: "x")).png"
                    let url = dir.appendingPathComponent(name)
                    if let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
                        CGImageDestinationAddImage(dest, image, nil)
                        CGImageDestinationFinalize(dest)
                    }
                }
            }
        }
        log.notice("visualizer dump written to \(dir.path, privacy: .public)")
    }
}
#endif
