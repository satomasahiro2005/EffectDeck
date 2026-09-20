//  JSFXLatencyTests.swift
//  PDC。設計 §11（P01-P05）。
//
//  JSFX は pdc_delay をいつでも書き換える。ホストはそれを 1 度だけ拾って
//  鎖全体を publish し直す（ETJSFXHost.swift の pollRuntimeChanges →
//  EffeTuneDSP.republish）。**取りこぼすと段がずれたまま、立てっぱなしだと
//  毎回組み直して音が切れる。**だから「1 度だけ true」を両側から見る。

import XCTest

final class JSFXLatencyTests: XCTestCase {

    private let frames = JSFX.maxFrames

    /// @init で決めた値は、1 ブロックも通さずに descriptor へ出ている。
    /// **通知は立たない**（作った時点の値なので、拾い直す必要が無い）。
    func testLatencyFromInitIsVisibleBeforeTheFirstBlock() throws {
        let host = try JSFX.load("pdc")
        XCTAssertEqual(host.latency, 64)
        XCTAssertFalse(ETJSFX_ConsumeLatencyChange(host.raw))
    }

    /// P01。つまみが 0 のときは 0 のまま。
    func testZeroLatencyStaysZero() throws {
        let host = try JSFX.load("pdc_slider")
        XCTAssertEqual(host.latency, 0)
        host.run(blocks: 2)
        XCTAssertEqual(host.latency, 0)
        XCTAssertFalse(ETJSFX_ConsumeLatencyChange(host.raw))
    }

    /// P02/P03。変わったら 1 度だけ true。
    func testLatencyChangeIsReportedExactlyOnce() throws {
        let host = try JSFX.load("pdc_slider")
        host.run(blocks: 1)

        host.set(0, 128)
        host.run(blocks: 1)
        XCTAssertEqual(host.latency, 128)
        XCTAssertTrue(ETJSFX_ConsumeLatencyChange(host.raw))
        XCTAssertFalse(ETJSFX_ConsumeLatencyChange(host.raw), "2 回目は false")

        host.set(0, 2048)
        host.run(blocks: 1)
        XCTAssertEqual(host.latency, 2048)
        XCTAssertTrue(ETJSFX_ConsumeLatencyChange(host.raw))
        XCTAssertFalse(ETJSFX_ConsumeLatencyChange(host.raw))

        // 同じ値を書き直しても変化ではない。
        host.set(0, 2048)
        host.run(blocks: 1)
        XCTAssertEqual(host.latency, 2048)
        XCTAssertFalse(ETJSFX_ConsumeLatencyChange(host.raw))
    }

    /// P04。負の遅延は 0 にする（負のまま渡すと鎖の長さが縮んで、他の段とずれる）。
    func testNegativeLatencyBecomesZero() throws {
        let host = try JSFX.load("pdc_slider")
        host.set(0, 256)
        host.run(blocks: 1)
        XCTAssertEqual(host.latency, 256)
        _ = ETJSFX_ConsumeLatencyChange(host.raw)

        host.set(0, -256)
        host.run(blocks: 1)
        XCTAssertEqual(host.latency, 0)
        XCTAssertTrue(ETJSFX_ConsumeLatencyChange(host.raw))
    }

    /// P05。端数は切り上げ。127.1 サンプル遅らせる方法は無いので、128 にする。
    func testFractionalLatencyRoundsUp() throws {
        let host = try JSFX.load("pdc_slider")
        host.set(0, 127.1)
        host.run(blocks: 1)
        XCTAssertEqual(host.latency, 128)
        XCTAssertTrue(ETJSFX_ConsumeLatencyChange(host.raw))

        host.set(0, 127.9)
        host.run(blocks: 1)
        XCTAssertEqual(host.latency, 128)
        XCTAssertFalse(ETJSFX_ConsumeLatencyChange(host.raw),
                       "切り上げ後が同じなら変化として出してはいけない")

        host.set(0, 128.1)
        host.run(blocks: 1)
        XCTAssertEqual(host.latency, 129)
        XCTAssertTrue(ETJSFX_ConsumeLatencyChange(host.raw))
    }
}
