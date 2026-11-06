//  SFZPageDecode.swift
//  流し込みの標本のページ（4096 フレーム）を、ファイルの該当範囲から作る。**Foundation だけ。**Linux でも走る（SFZPageDecodeTests）。
//
//  engine は標本の PCM を持たず、必要なページを要求してくる（Sources/Shared/ETSampleStream.h）。ページの中身を作るのが
//  ここ。数字は上流 js/sfz/sample-stream.js の readFrames（pcm と sf2-pcm）と 1 ビットまで同じ（Tools/golden/sample_page_golden.mjs が
//  上流の JS で作った見本と SFZPageDecodeTests が比べる）。
//
//  - WAV / AIFF / AIFC の PCM: ETSFZPCMHeader が上流の pcmMetadata と同じ読みで形（データの位置・語長・並び）を取り、
//    decodePCM が 1 つずつ float にする（value * 2^(1 - bits)、浮動小数はそのまま）。
//  - SF2: 16 bit（高位）と sm24 の下位 8 bit から (high * 256 + low) / 8388608、sm24 が無ければ high / 32768。
//  - FLAC などは AVAudioFile の側（ETSFZPageSource.swift）が読む。ここでは unsupported を返す。
//  - SF3（Ogg Vorbis）は ETVorbis.c（stb_vorbis）の側（ETSFZPageSource.swift の ETSFZVorbisReader）が読む。ここでは
//    unsupported を返す。ETSFZVorbisLayout は、その読み手が引く位置と長さの検査だけここに持つ（Foundation だけ）。
//
//  再生に使う標本は 1 または 2 チャンネル。ページはインターリーブの float（frames × channels）。

import Foundation

/// 上流の sample-stream.js のエラーコードと同じ区別（文は付けない。呼び手が要求を断念するだけ）。
enum ETSFZPageError: Error, Equatable {
    case range          // sample-range
    case format         // sample-format
    case changed        // sample-changed（読めた長さが足りない・ファイルが変わった）
    case unsupported    // この読み手では読めない形式（FLAC など）
}

/// WAV / AIFF の PCM の形（上流 pcmMetadata の出力のうち、読み出しに要るもの）。
struct ETSFZPCMLayout: Equatable {
    /// 標本ファイルの先頭から、PCM の先頭までのバイト数。
    var dataOffset: UInt64
    var blockAlign: Int
    var bitsPerSample: Int
    var float: Bool
    var littleEndian: Bool
    /// WAV の 8 bit は符号なし（-128 して使う）。AIFF は符号つき。
    var unsigned: Bool
}

enum ETSFZSampleFormat: Equatable {
    case pcm(ETSFZPCMLayout)
    /// SF2 の smpl（Int16 LE が frames 個）と、あれば sm24 の下位バイト（frames 個）。位置は書庫の標本の先頭から。
    case sf2PCM(dataOffset: UInt64, lowByteOffset: UInt64?)
    /// AVAudioFile に読ませる（FLAC など）。baseOffset は 0（ファイルそのもの）であること。
    case audioFile
    /// SF3 の標本 1 本（モノの Ogg Vorbis）。ETVorbis.c で復号する。
    case vorbis(ETSFZVorbisLayout)
}

/// SF3 の標本の Ogg の置き場所と、復号後のどの範囲を標本として使うか（上流の reader.pcm の dataOffset・dataBytes・
/// firstFrame・sourceFrames）。標本の frames（ETSFZSampleSource.frames）は使う範囲の長さで、ページ 0 は復号後の
/// firstFrame から始まる。
struct ETSFZVorbisLayout: Equatable {
    /// SoundFont ファイルの先頭から、この標本の Ogg の先頭まで。
    var dataOffset: UInt64
    /// Ogg のバイト数（最後のページの終わりまで）。
    var dataBytes: UInt64
    /// 復号後（最後の granule で切った全体）のどのフレームが標本のフレーム 0 か。
    var firstFrame: UInt64
    /// 復号後の全体の長さ（= 最後のページの granule）。
    var sourceFrames: UInt64

