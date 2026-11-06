//  SFZSoundFont.swift
//  SoundFont（SF2）を読み込む側の、Foundation だけの部品。Linux でも走る（SFZSoundFontTests）。
//
//    ETSFZPreset / ETSFZPresetMenu   音源が持つ Preset の一覧と、Preset の選択欄（上流 sfz-instrument.js の
//                                    validatePreparedSfzBank と _renderPresetSelection）
//    ETSFZSoundFontInfo              JS（上流の prepareSoundFontBank）が返した、Preset の一覧と標本の置き場所の表。
//                                    ここから ETSFZSampleSource（ページを作る側が読むファイルの範囲）を組む
//    ETSFZSoundFormats               SoundFont Library が取り込む拡張子
//
//  SF3（標本が Ogg Vorbis）も同じ道。PCM は ETVorbis.c（stb_vorbis）が標本ごとに復号して、ページとして渡す。
//  標本の位置は dataOffset（SoundFont ファイルの先頭から Ogg の先頭まで）・dataBytes（Ogg の長さ）、使う範囲は
//  firstFrame（復号後のどこが標本のフレーム 0 か）と sourceFrames（復号後の全体の長さ = 最後の granule）。
//
//  SF2 の PCM は **payload に入れない**（payload は表だけ。v9）。engine が必要なページを要求し、ETSFZPageSource が
//  置き場の .sfzbank（SF2 をそのまま入れた入れ物）から 16 bit（と sm24 の下位バイト）を読んで渡す。
//  標本ごとの位置は上流の SF2 の読み手（js/sf2/sample-reader.js）が決める値をそのまま使う
//    dataOffset      SF2 ファイルの先頭から、この標本の smpl の先頭まで
//    lowByteOffset   同じく sm24（24 bit の下位バイト）の先頭。sm24 が無ければ nil
//    baseOffset      .sfzbank の先頭から、SF2 ファイルの先頭まで（入れ物の頭の分）
//  標本の番号は payload の標本の表の並びと同じ（使われる標本の path を整列したもの。JS が同じ式で並べて返す）。

import Foundation

// MARK: - Preset

/// SoundFont の Preset 1 件（phdr）。bank と program は上流の値のまま。
struct ETSFZPreset: Equatable {
    var bank: Int
    var program: Int
    var name: String

    /// sp0 に入れる値。bank × 128 + program。
    var key: Int { bank * 128 + program }
}

enum ETSFZPresetMenu {

    /// 先頭の「音源の先頭」（sp0 = -1）。
    static let defaultKey = -1
    static let defaultLabel = "Default"

    struct Item: Equatable, Identifiable {
        var key: Int
        var label: String
        var id: Int { key }
    }

    /// 選べる Preset。bank ≤ 128・program ≤ 127 だけ（上流 sfz-instrument.js:397-398。GM 以外の
    /// 大きい bank 番号は sp0 の目盛りに入らない）。
    static func eligible(_ presets: [ETSFZPreset]) -> [ETSFZPreset] {
        presets.filter { $0.bank >= 0 && $0.bank <= 128 && $0.program >= 0 && $0.program <= 127 }
    }

    /// 選択欄の中身。選べる Preset が 1 つも無ければ空（SFZ のバンクや Preset を持たない音源では欄ごと隠す）。
    /// 先頭は Default（-1）、続きは `Bank b · p+1. name`。**同じ bank × program は先に出たものだけ**（上流の keys）。
    static func items(_ presets: [ETSFZPreset]) -> [Item] {
        let list = eligible(presets)
        guard !list.isEmpty else { return [] }
        var seen: Set<Int> = [defaultKey]
        var out = [Item(key: defaultKey, label: defaultLabel)]
        for preset in list where seen.insert(preset.key).inserted {
            out.append(Item(key: preset.key, label: label(of: preset)))
        }
        return out
    }

    static func label(of preset: ETSFZPreset) -> String {
        "Bank \(preset.bank) · \(preset.program + 1). \(preset.name)"
    }

