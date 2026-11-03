//  AssetPayloadTests.swift
//  資産（ETA1ペイロード）・確保の見積り・beginの引数（DSP/AssetPayload.swift）。**実機もエンジンも要らない。**
//
//  約束は2つ。
//    1. 上流と同じバイト・同じ見積りになる。見本は上流のJSそのものが吐いたもの
//       （Tests/Fixtures/Asset/asset-golden.json。作り直すときは
//       `EFFETUNE_ROOT=$(bash Tools/golden/extract_pin.sh) node Tools/golden/asset_golden.mjs`）。
//       見積りがずれると、カーネルが資産を断る（"refused the asset"）か、IRが要る以上に短く切られる
//    2. 弾くものを送る前に全部弾き、理由を取り違えない（NaNを「チャンネルの大きさ」と言わない）
//
//  AssetPayload.swiftとIRPreparation.swift（ETAssetTopology・ETAssetPath）をバンドルへ入れる。

import XCTest
import Foundation

final class AssetPayloadTests: XCTestCase {

    // MARK: - 見本

    private struct Golden: Decodable {
        let capacityBytes: Int
        let payloads: [Payload]
        let footprints: Table
        let maximumFrames: Table
        let stages: [Stages]

        struct Payload: Decodable {
            let name: String
            let channels: [String]
            let sampleRate: Int
            let topology: UInt32
            let paths: [[UInt32]]
            let payload: String
        }

        struct Table: Decodable {
            let columns: [String]
            let rows: [[Int]]
        }

        struct Stages: Decodable {
            let frames: Int
            let headBlock: Int
            let stages: [[Int]]
        }
    }

    private func golden() throws -> Golden {
        let file = try XCTUnwrap(TestResource.url("asset-golden", "json"))
        return try JSONDecoder().decode(Golden.self, from: Data(contentsOf: file))
    }

    /// float32のリトルエンディアンをbase64にしたもの。
    private static func floats(_ base64: String) throws -> [Float] {
        let bytes = [UInt8](try XCTUnwrap(Data(base64Encoded: base64)))
        XCTAssertEqual(bytes.count % 4, 0)
        return (0..<bytes.count / 4).map { Float(bitPattern: le32(bytes, 4 * $0)) }
    }

    private static func le32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    /// 投げた失敗のcaseの名前（関連値の手前まで）。ETAssetUploadErrorはEquatableでないので名前で比べる。
    private static func kind(_ error: Error) -> String {
        let text = String(describing: error)
        return text.split(separator: "(", maxSplits: 1).first.map(String.init) ?? text
    }

    private func assertThrows(_ expected: String,
                              _ message: String = "",
                              file: StaticString = #filePath,
                              line: UInt = #line,
                              _ body: () throws -> Any) {
        XCTAssertThrowsError(try body(), message, file: file, line: line) { error in
            XCTAssertTrue(error is ETAssetUploadError, "\(error)", file: file, line: line)
            XCTAssertEqual(Self.kind(error), expected, message, file: file, line: line)
        }
    }

    private static func column(_ table: Golden.Table, _ name: String) throws -> Int {
        try XCTUnwrap(table.columns.firstIndex(of: name), "列 \(name) が無い")
    }

    // MARK: - ペイロード

