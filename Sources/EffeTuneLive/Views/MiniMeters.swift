//  MiniMeters.swift
//  PiP に出す帯（MiniMeters の形）。スペクトログラム・波形・スペアナ・ステレオ・レベル。
//  横長の 1 段（Layout.strip）。
//
//  **見た目は MiniMeters の既定に寄せる。**minimeters.app の宣伝動画と画像、テーマのひな形
//  （_TEMPLATE）から拾った:
//      背景は黒。区画は枠も隙間も無く隣り合わせに切る。字は出さない。
//      スペクトログラム  低い所は暗い紫、上がるほど 紫 → 赤紫 → 橙 → 淡い黄
//      スペアナ         Both の形。量の色の塗りに 172,192,222 の線
//      波形            RGB のモード。低域 0–200Hz が赤、中域 200–2kHz が緑、高域 2kHz– が 50,50,255。
//                     足し合わせて一番強い色を明るさいっぱいにする（よく混ざると白っぽくなる）
//      ステレオ         灰色の菱形の格子に、波形と同じ色の点
//      レベル           172,192,222 の棒（L・R のピークと LUFS）を暗い溝の上に
//
//  **SwiftUI を通さない。**PiP は背景でも 30 回/秒描くので、音の輪（ETMeterTap）から読んだ標本を
//  自分で計り、CoreGraphics でピクセルの器へ直に描く。UIKit にも頼らない（Mac の試し描きで同じ物を動かす）。
//
//  **動かない部分とスペクトログラムは描かず、毎回写す。**背景・スペアナの周波数線・ステレオの格子・
//  レベルの溝は最初に 1 度だけ別の器へ描いておき、スペクトログラムは持っている並びをそのまま、
//  どちらも 1 行ずつ器へ写す。見た目は全部 CoreGraphics で描いた時と同じ（draw の direct: false が基準）。

import Accelerate
import CoreGraphics
import QuartzCore

@MainActor
final class ETMiniMeters {

    /// 器の大きさ（ピクセル）と区画の置き場。PiP の窓は器の縦横比で開く。
    struct Layout {
        let width: Int
        let height: Int
        let spectrogram: CGRect
        let waveform: CGRect
        let spectrum: CGRect
        let stereo: CGRect
        let level: CGRect

        /// iPhone。横長の 1 段（5:1）。左から スペクトログラム・波形・スペアナ・ステレオ・レベル。
        static let strip = Layout(
            width: 1280, height: 256,
            spectrogram: CGRect(x: 0, y: 0, width: 300, height: 256),
            waveform: CGRect(x: 300, y: 0, width: 400, height: 256),
            spectrum: CGRect(x: 700, y: 0, width: 300, height: 256),
            stereo: CGRect(x: 1000, y: 0, width: 216, height: 256),
            level: CGRect(x: 1216, y: 0, width: 64, height: 256))

    }

    let layout: Layout
    private let spectrogramWidth: Int
    private let spectrogramHeight: Int

    private var sampleRate: Double = 48000
    private var cursor: UInt64 = 0
    private var scratch = [Float](repeating: 0, count: 2 * 16384)

    // MARK: 波形

    private struct Column { var peak: Float; var color: (r: Float, g: Float, b: Float) }
    private static let columnCount = 1024
    /// 0 dBFS の高さ（区画の半分に対する割合）。-0.2 dB ぶん（0.5 dB は空きすぎ）。
    private static let waveformHeadroom = CGFloat(pow(10, -0.2 / 20))
    private var columns = [Column](repeating: Column(peak: 0, color: (0, 0, 0)), count: columnCount)
    private var columnHead = 0
    private var hopFill = 0
    private var hopPeak: Float = 0
    private var hopLow: Float = 0, hopMid: Float = 0, hopHigh: Float = 0
    private var lp200: Float = 0, lp2000: Float = 0
    private var coeff200: Float = 0, coeff2000: Float = 0
    /// 直近の桶の色。ステレオの点にも使う。
    private var lastColor: (r: Float, g: Float, b: Float) = (1, 1, 1)

    // MARK: スペクトログラム

