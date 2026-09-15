//  TransferCurveGraph.swift
//  入力に対して出力がどうなるかの曲線。Compressor や Saturation が出しているもの。
//
//  web 版の Compressor（plugins/dynamics/compressor.js:664 以降）は
//  -48/-36/-24/-12 dB に格子を引いて、入出力とも dB の線形軸で描いている。
//  縦横の範囲は呼ぶ側が決める（dB でも線形でもよい）。
//
//  縦横の範囲を同じにすると、素通しの線が 45 度になる。
//  触った所の入力と出力は、図の外（上）に出る。
//
//  使う側:
//      TransferCurveGraph(
//          curve: .sampled(id: "comp", from: -60, to: 0) { input in compressed(input) },
//          operatingPoint: CGPoint(x: inputDB, y: inputDB - reductionDB))

import SwiftUI

struct ETTransferCurve: Identifiable {
    let id: String
    /// x が入力、y が出力。単位は軸に合わせる（dB なら dB）。
    var points: [CGPoint]
    var width: CGFloat
    var dashed: Bool
    var subdued: Bool

    init(id: String, points: [CGPoint], width: CGFloat = 2,
         dashed: Bool = false, subdued: Bool = false) {
        self.id = id
        self.points = points
        self.width = width
        self.dashed = dashed
        self.subdued = subdued
    }

    /// 入力の並びに対する出力の並びから作る。DSP から出力側だけ貰うときはこれ。
    static func values(id: String, outputs: [Float],
                       from: Double, to: Double,
                       width: CGFloat = 2, dashed: Bool = false,
                       subdued: Bool = false) -> ETTransferCurve {
        let n = outputs.count
        guard n > 1 else { return ETTransferCurve(id: id, points: [], width: width) }
        let points = (0..<n).map { i -> CGPoint in
            let t = Double(i) / Double(n - 1)
            return CGPoint(x: from + t * (to - from), y: Double(outputs[i]))
        }
        return ETTransferCurve(id: id, points: points, width: width,
                               dashed: dashed, subdued: subdued)
    }

    /// 式から引く。
    static func sampled(id: String, count: Int = 128, from: Double, to: Double,
                        width: CGFloat = 2, dashed: Bool = false, subdued: Bool = false,
                        output: (Double) -> Double) -> ETTransferCurve {
        guard count > 1 else { return ETTransferCurve(id: id, points: [], width: width) }
        let points = (0..<count).map { i -> CGPoint in
            let t = Double(i) / Double(count - 1)
            let x = from + t * (to - from)
            return CGPoint(x: x, y: output(x))
        }
        return ETTransferCurve(id: id, points: points, width: width,
                               dashed: dashed, subdued: subdued)
    }

    /// x を手前から順に見て、与えた入力に対する出力を線で結んだ値として返す。
    func output(at input: Double) -> Double? {
        guard points.count > 1 else { return points.first.map { Double($0.y) } }
        if input <= Double(points[0].x) { return Double(points[0].y) }
        if input >= Double(points[points.count - 1].x) { return Double(points[points.count - 1].y) }
        for i in 1..<points.count {
            let a = points[i - 1]
            let b = points[i]
            if input <= Double(b.x) {
                let span = Double(b.x - a.x)
                guard span > 0 else { return Double(b.y) }
                let t = (input - Double(a.x)) / span
                return Double(a.y) + t * Double(b.y - a.y)
            }
        }
        return Double(points[points.count - 1].y)
    }
}

struct TransferCurveGraph: View {

    var curves: [ETTransferCurve]
    var inputRange: ClosedRange<Double>
    var outputRange: ClosedRange<Double>
    var tickStep: Double
    /// 入出力が等しい線（45 度）を薄く引くか。
    var showsUnity: Bool
    /// いま鳴っている所を丸で出す。x が入力、y が出力。
    var operatingPoint: CGPoint?
    var unit: String
    var height: CGFloat
    var caption: String?

    @State private var probe: Double?

    init(curves: [ETTransferCurve],
         inputRange: ClosedRange<Double> = -60...0,
         outputRange: ClosedRange<Double> = -60...0,
         tickStep: Double = 12,
         showsUnity: Bool = true,
         operatingPoint: CGPoint? = nil,
         unit: String = "dB",
         height: CGFloat = ETGraphMetrics.height,
         caption: String? = nil) {
        self.curves = curves
        self.inputRange = inputRange
        self.outputRange = outputRange
        self.tickStep = tickStep
        self.showsUnity = showsUnity
        self.operatingPoint = operatingPoint
        self.unit = unit
        self.height = height
        self.caption = caption
    }

