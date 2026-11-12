//  SFZStreamTable.swift
//  流し込みの SFZ（load_* を持つ SFZ・予算を超える SFZ。payload の表は v8 / v10）を読み込む側の、Foundation だけの部品。
//  Linux でも走る（SFZStreamTableTests）。
//
//    ETSFZStreamSample   JS（上流の prepareStreamedSfzBank のパッチ）が返した、標本 1 本の置き場所
//    ETSFZStreamTable    payload の標本の表と resident の範囲の読み、標本の表（ETSFZSampleSource）の組み立て
//    ETSFZStreamStaging  入れ物の外へ出す標本（FLAC など・JS が作った周期や発生源）の置き場
//
//  SFZ の PCM は **payload に入れない**（表だけ）。engine が必要なページを要求し、ETSFZPageSource が標本のファイルから作って渡す。
//  標本の番号は payload の標本の表と同じ（使われる標本の path の整列。保存形式の違う同じ標本は別の番号。JS が同じ番号で並べて返す）。
//    WAV・AIFF   入れ物（.sfzbank）の中の位置のまま読む（baseOffset = 入れ物の先頭から）
//    FLAC など   AVAudioFile は単体のファイルしか開けないので、入れ物から範囲を写し出して開く（ETSFZStreamStaging）
//    JS だけにある標本（オシレーターの周期・*sine などの発生源・埋め込みの標本）  JS が渡したバイト列を写し出す
//  resident の範囲（load_start・load_end・効果の IR・オシレーターの周期）は payload に入っていて、engine は
//  そのページが入っていないと音を出さない。**ACTIVE の前に ETSFZStream.preload で渡す。**

import Foundation

/// JS が返した、標本 1 本の置き場所。frames・channels・sampleRate は上流の値（payload の表と食い違えば断る）。
struct ETSFZStreamSample: Equatable {
    var index: Int
    /// 保存形式（0 = float、1 = 16 bit）。engine が持つ表と同じ値。
    var mode: Int
    var frames: UInt64
    var channels: Int
    var sampleRate: Int
    /// 標本のファイルの大きさ。
    var size: UInt64
    /// 入れ物（.sfzbank）の先頭から、この標本の先頭まで。入れ物の外の標本（inline）は nil。
    var offset: UInt64?
    /// 入れ物の外の標本のバイト列（JS が deliver したもの）。
    var inline: Data?
}

enum ETSFZStreamTable {

    static let magic: UInt32 = 0x31415445
    /// 上流 SFZ_STREAM_TABLE_VERSION・SFZ_STORAGE_TABLE_VERSION。
    static let streamVersion = 8
    static let storageVersion = 10
    /// preload の上限（上流 SfzSamplePageProvider.preload の 32768）。
    static let maxResidentPages = 32768
    /// 標本の数の上限（上流 SFZ_MAX_SAMPLES。0.18.0 で 10000 から 65536 になった）。
    static let maxSamples = 65536

    /// 標本の表の 1 行（payload から読んだもの）。
    struct Row: Equatable {
        var frames: UInt64
        var channels: Int
        var sampleRate: Int
        var mode: Int
        var residentCursor: Int
        var residentCount: Int
    }

    private static let invalid = ETSFZError.prepare(ETSFZPreparedCheck.preparationFailedMessage)

    /// payload の表の版と、付いてきた標本の置き場所の整合。v9 は SoundFont だけ、v8・v10 は流し込みの SFZ だけ、
    /// v6・v7 など常駐の資産はどちらも持たない。食い違いは JS の表と payload が合わない印なので送らない。
    static func requireConsistent(tableVersion: Int, hasSoundFont: Bool, hasStreamSources: Bool) throws {
        let consistent: Bool
        switch tableVersion {
        case 9: consistent = hasSoundFont && !hasStreamSources
        case streamVersion, storageVersion: consistent = hasStreamSources && !hasSoundFont
        default: consistent = !hasSoundFont && !hasStreamSources
        }
        guard consistent else { throw invalid }
    }

