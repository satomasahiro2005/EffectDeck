//  SamplePlayerPreparation.swift
//  SFZ Note Player / SoundFont Player の footprint（begin に渡す確保の見積り）を、エンジンに聞いて出す。
//
//  abi.h の et_sample_player_preparation_bytes は CONTROL 専用で、PCM を読まない。
//  必要な footprint は「payload のバイト数 + 返した追加分」だけ（コンパイラ内部の基底や sizeof の足し算は要らない）。
//  幾何（レート・処理チャンネル・maxFrames・bpm・player kind）は **begin と同じ値**を渡す。
//  上流の Android ホスト（native_engine.cpp:376-395）と同じ形: bpm 0・実際のレート・processingChannels・maxFrames。
//  純粋な部分（制御の長さ・幾何の検査・足し算と上限）は SFZPreparationRules.swift（Linux で試験）。
//
//  **音のスレッドからは呼ばない。**UI か utility のスレッドで。

import Foundation

enum ETSamplePlayerPreparation {

    /// 追加分（payload の外にカーネルが確保するバイト数）。
    static func additionalBytes(payload: [UInt8], geometry: ETSFZPreparationRules.Geometry,
                                formatTag: UInt32 = 1) throws -> UInt64 {
        let controlBytes = try ETSFZPreparationRules.controlBytes(of: payload)
        var additional: UInt64 = 0
        let status = payload.withUnsafeBufferPointer { buffer -> et_status in
            et_sample_player_preparation_bytes(
                buffer.baseAddress, UInt32(controlBytes), UInt32(payload.count), formatTag,
                Float(geometry.sampleRate), UInt32(geometry.processingChannels), UInt32(geometry.maxFrames),
                geometry.minimumPhysicalBpm, &additional, geometry.playerKind.rawValue)
        }
        guard Int(status) == ET_OK else { throw ETSFZError.prepare(ETSFZPreparationRules.effectsMessage) }
        return additional
    }

    /// begin の footprintBytes。maxBytes を超えるとき・UInt32 に入らないときは上流の too-large の文で止める。
    static func footprint(payload: [UInt8], geometry: ETSFZPreparationRules.Geometry,
                          maxBytes: Int, formatTag: UInt32 = 1) throws -> UInt32 {
        let additional = try additionalBytes(payload: payload, geometry: geometry, formatTag: formatTag)
        return try ETSFZPreparationRules.footprint(payloadBytes: payload.count, additionalBytes: additional,
                                                   maxBytes: maxBytes)
    }
}
