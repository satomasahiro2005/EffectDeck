//  AssetPayload.swift
//  FIR系7種へ送る「資産」（設計済みの係数）の並び・確保の見積り・beginの引数の解決。
//  **Foundationだけ。**エンジンのC関数・ログ・音のスレッドの締め出しはAssetUpload.swift
//  （同じenum AssetUploadのextension）にある。ここを分けたのは、設計側の純粋な部分と一緒に
//  単体テストのバンドルとLinuxの口（Tests/Linux/run.sh）へ入れるため。
//
//  --- ペイロードの並び（ETA1）---
//  出典は2つ。どちらも同じ並びを言っている。
//    書き手: Vendor/effetune/js/ir-library/ir-asset-payload.js:59-96 (buildIrAssetPayload)
//    読み手: Vendor/effetune/dsp/plugins/eq/five_band_fir_peq/kernel.cpp:282-288 (validatePayload)
//            Vendor/effetune/dsp/plugins/basics/fir_crossover/kernel.cpp:341-364 (validatePayload+decodeMatrixPaths)
//            Vendor/effetune/dsp/plugins/reverb/ir_reverb/kernel.cpp:486-496 (validatePayload)
//
//    +0  u32  magic 0x31415445
//    +4  u32  channels（IRのチャンネル数。1〜16）
//    +8  u32  frames（1チャンネルあたりのサンプル数）
//    +12 u32  sampleRate（整数。IR Reverbだけrate_dividerで割った値）
//    +16 u32  topology（0 未指定 / 1 mono / 2 independent / 3 trueStereo / 4 matrix）
//    +20 u32  pathCount（matrixのときだけ。それ以外は0）
//    +24 u32  0
//    +28 u32  0
//    +32      matrixのときだけpathがpathCount個。1個12バイトで
//             u32 inputSlot / u32 outputSlot / u32 irChannel
//    その後   float32がchannel-major（ch0のframes個、その後ch1 …）
//
//  すべてリトルエンディアン。arm64もリトルエンディアンなので、
//  係数の本体はFloatの並びをそのまま写して構わない（頭の32バイトだけは
//  誤解が起きないよう1バイトずつ書いている）。
//
//  見本は上流のJSそのものが吐いたもの（Tests/Fixtures/Asset/asset-golden.json。
//  作り直すときは Tools/golden/asset_golden.mjs）。照合は Tests/Unit/AssetPayloadTests.swift。

import Foundation

// MARK: - 資産の形

// ETAssetTopologyとETAssetPathはIRPreparation.swiftにある（単体テストのバンドルからも見えるように）。

/// et_instance_asset_stateの生値。abi.h:86-93と各カーネルのassetState()。
enum ETAssetState: UInt32 {
    case none = 0
    case staged = 1
    case preparing = 2
    case active = 3
    case error = 4
}

/// 生値をほどいたもの。
/// 下位8bitが状態、次の8bitが理由、bit16がreplacementDryReady。
/// 組み立てはfive_band_fir_peq/kernel.cpp:259-263。
struct ETAssetStatus {
    let raw: UInt32

    var state: ETAssetState { ETAssetState(rawValue: raw & 0xFF) ?? .none }

    /// errorのときだけ意味がある。1 = commitで弾かれた（並びか引数）、
    /// 2 = 確保できなかった（footprint不足を含む）、3 = 畳み込み器が受け取れなかった。
    var reason: UInt32 { (raw >> 8) & 0xFF }

    /// 差し替えのためにdryへ落とし切ったか。差し替え時の無音待ちに使う。
    var replacementDryReady: Bool { (raw & (1 << 16)) != 0 }

    var isActive: Bool { state == .active }
}

// MARK: - 失敗の種類

enum ETAssetUploadError: Error, LocalizedError {
    case engineNotReady
    case payloadTooShort
    case badMagic
    case badChannelCount
    case badFrameCount
    /// 係数にNaNか無限大が混ざっている。上流も別の理由で弾く
    /// （ir-asset-payload.js:28 'IR samples must be finite'）。
    case nonFiniteSample
    case badSampleRate
    case badTopology
    case badPaths
    case sizeMismatch(expected: Int, actual: Int)
    case tooLarge(bytes: Int, capacity: Int)
    /// 書き込み先の番地が取れなかった。AssetUpload.swiftの「64bitの口」を参照。
    case stagingAddressUnavailable
    case beginRejected
    case commitFailed(status: Int32)

