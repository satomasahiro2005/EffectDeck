//  RealFFTTests.swift
//  Swift だけの FFT（RealFFT）。NCS の帯と Skip 検出器の土台。
//
//  壊れると: NCS の帯がずれて球が音に動かない、Skip 検出器の特徴量が狂って曲の替わりを取り違える。

import XCTest

final class RealFFTTests: XCTestCase {

    func testSineAtBinHasTheExpectedPeakAndNoLeakage() {
        let n = 1024
        let fft = ETRealFFT(size: n)
        let amplitude: Float = 0.7
        let x = (0..<n).map { amplitude * Float(sin(2 * Double.pi * 64 * Double($0) / Double(n))) }
        var mag: [Float] = []
        x.withUnsafeBufferPointer { fft.magnitudes($0, window: [], into: &mag) }
        XCTAssertEqual(mag.count, n / 2 + 1)
        let peak = mag[64]
        XCTAssertEqual(peak, Float(n) / 2 * amplitude, accuracy: 1e-2)
        for (k, v) in mag.enumerated() where k != 64 {
            XCTAssertLessThan(v, peak * 1e-3, "bin \(k)")
        }
    }

    func testDCIsNTimesTheValue() {
        let n = 256
        let fft = ETRealFFT(size: n)
        let x = [Float](repeating: 0.25, count: n)
        var mag: [Float] = []
        x.withUnsafeBufferPointer { fft.magnitudes($0, window: [], into: &mag) }
        XCTAssertEqual(mag[0], Float(n) * 0.25, accuracy: 1e-4)
        for k in 1..<mag.count { XCTAssertLessThan(mag[k], 1e-4, "bin \(k)") }
    }

    func testParseval() {
        let n = 1024
        let fft = ETRealFFT(size: n)
        var state: UInt64 = 12345
        let x: [Float] = (0..<n).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: state >> 11) % 2000) / 1000 - 1
        }
        var power: [Float] = []
        x.withUnsafeBufferPointer { fft.power($0, window: [], into: &power) }
        // 実数列の全スペクトル: 0 と N/2 は 1 回、残りは 2 回
        var sum = Double(power[0]) + Double(power[n / 2])
        for k in 1..<(n / 2) { sum += 2 * Double(power[k]) }
        let time = x.reduce(0.0) { $0 + Double($1) * Double($1) }
        XCTAssertEqual(sum / Double(n), time, accuracy: 1e-4 * time)
    }

    func testPowerIsMagnitudeSquaredAndWindowIsApplied() {
        let n = 128
        let fft = ETRealFFT(size: n)
        let x = (0..<n).map { Float(cos(0.3 * Double($0))) }
        let w = (0..<n).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n - 1))) }
        var mag: [Float] = [], power: [Float] = []
        x.withUnsafeBufferPointer {
            fft.magnitudes($0, window: w, into: &mag)
            fft.power($0, window: w, into: &power)
        }
        for k in 0..<mag.count { XCTAssertEqual(power[k], mag[k] * mag[k], accuracy: max(1e-3, 1e-4 * power[k])) }
        // 窓あり・なしで結果が違う
        var plain: [Float] = []
        x.withUnsafeBufferPointer { fft.magnitudes($0, window: [], into: &plain) }
        XCTAssertNotEqual(plain[10], mag[10])
    }

    func testShortInputIsZeroPadded() {
        let fft = ETRealFFT(size: 64)
        let x = [Float](repeating: 1, count: 32)
        var mag: [Float] = []
        x.withUnsafeBufferPointer { fft.magnitudes($0, window: [], into: &mag) }
        XCTAssertEqual(mag[0], 32, accuracy: 1e-4)
    }
}
