//  SFZTests.swift
//  SFZ Note Player の取り込み（DSP/SFZParser・SFZBank・SFZAsset・SFZLibraryFiles）。
//  **見本は上流の js/sfz/*.js が作ったもの**（Tools/golden/sfz_golden.mjs → Tests/Fixtures/SFZ/sfz-golden.json）。
//  パーサの答え、バンクの入れ物と鍵（PC の EffeTune と同じ鍵になること）、資産のバイト列、予算への収め方、
//  フォルダの取り込み全体（鍵・バンク・資産）を、上流とバイトまで照合する。実機もエンジンも要らない。

import XCTest

final class SFZTests: XCTestCase {

    // MARK: 見本

    private static var cached: [String: Any]?

    private func golden() throws -> [String: Any] {
        if let cached = Self.cached { return cached }
        let url = try XCTUnwrap(TestResource.url("sfz-golden", "json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        Self.cached = object
        return object
    }

    private func list(_ key: String) throws -> [[String: Any]] {
        try XCTUnwrap(try golden()[key] as? [[String: Any]], key)
    }

    private func audio(_ name: String) throws -> Data {
        let all = try XCTUnwrap(try golden()["audio"] as? [String: String])
        return try XCTUnwrap(all[name].flatMap { Data(base64Encoded: $0) }, name)
    }

    /// 見本と同じ読み: 16 bit PCM の WAV を / 32768 で float に。
    static func decodeWAV(_ data: Data) throws -> ETSFZPCM {
        let b = [UInt8](data)
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        guard b.count >= 44 else { throw ETSFZError.prepare("not a WAV") }
        let channels = u16(22), rate = u32(24), bytes = u32(40)
        let frames = bytes / (channels * 2)
        var planes = [[Float]](repeating: [Float](repeating: 0, count: frames), count: channels)
        for f in 0..<frames {
            for c in 0..<channels {
                let raw = Int16(truncatingIfNeeded: u16(44 + (f * channels + c) * 2))
                planes[c][f] = Float(raw) / 32768
            }
        }
        return ETSFZPCM(channels: planes, sampleRate: rate)
    }

    static func inspectWAV(_ data: Data) -> (channels: Int, frames: Int)? {
        guard data.count >= 44 else { return nil }
        let b = [UInt8](data)
        let channels = Int(b[22]) | Int(b[23]) << 8
        let bytes = Int(b[40]) | Int(b[41]) << 8 | Int(b[42]) << 16 | Int(b[43]) << 24
        return channels > 0 ? (channels, bytes / (channels * 2)) : nil
    }

    private func region(_ dict: [String: Any]) -> ETSFZRegion {
        var r = ETSFZRegion(sample: dict["sample"] as! String, seqGroup: (dict["seqGroup"] as! NSNumber).intValue)
        for (key, value) in dict where key != "sample" && key != "seqGroup" {
            if let n = value as? NSNumber { r.set(key, n.doubleValue) }
        }
        return r
    }

    private func assertRegions(_ regions: [ETSFZRegion], _ expected: [[String: Any]], _ label: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(regions.count, expected.count, label, file: file, line: line)
        for (i, (mine, theirs)) in zip(regions, expected).enumerated() {
            XCTAssertEqual(mine.sample, theirs["sample"] as? String, "\(label)[\(i)] sample", file: file, line: line)
            XCTAssertEqual(mine.seqGroup, (theirs["seqGroup"] as? NSNumber)?.intValue, "\(label)[\(i)] seqGroup",
                           file: file, line: line)
            for (key, value) in theirs where key != "sample" && key != "seqGroup" {
                guard let n = value as? NSNumber else { continue }
                XCTAssertEqual(mine.value(key), n.doubleValue, "\(label)[\(i)].\(key)", file: file, line: line)
            }
            XCTAssertEqual(mine.end != nil, theirs["end"] is NSNumber, "\(label)[\(i)] end の有無", file: file, line: line)
            XCTAssertEqual(mine.loop_end != nil, theirs["loop_end"] is NSNumber, "\(label)[\(i)] loop_end の有無",
                           file: file, line: line)
        }
    }

    private func strings(_ value: Any?) -> [String] { (value as? [String]) ?? [] }

    // MARK: 道

    func testNormalizePathMatchesUpstream() throws {
        for item in try list("normalize") {
            let input = item["input"] as! String
            let directory = item["directory"] as? String ?? ""
            if let expected = item["expected"] as? String {
                XCTAssertEqual(try ETSFZParser.normalizePath(input, directory: directory), expected, input)
            } else {
                XCTAssertThrowsError(try ETSFZParser.normalizePath(input, directory: directory), input) {
                    XCTAssertEqual(($0 as? ETSFZError)?.code.rawValue, item["error"] as? String)
                }
            }
        }
    }

    // MARK: パーサ

    func testParserMatchesUpstream() throws {
        let sampleNames = Set((try XCTUnwrap(try golden()["audio"] as? [String: String])).keys)
        let cases = try list("parser")
        XCTAssertGreaterThanOrEqual(cases.count, 12)
        for item in cases {
            let name = item["name"] as! String
            let files = item["files"] as! [String: String]
            let expected = item["expected"] as! [String: Any]
            let maxBytes = (item["maxBytes"] as? NSNumber)?.intValue ?? ETSFZ.defaultMaxBytes
            let run = { try ETSFZParser.parse(selectedPath: item["selected"] as! String,
                                              readText: { files[$0] },
                                              hasSample: { sampleNames.contains($0) },
                                              maxBytes: maxBytes) }
            if let code = expected["error"] as? String {
                XCTAssertThrowsError(try run(), name) { error in
                    let e = error as? ETSFZError
                    XCTAssertEqual(e?.code.rawValue, code, name)
                    XCTAssertEqual(e?.message, expected["message"] as? String, name)
                }
                continue
            }
            let result = try run()
            assertRegions(result.regions, expected["regions"] as! [[String: Any]], name)
            XCTAssertEqual(result.dependencies, strings(expected["dependencies"]), "\(name) dependencies")
            let diag = expected["diagnostics"] as! [String: Any]
            XCTAssertEqual(result.diagnostics.ignoredOpcodes, strings(diag["ignoredOpcodes"]), "\(name) ignored")
            XCTAssertEqual(result.diagnostics.excludedOpcodes, strings(diag["excludedOpcodes"]), "\(name) excluded")
            XCTAssertEqual(result.diagnostics.missingSamples, strings(diag["missingSamples"]), "\(name) missing")
            XCTAssertEqual(result.diagnostics.invalidRegions, strings(diag["invalidRegions"]), "\(name) invalid")
            let warnings = (expected["warnings"] as! [[String: Any]]).map {
                ETSFZWarning(code: $0["code"] as! String, count: ($0["count"] as! NSNumber).intValue)
            }
            XCTAssertEqual(result.warnings, warnings, "\(name) warnings")
        }
    }

    func testJSNumberRules() {
        XCTAssertEqual(ETSFZ.jsNumber(" 12 "), 12)
        XCTAssertEqual(ETSFZ.jsNumber(""), 0)
        XCTAssertEqual(ETSFZ.jsNumber("1e3"), 1000)
        XCTAssertEqual(ETSFZ.jsNumber(".5"), 0.5)
        XCTAssertEqual(ETSFZ.jsNumber("5."), 5)
        XCTAssertEqual(ETSFZ.jsNumber("0x10"), 16)
        XCTAssertTrue(ETSFZ.jsNumber("1_0").isNaN)
        XCTAssertTrue(ETSFZ.jsNumber("12abc").isNaN)
        XCTAssertTrue(ETSFZ.jsNumber("nan").isNaN)
        XCTAssertEqual(ETSFZ.midi("c4"), 60)
        XCTAssertEqual(ETSFZ.midi("C#-1"), 1)
        XCTAssertEqual(ETSFZ.midi("db4"), 61)
        XCTAssertEqual(ETSFZ.midi("-3"), -3)
        XCTAssertTrue(ETSFZ.midi("h4").isNaN)
    }

    func testJSNumberString() {
        let cases: [(Double, String)] = [
            (0.001, "0.001"), (100, "100"), (0.5, "0.5"), (12.5, "12.5"), (1234.5678, "1234.5678"),
            (0.000001, "0.000001"), (1e-7, "1e-7"), (1.5e-7, "1.5e-7"), (1e21, "1e+21"),
            (123456789012345680000, "123456789012345680000"), (-0.25, "-0.25"), (0, "0"), (1e20, "100000000000000000000"),
        ]
        for (value, text) in cases { XCTAssertEqual(ETSFZBank.jsNumberString(value), text, text) }
    }

    func testJSONStringMatchesStringify() {
        XCTAssertEqual(ETSFZBank.jsonString("a\"b\\c/d"), "\"a\\\"b\\\\c/d\"")
        XCTAssertEqual(ETSFZBank.jsonString("é日本\u{2028}"), "\"é日本\u{2028}\"")
        XCTAssertEqual(ETSFZBank.jsonString("\n\t\r\u{08}\u{0C}\u{01}"), "\"\\n\\t\\r\\b\\f\\u0001\"")
    }

    func testSortFollowsUTF16Order() {
        // BMP の高い字（U+FF5E）は、補助面の字（U+1F600 = D83D DE00）より後ろ（UTF-16 の単位で比べる）。
        XCTAssertTrue(ETSFZ.jsLess("\u{1F600}", "\u{FF5E}"))
        XCTAssertFalse(ETSFZ.jsLess("b", "a"))
        XCTAssertTrue(ETSFZ.jsLess("a", "ab"))
    }

    // MARK: バンク

    func testBankContainerAndIdMatchUpstream() throws {
        for item in try list("bank") {
            let files = (item["files"] as! [String: String]).mapValues { Data(base64Encoded: $0)! }
            let warnings = (item["warnings"] as! [[String: Any]]).map {
                ETSFZWarning(code: $0["code"] as! String, count: ($0["count"] as! NSNumber).intValue)
            }
            let bank = try ETSFZBank.encode(selectedPath: item["selectedPath"] as! String, files: files,
                                            warnings: warnings)
            XCTAssertEqual(bank, Data(base64Encoded: item["container"] as! String), "入れ物がバイトまで同じ")
            XCTAssertEqual(ETSFZBank.identify(bank), item["id"] as? String, "鍵")
            XCTAssertEqual(try ETSFZBank.estimateBytes(selectedPath: item["selectedPath"] as! String,
                                                       sizes: files.mapValues(\.count)),
                           (item["estimate"] as! NSNumber).intValue)
            let decoded = try ETSFZBank.decode(bank)
            let expected = item["decoded"] as! [String: Any]
            XCTAssertEqual(decoded.selectedPath, expected["selectedPath"] as? String)
            XCTAssertEqual(decoded.warnings, warnings)
            XCTAssertEqual(Set(decoded.ranges.keys), Set(strings(expected["paths"])))
            for (path, data) in files {
                // 道は正規化される（\ は / になる）。
                XCTAssertEqual(decoded.file(try ETSFZParser.normalizePath(path)), data, path)
            }
        }
    }

    func testCorruptBanksAreRefused() throws {
        for item in try list("badBanks") {
            let bytes = Data(base64Encoded: item["bytes"] as! String)!
            XCTAssertThrowsError(try ETSFZBank.decode(bytes), item["name"] as! String) {
                XCTAssertEqual(($0 as? ETSFZError)?.code.rawValue, item["error"] as? String)
            }
        }
        XCTAssertThrowsError(try ETSFZBank.decode(Data(count: 5)))
        // 上限を越える入れ物は読まない。
        XCTAssertThrowsError(try ETSFZBank.decode(Data(count: 2000), maxBytes: 1000)) {
            XCTAssertEqual(($0 as? ETSFZError)?.code, .tooLarge)
        }
    }

    func testFolderListAndWarningMergeMatchUpstream() throws {
        let folder = try XCTUnwrap(try golden()["folder"] as? [String: Any])
        // 上流の見本は "root/" を取った道。
        let paths = strings(folder["paths"]).map { String($0.dropFirst("root/".count)) }
        XCTAssertEqual(try ETSFZBank.folderSFZPaths(paths), strings(folder["expected"]).map { $0 })
        XCTAssertThrowsError(try ETSFZBank.folderSFZPaths(["a.sfz", "./a.sfz"]))
        let merged = ETSFZBank.mergeWarnings(
            [ETSFZWarning(code: "invalid-regions", count: 2), ETSFZWarning(code: "reduced-bank", count: 1)],
            [ETSFZWarning(code: "invalid-regions", count: 5)],
            [ETSFZWarning(code: "loop-points-ignored", count: 1)])
        let expected = (try XCTUnwrap(try golden()["merged"] as? [[String: Any]])).map {
            ETSFZWarning(code: $0["code"] as! String, count: ($0["count"] as! NSNumber).intValue)
        }
        XCTAssertEqual(merged, expected)
    }

    // MARK: 資産

    func testAssetPayloadMatchesUpstreamByteForByte() throws {
        for item in try list("asset") {
            let name = item["name"] as! String
            let expected = item["expected"] as! [String: Any]
            var samples: [String: ETSFZPCM] = [:]
            for sample in item["samples"] as! [[String: Any]] {
                samples[sample["name"] as! String] = try Self.decodeWAV(Data(base64Encoded: sample["wav"] as! String)!)
            }
            let regions = (item["regions"] as! [[String: Any]]).map(region)
            let maxBytes = (item["maxBytes"] as? NSNumber)?.intValue ?? ETSFZ.defaultMaxBytes
            if let code = expected["error"] as? String {
                XCTAssertThrowsError(try ETSFZAsset.pack(regions, samples: samples, maxBytes: maxBytes), name) {
                    XCTAssertEqual(($0 as? ETSFZError)?.code.rawValue, code, name)
                    XCTAssertEqual(($0 as? ETSFZError)?.message, expected["message"] as? String, name)
                }
                continue
            }
            let packed = try ETSFZAsset.pack(regions, samples: samples, maxBytes: maxBytes)
            XCTAssertEqual(Data(packed.payload), Data(base64Encoded: expected["payload"] as! String), "\(name) payload")
            XCTAssertEqual(packed.footprintBytes, (expected["footprintBytes"] as! NSNumber).intValue, name)
            XCTAssertEqual(packed.floatCount, (expected["samples"] as! NSNumber).intValue, name)
            let warnings = (expected["warnings"] as! [[String: Any]]).map {
                ETSFZWarning(code: $0["code"] as! String, count: ($0["count"] as! NSNumber).intValue)
            }
            XCTAssertEqual(packed.warnings, warnings, name)
            // カーネルの検算（commitAsset）と同じ式で、頭を確かめる。
            let p = packed.payload
            func word(_ i: Int) -> UInt32 { UInt32(p[4 * i]) | UInt32(p[4 * i + 1]) << 8 | UInt32(p[4 * i + 2]) << 16 | UInt32(p[4 * i + 3]) << 24 }
            XCTAssertEqual(word(0), 0x3141_5445)
            XCTAssertEqual(word(2), UInt32(packed.floatCount))
            XCTAssertEqual(word(8), 0x53465A)
            XCTAssertEqual(word(9), 2)
            XCTAssertEqual(Int(word(10)), packed.regionCount)
            XCTAssertEqual(Int(word(11)), 30)
            XCTAssertEqual(Int(word(12)), 8 + 30 * packed.regionCount)
            XCTAssertEqual(p.count, 32 + 4 * packed.floatCount)
            XCTAssertEqual(Int(word(13)), packed.floatCount)
            XCTAssertEqual(ETSFZAsset.regionFields.count, 30)
        }
        XCTAssertEqual(try golden()["regionFields"] as? [String], ETSFZAsset.regionFields)
    }

    // MARK: 予算

    func testBudgetSelectionMatchesUpstream() throws {
        let budget = try XCTUnwrap(try golden()["budget"] as? [String: Any])
        let regions = (budget["regions"] as! [[String: Any]]).map(region)
        let metadata = (budget["metadata"] as! [String: [String: Any]]).mapValues {
            ETSFZSampleInfo(size: ($0["size"] as! NSNumber).intValue, frames: ($0["frames"] as! NSNumber).intValue,
                            channels: ($0["channels"] as! NSNumber).intValue)
        }
        let cases = budget["cases"] as! [[String: Any]]
        XCTAssertGreaterThanOrEqual(cases.count, 6)
        var reducedSeen = false
        for item in cases {
            let maxBytes = (item["maxBytes"] as! NSNumber).intValue
            let expected = item["expected"] as! [String: Any]
            if let code = expected["error"] as? String {
                XCTAssertThrowsError(try ETSFZBank.selectRegionsForBudget(regions, metadata: metadata, maxBytes: maxBytes,
                                                                          definitionBytes: 100), "\(maxBytes)") {
                    XCTAssertEqual(($0 as? ETSFZError)?.code.rawValue, code)
                }
                continue
            }
            let result = try ETSFZBank.selectRegionsForBudget(regions, metadata: metadata, maxBytes: maxBytes,
                                                              definitionBytes: 100)
            XCTAssertEqual(result.reduced, expected["reduced"] as? Bool, "\(maxBytes)")
            assertRegions(result.regions, expected["regions"] as! [[String: Any]], "予算 \(maxBytes)")
            if result.reduced {
                reducedSeen = true
                XCTAssertEqual(result.velocity, (expected["velocity"] as? NSNumber)?.intValue)
                XCTAssertEqual(result.keyCount, (expected["keyCount"] as? NSNumber)?.intValue)
            }
        }
        XCTAssertTrue(reducedSeen, "縮める場合が見本に入っていること")
    }

    // MARK: フォルダの取り込み全体

    private func writeFolder(_ folder: [String: [String: String]]) throws -> (URL, [ETSFZFolderFile]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sfz-test-\(UUID().uuidString)")
        var files: [ETSFZFolderFile] = []
        for (path, body) in folder {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data: Data = body["text"].map { Data($0.utf8) } ?? Data(base64Encoded: body["b64"] ?? "")!
            try data.write(to: url)
            files.append(ETSFZFolderFile(path: path, url: url, size: data.count))
        }
        return (root, files)
    }

    func testFolderImportMatchesUpstream() throws {
        let cases = try list("imports")
        XCTAssertGreaterThanOrEqual(cases.count, 8)
        var reduced = 0
        for item in cases {
            let name = item["name"] as! String
            let expected = item["expected"] as! [String: Any]
            let (root, files) = try writeFolder(item["folder"] as! [String: [String: String]])
            defer { try? FileManager.default.removeItem(at: root) }
            let maxBytes = (item["maxBytes"] as! NSNumber).intValue
            let run = {
                try ETSFZService.importFolder(
                    files: files, selectedPath: item["selected"] as! String, maxBytes: maxBytes,
                    decode: { data, _, _ in try Self.decodeWAV(data) },
                    inspect: { Self.inspectWAV((try? Data(contentsOf: $0)) ?? Data()) })
            }
            if let code = expected["error"] as? String {
                XCTAssertThrowsError(try run(), name) { error in
                    XCTAssertEqual((error as? ETSFZError)?.code.rawValue, code, name)
                    XCTAssertEqual((error as? ETSFZError)?.message, expected["message"] as? String, name)
                }
                continue
            }
            let result = try run()
            let entry = expected["entry"] as! [String: Any]
            XCTAssertEqual(result.id, entry["id"] as? String, "\(name) 鍵（PC の EffeTune と同じになること）")
            XCTAssertEqual(result.name, entry["name"] as? String, name)
            XCTAssertEqual(result.regionCount, (entry["regionCount"] as! NSNumber).intValue, name)
            XCTAssertEqual(result.bank, Data(base64Encoded: expected["bank"] as! String), "\(name) 入れ物")
            XCTAssertEqual(Data(result.prepared.asset.payload), Data(base64Encoded: expected["payload"] as! String),
                           "\(name) 資産")
            XCTAssertEqual(result.prepared.asset.footprintBytes, (expected["footprintBytes"] as! NSNumber).intValue, name)
            let warnings = (expected["warnings"] as! [[String: Any]]).map {
                ETSFZWarning(code: $0["code"] as! String, count: ($0["count"] as! NSNumber).intValue)
            }
            XCTAssertEqual(result.prepared.warnings, warnings, "\(name) 警告")
            if warnings.contains(where: { $0.code == "reduced-bank" }) { reduced += 1 }

            // 入れ物を読み直しても同じ資産になる（prepare(bank:)）。
            let again = try ETSFZService.prepare(bank: result.bank, decode: { data, _, _ in try Self.decodeWAV(data) },
                                                 maxBytes: maxBytes)
            XCTAssertEqual(Data(again.asset.payload), Data(result.prepared.asset.payload), "\(name) 読み直し")
            XCTAssertEqual(again.name, result.name)
            XCTAssertEqual(again.warnings, result.prepared.warnings, "\(name) 読み直しの警告")
        }
        XCTAssertGreaterThanOrEqual(reduced, 2, "縮めた取り込みが見本に入っていること")
    }

    // MARK: 置き場

    func testLibraryFilesRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sfz-lib-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ETSFZLibraryFiles(root: root)
        XCTAssertEqual(try library.readIndex(), [])
        let a = ETSFZLibraryEntry(id: "0123456789abcdef01234567", name: "Piano \"A\".sfz", regionCount: 12)
        let b = ETSFZLibraryEntry(id: "ffffffffffffffffffffffff", name: "é日本.sfz", regionCount: 1)
        try library.writeBank(a.id, Data([1, 2, 3]))
        try library.writeIndex(ETSFZLibraryFiles.sorted([b, a]))
        XCTAssertEqual(try library.readIndex(), [a, b])
        XCTAssertEqual(try library.readBank(a.id), Data([1, 2, 3]))
        XCTAssertNil(try library.readBank(b.id))
        XCTAssertNil(try library.readBank("not-an-id"))
        try library.removeBank(a.id)
        XCTAssertNil(try library.readBank(a.id))
        XCTAssertThrowsError(try library.removeBank("../escape"))
        // 壊れた index は storage の誤り。
        try Data("{\"version\":2,\"entries\":[]}".utf8).write(to: root.appendingPathComponent("index.json"))
        XCTAssertThrowsError(try library.readIndex()) { XCTAssertEqual(($0 as? ETSFZError)?.code, .storage) }
        try Data("{\"version\":1,\"entries\":[{\"id\":\"x\",\"name\":\"n\",\"regionCount\":1}]}".utf8)
            .write(to: root.appendingPathComponent("index.json"))
        XCTAssertThrowsError(try library.readIndex()) { XCTAssertEqual(($0 as? ETSFZError)?.code, .storage) }
    }

    func testIDShape() {
        XCTAssertTrue(ETSFZ.isValidID("0123456789abcdef01234567"))
        XCTAssertFalse(ETSFZ.isValidID("0123456789ABCDEF01234567"))
        XCTAssertFalse(ETSFZ.isValidID("0123456789abcdef0123456"))
        XCTAssertFalse(ETSFZ.isValidID(""))
    }
}
