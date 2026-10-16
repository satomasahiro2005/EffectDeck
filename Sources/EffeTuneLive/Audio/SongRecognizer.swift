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
//  **いつ動くか。**Visualizer のシートが（アプリが前にいて）出ているか、Floating Meters が出ているあいだ
//  （それぞれが setActive を呼ぶ。相手が居なければ読み手は空回りする）。
//  読み手は読んだ音を 10 秒ぶん溜めておき（history）、聞き始めるときは溜めた分から聞かせる。
//  無音やエラーのあとの聞き直しがすぐ当たるように。
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
    /// 取得状況（logStatus と同じ中身を 1 項目 1 行で）。デバッグ用の画面に出す。
    private(set) var status = ""
    /// current のアートワーク。Floating Meters が CoreGraphics で描く。読み込むまでは nil。
    @ObservationIgnored private(set) var artwork: CGImage?

    /// 聞き取りを頼んでいる所。どれかが居るあいだ動く。
    enum Client { case sheet, floatingMeters }

    @ObservationIgnored fileprivate var feeder: ETShazamFeeder?
    @ObservationIgnored private var mock: Task<Void, Never>?
    @ObservationIgnored private var clients: Set<Client> = []
    @ObservationIgnored private var artworkTask: Task<Void, Never>?

    private init() {}

    func setActive(_ active: Bool, for client: Client) {
        if active { clients.insert(client) } else { clients.remove(client) }
        if clients.isEmpty { stop() } else { start() }
    }

    /// 聞き取りを始める。繰り返し呼んでよい。
    private func start() {
        guard mock == nil else { return }
        if let feeder { feeder.start(); return }
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

    /// やめる。繰り返し呼んでよい。出ている曲と取得状況は残す（画面を離れても消えないように。本人）。
    /// 読み手も捨てずに止めるだけにして、数（一致・外れ・最後のエラー）を次に始めたときへ持ち越す。
    private func stop() {
        feeder?.pause()
        mock?.cancel()
        mock = nil
    }

    fileprivate func publish(_ song: ETRecognizedSong?) {
        guard current != song else { return }
        current = song
        artworkTask?.cancel()
        artworkTask = nil
        artwork = nil
        guard let song, let url = song.artworkURL else { return }
        artworkTask = Task { @MainActor [weak self] in
            let image = await Self.loadImage(url)
            guard !Task.isCancelled, let self, self.current == song else { return }
            self.artwork = image
        }
    }

    /// URLCache.shared に乗せる（AsyncImage と同じ置き場）。
    private static func loadImage(_ url: URL) async -> CGImage? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return UIImage(data: data)?.cgImage
    }

    /// 止めたあとに遅れて届いた結果を捨てるため、出した読み手がまだ生きているかを見る。
    fileprivate func publish(status line: String, from source: ETShazamFeeder) {
        guard feeder === source else { return }
        status = line
    }

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
    /// 溜めておくモノラルの長さ（フレーム）。10 秒。
    private static let historyFrames = 480_000
    /// 0.5 秒ぶんの interleaved 2ch。一度だけ確保する。
    private var scratch = [Float](repeating: 0, count: 48_000)
    /// 読んだ音のモノラル（輪）。休んでいるあいだも溜める。音が飛んだら捨てる（historyCount = 0）。
    private var history = [Float](repeating: 0, count: historyFrames)
    private var historyHead = 0
    private var historyCount = 0
    private var cursor: UInt64 = 0
    private var generation: UInt64 = 0
    private var session: SHSession?
    private var fedFrames: Int64 = 0
    private var policy = SongRecognitionPolicy()
    private var hadPeer = false
    /// timer が動いているか（DispatchSource の resume / suspend は対にしないと落ちる）。
    private var running = false
    /// 止めていたあいだの音を読まないよう、次の tick で読む位置を「いま」へ移す。
    private var resync = false
    private var loggedMiss = false
    // 取得状況を 1 秒ごとにログへ出すための数（logStatus）。
    private var ticks = 0
    private var lastPeak: Float = 0
    private var skippedTotal: UInt64 = 0
    private var sessions = 0
    private var matches = 0
    private var misses = 0
    private var lastError = "-"
    /// 最後の一致の中身（SHMatchedMediaItem）。一致度は 0〜1。
    private var lastMatch = "-"

    override init() {
        timer = DispatchSource.makeTimerSource(queue: queue)
        super.init()
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(50))
    }

    /// 止めてあれば動かす。繰り返し呼んでよい。
    func start() {
        queue.sync {
            guard !running else { return }
            running = true
            timer.resume()
        }
    }

    /// 止める。数と相手の世代は残し、次に動かしたときは「いま」から読む。
    func pause() {
        queue.sync {
            guard running else { return }
            running = false
            timer.suspend()
            dropSession()
            policy.discontinuity()
            historyCount = 0
            resync = true
        }
    }

    // MARK: - 読む

    private func tick() {
        ticks += 1
        if ticks % 4 == 0 { logStatus() }
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
            historyCount = 0
            publish(nil)
            return
        }
        if resync {
            resync = false
            cursor = rx.tapWritePosition()
            return
        }

        var skipped: UInt64 = 0
        let frames = Int(rx.tapRead(from: &cursor, into: &scratch, maxFrames: Self.maxFrames, skipped: &skipped))
        if skipped > 0 {
            skippedTotal += skipped
            Self.log.notice("tap skipped \(skipped, privacy: .public) samples")
            dropSession()
            policy.discontinuity()
            historyCount = 0
        }
        guard frames > 0 else {
            // 新しい音が来ないのも無音と見る。元のアプリが止まるとホストは IO を止めるが、
            // 接続は残って tapRead は 0 を返し続ける。時計を進めないと聞き取りが居座り、
            // 再開時に時刻の飛んだ流れを聞かせてしまう。
            lastPeak = 0
            if case .drop(let clear) = policy.audio(now: CACurrentMediaTime(), peak: 0) {
                dropSession()
                // 止まる前と再開後の音をつなげて聞かせない。
                historyCount = 0
                if clear { publish(nil) }
                Self.log.notice("session dropped: \(clear ? "attempt timed out" : "no data", privacy: .public)")
            }
            return
        }

        var peak: Float = 0
        for i in 0..<(frames * 2) { peak = max(peak, abs(scratch[i])) }
        lastPeak = peak
        remember(frames: frames)

        switch policy.audio(now: CACurrentMediaTime(), peak: peak) {
        case .startAndFeed:
            makeSession()
            feedHistory()
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
        sessions += 1
        fedFrames = 0
        loggedMiss = false
        if !Self.loggedCatalog {
            Self.loggedCatalog = true
            let catalog = made.catalog
            Self.log.notice("catalog query signature \(catalog.minimumQuerySignatureDuration, privacy: .public)s...\(catalog.maximumQuerySignatureDuration, privacy: .public)s")
        }
    }

    private func logStatus() {
        let db = lastPeak > 0 ? 20 * log10(lastPeak) : -.infinity
        let fields = [
            "peer=\(hadPeer)",
            "phase=\(policy.phase)",
            "peak=\(String(format: "%.1f", db))dB",
            "session=\(session != nil)",
            "fed=\(fedFrames)",
            "sessions=\(sessions)",
            "matches=\(matches)",
            "misses=\(misses)",
            "skipped=\(skippedTotal)",
            "lastError=\(lastError)",
            "match=\(lastMatch)",
        ]
        Self.log.notice("status \(fields.joined(separator: " "), privacy: .public)")
        let line = fields.joined(separator: "\n")
        Task { @MainActor [self] in ETSongRecognizer.shared.publish(status: line, from: self) }
    }

    private func dropSession() {
        session?.delegate = nil
        session = nil
    }

    /// 左右を平均したモノラルを溜める。
    private func remember(frames: Int) {
        let n = Self.historyFrames
        for i in 0..<frames {
            history[historyHead] = 0.5 * (scratch[2 * i] + scratch[2 * i + 1])
            historyHead = (historyHead + 1) % n
        }
        historyCount = min(historyCount + frames, n)
    }

    /// 溜めた分（いま読んだ分を含む）を古い順に聞かせる。
    private func feedHistory() {
        let n = Self.historyFrames, count = historyCount
        guard let session, count > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        let start = (historyHead - count + n) % n
        for i in 0..<count { channel[i] = history[(start + i) % n] }
        session.matchStreamingBuffer(buffer, at: AVAudioTime(sampleTime: fedFrames, atRate: Self.sampleRate))
        fedFrames += Int64(count)
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
            matches += 1
            lastMatch = String(format: "conf=%.2f skew=%.4f offset=%.1fs", item.confidence,
                               item.frequencySkew, item.predictedCurrentMatchOffset)
            let changed = policy.matched(id: id)
            guard changed else { return }
            Self.log.notice("matched id=\(id, privacy: .public) title=\(title, privacy: .public) artist=\(item.artist ?? "-", privacy: .public) artwork=\(item.artworkURL?.absoluteString ?? "-", privacy: .public)")
            publish(song)
        }
    }

    func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
        queue.async { [self] in
            guard self.session === session else { return }
            guard let error else {
                misses += 1
                // 外れても聞かせ続ける（streaming が聞き直す）。ログは 1 セッションに 1 回。
                if !loggedMiss {
                    loggedMiss = true
                    Self.log.notice("no match")
                }
                return
            }
            // 202（Missing entitlements = App Services の ShazamKit が未有効）も、ここのログだけで画面には出さない。
            let ns = error as NSError
            lastError = "\(ns.domain) \(ns.code)"
            let underlying = (ns.userInfo[NSUnderlyingErrorKey] as? NSError).map { "\($0.domain) \($0.code)" } ?? "-"
            Self.log.notice("error domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public) \(ns.localizedDescription, privacy: .public) underlying=\(underlying, privacy: .public)")
            policy.failed(code: ns.code, now: CACurrentMediaTime())
            dropSession()
        }
    }
}