    /// 1 本の Ogg の上限（ETVorbis.h の ET_VORBIS_MAX_BYTES）。
    static let maxBytes: UInt64 = 64 * 1024 * 1024
    /// 復号後の上限（ET_VORBIS_MAX_FRAMES）。
    static let maxFrames: UInt64 = 16 * 1024 * 1024
    /// 識別・コメント・設定のヘッダーと 1 ページが収まる最小の長さ（上流の size < 58）。
    static let minBytes: UInt64 = 58

    /// 形の検査。frames は標本の長さ。範囲が sourceFrames の中にあり、Ogg の長さと復号後の長さが上限の中なら true。
    func isValid(frames: UInt64) -> Bool {
        guard frames >= 1, sourceFrames >= 1, sourceFrames <= Self.maxFrames,
              dataBytes >= Self.minBytes, dataBytes <= Self.maxBytes else { return false }
        let (end, overflow) = firstFrame.addingReportingOverflow(frames)
        return !overflow && end <= sourceFrames
    }
}

/// 1 本の標本がどこにどう入っているか。上流の「標本の道」（samples[i]）に当たる。
struct ETSFZSampleSource: Equatable {
    var url: URL
    /// ファイルの中の、この標本の先頭（書庫の中なら offset。単体のファイルなら 0）。
    var baseOffset: UInt64
    var format: ETSFZSampleFormat
    var frames: UInt64
    var channels: Int
    var sampleRate: Int
}

enum ETSFZPageDecode {

    /// 1 ページのフレーム数（上流 SFZ_SAMPLE_PAGE_FRAMES）。
    static let pageFrames = 4096
    /// 1 回の読みの上限（上流 SFZ_SAMPLE_RANGE_MAX_BYTES）。4096 フレーム × 2 チャンネル × 8 バイトは 64 KiB で収まる。
    static let maxReadBytes = 1024 * 1024

    /// page 番目のページのフレーム数。範囲外（先頭が標本の外）なら nil。
    static func framesInPage(_ page: UInt64, totalFrames: UInt64) -> Int? {
        let (first, overflow) = page.multipliedReportingOverflow(by: UInt64(pageFrames))
        guard !overflow, first < totalFrames else { return nil }
        return Int(min(UInt64(pageFrames), totalFrames - first))
    }

    // MARK: PCM（WAV / AIFF）

    /// bytes（frames × blockAlign バイト）を float にする。上流 decodePcm と同じ式。非有限は format で止める。
    static func decodePCM(_ bytes: UnsafeRawBufferPointer, layout: ETSFZPCMLayout, channels: Int,
                          into out: UnsafeMutablePointer<Float>) throws {
        let bits = layout.bitsPerSample
        guard [8, 16, 24, 32, 64].contains(bits), channels >= 1, channels <= 2,
              layout.blockAlign == channels * bits / 8,
              bytes.count % layout.blockAlign == 0
        else { throw ETSFZPageError.format }
        let width = bits / 8
        let count = bytes.count / width
        let le = layout.littleEndian
        // 2^(1 - bits)。2 のべきなので掛け算は丸めない。
        let scale = Double(sign: .plus, exponent: 1 - bits, significand: 1)
        for i in 0..<count {
            let at = i * width
            let value: Double
            if layout.float {
                if bits == 32 {
                    let raw = load32(bytes, at, le)
                    value = Double(Float(bitPattern: raw))
                } else {
                    value = Double(bitPattern: load64(bytes, at, le))
                }
            } else if bits == 8 {
                let byte = bytes[at]
                value = layout.unsigned ? Double(Int(byte) - 128) : Double(Int8(bitPattern: byte))
            } else if bits == 16 {
                let raw = UInt16(truncatingIfNeeded: load16(bytes, at, le))
                value = Double(Int16(bitPattern: raw))
            } else if bits == 24 {
                var v = le
                    ? Int(bytes[at]) + Int(bytes[at + 1]) * 256 + Int(bytes[at + 2]) * 65536
                    : Int(bytes[at]) * 65536 + Int(bytes[at + 1]) * 256 + Int(bytes[at + 2])
                if v >= 0x800000 { v -= 0x1000000 }
                value = Double(v)
            } else {
                value = Double(Int32(bitPattern: load32(bytes, at, le)))
            }
            guard value.isFinite else { throw ETSFZPageError.format }
            // 浮動小数はそのまま、整数は 2^(1 - bits) を掛ける。Float32Array への代入と同じく最近接へ丸める。
            let scaled = layout.float ? value : value * scale
            let f = Float(scaled)
            guard f.isFinite else { throw ETSFZPageError.format }
            out[i] = f
        }
    }

