//  ETSFZVorbisReader.swift
//  SF3 の標本（モノの Ogg Vorbis）のページ（4096 フレーム）を、ETVorbis.c（stb_vorbis）で作る。
//
//  標本ごとに Ogg を読んで ETVorbisStream を作り、先頭から復号した PCM を覚える（頭のページだけ要る resident ページは
//  1 ページ分しか復号しない。続きは先読みする）。覚える量には上限があり、超えたら使っていない標本から外す（要るとき復号し直す）。
//  復号器（符号表で数百 KB）を開いたままにするのは、直近に使った数本だけ。
//  **1 つのスレッドから使う。**ETSFZPageReader（ETSFZPageSource.swift）が持ち、供給のスレッドか resident の preload から呼ぶ。
//
//  標本のフレーム 0 は、復号後（最後の granule で切った全体）の firstFrame 番目（ETSFZVorbisLayout）。
//  ページ p は標本のフレーム p × 4096 から。
//
//  Apple のプラットフォームだけ（C の ETVorbis.h を橋で引く。Linux の試験は空になる）。

#if canImport(Darwin)
import Foundation

final class ETSFZVorbisReader {

    private struct Key: Hashable {
        var path: String
        var offset: UInt64
    }

    /// 覚える量の上限（Ogg の写し + 復号済みの PCM + 開いている復号器）。1 本の標本が超えるときは、その 1 本だけ残す。
    static let budget = 64 * 1024 * 1024
    /// 復号器を開いたままにする標本の数。
    static let openDecoders = 8

    private let files = ETSFZFileReader()
    private var cache: ETSFZBudgetCache<Key, OpaquePointer>
    private let decoderLimit: Int

    init(budget: Int = ETSFZVorbisReader.budget, openDecoders: Int = ETSFZVorbisReader.openDecoders) {
        cache = ETSFZBudgetCache(budget: budget)
        decoderLimit = max(0, openDecoders)
    }

    deinit { close() }

    /// 覚えている標本の数と、そのうち復号器を開いているもの（試験が見る）。
    var cachedCount: Int { cache.count }
    var openDecoderCount: Int { cache.order.filter { key in cache.peek(key).map { ETVorbisStream_HasDecoder($0) != 0 } ?? false }.count }

    func close() {
        for stream in cache.removeAll() { ETVorbisStream_Close(stream) }
        files.closeAll()
    }

    func read(_ source: ETSFZSampleSource, layout: ETSFZVorbisLayout, page: UInt64, into out: UnsafeMutablePointer<Float>,
              capacity: Int) throws -> (frames: Int, channels: Int) {
        guard source.channels == 1 else { throw ETSFZPageError.format }
        guard layout.isValid(frames: source.frames) else { throw ETSFZPageError.format }
        guard let frames = ETSFZPageDecode.framesInPage(page, totalFrames: source.frames), frames <= capacity else {
            throw ETSFZPageError.range
        }
        let key = Key(path: source.url.path, offset: source.baseOffset &+ layout.dataOffset)
        let stream = try open(key, source: source, layout: layout)
        // 標本のフレーム 0 は復号後の firstFrame。ページは 4096 フレームごと。
        let first = layout.firstFrame + page * UInt64(ETSFZPageDecode.pageFrames)
        let status = ETVorbisStream_Read(stream, first, UInt32(frames), out)
        // 失敗した標本は手放す（作り直せば同じ要求をもう一度試せる）。
        guard status == Int32(ET_VORBIS_OK) else {
            if let broken = cache.remove(key) { ETVorbisStream_Close(broken) }
            throw status == Int32(ET_VORBIS_ERR_ARGUMENT) ? ETSFZPageError.range : ETSFZPageError.format
        }
        cache.update(key, cost: ETVorbisStream_Bytes(stream))
        for evicted in cache.trim(keeping: key) { ETVorbisStream_Close(evicted) }
        releaseOldDecoders()
        return (frames, 1)
    }

    private func open(_ key: Key, source: ETSFZSampleSource, layout: ETSFZVorbisLayout) throws -> OpaquePointer {
        if let stream = cache.use(key) { return stream }
        let data = try files.readAll(url: source.url, offset: key.offset, length: layout.dataBytes, limit: ETSFZVorbisLayout.maxBytes)
        var error: Int32 = 0
        let opened: OpaquePointer? = data.withUnsafeBytes { raw in
            ETVorbisStream_Open(raw.bindMemory(to: UInt8.self).baseAddress, raw.count, UInt32(clamping: source.sampleRate),
                                layout.sourceFrames, &error)
        }
        // 開けない（枠・CRC・モノでない・レート違い・上限）。ファイルが差し替わった形でもあるので format にする。
        guard let stream = opened else { throw ETSFZPageError.format }
        if let old = cache.insert(key, stream, cost: ETVorbisStream_Bytes(stream)) { ETVorbisStream_Close(old) }
        return stream
    }

    /// 直近に使った decoderLimit 本より前の標本の復号器を閉じる（復号済みの PCM は残す）。
    private func releaseOldDecoders() {
        let order = cache.order
        guard order.count > decoderLimit else { return }
        for key in order.prefix(order.count - decoderLimit) {
            if let stream = cache.peek(key), ETVorbisStream_HasDecoder(stream) != 0 {
                ETVorbisStream_ReleaseDecoder(stream)
                cache.update(key, cost: ETVorbisStream_Bytes(stream))
            }
        }
    }
}
#endif
