//  FiveBandPEQView.swift
//  5Band PEQ。web 版（Vendor/effetune/plugins/eq/five_band_peq.js）と同じ作りにしてある。
//  25 本のスライダーは出さない。図の印を掴んで周波数とゲインを動かし、
//  型と Q だけを下の一枚に出す。
//
//  曲線は params から引く。テレメトリは使わない
//  （dsp/plugins/eq/five_band_peq/kernel.cpp は何も書き出していない）。
//  1 本ぶんの式は web 版の calculateBandResponse（five_band_peq.js:820-854）と同じで、
//  係数の作り方は音が通る側（dsp/plugins/eq/five_band_peq/peq_coefficients.h:12-147）に揃えた。
//
//  web 版との違い:
//    - 横軸は 20Hz〜20kHz。web は 10Hz〜40kHz（同 716 行 freqToX）だが、
//      外側はパラメータの範囲外で掴めない帯になるので、iPhone の幅では詰めた。
//    - Q はホイール（PeqMarkerWheel）が使えないので、選んだバンドのスライダーにした。
//      web もバンドの操作列に同じスライダーを置いている（同 537-549 行）。
//    - バンドの入切は web の右クリック（同 478-482 行）に当たるものが無いので、ON バッジにした。

import SwiftUI
import Foundation

// MARK: - バンド 1 本ぶん

private struct PEQ5Band {
    var frequency: Double
    var gain: Double
    var q: Double
    /// params.json の enum の添字。peq_coefficients.h:51 の switch と同じ番号。
    var type: Int
    var enabled: Bool
}

// MARK: - 曲線の式

private enum PEQ5Math {

    /// five_band_peq.js:12-21 の FILTER_TYPES と同じ並び。字は画面用に伸ばしてある。
    static let typeNames = ["Peaking", "Low Pass", "High Pass", "Low Shelf",
                            "High Shelf", "Band Pass", "Notch", "All Pass"]

    /// ls / hs。peq_coefficients.h:32 と同じ判定。
    static func isShelf(_ type: Int) -> Bool { type == 3 || type == 4 }

    /// ゲインを使わない型。peq_coefficients.h:28 の response_without_gain と同じ。
    static func ignoresGain(_ type: Int) -> Bool {
        type == 1 || type == 2 || type == 5 || type == 6 || type == 7
    }

    /// シェルフだけ Q の上限が 2（five_band_peq.js:296-299 / peq_coefficients.h:33）。
    static func maximumQ(_ type: Int) -> Double { isShelf(type) ? 2 : 10 }

    struct Coefficients {
        var b0: Double
        var b1: Double
        var b2: Double
        var a1: Double
        var a2: Double
    }

