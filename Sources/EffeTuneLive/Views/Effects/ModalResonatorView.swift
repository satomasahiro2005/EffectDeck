//  ModalResonatorView.swift
//  Modal Resonator。共鳴 5 本。
//
//  上流（Vendor/effetune/plugins/resonator/modal_resonator.js:603-674）は
//  Resonator 1..5 のタブで 1 本ずつ出す形で、図は持っていない。
//  ここも「1 本だけ出す」形は同じにして、図を足した。
//  汎用のスライダーのままだと、同じ名前の行が 5 本ずつ 6 種類並び、
//  どの共鳴の話か分からなくなる。
//
//  タブの番号（上流の `sr`）は DSP に無い。カタログの floatCount は 31 で
//  5×6 + mix しかないので、選んでいる番号は画面だけで持つ。
//
//  図は params から引く。テレメトリは無い
//  （dsp/plugins/resonator/modal_resonator/kernel.cpp は何も書き出していない）。
//  式は音が通る側をそのまま Z 領域にしたもの。kernel.cpp:149-163（係数）と
//  188-216（信号）:
//    遅延 D = sampleRate / exp(fr)、読み出しは 1 次補間なので
//      Zd(z) = ((1 - frac) + frac·z⁻¹)·z^-floor(D)
//    帰還は生のまま         comb = Zd / (1 - fb·Zd)
//    出力に 1 次 HPF        ah(1 - z⁻¹) / (1 - ah·z⁻¹)
//    その後に 1 次 LPF      (1 - al) / (1 - al·z⁻¹)
//    5 本を足して、mix の dry/wet（kernel.cpp:141-142）で素の音と混ぜる
//
//  1 本が 1 つの山になる形ではない。遅延と帰還なので山は f0 の整数倍に並ぶ。
//  上流の LPF の既定値は f0 の 1.4 倍あたり（同 js:302-306。理由は
//  "to better match measurement data" としか書いていない）。
//  その上の山が落ちるので、図もそう出る。
//  decay を上げると山が針のように細くなり、512 点では拾いきれずに線が荒れる。
//  山の包絡（|Zd| / (1 - fb·|Zd|)）で描けば滑らかになるが、それだと谷が消えて
//  棚のように見え、共鳴がどこに在るか分からなくなる。
//  96kHz・512 点・mix 25・5 本とも入で測った、隣り合う 2 点の差:
//    既定値（decay 15/12/10/8/6ms）  平均 0.38dB・最大 3.0dB
//    5 本とも decay 40ms             平均 0.75dB・最大 9.3dB
//    5 本とも decay 100ms            平均 1.0dB・最大 17dB（頂点が 2.3dB 低く出る）
//    5 本とも decay 500ms            平均 1.3dB・最大 30dB（同 4.7dB 低く出る）
//  既定値のうちは線が繋がる。荒れるのは decay を上げたときだけ。
//
//  上流との違い:
//    - タブでなく直のボタン。Menu は足さない
//    - 周波数は Hz で出す。上流も数値欄は Hz で、スライダーだけ log 値を持つ
//      （同 js:545-555）。こちらのスライダーも log 値のままなので、
//      つまみの動きは上流と同じ

import SwiftUI
import Foundation

// MARK: - 共鳴 1 本ぶんの params

private struct ModalBand {
    var enabled: Bool
    /// Hz の自然対数。params.json の範囲は 3.00〜9.90（20Hz〜19.9kHz）。
    var frequencyLog: Double
    var decay: Double
    var lowPassLog: Double
    var highPassLog: Double
    var gain: Double
}

// MARK: - 図の式

private struct ModalComplex {
    var re: Double
    var im: Double

    static func * (a: ModalComplex, b: ModalComplex) -> ModalComplex {
        ModalComplex(re: a.re * b.re - a.im * b.im, im: a.re * b.im + a.im * b.re)
    }

    static func / (a: ModalComplex, b: ModalComplex) -> ModalComplex {
        let d = b.re * b.re + b.im * b.im
        guard d > 1e-30 else { return ModalComplex(re: 0, im: 0) }
        return ModalComplex(re: (a.re * b.re + a.im * b.im) / d,
                            im: (a.im * b.re - a.re * b.im) / d)
    }

    var magnitude: Double { (re * re + im * im).squareRoot() }
}

/// 1 本ぶんの係数。周波数ごとに作り直さない値をここに畳んでおく。
/// 中身は kernel.cpp:149-163 と同じ順で出す。
private struct ModalDesign {
    var delayFloor: Double
    var fraction: Double
    var feedback: Double
    var highPassAlpha: Double
    var lowPassAlpha: Double
    var gain: Double
}