    var errorDescription: String? {
        switch self {
        case .engineNotReady:
            return "The audio engine is not ready."
        case .payloadTooShort:
            return "The asset payload is smaller than its header."
        case .badMagic:
            return "The asset payload does not start with the expected signature."
        case .badChannelCount:
            return "An asset needs between 1 and 16 equally sized channels."
        case .badFrameCount:
            return "An asset channel must not be empty."
        case .nonFiniteSample:
            return "The filter came out with invalid samples."
        case .badSampleRate:
            return "The asset sample rate must be a positive whole number."
        case .badTopology:
            return "The asset topology is not supported."
        case .badPaths:
            return "The matrix routing of this asset is not valid."
        case .sizeMismatch(let expected, let actual):
            return "The asset payload is \(actual) bytes where its header describes \(expected)."
        case .tooLarge(let bytes, let capacity):
            return "The asset needs \(bytes) bytes and the effect accepts \(capacity)."
        case .stagingAddressUnavailable:
            return "This build cannot reach the effect's staging buffer."
        case .beginRejected:
            return "The effect refused the asset. Try a shorter filter."
        case .commitFailed:
            return "The effect could not take the asset."
        }
    }
}

// MARK: - 純粋な部分

enum AssetUpload {

    /// 頭の大きさ。全カーネル共通で32（kAssetHeaderBytes）。
    static let headerBytes = 32
    /// 0x31415445。"ETA1"をリトルエンディアンで置いたもの。
    static let magic: UInt32 = 0x3141_5445
    /// 1本のpathの大きさ（kMatrixPathBytes）。
    static let pathBytes = 12
    /// ET_ASSET_F32_MULTICH。format_tagはこれ1つだけ。
    static let formatTagF32MultiChannel: UInt32 = 1
    /// 資産1枠の上限。7種とも32MiB（kAssetCapacity）。
    static let capacityBytes = 32 * 1024 * 1024
    /// チャンネルとmatrixの経路の上限（ir-asset-payload.js:13-14）。
    static let maximumChannels = 16
    static let maximumMatrixPaths = 16

    // MARK: beginへ渡すもの

    /// et_instance_asset_beginの引数。
    /// channels / frames / topologyはnilにするとペイロードの頭から読む
    /// （dsp-engine-binding.js:668-673と同じで、明示があればそちらが勝つ）。
    struct BeginInfo {
        var channels: UInt32?
        var frames: UInt32?
        var topology: ETAssetTopology?
        /// 0 / 128 / 256 / 512 / 1024のどれか。0は「遅延なし」の意味で、
        /// カーネル側は128の頭ブロックを使う。
        var headBlock: UInt32
        /// 1 / 2 / 4。IR Reverb以外は1しか受け取らない。
        var rateDivider: UInt32
        /// matrixのときだけ1以上。それ以外は0でないと弾かれる。
        var pathCount: UInt32
        var inputCount: UInt32
        /// このエフェクトが処理するチャンネル数。engineのmaxChannels以下。
        var processingChannels: UInt32
        /// 確保の見積り。nilならestimateFootprintBytesで出す。
        /// ここをbyteSizeと同じにすると、畳み込み器の分が入らずに必ず落ちる
        /// （kernel.cpp:200の`convolver_.memoryBytes() + byteSize > footprintBytes`）。
        var footprintBytes: UInt32?

        init(channels: UInt32? = nil,
             frames: UInt32? = nil,
             topology: ETAssetTopology? = nil,
             headBlock: UInt32 = 128,
             rateDivider: UInt32 = 1,
             pathCount: UInt32 = 0,
             inputCount: UInt32 = 0,
             processingChannels: UInt32 = 2,
             footprintBytes: UInt32? = nil) {
            self.channels = channels
            self.frames = frames
            self.topology = topology
            self.headBlock = headBlock
            self.rateDivider = rateDivider
            self.pathCount = pathCount
            self.inputCount = inputCount
            self.processingChannels = processingChannels
            self.footprintBytes = footprintBytes
        }
    }

    /// 解決し終えたbeginの引数。AssetUpload.swiftの「64bitの口」へ渡す。
    struct BeginRequest: Equatable {
        var engine: UInt32
        var instance: UInt32
        var slot: UInt32
        var channels: UInt32
        var frames: UInt32
        var topology: UInt32
        var headBlock: UInt32
        var rateDivider: UInt32
        var pathCount: UInt32
        var inputCount: UInt32
        var processingChannels: UInt32
        var footprintBytes: UInt32
        var byteSize: UInt32
    }

    // MARK: - ペイロードを組む

