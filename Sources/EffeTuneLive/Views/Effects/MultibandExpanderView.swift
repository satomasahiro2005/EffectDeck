//  MultibandExpanderView.swift
//  Multiband Expander。帯の分かれ方と、選んでいるバンドの伝達曲線。
//
//  web 版（plugins/dynamics/multiband_expander.js:1130-1362 の createUI）は
//    ・クロスオーバー 4 本のスライダー
//    ・Band 1..5 のタブ（同 1211-1232）。選んだバンドの 6 本だけを出す
//    ・バンドごとの伝達曲線を 5 枚（同 1299-1337）。選んでいる 1 枚が active
//  という作り。タブの切り替えとバンドごとの曲線はそのまま写した。
//
//  伝達曲線の軸は web 版と同じ入力 -60〜0 dB・出力も -60〜0 dB
//  （同 1053-1055 行の (db+60)/60 が縦横とも同じ式）、格子は -48/-36/-24/-12（同 1010 行）。
//  曲線の式は 1 バンド版と同じなので ExpanderCurve をそのまま使う
//  （js は同 1100-1111、音の側は dsp/plugins/dynamics/multiband_expander/kernel.cpp:183-194。
//   makeup を足したあとの頭打ちは kernel が lookup_.gain の -60..20 で持っている）。
//
//  帯の図は web 版に無い。あちらは 4 本のスライダーの数値だけで、
//  どのバンドがどこを担当しているかは画面に出ない。ここは縦に並ぶスライダーだけだと
//  バンド番号と周波数が結びつかないので、分かれ方を 1 枚足した。
//  フィルタは LR24（Linkwitz-Riley 4 次）で、係数は
//    dsp/include/effetune/dsp/linkwitz_riley.h:27-62（音の側）
//    multiband_expander.js:179-234（描く側）
//  が同じ式。同じ 2 次の段を 2 回通すので、dB は 1 段ぶんの 2 倍になる。
//  バンドの作り方は kernel が使う multiband_common.h の順（js:362-385 も同じ）:
//    band0 = LP(f1)、band1 = HP(f1)LP(f2)、band2 = HP(f1)HP(f2)LP(f3)、
//    band3 = HP(f1..f3)LP(f4)、band4 = HP(f1..f4)
//  バンドの Gain は帯の図に入れていない。あれは静的な足し算で、
//  帯の分かれ方とは別の話なので混ぜない。
//
//  効いている量はテレメトリから来る。
//    枠の種類 13（multibandDynamics）・版 1・ペイロード 24 バイト
//    書く側 dsp/plugins/dynamics/multiband_telemetry.h:29-38
//      payload[0]    = u8 バンド数（5）
//      payload[1]    = u8 種類。0=Compressor, 1=Expander, 2=Transient
//      payload[2..3] = 0（std::array{} で 0 埋め）
//      payload[4+4i] = f32 バンド i の量
//    読む側 multiband_expander.js:767-788
//  同じ枠の種類を Multiband Compressor / Transient も使うので、payload[1] を必ず見る。
//  値は kernel.cpp:199 の last_gain_boost、ブロック最後のフレームの量で、
//  同行で abs を取っているため符号が無い。大きさだけ出す。

import SwiftUI
import Foundation

struct MultibandExpanderView: View {
    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    @Environment(\.etGraphOnly) private var graphOnly

    /// 選んでいるバンド。web 版の既定も Band 1（multiband_expander.js:30 の selectedBand = 0）。
    @State private var band = 0

    private static let bandCount = 5
    /// 並びは EffectCatalog.swift（＝params.json）の順。低い方から。
    private static let crossoverKeys = ["f1", "f2", "f3", "f4"]
    private static let samples = 256

    var body: some View {
        let selected = min(max(band, 0), Self.bandCount - 1)
        let rate = AudioIO.shared.processingRate
        let sampleRate = rate > 0 ? rate : 96000
        let edges = Self.crossoverKeys.map { DynamicsParams.value(node, $0) }
        let filters = edges.map {
            MultibandExpanderCrossover(sampleRate: sampleRate, cutoffHz: $0)
        }

        // 曲線を引く閉包へ self を渡さないよう、要る値だけ控える。
        let threshold = DynamicsParams.value(node, "t", band: selected)
        let ratio = DynamicsParams.value(node, "r", band: selected)
        let knee = DynamicsParams.value(node, "k", band: selected)
        let makeup = DynamicsParams.value(node, "g", band: selected)

        return VStack(alignment: .leading, spacing: 12) {
            FrequencyResponseGraph(
                curves: bandCurves(filters, selected: selected),
                decibelRange: -24...6,
                decibelStep: 6,
                height: ETGraphMetrics.compactHeight,
                caption: "Band \(selected + 1)  \(Self.span(edges, band: selected)) Hz")

            // 図だけの段では出さない（MultibandCompressorView と同じ理由）。
            if !graphOnly { bandPicker(edges) }

            TransferCurveGraph(
                curve: ETTransferCurve.sampled(id: "multiband-expander", count: 192,
                                               from: -60, to: 0) { input in
                    ExpanderCurve.output(input: input, threshold: threshold, ratio: ratio,
                                         knee: knee, makeup: makeup)
                },
                inputRange: -60...0,
                outputRange: -60...0,
                tickStep: 12,
                height: ETGraphMetrics.compactHeight,
                caption: "Band \(selected + 1)  in / out")

            MultibandExpanderMeter(tapId: node.tapId)

            if !graphOnly {
                parameters(selected: selected)
            }
        }
    }