    /// 1 本ぶんの係数。素通しなら nil。
    static func coefficients(_ band: PEQ5Band, sampleRate: Double) -> Coefficients? {
        guard band.enabled, sampleRate > 0 else { return nil }
        let type = band.type
        // 0.01dB 未満は素通し（peq_coefficients.h:29-31）。
        if abs(band.gain) < 0.01 && !ignoresGain(type) { return nil }

        var q = band.q
        if isShelf(type) { q = min(q, 2.0) }
        q = max(0.1, q)

        let a = pow(10.0, 0.025 * band.gain)
        let w0 = band.frequency * 2 * Double.pi / sampleRate
        let clamped = min(max(w0, 1e-6), Double.pi - 1e-6)
        let cosine = cos(clamped)
        let sine = sin(clamped)
        let alpha = sine / (2 * q)
        let negTwoCos = -2 * cosine

        var b0 = 0.0
        var b1 = 0.0
        var b2 = 0.0
        var a0 = 1.0
        var a1 = 0.0
        var a2 = 0.0

        switch type {
        case 0:                                   // Peaking
            let alphaA = alpha * a
            let alphaOverA = alpha / a
            b0 = 1 + alphaA
            b1 = negTwoCos
            b2 = 1 - alphaA
            a0 = 1 + alphaOverA
            a1 = negTwoCos
            a2 = 1 - alphaOverA
        case 1:                                   // Low Pass
            let oneMinus = 1 - cosine
            b0 = oneMinus * 0.5
            b1 = oneMinus
            b2 = b0
            a0 = 1 + alpha
            a1 = negTwoCos
            a2 = 1 - alpha
        case 2:                                   // High Pass
            let onePlus = 1 + cosine
            b0 = onePlus * 0.5
            b1 = -onePlus
            b2 = b0
            a0 = 1 + alpha
            a1 = negTwoCos
            a2 = 1 - alpha
        case 3:                                   // Low Shelf
            let sqrtA = (a < 0 ? 0 : a).squareRoot()
            let twoSqrtAalpha = 2 * sqrtA * alpha
            let aPlus = a + 1
            let aMinus = a - 1
            let one = aPlus - aMinus * cosine
            let two = aPlus + aMinus * cosine
            b0 = a * (one + twoSqrtAalpha)
            b1 = 2 * a * (aMinus - aPlus * cosine)
            b2 = a * (one - twoSqrtAalpha)
            a0 = two + twoSqrtAalpha
            a1 = -2 * (aMinus + aPlus * cosine)
            a2 = two - twoSqrtAalpha
        case 4:                                   // High Shelf
            let sqrtA = (a < 0 ? 0 : a).squareRoot()
            let twoSqrtAalpha = 2 * sqrtA * alpha
            let aPlus = a + 1
            let aMinus = a - 1
            let one = aPlus + aMinus * cosine
            let two = aPlus - aMinus * cosine
            b0 = a * (one + twoSqrtAalpha)
            b1 = -2 * a * (aMinus + aPlus * cosine)
            b2 = a * (one - twoSqrtAalpha)
            a0 = two + twoSqrtAalpha
            a1 = 2 * (aMinus - aPlus * cosine)
            a2 = two - twoSqrtAalpha
        case 5:                                   // Band Pass
            b0 = alpha
            b1 = 0
            b2 = -alpha
            a0 = 1 + alpha
            a1 = negTwoCos
            a2 = 1 - alpha
        case 6:                                   // Notch
            b0 = 1
            b1 = negTwoCos
            b2 = 1
            a0 = 1 + alpha
            a1 = negTwoCos
            a2 = 1 - alpha
        case 7:                                   // All Pass
            b0 = 1 - alpha
            b1 = negTwoCos
            b2 = 1 + alpha
            a0 = 1 + alpha
            a1 = negTwoCos
            a2 = 1 - alpha
        default:
            return nil
        }

        guard abs(a0) >= 1e-8 else { return nil }  // peq_coefficients.h:140-143
        let inverse = 1 / a0
        return Coefficients(b0: b0 * inverse, b1: b1 * inverse, b2: b2 * inverse,
                            a1: a1 * inverse, a2: a2 * inverse)
    }

    /// |H(e^jw)| を dB で。five_band_peq.js:846-853 と同じ。
    /// 20*log10(sqrt(num/den)) は 10*log10(num/den) と同じなので平方根は取らない。
    static func magnitudeDB(_ c: Coefficients, w: Double) -> Double {
        let cw = cos(w)
        let sw = sin(w)
        let cos2 = 2 * cw * cw - 1
        let sin2 = 2 * sw * cw
        let numRe = c.b0 + c.b1 * cw + c.b2 * cos2
        let numIm = -c.b1 * sw - c.b2 * sin2
        let denRe = 1 + c.a1 * cw + c.a2 * cos2
        let denIm = -c.a1 * sw - c.a2 * sin2
        let den = denRe * denRe + denIm * denIm
        // web はここで -Infinity を返す。足し合わせが壊れるので図の下端まで落とすだけにする。
        guard den > 1e-18 else { return -120 }
        let num = numRe * numRe + numIm * numIm
        return 10 * log10(max(1e-18, num / den))
    }
}

// MARK: - packed float 配列での位置

/// 名前は params.json と dsp/generated/cpp/FiveBandPEQPluginParams.h で揃っている。
private struct PEQ5Layout {
    let frequency: Int
    let gain: Int
    let q: Int
    let type: Int
    let enabled: Int
    let count: Int

    init(_ spec: ETEffect) {
        var offsets: [String: Int] = [:]
        var counts: [String: Int] = [:]
        for p in spec.params {
            offsets[p.name] = p.offset
            counts[p.name] = p.count
        }
        frequency = offsets["frequency"] ?? 0
        gain = offsets["gain"] ?? 5
        q = offsets["q"] ?? 10
        type = offsets["filterType"] ?? 15
        enabled = offsets["bandEnabled"] ?? 20
        count = counts["frequency"] ?? 5
    }
}

// MARK: - 値の行