private enum ModalMath {

    static func design(_ band: ModalBand, sampleRate: Double) -> ModalDesign? {
        guard band.enabled, sampleRate > 0 else { return nil }
        let frequency = exp(band.frequencyLog)
        guard frequency > 0 else { return nil }
        // 遅延の上限は 2 秒ではなく fr の下限（exp(3)）で決まる。
        // modal_resonator_common.h:13-25 の delayBufferLength と同じ。
        let maximumDelay = max(1.0, (sampleRate / exp(3.0)).rounded(.down))
        let delay = min(max(sampleRate / frequency, 1), maximumDelay)
        var cycles = band.decay * 0.001 * sampleRate / delay
        if cycles < 0.1 { cycles = 0.1 }                      // kernel.cpp:18, 152-154
        let feedback = min(exp(log(0.001) / cycles), 0.999)   // kernel.cpp:19-20, 155-156
        return ModalDesign(
            delayFloor: delay.rounded(.down),
            fraction: delay - delay.rounded(.down),
            feedback: feedback,
            highPassAlpha: exp(-2 * Double.pi * exp(band.highPassLog) / sampleRate),
            lowPassAlpha: exp(-2 * Double.pi * exp(band.lowPassLog) / sampleRate),
            gain: pow(10, band.gain / 20))
    }

    /// 1 本ぶんの H(e^jw)。
    static func response(_ d: ModalDesign, w: Double) -> ModalComplex {
        let cosine = cos(w)
        let sine = sin(w)
        let inverse = ModalComplex(re: cosine, im: -sine)          // z⁻¹

        // 補間した読み出し。位相の回りは floor(D) サンプルぶん。
        let interpolated = ModalComplex(re: (1 - d.fraction) + d.fraction * cosine,
                                        im: -d.fraction * sine)
        let angle = w * d.delayFloor
        let delayed = interpolated * ModalComplex(re: cos(angle), im: -sin(angle))

        let feedbackTerm = ModalComplex(re: 1 - d.feedback * delayed.re,
                                        im: -d.feedback * delayed.im)
        let comb = delayed / feedbackTerm

        let ah = d.highPassAlpha
        let highPass = ModalComplex(re: ah * (1 - inverse.re), im: -ah * inverse.im)
            / ModalComplex(re: 1 - ah * inverse.re, im: -ah * inverse.im)
        let al = d.lowPassAlpha
        let lowPass = ModalComplex(re: 1 - al, im: 0)
            / ModalComplex(re: 1 - al * inverse.re, im: -al * inverse.im)

        return comb * highPass * lowPass * ModalComplex(re: d.gain, im: 0)
    }

    /// dry と wet の割合。kernel.cpp:141-142。
    static func blend(mix: Double) -> (dry: Double, wet: Double) {
        mix < 50 ? (dry: 1.0, wet: mix * 0.02) : (dry: (100 - mix) * 0.02, wet: 1.0)
    }

    /// 5 本を足して素の音と混ぜたもの。dB。
    static func decibels(_ designs: [ModalDesign], mix: Double,
                         hz: Double, sampleRate: Double) -> Double {
        guard sampleRate > 0 else { return 0 }
        let w = 2 * Double.pi * hz / sampleRate
        var sum = ModalComplex(re: 0, im: 0)
        for d in designs {
            let h = response(d, w: w)
            sum.re += h.re
            sum.im += h.im
        }
        let (dry, wet) = blend(mix: mix)
        let total = ModalComplex(re: dry + wet * sum.re, im: wet * sum.im)
        return 20 * log10(max(total.magnitude, 1e-9))
    }
}

// MARK: - packed float 配列での位置

/// 名前は params.json と dsp/generated/cpp/ModalResonatorPluginParams.h で揃っている。
private struct ModalLayout {
    let enabled: Int
    let frequency: Int
    let decay: Int
    let lowPass: Int
    let highPass: Int
    let gain: Int
    let count: Int

    init(_ spec: ETEffect) {
        var offsets: [String: Int] = [:]
        var counts: [String: Int] = [:]
        for p in spec.params {
            offsets[p.name] = p.offset
            counts[p.name] = p.count
        }
        enabled = offsets["resonatorEnabled"] ?? 0
        frequency = offsets["frequencyLog"] ?? 5
        decay = offsets["decay"] ?? 10
        lowPass = offsets["lowPassLog"] ?? 15
        highPass = offsets["highPassLog"] ?? 20
        gain = offsets["gain"] ?? 25
        count = counts["frequencyLog"] ?? 5
    }
}

// MARK: - 値の行

