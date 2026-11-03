//  SFZAsset.swift
//  SFZ Note Player のカーネルへ送る「資産」（領域の表と音の PCM）の並び。
//  **Foundation だけ。**Linux でも走る（SFZTests）。
//
//  上流は js/sfz/asset.js の packSfzAsset。書き手は上流のそれ、読み手は
//  dsp/plugins/others/sfz_note_player/kernel.cpp の commitAsset（検算の式が書いてある）。
//
//  並び（すべてリトルエンディアン）:
//      0   外側の 32 バイト: u32 magic 0x31415445 / u32 1 / u32 floatCount / u32 1 / 0 …
//      32  u32 の表の頭 8 語: 0x53465a / 版 2 / 領域の数 / 1 領域の語数 30 / PCM の始まり（語）/ floatCount / 群の数 / 0
//      …   領域 1 つにつき 30 語（SFZ_REGION_FIELDS の順。添字は u32 のビットのまま、他は float32）
//      …   PCM。サンプルの道の順に、フレームごとにチャンネルを交互に並べた float32
//  floatCount は 32 バイトの後ろの語の数（= 8 + 30 × 領域 + PCM の語）。
//
//  カーネルへ渡す begin の引数は SFZ 専用（begin 側は AssetUpload.beginInfo では作らない）:
//      channels 1 / frames floatCount / topology 0 / head_block 128 / rate_divider 1 / processing_channels 1 /
//      footprint = バイト数 + 4 × (129 + 2 × 群 + Σ(hikey - lokey + 1))（カーネルが索引に使う分）。

import Foundation

/// 取り込んだ音。面ごとに分かれた float と、素材のレート（整数）。
struct ETSFZPCM {
    var channels: [[Float]]
    var sampleRate: Int
}

/// 送る資産。
struct ETSFZPackedAsset {
    /// 外側の 32 バイトから後ろ全部（AssetUpload.send へそのまま渡す）。
    var payload: [UInt8]
    var floatCount: Int
    var regionCount: Int
    /// begin の footprintBytes。
    var footprintBytes: Int
    var warnings: [ETSFZWarning]
}

enum ETSFZAsset {

    static let tableVersion: UInt32 = 2
    static let regionFields: [String] = [
        "sampleOffset", "sampleFrames", "channels", "sampleRate", "lokey", "hikey", "lovel", "hivel",
        "lorand", "hirand", "seq_length", "seq_position", "seqGroup", "pitch_keycenter",
        "pitch_keytrack", "transpose", "tune", "volume", "pan", "amp_veltrack", "offset", "end",
        "loop_mode", "loop_start", "loop_end", "ampeg_attack", "ampeg_hold", "ampeg_decay",
        "ampeg_sustain", "ampeg_release",
    ]
    /// u32 のビットのまま書く欄。
    private static let indexFields: Set<String> = ["sampleOffset", "sampleFrames", "offset", "end", "loop_start", "loop_end"]

    /// 領域に音の形を足したもの（packSfzAsset の `normalized`）。
    private struct Normalized {
        var region: ETSFZRegion
        var sampleFrames: Int
        var channels: Int
        var sampleRate: Int
        var sampleOffset = 0
        var end: Double
        var loop_end: Double

        func value(_ key: String) -> Double {
            switch key {
            case "sampleOffset": return Double(sampleOffset)
            case "sampleFrames": return Double(sampleFrames)
            case "channels": return Double(channels)
            case "sampleRate": return Double(sampleRate)
            case "end": return end
            case "loop_end": return loop_end
            default: return region.value(key) ?? .nan
            }
        }
    }

