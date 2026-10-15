//  PiPVisualizer.swift
//  図（Oscilloscope・Spectrum Analyzer など）を Picture in Picture の窓に出す。試作。
//
//  **PiP は動画の口しか無い。**図を出すには、描いた絵を 1 枚ずつ CMSampleBuffer にして
//  AVSampleBufferDisplayLayer に流し、そのレイヤーを PiP の元にする
//  （AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:)）。
//
//  絵はカードの図そのもの。ETEffectViews.view を etGraphOnly で ImageRenderer に描かせる。
//  図ごとに描き直す口を作らずに済み、カードと同じ見た目になる。
//
//  **背景でも描き続ける。**PiP は他のアプリの上で見るもので、そのあいだこのアプリは背景にいる。
//  CADisplayLink（ETDisplayPump）は背景で止まるので、ここはタイマーで回し、
//  背景ではテレメトリもこちらで汲む。DSP の出す速さも PiP のあいだは落とさない（ETDisplayPump.stop）。
//
//  レイヤーは窓のいちばん奥に 2pt で置く。PiP の元は窓に入っていないと始まらない。

import AVKit
import CoreMedia
import SwiftUI
import UIKit
import os

@MainActor
final class ETPiPVisualizer: NSObject, ObservableObject {

    static let shared = ETPiPVisualizer()

    /// PiP に出している段。nil なら出していない。
    @Published private(set) var nodeID: UUID?

    /// PiP のあいだ。ETDisplayPump が DSP の出す速さを落とさないために見る。
    var isActive: Bool { nodeID != nil }

    /// 描く幅（pt）と倍率。PiP の窓は絵の縦横比に合わせて開く。
    static let width: CGFloat = 360
    private static let scale: CGFloat = 2
    private static let framesPerSecond = 30

    private let log = Logger(subsystem: "ai.nemut.effetune", category: "pip")
    private let host = ETPiPHostView()
    private var controller: AVPictureInPictureController?
    private var possible: NSKeyValueObservation?
    /// 押されたが、まだ始められない（絵が 1 枚も入っていない）。
    private var wantsStart = false
    private var timer: DispatchSourceTimer?
    private var renderer: ImageRenderer<ETPiPGraph>?
    private var pool: CVPixelBufferPool?
    private var format: CMVideoFormatDescription?
    private var poolSize = (width: 0, height: 0)

    private override init() { super.init() }

    // MARK: - 出す・しまう