/// 名前・数値欄・スライダーの 2 段。ParameterRow と同じ形だが、
/// 触る先が「選んでいるバンド」なので別に持っている。
private struct PEQ5SliderRow: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    /// 周波数だけ対数。線形だと 20〜200Hz が数ポイントに潰れる。
    let logarithmic: Bool
    let decimals: Int
    let unit: String
    let onChange: (Double) -> Void

    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                field
            }
            Slider(value: Binding(get: { position },
                                  set: { onChange(denormalized($0)) }),
                   in: 0...1)
        }
    }

    private var text: String {
        let s = String(format: "%.\(decimals)f", value)
        return unit.isEmpty ? s : "\(s) \(unit)"
    }

    private var field: some View {
        Group {
            if editing {
                TextField("", text: $draft)
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(width: ETMetrics.valueWidth, height: ETMetrics.controlHeight)
                    .background(.quaternary, in: .rect(cornerRadius: ETMetrics.innerRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: ETMetrics.innerRadius, style: .continuous).stroke(.tint, lineWidth: 1))
                    .submitLabel(.done)
                    .onSubmit { commit() }
            } else {
                ValueBox(text: text)
                    .onTapGesture {
                        draft = String(format: "%.\(decimals)f", value)
                        editing = true
                    }
            }
        }
    }

    private func commit() {
        editing = false
        guard let v = Double(draft.trimmingCharacters(in: .whitespaces)) else { return }
        onChange(min(max(v, range.lowerBound), range.upperBound))
    }

    /// スライダーは 0〜1 で持つ。
    private var position: Double {
        let lo = range.lowerBound
        let hi = range.upperBound
        guard hi > lo else { return 0 }
        let t: Double
        if logarithmic {
            let low = log10(max(lo, 1e-9))
            let high = log10(max(hi, lo * 1.000001))
            t = (log10(max(value, 1e-9)) - low) / (high - low)
        } else {
            t = (value - lo) / (hi - lo)
        }
        return t.isFinite ? min(max(t, 0), 1) : 0
    }

    private func denormalized(_ t: Double) -> Double {
        let lo = range.lowerBound
        let hi = range.upperBound
        if logarithmic {
            let low = log10(max(lo, 1e-9))
            let high = log10(max(hi, lo * 1.000001))
            return pow(10, low + t * (high - low))
        }
        return lo + t * (hi - lo)
    }
}

// MARK: - 本体

struct FiveBandPEQView: View {
    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    /// カードの頭のボタンで立つ。図だけにして、下のつまみを畳む。
    @Environment(\.etGraphOnly) private var graphOnly

    /// 下の一枚に出しているバンド。図を掴むとそこへ移る。
    @State private var selected = 0

