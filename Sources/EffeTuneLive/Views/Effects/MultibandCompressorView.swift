//  MultibandCompressorView.swift
//  Multiband Compressor。バンドを 1 つ選んで、そのバンドの伝達曲線と値を出す。
//
//  上流は plugins/dynamics/multiband_compressor.js。
//    バンドの切り替えは Band 1..5 のタブ（同 1365 行）。既定は Band 1（同 26 行）
//    クロスオーバーは Freq 1..4 の 4 本（同 1348-1351 行）
//    バンドごとの値は Threshold / Ratio / Attack / Release / Knee / Gain の 6 本
//    （同 1439-1444 行）
//
//  伝達曲線は web 版 updateTransferGraphs（同 1231-1266 行）と同じ。
//    入力 -60〜0 dB、出力 -60〜0 dB（同 1247・1265 行が縦横とも 60 dB の線形）
//    格子は -48/-36/-24/-12 dB（同 1153 行）
//  式は Compressor と同じ形だが、web 版の Compressor と違って出力に clamp が無い
//  （multiband_compressor.js:1264 は inputDb - gainChange + band.g をそのまま使う）。
//  だから CompressorCurve は使わず、この画面で別に持つ。
//  枝の順番は音を作る側（dsp/plugins/dynamics/multiband_compressor/kernel.cpp:183-190）
//  と揃えてある。Knee = 0 のとき真ん中の枝に入らないのも同じ。
//
//  クロスオーバーの図は上流の Multiband Compressor には無い。
//  バンドのタブだけでは「どのバンドがどこを担当しているか」が出ないので、
//  同じ web 版の FIR Crossover が引いている図（plugins/basics/fir_crossover.js:839-923）
//  に合わせて描く。10Hz〜40kHz の対数・-60〜+12 dB・格子は -60/-48/-36/-24/-12/0
//  （同 853-854・862・884-886 行）。曲線は fir_crossover.js:917 と同じく
//  20*log10(max(1e-8, 振幅))。
//  フィルタは dsp/include/effetune/dsp/linkwitz_riley.h:27-61 の設計をそのまま写し、
//  分け方は dsp/plugins/dynamics/multiband_common.h:88-103 の木と同じ順に掛けている。
//  DSP は f1..f4 を並べ替えないので（kernel.cpp:113-116）、ここでも並べ替えない。
//
//  ゲインリダクションはテレメトリから来る。自前で包絡は追わない。
//    枠の種類 13（multibandDynamics）・版 1・ペイロード 24 バイト
//    書く側 dsp/plugins/dynamics/multiband_telemetry.h:29-37
//      payload[0]    = u8 バンド数（5）
//      payload[1]    = u8 種別（0 = GainReduction）
//      payload[2..3] = 0 のまま（std::array{} で 0 埋め、書いていない）
//      payload[4+4i] = f32 バンド i の削れた量（dB・0 以上）
//    読む側 plugins/dynamics/multiband_compressor.js:897-917
//    値は kernel.cpp:192・199-201 の magnitude。そのブロック最後のフレームの
//    |gain_change| で、符号は乗らない。web 版はこれを平滑してから描くが
//    （multiband_compressor.js:939-952）、こちらは DSP が出したそのままを出す。

import SwiftUI
import Foundation

struct MultibandCompressorView: View {
    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    /// 図だけ見る指定。ParameterRow は自分で畳むが、見出しは畳まないのでここで見る。
    @Environment(\.etGraphOnly) private var graphOnly

    /// 選んでいるバンド。web 版の既定も Band 1（multiband_compressor.js:26）。
    @State private var band = 0

    private static let bandCount = 5
    private static let lowHz: Double = 10
    private static let highHz: Double = 40000
    private static let samples = 192
    private static let curveSamples = 192

