//  FifteenBandPEQView.swift
//  15Band PEQ。web 版（Vendor/effetune/plugins/eq/fifteen_band_peq.js）と同じで、
//  75 本のスライダーは出さない。図の印を掴んで動かし、型と Q だけを下の一枚に出す。
//
//  曲線は params から引く。テレメトリは使わない
//  （dsp/plugins/eq/fifteen_band_peq/kernel.cpp は何も書き出していない）。
//  1 本ぶんの式は web 版の calculateBandResponse（fifteen_band_peq.js:1098-1132）と同じで、
//  係数の作り方は音が通る側（dsp/plugins/eq/five_band_peq/peq_coefficients.h:12-147。
//  15Band の kernel.cpp も同じヘッダを使っている）に揃えた。
//
//  印が 15 個あるので、掴む側に 3 つ足してある:
//    - 図を掴むと、最も近い印が選ばれて下の一枚がそのバンドに移る
//      （web も携帯では同じ。fifteen_band_peq.js:399-428 の getNearestBandIndexForGraphPoint）
//    - 下の番号の帯で直に選べる。選んだ番号は勝手に見える位置まで送る
//    - 選んでいる 1 本だけ、合成曲線の脇に破線で出す
//
//  web にあって、ここに無いもの: Import（.txt の EQ 設定の読み込み）。
//  ファイルを開く口がまだ無いので付けていない。Inverse は付けた。

import SwiftUI
import Foundation

// MARK: - バンド 1 本ぶん

private struct PEQ15Band {
    var frequency: Double
    var gain: Double
    var q: Double
    /// params.json の enum の添字。peq_coefficients.h:51 の switch と同じ番号。
    var type: Int
    var enabled: Bool
}

// MARK: - 曲線の式

private enum PEQ15Math {

    /// fifteen_band_peq.js:22-31 の FILTER_TYPES と同じ並び。字は画面用に伸ばしてある。
    static let typeNames = ["Peaking", "Low Pass", "High Pass", "Low Shelf",
                            "High Shelf", "Band Pass", "Notch", "All Pass"]

    /// ls / hs。peq_coefficients.h:32 と同じ判定。
    static func isShelf(_ type: Int) -> Bool { type == 3 || type == 4 }

    /// ゲインを使わない型。peq_coefficients.h:28 の response_without_gain と同じ。
    static func ignoresGain(_ type: Int) -> Bool {
        type == 1 || type == 2 || type == 5 || type == 6 || type == 7
    }

    /// シェルフだけ Q の上限が 2（fifteen_band_peq.js:317-320 / peq_coefficients.h:33）。
    static func maximumQ(_ type: Int) -> Double { isShelf(type) ? 2 : 10 }

    struct Coefficients {
        var b0: Double
        var b1: Double
        var b2: Double
        var a1: Double
        var a2: Double
    }

    /// 1 本ぶんの係数。素通しなら nil。
    static func coefficients(_ band: PEQ15Band, sampleRate: Double) -> Coefficients? {
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

    /// |H(e^jw)| を dB で。fifteen_band_peq.js:1124-1131 と同じ。
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

/// 名前は params.json と dsp/generated/cpp/FifteenBandPEQPluginParams.h で揃っている。
private struct PEQ15Layout {
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
        gain = offsets["gain"] ?? 15
        q = offsets["q"] ?? 30
        type = offsets["filterType"] ?? 45
        enabled = offsets["bandEnabled"] ?? 60
        count = counts["frequency"] ?? 15
    }
}

// MARK: - 値の行

/// 名前・数値欄・スライダーの 2 段。触る先が「選んでいるバンド」なので ParameterRow は使えない。
private struct PEQ15SliderRow: View {
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

struct FifteenBandPEQView: View {
    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    /// 下の一枚に出しているバンド。図を掴むとそこへ移る。
    @State private var selected = 0

    /// 生成されたカタログは配列の既定値を拾えていない
    /// （Tools/gen_catalog.py:101 で list を float に直せず 0 になる）。
    /// 全部 0Hz のままだと印が左端に 15 個重なるので、web 版の初期値
    /// （fifteen_band_peq.js:3-19）を最初の 1 回だけ入れる。
    private static let initialFrequencies: [Float] = [25, 40, 63, 100, 160, 250, 400, 630,
                                                      1000, 1600, 2500, 4000, 6300, 10000, 16000]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            graph
            bandStrip
            Divider()
            bandPanel
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
            height: 190,
            caption: "Drag the nearest marker, or pick a band below",
            onMarkerChanged: { id, hz, db in move(id, hz: hz, db: db) },
            onMarkerSelected: { selected = $0 })
    }