    /// 領域と PCM から資産を組む。
    /// 音の形が合わない（mono / stereo でない・レートが外れる）ものは prepare の誤り。
    /// 領域の再生位置が音の外・ループが外れる、などの領域は外して警告に数える（全部外れたら最初の誤りを投げる）。
    static func pack(_ inputRegions: [ETSFZRegion], samples: [String: ETSFZPCM],
                     maxBytes: Int = ETSFZ.defaultMaxBytes,
                     onDiagnostic: ((ETSFZDiagnostics) -> Void)? = nil) throws -> ETSFZPackedAsset {
        precondition(ETSFZ.isValidMaxBytes(maxBytes), "Invalid SFZ size limit.")
        if inputRegions.isEmpty { throw ETSFZError(code: .noRegions, message: "The SFZ has no playable regions.") }
        var samplePaths = ETSFZ.jsSorted(Array(Set(inputRegions.map(\.sample))))
        var info: [String: (frames: Int, channels: Int, rate: Int, offset: Int)] = [:]
        for path in samplePaths {
            guard let pcm = samples[path], let first = pcm.channels.first,
                  (1...2).contains(pcm.channels.count), !first.isEmpty,
                  pcm.channels.allSatisfy({ $0.count == first.count }),
                  pcm.sampleRate >= 1, pcm.sampleRate <= 768_000 else {
                throw ETSFZError.prepare("SFZ samples must contain mono or stereo audio.")
            }
            info[path] = (first.count, pcm.channels.count, pcm.sampleRate, 0)
        }

        var playable: [Normalized] = []
        var invalidRegions: [String] = []
        var firstInvalid: ETSFZError?
        var ignoredLoopPoints = 0
        for region in inputRegions {
            let i = info[region.sample]!
            let end = region.end ?? Double(i.frames - 1)
            var normalized = Normalized(region: region, sampleFrames: i.frames, channels: i.channels,
                                        sampleRate: i.rate, end: end, loop_end: region.loop_end ?? end)
            do {
                if normalized.region.offset > end || end >= Double(i.frames) || end < 0 {
                    throw ETSFZError.prepare("SFZ playback points exceed the sample.")
                }
                let invalidLoop = normalized.region.loop_start < 0 || normalized.region.loop_start > normalized.loop_end
                    || normalized.loop_end > end
                if invalidLoop && (region.loop_mode == 0 || region.loop_mode == 1) {
                    normalized.region.loop_start = 0
                    normalized.loop_end = end
                } else if invalidLoop {
                    throw ETSFZError.prepare("SFZ loop points exceed the sample.")
                }
                for key in regionFields where key != "sampleOffset" {
                    let value = normalized.value(key)
                    if !value.isFinite { throw ETSFZError.prepare("SFZ region has invalid values.") }
                    if indexFields.contains(key)
                        && (value != value.rounded(.towardZero) || value < 0 || value > 4_294_967_295) {
                        throw ETSFZError.prepare("SFZ sample positions must be non-negative integers.")
                    }
                }
                if invalidLoop { ignoredLoopPoints += 1 }
                playable.append(normalized)
            } catch let error as ETSFZError where error.code == .prepare {
                if firstInvalid == nil { firstInvalid = error }
                invalidRegions.append("\(region.sample): \(error.message)")
            }
        }
        if !invalidRegions.isEmpty { onDiagnostic?(ETSFZDiagnostics(invalidRegions: invalidRegions)) }
        if playable.isEmpty, let firstInvalid { throw firstInvalid }

        samplePaths = ETSFZ.jsSorted(Array(Set(playable.map(\.region.sample))))
        var poolLength = 0
        for path in samplePaths {
            info[path]!.offset = poolLength
            poolLength += info[path]!.frames * info[path]!.channels
        }
        let groupIds = Array(Set(playable.map(\.region.seqGroup))).sorted()
        let groups = Dictionary(uniqueKeysWithValues: groupIds.enumerated().map { ($1, $0) })
        let fieldCount = regionFields.count
        let poolOffset = 8 + fieldCount * playable.count
        let floatCount = poolOffset + poolLength
        let byteLength = 32 + floatCount * 4
        let indexEntries = playable.reduce(0) { $0 + Int($1.region.hikey - $1.region.lokey) + 1 }
        let footprintBytes = byteLength + 4 * (129 + 2 * groupIds.count + indexEntries)
        if footprintBytes > maxBytes { throw ETSFZError.tooLarge("The SFZ samples are too large to load.") }

        var payload = [UInt8](repeating: 0, count: byteLength)
        payload.withUnsafeMutableBytes { raw in
            func put(_ value: UInt32, at offset: Int) {
                raw.storeBytes(of: value.littleEndian, toByteOffset: offset, as: UInt32.self)
            }
            // 外側の頭。
            put(0x3141_5445, at: 0)
            put(1, at: 4)
            put(UInt32(floatCount), at: 8)
            put(1, at: 12)
            // 表の頭は u32 のビット（数としての変換ではない）。
            for (i, value) in [0x0053_465A, tableVersion, UInt32(playable.count), UInt32(fieldCount),
                               UInt32(poolOffset), UInt32(floatCount), UInt32(groupIds.count), 0].enumerated() {
                put(value, at: 32 + 4 * i)
            }
            for (index, var item) in playable.enumerated() {
                let i = info[item.region.sample]!
                item.sampleOffset = i.offset
                item.region.seqGroup = groups[item.region.seqGroup]!
                for (field, key) in regionFields.enumerated() {
                    let offset = 32 + 4 * (8 + index * fieldCount + field)
                    let value = item.value(key)
                    if indexFields.contains(key) {
                        put(UInt32(value), at: offset)
                    } else {
                        put(Float(value).bitPattern, at: offset)
                    }
                }
            }
        }
        // PCM。フレームごとにチャンネルを交互に。
        var invalidSample = false
        payload.withUnsafeMutableBytes { raw in
            for path in samplePaths {
                let pcm = samples[path]!
                let i = info[path]!
                var cursor = 32 + 4 * (poolOffset + i.offset)
                for frame in 0..<i.frames {
                    for channel in pcm.channels {
                        let value = channel[frame]
                        if !value.isFinite { invalidSample = true }
                        raw.storeBytes(of: value.bitPattern.littleEndian, toByteOffset: cursor, as: UInt32.self)
                        cursor += 4
                    }
                }
            }
        }
        if invalidSample { throw ETSFZError.prepare("SFZ audio contains invalid samples.") }

        var warnings: [ETSFZWarning] = []
        if ignoredLoopPoints > 0 { warnings.append(ETSFZWarning(code: "loop-points-ignored", count: ignoredLoopPoints)) }
        if !invalidRegions.isEmpty { warnings.append(ETSFZWarning(code: "invalid-regions", count: invalidRegions.count)) }
        return ETSFZPackedAsset(payload: payload, floatCount: floatCount, regionCount: playable.count,
                                footprintBytes: footprintBytes, warnings: warnings)
    }
}
