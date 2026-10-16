//  SongRecognizer.swift
//  Visualizer の試作。拡張（MDE）から受けた音を ShazamKit に聞かせて、曲とアートワークを取る。
//
//  **音のスレッドには何も足さない。**受け手のリング（ETLinkReceiver。DSP の前の音）を、
//  音のスレッドとは別の読み手が自分の位置で古い順に読む（tapRead）。読むのは専用の直列キューで、
//  250ms ごとに 0.5 秒ぶんまで。link.recv のキューにも ETMeterTap にも触れない。
//
//  聞かせるのは SHSession だけ（Shazam のカタログ）。48kHz のモノラルに落として
//  matchStreamingBuffer へ渡す。SHManagedSession・SHSignatureGenerator・MusicKit は使わない。
//  ShazamKit を import するのはこのファイルだけ。
//
//  **いつ動くか。**Visualizer のシートが出ていて、アプリが前にいて、拡張から音が来ているあいだだけ
//  （VisualizerView が start / stop を呼ぶ。相手が居なければ読み手は空回りする）。
//  聞かせる長さ・休み・無音の扱いは SongRecognitionPolicy（Foundation だけ。そちらに説明）。
//
//  **ShazamKit は音の指紋を Apple へ送る。**だから ETFeatures.visualizer は Debug と Beta だけ。
//  App ID の App Services で ShazamKit を有効にしておくこと（entitlement のキーは足さない）。
//  外れていると com.apple.ShazamKit の 202（Missing entitlements）がログに出る。画面には何も出さない。
//
//  撮影用に `-ETMockShazam 1` で作り物の曲を出す（ShazamKit は動かさない）。

import AVFoundation
import Observation
import ShazamKit
import UIKit
import os

@Observable @MainActor
final class ETSongRecognizer {

    static let shared = ETSongRecognizer()

    /// いま出す曲。聞き取れていない・やめているあいだは nil。
    private(set) var current: ETRecognizedSong?

    @ObservationIgnored fileprivate var feeder: ETShazamFeeder?
    @ObservationIgnored private var mock: Task<Void, Never>?

    private init() {}

    /// 聞き取りを始める。繰り返し呼んでよい。
    func start() {
        guard feeder == nil, mock == nil else { return }
        if UserDefaults.standard.bool(forKey: "ETMockShazam") {
            mock = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                publish(Self.mockSong())
            }
            return
        }
        let made = ETShazamFeeder()
        feeder = made
        made.start()
    }

    /// やめる。繰り返し呼んでよい。出ている曲も消す。
    func stop() {
        feeder?.stop()
        feeder = nil
        mock?.cancel()
        mock = nil
        current = nil
    }

    fileprivate func publish(_ song: ETRecognizedSong?) {
        guard current != song else { return }
        current = song
    }

    /// 止めたあとに遅れて届いた結果を捨てるため、出した読み手がまだ生きているかを見る。
    fileprivate func publish(_ song: ETRecognizedSong?, from source: ETShazamFeeder) {
        guard feeder === source else { return }
        publish(song)
    }

    /// AsyncImage の道を通すために、手元で描いた PNG のファイルを指す。
    private static func mockSong() -> ETRecognizedSong {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("et-mock-artwork.png")
        if !FileManager.default.fileExists(atPath: url.path) {
            let size = CGSize(width: 600, height: 600)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                let colors = [UIColor.systemIndigo.cgColor, UIColor.systemPink.cgColor] as CFArray
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                    context.cgContext.drawLinearGradient(gradient, start: .zero,
                                                         end: CGPoint(x: size.width, y: size.height), options: [])
                }
            }
            try? image.pngData()?.write(to: url)
        }
        return ETRecognizedSong(id: "mock", title: "Mock Song", artist: "Mock Artist", artworkURL: url)
    }
}

/// 受け手のリングを読んで SHSession に聞かせる。**持ち物は全部 queue の上でだけ触る**
/// （delegate は知らないスレッドから呼ばれるので、queue に移してから触る）。
final class ETShazamFeeder: NSObject, SHSessionDelegate, @unchecked Sendable {

    private static let log = Logger(subsystem: "ai.nemut.effetune", category: "shazam")
    private static let sampleRate = 48_000.0
    /// 1 回に読む上限（フレーム）。250ms ごとに 12000 フレームずつ来るので、遅れても 1 秒ぶんまで。
    private static let maxFrames: UInt32 = 24_000
    /// SHSession へ渡す形。ここに無い形は渡さない（変換器を挟まない）。
    private static let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    private static var loggedCatalog = false

    private let queue = DispatchQueue(label: "ai.nemut.effetune.shazam", qos: .utility)
    private let timer: DispatchSourceTimer
    /// 0.5 秒ぶんの interleaved 2ch。一度だけ確保する。
    private var scratch = [Float](repeating: 0, count: 48_000)
    private var cursor: UInt64 = 0
    private var generation: UInt64 = 0
    private var session: SHSession?
    private var fedFrames: Int64 = 0
    private var policy = SongRecognitionPolicy()
    private var hadPeer = false
    private var loggedMiss = false

