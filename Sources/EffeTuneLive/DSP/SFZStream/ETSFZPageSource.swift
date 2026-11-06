//  ETSFZPageSource.swift
//  流し込みの標本のページを作って、音のスレッドへ渡す側（供給）。
//
//  engine は SF2・SF3・load_* を持つ SFZ・予算を超える SFZ の PCM を持たず、必要なページ（4096 フレーム）を要求してくる。
//  音のスレッドは ETPipeline_Process の前後で要求を受け取って輪へ積み、用意できたページを publish する
//  （Sources/Shared/ETSampleStream.h）。ここは輪の反対側で、別のスレッドで次の順を回す。
//
//    TakeRequests → AcquirePage → ファイルから読んで float にする → SubmitPage
//
//  ページの作り方は SFZPageDecode.swift（WAV / AIFF の PCM と SF2。上流とビットまで同じ）と、AVAudioFile（FLAC など）と、
//  ETVorbis.c（SF3 の Ogg Vorbis。stb_vorbis。ETSFZVorbisReader.swift）。
//  **置き場が空のあいだは待つ**（音のスレッドが止まっていれば publish が進まない。master bypass・別 node の資産の
//  アップロード・割り込み・バックグラウンド）。要求は engine が再送しないので、捨てると bank を読み直すまでそのページが欠ける。
//  **読めなかった要求は黙って捨てず、失敗として残して手を止める**（ETSampleStream_Fail）。上流の sfzStreamFailed と同じで、
//  読み込む側が Status.failed を見て資産を外すか読み直す。
//
//  **control の側（Attach・Detach・resident の preload）は AssetUpload.holdOffAudioThread の中で呼ぶ。**
//  master bypass のあいだは音のスレッドが engine に触らないので、configure とページの publish をそこでできる。

import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

// MARK: - control の窓

/// ETSampleStream（C）の Swift 側の窓。
enum ETSFZStream {

    /// 上流の `failure('sample-*')` が出す文（js/sfz/sample-page-provider.js）。
    static let preparationFailedMessage = ETSFZPreparedCheck.preparationFailedMessage

    /// 画面や診断が読む状態（ETStreamStatus の写し）。
    struct Status: Equatable {
        var generation: UInt64
        var requestsTaken: UInt64
        var pagesPublished: UInt64
        var pagesStale: UInt64
        var publishErrors: UInt64
        var requestsAbandoned: UInt64
        var requestOverflows: UInt64
        /// 供給が作れなかった要求の数。
        var requestsFailed: UInt64
        /// 0 は無事。0 以外は最初の失敗の理由（ET_STREAM_FAIL_*）で、読み直しが要る。
        var failed: Int
        var outstanding: Int
        var forecastReady: Bool
        /// 圧に負けて先読みの窓を縮めた（上流の stream.limited）。
        var forecastLimited: Bool
        var readinessScope: Int
        var readinessPlanned: Int
        var readinessPending: Int

        var isFailed: Bool { failed != 0 }
    }

    /// 次に使う世代（プロセス全体で増える）。attach にはこれを渡す。
    static func nextGeneration() -> UInt64 { ETSampleStream_NextGeneration() }

    /// node か Section が無効なあいだ先読みを止める。ETPipeline_Publish が node ごとに合わせるので、普通は呼ばなくてよい。
    static func setEnabled(engine: UInt32, instance: UInt32, _ enabled: Bool) {
        ETSampleStream_SetEnabled(engine, instance, enabled ? 1 : 0)
    }

    /// 延ばしてある解放を試す。供給を止めたあとに呼ぶ（ETSFZPageSource.stop() が呼ぶ）。
    @discardableResult
    static func reap() -> Int { Int(ETSampleStream_Reap()) }

    /// instance を流しの対象にする（et_instance_stream_configure も呼ぶ）。**holdOffAudioThread の中で。**
    /// 戻りは slot。generation は nextGeneration() で取る（プロセス全体で増え続ける。前に受けた世代以下は断られる）。
    /// forecast は Note Player の先読み（SELECTED_PRESETS）を回すか。
    static func attach(engine: UInt32, instance: UInt32, generation: UInt64, sampleRate: Double,
                       forecast: Bool) throws -> UInt32 {
        var slot: UInt32 = 0
        let status = ETSampleStream_Attach(engine, instance, generation, sampleRate,
                                           forecast ? UInt32(ET_STREAM_ATTACH_FORECAST) : 0, &slot)
        guard status == 0 else { throw ETSFZError.prepare(preparationFailedMessage) }
        return slot
    }

