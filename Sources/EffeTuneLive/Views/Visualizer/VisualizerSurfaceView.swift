//  VisualizerSurfaceView.swift
//  アプリの中に Visualizer を出す面。CADisplayLink で回して、描き手（ETVisualizerRenderer）が
//  ビットマップに描いた絵を CALayer の contents に置く。SwiftUI は通さない。
//
//  **見えていて、アプリが背景に回っていないあいだだけ回す。**窓から外れたとき（シートを閉じたとき）と
//  背景に回ったときに止める。止めるのは `.background` だけで `.inactive` では止めない
//  （コントロールセンターを引き下ろすたびに作り直さない。PipelineView の scenePhase と同じ）。
//
//  **器の大きさは舞台の点の大きさ × 画素倍率。**画素倍率は 2（画面が 3x でも）、重いと 1 に落とす
//  （上流の auto quality と同じ。描きの時間の EMA が 12ms を超えたら落とし、5ms を切ったら戻す）。
//  幅は最大 2048。器は 2 枚を交互に使う（makeImage の絵が器を指したままだと、次の描きが写しを作って詰まる）。

import Combine
import SwiftUI
import UIKit
import os

struct ETVisualizerSurfaceView: UIViewRepresentable {
    let surface: ETVisualizerSurface
    /// 編集画面の見本。Fit は窓の形で組む。
    var preview = false

    func makeUIView(context: Context) -> ETVisualizerLayerView {
        ETVisualizerLayerView(surface: surface, preview: preview)
    }

    /// 設定は面自身が購読している。
    func updateUIView(_ uiView: ETVisualizerLayerView, context: Context) {}
}

@MainActor
final class ETVisualizerLayerView: UIView {

    private static let log = Logger(subsystem: "ai.nemut.effetune", category: "visualizer")
    private static let maxPixelWidth = 2048
    /// アプリの中の画面（見本でない）が Fit で最後に組んだ縦横比。編集画面の見本が同じ形で組めるように覚える。
    static var lastInAppFitRatio: Double?

    private let surface: ETVisualizerSurface
    private let preview: Bool
    private var config: ETVisualizerConfig
    private let stageLayer = CALayer()
    private var link: CADisplayLink?
    private var running = false
    private var inBackground: Bool
    private var cancellable: AnyCancellable?

    private var placements: [ETVisualizerPlacement] = []
    private var pixelWidth = 0
    private var pixelHeight = 0
    private var contexts: [CGContext] = []
    private var contextIndex = 0

    /// 0 は画素倍率 2・60Hz まで、1 は画素倍率 1・30Hz。
    private var quality = 0
    private var drawMilliseconds: Double = 0
    private var frames = 0

