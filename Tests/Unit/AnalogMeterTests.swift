//  AnalogMeterTests.swift
//  Analog Meter（2.12.0）の目盛りの写し方・枠の読み・ピークホールド（DSP/AnalogMeterModel.swift）。
//  **実機もエンジンも要らない。**期待値は analog_meter.js の式から手で出したもの。

import XCTest

final class AnalogMeterTests: XCTestCase {

    // MARK: 枠

    private func frame(mode: Int, channels: [(Float, Float)], flags: UInt16 = 0,
                       program: [Float]? = nil, sequence: UInt32 = 1) -> ETFrame {
        var bytes: [UInt8] = TelemetryBytes.u8(UInt8(mode)) + TelemetryBytes.u8(UInt8(channels.count))
            + TelemetryBytes.u16(flags)
        for (needle, peak) in channels { bytes += TelemetryBytes.f32(needle) + TelemetryBytes.f32(peak) }
        if let program { for v in program { bytes += TelemetryBytes.f32(v) } }
        return TelemetryBytes.frame(.analogMeter, sequence: sequence, payload: bytes)
    }

    func testParsesAStereoFrame() throws {
        let r = try XCTUnwrap(ETAnalogMeter.parse(frame(mode: 0, channels: [(-20, -10), (-18.5, -3)],
                                                        sequence: 9)))
        XCTAssertEqual(r.mode, 0)
        XCTAssertEqual(r.channelCount, 2)
        XCTAssertEqual(r.channels, [.init(needleDB: -20, maxDB: -10), .init(needleDB: -18.5, maxDB: -3)])
        XCTAssertNil(r.program)
        XCTAssertEqual(r.sequence, 9)
    }

    func testParsesLoudnessProgram() throws {
        let r = try XCTUnwrap(ETAnalogMeter.parse(frame(
            mode: 5, channels: [(-24, -24)], flags: 3, program: [-23, -22.5, -23.4, 6.5, -1.25, 125])))
        XCTAssertEqual(r.program, .init(momentary: -23, shortTerm: -22.5, integrated: Double(Float(-23.4)),
                                        lra: 6.5, maxTruePeak: -1.25, integratedSeconds: 125))
        XCTAssertTrue(r.integratedValid)
        XCTAssertTrue(r.lraValid)
    }

    /// Integrated / LRA が無効の間、DSP は 0 を書く。0 以外が来たら門で落とす（decodeAnalogMeter）。
    func testInvalidIntegratedMustBeZero() throws {
        XCTAssertNotNil(ETAnalogMeter.parse(frame(mode: 5, channels: [(-24, -24)], flags: 0,
                                                  program: [-23, -22, 0, 0, -3, 5])))
        XCTAssertNil(ETAnalogMeter.parse(frame(mode: 5, channels: [(-24, -24)], flags: 0,
                                               program: [-23, -22, -20, 0, -3, 5])))
        XCTAssertNil(ETAnalogMeter.parse(frame(mode: 5, channels: [(-24, -24)], flags: 1,
                                               program: [-23, -22, -20, 3, -3, 5])), "LRA 無効で 3")
    }