    /// 読み込んだ後の sp0。いまの値が選べる Preset に無ければ -1（上流の validatePreparedSfzBank）。
    /// 上流の sp0 は丸めた整数なので、小数や範囲外は -1 に戻る。
    static func validatedSelection(current: Float, presets: [ETSFZPreset]) -> Float {
        guard current.isFinite, current >= 0, current == current.rounded() else { return Float(defaultKey) }
        let keys = Set(eligible(presets).map(\.key))
        return keys.contains(Int(current)) ? current : Float(defaultKey)
    }
}

// MARK: - 標本の置き場所

/// SF2 の標本 1 本の、ファイルの中の位置（JS の reader.pcm と reader.rangeSource.offset）。
struct ETSFZSoundFontSample: Equatable {
    var baseOffset: UInt64
    var dataOffset: UInt64
    var lowByteOffset: UInt64?
    var frames: UInt64
    var sampleRate: Int
    /// SF3（Vorbis）の標本。
    var compressed: Bool = false
    /// SF3 の標本だけ。Ogg のバイト数（dataOffset から）。
    var dataBytes: UInt64 = 0
    /// SF3 の標本だけ。復号後のどのフレームが標本のフレーム 0 か（frames は使う範囲の長さ）。
    var firstFrame: UInt64 = 0
    /// SF3 の標本だけ。復号後の全体の長さ。
    var sourceFrames: UInt64 = 0
}

/// JS が返した SoundFont の情報。
struct ETSFZSoundFontInfo: Equatable {
    /// "sf2" / "sf3"。
    var format: String
    var presets: [ETSFZPreset]
    var samples: [ETSFZSoundFontSample]

    /// ページを作る側が読む標本の表。bank は置き場の .sfzbank。表の並びは payload の標本の番号と同じ。
    /// 読めない形（範囲の外・標本が 0 フレーム・SF3 の上限超え）は prepare の誤りにする。
    func sources(bank: URL, bankBytes: UInt64? = nil) throws -> [ETSFZSampleSource] {
        try samples.map { sample in
            guard sample.frames >= 1, (1...768_000).contains(sample.sampleRate) else { throw ETSFZError.prepare(ETSFZSoundFontInfo.invalidMessage) }
            if sample.compressed {
                let layout = ETSFZVorbisLayout(dataOffset: sample.dataOffset, dataBytes: sample.dataBytes,
                                               firstFrame: sample.firstFrame, sourceFrames: sample.sourceFrames)
                guard layout.isValid(frames: sample.frames) else { throw ETSFZError.prepare(ETSFZSoundFontInfo.invalidMessage) }
                if let bankBytes {
                    // Ogg が入れ物の外に出るのは、JS の表と置き場のファイルが食い違った印。
                    let start = sample.baseOffset.addingReportingOverflow(sample.dataOffset)
                    let end = start.partialValue.addingReportingOverflow(sample.dataBytes)
                    guard !start.overflow, !end.overflow, end.partialValue <= bankBytes else {
                        throw ETSFZError.prepare(ETSFZSoundFontInfo.invalidMessage)
                    }
                }
                return ETSFZSampleSource(url: bank, baseOffset: sample.baseOffset, format: .vorbis(layout),
                                         frames: sample.frames, channels: 1, sampleRate: sample.sampleRate)
            }
            if let bankBytes {
                // 範囲が入れ物の外に出るのは、JS の表と置き場のファイルが食い違った印。
                let (highEnd, overflowHigh) = sample.frames.multipliedReportingOverflow(by: 2)
                let highStart = sample.baseOffset.addingReportingOverflow(sample.dataOffset)
                let (end, overflowEnd) = highStart.partialValue.addingReportingOverflow(highEnd)
                guard !overflowHigh, !highStart.overflow, !overflowEnd, end <= bankBytes else {
                    throw ETSFZError.prepare(ETSFZSoundFontInfo.invalidMessage)
                }
                if let low = sample.lowByteOffset {
                    let start = sample.baseOffset.addingReportingOverflow(low)
                    let lowEnd = start.partialValue.addingReportingOverflow(sample.frames)
                    guard !start.overflow, !lowEnd.overflow, lowEnd.partialValue <= bankBytes else {
                        throw ETSFZError.prepare(ETSFZSoundFontInfo.invalidMessage)
                    }
                }
            }
            return ETSFZSampleSource(
                url: bank, baseOffset: sample.baseOffset,
                format: .sf2PCM(dataOffset: sample.dataOffset, lowByteOffset: sample.lowByteOffset),
                frames: sample.frames, channels: 1, sampleRate: sample.sampleRate)
        }
    }

