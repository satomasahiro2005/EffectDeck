//  ETChannelTests.swift
//  チャンネル指定の綴り（`ch` / `channel`）と descriptor の値の対応、それと処理幅（ETChannel.swift）。
//
//  処理幅は engine の飛ばし方（dsp/core/engine.cpp:757-769 の build_plan と、同 :990-1000 の
//  processPipeline）をそのまま写したものと、表の全部（Ch -2〜23 × engine 1〜16）で照らす。
//  前は EffeTuneDSP.routedChannels が対を常に 2、1 本を常に 1 と数えていて、出力 2ch で "56" に
//  置いた IR Reverb や Crosstalk を 2ch 幅として設計していた（engine はその段を飛ばす）。
//
//  上流の js/ir-library/ir-plugin-contract.js:26-39 selectedIrChannelCount とも照らし、
//  食い違う所（上流は engine の幅を見ずに 1 本を 1 と数える、など）を名前で挙げて固定する。

import XCTest

final class ETChannelTests: XCTestCase {

    // MARK: - 照らす相手

    /// engine.cpp:757-769（build_plan）の写し。回さない段は 0。
    /// validChannelSpec（engine.cpp:111-113）に通らない値は鎖ごと拒まれるので、それも 0。
    private func engineWidth(spec: Int8, engineChannels: Int) -> Int {
        guard spec == -2 || spec == -1 || (0...23).contains(spec) else { return 0 }
        var first = 0
        var routed = engineChannels
        if spec != -2 {
            routed = spec == -1 || spec >= 16 ? 2 : 1
            if spec >= 16 {
                first = Int(spec - 16) * 2
            } else if spec >= 0 {
                first = Int(spec)
            }
        }
        return first + routed > engineChannels ? 0 : routed
    }

    /// ir-plugin-contract.js:26-39 selectedIrChannelCount の写し。上流は保存形式の綴りで引く。
    private func upstreamWidth(channel: String?, engineChannels: Int) -> Int {
        guard engineChannels >= 1, engineChannels <= 16 else { return 0 }
        guard let channel else { return engineChannels >= 2 ? 2 : 1 }
        if channel == "A" { return engineChannels }
        if channel == "L" || channel == "R" { return 1 }
        if let n = Int(channel), (1...16).contains(n), String(n) == channel { return 1 }
        let pairs = ["34": 4, "56": 6, "78": 8, "910": 10, "1112": 12, "1314": 14, "1516": 16]
        if let need = pairs[channel] { return engineChannels >= need ? 2 : 0 }
        return 0
    }

    // MARK: - 処理幅

    /// 表の全部を engine の写しと照らす。
    func testProcessedWidthMatchesEngineForEveryCell() {
        var mismatches: [String] = []
        for spec in Int8(-2)...23 {
            for engine in 1...16 {
                let got = ETChannel.processedWidth(spec: spec, engineChannels: engine)
                let want = engineWidth(spec: spec, engineChannels: engine)
                if got != want { mismatches.append("spec \(spec) engine \(engine): \(got) != \(want)") }
            }
        }
        XCTAssertTrue(mismatches.isEmpty, mismatches.prefix(20).joined(separator: "\n")
                      + (mismatches.count > 20 ? "\n… \(mismatches.count) 件" : ""))
    }

    /// 監査で挙がった例。出力 2ch で "56" に置いた段は engine が飛ばす。
    func testPairBeyondTheOutputIsSkipped() {
        XCTAssertEqual(ETChannel.processedWidth(spec: 18, engineChannels: 2), 0)
        XCTAssertEqual(ETChannel.processedWidth(spec: 18, engineChannels: 6), 2)
        XCTAssertEqual(ETChannel.processedWidth(spec: 5, engineChannels: 4), 0)
        XCTAssertEqual(ETChannel.processedWidth(spec: 5, engineChannels: 6), 1)
        XCTAssertEqual(ETChannel.processedWidth(spec: -2, engineChannels: 7), 7)
        XCTAssertEqual(ETChannel.processedWidth(spec: -1, engineChannels: 2), 2)
        XCTAssertEqual(ETChannel.processedWidth(spec: 16, engineChannels: 2), 2)
    }

    /// engine の幅が 1〜16 の外なら 0（上流と同じ）。engine が拒む Ch も 0。
    func testOutOfRangeIsZero() {
        for spec in Int8(-2)...23 {
            XCTAssertEqual(ETChannel.processedWidth(spec: spec, engineChannels: 0), 0, "spec \(spec)")
            XCTAssertEqual(ETChannel.processedWidth(spec: spec, engineChannels: 17), 0, "spec \(spec)")
        }
        for spec: Int8 in [-3, 24, 100, -128, 127] {
            XCTAssertEqual(ETChannel.processedWidth(spec: spec, engineChannels: 16), 0, "spec \(spec)")
        }
    }

