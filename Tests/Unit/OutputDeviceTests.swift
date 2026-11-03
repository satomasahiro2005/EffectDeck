//  OutputDeviceTests.swift
//  出力先の鍵と切り替える時機（ETOutputDevice / ETDeviceSwitch）。出力補正の入れ替えの土台。
//
//  壊れると: 別のヘッドセットが同じ鍵になって他人の補正を読み込んだり、
//  揺れのたびに補正を入れ替えたり、組み直しの最中に入れ替えて音が途切れたりする。

import XCTest

final class OutputDeviceTests: XCTestCase {

    private func dev(_ kind: ETOutputDevice.Kind, _ name: String = "X", uid: String = "") -> ETOutputDevice {
        ETOutputDevice(kind: kind, uid: uid, name: name)
    }

    private let bt = ETOutputDevice(kind: .bluetooth, uid: "AA:BB-tacl", name: "AirPods Pro")
    private let spk = ETOutputDevice(kind: .speaker, uid: "Speaker", name: "iPad Speakers")

    /// 時刻が絡まない観測の呼び出し。lastStart / lastEscape は十分前。
    private func obs(_ s: inout ETDeviceSwitch, _ d: ETOutputDevice?, at now: TimeInterval,
                     active: Bool = true, lastStart: TimeInterval = -1000,
                     lastEscape: TimeInterval = -1000) -> ETDeviceSwitch.Step {
        s.observe(d, active: active, now: now, lastStart: lastStart, lastEscape: lastEscape)
    }

    // MARK: - 鍵

    func testSpeakerKeyIgnoresUid() {
        XCTAssertEqual(dev(.speaker, uid: "a").key, "speaker")
        XCTAssertEqual(dev(.speaker, uid: "b").key, "speaker")
    }

    func testWiredHeadphonesShareOneKey() {
        XCTAssertEqual(dev(.wired, "Headphones", uid: "1").key, "wired")
        XCTAssertEqual(dev(.wired, "Other", uid: "2").key, "wired")
    }

    func testLineOutKey() {
        XCTAssertEqual(dev(.lineOut).key, "lineOut")
    }

    func testUidKeyedKinds() {
        let kinds: [ETOutputDevice.Kind] = [.bluetooth, .bluetoothLE, .usb, .car, .hdmi]
        for k in kinds {
            XCTAssertEqual(dev(k, uid: " AA:BB-tacl ").key, "\(k.rawValue):AA:BB-tacl", "\(k)")
        }
    }

    func testSameNameDifferentUidDiffers() {
        let a = dev(.bluetooth, "AirPods Pro", uid: "11:11")
        let b = dev(.bluetooth, "AirPods Pro", uid: "22:22")
        XCTAssertNotNil(a.key)
        XCTAssertNotEqual(a.key, b.key)
    }

    func testEmptyUidFallsBackToName() {
        XCTAssertEqual(dev(.usb, "DAC", uid: "  ").key, "usb:name:DAC")
        XCTAssertEqual(dev(.usb, "DAC", uid: "").key, "usb:name:DAC")
    }

    func testHFPAndOtherHaveNoKey() {
        XCTAssertNil(dev(.hfp, uid: "x").key)
        XCTAssertNil(dev(.other, uid: "x").key)
    }

    func testKindsOfDifferentTypeNeverCollide() {
        XCTAssertNotEqual(dev(.bluetooth, uid: "same").key, dev(.bluetoothLE, uid: "same").key)
    }

    // MARK: - pick

    func testPickNilForOwnDeviceAnywhere() {
        XCTAssertNil(ETOutputDevice.pick([spk, dev(.other, "EffectDeck")]))
        XCTAssertNil(ETOutputDevice.pick([dev(.other, "effectdeck")]))
        XCTAssertNil(ETOutputDevice.pick([dev(.other, "EffectDeck"), bt]))
    }

    func testPickNilWhenHFPPresent() {
        XCTAssertNil(ETOutputDevice.pick([dev(.hfp, "AirPods Pro", uid: "x")]))
        XCTAssertNil(ETOutputDevice.pick([bt, dev(.hfp, "AirPods Pro", uid: "x")]))
    }