    /// ETA1のペイロードを組む。
    /// ir-asset-payload.js:59-96 (buildIrAssetPayload) をそのまま移したもの。
    ///
    /// - Parameters:
    ///   - channels: IRのチャンネル。長さは全部同じでないといけない
    ///   - sampleRate: 整数。IR Reverbでrate_dividerを使うときは割った後の値
    ///   - topology: matrix以外ではpathsを空にする
    static func makePayload(channels: [[Float]],
                            sampleRate: Int,
                            topology: ETAssetTopology = .unspecified,
                            paths: [ETAssetPath] = []) throws -> [UInt8] {
        guard !channels.isEmpty, channels.count <= maximumChannels else {
            throw ETAssetUploadError.badChannelCount
        }
        let frames = channels[0].count
        guard frames > 0 else { throw ETAssetUploadError.badFrameCount }
        for channel in channels {
            guard channel.count == frames else { throw ETAssetUploadError.badChannelCount }
            for sample in channel where !sample.isFinite {
                throw ETAssetUploadError.nonFiniteSample
            }
        }
        guard sampleRate > 0, sampleRate <= 0xFFFF_FFFF else { throw ETAssetUploadError.badSampleRate }

        if topology == .matrix {
            guard !paths.isEmpty, paths.count <= maximumMatrixPaths else { throw ETAssetUploadError.badPaths }
            for path in paths where path.irChannel >= UInt32(channels.count) {
                throw ETAssetUploadError.badPaths
            }
        } else if !paths.isEmpty {
            throw ETAssetUploadError.badPaths
        }

        var payload = [UInt8]()
        payload.reserveCapacity(headerBytes + paths.count * pathBytes + channels.count * frames * 4)

        appendLittleEndian(&payload, magic)                       // +0
        appendLittleEndian(&payload, UInt32(channels.count))      // +4
        appendLittleEndian(&payload, UInt32(frames))              // +8
        appendLittleEndian(&payload, UInt32(sampleRate))          // +12
        appendLittleEndian(&payload, topology.rawValue)           // +16
        appendLittleEndian(&payload, UInt32(paths.count))         // +20
        appendLittleEndian(&payload, 0)                           // +24
        appendLittleEndian(&payload, 0)                           // +28

        for path in paths {
            appendLittleEndian(&payload, path.inputSlot)
            appendLittleEndian(&payload, path.outputSlot)
            appendLittleEndian(&payload, path.irChannel)
        }

        // 係数の本体。arm64（とLinuxのx86_64）はリトルエンディアンなのでFloatの並びがそのまま通る。
        for channel in channels {
            channel.withUnsafeBufferPointer { buffer in
                payload.append(contentsOf: UnsafeRawBufferPointer(buffer))
            }
        }
        return payload
    }

    // MARK: - beginの引数を解く

    /// 係数から組んだペイロードに付けるbeginの引数。
    /// matrix以外はpathCountもinputCountも0でないとengineに弾かれる（engine.cpp:505-506）。
    /// inputCountは経路の入力の種類の数（ir-plugin-contract.js:188-190と同じ）。
    static func beginInfo(topology: ETAssetTopology,
                          paths: [ETAssetPath],
                          headBlock: UInt32 = 128,
                          rateDivider: UInt32 = 1,
                          processingChannels: UInt32 = 2) -> BeginInfo {
        var inputSlots = Set<UInt32>()
        if topology == .matrix {
            for path in paths { inputSlots.insert(path.inputSlot) }
        }
        return BeginInfo(topology: topology,
                         headBlock: headBlock,
                         rateDivider: rateDivider,
                         pathCount: topology == .matrix ? UInt32(paths.count) : 0,
                         inputCount: UInt32(inputSlots.count),
                         processingChannels: processingChannels)
    }