    // MARK: 帯の図

    /// 選んでいるバンドを最後に足す。後から描く方が上に乗る。
    private func bandCurves(_ filters: [MultibandExpanderCrossover],
                            selected: Int) -> [ETFrequencyCurve] {
        func curve(_ i: Int) -> ETFrequencyCurve {
            .sampled(id: "band\(i)", count: Self.samples,
                     width: i == selected ? 2 : 1,
                     subdued: i != selected) { hz in
                MultibandExpanderCrossover.decibels(band: i, hz: hz, filters: filters)
            }
        }
        var out = (0..<Self.bandCount).filter { $0 != selected }.map(curve)
        out.append(curve(selected))
        return out
    }

    // MARK: バンドを選ぶ

    /// web 版のバンドタブ（js:1211-1232）と同じ。番号の下に担当する帯を出す。
    private func bandPicker(_ edges: [Double]) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<Self.bandCount, id: \.self) { i in
                let isSelected = band == i
                Button {
                    band = i
                } label: {
                    VStack(spacing: 1) {
                        Text("\(i + 1)")
                            .font(.system(size: 13, weight: isSelected ? .bold : .regular))
                        Text(Self.span(edges, band: i))
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
                // 中は「1」と帯の 2 行なので、読み上げは番号だけにする。
                .accessibilityLabel("Band \(i + 1)")
            }
        }
    }

    /// バンドが担当する帯。両端は開いているので不等号で書く。
    private static func span(_ edges: [Double], band: Int) -> String {
        let lower = band > 0 && band - 1 < edges.count ? ETFormat.hzTick(edges[band - 1]) : nil
        let upper = band < edges.count ? ETFormat.hzTick(edges[band]) : nil
        switch (lower, upper) {
        case let (nil, .some(high)):          return "<\(high)"
        case let (.some(low), nil):           return ">\(low)"
        case let (.some(low), .some(high)):   return "\(low)–\(high)"
        default:                              return ""
        }
    }

    // MARK: params

    /// クロスオーバーの 4 本は 1 個ずつの値、残りの 6 本はバンドごとの配列。
    /// 配列の方を ParameterRow に渡すと行ごとにバンドを選ぶタブが出るので、
    /// 上で 1 回選んだバンドに向ける DynamicEQParameterRow を使う。
    private func parameters(selected: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(node.spec.params) { param in
                if let label = Self.groupLabel(before: param.key, band: selected) {
                    Text(label)
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                if param.isArray {
                    DynamicEQParameterRow(param: param, band: selected, nodeIndex: index,
                                          values: node.values, dsp: dsp)
                } else {
                    ParameterRow(param: param, nodeIndex: index, values: node.values, dsp: dsp)
                }
            }
        }
    }

    /// 10 本を 2 つに割る。並びは EffectCatalog.swift（＝params.json）の順。
    private static func groupLabel(before key: String, band: Int) -> String? {
        switch key {
        case "f1": return "CROSSOVER"
        case "t":  return "BAND \(band + 1)"
        default:   return nil
        }
    }
}

// MARK: - 効いている量

/// テレメトリを見るのはここだけ。カード全体で観測すると 30Hz で作り直される。
private struct MultibandExpanderMeter: View {
    let tapId: UInt32

    @ObservedObject private var telemetry = Telemetry.shared

    private static let bandCount = 5
    /// multiband_telemetry.h:18-22 の ValueKind。Expander は 1。
    private static let expansionMagnitude: UInt8 = 1

    var body: some View {
        if let values = magnitudes {
            // 段の高さと上限は 1 バンド版（ExpanderView）に合わせてある。
            MeterView(channels: values.enumerated().map {
                          ETMeterChannel(id: $0.offset, label: "\($0.offset + 1)",
                                         levelDB: $0.element)
                      },
                      range: 0...24,
                      ticks: [0, 6, 12, 18, 24],
                      holdsPeak: false,
                      rowHeight: 12,
                      caption: "Expansion (dB)",
                      showsReadout: false)
        }
    }

