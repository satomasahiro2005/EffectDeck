//  SongRecognizer.swift
//  Visualizer の試作。拡張（MDE）から受けた音を ShazamKit に聞かせて、曲とアートワークを取る。
//
//  **音のスレッドには何も足さない。**受け手のリング（ETLinkReceiver。DSP の前の音）を、
//  音のスレッドとは別の読み手が自分の位置で古い順に読む（tapRead）。読むのは専用の直列キューで、
//  250ms ごとに 0.5 秒ぶんまで。link.recv のキューにも ETMeterTap にも触れない。
//
//  問い合わせるのは SHSession だけ（Shazam のカタログ）。48kHz のモノラルに落として溜め、
//  直近 4 秒を SHSignatureGenerator で署名にして 2 秒ごとに match へ投げる（query の説明）。
//  SHManagedSession（マイクを使う）と MusicKit は使わない。
//  ShazamKit を import するのはこのファイルだけ。
//
//  **いつ動くか。**Visualizer のシートが（アプリが前にいて）出ているか、Floating Meters が出ているあいだ
//  （それぞれが setActive を呼ぶ。相手が居なければ読み手は空回りする）。
//  読み手は読んだ音を 12 秒ぶん溜めておき（history）、聞き始めるときは溜めた分から聞かせる。
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
    enum Client: Hashable { case floatingMeters, view(ObjectIdentifier) }

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
    /// ログの写し（Library/Caches/shazam.log）。idevicesyslog は Wi-Fi 越しだと途切れるので、
    /// 後から `xcrun devicectl device copy from` で吸い出せるよう端末に残す。5MB を越えたら空にする。
    private let file: FileHandle? = {
        guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let url = dir.appendingPathComponent("shazam.log")
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 5_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return handle
    }()
    private let stamp: DateFormatter = {
        let made = DateFormatter()
        made.dateFormat = "HH:mm:ss.SSS"
        return made
    }()
    private let timer: DispatchSourceTimer
    /// 溜めておくモノラルの長さ（フレーム）。12 秒（伸ばした窓の上限と同じ）。
    private static let historyFrames = 576_000
    /// 0.5 秒ぶんの interleaved 2ch。一度だけ確保する。
    private var scratch = [Float](repeating: 0, count: 48_000)
    /// 読んだ音のモノラル（輪）。休んでいるあいだも溜める。音が飛んだら捨てる（historyCount = 0）。
    private var history = [Float](repeating: 0, count: historyFrames)
    private var historyHead = 0
    private var historyCount = 0
    private var cursor: UInt64 = 0
    private var generation: UInt64 = 0
    private var session: SHSession?
    /// 問い合わせに使ったフレームの合計（取得状況の fed）。
    private var fedFrames: Int64 = 0
    /// 1 回に問い合わせる長さ（フレーム）。4 秒。
    private static let queryWindow = 192_000
    /// 外れが続いたときに伸ばす窓の上限（フレーム）。12 秒（カタログの最長の署名）。
    /// 4 秒の窓だけだと聞き分けにくい曲が 50 秒外れ続けた（10-17）。外れるたびに 2 秒ずつ伸ばし、当たったら戻す。
    private static let queryWindowMax = 576_000
    private static let queryWindowStep = 96_000
    private var missStreak = 0
    /// 何 tick（250ms）ごとに問い合わせるか。2 秒。
    private static let queryEveryTicks = 8
    /// 返事を待つ上限。これを過ぎたら次を投げる。
    private static let queryTimeout: CFTimeInterval = 6
    private var queryTick = 0
    private var inFlightSince: CFTimeInterval?
    /// カタログが受け付ける最短の署名（フレーム）。makeSession で読む。読むまでは 3 秒。
    private var minimumQueryFrames = 144_000.0
    private var queries = 0
    private var lastLatency = "-"

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
                note("peer lost")
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
            note("tap skipped \(skipped) samples")
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
                note("session dropped: \(clear ? "attempt timed out" : "no data")")
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
            query()
        case .feed:
            queryTick += 1
            if queryTick >= Self.queryEveryTicks { query() }
        case .drop(let clear):
            dropSession()
            if clear { publish(nil) }
            note("session dropped: \(clear ? "attempt timed out" : "silence")")
        case .skip:
            break
        }
    }

    private func makeSession() {
        let made = SHSession()
        made.delegate = self
        session = made
        sessions += 1
        loggedMiss = false
        inFlightSince = nil
        queryTick = 0
        let catalog = made.catalog
        minimumQueryFrames = max(1, catalog.minimumQuerySignatureDuration) * Self.sampleRate
        if !Self.loggedCatalog {
            Self.loggedCatalog = true
            note("catalog query signature \(catalog.minimumQuerySignatureDuration)s...\(catalog.maximumQuerySignatureDuration)s")
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
            "queries=\(queries)",
            "window=\(min(Self.queryWindow + missStreak * Self.queryWindowStep, Self.queryWindowMax) / 48_000)s",
            "latency=\(lastLatency)",
            "sessions=\(sessions)",
            "matches=\(matches)",
            "misses=\(misses)",
            "skipped=\(skippedTotal)",
            "lastError=\(lastError)",
            "match=\(lastMatch)",
        ]
        note("status \(fields.joined(separator: " "))")
        let line = fields.joined(separator: "\n")
        Task { @MainActor [self] in ETSongRecognizer.shared.publish(status: line, from: self) }
    }

    /// queue の上で呼ぶ。
    private func note(_ line: String) {
        Self.log.notice("\(line, privacy: .public)")
        // 旧 API の write(_:) は I/O エラーで ObjC 例外を投げ、Swift では捕まえられない。
        try? file?.write(contentsOf: Data("\(stamp.string(from: Date())) \(line)\n".utf8))
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

    /// 溜めた音の新しいほうから最大 queryWindow ぶんを署名にして問い合わせる。
    /// **長い流れ（matchStreamingBuffer）を 1 本で聞かせるのはやめた。**流れは窓に古い曲が残ると
    /// 当たらず、窓を 12 秒まで伸ばしてから聞き直すように見えた（10-17 の実機のログで曲の替わり目だけ
    /// 当たりが 12 秒刻みになり、新しい曲まで 10〜22 秒かかった）。短い窓を決まった間隔で投げれば、
    /// 窓に古い曲が残るのは最大 queryWindow ぶんだけになる。
    private func query() {
        guard let session else { return }
        let now = CACurrentMediaTime()
        // 返事を待っているあいだは重ねない（返事が来なければ queryTimeout で諦めて投げ直す）。
        if let sent = inFlightSince, now - sent < Self.queryTimeout { return }
        let n = Self.historyFrames
        // 外れが続くあいだは、直近 4 秒と伸ばした窓を交互に投げる。伸ばした窓だけにすると、曲を替えた直後は
        // 前の曲の音をかえって多く含み、新しい曲が窓の大半を占めるまで 4 回（約 8 秒）外れ続けた（10-17 の shazam.log）。
        // 直近 4 秒で曲の替わりを拾い、伸ばした窓で聞き分けにくい曲を拾う。
        let long = missStreak > 0 && queries % 2 == 1
        let window = long ? min(Self.queryWindow + missStreak * Self.queryWindowStep, Self.queryWindowMax) : Self.queryWindow
        let count = min(historyCount, window)
        guard Double(count) >= minimumQueryFrames,
              let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        let start = (historyHead - count + n) % n
        for i in 0..<count { channel[i] = history[(start + i) % n] }
        let generator = SHSignatureGenerator()
        do {
            try generator.append(buffer, at: nil)
        } catch {
            note("signature failed \((error as NSError).domain) \((error as NSError).code)")
            return
        }
        session.match(generator.signature())
        inFlightSince = now
        queries += 1
        queryTick = 0
        fedFrames += Int64(count)
    }

    /// 返事が来た。かかった時間を残す（速さを測るため）。
    private func answered(_ what: String) {
        guard let sent = inFlightSince else { return }
        inFlightSince = nil
        lastLatency = String(format: "%.2fs", CACurrentMediaTime() - sent)
        note("answer \(what) latency=\(lastLatency)")
    }

    private func publish(_ song: ETRecognizedSong?) {
        Task { @MainActor [self] in ETSongRecognizer.shared.publish(song, from: self) }
    }

    // MARK: - SHSessionDelegate（知らないスレッドから来る）

    func session(_ session: SHSession, didFind match: SHMatch) {
        queue.async { [self] in
            // 作り直す前のセッションの返事は捨てる。
            guard self.session === session, let item = match.mediaItems.first else { return }
            answered("match")
            let title = item.title ?? "Unknown"
            let id = item.shazamID ?? item.isrc ?? item.appleMusicID ?? "\(title)|\(item.artist ?? "")"
            let song = ETRecognizedSong(id: id, title: title, artist: item.artist, artworkURL: item.artworkURL)
            matches += 1
            lastMatch = String(format: "conf=%.2f skew=%.4f offset=%.1fs", item.confidence,
                               item.frequencySkew, item.predictedCurrentMatchOffset)
            missStreak = 0
            let changed = policy.matched(id: id, skew: item.frequencySkew)
            note("find id=\(id) title=\(title) conf=\(item.confidence) skew=\(item.frequencySkew) matchOffset=\(item.matchOffset) offset=\(item.predictedCurrentMatchOffset) changed=\(changed)")
            guard changed else { return }
            note("matched id=\(id) title=\(title) artist=\(item.artist ?? "-") artwork=\(item.artworkURL?.absoluteString ?? "-")")
            publish(song)
        }
    }

    func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
        queue.async { [self] in
            guard self.session === session else { return }
            answered(error == nil ? "miss" : "error")
            guard let error else {
                misses += 1
                missStreak += 1
                // 外れても聞かせ続ける（streaming が聞き直す）。ログは 1 セッションに 1 回。
                if !loggedMiss {
                    loggedMiss = true
                    note("no match")
                }
                return
            }
            // 202（Missing entitlements = App Services の ShazamKit が未有効）も、ここのログだけで画面には出さない。
            let ns = error as NSError
            lastError = "\(ns.domain) \(ns.code)"
            let underlying = (ns.userInfo[NSUnderlyingErrorKey] as? NSError).map { "\($0.domain) \($0.code)" } ?? "-"
            note("error domain=\(ns.domain) code=\(ns.code) \(ns.localizedDescription) underlying=\(underlying)")
            policy.failed(code: ns.code, now: CACurrentMediaTime())
            dropSession()
        }
    }
}
