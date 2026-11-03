//  ProcessingChannelsTests.swift
//  DSP と出力の間を何本で流すか（ETAudioSessionRules.processingChannels）と、
//  セッションへ要求する本数（requestedOutputChannels）。
//
//  壊れると: 多チャンネルの IF で音が別のスピーカーへ行くか、上限を超えて
//  et_engine_prepare が断り、鎖が丸ごと鳴らなくなる。

import XCTest

final class ProcessingChannelsTests: XCTestCase {

    /// 出力の本数 → 処理の本数の全表。下は 2（入力が L/R なので）、上は 16（DSP の上限）。
    func testProcessingChannelsTable() {
        let expected: [Int: Int] = [
            -1: 2, 0: 2, 1: 2, 2: 2, 3: 3, 4: 4, 6: 6, 8: 8,
            12: 12, 16: 16, 17: 16, 24: 16, 32: 16, 64: 16, Int.max: 16,
        ]
        for (actual, want) in expected.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(ETAudioSessionRules.processingChannels(forOutputChannels: actual), want,
                           "output \(actual)")
        }
    }

    /// 1〜32 のどれでも 2…16 に収まり、2…16 の中ではそのまま。
    func testProcessingChannelsIsAClamp() {
        for n in 1...32 {
            let p = ETAudioSessionRules.processingChannels(forOutputChannels: n)
            XCTAssertTrue((2...16).contains(p))
            if (2...16).contains(n) { XCTAssertEqual(p, n) }
        }
    }

    /// 鎖が広い幅を求めたら（5.1 の Virtual Room で 6）、2ch のヘッドホンでも 6 本で処理する。
    /// ミキサーへ渡す本数はハードウェアのまま（6 本を渡すとミキサーが勝手にダウンミックスする）。
    /// 6ch 以上の IF ではハードウェアの本数のまま。上は 16。
    func testChainCanWidenProcessingButNotTheOutput() {
        XCTAssertEqual(ETAudioSessionRules.processingChannels(forOutputChannels: 2, requiredByChain: 6), 6)
        XCTAssertEqual(ETAudioSessionRules.processingChannels(forOutputChannels: 1, requiredByChain: 6), 6)
        XCTAssertEqual(ETAudioSessionRules.processingChannels(forOutputChannels: 8, requiredByChain: 6), 8)
        XCTAssertEqual(ETAudioSessionRules.processingChannels(forOutputChannels: 2, requiredByChain: 2), 2)
        XCTAssertEqual(ETAudioSessionRules.processingChannels(forOutputChannels: 2, requiredByChain: 40), 16)
        XCTAssertEqual(ETAudioSessionRules.outputChannels(forOutputChannels: 2), 2)
        XCTAssertEqual(ETAudioSessionRules.outputChannels(forOutputChannels: 6), 6)
        // 鎖を入れない呼び方は前と同じ（既定は 2）。
        for n in -1...32 {
            XCTAssertEqual(ETAudioSessionRules.processingChannels(forOutputChannels: n),
                           ETAudioSessionRules.processingChannels(forOutputChannels: n, requiredByChain: 2))
        }
    }

    /// 組んだ幅と見張りが比べる幅は、同じ鎖の幅を入れれば一致する（組み直しが繰り返されない）。
    func testWatchdogAgreesWithStartWhenTheChainIsWide() {
        let built = ETAudioSessionRules.processingChannels(forOutputChannels: 2, requiredByChain: 6)
        let watched = ETAudioSessionRules.processingChannels(forOutputChannels: 2, requiredByChain: 6)
        XCTAssertFalse(ETRouteRebuildRule.channelMismatch(running: true, built: built, actual: watched))
        // 鎖を見ない見張りだと、6 と 2 で食い違い続ける。
        XCTAssertTrue(ETRouteRebuildRule.channelMismatch(
            running: true, built: built,
            actual: ETAudioSessionRules.processingChannels(forOutputChannels: 2)))
    }

    func testMaxChannelsIs16() {
        XCTAssertEqual(ETAudioSessionRules.maxChannels, 16)
    }

    /// 要求する本数は 1〜16。モノラルの経路（最大 1）には 1 を出す。
    func testRequestedOutputChannels() {
        XCTAssertEqual(ETAudioSessionRules.requestedOutputChannels(maximum: 0), 1)
        XCTAssertEqual(ETAudioSessionRules.requestedOutputChannels(maximum: 1), 1)
        XCTAssertEqual(ETAudioSessionRules.requestedOutputChannels(maximum: 2), 2)
        XCTAssertEqual(ETAudioSessionRules.requestedOutputChannels(maximum: 8), 8)
        XCTAssertEqual(ETAudioSessionRules.requestedOutputChannels(maximum: 16), 16)
        XCTAssertEqual(ETAudioSessionRules.requestedOutputChannels(maximum: 32), 16)
    }
}