    func testPickUsesFirstPort() {
        let usb = dev(.usb, "DAC", uid: "u1")
        XCTAssertEqual(ETOutputDevice.pick([usb, spk]), usb)
        XCTAssertNil(ETOutputDevice.pick([dev(.other, "AirPlay"), spk]))
    }

    func testPickEmptyIsNil() {
        XCTAssertNil(ETOutputDevice.pick([]))
    }

    // MARK: - シンボル

    func testSymbols() {
        XCTAssertEqual(ETOutputDevice.Kind.speaker.symbol, "speaker.wave.2")
        XCTAssertEqual(ETOutputDevice.Kind.usb.symbol, "cable.connector")
        XCTAssertEqual(ETOutputDevice.Kind.car.symbol, "car")
        XCTAssertEqual(ETOutputDevice.Kind.hdmi.symbol, "tv")
        XCTAssertEqual(ETOutputDevice.Kind.bluetooth.symbol, "headphones")
        for k in [ETOutputDevice.Kind.wired, .lineOut, .bluetoothLE, .hfp] {
            XCTAssertEqual(k.symbol, "headphones", "\(k)")
        }
        XCTAssertEqual(ETOutputDevice.Kind.other.symbol, "speaker")
    }

    func testKindRawValuesRoundTrip() {
        // 端末に残す文字列。綴りを変えると保存済みの紐付けが読めなくなる。
        let all: [ETOutputDevice.Kind] = [.speaker, .wired, .lineOut, .bluetooth, .bluetoothLE, .hfp, .usb, .car, .hdmi, .other]
        for k in all {
            XCTAssertEqual(ETOutputDevice.Kind(rawValue: k.rawValue), k)
        }
    }

    // MARK: - 切り替えの時機

    func testSwitchesAfterStableSeconds() {
        var s = ETDeviceSwitch(settled: "speaker")
        XCTAssertEqual(obs(&s, bt, at: 100), .wait(until: 102))
        XCTAssertEqual(obs(&s, bt, at: 101.9), .wait(until: 102))
        XCTAssertEqual(obs(&s, bt, at: 102), .switched(bt))
        XCTAssertEqual(s.settled, bt.key)
        XCTAssertNil(s.candidate)
    }

    func testSettledDeviceIsIdle() {
        var s = ETDeviceSwitch(settled: bt.key)
        for i in 0..<20 { XCTAssertEqual(obs(&s, bt, at: Double(i)), .idle) }
        XCTAssertNil(s.candidate)
    }

    func testSwitchesOnceThenIdle() {
        var s = ETDeviceSwitch(settled: "speaker")
        _ = obs(&s, bt, at: 0)
        XCTAssertEqual(obs(&s, bt, at: 2), .switched(bt))
        for i in 1...20 { XCTAssertEqual(obs(&s, bt, at: 2 + Double(i) * 0.3), .idle) }
    }

    func testInactiveClearsCandidateAndRestartsClock() {
        var s = ETDeviceSwitch(settled: "speaker")
        XCTAssertEqual(obs(&s, bt, at: 0), .wait(until: 2))
        XCTAssertEqual(obs(&s, bt, at: 1, active: false), .idle)
        XCTAssertNil(s.candidate)
        XCTAssertEqual(obs(&s, bt, at: 1.5), .wait(until: 3.5))
    }

    func testInactiveNeverSwitches() {
        var s = ETDeviceSwitch(settled: "speaker")
        var t = 0.0
        while t <= 30 {
            XCTAssertEqual(obs(&s, bt, at: t, active: false), .idle)
            t += 0.3
        }
        XCTAssertEqual(s.settled, "speaker")
        XCTAssertNil(s.candidate)
    }

    func testNilReadingKeepsSettled() {
        var s = ETDeviceSwitch(settled: bt.key)
        var t = 0.0
        while t < 5 {
            XCTAssertEqual(obs(&s, nil, at: t), .idle)
            t += 0.3
        }
        XCTAssertEqual(obs(&s, bt, at: 5.1), .idle)
        XCTAssertEqual(s.settled, bt.key)
    }