    /// 頭の32バイトはリトルエンディアンで、magic・チャンネル数・長さ・レート・topology・経路数・0・0。
    func testHeaderLE32Bytes() throws {
        let payload = try AssetUpload.makePayload(channels: [[0.5, -0.5, 0.25], [1, 2, 3]],
                                                  sampleRate: 0x0102_0304,
                                                  topology: .independent)
        XCTAssertEqual(payload.count, 32 + 2 * 3 * 4)
        XCTAssertEqual(Array(payload[0..<4]), [0x45, 0x54, 0x41, 0x31])  // "ETA1"
        XCTAssertEqual(Self.le32(payload, 0), AssetUpload.magic)
        XCTAssertEqual(Self.le32(payload, 4), 2)
        XCTAssertEqual(Self.le32(payload, 8), 3)
        XCTAssertEqual(Array(payload[12..<16]), [0x04, 0x03, 0x02, 0x01])
        XCTAssertEqual(Self.le32(payload, 16), ETAssetTopology.independent.rawValue)
        XCTAssertEqual(Self.le32(payload, 20), 0)
        XCTAssertEqual(Array(payload[24..<32]), [0, 0, 0, 0, 0, 0, 0, 0])

        let matrix = try AssetUpload.makePayload(
            channels: [[1], [2]], sampleRate: 48000, topology: .matrix,
            paths: [ETAssetPath(inputSlot: 7, outputSlot: 0x0A0B_0C0D, irChannel: 1)])
        XCTAssertEqual(matrix.count, 32 + 12 + 2 * 4)
        XCTAssertEqual(Self.le32(matrix, 20), 1)
        XCTAssertEqual(Self.le32(matrix, 32), 7)
        XCTAssertEqual(Array(matrix[36..<40]), [0x0D, 0x0C, 0x0B, 0x0A])
        XCTAssertEqual(Self.le32(matrix, 40), 1)
    }

    /// 係数はチャンネルごとに並ぶ（ch0の全部、その後ch1）。交互には置かない。
    func testSamplesPlanar() throws {
        let left: [Float] = [1, 2, 3, 4]
        let right: [Float] = [-1, -2, -3, -4]
        let payload = try AssetUpload.makePayload(channels: [left, right], sampleRate: 48000)
        let body = (0..<8).map { Float(bitPattern: Self.le32(payload, 32 + 4 * $0)) }
        XCTAssertEqual(body, left + right)
        // -0のビットも落とさない。
        let signed = try AssetUpload.makePayload(channels: [[-0.0]], sampleRate: 1)
        XCTAssertEqual(Self.le32(signed, 32), 0x8000_0000)
    }

    func testRejects0And17Channels() {
        assertThrows("badChannelCount") { try AssetUpload.makePayload(channels: [], sampleRate: 48000) }
        let seventeen = [[Float]](repeating: [0], count: 17)
        assertThrows("badChannelCount") { try AssetUpload.makePayload(channels: seventeen, sampleRate: 48000) }
        let sixteen = [[Float]](repeating: [0], count: 16)
        XCTAssertNoThrow(try AssetUpload.makePayload(channels: sixteen, sampleRate: 48000))
        assertThrows("badFrameCount") { try AssetUpload.makePayload(channels: [[]], sampleRate: 48000) }
    }

    func testRejectsUnevenLengths() {
        assertThrows("badChannelCount") {
            try AssetUpload.makePayload(channels: [[1, 2, 3], [1, 2]], sampleRate: 48000)
        }
        assertThrows("badChannelCount") {
            try AssetUpload.makePayload(channels: [[1], [1, 2]], sampleRate: 48000)
        }
    }

    /// **NaNや無限大は「サンプルがおかしい」で弾く。**直す前は`badChannelCount`で、
    /// 画面には「1〜16の同じ大きさのチャンネルが要る」と出ていた（大きさは合っているのに）。
    /// 上流も別の理由で弾く（ir-asset-payload.js:28 'IR samples must be finite'）。
    func testRejectsNaN() {
        for bad: Float in [.nan, .infinity, -.infinity, .signalingNaN] {
            assertThrows("nonFiniteSample", "\(bad)") {
                try AssetUpload.makePayload(channels: [[0, 0], [0, bad]], sampleRate: 48000)
            }
        }
        XCTAssertNotEqual(ETAssetUploadError.nonFiniteSample.errorDescription,
                          ETAssetUploadError.badChannelCount.errorDescription)
        // 見る順は上流と同じで、チャンネルごとに長さ→中身。NaNより前のチャンネルの長さ違いはそちらを言う。
        assertThrows("badChannelCount") {
            try AssetUpload.makePayload(channels: [[0, 0], [.nan]], sampleRate: 48000)
        }
    }