    /// 上流の selectedIrChannelCount と比べる。**食い違うのは次の 3 つだけ**で、どれも
    /// 上流が engine の幅を見ずに数えている所（engine はその段を回さない）:
    ///   - 既定（Stereo）を出力 1ch で: 上流 1 / engine 0
    ///   - 16（1ch 目と 2ch 目の対。上流に綴りが無く Stereo として読まれる）を出力 1ch で: 同じ
    ///   - 1 本（L / R / "3"〜"16"）を出力の幅より外で: 上流 1 / engine 0
    /// アプリの engine は 2〜16ch で組む（AudioIO.processingChannels）ので、上の 2 つは起きない。
    func testDiffersFromUpstreamOnlyWhereUpstreamIgnoresTheWidth() {
        var unexpected: [String] = []
        for spec in Int8(-2)...23 {
            for engine in 1...16 {
                let ours = ETChannel.processedWidth(spec: spec, engineChannels: engine)
                let theirs = upstreamWidth(channel: ETChannel.channel(from: spec), engineChannels: engine)
                guard ours != theirs else { continue }
                let stereoOnMono = (spec == -1 || spec == 16) && engine == 1
                let singleOutside = (0...15).contains(spec) && Int(spec) >= engine
                if !(ours == 0 && theirs == 1 && (stereoOnMono || singleOutside)) {
                    unexpected.append("spec \(spec) engine \(engine): ours \(ours) upstream \(theirs)")
                }
            }
        }
        XCTAssertTrue(unexpected.isEmpty, unexpected.joined(separator: "\n"))
    }

    /// 名乗る幅は、はみ出しを見ない。処理幅はそれか 0 のどちらか。
    func testNominalWidth() {
        for engine in 1...16 {
            XCTAssertEqual(ETChannel.nominalWidth(spec: -2, engineChannels: engine), engine)
            XCTAssertEqual(ETChannel.nominalWidth(spec: -1, engineChannels: engine), min(2, engine))
            for spec in Int8(0)...15 {
                XCTAssertEqual(ETChannel.nominalWidth(spec: spec, engineChannels: engine), 1)
            }
            for spec in Int8(16)...23 {
                XCTAssertEqual(ETChannel.nominalWidth(spec: spec, engineChannels: engine), 2)
            }
            for spec in Int8(-2)...23 {
                let nominal = ETChannel.nominalWidth(spec: spec, engineChannels: engine)
                let processed = ETChannel.processedWidth(spec: spec, engineChannels: engine)
                XCTAssertTrue(processed == 0 || processed == nominal,
                              "spec \(spec) engine \(engine): \(processed) / \(nominal)")
                XCTAssertGreaterThan(nominal, 0, "host に 0 を渡さない: spec \(spec) engine \(engine)")
            }
        }
    }

    // MARK: - 綴りの往復

    /// descriptor の値 → 綴り → 値。綴りが無いのは Stereo（-1、キーを出さない）と 16 だけ。
    /// 16 は Stereo に戻るが、engine はどちらも 1ch 目と 2ch 目の対として回すので音は同じ。
    func testSpecRoundTripsThroughTheSavedSpelling() {
        for spec in Int8(-2)...23 {
            let spelled = ETChannel.channel(from: spec)
            let back = ETChannel.spec(from: spelled)
            switch spec {
            case -1:
                XCTAssertNil(spelled)
                XCTAssertEqual(back, -1)
            case 16:
                XCTAssertNil(spelled)
                XCTAssertEqual(back, -1)
                for engine in 1...16 {
                    XCTAssertEqual(engineWidth(spec: 16, engineChannels: engine),
                                   engineWidth(spec: -1, engineChannels: engine), "engine \(engine)")
                }
            default:
                XCTAssertNotNil(spelled, "spec \(spec)")
                XCTAssertEqual(back, spec, "spec \(spec) → \(spelled ?? "nil")")
            }
        }
    }

    /// 綴り → 値 → 綴り。書く側の綴りはどれも読み戻せる。
    func testSavedSpellingsRoundTrip() {
        let spellings = ["A", "L", "R"] + (3...16).map(String.init)
            + ["34", "56", "78", "910", "1112", "1314", "1516"]
        for s in spellings {
            XCTAssertEqual(ETChannel.channel(from: ETChannel.spec(from: s)), s, s)
        }
    }

    /// 長い綴り・"1" "2"・知らない綴り。web 版と同じく、知らないものは Stereo に落とす。
    func testAliasesAndUnknownSpellings() {
        XCTAssertEqual(ETChannel.spec(from: "All"), -2)
        XCTAssertEqual(ETChannel.spec(from: "Left"), 0)
        XCTAssertEqual(ETChannel.spec(from: "Right"), 1)
        XCTAssertEqual(ETChannel.spec(from: "1"), 0)
        XCTAssertEqual(ETChannel.spec(from: "2"), 1)
        XCTAssertEqual(ETChannel.channel(from: ETChannel.spec(from: "1")), "L", "1ch 目は L と書く")
        for s in ["", "Stereo", "17", "0", "x", "3 4"] {
            XCTAssertEqual(ETChannel.spec(from: s), -1, s)
        }
        XCTAssertEqual(ETChannel.spec(from: "12"), 11)
        XCTAssertEqual(ETChannel.spec(from: nil), -1)
        for spec: Int8 in [-3, 24, 127, -128] {
            XCTAssertNil(ETChannel.channel(from: spec), "spec \(spec)")
        }
    }

    /// 対の見出し。16 が "1+2"、17 が "3+4"。
    func testPairName() {
        XCTAssertEqual(ETChannel.pairName(16), "1+2")
        XCTAssertEqual(ETChannel.pairName(17), "3+4")
        XCTAssertEqual(ETChannel.pairName(20), "9+10")
        XCTAssertEqual(ETChannel.pairName(23), "15+16")
    }
}
