//  NCSModelTests.swift
//  NCS の要素の音の写し（ETNCSAudio）・描く大きさ（ETNCSGeometry）・アートワークの色（ETNCSTint）。
//  期待値は本人の ncs_gl.py の _Audio を .venv（float32）で動かして取った数。
//
//  壊れると: NCS の球が元の GLava の移植とずれて音に動かない・動きすぎる、描く大きさが端末で破綻する、
//  何時間も回すと動きが荒くなる、取得中の粒の色が白に飛ぶ。

import XCTest

final class NCSModelTests: XCTestCase {

    func testMixMatchesNcsGl() {
        XCTAssertEqual(ETNCSAudio.mix([0.9, 0.1, 0.5, 0.3, 0.7, 0.2, 0.8, 0.4]), 5.496973100673527, accuracy: 1e-5)
        XCTAssertEqual(ETNCSAudio.mix([Float](repeating: 1, count: 8)), 9.0, accuracy: 1e-5)
        XCTAssertEqual(ETNCSAudio.mix([Float](repeating: 0, count: 8)), 0.0, accuracy: 1e-5)
        XCTAssertEqual(ETNCSAudio.mix([0.25, 0.6, 0.05, 0.95, 0.4, 0.75, 0.15, 0.5]), 5.336572308017457, accuracy: 1e-5)
    }

    func testUpdateMatchesNcsGlWithBands() {
        var audio = ETNCSAudio()
        let raw1 = (0..<96).map { 0.01 * Float(($0 % 7) + 1) }
        let raw2 = (0..<96).map { 0.02 * Float(($0 * 5) % 11) / 10 }
        let zeros = [Float](repeating: 0, count: 96)
        let r1 = audio.update(bands: raw1, gain: 1, dt: 1.0 / 60)
        XCTAssertEqual(r1.drive, 1.6646102666854858, accuracy: 1e-4)
        XCTAssertEqual(r1.audioRadius, 0.32999998331069946, accuracy: 1e-4)
        let r2 = audio.update(bands: raw2, gain: 1, dt: 1.0 / 60)
        XCTAssertEqual(r2.drive, 1.6629456564188003, accuracy: 1e-4)
        XCTAssertEqual(r2.audioRadius, 0.30361318588256836, accuracy: 1e-4)
        let r3 = audio.update(bands: zeros, gain: 1, dt: 1.0 / 60)
        XCTAssertEqual(r3.drive, 1.6612827107623815, accuracy: 1e-4)
        XCTAssertEqual(r3.audioRadius, 0.26717960834503174, accuracy: 1e-4)
    }

    func testFullPathMatchesNcsGl() {
        let rate = 48_000.0
        let window: [Float] = (0..<ETNCSAudio.fftSize).map {
            let t = Double($0) / rate
            return Float(0.5 * sin(2 * Double.pi * 100 * t) + 0.2 * sin(2 * Double.pi * 1000 * t))
        }
        let fft = ETRealFFT(size: ETNCSAudio.fftSize)
        let bands = window.withUnsafeBufferPointer { ETNCSAudio.bands($0, sampleRate: rate, fft: fft) }
        XCTAssertEqual(bands.count, 96)
        var audio = ETNCSAudio()
        let r = audio.update(bands: bands, gain: 1, dt: 1.0 / 60)
        XCTAssertEqual(r.drive, 0.2937246263027191, accuracy: 1e-3)
        XCTAssertEqual(r.audioRadius, 0.37671399116516113, accuracy: 1e-3)
    }

    func testCentersMatchLogspace() {
        XCTAssertEqual(ETNCSAudio.centers.count, 96)
        XCTAssertEqual(ETNCSAudio.centers[0], 30.99733615489634, accuracy: 1e-9)
        XCTAssertEqual(ETNCSAudio.centers[47], 670.5288992242449, accuracy: 1e-9)
        XCTAssertEqual(ETNCSAudio.centers[95], 15485.201618661653, accuracy: 1e-9)
    }

    func testDtScaling() {
        let raw = (0..<96).map { 0.02 * Float(($0 * 3) % 13) }
        var one = ETNCSAudio(), two = ETNCSAudio()
        // 同じ入力を 1/60 秒で 2 回と、2/60 秒で 1 回
        _ = two.update(bands: raw, gain: 1, dt: 1.0 / 60)
        let b = two.update(bands: raw, gain: 1, dt: 1.0 / 60)
        let a = one.update(bands: raw, gain: 1, dt: 2.0 / 60)
        XCTAssertEqual(a.drive, b.drive, accuracy: 1e-5)
        XCTAssertEqual(a.audioRadius, b.audioRadius, accuracy: 1e-5)
        for i in 0..<96 { XCTAssertEqual(one.spec[i], two.spec[i], accuracy: 1e-5) }
    }