    /// send(payload:info:)の前半。送る前に弾けるものを全部弾き、beginへ渡す値を決める。
    /// 見る順は、engine → 頭の大きさ → magic → topology → channels → frames → 大きさ → 見積り。
    static func beginRequest(engine: UInt32,
                             instance: UInt32,
                             slot: UInt32 = 0,
                             payload: [UInt8],
                             info: BeginInfo,
                             capacity: Int = AssetUpload.capacityBytes) throws -> BeginRequest {
        guard engine != 0, instance != 0 else { throw ETAssetUploadError.engineNotReady }
        guard payload.count >= headerBytes else { throw ETAssetUploadError.payloadTooShort }
        guard readLittleEndian(payload, 0) == magic else { throw ETAssetUploadError.badMagic }

        // 呼び出し側の指定が優先。無ければ頭から読む。
        let channels = info.channels ?? readLittleEndian(payload, 4)
        let frames = info.frames ?? readLittleEndian(payload, 8)
        let rawTopology = info.topology?.rawValue ?? readLittleEndian(payload, 16)
        guard let topology = ETAssetTopology(rawValue: rawTopology) else {
            throw ETAssetUploadError.badTopology
        }
        guard channels >= 1, channels <= UInt32(maximumChannels) else { throw ETAssetUploadError.badChannelCount }
        guard frames >= 1 else { throw ETAssetUploadError.badFrameCount }

        // 大きさが合っているかを先に見る。合わないものを渡すと
        // カーネルはERROR状態のまま黙るので、ここで弾いたほうが分かりやすい。
        // 式はaudio-processor.js:3040-3041と同じ。
        let matrixBytes = topology == .matrix ? Int(info.pathCount) * pathBytes : 0
        let expected = headerBytes + matrixBytes + Int(channels) * Int(frames) * 4
        guard expected == payload.count else {
            throw ETAssetUploadError.sizeMismatch(expected: expected, actual: payload.count)
        }

        let estimated = estimateFootprintBytes(frames: Int(frames),
                                               assetChannels: Int(channels),
                                               topology: topology,
                                               processingChannels: Int(info.processingChannels),
                                               headBlock: Int(info.headBlock),
                                               pathCount: Int(info.pathCount),
                                               inputCount: Int(info.inputCount))
        let footprint = info.footprintBytes.map { Int($0) } ?? estimated
        guard footprint >= payload.count, footprint <= capacity else {
            throw ETAssetUploadError.tooLarge(bytes: max(footprint, payload.count),
                                              capacity: capacity)
        }

        return BeginRequest(engine: engine,
                            instance: instance,
                            slot: slot,
                            channels: channels,
                            frames: frames,
                            topology: rawTopology,
                            headBlock: info.headBlock,
                            rateDivider: info.rateDivider,
                            pathCount: info.pathCount,
                            inputCount: info.inputCount,
                            processingChannels: info.processingChannels,
                            footprintBytes: UInt32(footprint),
                            byteSize: UInt32(payload.count))
    }

    // MARK: - 確保の見積り

    /// beginへ渡すfootprintBytes。
    /// ir-plugin-contract.js:209-239 (estimateIrKernelCommitFootprint) をそのまま移したもの。
    /// 実際の確保より必ず大きくなるように作られている。
    static func estimateFootprintBytes(frames: Int,
                                       assetChannels: Int,
                                       topology: ETAssetTopology,
                                       processingChannels: Int,
                                       headBlock: Int = 128,
                                       pathCount: Int = 0,
                                       inputCount: Int = 0) -> Int {
        guard frames >= 1, assetChannels >= 1, processingChannels >= 1 else { return 0 }
        let paths = resolvedPathCount(topology, assetChannels, processingChannels, pathCount)
        let payloadBytes = headerBytes
            + (topology == .matrix ? paths * pathBytes : 0)
            + frames * assetChannels * 4
        // カーネルがbeginで触る上限（staging + 下見）
        let kernelBeginBound = payloadBytes + frames * assetChannels * 16 + 2 * 1024 * 1024
        // 畳み込み器の上限
        let convolverBound = payloadBytes + estimateConvolverBytes(
            frames: frames,
            assetChannels: assetChannels,
            topology: topology,
            processingChannels: processingChannels,
            headBlock: headBlock,
            pathCount: pathCount,
            inputCount: inputCount
        )
        return max(kernelBeginBound, convolverBound)
    }