    var body: some View {
        // 曲線を引く閉包へ self を渡さないよう、要る値だけ控える。
        let selected = min(max(band, 0), Self.bandCount - 1)
        let edges = crossoverFrequencies
        let rate = AudioIO.shared.processingRate
        let sampleRate = rate > 0 ? rate : 48000
        let threshold = DynamicsParams.value(node, "t", band: selected)
        let ratio = DynamicsParams.value(node, "r", band: selected)
        let knee = DynamicsParams.value(node, "k", band: selected)
        let gain = DynamicsParams.value(node, "g", band: selected)

        return VStack(alignment: .leading, spacing: 12) {
            FrequencyResponseGraph(
                curves: crossoverCurves(edges: edges, sampleRate: sampleRate,
                                        selected: selected),
                frequencyRange: Self.lowHz...Self.highHz,
                decibelRange: -60...12,
                decibelStep: 12,
                caption: "Band \(selected + 1)  \(Self.span(selected, edges)) Hz")

            bandPicker(edges: edges)

            TransferCurveGraph(
                curve: ETTransferCurve.sampled(id: "band\(selected)", count: Self.curveSamples,
                                               from: -60, to: 0) { input in
                    MultibandCompressorCurve.output(input: input, threshold: threshold,
                                                    ratio: ratio, knee: knee, gain: gain)
                },
                inputRange: -60...0,
                outputRange: -60...0,
                tickStep: 12,
                height: ETGraphMetrics.compactHeight,
                caption: "Band \(selected + 1)  in / out")

            MultibandCompressorGainReduction(tapId: node.tapId, selected: selected)

            if !graphOnly {
                parameters(selected: selected)
            }
        }
    }

    // MARK: クロスオーバーの図

    /// f1..f4。DSP が読むのと同じ並び（kernel.cpp:113-114）。
    private var crossoverFrequencies: [Double] {
        (1...4).map { DynamicsParams.value(node, "f\($0)") }
    }

    /// 5 本まとめて引く。1 点ごとに 4 個のフィルタを 1 回だけ測って掛け合わせる。
    private func crossoverCurves(edges: [Double], sampleRate: Double,
                                 selected: Int) -> [ETFrequencyCurve] {
        let sections = MultibandCompressorCrossover.sections(frequencies: edges,
                                                             sampleRate: sampleRate)
        let lo = log10(Self.lowHz)
        let hi = log10(Self.highHz)
        var points = [[ETFreqPoint]](repeating: [], count: Self.bandCount)
        for b in 0..<Self.bandCount { points[b].reserveCapacity(Self.samples) }

        for sample in 0..<Self.samples {
            let t = Double(sample) / Double(Self.samples - 1)
            let hz = pow(10, lo + t * (hi - lo))
            let magnitudes = MultibandCompressorCrossover.magnitudes(hz: hz, sections: sections,
                                                                     sampleRate: sampleRate)
            for b in 0..<Self.bandCount {
                // fir_crossover.js:917 と同じ下限。
                let db = 20 * log10(max(magnitudes[b], 1e-8))
                points[b].append(ETFreqPoint(hz, db))
            }
        }

        // 選んでいるバンドを最後に足す。後から描く方が上に乗る。
        // 番号順のまま渡すと、クロスオーバーの交わる所で上の番号の細い線が
        // 選んでいるバンドの太い線を上書きする。
        let sampled = points
        func curve(_ b: Int) -> ETFrequencyCurve {
            ETFrequencyCurve(id: "band\(b)", points: sampled[b],
                             width: b == selected ? 2 : 1,
                             subdued: b != selected)
        }
        var out = (0..<Self.bandCount).filter { $0 != selected }.map(curve)
        out.append(curve(selected))
        return out
    }

    // MARK: バンドを選ぶ

    /// web 版のバンドタブと同じ。Menu は使わず直のボタンで並べる。
    private func bandPicker(edges: [Double]) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<Self.bandCount, id: \.self) { i in
                let isSelected = band == i
                Button {
                    band = i
                } label: {
                    VStack(spacing: 1) {
                        Text("\(i + 1)")
                            .font(.system(size: 13, weight: isSelected ? .bold : .regular))
                        Text(Self.span(i, edges))
                            .font(.system(size: 8, design: .monospaced))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .frame(maxWidth: .infinity, minHeight: ETMetrics.hitTarget)
                    .background(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                                in: .rect(cornerRadius: ETMetrics.innerRadius, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Band \(i + 1)")
            }
        }
    }

    /// そのバンドが受け持つ帯。両端は片側しか境が無い。
    private static func span(_ band: Int, _ edges: [Double]) -> String {
        let lower: Double? = band > 0 && band - 1 < edges.count ? edges[band - 1] : nil
        let upper: Double? = band < edges.count ? edges[band] : nil
        if let lower, let upper {
            return "\(ETFormat.hzTick(lower))–\(ETFormat.hzTick(upper))"
        }
        if let upper { return "≤\(ETFormat.hzTick(upper))" }
        if let lower { return "≥\(ETFormat.hzTick(lower))" }
        return ""
    }

    // MARK: 値

    /// クロスオーバーは 4 本まとめて、バンドごとの 6 本は選んだバンドのぶんだけ。
    private func parameters(selected: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            groupLabel("CROSSOVER")
            ForEach(node.spec.params.filter { !$0.isArray }) { param in
                ParameterRow(param: param, nodeIndex: index, values: node.values, dsp: dsp)
            }

            groupLabel("BAND \(selected + 1)")
            ForEach(node.spec.params.filter { $0.isArray }) { param in
                // 配列 1 個ぶんの行。5Band Dynamic EQ と同じものを使う。
                DynamicEQParameterRow(param: param, band: selected, nodeIndex: index,
                                      values: node.values, dsp: dsp)
            }
        }
    }

    private func groupLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .padding(.top, 2)
    }
}

