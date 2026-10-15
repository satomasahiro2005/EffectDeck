//  MiniMeters.swift
//  PiP に出す横長の帯（MiniMeters の形）。左から 流れる波形・スペクトラム・ステレオ・レベルと LUFS。
//
//  **SwiftUI を通さない。**PiP は背景でも 30 回/秒描くので、ImageRenderer で
//  SwiftUI の図を組み直すと重い。ここは音の輪（ETMeterTap）から読んだ標本を自分で計り、
//  CoreGraphics でピクセルの器へ直に描く。
//
//  計るもの:
//      波形      10ms ごとのピーク。色は低・中・高域の量（赤・緑・青）。
//      スペクトラム  4096 点の FFT（Hann）。20Hz–20kHz を対数で。落ちるときだけゆっくり。
//      ステレオ    直近 1024 標本の L/R を 45° 回して点で（上が M、横が S）。下に相関。
//      レベル     L/R のピーク（落ちは 24dB/秒、山は 1.5 秒残す）と、BS.1770 の
//                Momentary（400ms）・Short-term（3 秒）LUFS。

import Accelerate
import CoreGraphics
import UIKit

@MainActor
final class ETMiniMeters {

    /// 器の大きさ（ピクセル）。PiP の窓はこの縦横比で開く。
    static let pixelWidth = 1280
    static let pixelHeight = 256

    private var sampleRate: Double = 48000
    private var cursor: UInt64 = 0
    private var scratch = [Float](repeating: 0, count: 2 * 16384)

    // MARK: 波形

    private struct Column { var peak: Float; var low: Float; var mid: Float; var high: Float }
    private static let columnCount = 512
    private var columns = [Column](repeating: Column(peak: 0, low: 0, mid: 0, high: 0), count: columnCount)
    private var columnHead = 0
    private var hopFill = 0
    private var hopPeak: Float = 0
    private var hopLow: Float = 0, hopMid: Float = 0, hopHigh: Float = 0
    private var lowState: Float = 0, highLowState: Float = 0
    private var lowCoeff: Float = 0, highCoeff: Float = 0

    // MARK: スペクトラム

    private static let fftLog2 = 12
    private static let fftSize = 1 << fftLog2
    private var mono = [Float](repeating: 0, count: fftSize)
    private var monoHead = 0
    private let fftSetup: FFTSetup? = vDSP_create_fftsetup(vDSP_Length(fftLog2), FFTRadix(kFFTRadix2))
    private var window = [Float](repeating: 0, count: fftSize)
    private var spectrumDB: [Float] = []

    // MARK: ステレオ

    private static let scopeCount = 1024
    private var scopeL = [Float](repeating: 0, count: scopeCount)
    private var scopeR = [Float](repeating: 0, count: scopeCount)
    private var scopeHead = 0
    private var correlation: Float = 0

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
    private var shortTerm: Double = -.infinity