    func testRejectsRate0() {
        assertThrows("badSampleRate") { try AssetUpload.makePayload(channels: [[0]], sampleRate: 0) }
        assertThrows("badSampleRate") { try AssetUpload.makePayload(channels: [[0]], sampleRate: -48000) }
        assertThrows("badSampleRate") { try AssetUpload.makePayload(channels: [[0]], sampleRate: 0x1_0000_0000) }
        XCTAssertNoThrow(try AssetUpload.makePayload(channels: [[0]], sampleRate: 0xFFFF_FFFF))
    }

    func testRejectsPathsOnNonMatrix() {
        let path = ETAssetPath(inputSlot: 0, outputSlot: 0, irChannel: 0)
        for topology: ETAssetTopology in [.unspecified, .mono, .independent, .trueStereo] {
            assertThrows("badPaths", "\(topology)") {
                try AssetUpload.makePayload(channels: [[0], [0], [0], [0]], sampleRate: 48000,
                                            topology: topology, paths: [path])
            }
        }
        // matrixは1〜16本。
        assertThrows("badPaths") {
            try AssetUpload.makePayload(channels: [[0]], sampleRate: 48000, topology: .matrix, paths: [])
        }
        let seventeen = [ETAssetPath](repeating: path, count: 17)
        assertThrows("badPaths") {
            try AssetUpload.makePayload(channels: [[0]], sampleRate: 48000, topology: .matrix, paths: seventeen)
        }
        let sixteen = [ETAssetPath](repeating: path, count: 16)
        XCTAssertNoThrow(try AssetUpload.makePayload(channels: [[0]], sampleRate: 48000,
                                                     topology: .matrix, paths: sixteen))
    }

    func testRejectsIrChannelOutOfRange() {
        assertThrows("badPaths") {
            try AssetUpload.makePayload(channels: [[0], [0]], sampleRate: 48000, topology: .matrix,
                                        paths: [ETAssetPath(inputSlot: 0, outputSlot: 0, irChannel: 2)])
        }
        XCTAssertNoThrow(try AssetUpload.makePayload(
            channels: [[0], [0]], sampleRate: 48000, topology: .matrix,
            paths: [ETAssetPath(inputSlot: 0, outputSlot: 0, irChannel: 1)]))
    }

    /// **上流のbuildIrAssetPayloadと1バイトも違わない。**
    /// 見本が見ているもの: 5つのtopology、1×1、16チャンネル、FIR Crossoverの経路の並び、
    /// 対角16本、u32の端のスロット、-0・非正規化数・floatの最大値、レート1と0xFFFFFFFF。
    func testPayloadMatchesUpstreamBuildIrAssetPayload() throws {
        let g = try golden()
        XCTAssertGreaterThanOrEqual(g.payloads.count, 10)
        for c in g.payloads {
            let channels = try c.channels.map(Self.floats)
            let topology = try XCTUnwrap(ETAssetTopology(rawValue: c.topology), c.name)
            let paths = c.paths.map { ETAssetPath(inputSlot: $0[0], outputSlot: $0[1], irChannel: $0[2]) }
            let payload = try AssetUpload.makePayload(channels: channels, sampleRate: c.sampleRate,
                                                      topology: topology, paths: paths)
            let want = [UInt8](try XCTUnwrap(Data(base64Encoded: c.payload), c.name))
            XCTAssertEqual(payload.count, want.count, c.name)
            XCTAssertTrue(payload == want, "\(c.name): 最初に違うバイト "
                          + "\(zip(payload, want).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? -1)")

            // 送る側の前半も同じペイロードを通す（頭から読んだ値が合い、大きさの照合も通る）。
            let info = AssetUpload.beginInfo(topology: topology, paths: paths,
                                             processingChannels: UInt32(max(channels.count, 1)))
            XCTAssertNoThrow(try AssetUpload.beginRequest(engine: 1, instance: 1, payload: payload, info: info),
                             c.name)
        }
    }