    private static let fftLog2 = 12
    private static let fftSize = 1 << fftLog2
    private var mono = [Float](repeating: 0, count: fftSize)
    private var monoHead = 0
    private let fftSetup: FFTSetup? = vDSP_create_fftsetup(vDSP_Length(fftLog2), FFTRadix(kFFTRadix2))
    private var window = [Float](repeating: 0, count: fftSize)
    /// FFT の作業場。毎回作り直さず使い回す（毎回全部書き直すので前の値は残らない）。
    private var fftFrame = [Float](repeating: 0, count: fftSize)
    private var fftReal = [Float](repeating: 0, count: fftSize / 2)
    private var fftImag = [Float](repeating: 0, count: fftSize / 2)
    private var fftPower = [Float](repeating: 0, count: fftSize / 2)
    /// 1 行（1 列）が見る FFT の bin の範囲と、1kHz 軸の傾き。レートが決まれば変わらないので
    /// 毎回 pow / log2 を呼ばず configure で表にしておく。
    private struct Band { let b0: Int; let b1: Int; let tilt: Float }
    private var rowBands: [Band] = []
    private var columnBands: [Band] = []
    /// 区画ぶんのピクセル（RGBA、上が 0）。1 回描くごとに左へ送り、右端に新しい列を足す。
    private var spectrogram: [UInt32]
    /// 1 回で足す列の幅。30 回/秒で 300 ピクセルなら 5 秒。
    private static let spectrogramStep = 2
    /// スペアナの 2 ピクセルごとの値（dB、傾き込み）。上がるときはすぐ、落ちるときはゆっくり。
    private var spectrumDB: [Float]

    // MARK: ステレオ

    private static let scopeCount = 1024
    private var scopeL = [Float](repeating: 0, count: scopeCount)
    private var scopeR = [Float](repeating: 0, count: scopeCount)
    private var scopeColor = [(r: Float, g: Float, b: Float)](repeating: (1, 1, 1), count: scopeCount)
    private var scopeHead = 0

    // MARK: レベルと LUFS

    private var peakDB: [Float] = [-120, -120]
    private var holdDB: [Float] = [-120, -120]
    private var holdUntil: [Double] = [0, 0]
    private var lastTick = CACurrentMediaTime()
    private var kStates = [ETBiquadState](repeating: ETBiquadState(), count: 4)
    private var kShelf = ETBiquad()
    private var kHigh = ETBiquad()
    private var blockFill = 0
    private var blockSum: Double = 0
    private var blocks: [Double] = []
    private var momentary: Double = -.infinity