    // MARK: JSON から

    /// glue が返す `streamSamples`（[{index, mode, frames, channels, sampleRate, size, offset, inline}]）。
    /// inline の標本のバイト列は inline(index) で引く。形が違えば nil（流し込みの SFZ として扱わない）。
    static func parse(_ value: Any?, inline: (Int) -> Data?) -> [ETSFZStreamSample]? {
        guard let list = value as? [[String: Any]], !list.isEmpty, list.count <= maxSamples else { return nil }
        func unsigned(_ raw: Any?) -> UInt64? {
            guard let number = raw as? NSNumber else { return nil }
            let double = number.doubleValue
            guard double.isFinite, double >= 0, double == double.rounded(), double <= 9_007_199_254_740_991 else { return nil }
            return UInt64(double)
        }
        var out: [ETSFZStreamSample] = []
        for item in list {
            guard let index = unsigned(item["index"]), index == UInt64(out.count),
                  let mode = unsigned(item["mode"]), mode <= 1,
                  let frames = unsigned(item["frames"]), frames >= 1,
                  let channels = unsigned(item["channels"]), (1...2).contains(channels),
                  let rate = unsigned(item["sampleRate"]), (1...768_000).contains(rate),
                  let size = unsigned(item["size"]), size >= 1 else { return nil }
            var sample = ETSFZStreamSample(index: Int(index), mode: Int(mode), frames: frames, channels: Int(channels),
                                           sampleRate: Int(rate), size: size, offset: nil, inline: nil)
            if (item["inline"] as? Bool) == true {
                guard let data = inline(Int(index)), UInt64(data.count) == size else { return nil }
                sample.inline = data
            } else {
                guard let offset = unsigned(item["offset"]) else { return nil }
                sample.offset = offset
            }
            out.append(sample)
        }
        return out
    }

    // MARK: payload の読み

    private static func words(_ payload: Data) throws -> (word: (Int) -> UInt32, count: Int) {
        // payload の先頭 32 バイトは外枠、その後が u32 の並び（上流 packSfzAsset の integers）。
        guard payload.count >= 32 + 19 * 4, payload.count % 4 == 0 else { throw invalid }
        let base = payload.startIndex
        func read(_ at: Int) -> UInt32 {
            UInt32(payload[base + at]) | UInt32(payload[base + at + 1]) << 8 |
                UInt32(payload[base + at + 2]) << 16 | UInt32(payload[base + at + 3]) << 24
        }
        guard read(0) == magic else { throw invalid }
        let count = (payload.count - 32) / 4
        return ({ index in read(32 + index * 4) }, count)
    }

    /// payload の標本の表。v8（12 語の行）と v10（16 語の行・resident の範囲つき）を読む。
    static func rows(payload: Data) throws -> [Row] {
        let (word, count) = try words(payload)
        let version = Int(word(1))
        guard version == streamVersion || version == storageVersion else { throw invalid }
        let table = Int(word(12)), samples = Int(word(13))
        guard samples >= 1, samples <= maxSamples else { throw invalid }
        let rowWords = version == storageVersion ? 16 : 12
        guard table >= 0, table + samples * rowWords <= count else { throw invalid }
        var rows: [Row] = []
        rows.reserveCapacity(samples)
        for sample in 0..<samples {
            let at = table + sample * rowWords
            let frames = UInt64(word(at + 1)) << 32 | UInt64(word(at))
            var row = Row(frames: frames, channels: Int(word(at + 2)), sampleRate: Int(word(at + 3)), mode: 0,
                          residentCursor: 0, residentCount: 0)
            if version == storageVersion {
                row.mode = Int(word(at + 12))
                row.residentCursor = Int(word(at + 13))
                row.residentCount = Int(word(at + 14))
            }
            guard frames >= 1, (1...2).contains(row.channels), (1...768_000).contains(row.sampleRate), row.mode <= 1 else { throw invalid }
            rows.append(row)
        }
        return rows
    }

