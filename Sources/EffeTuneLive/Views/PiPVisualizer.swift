//  PiPVisualizer.swift
//  Mini Meters（MiniMeters.swift の横長の帯）を Picture in Picture の窓に出す。試作。
//
//  **PiP は動画の口しか無い。**描いた絵を 1 枚ずつ CMSampleBuffer にして
//  AVSampleBufferDisplayLayer に流し、そのレイヤーを PiP の元にする
//  （AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:)）。
//
//  **背景でも描き続ける。**PiP は他のアプリの上で見るもので、そのあいだこのアプリは背景にいる。
//  CADisplayLink は背景で止まるのでタイマーで回す。音は ETMeterTap から直に読むので、
//  図のテレメトリ（ETDisplayPump）には頼らない。
//
//  レイヤーは窓のいちばん奥に 2pt で置く。PiP の元は窓に入っていないと始まらない。
//
//  **押す前に用意しておく（prepare）。**押してから作ると、isPictureInPicturePossible が立つのは
//  後になり、そこで始めても押した操作の外なので出ない（初回は 2 回押さないと出なかった）。
//  起きたとき・前に来たときに窓とレイヤーと 1 枚目を用意し、押したらその場で始める。しまっても用意は残す。
//
//  **他のアプリに奪われたら、戻ったときに出し直す。**PiP は 1 つしか出ない。YouTube などが PiP を
//  始めるとこちらは止められる。自分で閉じた（✕・アプリに戻すボタン・メニュー）のでなければ、
//  このアプリが前に来たときにもう一度出す。✕ と奪われたのは、止まる前に setPlaying(false) が来るかで分ける
//  （✕ は再生を止める扱いになる。奪われたときは来ない、と見ている。didStop のログで確かめる）。

import AVKit
import CoreMedia
import UIKit
import os

@MainActor
final class ETPiPVisualizer: NSObject, ObservableObject {

    static let shared = ETPiPVisualizer()

    /// 測っている所（ET_METER_TAP_INPUT / ET_METER_TAP_OUTPUT）。nil なら出していない。
    @Published private(set) var point: Int32?

    private static let framesPerSecond = 30

    fileprivate let log = Logger(subsystem: "ai.nemut.effetune", category: "pip")
    private let host = ETPiPHostView()
    private var controller: AVPictureInPictureController?
    private var possible: NSKeyValueObservation?
    /// 押されたが、まだ始められない（絵が 1 枚も入っていない）。
    private var wantsStart = false
    private var timer: DispatchSourceTimer?
    private var meters: ETMiniMeters?
    private var pool: CVPixelBufferPool?
    private var format: CMVideoFormatDescription?
    /// 器の形。iPad は 16:9 の 2 段（PiP の窓を大きくできる）、iPhone は横長の 1 段。
    private let layout: ETMiniMeters.Layout =
        UIDevice.current.userInterfaceIdiom == .pad ? .large : .strip
    /// 止める理由が分かっているとき真（メニューで止めた・アプリに戻すボタン）。
    private var stopIsIntended = false
    /// ✕ で閉じると、止まる前に一時停止が来る。その時刻。
    private var pausedAt: CFTimeInterval = 0
    /// 最後に前に来た時刻。前に来た直後に止められたのは、離れたアプリの PiP に奪われたもの。
    private var activeAt: CFTimeInterval = 0
    /// 奪われたときに出していた所。前に来たら出し直す。
    private var resumePoint: Int32?
    private var foreground: NSObjectProtocol?

