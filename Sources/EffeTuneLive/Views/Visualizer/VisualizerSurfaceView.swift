//  VisualizerSurfaceView.swift
//  アプリの中に Visualizer を出す面。CADisplayLink で回して、描き手（ETVisualizerRenderer）が
//  ビットマップに描いた絵を CALayer の contents に置く。SwiftUI は通さない。
//
//  **面は枠いっぱいに描く。**縦横比を選ばせない・黒帯を付けない。どちらの並び（portrait / landscape）を
//  描くかは枠自身の形で決める（`forcedLayout` が無いとき）。編集画面は反対の向きや Floating Meters の縦横比を
//  見せたいので、その形の枠に入れて、並びを `forcedLayout` で指す。
//
//  **見えていて、アプリが背景に回っていないあいだだけ回す。**窓から外れたとき（カバーを閉じたとき）と
//  背景に回ったときに止める。止めるのは `.background` だけで `.inactive` では止めない
//  （コントロールセンターを引き下ろすたびに作り直さない。PipelineView の scenePhase と同じ）。
//
//  **器の大きさは枠の点の大きさ × 画素倍率。**画素倍率は 2（画面が 3x でも）、重いと 1 に落とす
//  （上流の auto quality と同じ。描きの時間の EMA が 12ms を超えたら落とし、5ms を切ったら戻す）。
//  長い辺は最大 2048。器は 2 枚を交互に使う（makeImage の絵が器を指したままだと、次の描きが写しを作って詰まる）。

import SwiftUI
import UIKit
import os

/// 面に描かせる物。編集画面は下書き（ドラッグ中の矩形を含む）をここへ入れる。
@MainActor
final class ETVisualizerStage {
    enum Mode: Equatable {
        case inApp
        /// Floating Meters。縦横比は枠の形で表すので、ここでは単位の取り方を替えるためだけに持つ。
        case floating(ETVisualizerAspect)
    }

    var mode: Mode = .inApp { didSet { version &+= 1 } }
    var scene: ETVisualizerScene { didSet { version &+= 1 } }
    /// 編集画面。曲名・歌手・JSFX の名前を仮に出す。
    var placeholders = false
    /// nil は枠の形で選ぶ。
    var forcedLayout: ETVisualizerLayoutKey? { didSet { version &+= 1 } }
    private(set) var version = 0

    init(scene: ETVisualizerScene? = nil) {
        self.scene = scene ?? ETVisualizerSettings.shared.scene
    }
}

struct ETVisualizerSurfaceView: UIViewRepresentable {
    let stage: ETVisualizerStage

    func makeUIView(context: Context) -> ETVisualizerLayerView {
        ETVisualizerLayerView(stage: stage)
    }

    /// 場面は舞台（stage）が持ち、面が自分で読む。
    func updateUIView(_ uiView: ETVisualizerLayerView, context: Context) {}
}

@MainActor
final class ETVisualizerLayerView: UIView {

    private static let log = Logger(subsystem: "ai.nemut.effetune", category: "visualizer")
    private static let maxPixelSide = 2048

    private let stage: ETVisualizerStage
    private let stageLayer = CALayer()
    private var link: CADisplayLink?
    private var running = false
    private var inBackground: Bool

    private var pixelWidth = 0
    private var pixelHeight = 0
    private var pixelScale: CGFloat = 1
    private var contexts: [CGContext] = []
    private var contextIndex = 0

    /// 最後に場面を読み込んだときの版と並び。
    private var seenVersion = -1
    private var seenLayout: ETVisualizerLayoutKey?
    private var jsfxElements: [ETVisualizerElement] = []
    /// NCS の粒の器。NCS の要素と、取得中のアートワークの要素の分。
    private let ncs = ETVisualizerNCS()
    private var ncsElements: [ETVisualizerElement] = []
    private var artworkElements: [ETVisualizerElement] = []
    private var layoutHasNCS = false

