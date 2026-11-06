//  SFZPageDecodeTests.swift
//  流し込みの標本のページ（DSP/SFZStream/SFZPageDecode）。WAV / AIFF の頭の読みと PCM の float 化、SF2 の 16 bit + sm24 が、
//  上流の js/sfz/sample-stream.js（Tools/golden/sample_page_golden.mjs が作った見本）と 1 ビットまで同じ float になることを見る。
//  実機もエンジンも要らない。engine 側の受け渡しは Tests/Native/sample_stream.c が見る。

import XCTest

final class SFZPageDecodeTests: XCTestCase {

    // MARK: 見本

    private struct Page {
        var page: UInt64
        var frames: Int
        var channels: Int
        var bits: [UInt32]
    }

    private struct Case {
        var name: String
        var file: Data
        var error: String?
        var metadata: [String: Any]?
        var pages: [Page]
    }

    private static var cached: [Case]?

    private func cases() throws -> [Case] {
        if let cached = Self.cached { return cached }
        let url = try XCTUnwrap(TestResource.url("sample-page-golden", "json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let list = try XCTUnwrap(root["cases"] as? [[String: Any]])
        let result = try list.map { item -> Case in
            let pages = (item["pages"] as? [[String: Any]] ?? []).map { page -> Page in
                let raw = Data(base64Encoded: page["f32"] as? String ?? "") ?? Data()
                let bits = stride(from: 0, to: raw.count, by: 4).map { i in
                    UInt32(raw[i]) | UInt32(raw[i + 1]) << 8 | UInt32(raw[i + 2]) << 16 | UInt32(raw[i + 3]) << 24
                }
                return Page(page: UInt64(page["page"] as? Int ?? 0), frames: page["frames"] as? Int ?? 0,
                            channels: page["channels"] as? Int ?? 0, bits: bits)
            }
            return Case(name: try XCTUnwrap(item["name"] as? String),
                        file: try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(item["file"] as? String))),
                        error: item["error"] as? String, metadata: item["metadata"] as? [String: Any], pages: pages)
        }
        Self.cached = result
        return result
    }

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("SFZPageDecodeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// file を（prefix バイトの前置きをつけて）書いた URL。
    private func write(_ file: Data, prefix: Int = 0, name: String = UUID().uuidString) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try (Data(repeating: 0xA5, count: prefix) + file).write(to: url)
        return url
    }

    private func int(_ value: Any?) -> Int { (value as? Int) ?? (value as? NSNumber)?.intValue ?? -1 }

    /// 見本の頭の読みの答えを、こちらの形にする。
    private func source(for item: Case, url: URL, baseOffset: UInt64, reader: ETSFZFileReader) throws -> ETSFZSampleSource {
        let metadata = try XCTUnwrap(item.metadata, item.name)
        if metadata["format"] as? String == "sf2-pcm" {
            let low = metadata["lowByteOffset"] as? Int
            return ETSFZSampleSource(url: url, baseOffset: baseOffset,
                                     format: .sf2PCM(dataOffset: UInt64(int(metadata["dataOffset"])), lowByteOffset: low.map { UInt64($0) }),
                                     frames: UInt64(int(metadata["frames"])), channels: int(metadata["channels"]),
                                     sampleRate: int(metadata["sampleRate"]))
        }
        return try ETSFZPCMHeader.source(url: url, baseOffset: baseOffset, size: UInt64(item.file.count), reader: reader)
    }

    // MARK: 頭の読み

