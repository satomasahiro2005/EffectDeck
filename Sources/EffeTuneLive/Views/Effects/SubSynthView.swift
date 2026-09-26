//  SubSynthView.swift
//  Sub Synth（SubSynthPlugin）。
//
//  上流は plugins/saturation/sub_synth.js。
//    行の並びは Sub Level → Sub LPF → Sub HPF → Dry Level → Dry HPF（同 400-405）。
//    周波数の 3 本は createLogarithmicParameterControl(..., 5, 400, 1, ...)（同 366, 373, 381）。
//      この写像は ParameterRow が持っている（ETSliderScale の
//      "SubSynthPlugin.slf" 以下 3 本）ので、行はそちらに任せる。
//    傾きは周波数と同じ行に付く select（同 371, 378, 386）。選択肢は
//      [0, -6, -12, -18, -24] で、字は 0 が 'Off'、他は絶対値の '6dB/oct'（同 347-354）。
//      ラベルは無い。ここは Menu を足さないので、5 個の直のボタンにして
//      周波数の行の下に添えた。
//
//  --- 図（drawGraph。同 429-555）---
//    横 5Hz〜1000Hz の対数（同 450 と 503）。格子は 5/10/20/50/100/200/500（同 447）で、
//      字は幅が狭いときの 4 つ（同 448）
//    縦 -30〜+6 dB、格子は 6 dB ごと（同 462-464）
//    線は 2 本。dry は Dry HPF だけを掛けたもの（同 501-519。Dry Level は入らない）、
//      sub は Sub Level に Sub LPF と Sub HPF を掛けたもの（同 525-554）
//    軸名は同 479-483 の「Frequency (Hz)」「Level (dB)」。GraphCanvas は軸名を持たず、
//      見出しにも入れない（見出しは線の名前だけ）。
//
//  上流は図をコントロールの後ろに置く（同 405）が、このアプリの他のカードは
//  図が先なので、そちらに合わせてある。

import SwiftUI
import Foundation

struct SubSynthView: View {

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    /// 図だけ見る指定。ParameterRow は自分で畳むが、ボタンは畳まないのでここで見る。
    @Environment(\.etGraphOnly) private var graphOnly

    private static let lowHz: Double = 5
    private static let highHz: Double = 1000
    private static let decibelRange: ClosedRange<Double> = -30...6
    private static let samples = 256
    /// select の選択肢（sub_synth.js:347）。
    private static let slopes: [Int] = [0, -6, -12, -18, -24]
    /// 格子（同 447）と、幅が狭いときに字を出すもの（同 448）。
    private static let gridFrequencies: [Double] = [5, 10, 20, 50, 100, 200, 500]
    private static let labeledFrequencies: Set<Double> = [10, 50, 200, 500]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            graph

