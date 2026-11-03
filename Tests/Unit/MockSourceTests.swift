//  MockSourceTests.swift
//  撮影用の作り物の信号（ETMockSource）。-ETMock 1 のときだけ音のスレッドで回る。
//
//  見張るのは「撮った画面が嘘にならない」ことだけ:
//    - 振幅が [-1, 1] に収まり、NaN を出さない
//    - 左右が違う（ステレオメーターが点にならない）
//    - 位相を戻すところで波形が跳ばない（長く撮り続けてもメーターと図に段が出ない）
//    - 掃引が 300Hz〜6kHz の筋のまま（スペクトログラムの斜めの筋。上に散らない）
//    - ブロックの切り方で中身が変わらない

import XCTest

final class MockSourceTests: XCTestCase {

    private func render(_ source: ETMockSource, frames: Int, block: Int = 512) -> [Float] {
        var out = [Float](repeating: 0, count: frames * 2)
        out.withUnsafeMutableBufferPointer { buf in
            var done = 0
            while done < frames {
                let n = min(block, frames - done)
                source.fill(buf.baseAddress! + done * 2, frames: n)
                done += n
            }
        }
        return out
    }

    func testStaysWithinUnitRangeAndFinite() {
        let s = render(ETMockSource(sampleRate: 48000), frames: 48000 * 8)
        for (i, v) in s.enumerated() {
            XCTAssertTrue(v.isFinite, "sample \(i) is not finite")
            XCTAssertLessThanOrEqual(abs(v), 1, "sample \(i)")
        }
        XCTAssertGreaterThan(s.map { abs($0) }.max() ?? 0, 0.05, "無音ではメーターが動かない")
    }

    func testLeftAndRightDiffer() {
        let s = render(ETMockSource(sampleRate: 48000), frames: 48000)
        var differ = 0
        var energyL = 0.0, energyR = 0.0
        for i in 0..<48000 {
            let l = s[i * 2], r = s[i * 2 + 1]
            if abs(l - r) > 1e-4 { differ += 1 }
            energyL += Double(l * l)
            energyR += Double(r * r)
        }
        XCTAssertGreaterThan(differ, 48000 * 9 / 10, "左右がほぼ同じだとステレオメーターが点になる")
        XCTAssertLessThan(energyR, energyL, "右は少し小さくしてある")
    }

    func testZeroOrNegativeRateFallsBackTo48k() {
        let a = render(ETMockSource(sampleRate: 0), frames: 256)
        let b = render(ETMockSource(sampleRate: -1), frames: 256)
        let c = render(ETMockSource(sampleRate: 48000), frames: 256)
        XCTAssertEqual(a, c)
        XCTAssertEqual(b, c)
    }

    /// 1 回で書いても細かく刻んでも同じ標本になる（位相の持ち越しが正しい）。
    func testBlockSizeDoesNotChangeTheSignal() {
        let whole = render(ETMockSource(sampleRate: 48000), frames: 3000, block: 3000)
        for block in [1, 7, 512, 1024] {
            XCTAssertEqual(render(ETMockSource(sampleRate: 48000), frames: 3000, block: block), whole,
                           "block \(block)")
        }
    }

    func testZeroFramesWritesNothing() {
        let src = ETMockSource(sampleRate: 48000)
        var sentinel: [Float] = [7, 7]
        sentinel.withUnsafeMutableBufferPointer { src.fill($0.baseAddress!, frames: 0) }
        XCTAssertEqual(sentinel, [7, 7])
        XCTAssertEqual(src.phase, 0)
    }

    // MARK: - 位相を戻すところ

    /// 位相を戻した先で、固定の周波数の成分（和音・雑音・強弱）がちょうど元に戻ること。
    /// 戻らないと wrapSeconds ごとに波形が跳ぶ。
    /// 217 秒だったときは 138.6Hz と 164.8Hz が半端な位相（0.2 と 0.6 周期）で切れていた。
    func testFixedComponentsRepeatAtTheWrap() {
        let w = ETMockSource.wrapSeconds
        for t in [0.0, 0.37, 2.5, 100.1, 216.9, 999.9] {
            let a = ETMockSource.frame(t: t, sweep: 0.3, sweepFrequency: 1000)
            let b = ETMockSource.frame(t: t + w, sweep: 0.3, sweepFrequency: 1000)
            XCTAssertEqual(a.left, b.left, accuracy: 1e-4, "t=\(t) L")
            XCTAssertEqual(a.right, b.right, accuracy: 1e-4, "t=\(t) R")
        }
    }

    /// 掃引の周波数そのものも wrapSeconds で戻る（7 秒の往復の整数倍）。
    func testSweepFrequencyRepeatsAtTheWrap() {
        let w = ETMockSource.wrapSeconds
        for t in stride(from: 0.0, to: 14.0, by: 0.37) {
            XCTAssertEqual(ETMockSource.sweepFrequency(at: t),
                           ETMockSource.sweepFrequency(at: t + w), accuracy: 1e-6, "t=\(t)")
        }
    }

    /// fill は wrapSeconds ぶん進んだところで数え直す。
    func testFillWrapsAtWrapSeconds() {
        let sr = 100.0
        let src = ETMockSource(sampleRate: sr)
        let total = Int(ETMockSource.wrapSeconds * sr) + 10
        _ = render(src, frames: total, block: 4096)
        XCTAssertEqual(src.phase, 10, accuracy: 0.5)
    }