    /// 1 本だけ渡すとき。
    init(curve: ETTransferCurve,
         inputRange: ClosedRange<Double> = -60...0,
         outputRange: ClosedRange<Double> = -60...0,
         tickStep: Double = 12,
         showsUnity: Bool = true,
         operatingPoint: CGPoint? = nil,
         unit: String = "dB",
         height: CGFloat = ETGraphMetrics.height,
         caption: String? = nil) {
        self.init(curves: [curve], inputRange: inputRange, outputRange: outputRange,
                  tickStep: tickStep, showsUnity: showsUnity, operatingPoint: operatingPoint,
                  unit: unit, height: height, caption: caption)
    }

    var body: some View {
        GraphCanvas(
            x: axis(inputRange),
            y: axis(outputRange),
            height: height,
            readout: readout,
            caption: caption,
            clipsContent: true,
            draw: { context, plot in
                if showsUnity {
                    // 入力＝出力の線。素通しの位置が一目で分かる。
                    let lo = max(inputRange.lowerBound, outputRange.lowerBound)
                    let hi = min(inputRange.upperBound, outputRange.upperBound)
                    var unity = Path()
                    unity.move(to: plot.point(lo, lo))
                    unity.addLine(to: plot.point(hi, hi))
                    context.stroke(unity, with: ETGraphShading.grid,
                                   style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }

                for curve in curves {
                    guard curve.points.count > 1 else { continue }
                    var path = Path()
                    for (i, p) in curve.points.enumerated() {
                        let pt = plot.point(Double(p.x), Double(p.y))
                        if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                    }
                    context.stroke(path,
                                   with: curve.subdued ? ETGraphShading.muted : ETGraphShading.curve,
                                   style: StrokeStyle(lineWidth: curve.width,
                                                      lineCap: .round, lineJoin: .round,
                                                      dash: curve.dashed ? [4, 3] : []))
                }

                if let op = operatingPoint {
                    let pt = plot.clampedPoint(Double(op.x), Double(op.y))
                    context.fill(Path(ellipseIn: CGRect(x: pt.x - 4, y: pt.y - 4,
                                                        width: 8, height: 8)),
                                 with: ETGraphShading.curve)
                }

                // 指で触った所。縦線と、曲線の上の丸。
                if let input = probe, let out = output(at: input) {
                    let pt = plot.clampedPoint(input, out)
                    var line = Path()
                    line.move(to: CGPoint(x: pt.x, y: plot.rect.minY))
                    line.addLine(to: CGPoint(x: pt.x, y: plot.rect.maxY))
                    context.stroke(line, with: ETGraphShading.grid,
                                   style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    context.stroke(Path(ellipseIn: CGRect(x: pt.x - 5, y: pt.y - 5,
                                                          width: 10, height: 10)),
                                   with: ETGraphShading.curve, lineWidth: 2)
                }
            },
            overlay: { plot in
                // 触って値を読むだけなので、一覧の縦スクロールと同時に効かせる。
                Color.clear
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { touch in
                                probe = plot.xAxis.clamp(plot.xValue(at: touch.location.x))
                            }
                            .onEnded { _ in probe = nil })
            })
    }

    private func axis(_ range: ClosedRange<Double>) -> ETAxis {
        if unit == "dB" {
            return ETAxis.decibels(range, step: tickStep)
        }
        return ETAxis.linear(range, ticks: ticks(range))
    }

    private func ticks(_ range: ClosedRange<Double>) -> [Double] {
        guard tickStep > 0 else { return [] }
        var out: [Double] = []
        var v = (range.lowerBound / tickStep).rounded(.up) * tickStep
        while v <= range.upperBound + 0.0001 {
            out.append(v)
            v += tickStep
        }
        return out
    }

    private func output(at input: Double) -> Double? {
        for curve in curves where !curve.subdued {
            if let v = curve.output(at: input) { return v }
        }
        return curves.first?.output(at: input)
    }

    /// 触っている所の入出力。図の外（上）に出る。
    private var readout: [ETReadoutItem] {
        guard let input = probe else { return [] }
        var items = [ETReadoutItem("IN", value(input))]
        if let out = output(at: input) {
            items.append(ETReadoutItem("OUT", value(out)))
            items.append(ETReadoutItem("Δ", ETFormat.gain(out - input)))
        }
        return items
    }

    private func value(_ v: Double) -> String {
        unit.isEmpty ? ETFormat.number(v) : "\(ETFormat.number(v)) \(unit)"
    }
}
