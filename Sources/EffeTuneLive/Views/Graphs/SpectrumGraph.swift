//  SpectrumGraph.swift
//  スペクトル。横は対数の周波数、縦は dB。棒でも折れ線でも描ける。
//
//  web 版（plugins/analyzer/spectrum_analyzer.js）に合わせてある。
//    表示範囲 20Hz〜40kHz（同 9-10 行）。既定は 20k までにしてある
//    縦の既定は -96 dB（同 22 行 this.dr）
//    bin の周波数は i * sampleRate / fftSize、fftSize は bin 数の 2 倍（同 760 行）
//
//  bin は数千本ある。画面は 300pt しかないので、1pt ごとに最大値だけ残して描く。
//  毎枠 8000 本ぶんの Path を作らない。
//
//  使う側:
//      SpectrumGraph(decibels: current, peaks: held,
//                    bins: .fft(sampleRate: sampleRate))

import SwiftUI

/// bin の番号から周波数への直し方。
enum ETSpectrumBins {
    /// FFT の bin。周波数は i * sampleRate / (2 * bin 数)。
    case fft(sampleRate: Double)
    /// 対数で等間隔に並んでいる列。
    case logSpaced(from: Double, to: Double)
    /// 1 本ずつ周波数が決まっている列。
    case explicit([Double])

    func frequency(_ index: Int, count: Int) -> Double {
        switch self {
        case .fft(let sampleRate):
            guard count > 0 else { return 0 }
            return Double(index) * sampleRate / (2 * Double(count))
        case .logSpaced(let from, let to):
            guard count > 1 else { return from }
            let lo = log10(max(from, 1e-9))
            let hi = log10(max(to, from * 1.000001))
            let t = Double(index) / Double(count - 1)
            return pow(10, lo + t * (hi - lo))
        case .explicit(let table):
            return table.indices.contains(index) ? table[index] : 0
        }
    }
}

struct SpectrumGraph: View {

    enum Style: Equatable {
        case bars
        case line
        /// 折れ線の下を塗る。
        case filled
    }

    /// dB の並び。DSP が dB で出しているならそのまま渡す。
    var decibels: [Float]
    /// ピーク保持の並び（あれば薄い線で重ねる）。
    var peaks: [Float]?
    var bins: ETSpectrumBins
    var frequencyRange: ClosedRange<Double>
    var decibelRange: ClosedRange<Double>
    var style: Style
    var height: CGFloat
    var caption: String?

    @State private var probe: CGPoint?

    init(decibels: [Float],
         peaks: [Float]? = nil,
         bins: ETSpectrumBins,
         frequencyRange: ClosedRange<Double> = 20...20000,
         decibelRange: ClosedRange<Double> = -96...0,
         style: Style = .filled,
         height: CGFloat = ETGraphMetrics.height,
         caption: String? = nil) {
        self.decibels = decibels
        self.peaks = peaks
        self.bins = bins
        self.frequencyRange = frequencyRange
        self.decibelRange = decibelRange
        self.style = style
        self.height = height
        self.caption = caption
    }

    /// 線形の大きさ（振幅）で来た列から。
    static func amplitudes(_ values: [Float], bins: ETSpectrumBins,
                           frequencyRange: ClosedRange<Double> = 20...20000,
                           decibelRange: ClosedRange<Double> = -96...0,
                           style: Style = .filled,
                           height: CGFloat = ETGraphMetrics.height,
                           caption: String? = nil) -> SpectrumGraph {
        SpectrumGraph(decibels: values.map { Float(ETdB.fromAmplitude($0)) },
                      bins: bins, frequencyRange: frequencyRange,
                      decibelRange: decibelRange, style: style,
                      height: height, caption: caption)
    }