    /// 0 は画素倍率 2・60Hz まで、1 は画素倍率 1・30Hz。
    private var quality = 0
    private var drawMilliseconds: Double = 0
    private var frames = 0

    init(stage: ETVisualizerStage) {
        self.stage = stage
        inBackground = UIApplication.shared.applicationState == .background
        super.init(frame: .zero)
        backgroundColor = .black
        isOpaque = true
        stageLayer.contentsGravity = .resize
        stageLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(stageLayer)
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
        rebuildLayout()
        refreshScene()
        Self.log.notice("view start mode=\(self.modeName, privacy: .public) layout=\(self.layout.rawValue, privacy: .public)")
    }

    private func stop() {
        guard running else { return }
        running = false
        link?.invalidate()
        link = nil
        ETVisualizerTap.shared.release(self)
        ETVisualizerAnalysis.shared.unregister(self)
        ETVisualizerJSFXPool.shared.release(self)
        ncs.releaseAll()
        seenLayout = nil
        seenVersion = -1
        updateRecognition()
        Self.log.notice("view stop")
    }

    private var modeName: String {
        if case .floating = stage.mode { return "floating" }
        return "inApp"
    }

    private var frameRateRange: CAFrameRateRange {
        quality == 0 ? CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
                     : CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)
    }

    /// 描く並び。指定が無ければ枠の形で決める。
    private var layout: ETVisualizerLayoutKey {
        stage.forcedLayout ?? .of(width: Double(max(pixelWidth, 1)), height: Double(max(pixelHeight, 1)))
    }

    /// 場面を読み込み直す: 解析に頼むもの・曲の聞き取り・JSFX の要素。
    private func refreshScene() {
        seenVersion = stage.version
        let layout = self.layout
        seenLayout = layout
        let scene = stage.scene
        jsfxElements = scene[layout].filter { $0.kind == .jsfx }
        ncsElements = scene[layout].filter { $0.kind == .ncs }
        artworkElements = ETFeatures.visualizer ? scene[layout].filter { $0.kind == .artwork } : []
        layoutHasNCS = !ncsElements.isEmpty
        guard running else { return }
        ETVisualizerAnalysis.shared.register(self, needs: scene.needs(layout, allowsSong: ETFeatures.visualizer))
        updateRecognition()
        ETVisualizerJSFXPool.shared.acquire(self, elements: jsfxElements)
    }

    /// 曲の聞き取りは、回っていて、場面が曲を使うときだけ（版が許すときだけ）。
    private func updateRecognition() {
        guard ETFeatures.visualizer else { return }
        let wanted = running && stage.scene.usesSong(layout)
        ETSongRecognizer.shared.setActive(wanted, for: .view(ObjectIdentifier(self)))
    }

    // MARK: - 大きさ

    override func layoutSubviews() {
        super.layoutSubviews()
        rebuildLayout()
    }

    /// 枠・器の大きさを作り直す。大きさが変わったときだけ器を作り直す。
    private func rebuildLayout() {
        let box = bounds
        guard box.width > 0, box.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stageLayer.frame = box
        CATransaction.commit()

        let screenScale = window?.windowScene?.screen.scale ?? 2
        pixelScale = quality == 0 ? min(screenScale, 2) : 1
        var newWidth = Int((box.width * pixelScale).rounded())
        var newHeight = Int((box.height * pixelScale).rounded())
        let longSide = max(newWidth, newHeight)
        if longSide > Self.maxPixelSide {
            let k = Double(Self.maxPixelSide) / Double(longSide)
            newWidth = Int((Double(newWidth) * k).rounded())
            newHeight = Int((Double(newHeight) * k).rounded())
            // 長い辺で縮めたあとの、本当の画素 / 点。JSFX の絵の大きさ（点）がこれで決まる。
            pixelScale = CGFloat(newWidth) / box.width
        }
        newWidth = max(newWidth, 2)
        newHeight = max(newHeight, 2)
        if newWidth != pixelWidth || newHeight != pixelHeight || contexts.isEmpty {
            pixelWidth = newWidth
            pixelHeight = newHeight
            contexts = (0..<2).compactMap { _ in makeContext(newWidth, newHeight) }
            contextIndex = 0
        }
    }

    private func makeContext(_ width: Int, _ height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    /// 倍率。アプリの中は短い辺 / 720、Floating Meters は長い辺 / 1280。
    private var unit: Double {
        if case .floating = stage.mode {
            return ETVisualizerUnit.floating(pixelWidth: Double(pixelWidth), pixelHeight: Double(pixelHeight))
        }
        return ETVisualizerUnit.inApp(pixelWidth: Double(pixelWidth), pixelHeight: Double(pixelHeight))
    }

    // MARK: - 描く

    @objc private func tick(_ link: CADisplayLink) {
        guard contexts.count == 2 else { return }
        let start = CACurrentMediaTime()
        if stage.version != seenVersion || seenLayout != self.layout { refreshScene() }
        let analysis = ETVisualizerAnalysis.shared
        analysis.update(rate: AudioIO.shared.sampleRate, now: start)

        let layout = self.layout
        let scene = stage.scene
        let allowsSong = ETFeatures.visualizer
        let recognizer = ETSongRecognizer.shared
        let artwork = allowsSong ? recognizer.artwork : nil
        let blurred = allowsSong && scene.background.kind == .artwork
            ? ETVisualizerArtworkBlur.shared.image(for: artwork) : nil
        var song: ETVisualizerSongText?
        if allowsSong, let current = recognizer.current {
            song = ETVisualizerSongText(title: current.title, artist: current.artist ?? "")
        }
        let pool = ETVisualizerJSFXPool.shared
        // 曲の取得中は、アートワークが粒に替わる（Metal が無い版・曲を使えない版では重み 0）
        let presentation: (weight: Double, color: ETVisualizerColor) = allowsSong && !artworkElements.isEmpty && ncs.isAvailable
            ? recognizer.identifyingPresentation(now: start) : (weight: 0, color: ETNCSConstants.defaultColor)
        let frame = ETVisualizerFrame(
            analysis: analysis, artwork: artwork, blurredArtwork: blurred, song: song,
            jsfxImages: pool.images(for: jsfxElements.map(\.id)), ncsImages: ncs.images(),
            identifying: presentation.weight, allowsSong: allowsSong, placeholders: stage.placeholders)

        contextIndex ^= 1
        let ctx = contexts[contextIndex]
        let size = CGSize(width: pixelWidth, height: pixelHeight)
        let unit = CGFloat(self.unit)
        ctx.saveGState()
        // 上を 0 にする。
        ctx.translateBy(x: 0, y: CGFloat(pixelHeight))
        ctx.scaleBy(x: 1, y: -1)
        ETVisualizerRenderer.draw(scene: scene, layout: layout, frame: frame, in: ctx, pixelSize: size, unit: unit)
        ctx.restoreGState()
        let image = ctx.makeImage()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stageLayer.contents = image
        CATransaction.commit()

        // JSFX の要素の枠（カードの内側）を点にして、1 枚頼む。
        for element in jsfxElements {
            var content = ETVisualizerRenderer.pixelRect(element.rect, size)
            if element.card { content = content.insetBy(dx: 8 * unit, dy: 8 * unit) }
            guard content.width >= 1, content.height >= 1 else { continue }
            pool.step(element.id, holder: self,
                      logical: CGSize(width: content.width / pixelScale, height: content.height / pixelScale),
                      surfaceScale: pixelScale, now: start)
        }

        // NCS の粒の器を進める（GPU に投げるだけで待たない）
        ncs.step(ncsElements: ncsElements, artworkElements: artworkElements, layoutHasNCS: layoutHasNCS,
                 presentation: presentation, pixelSize: size, unit: unit, analysis: analysis, now: start)

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
