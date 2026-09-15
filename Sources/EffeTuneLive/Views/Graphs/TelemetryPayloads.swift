//  TelemetryPayloads.swift
//  テレメトリのペイロードを読むための道具。汎用の読み出しだけ置く。
//  どのエフェクトがどの並びで書いているかは、ここでは決めない。
//
//  枠の形は Telemetry.swift（と dsp/core/telemetry.cpp）が扱う。
//  こちらは payload の中だけを見る。
//
//  並びは全部リトルエンディアン。DSP は dsp/core/binary_io.h の writeU16 / writeU32 /
//  writeF32 で書いており（例: dsp/plugins/analyzer/level_meter/kernel.cpp:167-172）、
//  arm64 も同じ並びなので、そのまま読める。
//
//  読めなかったら nil を返す。ここで 0 を返して図を描くと、
//  「値が無い」と「値が 0」の区別がつかなくなる。
//
//  使う側:
//      guard let frame = Telemetry.shared.frame(tap: node.tapId, type: .level) else { return nil }
//      var r = frame.reader()
//      guard let channels = r.u32(), let values = r.floats(Int(channels) * 2) else { return nil }

import Foundation

// MARK: - ペイロード

struct ETPayload {

    let bytes: [UInt8]

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    init(_ frame: ETFrame) {
        self.bytes = frame.payload
    }

    var count: Int { bytes.count }
    var isEmpty: Bool { bytes.isEmpty }

    /// offset から size バイトが payload に収まっているか。
    func fits(_ offset: Int, _ size: Int) -> Bool {
        offset >= 0 && size >= 0 && offset <= bytes.count - size && size <= bytes.count
    }

    // MARK: 1 個ずつ

    func u8(at offset: Int) -> UInt8? {
        fits(offset, 1) ? bytes[offset] : nil
    }

    func u16(at offset: Int) -> UInt16? {
        guard fits(offset, 2) else { return nil }
        return bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }
    }

    func u32(at offset: Int) -> UInt32? {
        guard fits(offset, 4) else { return nil }
        return bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }

    func i32(at offset: Int) -> Int32? {
        guard fits(offset, 4) else { return nil }
        return bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Int32.self) }
    }

    func f32(at offset: Int) -> Float? {
        guard fits(offset, 4) else { return nil }
        return bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Float.self) }
    }

    func f64(at offset: Int) -> Double? {
        guard fits(offset, 8) else { return nil }
        return bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Double.self) }
    }

    // MARK: 並び

    /// offset から Float を count 個。1 個でも足りなければ nil。
    func floats(at offset: Int, count n: Int) -> [Float]? {
        guard n >= 0, fits(offset, n * 4) else { return nil }
        guard n > 0 else { return [] }
        return bytes.withUnsafeBytes { raw in
            (0..<n).map { raw.loadUnaligned(fromByteOffset: offset + $0 * 4, as: Float.self) }
        }
    }

    /// offset から最後まで、Float として読めるだけ。
    func floats(from offset: Int = 0) -> [Float] {
        let n = max(0, (bytes.count - max(offset, 0)) / 4)
        return floats(at: max(offset, 0), count: n) ?? []
    }

    /// offset から Int32 を count 個。
    func int32s(at offset: Int, count n: Int) -> [Int32]? {
        guard n >= 0, fits(offset, n * 4) else { return nil }
        guard n > 0 else { return [] }
        return bytes.withUnsafeBytes { raw in
            (0..<n).map { raw.loadUnaligned(fromByteOffset: offset + $0 * 4, as: Int32.self) }
        }
    }

    /// offset から UInt32 を count 個。
    func uint32s(at offset: Int, count n: Int) -> [UInt32]? {
        guard n >= 0, fits(offset, n * 4) else { return nil }
        guard n > 0 else { return [] }
        return bytes.withUnsafeBytes { raw in
            (0..<n).map { raw.loadUnaligned(fromByteOffset: offset + $0 * 4, as: UInt32.self) }
        }
    }

    /// 飛び飛びに読む。{peak, rms} が交互に並ぶような並びから片方だけ取るとき。
    /// stride と lane はバイトでなく Float の個数で数える。
    func floats(at offset: Int, count n: Int, stride: Int, lane: Int = 0) -> [Float]? {
        guard offset >= 0, n >= 0, stride > 0, lane >= 0, lane < stride else { return nil }
        guard n > 0 else { return [] }
        let last = offset + ((n - 1) * stride + lane) * 4
        guard fits(last, 4) else { return nil }
        return bytes.withUnsafeBytes { raw in
            (0..<n).map {
                raw.loadUnaligned(fromByteOffset: offset + ($0 * stride + lane) * 4, as: Float.self)
            }
        }
    }

    func reader(at offset: Int = 0) -> ETPayloadReader {
        ETPayloadReader(self, at: offset)
    }

    // MARK: 並べ替え

    /// 交互に並んだ値を lane ごとに分ける。[L0,R0,L1,R1,...] → [[L...],[R...]]
    static func deinterleave(_ values: [Float], lanes: Int) -> [[Float]] {
        guard lanes > 0 else { return [] }
        let n = values.count / lanes
        return (0..<lanes).map { lane in
            (0..<n).map { values[$0 * lanes + lane] }
        }
    }
}

