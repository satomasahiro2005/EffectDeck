//  SFZPoolFillTests.swift
//  SFZ・SoundFont の PCM を staging へ直に書く道（DSP/SFZPoolFill）と、確保の見積りの純粋な部分（DSP/SFZPreparationRules）。
//  見本は上流の js/sfz/asset.js が書いた payload（Tests/Fixtures/SFZ/payloads/*.bin。Tools/golden/sfz_golden.mjs）。
//  上流の書き手（フレームごとにチャンネルを交互に並べる float 1 つずつの書き込み）と、バイトまで同じになることを見る。
//  実機もエンジンも要らない。エンジンへ聞く側は Tests/Native/sfz_admission.c が見る。

import XCTest

final class SFZPoolFillTests: XCTestCase {

    // MARK: 道具

    private func payload(_ name: String) throws -> [UInt8] {
        let url = try XCTUnwrap(TestResource.url(name, "bin", subdirectory: "payloads"), name)
        return [UInt8](try Data(contentsOf: url))
    }

    private func word(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
    }

    private func floats(_ bytes: [UInt8], from start: Int) -> [Float] {
        stride(from: start, to: bytes.count, by: 4).map { Float(bitPattern: UInt32(word(bytes, $0))) }
    }

    /// 4 バイト境界に置いた書き込み先（本物の staging は et_instance_asset_begin_ptr の返す、整列した領域）。
    private func withStaging<R>(bytes: [UInt8], _ body: (ETSFZPoolFill, UnsafeMutableRawBufferPointer) throws -> R) throws -> R {
        let raw = UnsafeMutableRawBufferPointer.allocate(byteCount: bytes.count, alignment: 16)
        defer { raw.deallocate() }
        raw.copyBytes(from: bytes)
        return try body(ETSFZPoolFill(staging: raw), raw)
    }

    /// 上流 asset.js の書き手と同じ手順（比べる相手）。
    private func reference(_ planes: [[Float]], frames: Int) -> [Float] {
        var out: [Float] = []
        for frame in 0..<frames { for plane in planes { out.append(plane[frame]) } }
        return out
    }

    private func prepareError(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) -> ETSFZError? {
        do { try body() } catch { return error as? ETSFZError }
        XCTFail("止まらなかった", file: file, line: line)
        return nil
    }

    // MARK: 書き手

    func testStereoInterleavesFrameByFrameAtOffset() throws {
        let left: [Float] = [1, 2, 3, 4], right: [Float] = [-1, -2, -3, -4]
        try withStaging(bytes: [UInt8](repeating: 0xAB, count: 32 + 4 * 16)) { fill, raw in
            XCTAssertNoThrow(try fill.write(floatOffset: 3, frames: 4, planes: [left, right]))
            let bytes = [UInt8](raw)
            XCTAssertEqual(floats(bytes, from: 32 + 4 * 3).prefix(8), [1, -1, 2, -2, 3, -3, 4, -4])
            // 外側の 32 バイトと、書いた範囲の前後には触れない。
            XCTAssertTrue(bytes[0..<(32 + 4 * 3)].allSatisfy { $0 == 0xAB })
            XCTAssertTrue(bytes[(32 + 4 * 11)...].allSatisfy { $0 == 0xAB })
        }
    }

    func testMonoAndThreeChannelsMatchTheUpstreamLoop() throws {
        for channels in [1, 2, 3, 4] {
            let frames = 37
            let planes = (0..<channels).map { c in (0..<frames).map { Float(c * 100 + $0) * 0.25 - 3 } }
            try withStaging(bytes: [UInt8](repeating: 0, count: 32 + 4 * (5 + frames * channels + 2))) { fill, raw in
                XCTAssertNoThrow(try fill.write(floatOffset: 5, frames: frames, planes: planes), "ch=\(channels)")
                XCTAssertEqual(Array(floats([UInt8](raw), from: 32 + 4 * 5).prefix(frames * channels)),
                               reference(planes, frames: frames), "ch=\(channels)")
            }
        }
    }

    func testNonFiniteValueStopsWithUpstreamText() throws {
        for bad in [Float.nan, .infinity, -.infinity] {
            for (channels, at) in [(1, 7), (2, 0), (2, 9)] {
                var planes = [[Float]](repeating: [Float](repeating: 0.5, count: 10), count: channels)
                planes[channels - 1][at] = bad
                try withStaging(bytes: [UInt8](repeating: 0, count: 32 + 4 * 40)) { fill, _ in
                    let error = prepareError { try fill.write(floatOffset: 0, frames: 10, planes: planes) }
                    XCTAssertEqual(error?.code, .prepare)
                    XCTAssertEqual(error?.message, "SFZ audio contains invalid samples.")
                }
            }
        }
    }