    /// 先に渡しておくページ（resident の範囲を 4096 フレームごとにしたもの。上流 streamed-bank.js の required と同じ並び）。
    /// v8 は resident の範囲を持たない（空）。
    static func residentPages(payload: Data) throws -> [(sample: Int, page: UInt64)] {
        let rows = try rows(payload: payload)
        let (word, count) = try words(payload)
        guard Int(word(1)) == storageVersion else { return [] }
        let offset = Int(word(17)), total = Int(word(18))
        guard offset >= 0, total >= 0, offset + total * 4 <= count else { throw invalid }
        let page = UInt64(ETSFZPageDecode.pageFrames)
        var pages: [(sample: Int, page: UInt64)] = []
        var used = 0
        for (sample, row) in rows.enumerated() {
            guard row.residentCursor >= 0, row.residentCount >= 0, row.residentCursor + row.residentCount <= total else { throw invalid }
            used += row.residentCount
            for interval in row.residentCursor..<(row.residentCursor + row.residentCount) {
                let at = offset + interval * 4
                let first = UInt64(word(at + 1)) << 32 | UInt64(word(at))
                let end = UInt64(word(at + 3)) << 32 | UInt64(word(at + 2))
                guard first < end, end <= row.frames else { throw invalid }
                for index in (first / page)...((end - 1) / page) {
                    pages.append((sample, index))
                    guard pages.count <= maxResidentPages else { throw invalid }
                }
            }
        }
        guard used == total else { throw invalid }
        return pages
    }

    // MARK: 標本の表

    /// 標本の番号ごとの読み口。JS の表と payload の表が食い違えば断る。
    /// bank は置き場の .sfzbank、bankID はその 24 桁（staging の名前）。
    static func sources(samples: [ETSFZStreamSample], payload: Data, bank: URL, bankBytes: UInt64, bankID: String,
                        staging: ETSFZStreamStaging, reader: ETSFZFileReader = ETSFZFileReader()) throws -> [ETSFZSampleSource] {
        defer { reader.closeAll() }
        let table = try rows(payload: payload)
        guard table.count == samples.count else { throw invalid }
        var out: [ETSFZSampleSource] = []
        out.reserveCapacity(samples.count)
        for (index, sample) in samples.enumerated() {
            let row = table[index]
            guard sample.index == index, sample.frames == row.frames, sample.channels == row.channels,
                  sample.sampleRate == row.sampleRate, sample.mode == row.mode else { throw invalid }
            do {
                out.append(try source(for: sample, bank: bank, bankBytes: bankBytes, bankID: bankID, staging: staging, reader: reader))
            } catch let error as ETSFZError {
                throw error
            } catch {
                throw invalid
            }
        }
        return out
    }

    private static func source(for sample: ETSFZStreamSample, bank: URL, bankBytes: UInt64, bankID: String,
                               staging: ETSFZStreamStaging, reader: ETSFZFileReader) throws -> ETSFZSampleSource {
        // 標本のファイルの置き場所（url・先頭・大きさ）
        var url = bank, base: UInt64 = 0, standalone = false
        if let inline = sample.inline {
            url = try staging.stage(inline, bank: bankID, index: sample.index, ext: ETSFZAudioSniff.fileExtension(for: inline))
            standalone = true
        } else if let offset = sample.offset {
            let (end, overflow) = offset.addingReportingOverflow(sample.size)
            guard !overflow, end <= bankBytes else { throw invalid }
            base = offset
        } else {
            throw invalid
        }
        guard sample.size >= 12 else { throw invalid }
        let head = try reader.read(url: url, offset: base, length: 12)
        let signature = String(decoding: head.prefix(4), as: UTF8.self)
        if signature == "RIFF" || signature == "FORM" {
            // WAV・AIFF は入れ物の中のまま読む。頭の読みは上流の pcmMetadata と同じで、上流が見た frames などと合うこと
            let found = try ETSFZPCMHeader.source(url: url, baseOffset: base, size: sample.size, reader: reader)
            guard found.frames == sample.frames, found.channels == sample.channels, found.sampleRate == sample.sampleRate else { throw invalid }
            return found
        }
        // FLAC など。AVAudioFile に開かせるため単体のファイルにする（入れ物の中なら範囲を写し出す）
        if !standalone {
            var prefix = head
            if prefix.count < 12 { prefix = Data() }
            url = try staging.extract(from: bank, offset: base, length: sample.size, bank: bankID, index: sample.index,
                                      ext: ETSFZAudioSniff.fileExtension(for: prefix))
        }
        return ETSFZSampleSource(url: url, baseOffset: 0, format: .audioFile, frames: sample.frames, channels: sample.channels,
                                 sampleRate: sample.sampleRate)
    }
}