    // MARK: - music の強弱

    /// 強弱は周期（16 秒）で戻り、1 周期の平均パワーが musicGain のままになる（統合 -23 LUFS 前後）。
    func testMusicEnvelopeRepeatsAndKeepsAveragePower() {
        for t in stride(from: 0.0, to: 16.0, by: 0.37) {
            XCTAssertEqual(ETMockSource.envelope(at: t), ETMockSource.envelope(at: t + 16 * 450), accuracy: 1e-9)
        }
        var power = 0.0
        let n = 16_000
        for i in 0..<n {
            let a = ETMockSource.envelope(at: Double(i) / Double(n) * ETMockSource.envelopePeriod)
            power += a * a
        }
        let meanDB = 10 * log10(power / Double(n))
        XCTAssertEqual(meanDB, -0.73, accuracy: 0.05, "正規化のあとの -0.73 dB 以外に偏らない")
    }

    /// 静かでない区間では 1〜2Hz のアクセントが ±6〜10 dB で動き、静かな区間（10〜12 秒）は
    /// そこより十分低い。VU の針が上下しバリスティクスが見える。
    func testMusicEnvelopeHasAccentsAndAQuietSection() {
        var loud: [Double] = []
        var quiet: [Double] = []
        for t in stride(from: 0.0, to: 16.0, by: 0.01) {
            let db = 20 * log10(ETMockSource.envelope(at: t))
            if t >= 10.3 && t < 11.9 { quiet.append(db) }
            else if t < 9.7 || t >= 12.3 { loud.append(db) }
        }
        let swing = (loud.max() ?? 0) - (loud.min() ?? 0)
        XCTAssertGreaterThan(swing, 12, "アクセントの上下（±6 dB 以上）")
        XCTAssertLessThan(swing, 22, "アクセントの上下（±10 dB 以下）")
        XCTAssertLessThan(quiet.max() ?? 0, (loud.max() ?? 0) - 12, "静かな区間は山より 12 dB 以上低い")
    }

    // MARK: - 掃引

    func testSweepFrequencyRange() {
        XCTAssertEqual(ETMockSource.sweepFrequency(at: 0), 300, accuracy: 1e-9)
        XCTAssertEqual(ETMockSource.sweepFrequency(at: 3.5), 6000, accuracy: 1e-6)
        XCTAssertEqual(ETMockSource.sweepFrequency(at: 7), 300, accuracy: 1e-6)
        for t in stride(from: 0.0, to: 14.0, by: 0.01) {
            let f = ETMockSource.sweepFrequency(at: t)
            XCTAssertGreaterThanOrEqual(f, 300 - 1e-9)
            XCTAssertLessThanOrEqual(f, 6000 + 1e-6)
        }
    }

    /// **掃引の位相は積分で出す。**
    /// 周波数に t を掛けて sin に入れると、瞬時周波数が f0 + t·f0' になって
    /// 秒を追うごとに上へ散る（10 秒で数十 kHz、折り返して帯域全体に撒かれる）。
    /// 撮影は起動から数秒後なので、スペクトログラムの筋が最初の 1〜2 秒しか出ていなかった。
    /// 9.5〜20kHz には何も置いていない（掃引は 6kHz まで、雑音は 6214Hz と 8448Hz）。
    func testSweepStaysBelowItsTopAfterSeconds() {
        let sr = 48000.0
        let n = 4096
        let src = ETMockSource(sampleRate: sr)
        for start in [5.0, 10.0, 20.0] {
            // start 秒まで進める。
            let target = Int(start * sr)
            let already = Int(src.phase.rounded())
            if target > already { _ = render(src, frames: target - already, block: 4096) }
            let block = render(src, frames: n, block: n)
            let left = (0..<n).map { Double(block[$0 * 2]) }
            let fraction = Self.bandEnergyFraction(left, sampleRate: sr, low: 9500, high: 20000)
            XCTAssertLessThan(fraction, 1e-6,
                              "t=\(start)s: 9.5〜20kHz に \(fraction) の強さが漏れている")
        }
    }

    /// Hann 窓を掛けたブロックのうち [low, high] Hz の帯に入る強さの割合（Goertzel）。
    static func bandEnergyFraction(_ x: [Double], sampleRate: Double,
                                   low: Double, high: Double) -> Double {
        let n = x.count
        let w = (0..<n).map { x[$0] * (0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n))) }
        let total = Double(n) * w.reduce(0) { $0 + $1 * $1 }
        guard total > 0 else { return 0 }
        let k0 = Int((low / sampleRate * Double(n)).rounded(.up))
        let k1 = Int((high / sampleRate * Double(n)).rounded(.down))
        var band = 0.0
        for k in k0...k1 {
            let coeff = 2 * cos(2 * Double.pi * Double(k) / Double(n))
            var s1 = 0.0, s2 = 0.0
            for v in w {
                let s0 = v + coeff * s1 - s2
                s2 = s1
                s1 = s0
            }
            band += s1 * s1 + s2 * s2 - coeff * s1 * s2
        }
        return 2 * band / total
    }
}