    init(layout: Layout = .strip) {
        self.layout = layout
        spectrogramWidth = Int(layout.spectrogram.width)
        spectrogramHeight = Int(layout.spectrogram.height)
        spectrogram = [UInt32](repeating: 0xFF000000, count: spectrogramWidth * spectrogramHeight)
        spectrumDB = [Float](repeating: -120, count: Int(layout.spectrum.width) / 2)
        vDSP_hann_window(&window, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
        configure(rate: 48000)
    }

    deinit {
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    private func configure(rate: Double) {
        sampleRate = rate
        coeff200 = Float(1 - exp(-2 * Double.pi * 200 / rate))
        coeff2000 = Float(1 - exp(-2 * Double.pi * 2000 / rate))
        (kShelf, kHigh) = ETBiquad.kWeighting(rate: rate)
        kStates = [ETBiquadState](repeating: ETBiquadState(), count: 4)
        blocks.removeAll()
        blockFill = 0
        blockSum = 0

        let binHz = rate / Double(Self.fftSize)
        let height = spectrogramHeight
        // 下が 20Hz、上が 20kHz の対数。
        rowBands = (0..<height).map { y in
            Self.band(Double(height - 1 - y) / Double(height), Double(height - y) / Double(height), binHz: binHz)
        }
        let columns = spectrumDB.count
        columnBands = (0..<columns).map { c in
            Self.band(Double(c) / Double(columns), Double(c + 1) / Double(columns), binHz: binHz)
        }
    }

    /// 20Hz〜20kHz の対数軸の t0〜t1 が当たる bin の範囲と、1kHz を軸にした 3dB/oct の傾き。
    private static func band(_ t0: Double, _ t1: Double, binHz: Double) -> Band {
        let n = fftSize
        let b0 = max(1, Int(20 * pow(1000, t0) / binHz))
        let b1 = min(n / 2 - 1, max(b0, Int(20 * pow(1000, t1) / binHz)))
        let center = 20 * pow(1000, (t0 + t1) / 2)
        return Band(b0: b0, b1: b1, tilt: Float(3 * log2(center / 1000)))
    }

    /// 読み始める位置を今にする（前に溜まっていたものを流さない）。
    func reset() {
        _ = ETMeterTap_Read(0, &scratch, 0, &cursor)
    }

    // MARK: - 読む

    func pull(rate: Double, now: Double = CACurrentMediaTime()) {
        if rate > 0 && rate != sampleRate { configure(rate: rate) }
        let maxFrames = UInt32(scratch.count / 2)
        let n = Int(scratch.withUnsafeMutableBufferPointer {
            ETMeterTap_Read(cursor, $0.baseAddress, maxFrames, &cursor)
        })
        let dt = Float(now - lastTick)
        lastTick = now

        var peakL: Float = 0, peakR: Float = 0
        let hop = max(1, Int(sampleRate / 100))
        let blockLength = max(1, Int(sampleRate / 10))
        for i in 0..<n {
            let l = scratch[2 * i], r = scratch[2 * i + 1]
            peakL = max(peakL, abs(l))
            peakR = max(peakR, abs(r))
            let m = 0.5 * (l + r)

            // 波形の桶。帯は 200Hz と 2kHz で切る（MiniMeters の RGB のモードと同じ）。
            lp200 += coeff200 * (m - lp200)
            lp2000 += coeff2000 * (m - lp2000)
            let low = lp200, mid = lp2000 - lp200, high = m - lp2000
            hopPeak = max(hopPeak, max(abs(l), abs(r)))
            hopLow += low * low
            hopMid += mid * mid
            hopHigh += high * high
            hopFill += 1
            if hopFill >= hop {
                lastColor = Self.bandColor(low: hopLow, mid: hopMid, high: hopHigh)
                columns[columnHead] = Column(peak: hopPeak, color: lastColor)
                columnHead = (columnHead + 1) % Self.columnCount
                hopFill = 0
                hopPeak = 0; hopLow = 0; hopMid = 0; hopHigh = 0
            }

            mono[monoHead] = m
            monoHead = (monoHead + 1) & (Self.fftSize - 1)
            scopeL[scopeHead] = l
            scopeR[scopeHead] = r
            scopeColor[scopeHead] = lastColor
            scopeHead = (scopeHead + 1) % Self.scopeCount

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

        for ch in 0..<2 {
            let p = ch == 0 ? peakL : peakR
            let db = p > 0 ? 20 * log10(p) : -120
            peakDB[ch] = max(db, peakDB[ch] - 24 * dt, -120)
            if db >= holdDB[ch] || now > holdUntil[ch] {
                holdDB[ch] = max(db, peakDB[ch])
                holdUntil[ch] = now + 1.5
            }
        }
        advanceSpectrogram()
    }

    /// 帯の量から色を作る。低域は赤、中域は緑、高域は 50,50,255 を足し、一番強い所を 1 にする。
    /// 高い帯ほど量が小さいので、足す前に持ち上げる（そのままだとほぼ赤一色になる）。
    private static func bandColor(low: Float, mid: Float, high: Float) -> (r: Float, g: Float, b: Float) {
        let a = sqrt(low), b = 1.0 * sqrt(mid), c = 5.0 * sqrt(high)
        let r = a + 0.196 * c, g = b + 0.196 * c, bl = c
        let top = max(r, g, bl)
        guard top > 1e-9 else { return (1, 1, 1) }
        return (r / top, g / top, bl / top)
    }

    // MARK: - スペクトログラム

    private func advanceSpectrogram() {
        guard let fftSetup else { return }
        let n = Self.fftSize
        let head = monoHead
        fftFrame.withUnsafeMutableBufferPointer { f in
            mono.withUnsafeBufferPointer { m in
                window.withUnsafeBufferPointer { w in
                    for i in 0..<n { f[i] = m[(head + i) & (n - 1)] * w[i] }
                }
            }
        }
        fftReal.withUnsafeMutableBufferPointer { re in
            fftImag.withUnsafeMutableBufferPointer { im in
                fftPower.withUnsafeMutableBufferPointer { pw in
                    var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                    fftFrame.withUnsafeBufferPointer { src in
                        src.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                        }
                    }
                    vDSP_fft_zrip(fftSetup, &split, 1, vDSP_Length(Self.fftLog2), FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, pw.baseAddress!, 1, vDSP_Length(n / 2))
                }
            }
        }
        let power = fftPower
        let scale = 1 / Float(n * n)
        let width = spectrogramWidth, height = spectrogramHeight, step = Self.spectrogramStep
        // 左へ送る。
        spectrogram.withUnsafeMutableBufferPointer { px in
            for y in 0..<height {
                let row = px.baseAddress! + y * width
                memmove(row, row + step, (width - step) * MemoryLayout<UInt32>.size)
            }
        }
        for y in 0..<height {
            let band = rowBands[y]
            var peak: Float = 0
            for b in band.b0...band.b1 { peak = max(peak, power[b]) }
            // 1kHz を軸に 3dB/oct 持ち上げる（音楽は高いほど小さいので、そのままだと下だけ明るい）。
            // 傾きは 6 に先に足さない（Float の足し算は順を変えると 1 つ違うことがあり、色の 1 段が変わる）。
            let db = peak > 0 ? 10 * log10(peak * scale) + 6 + band.tilt : -120
            let pixel = Self.heat(db)
            for x in (width - step)..<width { spectrogram[y * width + x] = pixel }
        }
        // スペアナも同じ FFT から。
        let columns = spectrumDB.count
        for c in 0..<columns {
            let band = columnBands[c]
            var peak: Float = 0
            for b in band.b0...band.b1 { peak = max(peak, power[b]) }
            let db = peak > 0 ? 10 * log10(peak * scale) + 6 + band.tilt : -120
            spectrumDB[c] = db > spectrumDB[c] ? db : max(db, spectrumDB[c] - 1.5)
        }
    }

    /// 量（dB）から色。黒 → 深い紫 → 紫 → 赤紫 → 赤橙 → 橙 → 淡い黄（MiniMeters のスペクトログラムの見え方）。
    /// 音楽の大半（-70〜-45dB）が紫と赤紫に、強い倍音と低音（-35dB より上）だけが橙に来るように置く。
    private static let heatStops: [(t: Float, r: Float, g: Float, b: Float)] = [
        (0.00, 0.02, 0.01, 0.06),
        (0.25, 0.09, 0.03, 0.22),
        (0.45, 0.33, 0.07, 0.50),
        (0.62, 0.78, 0.16, 0.59),
        (0.78, 0.94, 0.27, 0.24),
        (0.90, 1.00, 0.55, 0.16),
        (1.00, 1.00, 0.90, 0.59),
    ]

    private static func heat(_ db: Float) -> UInt32 {
        let t = max(0, min(1, (db + 84) / 78))
        var i = 1
        while i < heatStops.count - 1 && heatStops[i].t < t { i += 1 }
        let lo = heatStops[i - 1], hi = heatStops[i]
        let f = (t - lo.t) / max(hi.t - lo.t, 1e-6)
        return pack(lo.r + (hi.r - lo.r) * f, lo.g + (hi.g - lo.g) * f, lo.b + (hi.b - lo.b) * f)
    }

    /// 器の並び（BGRA、little endian で 32bit に読むと ARGB）に合わせて詰める。
    private static func pack(_ r: Float, _ g: Float, _ b: Float) -> UInt32 {
        func byte(_ v: Float) -> UInt32 { UInt32(max(0, min(255, (v * 255).rounded()))) }
        return 0xFF000000 | byte(r) << 16 | byte(g) << 8 | byte(b)
    }

    // MARK: - 描く

    private static let grid = CGColor(red: 70 / 255, green: 74 / 255, blue: 82 / 255, alpha: 1)
    private static let meter = CGColor(red: 172 / 255, green: 192 / 255, blue: 222 / 255, alpha: 1)
    private static let groove = CGColor(red: 24 / 255, green: 26 / 255, blue: 30 / 255, alpha: 1)
    private static let deviceRGB = CGColorSpaceCreateDeviceRGB()
    /// 器と同じ並び（BGRA、premultipliedFirst・little endian）。
    private static let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue

    /// 動かない部分（背景・周波数線・ステレオの格子・レベルの溝）を描いた器。最初に 1 度だけ作る。
    /// 格子の斜めの線と溝の縁はアンチエイリアスがかかって描くのがいちばん重いので、毎回描かず写す。
    private var backdrop: CGContext?

    /// `context` は上が 0 の向き（呼び手が反転してある）。器は BGRA（premultipliedFirst・little endian）。
    /// `direct` が false なら、動かない部分もスペクトログラムも毎回 CoreGraphics で描く
    /// （写す道の結果を比べるときの基準）。
    /// 戻り値は写す道を通ったか。器が想定の形でないと黙って全部描く道に落ちて遅くなるので、
    /// 試験（MiniMetersTests）がこの値で「PiP の器で写す道を通る」ことを見張る。
    @discardableResult
    func draw(in context: CGContext, direct: Bool = true) -> Bool {
        let copied = direct && copyBackdrop(into: context)
        if !copied {
            drawBackdrop(context)
            drawSpectrogram(context, layout.spectrogram)
        }
        drawWaveform(context, layout.waveform)
        drawSpectrum(context, layout.spectrum)
        drawStereo(context, layout.stereo)
        drawLevels(context, layout.level)
        return copied
    }

    /// 動かない部分を、黒の下地 → 周波数線 → ステレオの格子 → 溝の順に描く。
    /// 区画どうしは重ならないので、あとから描く動く部分との順は見た目に響かない。
    private func drawBackdrop(_ context: CGContext) {
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(layout.width), height: CGFloat(layout.height)))
        drawSpectrumGrid(context, layout.spectrum)
        drawStereoGrid(context, layout.stereo)
        drawLevelGrooves(context, layout.level)
    }

