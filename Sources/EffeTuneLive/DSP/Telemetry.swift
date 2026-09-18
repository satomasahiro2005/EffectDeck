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

/// EffeTune の TelemetryFrameType と同じ番号。
enum ETFrameType: UInt16 {
    case level              = 1
    case gainReduction      = 2
    case scopeSnapshot      = 3
    case spectrum           = 4
    case spectrogramColumn  = 5
    case stereoField        = 6
    case loudnessLevels     = 7
    case transientGain      = 8
    case channelCount       = 9
    case multiChannelLevels = 10
    case dsd64IMD           = 11
    case powerAmpSag        = 12
    case multibandDynamics  = 13
    case fiveBandDynamicEQ  = 14
    case vinylSimulator     = 15
    case fmRadioSimulator   = 16
    case amRadioSimulator   = 17
    case swRadioSimulator   = 18
    case tubeSimulator      = 19
    case phaseSelectMap     = 20
    case pitchMeter         = 26
}

struct ETFrame {
    let type: UInt16
    let version: UInt16
    let tapId: UInt32
    let sequence: UInt32
    let dropped: Bool
    let payload: [UInt8]

    /// ペイロードを Float の並びとして読む。
    var floats: [Float] {
        let n = payload.count / 4
        guard n > 0 else { return [] }
        return payload.withUnsafeBytes { raw in
            (0..<n).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
        }
    }

    func u32(at offset: Int) -> UInt32 {
        guard offset + 4 <= payload.count else { return 0 }
        return payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }
}

@MainActor
final class Telemetry: ObservableObject {

    static let shared = Telemetry()

    private let log = Logger(subsystem: "ai.nemut.effetune", category: "telemetry")

    /// tap ごと・種類ごとの最新の枠。描く側はここを見る。
    @Published private(set) var latest: [UInt64: ETFrame] = [:]
    @Published private(set) var droppedFrames: UInt32 = 0

    /// 取り込み用。毎回確保しないよう持っておく。
    ///
    /// **輪と同じ大きさにする。** 64KB だと 1 回の poll で汲み切れず、
    /// 残りは次の poll まで輪に積まれたままになる。スペアナの枠は 1 本で
    /// 16KB あり（FFT 4096 → bin 2049 → `12 + 2049*8`）、それが 60Hz で出る。
    /// 図を持つ段が数枚並ぶと 1 回ぶんで 64KB を越えるので、汲み残しが
    /// 次の枠に上書きされて `droppedFrames` が増える。
    private var buffer = [UInt8](repeating: 0, count: Int(EffeTuneDSP.telemetryRingBytes))

    private init() {}

    private var pending: [(time: TimeInterval, frames: [UInt64: ETFrame])] = []
    private var synchronized = false

    static func key(tap: UInt32, type: ETFrameType) -> UInt64 {
        UInt64(tap) << 16 | UInt64(type.rawValue)
    }

    func frame(tap: UInt32, type: ETFrameType) -> ETFrame? {
        latest[Self.key(tap: tap, type: type)]
    }

    func clear() {
        latest.removeAll()
        droppedFrames = 0
        pending.removeAll()
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

        while offset + 16 <= bytes {
            let type    = load16(offset)
            let version = load16(offset + 2)
            let tap     = load32(offset + 4)
            let seq     = load32(offset + 8)
            let payloadBytes = Int(load16(offset + 12))
            let flags   = load16(offset + 14)

            let frameBytes = (16 + payloadBytes + 3) & ~3
            guard frameBytes >= 16, offset + frameBytes <= bytes else { break }

            let start = offset + 16
            let payload = Array(buffer[start..<(start + payloadBytes)])

            let frame = ETFrame(type: type, version: version, tapId: tap, sequence: seq,
                                dropped: flags & 1 != 0, payload: payload)
            found[UInt64(tap) << 16 | UInt64(type)] = frame

            offset += frameBytes
        }

        if !found.isEmpty { pending.append((now + delay, found)) }
        var ready: [UInt64: ETFrame] = [:]
        while let first = pending.first, first.time <= now {
            ready.merge(first.frames) { _, new in new }
            pending.removeFirst()
        }
        // Bound memory even if the output route changes to an unusually long delay.
        if pending.count > 180 { pending.removeFirst(pending.count - 180) }
        if !ready.isEmpty { latest.merge(ready) { _, new in new } }
    }

    private func load16(_ o: Int) -> UInt16 {
        UInt16(buffer[o]) | UInt16(buffer[o + 1]) << 8
    }

    private func load32(_ o: Int) -> UInt32 {
        UInt32(buffer[o]) | UInt32(buffer[o + 1]) << 8
            | UInt32(buffer[o + 2]) << 16 | UInt32(buffer[o + 3]) << 24
    }
}
