//  AssetUpload.swift
//  FIR 系 7 種へ「資産」（設計済みの係数）を送り込む共通の口。
//
//  カーネルは出来上がった FIR 係数を受け取るだけで、係数の設計は JS 側にある。
//  その受け渡しの部分だけをここに集める。設計そのものは各担当のファイル。
//
//  --- ペイロードの並び（ETA1）---
//  出典は 2 つ。どちらも同じ並びを言っている。
//    書き手: Vendor/effetune/js/ir-library/ir-asset-payload.js:74-93 (buildIrAssetPayload)
//    読み手: Vendor/effetune/dsp/plugins/eq/five_band_fir_peq/kernel.cpp:282-288 (validatePayload)
//            Vendor/effetune/dsp/plugins/basics/fir_crossover/kernel.cpp:341-364 (validatePayload+decodeMatrixPaths)
//            Vendor/effetune/dsp/plugins/reverb/ir_reverb/kernel.cpp:486-496 (validatePayload)
//
//    +0  u32  magic 0x31415445
//    +4  u32  channels（IR のチャンネル数。1〜16）
//    +8  u32  frames（1 チャンネルあたりのサンプル数）
//    +12 u32  sampleRate（整数。IR Reverb だけ rate_divider で割った値）
//    +16 u32  topology（0 未指定 / 1 mono / 2 independent / 3 trueStereo / 4 matrix）
//    +20 u32  pathCount（matrix のときだけ。それ以外は 0）
//    +24 u32  0
//    +28 u32  0
//    +32      matrix のときだけ path が pathCount 個。1 個 12 バイトで
//             u32 inputSlot / u32 outputSlot / u32 irChannel
//    その後   float32 が channel-major（ch0 の frames 個、その後 ch1 …）
//
//  すべてリトルエンディアン。arm64 もリトルエンディアンなので、
//  係数の本体は Float の並びをそのまま写して構わない（頭の 32 バイトだけは
//  誤解が起きないよう 1 バイトずつ書いている）。
//
//  --- 送り込む手順 ---
//  Vendor/effetune/js/audio/dsp-engine-binding.js:663-682 の instanceSetAsset と同じ形。
//    1. ペイロードの頭から channels / frames / topology を読む（呼び出し側の指定が優先）
//    2. et_instance_asset_begin で書き込み先を取る
//    3. そこへペイロードをそのまま写す
//    4. et_instance_asset_commit する（format_tag は 1 = ET_ASSET_F32_MULTICH）
//    5. どこかで失敗したら et_instance_asset_abort
//
//  --- 音のスレッドとの競合をどう避けるか ---
//  ETPipeline.c は descriptor を「音のスレッドの頭で反映する」形にしているが、
//  資産は同じ形にしなかった。理由:
//
//    begin は確保を伴う。しかも小さくない。
//    kernel.cpp:170-210 を読むと、beginAsset は footprint + 1MiB の下見の確保を
//    1 回、staging を 1 回、さらに convolver_.reserve() で分割畳み込みの器を
//    作り直す。32MiB まで在り得る。commit 側も IR を分割して FFT に掛け直す。
//    これを音のスレッドの頭でやると、その 1 ブロックは確実に落ちる。
//
//  そこで逆向きにした。**音のスレッドを engine から締め出してから、UI スレッドで送る。**
//  締め出しに使うのは master bypass。engine.cpp:902-907 の processPipeline は
//  master_bypass != 0 のとき instance を 1 つも引かずに ET_OK で戻る。
//  つまり bypass を上げているあいだ、カーネルは誰にも触られていない。
//
//    1. いまの bypass の値を控えて 1 にする
//    2. ETPipeline_ProcessCount が 2 つ進むのを待つ（進まない＝鳴っていないので誰も読んでいない）
//    3. begin → 写す → commit
//    4. bypass を元に戻す
//
//  代償は、送り込んでいるあいだ鎖全体が素通しになること。数十 ms から数百 ms。
//  EffeTune 本体も（AudioWorklet スレッドの上で）同じ時間を止めているので、
//  質は変わらない。UI スレッドは待たされるが、資産を送るのは操作の瞬間だけ。
//
//  **音のスレッドからは絶対に呼ばない。**
//
//  --- 送った後にやること（呼び出し側） ---
//  commit が通ると instance の遅延が変わる。鎖の遅延合わせは
//  et_pipeline_configure が読み直すので、成功したら鎖を publish し直すこと。
//  JS も同じ場所で refreshDspPipelineForLatencyChange を呼んでいる
//  （plugins/audio-processor.js:3226）。

