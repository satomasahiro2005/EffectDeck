//  VisualizerArtworkBlur.swift
//  アートワークの背景用に、絵を小さくしてぼかしたものを作る。描き手（VisualizerRenderer）は UIKit にも
//  CoreImage にも頼らないので、ぼかしはここ（アプリ側）で作って渡す。
//
//  **絵が替わったときに 1 回だけ作る。**毎フレームは何も走らない。作るのは主でない列（utility）で、
//  出来るまで image(for:) は nil を返し、描き手は背景の色で塗る。出来た絵が今の絵のものでなければ捨てる。
//  手順: 長い辺 256 画素に縮める → 端を延ばして（clampedToExtent）ガウスぼかし（半径 18）→ 元の大きさで切る。

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import os

@MainActor
final class ETVisualizerArtworkBlur {

    static let shared = ETVisualizerArtworkBlur()

    private static let log = Logger(subsystem: "ai.nemut.effetune", category: "visualizer")
    /// 作るたびに建てない。GPU を使う既定のまま 1 つを使い回す。
    nonisolated(unsafe) private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// 1 枠だけ覚える。元の絵を強く持つので、同じ絵かは ObjectIdentifier で見ても取り違えない。
    private var source: CGImage?
    private var key: ObjectIdentifier?
    private var result: CGImage?
    private var working: ObjectIdentifier?

    private init() {}

    /// 同じ絵なら作ってある物。違えば作り始めて、出来るまでは nil（呼ぶ側は代わりの色で塗る）。
    func image(for artwork: CGImage?) -> CGImage? {
        guard let artwork else { return nil }
        let id = ObjectIdentifier(artwork)
        if key == id { return result }
        if working == id { return nil }
        // 絵が替わった。前の絵のぼかしは捨てる。
        source = artwork
        key = id
        result = nil
        working = id
        Task.detached(priority: .utility) {
            let blurred = Self.blur(artwork)
            await MainActor.run {
                let shared = ETVisualizerArtworkBlur.shared
                if shared.working == id { shared.working = nil }
                // 作っている間にまた替わっていたら捨てる。
                guard shared.key == id, let blurred else { return }
                shared.result = blurred
                Self.log.notice("artwork blur ready \(blurred.width, privacy: .public)x\(blurred.height, privacy: .public)")
            }
        }
        return nil
    }

    nonisolated private static func blur(_ artwork: CGImage) -> CGImage? {
        let longSide = CGFloat(max(artwork.width, artwork.height))
        guard longSide > 0 else { return nil }
        let scale = min(1, 256 / longSide)
        var input = CIImage(cgImage: artwork)
        if scale < 1 { input = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        let extent = input.extent
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = input.clampedToExtent()
        filter.radius = 18
        guard let output = filter.outputImage?.cropped(to: extent) else { return nil }
        return context.createCGImage(output, from: extent)
    }
}