// MARK: - ゲインリダクション

/// 図の一番内側。**Telemetry を見るのはここだけ**にしてある。
/// カード全体で観測すると 30Hz で作り直されて、バンドのボタンが固まる。
private struct MultibandCompressorGainReduction: View {
    let tapId: UInt32
    let selected: Int

    @ObservedObject private var telemetry = Telemetry.shared

    private static let bandCount = 5

    var body: some View {
        if let values = gainReductions {
            MeterView(
                channels: (0..<Self.bandCount).map { i in
                    ETMeterChannel(id: i, label: "\(i + 1)", levelDB: values[i])
                },
                range: 0...24,
                ticks: [0, 6, 12, 18, 24],
                holdsPeak: false,
                rowHeight: 12,
                caption: "GR  Band \(selected + 1)  \(ETFormat.db(values[selected]))",
                showsReadout: false)
        }
    }

    /// 枠が無い・版が違う・長さが違う・負の値なら nil。読めないものは描かない。
    /// 0 を返すと「削れていない」と「値が無い」の区別がつかなくなる。
    private var gainReductions: [Double]? {
        guard let frame = telemetry.frame(tap: tapId, type: .multibandDynamics),
              frame.matches(version: 1),
              frame.hasPayload(bytes: 24) else { return nil }
        let payload = frame.payloadView
        // multiband_telemetry.h:31-32 の バンド数 と 種別（0 = GainReduction）。
        guard payload.u8(at: 0) == UInt8(Self.bandCount),
              payload.u8(at: 1) == 0,
              payload.u16(at: 2) == 0,
              let values = payload.floats(at: 4, count: Self.bandCount) else { return nil }
        var out: [Double] = []
        out.reserveCapacity(values.count)
        for value in values {
            guard value.isFinite, value >= 0 else { return nil }
            out.append(Double(value))
        }
        guard out.indices.contains(selected) else { return nil }
        return out
    }
}

// MARK: - 伝達曲線の式

/// multiband_compressor.js:1235-1264 と kernel.cpp:174-190 を写したもの。
/// Compressor と違い、出力に clamp は無い。
enum MultibandCompressorCurve {

    static func output(input: Double, threshold: Double, ratio: Double,
                       knee: Double, gain: Double) -> Double {
        // kernel.cpp:174-177 の clamp。カタログの範囲と同じなので普通は素通し。
        let ratio = min(max(ratio, 0.5), 20)
        let knee = max(knee, 0)
        let halfKnee = knee * 0.5
        // kernel.cpp:179 と同じ。ratio == 1 のときだけ 0 に落とす。
        let slope = ratio == 1 ? 0 : 1 - 1 / ratio
        let difference = input - threshold

        var gainChange = 0.0
        if difference <= -halfKnee {
            gainChange = 0
        } else if difference >= halfKnee {
            gainChange = difference * slope
        } else {
            // kernel.cpp:189 と同じ。knee が 0 のときここには来ない。
            let position = knee > 0 ? (difference + halfKnee) / knee : 1
            gainChange = slope * knee * position * position * 0.5
        }

        // gainChange > 0 は削り、< 0 は持ち上げ（ratio < 1 のとき）。
        return input - gainChange + gain
    }
}

// MARK: - クロスオーバー

/// dsp/include/effetune/dsp/linkwitz_riley.h:27-61 の設計と、
/// dsp/plugins/dynamics/multiband_common.h:88-103 の分け方。
enum MultibandCompressorCrossover {

