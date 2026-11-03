//  AssetUpload.swift
//  FIR 系 7 種へ「資産」（設計済みの係数）を送り込む共通の口。
//
//  カーネルは出来上がった FIR 係数を受け取るだけで、係数の設計は JS 側にある。
//  その受け渡しの部分だけをここに集める。設計そのものは各担当のファイル。
//
//  ペイロードの並び（ETA1）・確保の見積り・begin の引数の解決は AssetPayload.swift にある
//  （同じ enum AssetUpload。Foundation だけなので単体テストのバンドルへ入る）。
//  ここに残したのは、エンジンの C 関数を呼ぶところと、音のスレッドを締め出すところ。
//
//  --- 送り込む手順 ---
//  Vendor/effetune/js/audio/dsp-engine-binding.js:663-682 の instanceSetAsset と同じ形。
//    1. ペイロードの頭から channels / frames / topology を読む（呼び出し側の指定が優先）
//       （AssetUpload.beginRequest。送る前に弾けるものはそこで全部弾く）
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

// MARK: - 送り込む口

extension AssetUpload {

    private static let log = Logger(subsystem: "ai.nemut.effetune", category: "asset")

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
                     formatTag: UInt32 = AssetUpload.formatTagF32MultiChannel,
                     capacity: Int = AssetUpload.capacityBytes) throws {
        // capacity は 1 枠の上限。FIR 系の 7 種は 32MiB、SFZ Note Player は 1GiB（sfz_note_player/bank.h の kCapacity）。
        let request = try beginRequest(engine: engine,
                                       instance: instance,
                                       slot: slot,
                                       payload: payload,
                                       info: info,
                                       capacity: capacity)

        // 書き込み先が取れない環境なら、確保させる前に落とす。
        guard canStage else { throw ETAssetUploadError.stagingAddressUnavailable }

        // **渡す値を全部出す。** カーネルの validateBegin は理由を返さないので、
        // 弾かれたときはこの行と条件表を突き合わせるしかない。
        if ETConsoleLog.on {
            print("asset begin ch=\(request.channels) frames=\(request.frames)"
                  + " topo=\(request.topology) head=\(request.headBlock)"
                  + " div=\(request.rateDivider) paths=\(request.pathCount)"
                  + " inputs=\(request.inputCount) proc=\(request.processingChannels)"
                  + " footprint=\(request.footprintBytes) bytes=\(request.byteSize)")
        }

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
            let line = "asset 送り込み失敗 instance=\(instance) slot=\(slot) \(String(describing: error))"
            log.error("\(line, privacy: .public)")
            ETLogTap.record(line)
            if ETConsoleLog.on { print(line) }
            throw error
        }
        log.notice("asset 送り込み instance=\(instance) slot=\(slot) bytes=\(payload.count) ch=\(request.channels) frames=\(request.frames) topology=\(request.topology)")
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
        let info = beginInfo(topology: topology,
                             paths: paths,
                             headBlock: headBlock,
                             rateDivider: rateDivider,
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
            // 打ち切られたら降りる。Task.sleep は打ち切られた後 `try?` で
            // すぐ返るので、ここを見ないと期限まで MainActor を回し続ける。
            if Task.isCancelled { break }
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

    /// 呼び出し側が自前で書き込み先を用意したいときの差し込み口。
    /// nil のあいだは abi.h の 64bit の口を直に呼ぶ。
    static var stagingAddressProvider: ((BeginRequest) -> UnsafeMutableRawPointer?)?

    /// 資産を送り込める build かどうか。画面に出す前の判断に使える。
    ///
    /// **dlsym で探さない。**以前は `et_instance_asset_begin_ptr` を
    /// `dlsym(RTLD_DEFAULT, ...)` で引いていたが、**Release は実行ファイルの
    /// シンボルを strip する**ので、Debug では見つかって TestFlight と App Store
    /// では見つからない。出荷した ipa を `nm` で見ると `asset_begin` は 0 件だった。
    /// 宣言は abi.h に ET_EXPORT 付きで在るので、直に呼べばリンク時に解決される。
    /// パッチが当たっていない木では**ビルドが止まる**が、利用者の手元で
    /// 「IR を入れられない」になるより、そちらのほうが早く気づける。
    static var canStage: Bool { true }

    private static func beginStaging(_ request: BeginRequest) throws -> UnsafeMutableRawPointer {
        if let provider = stagingAddressProvider {
            guard let staging = provider(request) else { throw ETAssetUploadError.beginRejected }
            return staging
        }
        guard let staging = et_instance_asset_begin_ptr(
            request.engine, request.instance, request.slot,
            request.channels, request.frames, request.topology,
            request.headBlock, request.rateDivider,
            request.pathCount, request.inputCount,
            request.processingChannels, request.footprintBytes,
            request.byteSize
        ) else {
            throw ETAssetUploadError.beginRejected
        }
        return UnsafeMutableRawPointer(staging)
    }

    // MARK: - 音のスレッドを締め出す

    /// bypass を上げて、音のスレッドが engine に触らなくなってから body を回す。
    /// engine.cpp:902-907 のとおり、master_bypass のときは instance を 1 つも引かない。
    @MainActor
    static func holdOffAudioThread(_ body: () -> Void) {
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
}