    private static func load16(_ b: UnsafeRawBufferPointer, _ at: Int, _ le: Bool) -> UInt16 {
        le ? UInt16(b[at]) | UInt16(b[at + 1]) << 8 : UInt16(b[at]) << 8 | UInt16(b[at + 1])
    }

    private static func load32(_ b: UnsafeRawBufferPointer, _ at: Int, _ le: Bool) -> UInt32 {
        if le {
            return UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
        }
        return UInt32(b[at]) << 24 | UInt32(b[at + 1]) << 16 | UInt32(b[at + 2]) << 8 | UInt32(b[at + 3])
    }

    private static func load64(_ b: UnsafeRawBufferPointer, _ at: Int, _ le: Bool) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<8 {
            let byte = UInt64(b[at + (le ? 7 - k : k)])
            v = v << 8 | byte
        }
        return v
    }

    // MARK: SF2

    /// high は Int16 LE が frames 個、low は sm24 の下位バイトが frames 個（無ければ nil）。
    static func convertSF2(high: UnsafeRawBufferPointer, low: UnsafeRawBufferPointer?, frames: Int,
                           into out: UnsafeMutablePointer<Float>) throws {
        guard frames >= 0, high.count >= frames * 2, low == nil || low!.count >= frames else { throw ETSFZPageError.range }
        for frame in 0..<frames {
            let raw = UInt16(high[frame * 2]) | UInt16(high[frame * 2 + 1]) << 8
            let h = Int(Int16(bitPattern: raw))
            if let low {
                // (high * 256 + low) / 8388608。分子は整数で、2^23 での割り算は丸めない。
                out[frame] = Float(Double(h * 256 + Int(low[frame])) / 8388608.0)
            } else {
                out[frame] = Float(Double(h) / 32768.0)
            }
        }
    }
}

// MARK: - 読み出し

/// ファイルの範囲を読む。開いたファイルを少しだけ覚える（ページごとに開き直さない）。**1 つのスレッドから使う。**
final class ETSFZFileReader {

    private var handles: [(path: String, handle: FileHandle)] = []
    private let limit: Int

    init(limit: Int = 16) { self.limit = max(1, limit) }

    deinit { closeAll() }

    func closeAll() {
        for entry in handles { try? entry.handle.close() }
        handles.removeAll()
    }

    private func handle(for url: URL) throws -> FileHandle {
        if let index = handles.firstIndex(where: { $0.path == url.path }) {
            // 最近使った順に並べ替える。
            let entry = handles.remove(at: index)
            handles.append(entry)
            return entry.handle
        }
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) } catch { throw ETSFZPageError.changed }
        handles.append((url.path, handle))
        if handles.count > limit {
            let evicted = handles.removeFirst()
            try? evicted.handle.close()
        }
        return handle
    }

    /// offset から length バイト。足りなければ changed（ファイルが縮んだ・差し替わった）。
    func read(url: URL, offset: UInt64, length: Int) throws -> Data {
        guard length >= 0, length <= ETSFZPageDecode.maxReadBytes else { throw ETSFZPageError.range }
        if length == 0 { return Data() }
        let file = try handle(for: url)
        let data: Data?
        do {
            try file.seek(toOffset: offset)
            data = try file.read(upToCount: length)
        } catch {
            throw ETSFZPageError.changed
        }
        guard let data, data.count == length else { throw ETSFZPageError.changed }
        return data
    }
}

extension ETSFZFileReader {

    /// offset から length バイトを 1 本の Data にして返す（SF3 の標本の Ogg。1 回の読みの上限 maxReadBytes ごとに区切って読む）。
    /// 足りなければ changed、上限（limit）を超えれば range。
    func readAll(url: URL, offset: UInt64, length: UInt64, limit: UInt64) throws -> Data {
        guard length <= limit, length <= UInt64(Int.max) else { throw ETSFZPageError.range }
        var data = Data()
        data.reserveCapacity(Int(length))
        var done: UInt64 = 0
        while done < length {
            let chunk = Int(min(UInt64(ETSFZPageDecode.maxReadBytes), length - done))
            data.append(try read(url: url, offset: offset + done, length: chunk))
            done += UInt64(chunk)
        }
        return data
    }
}