    init(surface: ETVisualizerSurface, preview: Bool) {
        self.surface = surface
        self.preview = preview
        config = ETVisualizerSettings.shared.config(surface)
        inBackground = UIApplication.shared.applicationState == .background
        super.init(frame: .zero)
        backgroundColor = .black
        isOpaque = true
        stageLayer.contentsGravity = .resize
        stageLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(stageLayer)

        // 発行されるのは変わる前（willSet）なので、読み直さず渡された値を使う。
        let settings = ETVisualizerSettings.shared
        let publisher = surface == .inApp ? settings.$inApp : settings.$floating
        cancellable = publisher.dropFirst().sink { [weak self] value in
            MainActor.assumeIsolated { self?.configChanged(value) }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(enteredBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willEnterForeground),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - 回す・止める

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateRunning()
    }

    @objc private func enteredBackground() {
        inBackground = true
        updateRunning()
    }

    @objc private func willEnterForeground() {
        inBackground = false
        updateRunning()
    }

    private func updateRunning() {
        if window != nil && !inBackground { start() } else { stop() }
    }

    private func start() {
        guard !running else { return }
        running = true
        let made = CADisplayLink(target: self, selector: #selector(tick(_:)))
        made.preferredFrameRateRange = frameRateRange
        made.add(to: .main, forMode: .common)
        link = made
        ETVisualizerTap.shared.acquire(self)
        ETVisualizerAnalysis.shared.register(self, needs: config.needs(allowsArtwork: ETFeatures.visualizer))
        updateRecognition()
        rebuildLayout()
        Self.log.notice("view start surface=\(self.surface.rawValue, privacy: .public) preview=\(self.preview, privacy: .public)")
    }

    private func stop() {
        guard running else { return }
        running = false
        link?.invalidate()
        link = nil
        ETVisualizerTap.shared.release(self)
        ETVisualizerAnalysis.shared.unregister(self)
        updateRecognition()
        Self.log.notice("view stop surface=\(self.surface.rawValue, privacy: .public) preview=\(self.preview, privacy: .public)")
    }

    private var frameRateRange: CAFrameRateRange {
        quality == 0 ? CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
                     : CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)
    }

    /// アートワークの聞き取りは、回っていて、アートワークを出す設定のときだけ（版が許すときだけ）。
    private func updateRecognition() {
        guard ETFeatures.visualizer else { return }
        let wanted = running && config.visibleKinds(allowsArtwork: true).contains(.artwork)
        ETSongRecognizer.shared.setActive(wanted, for: .view(ObjectIdentifier(self)))
    }

    private func configChanged(_ new: ETVisualizerConfig) {
        config = new
        guard running else { return }
        ETVisualizerAnalysis.shared.register(self, needs: config.needs(allowsArtwork: ETFeatures.visualizer))
        updateRecognition()
        rebuildLayout()
    }

    // MARK: - 大きさ

    override func layoutSubviews() {
        super.layoutSubviews()
        rebuildLayout()
    }

    /// 舞台の縦横比。Floating Meters の見本は PiP の器と同じ形。Fit は画面（見本では窓）の形。
    private var stageRatio: Double {
        if surface == .floating {
            let size = ETVisualizerLayout.pipPixelSize(config.aspect.ratio ?? 5)
            return Double(size.0) / Double(size.1)
        }
        if let ratio = config.aspect.ratio { return ratio }
        if preview, let last = Self.lastInAppFitRatio { return last }
        let reference = preview ? (window?.bounds.size ?? bounds.size) : bounds.size
        return ETVisualizerLayout.fitRatio(width: Double(reference.width), height: Double(reference.height))
    }

    /// 舞台の枠・器の大きさ・置き場を作り直す。大きさが変わったときだけ器を作り直す。
    private func rebuildLayout() {
        let box = bounds
        guard box.width > 0, box.height > 0 else { return }
        if surface == .inApp && !preview && config.aspect == .fit {
            Self.lastInAppFitRatio = ETVisualizerLayout.fitRatio(width: Double(box.width), height: Double(box.height))
        }
        let ratio = stageRatio
        var width = box.width
        var height = width / ratio
        if height > box.height {
            height = box.height
            width = height * ratio
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stageLayer.frame = CGRect(x: (box.width - width) / 2, y: (box.height - height) / 2,
                                  width: width, height: height)
        CATransaction.commit()

        let screenScale = window?.windowScene?.screen.scale ?? 2
        let pixelScale = quality == 0 ? min(screenScale, 2) : 1
        var newWidth = Int((width * pixelScale).rounded())
        var newHeight = Int((height * pixelScale).rounded())
        if newWidth > Self.maxPixelWidth {
            newHeight = Int((Double(newHeight) * Double(Self.maxPixelWidth) / Double(newWidth)).rounded())
            newWidth = Self.maxPixelWidth
        }
        newWidth = max(newWidth, 2)
        newHeight = max(newHeight, 2)
        if newWidth != pixelWidth || newHeight != pixelHeight || contexts.isEmpty {
            pixelWidth = newWidth
            pixelHeight = newHeight
            contexts = (0..<2).compactMap { _ in makeContext(newWidth, newHeight) }
            contextIndex = 0
        }
        placements = ETVisualizerLayout.place(config.visibleKinds(allowsArtwork: ETFeatures.visualizer),
                                              analogMode: config.analogMode,
                                              ratio: Double(pixelWidth) / Double(pixelHeight))
    }

    private func makeContext(_ width: Int, _ height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    // MARK: - 描く

    @objc private func tick(_ link: CADisplayLink) {
        guard contexts.count == 2 else { return }
        let start = CACurrentMediaTime()
        let analysis = ETVisualizerAnalysis.shared
        analysis.update(rate: AudioIO.shared.sampleRate, now: start)

        contextIndex ^= 1
        let ctx = contexts[contextIndex]
        ctx.saveGState()
        // 上を 0 にする。
        ctx.translateBy(x: 0, y: CGFloat(pixelHeight))
        ctx.scaleBy(x: 1, y: -1)
        ETVisualizerRenderer.draw(config: config, placements: placements, analysis: analysis,
                                  artwork: ETFeatures.visualizer ? ETSongRecognizer.shared.artwork : nil,
                                  in: ctx, pixelSize: CGSize(width: pixelWidth, height: pixelHeight))
        ctx.restoreGState()
        let image = ctx.makeImage()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stageLayer.contents = image
        CATransaction.commit()

        adjustQuality(milliseconds: (CACurrentMediaTime() - start) * 1000)
    }

    /// 描きの時間の EMA（α 0.1）を 120 枚ごとに見て、重ければ画素倍率と回数を落とし、軽ければ戻す。
    private func adjustQuality(milliseconds: Double) {
        drawMilliseconds = drawMilliseconds == 0 ? milliseconds : drawMilliseconds * 0.9 + milliseconds * 0.1
        frames += 1
        guard frames >= 120 else { return }
        frames = 0
        if drawMilliseconds > 12 && quality == 0 {
            quality = 1
        } else if drawMilliseconds < 5 && quality == 1 {
            quality = 0
        } else {
            return
        }
        link?.preferredFrameRateRange = frameRateRange
        rebuildLayout()
        Self.log.notice("view quality=\(self.quality, privacy: .public) ema=\(self.drawMilliseconds, privacy: .public)ms")
    }
}
