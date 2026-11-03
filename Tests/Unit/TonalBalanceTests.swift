//  TonalBalanceTests.swift
//  Tonal Balance EQ（2.12.0）の枠の読み・補間・曲線・Target adjust の応答
//  （DSP/TonalBalanceModel.swift）。**実機もエンジンも要らない。**
//  期待値は tonal_balance_eq.js の式から手で出したもの。

import XCTest

final class TonalBalanceTests: XCTestCase {

    typealias T = ETTonalBalance

    // MARK: 枠を作る

    private struct Fields {
        var rate: Float = 48000
        var flags: UInt8 = 1 | 2 | 4 | 8
        var target: UInt8 = 0
        var loudness: Float = -23
        var makeup: Float = 1.5
        var level = [Float](repeating: -40, count: 41)
        var persistence = [Float](repeating: 1, count: 41)
        var presence = [Float](repeating: 0.5, count: 41)
        var mu = [Float](repeating: -34, count: 41)
        var sigma = [Float](repeating: 2, count: 41)
        var bandFlags = [UInt8](repeating: 28, count: 41)
        var response = [Float](repeating: 0, count: 128)
    }

    private func frame(_ f: Fields = Fields(), bands: UInt16 = 41, grid: UInt16 = 128,
                       length: Int = 1564, sequence: UInt32 = 3) -> ETFrame {
        var p = [UInt8](repeating: 0, count: length)
        func put(_ bytes: [UInt8], _ offset: Int) { TelemetryBytes.put(bytes, at: offset, into: &p) }
        put(TelemetryBytes.f32(f.rate), 0)
        put(TelemetryBytes.u16(bands), 4)
        put(TelemetryBytes.u16(grid), 6)
        put([f.flags], 8)
        put([f.target], 9)
        put(TelemetryBytes.f32(f.loudness), 12)
        put(TelemetryBytes.f32(f.makeup), 16)
        func floats(_ values: [Float], _ offset: Int) {
            for (i, v) in values.enumerated() { put(TelemetryBytes.f32(v), offset + 4 * i) }
        }
        floats(f.level, 24)
        floats(f.persistence, 188)
        floats(f.presence, 352)
        floats(f.mu, 680)
        floats(f.sigma, 844)
        for (i, b) in f.bandFlags.enumerated() { put([b], 1008 + i) }
        floats(f.response, 1052)
        return TelemetryBytes.frame(.tonalBalance, sequence: sequence, payload: Array(p.prefix(length)))
    }

    // MARK: 定数

    func testBandCentresFollowTheERBRate() {
        XCTAssertEqual(T.bandCentres.count, 41)
        XCTAssertEqual(T.bandCentres[0], 26.0, accuracy: 0.1)
        XCTAssertEqual(T.bandCentres[40], 18600, accuracy: 100)
        XCTAssertEqual(T.bandCentres, T.bandCentres.sorted())
        // 応答の 128 点は 20Hz〜20kHz を対数で等間隔。
        XCTAssertEqual(pow(10, T.gridLogFreqs[0]), 20, accuracy: 1e-9)
        XCTAssertEqual(pow(10, T.gridLogFreqs[127]), 20000, accuracy: 1e-6)
        XCTAssertEqual(T.adjustLogFreqs.count, 512)
        XCTAssertEqual(T.curveLogFreqs.count, 128 + 41)
        XCTAssertEqual(T.curveLogFreqs, T.curveLogFreqs.sorted())
    }

    // MARK: Averaging Time

    func testAveragingTimeMapsLogarithmicallyWithInfinityOnTop() {
        XCTAssertEqual(T.averagingTimeToSliderPosition(0.1), 0, accuracy: 1e-9)
        XCTAssertEqual(T.averagingTimeToSliderPosition(100), 100, accuracy: 1e-9)
        XCTAssertEqual(T.averagingTimeToSliderPosition(10.0.squareRoot() * 1), 50, accuracy: 1e-9,
                       "0.1 と 100 の幾何平均 √10 が真ん中")
        XCTAssertEqual(T.sliderPositionToAveragingTime(0), 0.1)
        XCTAssertEqual(T.sliderPositionToAveragingTime(100), 100)
        XCTAssertEqual(T.sliderPositionToAveragingTime(50), 3.2, "√10 = 3.162… を 0.1 に丸める")
        XCTAssertEqual(T.formatAveragingTime(100), "∞")
        XCTAssertEqual(T.formatAveragingTime(30), "30.0")
        XCTAssertEqual(T.formatAveragingTime(0.1), "0.1")
    }