/// ページ 1 枚を、ファイルから作る（PCM と SF2）。FLAC などは unsupported。
final class ETSFZPageRenderer {

    private let reader: ETSFZFileReader

    init(reader: ETSFZFileReader = ETSFZFileReader()) { self.reader = reader }

    func close() { reader.closeAll() }

    /// page 番目のページを out へ書く。out は capacity 個以上の float（4096 × 2）。戻りは書いたフレーム数とチャンネル数。
    func render(_ source: ETSFZSampleSource, page: UInt64, into out: UnsafeMutablePointer<Float>,
                capacity: Int) throws -> (frames: Int, channels: Int) {
        guard source.channels >= 1, source.channels <= 2 else { throw ETSFZPageError.format }
        guard let frames = ETSFZPageDecode.framesInPage(page, totalFrames: source.frames) else { throw ETSFZPageError.range }
        guard frames * source.channels <= capacity else { throw ETSFZPageError.range }
        let first = page * UInt64(ETSFZPageDecode.pageFrames)
        switch source.format {
        case .pcm(let layout):
            guard layout.blockAlign == source.channels * layout.bitsPerSample / 8 else { throw ETSFZPageError.format }
            let start = source.baseOffset + layout.dataOffset + first * UInt64(layout.blockAlign)
            let data = try reader.read(url: source.url, offset: start, length: frames * layout.blockAlign)
            try data.withUnsafeBytes {
                try ETSFZPageDecode.decodePCM($0, layout: layout, channels: source.channels, into: out)
            }
        case .sf2PCM(let dataOffset, let lowByteOffset):
            // SF2 の標本は 1 チャンネル（ステレオは 2 本の標本で、engine が組む）。
            guard source.channels == 1 else { throw ETSFZPageError.format }
            let high = try reader.read(url: source.url, offset: source.baseOffset + dataOffset + first * 2, length: frames * 2)
            let low = try lowByteOffset.map {
                try reader.read(url: source.url, offset: source.baseOffset + $0 + first, length: frames)
            }
            try high.withUnsafeBytes { highBytes in
                if let low {
                    try low.withUnsafeBytes { try ETSFZPageDecode.convertSF2(high: highBytes, low: $0, frames: frames, into: out) }
                } else {
                    try ETSFZPageDecode.convertSF2(high: highBytes, low: nil, frames: frames, into: out)
                }
            }
        case .audioFile, .vorbis:
            throw ETSFZPageError.unsupported
        }
        return (frames, source.channels)
    }
}

// MARK: - 費用つきの LRU

/// 使った順に並べ、費用（バイト）の合計が上限を超えたら古い方から外す入れ物。SF3 の標本（復号器と復号済みの PCM）を持つ
/// ETSFZVorbisReader が使う。外した値は呼び手へ返す（閉じるのは呼び手）。**1 つのスレッドから使う。**
struct ETSFZBudgetCache<Key: Hashable, Value> {

    private var items: [Key: (value: Value, cost: Int)] = [:]
    /// 古い順（先頭が一番使っていない）。
    private(set) var order: [Key] = []
    let budget: Int

    init(budget: Int) { self.budget = max(0, budget) }

    var count: Int { items.count }
    var totalCost: Int { items.values.reduce(0) { $0 + $1.cost } }

    /// 見つかれば「いま使った」にして返す。
    mutating func use(_ key: Key) -> Value? {
        guard let item = items[key] else { return nil }
        touch(key)
        return item.value
    }

    /// 触らずに見る（復号器を持つ数を数えるときなど）。
    func peek(_ key: Key) -> Value? { items[key]?.value }

    /// 入れる（いま使った）。同じ鍵があれば置き換え、古い値を返す。
    mutating func insert(_ key: Key, _ value: Value, cost: Int) -> Value? {
        let old = items[key]?.value
        items[key] = (value, max(0, cost))
        touch(key)
        return old
    }

    /// 費用が変わった（復号が進んだ）。
    mutating func update(_ key: Key, cost: Int) {
        guard let item = items[key] else { return }
        items[key] = (item.value, max(0, cost))
    }