    func testRejectsMalformedFrames() {
        XCTAssertNil(ETAnalogMeter.parse(nil))
        // mode が範囲の外（2.14.0 で 6 = Custom が増えた）・チャンネル 0・17。
        XCTAssertNil(ETAnalogMeter.parse(frame(mode: 7, channels: [(0, 0)])))
        XCTAssertNil(ETAnalogMeter.parse(frame(mode: 0, channels: [])))
        XCTAssertNil(ETAnalogMeter.parse(frame(mode: 0, channels: Array(repeating: (0, 0), count: 17))))
        // flags は Loudness 以外では 0 のみ。
        XCTAssertNil(ETAnalogMeter.parse(frame(mode: 0, channels: [(0, 0)], flags: 1)))
        // 長さ違い（Loudness に program が無い・余り）。
        XCTAssertNil(ETAnalogMeter.parse(frame(mode: 5, channels: [(0, 0)])))
        XCTAssertNil(ETAnalogMeter.parse(frame(mode: 0, channels: [(0, 0)], program: [1])))
        // NaN・-240 より下。
        XCTAssertNil(ETAnalogMeter.parse(frame(mode: 0, channels: [(.nan, 0)])))
        XCTAssertNil(ETAnalogMeter.parse(frame(mode: 0, channels: [(-241, 0)])))
        // 版違い・型違い。
        XCTAssertNil(ETAnalogMeter.parse(TelemetryBytes.frame(.analogMeter, version: 2,
                                                              payload: [0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])))
        XCTAssertNil(ETAnalogMeter.parse(TelemetryBytes.frame(.level, payload: [0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])))
    }

    // MARK: 目盛り

    private func settings(_ mutate: (inout ETAnalogMeter.Settings) -> Void = { _ in }) -> ETAnalogMeter.Settings {
        var s = ETAnalogMeter.Settings()
        mutate(&s)
        return s
    }

    /// VU は電圧に比例。基準（rl）が 0 VU で、+3 VU が右端。
    func testVUScale() {
        let s = ETAnalogMeter.scale(mode: "VU", settings: settings())
        XCTAssertEqual(s.min, -20)
        XCTAssertEqual(s.max, 3)
        XCTAssertEqual(s.dbPosition(-14), pow(10, 0) / pow(10, 3.0 / 20), accuracy: 1e-12)
        XCTAssertEqual(s.dbPosition(-11), 1, accuracy: 1e-12)
        XCTAssertEqual(s.dbPosition(0), 1, "右端で止まる")
        XCTAssertLessThan(s.dbPosition(-100), 0.001, "電圧に比例するので 0 には着かないが、ほぼ左端")
        XCTAssertEqual(s.readout(-14), "0.0 VU")
        XCTAssertEqual(s.readout(-11), "+3.0 VU")
        XCTAssertEqual(s.readout(-200), "-∞")
        // 目盛りの字は -1 と 1 だけ空。
        XCTAssertEqual(s.ticks.filter { $0.label.isEmpty }.map(\.value), [-1, 1])
        XCTAssertEqual(s.reference, 0)
        XCTAssertEqual(s.redFrom, 0)
    }

    /// BBC PPM は 1〜7 の目盛り。2〜7 は 4 dB おき、1 は 2 の 6 dB 下。基準は 4（rl）。
    func testBBCPPMMarks() {
        let s = ETAnalogMeter.scale(mode: "PPM", settings: settings { $0.ppmScale = 1; $0.reference = -18 })
        XCTAssertEqual(s.toLabel(-18), 4)
        XCTAssertEqual(s.toLabel(-26), 2, accuracy: 1e-12)
        XCTAssertEqual(s.toLabel(-32), 1, accuracy: 1e-12)
        XCTAssertEqual(s.toLabel(-10), 6, accuracy: 1e-12)
        XCTAssertEqual(s.valuePosition(4), 0.5, accuracy: 1e-12)
        XCTAssertEqual(s.readout(-18), "Mark 4.0")
        XCTAssertEqual(s.redFrom, 6)
        XCTAssertEqual(s.ticks.map(\.label), ["1", "2", "3", "4", "5", "6", "7"])
    }