    func testAveragingTimeTypedText() {
        XCTAssertEqual(T.parseAveragingTime("∞"), 100)
        XCTAssertEqual(T.parseAveragingTime(" inf "), 100)
        XCTAssertEqual(T.parseAveragingTime("Infinity"), 100)
        XCTAssertEqual(T.parseAveragingTime("12.5"), 12.5)
        XCTAssertEqual(T.parseAveragingTime("500"), 100, "範囲の上は ∞")
        XCTAssertEqual(T.parseAveragingTime("0.01"), 0.1)
        XCTAssertNil(T.parseAveragingTime("abc"))
        XCTAssertNil(T.parseAveragingTime(""))
    }

    func testShelfQIsCappedAtTwo() {
        XCTAssertEqual(T.maximumQ(type: 0), 10)
        XCTAssertEqual(T.maximumQ(type: 1), 2)
        XCTAssertEqual(T.maximumQ(type: 2), 2)
    }

    // MARK: 枠の読み

    func testParsesAFrame() throws {
        var f = Fields()
        f.target = 5
        f.level[3] = -50.5
        f.bandFlags[3] = 0
        f.response[127] = 3.5
        let r = try XCTUnwrap(T.parse(frame(f, sequence: 11)))
        XCTAssertEqual(r.sampleRate, 48000)
        XCTAssertEqual(r.targetIndex, 5)
        XCTAssertEqual(r.loudness, -23)
        XCTAssertEqual(r.makeup, 1.5)
        XCTAssertTrue(r.loudnessIsValid)
        XCTAssertEqual(r.levelDb[3], -50.5)
        XCTAssertEqual(r.bandFlags[3], 0)
        XCTAssertEqual(r.bandFlags[4], 28)
        XCTAssertEqual(r.response.count, 128)
        XCTAssertEqual(r.response[127], 3.5)
        XCTAssertEqual(r.sequence, 11)
    }

    func testRejectsMalformedFrames() {
        XCTAssertNil(T.parse(nil))
        XCTAssertNil(T.parse(frame(length: 1563)))
        XCTAssertNil(T.parse(frame(length: 1565)))
        XCTAssertNil(T.parse(frame(bands: 40)))
        XCTAssertNil(T.parse(frame(grid: 64)))
        var f = Fields()
        f.rate = 0
        XCTAssertNil(T.parse(frame(f)))
        f = Fields()
        f.level[7] = .nan
        XCTAssertNil(T.parse(frame(f)))
        f = Fields()
        f.response[0] = .infinity
        XCTAssertNil(T.parse(frame(f)))
        f = Fields()
        f.makeup = .nan
        XCTAssertNil(T.parse(frame(f)))
        XCTAssertNil(T.parse(TelemetryBytes.frame(.tonalBalance, version: 2, payload: [UInt8](repeating: 0, count: 1564))))
        XCTAssertNil(T.parse(TelemetryBytes.frame(.level, payload: [UInt8](repeating: 0, count: 1564))))
    }

    // MARK: 補間

    func testInterpolationIsExactOnLinearData() {
        let values = T.bandLogFreqs.map { 3 + 2 * $0 }
        let curve = T.interpolateBands(values)
        XCTAssertEqual(curve.count, T.curveLogFreqs.count)
        let low = T.bandLogFreqs[0], high = T.bandLogFreqs[40]
        var inside = 0
        for (i, x) in T.curveLogFreqs.enumerated() {
            if x < low || x > high {
                XCTAssertTrue(curve[i].isNaN, "帯域の外は NaN: \(x)")
            } else {
                XCTAssertEqual(curve[i], 3 + 2 * x, accuracy: 1e-9)
                inside += 1
            }
        }
        XCTAssertGreaterThan(inside, 100)
    }

    func testInterpolationPassesThroughEveryBandAndStaysBetweenNeighbours() {
        // 凸凹のある値でも、帯域の中心は値のまま通り、隣り合う 2 つの値の外へは出ない（単調）。
        let values = (0..<41).map { Double(($0 * 7) % 11) - 5 }
        let curve = T.interpolateBands(values)
        for band in 0..<41 {
            let x = T.bandLogFreqs[band]
            let index = T.curveLogFreqs.firstIndex(of: x)
            XCTAssertNotNil(index, "帯域の中心は曲線の点に入っている")
            XCTAssertEqual(curve[index!], values[band], accuracy: 1e-12)
        }
        for (i, x) in T.curveLogFreqs.enumerated() where curve[i].isFinite {
            let upper = T.bandLogFreqs.firstIndex { $0 >= x } ?? 40
            let lower = max(upper - 1, 0)
            let bounds = (min(values[lower], values[upper]), max(values[lower], values[upper]))
            XCTAssertGreaterThanOrEqual(curve[i], bounds.0 - 1e-9)
            XCTAssertLessThanOrEqual(curve[i], bounds.1 + 1e-9)
        }
    }