    /// 読めなければ nil。0 を返すと「効いていない」と「値が無い」の区別がつかない。
    private var magnitudes: [Double]? {
        guard let frame = telemetry.frame(tap: tapId, type: .multibandDynamics),
              frame.matches(version: 1),
              frame.hasPayload(bytes: 4 + Self.bandCount * 4) else { return nil }
        let payload = frame.payloadView
        guard payload.u8(at: 0) == UInt8(Self.bandCount),
              payload.u8(at: 1) == Self.expansionMagnitude,
              payload.u16(at: 2) == 0,
              let values = payload.floats(at: 4, count: Self.bandCount) else { return nil }
        var out: [Double] = []
        out.reserveCapacity(values.count)
        for value in values {
            // kernel.cpp:199 で abs を取っているので負は来ない。来たら読み違えている。
            guard value.isFinite, value >= 0 else { return nil }
            out.append(Double(value))
        }
        return out
    }
}

// MARK: - 帯の分かれ方

/// LR24 の片側 1 本ぶん。linkwitz_riley.h:27-62 と multiband_expander.js:179-234 を写したもの。
private struct MultibandExpanderCrossover {

    /// 2 次 Butterworth の Q。biquad.h:11 の kSecondOrderButterworthQ（0x1.6a09e667f3bcdp-1）
    /// と同じ値になるよう sqrt(0.5) で書く。1/sqrt(2) は最下位 1 ビットずれる。
    private static let butterworthQ = (0.5 as Double).squareRoot()

    struct Section {
        var b0 = 1.0
        var b1 = 0.0
        var b2 = 0.0
        var a1 = 0.0
        var a2 = 0.0
    }

    var lowpass = Section()
    var highpass = Section()
    var sampleRate = 0.0

    init(sampleRate: Double, cutoffHz: Double) {
        self.sampleRate = sampleRate
        guard sampleRate.isFinite, sampleRate > 0, cutoffHz.isFinite else { return }

        // linkwitz_riley.h:33-38 と同じ順で丸める。上限が先、下限があと。
        var cutoff = min(cutoffHz, sampleRate * 0.499)
        if cutoff < 10 { cutoff = 10 }
        guard cutoff < sampleRate * 0.5 else { return }

        let k = 2 * sampleRate
        let warped = 2 * sampleRate * tan(Double.pi * cutoff / sampleRate)
        let q = Self.butterworthQ
        let kSquaredQ = k * k * q
        let warpedSquaredQ = warped * warped * q
        let a0 = kSquaredQ + k * warped + warpedSquaredQ
        guard a0 != 0 else { return }

        let a1 = (-2 * kSquaredQ + 2 * warpedSquaredQ) / a0
        let a2 = (kSquaredQ - k * warped + warpedSquaredQ) / a0

        lowpass = Section(b0: warpedSquaredQ / a0, b1: 2 * warpedSquaredQ / a0,
                          b2: warpedSquaredQ / a0, a1: a1, a2: a2)
        highpass = Section(b0: kSquaredQ / a0, b1: -2 * kSquaredQ / a0,
                           b2: kSquaredQ / a0, a1: a1, a2: a2)
    }

    /// 同じ段を 2 回通すので dB は 2 倍。
    func decibels(_ section: Section, hz: Double) -> Double {
        guard sampleRate > 0, hz > 0, hz < sampleRate * 0.5 else { return -120 }
        return 2 * Self.sectionDecibels(section, w: 2 * Double.pi * hz / sampleRate)
    }

    /// |H(e^jw)| を dB で。20*log10(sqrt(num/den)) は 10*log10(num/den) と同じ。
    private static func sectionDecibels(_ c: Section, w: Double) -> Double {
        let cw = cos(w)
        let sw = sin(w)
        let cos2 = 2 * cw * cw - 1
        let sin2 = 2 * sw * cw
        let numeratorRe = c.b0 + c.b1 * cw + c.b2 * cos2
        let numeratorIm = -c.b1 * sw - c.b2 * sin2
        let denominatorRe = 1 + c.a1 * cw + c.a2 * cos2
        let denominatorIm = -c.a1 * sw - c.a2 * sin2
        let denominator = denominatorRe * denominatorRe + denominatorIm * denominatorIm
        guard denominator > 1e-18 else { return -120 }
        let numerator = numeratorRe * numeratorRe + numeratorIm * numeratorIm
        return 10 * log10(max(1e-18, numerator / denominator))
    }

    /// バンド i が通す量。帯の作り方は kernel が使う multiband_common.h の順で、
    /// 下のクロスオーバーを全部 HP で抜けたあと、自分の上を LP で切る。
    /// いちばん上のバンドだけ LP が無い。
    static func decibels(band: Int, hz: Double, filters: [MultibandExpanderCrossover]) -> Double {
        var total = 0.0
        for i in 0..<min(band, filters.count) {
            total += filters[i].decibels(filters[i].highpass, hz: hz)
        }
        if band < filters.count {
            total += filters[band].decibels(filters[band].lowpass, hz: hz)
        }
        return total
    }
}