    /// DIN は基準が -9、Nagra（sc = 2）は 0 dB が基準。
    func testDINAndNagraPPM() {
        let din = ETAnalogMeter.scale(mode: "PPM", settings: settings { $0.reference = -18; $0.range = 50 })
        XCTAssertEqual(din.min, -50)
        XCTAssertEqual(din.max, 5)
        XCTAssertEqual(din.reference, -9)
        XCTAssertEqual(din.toLabel(-18), -9, accuracy: 1e-12, "rl が基準の -9")
        XCTAssertEqual(din.ticks.first { $0.value == -10 }?.label, "", "-10 は字を出さない")
        let nagra = ETAnalogMeter.scale(mode: "PPM", settings: settings {
            $0.ppmScale = 2; $0.reference = -18; $0.range = 30 })
        XCTAssertEqual(nagra.reference, 0)
        XCTAssertEqual(nagra.toLabel(-18), 0)
        XCTAssertEqual(nagra.ticks.map(\.value), [-30, -25, -20, -15, -10, -5, 0, 5], "range <= 30 は 5 dB おき")
    }

    func testRMSAndPeakScales() {
        let rms = ETAnalogMeter.scale(mode: "RMS", settings: settings { $0.reference = -20; $0.range = 40 })
        XCTAssertEqual(rms.min, -40)
        XCTAssertEqual(rms.max, 20)
        XCTAssertEqual(rms.ticks.map(\.value), [-40, -30, -20, -10, 0, 10, 20])
        XCTAssertEqual(rms.dbPosition(-20), 2.0 / 3, accuracy: 1e-12)
        XCTAssertNil(rms.redFrom)
        let tp = ETAnalogMeter.scale(mode: "True Peak", settings: settings { $0.range = 20 })
        XCTAssertEqual(tp.unit, "dBTP")
        XCTAssertEqual(tp.ticks.map(\.value), [-20, -15, -10, -5, 0])
        XCTAssertEqual(tp.readout(-1.5), "-1.5 dBTP")
        let sp = ETAnalogMeter.scale(mode: "Sample Peak", settings: settings { $0.range = 60 })
        XCTAssertEqual(sp.ticks.first?.value, -60)
        XCTAssertEqual(sp.ticks.map(\.value).prefix(3).map { $0 }, [-60, -50, -40], "range > 30 は 10 dB おき")
    }

    /// Loudness の目盛りは Target を中心に -18..+9（EBU +9）か -36..+18。字は絶対値の LUFS。
    func testLoudnessScale() {
        let narrow = ETAnalogMeter.scale(mode: "Loudness", settings: settings { $0.target = -23 })
        XCTAssertEqual(narrow.min, -41)
        XCTAssertEqual(narrow.max, -14)
        XCTAssertEqual(narrow.reference, -23)
        XCTAssertEqual(narrow.ticks.map(\.label), ["-41", "-38", "-35", "-32", "-29", "-26", "-23", "-20", "-17", "-14"])
        XCTAssertEqual(narrow.readout(-23), "-23.0 LUFS")
        let wide = ETAnalogMeter.scale(mode: "Loudness", settings: settings { $0.target = -14; $0.loudnessScale = 1 })
        XCTAssertEqual(wide.min, -50)
        XCTAssertEqual(wide.max, 4)
        XCTAssertEqual(wide.ticks.count, 10, "6 LU おき: -36..18")
    }

    func testSparseLabelsKeepEveryOtherFromTheReference() {
        let s = ETAnalogMeter.scale(mode: "Loudness", settings: settings())
        let kept = ETAnalogMeter.sparseLabels(s)
        // 基準 -23 から数えて 1 つおき。
        XCTAssertTrue(kept.contains(-23))
        XCTAssertFalse(kept.contains(-26))
        XCTAssertTrue(kept.contains(-29))
        XCTAssertTrue(kept.contains(-17))
    }

    func testLinearTicksIncludeExtrasAndDropOutOfRange() {
        let ticks = ETAnalogMeter.linearTicks(-12, 5, 10, extra: [-9, 5, 99], unlabeled: [-10])
        XCTAssertEqual(ticks.map(\.value), [-10, -9, 0, 5])
        XCTAssertEqual(ticks.map(\.label), ["", "-9", "0", "5"])
        XCTAssertEqual(ETAnalogMeter.jsString(-0.0), "0")
        XCTAssertEqual(ETAnalogMeter.jsString(2.5), "2.5")
    }

