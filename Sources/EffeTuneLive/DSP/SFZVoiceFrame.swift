//  SFZVoiceFrame.swift
//  SFZ Note Player の声の枠（2.14.0、型 30・版 1）。**Foundation だけ。**
//
//  kernel.cpp の writeTelemetry が書き、sfz_note_player.js の handleTelemetry が読む:
//      0   u16 鳴っている声の数（total）
//      2   u16 声の上限（Max Voices）
//      4 + 鍵 × 8   u16 その鍵で鳴っている声の数 / 2 バイト空き / f32 強さ（0〜1、1 秒で 1/e に落ちる）
//  長さは 4 + 128 × 8 = 1028 ちょうど。読めない枠は捨てる（上流と同じ検め方）。

import Foundation

struct ETSFZVoiceFrame: Equatable {
    var total: Int
    var limit: Int
    var counts: [Int]
    var velocities: [Float]

    static let byteCount = 4 + 128 * 8

    static func parse(type: UInt16, version: UInt16, payload: [UInt8]) -> ETSFZVoiceFrame? {
        guard type == 30, version == 1, payload.count == byteCount else { return nil }
        func u16(_ o: Int) -> Int { Int(payload[o]) | Int(payload[o + 1]) << 8 }
        func f32(_ o: Int) -> Float {
            Float(bitPattern: UInt32(payload[o]) | UInt32(payload[o + 1]) << 8
                  | UInt32(payload[o + 2]) << 16 | UInt32(payload[o + 3]) << 24)
        }
        let total = u16(0), limit = u16(2)
        guard limit >= 1, limit <= 128, total <= limit else { return nil }
        var counts = [Int](repeating: 0, count: 128)
        var velocities = [Float](repeating: 0, count: 128)
        var counted = 0
        for midi in 0..<128 {
            let count = u16(4 + midi * 8)
            let velocity = f32(8 + midi * 8)
            guard count <= total, velocity.isFinite, velocity >= 0, velocity <= 1,
                  count > 0 || velocity == 0 else { return nil }
            counts[midi] = count
            velocities[midi] = velocity
            counted += count
        }
        guard counted == total else { return nil }
        return ETSFZVoiceFrame(total: total, limit: limit, counts: counts, velocities: velocities)
    }
}

/// 図に出す声。枠が来たら鳴っている鍵は枠の強さに、鳴っていない鍵は前の値を経った秒数ぶん落とす。
/// 描くときも前の枠からの秒数で落とす（e^-t）。上流の _velocities と drawGraph の decay。
struct ETSFZVoiceDisplay {
    private(set) var counts = [Int](repeating: 0, count: 128)
    private(set) var velocities = [Float](repeating: 0, count: 128)
    private(set) var active = 0
    private(set) var frameTime: Double?

    mutating func accept(_ frame: ETSFZVoiceFrame, now: Double) {
        let decay = Float(exp(-(frameTime.map { max(0, now - $0) } ?? 0)))
        for midi in 0..<128 {
            counts[midi] = frame.counts[midi]
            velocities[midi] = frame.counts[midi] > 0 ? frame.velocities[midi] : velocities[midi] * decay
        }
        active = frame.total
        frameTime = now
    }

    mutating func clear() { self = ETSFZVoiceDisplay() }

    /// いま描く強さ（前の枠から経ったぶん落としたもの）。
    func velocity(_ midi: Int, now: Double) -> Float {
        let elapsed = frameTime.map { max(0, now - $0) } ?? 0
        return velocities[midi] * Float(exp(-elapsed))
    }

    /// まだ見える棒があるか。無ければ時計を止めてよい。
    func isAnimating(now: Double) -> Bool {
        let elapsed = frameTime.map { max(0, now - $0) } ?? 0
        let scale = Float(exp(-elapsed))
        return velocities.contains { $0 * scale > 0.002 }
    }
}

/// 鍵の並び（frequency-axis.js の noteAxisKeys）。`length` は図の横幅。白鍵は 1 オクターブを 7 等分した位置。
struct ETNoteAxisKey {
    var midi: Int
    var black: Bool
    var start: Double
    var end: Double
    var whiteStart: Double
    var whiteEnd: Double

    static func keys(lowest mn: Int, highest mx: Int, length: Double) -> [ETNoteAxisKey] {
        let rowHeight = length / Double(mx - mn + 1)
        let whiteClasses = [0, 2, 4, 5, 7, 9, 11]
        func clamp(_ v: Double) -> Double { min(max(v, 0), length) }
        var out: [ETNoteAxisKey] = []
        let first = Int((Double(mn) / 12).rounded(.down)) * 12
        let last = Int((Double(mx + 1) / 12).rounded(.up)) * 12
        for midi in first...last {
            let pitchClass = ((midi % 12) + 12) % 12
            let whiteIndex = whiteClasses.firstIndex(of: pitchClass)
            let black = whiteIndex == nil
            if black && (midi < mn || midi > mx) { continue }
            let start = clamp(Double(midi - mn) * rowHeight)
            let end = clamp(Double(midi - mn + 1) * rowHeight)
            let base = Double(midi - pitchClass - mn) * rowHeight
            let index = Double(whiteIndex ?? -1)
            let whiteStart = clamp(base + index * 12 * rowHeight / 7)
            let whiteEnd = clamp(base + (index + 1) * 12 * rowHeight / 7)
            if !black && whiteEnd <= whiteStart { continue }
            out.append(ETNoteAxisKey(midi: midi, black: black, start: start, end: end,
                                     whiteStart: whiteStart, whiteEnd: whiteEnd))
        }
        return out
    }

    /// 触った鍵（hitKey）。`across` は鍵盤の手前からの深さ。黒鍵の深さまでは黒鍵を先に見る。
    static func hit(_ keys: [ETNoteAxisKey], along: Double, across: Double,
                    gutter: Double, blackDepth: Double) -> ETNoteAxisKey? {
        guard across >= 0, across <= gutter else { return nil }
        if across <= blackDepth, let black = keys.first(where: { $0.black && along >= $0.start && along <= $0.end }) {
            return black
        }
        return keys.first { !$0.black && along >= $0.whiteStart && along <= $0.whiteEnd }
    }
}
