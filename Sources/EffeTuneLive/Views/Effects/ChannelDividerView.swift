//  ChannelDividerView.swift
//  Channel Divider（ChannelDividerPlugin）。
//
//  上流は plugins/basics/channel_divider.js。
//    バンド数は 2/3/4 のラジオ（同 603-621）
//    分岐点は Freq 1..3。ラベルは 'Freq 1 (Hz):'（同 713）。
//      つまみは位置 0-1000 を 10Hz〜40kHz へ対数で写す（同 715-716 と 786-797）。
//      この写像は ParameterRow が持っている（ETSliderScale の
//      "ChannelDividerPlugin.f1" 以下 3 本）ので、行はそちらに任せる。
//    スロープは周波数と同じ行の select。選択肢は -12..-96 の 8 個で、
//      字は絶対値の '12dB'（同 687-706 と 721-722）。ラベルは無い。
//    バンド数に足りない行は opacity 0.5（同 750-752）。上流も disabled にはしない。
//
//  --- 図（drawGraph。同 799-883）---
//    横 10Hz〜40kHz の対数（同 811-812）
//    縦 -60〜+12 dB、格子は -60/-48/-36/-24/-12/0（同 833-835）
//    トレースはバンド数ぶん。Low/Mid/High の組み方は同 856-869
//    フィルタは Butterworth_N を 2 回重ねた Linkwitz-Riley（同 937-953）
//
//  図のサンプリング周波数は 96000 固定。上流も同じ（同 897 の
//  `const fs = 96000; // Default sample rate for graph calculation`）。
//  実際に鳴っているレートではないので、40kHz 付近は上流と同じだけ狙いからずれる。
//
//  上流の select はここでは使わない（Menu を足さない）。8 個の直のボタンにしてある。
//  1 行に 8 個並べると 1 個が 44pt を割るので、4 列 2 段に割った。
//
//  上流は図をコントロールの後ろに置く（同 627-641）が、このアプリの他のカードは
//  図が先なので、そちらに合わせてある。

import SwiftUI
import Foundation

struct ChannelDividerView: View {

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    /// 図だけ見る指定。ParameterRow は自分で畳むが、ボタンは畳まないのでここで見る。
    @Environment(\.etGraphOnly) private var graphOnly

    private static let lowHz: Double = 10
    private static let highHz: Double = 40000
    private static let samples = 256
    /// 図を引くときのサンプリング周波数（channel_divider.js:897）。
    private static let graphRate: Double = 96000
    /// select の選択肢（同 692）を 4 列 2 段に割ったもの。
    private static let slopeRows: [[Int]] = [[-12, -24, -36, -48], [-60, -72, -84, -96]]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FrequencyResponseGraph(
                curves: bandCurves,
                frequencyRange: Self.lowHz...Self.highHz,
                decibelRange: -60...12,
                decibelStep: 12,
                caption: bandNames.joined(separator: " / "))

