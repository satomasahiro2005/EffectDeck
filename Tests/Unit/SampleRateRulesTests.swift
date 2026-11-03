//  SampleRateRulesTests.swift
//  AudioIO がセッションのレートから決める値（ETAudioSessionRules）。
//
//  リンクは 48kHz 固定。ハードウェアが別のレートで回っていると音程と速さがずれるので、
//  黙って進めず status に出す。その字は StatusReadings.swift の ETRunState.current が
//  失敗の前方一致（failurePrefixes）と "Interrupted" の完全一致で読むので、
//  どちらにも当たらないことを ETRunState に通して見張る。

import XCTest

final class SampleRateRulesTests: XCTestCase {

    func testLinkRateIs48k() {
        XCTAssertEqual(ETAudioSessionRules.linkSampleRate, 48000)
    }

    /// セッションがまだレートを名乗っていない（0・負・NaN）なら 48kHz で組む。
    func testEffectiveSampleRate() {
        XCTAssertEqual(ETAudioSessionRules.effectiveSampleRate(44100), 44100)
        XCTAssertEqual(ETAudioSessionRules.effectiveSampleRate(96000), 96000)
        XCTAssertEqual(ETAudioSessionRules.effectiveSampleRate(0), 48000)
        XCTAssertEqual(ETAudioSessionRules.effectiveSampleRate(-1), 48000)
        XCTAssertEqual(ETAudioSessionRules.effectiveSampleRate(.nan), 48000)
    }

    /// 1Hz 未満の差は同じレートとみなす。
    func testMatchesLinkRate() {
        XCTAssertTrue(ETAudioSessionRules.matchesLinkRate(48000))
        XCTAssertTrue(ETAudioSessionRules.matchesLinkRate(48000.9))
        XCTAssertTrue(ETAudioSessionRules.matchesLinkRate(47999.1))
        XCTAssertFalse(ETAudioSessionRules.matchesLinkRate(48001))
        XCTAssertFalse(ETAudioSessionRules.matchesLinkRate(44100))
        // Bluetooth のマイクに引きずられて HFP に落ちたときのレート（2026-09-18 実機）。
        XCTAssertFalse(ETAudioSessionRules.matchesLinkRate(16000))
        XCTAssertFalse(ETAudioSessionRules.matchesLinkRate(32000))
        XCTAssertFalse(ETAudioSessionRules.matchesLinkRate(.nan))
    }

    func testRunningStatus() {
        XCTAssertEqual(ETAudioSessionRules.runningStatus(sampleRate: 48000), "Running")
        XCTAssertEqual(ETAudioSessionRules.runningStatus(sampleRate: 44100),
                       "Running at 44100 Hz, input is 48000 Hz")
        XCTAssertEqual(ETAudioSessionRules.runningStatus(sampleRate: 16000),
                       "Running at 16000 Hz, input is 48000 Hz")
    }

    /// Settings が読むのは ETRunState.current。鳴っているときの字が
    /// 失敗（failurePrefixes）にも中断（"Interrupted"）にも読まれず、再生と出る。
    func testRunningStatusReadsAsRunning() {
        for sr in [48000.0, 44100, 16000, 32000, 96000, 192000] {
            var s = ETAudioSnapshot()
            s.status = ETAudioSessionRules.runningStatus(sampleRate: sr)
            s.sampleRate = sr
            s.hasPeer = true
            s.running = true
            s.route = "Speaker"
            XCTAssertEqual(ETRunState.current(s), .playing(output: "Speaker"), s.status)
            XCTAssertFalse(ETRunState.failurePrefixes.contains { s.status.hasPrefix($0) }, s.status)
        }
    }

    func testBlockFrames() {
        XCTAssertEqual(ETAudioSessionRules.blockFrames(ioBufferDuration: 0.005333, sampleRate: 48000), 256)
        XCTAssertEqual(ETAudioSessionRules.blockFrames(ioBufferDuration: 256.0 / 48000, sampleRate: 48000), 256)
        XCTAssertEqual(ETAudioSessionRules.blockFrames(ioBufferDuration: 1024.0 / 44100, sampleRate: 44100), 1024)
        XCTAssertEqual(ETAudioSessionRules.blockFrames(ioBufferDuration: 0, sampleRate: 48000), 0)
    }

    /// 値が無い（NaN・無限）ときは 0。Int へ直すところで落ちない。
    func testBlockFramesNonFiniteIsZero() {
        XCTAssertEqual(ETAudioSessionRules.blockFrames(ioBufferDuration: .nan, sampleRate: 48000), 0)
        XCTAssertEqual(ETAudioSessionRules.blockFrames(ioBufferDuration: 0.01, sampleRate: .infinity), 0)
    }

    /// 有限でも Int に入らない大きさ（2^63 以上）は 0。Int(Double) はそこで落ちる。
    /// 実機では起きないが、表示のための数で落ちる形は残さない。
    func testBlockFramesBeyondIntIsZero() {
        XCTAssertEqual(ETAudioSessionRules.blockFrames(ioBufferDuration: 1e300, sampleRate: 48000), 0)
        XCTAssertEqual(ETAudioSessionRules.blockFrames(ioBufferDuration: 0x1p63, sampleRate: 1), 0)
        XCTAssertEqual(ETAudioSessionRules.blockFrames(ioBufferDuration: -1e19, sampleRate: 1), 0)
        // 入る大きさはそのまま（2^63 のすぐ下の Double）。
        XCTAssertEqual(ETAudioSessionRules.blockFrames(ioBufferDuration: 0x1p63.nextDown, sampleRate: 1),
                       Int(0x1p63.nextDown))
    }

    /// 図を音に合わせる遅れ = 出力の遅延 + 1 ブロック + リサンプラの遅延 / レート。
    func testDisplayDelay() {
        let d = ETAudioSessionRules.displayDelay(sync: true, outputLatency: 0.010,
                                                 ioBufferDuration: 0.005, resamplerLatency: 48,
                                                 sampleRate: 48000)
        XCTAssertEqual(d, 0.016, accuracy: 1e-12)
        XCTAssertEqual(ETAudioSessionRules.displayDelay(sync: false, outputLatency: 0.010,
                                                        ioBufferDuration: 0.005, resamplerLatency: 48,
                                                        sampleRate: 48000), 0)
    }

    /// レートが 0 でも割り算が飛ばない（1 で押さえる）。
    func testDisplayDelayWithZeroRate() {
        let d = ETAudioSessionRules.displayDelay(sync: true, outputLatency: 0, ioBufferDuration: 0,
                                                 resamplerLatency: 31, sampleRate: 0)
        XCTAssertEqual(d, 31)
    }
}
