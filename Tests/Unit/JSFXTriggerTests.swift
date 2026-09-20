//  JSFXTriggerTests.swift
//  trigger。設計 §9（T01-T07）。
//
//  **溜めない**のが肝。process は running でなければ掃き出しの前に return するので、
//  止まっている間に溜めると、再開した最初の 1 ブロックで一斉に発火する。
//  画面には何も出ないから、押しても効かないのか溜まっているのか区別できない。
//  ETJSFX_SendTrigger はそれを避けるために running でなければ false を返して捨てる
//  （ETJSFXHost.h に明記）。

import XCTest

final class JSFXTriggerTests: XCTestCase {

    /// T01/T02。本数は ysfx_max_triggers。**UI が 10 を直書きしないための口**
    /// なので、値そのものも見る。
    func testTriggerRangeAndCount() throws {
        let host = try JSFX.load("trigger")
        XCTAssertEqual(ETJSFX_MaxTriggers(), 10)
        for index in 0..<ETJSFX_MaxTriggers() {
            XCTAssertTrue(ETJSFX_SendTrigger(host.raw, index), "trigger \(index)")
        }
        XCTAssertFalse(ETJSFX_SendTrigger(host.raw, ETJSFX_MaxTriggers()))
        XCTAssertFalse(ETJSFX_SendTrigger(host.raw, UInt32.max))
    }

    /// T03/T04。10 回送っても 1 ブロックで 1 回。次のブロックでは発火しない。
    func testTriggerFiresOnceAndDoesNotRepeat() throws {
        let host = try JSFX.load("trigger_count")
        host.run(blocks: 1)
        XCTAssertEqual(host.get(0), 0, "発火数")
        XCTAssertEqual(host.get(1), 0, "trigger の中身")

        for _ in 0..<10 { XCTAssertTrue(ETJSFX_SendTrigger(host.raw, 0)) }
        host.run(blocks: 1)
        XCTAssertEqual(host.get(0), 1, "10 回送っても 1 回")
        XCTAssertEqual(host.get(1), 1, "bit 0")

        host.run(blocks: 1)
        XCTAssertEqual(host.get(0), 1, "次のブロックで増えない")
        XCTAssertEqual(host.get(1), 0, "trigger は 1 ブロックで消える")
    }

    /// T05。別々の trigger は同じブロックで両方出る。番号 → bit の対応も見る。
    func testDifferentTriggersArriveInTheSameBlock() throws {
        let host = try JSFX.load("trigger")
        host.run(blocks: 1)
        XCTAssertEqual(host.get(0), 0)

        XCTAssertTrue(ETJSFX_SendTrigger(host.raw, 0))
        XCTAssertTrue(ETJSFX_SendTrigger(host.raw, 1))
        host.run(blocks: 1)
        // fixture は trigger の bit 0/1/2 を 1/2/4 として溜める。
        XCTAssertEqual(host.get(0), 3)

        XCTAssertTrue(ETJSFX_SendTrigger(host.raw, 2))
        host.run(blocks: 1)
        XCTAssertEqual(host.get(0), 7)
    }

    /// T07。自動バイパス中は捨てる。**ここが true を返すと、解除した瞬間に
    /// 押した覚えの無い音が出る。**
    func testTriggerIsDroppedWhileBypassed() throws {
        let host = try JSFX.exhaustedSlowHost()
        XCTAssertFalse(host.isRunning, "slow.jsfx が締切を超えていない")
        for index in 0..<ETJSFX_MaxTriggers() {
            XCTAssertFalse(ETJSFX_SendTrigger(host.raw, index), "trigger \(index)")
        }

        // 解除したら、また受け取る。
        XCTAssertTrue(ETJSFX_ClearDiagnostic(host.raw))
        XCTAssertTrue(ETJSFX_SendTrigger(host.raw, 0))
    }

    /// 捨てた trigger が後から出てこないこと（§9 の「遅延発火しない」）。
    /// **溜めていたら、解除した後の最初のブロックで発火数が上がる。**
    /// slow_trigger.jsfx は重い @sample と発火数の数えを両方持っているので、
    /// 同じ 1 つの host で「止める → 送る → 解除する → 数える」が見られる。
    func testDroppedTriggersDoNotFireAfterRecovery() throws {
        let frames = JSFX.deadlineFrames
        let host = try JSFX.load("slow_trigger", maxFrames: frames)
        host.set(0, JSFX.spin)
        var planar = JSFX.signal(channels: 2, frames: frames)
        for _ in 0..<12 {
            guard host.isRunning else { break }
            _ = host.process(&planar, channels: 2, frames: frames)
        }
        XCTAssertFalse(host.isRunning, "slow_trigger.jsfx が締切を超えていない")
        XCTAssertEqual(host.get(1), 0, "まだ 1 回も送っていない")

        // 止まっている間の送信は全部捨てられる。
        for _ in 0..<5 { XCTAssertFalse(ETJSFX_SendTrigger(host.raw, 0)) }

        XCTAssertTrue(ETJSFX_ClearDiagnostic(host.raw))
        host.set(0, 0)                                   // 軽くして走らせ直す
        XCTAssertEqual(host.run(blocks: 2, frames: frames), 0)
        XCTAssertTrue(host.isRunning)
        XCTAssertEqual(host.get(1), 0, "捨てたはずの trigger が後から出た")

        // 解除後に送ったぶんは普通に届く。
        XCTAssertTrue(ETJSFX_SendTrigger(host.raw, 0))
        host.run(blocks: 1, frames: frames)
        XCTAssertEqual(host.get(1), 1)
    }
}