/// 名前・数値欄・スライダーの 2 段。触る先が「選んでいる共鳴」なので、
/// ParameterRow は使わずここに持っている。
private struct ModalSliderRow: View {
    let title: String
    /// 格納されている値。周波数は Hz の自然対数。
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    /// true なら画面には exp(value) を Hz で出す。上流の数値欄と同じ（js:545-555）。
    let hertz: Bool
    let decimals: Int
    let unit: String
    let onChange: (Double) -> Void

    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                field
            }
            ETSlider(value: Binding(get: { value }, set: { onChange(clamped($0)) }),
                     range: range, step: step)
        }
    }

    /// 数値欄。Text に onTapGesture を足す形だと支援技術から操作できないので、
    /// ParameterRow と同じく常に TextField を置く。
    private var field: some View {
        TextField(title, text: Binding(get: { editing ? draft : text },
                                       set: { draft = $0 }))
            .keyboardType(.numbersAndPunctuation)
            .multilineTextAlignment(.center)
            .font(.system(size: 13, design: .monospaced))
            .focused($focused)
            .frame(width: ETMetrics.valueWidth, height: ETMetrics.controlHeight)
            .background(.quaternary, in: .rect(cornerRadius: ETMetrics.innerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: ETMetrics.innerRadius, style: .continuous)
                .stroke(.tint, lineWidth: editing ? 1 : 0))
            .submitLabel(.done)
            .onSubmit { commit() }
            .onChange(of: focused) { _, now in
                if now {
                    draft = plain
                    editing = true
                } else if editing {
                    // 他を触ってキーボードが引っ込んだときも確定させる。
                    commit()
                }
            }
            .accessibilityLabel(title)
            .accessibilityValue(text)
    }

    private var text: String { unit.isEmpty ? plain : "\(plain) \(unit)" }

    private var plain: String {
        hertz ? String(Int(exp(value).rounded())) : String(format: "%.\(decimals)f", value)
    }

    private func commit() {
        editing = false
        focused = false
        guard let typed = Double(draft.trimmingCharacters(in: .whitespaces)) else { return }
        // 周波数は Hz で打ち込ませて、格納は自然対数に直す（js:578-583）。
        onChange(clamped(hertz ? log(max(typed, 1e-6)) : typed))
    }

    private func clamped(_ v: Double) -> Double {
        min(max(v, range.lowerBound), range.upperBound)
    }
}

// MARK: - 本体

struct ModalResonatorView: View {
    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    @Environment(\.etGraphOnly) private var graphOnly

    /// 下の一枚に出している共鳴。図の印を掴むとそこへ移る。
    @State private var selected = 0

