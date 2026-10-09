//  TelemetryFrame.swift
//  エフェクトが描画用に吐く枠1つぶんと、その種類の番号。
//
//  Telemetry.swiftから分けてあるのは、Foundationだけで試験のバンドルに入れるため。
//  Telemetryはosとet_telemetry_readに触る。枠の並び（ヘッダの16バイト）はTelemetry.swiftの頭を読むこと。

import Foundation

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
    case noteSpectrogram    = 24
    case pitchMeter         = 26
    case analogMeter        = 27
    case rhythmAnalyzer     = 28
    case tonalBalance       = 29
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
