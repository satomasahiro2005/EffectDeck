//  SFZPreparationRules.swift
//  SFZ Note Player / SoundFont Player の「確保の見積り」のうち、エンジンを呼ばない部分。
//  **Foundation だけ。**Linux でも走る（SFZPoolFillTests）。エンジンを呼ぶ側は SamplePlayerPreparation.swift。
//
//  上流の写し元:
//    js/sfz/effect-cost.js        samplePlayerPreparationData（payload の頭から「制御の部分」を切る）
//    js/sfz/preparation-context.js sfzPreparationContext（幾何の検査）・materializeSfzAsset（足し算と上限）
//  abi.h の et_sample_player_preparation_bytes は「payload + 返した追加分」だけが正しい footprint と言う。
//  制御の部分 = 外側の 32 バイト + u32@48 × 4（コンパイル済みの表が PCM の手前で終わるところ）。
//  ストリーミングの入れ物は表だけなので、制御の部分が payload の全部になる。

import Foundation

enum ETSFZPreparationRules {

    /// 上流 preparation-context.js:52-54 の文。
    static let tooLargeMessage = "The instrument needs more memory for these audio settings. Increase the SoundFont size limit or choose another instrument."
    static let invalidDataMessage = "The instrument preparation data is invalid."
    static let audioConfigMessage = "The instrument audio configuration is unavailable. Try again after changing audio settings."
    static let tempoMessage = "The instrument tempo configuration could not be prepared."
    /// 上流 effect-cost.js の、見積りの呼びが失敗したときの文。
    static let effectsMessage = "The instrument effects could not be prepared for these audio settings."

    static let magic: UInt32 = 0x31415445
    /// 1 つの instance が受ける処理チャンネルの上限（上流の検査と同じ）。
    static let maxProcessingChannels = 16

    /// et_sample_player_preparation_bytes の player_kind。
    enum PlayerKind: UInt32 {
        case note = 0   // SFZNotePlayerPlugin（128 声）
        case main = 1   // SoundFontPlayerPlugin（1024 声）

        /// 上流 sfzPlayerKind。知らない型は prepare の誤り。
        init(typeName: String) throws {
            switch typeName {
            case "SFZNotePlayerPlugin": self = .note
            case "SoundFontPlayerPlugin": self = .main
            default: throw ETSFZError.prepare("The instrument player is unavailable. Reload the app and try again.")
            }
        }
    }

    /// 見積りと確保が同じ値を見るための幾何（上流 sfzPreparationContext）。
    /// **同じ processingChannels を BeginInfo にも入れる**こと（commitSfzEffects が一致を要る）。
    struct Geometry: Equatable {
        var sampleRate: Double
        var processingChannels: Int
        var maxFrames: Int
        /// 0 は「単独の 120 BPM」の意味。EffectDeck は拍の地図を持たないので 0。
        var minimumPhysicalBpm: Double
        var playerKind: PlayerKind

        init(sampleRate: Double, processingChannels: Int, maxFrames: Int,
             minimumPhysicalBpm: Double = 0, playerKind: PlayerKind = .note) throws {
            guard sampleRate.isFinite, sampleRate > 0,
                  (1...maxProcessingChannels).contains(processingChannels),
                  (1...Int(UInt32.max)).contains(maxFrames)
            else { throw ETSFZError.prepare(ETSFZPreparationRules.audioConfigMessage) }
            guard minimumPhysicalBpm.isFinite, minimumPhysicalBpm >= 0 else {
                throw ETSFZError.prepare(ETSFZPreparationRules.tempoMessage)
            }
            self.sampleRate = sampleRate
            self.processingChannels = processingChannels
            self.maxFrames = maxFrames
            self.minimumPhysicalBpm = minimumPhysicalBpm
            self.playerKind = playerKind
        }
    }

    /// payload の頭から、見積りに渡す制御の部分の長さ（上流 samplePlayerPreparationData）。
    static func controlBytes(of payload: [UInt8]) throws -> Int {
        guard payload.count >= 56, payload.count <= Int(UInt32.max), payload.count % 4 == 0 else {
            throw ETSFZError.prepare(invalidDataMessage)
        }
        func word(_ offset: Int) -> UInt32 {
            UInt32(payload[offset]) | UInt32(payload[offset + 1]) << 8
                | UInt32(payload[offset + 2]) << 16 | UInt32(payload[offset + 3]) << 24
        }
        let control = 32 + Int(word(48)) * 4
        guard word(0) == magic, control >= 56, control <= payload.count else {
            throw ETSFZError.prepare(invalidDataMessage)
        }
        return control
    }

    /// 制御の部分だけ持っているとき（payload の本体は staging へ直に書くので、配列には作らない）の長さ。
    /// control は payload の頭から数えた制御の部分（流し込みの入れ物は payload 全体）、payloadBytes は payload 全体の長さ。
    static func controlBytes(of control: [UInt8], payloadBytes: Int) throws -> Int {
        guard payloadBytes >= control.count, payloadBytes <= Int(UInt32.max), payloadBytes % 4 == 0 else {
            throw ETSFZError.prepare(invalidDataMessage)
        }
        return try controlBytes(of: control)
    }

    /// JS が渡す幾何（ETSFZGeometry）を、見積りと begin が同じ値を見る形にする。player kind は 0・1 だけ。
    static func geometry(_ value: ETSFZGeometry) throws -> Geometry {
        guard let raw = UInt32(exactly: value.playerKind), let kind = PlayerKind(rawValue: raw) else {
            throw ETSFZError.prepare(audioConfigMessage)
        }
        return try Geometry(sampleRate: value.sampleRate, processingChannels: value.processingChannels,
                            maxFrames: value.maxFrames, minimumPhysicalBpm: value.minimumPhysicalBpm, playerKind: kind)
    }

    /// 追加分を足して上限に収める（上流 materializeSfzAsset ＋ Android の native_engine.cpp:390-395）。
    /// footprint = payload + 追加分。maxBytes を超えるか UInt32 に入らなければ too-large。
    static func footprint(payloadBytes: Int, additionalBytes: UInt64, maxBytes: Int) throws -> UInt32 {
        let (total, overflow) = UInt64(max(payloadBytes, 0)).addingReportingOverflow(additionalBytes)
        guard !overflow, total <= UInt64(UInt32.max), total <= UInt64(max(maxBytes, 0)) else {
            throw ETSFZError.tooLarge(tooLargeMessage)
        }
        return UInt32(total)
    }
}