    func testInterpolationBreaksAtAMissingBand() {
        var values = T.bandLogFreqs.map { 3 + 2 * $0 }
        values[20] = .nan
        let curve = T.interpolateBands(values)
        for (i, x) in T.curveLogFreqs.enumerated() {
            if x > T.bandLogFreqs[19] && x < T.bandLogFreqs[21] {
                XCTAssertTrue(curve[i].isNaN, "欠けた帯域のまわりは NaN")
            }
            if x == T.bandLogFreqs[19] { XCTAssertEqual(curve[i], values[19], accuracy: 1e-12) }
        }
    }

    // MARK: 密度の差

    func testDensityOffsets() {
        let offsets = T.densityOffsets(sampleRate: 48000)
        XCTAssertEqual(offsets.count, 41)
        // 48kHz は FFT 4096（bin 11.71875Hz）。帯域 0（26Hz）は bin 2〜3 の 2 本。
        XCTAssertEqual(offsets[0], 10 * log10(2 * 48000.0 / 4096), accuracy: 1e-9)
        for band in 20..<41 { XCTAssertTrue(offsets[band].isFinite, "\(band)") }
        // 帯域幅が広いほど大きい。
        XCTAssertGreaterThan(offsets[40], offsets[20])
        XCTAssertGreaterThan(offsets[20], offsets[0])
    }

    // MARK: 描く曲線

    func testAlignedMeasurementEqualsTheTargetWhenOffsetByAConstant() throws {
        let r = try XCTUnwrap(T.parse(frame()))
        let d = T.display(reading: r, range: 12, amount: 1)
        for band in 0..<41 {
            XCTAssertTrue(d.target[band].isFinite)
            XCTAssertEqual(d.targetHigh[band] - d.target[band], 2, accuracy: 1e-9, "± sigma")
            // 全帯域が 6 dB 低いだけなので、そろえれば目標に重なり、持ち上げは要らない。
            XCTAssertEqual(d.measured[band], d.target[band], accuracy: 1e-5)
            XCTAssertEqual(d.lift[band], 0, accuracy: 1e-9)
            XCTAssertEqual(d.presence[band], 0.5, accuracy: 1e-9)
        }
        XCTAssertEqual(d.curves.target.count, T.curveLogFreqs.count)
        XCTAssertEqual(d.response.count, 128)
    }

    func testAMissingBandLiftsByTheClippedDeficitTimesWhatPresenceLeaves() throws {
        var f = Fields()
        f.level[10] = f.mu[10] - 12          // 他は 6 dB 低い。この 1 本だけ 12 dB 低い。
        let r = try XCTUnwrap(T.parse(frame(f)))
        let d = T.display(reading: r, range: 12, amount: 1)
        // 重みは presence + (1 - 内容の割合) × persistence = 1。合わせるずれは 6.1463。
        let offset = (6.0 * 40 + 12) / 41
        XCTAssertEqual(d.lift[10], 0.5 * (12 - offset), accuracy: 1e-5)
        for band in 0..<41 where band != 10 { XCTAssertEqual(d.lift[band], 0, accuracy: 1e-9, "\(band)") }
        // Range で挟む。2 dB に絞れば持ち上げも 2 dB まで。
        let narrow = T.display(reading: r, range: 2, amount: 1)
        XCTAssertEqual(narrow.lift[10], 0.5 * 2, accuracy: 1e-9)
        // Amount 0 なら持ち上げ無し。
        XCTAssertEqual(T.display(reading: r, range: 12, amount: 0).lift[10], 0, accuracy: 1e-12)
    }

    func testBandsWithoutALevelStayBlank() throws {
        var f = Fields()
        f.bandFlags[5] = 4          // 目標だけ。測定が無い。
        f.bandFlags[6] = 8          // 測定だけ。目標が無い。
        let r = try XCTUnwrap(T.parse(frame(f)))
        let d = T.display(reading: r, range: 12, amount: 1)
        XCTAssertTrue(d.target[5].isFinite)
        XCTAssertTrue(d.measured[5].isNaN)
        XCTAssertTrue(d.target[6].isNaN)
        XCTAssertTrue(d.measured[6].isFinite)
        XCTAssertTrue(d.lift[5].isNaN)
        XCTAssertTrue(d.lift[6].isNaN, "Low–High の外は補正されない")
    }

    // MARK: Target adjust

