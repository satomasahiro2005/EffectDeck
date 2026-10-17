//  VisualizerNCSModel.swift
//  NCS の要素の「音 → 半径と乱れ」「描く大きさ」「アートワークの色」。Foundation だけ
//  （Tests/Unit/NCSModelTests.swift）。描くのは Metal（VisualizerNCS.metal / VisualizerNCS.swift）。
//
//  元は NCS Spectrum（Roonil/NCS_Spectrum_GLava）の GLava の移植、本人の ncs_gl.py。
//  ここにあるのはその _Audio（setAudio の並べ替えの網まで）と、1080 基準の定数を描く大きさに合わせる規則。

import Foundation

enum ETNCSConstants {
    /// ncs_gl.py の render() の color_rgb（0.0118, 0.1412, 0.3412）× 255 = 3, 36, 87。
    static let defaultColor = ETVisualizerColor(0x032457)
    /// ncs_gl.py NCSGLRenderer(speed=2.5)。
    static let elementSpeed = 2.5
    /// ncs.glsl のままの速さ。取得中はゆっくり漂わせる。
    static let identifyingSpeed = 1.0
    /// render(idle=0.7)。無音でも場がゆっくり流れる床。
    static let idle: Float = 0.7
    /// ncs.glsl の flowX = flowZ = 0。
    static let flowY = 0.033, flowEvolution = 0.015
}

// MARK: - 音

/// ncs_gl.py の _Audio。FFT の 96 帯を平滑して、setAudio の並べ替えの網で finalAudio を作る。
struct ETNCSAudio {
    static let bandCount = 96, fftSize = 2048, lowHz = 30.0, highHz = 16_000.0
    /// np.logspace(log10 30, log10 16000, 97) の隣どうしの幾何平均。
    static let centers: [Double] = {
        let a = log10(lowHz), b = log10(highHz)
        let step = (b - a) / Double(bandCount)
        let edges = (0...bandCount).map { pow(10, a + Double($0) * step) }
        return (0..<bandCount).map { (edges[$0] * edges[$0 + 1]).squareRoot() }
    }()
    /// np.hanning(N)（0.5 − 0.5·cos(2πn/(N−1))）。
    static let hann: [Float] = (0..<fftSize).map {
        Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(fftSize - 1)))
    }
    static let attack: Float = 0.6, decay: Float = 0.12, agcRelease: Float = 0.999, agcFloor: Float = 1e-4
    static let fractalMix: Float = 0.5, fractalMultiplier: Float = 9, release: Float = 0.999
    /// ncs_gl.py の setAudio の並べ替えの網（そのまま）。
    private static let network: [(Int, Int)] = [
        (0, 2), (1, 3), (4, 6), (5, 7), (0, 4), (1, 5), (2, 6), (3, 7),
        (0, 1), (2, 3), (4, 5), (6, 7), (2, 4), (3, 5), (1, 4), (3, 6),
        (1, 2), (3, 4), (5, 6),
    ]

    var spec = [Float](repeating: 0, count: 96)
    var agc: Float = 1e-4
    var drive: Float = 0

    /// np.hanning(N) → |rfft|·2/N → np.interp(centers, k·rate/N, mag)。`window` は古い順の 2048 標本。
    static func bands(_ window: UnsafeBufferPointer<Float>, sampleRate: Double, fft: ETRealFFT) -> [Float] {
        var mag = [Float](repeating: 0, count: fftSize / 2 + 1)
        fft.magnitudes(window, window: hann, into: &mag)
        let scale = 2 / Float(fftSize)
        // ncs_gl.py は rate を 8000 以上に丸める
        let df = max(8000, sampleRate) / Double(fftSize)
        var out = [Float](repeating: 0, count: bandCount)
        let last = fftSize / 2
        for (i, c) in centers.enumerated() {
            // np.interp は範囲の外では端の値
            let pos = c / df
            if pos >= Double(last) {
                out[i] = mag[last] * scale
            } else {
                let k = Int(pos)
                let f = Float(pos - Double(k))
                out[i] = (mag[k] + (mag[k + 1] - mag[k]) * f) * scale
            }
        }
        return out
    }

    private static func mix(_ x: Float, _ y: Float, _ t: Float) -> Float { x * (1 - t) + y * t }

    /// ncs_gl.py の setAudio（並べ替えの網はそのまま）。a は 8 個。
    static func mix(_ values: [Float]) -> Float {
        precondition(values.count == 8)
        var a = values
        for (i, j) in network where a[i] > a[j] { a.swapAt(i, j) }
        let inner0 = mix(a[7] * a[6] - a[1] * a[0], a[7] * a[6], a[5])
        let inner1 = mix(a[6] * mix(a[7] - a[0], a[6] - a[3], a[7] * a[6]) - pow(a[1] * a[0], 1.05),
                         a[7] * a[6], a[5] * a[4])
        return fractalMultiplier * mix(inner0, inner1, fractalMix)
    }

    private func sample(_ pos: Float) -> Float {
        let x = Double(min(max(pos, 0), 1)) * Double(Self.bandCount - 1)
        let i = Int(x)
        let f = Float(x - Double(i))
        let a = spec[i], b = spec[min(i + 1, Self.bandCount - 1)]
        return a + (b - a) * f
    }

    /// 1 回進める。bands が nil なら帯は据え置き（AGC と平滑を回さない）。返すのは (drive, audioRadius)。
    /// ncs_gl.py は 60fps で 1 コマずつ進める。dt をコマ数 f に直して、1/60 秒を 2 回と 1/30 秒を 1 回が同じになるようにする。
    mutating func update(bands: [Float]?, gain: Float, dt: Double) -> (drive: Float, audioRadius: Float) {
        let f = Float(min(max(dt.isFinite ? dt : 0, 0), 0.25) * 60)
        if let bands, bands.count == Self.bandCount {
            agc = max(bands.max() ?? 0, agc * pow(Self.agcRelease, f), Self.agcFloor)
            for i in 0..<Self.bandCount {
                let new = min(max(bands[i] / agc * (gain * 1.1), 0), 1)
                let coefficient = new > spec[i] ? Self.attack : Self.decay
                let k = 1 - pow(1 - coefficient, f)
                spec[i] += (new - spec[i]) * k
            }
        }
        let audioRadius = max(sample(0.1), sample(0.15))
        let a = (0..<8).map { k in max(sample(0.2 + 0.1 * Float(k)), sample(0.25 + 0.1 * Float(k))) }
        let final = Self.mix(a)
        drive = max(final, drive * pow(Self.release, f))
        return (drive, audioRadius)
    }
}

