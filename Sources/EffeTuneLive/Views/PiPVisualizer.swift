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
//  **入り切りはメニューのトグル（selected）。**入っているあいだに PiP が外で止まったら、このアプリが
//  前に来たときにもう一度出す。YouTube などが PiP を始めるとこちらは止められるため（PiP は 1 つだけ）。
//  外で ✕ を押したのと奪われたのは見分けられない。実機のログ（10-16）では届く知らせ
//  （setPlaying(false) → willStop → didStop、0.8 秒）も止まった後の possible も同じで、他のアプリが
//  鳴っているかで分けても、音楽を流しながらの ✕ は奪われたのと同じになった（本人「自分でバツしてもなる」）。
//  なので止める操作をはっきりさせた（本人「mini metersはトグルにするか」）。**切るのはメニューの Off と拡大。**
//  このアプリの中で ✕ を押しても切らず、次にこのアプリが前に来たときに出す（本人「オフにしないで勝手に」）。
//  ただしアプリに戻すボタン（拡大）は切る。切らないとアプリの中でまた出て、閉じる手が Off しか無い。
//  Debug と Beta では、拡大はそのうえで Visualizer のシートを開く（ETFeatures.visualizer）。

import AVKit
import CoreMedia
import UIKit
import os

@MainActor
final class ETPiPVisualizer: NSObject, ObservableObject {

    static let shared = ETPiPVisualizer()

    /// 測っている所（ET_METER_TAP_INPUT / ET_METER_TAP_OUTPUT）。nil なら出していない。
    @Published private(set) var point: Int32?
    /// メニューのトグル。入っている所。nil なら切ってある。外で止まっても、これが残っていれば出し直す。
    @Published private(set) var selected: Int32?
    /// アプリに戻すボタンで Visualizer を開く頼み。PipelineView が数の変化だけを見る。
    @Published private(set) var visualizerRequests = 0

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
    /// 器の形。iPad も iPhone と同じ横長の 1 段（本人「ipadでもiphoneと揃えてくれ」）。
    private let layout: ETMiniMeters.Layout = ETFeatures.visualizer ? .stripWithArtwork : .strip
    /// 最後に前に来た時刻。前に来た直後に止められたのは、離れたアプリの PiP に奪われたもの。
    private var activeAt: CFTimeInterval = 0
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

    /// メニューのトグル。nil で切る。
    func select(_ newPoint: Int32?) {
        selected = newPoint
        if let newPoint { start(point: newPoint) } else { stop() }
    }

    private func start(point newPoint: Int32) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            log.error("PiP が使えない端末")
            return
        }
        ETMeterTap_SetPoint(newPoint)
        if point != nil, controller?.isPictureInPictureActive == true {
            // 出ている窓のまま、測る所だけ替える。
            point = newPoint
            meters?.reset()
            return
        }
        point = newPoint
        prepare()
        if ETFeatures.visualizer { ETSongRecognizer.shared.setActive(true, for: .floatingMeters) }
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

    private func stop() {
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
        attempt += 1
        let this = attempt
        controller.startPictureInPicture()
        // **黙って始まらないことがある。**作ったばかりの係では possible が真でも、
        // startPictureInPicture が何も言わずに終わる（実機のログ。2 回目に押すと出た）。
        // 少し待っても始まりかけていなければ、もう一度だけ始める。
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            ETPiPVisualizer.shared.retryIfSilent(this)
        }
    }

    /// 何回目に始めたか。retryIfSilent が古い回のやり直しをしないように。
    private var attempt = 0
    /// willStart が来たか（始まりかけている）。
    fileprivate var starting = false

    private func retryIfSilent(_ this: Int) {
        guard this == attempt, point != nil, let controller,
              !starting, !controller.isPictureInPictureActive else { return }
        log.info("PiP が始まらなかったのでもう一度 possible=\(controller.isPictureInPicturePossible, privacy: .public)")
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
        if ETFeatures.visualizer { ETSongRecognizer.shared.setActive(false, for: .floatingMeters) }
    }

    /// PiP が止まった。トグルが入ったままなら、前に来たときに出し直す。
    fileprivate func didStop() {
        starting = false
        let now = CACurrentMediaTime()
        let state = UIApplication.shared.applicationState
        // 前にいて、前に来てから時間が経っている → このアプリの中で ✕ を押した。切る。
        // 前に来た直後なら、離れたアプリの PiP に奪われた（✕ を押す間は無い）。
        let closedInApp = state == .active && now - activeAt > 2
        log.info("PiP が止まった selected=\(self.selected != nil, privacy: .public) state=\(state.rawValue, privacy: .public) sinceActive=\(now - self.activeAt, privacy: .public)")
        teardown()
        // 中で ✕ を押したのなら、次に前に来るまで出し直さない。
        if state == .active && !closedInApp { resume() }
    }

    private func becameActive() {
        activeAt = CACurrentMediaTime()
        // 起きたときと戻ったときに用意する。押したその場で始められるように。
        prepare()
        resume()
    }

    /// トグルが入っていて出ていなければ出し直す。
    private func resume() {
        guard let again = selected, point == nil else { return }
        log.info("PiP を出し直す")
        // 前に来た回のうちはまだ始められないことがあるので、1 回遅らせる。
        Task { @MainActor in
            let pip = ETPiPVisualizer.shared
            guard pip.selected == again, pip.point == nil else { return }
            pip.start(point: again)
        }
    }

    /// アプリに戻すボタン（拡大）。切る。切らないと、戻ってきたアプリの中でまた出て、
    /// メニューの Off 以外に閉じる手が無くなる（本人「拡大したらオフにしないと戻す方法がない」）。
    fileprivate func restoring() {
        selected = nil
        if ETFeatures.visualizer { visualizerRequests &+= 1 }
    }

    private func attachHost() {
        // 前に来た知らせの時点ではまだ鍵の窓が無いことがある（起動直後）。そのときは前にいる場面の窓に置く。
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.filter { $0.activationState == .foregroundActive }.flatMap(\.windows)
            + scenes.flatMap(\.windows)
        guard host.superview == nil,
              let window = windows.first(where: \.isKeyWindow) ?? windows.first else { return }
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
        if ETFeatures.visualizer { meters.artwork = ETSongRecognizer.shared.artwork }
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
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            ETPiPVisualizer.shared.starting = true
            ETPiPVisualizer.shared.log.info("PiP が始まる")
        }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in ETPiPVisualizer.shared.starting = false }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in ETPiPVisualizer.shared.didStop() }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error) {
        let text = error.localizedDescription
        Task { @MainActor in
            ETPiPVisualizer.shared.starting = false
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

/// PiP の元のレイヤーを持つだけの面。
final class ETPiPHostView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer {
        // swiftlint:disable:next force_cast
        layer as! AVSampleBufferDisplayLayer
    }
}