    func testShortPlaneIsInvalidSamplesLikeUndefinedInJS() throws {
        try withStaging(bytes: [UInt8](repeating: 0, count: 32 + 4 * 40)) { fill, _ in
            let error = prepareError { try fill.write(floatOffset: 0, frames: 10, planes: [[Float](repeating: 0, count: 10), [Float](repeating: 0, count: 9)]) }
            XCTAssertEqual(error?.message, "SFZ audio contains invalid samples.")
        }
    }

    func testWriteOutsideThePayloadIsRefusedAndNothingIsWritten() throws {
        let size = 32 + 4 * 8
        try withStaging(bytes: [UInt8](repeating: 0x11, count: size)) { fill, raw in
            // ちょうど収まるのは通り、1 float 超えるのは止まる。
            XCTAssertNoThrow(try fill.write(floatOffset: 4, frames: 4, planes: [[1, 1, 1, 1]]))
            for (offset, frames) in [(5, 4), (-1, 1), (0, 9), (Int.max, 2), (2, Int.max)] {
                let error = prepareError { try fill.write(floatOffset: offset, frames: frames, planes: [[Float](repeating: 1, count: max(0, min(frames, 16)))]) }
                XCTAssertEqual(error?.message, "The instrument preparation data is invalid.", "offset=\(offset) frames=\(frames)")
            }
            XCTAssertTrue([UInt8](raw)[0..<(32 + 4 * 4)].allSatisfy { $0 == 0x11 })
        }
    }

    func testEmptyWritesAreNoOps() throws {
        try withStaging(bytes: [UInt8](repeating: 0x22, count: 32)) { fill, raw in
            try fill.write(floatOffset: 0, frames: 0, planes: [[Float]()])
            try fill.write(floatOffset: 0, frames: 5, planes: [[Float]]())
            XCTAssertTrue([UInt8](raw).allSatisfy { $0 == 0x22 })
        }
    }

    /// 上流が書いた payload の PCM（プール）を 0 に潰して、面に分けて書き直すと、元のバイトに戻る。
    func testRefillingTheGoldenPoolReproducesUpstreamBytes() throws {
        for name in ["asset-two-samples", "imports-plain", "imports-wav-smpl-loop"] {
            let original = try payload(name)
            let poolStart = word(original, 48)               // u32@48 = PCM の始まり（外側の 32 バイトの後ろから数えた float）
            let poolFloats = (original.count - 32) / 4 - poolStart
            XCTAssertGreaterThan(poolFloats, 4, name)
            for channels in [1, 2] where poolFloats % channels == 0 {
                let frames = poolFloats / channels
                let pool = floats(original, from: 32 + 4 * poolStart)
                var planes = [[Float]](repeating: [], count: channels)
                for (index, value) in pool.enumerated() { planes[index % channels].append(value) }
                var wiped = original
                for index in (32 + 4 * poolStart)..<wiped.count { wiped[index] = 0 }
                try withStaging(bytes: wiped) { fill, raw in
                    XCTAssertNoThrow(try fill.write(floatOffset: poolStart, frames: frames, planes: planes), "\(name) ch=\(channels)")
                    XCTAssertEqual([UInt8](raw), original, "\(name) ch=\(channels)")
                }
            }
        }
    }

    // MARK: 制御の長さ

    func testControlBytesOfUpstreamPayloads() throws {
        for name in ["asset-two-samples", "asset-groups-and-offsets", "imports-plain", "imports-effects", "imports-script"] {
            let bytes = try payload(name)
            let control = try ETSFZPreparationRules.controlBytes(of: bytes)
            XCTAssertEqual(control, 32 + 4 * word(bytes, 48), name)
            XCTAssertLessThan(control, bytes.count, "\(name): 常駐の PCM が後ろに続く")
        }
        // ストリーミングの入れ物は表だけ。制御の部分が payload の全部。
        for name in ["streamed-streamed-load-opcodes", "streamed-streamed-effects", "streamed-streamed-generators"] {
            let bytes = try payload(name)
            XCTAssertEqual(try ETSFZPreparationRules.controlBytes(of: bytes), bytes.count, name)
        }
    }

