//  FIRDesign.swift
//  FIR 係数を設計する側が共通で使う道具。
//
//  EffeTune は係数の設計を JS でやっている。各 design-core.js が使っている
//  道具のうち、どの設計にも出てくるものをここに集めた。
//  設計そのもの（どんな応答を作るか）は各担当のファイル。
//
//  --- 何を入れて何を入れなかったか ---
//  窓は Vendor/effetune/js/**/design-core.js を全部読んで決めた。
//    - 出てくるのは「持ち上げ余弦」だけ。0.5 - 0.5cos(πx) で立ち上げ、
//      0.5 + 0.5cos(πx) で落とす。6 本の design-core すべてがこれを使う
//    - createWindow（端だけ落とす窓）は fir-crossover:97-115 と
//      five-band-fir-peq:216-234 に同じものが 2 つある。room-eq:225-238 もほぼ同じ
//    - Kaiser は窓関数としてではなく、窓付き sinc のリサンプラで使われている
//      （utils/measurement-dsp/resample.js:36）。crosstalk と room-eq がそれを呼ぶ
//    - **Hamming と Blackman は 1 か所も使われていない。** grep しても出てこない。
//      それでも短いので置いてあるが、JS に対応するものは無い
//
//  --- 数の扱い ---
//  JS の Number は double なので、途中は全部 Double で回して、
//  カーネルへ渡す直前に Float へ落とす（toFloat）。
//
//  --- FFT ---
//  design-core が呼ぶのは realTransform と inverseRealTransform の 2 つだけ。
//  中身は Accelerate の vDSP（Double 版）にした。
//  値の約束は js/utils/measurement-dsp/fft.js:136-189 に合わせてある:
//    - realTransform は正規化なしの前進 DFT。長さ N を入れて N/2+1 個を返す
//    - inverseRealTransform は 1/N を掛けた逆変換の実部だけを返す。
//      JS も戻り値は実部だけなので、imag[0] と imag[N/2] は結果に効かない
//      （その 2 つは出力の虚部にしか寄与しない）。vDSP の詰め方と同じになる

import Accelerate
import Foundation

enum FIRDesign {

    // MARK: - 窓