    func testCapacityMatchesUpstream() throws {
        XCTAssertEqual(try golden().capacityBytes, AssetUpload.capacityBytes)
    }

    // MARK: - 見積り

    /// **上流のestimateIrKernelCommitFootprint・estimateIrConvolverMemoryUpperBoundと同じ数。**
    /// 5つのtopology × 頭ブロック{0,128,256,512,1024} × チャンネル数の組 × 1〜1048576フレーム。
    func testFootprintMatchesUpstream() throws {
        let table = try golden().footprints
        let c = (topology: try Self.column(table, "topology"),
                 head: try Self.column(table, "headBlock"),
                 asset: try Self.column(table, "assetChannels"),
                 processing: try Self.column(table, "processingChannels"),
                 paths: try Self.column(table, "pathCount"),
                 inputs: try Self.column(table, "inputCount"),
                 frames: try Self.column(table, "frames"),
                 footprint: try Self.column(table, "footprint"),
                 convolver: try Self.column(table, "convolver"))
        XCTAssertGreaterThanOrEqual(table.rows.count, 2000)
        var seenTopologies = Set<UInt32>()
        var seenHeads = Set<Int>()
        var mismatches = 0
        for row in table.rows {
            let topology = try XCTUnwrap(ETAssetTopology(rawValue: UInt32(row[c.topology])))
            seenTopologies.insert(topology.rawValue)
            seenHeads.insert(row[c.head])
            let footprint = AssetUpload.estimateFootprintBytes(frames: row[c.frames],
                                                               assetChannels: row[c.asset],
                                                               topology: topology,
                                                               processingChannels: row[c.processing],
                                                               headBlock: row[c.head],
                                                               pathCount: row[c.paths],
                                                               inputCount: row[c.inputs])
            let convolver = AssetUpload.estimateConvolverBytes(frames: row[c.frames],
                                                               assetChannels: row[c.asset],
                                                               topology: topology,
                                                               processingChannels: row[c.processing],
                                                               headBlock: row[c.head],
                                                               pathCount: row[c.paths],
                                                               inputCount: row[c.inputs])
            if footprint != row[c.footprint] || convolver != row[c.convolver] {
                mismatches += 1
                if mismatches <= 10 {
                    XCTFail("\(row): footprint \(footprint) convolver \(convolver)")
                }
            }
        }
        XCTAssertEqual(mismatches, 0)
        XCTAssertEqual(seenTopologies, [0, 1, 2, 3, 4])
        XCTAssertEqual(seenHeads, [0, 128, 256, 512, 1024])
    }

    /// 上流のmaximumIrFramesForKernelと同じ答え。
    func testMaximumFramesMatchesUpstream() throws {
        let table = try golden().maximumFrames
        let c = (topology: try Self.column(table, "topology"),
                 head: try Self.column(table, "headBlock"),
                 asset: try Self.column(table, "assetChannels"),
                 processing: try Self.column(table, "processingChannels"),
                 paths: try Self.column(table, "pathCount"),
                 inputs: try Self.column(table, "inputCount"),
                 source: try Self.column(table, "sourceFrames"),
                 maximum: try Self.column(table, "maximumFrames"))
        XCTAssertGreaterThanOrEqual(table.rows.count, 600)
        for row in table.rows {
            let topology = try XCTUnwrap(ETAssetTopology(rawValue: UInt32(row[c.topology])))
            let maximum = AssetUpload.maximumFrames(sourceFrames: row[c.source],
                                                    assetChannels: row[c.asset],
                                                    topology: topology,
                                                    processingChannels: row[c.processing],
                                                    headBlock: row[c.head],
                                                    pathCount: row[c.paths],
                                                    inputCount: row[c.inputs])
            XCTAssertEqual(maximum, row[c.maximum], "\(row)")
        }
    }

