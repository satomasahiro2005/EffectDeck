//  SpectrumSmoothingTests.swift
//  1/12 オクターブの平滑。**実機もエンジンも要らない。**
//
//  移植元は Vendor/effetune/plugins/spectrum-overlay.js:86-93, 128-142。
//  あちらの窓の端は bin 番号だけで決まるので、標本化周波数も FFT の大きさも
//  要らずに数で照合できる。実機で目視するまで気づけない類の間違い
//  （ceil と floor の取り違え、窓の幅の off-by-one、電力ではなく dB を足す）を
//  ここで落とす。
//
//  期待値は上流の式から手で出したもので、こちらの実装から出したものではない:
//      first = ceil(i / 2^(1/24))、end = min(floor(i * 2^(1/24)) + 1, n)
//      average = sum(power[first..<end]) / (end - first)
//      out = 10 * log10(max(average, 1e-24))

import XCTest
import Foundation

final class SpectrumSmoothingTests: XCTestCase {

    /// spectrum-overlay.js:9 の SMOOTHING_EDGE_RATIO。
    func testEdgeRatioIsAQuarterToneOnEachSide() {
        XCTAssertEqual(ETSpectrumSmoothing.edgeRatio, 1.029302236643492, accuracy: 1e-12)
        // 上下に足して 1/12 オクターブ。
        XCTAssertEqual(pow(ETSpectrumSmoothing.edgeRatio, 2), pow(2, 1.0 / 12), accuracy: 1e-12)
    }

    /// 平らな入力は平らなまま出る。等しい電力を平均しても同じ電力にしかならない。
    /// 窓の幅を取り違えていてもここは通るので、これは最低限の門。
    func testFlatInputStaysFlat() {
        let input = [Float](repeating: -60, count: 512)
        let out = ETSpectrumSmoothing.twelfthOctave(decibels: input)
        XCTAssertEqual(out.count, input.count)
        // bin 0 は窓が自分だけ（first=0, end=1）なので、そこも -60。
        for (i, v) in out.enumerated() {
            XCTAssertEqual(Double(v), -60, accuracy: 1e-3, "bin \(i)")
        }
    }

    /// 1 本だけ立っている入力を均すと、窓の幅ぶんだけ下がって、窓の幅ぶんだけ広がる。
    ///
    /// bin 100 だけ 0dB、残りは床（-240dB = 電力 1e-24）。
    /// 上流の式で i=100 の窓は [98, 103) の 5 本なので、
    ///     10*log10(1/5) = -6.98970 dB
    /// 窓に bin 100 が入るのは i = 98...102 だけ。i=97 の窓は [95,100)、
    /// i=103 の窓は [101,107) で、どちらも 100 を含まない。
    func testSingleBinSpreadsOverTheWindow() {
        var input = [Float](repeating: Float(ETSpectrumSmoothing.floorDB), count: 512)
        input[100] = 0
        let out = ETSpectrumSmoothing.twelfthOctave(decibels: input)

        XCTAssertEqual(Double(out[100]), -6.9897000433601875, accuracy: 1e-4)
        XCTAssertEqual(Double(out[98]), -6.9897000433601875, accuracy: 1e-4)
        XCTAssertEqual(Double(out[102]), -6.9897000433601875, accuracy: 1e-4)

        // 窓の外は床のまま。ここが床でなければ窓が広すぎる。
        XCTAssertEqual(Double(out[97]), ETSpectrumSmoothing.floorDB, accuracy: 1e-3)
        XCTAssertEqual(Double(out[103]), ETSpectrumSmoothing.floorDB, accuracy: 1e-3)
    }

    /// dB のまま足していないこと。
    ///
    /// bin 100 に 0dB、bin 101 に -20dB を置く。i=100 の窓は [98,103) の 5 本なので
    ///     10*log10((1 + 0.01) / 5) = -6.9466 dB
    /// -20dB の 1 本が足すのは電力で 0.01 しかないので、答えは -20dB を無視した
    /// -6.9897dB からほとんど動かない。dB を足していれば大きく外れる。
    func testAveragesPowerNotDecibels() {
        var input = [Float](repeating: Float(ETSpectrumSmoothing.floorDB), count: 512)
        input[100] = 0
        input[101] = -20
        let out = ETSpectrumSmoothing.twelfthOctave(decibels: input)

        XCTAssertEqual(Double(out[100]), 10 * log10(1.01 / 5), accuracy: 1e-4)
    }

    /// 読めない値（-inf / NaN）が来ても床に落ちるだけで、隣を巻き込まない。
    /// 移動和に NaN が 1 つ入ると、そこから先が全部 NaN になる。
    func testNonFiniteInputDoesNotPoisonTheMovingSum() {
        var input = [Float](repeating: -60, count: 512)
        input[200] = -.infinity
        input[300] = .nan
        let out = ETSpectrumSmoothing.twelfthOctave(decibels: input)

        for (i, v) in out.enumerated() {
            XCTAssertTrue(v.isFinite, "bin \(i) が \(v)")
        }
        // 汚染が起きていれば、後ろの平らな所が -60 から外れる。
        XCTAssertEqual(Double(out[450]), -60, accuracy: 1e-3)
    }

    /// 短すぎる入力はそのまま返す（窓が作れない）。
    func testShortInputPassesThrough() {
        XCTAssertEqual(ETSpectrumSmoothing.twelfthOctave(decibels: []), [])
        XCTAssertEqual(ETSpectrumSmoothing.twelfthOctave(decibels: [-12]), [-12])
    }
}
