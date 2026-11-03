//  RoomEQDesigner.swift
//  Room EQ（RoomEqPlugin）の補正 FIR を instance へ送り込む。
//  設計そのもの（design-core.js の min / lin の移し）は RoomEQDesign.swift。
//
//  元は Vendor/effetune/js/room-eq/design-worker.js（設計→ペイロード）と
//  plugins/eq/room_eq.js（作り直しの待ち・世代）。
//
//  --- ペイロードの並び（ETA1）---
//  読み手: dsp/plugins/eq/room_eq/kernel.cpp:311-318 (validatePayload)
//            +0  u32 magic 0x31415445
//            +4  u32 channels      … begin へ渡した channels と一致すること
//            +8  u32 frames        … 同上
//            +12 u32 sampleRate    … std::lround(sample_rate_) と一致すること
//            +16 u32 topology      … 同上
//            +20/+24/+28 u32 0
//          dsp/plugins/eq/room_eq/kernel.cpp:249-250
//            頭の 32 バイトの直後から float32 が channel-major で channels*frames 個。
//            そのまま convolver_.commit(samples, channels, frames) へ渡される
//  書き手: js/ir-library/ir-asset-payload.js:59-96 (buildIrAssetPayload)
//          js/room-eq/design-worker.js:21-27
//            topology は channels.length > 1 なら independent、そうでなければ mono
//            sampleRate は result.config.sampleRate（正規化後の整数）
//
//  --- begin の制約（kernel.cpp:292-309 validateBegin）---
//    topology=mono なら channels==1、independent なら channels==processingChannels
//    frames は 1〜131072
//    headBlock は 0 / 128 / 256 / 512 / 1024 のどれか
//    rateDivider==1、pathCount==0、inputCount==0
//    byteSize == 32 + channels*frames*4
//    **filterDelaySamples（fd）が 0〜65536 の範囲に入っていること。**
//    fd は begin の時点のパラメータが読まれる（kernel.cpp:232-233 で
//    candidate_latency_ = headBlock + fd）。だから送り込む前に
//    RoomEQDesign.filterDelaySamples と latencyMode を先にパラメータへ書くこと。
//    順番を逆にすると、遅延だけ前の設計のまま残る。
//
//  --- 重さ ---
//  設計は重い（RoomEQDesign.swift の頭）。RoomEQCorrection が Task.detached で外へ出し、
//  出来上がってから MainActor で送る。JS も Worker でやっている（js/room-eq/designer.js:1-10）。

import Combine
import Foundation
import os

// MARK: - 送り込む

extension RoomEQDesigner {

    // 名前を log にすると Foundation の log() が隠れて自然対数が呼べなくなる。
    fileprivate static let logger = Logger(subsystem: "ai.nemut.effetune", category: "roomeq")

    /// 出来上がった係数を instance の枠 0 へ送る。
    ///
    /// **先にパラメータ（fd / lt）を書いてから呼ぶこと。** カーネルは begin の時点の
    /// fd を読んで遅延を決める（kernel.cpp:232-233）。
    @MainActor
    static func send(design: RoomEQDesign,
                     engine: UInt32,
                     instance: UInt32,
                     slot: UInt32 = 0,
                     processingChannels: UInt32,
                     latencyMode: UInt32 = 128) throws {
        guard !design.channels.isEmpty else { throw RoomEQDesignError.noSources }
        guard allowedLatencyModes.contains(latencyMode) else {
            throw RoomEQDesignError.invalidLatencyMode(latencyMode)
        }
        // design-worker.js:24-26 と同じ決め方。
        let topology: ETAssetTopology = design.channels.count > 1 ? .independent : .mono
        // kernel.cpp:293-295。mono は 1 チャンネル、independent は処理幅と一致。
        if topology == .independent && UInt32(design.channels.count) != processingChannels {
            throw RoomEQDesignError.channelCountMismatch(assetChannels: design.channels.count,
                                                          processingChannels: Int(processingChannels))
        }
        try AssetUpload.send(engine: engine,
                             instance: instance,
                             slot: slot,
                             channels: design.channels,
                             sampleRate: design.sampleRate,
                             topology: topology,
                             headBlock: latencyMode,
                             rateDivider: 1,
                             processingChannels: processingChannels)
        logger.notice("room eq 送り込み ch=\(design.channels.count) taps=\(design.taps) fd=\(design.filterDelaySamples)")
    }
}