    /// 答えは「32MiBに収まる最大のframes」。1つ増やすと収まらない（元の長さで頭打ちでなければ）。
    func testMaximumFramesLargestFitting32MiB() {
        let shapes: [(ETAssetTopology, Int, Int, Int, Int)] = [
            (.mono, 1, 2, 0, 0), (.independent, 2, 2, 0, 0), (.trueStereo, 4, 2, 0, 0),
            (.independent, 16, 16, 0, 0), (.matrix, 4, 8, 8, 2), (.unspecified, 8, 6, 0, 0)
        ]
        for (topology, asset, processing, paths, inputs) in shapes {
            for head in [0, 128, 256, 512, 1024] {
                func footprint(_ frames: Int) -> Int {
                    AssetUpload.estimateFootprintBytes(frames: frames, assetChannels: asset, topology: topology,
                                                       processingChannels: processing, headBlock: head,
                                                       pathCount: paths, inputCount: inputs)
                }
                let source = 50_000_000
                let maximum = AssetUpload.maximumFrames(sourceFrames: source, assetChannels: asset,
                                                        topology: topology, processingChannels: processing,
                                                        headBlock: head, pathCount: paths, inputCount: inputs)
                let label = "\(topology) \(asset)/\(processing) head \(head)"
                XCTAssertLessThan(maximum, source, label)
                XCTAssertLessThanOrEqual(footprint(maximum), AssetUpload.capacityBytes, label)
                XCTAssertGreaterThan(footprint(maximum + 1), AssetUpload.capacityBytes, label)
                // 元が短ければ元の長さのまま。
                XCTAssertEqual(AssetUpload.maximumFrames(sourceFrames: 1000, assetChannels: asset,
                                                         topology: topology, processingChannels: processing,
                                                         headBlock: head, pathCount: paths,
                                                         inputCount: inputs), 1000, label)
            }
        }
        // 0以下の長さは1（上流と同じ）。容量を小さくすれば答えも縮む。
        XCTAssertEqual(AssetUpload.maximumFrames(sourceFrames: 0, assetChannels: 1, topology: .mono,
                                                 processingChannels: 2), 1)
        let small = AssetUpload.maximumFrames(sourceFrames: 1_000_000, assetChannels: 1, topology: .mono,
                                              processingChannels: 2, capacityBytes: 4 * 1024 * 1024)
        let full = AssetUpload.maximumFrames(sourceFrames: 1_000_000, assetChannels: 1, topology: .mono,
                                             processingChannels: 2)
        XCTAssertLessThan(small, full)
    }

    /// 分割畳み込みの段の切り方（上流の書き出されていないconvolutionStages）。
    func testConvolutionStagesMatchUpstream() throws {
        let sets = try golden().stages
        XCTAssertGreaterThanOrEqual(sets.count, 50)
        for set in sets {
            let stages = AssetUpload.convolutionStages(frames: set.frames, headBlock: set.headBlock)
            XCTAssertEqual(stages.map { [$0.block, $0.offset, $0.segmentFrames] }, set.stages,
                           "frames \(set.frames) head \(set.headBlock)")
        }
    }

    /// 経路か入力が0になる組み合わせでは畳み込み器の見積りは0（上流はTypeErrorを投げる）。
    /// makePayloadとbeginInfoから来る値ではその組み合わせにならない。beginRequestは
    /// BeginInfoのpathCountとinputCountをそのまま使うので、手で組んだ0は通って見積りが小さくなる。
    /// ここは今の振る舞いを留めるだけ。
    func testConvolverZeroWithoutPathOrInput() {
        XCTAssertEqual(AssetUpload.estimateConvolverBytes(frames: 1000, assetChannels: 2, topology: .matrix,
                                                          processingChannels: 2, pathCount: 0, inputCount: 2), 0)
        XCTAssertEqual(AssetUpload.estimateConvolverBytes(frames: 1000, assetChannels: 2, topology: .matrix,
                                                          processingChannels: 2, pathCount: 2, inputCount: 0), 0)
        XCTAssertEqual(AssetUpload.estimateFootprintBytes(frames: 0, assetChannels: 1, topology: .mono,
                                                          processingChannels: 1), 0)
    }

