//  RouteEscapeTests.swift
//  ETRouteEscape の判断。**実機もシミュレータの音も要らない。**
//
//  ここが在る理由は docs/connect-log.md の B-3。
//  出力先が仮想デバイスへ戻ったときに引き剥がしを掛け直さない穴があり、
//  判断が AVAudioSession に触る関数の中に埋まっていたせいで、
//  実機で 25 秒のログを取るまで見つけられなかった。
//  下の testReappliesWhenRouteReturns がその穴を直接突く。

// RouteEscape.swift はこのバンドルへ直接コンパイルしている（project.yml）。
// アプリを建てずに済むので、拡張＝MediaDevice.framework に一切触らない。
import XCTest

final class RouteEscapeTests: XCTestCase {

    /// 仮想デバイスを指していたら引き剥がす。
    func testEscapesWhenOnVirtual() {
        var e = ETRouteEscape()
        XCTAssertEqual(e.decide(onVirtual: true, onSpeaker: false, now: 100), .speaker)
        XCTAssertTrue(e.overriding)
    }

    /// 掛けた直後は何もしない。
    /// overrideOutputAudioPort は反映まで 2 秒ほどかかるので、
    /// その間に打ち直すと 2 秒で 8 回のルート変更になり MediaDevice が壊れる。
    func testDoesNotRepeatWithinRetryWindow() {
        var e = ETRouteEscape()
        _ = e.decide(onVirtual: true, onSpeaker: false, now: 100)
        XCTAssertNil(e.decide(onVirtual: true, onSpeaker: false, now: 100.5))
        XCTAssertNil(e.decide(onVirtual: true, onSpeaker: false, now: 102.9))
    }

    /// **これが今回の穴。**
    /// 一度引き剥がしたあとルートが仮想デバイスへ戻っても、
    /// 古い実装は `onVirtual && overriding` に何も書いておらず二度と掛け直さなかった。
    /// 間隔が空いていれば掛け直すこと。
    func testReappliesWhenRouteReturns() {
        var e = ETRouteEscape()
        XCTAssertEqual(e.decide(onVirtual: true, onSpeaker: false, now: 100), .speaker)
        // 相手がもう一度 EffeTune を選んだ。ルートが戻っている。
        XCTAssertEqual(e.decide(onVirtual: true, onSpeaker: false, now: 103), .speaker)
        XCTAssertEqual(e.decide(onVirtual: true, onSpeaker: false, now: 106), .speaker)
    }

    /// 掛かっている間ずっと仮想デバイスのままでも、打つのは間隔ごとに 1 回だけ。
    /// 25 秒で 8 回を超えないこと（元の latch が防いでいたもの）。
    func testRetryRateIsBounded() {
        var e = ETRouteEscape()
        var hits = 0
        var t = 100.0
        while t < 125 {
            if e.decide(onVirtual: true, onSpeaker: false, now: t) != nil { hits += 1 }
            t += 0.3   // tick は 3.3Hz
        }
        XCTAssertGreaterThan(hits, 1, "掛け直さないなら B-3 の穴が戻っている")
        XCTAssertLessThanOrEqual(hits, 9, "25 秒で 9 回を超えるとセッションが壊れる")
    }

    /// 仮想デバイスから外れたら override を戻す。
    func testClearsWhenOffVirtual() {
        var e = ETRouteEscape()
        _ = e.decide(onVirtual: true, onSpeaker: false, now: 100)
        XCTAssertEqual(e.decide(onVirtual: false, onSpeaker: false, now: 110), .clear)
        XCTAssertFalse(e.overriding)
    }

    /// **スピーカーになっているだけでは戻さない。**
    /// それはこちらが引き剥がした結果なので、「外れた」と誤認して戻すと往復する。
    func testDoesNotClearWhileOnSpeaker() {
        var e = ETRouteEscape()
        _ = e.decide(onVirtual: true, onSpeaker: false, now: 100)
        XCTAssertNil(e.decide(onVirtual: false, onSpeaker: true, now: 110))
        XCTAssertTrue(e.overriding)
    }

    /// 掛けていないときに外れても何も打たない。
    func testIdleWhenNothingToDo() {
        var e = ETRouteEscape()
        XCTAssertNil(e.decide(onVirtual: false, onSpeaker: true, now: 100))
        XCTAssertNil(e.decide(onVirtual: false, onSpeaker: false, now: 100))
    }

    /// セッションを開き直したら最初から。次の仮想デバイスで即座に掛かること。
    func testResetAllowsImmediateEscape() {
        var e = ETRouteEscape()
        _ = e.decide(onVirtual: true, onSpeaker: false, now: 100)
        e.reset()
        XCTAssertFalse(e.overriding)
        XCTAssertEqual(e.decide(onVirtual: true, onSpeaker: false, now: 100.1), .speaker)
    }

    /// 往復しても状態が壊れないこと。
    func testRoundTrip() {
        var e = ETRouteEscape()
        XCTAssertEqual(e.decide(onVirtual: true, onSpeaker: false, now: 100), .speaker)
        XCTAssertEqual(e.decide(onVirtual: false, onSpeaker: false, now: 105), .clear)
        XCTAssertEqual(e.decide(onVirtual: true, onSpeaker: false, now: 110), .speaker)
        XCTAssertEqual(e.decide(onVirtual: false, onSpeaker: false, now: 115), .clear)
        XCTAssertFalse(e.overriding)
    }
}