    override init() {
        timer = DispatchSource.makeTimerSource(queue: queue)
        super.init()
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(50))
    }

    func start() {
        timer.resume()
    }

    func stop() {
        queue.sync {
            timer.cancel()
            dropSession()
            policy.reset()
        }
    }

    // MARK: - 読む

    private func tick() {
        let rx = ETLinkReceiver.shared
        guard rx.hasPeer else {
            if hadPeer {
                hadPeer = false
                dropSession()
                policy.peerLost()
                publish(nil)
                Self.log.notice("peer lost")
            }
            return
        }
        // 繋がった直後と繋ぎ直しは「いま」から読む（古い音を聞かせ直さない）。
        if !hadPeer || rx.peerGeneration != generation {
            hadPeer = true
            generation = rx.peerGeneration
            cursor = rx.tapWritePosition()
            dropSession()
            policy.peerLost()
            publish(nil)
            return
        }

        var skipped: UInt64 = 0
        let frames = Int(rx.tapRead(from: &cursor, into: &scratch, maxFrames: Self.maxFrames, skipped: &skipped))
        if skipped > 0 {
            Self.log.notice("tap skipped \(skipped, privacy: .public) samples")
            dropSession()
            policy.discontinuity()
        }
        guard frames > 0 else {
            // 新しい音が来ないのも無音と見る。元のアプリが止まるとホストは IO を止めるが、
            // 接続は残って tapRead は 0 を返し続ける。時計を進めないと聞き取りが居座り、
            // 再開時に時刻の飛んだ流れを聞かせてしまう。
            if case .drop(let clear) = policy.audio(now: CACurrentMediaTime(), peak: 0) {
                dropSession()
                if clear { publish(nil) }
                Self.log.notice("session dropped: \(clear ? "attempt timed out" : "no data", privacy: .public)")
            }
            return
        }

        var peak: Float = 0
        for i in 0..<(frames * 2) { peak = max(peak, abs(scratch[i])) }

        switch policy.audio(now: CACurrentMediaTime(), peak: peak) {
        case .startAndFeed:
            makeSession()
            feed(frames: frames)
        case .feed:
            feed(frames: frames)
        case .drop(let clear):
            dropSession()
            if clear { publish(nil) }
            Self.log.notice("session dropped: \(clear ? "attempt timed out" : "silence", privacy: .public)")
        case .skip:
            break
        }
    }

    private func makeSession() {
        let made = SHSession()
        made.delegate = self
        session = made
        fedFrames = 0
        loggedMiss = false
        if !Self.loggedCatalog {
            Self.loggedCatalog = true
            let catalog = made.catalog
            Self.log.notice("catalog query signature \(catalog.minimumQuerySignatureDuration, privacy: .public)s...\(catalog.maximumQuerySignatureDuration, privacy: .public)s")
        }
    }

    private func dropSession() {
        session?.delegate = nil
        session = nil
    }

    /// 左右を平均したモノラルにして聞かせる。SHSession が後まで持つかもしれないので、
    /// 毎回新しい器にする（音のスレッドではないので確保してよい）。
    private func feed(frames: Int) {
        guard let session,
              let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { channel[i] = 0.5 * (scratch[2 * i] + scratch[2 * i + 1]) }
        session.matchStreamingBuffer(buffer, at: AVAudioTime(sampleTime: fedFrames, atRate: Self.sampleRate))
        fedFrames += Int64(frames)
    }

    private func publish(_ song: ETRecognizedSong?) {
        Task { @MainActor [self] in ETSongRecognizer.shared.publish(song, from: self) }
    }

    // MARK: - SHSessionDelegate（知らないスレッドから来る）

    func session(_ session: SHSession, didFind match: SHMatch) {
        queue.async { [self] in
            // 作り直す前のセッションの返事は捨てる。
            guard self.session === session, let item = match.mediaItems.first else { return }
            let title = item.title ?? "Unknown"
            let id = item.shazamID ?? item.isrc ?? item.appleMusicID ?? "\(title)|\(item.artist ?? "")"
            let song = ETRecognizedSong(id: id, title: title, artist: item.artist, artworkURL: item.artworkURL)
            let changed = policy.matched(id: id, now: CACurrentMediaTime())
            dropSession()
            guard changed else { return }
            Self.log.notice("matched id=\(id, privacy: .public) title=\(title, privacy: .public) artist=\(item.artist ?? "-", privacy: .public) artwork=\(item.artworkURL?.absoluteString ?? "-", privacy: .public)")
            publish(song)
        }
    }

    func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
        queue.async { [self] in
            guard self.session === session else { return }
            guard let error else {
                // 外れは続けて聞かせる（上限まで streaming が聞き直す）。ログは 1 セッションに 1 回。
                if !loggedMiss {
                    loggedMiss = true
                    Self.log.notice("no match")
                }
                return
            }
            // 202（Missing entitlements = App Services の ShazamKit が未有効）も、ここのログだけで画面には出さない。
            let ns = error as NSError
            let underlying = (ns.userInfo[NSUnderlyingErrorKey] as? NSError).map { "\($0.domain) \($0.code)" } ?? "-"
            Self.log.notice("error domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public) \(ns.localizedDescription, privacy: .public) underlying=\(underlying, privacy: .public)")
            policy.failed(code: ns.code, now: CACurrentMediaTime())
            dropSession()
        }
    }
}
