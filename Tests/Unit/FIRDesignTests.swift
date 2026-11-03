//  FIRDesignTests.swift
//  FIR設計の共通の道具（DSP/FIRDesign.swift）。**実機もエンジンも要らない。**
//
//  7つの設計（5Band FIR PEQ・FIR Crossover・Bass Management・Group Delay EQ/PEQ・Crosstalk・Room EQ）が
//  このFFT・窓・最小位相を通る。ここが狂うと全部の曲線が黙って変わる。
//
//  見本は上流のJSそのものが吐いたもの（Tests/Fixtures/FIR/fir-golden.json。作り直すときは
//  `EFFETUNE_ROOT=$(bash Tools/golden/extract_pin.sh) node Tools/golden/fir_golden.mjs`）。
//  上流のFFTは回転因子の表がFloat32Arrayなので、FFTを通る見本（最小位相・群遅延）は
//  その分の差を見込んだ許容で比べる。FFTを通らないもの（窓・リサンプラ・丸め・読み取り）は
//  ほぼビットまで合わせる。
//
//  **Linuxではvdspの代役（Tests/Linux/Shims/Accelerate）で走る。**代役は素朴なDFTなので、
//  RealFFTの詰め方（testRealFFTMatchesDFTPacking）が本当に確かめられるのはMacだけ。

import XCTest
import Foundation

final class FIRDesignTests: XCTestCase {

    // MARK: - 見本

    private struct Golden: Decodable {
        let bessel: [[Double]]
        let jsRound: [RoundRow]
        let measureResponse: [Measure]
        let minimumPhase: [MinimumPhase]
        let resample: [Resample]
        let sampleAtFrequency: Sampling
        let windows: [Window]
        let zeroTail: ZeroTail

        struct RoundRow: Decodable {
            let input: Double
            let expected: Double
            init(from decoder: Decoder) throws {
                var row = try decoder.unkeyedContainer()
                let x = try row.decode(Double.self)
                let r = try row.decode(Double.self)
                let inputNegativeZero = try row.decode(Bool.self)
                let expectedNegativeZero = try row.decode(Bool.self)
                input = inputNegativeZero ? -0.0 : x
                expected = expectedNegativeZero ? -0.0 : r
            }
        }

        struct Measure: Decodable {
            let name: String
            let ir: String
            let size: Int
            let sampleRate: Double
            let bulkDelaySamples: Double
            let frequencies: String
            let realizedMs: String
            let rippleDb: Double
        }

        struct MinimumPhase: Decodable {
            let name: String
            let fftSize: Int
            let magnitudes: String
            let phase: String
        }

        struct Resample: Decodable {
            let name: String
            let input: String
            let output: String
            let sourceRate: Int
            let targetRate: Int
            let radius: Int?
        }

        struct Sampling: Decodable {
            let fftSize: Int
            let sampleRate: Double
            let values: [Double]
            let queries: [[Double]]
        }

        struct Window: Decodable {
            let taps: Int
            let minimumPhase: Bool
            let window: String
        }

        struct ZeroTail: Decodable {
            let source: [Double]
            let starts: [Start]

            struct Start: Decodable {
                let start: Int
                let expected: [Double]
                init(from decoder: Decoder) throws {
                    var row = try decoder.unkeyedContainer()
                    start = try row.decode(Int.self)
                    expected = try row.decode([Double].self)
                }
            }
        }
    }

    private static var cached: Golden?

    private func golden() throws -> Golden {
        if let g = Self.cached { return g }
        let file = try XCTUnwrap(TestResource.url("fir-golden", "json"))
        let g = try JSONDecoder().decode(Golden.self, from: Data(contentsOf: file))
        Self.cached = g
        return g
    }

    private static func bytes(_ base64: String) throws -> [UInt8] {
        [UInt8](try XCTUnwrap(Data(base64Encoded: base64)))
    }

    /// float32のリトルエンディアンをbase64にしたもの。
    private static func floats(_ base64: String) throws -> [Float] {
        let b = try bytes(base64)
        XCTAssertEqual(b.count % 4, 0)
        return (0..<b.count / 4).map { i in
            var bits: UInt32 = 0
            for k in 0..<4 { bits |= UInt32(b[4 * i + k]) << (8 * UInt32(k)) }
            return Float(bitPattern: bits)
        }
    }

