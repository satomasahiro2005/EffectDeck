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
//    - createWindow（端だけ落とす窓）は fir-crossover:123-141 と
//      five-band-fir-peq:216-234 に同じものが 2 つある。room-eq:225-238 もほぼ同じ
//    - Kaiser は窓関数としてではなく、窓付き sinc のリサンプラの中で使われている
//      （utils/measurement-dsp/resample.js:36）。ここでは resampleWindowedSinc の中に置いた
//    - Hann・Hamming・Blackman・Kaiser の窓関数、持ち上げ余弦の単体、toDouble は
//      どこからも呼ばれていなかったので消した（上流にも対応するものが無い）
//
//  --- 設計どうしで共通の手順 ---
//  minimumPhase・measureResponse・sampleAtFrequency・zeroTail・jsRound・
//  resampleWindowedSinc は、各設計のファイルに private の写しが 2〜3 本ずつある。
//  1 本にまとめる先としてここに置いた（写しから乗り換えるのは次の段）。
//  どれも上流の関数そのものの出力と照合してある（Tests/Unit/FIRDesignTests.swift。
//  見本は Tools/golden/fir_golden.mjs が作る Tests/Fixtures/FIR/fir-golden.json）。
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

    /// 第 1 種変形ベッセル関数 I0。
    /// resample.js:5-14 をそのまま移した（20 項で打ち切り、相対 1e-12 で抜ける）。
    /// 打ち切るので大きい値では本当の I0 より小さくなる。上流と同じ数を出すための形。
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

    /// FIR の端だけを落とす窓。
    /// fir-crossover/design-core.js:123-141 と five-band-fir-peq/design-core.js:216-234
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

    // MARK: - 最小位相

    /// 振幅から最小位相の位相（bin ごと、ラジアン）を出す。実ケプストラムを因果側へ折り返し、
    /// その FFT の虚部を取る（Hilbert 変換）。
    /// fir-crossover/design-core.js:108-120、five-band-fir-peq/design-core.js:198-214、
    /// room-eq/design-core.js:692-703 の minimumPhaseForMagnitude。3 本とも同じ手順
    /// （NaN の扱いだけ違う。floor の説明を見ること）。
    ///
    /// - Parameters:
    ///   - magnitudes: 0〜fftSize/2 の fftSize/2+1 個。それより後ろは見ない。足りない bin は
    ///     対数振幅 0（振幅 1）として扱う（fir-crossover・five-band と同じ）
    ///   - floor: 対数を取る前の床。3 本とも 1e-8。床以下と NaN は床にする。
    ///     NaN を床にするのは five-band-fir-peq と同じで、fir-crossover と room-eq とは違う。
    ///     その 2 本は Math.max(1e-8, NaN) が NaN のまま残り、utils/measurement-dsp/fft.js:179 の
    ///     `realHalf[index] || 0` で対数振幅 0（振幅 1）になる。ここは床に揃える
    ///     （Swift の設計側の写しも 3 本とも床にしている）
    /// - Returns: fftSize/2+1 個。fftSize が 4 以上の 2 の冪でなければ 0 を並べて返す
    ///
    /// 折り返しで index == fftSize/2 だけは 2 倍にも 0 にもしない。
    /// JS の 2 本のループがどちらもその添字を外しているため。
    static func minimumPhase(magnitudes: [Double],
                             fftSize: Int,
                             floor: Double = 1e-8,
                             fft: RealFFT? = nil) -> [Double] {
        let half = fftSize / 2
        guard let transform = fft ?? FIRDesign.fft(size: fftSize), transform.size == fftSize else {
            return [Double](repeating: 0, count: max(half + 1, 0))
        }
        let count = min(magnitudes.count, half + 1)
        var logMagnitude = [Double](repeating: 0, count: half + 1)
        for bin in 0..<count {
            let magnitude = magnitudes[bin]
            logMagnitude[bin] = log(magnitude > floor ? magnitude : floor)
        }
        var cepstrum = transform.inverseRealTransform(
            real: logMagnitude,
            imag: [Double](repeating: 0, count: logMagnitude.count)
        )
        if half > 1 {
            for index in 1..<half { cepstrum[index] *= 2 }
        }
        if half + 1 < fftSize {
            for index in (half + 1)..<fftSize { cepstrum[index] = 0 }
        }
        return transform.realTransform(cepstrum).imag
    }

    // MARK: - 出来た係数を測る

    /// bin ごとの振幅（dB）と群遅延（サンプル）。
    struct BinResponse: Equatable {
        /// 10·log10(|H|²)。|H|² が epsilon 以下なら epsilon で測る。
        let magnitudeDb: [Double]
        /// Re(H'·conj(H)) / |H|²。H' は n·h[n] の変換。|H|² が epsilon 以下の bin は fallbackDelay。
        let delaySamples: [Double]
    }

    /// 出来上がった FIR の振幅と群遅延を bin ごとに出す。
    /// group-delay-eq/design-core.js:222-243、group-delay-peq/design-core.js:321-343 の
    /// measureResponse の前半（2 本とも同じ）。群遅延は「傾斜をかけた変換との比」で出すので、
    /// 位相をほどく必要がない。周波数の格子へ読み替えて暴れを数える後半は設計ごとに違う
    /// （group-delay-peq は設計の帯の外を数えない）ので、ここには入れていない。
    ///
    /// - Parameters:
    ///   - ir: 係数。size より長ければ先頭 size 個だけを見る
    ///   - size: FFT の長さ（4 以上の 2 の冪）。上流は taps の 2 倍
    ///   - epsilon: 上流は 1e-12（MAGNITUDE_EPSILON）
    ///   - fallbackDelay: 無音の bin に置く遅延。上流は target.bulkDelaySamples
    /// - Returns: size が 4 以上の 2 の冪でなければ nil
    static func measureResponse(ir: [Float],
                                size: Int,
                                epsilon: Double = 1e-12,
                                fallbackDelay: Double,
                                fft: RealFFT? = nil) -> BinResponse? {
        guard let transform = fft ?? FIRDesign.fft(size: size), transform.size == size else { return nil }
        var impulse = [Double](repeating: 0, count: size)
        var ramped = [Double](repeating: 0, count: size)
        let count = min(ir.count, size)
        for index in 0..<count {
            let value = Double(ir[index])
            impulse[index] = value
            ramped[index] = value * Double(index)
        }
        let spectrum = transform.realTransform(impulse)
        let rampedSpectrum = transform.realTransform(ramped)
        let bins = spectrum.real.count
        var magnitudeDb = [Double](repeating: 0, count: bins)
        var delaySamples = [Double](repeating: 0, count: bins)
        for bin in 0..<bins {
            let real = spectrum.real[bin]
            let imag = spectrum.imag[bin]
            let power = real * real + imag * imag
            magnitudeDb[bin] = 10 * log10(power > epsilon ? power : epsilon)
            delaySamples[bin] = power > epsilon
                ? (rampedSpectrum.real[bin] * real + rampedSpectrum.imag[bin] * imag) / power
                : fallbackDelay
        }
        return BinResponse(magnitudeDb: magnitudeDb, delaySamples: delaySamples)
    }

    /// bin の並びを周波数で読む。bin のあいだは直線で結ぶ。
    /// five-band-fir-peq/design-core.js:249-255、group-delay-eq:164-170、group-delay-peq:263-269
    /// の sampleAtFrequency（3 本とも同じ）。
    ///
    /// 上流と違うのは端だけ: 空なら 0、負の位置は先頭の値を返す（上流は undefined を読んで NaN）。
    /// 位置が NaN なら NaN（上流と同じ）。Int へ落とす前に見るので、どんな値でも落ちない。
    static func sampleAtFrequency(_ values: [Double],
                                  frequency: Double,
                                  size: Int,
                                  sampleRate: Double) -> Double {
        guard let last = values.last else { return 0 }
        let position = frequency * Double(size) / sampleRate
        if position.isNaN { return .nan }
        let lowerPosition = position.rounded(.down)
        if lowerPosition + 1 >= Double(values.count) { return last }
        if lowerPosition < 0 { return values[0] }
        let lower = Int(lowerPosition)
        return values[lower] + (values[lower + 1] - values[lower]) * (position - lowerPosition)
    }

    /// JS の TypedArray.prototype.fill(0, start) と同じ。start が負なら後ろから数える。
    /// group-delay-eq:194・209、group-delay-peq:293・308 の `impulse.fill(0, taps)`。
    static func zeroTail(_ values: inout [Double], from start: Int) {
        let count = values.count
        let begin = start < 0 ? max(count + start, 0) : min(start, count)
        guard begin < count else { return }
        for index in begin..<count { values[index] = 0 }
    }

    // MARK: - JS の Math.round

    /// JS の Math.round（ECMAScript の定義どおり）。
    ///   - 半分はいつも +∞ の側へ（2.5 → 3、-2.5 → -2）。Swift の rounded() は 0 から遠い側へ
    ///     丸めるので負の半分で食い違う
    ///   - floor(x + 0.5) とも違う。0.49999999999999994 や 2^52+1 は足した時点で丸めが起き、
    ///     1 つ上へずれる。ここは小数部を見て決める（x - floor(x) は丸めずに出る）
    ///   - -0.5 以上 0 未満と -0 は -0。NaN と ±∞ はそのまま
    static func jsRound(_ value: Double) -> Double {
        guard value.isFinite else { return value }
        let down = value.rounded(.down)
        let rounded = value - down >= 0.5 ? down + 1 : down
        if rounded == 0 && value.sign == .minus { return -0.0 }
        return rounded
    }

    // MARK: - 窓付き sinc のリサンプラ

    /// utils/measurement-dsp/resample.js:61-119 の resampleWindowedSinc。
    /// Kaiser 窓の sinc で、100dB の減衰を狙う。レートは整数なので、上流の「位相の表」の側
    /// （:83-86、:97-103）だけを通る。位相は使ったものだけ作って使い回す（表は呼び出しの中だけで持つ）。
    ///
    /// - Parameters:
    ///   - radius: 片側のタップ数。nil なら上流と同じく減衰と遷移帯から決める。
    ///     crosstalk-cancellation は resampleSupportRadius で決めた値を渡している
    ///   - beta: Kaiser の β。nil なら 0.1102·(100 - 8.7)
    /// - Returns: 長さは max(1, Math.round(input.count·target/source))。
    ///   同じレートなら input のまま。レートか radius・beta が正しくなければ input のまま
    ///   （上流は TypeError を投げる）
    static func resampleWindowedSinc(_ input: [Float],
                                     sourceRate: Int,
                                     targetRate: Int,
                                     radius: Int? = nil,
                                     beta: Double? = nil) -> [Float] {
        guard sourceRate > 0, targetRate > 0 else { return input }
        if sourceRate == targetRate { return input }
        let outputLength = max(1, Int(jsRound(Double(input.count) * Double(targetRate) / Double(sourceRate))))
        let bandLimit = targetRate < sourceRate ? Double(targetRate) / Double(sourceRate) : 1
        let cutoff = bandLimit * 0.95
        let transitionWidthRadians = Double.pi * bandLimit * 0.1
        let attenuationDb = 100.0
        let kaiserBeta = beta ?? 0.1102 * (attenuationDb - 8.7)
        let support = radius ?? Int(((attenuationDb - 8) / (4.57 * transitionWidthRadians)).rounded(.up))
        guard support >= 1, kaiserBeta.isFinite, kaiserBeta >= 0 else { return input }
        let normalizer = besselI0(kaiserBeta)

        let divisor = greatestCommonDivisor(sourceRate, targetRate)
        let sourceStep = sourceRate / divisor
        let phaseCount = targetRate / divisor
        var phases = [Int: [Double]]()
        var output = [Float](repeating: 0, count: outputLength)

        for outputIndex in 0..<outputLength {
            let position = outputIndex * sourceStep
            let center = position / phaseCount          // Math.floor（どちらも正）
            let phaseIndex = position % phaseCount
            let coefficients: [Double]
            if let cached = phases[phaseIndex] {
                coefficients = cached
            } else {
                coefficients = resamplePhaseCoefficients(fraction: Double(phaseIndex) / Double(phaseCount),
                                                         cutoff: cutoff,
                                                         radius: support,
                                                         beta: kaiserBeta,
                                                         normalizer: normalizer)
                phases[phaseIndex] = coefficients
            }

            let firstInputIndex = center - support + 1
            var weighted = 0.0
            if firstInputIndex >= 0 && firstInputIndex + coefficients.count <= input.count {
                for tap in 0..<coefficients.count {
                    weighted += Double(input[firstInputIndex + tap]) * coefficients[tap]
                }
                output[outputIndex] = Float(weighted)
                continue
            }
            // 端。届いた分だけで重みを割り直す。
            var weightTotal = 0.0
            for tap in 0..<coefficients.count {
                let inputIndex = firstInputIndex + tap
                if inputIndex < 0 || inputIndex >= input.count { continue }
                let weight = coefficients[tap]
                weighted += Double(input[inputIndex]) * weight
                weightTotal += weight
            }
            output[outputIndex] = weightTotal == 0 ? 0 : Float(weighted / weightTotal)
        }
        return output
    }

    /// resample.js:28-45 の createPhaseCoefficients。1 つの位相ぶんの 2·radius 個の係数（和が 1）。
    static func resamplePhaseCoefficients(fraction: Double,
                                          cutoff: Double,
                                          radius: Int,
                                          beta: Double,
                                          normalizer: Double) -> [Double] {
        var coefficients = [Double](repeating: 0, count: radius * 2)
        var total = 0.0
        for tap in 0..<coefficients.count {
            let distance = fraction - Double(tap - radius + 1)
            let normalized = distance / Double(radius)
            if normalized <= -1 || normalized >= 1 { continue }
            let window = besselI0(beta * (1 - normalized * normalized).squareRoot()) / normalizer
            let weight = cutoff * sinc(distance * cutoff) * window
            coefficients[tap] = weight
            total += weight
        }
        if total != 0 {
            for tap in 0..<coefficients.count { coefficients[tap] /= total }
        }
        return coefficients
    }

    /// resample.js:1-3。sin(πx)/(πx)、0 では 1。
    static func sinc(_ value: Double) -> Double {
        value == 0 ? 1 : sin(Double.pi * value) / (Double.pi * value)
    }

    /// resample.js:19-26。
    static func greatestCommonDivisor(_ left: Int, _ right: Int) -> Int {
        var a = left
        var b = right
        while b != 0 {
            let remainder = a % b
            a = b
            b = remainder
        }
        return a
    }
}