    func testControlBytesRejectsBrokenPayloads() throws {
        let good = try payload("imports-plain")
        let invalid = "The instrument preparation data is invalid."
        func message(_ bytes: [UInt8]) -> String? {
            do { _ = try ETSFZPreparationRules.controlBytes(of: bytes) } catch { return (error as? ETSFZError)?.message }
            return nil
        }
        XCTAssertEqual(message([]), invalid)
        XCTAssertEqual(message(Array(good.prefix(52))), invalid)           // 56 未満
        XCTAssertEqual(message(Array(good.prefix(good.count - 1))), invalid) // 4 の倍数でない
        var wrongMagic = good; wrongMagic[0] ^= 1
        XCTAssertEqual(message(wrongMagic), invalid)
        var huge = good; huge[51] = 0xFF                                     // u32@48 を大きくして payload の外へ
        XCTAssertEqual(message(huge), invalid)
        var tiny = good; tiny[48] = 0; tiny[49] = 0; tiny[50] = 0; tiny[51] = 0   // 32 + 0 = 32 < 56
        XCTAssertEqual(message(tiny), invalid)
    }

    // MARK: 幾何と足し算

    func testGeometryValidationFollowsUpstream() throws {
        XCTAssertNoThrow(try ETSFZPreparationRules.Geometry(sampleRate: 48000, processingChannels: 2, maxFrames: 4096))
        XCTAssertNoThrow(try ETSFZPreparationRules.Geometry(sampleRate: 44100, processingChannels: 16, maxFrames: Int(UInt32.max),
                                                           minimumPhysicalBpm: 0, playerKind: .main))
        let audio = "The instrument audio configuration is unavailable. Try again after changing audio settings."
        let bad: [(Double, Int, Int)] = [(0, 2, 128), (-1, 2, 128), (.nan, 2, 128), (.infinity, 2, 128),
                                         (48000, 0, 128), (48000, 17, 128), (48000, 2, 0), (48000, 2, Int(UInt32.max) + 1)]
        for (rate, channels, frames) in bad {
            XCTAssertThrowsError(try ETSFZPreparationRules.Geometry(sampleRate: rate, processingChannels: channels, maxFrames: frames),
                                 "\(rate) \(channels) \(frames)") { XCTAssertEqual(($0 as? ETSFZError)?.message, audio) }
        }
        for bpm in [-1.0, .nan, .infinity] {
            XCTAssertThrowsError(try ETSFZPreparationRules.Geometry(sampleRate: 48000, processingChannels: 2, maxFrames: 128,
                                                                    minimumPhysicalBpm: bpm)) {
                XCTAssertEqual(($0 as? ETSFZError)?.message, "The instrument tempo configuration could not be prepared.")
            }
        }
    }

    func testPlayerKindFromTypeName() throws {
        XCTAssertEqual(try ETSFZPreparationRules.PlayerKind(typeName: "SFZNotePlayerPlugin"), .note)
        XCTAssertEqual(try ETSFZPreparationRules.PlayerKind(typeName: "SoundFontPlayerPlugin"), .main)
        XCTAssertThrowsError(try ETSFZPreparationRules.PlayerKind(typeName: "VolumePlugin"))
        XCTAssertEqual(ETSFZPreparationRules.PlayerKind.note.rawValue, 0)
        XCTAssertEqual(ETSFZPreparationRules.PlayerKind.main.rawValue, 1)
    }

    func testFootprintIsPayloadPlusAdditionalWithinTheLimit() throws {
        XCTAssertEqual(try ETSFZPreparationRules.footprint(payloadBytes: 1000, additionalBytes: 234, maxBytes: 1234), 1234)
        let tooLarge = "The instrument needs more memory for these audio settings. Increase the SoundFont size limit or choose another instrument."
        for (payload, extra, limit) in [(1000, UInt64(235), 1234), (1000, UInt64(1) << 40, 1 << 30),
                                        (Int(UInt32.max), UInt64(1), Int.max), (10, UInt64.max, Int.max)] {
            XCTAssertThrowsError(try ETSFZPreparationRules.footprint(payloadBytes: payload, additionalBytes: extra, maxBytes: limit)) {
                let error = $0 as? ETSFZError
                XCTAssertEqual(error?.code, .tooLarge)
                XCTAssertEqual(error?.message, tooLarge)
            }
        }
        // UInt32 ちょうどは通る。
        XCTAssertEqual(try ETSFZPreparationRules.footprint(payloadBytes: Int(UInt32.max) - 5, additionalBytes: 5, maxBytes: Int.max), UInt32.max)
    }
}