    func testNilReadingClearsCandidate() {
        var s = ETDeviceSwitch(settled: "speaker")
        XCTAssertEqual(obs(&s, bt, at: 0), .wait(until: 2))
        XCTAssertEqual(obs(&s, nil, at: 1), .idle)
        XCTAssertNil(s.candidate)
        XCTAssertEqual(obs(&s, bt, at: 1.2), .wait(until: 3.2))
    }

    func testKeylessDeviceIsIdle() {
        var s = ETDeviceSwitch(settled: "speaker")
        XCTAssertEqual(obs(&s, dev(.hfp, "AirPods Pro", uid: "x"), at: 0), .idle)
        XCTAssertEqual(obs(&s, dev(.other, "AirPlay"), at: 10), .idle)
        XCTAssertEqual(s.settled, "speaker")
    }

    func testFlappingRestartsClock() {
        var s = ETDeviceSwitch(settled: "x")
        let a = dev(.usb, "A", uid: "a")
        let b = dev(.usb, "B", uid: "b")
        XCTAssertEqual(obs(&s, a, at: 0), .wait(until: 2))
        XCTAssertEqual(obs(&s, b, at: 1), .wait(until: 3))
        XCTAssertEqual(obs(&s, a, at: 1.5), .wait(until: 3.5))
        XCTAssertEqual(obs(&s, a, at: 3.4), .wait(until: 3.5))
        XCTAssertEqual(obs(&s, a, at: 3.5), .switched(a))
    }

    func testWaitsAfterStart() {
        var s = ETDeviceSwitch(settled: "speaker")
        let due = 1.8 + ETDeviceSwitch.afterStartSeconds
        XCTAssertEqual(due, 3.3, accuracy: 1e-9)
        XCTAssertEqual(obs(&s, bt, at: 0, lastStart: 1.8), .wait(until: due))
        XCTAssertEqual(obs(&s, bt, at: 2.5, lastStart: 1.8), .wait(until: due))
        XCTAssertEqual(obs(&s, bt, at: due, lastStart: 1.8), .switched(bt))
    }

    func testWaitsAfterEscape() {
        var s = ETDeviceSwitch(settled: "speaker")
        XCTAssertEqual(obs(&s, bt, at: 0, lastEscape: 1), .wait(until: 4))
        XCTAssertEqual(obs(&s, bt, at: 3.9, lastEscape: 1), .wait(until: 4))
        XCTAssertEqual(obs(&s, bt, at: 4, lastEscape: 1), .switched(bt))
    }

    func testRealChangesSwitchEachTime() {
        var s = ETDeviceSwitch(settled: nil)
        let a = dev(.usb, "A", uid: "a")
        let b = dev(.usb, "B", uid: "b")
        _ = obs(&s, a, at: 0)
        XCTAssertEqual(obs(&s, a, at: 2), .switched(a))
        _ = obs(&s, b, at: 3)
        XCTAssertEqual(obs(&s, b, at: 5), .switched(b))
        _ = obs(&s, a, at: 6)
        XCTAssertEqual(obs(&s, a, at: 8), .switched(a))
    }

    func testUnboundStillSettles() {
        // 紐付けは見ない。決めるのは出力先だけ。
        var s = ETDeviceSwitch(settled: nil)
        _ = obs(&s, spk, at: 0)
        XCTAssertEqual(obs(&s, spk, at: 2), .switched(spk))
        XCTAssertEqual(s.settled, "speaker")
    }

    func testFirstLaunchWithNoSettledSwitches() {
        var s = ETDeviceSwitch(settled: nil)
        XCTAssertEqual(obs(&s, bt, at: 0), .wait(until: 2))
    }

    func testStableConstants() {
        XCTAssertEqual(ETDeviceSwitch.stableSeconds, 2)
        XCTAssertEqual(ETDeviceSwitch.afterStartSeconds, 1.5)
        XCTAssertEqual(ETDeviceSwitch.afterEscapeSeconds, ETRouteEscape.retry)
    }
}