    init() {
        vDSP_hann_window(&window, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
        configure(rate: 48000)
    }

    deinit {
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    private func configure(rate: Double) {
        sampleRate = rate
        lowCoeff = Float(1 - exp(-2 * Double.pi * 250 / rate))
        highCoeff = Float(1 - exp(-2 * Double.pi * 4000 / rate))
        (kShelf, kHigh) = ETBiquad.kWeighting(rate: rate)
        kStates = [ETBiquadState](repeating: ETBiquadState(), count: 4)
        blocks.removeAll()
        blockFill = 0
        blockSum = 0
    }

    /// 読み始める位置を今にする（前に溜まっていたものを流さない）。
    func reset() {
        _ = ETMeterTap_Read(0, &scratch, 0, &cursor)
    }

    // MARK: - 読む

    func pull(rate: Double) {
        if rate > 0 && rate != sampleRate { configure(rate: rate) }
        let maxFrames = UInt32(scratch.count / 2)
        let n = Int(scratch.withUnsafeMutableBufferPointer {
            ETMeterTap_Read(cursor, $0.baseAddress, maxFrames, &cursor)
        })
        let now = CACurrentMediaTime()
        let dt = Float(now - lastTick)
        lastTick = now

        var blockPeak: [Float] = [0, 0]
        var sumLR: Float = 0, sumLL: Float = 0, sumRR: Float = 0
        let hop = max(1, Int(sampleRate / 100))
        let blockLength = max(1, Int(sampleRate / 10))
        for i in 0..<n {
            let l = scratch[2 * i], r = scratch[2 * i + 1]
            blockPeak[0] = max(blockPeak[0], abs(l))
            blockPeak[1] = max(blockPeak[1], abs(r))
            let m = 0.5 * (l + r)

            // 波形の桶。
            lowState += lowCoeff * (m - lowState)
            highLowState += highCoeff * (m - highLowState)
            let low = lowState, high = m - highLowState, mid = highLowState - lowState
            hopPeak = max(hopPeak, max(abs(l), abs(r)))
            hopLow += low * low
            hopMid += mid * mid
            hopHigh += high * high
            hopFill += 1
            if hopFill >= hop {
                columns[columnHead] = Column(peak: hopPeak, low: hopLow, mid: hopMid, high: hopHigh)
                columnHead = (columnHead + 1) % Self.columnCount
                hopFill = 0
                hopPeak = 0; hopLow = 0; hopMid = 0; hopHigh = 0
            }

            // FFT とステレオの輪。
            mono[monoHead] = m
            monoHead = (monoHead + 1) & (Self.fftSize - 1)
            scopeL[scopeHead] = l
            scopeR[scopeHead] = r
            scopeHead = (scopeHead + 1) % Self.scopeCount
            sumLR += l * r; sumLL += l * l; sumRR += r * r

            // K 特性をかけて 100ms ごとに 2 乗の平均。
            let kl = kHigh.run(kShelf.run(Double(l), &kStates[0]), &kStates[1])
            let kr = kHigh.run(kShelf.run(Double(r), &kStates[2]), &kStates[3])
            blockSum += kl * kl + kr * kr
            blockFill += 1
            if blockFill >= blockLength {
                blocks.append(blockSum / Double(blockLength))
                if blocks.count > 30 { blocks.removeFirst(blocks.count - 30) }
                blockSum = 0
                blockFill = 0
                momentary = Self.loudness(blocks.suffix(4))
                shortTerm = Self.loudness(blocks.suffix(30))
            }
        }

        // 相関は新しく来た分で。来ていなければゆっくり 0 へ。
        if sumLL > 1e-9 && sumRR > 1e-9 {
            let c = sumLR / sqrt(sumLL * sumRR)
            correlation += 0.3 * (c - correlation)
        } else {
            correlation *= 0.9
        }

        for ch in 0..<2 {
            let db = blockPeak[ch] > 0 ? 20 * log10(blockPeak[ch]) : -120
            let fallen = peakDB[ch] - 24 * dt
            peakDB[ch] = max(db, fallen, -120)
            if db >= holdDB[ch] || now > holdUntil[ch] {
                holdDB[ch] = max(db, peakDB[ch])
                holdUntil[ch] = now + 1.5
            }
        }
    }

    private static func loudness(_ values: ArraySlice<Double>) -> Double {
        guard !values.isEmpty else { return -.infinity }
        let mean = values.reduce(0, +) / Double(values.count)
        return mean > 1e-12 ? -0.691 + 10 * log10(mean) : -.infinity
    }

    // MARK: - 描く

    private static let background = UIColor(red: 0.04, green: 0.045, blue: 0.055, alpha: 1).cgColor
    private static let panel = UIColor(red: 0.075, green: 0.083, blue: 0.1, alpha: 1).cgColor
    private static let grid = UIColor(white: 1, alpha: 0.07).cgColor
    private static let label = UIColor(white: 1, alpha: 0.45)
    private static let accent = UIColor(red: 0.35, green: 0.75, blue: 1, alpha: 1)

    /// `context` は上が 0 の向き（呼び手が反転してある）。
    func draw(in context: CGContext) {
        let w = CGFloat(Self.pixelWidth), h = CGFloat(Self.pixelHeight)
        context.setFillColor(Self.background)
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))

        let gap: CGFloat = 8
        let inner = h - 2 * gap
        let stereoWidth = inner
        let levelWidth: CGFloat = 200
        let rest = w - 5 * gap - stereoWidth - levelWidth
        let waveWidth = (rest * 0.5).rounded()
        let spectrumWidth = rest - waveWidth
        var x = gap
        let wave = CGRect(x: x, y: gap, width: waveWidth, height: inner); x += waveWidth + gap
        let spectrum = CGRect(x: x, y: gap, width: spectrumWidth, height: inner); x += spectrumWidth + gap
        let stereo = CGRect(x: x, y: gap, width: stereoWidth, height: inner); x += stereoWidth + gap
        let levels = CGRect(x: x, y: gap, width: levelWidth, height: inner)

        for rect in [wave, spectrum, stereo, levels] {
            context.setFillColor(Self.panel)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil))
            context.fillPath()
        }

        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        drawWaveform(context, wave.insetBy(dx: 6, dy: 6))
        drawSpectrum(context, spectrum.insetBy(dx: 6, dy: 6))
        drawStereo(context, stereo.insetBy(dx: 10, dy: 8))
        drawLevels(context, levels.insetBy(dx: 12, dy: 10))
    }

    private func drawWaveform(_ context: CGContext, _ rect: CGRect) {
        context.saveGState()
        context.clip(to: rect)
        let center = rect.midY
        context.setFillColor(Self.grid)
        context.fill(CGRect(x: rect.minX, y: center, width: rect.width, height: 1))
        let count = min(Int(rect.width / 2), Self.columnCount)
        for k in 0..<count {
            let index = (columnHead - 1 - k + 2 * Self.columnCount) % Self.columnCount
            let column = columns[index]
            guard column.peak > 0.0005 else { continue }
            let total = max(column.low + column.mid + column.high, 1e-12)
            let r = CGFloat(sqrt(column.low / total)), g = CGFloat(sqrt(column.mid / total))
            let b = CGFloat(sqrt(column.high / total))
            let top = max(r, g, b)
            context.setFillColor(red: 0.25 + 0.75 * r / top, green: 0.25 + 0.75 * g / top,
                                 blue: 0.25 + 0.75 * b / top, alpha: 1)
            let half = CGFloat(min(column.peak, 1)) * rect.height / 2
            context.fill(CGRect(x: rect.maxX - CGFloat(k + 1) * 2, y: center - half, width: 2, height: 2 * half))
        }
        context.restoreGState()
    }

    private func drawSpectrum(_ context: CGContext, _ rect: CGRect) {
        guard let fftSetup else { return }
        let n = Self.fftSize
        // 輪を時間順に並べて窓をかける。
        var frame = [Float](repeating: 0, count: n)
        for i in 0..<n { frame[i] = mono[(monoHead + i) & (n - 1)] * window[i] }
        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var power = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                frame.withUnsafeBufferPointer { src in
                    src.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, vDSP_Length(Self.fftLog2), FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(n / 2))
            }
        }
        // zrip は 2 倍で返す。窓の正規化（HANN_NORM で平均 1）と合わせて正弦波の 0dBFS が 0 付近に来るようにする。
        let scale = 1 / Float(n * n)
        let columns = Int(rect.width / 2)
        if spectrumDB.count != columns { spectrumDB = [Float](repeating: -100, count: columns) }
        let binHz = sampleRate / Double(n)
        for c in 0..<columns {
            let f0 = 20 * pow(1000, Double(c) / Double(columns))
            let f1 = 20 * pow(1000, Double(c + 1) / Double(columns))
            let b0 = max(1, Int(f0 / binHz)), b1 = min(n / 2 - 1, max(b0, Int(f1 / binHz)))
            var peak: Float = 0
            if b0 <= b1 { for b in b0...b1 { peak = max(peak, power[b]) } }
            let db = peak > 0 ? 10 * log10(peak * scale) + 6 : -100
            // 上がるときはすぐ、落ちるときはゆっくり。
            spectrumDB[c] = db > spectrumDB[c] ? db : spectrumDB[c] - 1.2
        }

        context.saveGState()
        context.clip(to: rect)
        context.setFillColor(Self.grid)
        for f in [100.0, 1000.0, 10000.0] {
            let gx = rect.minX + CGFloat(log(f / 20) / log(1000)) * rect.width
            context.fill(CGRect(x: gx, y: rect.minY, width: 1, height: rect.height))
        }
        func y(_ db: Float) -> CGFloat {
            let t = CGFloat((min(max(db, -90), 0) + 90) / 90)
            return rect.maxY - t * rect.height
        }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        for c in 0..<columns {
            path.addLine(to: CGPoint(x: rect.minX + CGFloat(c) * 2 + 1, y: y(spectrumDB[c])))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        context.addPath(path)
        context.setFillColor(Self.accent.withAlphaComponent(0.28).cgColor)
        context.fillPath()
        let line = CGMutablePath()
        for c in 0..<columns {
            let p = CGPoint(x: rect.minX + CGFloat(c) * 2 + 1, y: y(spectrumDB[c]))
            if c == 0 { line.move(to: p) } else { line.addLine(to: p) }
        }
        context.addPath(line)
        context.setStrokeColor(Self.accent.cgColor)
        context.setLineWidth(2)
        context.strokePath()
        context.restoreGState()
        write("20", at: CGPoint(x: rect.minX + 2, y: rect.minY + 2))
        write("1k", at: CGPoint(x: rect.minX + rect.width * 2 / 3 + 3, y: rect.minY + 2))
    }

    private func drawStereo(_ context: CGContext, _ rect: CGRect) {
        let barHeight: CGFloat = 8
        let scopeRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width,
                               height: rect.height - barHeight - 8)
        let side = min(scopeRect.width, scopeRect.height)
        let square = CGRect(x: scopeRect.midX - side / 2, y: scopeRect.minY, width: side, height: side)
        context.saveGState()
        context.clip(to: square)
        context.setStrokeColor(Self.grid)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: square.midX, y: square.minY))
        context.addLine(to: CGPoint(x: square.midX, y: square.maxY))
        context.move(to: CGPoint(x: square.minX, y: square.midY))
        context.addLine(to: CGPoint(x: square.maxX, y: square.midY))
        context.strokePath()
        context.setFillColor(Self.accent.withAlphaComponent(0.55).cgColor)
        let radius = side / 2
        for i in 0..<Self.scopeCount {
            let l = CGFloat(scopeL[i]), r = CGFloat(scopeR[i])
            let px = square.midX + (r - l) * 0.7071 * radius
            let py = square.midY - (l + r) * 0.7071 * radius
            context.fill(CGRect(x: px - 1, y: py - 1, width: 2, height: 2))
        }
        context.restoreGState()

        let bar = CGRect(x: rect.minX, y: rect.maxY - barHeight, width: rect.width, height: barHeight)
        context.setFillColor(Self.grid)
        context.fill(bar)
        let c = CGFloat(max(-1, min(1, correlation)))
        let mid = bar.midX
        let end = mid + c * bar.width / 2
        context.setFillColor((c < 0 ? UIColor.systemRed : UIColor.systemGreen).cgColor)
        context.fill(CGRect(x: min(mid, end), y: bar.minY, width: abs(end - mid), height: bar.height))
        context.setFillColor(UIColor(white: 1, alpha: 0.5).cgColor)
        context.fill(CGRect(x: mid - 0.5, y: bar.minY - 2, width: 1, height: bar.height + 4))
    }

    private func drawLevels(_ context: CGContext, _ rect: CGRect) {
        let barWidth: CGFloat = 18
        let meter = CGRect(x: rect.minX, y: rect.minY, width: 2 * barWidth + 6, height: rect.height)
        func y(_ db: Float) -> CGFloat {
            let t = CGFloat((min(max(db, -60), 0) + 60) / 60)
            return meter.maxY - t * meter.height
        }
        for ch in 0..<2 {
            let bx = meter.minX + CGFloat(ch) * (barWidth + 6)
            context.setFillColor(Self.grid)
            context.fill(CGRect(x: bx, y: meter.minY, width: barWidth, height: meter.height))
            let top = y(peakDB[ch])
            // 緑 → 黄（-12）→ 赤（-3）。
            for (from, to, color) in [(Float(-60), Float(-12), UIColor.systemGreen),
                                      (-12, -3, UIColor.systemYellow), (-3, 0, UIColor.systemRed)] {
                let lo = y(from), hi = max(y(to), top)
                guard hi < lo else { continue }
                context.setFillColor(color.cgColor)
                context.fill(CGRect(x: bx, y: hi, width: barWidth, height: lo - hi))
            }
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(x: bx, y: y(holdDB[ch]) - 1, width: barWidth, height: 2))
        }
        let textX = meter.maxX + 14
        let big = UIFont.monospacedDigitSystemFont(ofSize: 34, weight: .semibold)
        write(Self.lufsText(momentary), at: CGPoint(x: textX, y: rect.minY), font: big, color: .white)
        write("M LUFS", at: CGPoint(x: textX, y: rect.minY + 42))
        write(Self.lufsText(shortTerm), at: CGPoint(x: textX, y: rect.minY + 90),
              font: UIFont.monospacedDigitSystemFont(ofSize: 26, weight: .medium), color: UIColor(white: 1, alpha: 0.8))
        write("S LUFS", at: CGPoint(x: textX, y: rect.minY + 124))
        write(String(format: "%.1f dB", max(holdDB[0], holdDB[1])), at: CGPoint(x: textX, y: rect.maxY - 22))
    }

    private static func lufsText(_ value: Double) -> String {
        value.isFinite && value > -70 ? String(format: "%.1f", value) : "—"
    }

    private func write(_ text: String, at point: CGPoint,
                       font: UIFont = .systemFont(ofSize: 16, weight: .medium),
                       color: UIColor = ETMiniMeters.label) {
        (text as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
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