// MARK: - 作り直しと送り直し

/// パラメータが変わったら設計し直して送り直す係。
/// room_eq.js:1770-1774 の _scheduleDesign と同じで、150ms 待ってからまとめて 1 回だけ
/// 設計する。設計は Task.detached で外へ出す（JS は Worker：designer.js:1-10）。
/// 途中で新しい注文が来たら、古い結果は世代番号で捨てる（room_eq.js:1843-1846）。
@MainActor
final class RoomEQCorrection: ObservableObject {

    enum State: Equatable {
        case idle
        case designing
        case sending
        /// 送り込み済み。カーネルが active になるのは音が何ブロックか通った後。
        case sent
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var design: RoomEQDesign?
    /// カーネルの資産の様子。送った後に読むと preparing → active と進む。
    @Published private(set) var assetState: ETAssetState = .none

    private var task: Task<Void, Never>?
    private var generation = 0

    init() {}

    /// 設計と送り込みを予約する。既に予約が在れば捨てて取り直す。
    /// - Parameter delay: まとめる待ち時間。既定 150ms は room_eq.js:1770 と同じ。
    func schedule(config: RoomEQConfig,
                  sources: [RoomEQSource?],
                  engine: UInt32,
                  instance: UInt32,
                  slot: UInt32 = 0,
                  processingChannels: UInt32,
                  latencyMode: UInt32 = 128,
                  delay: Duration = .milliseconds(150),
                  onDesigned: ((RoomEQDesign) -> Void)? = nil) {
        generation += 1
        let generation = self.generation
        task?.cancel()
        state = .designing
        // この Task は @MainActor の中で作るので、中身も MainActor で走る。
        // 外へ出るのは下の Task.detached だけ。
        task = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            if Task.isCancelled { return }
            guard let self, self.isCurrent(generation) else { return }

            do {
                try RoomEQDesigner.checkCapacity(config: config,
                                                 channelCount: sources.count,
                                                 processingChannels: Int(processingChannels),
                                                 latencyMode: latencyMode)
            } catch {
                self.finish(generation, failure: error)
                return
            }

            // 重いのは全部ここ。音のスレッドにも MainActor にも乗せない。
            let designed = await Task.detached(priority: .userInitiated) {
                RoomEQDesigner.design(config: config, sources: sources)
            }.value

            if Task.isCancelled { return }
            guard self.isCurrent(generation) else { return }
            self.publish(generation, design: designed)
            // 出来上がった遅延を先にパラメータへ書かせる。カーネルは begin の時点の
            // fd を読む（kernel.cpp:232-233）ので、送るより前でないと効かない。
            onDesigned?(designed)

            do {
                try RoomEQDesigner.send(design: designed,
                                        engine: engine,
                                        instance: instance,
                                        slot: slot,
                                        processingChannels: processingChannels,
                                        latencyMode: latencyMode)
            } catch {
                self.finish(generation, failure: error)
                return
            }
            guard self.isCurrent(generation) else { return }
            let status = await AssetUpload.waitForActive(engine: engine,
                                                         instance: instance,
                                                         slot: slot)
            self.finish(generation, status: status)
        }
    }

    /// 予約を取り消す。送り込み済みのものは外さない。
    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        if state == .designing || state == .sending { state = .idle }
    }

    /// 資産を外して素通しに戻す。
    func clear(engine: UInt32, instance: UInt32, slot: UInt32 = 0) {
        cancel()
        AssetUpload.clear(engine: engine, instance: instance, slot: slot)
        design = nil
        assetState = .none
        state = .idle
    }

    private func isCurrent(_ generation: Int) -> Bool {
        self.generation == generation
    }

    private func publish(_ generation: Int, design: RoomEQDesign) {
        guard isCurrent(generation) else { return }
        self.design = design
        state = .sending
    }

    private func finish(_ generation: Int, status: ETAssetStatus) {
        guard isCurrent(generation) else { return }
        assetState = status.state
        state = .sent
    }

    private func finish(_ generation: Int, failure: Error) {
        guard isCurrent(generation) else { return }
        let message = (failure as? LocalizedError)?.errorDescription ?? "The correction could not be loaded."
        state = .failed(message)
    }
}