    /// 合成した特性と、選んでいるバンド 1 本ぶん。
    /// 15 本ぶんを全部薄く重ねると図が埋まるので、内訳は選んでいる 1 本だけにしてある。
    private var curves: [ETFrequencyCurve] {
        let rate = sampleRate
        let designed = bands.enumerated().compactMap { pair -> (Int, PEQ15Math.Coefficients)? in
            guard let c = PEQ15Math.coefficients(pair.element, sampleRate: rate) else { return nil }
            return (pair.offset, c)
        }
        var result: [ETFrequencyCurve] = []
        if designed.count > 1, let picked = designed.first(where: { $0.0 == selected }) {
            let c = picked.1
            result.append(ETFrequencyCurve.sampled(id: "band", count: 160,
                                                   width: 1, dashed: true, subdued: true) { hz in
                PEQ15Math.magnitudeDB(c, w: hz * 2 * Double.pi / rate)
            })
        }
        result.append(ETFrequencyCurve.sampled(id: "sum", count: 220) { hz in
            let w = hz * 2 * Double.pi / rate
            var total = 0.0
            for entry in designed { total += PEQ15Math.magnitudeDB(entry.1, w: w) }
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
    /// （fifteen_band_peq.js:1218-1222 の setBand）。
    private func move(_ i: Int, hz: Double, db: Double) {
        let l = layout
        guard i >= 0, i < l.count else { return }
        dsp.setValue(Float(min(max(hz, 20), 20000)), at: index, offset: l.frequency + i)
        dsp.setValue(Float(min(max(db, -20), 20)), at: index, offset: l.gain + i)
    }

    // MARK: バンドを選ぶ帯

    private var bandStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("BANDS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Invert Gains") { invertGains() }
                    .font(.system(size: 12))
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
            }
            numbers
        }
    }

    /// 15 個は横に収まらないので送る。選んだ番号は見える位置まで自分で寄せる
    /// （図を掴んで選ばれたときも同じ）。
    private var numbers: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(Array(0..<layout.count), id: \.self) { i in
                        chip(i).id(i)
                    }
                }
                .padding(.vertical, 1)
            }
            .onChange(of: selected) { _, new in
                withAnimation(.snappy(duration: 0.2)) { proxy.scrollTo(new, anchor: .center) }
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
                .frame(minWidth: 34, minHeight: 30)
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
                    ForEach(Array(PEQ15Math.typeNames.indices), id: \.self) { i in
                        Text(PEQ15Math.typeNames[i]).tag(i)
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

            PEQ15SliderRow(title: "Freq", value: current.frequency, range: 20...20000,
                           logarithmic: true, decimals: 0, unit: "Hz") { v in
                dsp.setValue(Float(v), at: index, offset: l.frequency + selected)
            }

            PEQ15SliderRow(title: "Gain", value: current.gain, range: -20...20,
                           logarithmic: false, decimals: 1, unit: "dB") { v in
                dsp.setValue(Float(v), at: index, offset: l.gain + selected)
            }
            .opacity(PEQ15Math.ignoresGain(current.type) ? 0.5 : 1)

            PEQ15SliderRow(title: "Q", value: current.q,
                           range: 0.1...PEQ15Math.maximumQ(current.type),
                           logarithmic: false, decimals: 2, unit: "") { v in
                dsp.setValue(Float(v), at: index, offset: l.q + selected)
            }
        }
    }

    /// 型を変えたら、シェルフのときだけ Q を 2 に丸める（fifteen_band_peq.js:761-766）。
    private func setType(_ newType: Int) {
        let l = layout
        dsp.setValue(Float(newType), at: index, offset: l.type + selected)
        if PEQ15Math.isShelf(newType), band(selected).q > 2 {
            dsp.setValue(2, at: index, offset: l.q + selected)
        }
    }

    /// web の Inverse ボタン（fifteen_band_peq.js:345-355）。全バンドのゲインの符号を返す。
    private func invertGains() {
        let l = layout
        for i in 0..<l.count {
            dsp.setValue(-value(l.gain + i), at: index, offset: l.gain + i)
        }
    }

    // MARK: 値の出し入れ

    private var layout: PEQ15Layout { PEQ15Layout(node.spec) }

    private var bands: [PEQ15Band] { (0..<layout.count).map { band($0) } }

    private func band(_ i: Int) -> PEQ15Band {
        let l = layout
        return PEQ15Band(frequency: Double(value(l.frequency + i)),
                         gain: Double(value(l.gain + i)),
                         q: Double(value(l.q + i)),
                         type: min(max(Int(value(l.type + i).rounded()), 0),
                                   PEQ15Math.typeNames.count - 1),
                         enabled: value(l.enabled + i) >= 0.5)
    }

    private func value(_ offset: Int) -> Float {
        node.values.indices.contains(offset) ? node.values[offset] : 0
    }

    /// 音が通るレート。EffeTune は _sampleRate をそのまま曲線に使っている
    /// （fifteen_band_peq.js:1099）。こちらは実際に DSP を回しているレートを見る。
    private var sampleRate: Double {
        let rate = AudioIO.shared.processingRate
        return rate > 0 ? rate : 96000
    }

}