    private func makeBackdrop() -> CGContext? {
        guard let made = CGContext(data: nil, width: layout.width, height: layout.height,
                                   bitsPerComponent: 8, bytesPerRow: layout.width * 4,
                                   space: Self.deviceRGB, bitmapInfo: Self.bitmapInfo) else { return nil }
        // 呼び手と同じ向き（上を 0 に）にして描く。
        made.translateBy(x: 0, y: CGFloat(layout.height))
        made.scaleBy(x: 1, y: -1)
        drawBackdrop(made)
        return made
    }

    /// 動かない部分とスペクトログラムを器へ 1 行ずつ写す。器が想定の形（BGRA・反転済み・同じ大きさ）で
    /// なければ何もせず false を返す（呼び手は全部描く）。**器へ何か描く前に呼ぶ。**
    private func copyBackdrop(into context: CGContext) -> Bool {
        guard let base = context.data,
              context.width == layout.width, context.height == layout.height,
              context.bitsPerComponent == 8, context.bitsPerPixel == 32,
              context.alphaInfo == .premultipliedFirst,
              context.bitmapInfo.intersection(.byteOrderMask) == .byteOrder32Little,
              let space = context.colorSpace, CFEqual(space, Self.deviceRGB),
              context.ctm == CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(layout.height)),
              layout.spectrogram == layout.spectrogram.integral else { return false }
        let x0 = Int(layout.spectrogram.minX), y0 = Int(layout.spectrogram.minY)
        guard x0 >= 0, y0 >= 0,
              x0 + spectrogramWidth <= layout.width, y0 + spectrogramHeight <= layout.height else { return false }
        if backdrop == nil { backdrop = makeBackdrop() }
        guard let made = backdrop, let from = made.data else { return false }
        // 器の行は詰め物が入ることがあるので、行の長さは器のものを使う。
        let dstRow = context.bytesPerRow, srcRow = made.bytesPerRow
        for y in 0..<layout.height {
            memcpy(base + y * dstRow, from + y * srcRow, layout.width * 4)
        }
        // 反転した向きでは、スペクトログラムの行 0 が器の上の行に来る（描いた時と同じ）。並びは最初から BGRA。
        let width = spectrogramWidth
        spectrogram.withUnsafeBytes { px in
            for y in 0..<spectrogramHeight {
                memcpy(base + (y0 + y) * dstRow + x0 * 4, px.baseAddress! + y * width * 4, width * 4)
            }
        }
        return true
    }

    /// 全部 CoreGraphics で描く道だけが使う。写す道では copyBackdrop が代わりをする。
    private func drawSpectrogram(_ context: CGContext, _ rect: CGRect) {
        let width = spectrogramWidth, height = spectrogramHeight
        let image: CGImage? = spectrogram.withUnsafeBytes { bytes in
            guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                           bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                                    | CGBitmapInfo.byteOrder32Little.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
        guard let image else { return }
        // 呼び手が上下を反転しているので、絵は反転し直して置く（行 0 を上に）。
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        context.restoreGState()
    }

    /// スペアナの後ろの 10 刻みの周波数の細い線。
    private func drawSpectrumGrid(_ context: CGContext, _ rect: CGRect) {
        context.saveGState()
        context.clip(to: rect)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.07))
        var decade = 10.0
        while decade < 20000 {
            for k in 1...9 {
                let f = decade * Double(k)
                guard f >= 20 && f <= 20000 else { continue }
                let gx = rect.minX + CGFloat(log(f / 20) / log(1000)) * rect.width
                context.fill(CGRect(x: gx.rounded(), y: rect.minY, width: 1, height: rect.height))
            }
            decade *= 10
        }
        context.restoreGState()
    }

    /// MiniMeters の Both の形。塗りは列ごとに量の色（スペクトログラムと同じ並び）、上に 172,192,222 の線。
    private func drawSpectrum(_ context: CGContext, _ rect: CGRect) {
        context.saveGState()
        context.clip(to: rect)
        func y(_ db: Float) -> CGFloat {
            let t = CGFloat((min(max(db, -84), -6) + 84) / 78)
            return rect.maxY - t * rect.height
        }
        let columns = spectrumDB.count
        let line = CGMutablePath()
        for c in 0..<columns {
            let top = y(spectrumDB[c])
            let x = rect.minX + CGFloat(c) * 2
            // 高さ 0 の塗りは何も描かない。
            if top < rect.maxY {
                let color = Self.heat(spectrumDB[c])
                context.setFillColor(red: CGFloat((color >> 16) & 0xFF) / 255,
                                     green: CGFloat((color >> 8) & 0xFF) / 255,
                                     blue: CGFloat(color & 0xFF) / 255, alpha: 1)
                context.fill(CGRect(x: x, y: top, width: 2, height: rect.maxY - top))
            }
            let p = CGPoint(x: x + 1, y: top)
            if c == 0 { line.move(to: p) } else { line.addLine(to: p) }
        }
        context.addPath(line)
        context.setStrokeColor(Self.meter)
        context.setLineWidth(2)
        context.setLineJoin(.round)
        context.strokePath()
        context.restoreGState()
    }

    private func drawWaveform(_ context: CGContext, _ rect: CGRect) {
        let center = rect.midY
        let count = min(Int(rect.width), Self.columnCount)
        for k in 0..<count {
            let column = columns[(columnHead - 1 - k + 2 * Self.columnCount) % Self.columnCount]
            // 0 dBFS を区画いっぱいにせず 0.2 dB ぶん空ける。音圧の高い曲はほぼ 0 dBFS に張り付き、
            // いっぱいだと上下が切れて見える（本人「0.5dbくらいだけ開けれる？」）。
            let half = CGFloat(min(column.peak, 1)) * Self.waveformHeadroom * rect.height / 2
            guard half >= 0.5 else { continue }
            context.setFillColor(red: CGFloat(column.color.r), green: CGFloat(column.color.g),
                                 blue: CGFloat(column.color.b), alpha: 1)
            context.fill(CGRect(x: rect.maxX - CGFloat(k + 1), y: center - half, width: 1, height: 2 * half))
        }
    }

    /// 菱形が 2 重と、縦横の線と、L・R の向きの線（MiniMeters の格子）。
    private func drawStereoGrid(_ context: CGContext, _ rect: CGRect) {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2 - 4
        context.saveGState()
        context.setStrokeColor(Self.grid)
        context.setLineWidth(2)
        for scale in [1.0, 0.5] as [CGFloat] {
            let r = radius * scale
            context.move(to: CGPoint(x: c.x, y: c.y - r))
            context.addLine(to: CGPoint(x: c.x + r, y: c.y))
            context.addLine(to: CGPoint(x: c.x, y: c.y + r))
            context.addLine(to: CGPoint(x: c.x - r, y: c.y))
            context.closePath()
        }
        context.move(to: CGPoint(x: c.x, y: c.y - radius))
        context.addLine(to: CGPoint(x: c.x, y: c.y + radius))
        context.move(to: CGPoint(x: c.x - radius, y: c.y))
        context.addLine(to: CGPoint(x: c.x + radius, y: c.y))
        context.move(to: CGPoint(x: c.x - radius / 2, y: c.y - radius / 2))
        context.addLine(to: CGPoint(x: c.x + radius / 2, y: c.y + radius / 2))
        context.move(to: CGPoint(x: c.x + radius / 2, y: c.y - radius / 2))
        context.addLine(to: CGPoint(x: c.x - radius / 2, y: c.y + radius / 2))
        context.strokePath()
        context.restoreGState()
    }

    private func drawStereo(_ context: CGContext, _ rect: CGRect) {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2 - 4
        context.saveGState()
        context.clip(to: rect)
        // 直前と同じ色なら塗りの色を入れ直さない（NaN から始めて最初は必ず入れる）。
        var lastR = Float.nan, lastG = Float.nan, lastB = Float.nan
        for i in 0..<Self.scopeCount {
            let l = CGFloat(scopeL[i]), r = CGFloat(scopeR[i])
            let px = c.x + (r - l) * 0.7071 * radius
            let py = c.y - (l + r) * 0.7071 * radius
            // 切り取りの外に丸ごと出た点は何も描かない（縁のぼかしが届く 1 ピクセルぶんは余裕を見る）。
            if px + 3 < rect.minX || px - 3 > rect.maxX || py + 3 < rect.minY || py - 3 > rect.maxY { continue }
            let color = scopeColor[i]
            if color.r != lastR || color.g != lastG || color.b != lastB {
                context.setFillColor(red: CGFloat(color.r), green: CGFloat(color.g), blue: CGFloat(color.b), alpha: 1)
                lastR = color.r; lastG = color.g; lastB = color.b
            }
            context.fillEllipse(in: CGRect(x: px - 2, y: py - 2, width: 4, height: 4))
        }
        context.restoreGState()
    }

    /// 溝と棒の置き場（x）。浮動小数の足し順を変えると 1 ピクセルずれることがあるので、この順のまま。
    /// 幅は 64 ピクセルの区画のときの大きさ。区画が広ければ同じ割合で太くする。
    private func levelSlots(_ rect: CGRect)
        -> (thin: CGFloat, wide: CGFloat, left: CGFloat, right: CGFloat, lufs: CGFloat) {
        let k = max(1, rect.width / 64)
        let thin = 10 * k, wide = 16 * k, gap = 3 * k, apart = 8 * k
        let total = 2 * thin + gap + apart + wide
        var x = rect.midX - total / 2
        let left = x
        x += thin + gap
        let right = x
        x += thin + gap
        x += apart - gap
        return (thin, wide, left, right, x)
    }

    private func drawLevelGrooves(_ context: CGContext, _ rect: CGRect) {
        let slots = levelSlots(rect)
        context.setFillColor(Self.groove)
        context.fill(CGRect(x: slots.left, y: rect.minY, width: slots.thin, height: rect.height))
        context.fill(CGRect(x: slots.right, y: rect.minY, width: slots.thin, height: rect.height))
        context.fill(CGRect(x: slots.lufs, y: rect.minY, width: slots.wide, height: rect.height))
    }

    private func drawLevels(_ context: CGContext, _ rect: CGRect) {
        // L・R のピーク（細い 2 本）と LUFS（太い 1 本）。MiniMeters の Peak/LUFS と同じ並び。溝は背景に描いてある。
        let slots = levelSlots(rect)
        func y(_ db: Double) -> CGFloat {
            let t = CGFloat((min(max(db, -60), 0) + 60) / 60)
            return rect.maxY - t * rect.height
        }
        context.setFillColor(Self.meter)
        for ch in 0..<2 {
            let x = ch == 0 ? slots.left : slots.right
            let top = y(Double(peakDB[ch]))
            context.fill(CGRect(x: x, y: top, width: slots.thin, height: rect.maxY - top))
            context.fill(CGRect(x: x, y: y(Double(holdDB[ch])) - 1, width: slots.thin, height: 2))
        }
        if momentary.isFinite {
            let top = y(momentary)
            context.fill(CGRect(x: slots.lufs, y: top, width: slots.wide, height: rect.maxY - top))
        }
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
