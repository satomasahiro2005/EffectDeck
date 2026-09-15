//  StereoMeterView.swift
//  Stereo Meter。ゴニオメーター（L/R のリサージュ）と、相関・左右バランス・L/R のピーク。
//
//  テレメトリ: ETFrameType.stereoField = 6、formatVersion 2
//  （kernel.cpp:15-16 の kTapStereoField / kTelemetryVersion、
//    stereo_meter.js:1-2 の STEREO_FIELD_TAP_FRAME / _TELEMETRY_VERSION）
//
//  ペイロードの並び。dsp/plugins/analyzer/stereo_meter/kernel.cpp:344-389 が書き、
//  plugins/analyzer/stereo_meter.js:326-396 が同じ位置を読んでいる:
//      0                      f32 sampleRate      kernel.cpp:348 / stereo_meter.js:341
//      4                      u16 sampleCount     kernel.cpp:349 / stereo_meter.js:342
//      6                      u16 sampleFlags     kernel.cpp:350 / stereo_meter.js:343
//                                                 bit0 = 取りこぼし（kernel.cpp:27）
//      8 + i*8                f32 x = R - L       kernel.cpp:362 / stereo_meter.js:358
//      12 + i*8               f32 y = L + R       kernel.cpp:363 / stereo_meter.js:359
//      env  = 8 + n*8         f32 × 360           角度ごとのピーク（kernel.cpp:367-371）
//                                                 添字は度。角度は -atan2(y, x)（kernel.cpp:178）
//      stat = env + 1440      f32 correlation     kernel.cpp:385 / stereo_meter.js:375
//      stat + 4               f32 balance         10log10(ΣR²) - 10log10(ΣL²)  kernel.cpp:382-386
//      stat + 8               f32 peakL           kernel.cpp:387  線形の振幅
//      stat + 12              f32 peakR           kernel.cpp:388  線形の振幅
//  長さは 8 + n*8 + 1456 ちょうど（kernel.cpp:389 / stereo_meter.js:344-350）。
//
//  点の置き方は web 版と同じ（stereo_meter.js:599-600）:
//      screenX = cx + (x * 0.5) * radius
//      screenY = cy - (y * 0.5) * radius
//  つまり同相のモノラルは真上へ伸びる。包絡線だけは web 版が
//  y に + を使っている（同 645）ので、こちらも符号を合わせてある。
//
//  web 版は 1 秒ぶんの輪を持ち、Window の長さだけ遡って点を描いている（同 584-604）。
//  こちらは輪を持たず、いま来た枠に入っている差分（約 1/30 秒）だけを描く。
//  相関とバランスは DSP が Window の長さで計算したものをそのまま出すので、
//  Window のつまみはその 2 つに効く。
//
//  包絡線のならしは web 版と同じ σ = 5°、±15°のガウス（同 620-636）。

import SwiftUI
import Foundation

struct StereoMeterView: View {

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    @StateObject private var telemetry = Telemetry.shared

    /// 角度ごとのピーク（stereo_meter.js:6）。
    private static let envelopeBins = 360
    /// バランスの目盛りの端。web 版の energyMax（stereo_meter.js:721）。
    private static let balanceLimit: Double = 18
    /// 点は多いので間引く上限。
    private static let maxPoints = 1500

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let r = reading {
                goniometer(r)
                peakMeter(r)
                ETStereoBipolarBar(title: "CORR",
                                   value: Double(r.correlation),
                                   range: -1...1,
                                   ticks: [-1, -0.5, 0, 0.5, 1],
                                   tickLabel: { String(format: "%.1f", $0) },
                                   text: String(format: "%.2f", Double(r.correlation)))
                ETStereoBipolarBar(title: "BALANCE",
                                   value: Double(r.balance),
                                   range: -Self.balanceLimit...Self.balanceLimit,
                                   ticks: [-12, -6, 0, 6, 12],
                                   tickLabel: { "\(Int($0))" },
                                   text: ETFormat.gain(Double(r.balance)))
            } else {
                GraphCanvas(x: .blank(), y: .blank(),
                            height: ETGraphMetrics.height,
                            insets: .none,
                            caption: "Waiting for audio",
                            clipsContent: false,
                            draw: { context, plot in
                                Self.drawField(&context, plot)
                            })
            }