    var body: some View {
        GraphCanvas(
            x: .frequency(frequencyRange.lowerBound, frequencyRange.upperBound),
            y: .decibels(decibelRange, step: decibelStep),
            height: height,
            readout: readout,
            caption: caption,
            clipsContent: true,
            draw: { context, plot in
                let columns = columnize(decibels, plot: plot)
                guard !columns.isEmpty else { return }
                let bottom = plot.rect.maxY

                switch style {
                case .bars:
                    var path = Path()
                    for column in columns {
                        let y = plot.y(column.db)
                        guard y < bottom else { continue }
                        path.move(to: CGPoint(x: column.x, y: bottom))
                        path.addLine(to: CGPoint(x: column.x, y: y))
                    }
                    context.stroke(path, with: ETGraphShading.curve, lineWidth: 1)

                case .line, .filled:
                    var path = Path()
                    for (i, column) in columns.enumerated() {
                        let pt = CGPoint(x: column.x, y: plot.y(column.db))
                        if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                    }
                    if style == .filled {
                        var area = path
                        area.addLine(to: CGPoint(x: columns[columns.count - 1].x, y: bottom))
                        area.addLine(to: CGPoint(x: columns[0].x, y: bottom))
                        area.closeSubpath()
                        context.fill(area, with: ETGraphShading.grid)
                    }
                    context.stroke(path, with: ETGraphShading.curve,
                                   style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                }

                // ピーク保持。薄い線で上に重ねる。
                if let peaks, !peaks.isEmpty {
                    let held = columnize(peaks, plot: plot)
                    if held.count > 1 {
                        var path = Path()
                        for (i, column) in held.enumerated() {
                            let pt = CGPoint(x: column.x, y: plot.y(column.db))
                            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                        }
                        context.stroke(path, with: ETGraphShading.muted, lineWidth: 1)
                    }
                }

                // 触った所の縦線。
                if let p = probe {
                    var line = Path()
                    let x = plot.x(Double(p.x))
                    line.move(to: CGPoint(x: x, y: plot.rect.minY))
                    line.addLine(to: CGPoint(x: x, y: plot.rect.maxY))
                    context.stroke(line, with: ETGraphShading.axis,
                                   style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                }
            },
            overlay: { plot in
                // 触って値を読むだけなので、一覧の縦スクロールと同時に効かせる。
                Color.clear
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { touch in
                                let hz = plot.xAxis.clamp(plot.xValue(at: touch.location.x))
                                probe = CGPoint(x: hz, y: decibel(at: hz))
                            }
                            .onEnded { _ in probe = nil })
            })
    }

    // MARK: 中身

    private var decibelStep: Double {
        let span = decibelRange.upperBound - decibelRange.lowerBound
        if span > 72 { return 24 }
        if span > 36 { return 12 }
        return 6
    }

    private struct Column {
        var x: CGFloat
        var db: Double
    }

    /// 1pt ごとに最大値だけ残す。bin は周波数の順に並んでいるので 1 度なめれば足りる。
    private func columnize(_ values: [Float], plot: ETPlot) -> [Column] {
        let count = values.count
        guard count > 0 else { return [] }
        let floorDB = decibelRange.lowerBound
        var out: [Column] = []
        out.reserveCapacity(Int(plot.rect.width) + 2)

        var bucket = Int.min
        var bestDB = floorDB
        var bestX: CGFloat = 0

        for i in 0..<count {
            let hz = bins.frequency(i, count: count)
            guard hz >= frequencyRange.lowerBound, hz <= frequencyRange.upperBound else { continue }
            let x = plot.x(hz)
            guard x.isFinite else { continue }
            let slot = Int(x)
            let db = max(ETdB.finite(Double(values[i]), floor: floorDB), floorDB)
            if slot != bucket {
                if bucket != Int.min { out.append(Column(x: bestX, db: bestDB)) }
                bucket = slot
                bestDB = db
                bestX = x
            } else if db > bestDB {
                bestDB = db
                bestX = x
            }
        }
        if bucket != Int.min { out.append(Column(x: bestX, db: bestDB)) }
        return out
    }

    /// 周波数に一番近い bin の値。bin が周波数の順に並んでいることを当てにしている。
    private func decibel(at hz: Double) -> Double {
        let count = decibels.count
        guard count > 0 else { return decibelRange.lowerBound }
        var bestIndex = 0
        var bestDistance = Double.greatestFiniteMagnitude
        for i in 0..<count {
            let d = abs(bins.frequency(i, count: count) - hz)
            if d < bestDistance {
                bestDistance = d
                bestIndex = i
            } else if d > bestDistance {
                // 周波数は単調に増えるので、離れ始めたら打ち切ってよい。
                break
            }
        }
        return ETdB.finite(Double(decibels[bestIndex]), floor: decibelRange.lowerBound)
    }

    /// 触っている所の周波数と大きさ。図の外（上）に出る。
    private var readout: [ETReadoutItem] {
        guard let p = probe else { return [] }
        return [ETReadoutItem("FREQ", ETFormat.hz(Double(p.x))),
                ETReadoutItem("LEVEL", ETFormat.db(Double(p.y)))]
    }
}