    /// 生成されたカタログは配列の既定値を拾えていない
    /// （Tools/gen_catalog.py:101 で list を float に直せず 0 になる）。
    /// 全部 0Hz のままだと印が左端に重なるので、web 版の初期値
    /// （five_band_peq.js:3-9）を最初の 1 回だけ入れる。
    private static let initialFrequencies: [Float] = [100, 316, 1000, 3160, 10000]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            graph
            // 図だけのときも帯は残す。どのバンドを見ているかが図の印と対応していて、
            // 消すと選べなくなる（図の印を掴めば選べるが、細い）。
            bandStrip
            if !graphOnly {
                Divider()
                bandPanel
            }
        }
    }

    // MARK: 図

    private var graph: some View {
        FrequencyResponseGraph(
            curves: curves,
            markers: markers,
            frequencyRange: 20...20000,
            decibelRange: -20...20,
            decibelStep: 6,
            height: ETGraphMetrics.height,
            caption: "Drag a marker — across for frequency, up for gain",
            onMarkerChanged: { id, hz, db in move(id, hz: hz, db: db) },
            onMarkerSelected: { selected = $0 })
    }

    /// 合成した特性と、選んでいるバンド 1 本ぶん。
    private var curves: [ETFrequencyCurve] {
        let rate = sampleRate
        let designed = bands.enumerated().compactMap { pair -> (Int, PEQ5Math.Coefficients)? in
            guard let c = PEQ5Math.coefficients(pair.element, sampleRate: rate) else { return nil }
            return (pair.offset, c)
        }
        var result: [ETFrequencyCurve] = []
        // 選んでいる 1 本。合成が平らでも、いま何を触っているかが見えるように。
        if designed.count > 1, let picked = designed.first(where: { $0.0 == selected }) {
            let c = picked.1
            result.append(ETFrequencyCurve.sampled(id: "band", count: 160,
                                                   width: 1, dashed: true, subdued: true) { hz in
                PEQ5Math.magnitudeDB(c, w: hz * 2 * Double.pi / rate)
            })
        }
        result.append(ETFrequencyCurve.sampled(id: "sum", count: 220) { hz in
            let w = hz * 2 * Double.pi / rate
            var total = 0.0
            for entry in designed { total += PEQ5Math.magnitudeDB(entry.1, w: w) }
            return total
        })
        return result
    }

    private var markers: [ETFrequencyMarker] {
        bands.enumerated().map { i, item in
            ETFrequencyMarker(id: i, hz: item.frequency, db: item.gain,
                              label: "\(i + 1)", isActive: item.enabled)
        }
    }

    /// 印を動かすと、web と同じく周波数とゲインが同時に変わる
    /// （five_band_peq.js:942-946 の setBand）。
    private func move(_ i: Int, hz: Double, db: Double) {
        let l = layout
        guard i >= 0, i < l.count else { return }
        dsp.setValue(Float(min(max(hz, 20), 20000)), at: index, offset: l.frequency + i)
        dsp.setValue(Float(min(max(db, -20), 20)), at: index, offset: l.gain + i)
    }

    // MARK: バンドを選ぶ帯

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
        }
        .buttonStyle(.plain)
    }

    // MARK: 選んでいるバンド

    private var bandPanel: some View {
        let l = layout
        let current = band(selected)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("BAND \(selected + 1)")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)

                Picker("", selection: Binding(get: { current.type },
                                              set: { setType($0) })) {
                    ForEach(Array(PEQ5Math.typeNames.indices), id: \.self) { i in
                        Text(PEQ5Math.typeNames[i]).tag(i)
                    }
                }
                .pickerStyle(.menu)

                Spacer(minLength: 0)

                Toggle("Enabled", isOn: Binding(
                    get: { current.enabled },
                    set: { _ in dsp.setValue(current.enabled ? 0 : 1, at: index, offset: l.enabled + selected) }))
                    .toggleStyle(.power)
                    .labelsHidden()
            }

            PEQ5SliderRow(title: "Freq", value: current.frequency, range: 20...20000,
                          logarithmic: true, decimals: 0, unit: "Hz") { v in
                dsp.setValue(Float(v), at: index, offset: l.frequency + selected)
            }

            PEQ5SliderRow(title: "Gain", value: current.gain, range: -20...20,
                          logarithmic: false, decimals: 1, unit: "dB") { v in
                dsp.setValue(Float(v), at: index, offset: l.gain + selected)
            }
            .opacity(PEQ5Math.ignoresGain(current.type) ? 0.5 : 1)

            PEQ5SliderRow(title: "Q", value: current.q,
                          range: 0.1...PEQ5Math.maximumQ(current.type),
                          logarithmic: false, decimals: 2, unit: "") { v in
                dsp.setValue(Float(v), at: index, offset: l.q + selected)
            }
        }
    }

    /// 型を変えたら、シェルフのときだけ Q を 2 に丸める（five_band_peq.js:301-307）。
    private func setType(_ newType: Int) {
        let l = layout
        dsp.setValue(Float(newType), at: index, offset: l.type + selected)
        if PEQ5Math.isShelf(newType), band(selected).q > 2 {
            dsp.setValue(2, at: index, offset: l.q + selected)
        }
    }

    // MARK: 値の出し入れ

    private var layout: PEQ5Layout { PEQ5Layout(node.spec) }

    private var bands: [PEQ5Band] { (0..<layout.count).map { band($0) } }

    private func band(_ i: Int) -> PEQ5Band {
        let l = layout
        return PEQ5Band(frequency: Double(value(l.frequency + i)),
                        gain: Double(value(l.gain + i)),
                        q: Double(value(l.q + i)),
                        type: min(max(Int(value(l.type + i).rounded()), 0),
                                  PEQ5Math.typeNames.count - 1),
                        enabled: value(l.enabled + i) >= 0.5)
    }

    private func value(_ offset: Int) -> Float {
        node.values.indices.contains(offset) ? node.values[offset] : 0
    }

    /// 音が通るレート。EffeTune は _sampleRate をそのまま曲線に使っている
    /// （five_band_peq.js:821。届く前は 96000）。こちらは実際に DSP を回しているレートを見る。
    private var sampleRate: Double {
        let rate = AudioIO.shared.processingRate
        return rate > 0 ? rate : 96000
    }

}