    // MARK: 並べ方

    func testGrid() {
        XCTAssertEqual(ETAnalogMeter.grid(cells: 0), .init(cells: 1, columns: 1, rows: 1))
        XCTAssertEqual(ETAnalogMeter.grid(cells: 2), .init(cells: 2, columns: 2, rows: 1))
        XCTAssertEqual(ETAnalogMeter.grid(cells: 5), .init(cells: 5, columns: 4, rows: 2))
        XCTAssertEqual(ETAnalogMeter.grid(cells: 5, maxColumns: ETAnalogMeter.mobileColumns),
                       .init(cells: 5, columns: 2, rows: 3))
        // 針 1 つは 4:3。
        XCTAssertEqual(ETAnalogMeter.grid(cells: 3).aspect, 3 * 4.0 / 3, accuracy: 1e-12)
        XCTAssertEqual(ETAnalogMeter.cellCount(mode: 5, channelCount: 2), 3, "Loudness は Program が 1 つ増える")
        XCTAssertEqual(ETAnalogMeter.cellCount(mode: 0, channelCount: 2), 2)
    }

    // MARK: 行の出し分け

    func testRowsActiveByMode() {
        func active(_ mode: Int, sc: Int = 0) -> Set<String> {
            var s = ETAnalogMeter.Settings()
            s.mode = mode
            s.ppmScale = sc
            return Set(["it", "at", "rt", "rl", "rg", "sc", "ph", "ln", "tg", "ls"]
                .filter { ETAnalogMeter.isActive($0, settings: s) })
        }
        XCTAssertEqual(active(0), ["rl"], "VU")
        XCTAssertEqual(active(1), ["at", "rt", "rl", "rg", "sc", "ph"], "PPM DIN")
        XCTAssertEqual(active(1, sc: 1), ["at", "rt", "rl", "sc", "ph"], "BBC は Range が効かない")
        XCTAssertEqual(active(2), ["it", "rl", "rg", "ph"], "RMS")
        XCTAssertEqual(active(3), ["rt", "rg", "ph"], "Sample Peak")
        XCTAssertEqual(active(4), ["rt", "rg", "ph"], "True Peak")
        XCTAssertEqual(active(5), ["ln", "tg", "ls"], "Loudness")
        XCTAssertTrue(ETAnalogMeter.holdsPeak(mode: 1))
        XCTAssertFalse(ETAnalogMeter.holdsPeak(mode: 0))
        XCTAssertFalse(ETAnalogMeter.holdsPeak(mode: 5))
    }

    func testSettingsClamp() {
        typealias S = ETAnalogMeter.Settings
        XCTAssertEqual(S.clamped(-99, -30, 0, previous: -14), -30)
        XCTAssertEqual(S.clamped(5, -30, 0, previous: -14), 0)
        XCTAssertEqual(S.clamped(.nan, -30, 0, previous: -14), -14)
        XCTAssertEqual(S.clamped(.infinity, -30, 0, previous: -14), -14, "無限は前の値（parseFiniteNumber）")
    }

    // MARK: ピークホールド

    func testPeakHold() {
        typealias A = ETAnalogMeter
        var hold = A.Hold(db: .nan, time: 0, overTime: nil)
        hold = A.updateHold(hold, db: -12, now: 10, holdSeconds: 1)
        XCTAssertEqual(hold.db, -12)
        // 低い読みの間は保持する。
        hold = A.updateHold(hold, db: -20, now: 10.5, holdSeconds: 1)
        XCTAssertEqual(hold.db, -12)
        XCTAssertEqual(hold.time, 10)
        // 高い読みは上書き。
        hold = A.updateHold(hold, db: -8, now: 10.6, holdSeconds: 1)
        XCTAssertEqual(hold.db, -8)
        // 時間が過ぎたら検出器に付いていく。
        hold = A.updateHold(hold, db: -30, now: 12, holdSeconds: 1)
        XCTAssertEqual(hold.db, -30)
        // Peak Hold 0 は保持しない。
        hold = A.updateHold(hold, db: -40, now: 12.1, holdSeconds: 0)
        XCTAssertEqual(hold.db, -40)
    }

