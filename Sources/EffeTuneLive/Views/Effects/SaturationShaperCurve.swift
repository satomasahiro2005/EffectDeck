//  SaturationShaperCurve.swift
//  歪み系 4 つ（Saturation / Hard Clipping / Harmonic Distortion / Dynamic Saturation）が
//  共通で使う伝達曲線。ここは描く土台だけで、曲線の式は各エフェクトが渡す。
//
//  なぜ TransferCurveGraph を使わないか:
//    あちらは入出力とも dB の軸を前提にしていて、上に出す Δ を必ず ETFormat.gain（dB）で書く。
//    こちらの 4 つは web 版と同じく線形の振幅 -1..1 で描く必要がある。
//    bias を持つ曲線は上下で形が違うので、dB の軸だと片側しか見えない。
//    それで GraphCanvas（土台）の上に自分で引いている。格子・塗り・触った所の出し方は
//    TransferCurveGraph と同じ作りに揃えてある。
//
//  軸の取り方は web 版の canvas と同じ。
//    plugins/saturation/saturation.js:202-206  x = (i/width)*2 - 1、y も -1..1 を画面へ
//  web 版は格子の ±0.5 に "-6dB" と書いているが、ここでは振幅の数字を出し、
//  dB は触ったときの GAIN として出す（同じ軸に -6dB が 2 つ並ぶと読みにくいため）。

import SwiftUI
import Foundation

struct SaturationShaperCurve: View {

    /// 入力（線形の振幅、-1..1）に対する出力。単位は入力と同じ。
    var shape: (Double) -> Double
    /// 折れる所。その高さに薄い横線を引き、曲線の標本にもその x を足して角を丸めない。
    /// Hard Clipping のしきい値がこれ。
    var knees: [Double]
    var caption: String?
    var height: CGFloat

    /// 触っている入力。指を離すと nil に戻る。
    @State private var probe: Double?

    /// 横に取る標本の数。390pt 幅ならこれで階段に見えない。
    private static let sampleCount = 161

    init(shape: @escaping (Double) -> Double,
         knees: [Double] = [],
         caption: String? = nil,
         height: CGFloat = ETGraphMetrics.height) {
        self.shape = shape
        self.knees = knees
        self.caption = caption
        self.height = height
    }

    var body: some View {
        // 描く側の閉包へ self ごと渡さないよう、要るものだけ控える。
        let shape = self.shape
        let knees = self.knees
        let touched = self.probe
        let points = Self.samples(shape, knees: knees)

        return GraphCanvas(
            x: Self.amplitudeAxis,
            y: Self.amplitudeAxis,
            height: height,
            insets: ETGraphInsets(leading: 30, trailing: 8, top: 6, bottom: 14),
            readout: readout,
            caption: caption,
            clipsContent: true,
            draw: { context, plot in
                // 素通しの線。歪みがどちらへ曲がっているかはこれと比べて見る。
                var unity = Path()
                unity.move(to: plot.point(-1, -1))
                unity.addLine(to: plot.point(1, 1))
                context.stroke(unity, with: ETGraphShading.grid,
                               style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                // 折れる高さ。
                for level in knees {
                    let py = plot.y(level)
                    guard py >= plot.rect.minY, py <= plot.rect.maxY else { continue }
                    var line = Path()
                    line.move(to: CGPoint(x: plot.rect.minX, y: py))
                    line.addLine(to: CGPoint(x: plot.rect.maxX, y: py))
                    context.stroke(line, with: ETGraphShading.muted,
                                   style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                }

                // 曲線。値が取れなかった所では線を切る。
                var curve = Path()
                var started = false
                for p in points {
                    guard p.y.isFinite else {
                        started = false
                        continue
                    }
                    let pt = plot.point(Double(p.x), Double(p.y))
                    if started {
                        curve.addLine(to: pt)
                    } else {
                        curve.move(to: pt)
                        started = true
                    }
                }
                context.stroke(curve, with: ETGraphShading.curve,
                               style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                // 触っている所。指の下は見えないので、値そのものは図の上（readout）に出る。
                if let input = touched {
                    let out = shape(input)
                    guard out.isFinite else { return }
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
                // 読むだけなので、一覧の縦スクロールと同時に効かせる。
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

    // MARK: 軸

    /// 線形の振幅。0 の線だけ濃くする。
    private static let amplitudeAxis = ETAxis(
        scale: .linear, lower: -1, upper: 1,
        ticks: [ETAxisTick(-1.0, "-1.0"),
                ETAxisTick(-0.5, "-0.5"),
                ETAxisTick(0.0, "0", emphasized: true),
                ETAxisTick(0.5, "0.5"),
                ETAxisTick(1.0, "1.0")])

    // MARK: 標本

    private static func samples(_ shape: (Double) -> Double, knees: [Double]) -> [CGPoint] {
        var xs = (0..<sampleCount).map {
            -1.0 + 2.0 * Double($0) / Double(sampleCount - 1)
        }
        // 角のちょうどその点を通らせる。入れないと折れ目が丸く見える。
        for knee in knees where knee > -1 && knee < 1 {
            xs.append(knee)
        }
        xs.sort()
        return xs.map { x in
            let y = shape(x)
            // 枠の外へ行っても座標は暴れさせない（軸は ±1、はみ出しは切って見せる）。
            return CGPoint(x: x, y: y.isFinite ? min(max(y, -8), 8) : Double.nan)
        }
    }

    // MARK: 上に出す値

    private var readout: [ETReadoutItem] {
        guard let input = probe else { return [] }
        let out = shape(input)
        guard out.isFinite else { return [ETReadoutItem("IN", ETFormat.number(input))] }
        var items = [ETReadoutItem("IN", ETFormat.number(input)),
                     ETReadoutItem("OUT", ETFormat.number(out))]
        // 0 のそばは比が意味を持たないので出さない。
        if abs(input) > 0.02, abs(out) > 1e-6 {
            items.append(ETReadoutItem("GAIN", ETFormat.gain(20 * log10(abs(out) / abs(input)))))
        }
        return items
    }
}

// MARK: - 値の取り出し

// 他の担当と名前がぶつからないよう、外へ出す名前はこの型ひとつに寄せてある。
extension SaturationShaperCurve {

    /// node.values から key で引く。offset はカタログ（EffectCatalog.swift）が持っている。
    @MainActor
    static func value(_ node: EffeTuneDSP.Node, _ key: String) -> Double {
        guard let param = node.spec.params.first(where: { $0.key == key }) else { return 0 }
        guard node.values.indices.contains(param.offset) else { return Double(param.defaultValue) }
        return Double(node.values[param.offset])
    }

    /// 選択肢の番号。Hard Clipping の mode（0=both, 1=positive, 2=negative）がこれ。
    @MainActor
    static func choice(_ node: EffeTuneDSP.Node, _ key: String) -> Int {
        Int(value(node, key).rounded())
    }
}