            ForEach(node.spec.params) { param in
                ParameterRow(param: param, nodeIndex: index, values: node.values, dsp: dsp)
            }
        }
    }

    // MARK: ゴニオメーター

    private func goniometer(_ r: Reading) -> some View {
        let envelope = Self.smooth(r.envelope)
        return GraphCanvas(
            x: .blank(), y: .blank(),
            height: 200,
            insets: .none,
            readout: [ETReadoutItem("CORR", String(format: "%.2f", Double(r.correlation))),
                      ETReadoutItem("BAL", ETFormat.gain(Double(r.balance)))],
            clipsContent: true,
            draw: { context, plot in
                Self.drawField(&context, plot)
                Self.drawSamples(&context, plot, r.samples)
                Self.drawEnvelope(&context, plot, envelope)
            })
    }

    /// 枠・対角線・四隅の名前。値が無いときもこれだけは出す。
    private static func drawField(_ context: inout GraphicsContext, _ plot: ETPlot) {
        let rect = plot.rect
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let size = min(rect.width, rect.height)
        let radius = size * 0.45

        // ひし形。
        var diamond = Path()
        diamond.move(to: CGPoint(x: center.x, y: center.y - radius))
        diamond.addLine(to: CGPoint(x: center.x + radius, y: center.y))
        diamond.addLine(to: CGPoint(x: center.x, y: center.y + radius))
        diamond.addLine(to: CGPoint(x: center.x - radius, y: center.y))
        diamond.closeSubpath()
        context.stroke(diamond, with: ETGraphShading.axis, lineWidth: 1)

        // 縦横と 45 度（stereo_meter.js:552-570）。45 度は四隅まで伸ばす。
        var cross = Path()
        cross.move(to: CGPoint(x: center.x, y: center.y - radius))
        cross.addLine(to: CGPoint(x: center.x, y: center.y + radius))
        cross.move(to: CGPoint(x: center.x - radius, y: center.y))
        cross.addLine(to: CGPoint(x: center.x + radius, y: center.y))
        for corner in [CGPoint(x: 1, y: 1), CGPoint(x: -1, y: 1),
                       CGPoint(x: -1, y: -1), CGPoint(x: 1, y: -1)] {
            cross.move(to: center)
            cross.addLine(to: CGPoint(x: center.x + corner.x * radius,
                                      y: center.y + corner.y * radius))
        }
        context.stroke(cross, with: ETGraphShading.grid, lineWidth: 0.5)

        // 四隅の名前（stereo_meter.js:577-581）。
        let inset = size * 0.2
        let names: [(String, CGPoint)] = [
            ("L+", CGPoint(x: center.x - radius + inset, y: center.y - radius + inset)),
            ("R+", CGPoint(x: center.x + radius - inset, y: center.y - radius + inset)),
            ("R-", CGPoint(x: center.x - radius + inset, y: center.y + radius - inset)),
            ("L-", CGPoint(x: center.x + radius - inset, y: center.y + radius - inset))
        ]
        for (name, at) in names {
            context.draw(Text(name)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary),
                         at: at, anchor: .center)
        }
    }

    /// いま来た枠の点。古いものほど薄く出す（web 版の age grading と同じ考え方）。
    private static func drawSamples(_ context: inout GraphicsContext, _ plot: ETPlot,
                                    _ samples: [Float]) {
        let count = samples.count / 2
        guard count > 0 else { return }
        let rect = plot.rect
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) * 0.45
        let step = max(1, count / maxPoints)

        var groups = [Path(), Path(), Path(), Path()]
        var i = 0
        while i < count {
            let x = Double(samples[i * 2])
            let y = Double(samples[i * 2 + 1])
            let group = min(3, i * 4 / count)
            i += step
            guard x.isFinite, y.isFinite else { continue }
            // ひし形の外へ大きく外れた点で Path を壊さないよう、ほどほどで止める。
            let cx = min(max(x, -4), 4)
            let cy = min(max(y, -4), 4)
            let px = center.x + CGFloat(cx * 0.5) * radius
            let py = center.y - CGFloat(cy * 0.5) * radius
            groups[group].addRect(CGRect(x: px - 0.75, y: py - 0.75, width: 1.5, height: 1.5))
        }

        for (group, path) in groups.enumerated() where !path.isEmpty {
            context.opacity = 0.35 + 0.65 * Double(group) / 3
            context.fill(path, with: ETGraphShading.curve)
        }
        context.opacity = 1
    }

    /// 角度ごとのピークを結んだ輪（stereo_meter.js:641-653）。
    private static func drawEnvelope(_ context: inout GraphicsContext, _ plot: ETPlot,
                                     _ envelope: [Double]) {
        guard envelope.count == envelopeBins else { return }
        let rect = plot.rect
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) * 0.45

        var path = Path()
        for bin in 0..<envelopeBins {
            let radians = Double(bin) * .pi / 180
            let r = min(max(envelope[bin], 0), 4) * 0.5 * Double(radius)
            let point = CGPoint(x: center.x + CGFloat(cos(radians) * r),
                                y: center.y + CGFloat(sin(radians) * r))
            if bin == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        context.stroke(path, with: ETGraphShading.muted,
                       style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
    }

    /// σ = 5°、±15°のガウスでならす（stereo_meter.js:620-636）。
    private static let gaussian: [Double] = {
        let sigma = 5.0
        return (-15...15).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
    }()

    private static func smooth(_ peaks: [Float]) -> [Double] {
        guard peaks.count == envelopeBins else { return [] }
        let weights = gaussian
        let total = weights.reduce(0, +)
        guard total > 0 else { return [] }
        return (0..<envelopeBins).map { bin in
            var sum = 0.0
            for (k, weight) in weights.enumerated() {
                let angle = ((bin + k - 15) % envelopeBins + envelopeBins) % envelopeBins
                sum += Double(peaks[angle]) * weight
            }
            return sum / total
        }
    }

    // MARK: L/R のピーク

    private func peakMeter(_ r: Reading) -> some View {
        MeterView(channels: [ETMeterChannel.amplitude(id: 0, label: "L", level: r.peakL),
                             ETMeterChannel.amplitude(id: 1, label: "R", level: r.peakR)],
                  range: -96...0,
                  ticks: [-96, -72, -48, -24, -12, 0],
                  rowHeight: 12)
    }

    // MARK: 枠を読む

    private struct Reading {
        var sampleRate: Float
        /// x, y が交互。x = R - L、y = L + R。
        var samples: [Float]
        var envelope: [Float]
        var correlation: Float
        var balance: Float
        var peakL: Float
        var peakR: Float
    }

    private var reading: Reading? {
        guard let frame = telemetry.frame(tap: node.tapId, type: .stereoField),
              frame.matches(version: 2) else { return nil }

        let payload = frame.payloadView
        guard let sampleRate = payload.f32(at: 0),
              let count16 = payload.u16(at: 4),
              let flags = payload.u16(at: 6) else { return nil }

        let count = Int(count16)
        let envelopeOffset = 8 + count * 8
        let statisticsOffset = envelopeOffset + Self.envelopeBins * 4

        // stereo_meter.js:344-352 と同じ門。
        guard sampleRate.isFinite, sampleRate > 0, sampleRate <= 768000,
              count <= 8000, flags & ~UInt16(1) == 0,
              payload.count == statisticsOffset + 16 else { return nil }

        guard let samples = payload.floats(at: 8, count: count * 2),
              let envelope = payload.floats(at: envelopeOffset, count: Self.envelopeBins),
              let correlation = payload.f32(at: statisticsOffset),
              let balance = payload.f32(at: statisticsOffset + 4),
              let peakL = payload.f32(at: statisticsOffset + 8),
              let peakR = payload.f32(at: statisticsOffset + 12) else { return nil }

        guard !envelope.contains(where: { !$0.isFinite || $0 < 0 }),
              correlation.isFinite, correlation >= -1, correlation <= 1,
              balance.isFinite,
              peakL.isFinite, peakL >= 0, peakR.isFinite, peakR >= 0 else { return nil }

        return Reading(sampleRate: sampleRate, samples: samples, envelope: envelope,
                       correlation: correlation, balance: balance,
                       peakL: peakL, peakR: peakR)
    }
}

