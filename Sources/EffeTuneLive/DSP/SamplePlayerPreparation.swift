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

    /// 制御の部分だけから出す版（本体は staging へ直に書くので payload の配列が無い。SFZLoader）。
    /// control は payload の頭から数えた制御の部分（流し込みの入れ物は payload 全体）、payloadBytes は payload 全体の長さ。
    static func additionalBytes(control: [UInt8], payloadBytes: Int, geometry: ETSFZPreparationRules.Geometry,
                                formatTag: UInt32 = 1) throws -> UInt64 {
        let controlBytes = try ETSFZPreparationRules.controlBytes(of: control, payloadBytes: payloadBytes)
        var additional: UInt64 = 0
        let status = control.withUnsafeBufferPointer { buffer -> et_status in
            et_sample_player_preparation_bytes(
                buffer.baseAddress, UInt32(controlBytes), UInt32(payloadBytes), formatTag,
                Float(geometry.sampleRate), UInt32(geometry.processingChannels), UInt32(geometry.maxFrames),
                geometry.minimumPhysicalBpm, &additional, geometry.playerKind.rawValue)
        }
        guard Int(status) == ET_OK else { throw ETSFZError.prepare(ETSFZPreparationRules.effectsMessage) }
        return additional
    }

    /// 制御の部分だけから出す footprint（begin に渡す値）。**send のたびに引き直す**（幾何が変わるため）。
    static func footprint(control: [UInt8], payloadBytes: Int, geometry: ETSFZPreparationRules.Geometry,
                          maxBytes: Int, formatTag: UInt32 = 1) throws -> UInt32 {
        let additional = try additionalBytes(control: control, payloadBytes: payloadBytes, geometry: geometry,
                                             formatTag: formatTag)
        return try ETSFZPreparationRules.footprint(payloadBytes: payloadBytes, additionalBytes: additional,
                                                   maxBytes: maxBytes)
    }

    /// 上流の estimateEffectBytes の口（JS から呼ばれる。ETSFZScriptService の estimate）。**追加分だけ**を返す
    /// （足し算と上限は JS の materializeSfzAsset がやる）。
    static func scriptEstimate(control: Data, payloadBytes: Int, geometry: ETSFZGeometry, formatTag: Int) throws -> Int {
        let native = try ETSFZPreparationRules.geometry(geometry)
        let added = try additionalBytes(control: [UInt8](control), payloadBytes: payloadBytes, geometry: native,
                                        formatTag: UInt32(clamping: formatTag))
        guard added <= UInt64(Int.max) else { throw ETSFZError.tooLarge(ETSFZPreparationRules.tooLargeMessage) }
        return Int(added)
    }

    /// begin の footprintBytes。maxBytes を超えるとき・UInt32 に入らないときは上流の too-large の文で止める。
    static func footprint(payload: [UInt8], geometry: ETSFZPreparationRules.Geometry,
                          maxBytes: Int, formatTag: UInt32 = 1) throws -> UInt32 {
        let additional = try additionalBytes(payload: payload, geometry: geometry, formatTag: formatTag)
        return try ETSFZPreparationRules.footprint(payloadBytes: payload.count, additionalBytes: additional,
                                                   maxBytes: maxBytes)
    }
}
