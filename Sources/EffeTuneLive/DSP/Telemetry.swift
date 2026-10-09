//  Telemetry.swift
//  エフェクトが描画用に吐く値を受け取る。
//
//  可視化の計算は EffeTune の DSP が済ませている。Level Meter も Spectrum Analyzer も
//  Compressor のゲインリダクションも、カーネルが writeTelemetry で枠に書いて出す。
//  こちら側の仕事は、それを読んで描くことだけ。自前で解析はしない。
//
//  枠の形（dsp/core/telemetry.cpp と js/audio/telemetry-hub.js と同じ）:
//      0  u16 frameType
//      2  u16 formatVersion
//      4  u32 tapId          どのエフェクトが出したか
//      8  u32 sequence
//     12  u16 payloadBytes
//     14  u16 flags          bit0 = 取りこぼしあり
//     16  payload
//  1 枠の長さは (16 + payloadBytes) を 4 の倍数に切り上げたもの。

import Foundation
import os

@MainActor
final class Telemetry: ObservableObject {

    static let shared = Telemetry()

    private let log = Logger(subsystem: "ai.nemut.effetune", category: "telemetry")

    /// tap ごと・種類ごとの最新の枠。描く側はここを見る。
    @Published private(set) var latest: [UInt64: ETFrame] = [:]
    @Published private(set) var droppedFrames: UInt32 = 0
    /// PC の測定値を映している tap（RemoteMirror.refreshMirrored が決める）。
    /// ここに入った tap は手元の枠を捨て、inject で来る PC の枠だけを latest へ入れる。
    /// 変わるのは入切と鎖の組み直しのときだけなので、図はこれを見て履歴を捨てられる。
    @Published private(set) var mirrored: Set<UInt32> = []

    /// 取り込み用。毎回確保しないよう持っておく。
    ///
    /// **輪と同じ大きさにする。** 64KB だと 1 回の poll で汲み切れず、
    /// 残りは次の poll まで輪に積まれたままになる。スペアナの枠は 1 本で
    /// 16KB あり（FFT 4096 → bin 2049 → `12 + 2049*8`）、新しい解析ができるたびに
    /// 出る（FFT 4096 なら 2048 サンプルごと、kernel.cpp:359-368）。
    /// 図を持つ段と PEQ の探り（段 1 つに 2 台）が並ぶと 1 回ぶんで 64KB を越えるので、
    /// 汲み残しが次の枠に上書きされて `droppedFrames` が増える。
    private var buffer = [UInt8](repeating: 0, count: Int(EffeTuneDSP.telemetryRingBytes))

    private init() {}

    private var pending: [(time: TimeInterval, frames: [UInt64: ETFrame], queued: [ETFrame])] = []

    /// 畳まずに届いた順に全部取っておく枠（Rhythm Analyzer と Note Spectrogram）。
    ///
    /// Rhythm Analyzer: 枠 1 つは、前の枠からの onset（最大 16 個）と取りこぼした数を運ぶ
    /// （rhythm_analyzer/kernel.cpp の kMaxEvents と droppedEvents）。1 回の poll に 2 枠以上
    /// 入ると、最新だけ残す `latest` では前の枠の onset が消える。
    /// Note Spectrogram: カーネルは 20 ms ごと（50 fps）に枠を出し、こちらの poll は 30Hz なので、
    /// 最新だけだと 4 割が落ちる。2・4・8 枠前の確からしさの直しは枠の番号で当て先を探すので、
    /// 落ちた枠の列へは直しが届かない（2.13.0）。
    /// 上流のハブは枠ごとに購読者へ配るので落とさない。tap と種類ごとに持ち、描く側が drainFrames で取り出す。
    private var frameQueue: [UInt64: [ETFrame]] = [:]
    /// 溜める種類。Note Spectrogram（24）は ETFrameType に無いので数で持つ。
    static let queuedTypes: Set<UInt16> = [ETFrameType.noteSpectrogram.rawValue,
                                           ETFrameType.rhythmAnalyzer.rawValue]
    /// tap と種類ごとの上限。30Hz なら 8 秒ぶん（Note Spectrogram は 50 fps なので 5 秒）。
    /// 描く側が止まっていた間に溜め続けない。
    static let queueLimit = 256
    private var synchronized = false

    static func key(tap: UInt32, type: ETFrameType) -> UInt64 {
        UInt64(tap) << 16 | UInt64(type.rawValue)
    }

    func frame(tap: UInt32, type: ETFrameType) -> ETFrame? {
        latest[Self.key(tap: tap, type: type)]
    }

    /// 溜まっている枠を、届いた順に全部渡して空にする。
    func drainFrames(tap: UInt32, type: UInt16) -> [ETFrame] {
        frameQueue.removeValue(forKey: UInt64(tap) << 16 | UInt64(type)) ?? []
    }

    func drainRhythmFrames(tap: UInt32) -> [ETFrame] {
        drainFrames(tap: tap, type: ETFrameType.rhythmAnalyzer.rawValue)
    }

    /// clear した回数。エンジンを作り直すと枠の番号も世代も数え直しになる（Rhythm Analyzer は
    /// 世代で古い枠を見分けるので、出どころが替わったことをこの数で知る）。
    private(set) var clearCount = 0

