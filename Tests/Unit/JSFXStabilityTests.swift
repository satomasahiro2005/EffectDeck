//  JSFXStabilityTests.swift
//  スクリプトが悪くても host の外へ漏らさないこと。
//
//  見ているのは 6 つ:
//    - 出力の NaN・Inf・非正規化数は 0 になって出る（後段の IIR が戻らなくなるから）
//    - @serialize は書いている最中に 16 MiB で止まる。保存できたものは必ず読み戻せる
//    - プリプロセッサの展開結果にも 1 MB の上限が掛かる
//    - pdc_delay は 0〜192000 に切られる
//    - @slider のブロックを締切から外すのは続けて 16 回まで
//    - 保守（SaveState / Reconfigure / Destroy）は 1 本ずつ
//
//  保守の試験は**途中の値を見ない**（JSFXRaceTests と同じ理由）。どの順で
//  重なっても成り立つことだけを見る。

import XCTest
import Foundation

/// 別のスレッドで取った状態を溜める。
private final class JSFXSaved {
    private let lock = NSLock()
    private var items: [Data?] = []
    func add(_ data: Data?) { lock.lock(); items.append(data); lock.unlock() }
    var all: [Data?] { lock.lock(); defer { lock.unlock() }; return items }
}

/// 別のスレッドで立てる印。
private final class JSFXFlag {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

final class JSFXStabilityTests: XCTestCase {

    private let frames = JSFX.maxFrames

    @discardableResult
    private func block(_ host: JSFXHost, frames: UInt32) -> Int32 {
        var planar = JSFX.signal(channels: 2, frames: frames)
        return host.process(&planar, channels: 2, frames: frames)
    }

    private func output(_ host: JSFXHost, mode: Double) -> [Float] {
        host.set(0, mode)
        var planar = [Float](repeating: 0.25, count: 2 * Int(frames))
        XCTAssertEqual(host.process(&planar, channels: 2, frames: frames), 0)
        return planar
    }

    // MARK: - 出力を拭く

    /// 1/0（Inf）、-1/0（-Inf）、float で非正規化数になる 1e-40 は 0 で出る。
    /// Inf は後段の biquad に入ると帰還を NaN にして戻らない。
    func testNonFiniteAndDenormalOutputLeavesAsZero() throws {
        let host = try JSFX.load("nonfinite")
        for mode in [0.0, 1.0] {
            let out = output(host, mode: mode)
            XCTAssertTrue(out.allSatisfy { $0 == 0 }, "mode \(mode) が 0 以外で出た: \(out[0]), \(out[Int(frames)])")
        }
        let out = output(host, mode: 2)
        XCTAssertTrue(JSFX.channel(0, of: out, frames: frames).allSatisfy { $0 == 0 }, "log(0) が残った")
        for value in JSFX.channel(1, of: out, frames: frames) {
            XCTAssertEqual(value, 0.125, accuracy: 1e-6)
        }
    }

    /// 普通の値には触らない。
    func testFiniteOutputIsUntouched() throws {
        let host = try JSFX.load("nonfinite")
        let out = output(host, mode: 3)
        for value in out { XCTAssertEqual(value, 0.125, accuracy: 1e-6) }
    }

    // MARK: - @serialize の大きさ

    /// file_mem(0, 0, 1e9) は 4 GB 書こうとする。**書いている最中に止まって false。**
    /// 止まらなければ、上限の比較に着く前にメモリで落ちる。
    func testRunawaySerializeIsRefusedWhileWriting() throws {
        let host = try JSFX.load("serialize_size")
        host.set(0, 1e9)
        XCTAssertNil(host.save())
        XCTAssertTrue(host.isRunning, "断ったあと音へ戻っていない")

        host.set(0, 16)
        let saved = try XCTUnwrap(host.save())
        XCTAssertTrue(host.load(saved))
    }

    /// **保存できたものは必ず読み戻せる。**枠（12 + 12n バイト）のぶん上限を
    /// 超えたものは、保存の時点で断る（読み戻しで断られると状態ごと失う）。
    func testEverySavedStateCanBeLoaded() throws {
        let host = try JSFX.load("serialize_size")
        host.set(0, 4_194_000)                  // 16 MiB より少し小さい
        let fits = try XCTUnwrap(host.save())
        XCTAssertTrue(host.load(fits))

        host.set(0, 4_194_303)                  // payload は収まるが、枠を足すと超える
        XCTAssertNil(host.save())
    }

    // MARK: - プリプロセッサ

    /// 15 バイトの `<? ?>` が 7 MB の本文になる。展開した後にも上限を掛ける。
    func testOversizedPreprocessorOutputIsRejected() throws {
        let result = try JSFX.open("preprocess_large")
        XCTAssertNil(result.raw)
        XCTAssertTrue(result.message.contains("Preprocessed source exceeds the 1 MB limit."),
                      result.message)
    }

