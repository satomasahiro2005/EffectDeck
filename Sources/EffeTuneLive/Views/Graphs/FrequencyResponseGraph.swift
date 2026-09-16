//  FrequencyResponseGraph.swift
//  周波数特性。横は 20Hz〜20kHz の対数、縦は dB。
//
//  web 版の PEQ（plugins/eq/five_band_peq.js）と同じ形にしてある。
//    格子は 20/50/100/200/500/1k/2k/5k/10k/20k（同 380 行）
//    dB の線は 6 dB ごと（同 394 行 gains）
//    曲線は枠から出ても切らない（同 718 行 gainToY のコメント "NEVER Clamp gain"）
//
//  指で印を掴むと、その値は図の外（上）に出る。指の下は見えないので図には書かない。
//
//  使う側:
//      FrequencyResponseGraph(
//          curves: [ETFrequencyCurve.sampled(id: "sum") { hz in totalGainDB(at: hz) }],
//          markers: bands.map { ETFrequencyMarker(id: $0.index, hz: $0.hz, db: $0.gain,
//                                                 label: "\($0.index + 1)") },
//          onMarkerChanged: { band, hz, db in setBand(band, hz: hz, gain: db) })
//
//  印を渡さなければ曲線だけの図になる（指は受けないので一覧のスクロールを邪魔しない）。

import SwiftUI

// MARK: - 曲線

struct ETFreqPoint {
    var hz: Double
    var db: Double

    init(_ hz: Double, _ db: Double) {
        self.hz = hz
        self.db = db
    }
}

struct ETFrequencyCurve: Identifiable {
    let id: String
    var points: [ETFreqPoint]
    var width: CGFloat
    var dashed: Bool
    /// バンドごとの内訳のように、合成曲線の脇に薄く添えるもの。
    var subdued: Bool

    init(id: String, points: [ETFreqPoint], width: CGFloat = 2,
         dashed: Bool = false, subdued: Bool = false) {
        self.id = id
        self.points = points
        self.width = width
        self.dashed = dashed
        self.subdued = subdued
    }

    /// 対数で等間隔に並んだ dB の列から作る。DSP から並びだけ貰うときはこれ。
    static func logSpaced(id: String, decibels: [Float],
                          from: Double = 20, to: Double = 20000,
                          width: CGFloat = 2, dashed: Bool = false,
                          subdued: Bool = false) -> ETFrequencyCurve {
        let n = decibels.count
        guard n > 1 else {
            return ETFrequencyCurve(id: id, points: [], width: width,
                                    dashed: dashed, subdued: subdued)
        }
        let lo = log10(max(from, 1e-9))
        let hi = log10(max(to, from * 1.000001))
        let points = (0..<n).map { i -> ETFreqPoint in
            let t = Double(i) / Double(n - 1)
            return ETFreqPoint(pow(10, lo + t * (hi - lo)), Double(decibels[i]))
        }
        return ETFrequencyCurve(id: id, points: points, width: width,
                                dashed: dashed, subdued: subdued)
    }

    /// 式から引く。count 点を対数で等間隔に取る。
    static func sampled(id: String, count: Int = 256,
                        from: Double = 20, to: Double = 20000,
                        width: CGFloat = 2, dashed: Bool = false, subdued: Bool = false,
                        magnitude: (Double) -> Double) -> ETFrequencyCurve {
        guard count > 1 else {
            return ETFrequencyCurve(id: id, points: [], width: width,
                                    dashed: dashed, subdued: subdued)
        }
        let lo = log10(max(from, 1e-9))
        let hi = log10(max(to, from * 1.000001))
        let points = (0..<count).map { i -> ETFreqPoint in
            let t = Double(i) / Double(count - 1)
            let hz = pow(10, lo + t * (hi - lo))
            return ETFreqPoint(hz, magnitude(hz))
        }
        return ETFrequencyCurve(id: id, points: points, width: width,
                                dashed: dashed, subdued: subdued)
    }
}

// MARK: - 掴める印

struct ETFrequencyMarker: Identifiable {
    var id: Int
    var hz: Double
    var db: Double
    /// 印の中に出す字。PEQ はバンド番号を入れている。
    var label: String
    var isActive: Bool

    init(id: Int, hz: Double, db: Double, label: String = "", isActive: Bool = true) {
        self.id = id
        self.hz = hz
        self.db = db
        self.label = label
        self.isActive = isActive
    }
}

// MARK: - 本体

struct FrequencyResponseGraph: View {

    var curves: [ETFrequencyCurve]
    var markers: [ETFrequencyMarker]
    var frequencyRange: ClosedRange<Double>
    var decibelRange: ClosedRange<Double>
    var decibelStep: Double
    var height: CGFloat
    var caption: String?
    /// 図に重ねるスペクトラムの tap 番号。nil なら重ねない（既定）。
    ///
    /// 上流はホストのループが段の前後で音を横取りして描いている
    /// （plugins/audio-processor.js:5142,5275）。その口が dsp/include/effetune/abi.h に
    /// 無いので、こちらは隣に置かれた Spectrum Analyzer の tap を借りる。
    /// 探し方は ETSpectrumOverlayFinder、描くのは SpectrumOverlayLayer。
    var spectrumTap: UInt32?
    /// 印を動かしたとき。(印の id, 周波数, dB)。両方が同時に動く。
    var onMarkerChanged: ((Int, Double, Double) -> Void)?
    var onMarkerSelected: ((Int) -> Void)?