// MARK: - 入れ物の外へ出す標本の置き場

/// 標本を単体のファイルにして置く場所。<root>/<bankID>/<番号>.<拡張子>。OS が片付けてよい場所（Caches）に置くので、
/// 読み込むたびに無ければ作り直す。バンクを消したら一緒に消す。
struct ETSFZStreamStaging {

    let root: URL

    init(root: URL) { self.root = root }

    /// 本番の置き場（Caches/SFZStream）。
    static var standard: ETSFZStreamStaging {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return ETSFZStreamStaging(root: base.appendingPathComponent("SFZStream", isDirectory: true))
    }

    private static let invalid = ETSFZError.prepare(ETSFZPreparedCheck.preparationFailedMessage)
    private static let chunkBytes = 1024 * 1024

    func directory(bank: String) -> URL { root.appendingPathComponent(bank, isDirectory: true) }

    private func target(bank: String, index: Int, ext: String) throws -> URL {
        // 名前は 24 桁の 16 進と、番号と、拡張子（英小文字・数字）だけ。道の組み立てが入り込む余地を作らない
        guard ETSFZ.isValidID(bank), index >= 0, !ext.isEmpty, ext.utf8.allSatisfy({ ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) })
        else { throw Self.invalid }
        let folder = directory(bank: bank)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("\(index).\(ext)")
    }

    private func size(of url: URL) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attributes[.size] as? NSNumber else { return nil }
        return number.uint64Value
    }

    /// バイト列をそのまま置く（JS が作った標本。小さい）。
    func stage(_ data: Data, bank: String, index: Int, ext: String) throws -> URL {
        let url = try target(bank: bank, index: index, ext: ext)
        do { try data.write(to: url, options: .atomic) } catch { throw Self.invalid }
        return url
    }

    /// 入れ物の範囲を単体のファイルへ写す。同じ大きさのファイルが既にあれば使い回す（入れ物は書き換わらない）。
    func extract(from source: URL, offset: UInt64, length: UInt64, bank: String, index: Int, ext: String) throws -> URL {
        let url = try target(bank: bank, index: index, ext: ext)
        if size(of: url) == length { return url }
        let temporary = url.deletingLastPathComponent().appendingPathComponent("\(index).\(ext).tmp")
        try? FileManager.default.removeItem(at: temporary)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw Self.invalid }
        do {
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: temporary)
            defer { try? output.close() }
            try input.seek(toOffset: offset)
            var remaining = length
            while remaining > 0 {
                let count = Int(min(remaining, UInt64(Self.chunkBytes)))
                guard let chunk = try input.read(upToCount: count), chunk.count == count else { throw Self.invalid }
                try output.write(contentsOf: chunk)
                remaining -= UInt64(count)
            }
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: temporary, to: url)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw Self.invalid
        }
        return url
    }

    /// バンクの分を消す。
    func remove(bank: String) {
        guard ETSFZ.isValidID(bank) else { return }
        try? FileManager.default.removeItem(at: directory(bank: bank))
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: root)
    }
}