    func testResolvedCounts() {
        XCTAssertEqual(AssetUpload.resolvedPathCount(.mono, 1, 6, 0), 6)
        XCTAssertEqual(AssetUpload.resolvedPathCount(.trueStereo, 4, 2, 0), 4)
        XCTAssertEqual(AssetUpload.resolvedPathCount(.matrix, 4, 8, 8), 8)
        XCTAssertEqual(AssetUpload.resolvedPathCount(.independent, 3, 8, 0), 3)
        XCTAssertEqual(AssetUpload.resolvedPathCount(.unspecified, 5, 8, 0), 5)
        XCTAssertEqual(AssetUpload.resolvedInputCount(.trueStereo, 6, 0), 2)
        XCTAssertEqual(AssetUpload.resolvedInputCount(.matrix, 6, 3), 3)
        XCTAssertEqual(AssetUpload.resolvedInputCount(.mono, 6, 0), 6)
        XCTAssertEqual(AssetUpload.resolvedInputCount(.independent, 6, 0), 6)
        XCTAssertEqual(AssetUpload.resolvedInputCount(.unspecified, 6, 0), 6)
    }

    // MARK: - 状態のビット

    /// 下位8bitが状態、次の8bitが理由、bit16がreplacementDryReady（five_band_fir_peq/kernel.cpp:259-263）。
    func testStatusBits() {
        XCTAssertEqual(ETAssetStatus(raw: 0).state, ETAssetState.none)
        XCTAssertEqual(ETAssetStatus(raw: 1).state, .staged)
        XCTAssertEqual(ETAssetStatus(raw: 2).state, .preparing)
        XCTAssertEqual(ETAssetStatus(raw: 3).state, .active)
        XCTAssertTrue(ETAssetStatus(raw: 3).isActive)
        XCTAssertFalse(ETAssetStatus(raw: 2).isActive)
        let error = ETAssetStatus(raw: 4 | (2 << 8))
        XCTAssertEqual(error.state, .error)
        XCTAssertEqual(error.reason, 2)
        XCTAssertFalse(error.replacementDryReady)
        let dry = ETAssetStatus(raw: 3 | (1 << 16) | (0xFF << 8))
        XCTAssertEqual(dry.state, .active)
        XCTAssertEqual(dry.reason, 0xFF)
        XCTAssertTrue(dry.replacementDryReady)
        // 知らない状態の値はnoneに落とす（上の桁は状態に混ぜない）。
        XCTAssertEqual(ETAssetStatus(raw: 5).state, ETAssetState.none)
        XCTAssertEqual(ETAssetStatus(raw: 0x1_0003).state, .active)
        XCTAssertEqual(ETAssetStatus(raw: 0xFFFF_FF03).state, .active)
    }

    // MARK: - beginの引数