    func clear() {
        clearCount &+= 1
        frameQueue.removeAll()
        latest.removeAll()
        droppedFrames = 0
        pending.removeAll()
    }

    /// PC の測定値を映す tap を入れ替える。
    ///
    /// **増えた tap も減った tap も、溜めてある枠を捨てる。**始めた直後に手元の古い枠が、
    /// やめた直後に PC の古い枠が図に残らないように。pending（Sync visuals の遅れ待ち）からも捨てる。
    func setMirrored(_ taps: Set<UInt32>) {
        guard taps != mirrored else { return }
        let changed = taps.symmetricDifference(mirrored)
        let stale = latest.keys.filter { changed.contains(UInt32(truncatingIfNeeded: $0 >> 16)) }
        if !stale.isEmpty {
            var next = latest
            for key in stale { next.removeValue(forKey: key) }
            latest = next
        }
        for i in pending.indices {
            pending[i].frames = pending[i].frames.filter {
                !changed.contains(UInt32(truncatingIfNeeded: $0.key >> 16))
            }
        }
        mirrored = taps
    }

    /// PC から来た枠を入れる。tapId は手元の段の値に付け替え済み（ETRemoteTelemetry.frame）。
    ///
    /// **pending と displayDelay を通さない。**PC は自分の出力の遅れ（visual-sync）を済ませてから
    /// 送ってくる（telemetry-hub.js の _dispatch の後で拾っている）。手元の出力の遅れは PC の音に関係ない。
    /// 書き換えは 1 回にまとめる（latest を観測している図が 1 回だけ描き直す）。
    func inject(_ frames: [ETFrame]) {
        var found: [UInt64: ETFrame] = [:]
        for frame in frames where mirrored.contains(frame.tapId) {
            found[UInt64(frame.tapId) << 16 | UInt64(frame.type)] = frame
            // Rhythm Analyzer は 1 枚ごとに次の枠を読む前提の持ち越しがあり、Note Spectrogram は
            // 枠の番号で前の枠の列を直すので、どちらも溜めて渡す。
            if Self.queuedTypes.contains(frame.type) { enqueue(frame) }
        }
        guard !found.isEmpty else { return }
        latest.merge(found) { _, new in new }
    }

    /// 溜まっているぶんを読み出して、種類ごとに最新だけ残す。
    func poll(engine: UInt32, displayDelay: TimeInterval = 0) {
        guard engine != 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let delay = displayDelay.isFinite ? min(5, max(0, displayDelay)) : 0
        if synchronized != (delay > 0) {
            pending.removeAll()
            synchronized = delay > 0
        }

        var dropped: UInt32 = 0
        let read = buffer.withUnsafeMutableBufferPointer { buf -> UInt32 in
            et_telemetry_read(engine, buf.baseAddress, UInt32(buf.count), &dropped)
        }
        if dropped > 0 { droppedFrames &+= dropped }

        var offset = 0
        let bytes = Int(read)
        var found: [UInt64: ETFrame] = [:]
        var queued: [ETFrame] = []

        while offset + 16 <= bytes {
            let type    = load16(offset)
            let version = load16(offset + 2)
            let tap     = load32(offset + 4)
            let seq     = load32(offset + 8)
            let payloadBytes = Int(load16(offset + 12))
            let flags   = load16(offset + 14)

            let frameBytes = (16 + payloadBytes + 3) & ~3
            guard frameBytes >= 16, offset + frameBytes <= bytes else { break }

            // PC の測定値を映している段の枠は捨てる（写しも作らない）。読み進めるのは止めない。
            if !mirrored.contains(tap) {
                let start = offset + 16
                let payload = Array(buffer[start..<(start + payloadBytes)])
                let frame = ETFrame(type: type, version: version, tapId: tap, sequence: seq,
                                    dropped: flags & 1 != 0, payload: payload)
                found[UInt64(tap) << 16 | UInt64(type)] = frame
                if Self.queuedTypes.contains(type) { queued.append(frame) }
            }

            offset += frameBytes
        }

        if !found.isEmpty { pending.append((now + delay, found, queued)) }
        var ready: [UInt64: ETFrame] = [:]
        while let first = pending.first, first.time <= now {
            ready.merge(first.frames) { _, new in new }
            for frame in first.queued { enqueue(frame) }
            pending.removeFirst()
        }
        // Bound memory even if the output route changes to an unusually long delay.
        if pending.count > 180 { pending.removeFirst(pending.count - 180) }
        if !ready.isEmpty { latest.merge(ready) { _, new in new } }
    }

    private func enqueue(_ frame: ETFrame) {
        let key = UInt64(frame.tapId) << 16 | UInt64(frame.type)
        var queue = frameQueue[key] ?? []
        queue.append(frame)
        if queue.count > Self.queueLimit {
            queue.removeFirst(queue.count - Self.queueLimit)
        }
        frameQueue[key] = queue
    }

    private func load16(_ o: Int) -> UInt16 {
        UInt16(buffer[o]) | UInt16(buffer[o + 1]) << 8
    }

    private func load32(_ o: Int) -> UInt32 {
        UInt32(buffer[o]) | UInt32(buffer[o + 1]) << 8
            | UInt32(buffer[o + 2]) << 16 | UInt32(buffer[o + 3]) << 24
    }
}