    /// 流しをやめる。畳んだ slot の数。
    @discardableResult
    static func detach(engine: UInt32, instance: UInt32) -> Int {
        Int(ETSampleStream_Detach(engine, instance))
    }

    static func status(slot: UInt32) -> Status? {
        var raw = ETStreamStatus()
        guard ETSampleStream_Snapshot(slot, &raw) != 0 else { return nil }
        return Status(generation: raw.generation, requestsTaken: raw.requestsTaken, pagesPublished: raw.pagesPublished,
                      pagesStale: raw.pagesStale, publishErrors: raw.publishErrors, requestsAbandoned: raw.requestsAbandoned,
                      requestOverflows: raw.requestOverflows, requestsFailed: raw.requestsFailed,
                      failed: Int(raw.failed), outstanding: Int(raw.outstanding),
                      forecastReady: raw.forecastReady != 0, forecastLimited: raw.forecastLimited != 0,
                      readinessScope: Int(raw.readinessScope), readinessPlanned: Int(raw.readinessPlanned),
                      readinessPending: Int(raw.readinessPending))
    }

    /// resident ページ（先に渡しておく頭のページ）を、control から直に渡す。**holdOffAudioThread の中で。**
    /// 渡した枚数を返す。1 枚でも engine が断れば止める。
    @discardableResult
    static func preload(engine: UInt32, instance: UInt32, generation: UInt64, samples: [ETSFZSampleSource],
                        pages: [(sample: Int, page: UInt64)], reader: ETSFZPageReading = ETSFZPageReader()) throws -> Int {
        defer { reader.close() }
        let capacity = ETSFZPageDecode.pageFrames * 2
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        var published = 0
        for item in pages {
            guard item.sample >= 0, item.sample < samples.count else { throw ETSFZError.prepare(preparationFailedMessage) }
            let result: (frames: Int, channels: Int)
            do { result = try reader.readPage(samples[item.sample], page: item.page, into: buffer, capacity: capacity) }
            catch { throw ETSFZError.prepare(preparationFailedMessage) }
            let status = ETSampleStream_PublishDirect(engine, instance, generation, UInt32(item.sample), item.page, buffer,
                                                      UInt32(result.frames), UInt32(result.channels), 1)
            guard status == 0 else { throw ETSFZError.prepare(preparationFailedMessage) }
            published += 1
        }
        return published
    }
}

// MARK: - 読み手

/// ページ 1 枚を読む口。PCM と SF2 は SFZPageDecode、FLAC などは AVAudioFile。
protocol ETSFZPageReading: AnyObject {
    func readPage(_ source: ETSFZSampleSource, page: UInt64, into out: UnsafeMutablePointer<Float>,
                  capacity: Int) throws -> (frames: Int, channels: Int)
    func close()
}

final class ETSFZPageReader: ETSFZPageReading {

    private let renderer = ETSFZPageRenderer()
    private let vorbis = ETSFZVorbisReader()
    #if canImport(AVFoundation)
    private let audio = ETSFZAudioFileReader()
    #endif

    func readPage(_ source: ETSFZSampleSource, page: UInt64, into out: UnsafeMutablePointer<Float>,
                  capacity: Int) throws -> (frames: Int, channels: Int) {
        do {
            return try renderer.render(source, page: page, into: out, capacity: capacity)
        } catch ETSFZPageError.unsupported {
            if case .vorbis(let layout) = source.format {
                return try vorbis.read(source, layout: layout, page: page, into: out, capacity: capacity)
            }
            #if canImport(AVFoundation)
            return try audio.read(source, page: page, into: out, capacity: capacity)
            #else
            throw ETSFZPageError.unsupported
            #endif
        }
    }

    func close() {
        renderer.close()
        vorbis.close()
        #if canImport(AVFoundation)
        audio.close()
        #endif
    }
}

#if canImport(AVFoundation)
/// AVAudioFile でフレームの範囲を読む（FLAC など、上流が JS で 1 ビットずつ読むもの）。
/// 標本は 1 本のファイルそのもの（書庫の中の位置は読めない）。開いたファイルを少しだけ覚える。**1 つのスレッドから使う。**
final class ETSFZAudioFileReader {