    /// float64のリトルエンディアンをbase64にしたもの。
    private static func doubles(_ base64: String) throws -> [Double] {
        let b = try bytes(base64)
        XCTAssertEqual(b.count % 8, 0)
        return (0..<b.count / 8).map { i in
            var bits: UInt64 = 0
            for k in 0..<8 { bits |= UInt64(b[8 * i + k]) << (8 * UInt64(k)) }
            return Double(bitPattern: bits)
        }
    }

    /// 決まった乱数（-1〜1）。
    private static func noise(_ count: Int, seed: UInt32) -> [Double] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return Double(state) / 4_294_967_296 * 2 - 1
        }
    }

    private static func maxDifference(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).reduce(0) { max($0, abs($1.0 - $1.1)) }
    }

    // MARK: - FFT

    /// 前進→逆で元に戻る（N=4〜4096、1e-12以内）。
    func testRealFFTRoundTrip() throws {
        var size = 4
        while size <= 4096 {
            let fft = try XCTUnwrap(FIRDesign.RealFFT(size: size))
            let input = Self.noise(size, seed: UInt32(size))
            let spectrum = fft.realTransform(input)
            XCTAssertEqual(spectrum.real.count, size / 2 + 1)
            XCTAssertEqual(spectrum.imag.count, size / 2 + 1)
            let back = fft.inverseRealTransform(real: spectrum.real, imag: spectrum.imag)
            XCTAssertEqual(back.count, size)
            XCTAssertLessThanOrEqual(Self.maxDifference(back, input), 1e-12, "N=\(size)")
            size *= 2
        }
    }

    /// **fft.jsと同じ約束で詰める。**前進は正規化なしのDFTで0〜N/2（DCとNyquistの虚部は0）、
    /// 逆は1/Nを掛けた実部だけ（imag[0]とimag[N/2]は結果に効かない）。素朴なDFTとN=4〜1024で照合する。
    /// 短い入力は0で埋め、長い入力は先頭N個だけを見る。
    func testRealFFTMatchesDFTPacking() throws {
        var size = 4
        while size <= 1024 {
            let fft = try XCTUnwrap(FIRDesign.RealFFT(size: size))
            let half = size / 2
            let input = Self.noise(size, seed: 7 &+ UInt32(size))
            let spectrum = fft.realTransform(input)
            var worst = 0.0
            for k in 0...half {
                var re = 0.0
                var im = 0.0
                for n in 0..<size {
                    let angle = 2 * Double.pi * Double(k * n % size) / Double(size)
                    re += input[n] * cos(angle)
                    im -= input[n] * sin(angle)
                }
                worst = max(worst, abs(spectrum.real[k] - re), abs(spectrum.imag[k] - im))
            }
            XCTAssertLessThanOrEqual(worst, 1e-9, "forward N=\(size)")
            XCTAssertEqual(spectrum.imag[0], 0, "N=\(size) DCの虚部")
            XCTAssertEqual(spectrum.imag[half], 0, "N=\(size) Nyquistの虚部")

            // 逆。imag[0]とimag[N/2]に値を入れても実部の出力は変わらない。
            var real = Self.noise(half + 1, seed: 11 &+ UInt32(size))
            var imag = Self.noise(half + 1, seed: 13 &+ UInt32(size))
            let output = fft.inverseRealTransform(real: real, imag: imag)
            var expected = [Double](repeating: 0, count: size)
            for n in 0..<size {
                var sum = real[0] + real[half] * (n % 2 == 0 ? 1 : -1)
                for k in 1..<half {
                    let angle = 2 * Double.pi * Double(k * n % size) / Double(size)
                    sum += 2 * (real[k] * cos(angle) - imag[k] * sin(angle))
                }
                expected[n] = sum / Double(size)
            }
            XCTAssertLessThanOrEqual(Self.maxDifference(output, expected), 1e-9, "inverse N=\(size)")
            imag[0] = 0
            imag[half] = 0
            XCTAssertLessThanOrEqual(Self.maxDifference(fft.inverseRealTransform(real: real, imag: imag), output),
                                     1e-15, "imag[0]・imag[N/2]は効かない N=\(size)")
            // 足りない配列は0とみなす。
            real.removeLast()
            let short = fft.inverseRealTransform(real: real, imag: [])
            XCTAssertEqual(short.count, size)
            size *= 2
        }

        let fft = try XCTUnwrap(FIRDesign.RealFFT(size: 8))
        let shortInput: [Double] = [1, 2, 3]
        let padded = fft.realTransform(shortInput + [0, 0, 0, 0, 0])
        let fromShort = fft.realTransform(shortInput)
        XCTAssertEqual(fromShort.real, padded.real)
        XCTAssertEqual(fromShort.imag, padded.imag)
        let longInput = Self.noise(12, seed: 99)
        let fromLong = fft.realTransform(longInput)
        let firstEight = fft.realTransform(Array(longInput.prefix(8)))
        XCTAssertEqual(fromLong.real, firstEight.real)
        XCTAssertEqual(fromLong.imag, firstEight.imag)
        let empty = fft.realTransform([])
        XCTAssertEqual(empty.real, [Double](repeating: 0, count: 5))
    }

    func testInitRejectsNonPow2AndSmall() {
        for size in [-4, 0, 1, 2, 3, 5, 6, 12, 1000, 4097] {
            XCTAssertNil(FIRDesign.RealFFT(size: size), "\(size)")
            XCTAssertNil(FIRDesign.fft(size: size), "\(size)")
        }
        for size in [4, 8, 16, 1024, 65536] {
            XCTAssertEqual(FIRDesign.RealFFT(size: size)?.size, size)
        }
    }

    /// 大きさごとに1つだけ作って使い回す（fft.jsのplanCacheと同じ役目）。
    func testFFTCacheSameInstance() throws {
        let a = try XCTUnwrap(FIRDesign.fft(size: 256))
        let b = try XCTUnwrap(FIRDesign.fft(size: 256))
        let c = try XCTUnwrap(FIRDesign.fft(size: 512))
        XCTAssertTrue(a === b)
        XCTAssertFalse(a === c)
        XCTAssertEqual(c.size, 512)
    }

    func testNextPowerOfTwo() {
        XCTAssertEqual(FIRDesign.nextPowerOfTwo(-5), 1)
        XCTAssertEqual(FIRDesign.nextPowerOfTwo(0), 1)
        XCTAssertEqual(FIRDesign.nextPowerOfTwo(1), 1)
        XCTAssertEqual(FIRDesign.nextPowerOfTwo(2), 2)
        XCTAssertEqual(FIRDesign.nextPowerOfTwo(3), 4)
        XCTAssertEqual(FIRDesign.nextPowerOfTwo(1024), 1024)
        XCTAssertEqual(FIRDesign.nextPowerOfTwo(1025), 2048)
        XCTAssertEqual(FIRDesign.nextPowerOfTwo(131_073), 262_144)
    }

    // MARK: - 窓

    /// I0(1) = 1.2660658777520082。20項で打ち切る上流と同じ数（大きい値ほど本当のI0から離れる）。
    func testBesselI0() throws {
        XCTAssertEqual(FIRDesign.besselI0(0), 1)
        XCTAssertEqual(FIRDesign.besselI0(1), 1.2660658777520082, accuracy: 1e-15)
        XCTAssertEqual(FIRDesign.besselI0(-2), FIRDesign.besselI0(2))
        let rows = try golden().bessel
        XCTAssertGreaterThanOrEqual(rows.count, 10)
        for row in rows {
            let value = FIRDesign.besselI0(row[0])
            XCTAssertLessThanOrEqual(abs(value - row[1]) / row[1], 1e-14, "I0(\(row[0])) \(value) vs \(row[1])")
        }
    }

    /// 最小位相は後ろ1割だけを落とす。頭から9割は1、落ち始めは1、最後は0、その間は単調に下がる。
    func testCreateWindowMinPhaseFadesLast10Pct() {
        for taps in [100, 1000, 8192] {
            let window = FIRDesign.createWindow(taps: taps, minimumPhase: true)
            let fadeStart = Int((Double(taps) * 0.9).rounded(.down))
            XCTAssertEqual(window.count, taps)
            XCTAssertTrue(window[0..<fadeStart].allSatisfy { $0 == 1 }, "\(taps)")
            XCTAssertEqual(window[fadeStart], 1, accuracy: 1e-15)
            XCTAssertEqual(window[taps - 1], 0, accuracy: 1e-15)
            for index in fadeStart..<(taps - 1) {
                XCTAssertGreaterThanOrEqual(window[index], window[index + 1], "\(taps) @\(index)")
            }
        }
        XCTAssertEqual(FIRDesign.createWindow(taps: 1, minimumPhase: true), [1])
        XCTAssertEqual(FIRDesign.createWindow(taps: 0, minimumPhase: true), [])
    }

    /// 線形位相は前後5%ずつを落とす。真ん中は1、端は0から上がり、前後は対称
    /// （w[i] == w[taps - i]。JSの式どおり、添字0は0で終わりの添字は0にならない）。
    func testCreateWindowLinPhaseFades5PctEachEdge() {
        for taps in [100, 1000, 8192] {
            let window = FIRDesign.createWindow(taps: taps, minimumPhase: false)
            let edge = Double(taps) * 0.05
            XCTAssertEqual(window.count, taps)
            XCTAssertEqual(window[0], 0)
            for index in 0..<taps {
                let position = Double(index)
                if position >= edge && position <= Double(taps) - edge {
                    XCTAssertEqual(window[index], 1, "\(taps) @\(index)")
                } else {
                    XCTAssertLessThan(window[index], 1, "\(taps) @\(index)")
                }
            }
            for index in 1..<Int(edge.rounded(.up)) {
                XCTAssertEqual(window[index], window[taps - index], accuracy: 1e-15, "\(taps) @\(index)")
            }
        }
        XCTAssertEqual(FIRDesign.createWindow(taps: 0, minimumPhase: false), [])
        XCTAssertEqual(FIRDesign.createWindow(taps: 1, minimumPhase: false), [0])
    }

    /// fir-crossoverとfive-band-fir-peqのcreateWindow（2本とも同じ答え）と一致する。
    func testCreateWindowMatchesUpstream() throws {
        let cases = try golden().windows
        XCTAssertGreaterThanOrEqual(cases.count, 20)
        for c in cases {
            let want = try Self.doubles(c.window)
            let got = FIRDesign.createWindow(taps: c.taps, minimumPhase: c.minimumPhase)
            XCTAssertEqual(got.count, want.count, "\(c.taps) \(c.minimumPhase)")
            XCTAssertLessThanOrEqual(Self.maxDifference(got, want), 1e-15, "\(c.taps) \(c.minimumPhase)")
        }
    }

    // MARK: - dBと周波数軸

    func testLogFrequencies() {
        XCTAssertEqual(FIRDesign.logFrequencies(low: 20, high: 20000, count: 0), [])
        XCTAssertEqual(FIRDesign.logFrequencies(low: 20, high: 20000, count: 1), [20])
        XCTAssertEqual(FIRDesign.logFrequencies(low: 0, high: 20000, count: 8), [])
        XCTAssertEqual(FIRDesign.logFrequencies(low: 20, high: -1, count: 8), [])
        let grid = FIRDesign.logFrequencies(low: 10, high: 40000, count: 512)
        XCTAssertEqual(grid.count, 512)
        XCTAssertEqual(grid[0], 10)
        XCTAssertEqual(grid[511], 40000, accuracy: 40000 * 1e-12)
        let ratio = grid[1] / grid[0]
        for index in 1..<grid.count {
            XCTAssertEqual(grid[index] / grid[index - 1], ratio, accuracy: 1e-9)
        }
        let decade = FIRDesign.logFrequencies(low: 1, high: 1000, count: 4)
        for (got, want) in zip(decade, [1.0, 10, 100, 1000]) {
            XCTAssertEqual(got, want, accuracy: want * 1e-12)
        }
    }

    /// 0や負で落ちないように床を敷く。床は設計ごとに違うので呼ぶ側が決める（既定は1e-8と1e-12）。
    func testDecibelFloors() {
        XCTAssertEqual(FIRDesign.decibels(fromGain: 0), -160, accuracy: 1e-12)
        XCTAssertEqual(FIRDesign.decibels(fromGain: -3), -160, accuracy: 1e-12)
        XCTAssertEqual(FIRDesign.decibels(fromGain: .nan), -160, accuracy: 1e-12)
        XCTAssertEqual(FIRDesign.decibels(fromGain: 0, floor: 1e-12), -240, accuracy: 1e-12)
        XCTAssertEqual(FIRDesign.decibels(fromGain: 10), 20, accuracy: 1e-12)
        XCTAssertEqual(FIRDesign.decibels(fromPower: 0), -120, accuracy: 1e-12)
        XCTAssertEqual(FIRDesign.decibels(fromPower: 100), 20, accuracy: 1e-12)
        XCTAssertEqual(FIRDesign.decibels(fromPower: 0, floor: 1e-8), -80, accuracy: 1e-12)
        XCTAssertEqual(FIRDesign.gain(fromDecibels: 20), 10, accuracy: 1e-12)
        XCTAssertEqual(FIRDesign.gain(fromDecibels: -6), 0.5011872336272722, accuracy: 1e-15)
        XCTAssertEqual(FIRDesign.amplitude(fromDecibels: 40), 10, accuracy: 1e-12)
        XCTAssertEqual(FIRDesign.amplitude(fromDecibels: 6), FIRDesign.gain(fromDecibels: 3), accuracy: 1e-15)
    }

    // MARK: - 最小位相

    /// minimumPhaseForMagnitude（fir-crossover・five-band-fir-peq・room-eqの3本とも同じ答え）と一致する。
    /// 上流のFFTはFloat32の回転因子なので、位相で1e-5ラジアンまでの差は見込む
    /// （Linuxの代役で測った差は最大1.4e-6。床に当たるbinの多い形がいちばん大きい）。
    func testMinimumPhaseMatchesUpstream() throws {
        let cases = try golden().minimumPhase
        XCTAssertGreaterThanOrEqual(cases.count, 6)
        var report = [String]()
        for c in cases {
            let magnitudes = try Self.doubles(c.magnitudes)
            let want = try Self.doubles(c.phase)
            let got = FIRDesign.minimumPhase(magnitudes: magnitudes, fftSize: c.fftSize)
            XCTAssertEqual(got.count, c.fftSize / 2 + 1, c.name)
            XCTAssertEqual(want.count, got.count, c.name)
            let worst = Self.maxDifference(got, want)
            report.append("\(c.name) \(worst)")
            XCTAssertLessThanOrEqual(worst, 1e-5, c.name)
            // 渡したFFTを使っても同じ。
            let fft = try XCTUnwrap(FIRDesign.fft(size: c.fftSize))
            XCTAssertEqual(FIRDesign.minimumPhase(magnitudes: magnitudes, fftSize: c.fftSize, fft: fft), got, c.name)
        }
        print("FIRDesign minimumPhase vs upstream: " + report.joined(separator: ", "))
    }

    /// 平らな振幅の最小位相は0。床より小さい値とNaNは床として扱う。大きさが合わなければ0を並べる。
    /// NaNを床にするのはfive-band-fir-peqと同じ。fir-crossoverとroom-eqは振幅1として扱うので、
    /// 上流の見本（NaNを入れていない）ではこの違いは見えない。
    func testMinimumPhaseEdges() throws {
        let flat = FIRDesign.minimumPhase(magnitudes: [Double](repeating: 1, count: 33), fftSize: 64)
        XCTAssertEqual(flat.count, 33)
        XCTAssertLessThanOrEqual(flat.map(abs).max() ?? 1, 1e-12)
        var withNaN = (0...16).map { 0.5 + Double($0) / 16 }
        var floored = withNaN
        withNaN[3] = .nan
        withNaN[5] = 0
        floored[3] = 1e-8
        floored[5] = 1e-8
        XCTAssertEqual(FIRDesign.minimumPhase(magnitudes: withNaN, fftSize: 32),
                       FIRDesign.minimumPhase(magnitudes: floored, fftSize: 32))
        // 後ろに余った値は見ない。
        XCTAssertEqual(FIRDesign.minimumPhase(magnitudes: floored + [100, 200], fftSize: 32),
                       FIRDesign.minimumPhase(magnitudes: floored, fftSize: 32))
        XCTAssertEqual(FIRDesign.minimumPhase(magnitudes: floored, fftSize: 48), [Double](repeating: 0, count: 25))
        // 違う大きさのFFTを渡されたら使わない。
        let wrong = try XCTUnwrap(FIRDesign.fft(size: 16))
        XCTAssertEqual(FIRDesign.minimumPhase(magnitudes: floored, fftSize: 32, fft: wrong),
                       [Double](repeating: 0, count: 17))
    }

    // MARK: - 出来た係数を測る

    /// group-delay-eqのmeasureResponseと同じ数になる。bin ごとの振幅と群遅延をここで出し、
    /// 格子への読み替えと暴れの数え方（group-delay-eqは格子の全部を数える）はテストの中で組む。
    /// 見本はdesignGroupDelayFilterの答え（係数・realizedMs・rippleDb）。FFTの差を見込んで
    /// 群遅延は1e-5ms、暴れは1e-5dBまで（Linuxの代役で測った差は2e-7msと4e-7dB）。
    func testMeasureResponseMatchesUpstream() throws {
        let cases = try golden().measureResponse
        XCTAssertEqual(cases.count, 2)
        var report = [String]()
        for c in cases {
            let ir = try Self.floats(c.ir)
            let frequencies = try Self.doubles(c.frequencies)
            let wantMs = try Self.doubles(c.realizedMs)
            let bins = try XCTUnwrap(FIRDesign.measureResponse(ir: ir, size: c.size,
                                                               fallbackDelay: c.bulkDelaySamples))
            XCTAssertEqual(bins.magnitudeDb.count, c.size / 2 + 1)
            XCTAssertEqual(bins.delaySamples.count, c.size / 2 + 1)
            var ripple = 0.0
            var worstMs = 0.0
            for (point, frequency) in frequencies.enumerated() {
                let delay = FIRDesign.sampleAtFrequency(bins.delaySamples, frequency: frequency,
                                                        size: c.size, sampleRate: c.sampleRate)
                let realized = (delay - c.bulkDelaySamples) * 1000 / c.sampleRate
                worstMs = max(worstMs, abs(realized - wantMs[point]))
                let deviation = FIRDesign.sampleAtFrequency(bins.magnitudeDb, frequency: frequency,
                                                            size: c.size, sampleRate: c.sampleRate)
                ripple = max(ripple, abs(deviation))
            }
            report.append("\(c.name) ms \(worstMs) ripple \(ripple) vs \(c.rippleDb)")
            XCTAssertLessThanOrEqual(worstMs, 1e-5, c.name)
            XCTAssertEqual(ripple, c.rippleDb, accuracy: 1e-5, c.name)
        }
        print("FIRDesign measureResponse vs upstream: " + report.joined(separator: ", "))
    }

    /// 無音の係数は全binが床（-120dB）で、遅延は代わりの値。大きさが2の冪でなければnil。
    func testMeasureResponseSilentAndBadSize() throws {
        let silent = try XCTUnwrap(FIRDesign.measureResponse(ir: [0, 0, 0, 0], size: 16, fallbackDelay: 3.5))
        XCTAssertEqual(silent.magnitudeDb, [Double](repeating: -120, count: 9))
        XCTAssertEqual(silent.delaySamples, [Double](repeating: 3.5, count: 9))
        // 単位インパルスをdサンプル遅らせると、どのbinも0dB・群遅延d。
        var impulse = [Float](repeating: 0, count: 32)
        impulse[5] = 1
        let delayed = try XCTUnwrap(FIRDesign.measureResponse(ir: impulse, size: 64, fallbackDelay: 0))
        XCTAssertLessThanOrEqual(delayed.magnitudeDb.map(abs).max() ?? 1, 1e-9)
        XCTAssertLessThanOrEqual(delayed.delaySamples.map { abs($0 - 5) }.max() ?? 1, 1e-9)
        // sizeより長い係数は先頭size個だけを見る。
        XCTAssertEqual(FIRDesign.measureResponse(ir: impulse + [1, 1, 1], size: 32, fallbackDelay: 0),
                       FIRDesign.measureResponse(ir: impulse, size: 32, fallbackDelay: 0))
        XCTAssertNil(FIRDesign.measureResponse(ir: impulse, size: 48, fallbackDelay: 0))
    }

    /// five-band-fir-peqとgroup-delay-eqのsampleAtFrequency（2本とも同じ答え）と一致する。
    /// 上流と違う端（負の位置・空）は、落ちずに先頭の値・0を返すことを留める。
    func testSampleAtFrequencyMatchesUpstream() throws {
        let s = try golden().sampleAtFrequency
        XCTAssertGreaterThanOrEqual(s.queries.count, 10)
        for query in s.queries {
            let got = FIRDesign.sampleAtFrequency(s.values, frequency: query[0], size: s.fftSize,
                                                  sampleRate: s.sampleRate)
            XCTAssertEqual(got, query[1], accuracy: 1e-12, "\(query[0])Hz")
        }
        XCTAssertEqual(FIRDesign.sampleAtFrequency(s.values, frequency: -100, size: s.fftSize,
                                                   sampleRate: s.sampleRate), s.values[0])
        XCTAssertEqual(FIRDesign.sampleAtFrequency(s.values, frequency: -.infinity, size: s.fftSize,
                                                   sampleRate: s.sampleRate), s.values[0])
        XCTAssertEqual(FIRDesign.sampleAtFrequency(s.values, frequency: .infinity, size: s.fftSize,
                                                   sampleRate: s.sampleRate), s.values.last)
        XCTAssertTrue(FIRDesign.sampleAtFrequency(s.values, frequency: .nan, size: s.fftSize,
                                                  sampleRate: s.sampleRate).isNaN)
        XCTAssertEqual(FIRDesign.sampleAtFrequency([], frequency: 100, size: 32, sampleRate: 48000), 0)
        XCTAssertEqual(FIRDesign.sampleAtFrequency([7], frequency: 0, size: 32, sampleRate: 48000), 7)
    }

    /// JSのTypedArray.fill(0, start)と同じ（負のstartは後ろから数える）。
    func testZeroTailMatchesTypedArrayFill() throws {
        let z = try golden().zeroTail
        XCTAssertGreaterThanOrEqual(z.starts.count, 8)
        for row in z.starts {
            var values = z.source
            FIRDesign.zeroTail(&values, from: row.start)
            XCTAssertEqual(values, row.expected, "start \(row.start)")
        }
        var empty = [Double]()
        FIRDesign.zeroTail(&empty, from: -1)
        XCTAssertEqual(empty, [])
    }

    // MARK: - Math.round

    /// JSのMath.roundと同じ。半分は+∞の側、-0.5〜0は-0、floor(x+0.5)がずれる値
    /// （0.49999999999999994、2^52付近）もずれない。見本はnodeのMath.roundそのもの。
    func testJsRoundHalves() throws {
        let rows = try golden().jsRound
        XCTAssertGreaterThanOrEqual(rows.count, 20)
        for row in rows {
            let got = FIRDesign.jsRound(row.input)
            XCTAssertEqual(got, row.expected, "Math.round(\(row.input))")
            XCTAssertEqual(got.sign, row.expected.sign, "Math.round(\(row.input)) の符号")
        }
        XCTAssertEqual(FIRDesign.jsRound(2.5), 3)
        XCTAssertEqual(FIRDesign.jsRound(-2.5), -2)
        XCTAssertEqual(FIRDesign.jsRound(0.49999999999999994), 0)
        XCTAssertEqual((0.49999999999999994 + 0.5).rounded(.down), 1, "floor(x+0.5)ならずれる値")
        XCTAssertTrue(FIRDesign.jsRound(.nan).isNaN)
        XCTAssertEqual(FIRDesign.jsRound(.infinity), .infinity)
        XCTAssertEqual(FIRDesign.jsRound(-.infinity), -.infinity)
    }

    // MARK: - リサンプラ

    /// **resample.jsのresampleWindowedSincと同じ標本。**上げ・下げ・整数倍・端（短い入力、
    /// 1標本）・radiusの明示（crosstalk-cancellationの形）。FFTを通らないので、float32の丸め1〜2つぶん
    /// （相対2e-7）まで。Linuxではビットまで一致した（sinのulpの違いがあるMacのための余裕）。
    func testResampleMatchesUpstream() throws {
        let cases = try golden().resample
        XCTAssertGreaterThanOrEqual(cases.count, 10)
        var report = [String]()
        for c in cases {
            let input = try Self.floats(c.input)
            let want = try Self.floats(c.output)
            let got = FIRDesign.resampleWindowedSinc(input, sourceRate: c.sourceRate, targetRate: c.targetRate,
                                                     radius: c.radius)
            XCTAssertEqual(got.count, want.count, c.name)
            var worst = 0.0
            for (a, b) in zip(got, want) {
                worst = max(worst, abs(Double(a) - Double(b)) / max(1, abs(Double(b))))
            }
            report.append("\(c.name) \(worst)")
            XCTAssertLessThanOrEqual(worst, 2e-7, c.name)
        }
        print("FIRDesign resample vs upstream: " + report.joined(separator: ", "))
    }

    /// 同じレートは入力のまま。レート・radius・βが正しくなければ入力のまま（上流は投げる）。
    /// 空の入力は1標本の0（上流と同じ長さの式 max(1, round(...))）。
    func testResampleEdges() {
        let input: [Float] = [0.5, -0.25, 1, 0]
        XCTAssertEqual(FIRDesign.resampleWindowedSinc(input, sourceRate: 48000, targetRate: 48000), input)
        XCTAssertEqual(FIRDesign.resampleWindowedSinc(input, sourceRate: 0, targetRate: 48000), input)
        XCTAssertEqual(FIRDesign.resampleWindowedSinc(input, sourceRate: 48000, targetRate: -1), input)
        XCTAssertEqual(FIRDesign.resampleWindowedSinc(input, sourceRate: 44100, targetRate: 48000, radius: 0), input)
        XCTAssertEqual(FIRDesign.resampleWindowedSinc(input, sourceRate: 44100, targetRate: 48000, beta: -1), input)
        XCTAssertEqual(FIRDesign.resampleWindowedSinc(input, sourceRate: 44100, targetRate: 48000, beta: .nan), input)
        XCTAssertEqual(FIRDesign.resampleWindowedSinc([], sourceRate: 44100, targetRate: 48000), [0])
        // 長さは Math.round(n·target/source)。
        XCTAssertEqual(FIRDesign.resampleWindowedSinc([Float](repeating: 0, count: 441), sourceRate: 44100,
                                                      targetRate: 48000).count, 480)
        XCTAssertEqual(FIRDesign.resampleWindowedSinc([Float](repeating: 0, count: 3), sourceRate: 96000,
                                                      targetRate: 48000).count, 2)
    }

    /// 1つの位相の係数は和が1（直流をそのまま通す）で、個数は2·radius。
    func testResamplePhaseCoefficientsSumToOne() {
        let beta = 0.1102 * (100 - 8.7)
        let normalizer = FIRDesign.besselI0(beta)
        for fraction in [0.0, 0.25, 0.5, 0.9] {
            let coefficients = FIRDesign.resamplePhaseCoefficients(fraction: fraction, cutoff: 0.95 * 44100 / 48000,
                                                                   radius: 30, beta: beta, normalizer: normalizer)
            XCTAssertEqual(coefficients.count, 60)
            XCTAssertEqual(coefficients.reduce(0, +), 1, accuracy: 1e-12, "\(fraction)")
        }
        XCTAssertEqual(FIRDesign.sinc(0), 1)
        XCTAssertEqual(FIRDesign.sinc(1), 0, accuracy: 1e-15)
        XCTAssertEqual(FIRDesign.sinc(0.5), 2 / Double.pi, accuracy: 1e-15)
        XCTAssertEqual(FIRDesign.greatestCommonDivisor(44100, 48000), 300)
        XCTAssertEqual(FIRDesign.greatestCommonDivisor(192000, 44100), 300)
        XCTAssertEqual(FIRDesign.greatestCommonDivisor(7, 13), 1)
    }
}