    /// matrixだけが経路数と入力の種類の数を持つ。それ以外は0（engine.cpp:505-506）。
    func testBeginInfoCountsDistinctInputSlots() {
        var crossover = [ETAssetPath]()
        for band in UInt32(0)..<3 {
            crossover.append(ETAssetPath(inputSlot: 0, outputSlot: band * 2, irChannel: band))
            crossover.append(ETAssetPath(inputSlot: 1, outputSlot: band * 2 + 1, irChannel: band))
        }
        let matrix = AssetUpload.beginInfo(topology: .matrix, paths: crossover, headBlock: 256,
                                           rateDivider: 2, processingChannels: 6)
        XCTAssertEqual(matrix.pathCount, 6)
        XCTAssertEqual(matrix.inputCount, 2)
        XCTAssertEqual(matrix.headBlock, 256)
        XCTAssertEqual(matrix.rateDivider, 2)
        XCTAssertEqual(matrix.processingChannels, 6)
        XCTAssertEqual(matrix.topology, ETAssetTopology.matrix)
        XCTAssertNil(matrix.channels)
        XCTAssertNil(matrix.frames)
        XCTAssertNil(matrix.footprintBytes)
        let stereo = AssetUpload.beginInfo(topology: .independent, paths: crossover)
        XCTAssertEqual(stereo.pathCount, 0)
        XCTAssertEqual(stereo.inputCount, 0)
        XCTAssertEqual(stereo.headBlock, 128)
        XCTAssertEqual(stereo.rateDivider, 1)
        XCTAssertEqual(stereo.processingChannels, 2)
    }

    /// 明示が無ければ頭から読み、明示があればそちらが勝つ（dsp-engine-binding.js:668-673）。
    func testBeginRequestReadsHeaderAndOverrides() throws {
        let payload = try AssetUpload.makePayload(channels: [[1, 2, 3, 4], [5, 6, 7, 8]], sampleRate: 48000,
                                                  topology: .independent)
        let info = AssetUpload.BeginInfo(headBlock: 512, rateDivider: 1, processingChannels: 2)
        let request = try AssetUpload.beginRequest(engine: 3, instance: 9, slot: 1, payload: payload, info: info)
        let estimated = AssetUpload.estimateFootprintBytes(frames: 4, assetChannels: 2, topology: .independent,
                                                           processingChannels: 2, headBlock: 512)
        XCTAssertEqual(request, AssetUpload.BeginRequest(engine: 3, instance: 9, slot: 1, channels: 2, frames: 4,
                                                         topology: 2, headBlock: 512, rateDivider: 1,
                                                         pathCount: 0, inputCount: 0, processingChannels: 2,
                                                         footprintBytes: UInt32(estimated),
                                                         byteSize: UInt32(payload.count)))

        // 明示したtopologyが頭より勝つ（大きさの式はmatrixでないので変わらない）。
        var override = info
        override.topology = .trueStereo
        override.footprintBytes = 4 * 1024 * 1024
        let forced = try AssetUpload.beginRequest(engine: 3, instance: 9, payload: payload, info: override)
        XCTAssertEqual(forced.topology, ETAssetTopology.trueStereo.rawValue)
        XCTAssertEqual(forced.footprintBytes, 4 * 1024 * 1024)
        XCTAssertEqual(forced.slot, 0)

        // 明示したchannels/framesが頭と合わなければ、大きさの照合で落ちる。
        var wrong = info
        wrong.frames = 5
        assertThrows("sizeMismatch") {
            try AssetUpload.beginRequest(engine: 3, instance: 9, payload: payload, info: wrong)
        }
    }