    private var files: [(path: String, file: AVAudioFile)] = []
    private var buffer: AVAudioPCMBuffer?
    private let limit = 8

    func close() {
        files.removeAll()
        buffer = nil
    }

    private func open(_ url: URL) throws -> AVAudioFile {
        if let index = files.firstIndex(where: { $0.path == url.path }) {
            let entry = files.remove(at: index)
            files.append(entry)
            return entry.file
        }
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw ETSFZPageError.changed }
        files.append((url.path, file))
        if files.count > limit { files.removeFirst() }
        return file
    }

    func read(_ source: ETSFZSampleSource, page: UInt64, into out: UnsafeMutablePointer<Float>,
              capacity: Int) throws -> (frames: Int, channels: Int) {
        guard source.baseOffset == 0 else { throw ETSFZPageError.unsupported }
        guard source.channels >= 1, source.channels <= 2 else { throw ETSFZPageError.format }
        guard let frames = ETSFZPageDecode.framesInPage(page, totalFrames: source.frames),
              frames * source.channels <= capacity else { throw ETSFZPageError.range }
        let file = try open(source.url)
        // 長さと形が取り込んだときと同じ（差し替わったファイルを別の標本として鳴らさない）。
        guard UInt64(file.length) == source.frames, Int(file.processingFormat.channelCount) == source.channels else {
            throw ETSFZPageError.changed
        }
        let format = file.processingFormat
        if buffer == nil || buffer!.format != format {
            buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(ETSFZPageDecode.pageFrames))
        }
        guard let pcm = buffer, let planes = pcm.floatChannelData else { throw ETSFZPageError.format }
        file.framePosition = AVAudioFramePosition(page * UInt64(ETSFZPageDecode.pageFrames))
        do { try file.read(into: pcm, frameCount: AVAudioFrameCount(frames)) } catch { throw ETSFZPageError.changed }
        guard Int(pcm.frameLength) == frames else { throw ETSFZPageError.changed }
        // 面ごとの float を、フレームごとにチャンネルを交互に並べる。
        for channel in 0..<source.channels {
            let plane = planes[channel]
            var cursor = channel
            for frame in 0..<frames {
                let value = plane[frame]
                guard value.isFinite else { throw ETSFZPageError.format }
                out[cursor] = value
                cursor += source.channels
            }
        }
        return (frames, source.channels)
    }
}
#endif

// MARK: - 供給のスレッド

/// 1 つの流し（slot と世代）にページを供給するスレッド。バンクを読み直したら止めて作り直す。
/// 失敗（読めない・標本の番号が表の外）したら slot に理由を残して手を止める。
final class ETSFZPageSource: @unchecked Sendable {

    let slot: UInt32
    let generation: UInt64

    private let samples: [ETSFZSampleSource]
    private let reader: ETSFZPageReading
    private let lock = NSLock()
    private var stopped = false
    private var running = false
    private var failures = 0
    private var failedReason: UInt32 = 0
    private var failureHandler: (() -> Void)?
    private let finished = DispatchSemaphore(value: 0)

    init(slot: UInt32, generation: UInt64, samples: [ETSFZSampleSource], reader: ETSFZPageReading = ETSFZPageReader()) {
        self.slot = slot
        self.generation = generation
        self.samples = samples
        self.reader = reader
    }

    /// 作れずに失敗した要求の数（診断用。画面には出さない）。
    var failureCount: Int {
        lock.lock(); defer { lock.unlock() }
        return failures
    }

    /// 最初の失敗の理由（ET_STREAM_FAIL_*）。0 は無事。
    var failure: UInt32 {
        lock.lock(); defer { lock.unlock() }
        return failedReason
    }

    /// 失敗で手を止めたときに、供給のスレッドから 1 度だけ呼ぶ。start() の前に置く。
    /// 資産を外すか読み直すのは読み込む側（上流の sfzStreamFailed → clearPluginAsset）。
    func onFailure(_ handler: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }
        failureHandler = handler
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    func start() {
        lock.lock()
        guard !running, !stopped else { lock.unlock(); return }
        running = true
        lock.unlock()
        // 音のスレッドの隣で先に鳴らす分を作るので、utility より上げておく（足りなければ音が落ちる）。
        let thread = Thread { [self] in
            run()
            finished.signal()
        }
        thread.name = "ai.nemut.effetune.sfz-page-source"
        thread.qualityOfService = .userInitiated
        // SF3 の復号（stb_vorbis）は一時領域をスタックに取る。副スレッドの既定（512 KB）より余裕を持たせる。
        thread.stackSize = 2 * 1024 * 1024
        thread.start()
    }

