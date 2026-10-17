//  VisualizerAnalysis.swift
//  Visualizer の解析。音の輪（ETMeterTap）から読んだ標本を計り、描く側（VisualizerRenderer）が読む値にする。
//  アプリの中の画面も Floating Meters も、ここに 1 つだけある ETVisualizerAnalysis.shared を読む。
//
//  **SwiftUI も UIKit も通さない。**PiP は背景でも 30 回/秒描くので、読みも計りも描きも画面の部品に頼らない
//  （Mac の試し描きで同じ物を動かす）。音のスレッドには何も足さない（ETMeterTap が写すだけ）。
//
//  **誰が要るかで計算を変える。**呼び手は register で要るものを申し出る（ETVisualizerNeedsSet）。
//  スペクトログラムの輪・スペクトラム・VU の針・ステレオの角度ごとのピークは、要るあいだだけ確保して計り、
//  要らなくなったら捨てる。波形・ステレオの点・レベルは安いので常に計る。
//
//  **落ちる速さは時間で決める**（VisualizerBallistics）。2 つの面が同じ回に update を呼んでも、
//  0.002 秒以内の呼びは何もしない。

import Accelerate
import CoreGraphics
import QuartzCore

/// 0〜1 の色。波形の帯の色が元で、ステレオの点にも使う。
struct ETVisualizerRGB {
    var r: Float
    var g: Float
    var b: Float
}

/// 波形の 1 桶（10ms）。
struct ETVisualizerColumn {
    /// max(|L|, |R|)。Classic の波形。
    var peak: Float
    /// 左右を平均したモノラルの最小・最大。EffeTune の波形。
    var lo: Float
    var hi: Float
    var color: ETVisualizerRGB
}

/// スペクトログラムの輪。BGRA（little endian で 32bit に読むと ARGB）の `rows` 行 × `columns` 列を
/// 手で確保した 1 枚の絵として持ち、新しい列を 1 つずつ head の所へ書く。
/// 描く側は image() で作った CGImage（輪を写さずに指す）を切り出して、古い順に 2 つに分けて置く。
final class ETSpectrogramRing {
    let columns: Int
    let rows: Int
    private let pixels: UnsafeMutablePointer<UInt32>
    /// 次に書く列。1 つ手前がいちばん新しい。
    private(set) var head = 0