    /// 上限を超えていれば、古い方から外す。keeping（いま使っている 1 件）は外さない。外した値を古い順に返す。
    mutating func trim(keeping: Key) -> [Value] {
        var evicted: [Value] = []
        var total = totalCost
        var index = 0
        while total > budget, index < order.count {
            let key = order[index]
            if key == keeping { index += 1; continue }
            if let item = items.removeValue(forKey: key) {
                total -= item.cost
                evicted.append(item.value)
            }
            order.remove(at: index)
        }
        return evicted
    }

    mutating func remove(_ key: Key) -> Value? {
        guard let item = items.removeValue(forKey: key) else { return nil }
        order.removeAll { $0 == key }
        return item.value
    }

    /// 全部外す（古い順）。
    mutating func removeAll() -> [Value] {
        let all = order.compactMap { items[$0]?.value }
        items.removeAll()
        order.removeAll()
        return all
    }

    private mutating func touch(_ key: Key) {
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
        order.append(key)
    }
}

// MARK: - WAV / AIFF の頭

/// 上流 sample-stream.js の pcmMetadata の移植。WAV（PCM・IEEE float・WAVE_FORMAT_EXTENSIBLE）と AIFF / AIFC
/// （NONE・twos・sowt・fl32・fl64）の頭から、形とフレーム数を取る。
struct ETSFZPCMHeader: Equatable {
    var layout: ETSFZPCMLayout
    var channels: Int
    var sampleRate: Int
    var frames: UInt64

    /// read(offset, length) は範囲外なら range、短ければ changed を投げる読み手（ETSFZFileReader の薄い包み）。
    /// size は標本の全長。
    static func parse(size: UInt64, read: (UInt64, Int) throws -> Data) throws -> ETSFZPCMHeader {
        guard size >= 12 else { throw ETSFZPageError.format }
        let prefix = try read(0, 12)
        let signature = text(prefix, 0, 4)
        // 上流は RIFF と FORM だけを pcmMetadata へ回す（fLaC は別、ほかは sample-format）。
        guard signature == "RIFF" || signature == "FORM" else { throw ETSFZPageError.format }
        return try parse(size: size, prefix: prefix, wave: signature == "RIFF", read: read)
    }

    private static func text(_ data: Data, _ from: Int, _ to: Int) -> String {
        String(decoding: data.subdata(in: (data.startIndex + from)..<(data.startIndex + to)), as: UTF8.self)
    }