    func testBandResponse() {
        let rate = 48000.0
        func band(_ type: Int, gain: Double, q: Double = 1) -> T.AdjustBand {
            .init(enabled: true, type: type, frequency: 1000, gain: gain, q: q)
        }
        // 中心でちょうどゲイン。
        XCTAssertEqual(T.bandResponseDB(frequency: 1000, band: band(0, gain: 6), sampleRate: rate), 6, accuracy: 0.01)
        XCTAssertEqual(T.bandResponseDB(frequency: 1000, band: band(0, gain: -9.5), sampleRate: rate), -9.5, accuracy: 0.01)
        // 0.01 dB 未満は素通し。
        XCTAssertEqual(T.bandResponseDB(frequency: 1000, band: band(0, gain: 0.005), sampleRate: rate), 0)
        // 遠くでは動かない。
        XCTAssertEqual(T.bandResponseDB(frequency: 20, band: band(0, gain: 6), sampleRate: rate), 0, accuracy: 0.05)
        // シェルフは片側がゲインに着く。
        XCTAssertEqual(T.bandResponseDB(frequency: 20, band: band(1, gain: 6), sampleRate: rate), 6, accuracy: 0.05)
        XCTAssertEqual(T.bandResponseDB(frequency: 20000, band: band(2, gain: 6), sampleRate: rate), 6, accuracy: 0.3)
        // シェルフの Q は 2 で止まる（5 と 2 が同じ）。
        XCTAssertEqual(T.bandResponseDB(frequency: 700, band: band(1, gain: 6, q: 5), sampleRate: rate),
                       T.bandResponseDB(frequency: 700, band: band(1, gain: 6, q: 2), sampleRate: rate), accuracy: 1e-12)
        // peaking は 5 と 2 が違う。
        XCTAssertNotEqual(T.bandResponseDB(frequency: 700, band: band(0, gain: 6, q: 5), sampleRate: rate),
                          T.bandResponseDB(frequency: 700, band: band(0, gain: 6, q: 2), sampleRate: rate))
    }

    func testAdjustCurveSumsEnabledBands() {
        let rate = 48000.0
        let flat = T.ETAdjustFixture.flatBands
        let none = T.adjustCurve(bands: flat, sampleRate: rate)
        XCTAssertEqual(none.count, 512)
        XCTAssertTrue(none.allSatisfy { $0 == 0 })
        var bands = flat
        bands[2].gain = 6                    // 1000Hz
        bands[3].gain = 6
        bands[3].enabled = false
        let curve = T.adjustCurve(bands: bands, sampleRate: rate)
        let index = T.adjustLogFreqs.indices.min { abs(T.adjustLogFreqs[$0] - 3) < abs(T.adjustLogFreqs[$1] - 3) }!
        XCTAssertEqual(curve[index], T.bandResponseDB(frequency: pow(10, T.adjustLogFreqs[index]),
                                                      band: bands[2], sampleRate: rate), accuracy: 1e-12)
        XCTAssertGreaterThan(curve[index], 5.5, "切った帯域は足さない")
        XCTAssertLessThan(curve[index], 6.01)
    }

    // MARK: 縦軸

    func testDbRangeGrowsInSixDecibelSteps() {
        var bands = T.ETAdjustFixture.flatBands
        let none = T.fitDbRange(top: 12, bottom: -12, view: nil, adjust: [], adjustBands: bands)
        XCTAssertEqual(none.top, 12)
        XCTAssertEqual(none.bottom, -12)
        bands[0].gain = 15
        let up = T.fitDbRange(top: 12, bottom: -12, view: nil, adjust: [], adjustBands: bands)
        XCTAssertEqual(up.top, 18, "15 + 1.5 = 16.5 を収める 6 の倍数")
        XCTAssertEqual(up.bottom, -12)
        bands[0].gain = -20
        let down = T.fitDbRange(top: 12, bottom: -12, view: nil, adjust: [], adjustBands: bands)
        XCTAssertEqual(down.bottom, -24)
        // 切った帯域の印は数えない。
        bands[0].enabled = false
        XCTAssertEqual(T.fitDbRange(top: 12, bottom: -12, view: nil, adjust: [], adjustBands: bands).bottom, -12)
        // 縮まない。
        let kept = T.fitDbRange(top: 30, bottom: -30, view: nil, adjust: [], adjustBands: bands)
        XCTAssertEqual(kept.top, 30)
        XCTAssertEqual(kept.bottom, -30)
        // 曲線の NaN は無視する。
        XCTAssertEqual(T.fitDbRange(top: 12, bottom: -12, view: nil, adjust: [.nan, 1],
                                    adjustBands: T.ETAdjustFixture.flatBands).top, 12)
    }
}

extension ETTonalBalance {
    /// テスト用: 5 本とも 0 dB の Target adjust（上流の既定の周波数）。
    enum ETAdjustFixture {
        static var flatBands: [ETTonalBalance.AdjustBand] {
            ETTonalBalance.adjustFrequencies.map {
                .init(enabled: true, type: 0, frequency: $0, gain: 0, q: 0.7)
            }
        }
    }
}