import Darwin
import Foundation
import os

// MARK: - 資産の形

/// ETA1 の topology。ir-asset-payload.js:5-11 と kernel.h の値が一致している。
enum ETAssetTopology: UInt32 {
    case unspecified = 0
    case mono = 1
    case independent = 2
    case trueStereo = 3
    case matrix = 4
}

/// matrix topology のときだけ要る経路。1 本 12 バイト。
struct ETAssetPath {
    var inputSlot: UInt32
    var outputSlot: UInt32
    var irChannel: UInt32

    init(inputSlot: UInt32, outputSlot: UInt32, irChannel: UInt32) {
        self.inputSlot = inputSlot
        self.outputSlot = outputSlot
        self.irChannel = irChannel
    }
}

/// et_instance_asset_state の生値。abi.h:86-93 と各カーネルの assetState()。
enum ETAssetState: UInt32 {
    case none = 0
    case staged = 1
    case preparing = 2
    case active = 3
    case error = 4
}

/// 生値をほどいたもの。
/// 下位 8bit が状態、次の 8bit が理由、bit16 が replacementDryReady。
/// 組み立ては five_band_fir_peq/kernel.cpp:259-263。
struct ETAssetStatus {
    let raw: UInt32

    var state: ETAssetState { ETAssetState(rawValue: raw & 0xFF) ?? .none }

    /// error のときだけ意味がある。1 = commit で弾かれた（並びか引数）、
    /// 2 = 確保できなかった（footprint 不足を含む）、3 = 畳み込み器が受け取れなかった。
    var reason: UInt32 { (raw >> 8) & 0xFF }

    /// 差し替えのために dry へ落とし切ったか。差し替え時の無音待ちに使う。
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
    case badSampleRate
    case badTopology
    case badPaths
    case sizeMismatch(expected: Int, actual: Int)
    case tooLarge(bytes: Int, capacity: Int)
    /// 書き込み先の番地が取れなかった。下の「64bit の口」を参照。
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

// MARK: - 送り込む口

enum AssetUpload {

    private static let log = Logger(subsystem: "ai.nemut.effetune", category: "asset")

    /// 頭の大きさ。全カーネル共通で 32（kAssetHeaderBytes）。
    static let headerBytes = 32
    /// 0x31415445。"ETA1" をリトルエンディアンで置いたもの。
    static let magic: UInt32 = 0x3141_5445
    /// 1 本の path の大きさ（kMatrixPathBytes）。
    static let pathBytes = 12
    /// ET_ASSET_F32_MULTICH。format_tag はこれ 1 つだけ。
    static let formatTagF32MultiChannel: UInt32 = 1
    /// 資産 1 枠の上限。7 種とも 32MiB（kAssetCapacity）。
    static let capacityBytes = 32 * 1024 * 1024

    // MARK: begin へ渡すもの

    /// et_instance_asset_begin の引数。
    /// channels / frames / topology は nil にするとペイロードの頭から読む
    /// （dsp-engine-binding.js:668-673 と同じで、明示があればそちらが勝つ）。
    struct BeginInfo {
        var channels: UInt32?
        var frames: UInt32?
        var topology: ETAssetTopology?
        /// 0 / 128 / 256 / 512 / 1024 のどれか。0 は「遅延なし」の意味で、
        /// カーネル側は 128 の頭ブロックを使う。
        var headBlock: UInt32
        /// 1 / 2 / 4。IR Reverb 以外は 1 しか受け取らない。
        var rateDivider: UInt32
        /// matrix のときだけ 1 以上。それ以外は 0 でないと弾かれる。
        var pathCount: UInt32
        var inputCount: UInt32
        /// このエフェクトが処理するチャンネル数。engine の maxChannels 以下。
        var processingChannels: UInt32
        /// 確保の見積り。nil なら estimateFootprintBytes で出す。
        /// ここを byteSize と同じにすると、畳み込み器の分が入らずに必ず落ちる
        /// （kernel.cpp:200 の `convolver_.memoryBytes() + byteSize > footprintBytes`）。
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

    /// 解決し終えた begin の引数。下の「64bit の口」へ渡す。
    struct BeginRequest {
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