    // Data の添字は startIndex 起点とは限らないので、取り出しは byte(at:) 経由にする。
    private static func byte(_ d: Data, _ i: Int) -> UInt8 { d[d.startIndex + i] }
    private static func u16(_ d: Data, _ i: Int, le: Bool) -> Int {
        le ? Int(byte(d, i)) | Int(byte(d, i + 1)) << 8 : Int(byte(d, i)) << 8 | Int(byte(d, i + 1))
    }
    private static func u32(_ d: Data, _ i: Int, le: Bool) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<4 { v = v << 8 | UInt64(byte(d, i + (le ? 3 - k : k))) }
        return v
    }
    private static func u64be(_ d: Data, _ i: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<8 { v = v << 8 | UInt64(byte(d, i + k)) }
        return v
    }

    private static func parse(size: UInt64, prefix: Data, wave: Bool,
                              read: (UInt64, Int) throws -> Data) throws -> ETSFZPCMHeader {
        let kind = text(prefix, 8, 12)
        if wave { guard kind == "WAVE" else { throw ETSFZPageError.format } }
        else { guard kind == "AIFF" || kind == "AIFC" else { throw ETSFZPageError.format } }

        struct Format { var channels: Int; var sampleRate: Double; var blockAlign: Int; var bits: Int
            var float: Bool; var littleEndian: Bool; var unsigned: Bool; var frames: UInt64? }
        var format: Format?
        var data: (offset: UInt64, bytes: UInt64)?
        var offset: UInt64 = 12
        var count = 0
        while count < 1024, offset + 8 <= size {
            count += 1
            let header = try read(offset, 8)
            let tag = text(header, 0, 4)
            let length = u32(header, 4, le: wave)
            let start = offset + 8
            guard start + length <= size else { throw ETSFZPageError.format }
            if wave && tag == "fmt " {
                guard length >= 16 else { throw ETSFZPageError.format }
                let bytes = try read(start, Int(min(length, 40)))
                var code = u16(bytes, 0, le: true)
                if code == 0xfffe {
                    guard length >= 40, u16(bytes, 16, le: true) >= 22 else { throw ETSFZPageError.format }
                    code = u16(bytes, 24, le: true)
                    // KSDATAFORMAT_SUBTYPE の後ろ 14 バイト。
                    let guid: [UInt8] = [0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71]
                    guard (0..<14).allSatisfy({ byte(bytes, 26 + $0) == guid[$0] }) else { throw ETSFZPageError.format }
                }
                format = Format(channels: u16(bytes, 2, le: true), sampleRate: Double(u32(bytes, 4, le: true)),
                                blockAlign: u16(bytes, 12, le: true), bits: u16(bytes, 14, le: true),
                                float: code == 3, littleEndian: true, unsigned: true, frames: nil)
                guard code == 1 || code == 3 else { throw ETSFZPageError.format }
            } else if !wave && tag == "COMM" {
                let aifc = kind == "AIFC"
                guard length >= (aifc ? 22 : 18) else { throw ETSFZPageError.format }
                let bytes = try read(start, aifc ? 22 : 18)
                let exponent = u16(bytes, 8, le: false)
                let fraction = Double(u64be(bytes, 10))
                let compression = aifc ? text(bytes, 18, 22) : "NONE"
                guard ["NONE", "twos", "sowt", "fl32", "FL32", "fl64", "FL64"].contains(compression) else { throw ETSFZPageError.format }
                let channels = u16(bytes, 0, le: false)
                let bits = u16(bytes, 6, le: false)
                format = Format(channels: channels, sampleRate: scalbn(fraction, (exponent & 32767) - 16383 - 63),
                                blockAlign: channels * ((bits + 7) / 8), bits: bits, float: compression.lowercased().hasPrefix("fl"),
                                littleEndian: compression == "sowt", unsigned: false, frames: u32(bytes, 2, le: false))
                guard exponent & 32768 == 0 else { throw ETSFZPageError.format }
            } else if wave && tag == "data" {
                data = (start, length)
            } else if !wave && tag == "SSND" {
                guard length >= 8 else { throw ETSFZPageError.format }
                let bytes = try read(start, 8)
                let skip = u32(bytes, 0, le: false)
                guard skip <= length - 8 else { throw ETSFZPageError.format }
                data = (start + 8 + skip, length - 8 - skip)
            }
            if format != nil && data != nil { break }
            offset = start + length + (length & 1)
        }
        guard let f = format, let d = data,
              f.sampleRate == f.sampleRate.rounded(), f.sampleRate >= 1, f.sampleRate <= 768000,
              f.channels >= 1, f.channels <= 2, [8, 16, 24, 32, 64].contains(f.bits),
              !f.float || [32, 64].contains(f.bits), f.float || f.bits != 64,
              f.blockAlign == f.channels * f.bits / 8, f.blockAlign > 0, d.bytes % UInt64(f.blockAlign) == 0
        else { throw ETSFZPageError.format }
        let frames = d.bytes / UInt64(f.blockAlign)
        guard frames > 0, f.frames == nil || f.frames == frames else { throw ETSFZPageError.format }
        return ETSFZPCMHeader(
            layout: ETSFZPCMLayout(dataOffset: d.offset, blockAlign: f.blockAlign, bitsPerSample: f.bits, float: f.float,
                                   littleEndian: f.littleEndian, unsigned: f.unsigned),
            channels: f.channels, sampleRate: Int(f.sampleRate), frames: frames)
    }

    /// ファイルの先頭から頭を読んで、標本の入り口にする（baseOffset は書庫の中の位置）。
    static func source(url: URL, baseOffset: UInt64, size: UInt64, reader: ETSFZFileReader) throws -> ETSFZSampleSource {
        let header = try parse(size: size) { offset, length in
            guard offset + UInt64(length) <= size else { throw ETSFZPageError.range }
            return try reader.read(url: url, offset: baseOffset + offset, length: length)
        }
        return ETSFZSampleSource(url: url, baseOffset: baseOffset, format: .pcm(header.layout), frames: header.frames,
                                 channels: header.channels, sampleRate: header.sampleRate)
    }
}