    /// 見る順は engine → 頭の大きさ → magic → topology → channels → frames → 大きさ → 見積り。
    func testBeginRequestRejections() throws {
        let good = try AssetUpload.makePayload(channels: [[1, 2]], sampleRate: 48000, topology: .mono)
        let info = AssetUpload.BeginInfo()
        assertThrows("engineNotReady") { try AssetUpload.beginRequest(engine: 0, instance: 1, payload: good, info: info) }
        assertThrows("engineNotReady") { try AssetUpload.beginRequest(engine: 1, instance: 0, payload: [], info: info) }
        assertThrows("payloadTooShort") {
            try AssetUpload.beginRequest(engine: 1, instance: 1, payload: Array(good[0..<31]), info: info)
        }
        var badMagic = good
        badMagic[0] ^= 0xFF
        assertThrows("badMagic") { try AssetUpload.beginRequest(engine: 1, instance: 1, payload: badMagic, info: info) }
        var badTopology = good
        badTopology[16] = 5
        assertThrows("badTopology") {
            try AssetUpload.beginRequest(engine: 1, instance: 1, payload: badTopology, info: info)
        }
        var noChannels = good
        noChannels[4] = 0
        assertThrows("badChannelCount") {
            try AssetUpload.beginRequest(engine: 1, instance: 1, payload: noChannels, info: info)
        }
        var manyChannels = info
        manyChannels.channels = 17
        assertThrows("badChannelCount") {
            try AssetUpload.beginRequest(engine: 1, instance: 1, payload: good, info: manyChannels)
        }
        var noFrames = good
        noFrames[8] = 0
        assertThrows("badFrameCount") {
            try AssetUpload.beginRequest(engine: 1, instance: 1, payload: noFrames, info: info)
        }
        assertThrows("sizeMismatch") {
            try AssetUpload.beginRequest(engine: 1, instance: 1, payload: good + [0, 0, 0, 0], info: info)
        }
        // matrixは経路の12バイトを大きさに数える。経路数を言わなければ合わない。
        let matrix = try AssetUpload.makePayload(channels: [[1]], sampleRate: 48000, topology: .matrix,
                                                 paths: [ETAssetPath(inputSlot: 0, outputSlot: 0, irChannel: 0)])
        assertThrows("sizeMismatch") {
            try AssetUpload.beginRequest(engine: 1, instance: 1, payload: matrix, info: info)
        }
        let matrixInfo = AssetUpload.beginInfo(topology: .matrix,
                                               paths: [ETAssetPath(inputSlot: 0, outputSlot: 0, irChannel: 0)])
        XCTAssertNoThrow(try AssetUpload.beginRequest(engine: 1, instance: 1, payload: matrix, info: matrixInfo))
    }

    /// 見積りはペイロード以上で32MiB以下。外れたら送る前にtooLarge。
    func testBeginRequestFootprintBounds() throws {
        let payload = try AssetUpload.makePayload(channels: [[Float](repeating: 0, count: 1000)], sampleRate: 48000)
        var info = AssetUpload.BeginInfo()
        info.footprintBytes = UInt32(payload.count - 1)
        assertThrows("tooLarge") { try AssetUpload.beginRequest(engine: 1, instance: 1, payload: payload, info: info) }
        info.footprintBytes = UInt32(payload.count)
        XCTAssertEqual(try AssetUpload.beginRequest(engine: 1, instance: 1, payload: payload, info: info).footprintBytes,
                       UInt32(payload.count))
        // ちょうど32MiBは通る（maximumFramesも<=で数える）。
        info.footprintBytes = UInt32(AssetUpload.capacityBytes)
        XCTAssertEqual(try AssetUpload.beginRequest(engine: 1, instance: 1, payload: payload, info: info).footprintBytes,
                       UInt32(AssetUpload.capacityBytes))
        info.footprintBytes = UInt32(AssetUpload.capacityBytes + 1)
        assertThrows("tooLarge") { try AssetUpload.beginRequest(engine: 1, instance: 1, payload: payload, info: info) }

        // 見積りが32MiBを超える長さは、明示が無くても送る前に落ちる。
        let frames = AssetUpload.maximumFrames(sourceFrames: 20_000_000, assetChannels: 1, topology: .mono,
                                               processingChannels: 2) + 1
        let long = try AssetUpload.makePayload(channels: [[Float](repeating: 0, count: frames)], sampleRate: 48000,
                                               topology: .mono)
        assertThrows("tooLarge") {
            try AssetUpload.beginRequest(engine: 1, instance: 1, payload: long, info: AssetUpload.BeginInfo())
        }
        XCTAssertNoThrow(try AssetUpload.beginRequest(engine: 1, instance: 1, payload: Array(long.prefix(long.count - 4)),
                                                      info: AssetUpload.BeginInfo(frames: UInt32(frames - 1))))
    }
}