// MARK: - 頭から順に読む

/// 位置を数えながら読む。読めた分だけ進む。読めなければ nil を返して位置は動かない。
struct ETPayloadReader {

    let payload: ETPayload
    private(set) var offset: Int

    init(_ payload: ETPayload, at offset: Int = 0) {
        self.payload = payload
        self.offset = max(0, offset)
    }

    var remaining: Int { max(0, payload.count - offset) }
    var isAtEnd: Bool { remaining == 0 }

    mutating func skip(_ bytes: Int) -> Bool {
        guard bytes >= 0, remaining >= bytes else { return false }
        offset += bytes
        return true
    }

    mutating func u8() -> UInt8? {
        guard let v = payload.u8(at: offset) else { return nil }
        offset += 1
        return v
    }

    mutating func u16() -> UInt16? {
        guard let v = payload.u16(at: offset) else { return nil }
        offset += 2
        return v
    }

    mutating func u32() -> UInt32? {
        guard let v = payload.u32(at: offset) else { return nil }
        offset += 4
        return v
    }

    mutating func i32() -> Int32? {
        guard let v = payload.i32(at: offset) else { return nil }
        offset += 4
        return v
    }

    mutating func f32() -> Float? {
        guard let v = payload.f32(at: offset) else { return nil }
        offset += 4
        return v
    }

    mutating func f64() -> Double? {
        guard let v = payload.f64(at: offset) else { return nil }
        offset += 8
        return v
    }

    mutating func floats(_ n: Int) -> [Float]? {
        guard let v = payload.floats(at: offset, count: n) else { return nil }
        offset += n * 4
        return v
    }

    mutating func uint32s(_ n: Int) -> [UInt32]? {
        guard let v = payload.uint32s(at: offset, count: n) else { return nil }
        offset += n * 4
        return v
    }

    /// 残り全部を Float として。端数のバイトは捨てる。
    mutating func rest() -> [Float] {
        let v = payload.floats(from: offset)
        offset = payload.count
        return v
    }
}

// MARK: - 枠から

extension ETFrame {

    var payloadView: ETPayload { ETPayload(self) }

    func reader(at offset: Int = 0) -> ETPayloadReader {
        ETPayloadReader(ETPayload(self), at: offset)
    }

    /// 期待している長さかどうか。C++ 側が書いている大きさと突き合わせてから読む。
    func hasPayload(bytes: Int) -> Bool { payload.count == bytes }

    func hasPayload(atLeast bytes: Int) -> Bool { payload.count >= bytes }

    /// 版が合わないものは読まない。形が変わっている見込みなので、図は出さない方がよい。
    func matches(version: UInt16) -> Bool { self.version == version }
}
