//  SFZLoaderSupportTests.swift
//  SFZLoader の Foundation だけの部品（DSP/SFZLoaderSupport）と、それが頼る begin の引数（AssetUpload.beginRequest の
//  header 版）・見積りの規則（SFZPreparationRules）。見本は上流の js/sfz/asset.js が書いた payload
//  （Tests/Fixtures/SFZ/payloads/*.bin。Tools/golden/sfz_golden.mjs）。
//  JavaScriptCore・エンジン・AVFoundation を通る側は実機の CI（SFZScriptHostTests・Tests/Native/sfz_admission.c）が見る。

import XCTest

final class SFZLoaderSupportTests: XCTestCase {

    // MARK: 道具

    private func payload(_ name: String) throws -> [UInt8] {
        let url = try XCTUnwrap(TestResource.url(name, "bin", subdirectory: "payloads"), name)
        return [UInt8](try Data(contentsOf: url))
    }

    private func word(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
    }

    /// 制御の部分の長さ（上流 samplePlayerPreparationData）。流し込みの入れ物は payload 全体になる。
    private func controlLength(_ bytes: [UInt8]) -> Int { 32 + 4 * word(bytes, 48) }

    private func floats(_ bytes: ArraySlice<UInt8>) -> [Float] {
        let base = bytes.startIndex
        return stride(from: 0, to: bytes.count, by: 4).map { offset in
            Float(bitPattern: UInt32(bytes[base + offset]) | UInt32(bytes[base + offset + 1]) << 8
                | UInt32(bytes[base + offset + 2]) << 16 | UInt32(bytes[base + offset + 3]) << 24)
        }
    }