    func testHeaderMatchesUpstreamMetadata() throws {
        var checked = 0
        for item in try cases() where item.metadata?["format"] as? String == "pcm" {
            let metadata = try XCTUnwrap(item.metadata)
            let url = try write(item.file)
            let reader = ETSFZFileReader()
            let sample = try source(for: item, url: url, baseOffset: 0, reader: reader)
            guard case .pcm(let layout) = sample.format else { return XCTFail(item.name) }
            XCTAssertEqual(Int(sample.frames), int(metadata["frames"]), item.name)
            XCTAssertEqual(sample.channels, int(metadata["channels"]), item.name)
            XCTAssertEqual(sample.sampleRate, int(metadata["sampleRate"]), item.name)
            XCTAssertEqual(Int(layout.dataOffset), int(metadata["dataOffset"]), item.name)
            XCTAssertEqual(layout.blockAlign, int(metadata["blockAlign"]), item.name)
            XCTAssertEqual(layout.bitsPerSample, int(metadata["bitsPerSample"]), item.name)
            XCTAssertEqual(layout.float, metadata["float"] as? Bool, item.name)
            XCTAssertEqual(layout.littleEndian, metadata["littleEndian"] as? Bool, item.name)
            XCTAssertEqual(layout.unsigned, metadata["unsigned"] as? Bool, item.name)
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(checked, 15)
    }

    func testHeaderErrorsMatchUpstream() throws {
        var checked = 0
        for item in try cases() where item.error != nil {
            XCTAssertEqual(item.error, "sample-format", "上流の区別が変わった: \(item.name)")
            let url = try write(item.file)
            let reader = ETSFZFileReader()
            XCTAssertThrowsError(try ETSFZPCMHeader.source(url: url, baseOffset: 0, size: UInt64(item.file.count), reader: reader),
                                 item.name) { error in
                XCTAssertEqual(error as? ETSFZPageError, .format, item.name)
            }
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(checked, 8)
    }

    // MARK: ページ

    /// 見本の全ページが、ビットまで同じ。前置き（書庫の中の位置）を付けても同じ。
    func testPagesAreBitIdenticalToUpstream() throws {
        var pages = 0
        for item in try cases() where item.metadata != nil {
            for prefix in [0, 101] {
                let url = try write(item.file, prefix: prefix)
                let reader = ETSFZFileReader()
                let renderer = ETSFZPageRenderer(reader: reader)
                let sample = try source(for: item, url: url, baseOffset: UInt64(prefix), reader: reader)
                for expected in item.pages {
                    var out = [Float](repeating: .nan, count: ETSFZPageDecode.pageFrames * 2)
                    let result = try out.withUnsafeMutableBufferPointer {
                        try renderer.render(sample, page: expected.page, into: $0.baseAddress!, capacity: $0.count)
                    }
                    XCTAssertEqual(result.frames, expected.frames, "\(item.name) page \(expected.page)")
                    XCTAssertEqual(result.channels, expected.channels, "\(item.name) page \(expected.page)")
                    let count = result.frames * result.channels
                    XCTAssertEqual(expected.bits.count, count, item.name)
                    let got = out.prefix(count).map { $0.bitPattern }
                    if got != expected.bits {
                        let at = zip(got, expected.bits).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? -1
                        XCTFail("\(item.name) page \(expected.page) prefix \(prefix): first difference at \(at): "
                                + "\(at >= 0 ? got[at] : 0) vs \(at >= 0 ? expected.bits[at] : 0)")
                    }
                    // 書いた範囲の外には触らない。
                    XCTAssertTrue(out.dropFirst(count).allSatisfy { $0.isNaN }, "\(item.name): wrote past the page")
                    pages += 1
                }
            }
        }
        XCTAssertGreaterThanOrEqual(pages, 60)
    }

    func testFramesInPage() {
        XCTAssertEqual(ETSFZPageDecode.framesInPage(0, totalFrames: 10000), 4096)
        XCTAssertEqual(ETSFZPageDecode.framesInPage(1, totalFrames: 10000), 4096)
        XCTAssertEqual(ETSFZPageDecode.framesInPage(2, totalFrames: 10000), 1808)
        XCTAssertNil(ETSFZPageDecode.framesInPage(3, totalFrames: 10000))
        XCTAssertEqual(ETSFZPageDecode.framesInPage(0, totalFrames: 1), 1)
        XCTAssertNil(ETSFZPageDecode.framesInPage(1, totalFrames: 4096))
        XCTAssertNil(ETSFZPageDecode.framesInPage(0, totalFrames: 0))
        XCTAssertNil(ETSFZPageDecode.framesInPage(UInt64.max, totalFrames: UInt64.max))
        XCTAssertEqual(ETSFZPageDecode.framesInPage(UInt64(1) << 33, totalFrames: (UInt64(1) << 45) + 5), 5)
        XCTAssertEqual(ETSFZPageDecode.framesInPage(UInt64(1) << 33, totalFrames: (UInt64(1) << 45) + 9000), 4096)
    }

    // MARK: 断り方

    private func monoSource(_ item: Case, url: URL) throws -> ETSFZSampleSource {
        try source(for: item, url: url, baseOffset: 0, reader: ETSFZFileReader())
    }

    func testRendererRejectsWhatItCannotRead() throws {
        let item = try XCTUnwrap(try cases().first { $0.name == "wav16-stereo-odd-chunk" })
        let url = try write(item.file)
        var sample = try monoSource(item, url: url)
        var out = [Float](repeating: 0, count: 8192)
        let renderer = ETSFZPageRenderer()
        func render(_ sample: ETSFZSampleSource, page: UInt64, capacity: Int = 8192) throws -> (frames: Int, channels: Int) {
            try out.withUnsafeMutableBufferPointer { try renderer.render(sample, page: page, into: $0.baseAddress!, capacity: capacity) }
        }
        // 範囲外のページ。
        XCTAssertThrowsError(try render(sample, page: 2)) { XCTAssertEqual($0 as? ETSFZPageError, .range) }
        // 受け取る側が小さい。
        XCTAssertThrowsError(try render(sample, page: 0, capacity: 100)) { XCTAssertEqual($0 as? ETSFZPageError, .range) }
        // チャンネル数が語長と合わない（3 チャンネルは再生しない）。
        var bad = sample
        bad.channels = 3
        XCTAssertThrowsError(try render(bad, page: 0)) { XCTAssertEqual($0 as? ETSFZPageError, .format) }
        bad = sample
        bad.channels = 1   // blockAlign（4）は 1 チャンネル × 16 bit（2）と合わない
        XCTAssertThrowsError(try render(bad, page: 0)) { XCTAssertEqual($0 as? ETSFZPageError, .format) }
        // 読めない形式は unsupported（AVAudioFile の側が読む）。
        sample.format = .audioFile
        XCTAssertThrowsError(try render(sample, page: 0)) { XCTAssertEqual($0 as? ETSFZPageError, .unsupported) }
    }

    func testShortOrMissingFileIsChanged() throws {
        let item = try XCTUnwrap(try cases().first { $0.name == "wav16-mono" })
        let url = try write(item.file)
        let sample = try monoSource(item, url: url)
        // 縮んだファイル（最後のページが読めない）。
        try item.file.prefix(item.file.count - 50).write(to: url)
        var out = [Float](repeating: 0, count: 8192)
        let renderer = ETSFZPageRenderer()
        XCTAssertNoThrow(try out.withUnsafeMutableBufferPointer { try renderer.render(sample, page: 0, into: $0.baseAddress!, capacity: $0.count) })
        XCTAssertThrowsError(try out.withUnsafeMutableBufferPointer { try renderer.render(sample, page: 1, into: $0.baseAddress!, capacity: $0.count) }) {
            XCTAssertEqual($0 as? ETSFZPageError, .changed)
        }
        // 消えたファイル。
        let reader2 = ETSFZFileReader()
        XCTAssertThrowsError(try reader2.read(url: scratch.appendingPathComponent("nothing"), offset: 0, length: 4)) {
            XCTAssertEqual($0 as? ETSFZPageError, .changed)
        }
        XCTAssertThrowsError(try reader2.read(url: url, offset: 0, length: ETSFZPageDecode.maxReadBytes + 1)) {
            XCTAssertEqual($0 as? ETSFZPageError, .range)
        }
    }

    // MARK: 変換そのもの

    private func decode(_ bytes: [UInt8], bits: Int, channels: Int = 1, float: Bool = false, le: Bool = true,
                        unsigned: Bool = false) throws -> [Float] {
        let layout = ETSFZPCMLayout(dataOffset: 0, blockAlign: channels * bits / 8, bitsPerSample: bits, float: float,
                                    littleEndian: le, unsigned: unsigned)
        var out = [Float](repeating: 0, count: bytes.count / (bits / 8))
        try bytes.withUnsafeBytes { raw in
            try out.withUnsafeMutableBufferPointer { try ETSFZPageDecode.decodePCM(raw, layout: layout, channels: channels, into: $0.baseAddress!) }
        }
        return out
    }

    func testDecodePCMEdges() throws {
        XCTAssertEqual(try decode([0x00, 0x80, 0xFF, 0x7F, 0x00, 0x00, 0xFF, 0xFF], bits: 16), [-1, 32767 / 32768, 0, -1 / 32768])
        XCTAssertEqual(try decode([0x80, 0x80, 0xFF, 0x00], bits: 8, unsigned: true), [0, 0, 127 / 128, -128 / 128])
        XCTAssertEqual(try decode([0x80, 0x80, 0x7F, 0x00], bits: 8, unsigned: false), [-1, -1, 127 / 128, 0])
        XCTAssertEqual(try decode([0x00, 0x00, 0x80, 0xFF, 0xFF, 0x7F], bits: 24), [-1, 8388607 / 8388608])
        XCTAssertEqual(try decode([0x80, 0x00, 0x00, 0x7F, 0xFF, 0xFF], bits: 24, le: false), [-1, 8388607 / 8388608])
        XCTAssertEqual(try decode([0x00, 0x00, 0x00, 0x80, 0xFF, 0xFF, 0xFF, 0x7F], bits: 32), [-1, Float(Double(Int32.max) / 2147483648)])
        // 浮動小数はそのまま。
        XCTAssertEqual(try decode([0x00, 0x00, 0x80, 0x3F], bits: 32, float: true), [1])
        XCTAssertEqual(try decode([0x3F, 0x00, 0x00, 0x00, 0xC0, 0x00, 0x00, 0x00], bits: 64, float: true, le: false).count, 1)
        XCTAssertEqual(try decode([0x3F, 0xB9, 0x99, 0x99, 0x99, 0x99, 0x99, 0x9A], bits: 64, float: true, le: false), [Float(0.1)])
        XCTAssertEqual(try decode([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x3F], bits: 64, float: true), [1])
    }

    func testNonFiniteSamplesAreRefused() {
        // NaN・inf の float32。
        XCTAssertThrowsError(try decode([0x00, 0x00, 0xC0, 0x7F], bits: 32, float: true)) { XCTAssertEqual($0 as? ETSFZPageError, .format) }
        XCTAssertThrowsError(try decode([0x00, 0x00, 0x80, 0x7F], bits: 32, float: true)) { XCTAssertEqual($0 as? ETSFZPageError, .format) }
        // float64 が float32 に収まらない（上流は Float32Array へ入れて非有限になった時点で断る）。
        XCTAssertThrowsError(try decode([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x7E], bits: 64, float: true)) {
            XCTAssertEqual($0 as? ETSFZPageError, .format)
        }
        // float64 の NaN。
        XCTAssertThrowsError(try decode([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF8, 0x7F], bits: 64, float: true)) {
            XCTAssertEqual($0 as? ETSFZPageError, .format)
        }
    }

    func testDecodePCMRejectsBadLayouts() {
        let layout = ETSFZPCMLayout(dataOffset: 0, blockAlign: 4, bitsPerSample: 12, float: false, littleEndian: true, unsigned: false)
        var out = [Float](repeating: 0, count: 8)
        let bytes = [UInt8](repeating: 0, count: 8)
        XCTAssertThrowsError(try bytes.withUnsafeBytes { raw in
            try out.withUnsafeMutableBufferPointer { try ETSFZPageDecode.decodePCM(raw, layout: layout, channels: 2, into: $0.baseAddress!) }
        })
        // 端数のバイト（frame に満たない）。
        let ragged = ETSFZPCMLayout(dataOffset: 0, blockAlign: 4, bitsPerSample: 16, float: false, littleEndian: true, unsigned: false)
        XCTAssertThrowsError(try [UInt8](repeating: 0, count: 6).withUnsafeBytes { raw in
            try out.withUnsafeMutableBufferPointer { try ETSFZPageDecode.decodePCM(raw, layout: ragged, channels: 2, into: $0.baseAddress!) }
        })
    }

    func testSF2Conversion() throws {
        // high = -32768 / 32767 / -1 / 0、low = 0 / 255 / 255 / 1
        let high: [UInt8] = [0x00, 0x80, 0xFF, 0x7F, 0xFF, 0xFF, 0x00, 0x00]
        let low: [UInt8] = [0, 255, 255, 1]
        var out = [Float](repeating: 0, count: 4)
        try high.withUnsafeBytes { h in
            try low.withUnsafeBytes { l in
                try out.withUnsafeMutableBufferPointer { try ETSFZPageDecode.convertSF2(high: h, low: l, frames: 4, into: $0.baseAddress!) }
            }
        }
        XCTAssertEqual(out, [-8388608 / 8388608, Float(8388607) / 8388608, -1 / 8388608, 1 / 8388608])
        try high.withUnsafeBytes { h in
            try out.withUnsafeMutableBufferPointer { try ETSFZPageDecode.convertSF2(high: h, low: nil, frames: 4, into: $0.baseAddress!) }
        }
        XCTAssertEqual(out, [-1, 32767 / 32768, -1 / 32768, 0])
        // 足りないバイト。
        XCTAssertThrowsError(try high.withUnsafeBytes { h in
            try out.withUnsafeMutableBufferPointer { try ETSFZPageDecode.convertSF2(high: h, low: nil, frames: 5, into: $0.baseAddress!) }
        }) { XCTAssertEqual($0 as? ETSFZPageError, .range) }
    }

    // MARK: 読み手

    func testReaderKeepsFewHandlesAndStaysCorrect() throws {
        let reader = ETSFZFileReader(limit: 2)
        var urls: [URL] = []
        for i in 0..<5 { urls.append(try write(Data((0..<64).map { UInt8(($0 + i * 7) & 255) }), name: "f\(i)")) }
        // 上限を超えて開き直しても、中身は取り違えない。
        for round in 0..<3 {
            for (i, url) in urls.enumerated() {
                let data = try reader.read(url: url, offset: UInt64(round * 3), length: 8)
                XCTAssertEqual([UInt8](data), (0..<8).map { UInt8(($0 + round * 3 + i * 7) & 255) })
            }
        }
        reader.closeAll()
        XCTAssertEqual(try reader.read(url: urls[0], offset: 60, length: 4).count, 4)
        XCTAssertThrowsError(try reader.read(url: urls[0], offset: 62, length: 4)) { XCTAssertEqual($0 as? ETSFZPageError, .changed) }
    }
}