    /// 上流の prepareSoundFontBank の「圧縮標本を断る」文（sf2/asset.js）。「This browser」は「This device」にする（SFZMessages と同じ）。
    /// Vorbis を native で復号するので、この文が出るのは JS が codec を使えないと答えたときだけ（出ない）。
    static let compressedMessage = "This device cannot play compressed SoundFonts. Choose an SF2 SoundFont."
    static let invalidMessage = "The SoundFont collection could not be prepared."

    // MARK: JSON から

    private static func unsigned(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double >= 0, double == double.rounded(), double <= 9_007_199_254_740_991 else { return nil }
        return UInt64(double)
    }

    /// glue が返す `soundFont`（{format, presets:[{bank, program, name}], samples:[{base, dataOffset, lowByteOffset, frames, sampleRate,
    /// compressed, dataBytes, firstFrame, sourceFrames}]}。最後の 3 つは SF3 の標本だけ）。
    /// 形が違えば nil（SoundFont として扱わない）。
    static func parse(_ value: Any?) -> ETSFZSoundFontInfo? {
        guard let object = value as? [String: Any], let format = object["format"] as? String,
              let presetList = object["presets"] as? [[String: Any]],
              let sampleList = object["samples"] as? [[String: Any]] else { return nil }
        var presets: [ETSFZPreset] = []
        for item in presetList {
            guard let bank = unsigned(item["bank"]), let program = unsigned(item["program"]),
                  bank <= 65535, program <= 65535 else { return nil }
            presets.append(ETSFZPreset(bank: Int(bank), program: Int(program), name: (item["name"] as? String) ?? ""))
        }
        var samples: [ETSFZSoundFontSample] = []
        for item in sampleList {
            guard let base = unsigned(item["base"]), let data = unsigned(item["dataOffset"]),
                  let frames = unsigned(item["frames"]), let rate = unsigned(item["sampleRate"]), rate <= 768_000
            else { return nil }
            var low: UInt64?
            if let raw = item["lowByteOffset"], !(raw is NSNull) {
                guard let parsed = unsigned(raw) else { return nil }
                low = parsed
            }
            let compressed = (item["compressed"] as? Bool) ?? false
            var sample = ETSFZSoundFontSample(baseOffset: base, dataOffset: data, lowByteOffset: low, frames: frames,
                                              sampleRate: Int(rate), compressed: compressed)
            if compressed {
                // SF3 の標本は 3 つとも要る。欠けた表は SoundFont として扱わない。
                guard let bytes = unsigned(item["dataBytes"]), let first = unsigned(item["firstFrame"]),
                      let source = unsigned(item["sourceFrames"]) else { return nil }
                sample.dataBytes = bytes
                sample.firstFrame = first
                sample.sourceFrames = source
            }
            samples.append(sample)
        }
        return ETSFZSoundFontInfo(format: format, presets: presets, samples: samples)
    }
}

// MARK: - 取り込む拡張子

enum ETSFZSoundFormats {

    /// SoundFont Library が取り込む SoundFont の拡張子。
    static let soundFontExtensions = ["sf2", "sf3"]

    /// 取り込みの一覧に出す道か（SFZ か、取り込める SoundFont）。
    static func isInstrument(path: String) -> Bool {
        let lower = path.lowercased()
        if lower.hasSuffix(".sfz") { return true }
        return soundFontExtensions.contains { lower.hasSuffix(".\($0)") }
    }

    static func isSoundFont(path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasSuffix(".sf2") || lower.hasSuffix(".sf3")
    }
}
