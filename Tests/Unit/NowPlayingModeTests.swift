//  NowPlayingModeTests.swift
//  Now Playing を名乗るかどうかの測るための口（ETNowPlayingMode）と、ロック画面の字。
//
//  名乗るとループバックを招く（NowPlayingMode.swift の実測）。だから既定は off で、
//  **焼き付けは Debug だけ**。Release が焼いた値を読むと、開発中に焼いた on が
//  店の版に残って名乗り続ける。

import XCTest

final class NowPlayingModeTests: XCTestCase {

    private typealias M = ETNowPlayingMode

    func testDefaultIsOff() {
        for persists in [true, false] {
            XCTAssertEqual(M.resolve(argument: nil, persisted: nil, persists: persists),
                           .init(mode: .off, save: nil))
        }
    }

    /// Debug: 引数は効いて、焼き付ける。
    func testDebugArgumentWinsAndIsPersisted() {
        XCTAssertEqual(M.resolve(argument: "first", persisted: "on", persists: true),
                       .init(mode: .first, save: .first))
        XCTAssertEqual(M.resolve(argument: "off", persisted: "on", persists: true),
                       .init(mode: .off, save: .off), "焼いた値は -ETNowPlaying off で戻せる")
    }

    /// Debug: 引数が無ければ焼いた値を読む（書き直さない）。
    func testDebugReadsPersistedValue() {
        XCTAssertEqual(M.resolve(argument: nil, persisted: "on", persists: true),
                       .init(mode: .on, save: nil))
    }

    /// Release: 引数は効くが焼かない。
    func testReleaseArgumentIsNotPersisted() {
        XCTAssertEqual(M.resolve(argument: "first", persisted: nil, persists: false),
                       .init(mode: .first, save: nil))
    }

    /// **Release は焼いてある値を読まない。** 開発中に焼いた on を店の版へ持ち込まない。
    func testReleaseIgnoresPersistedValue() {
        XCTAssertEqual(M.resolve(argument: nil, persisted: "on", persists: false),
                       .init(mode: .off, save: nil))
        XCTAssertEqual(M.resolve(argument: nil, persisted: "first", persists: false),
                       .init(mode: .off, save: nil))
    }

    /// 読めない字の引数は無かったことにする（Debug なら焼いた値へ、無ければ off）。
    func testUnknownArgumentFallsThrough() {
        XCTAssertEqual(M.resolve(argument: "ON", persisted: "first", persists: true),
                       .init(mode: .first, save: nil), "大文字は別の字")
        XCTAssertEqual(M.resolve(argument: "", persisted: nil, persists: true),
                       .init(mode: .off, save: nil))
        XCTAssertEqual(M.resolve(argument: "yes", persisted: "garbage", persists: true),
                       .init(mode: .off, save: nil))
    }

    /// 引数と保存の鍵、生の値は起動の手順（devicectl の -ETNowPlaying）と tick のログ（np=）に出る。
    func testKeysAndRawValuesAreStable() {
        XCTAssertEqual(M.argumentKey, "ETNowPlaying")
        XCTAssertEqual(M.persistedKey, "diag.nowPlaying")
        XCTAssertEqual([M.on, .off, .first].map(\.rawValue), ["on", "off", "first"])
    }

    // MARK: - ロック画面の字

    func testArtistText() {
        XCTAssertEqual(ETNowPlayingText.artist(active: true, count: 1), "1 effect")
        XCTAssertEqual(ETNowPlayingText.artist(active: true, count: 0), "0 effects")
        XCTAssertEqual(ETNowPlayingText.artist(active: true, count: 5), "5 effects")
        XCTAssertEqual(ETNowPlayingText.artist(active: false, count: 5), "Bypassed")
        XCTAssertEqual(ETNowPlayingText.title, "EffectDeck")
    }

    // MARK: - ロック画面へ出す中身と、出すかどうか

    /// 効いているのは「素通しでなく、通ったノードが 1 つ以上」のときだけ。
    func testStateIsActiveOnlyWithoutBypassAndWithNodes() {
        let on = ETNowPlayingState(running: true, bypass: false, applied: 3)
        XCTAssertTrue(on.active)
        XCTAssertEqual(on.count, 3)
        XCTAssertFalse(ETNowPlayingState(running: true, bypass: true, applied: 3).active)
        XCTAssertEqual(ETNowPlayingState(running: true, bypass: true, applied: 3).count, 3)
        XCTAssertFalse(ETNowPlayingState(running: true, bypass: false, applied: 0).active)
        XCTAssertFalse(ETNowPlayingState(running: false, bypass: false, applied: 3).running)
    }

    /// 最初の 1 回は必ず出し、同じ中身は 2 度出さない。変わったら出す。
    func testThrottlePublishesChangesOnly() {
        var throttle = ETNowPlayingThrottle()
        let idle = ETNowPlayingState(running: false, bypass: false, applied: 0)
        let two = ETNowPlayingState(running: true, bypass: false, applied: 2)
        XCTAssertTrue(throttle.shouldPublish(idle), "最初の 1 回（止まっている形でも）")
        XCTAssertFalse(throttle.shouldPublish(idle))
        XCTAssertTrue(throttle.shouldPublish(two))
        XCTAssertFalse(throttle.shouldPublish(two))
        XCTAssertTrue(throttle.shouldPublish(ETNowPlayingState(running: true, bypass: true, applied: 2)))
        XCTAssertTrue(throttle.shouldPublish(two))
    }

    /// **stop() の後は同じ中身でも出し直す。** stop() はロック画面の割り当てを外すので、
    /// 覚えたままだと stop→start で同じ組になったとき付け直さない（設定変更やレートの
    /// 組み直しで毎回起きていた）。
    func testForgetRepublishesTheSameState() {
        var throttle = ETNowPlayingThrottle()
        let two = ETNowPlayingState(running: true, bypass: false, applied: 2)
        XCTAssertTrue(throttle.shouldPublish(two))
        throttle.forget()
        XCTAssertTrue(throttle.shouldPublish(two))
        XCTAssertFalse(throttle.shouldPublish(two))
    }
}
