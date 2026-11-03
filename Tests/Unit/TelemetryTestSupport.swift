//  TelemetryTestSupport.swift
//  テレメトリの枠を、テストで作る道具。DSP が書く並び（リトルエンディアン）をそのまま作る。

import Foundation

enum TelemetryBytes {
    static func u8(_ v: UInt8) -> [UInt8] { [v] }

    static func u16(_ v: UInt16) -> [UInt8] {
        [UInt8(v & 0xff), UInt8(v >> 8)]
    }

    static func u32(_ v: UInt32) -> [UInt8] {
        (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xff) }
    }

    static func i32(_ v: Int32) -> [UInt8] { u32(UInt32(bitPattern: v)) }

    static func f32(_ v: Float) -> [UInt8] { u32(v.bitPattern) }

    /// 先頭 offset に bytes を書き込む（足りなければ 0 で伸ばす）。
    static func put(_ bytes: [UInt8], at offset: Int, into payload: inout [UInt8]) {
        if payload.count < offset + bytes.count {
            payload += [UInt8](repeating: 0, count: offset + bytes.count - payload.count)
        }
        for (i, b) in bytes.enumerated() { payload[offset + i] = b }
    }

    static func frame(_ type: ETFrameType, version: UInt16 = 1, tap: UInt32 = 7,
                      sequence: UInt32 = 1, payload: [UInt8]) -> ETFrame {
        ETFrame(type: type.rawValue, version: version, tapId: tap, sequence: sequence,
                dropped: false, payload: payload)
    }
}