    func testOverLampStaysLitForTheHoldOrOneSecond() {
        typealias A = ETAnalogMeter
        var hold = A.Hold(db: -1, time: 5, overTime: nil)
        XCTAssertFalse(A.isOverLit(hold, now: 5, holdSeconds: 2))
        hold = A.updateHold(hold, db: 0.5, now: 6, holdSeconds: 2)
        XCTAssertEqual(hold.overTime, 6)
        XCTAssertTrue(A.isOverLit(hold, now: 7.9, holdSeconds: 2))
        XCTAssertFalse(A.isOverLit(hold, now: 8.1, holdSeconds: 2))
        // Peak Hold 0 でも記録し、1 秒点く。
        hold = A.updateHold(A.Hold(), db: 2, now: 1, holdSeconds: 0)
        XCTAssertEqual(hold.overTime, 1)
        XCTAssertTrue(A.isOverLit(hold, now: 1.9, holdSeconds: 0))
        XCTAssertFalse(A.isOverLit(hold, now: 2.1, holdSeconds: 0))
        XCTAssertFalse(A.isOverLit(nil, now: 0, holdSeconds: 1))
    }

    // MARK: 文字

    func testDurationText() {
        XCTAssertEqual(ETAnalogMeter.duration(0), "0:00")
        XCTAssertEqual(ETAnalogMeter.duration(59.9), "0:59")
        XCTAssertEqual(ETAnalogMeter.duration(125), "2:05")
        XCTAssertEqual(ETAnalogMeter.duration(3661), "1:01:01")
        XCTAssertEqual(ETAnalogMeter.duration(-5), "0:00")
        // Float の枠は 3e38 まで運べる。Int に入らなくても落ちない。
        XCTAssertFalse(ETAnalogMeter.duration(3e38).isEmpty)
    }

    func testCellTitlesAndReadings() throws {
        XCTAssertEqual(ETAnalogMeter.cellTitle(channel: 1, mode: 0, channelCount: 2), "Ch 2")
        XCTAssertEqual(ETAnalogMeter.cellTitle(channel: 1, mode: 5, channelCount: 2), "Ch 2 (reference)")
        XCTAssertEqual(ETAnalogMeter.cellTitle(channel: -1, mode: 5, channelCount: 2), "Program")
        XCTAssertEqual(ETAnalogMeter.cellTitle(channel: -1, mode: 5, channelCount: 6), "Program")
        XCTAssertEqual(ETAnalogMeter.cellTitle(channel: -1, mode: 5, channelCount: 4), "Program (reference)")

        let r = try XCTUnwrap(ETAnalogMeter.parse(frame(
            mode: 5, channels: [(-24, -20)], flags: 3, program: [-23, -22, -23, 5, -2, 10])))
        XCTAssertEqual(ETAnalogMeter.cellReading(channel: -1, reading: r, mode: 5, needle: 0), -23)
        XCTAssertEqual(ETAnalogMeter.cellReading(channel: -1, reading: r, mode: 5, needle: 1), -22)
        // Loudness の各チャンネルは、Short-term のとき maxDb（上流の cellReading）。
        XCTAssertEqual(ETAnalogMeter.cellReading(channel: 0, reading: r, mode: 5, needle: 0), -24)
        XCTAssertEqual(ETAnalogMeter.cellReading(channel: 0, reading: r, mode: 5, needle: 1), -20)
        XCTAssertNil(ETAnalogMeter.cellReading(channel: 3, reading: r, mode: 5, needle: 0))
        XCTAssertNil(ETAnalogMeter.cellReading(channel: 0, reading: nil, mode: 0, needle: 0))
    }