    /// Hann（対称）。w[i] = 0.5 - 0.5cos(2πi/(N-1))
    static func hann(_ count: Int) -> [Double] {
        guard count > 1 else { return [Double](repeating: 1, count: max(count, 0)) }
        let denominator = Double(count - 1)
        return (0..<count).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / denominator) }
    }

    /// Hamming。design-core には出てこない。
    static func hamming(_ count: Int) -> [Double] {
        guard count > 1 else { return [Double](repeating: 1, count: max(count, 0)) }
        let denominator = Double(count - 1)
        return (0..<count).map { 0.54 - 0.46 * cos(2 * Double.pi * Double($0) / denominator) }
    }

    /// Blackman。design-core には出てこない。
    static func blackman(_ count: Int) -> [Double] {
        guard count > 1 else { return [Double](repeating: 1, count: max(count, 0)) }
        let denominator = Double(count - 1)
        return (0..<count).map { index -> Double in
            let phase = 2 * Double.pi * Double(index) / denominator
            return 0.42 - 0.5 * cos(phase) + 0.08 * cos(2 * phase)
        }
    }

    /// Kaiser。beta は減衰量から決める。resample.js:76 は 100dB に対して
    /// 0.1102 * (100 - 8.7) を使っている。
    static func kaiser(_ count: Int, beta: Double) -> [Double] {
        guard count > 1 else { return [Double](repeating: 1, count: max(count, 0)) }
        let normalizer = besselI0(beta)
        let denominator = Double(count - 1)
        return (0..<count).map { index -> Double in
            let position = 2 * Double(index) / denominator - 1
            let inside = 1 - position * position
            return besselI0(beta * (inside > 0 ? inside.squareRoot() : 0)) / normalizer
        }
    }

    /// 第 1 種変形ベッセル関数 I0。
    /// resample.js:5-14 をそのまま移した（20 項で打ち切り、相対 1e-12 で抜ける）。
    static func besselI0(_ value: Double) -> Double {
        var sum = 1.0
        var term = 1.0
        let scaled = value * value / 4
        for index in 1..<20 {
            term *= scaled / Double(index * index)
            sum += term
            if term < sum * 1e-12 { break }
        }
        return sum
    }

    /// 立ち上がり。0.5 - 0.5cos(πx)。x は 0〜1。
    static func raisedCosineRise(_ position: Double) -> Double {
        0.5 - 0.5 * cos(Double.pi * min(max(position, 0), 1))
    }

    /// 立ち下がり。0.5 + 0.5cos(πx)。x は 0〜1。
    static func raisedCosineFall(_ position: Double) -> Double {
        0.5 + 0.5 * cos(Double.pi * min(max(position, 0), 1))
    }

    /// FIR の端だけを落とす窓。
    /// fir-crossover/design-core.js:97-115 と five-band-fir-peq/design-core.js:216-234
    /// に同じものが 2 つあり、どちらも中身は一致している。
    ///
    /// - Parameter minimumPhase: 最小位相なら後ろ 1 割だけを落とす。
    ///   線形位相なら前後 5% ずつを落とす。
    static func createWindow(taps: Int, minimumPhase: Bool) -> [Double] {
        guard taps > 0 else { return [] }
        var window = [Double](repeating: 1, count: taps)

        if minimumPhase {
            let fadeStart = Int((Double(taps) * 0.9).rounded(.down))
            let fadeLength = taps - fadeStart - 1
            let denominator = Double(fadeLength > 1 ? fadeLength : 1)
            var index = fadeStart
            while index < taps {
                let fraction = Double(index - fadeStart) / denominator
                window[index] = 0.5 + 0.5 * cos(Double.pi * fraction)
                index += 1
            }
            return window
        }

        let edge = Double(taps) * 0.05
        guard edge > 0 else { return window }
        for index in 0..<taps {
            let position = Double(index)
            if position < edge {
                window[index] = 0.5 - 0.5 * cos(Double.pi * position / edge)
            } else if position > Double(taps) - edge {
                window[index] = 0.5 - 0.5 * cos(Double.pi * (Double(taps) - position) / edge)
            }
        }
        return window
    }

    // MARK: - FFT

    /// 実数の FFT。js/utils/measurement-dsp/fft.js と同じ約束で答えを返す。
    ///
    /// setup は作り直すと高いので、使い回す。中身は読むだけなので
    /// 1 つの RealFFT を複数のスレッドから同時に使ってよい
    /// （毎回の作業用の配列は呼び出しごとに取っている）。
    final class RealFFT {
        // kFFTDirection_Inverse は -1。FFTDirection の符号に関わらず同じ
        // ビットの並びになるように truncatingIfNeeded で作る。
        private static let forward = FFTDirection(truncatingIfNeeded: kFFTDirection_Forward)
        private static let inverse = FFTDirection(truncatingIfNeeded: kFFTDirection_Inverse)

        let size: Int
        private let log2n: vDSP_Length
        private let setup: FFTSetupD

        /// size は 4 以上の 2 の冪。
        init?(size: Int) {
            guard size >= 4, (size & (size - 1)) == 0 else { return nil }
            let bits = vDSP_Length(size.trailingZeroBitCount)
            guard let created = vDSP_create_fftsetupD(bits, FFTRadix(kFFTRadix2)) else { return nil }
            self.size = size
            self.log2n = bits
            self.setup = created
        }

        deinit {
            vDSP_destroy_fftsetupD(setup)
        }

        /// 前進。正規化していない DFT で、返すのは 0〜N/2 の N/2+1 個。
        /// 入力が短ければ 0 で埋め、長ければ先頭 N 個だけを見る（JS と同じ）。
        func realTransform(_ input: [Double]) -> (real: [Double], imag: [Double]) {
            let half = size / 2
            var padded = [Double](repeating: 0, count: size)
            let copyCount = min(input.count, size)
            if copyCount > 0 {
                for index in 0..<copyCount { padded[index] = input[index] }
            }

            var realPart = [Double](repeating: 0, count: half)
            var imagPart = [Double](repeating: 0, count: half)

            realPart.withUnsafeMutableBufferPointer { realBuffer in
                imagPart.withUnsafeMutableBufferPointer { imagBuffer in
                    var split = DSPDoubleSplitComplex(realp: realBuffer.baseAddress!,
                                                      imagp: imagBuffer.baseAddress!)
                    padded.withUnsafeBufferPointer { source in
                        source.baseAddress!.withMemoryRebound(to: DSPDoubleComplex.self,
                                                              capacity: half) { interleaved in
                            vDSP_ctozD(interleaved, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zripD(setup, &split, 1, log2n, RealFFT.forward)
                }
            }

            // vDSP は数学どおりの値の 2 倍を返し、DC を realp[0]、Nyquist を imagp[0] に詰める。
            var real = [Double](repeating: 0, count: half + 1)
            var imag = [Double](repeating: 0, count: half + 1)
            real[0] = realPart[0] * 0.5
            real[half] = imagPart[0] * 0.5
            if half > 1 {
                for bin in 1..<half {
                    real[bin] = realPart[bin] * 0.5
                    imag[bin] = imagPart[bin] * 0.5
                }
            }
            return (real, imag)
        }

        /// 逆変換。長さ N の実部だけを返す。
        /// real / imag は 0〜N/2 の N/2+1 個（足りなければ 0 とみなす）。
        func inverseRealTransform(real: [Double], imag: [Double]) -> [Double] {
            let half = size / 2
            var realPart = [Double](repeating: 0, count: half)
            var imagPart = [Double](repeating: 0, count: half)

            // DC と Nyquist は vDSP の詰め方に合わせて realp[0] / imagp[0] へ。
            // 虚部は実部だけの出力に効かないので落としてよい。
            realPart[0] = element(real, 0)
            imagPart[0] = element(real, half)
            if half > 1 {
                for bin in 1..<half {
                    realPart[bin] = element(real, bin)
                    imagPart[bin] = element(imag, bin)
                }
            }

            var output = [Double](repeating: 0, count: size)
            realPart.withUnsafeMutableBufferPointer { realBuffer in
                imagPart.withUnsafeMutableBufferPointer { imagBuffer in
                    var split = DSPDoubleSplitComplex(realp: realBuffer.baseAddress!,
                                                      imagp: imagBuffer.baseAddress!)
                    vDSP_fft_zripD(setup, &split, 1, log2n, RealFFT.inverse)
                    output.withUnsafeMutableBufferPointer { destination in
                        destination.baseAddress!.withMemoryRebound(to: DSPDoubleComplex.self,
                                                                    capacity: half) { interleaved in
                            vDSP_ztocD(&split, 1, interleaved, 2, vDSP_Length(half))
                        }
                    }
                }
            }

            // 数学どおりの値を入れているので、戻すのは 1/N だけでよい
            // （vDSP の前進が 2 倍、往復が 2N 倍になる分を相殺した後の数）。
            let scale = 1 / Double(size)
            for index in 0..<size { output[index] *= scale }
            return output
        }

        private func element(_ values: [Double], _ index: Int) -> Double {
            index >= 0 && index < values.count ? values[index] : 0
        }
    }

    /// 大きさごとに 1 つだけ作って使い回す。fft.js の planCache と同じ役目。
    private static let fftCacheLock = NSLock()
    private static var fftCache = [Int: RealFFT]()

    static func fft(size: Int) -> RealFFT? {
        fftCacheLock.lock()
        defer { fftCacheLock.unlock() }
        if let cached = fftCache[size] { return cached }
        guard let created = RealFFT(size: size) else { return nil }
        fftCache[size] = created
        return created
    }

    /// 2 の冪へ切り上げる。
    static func nextPowerOfTwo(_ value: Int) -> Int {
        var result = 1
        while result < value { result *= 2 }
        return result
    }

    // MARK: - dB と線形

    /// dB から振幅へ。10^(dB/20)
    static func gain(fromDecibels decibels: Double) -> Double {
        pow(10, decibels / 20)
    }

    /// ピークやシェルフの係数に使う半分の指数。10^(dB/40)
    /// five-band-fir-peq/design-core.js:81 と room-eq/design-core.js:595 がこれ。
    static func amplitude(fromDecibels decibels: Double) -> Double {
        pow(10, decibels / 40)
    }

    /// 振幅から dB へ。0 で落ちないように床を敷く。
    /// 床の値は design-core ごとに違う（fir-crossover・five-band-fir-peq・room-eq は 1e-8、
    /// crosstalk-cancellation と group-delay 系は 1e-12）ので、移す側で指定する。
    static func decibels(fromGain gain: Double, floor: Double = 1e-8) -> Double {
        20 * log10(gain > floor ? gain : floor)
    }

    /// 電力から dB へ。group-delay-eq/design-core.js:238 と同じ形。
    static func decibels(fromPower power: Double, floor: Double = 1e-12) -> Double {
        10 * log10(power > floor ? power : floor)
    }

    // MARK: - 対数の周波数軸

    /// 対数で等間隔に並べた周波数。
    /// five-band-fir-peq/design-core.js:242-245、group-delay-eq:116-119、
    /// group-delay-peq:212-215 が同じ形で書いている。
    static func logFrequencies(low: Double, high: Double, count: Int) -> [Double] {
        guard count > 0, low > 0, high > 0 else { return [] }
        if count == 1 { return [low] }
        let step = log10(high / low) / Double(count - 1)
        return (0..<count).map { low * pow(10, step * Double($0)) }
    }

    /// オクターブ数。log2(high/low)。
    static func octaves(from low: Double, to high: Double) -> Double {
        guard low > 0, high > 0 else { return 0 }
        return log2(high / low)
    }

    /// FFT の bin の中心周波数。
    static func binFrequencies(fftSize: Int, sampleRate: Double) -> [Double] {
        guard fftSize > 0 else { return [] }
        let half = fftSize / 2
        let step = sampleRate / Double(fftSize)
        return (0...half).map { Double($0) * step }
    }

    // MARK: - Float へ落とす

    /// 途中計算は Double、カーネルへ渡すのは Float。最後にここを通す。
    static func toFloat(_ values: [Double]) -> [Float] {
        values.map { Float($0) }
    }

    static func toDouble(_ values: [Float]) -> [Double] {
        values.map { Double($0) }
    }
}