// MARK: - 左右に振れる棒

/// 中心が 0 で、左右どちらにも伸びる 1 本の棒。相関とバランスに使う。
/// 値は棒の中に書かない（棒で隠れる）ので、図の外（上）に出す。
private struct ETStereoBipolarBar: View {

    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let ticks: [Double]
    let tickLabel: (Double) -> String
    let text: String

    var body: some View {
        GraphCanvas(
            x: ETAxis.linear(range, ticks: ticks, label: tickLabel),
            y: .blank(),
            height: 40,
            insets: ETGraphInsets(leading: 10, trailing: 10, top: 4, bottom: 14),
            readout: [ETReadoutItem(title, text)],
            clipsContent: true,
            draw: { context, plot in
                let zero = plot.x(0)
                let clamped = min(max(value, range.lowerBound), range.upperBound)
                let tip = plot.x(clamped)
                let bar = CGRect(x: min(zero, tip), y: plot.rect.midY - 7,
                                 width: abs(tip - zero), height: 14)
                if bar.width > 0.5 {
                    context.fill(Path(roundedRect: bar, cornerRadius: 2),
                                 with: ETGraphShading.curve)
                }
                var middle = Path()
                middle.move(to: CGPoint(x: zero, y: plot.rect.minY))
                middle.addLine(to: CGPoint(x: zero, y: plot.rect.maxY))
                context.stroke(middle, with: ETGraphShading.axis, lineWidth: 1)
            })
    }
}