    /// 止める。スレッドが抜けるまで（最大 1 秒）待ち、延ばしてあった確保の解放を試す。
    func stop() {
        lock.lock()
        stopped = true
        let wasRunning = running
        running = false
        lock.unlock()
        if wasRunning { _ = finished.wait(timeout: .now() + 1.0) }
        // ETPipeline_DestroyInstances は供給を止める前に Detach するので、確保はここまで墓場にある。
        ETSFZStream.reap()
    }

    /// 1 件の結果。
    private enum Outcome {
        case served
        /// 止められた・畳まれた・世代が替わった。失敗ではない。
        case interrupted
        case failed(UInt32)
    }

    private func run() {
        var requests = [ETStreamRequest](repeating: ETStreamRequest(), count: 64)
        while !isStopped {
            let taken = requests.withUnsafeMutableBufferPointer {
                Int(ETSampleStream_TakeRequests(slot, generation, $0.baseAddress, UInt32($0.count)))
            }
            if taken == 0 {
                // 畳まれた（バンクを読み直した・instance を壊した）ら終わる。
                if ETSampleStream_IsCurrent(slot, generation) == 0 { break }
                Thread.sleep(forTimeInterval: 0.002)
                continue
            }
            for index in 0..<taken {
                switch serve(requests[index]) {
                case .served:
                    continue
                case .interrupted:
                    // 取ったまま渡さない分は片付けた数に入れる（畳まれていれば何も起きない）。
                    ETSampleStream_Abandon(slot, generation, UInt32(taken - index))
                case .failed(let reason):
                    // この束の残りも、このスレッドが抜けるので渡せない。まとめて失敗にする。
                    ETSampleStream_Fail(slot, generation, reason, UInt32(taken - index))
                    recordFailure(reason, count: taken - index)
                    reader.close()
                    return
                }
                break
            }
        }
        reader.close()
    }

    private func recordFailure(_ reason: UInt32, count: Int) {
        lock.lock()
        failures += count
        if failedReason == 0 { failedReason = reason }
        let handler = failureHandler
        failureHandler = nil
        lock.unlock()
        handler?()
    }

    /// 置き場が空くまで待つ。**期限は付けない**（音のスレッドが止まっているあいだは空かない。再開すれば空く）。
    /// 止められた・畳まれたら nil。
    private func acquire() -> UnsafeMutablePointer<ETStreamPage>? {
        while true {
            if let page = ETSampleStream_AcquirePage(slot, generation) { return page }
            if isStopped || ETSampleStream_IsCurrent(slot, generation) == 0 { return nil }
            Thread.sleep(forTimeInterval: 0.001)
        }
    }

    private func serve(_ request: ETStreamRequest) -> Outcome {
        guard Int(request.sample) < samples.count else { return .failed(UInt32(ET_STREAM_FAIL_RANGE)) }
        guard let page = acquire() else { return .interrupted }
        let result: (frames: Int, channels: Int)
        do {
            result = try reader.readPage(samples[Int(request.sample)], page: request.page, into: page.pointee.pcm,
                                         capacity: ETSFZPageDecode.pageFrames * 2)
        } catch {
            ETSampleStream_ReleasePage(page)
            // 読んでいる間に畳まれたのなら失敗ではない（バンクを差し替えると読み手が changed を投げうる）。
            return ETSampleStream_IsCurrent(slot, generation) == 0 || isStopped
                ? .interrupted : .failed(UInt32(ET_STREAM_FAIL_READ))
        }
        // engine へ渡せる形か（1〜4096 フレーム・1 か 2 チャンネル）。読み手が守るはずだが、守らなければ失敗として見せる。
        guard result.frames >= 1, result.frames <= ETSFZPageDecode.pageFrames, result.channels >= 1, result.channels <= 2 else {
            ETSampleStream_ReleasePage(page)
            return .failed(UInt32(ET_STREAM_FAIL_SUBMIT))
        }
        var copy = request
        // 0 は世代違いで捨てられた（もう古い要求）。失敗ではない。
        _ = ETSampleStream_SubmitPage(page, &copy, UInt32(result.frames), UInt32(result.channels))
        return .served
    }
}