    /// 32MiBに収まる最大のframesを二分探索で出す。
    /// ir-plugin-contract.js:241-269 (maximumIrFramesForKernel)。
    static func maximumFrames(sourceFrames: Int,
                              assetChannels: Int,
                              topology: ETAssetTopology,
                              processingChannels: Int,
                              headBlock: Int = 128,
                              pathCount: Int = 0,
                              inputCount: Int = 0,
                              capacityBytes: Int = AssetUpload.capacityBytes) -> Int {
        guard sourceFrames >= 1 else { return 1 }
        var low = 1
        var high = sourceFrames
        while low < high {
            let middle = (low + high + 1) / 2
            let footprint = estimateFootprintBytes(frames: middle,
                                                   assetChannels: assetChannels,
                                                   topology: topology,
                                                   processingChannels: processingChannels,
                                                   headBlock: headBlock,
                                                   pathCount: pathCount,
                                                   inputCount: inputCount)
            if footprint <= capacityBytes {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return low
    }

    /// ir-plugin-contract.js:75-103 (estimateIrConvolverMemoryUpperBound)。
    /// 経路か入力が0になる組み合わせでは0を返す（上流はTypeErrorを投げる）。
    /// makePayloadとbeginInfoから来る値ではその組み合わせにならない。beginRequestは
    /// BeginInfoのpathCountとinputCountをそのまま使うので、手で組んだ0が来ると
    /// 見積りが小さくなり、カーネルがbeginで断る（beginRejected）。
    static func estimateConvolverBytes(frames: Int,
                                       assetChannels: Int,
                                       topology: ETAssetTopology,
                                       processingChannels: Int,
                                       headBlock: Int = 128,
                                       pathCount: Int = 0,
                                       inputCount: Int = 0) -> Int {
        let paths = resolvedPathCount(topology, assetChannels, processingChannels, pathCount)
        let inputs = resolvedInputCount(topology, processingChannels, inputCount)
        guard paths >= 1, inputs >= 1 else { return 0 }

        let stages = convolutionStages(frames: frames, headBlock: headBlock)
        var requiredRing = headBlock + 4096
        var bytes = 16 * 1024                      // CONVOLVER_IMPL_BYTES_UPPER_BOUND
        for stage in stages {
            let required = headBlock + stage.offset + stage.block + 4096
            if required > requiredRing { requiredRing = required }
            let fft = 2 * stage.block
            let partitions = (stage.segmentFrames + stage.block - 1) / stage.block
            let floatCount = 3 * inputs * stage.block
                + 2 * fft
                + (inputs + assetChannels) * partitions * fft
                + 2 * processingChannels * fft
            bytes += 512                           // CONVOLVER_STAGE_BYTES_UPPER_BOUND
                + floatCount * 4
                + nextPowerOfTwo(paths) * 12
                + 136                              // PFFFT_SETUP_FIXED_BYTES_UPPER_BOUND
                + fft * 4
        }
        bytes += processingChannels * nextPowerOfTwo(requiredRing) * 4
        if headBlock == 0 { bytes += (assetChannels + inputs) * 128 * 4 }
        bytes += inputs * 4
        return bytes
    }

    // MARK: - 分割畳み込みの段

    /// 畳み込みの1段。blockの大きさで、IRのoffsetからsegmentFrames個を受け持つ。
    struct ConvolutionStage: Equatable {
        let block: Int
        let offset: Int
        let segmentFrames: Int
    }

    /// ir-plugin-contract.js:57-72 (convolutionStages)。
    /// 頭ブロックが0（遅延なし）のときは128の段を128から始める（頭の128は直に畳み込む）。
    static func convolutionStages(frames: Int, headBlock: Int) -> [ConvolutionStage] {
        let head = headBlock == 0 ? 128 : headBlock
        var stages = [ConvolutionStage]()
        func add(_ block: Int, _ offset: Int, _ end: Int) {
            if offset >= frames || end <= offset { return }
            stages.append(ConvolutionStage(block: block, offset: offset,
                                           segmentFrames: min(end, frames) - offset))
        }
        add(head, headBlock == 0 ? 128 : 0, 4 * head)
        var block = 2 * head
        while block < 4096 {
            add(block, 2 * block, 4 * block)
            block *= 2
        }
        add(4096, 8192, frames)
        return stages
    }

    /// ir-plugin-contract.js:13-19 (topologyPathCount)。
    static func resolvedPathCount(_ topology: ETAssetTopology,
                                  _ assetChannels: Int,
                                  _ processingChannels: Int,
                                  _ pathCount: Int) -> Int {
        switch topology {
        case .mono: return processingChannels
        case .trueStereo: return 4
        case .matrix: return pathCount
        case .independent, .unspecified: return assetChannels
        }
    }

    /// ir-plugin-contract.js:21-25 (topologyInputCount)。
    static func resolvedInputCount(_ topology: ETAssetTopology,
                                   _ processingChannels: Int,
                                   _ inputCount: Int) -> Int {
        switch topology {
        case .trueStereo: return 2
        case .matrix: return inputCount
        case .mono, .independent, .unspecified: return processingChannels
        }
    }

    // MARK: - 細かい道具

    private static func nextPowerOfTwo(_ value: Int) -> Int {
        var result = 1
        while result < value { result *= 2 }
        return result
    }

    private static func appendLittleEndian(_ out: inout [UInt8], _ value: UInt32) {
        out.append(UInt8(value & 0xFF))
        out.append(UInt8((value >> 8) & 0xFF))
        out.append(UInt8((value >> 16) & 0xFF))
        out.append(UInt8((value >> 24) & 0xFF))
    }

    private static func readLittleEndian(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}