    /// 1 + a1 z^-1 + a2 z^-2 で正規化した双二次（biquad.h:13-14 と同じ向き）。
    struct Biquad {
        var b0: Double = 0
        var b1: Double = 0
        var b2: Double = 0
        var a1: Double = 0
        var a2: Double = 0
    }

    /// 1 つの分岐点。低い側と高い側で分母は同じ。
    struct Section {
        var lowpass = Biquad()
        var highpass = Biquad()
    }

    /// biquad.h:11 の 1/sqrt(2)。丸め位置まで同じにしておく。
    private static let butterworthQ = 0x1.6a09e667f3bcdp-1

    static func sections(frequencies: [Double], sampleRate: Double) -> [Section] {
        frequencies.map { design(sampleRate: sampleRate, cutoff: $0) }
    }

    /// designLinkwitzRiley24 と同じ。範囲の外は係数 0 のまま返す（C++ も同じ）。
    static func design(sampleRate: Double, cutoff requested: Double) -> Section {
        var result = Section()
        guard sampleRate.isFinite, sampleRate > 0, requested.isFinite else { return result }

        let maximumCutoff = sampleRate * 0.499
        var cutoff = requested > maximumCutoff ? maximumCutoff : requested
        if cutoff < 10 { cutoff = 10 }
        guard cutoff > 0, cutoff < sampleRate * 0.5 else { return result }

        let k = 2 * sampleRate
        let warped = 2 * sampleRate * tan(Double.pi * cutoff / sampleRate)
        let q = butterworthQ
        let kSquaredQ = k * k * q
        let warpedSquaredQ = warped * warped * q
        let a0 = kSquaredQ + k * warped + warpedSquaredQ
        guard a0 != 0 else { return result }

        let a1 = (-2 * kSquaredQ + 2 * warpedSquaredQ) / a0
        let a2 = (kSquaredQ - k * warped + warpedSquaredQ) / a0

        result.lowpass = Biquad(b0: warpedSquaredQ / a0, b1: 2 * warpedSquaredQ / a0,
                                b2: warpedSquaredQ / a0, a1: a1, a2: a2)
        result.highpass = Biquad(b0: kSquaredQ / a0, b1: -2 * kSquaredQ / a0,
                                 b2: kSquaredQ / a0, a1: a1, a2: a2)
        return result
    }

    /// バンド 5 本ぶんの振幅（線形）。分岐点が 4 つ無ければ全部 0。
    static func magnitudes(hz: Double, sections: [Section], sampleRate: Double) -> [Double] {
        guard sections.count == 4, sampleRate > 0 else {
            return [Double](repeating: 0, count: 5)
        }
        var low = [Double](repeating: 0, count: 4)
        var high = [Double](repeating: 0, count: 4)
        for i in 0..<4 {
            // LR24 は同じ双二次を 2 段通す（linkwitz_riley.h:74-79）ので振幅は 2 乗。
            let l = magnitude(sections[i].lowpass, hz: hz, sampleRate: sampleRate)
            let h = magnitude(sections[i].highpass, hz: hz, sampleRate: sampleRate)
            low[i] = l * l
            high[i] = h * h
        }
        // multiband_common.h:88-103 の木。高い側を順に降ろしていく。
        return [
            low[0],
            high[0] * low[1],
            high[0] * high[1] * low[2],
            high[0] * high[1] * high[2] * low[3],
            high[0] * high[1] * high[2] * high[3],
        ]
    }

    /// |H(e^jw)|。
    static func magnitude(_ filter: Biquad, hz: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * hz / sampleRate
        let cos1 = cos(w)
        let sin1 = sin(w)
        // 倍角。2 点ぶんの三角関数を省く。
        let cos2 = 2 * cos1 * cos1 - 1
        let sin2 = 2 * sin1 * cos1
        let numeratorReal = filter.b0 + filter.b1 * cos1 + filter.b2 * cos2
        let numeratorImaginary = -(filter.b1 * sin1 + filter.b2 * sin2)
        let denominatorReal = 1 + filter.a1 * cos1 + filter.a2 * cos2
        let denominatorImaginary = -(filter.a1 * sin1 + filter.a2 * sin2)
        let denominator = denominatorReal * denominatorReal
            + denominatorImaginary * denominatorImaginary
        guard denominator > 0 else { return 0 }
        let numerator = numeratorReal * numeratorReal + numeratorImaginary * numeratorImaginary
        return (numerator / denominator).squareRoot()
    }
}