    func start(nodeID id: UUID) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            log.error("PiP が使えない端末")
            return
        }
        if nodeID == id, controller?.isPictureInPictureActive == true { return }
        nodeID = id
        attachHost()
        if controller == nil {
            let source = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: host.displayLayer, playbackDelegate: self)
            let made = AVPictureInPictureController(contentSource: source)
            made.delegate = self
            // 生の図なので、早送りや戻しの印は要らない。
            made.requiresLinearPlayback = true
            controller = made
            possible = made.observe(\.isPictureInPicturePossible, options: [.new]) { _, _ in
                Task { @MainActor in ETPiPVisualizer.shared.startIfPossible() }
            }
        }
        let made = ImageRenderer(content: ETPiPGraph(nodeID: id, dsp: EffeTuneDSP.shared))
        made.scale = Self.scale
        made.proposedSize = ProposedViewSize(width: Self.width, height: nil)
        renderer = made
        wantsStart = true
        EffeTuneDSP.shared.setTelemetryRate(EffeTuneDSP.telemetryHz)
        startTimer()
        // 1 枚目はすぐ入れる。入らないと isPictureInPicturePossible が立たない。
        tick()
        startIfPossible()
    }

    func stop() {
        if controller?.isPictureInPictureActive == true {
            controller?.stopPictureInPicture()
        } else {
            teardown()
        }
    }

    private func startIfPossible() {
        guard wantsStart, let controller, controller.isPictureInPicturePossible,
              !controller.isPictureInPictureActive else { return }
        wantsStart = false
        controller.startPictureInPicture()
    }

    private func teardown() {
        wantsStart = false
        timer?.cancel()
        timer = nil
        renderer = nil
        nodeID = nil
        host.displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        host.removeFromSuperview()
        // 画面が出ていなければ、ETDisplayPump.stop が落とし損ねた速さをここで落とす。
        if UIApplication.shared.applicationState == .background {
            EffeTuneDSP.shared.setTelemetryRate(0)
        }
    }

    private func attachHost() {
        guard host.superview == nil,
              let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows)
                .first(where: \.isKeyWindow) else { return }
        host.frame = CGRect(x: 0, y: 0, width: 2, height: 2)
        window.insertSubview(host, at: 0)
    }

    // MARK: - 描く

    private func startTimer() {
        guard timer == nil else { return }
        let made = DispatchSource.makeTimerSource(queue: .main)
        made.schedule(deadline: .now(), repeating: .milliseconds(1000 / Self.framesPerSecond))
        made.setEventHandler { MainActor.assumeIsolated { ETPiPVisualizer.shared.tick() } }
        made.resume()
        timer = made
    }

    private func tick() {
        guard let id = nodeID else { return }
        guard EffeTuneDSP.shared.chain.contains(where: { $0.id == id }) else {
            // 段が消えた。
            stop()
            return
        }
        // 前にいるあいだは ETDisplayPump が汲んでいる。
        if UIApplication.shared.applicationState != .active {
            AudioIO.shared.pollTelemetry()
        }
        guard let image = renderer?.cgImage else { return }
        enqueue(image)
    }

    private func enqueue(_ image: CGImage) {
        guard let buffer = pixelBuffer(for: image),
              let format,
              let sample = sampleBuffer(buffer, format: format) else { return }
        let output = host.displayLayer.sampleBufferRenderer
        if output.status == .failed {
            log.error("PiP のレイヤーが落ちた: \(String(describing: output.error), privacy: .public)")
            output.flush()
        }
        if output.isReadyForMoreMediaData { output.enqueue(sample) }
    }

    private func pixelBuffer(for image: CGImage) -> CVPixelBuffer? {
        let width = image.width, height = image.height
        if pool == nil || poolSize != (width, height) {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ]
            var made: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &made)
            pool = made
            poolSize = (width, height)
            format = nil
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(UIColor.black.cgColor)
        context.fill(rect)
        context.draw(image, in: rect)
        if format == nil {
            var made: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer,
                                                         formatDescriptionOut: &made)
            format = made
        }
        return buffer
    }

    private func sampleBuffer(_ buffer: CVPixelBuffer, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(Self.framesPerSecond)),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer,
                                                 formatDescription: format,
                                                 sampleTiming: &timing,
                                                 sampleBufferOut: &sample)
        guard let sample else { return nil }
        // 時計を持たせず、来たらすぐ出す。
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(first,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}

// MARK: - PiP の知らせ

extension ETPiPVisualizer: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in ETPiPVisualizer.shared.teardown() }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error) {
        let text = error.localizedDescription
        Task { @MainActor in
            ETPiPVisualizer.shared.log.error("PiP を始められない: \(text, privacy: .public)")
            ETPiPVisualizer.shared.teardown()
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}

extension ETPiPVisualizer: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {}

    /// 終わりの無い生の流れ。
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController) -> Bool { false }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

// MARK: - 絵

/// PiP に描く図。カードの図だけの形と同じもの。
struct ETPiPGraph: View {
    let nodeID: UUID
    @ObservedObject var dsp: EffeTuneDSP

    var body: some View {
        if let index = dsp.chain.firstIndex(where: { $0.id == nodeID }) {
            let node = dsp.chain[index]
            ETEffectViews.view(index: index, node: node, dsp: dsp)
                .id(node.resetCount)
                .environment(\.etGraphOnly, true)
                .padding(10)
                .frame(width: ETPiPVisualizer.width)
                .background(Color.black)
                .environment(\.colorScheme, .dark)
        }
    }
}

/// PiP の元のレイヤーを持つだけの面。
final class ETPiPHostView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer {
        // swiftlint:disable:next force_cast
        layer as! AVSampleBufferDisplayLayer
    }
}