    @State private var dragging: Int?
    @State private var dragged: ETFreqPoint?

    init(curves: [ETFrequencyCurve],
         markers: [ETFrequencyMarker] = [],
         frequencyRange: ClosedRange<Double> = 20...20000,
         decibelRange: ClosedRange<Double> = -24...24,
         decibelStep: Double = 6,
         height: CGFloat = ETGraphMetrics.height,
         caption: String? = nil,
         spectrumTap: UInt32? = nil,
         onMarkerChanged: ((Int, Double, Double) -> Void)? = nil,
         onMarkerSelected: ((Int) -> Void)? = nil) {
        self.curves = curves
        self.markers = markers
        self.frequencyRange = frequencyRange
        self.decibelRange = decibelRange
        self.decibelStep = decibelStep
        self.height = height
        self.caption = caption
        self.spectrumTap = spectrumTap
        self.onMarkerChanged = onMarkerChanged
        self.onMarkerSelected = onMarkerSelected
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
                // 掴んでいる間の目印。指の下に細い十字を出しておく。
                if let p = dragged {
                    var cross = Path()
                    let pt = plot.clampedPoint(p.hz, p.db)
                    cross.move(to: CGPoint(x: pt.x, y: plot.rect.minY))
                    cross.addLine(to: CGPoint(x: pt.x, y: plot.rect.maxY))
                    cross.move(to: CGPoint(x: plot.rect.minX, y: pt.y))
                    cross.addLine(to: CGPoint(x: plot.rect.maxX, y: pt.y))
                    context.stroke(cross, with: ETGraphShading.grid,
                                   style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                }
                for curve in curves {
                    guard curve.points.count > 1 else { continue }
                    var path = Path()
                    for (i, p) in curve.points.enumerated() {
                        let pt = plot.point(p.hz, ETdB.finite(p.db, floor: decibelRange.lowerBound - 60))
                        if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                    }
                    let shading = curve.subdued ? ETGraphShading.muted : ETGraphShading.curve
                    context.stroke(path, with: shading,
                                   style: StrokeStyle(lineWidth: curve.width,
                                                      lineCap: .round, lineJoin: .round,
                                                      dash: curve.dashed ? [4, 3] : []))
                }
            },
            overlay: { plot in
                ZStack {
                    // 重ねるスペクトラム。**曲線の上**に出る。
                    // 上流も PEQ の曲線の上に 0.85 で重ねている
                    // （spectrum-overlay.css:15 の z-index: 2）。
                    // Telemetry を観測するのはこの層の中だけ。ここより外で観測すると
                    // 30Hz で body が回り、掴んでいる印と下のつまみが固まる。
                    if let spectrumTap {
                        SpectrumOverlayLayer(tapId: spectrumTap, plot: plot)
                    }

                    // 指を受ける面。印より下に置く（印は当たり判定を持たない）。
                    // 印が無いときは面を置かない。置くと一覧の縦スクロールを食う。
                    if !markers.isEmpty {
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(drag(in: plot))
                    }

                    ForEach(markers) { marker in
                        markerBadge(marker)
                            .position(plot.clampedPoint(marker.hz, marker.db))
                            .allowsHitTesting(false)
                    }
                }
            })
    }

    // MARK: 掴む

    private func drag(in plot: ETPlot) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !markers.isEmpty else { return }
                if dragging == nil {
                    // 掴んだ位置から最も近い印を選ぶ。
                    dragging = nearest(to: value.startLocation, in: plot)?.id
                    if let id = dragging { onMarkerSelected?(id) }
                }
                guard let id = dragging else { return }
                let v = plot.values(at: value.location)
                dragged = ETFreqPoint(v.x, v.y)
                onMarkerChanged?(id, v.x, v.y)
            }
            .onEnded { _ in
                dragging = nil
                dragged = nil
            }
    }

    private func nearest(to location: CGPoint, in plot: ETPlot) -> ETFrequencyMarker? {
        markers.min { a, b in
            squaredDistance(from: location, to: plot.clampedPoint(a.hz, a.db))
                < squaredDistance(from: location, to: plot.clampedPoint(b.hz, b.db))
        }
    }

    /// 比べるだけなので平方根は取らない。
    private func squaredDistance(from a: CGPoint, to b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return dx * dx + dy * dy
    }

    // MARK: 見た目

    private func markerBadge(_ marker: ETFrequencyMarker) -> some View {
        let held = dragging == marker.id
        return Text(marker.label)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(marker.isActive ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .frame(width: 22, height: 22)
            .background(marker.isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                        in: Circle())
            .overlay(Circle().stroke(.tint, lineWidth: held ? 2 : 0).scaleEffect(held ? 1.4 : 1))
    }

    /// 掴んでいる値。図の外（上）に出る。
    private var readout: [ETReadoutItem] {
        guard let p = dragged, let id = dragging else { return [] }
        var items: [ETReadoutItem] = []
        if let marker = markers.first(where: { $0.id == id }), !marker.label.isEmpty {
            items.append(ETReadoutItem("BAND", marker.label))
        }
        items.append(ETReadoutItem("FREQ", ETFormat.hz(p.hz)))
        items.append(ETReadoutItem("GAIN", ETFormat.gain(p.db)))
        return items
    }
}