            if !graphOnly {
                row("sl")
                filterGroup(frequency: "slf", slope: "sls", name: "Sub Low Pass Slope")
                filterGroup(frequency: "shf", slope: "shs", name: "Sub High Pass Slope")
                row("dl")
                filterGroup(frequency: "dhf", slope: "dhs", name: "Dry High Pass Slope")
            }
        }
    }

    // MARK: 図

    private var graph: some View {
        let traces = curves
        return GraphCanvas(
            x: Self.frequencyAxis,
            y: ETAxis.decibels(Self.decibelRange, step: 6),
            height: ETGraphMetrics.height,
            insets: .standard,
            caption: "Sub / Dry",
            clipsContent: true,
            draw: { context, plot in
                for trace in traces {
                    guard trace.points.count > 1 else { continue }
                    var path = Path()
                    for (i, point) in trace.points.enumerated() {
                        let position = plot.point(
                            point.hz,
                            ETdB.finite(point.db, floor: Self.decibelRange.lowerBound - 60))
                        if i == 0 { path.move(to: position) } else { path.addLine(to: position) }
                    }
                    context.stroke(path,
                                   with: trace.subdued ? ETGraphShading.muted
                                                       : ETGraphShading.curve,
                                   style: StrokeStyle(lineWidth: 2, lineCap: .round,
                                                      lineJoin: .round))
                }
            })
    }

    private static var frequencyAxis: ETAxis {
        let ticks = gridFrequencies.map { hz in
            ETAxisTick(hz, labeledFrequencies.contains(hz) ? ETFormat.hzTick(hz) : nil)
        }
        return ETAxis(scale: .logarithmic, lower: lowHz, upper: highHz, ticks: ticks)
    }

    /// 上流は dry を先に、sub を後に引く（sub_synth.js:498 と 522）。重なりの上下もそれに合わせる。
    private var curves: [ETFrequencyCurve] {
        let subLevel = DynamicsParams.value(node, "sl") / 100
        let subLpfHz = DynamicsParams.value(node, "slf")
        let subLpfSlope = DynamicsParams.value(node, "sls")
        let subHpfHz = DynamicsParams.value(node, "shf")
        let subHpfSlope = DynamicsParams.value(node, "shs")
        let dryHpfHz = DynamicsParams.value(node, "dhf")
        let dryHpfSlope = DynamicsParams.value(node, "dhs")

        let dry = ETFrequencyCurve.sampled(id: "dry", count: Self.samples,
                                           from: Self.lowHz, to: Self.highHz,
                                           subdued: true) { hz in
            SubSynthResponse.decibels(
                SubSynthResponse.magnitude(hz: hz, cutoff: dryHpfHz,
                                           slope: dryHpfSlope, isHighpass: true))
        }
        let sub = ETFrequencyCurve.sampled(id: "sub", count: Self.samples,
                                           from: Self.lowHz, to: Self.highHz) { hz in
            let magnitude = subLevel
                * SubSynthResponse.magnitude(hz: hz, cutoff: subLpfHz,
                                             slope: subLpfSlope, isHighpass: false)
                * SubSynthResponse.magnitude(hz: hz, cutoff: subHpfHz,
                                             slope: subHpfSlope, isHighpass: true)
            return SubSynthResponse.decibels(magnitude)
        }
        return [dry, sub]
    }

    // MARK: 行

    @ViewBuilder
    private func row(_ key: String) -> some View {
        if let param = node.spec.params.first(where: { $0.key == key }) {
            ParameterRow(param: param, nodeIndex: index, values: node.values, dsp: dsp)
        }
    }

    /// 上流は 1 行に［ラベル・つまみ・数値欄・傾き］を並べる（同 366-371）が、
    /// iPhone の幅では潰れるので ParameterRow と同じ 2 段にして、傾きを下に添える。
    private func filterGroup(frequency: String, slope: String, name: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            row(frequency)
            slopeRow(slope, name: name)
        }
    }

    private func slopeRow(_ key: String, name: String) -> some View {
        let current = Int(DynamicsParams.value(node, key).rounded())
        return HStack(spacing: 4) {
            ForEach(Self.slopes, id: \.self) { slope in
                slopeButton(key, name: name, slope: slope, isSelected: current == slope)
            }
        }
    }

    private func slopeButton(_ key: String, name: String,
                             slope: Int, isSelected: Bool) -> some View {
        Button {
            set(key, Float(slope))
        } label: {
            // 上流の option と同じ字（同 351）。
            Text(slope == 0 ? "Off" : "\(abs(slope))dB/oct")
                .font(.system(size: 12, weight: isSelected ? .bold : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .frame(maxWidth: .infinity, minHeight: ETMetrics.hitTarget)
                .background(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                            in: .rect(cornerRadius: ETMetrics.innerRadius, style: .continuous))
                // 字は 2〜8 文字で幅が揃わない。枠いっぱいを押せる面にする。
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityValue(slope == 0 ? "Off" : "\(abs(slope)) dB per octave")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: 値

    private func set(_ key: String, _ value: Float) {
        guard let param = node.spec.params.first(where: { $0.key == key }) else { return }
        dsp.setValue(value, at: index, offset: param.offset)
    }
}

// MARK: - 応答

/// 図を引くためだけの振幅。sub_synth.js:487-554 を写したもの。
/// 音を作る側（registerProcessor の中）ではない。
enum SubSynthResponse {

    /// 同 487-495。6dB/oct ごとに 1 次、2 つで 2 次にまとめる。
    static func stages(_ slope: Double) -> (first: Int, second: Int) {
        let steepness = abs(slope)
        guard steepness > 0 else { return (0, 0) }
        let n = Int((steepness / 6).rounded())
        if n % 2 == 1 { return (first: 1, second: (n - 1) / 2) }
        return (first: 0, second: n / 2)
    }

    /// フィルタ 1 本ぶんの振幅。同 505-514（HPF）と 530-539（LPF）。
    /// 傾きが 0 のときは上流と同じく素通し。
    static func magnitude(hz: Double, cutoff: Double,
                          slope: Double, isHighpass: Bool) -> Double {
        guard slope != 0, cutoff > 0 else { return 1 }
        let (first, second) = stages(slope)
        let ratio = hz / cutoff
        let squared = ratio * ratio
        var amplitude = 1.0
        if first > 0 {
            amplitude *= isHighpass ? ratio / sqrt(1 + squared) : 1 / sqrt(1 + squared)
        }
        if second > 0 {
            let denominator = sqrt(1 + 2 * squared + squared * squared)
            amplitude *= pow(isHighpass ? squared / denominator : 1 / denominator,
                             Double(second))
        }
        return amplitude
    }

    /// 同 515 と 550。Sub Level が 0 のとき上流は -Infinity を y に渡して線が消える。
    /// ここは軸の下に落として、線の形を保ったまま外へ出す。
    static func decibels(_ magnitude: Double) -> Double {
        magnitude > 0 ? 20 * log10(magnitude) : -200
    }
}