    private func withStaging<R>(count: Int, fill byte: UInt8 = 0xAB,
                                _ body: (UnsafeMutableRawBufferPointer) throws -> R) rethrows -> R {
        let raw = UnsafeMutableRawBufferPointer.allocate(byteCount: count, alignment: 16)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: byte)
        return try body(raw)
    }

    private let fixtures = ["asset-two-samples", "asset-groups-and-offsets", "imports-plain", "imports-effects",
                            "imports-aria-bank", "imports-generators-only", "migration-0.16-import-limit-6500",
                            "sf2-native-fixture", "streamed-streamed-effects"]

    // MARK: staging へ組む

    /// payload を「制御の部分」と「プールの float」に割り、JS の書き手の代わりに 1 区間（モノ）で戻す。
    /// 組み上がりは元の payload とバイトまで同じ（staging の初期値が 0xAB でも残りを 0 にするので、元が 0 の所は 0 になる）。
    func testControlPlusPoolRebuildsUpstreamPayloadByteForByte() throws {
        for name in fixtures {
            let original = try payload(name)
            let split = controlLength(original)
            XCTAssertLessThanOrEqual(split, original.count, name)
            let control = Data(original[0..<split])
            let pool = floats(original[split...])
            let entries = pool.isEmpty ? [] : [ETSFZPoolEntry(path: "x", floatOffset: (split - 32) / 4, frames: pool.count,
                                                              planes: [ETSFZPlane(pool)])]
            try withStaging(count: original.count) { staging in
                XCTAssertNoThrow(try ETSFZPayloadFill.fill(staging: staging, control: control, pool: entries), name)
                XCTAssertEqual([UInt8](staging), original, name)
            }
        }
    }

    /// frame 数（payload の頭の +8）は全部の見本で (全体 − 32) / 4。begin の frames を頭から読んでも sizeMismatch にならない前提。
    func testHeaderFramesAreWordCountForEveryFixture() throws {
        for name in fixtures {
            let bytes = try payload(name)
            XCTAssertEqual(32 + 4 * word(bytes, 8), bytes.count, name)
        }
    }

    func testStereoPlanesInterleaveAfterControl() throws {
        let original = try payload("asset-two-samples")
        let split = controlLength(original)
        let control = Data(original[0..<split])
        let left: [Float] = [1, 2, 3], right: [Float] = [-1, -2, -3]
        let total = split + 4 * 6
        try withStaging(count: total) { staging in
            let entry = ETSFZPoolEntry(path: "s", floatOffset: (split - 32) / 4, frames: 3,
                                       planes: [ETSFZPlane(left), ETSFZPlane(right)])
            try ETSFZPayloadFill.fill(staging: staging, control: control, pool: [entry])
            XCTAssertEqual(Array([UInt8](staging)[0..<split]), [UInt8](control))
            XCTAssertEqual(floats([UInt8](staging)[split...]), [1, -1, 2, -2, 3, -3])
        }
    }

    /// 書かれなかった float（区間の間・末尾）は 0。staging の初期値（0xAB）が残らない。
    func testUnwrittenPoolStaysZero() throws {
        let original = try payload("asset-two-samples")
        let split = controlLength(original)
        let control = Data(original[0..<split])
        let total = split + 4 * 8
        try withStaging(count: total) { staging in
            let entry = ETSFZPoolEntry(path: "s", floatOffset: (split - 32) / 4 + 2, frames: 2, planes: [ETSFZPlane([5, 6])])
            try ETSFZPayloadFill.fill(staging: staging, control: control, pool: [entry])
            XCTAssertEqual(floats([UInt8](staging)[split...]), [0, 0, 5, 6, 0, 0, 0, 0])
        }
    }

    /// 区間が順不同で渡されても、間と末尾だけが 0 になり、書いた所は消えない。
    func testOutOfOrderEntriesKeepWrittenFloatsAndZeroGaps() throws {
        let original = try payload("asset-two-samples")
        let split = controlLength(original)
        let control = Data(original[0..<split])
        let total = split + 4 * 10
        try withStaging(count: total) { staging in
            let base = (split - 32) / 4
            let later = ETSFZPoolEntry(path: "b", floatOffset: base + 6, frames: 2, planes: [ETSFZPlane([7, 8])])
            let earlier = ETSFZPoolEntry(path: "a", floatOffset: base + 1, frames: 2, planes: [ETSFZPlane([3, 4])])
            try ETSFZPayloadFill.fill(staging: staging, control: control, pool: [later, earlier])
            XCTAssertEqual(floats([UInt8](staging)[split...]), [0, 3, 4, 0, 0, 0, 7, 8, 0, 0])
        }
    }

    /// 区間が不正なら、staging を書かずに止める（半端に書いた形を残さない）。
    func testInvalidEntryLeavesStagingUntouched() throws {
        let original = try payload("asset-two-samples")
        let split = controlLength(original)
        let control = Data(original[0..<split])
        try withStaging(count: split + 8) { staging in
            let before = [UInt8](staging)
            let bad = ETSFZPoolEntry(path: "x", floatOffset: (split - 32) / 4 + 1, frames: 2, planes: [ETSFZPlane([1, 2])])
            XCTAssertThrowsError(try ETSFZPayloadFill.fill(staging: staging, control: control, pool: [bad]))
            XCTAssertEqual([UInt8](staging), before)
        }
    }

    func testPoolIntoControlOrOutsideIsRejected() throws {
        let original = try payload("asset-two-samples")
        let split = controlLength(original)
        let control = Data(original[0..<split])
        let total = split + 4 * 4
        try withStaging(count: total) { staging in
            // 制御の部分の中へ食い込む。
            let inside = ETSFZPoolEntry(path: "a", floatOffset: (split - 32) / 4 - 1, frames: 2, planes: [ETSFZPlane([1, 2])])
            XCTAssertThrowsError(try ETSFZPayloadFill.fill(staging: staging, control: control, pool: [inside])) {
                XCTAssertEqual(($0 as? ETSFZError)?.message, ETSFZPoolFill.invalidPayloadMessage)
            }
            // 末尾の外へ出る。
            let outside = ETSFZPoolEntry(path: "b", floatOffset: (split - 32) / 4 + 3, frames: 2, planes: [ETSFZPlane([1, 2])])
            XCTAssertThrowsError(try ETSFZPayloadFill.fill(staging: staging, control: control, pool: [outside])) {
                XCTAssertEqual(($0 as? ETSFZError)?.message, ETSFZPoolFill.invalidPayloadMessage)
            }
            // 負の位置。
            let negative = ETSFZPoolEntry(path: "c", floatOffset: -1, frames: 1, planes: [ETSFZPlane([1])])
            XCTAssertThrowsError(try ETSFZPayloadFill.fill(staging: staging, control: control, pool: [negative]))
        }
        // control が staging より大きい・32 バイトに満たない。
        try withStaging(count: split - 4) { staging in
            XCTAssertThrowsError(try ETSFZPayloadFill.fill(staging: staging, control: control, pool: []))
        }
        try withStaging(count: 64) { staging in
            XCTAssertThrowsError(try ETSFZPayloadFill.fill(staging: staging, control: Data(count: 16), pool: []))
        }
    }

    func testNonFinitePcmStopsWithUpstreamText() throws {
        let original = try payload("asset-two-samples")
        let split = controlLength(original)
        let control = Data(original[0..<split])
        try withStaging(count: split + 8) { staging in
            let entry = ETSFZPoolEntry(path: "n", floatOffset: (split - 32) / 4, frames: 2, planes: [ETSFZPlane([1, .nan])])
            XCTAssertThrowsError(try ETSFZPayloadFill.fill(staging: staging, control: control, pool: [entry])) {
                XCTAssertEqual(($0 as? ETSFZError)?.message, ETSFZPoolFill.invalidSamplesMessage)
            }
        }
    }

    // MARK: 覚え

    private func prepared(bytes: Int, id: String = "a") -> ETSFZScriptPrepared {
        ETSFZScriptPrepared(id: id, name: "n", format: nil, regionCount: 1, sampleCount: nil, tableVersion: 7, formatTag: 1,
                            control: Data(count: 32), payloadByteCount: bytes, poolEntries: [], warnings: [],
                            unsupportedOpcodes: [], unsupportedRuntime: [], incomplete: false, tailSeconds: nil,
                            warmupSamples: nil, footprintBytes: nil, nativePreparationBytes: nil, processingChannels: 2,
                            presentation: nil)
    }

    func testCacheIsKeyedByBankAndBundleSha() {
        var cache = ETSFZPreparedCache(limitBytes: 1000)
        let key = ETSFZPreparedCache.Key(bankID: "a", bundleSHA: "s1")
        XCTAssertNil(cache.get(key))
        XCTAssertTrue(cache.store(prepared(bytes: 500), for: key))
        XCTAssertEqual(cache.get(key)?.payloadByteCount, 500)
        // 束ねが変わった（JS を差し替えた版）と別のバンクは当たらない。
        XCTAssertNil(cache.get(ETSFZPreparedCache.Key(bankID: "a", bundleSHA: "s2")))
        XCTAssertNil(cache.get(ETSFZPreparedCache.Key(bankID: "b", bundleSHA: "s1")))
    }

    func testCacheDropsOverLimitAndForgetsRemoved() {
        var cache = ETSFZPreparedCache(limitBytes: 1000)
        let key = ETSFZPreparedCache.Key(bankID: "a", bundleSHA: "s")
        cache.store(prepared(bytes: 400), for: key)
        // 上限ちょうどは覚える。越えたら前の覚えも捨てる。
        XCTAssertTrue(cache.store(prepared(bytes: 1000), for: key))
        XCTAssertFalse(cache.store(prepared(bytes: 1001), for: key))
        XCTAssertNil(cache.get(key))
        cache.store(prepared(bytes: 10), for: key)
        cache.remove(bankID: "other")
        XCTAssertNotNil(cache.get(key))
        cache.remove(bankID: "a")
        XCTAssertNil(cache.get(key))
        cache.store(prepared(bytes: 10), for: key)
        cache.removeAll()
        XCTAssertNil(cache.get(key))
    }

    // MARK: 束ねの印

    func testBundleShaReadFromHeader() {
        let sha = String(repeating: "ab", count: 32)
        let header = "// effetune-sfz.js: x\n// pin: 1\n// esbuild: 0.28.2\n// sha256: \(sha)\nvar ETSFZ = 1\n"
        XCTAssertEqual(ETSFZBundleIdentity.sha(inHeader: header), sha)
        XCTAssertNil(ETSFZBundleIdentity.sha(inHeader: "var ETSFZ = 1"))
        XCTAssertNil(ETSFZBundleIdentity.sha(inHeader: "// sha256: ABC\n"), "桁と字が合わないものは採らない")
    }

    func testCommittedBundleCarriesSha() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Sources/EffeTuneLive/Resources/SFZ/effetune-sfz.js")
        let sha = ETSFZBundleIdentity.sha(ofBundleAt: url)
        XCTAssertEqual(sha.count, 64, "同梱の束ねの頭に sha256 の行がある")
        XCTAssertEqual(ETSFZBundleIdentity.sha(ofBundleAt: url.appendingPathExtension("missing")), "unknown")
    }

    // MARK: 音のファイルの型

    func testAudioSniffPicksExtensionFromMagic() {
        func data(_ text: String, at offset: Int = 0) -> Data {
            Data(repeating: 0, count: offset) + Data(text.utf8) + Data(repeating: 0, count: 8)
        }
        XCTAssertEqual(ETSFZAudioSniff.fileExtension(for: data("RIFF")), "wav")
        XCTAssertEqual(ETSFZAudioSniff.fileExtension(for: data("RF64")), "wav")
        XCTAssertEqual(ETSFZAudioSniff.fileExtension(for: Data("FORM".utf8) + Data(count: 4) + Data("AIFF".utf8)), "aif")
        XCTAssertEqual(ETSFZAudioSniff.fileExtension(for: Data("FORM".utf8) + Data(count: 4) + Data("AIFC".utf8)), "aifc")
        XCTAssertEqual(ETSFZAudioSniff.fileExtension(for: data("fLaC")), "flac")
        XCTAssertEqual(ETSFZAudioSniff.fileExtension(for: data("OggS")), "ogg")
        XCTAssertEqual(ETSFZAudioSniff.fileExtension(for: data("caff")), "caf")
        XCTAssertEqual(ETSFZAudioSniff.fileExtension(for: data("ftyp", at: 4)), "m4a")
        XCTAssertEqual(ETSFZAudioSniff.fileExtension(for: data("ID3")), "mp3")
        XCTAssertEqual(ETSFZAudioSniff.fileExtension(for: Data([0xFF, 0xFB, 0x90, 0x00])), "mp3")
        XCTAssertEqual(ETSFZAudioSniff.fileExtension(for: Data()), "wav")
        XCTAssertEqual(ETSFZAudioSniff.fileExtension(for: Data([1, 2, 3])), "wav")
    }

    // MARK: commit の後の見張り

    func testAssetWatchVerdicts() {
        XCTAssertEqual(ETSFZAssetWatch.verdict(ETAssetStatus(raw: 3)), .active)
        XCTAssertEqual(ETSFZAssetWatch.verdict(ETAssetStatus(raw: 2)), .waiting)
        XCTAssertEqual(ETSFZAssetWatch.verdict(ETAssetStatus(raw: 1)), .waiting)
        XCTAssertEqual(ETSFZAssetWatch.verdict(ETAssetStatus(raw: 0)), .gone)
        // ERROR。reason 2（確保できなかった）は too-large、1（commit で弾かれた）・3 は prepare。
        XCTAssertEqual(ETSFZAssetWatch.verdict(ETAssetStatus(raw: 4 | 2 << 8)), .failed(.tooLarge))
        XCTAssertEqual(ETSFZAssetWatch.verdict(ETAssetStatus(raw: 4 | 1 << 8)), .failed(.prepare))
        XCTAssertEqual(ETSFZAssetWatch.verdict(ETAssetStatus(raw: 4 | 3 << 8)), .failed(.prepare))
        XCTAssertEqual(ETSFZAssetWatch.verdict(ETAssetStatus(raw: 4)), .failed(.prepare))
    }

    // MARK: 見積りの規則

    func testControlBytesFromControlOnly() throws {
        for name in fixtures {
            let original = try payload(name)
            let split = controlLength(original)
            let control = [UInt8](original[0..<split])
            XCTAssertEqual(try ETSFZPreparationRules.controlBytes(of: control, payloadBytes: original.count), split, name)
            // 全体を渡す版と同じ値。
            XCTAssertEqual(try ETSFZPreparationRules.controlBytes(of: original), split, name)
        }
        let original = try payload("imports-plain")
        let control = [UInt8](original[0..<controlLength(original)])
        // payload 全体が control より短い・4 の倍数でない・UInt32 に入らないものは止める。
        XCTAssertThrowsError(try ETSFZPreparationRules.controlBytes(of: control, payloadBytes: control.count - 4))
        XCTAssertThrowsError(try ETSFZPreparationRules.controlBytes(of: control, payloadBytes: control.count + 2))
        XCTAssertThrowsError(try ETSFZPreparationRules.controlBytes(of: control, payloadBytes: Int(UInt32.max) + 1))
    }

    func testScriptGeometryMapsToNativeGeometry() throws {
        let value = ETSFZGeometry(sampleRate: 48000, processingChannels: 2, maxFrames: 4096, minimumPhysicalBpm: 0, playerKind: 0)
        let native = try ETSFZPreparationRules.geometry(value)
        XCTAssertEqual(native.sampleRate, 48000)
        XCTAssertEqual(native.processingChannels, 2)
        XCTAssertEqual(native.maxFrames, 4096)
        XCTAssertEqual(native.playerKind, .note)
        var main = value
        main.playerKind = 1
        XCTAssertEqual(try ETSFZPreparationRules.geometry(main).playerKind, .main)
        var bads: [ETSFZGeometry] = []
        for change in [{ (v: inout ETSFZGeometry) in v.playerKind = 2 }, { $0.playerKind = -1 },
                       { $0.processingChannels = 0 }, { $0.processingChannels = 17 },
                       { $0.maxFrames = 0 }, { $0.sampleRate = .nan }] as [(inout ETSFZGeometry) -> Void] {
            var v = value
            change(&v)
            bads.append(v)
        }
        for bad in bads {
            XCTAssertThrowsError(try ETSFZPreparationRules.geometry(bad)) { XCTAssertTrue($0 is ETSFZError) }
        }
    }

    // MARK: begin の引数（header 版）

    private func info(_ footprint: UInt32, proc: UInt32 = 2) -> AssetUpload.BeginInfo {
        AssetUpload.BeginInfo(channels: 1, frames: nil, topology: .unspecified, headBlock: 128, rateDivider: 1,
                              pathCount: 0, inputCount: 0, processingChannels: proc, footprintBytes: footprint)
    }

    func testHeaderBeginRequestMatchesPayloadBeginRequest() throws {
        for name in fixtures {
            let original = try payload(name)
            let footprint = UInt32(original.count + 4096)
            let whole = try AssetUpload.beginRequest(engine: 1, instance: 2, payload: original, info: info(footprint, proc: 4),
                                                     capacity: ETSFZ.maxSupportedBytes)
            let header = try AssetUpload.beginRequest(engine: 1, instance: 2, header: Array(original.prefix(32)),
                                                      byteCount: original.count, info: info(footprint, proc: 4),
                                                      capacity: ETSFZ.maxSupportedBytes)
            XCTAssertEqual(whole, header, name)
            // frames は payload の頭から読む。processingChannels は渡した値のまま（見積りと同じ値を入れる）。
            XCTAssertEqual(header.frames, UInt32(word(original, 8)), name)
            XCTAssertEqual(header.channels, 1, name)
            XCTAssertEqual(header.processingChannels, 4, name)
            XCTAssertEqual(header.byteSize, UInt32(original.count), name)
            XCTAssertEqual(header.footprintBytes, footprint, name)
        }
    }

    func testHeaderBeginRequestRejectsWrongSizesAndHeaders() throws {
        let original = try payload("imports-plain")
        let header = Array(original.prefix(32))
        let footprint = UInt32(original.count + 4096)
        func request(header: [UInt8], byteCount: Int, footprint: UInt32 = footprint) throws -> AssetUpload.BeginRequest {
            try AssetUpload.beginRequest(engine: 1, instance: 2, header: header, byteCount: byteCount,
                                         info: info(footprint), capacity: ETSFZ.maxSupportedBytes)
        }
        // 全体の長さが頭の frames と合わない。
        XCTAssertThrowsError(try request(header: header, byteCount: original.count + 4)) {
            guard case ETAssetUploadError.sizeMismatch = $0 else { return XCTFail("\($0)") }
        }
        // footprint が payload より小さい・上限を越える。
        XCTAssertThrowsError(try request(header: header, byteCount: original.count, footprint: UInt32(original.count - 4))) {
            guard case ETAssetUploadError.tooLarge = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try AssetUpload.beginRequest(engine: 1, instance: 2, header: header, byteCount: original.count,
                                                          info: info(footprint), capacity: original.count)) {
            guard case ETAssetUploadError.tooLarge = $0 else { return XCTFail("\($0)") }
        }
        // 頭が足りない・magic が違う・engine が無い。
        XCTAssertThrowsError(try request(header: Array(header.prefix(16)), byteCount: original.count)) {
            guard case ETAssetUploadError.payloadTooShort = $0 else { return XCTFail("\($0)") }
        }
        var bad = header
        bad[0] ^= 0xFF
        XCTAssertThrowsError(try request(header: bad, byteCount: original.count)) {
            guard case ETAssetUploadError.badMagic = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try AssetUpload.beginRequest(engine: 0, instance: 2, header: header, byteCount: original.count,
                                                          info: info(footprint))) {
            guard case ETAssetUploadError.engineNotReady = $0 else { return XCTFail("\($0)") }
        }
    }

    // MARK: 置き場を JS の口にそろえる

    private func makeAdapter() throws -> (ETSFZScriptBackendAdapter, ETSFZLibraryBackend, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sfz-adapter-" + UUID().uuidString)
        let backend = ETSFZLibraryBackend(root: root)
        return (ETSFZScriptBackendAdapter(backend: backend), backend, root)
    }

    private let idA = "0123456789abcdef01234567"

    func testAdapterReadsWritesAndRemoves() throws {
        let (adapter, _, root) = try makeAdapter()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(try adapter.read("index.json"))
        try adapter.writeAtomic("index.json", Data("{}".utf8))
        XCTAssertEqual(try adapter.read("index.json"), Data("{}".utf8))
        try adapter.writeAtomic(idA + ".sfzbank", Data(repeating: 7, count: 100))
        let file = try XCTUnwrap(try adapter.readSfzBankFile(idA + ".sfzbank"))
        XCTAssertEqual(file.size, 100)
        XCTAssertEqual(file.path, idA + ".sfzbank")
        XCTAssertGreaterThan(file.lastModified, 0, "更新時刻はミリ秒（JS の File.lastModified）")
        try adapter.remove(idA + ".sfzbank")
        XCTAssertNil(try adapter.readSfzBankFile(idA + ".sfzbank"))
        try adapter.cleanupTemporary()
    }

    func testAdapterTurnsBackendFailuresIntoCodedErrors() throws {
        let (adapter, _, root) = try makeAdapter()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try adapter.read("../index.json")) {
            XCTAssertEqual(($0 as? ETSFZError)?.code, .storage)
        }
        XCTAssertThrowsError(try adapter.writeSfzBankFile(idA + ".sfzbank", segments: [.bytes(Data(repeating: 1, count: 64))],
                                                          isCurrent: { false })) {
            XCTAssertEqual(($0 as? ETSFZError)?.code, .cancelled)
        }
        // 取り消しで書きかけを残さない。
        XCTAssertNil(try adapter.read(idA + ".sfzbank"))
        XCTAssertEqual(ETSFZScriptBackendAdapter.map(ETSFZBackendError.tooLarge) as? ETSFZError,
                       ETSFZError(code: .tooLarge, message: "The SFZ bank is too large to load."))
        XCTAssertEqual((ETSFZScriptBackendAdapter.map(ETSFZBackendError.io("disk")) as? ETSFZError)?.code, .storage)
        // 既に ETSFZError ならそのまま。
        let known = ETSFZError(code: .noRegions, message: "x")
        XCTAssertEqual(ETSFZScriptBackendAdapter.map(known) as? ETSFZError, known)
    }

    /// 入れ物の書き込みは部分をつなぐ。ファイルの範囲は元のファイルから直に写る（JS を通さない）。
    func testAdapterWritesSegmentsFromBytesAndFileRanges() throws {
        let (adapter, _, root) = try makeAdapter()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.bin")
        let body = Data((0..<5000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        try body.write(to: source)
        let head = Data("SFZBANK\u{1}0123".utf8)
        try adapter.writeSfzBankFile(idA + ".sfzbank",
                                     segments: [.bytes(head), .fileRange(url: source, offset: 100, length: 3000), .bytes(Data([9]))],
                                     isCurrent: { true })
        XCTAssertEqual(try adapter.read(idA + ".sfzbank"), head + body[100..<3100] + Data([9]))
    }

    // MARK: 送る前の確かめ（上流の validatePreparedSfzBank）

    func testRequireCompleteAcceptsCleanBank() throws {
        try ETSFZPreparedCheck.requireComplete(unsupportedOpcodes: [], unsupportedRuntime: [], incomplete: false)
    }

    func testRequireCompleteRejectsUnsupportedOrIncompleteBank() {
        let cases: [([String], [String], Bool)] = [(["foo"], [], false), ([], ["effects"], false), ([], [], true)]
        for (opcodes, runtime, incomplete) in cases {
            XCTAssertThrowsError(try ETSFZPreparedCheck.requireComplete(
                unsupportedOpcodes: opcodes, unsupportedRuntime: runtime, incomplete: incomplete)) { error in
                let known = error as? ETSFZError
                XCTAssertEqual(known?.code, .unsupportedRuntime)
                XCTAssertEqual(known?.message, ETSFZMessages.error("unsupported-runtime"))
            }
        }
    }

    func testStreamedPayloadNeedsSampleSources() throws {
        for version in [8, 9, 10] {
            XCTAssertThrowsError(try ETSFZPreparedCheck.requireStreamSources(tableVersion: version, hasSources: false)) { error in
                XCTAssertEqual((error as? ETSFZError)?.message, ETSFZPreparedCheck.preparationFailedMessage)
            }
            try ETSFZPreparedCheck.requireStreamSources(tableVersion: version, hasSources: true)
        }
        // 常駐の資産（v6・v7）は標本の表が無くてよい
        for version in [6, 7] { try ETSFZPreparedCheck.requireStreamSources(tableVersion: version, hasSources: false) }
    }
}