    // MARK: 2.12.0 の見た目の寄せ方

    func testTrimZerosMatchesUpstreamNumberInputs() {
        XCTAssertEqual(ETAnalogMeter.trimZeros("5.00"), "5")
        XCTAssertEqual(ETAnalogMeter.trimZeros("1.50"), "1.5")
        XCTAssertEqual(ETAnalogMeter.trimZeros("10.0"), "10")
        XCTAssertEqual(ETAnalogMeter.trimZeros("0.0"), "0")
        XCTAssertEqual(ETAnalogMeter.trimZeros("-0.00"), "0")
        XCTAssertEqual(ETAnalogMeter.trimZeros("0.25"), "0.25")
        XCTAssertEqual(ETAnalogMeter.trimZeros("100"), "100", "小数点が無ければ 0 を落とさない")
        XCTAssertEqual(ETAnalogMeter.trimZeros("-14"), "-14")
    }

    /// 強調するのは基準の目盛りだけ（上流 analog_meter.js:759-772）。赤い帯の始まりは強調しない。
    func testEmphasizedTickIsOnlyTheReference() {
        let din = ETAnalogMeter.scale(mode: "PPM", settings: settings())
        XCTAssertTrue(ETAnalogMeter.isEmphasized(-9, in: din))
        XCTAssertFalse(ETAnalogMeter.isEmphasized(0, in: din), "DIN の 0 は赤の始まりで、基準ではない")
        XCTAssertFalse(ETAnalogMeter.isEmphasized(-5, in: din))
        let peak = ETAnalogMeter.scale(mode: "Sample Peak", settings: settings())
        XCTAssertFalse(ETAnalogMeter.isEmphasized(0, in: peak), "基準も赤も無い針")
        let loud = ETAnalogMeter.scale(mode: "Loudness", settings: settings())
        XCTAssertTrue(ETAnalogMeter.isEmphasized(-23, in: loud))
    }

    func testStatsGoToTheEmptySlotOrABand() {
        // 針 3 つ: iPad の 3 列には空きが無く、iPhone の 2 列には 4 つ目が空く。
        XCTAssertFalse(ETAnalogMeter.hasEmptySlot(ETAnalogMeter.grid(cells: 3)))
        XCTAssertTrue(ETAnalogMeter.hasEmptySlot(ETAnalogMeter.grid(cells: 3, maxColumns: 2)))
        XCTAssertFalse(ETAnalogMeter.hasEmptySlot(ETAnalogMeter.grid(cells: 2, maxColumns: 2)))
        XCTAssertTrue(ETAnalogMeter.hasEmptySlot(ETAnalogMeter.grid(cells: 7)), "8 枠に 7 つ")
    }

    func testStatRowsKeepUpstreamTexts() {
        let p = ETAnalogMeter.Program(momentary: -13.44, shortTerm: -15.6, integrated: -15.4, lra: 0.44,
                                      maxTruePeak: -5.4, integratedSeconds: 9)
        let rows = ETAnalogMeter.statRows(program: p, integratedValid: true, lraValid: true)
        XCTAssertEqual(rows.map(\.label), ["M", "S", "I", "LRA", "TP", "Time"])
        XCTAssertEqual(rows.map(\.value), ["-13.4 LUFS", "-15.6 LUFS", "-15.4 LUFS", "0.4 LU", "-5.4 dBTP", "0:09"])
        let off = ETAnalogMeter.statRows(program: p, integratedValid: false, lraValid: false)
        XCTAssertEqual(off[2].value, "--- LUFS")
        XCTAssertEqual(off[3].value, "--- LU")
        var silent = p
        silent.momentary = -200
        XCTAssertEqual(ETAnalogMeter.statRows(program: silent, integratedValid: true, lraValid: true)[0].value, "-∞ LUFS")
    }
}