    /// fr / lp / hp の範囲（3.00〜9.90）を Hz に直したもの。
    private static let lowestHz = exp(3.0)
    private static let highestHz = exp(9.9)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            graph
            // **畳んだら札も消す。**畳んだ図は allowsHitTesting(false) で押せない
            // （EffectCardView の畳んだ図）ので、押せない札を残しても場所を取るだけ。
            if !graphOnly {
                bandStrip
                Divider()
                bandPanel
                // mix だけは普通の行でよい。配列の行はここに出さない。
                ForEach(node.spec.params.filter { !$0.isArray }) { param in
                    ParameterRow(param: param, nodeIndex: index, values: node.values, dsp: dsp)
                }
            }
        }
        // 畳むとこの View ごと消えるので、選んでいる共鳴は外に覚えておく。
        .etRemembers($selected, key: "band", node: node.id)
    }

    // MARK: 図

    private var graph: some View {
        FrequencyResponseGraph(
            curves: curves,
            markers: markers,
            frequencyRange: 20...20000,
            decibelRange: -24...24,
            decibelStep: 6,
            height: ETGraphMetrics.height,
            onMarkerChanged: { id, hz, db in move(id, hz: hz, db: db) },
            onMarkerSelected: { selected = $0 })
    }

    /// 曲線を引く閉包へ self を渡さないよう、要る値だけ控える。
    private var curves: [ETFrequencyCurve] {
        let rate = sampleRate
        let designs = bands.compactMap { ModalMath.design($0, sampleRate: rate) }
        let mixValue = mix
        return [ETFrequencyCurve.sampled(id: "sum", count: 512) { hz in
            ModalMath.decibels(designs, mix: mixValue, hz: hz, sampleRate: rate)
        }]
    }

    /// 印は共鳴の周波数とゲイン。曲線の高さではない
    /// （山の高さは decay と帰還でも上がるので、印とは揃わない）。
    private var markers: [ETFrequencyMarker] {
        bands.enumerated().map { i, item in
            ETFrequencyMarker(id: i, hz: exp(item.frequencyLog), db: item.gain,
                              label: "\(i + 1)", isActive: item.enabled)
        }
    }

    private func move(_ i: Int, hz: Double, db: Double) {
        let l = layout
        guard i >= 0, i < l.count else { return }
        let clampedHz = min(max(hz, Self.lowestHz), Self.highestHz)
        dsp.setValue(Float(log(clampedHz)), at: index, offset: l.frequency + i)
        dsp.setValue(Float(min(max(db, -18), 18)), at: index, offset: l.gain + i)
    }

    // MARK: 共鳴を選ぶ帯

    private var bandStrip: some View {
        HStack(spacing: 6) {
            ForEach(Array(0..<layout.count), id: \.self) { i in
                chip(i)
            }
        }
    }

    private func chip(_ i: Int) -> some View {
        let isOn = band(i).enabled
        let isPicked = selected == i
        return Button {
            selected = i
        } label: {
            Text("\(i + 1)")
                .font(.system(size: 13, weight: isPicked ? .bold : .regular))
                .foregroundStyle(isPicked ? AnyShapeStyle(.white)
                                          : (isOn ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)))
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(isPicked ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                            in: .rect(cornerRadius: ETMetrics.innerRadius, style: .continuous))
                .opacity(isOn ? 1 : 0.45)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Resonator \(i + 1)")
    }

    // MARK: 選んでいる共鳴

    private var bandPanel: some View {
        let l = layout
        let current = band(selected)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("RESONATOR \(selected + 1)")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                Toggle("Enabled", isOn: Binding(
                    get: { current.enabled },
                    set: { _ in dsp.setValue(current.enabled ? 0 : 1,
                                             at: index, offset: l.enabled + selected) }))
                    .toggleStyle(.power)
                    .labelsHidden()
            }

            // 切っている間は値の行だけ薄くする。見出しと入切は薄くしない。
            // 戻すのがこの入切なので、押せないものに見えてはいけない。
            rows(l, current)
        }
    }

    private func rows(_ l: ModalLayout, _ current: ModalBand) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ModalSliderRow(title: "Freq", value: current.frequencyLog, range: 3...9.9,
                           step: 0.01, hertz: true, decimals: 0, unit: "Hz") { v in
                dsp.setValue(Float(v), at: index, offset: l.frequency + selected)
            }

            ModalSliderRow(title: "Decay", value: current.decay, range: 1...500,
                           step: 1, hertz: false, decimals: 0, unit: "ms") { v in
                dsp.setValue(Float(v), at: index, offset: l.decay + selected)
            }

            ModalSliderRow(title: "LPF", value: current.lowPassLog, range: 3...9.9,
                           step: 0.01, hertz: true, decimals: 0, unit: "Hz") { v in
                dsp.setValue(Float(v), at: index, offset: l.lowPass + selected)
            }

            ModalSliderRow(title: "HPF", value: current.highPassLog, range: 3...9.9,
                           step: 0.01, hertz: true, decimals: 0, unit: "Hz") { v in
                dsp.setValue(Float(v), at: index, offset: l.highPass + selected)
            }

            ModalSliderRow(title: "Gain", value: current.gain, range: -18...18,
                           step: 0.1, hertz: false, decimals: 1, unit: "dB") { v in
                dsp.setValue(Float(v), at: index, offset: l.gain + selected)
            }
        }
        .opacity(current.enabled ? 1 : 0.55)
    }

    // MARK: 値の出し入れ

    private var layout: ModalLayout { ModalLayout(node.spec) }

    private var bands: [ModalBand] { (0..<layout.count).map { band($0) } }

    private func band(_ i: Int) -> ModalBand {
        let l = layout
        return ModalBand(enabled: value(l.enabled + i) >= 0.5,
                         frequencyLog: Double(value(l.frequency + i)),
                         decay: Double(value(l.decay + i)),
                         lowPassLog: Double(value(l.lowPass + i)),
                         highPassLog: Double(value(l.highPass + i)),
                         gain: Double(value(l.gain + i)))
    }

    private var mix: Double {
        guard let param = node.spec.params.first(where: { $0.name == "mix" }) else { return 25 }
        return node.values.indices.contains(param.offset)
            ? Double(node.values[param.offset]) : Double(param.defaultValue)
    }

    private func value(_ offset: Int) -> Float {
        node.values.indices.contains(offset) ? node.values[offset] : 0
    }

    /// 音が通るレート。遅延も帰還もレートで決まるので、実際に回しているものを見る。
    private var sampleRate: Double {
        let rate = AudioIO.shared.processingRate
        return rate > 0 ? rate : 96000
    }
}