    init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
        pixels = UnsafeMutablePointer<UInt32>.allocate(capacity: columns * rows)
        pixels.initialize(repeating: 0xFF000000, count: columns * rows)
    }

    deinit {
        pixels.deallocate()
    }

    func clear() {
        pixels.update(repeating: 0xFF000000, count: columns * rows)
        head = 0
    }

    /// 同じ列を `count` 回足す（上限は輪の幅）。`column` は `rows` 個。
    func append(_ column: UnsafePointer<UInt32>, count: Int) {
        for _ in 0..<min(count, columns) {
            for y in 0..<rows { pixels[y * columns + head] = column[y] }
            head = head + 1 == columns ? 0 : head + 1
        }
    }

    /// 輪を写さずに指す絵。この回の描きの中だけで使う（輪が書き換わる前に捨てる）。
    func image() -> CGImage? {
        guard let provider = CGDataProvider(dataInfo: nil, data: pixels, size: columns * rows * 4,
                                            releaseData: { _, _, _ in }) else { return nil }
        return CGImage(width: columns, height: rows, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: columns * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

@MainActor
final class ETVisualizerAnalysis {

    static let shared = ETVisualizerAnalysis()

    // MARK: 大きさ

    static let waveformColumns = 1280
    static let spectrogramRows = 256
    static let classicColumns = 1280
    static let effetuneColumns = 1024
    /// EffeTune のスペクトログラムが 1 列進む標本の数（上流の 2^12 の半分）。
    static let effetuneHop = 2048
    static let spectrumBins = 640
    static let envelopeBins = 360
    static let monoCount = 8192
    static let stereoCount = 8192
    private static let fftLog2 = 12
    private static let fftSize = 1 << fftLog2

    // MARK: 読む

    private(set) var sampleRate: Double = 48000
    private var cursor: UInt64 = 0
    private var scratch = [Float](repeating: 0, count: 2 * 16384)
    private var lastUpdate: Double = 0

    // MARK: 頼み

    private var holders: [ObjectIdentifier: ETVisualizerNeedsSet] = [:]
    private(set) var needs: ETVisualizerNeedsSet = []

    // MARK: 波形（常に）

    private(set) var columns = [ETVisualizerColumn](
        repeating: ETVisualizerColumn(peak: 0, lo: 0, hi: 0, color: ETVisualizerRGB(r: 0, g: 0, b: 0)),
        count: waveformColumns)
    private var columnHead = 0
    private var hopFill = 0
    private var hopPeak: Float = 0
    private var hopLo: Float = .infinity, hopHi: Float = -.infinity
    private var hopLow: Float = 0, hopMid: Float = 0, hopHigh: Float = 0
    private var lp200: Float = 0, lp2000: Float = 0
    private var coeff200: Float = 0, coeff2000: Float = 0
    /// 直近の桶の色。ステレオの点にも使う。
    private var lastColor = ETVisualizerRGB(r: 1, g: 1, b: 1)

    // MARK: モノラルとステレオの標本（常に）

    private var mono = [Float](repeating: 0, count: monoCount)
    /// これまでに書いた標本の数。添字は `& (monoCount - 1)`。
    private(set) var monoTotal = 0
    private var stereoL = [Float](repeating: 0, count: stereoCount)
    private var stereoR = [Float](repeating: 0, count: stereoCount)
    private var stereoColor = [ETVisualizerRGB](repeating: ETVisualizerRGB(r: 1, g: 1, b: 1), count: stereoCount)
    private(set) var stereoTotal = 0

    // MARK: レベル（常に）

    private(set) var classicLevels = [ETVisualizerBallistics.Level](
        repeating: ETVisualizerBallistics.Level(floor: ETVisualizerBallistics.classicFloor), count: 2)
    private(set) var effetuneLevels = [ETVisualizerBallistics.Level](
        repeating: ETVisualizerBallistics.Level(floor: ETVisualizerBallistics.effetuneFloor), count: 2)

    // MARK: ラウドネス（.loudness）

    private var kStates = [ETBiquadState](repeating: ETBiquadState(), count: 4)
    private var kShelf = ETBiquad()
    private var kHigh = ETBiquad()
    private var blockFill = 0
    private var blockSum: Double = 0
    private var blocks: [Double] = []
    /// Momentary LUFS。測れていないあいだは -∞。
    private(set) var momentary: Double = -.infinity

    // MARK: VU（.vu）

    private var needles: [ETVUNeedle] = []
    private(set) var vuDB: [Float] = [-240, -240]

    // MARK: ステレオの角度ごとのピーク（.stereoEnvelope）

    /// 添字は度（-atan2(y, x)）。値は 0.5·√(x²+y²) のピーク。
    private(set) var envelope: [Double] = []

    // MARK: FFT（スペクトログラム・スペクトラム）

    private let fftSetup: FFTSetup? = vDSP_create_fftsetup(vDSP_Length(fftLog2), FFTRadix(kFFTRadix2))
    private var windowClassic = [Float](repeating: 0, count: fftSize)
    private var windowEffeTune = [Float](repeating: 0, count: fftSize)
    private var frame = [Float](repeating: 0, count: fftSize)
    private var real = [Float](repeating: 0, count: fftSize / 2)
    private var imag = [Float](repeating: 0, count: fftSize / 2)
    private var power = [Float](repeating: 0, count: fftSize / 2)

    // 標本率が決まると決まる、行や桶ごとの FFT の目盛りの範囲（configure で作る）。
    // lo が負なら Nyquist より上（黒・-∞）。tilt は dB に足す傾き。
    private var classicRowLo = [Int32](), classicRowHi = [Int32](), classicRowTilt = [Float]()
    private var classicBinLo = [Int32](), classicBinHi = [Int32](), classicBinTilt = [Float]()
    private var effetuneRowLo = [Int32](), effetuneRowHi = [Int32]()
    private var effetuneBinLo = [Int32](), effetuneBinHi = [Int32]()

    private(set) var classicSpectrogram: ETSpectrogramRing?
    private(set) var effetuneSpectrogram: ETSpectrogramRing?
    private var classicPending = 0
    private var effetunePending = 0
    private var columnScratch = [UInt32](repeating: 0xFF000000, count: spectrogramRows)

    /// Classic のスペクトラム（dB、傾き込み。落ちるのは 45dB/秒）。
    private(set) var classicSpectrum: [Float] = []
    /// EffeTune のスペクトラム。current は即座、peak は 20dB/秒で落ちる。Nyquist より上は -∞。
    private(set) var effetuneSpectrum: [Float] = []
    private(set) var effetunePeaks: [Float] = []

    private static let classicSpectrumFall: Float = 45

    private init() {
        vDSP_hann_window(&windowClassic, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
        vDSP_hann_window(&windowEffeTune, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_DENORM))
        configure(rate: 48000)
    }

    // MARK: - 頼み

    /// `holder`（画面や PiP）が要るものを申し出る。もう一度呼ぶと置き換える。
    func register(_ holder: AnyObject, needs wanted: ETVisualizerNeedsSet) {
        holders[ObjectIdentifier(holder)] = wanted
        applyNeeds()
    }

    func unregister(_ holder: AnyObject) {
        holders[ObjectIdentifier(holder)] = nil
        applyNeeds()
    }

    /// 要るものの和。増えたものは確保して白紙から、減ったものは捨てる。
    private func applyNeeds() {
        let union = holders.values.reduce(into: ETVisualizerNeedsSet()) { $0.formUnion($1) }
        let added = union.subtracting(needs)
        needs = union

        func ring(_ wanted: Bool, _ current: ETSpectrogramRing?, _ columns: Int) -> ETSpectrogramRing? {
            guard wanted else { return nil }
            return current ?? ETSpectrogramRing(columns: columns, rows: Self.spectrogramRows)
        }
        classicSpectrogram = ring(union.contains(.classicSpectrogram), classicSpectrogram, Self.classicColumns)
        effetuneSpectrogram = ring(union.contains(.effetuneSpectrogram), effetuneSpectrogram, Self.effetuneColumns)
        if added.contains(.classicSpectrogram) { classicPending = 0 }
        if added.contains(.effetuneSpectrogram) { effetunePending = 0 }

        if union.contains(.classicSpectrum) {
            if classicSpectrum.isEmpty { classicSpectrum = [Float](repeating: -120, count: Self.spectrumBins) }
        } else {
            classicSpectrum = []
        }
        if union.contains(.effetuneSpectrum) {
            if effetuneSpectrum.isEmpty {
                effetuneSpectrum = [Float](repeating: -.infinity, count: Self.spectrumBins)
                effetunePeaks = [Float](repeating: -.infinity, count: Self.spectrumBins)
            }
        } else {
            effetuneSpectrum = []
            effetunePeaks = []
        }

        if added.contains(.loudness) { resetLoudness() }
        if !union.contains(.loudness) { blocks = [] }
        if union.contains(.vu) {
            if needles.isEmpty {
                needles = [ETVUNeedle(rate: sampleRate), ETVUNeedle(rate: sampleRate)]
                vuDB = [-240, -240]
            }
        } else {
            needles = []
        }
        if union.contains(.stereoEnvelope) {
            if envelope.isEmpty { envelope = [Double](repeating: 0, count: Self.envelopeBins) }
        } else {
            envelope = []
        }
    }

    private func resetLoudness() {
        kStates = [ETBiquadState](repeating: ETBiquadState(), count: 4)
        blocks.removeAll(keepingCapacity: true)
        blockFill = 0
        blockSum = 0
        momentary = -.infinity
    }

    // MARK: - 標本率ごとの用意

    private func configure(rate: Double) {
        sampleRate = rate
        coeff200 = Float(1 - exp(-2 * Double.pi * 200 / rate))
        coeff2000 = Float(1 - exp(-2 * Double.pi * 2000 / rate))
        (kShelf, kHigh) = ETBiquad.kWeighting(rate: rate)
        resetLoudness()
        if !needles.isEmpty { needles = [ETVUNeedle(rate: rate), ETVUNeedle(rate: rate)] }

        let half = Self.fftSize / 2
        let binHz = rate / Double(Self.fftSize)
        let last = half - 1
        /// 周波数の区間 [f0, f1) が当たる FFT の目盛り。最低 1、最大 last。
        func bins(_ f0: Double, _ f1: Double) -> (Int32, Int32) {
            let lo = min(max(1, Int(f0 / binHz)), last)
            let hi = min(last, max(lo, Int(f1 / binHz)))
            return (Int32(lo), Int32(hi))
        }

        // Classic。下が 20Hz、上が 20kHz の対数。1kHz を軸に 3dB/oct 持ち上げる（音楽は高いほど小さいので、
        // そのままだと下だけ明るい）。+6 は以前の MiniMeters と同じ。
        let rows = Self.spectrogramRows
        classicRowLo = []; classicRowHi = []; classicRowTilt = []
        for y in 0..<rows {
            let t0 = Double(rows - 1 - y) / Double(rows), t1 = Double(rows - y) / Double(rows)
            let (lo, hi) = bins(20 * pow(1000, t0), 20 * pow(1000, t1))
            classicRowLo.append(lo); classicRowHi.append(hi)
            classicRowTilt.append(6 + Float(3 * log2(20 * pow(1000, (t0 + t1) / 2) / 1000)))
        }
        let fine = Self.spectrumBins
        classicBinLo = []; classicBinHi = []; classicBinTilt = []
        for c in 0..<fine {
            let t0 = Double(c) / Double(fine), t1 = Double(c + 1) / Double(fine)
            let (lo, hi) = bins(20 * pow(1000, t0), 20 * pow(1000, t1))
            classicBinLo.append(lo); classicBinHi.append(hi)
            classicBinTilt.append(6 + Float(3 * log2(20 * pow(1000, (t0 + t1) / 2) / 1000)))
        }

        // EffeTune。20Hz〜40kHz の対数（上流の log-hq）。Nyquist より上は負の lo で印を付ける。
        let nyquist = rate / 2
        effetuneRowLo = []; effetuneRowHi = []
        for y in 0..<rows {
            let t0 = Double(rows - 1 - y) / Double(rows), t1 = Double(rows - y) / Double(rows)
            let f0 = 20 * pow(2000, t0), f1 = 20 * pow(2000, t1)
            if f0 >= nyquist {
                effetuneRowLo.append(-1); effetuneRowHi.append(-1)
            } else {
                let (lo, hi) = bins(f0, f1)
                effetuneRowLo.append(lo); effetuneRowHi.append(hi)
            }
        }
        effetuneBinLo = []; effetuneBinHi = []
        let step = pow(2000, 0.5 / Double(fine - 1))
        for i in 0..<fine {
            let f = 20 * pow(2000, Double(i) / Double(fine - 1))
            if f >= nyquist {
                effetuneBinLo.append(-1); effetuneBinHi.append(-1)
                continue
            }
            let center = min(max(1, Int(f / binHz)), last)
            let (lo, hi) = bins(f / step, f * step)
            effetuneBinLo.append(Int32(min(Int(lo), center)))
            effetuneBinHi.append(Int32(max(Int(hi), center)))
        }
    }

    /// 読み始める位置を今にして、溜めたものを全部捨てる（前に溜まっていたものを流さない）。
    func reset() {
        _ = ETMeterTap_Read(0, &scratch, 0, &cursor)
        lastUpdate = 0
        for i in columns.indices { columns[i] = ETVisualizerColumn(peak: 0, lo: 0, hi: 0, color: ETVisualizerRGB(r: 0, g: 0, b: 0)) }
        columnHead = 0
        hopFill = 0
        hopPeak = 0; hopLo = .infinity; hopHi = -.infinity
        hopLow = 0; hopMid = 0; hopHigh = 0
        lp200 = 0; lp2000 = 0
        for i in mono.indices { mono[i] = 0 }
        monoTotal = 0
        for i in stereoL.indices { stereoL[i] = 0; stereoR[i] = 0 }
        stereoTotal = 0
        classicLevels = classicLevels.map { _ in ETVisualizerBallistics.Level(floor: ETVisualizerBallistics.classicFloor) }
        effetuneLevels = effetuneLevels.map { _ in ETVisualizerBallistics.Level(floor: ETVisualizerBallistics.effetuneFloor) }
        resetLoudness()
        for i in needles.indices { needles[i].reset() }
        vuDB = [-240, -240]
        for i in envelope.indices { envelope[i] = 0 }
        classicSpectrogram?.clear()
        effetuneSpectrogram?.clear()
        classicPending = 0
        effetunePending = 0
        for i in classicSpectrum.indices { classicSpectrum[i] = -120 }
        for i in effetuneSpectrum.indices { effetuneSpectrum[i] = -.infinity; effetunePeaks[i] = -.infinity }
    }

    // MARK: - 読む

    /// 輪から新しい標本を読んで計る。どの面も描く前に呼ぶ。0.002 秒以内の 2 度目は何もしない。
    func update(rate: Double, now: Double) {
        if lastUpdate != 0 && now - lastUpdate < 0.002 { return }
        if rate > 0 && rate != sampleRate { configure(rate: rate) }
        let dt = lastUpdate == 0 ? 0 : Float(max(now - lastUpdate, 0))
        lastUpdate = now

        let maxFrames = UInt32(scratch.count / 2)
        let n = Int(scratch.withUnsafeMutableBufferPointer {
            ETMeterTap_Read(cursor, $0.baseAddress, maxFrames, &cursor)
        })
        // JSFX の要素にも同じ標本を渡す（輪を読むのはここ 1 か所だけ）。要素が無ければ何もしない。
        if n > 0 {
            scratch.withUnsafeBufferPointer {
                ETVisualizerJSFXPool.shared.feed(UnsafeBufferPointer(rebasing: $0[0..<2 * n]), frames: n)
            }
        }

        let wantLoudness = needs.contains(.loudness)
        let wantVU = needs.contains(.vu) && needles.count == 2
        let wantEnvelope = needs.contains(.stereoEnvelope) && envelope.count == Self.envelopeBins
        if wantEnvelope && n > 0 {
            // 1 標本ごとに 20dB/秒で落とす分を、この回の n 標本ぶんまとめて掛ける。
            let decay = pow(exp(-log(10.0) / sampleRate), Double(n))
            for b in 0..<Self.envelopeBins {
                let v = envelope[b] * decay
                envelope[b] = v < 1e-9 ? 0 : v
            }
        }

        var peakL: Float = 0, peakR: Float = 0
        let hop = max(1, Int(sampleRate / 100))
        let blockLength = max(1, Int(sampleRate / 10))
        let monoMask = Self.monoCount - 1
        let stereoMask = Self.stereoCount - 1
        for i in 0..<n {
            // 鎖が壊れて NaN / Inf が来ても、状態（K 特性・針・包絡）を汚さず Int 変換で落ちないよう 0 にする。
            var l = scratch[2 * i], r = scratch[2 * i + 1]
            if !l.isFinite { l = 0 }
            if !r.isFinite { r = 0 }
            peakL = max(peakL, abs(l))
            peakR = max(peakR, abs(r))
            let m = 0.5 * (l + r)

            // 波形の桶。帯は 200Hz と 2kHz で切る（MiniMeters の RGB のモードと同じ）。
            lp200 += coeff200 * (m - lp200)
            lp2000 += coeff2000 * (m - lp2000)
            let low = lp200, mid = lp2000 - lp200, high = m - lp2000
            hopPeak = max(hopPeak, max(abs(l), abs(r)))
            hopLo = min(hopLo, m)
            hopHi = max(hopHi, m)
            hopLow += low * low
            hopMid += mid * mid
            hopHigh += high * high
            hopFill += 1
            if hopFill >= hop {
                lastColor = Self.bandColor(low: hopLow, mid: hopMid, high: hopHigh)
                columns[columnHead] = ETVisualizerColumn(peak: hopPeak, lo: hopLo, hi: hopHi, color: lastColor)
                columnHead = (columnHead + 1) % Self.waveformColumns
                hopFill = 0
                hopPeak = 0; hopLo = .infinity; hopHi = -.infinity
                hopLow = 0; hopMid = 0; hopHigh = 0
            }

            mono[monoTotal & monoMask] = m
            monoTotal += 1
            let slot = stereoTotal & stereoMask
            stereoL[slot] = l
            stereoR[slot] = r
            stereoColor[slot] = lastColor
            stereoTotal += 1

            if wantLoudness {
                // K 特性をかけて 100ms ごとに 2 乗の平均。Momentary は直近 400ms。
                let kl = kHigh.run(kShelf.run(Double(l), &kStates[0]), &kStates[1])
                let kr = kHigh.run(kShelf.run(Double(r), &kStates[2]), &kStates[3])
                blockSum += kl * kl + kr * kr
                blockFill += 1
                if blockFill >= blockLength {
                    blocks.append(blockSum / Double(blockLength))
                    if blocks.count > 4 { blocks.removeFirst(blocks.count - 4) }
                    blockSum = 0
                    blockFill = 0
                    let mean = blocks.reduce(0, +) / Double(blocks.count)
                    momentary = mean > 1e-12 ? -0.691 + 10 * log10(mean) : -.infinity
                }
            }
            if wantVU {
                needles[0].feed(l)
                needles[1].feed(r)
            }
            if wantEnvelope {
                // 上流の updateAngleEnvelope（stereo_meter/kernel.cpp）。角度は -atan2(y, x) を度で。
                let x = Double(r) - Double(l), y = Double(l) + Double(r)
                let angle = -atan2(y, x) * 180 / Double.pi
                var bin = Int((angle + 0.5).rounded(.down)) % Self.envelopeBins
                if bin < 0 { bin += Self.envelopeBins }
                let magnitude = 0.5 * (x * x + y * y).squareRoot()
                if magnitude > envelope[bin] { envelope[bin] = magnitude }
            }
        }
        if wantVU {
            vuDB[0] = needles[0].db
            vuDB[1] = needles[1].db
        }

        // 棒の高さ。ブロックのピーク（dBFS）から。
        for ch in 0..<2 {
            let peak = ch == 0 ? peakL : peakR
            let db: Float = peak > 0 ? 20 * log10(peak) : -120
            ETVisualizerBallistics.classic(&classicLevels[ch], db: db, now: now, dt: dt)
            ETVisualizerBallistics.effetune(&effetuneLevels[ch], db: db, now: now, dt: dt)
        }

        advanceSpectra(newSamples: n, dt: dt)
    }

    /// 帯の量から色を作る。低域は赤、中域は緑、高域は 50,50,255 を足し、一番強い所を 1 にする。
    /// 高い帯ほど量が小さいので、足す前に持ち上げる（そのままだとほぼ赤一色になる）。
    private static func bandColor(low: Float, mid: Float, high: Float) -> ETVisualizerRGB {
        let a = low.squareRoot(), b = 1.0 * mid.squareRoot(), c = 5.0 * high.squareRoot()
        let r = a + 0.196 * c, g = b + 0.196 * c, bl = c
        let top = max(r, g, bl)
        guard top > 1e-9 else { return ETVisualizerRGB(r: 1, g: 1, b: 1) }
        return ETVisualizerRGB(r: r / top, g: g / top, b: bl / top)
    }

    // MARK: - スペクトログラムとスペクトラム

    private func advanceSpectra(newSamples n: Int, dt: Float) {
        let classicWanted = !needs.intersection([.classicSpectrogram, .classicSpectrum]).isEmpty
        let effetuneWanted = !needs.intersection([.effetuneSpectrogram, .effetuneSpectrum]).isEmpty
        guard n > 0, fftSetup != nil, classicWanted || effetuneWanted else {
            fallSpectra(dt: dt)
            return
        }
        // スペクトラムは毎回要る。スペクトログラムだけなら、次の 1 列が出来る回（hop に届く回）だけ FFT する。
        // 届かない回は溜めるだけ（捨てる FFT を回さない）。
        if classicWanted {
            let hop = max(1, Int(sampleRate / 60))
            if !classicSpectrum.isEmpty || (classicSpectrogram != nil && classicPending + n >= hop) {
                fft(window: windowClassic) { self.advanceClassic(dt: dt, newSamples: n) }
            } else {
                classicPending += n
            }
        }
        if effetuneWanted {
            if !effetuneSpectrum.isEmpty || (effetuneSpectrogram != nil && effetunePending + n >= Self.effetuneHop) {
                fft(window: windowEffeTune) { self.advanceEffeTune(dt: dt, newSamples: n) }
            } else {
                effetunePending += n
            }
        }
    }

    /// 標本が来なかった回。スペクトラムは落とすだけ。
    private func fallSpectra(dt: Float) {
        for i in classicSpectrum.indices {
            classicSpectrum[i] = ETVisualizerBallistics.fall(classicSpectrum[i], input: -120,
                                                             rate: Self.classicSpectrumFall, dt: dt, floor: -120)
        }
        for i in effetunePeaks.indices {
            effetunePeaks[i] = ETVisualizerBallistics.fall(effetunePeaks[i], input: effetuneSpectrum[i],
                                                           rate: ETVisualizerBallistics.effetuneFall, dt: dt,
                                                           floor: -.infinity)
        }
    }

    /// いちばん新しい 4096 標本に窓をかけて FFT し、`power`（2048 個）に出して `then` を呼ぶ。
    private func fft(window: [Float], then: () -> Void) {
        guard let fftSetup else { return }
        let size = Self.fftSize
        let start = monoTotal - size
        let mask = Self.monoCount - 1
        for i in 0..<size { frame[i] = mono[(start + i) & mask] * window[i] }
        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                frame.withUnsafeBufferPointer { src in
                    src.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(size / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, vDSP_Length(Self.fftLog2), FFTDirection(FFT_FORWARD))
                power.withUnsafeMutableBufferPointer {
                    vDSP_zvmags(&split, 1, $0.baseAddress!, 1, vDSP_Length(size / 2))
                }
            }
        }
        then()
    }

    /// `power` の [lo, hi] の最大。
    @inline(__always)
    private func maxPower(_ lo: Int32, _ hi: Int32) -> Float {
        var peak: Float = 0
        var b = Int(lo)
        let end = Int(hi)
        while b <= end {
            peak = max(peak, power[b])
            b += 1
        }
        return peak
    }

    private func advanceClassic(dt: Float, newSamples n: Int) {
        let scale = 1 / Float(Self.fftSize * Self.fftSize)
        if let ring = classicSpectrogram {
            let hop = max(1, Int(sampleRate / 60))
            classicPending += n
            let k = classicPending / hop
            classicPending -= k * hop
            if k > 0 {
                let rows = Self.spectrogramRows
                for y in 0..<rows {
                    let peak = maxPower(classicRowLo[y], classicRowHi[y])
                    let db = peak > 0 ? 10 * log10(peak * scale) + classicRowTilt[y] : -120
                    columnScratch[y] = ETVisualizerPalette.classicHeat(db)
                }
                columnScratch.withUnsafeBufferPointer { ring.append($0.baseAddress!, count: k) }
            }
        }
        if !classicSpectrum.isEmpty {
            for i in 0..<Self.spectrumBins {
                let peak = maxPower(classicBinLo[i], classicBinHi[i])
                let db: Float = peak > 0 ? 10 * log10(peak * scale) + classicBinTilt[i] : -120
                classicSpectrum[i] = ETVisualizerBallistics.fall(classicSpectrum[i], input: db,
                                                                 rate: Self.classicSpectrumFall, dt: dt, floor: -120)
            }
        }
    }

    private func advanceEffeTune(dt: Float, newSamples n: Int) {
        // 窓は DENORM。満点の正弦が 0dB になるよう (n/2)² で割る。
        let reference = 20 * log10(Float(Self.fftSize / 2))
        if let ring = effetuneSpectrogram {
            effetunePending += n
            let k = effetunePending / Self.effetuneHop
            effetunePending -= k * Self.effetuneHop
            if k > 0 {
                let rows = Self.spectrogramRows
                for y in 0..<rows {
                    let lo = effetuneRowLo[y]
                    if lo < 0 {
                        columnScratch[y] = 0xFF000000
                        continue
                    }
                    let peak = maxPower(lo, effetuneRowHi[y])
                    let db: Float = peak > 0 ? 10 * log10(peak) - reference : -200
                    columnScratch[y] = ETVisualizerPalette.effetuneColor(1 - db / -96)
                }
                columnScratch.withUnsafeBufferPointer { ring.append($0.baseAddress!, count: k) }
            }
        }
        if !effetuneSpectrum.isEmpty {
            for i in 0..<Self.spectrumBins {
                let lo = effetuneBinLo[i]
                let db: Float
                if lo < 0 {
                    db = -.infinity
                } else {
                    let peak = maxPower(lo, effetuneBinHi[i])
                    db = peak > 0 ? 10 * log10(peak) - reference : -200
                }
                effetuneSpectrum[i] = db
                effetunePeaks[i] = ETVisualizerBallistics.fall(effetunePeaks[i], input: db,
                                                               rate: ETVisualizerBallistics.effetuneFall, dt: dt,
                                                               floor: -.infinity)
            }
        }
    }

    // MARK: - 描く側が読む

    /// 新しいほうから k 番目（0 が最新）の波形の桶。
    func column(newest k: Int) -> ETVisualizerColumn {
        columns[(columnHead - 1 - k + 2 * Self.waveformColumns) % Self.waveformColumns]
    }

    /// 通し番号 `absolute` のモノラル標本（古いものは輪が上書きしている）。
    func monoSample(at absolute: Int) -> Float {
        mono[absolute & (Self.monoCount - 1)]
    }

    /// 通し番号 `absolute` のステレオの 1 点。
    func stereoFrame(at absolute: Int) -> (l: Float, r: Float, color: ETVisualizerRGB) {
        let slot = absolute & (Self.stereoCount - 1)
        return (stereoL[slot], stereoR[slot], stereoColor[slot])
    }

    /// 直近 `seconds` 秒の相関（-1〜1）と左右差（dB。R が大きいと正）。stereo_meter/kernel.cpp と同じ式。
    func stereoStatistics(seconds: Double) -> (correlation: Double, balance: Double) {
        let count = min(Int(seconds * sampleRate), Self.stereoCount, stereoTotal)
        guard count > 0 else { return (0, 0) }
        var sumL2 = 0.0, sumR2 = 0.0, sumLR = 0.0
        for a in (stereoTotal - count)..<stereoTotal {
            let slot = a & (Self.stereoCount - 1)
            let l = Double(stereoL[slot]), r = Double(stereoR[slot])
            sumL2 += l * l
            sumR2 += r * r
            sumLR += l * r
        }
        var correlation = 0.0
        if sumL2 > 0 && sumR2 > 0 {
            correlation = min(1, max(-1, sumLR / (sumL2.squareRoot() * sumR2.squareRoot())))
        }
        let epsilon = 1e-12
        return (correlation, 10 * log10(sumR2 + epsilon) - 10 * log10(sumL2 + epsilon))
    }
}

// MARK: - K 特性（ITU-R BS.1770）

struct ETBiquadState { var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0 }

struct ETBiquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0

    func run(_ x: Double, _ s: inout ETBiquadState) -> Double {
        let y = b0 * x + b1 * s.x1 + b2 * s.x2 - a1 * s.y1 - a2 * s.y2
        s.x2 = s.x1; s.x1 = x; s.y2 = s.y1; s.y1 = y
        return y
    }

    /// 前段の棚と後段の高域通過。48kHz の表の係数を、どのレートでも同じ形になるよう作り直す
    /// （libebur128 と同じ作り方）。
    static func kWeighting(rate: Double) -> (ETBiquad, ETBiquad) {
        var shelf = ETBiquad()
        do {
            let f0 = 1681.974450955533, gain = 3.999843853973347, q = 0.7071752369554196
            let k = tan(Double.pi * f0 / rate)
            let vh = pow(10, gain / 20), vb = pow(vh, 0.4996667741545416)
            let a0 = 1 + k / q + k * k
            shelf.b0 = (vh + vb * k / q + k * k) / a0
            shelf.b1 = 2 * (k * k - vh) / a0
            shelf.b2 = (vh - vb * k / q + k * k) / a0
            shelf.a1 = 2 * (k * k - 1) / a0
            shelf.a2 = (1 - k / q + k * k) / a0
        }
        var high = ETBiquad()
        do {
            let f0 = 38.13547087602444, q = 0.5003270373238773
            let k = tan(Double.pi * f0 / rate)
            let a0 = 1 + k / q + k * k
            high.b0 = 1; high.b1 = -2; high.b2 = 1
            high.a1 = 2 * (k * k - 1) / a0
            high.a2 = (1 - k / q + k * k) / a0
        }
        return (shelf, high)
    }
}