    func testNilBandsKeepSpectrumAndDriveStays() {
        var audio = ETNCSAudio()
        let raw = (0..<96).map { 0.01 * Float(($0 % 7) + 1) }
        let first = audio.update(bands: raw, gain: 1, dt: 1.0 / 60)
        let spec = audio.spec, agc = audio.agc
        let held = audio.update(bands: nil, gain: 1, dt: 1.0 / 60)
        XCTAssertEqual(audio.spec, spec)
        XCTAssertEqual(audio.agc, agc)
        // 帯が同じなら finalAudio も同じ（drive は 0.999 倍より下がらない）
        XCTAssertEqual(held.drive, first.drive, accuracy: 1e-5)
        XCTAssertEqual(held.audioRadius, first.audioRadius, accuracy: 1e-6)
    }

    func testGeometry() {
        let big = ETNCSGeometry.size(contentSide: 1000)
        XCTAssertEqual(big, ETNCSGeometry.Size(renderSide: 760, gridN: 380, spacing: 2, densityScale: 4, scale: Float(760.0 / 1080)))
        let small = ETNCSGeometry.size(contentSide: 100)
        XCTAssertEqual(small, ETNCSGeometry.Size(renderSide: 256, gridN: 256, spacing: 1, densityScale: 1, scale: Float(256.0 / 1080)))
        XCTAssertNil(ETNCSGeometry.size(contentSide: 10))
        XCTAssertNil(ETNCSGeometry.size(contentSide: .nan))
        XCTAssertNil(ETNCSGeometry.size(contentSide: .infinity))
        let mid = ETNCSGeometry.size(contentSide: 500)
        XCTAssertEqual(mid?.renderSide, 500)
        XCTAssertEqual(mid?.gridN, 380)
        XCTAssertEqual(mid?.densityScale ?? 0, Float((500.0 / 380) * (500.0 / 380)), accuracy: 1e-5)
        // 粒の数は 380² を越えない
        for side in stride(from: 24.0, through: 4000, by: 37) {
            if let s = ETNCSGeometry.size(contentSide: side) { XCTAssertLessThanOrEqual(s.gridN * s.gridN, 144_400) }
        }
    }

    func testFlowOffsetsWrap() {
        // T = 10000: y = fmod(0.033·10000, 289) = fmod(330, 289) = 41、e = fmod(150, 289) = 150
        let (f0, f1, f2) = ETNCSGeometry.flowOffsets(time: 10_000)
        XCTAssertEqual(f0, SIMD4<Float>(0, 41, 0, 150))
        XCTAssertEqual(f1, SIMD4<Float>(41, 0, 0, 150))
        XCTAssertEqual(f2, SIMD4<Float>(0, 0, 41, 150))
        let (z0, _, _) = ETNCSGeometry.flowOffsets(time: 0)
        XCTAssertEqual(z0, SIMD4<Float>(0, 0, 0, 0))
        // 何時間回しても小さい値のまま（Float の桁が減らない）
        let (long, _, _) = ETNCSGeometry.flowOffsets(time: 3600 * 1000)
        XCTAssertLessThan(long.y, 289)
        XCTAssertLessThan(long.w, 289)
    }

    func testTint() {
        var red = [UInt8]()
        for _ in 0..<256 { red += [255, 0, 0, 255] }
        XCTAssertEqual(ETNCSTint.tint(rgba: red, pixelCount: 256)?.hex, "#570000")
        var black = [UInt8]()
        for _ in 0..<256 { black += [0, 0, 0, 255] }
        XCTAssertNil(ETNCSTint.tint(rgba: black, pixelCount: 256))
        XCTAssertNil(ETNCSTint.tint(rgba: [], pixelCount: 0))
        // 白でも飛ばない（最大の成分は 0x57）
        var white = [UInt8]()
        for _ in 0..<256 { white += [255, 255, 255, 255] }
        XCTAssertEqual(ETNCSTint.tint(rgba: white, pixelCount: 256)?.hex, "#575757")
        var state: UInt32 = 7
        for _ in 0..<20 {
            var px = [UInt8]()
            for _ in 0..<(256 * 4) {
                state = state &* 1664525 &+ 1013904223
                px.append(UInt8(truncatingIfNeeded: state >> 16))
            }
            if let c = ETNCSTint.tint(rgba: px, pixelCount: 256) {
                let top = max((c.rgb >> 16) & 0xFF, (c.rgb >> 8) & 0xFF, c.rgb & 0xFF)
                XCTAssertEqual(top, 0x57)
            }
        }
        // 彩度のある画素が重みで勝つ（灰色の中の青）
        var mixed = [UInt8]()
        for i in 0..<256 { mixed += i < 200 ? [128, 128, 128, 255] : [0, 0, 255, 255] }
        let c = ETNCSTint.tint(rgba: mixed, pixelCount: 256)
        XCTAssertNotNil(c)
        XCTAssertGreaterThan(c!.rgb & 0xFF, (c!.rgb >> 16) & 0xFF)
    }
}