// MARK: - 描く大きさ

enum ETNCSGeometry {
    static let minContentSide = 24.0, minRenderSide = 256, maxRenderSide = 760, maxGridSide = 380, referenceHeight = 1080.0

    struct Size: Equatable {
        /// 正方形の辺（画素）。
        let renderSide: Int
        /// 粒の格子の 1 辺。
        let gridN: Int
        /// 粒の間隔（画素）。ncs_gl.py の arange(0.5, res, spacing)。
        let spacing: Float
        /// 間引いた分を戻す係数（spacing²。ncs_gl.py の density_scale）。
        let densityScale: Float
        /// 1080 基準の定数に掛ける（renderSide / 1080）。
        let scale: Float
    }

    /// 要素の内側の辺（画素）から。有限でない・24 未満は nil（描かない）。
    static func size(contentSide: Double) -> Size? {
        guard contentSide.isFinite, contentSide >= minContentSide else { return nil }
        let side = Int(min(max(contentSide, Double(minRenderSide)), Double(maxRenderSide)).rounded())
        let grid = min(side, maxGridSide)
        let spacing = Float(side) / Float(grid)
        return Size(renderSide: side, gridN: grid, spacing: spacing, densityScale: spacing * spacing,
                    scale: Float(Double(side) / referenceHeight))
    }

    /// flow·uTime を 289 で割った余り（Double で計算）。cnoise は mod289(floor(P)) と fract(P) だけで決まるので
    /// 289 を足し引きしても同じ値になり、何時間回しても Float の桁が減らない。
    /// fbm3 の 3 回ぶん: f0 = (0, y, 0, e)、f1 = (y, 0, 0, e)、f2 = (0, 0, y, e)。y = fmod(flowY·T, 289)、e = fmod(flowEvolution·T, 289)。
    static func flowOffsets(time: Double) -> (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) {
        func wrap(_ v: Double) -> Float {
            guard v.isFinite else { return 0 }
            var r = v.truncatingRemainder(dividingBy: 289)
            if r < 0 { r += 289 }
            return Float(r)
        }
        let y = wrap(ETNCSConstants.flowY * time), e = wrap(ETNCSConstants.flowEvolution * time)
        return (SIMD4(0, y, 0, e), SIMD4(y, 0, 0, e), SIMD4(0, 0, y, e))
    }
}

// MARK: - アートワークの色

enum ETNCSTint {
    /// 16×16 の RGBA8 から、取得中の粒の色を作る。彩度 × 明るさで重みを付けた平均を、既定の色の明るさに揃える。
    /// 既定の色（0x57 = 87）と同じ明るさにするのは、球の殻が白に飛ばず NCS の色で飽和するように。
    static func tint(rgba: [UInt8], pixelCount: Int) -> ETVisualizerColor? {
        let count = min(pixelCount, rgba.count / 4)
        guard count > 0 else { return nil }
        var sr = 0.0, sg = 0.0, sb = 0.0, total = 0.0
        for i in 0..<count {
            let r = Double(rgba[4 * i]) / 255, g = Double(rgba[4 * i + 1]) / 255, b = Double(rgba[4 * i + 2]) / 255
            let v = max(r, g, b), low = min(r, g, b)
            let s = v > 0 ? (v - low) / v : 0
            let w = s * v + 0.02
            sr += r * w
            sg += g * w
            sb += b * w
            total += w
        }
        guard total > 0 else { return nil }
        let mean = (sr / total, sg / total, sb / total)
        let top = max(mean.0, mean.1, mean.2)
        guard top >= 0.02 else { return nil }
        let k = (Double(0x57) / 255) / top
        func byte(_ v: Double) -> UInt32 { UInt32(min(max((v * k * 255).rounded(), 0), 255)) }
        return ETVisualizerColor((byte(mean.0) << 16) | (byte(mean.1) << 8) | byte(mean.2))
    }
}