    /// 上限の内側の `<? ?>` はそのまま動く。
    func testSmallPreprocessorBlockStillCompiles() throws {
        let host = try JSFX.load("preprocess_small")
        host.set(0, 0.5)
        let input = JSFX.signal(channels: 2, frames: frames)
        var planar = input
        XCTAssertEqual(host.process(&planar, channels: 2, frames: frames), 0)
        for (index, value) in planar.enumerated() {
            XCTAssertEqual(value, input[index] * 0.5, accuracy: 1e-6, "sample \(index)")
        }
    }

    // MARK: - 遅延

    /// 上限を超える値と Inf は 192000、NaN は 0。**切った値でも変化は 1 度だけ出す。**
    func testLatencyIsClamped() throws {
        let host = try JSFX.load("pdc_slider")
        host.set(0, 1e12)
        host.run(blocks: 1)
        XCTAssertEqual(host.latency, 192_000)
        XCTAssertTrue(ETJSFX_ConsumeLatencyChange(host.raw))

        host.set(0, .infinity)
        host.run(blocks: 1)
        XCTAssertEqual(host.latency, 192_000)
        XCTAssertFalse(ETJSFX_ConsumeLatencyChange(host.raw), "切った後が同じなら変化ではない")

        host.set(0, .nan)
        host.run(blocks: 1)
        XCTAssertEqual(host.latency, 0)

        host.set(0, 128)
        host.run(blocks: 1)
        XCTAssertEqual(host.latency, 128)
    }

    // MARK: - 締切

    /// つまみを回し続けて毎ブロックが @slider のブロックになっても、**永久には外さない。**
    /// 16 回までは外す（REAPER と同じく、回している間の重さでは落とさない）。
    func testBackToBackSliderBlocksCannotHideOverrunsForever() throws {
        let host = try JSFX.load("slow", maxFrames: JSFX.deadlineFrames)
        var blocks = 0
        while host.isRunning && blocks < 60 {
            host.set(0, blocks % 2 == 0 ? JSFX.spin : JSFX.spin - 1)
            block(host, frames: JSFX.deadlineFrames)
            blocks += 1
        }
        XCTAssertFalse(host.isRunning, "@slider のブロックが続く限り判定に入らない")
        XCTAssertGreaterThan(blocks, 16, "@slider のブロックを外していない")
        XCTAssertEqual(host.diagnostic, "Repeated audio deadline overruns; JSFX was bypassed.")
    }

    /// 同じ値を送り直しても @slider は走らない。**走らないブロックは外さない。**
    func testResendingTheSameSliderValueIsNotExempt() throws {
        let host = try JSFX.load("slow", maxFrames: JSFX.deadlineFrames)
        host.set(0, JSFX.spin)
        block(host, frames: JSFX.deadlineFrames)    // 値が変わる。ここは外す
        var blocks = 0
        while host.isRunning && blocks < 12 {
            host.set(0, JSFX.spin)
            block(host, frames: JSFX.deadlineFrames)
            blocks += 1
        }
        XCTAssertFalse(host.isRunning, "同じ値を送るだけで締切から外れ続けている")
    }

    // MARK: - 保守は 1 本ずつ

    /// 2 本の SaveState を重ねても、どちらも 1 本だけで取ったものと同じ。
    /// @serialize は file 0 の buffer を共有するので、重なると互いに書き込む。
    func testConcurrentSaveStatesReturnTheSameState() throws {
        let host = try JSFX.load("serialize_size")
        host.set(0, 500_000)
        let reference = try XCTUnwrap(host.save())
        let raw = host.raw
        let group = DispatchGroup()
        let saved = JSFXSaved()

        withExtendedLifetime(host) {
            for _ in 0..<2 {
                DispatchQueue.global(qos: .userInitiated).async(group: group) {
                    for _ in 0..<10 {
                        var bytes: UnsafeMutablePointer<UInt8>?
                        var size = 0
                        var data: Data?
                        if ETJSFX_SaveState(raw, &bytes, &size), let bytes {
                            data = Data(bytes: bytes, count: size)
                            ETJSFX_FreeBytes(UnsafeMutableRawPointer(bytes))
                        }
                        saved.add(data)
                    }
                }
            }
            XCTAssertEqual(group.wait(timeout: .now() + 120), .success, "止まった")
        }
        let results = saved.all
        XCTAssertEqual(results.count, 20)
        XCTAssertTrue(results.allSatisfy { $0 == reference }, "重なった SaveState の中身が化けた")
        XCTAssertTrue(host.isRunning)
    }

