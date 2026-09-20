//  JSFXDeadlineTests.swift
//  締切超過と自動バイパス。設計 §13（D01-D04）。
//
//  **ここだけ時間に依存する。**だから余裕を大きく取る。
//
//    - 重いブロック: slow.jsfx を上限（1 サンプルあたり 20000 回のループ）で回す。
//      持ち時間 1/48000 秒（20.8 µs）に対して通訳実行で 10 倍以上掛かる。
//    - 軽いブロック: 同じ fixture を 0 回に落とす。512 フレーム＝持ち時間 10.6 ms。
//      実行機が少し詰まっても超えない長さにしてある（128 フレームだと 2.67 ms で、
//      別の処理に割り込まれただけで超えることがある）。
//
//  数え方の約束（ETJSFXHost.cpp の process）:
//    - @slider が走ったブロックは**測らない**。ただし**回数を 0 に戻しもしない**。
//      戻すと、つまみを 1 ブロックおきに動かすだけで判定が永久に成立しなくなる。
//    - 締切内で終わったブロックだけが回数を 0 に戻す。
//    - 3 連続で超えたら automaticBypass。戻す口は ClearDiagnostic だけ。

import XCTest

final class JSFXDeadlineTests: XCTestCase {

    private let frames = JSFX.maxFrames

    /// 1 ブロック回す。戻り値は process のもの。
    @discardableResult
    private func block(_ host: JSFXHost, frames: UInt32) -> Int32 {
        var planar = JSFX.signal(channels: 2, frames: frames)
        return host.process(&planar, channels: 2, frames: frames)
    }

    /// 重い設定のまま、回数が 0 で @slider も済んでいる状態まで進める。
    private func settledSlowHost() throws -> JSFXHost {
        let host = try JSFX.load("slow", maxFrames: frames)
        host.set(0, 0)                      // まず軽くする
        block(host, frames: frames)         // @slider（測らないブロック）
        block(host, frames: frames)         // Create 直後のぶんの引き継ぎ
        block(host, frames: frames)         // ここで回数が 0 に戻る
        XCTAssertTrue(host.isRunning)
        XCTAssertEqual(host.deadlineTrips, 0, "軽いブロックで締切を超えている")
        return host
    }

    /// D01 + D02。最初の @slider ブロックは数えない。そのあと 3 連続で落ちる。
    func testFirstSliderBlockIsNotCountedThenThreeOverrunsBypass() throws {
        let host = try JSFX.load("slow", maxFrames: JSFX.deadlineFrames)
        host.set(0, JSFX.spin)

        block(host, frames: JSFX.deadlineFrames)
        XCTAssertEqual(host.deadlineTrips, 0, "@slider が走ったブロックを数えている")
        XCTAssertTrue(host.isRunning)

        var blocks = 1
        while host.isRunning && blocks < 12 {
            block(host, frames: JSFX.deadlineFrames)
            blocks += 1
        }
        XCTAssertFalse(host.isRunning, "超え続けても自動バイパスへ落ちない")
        XCTAssertGreaterThanOrEqual(host.deadlineTrips, 3)
        XCTAssertEqual(host.diagnostic, "Repeated audio deadline overruns; JSFX was bypassed.")
        // 使った割合の最大値。超えているのだから 1000‰ を上回る。
        XCTAssertGreaterThanOrEqual(ETJSFX_DeadlineWorstPermille(host.raw), 1000)
    }

    /// バイパス中の process は**素通り（0）**で、失敗（負）ではない。
    /// 負を返すと橋が段を外しにかかる。
    func testBypassedProcessPassesAudioThroughWithoutError() throws {
        let host = try JSFX.exhaustedSlowHost()
        XCTAssertFalse(host.isRunning)

        let input = JSFX.signal(channels: 2, frames: JSFX.deadlineFrames)
        var planar = input
        XCTAssertEqual(host.process(&planar, channels: 2, frames: JSFX.deadlineFrames), 0)
        XCTAssertEqual(planar, input, "バイパス中に音へ触っている")
    }

    /// D04。解除して走り直す。**解除直後の 1 回では再び落ちない。**
    /// 累計（DeadlineTrips）は測るためのものなので 0 へ戻さない。
    func testClearDiagnosticResumesAndKeepsTheCumulativeCount() throws {
        let host = try JSFX.exhaustedSlowHost()
        XCTAssertFalse(host.isRunning)
        let trips = host.deadlineTrips
        XCTAssertGreaterThanOrEqual(trips, 3)

        XCTAssertTrue(ETJSFX_ClearDiagnostic(host.raw))
        XCTAssertTrue(host.isRunning)
        XCTAssertEqual(host.diagnostic, "")
        XCTAssertEqual(host.deadlineTrips, trips, "累計を 0 に戻している")

        // 重いままなので 1 回は超える。それでも走り続ける。
        block(host, frames: JSFX.deadlineFrames)
        XCTAssertTrue(host.isRunning, "解除直後の 1 回で再び落ちた")
        block(host, frames: JSFX.deadlineFrames)
        XCTAssertTrue(host.isRunning, "2 回でも落ちない")
        block(host, frames: JSFX.deadlineFrames)
        XCTAssertFalse(host.isRunning, "3 回目で落ちない")

        // 走っていないときの解除は false（戻す相手が居ない）。
        XCTAssertTrue(ETJSFX_ClearDiagnostic(host.raw))
        XCTAssertFalse(ETJSFX_ClearDiagnostic(host.raw), "running を running へ戻している")
    }

    /// §13.3。**つまみを動かしたブロックは回数を 0 に戻さない。**
    /// 戻してしまうと、重い JSFX でもつまみを触り続けるだけで永久に落ちない。
    ///
    ///     超過 → つまみブロック → 超過 → 超過 → バイパス
    func testSliderBlockDoesNotResetTheConsecutiveCount() throws {
        let host = try settledSlowHost()

        host.set(0, JSFX.spin)
        block(host, frames: frames)                 // つまみブロック（測らない）
        block(host, frames: frames)                 // 1 回目の超過
        XCTAssertTrue(host.isRunning)

        host.set(0, JSFX.spin - 1)
        block(host, frames: frames)                 // つまみブロック（測らない）
        XCTAssertTrue(host.isRunning)

        block(host, frames: frames)                 // 2 回目
        XCTAssertTrue(host.isRunning)
        block(host, frames: frames)                 // 3 回目
        XCTAssertFalse(host.isRunning,
                       "つまみブロックで連続の数が 0 に戻っている")
    }

    /// D03。**締切内で終わったブロックは回数を 0 に戻す。**
    ///
    ///     超過 → 普通 → 超過 → 超過 → まだ走る → 超過 → バイパス
    func testANormalBlockResetsTheConsecutiveCount() throws {
        let host = try settledSlowHost()

        host.set(0, JSFX.spin)
        block(host, frames: frames)                 // つまみブロック
        block(host, frames: frames)                 // 1 回目の超過
        XCTAssertTrue(host.isRunning)

        host.set(0, 0)
        block(host, frames: frames)                 // つまみブロック（軽くなる）
        block(host, frames: frames)                 // 締切内 → ここで 0 に戻る
        XCTAssertTrue(host.isRunning)

        host.set(0, JSFX.spin)
        block(host, frames: frames)                 // つまみブロック（また重くする）
        block(host, frames: frames)                 // 1 回目
        block(host, frames: frames)                 // 2 回目
        XCTAssertTrue(host.isRunning, "普通のブロックで数が 0 に戻っていない")
        block(host, frames: frames)                 // 3 回目
        XCTAssertFalse(host.isRunning)
    }
}
