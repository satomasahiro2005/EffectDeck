//  PreferencesValuesTests.swift
//  設定の値（PreferencesValues.swift）。選べる値の往復と、保存した値の読み方。
//
//  Preferences.shared は触らない（UIKit の UIApplication を連れてくる）。読み方は
//  PreferencesValues の関数を直に呼ぶ。Preferences の init が同じ関数を通って読む。

import XCTest

final class PreferencesValuesTests: XCTestCase {

    // MARK: - 選べる値

    func testProcessingRateRawValuesRoundTrip() {
        XCTAssertEqual(ETProcessingRate.allCases.map(\.rawValue), [48000, 96000, 192000])
        for rate in ETProcessingRate.allCases {
            XCTAssertEqual(ETProcessingRate(rawValue: rate.rawValue), rate)
            XCTAssertEqual(PreferencesValues.processingRate(rate.rawValue), rate)
            // 入口の 48 kHz に対する整数の倍率。
            XCTAssertEqual(Int(rate.factor) * 48000, rate.rawValue)
            XCTAssertEqual(rate.factorLabel, "\(rate.factor)×")
        }
    }

    func testLatencyRawValuesRoundTrip() {
        XCTAssertEqual(ETLatency.allCases.map(\.rawValue), ["interactive", "balanced", "playback"])
        XCTAssertEqual(ETLatency.allCases.map(\.frames), [256, 512, 1024])
        for latency in ETLatency.allCases {
            XCTAssertEqual(ETLatency(rawValue: latency.rawValue), latency)
            XCTAssertEqual(PreferencesValues.latency(latency.rawValue), latency)
            XCTAssertEqual(latency.bufferDuration, Double(latency.frames) / 48000, accuracy: 1e-12)
        }
        XCTAssertEqual(ETLatency.interactive.msLabel, "5.3 ms")
        XCTAssertEqual(ETLatency.playback.choiceTitle, "1024 spls · 21.3 ms")
    }

    func testCanvasModeRawValuesRoundTrip() {
        // allCases の並びがそのまま札の順（既定が左）。
        XCTAssertEqual(ETJSFXCanvasMode.allCases, [.adaptive, .pixelPerfect])
        for mode in ETJSFXCanvasMode.allCases {
            XCTAssertEqual(ETJSFXCanvasMode(rawValue: mode.rawValue), mode)
            XCTAssertEqual(PreferencesValues.jsfxCanvasMode(mode.rawValue), mode)
        }
    }

    /// 保存が無い・知らない値・型が違うときは既定。
    func testUnknownStoredValuesFallBackToDefaults() {
        XCTAssertEqual(PreferencesValues.processingRate(nil), .r96)
        XCTAssertEqual(PreferencesValues.processingRate(44100), .r96)
        XCTAssertEqual(PreferencesValues.processingRate("48000"), .r96)
        XCTAssertEqual(PreferencesValues.latency(nil), .interactive)
        XCTAssertEqual(PreferencesValues.latency("low"), .interactive)
        XCTAssertEqual(PreferencesValues.jsfxCanvasMode(nil), .adaptive)
        XCTAssertEqual(PreferencesValues.jsfxCanvasMode("stretch"), .adaptive)
    }

    // MARK: - Silence threshold

    /// 読むときに -90 … -20 へ収める。前は範囲の外の値がそのまま音の判定へ入っていた。
    func testSilenceThresholdClampedOnLoad() {
        XCTAssertEqual(PreferencesValues.silenceThreshold(-200.0), -90)
        XCTAssertEqual(PreferencesValues.silenceThreshold(-90.0), -90)
        XCTAssertEqual(PreferencesValues.silenceThreshold(-85.0), -85, "範囲の中はそのまま")
        XCTAssertEqual(PreferencesValues.silenceThreshold(-20.0), -20)
        XCTAssertEqual(PreferencesValues.silenceThreshold(0.0), -20)
        XCTAssertEqual(PreferencesValues.silenceThreshold(Double.infinity), -20)
        XCTAssertEqual(PreferencesValues.silenceThreshold(-Double.infinity), -90)
    }

    func testSilenceThresholdDefaultWhenMissingOrNotANumber() {
        XCTAssertEqual(PreferencesValues.silenceThreshold(nil), -80)
        XCTAssertEqual(PreferencesValues.silenceThreshold(Double.nan), -80)
        XCTAssertEqual(PreferencesValues.silenceThreshold("-30"), -80)
    }

    /// 範囲と刻みは上流（power-policy.js の SILENCE_THRESHOLD_DB_VALUES）と同じで、既定は刻みに乗る。
    func testSilenceRangeMatchesUpstreamSteps() {
        let steps = stride(from: PreferencesValues.silenceRange.lowerBound,
                           through: PreferencesValues.silenceRange.upperBound,
                           by: PreferencesValues.silenceStep).map { $0 }
        XCTAssertEqual(steps, [-90, -80, -70, -60, -50, -40, -30, -20])
        XCTAssertTrue(steps.contains(PreferencesValues.silenceDefault))
    }

    /// 鍵の綴りは UI テストと撮影が引数で渡すので変えない。
    func testKeysUnchanged() {
        typealias Key = PreferencesValues.Key
        XCTAssertEqual([Key.rate, Key.latency, Key.power, Key.silence, Key.awake,
                        Key.syncVisualsToAudio, Key.jsfxCanvasMode],
                       ["pref.rate", "pref.latency", "pref.power", "pref.silence", "pref.awake",
                        "pref.syncVisualsToAudio", "pref.jsfxCanvasMode"])
    }

    // MARK: - Remote Control（入切をやめた）

    func testRemoteWantsConnectionMigratesTheOldEnabledFlag() {
        // 新しい鍵が無ければ、前の版の入切を引き継ぐ。
        XCTAssertTrue(PreferencesValues.remoteWantsConnection(stored: nil, legacy: true))
        XCTAssertFalse(PreferencesValues.remoteWantsConnection(stored: nil, legacy: false))
        // どちらも無い（一度も使っていない）はつながない。
        XCTAssertFalse(PreferencesValues.remoteWantsConnection(stored: nil, legacy: nil))
        // 新しい鍵があればそちらが勝つ（Disconnect した後に前の鍵が残っていても戻らない）。
        XCTAssertFalse(PreferencesValues.remoteWantsConnection(stored: false, legacy: true))
        XCTAssertTrue(PreferencesValues.remoteWantsConnection(stored: true, legacy: false))
        // 型が違うものは無いのと同じ。
        XCTAssertFalse(PreferencesValues.remoteWantsConnection(stored: "yes", legacy: nil))
    }
}