    /// 自動バイパス中に SaveState と Reconfigure が重なっても、バイパスは解けない（§14）。
    /// 解けるのは ClearDiagnostic だけ。**途中でも開かない**: 後から来た Reconfigure が
    /// 先に終わって running へ戻すと、@serialize の最中に音が VM へ入る。
    func testOverlappingMaintenanceKeepsAutomaticBypass() throws {
        let host = try bypassedSlowSerializeHost()
        let raw = host.raw
        let group = DispatchGroup()
        let saved = JSFXFlag()
        var opened = 0
        withExtendedLifetime(host) {
            DispatchQueue.global(qos: .utility).async(group: group) {
                var bytes: UnsafeMutablePointer<UInt8>?
                var size = 0
                if ETJSFX_SaveState(raw, &bytes, &size), let bytes {
                    ETJSFX_FreeBytes(UnsafeMutableRawPointer(bytes))
                }
                saved.set()
            }
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                Thread.sleep(forTimeInterval: 0.005)
                _ = ETJSFX_Reconfigure(raw, JSFX.sampleRate, JSFX.deadlineFrames)
            }
            while !saved.isSet { if ETJSFX_IsRunning(raw) { opened += 1 }; usleep(20) }
            XCTAssertEqual(group.wait(timeout: .now() + 120), .success, "止まった")
        }
        XCTAssertEqual(opened, 0, "SaveState の最中に音の口が開いた")
        XCTAssertFalse(host.isRunning, "保守が重なってバイパスが解けた")
        XCTAssertEqual(host.diagnostic, "Repeated audio deadline overruns; JSFX was bypassed.")
    }

    /// 保存の最中に Re-enable を押しても、**素通しなのに札が無い**状態にはならない。
    /// 戻せなかったら（false）診断が残り、戻せたら（true）走っている。
    func testReenableDuringSaveStateNeverHidesTheBypass() throws {
        let host = try bypassedSlowSerializeHost()
        let raw = host.raw
        let group = DispatchGroup()
        var cleared = false
        withExtendedLifetime(host) {
            DispatchQueue.global(qos: .utility).async(group: group) {
                var bytes: UnsafeMutablePointer<UInt8>?
                var size = 0
                if ETJSFX_SaveState(raw, &bytes, &size), let bytes {
                    ETJSFX_FreeBytes(UnsafeMutableRawPointer(bytes))
                }
            }
            Thread.sleep(forTimeInterval: 0.01)
            cleared = ETJSFX_ClearDiagnostic(raw)
            XCTAssertEqual(group.wait(timeout: .now() + 120), .success, "止まった")
        }
        if cleared {
            XCTAssertTrue(host.isRunning)
        } else {
            XCTAssertFalse(host.isRunning)
            XCTAssertFalse(host.diagnostic.isEmpty, "素通しのまま札が消えた")
            XCTAssertTrue(ETJSFX_ClearDiagnostic(raw), "保存の後でも戻せない")
            XCTAssertTrue(host.isRunning)
        }
    }

    /// **Destroy は走っている SaveState を待つ。**待たずに消すと、@serialize が
    /// 解放済みの VM の上で走り続ける。
    func testDestroyWaitsForARunningSaveState() throws {
        let result = try JSFX.open("serialize_size")
        let raw = try XCTUnwrap(result.raw)
        ETJSFX_SetSlider(raw, 1, 20_000)        // @serialize で 2000 万回回す
        let finished = JSFXFlag()
        let group = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: group) {
            var bytes: UnsafeMutablePointer<UInt8>?
            var size = 0
            if ETJSFX_SaveState(raw, &bytes, &size), let bytes {
                ETJSFX_FreeBytes(UnsafeMutableRawPointer(bytes))
            }
            finished.set()
        }
        // SaveState が maintenance へ入るのを待つ。
        let deadline = Date().addingTimeInterval(10)
        while ETJSFX_IsRunning(raw) && !finished.isSet && Date() < deadline { usleep(50) }
        if finished.isSet {
            ETJSFX_Destroy(raw)
            throw XCTSkip("SaveState が先に終わった（重ねられなかった）")
        }
        ETJSFX_Destroy(raw)
        // Destroy が待つのは users が 0 になるまで。users は SaveState が錠を放した後、
        // Swift へ戻る前に減るので、finished.set() はまだ走っていないことがある。
        // 戻ってすぐ終わる（@serialize を待たされていない）ことを見る。
        XCTAssertEqual(group.wait(timeout: .now() + 1), .success, "Destroy の後も SaveState が戻らない")
        XCTAssertTrue(finished.isSet, "SaveState の最中に解放した")
    }

    /// slow_serialize を自動バイパスまで追い込む。@serialize は 300 万回回る。
    private func bypassedSlowSerializeHost() throws -> JSFXHost {
        let host = try JSFX.load("slow_serialize", maxFrames: JSFX.deadlineFrames)
        host.set(0, JSFX.spin)
        host.set(1, 3000)
        var blocks = 0
        while host.isRunning && blocks < 12 {
            block(host, frames: JSFX.deadlineFrames)
            blocks += 1
        }
        XCTAssertFalse(host.isRunning, "自動バイパスへ落ちない")
        return host
    }
}