    private override init() {
        super.init()
        foreground = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ETPiPVisualizer.shared.becameActive() }
        }
    }

    // MARK: - 出す・しまう

    /// 窓・レイヤー・PiP の係と 1 枚目を用意する。何度呼んでもよい。
    func prepare() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        attachHost()
        guard host.superview != nil else { return }
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
        if meters == nil {
            // 1 枚目（何も鳴っていない帯）。入らないと isPictureInPicturePossible が立たない。
            enqueue(ETMiniMeters(layout: layout))
        }
    }

    func start(point newPoint: Int32) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            log.error("PiP が使えない端末")
            return
        }
        resumePoint = nil
        stopIsIntended = false
        ETMeterTap_SetPoint(newPoint)
        if point != nil, controller?.isPictureInPictureActive == true {
            // 出ている窓のまま、測る所だけ替える。
            point = newPoint
            meters?.reset()
            return
        }
        point = newPoint
        prepare()
        let made = ETMiniMeters(layout: layout)
        made.reset()
        meters = made
        startTimer()
        tick()
        wantsStart = true
        log.info("PiP を始める possible=\(self.controller?.isPictureInPicturePossible == true, privacy: .public)")
        // 用意ができていれば押したその場で始める。まだなら立った所で（startIfPossible）。
        startIfPossible()
    }

    func stop() {
        resumePoint = nil
        stopIsIntended = true
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

    /// 止まった後。窓・レイヤー・PiP の係と最後の絵は残す（次に押したらすぐ始められるように）。
    fileprivate func teardown() {
        wantsStart = false
        timer?.cancel()
        timer = nil
        meters = nil
        point = nil
        ETMeterTap_SetPoint(Int32(ET_METER_TAP_OFF))
    }

    /// PiP が止まった。自分で閉じたのでなければ、出していた所を控えて前に来たら出し直す。
    fileprivate func didStop() {
        let now = CACurrentMediaTime()
        let state = UIApplication.shared.applicationState
        let closedByUser = stopIsIntended || now - pausedAt < 1.5
        // 前にいて、前に来てから時間が経っている → このアプリの中で ✕ を押した。
        let closedInApp = state == .active && now - activeAt > 2
        log.info("PiP が止まった intended=\(self.stopIsIntended, privacy: .public) paused=\(now - self.pausedAt, privacy: .public) state=\(state.rawValue, privacy: .public) sinceActive=\(now - self.activeAt, privacy: .public)")
        let was = point
        stopIsIntended = false
        teardown()
        guard !closedByUser, !closedInApp, let was else { return }
        resumePoint = was
        // 前に来た直後に奪われた（離れたアプリが PiP を始めた）なら、今出し直す。
        if state == .active { resume() }
    }

    private func becameActive() {
        activeAt = CACurrentMediaTime()
        // 起きたときと戻ったときに用意する。押したその場で始められるように。
        prepare()
        if resumePoint != nil { resume() }
    }

    private func resume() {
        guard let again = resumePoint else { return }
        resumePoint = nil
        log.info("奪われた PiP を出し直す")
        // 前に来た回のうちはまだ始められないことがあるので、1 回遅らせる。
        Task { @MainActor in ETPiPVisualizer.shared.start(point: again) }
    }

    fileprivate func playbackPaused() {
        pausedAt = CACurrentMediaTime()
    }

    fileprivate func restoring() {
        stopIsIntended = true
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
        guard let meters else { return }
        meters.pull(rate: AudioIO.shared.sampleRate)
        enqueue(meters)
    }

    private func enqueue(_ meters: ETMiniMeters) {
        guard let buffer = pixelBuffer(meters), let format,
              let sample = sampleBuffer(buffer, format: format) else { return }
        let output = host.displayLayer.sampleBufferRenderer
        if output.status == .failed {
            log.error("PiP のレイヤーが落ちた: \(String(describing: output.error), privacy: .public)")
            output.flush()
        }
        if output.isReadyForMoreMediaData { output.enqueue(sample) }
    }

    private func pixelBuffer(_ meters: ETMiniMeters) -> CVPixelBuffer? {
        let width = layout.width, height = layout.height
        if pool == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ]
            var made: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &made)
            pool = made
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
        // 上を 0 にする（UIKit の字の描き方に合わせる）。
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        meters.draw(in: context)
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
        Task { @MainActor in ETPiPVisualizer.shared.didStop() }
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
        // アプリに戻すボタン。自分で閉じたのと同じ扱い（戻ってきても出し直さない）。
        Task { @MainActor in ETPiPVisualizer.shared.restoring() }
        completionHandler(true)
    }
}

extension ETPiPVisualizer: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        // ✕ で閉じると止まる前にこれが来る（奪われたときは来ない）。
        guard !playing else { return }
        Task { @MainActor in ETPiPVisualizer.shared.playbackPaused() }
    }

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

/// PiP の元のレイヤーを持つだけの面。
final class ETPiPHostView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer {
        // swiftlint:disable:next force_cast
        layer as! AVSampleBufferDisplayLayer
    }
}