            if !graphOnly {
                bandCountRow
                ForEach(1...3, id: \.self) { i in
                    crossoverGroup(i)
                }
            }
        }
    }

    // MARK: 図

    /// バンド数。上流は 2..4（channel_divider.js:611）。
    private var bandCount: Int {
        min(max(Int(DynamicsParams.value(node, "bc").rounded()), 2), 4)
    }

    /// channel_divider.js:856-869 の名前。
    private var bandNames: [String] {
        switch bandCount {
        case 3:  return ["Low", "Mid", "High"]
        case 4:  return ["Low", "Mid-Low", "Mid-High", "High"]
        default: return ["Low", "High"]
        }
    }

    /// バンドごとのフィルタ。同 856-869 と同じ組み方。
    /// DSP は f1..f3 を並べ替えないので、ここでも並べ替えない。
    private var bandFilters: [[ChannelDividerCrossover.Filter]] {
        let frequencies = (1...3).map { DynamicsParams.value(node, "f\($0)") }
        let slopes = (1...3).map { DynamicsParams.value(node, "s\($0)") }
        func lowpass(_ n: Int) -> ChannelDividerCrossover.Filter {
            ChannelDividerCrossover.Filter(hz: frequencies[n], slope: slopes[n], isHighpass: false)
        }
        func highpass(_ n: Int) -> ChannelDividerCrossover.Filter {
            ChannelDividerCrossover.Filter(hz: frequencies[n], slope: slopes[n], isHighpass: true)
        }
        switch bandCount {
        case 3:  return [[lowpass(0)], [highpass(0), lowpass(1)], [highpass(1)]]
        case 4:  return [[lowpass(0)], [highpass(0), lowpass(1)],
                         [highpass(1), lowpass(2)], [highpass(2)]]
        default: return [[lowpass(0)], [highpass(0)]]
        }
    }

    /// 上流は全部のトレースを同じ太さ・同じ色で引く（同 871-883）。ここでも分けない。
    private var bandCurves: [ETFrequencyCurve] {
        let rate = Self.graphRate
        return bandFilters.enumerated().map { position, filters -> ETFrequencyCurve in
            // 係数はフィルタ 1 本につき 1 回だけ設計する。点ごとに作り直さない。
            let designed = filters.map {
                ChannelDividerCrossover.sections(cutoff: $0.hz, slope: $0.slope,
                                                 isHighpass: $0.isHighpass, sampleRate: rate)
            }
            return ETFrequencyCurve.sampled(id: "band\(position)", count: Self.samples,
                                            from: Self.lowHz, to: Self.highHz) { hz in
                // 上流はフィルタごとに dB にしてから足す（同 887-895）。
                designed.reduce(0.0) {
                    $0 + ChannelDividerCrossover.decibels(hz: hz, sections: $1, sampleRate: rate)
                }
            }
        }
    }

    // MARK: バンド数

    /// 上流はラジオ（同 603-621）。ここは直のボタンで並べる。
    private var bandCountRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Band Count").font(.system(size: 14))
            HStack(spacing: 6) {
                ForEach([2, 3, 4], id: \.self) { count in
                    let isSelected = bandCount == count
                    Button {
                        set("bc", Float(count))
                    } label: {
                        Text("\(count)")
                            .font(.system(size: 13, weight: isSelected ? .bold : .regular))
                            .foregroundStyle(isSelected ? AnyShapeStyle(.white)
                                                        : AnyShapeStyle(.secondary))
                            .frame(maxWidth: .infinity, minHeight: ETMetrics.hitTarget)
                            .background(isSelected ? AnyShapeStyle(.tint)
                                                   : AnyShapeStyle(.quaternary),
                                        in: .rect(cornerRadius: ETMetrics.innerRadius,
                                                  style: .continuous))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Band count \(count)")
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                }
            }
        }
    }

    // MARK: 分岐点

    /// 上流は 1 行に［ラベル・つまみ・数値欄・スロープ］を並べる（同 708-730）が、
    /// iPhone の幅では潰れるので ParameterRow と同じ 2 段にして、スロープを下に添える。
    private func crossoverGroup(_ i: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            frequencyRow(i)
            slopeRow(i)
        }
        // 足りない行は薄くする（同 750-752）。触れる状態は変えない。
        .opacity(bandCount >= i + 1 ? 1 : 0.5)
    }

    @ViewBuilder
    private func frequencyRow(_ i: Int) -> some View {
        if let param = node.spec.params.first(where: { $0.key == "f\(i)" }) {
            ParameterRow(param: Self.relabeled(param, "Freq \(i)"),
                         nodeIndex: index, values: node.values, dsp: dsp)
        }
    }

    private func slopeRow(_ i: Int) -> some View {
        let current = Int(DynamicsParams.value(node, "s\(i)").rounded())
        return VStack(spacing: 4) {
            ForEach(Self.slopeRows.indices, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(Self.slopeRows[row], id: \.self) { slope in
                        slopeButton(i, slope: slope, isSelected: current == slope)
                    }
                }
            }
        }
    }

    private func slopeButton(_ i: Int, slope: Int, isSelected: Bool) -> some View {
        Button {
            set("s\(i)", Float(slope))
        } label: {
            // 上流の option と同じ字（同 697）。
            Text("\(abs(slope))dB")
                .font(.system(size: 12, weight: isSelected ? .bold : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .frame(maxWidth: .infinity, minHeight: ETMetrics.hitTarget)
                .background(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                            in: .rect(cornerRadius: ETMetrics.innerRadius, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Slope \(i)")
        .accessibilityValue("\(abs(slope)) dB per octave")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: 値

    private func set(_ key: String, _ value: Float) {
        guard let param = node.spec.params.first(where: { $0.key == key }) else { return }
        dsp.setValue(value, at: index, offset: param.offset)
    }

    /// 名前だけ差し替えた写し。EffectCatalog.swift は生成物なので、
    /// 上流のラベル（同 713 の 'Freq 1 (Hz):'）はここで当てる。
    private static func relabeled(_ param: ETParam, _ label: String) -> ETParam {
        ETParam(name: param.name, key: param.key, label: label, kind: param.kind,
                defaultValue: param.defaultValue, offset: param.offset, count: param.count)
    }
}

// MARK: - フィルタ

/// 図を引くためだけの設計と振幅。channel_divider.js:897-1027 を写したもの。
/// 音を作る側（registerProcessor の中、同 100-200）ではない。
enum ChannelDividerCrossover {

    /// 分岐フィルタ 1 本。channel_divider.js:857 の { freq, slope, type }。
    struct Filter {
        var hz: Double
        var slope: Double
        var isHighpass: Bool
    }

    /// 1 + a1 z^-1 + a2 z^-2 で正規化した双二次。
    struct Biquad {
        var b0 = 0.0
        var b1 = 0.0
        var b2 = 0.0
        var a1 = 0.0
        var a2 = 0.0
    }

    /// 10*log10(1e-20)。上流の下限（同 932）。
    private static let decibelFloor = -200.0

    /// Butterworth_N を 2 回重ねたものが Linkwitz-Riley（同 937-953）。
    /// 12 の倍数でない傾きは上流と同じく空で返す（同 941）。
    static func sections(cutoff: Double, slope: Double, isHighpass: Bool,
                         sampleRate: Double) -> [Biquad] {
        let magnitude = abs(slope)
        guard magnitude > 0, cutoff > 0, magnitude.isFinite,
              magnitude.truncatingRemainder(dividingBy: 12) == 0 else { return [] }
        let designed = butterworth(order: Int(magnitude / 12), cutoff: cutoff,
                                   isHighpass: isHighpass, sampleRate: sampleRate)
        guard !designed.isEmpty else { return [] }
        return designed + designed
    }

    /// 同 955-972。奇数次は 1 次を 1 つ足す。
    static func butterworth(order: Int, cutoff: Double, isHighpass: Bool,
                            sampleRate: Double) -> [Biquad] {
        guard order > 0 else { return [] }
        var out: [Biquad] = []
        if order % 2 != 0,
           let first = firstOrder(cutoff: cutoff, isHighpass: isHighpass, sampleRate: sampleRate) {
            out.append(first)
        }
        for q in qs(order: order) {
            if let section = secondOrder(cutoff: cutoff, q: q, isHighpass: isHighpass,
                                         sampleRate: sampleRate) {
                out.append(section)
            }
        }
        return out
    }

    /// 同 974-984。
    private static func qs(order: Int) -> [Double] {
        let pairs = order / 2
        guard pairs > 0 else { return [] }
        return (1...pairs).map { k -> Double in
            let theta = Double(2 * k - 1) * Double.pi / Double(2 * order)
            return 1 / (2 * sin(theta))
        }
    }

    /// 同 986-1003。双一次変換。周波数は tan で prewarp する。
    private static func firstOrder(cutoff: Double, isHighpass: Bool,
                                   sampleRate: Double) -> Biquad? {
        guard cutoff > 0, cutoff < sampleRate * 0.5 else { return nil }
        let k = 2 * sampleRate
        let omega = 2 * sampleRate * tan(Double.pi * cutoff / sampleRate)
        let a0 = k + omega
        guard a0 != 0 else { return nil }
        let b0 = isHighpass ? -k : omega
        let b1 = isHighpass ? k : omega
        return Biquad(b0: b0 / a0, b1: b1 / a0, b2: 0, a1: (omega - k) / a0, a2: 0)
    }

    /// 同 1005-1027。
    private static func secondOrder(cutoff: Double, q: Double, isHighpass: Bool,
                                    sampleRate: Double) -> Biquad? {
        guard cutoff > 0, cutoff < sampleRate * 0.5 else { return nil }
        let k = 2 * sampleRate
        let omega = 2 * sampleRate * tan(Double.pi * cutoff / sampleRate)
        let kSquaredQ = k * k * q
        let omegaSquaredQ = omega * omega * q
        let a0 = kSquaredQ + k * omega + omegaSquaredQ
        guard a0 != 0 else { return nil }
        let a1 = -2 * kSquaredQ + 2 * omegaSquaredQ
        let a2 = kSquaredQ - k * omega + omegaSquaredQ
        // lp は Om²Q・2Om²Q・Om²Q、hp は K²Q・-2K²Q・K²Q。両端は同じ値。
        let b0 = isHighpass ? kSquaredQ : omegaSquaredQ
        let b1 = isHighpass ? -2 * kSquaredQ : 2 * omegaSquaredQ
        return Biquad(b0: b0 / a0, b1: b1 / a0, b2: b0 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    /// 同 897-934。z^-1 と z^-2 を 1 回だけ作って、節ごとに |分子|²/|分母|² を掛ける。
    static func decibels(hz: Double, sections: [Biquad], sampleRate: Double) -> Double {
        guard hz > 0, !sections.isEmpty else { return 0 }
        let w = 2 * Double.pi * hz / sampleRate
        let z1Real = cos(w)
        let z1Imaginary = -sin(w)
        let z2Real = cos(2 * w)
        let z2Imaginary = -sin(2 * w)

        var squared = 1.0
        for s in sections {
            let numeratorReal = s.b0 + s.b1 * z1Real + s.b2 * z2Real
            let numeratorImaginary = s.b1 * z1Imaginary + s.b2 * z2Imaginary
            let denominatorReal = 1 + s.a1 * z1Real + s.a2 * z2Real
            let denominatorImaginary = s.a1 * z1Imaginary + s.a2 * z2Imaginary
            let numerator = numeratorReal * numeratorReal
                + numeratorImaginary * numeratorImaginary
            let denominator = denominatorReal * denominatorReal
                + denominatorImaginary * denominatorImaginary
            // 上流には無い番人。0 で割ると以降の点が NaN になって線が消える。
            guard denominator > 0 else { return decibelFloor }
            squared *= numerator / denominator
        }
        return 10 * log10(max(squared, 1e-20))
    }
}