    /// ETA1 のペイロードを組む。
    /// ir-asset-payload.js:59-96 (buildIrAssetPayload) をそのまま移したもの。
    ///
    /// - Parameters:
    ///   - channels: IR のチャンネル。長さは全部同じでないといけない
    ///   - sampleRate: 整数。IR Reverb で rate_divider を使うときは割った後の値
    ///   - topology: matrix 以外では paths を空にする
    static func makePayload(channels: [[Float]],
                            sampleRate: Int,
                            topology: ETAssetTopology = .unspecified,
                            paths: [ETAssetPath] = []) throws -> [UInt8] {
        guard !channels.isEmpty, channels.count <= 16 else { throw ETAssetUploadError.badChannelCount }
        let frames = channels[0].count
        guard frames > 0 else { throw ETAssetUploadError.badFrameCount }
        for channel in channels {
            guard channel.count == frames else { throw ETAssetUploadError.badChannelCount }
            for sample in channel where !sample.isFinite {
                throw ETAssetUploadError.badChannelCount
            }
        }
        guard sampleRate > 0, sampleRate <= 0xFFFF_FFFF else { throw ETAssetUploadError.badSampleRate }

        if topology == .matrix {
            guard !paths.isEmpty, paths.count <= 16 else { throw ETAssetUploadError.badPaths }
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

        // 係数の本体。arm64 はリトルエンディアンなので Float の並びがそのまま通る。
        for channel in channels {
            channel.withUnsafeBufferPointer { buffer in
                payload.append(contentsOf: UnsafeRawBufferPointer(buffer))
            }
        }
        return payload
    }

    // MARK: - 確保の見積り

    /// begin へ渡す footprintBytes。
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
        // カーネルが begin で触る上限（staging + 下見）
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

    /// 32MiB に収まる最大の frames を二分探索で出す。
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

    // MARK: - 送り込む

    /// begin → 写す → commit をまとめて行う。
    /// dsp-engine-binding.js:663-682 の instanceSetAsset と同じ形。
    ///
    /// **UI スレッドから呼ぶこと。** 送り込んでいるあいだ、音は素通しになる。
    /// 戻るまでに数十 ms から数百 ms かかるので、設計そのものは先に済ませておく。
    @MainActor
    static func send(engine: UInt32,
                     instance: UInt32,
                     slot: UInt32 = 0,
                     payload: [UInt8],
                     info: BeginInfo,
                     formatTag: UInt32 = AssetUpload.formatTagF32MultiChannel) throws {
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
        guard channels >= 1, channels <= 16 else { throw ETAssetUploadError.badChannelCount }
        guard frames >= 1 else { throw ETAssetUploadError.badFrameCount }

        // 大きさが合っているかを先に見る。合わないものを渡すと
        // カーネルは ERROR 状態のまま黙るので、ここで弾いたほうが分かりやすい。
        // 式は audio-processor.js:3040-3041 と同じ。
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
        guard footprint >= payload.count, footprint <= capacityBytes else {
            throw ETAssetUploadError.tooLarge(bytes: max(footprint, payload.count),
                                              capacity: capacityBytes)
        }

        let request = BeginRequest(engine: engine,
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

        // 書き込み先が取れない環境なら、確保させる前に落とす。
        guard canStage else { throw ETAssetUploadError.stagingAddressUnavailable }

        var thrown: Error?
        holdOffAudioThread {
            do {
                let staging = try beginStaging(request)
                payload.withUnsafeBytes { source in
                    if let base = source.baseAddress {
                        staging.copyMemory(from: base, byteCount: payload.count)
                    }
                }
                let status = et_instance_asset_commit(engine, instance, slot,
                                                      UInt32(payload.count), formatTag)
                guard Int(status) == ET_OK else {
                    // 失敗したら staging を握ったままにしない。
                    et_instance_asset_abort(engine, instance, slot)
                    throw ETAssetUploadError.commitFailed(status: Int32(status))
                }
            } catch {
                thrown = error
            }
        }
        if let error = thrown {
            log.error("asset 送り込み失敗 instance=\(instance) slot=\(slot) \(String(describing: error))")
            throw error
        }
        log.notice("asset 送り込み instance=\(instance) slot=\(slot) bytes=\(payload.count) ch=\(channels) frames=\(frames) topology=\(rawTopology)")
    }

    /// 係数から組んで送るところまで。設計側はふつうこちらを呼べばよい。
    @MainActor
    static func send(engine: UInt32,
                     instance: UInt32,
                     slot: UInt32 = 0,
                     channels: [[Float]],
                     sampleRate: Int,
                     topology: ETAssetTopology,
                     paths: [ETAssetPath] = [],
                     headBlock: UInt32 = 128,
                     rateDivider: UInt32 = 1,
                     processingChannels: UInt32 = 2) throws {
        let payload = try makePayload(channels: channels,
                                      sampleRate: sampleRate,
                                      topology: topology,
                                      paths: paths)
        // matrix 以外は pathCount も inputCount も 0 でないと engine に弾かれる
        // （engine.cpp:505-506）。
        var inputSlots = Set<UInt32>()
        if topology == .matrix {
            for path in paths { inputSlots.insert(path.inputSlot) }
        }
        let inputCount = UInt32(inputSlots.count)
        let info = BeginInfo(topology: topology,
                             headBlock: headBlock,
                             rateDivider: rateDivider,
                             pathCount: topology == .matrix ? UInt32(paths.count) : 0,
                             inputCount: inputCount,
                             processingChannels: processingChannels)
        try send(engine: engine, instance: instance, slot: slot, payload: payload, info: info)
    }

    /// 資産を外す。素通しに戻る。
    @MainActor
    static func clear(engine: UInt32, instance: UInt32, slot: UInt32 = 0) {
        guard engine != 0, instance != 0 else { return }
        holdOffAudioThread {
            et_instance_asset_abort(engine, instance, slot)
        }
    }

    // MARK: - 送り込めているか

    /// et_instance_asset_state を包んだもの。
    /// commit の直後は preparing で、音が何ブロックか通ってから active になる
    /// （畳み込み器が分割を積み終わるのが process の中だから）。
    /// 無音で休んでいるあいだは preparing のまま進まない。
    static func status(engine: UInt32, instance: UInt32, slot: UInt32 = 0) -> ETAssetStatus {
        guard engine != 0, instance != 0 else { return ETAssetStatus(raw: 0) }
        return ETAssetStatus(raw: et_instance_asset_state(engine, instance, slot))
    }

    /// active になるまで待つ。音が鳴っていないと進まないので、必ず期限を切る。
    /// 画面に「かけ始めました」を出すときに使う。
    @MainActor
    static func waitForActive(engine: UInt32,
                              instance: UInt32,
                              slot: UInt32 = 0,
                              timeout: TimeInterval = 2.0) async -> ETAssetStatus {
        let deadline = Date().addingTimeInterval(timeout)
        var current = status(engine: engine, instance: instance, slot: slot)
        while current.state == .preparing || current.state == .staged {
            if Date() >= deadline { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
            current = status(engine: engine, instance: instance, slot: slot)
        }
        return current
    }

    // MARK: - 64bit の口

    // ここが今のところ塞がっている。
    //
    // abi.cpp:170-185 の et_instance_asset_begin は
    //   return static_cast<std::uint32_t>(reinterpret_cast<std::uintptr_t>(staging));
    // と書いてあって、番地を uint32 に切り落としている。WASM（32bit）では
    // これで足りるが、arm64 では上位 32bit が落ちて使えない番地になる。
    // dsp 側も native のテストでは C++ の Engine::beginInstanceAsset を直に呼んでいて
    // （plugins/eq/five_band_fir_peq/native_test.cpp:90）、この口は通っていない。
    //
    // Vendor を書き換えずに済ませるため、番地を返す口があればそちらを使う。
    // abi.cpp に次の 1 本を足せば、ここは自動で繋がる:
    //
    //   ET_EXPORT uint8_t *et_instance_asset_begin_ptr(
    //       et_engine engine, et_instance instance, uint32_t slot,
    //       uint32_t channels, uint32_t frames, uint32_t topology,
    //       uint32_t head_block, uint32_t rate_divider,
    //       uint32_t path_count, uint32_t input_count,
    //       uint32_t processing_channels, uint32_t footprint_bytes,
    //       uint32_t byte_size);
    //
    // 別の形で通したいときは stagingAddressProvider に入れる。

    private typealias BeginPointerFunction = @convention(c) (
        UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
        UInt32, UInt32, UInt32, UInt32, UInt32, UInt32
    ) -> UnsafeMutableRawPointer?

    /// 呼び出し側が自前で書き込み先を用意したいときの差し込み口。
    /// nil のあいだは下の dlsym → 32bit の口、の順に探す。
    static var stagingAddressProvider: ((BeginRequest) -> UnsafeMutableRawPointer?)?

    private static let beginPointer: BeginPointerFunction? = {
        // RTLD_DEFAULT。同じ実行ファイルに入っているので、これで見つかる。
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                                 "et_instance_asset_begin_ptr") else { return nil }
        return unsafeBitCast(symbol, to: BeginPointerFunction.self)
    }()

    /// 資産を送り込める build かどうか。画面に出す前の判断に使える。
    static var canStage: Bool {
        stagingAddressProvider != nil
            || beginPointer != nil
            || MemoryLayout<UnsafeRawPointer>.size == 4
    }

    private static func beginStaging(_ request: BeginRequest) throws -> UnsafeMutableRawPointer {
        if let provider = stagingAddressProvider {
            guard let staging = provider(request) else { throw ETAssetUploadError.beginRejected }
            return staging
        }
        if let begin = beginPointer {
            guard let staging = begin(request.engine, request.instance, request.slot,
                                      request.channels, request.frames, request.topology,
                                      request.headBlock, request.rateDivider,
                                      request.pathCount, request.inputCount,
                                      request.processingChannels, request.footprintBytes,
                                      request.byteSize) else {
                throw ETAssetUploadError.beginRejected
            }
            return staging
        }
        // ポインタが 32bit の環境（WASM）でだけ、abi.h の口がそのまま使える。
        if MemoryLayout<UnsafeRawPointer>.size == 4 {
            let address = et_instance_asset_begin(
                request.engine, request.instance, request.slot,
                request.channels, request.frames, request.topology,
                request.headBlock, request.rateDivider,
                request.pathCount, request.inputCount,
                request.processingChannels, request.footprintBytes,
                request.byteSize
            )
            guard let staging = UnsafeMutableRawPointer(bitPattern: UInt(address)) else {
                throw ETAssetUploadError.beginRejected
            }
            return staging
        }
        log.error("et_instance_asset_begin は番地を uint32 に切り落とす。64bit では使えない")
        throw ETAssetUploadError.stagingAddressUnavailable
    }

    // MARK: - 音のスレッドを締め出す

    /// bypass を上げて、音のスレッドが engine に触らなくなってから body を回す。
    /// engine.cpp:902-907 のとおり、master_bypass のときは instance を 1 つも引かない。
    @MainActor
    private static func holdOffAudioThread(_ body: () -> Void) {
        // 利用者が入れている bypass は壊さない。
        let userBypass = EffeTuneDSP.shared.bypass
        ETPipeline_SetBypass(1)
        defer { ETPipeline_SetBypass(userBypass ? 1 : 0) }

        // bypass を上げる前に始まっていたブロックを追い出す。
        // 2 つ進めば、いま回っているブロックは bypass を見た後のもの。
        // 進まないのは鳴っていないときで、そのときは誰も engine を読んでいない。
        let mark = ETPipeline_ProcessCount()
        let deadline = Date().addingTimeInterval(0.05)
        while ETPipeline_ProcessCount() < mark &+ 2 && Date() < deadline {
            usleep(1000)
        }
        body()
    }

    // MARK: - 細かい道具

    private struct Stage {
        let block: Int
        let offset: Int
        let segmentFrames: Int
    }

    /// ir-plugin-contract.js:57-72 (convolutionStages)。
    private static func convolutionStages(frames: Int, headBlock: Int) -> [Stage] {
        let head = headBlock == 0 ? 128 : headBlock
        var stages = [Stage]()
        func add(_ block: Int, _ offset: Int, _ end: Int) {
            if offset >= frames || end <= offset { return }
            stages.append(Stage(block: block, offset: offset, segmentFrames: min(end, frames) - offset))
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
    private static func resolvedPathCount(_ topology: ETAssetTopology,
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
    private static func resolvedInputCount(_ topology: ETAssetTopology,
                                           _ processingChannels: Int,
                                           _ inputCount: Int) -> Int {
        switch topology {
        case .trueStereo: return 2
        case .matrix: return inputCount
        case .mono, .independent, .unspecified: return processingChannels
        }
    }

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
