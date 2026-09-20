//  15BandGEQView.swift
//  15Band GEQ（FifteenBandGEQPlugin）。触るのはバンドごとのゲイン 15 本だけで、
//  周波数と Q は動かない（kernel.cpp:20-22 の kQ = 2.1 と kFrequencies）。
//
//  web 版（Vendor/effetune/plugins/eq/fifteen_band_geq.js:283-390 の createUI）は
//  縦スライダー 15 本と応答の図を並べている。図の作りはそのまま写した:
//    横 20Hz〜20kHz の対数、格子は 20/50/100/200/500/1k/2k/5k/10k/20k（js:453）
//    縦 -24〜+24dB、線は 6dB ごと（js:463）
//    曲線は 15 本ぶんの dB を足したもの（js:492-497）
//
//  縦スライダー 15 本は携帯の幅に入らないので、
//    - 図の印を掴んでそのバンドのゲインを動かす（横には動かない。周波数は固定）
//    - 下の帯で直にバンドを選び、選んだ 1 本だけスライダーを出す
//  の 2 つに置き換えてある。web の dblclick（js:332-337、そのバンドを 0 に戻す）は
//  Reset Band、Reset ボタン（js:362-373）は Reset All に当てた。
//
//  テレメトリは使わない。kernel.cpp は何も書き出していないので、
//  曲線は params から引く。式は js:408-440 の biquadMag と同じ。

import SwiftUI
import Foundation

// MARK: - 曲線の式

private enum GEQ15Math {

    /// js:2-18 の BANDS。kernel.cpp:21-22 の kFrequencies と同じ並び。
    static let frequencies: [Double] = [25, 40, 63, 100, 160, 250, 400, 630,
                                        1000, 1600, 2500, 4000, 6300, 10000, 16000]

    /// 帯に出す字。js の name（'1.0 kHz'）は幅を食うので詰めてある。
    static let names = ["25", "40", "63", "100", "160", "250", "400", "630",
                        "1k", "1.6k", "2.5k", "4k", "6.3k", "10k", "16k"]

    /// js:3-17 の name をそのまま。読み上げと見出しに使う。
    static let fullNames = ["25 Hz", "40 Hz", "63 Hz", "100 Hz", "160 Hz", "250 Hz",
                            "400 Hz", "630 Hz", "1.0 kHz", "1.6 kHz", "2.5 kHz",
                            "4.0 kHz", "6.3 kHz", "10 kHz", "16 kHz"]

    static func fullName(_ i: Int) -> String {
        fullNames.indices.contains(i) ? fullNames[i] : "Band \(i + 1)"
    }

    /// 全バンド共通。kernel.cpp:20 kQ / js:25 Q_FACTOR。
    static let q = 2.1

    /// これ未満のゲインは素通し。kernel.cpp と js:23 GAIN_BYPASS_THRESHOLD。
    static let bypassThreshold = 0.01

    static let gainRange: ClosedRange<Double> = -12...12

    struct Coefficients {
        var b0: Double
        var b1: Double
        var b2: Double
        var a1: Double
        var a2: Double
    }

    /// ピーキング 1 本ぶん。素通しなら nil。
    /// A の作り方は音が通る側に合わせてある（kernel.cpp:141 の sqrt(10^(0.05*g))）。
    static func coefficients(gain: Double, frequency: Double,
                             sampleRate: Double) -> Coefficients? {
        guard abs(gain) >= bypassThreshold, sampleRate > 0 else { return nil }

        let a = pow(10.0, 0.05 * gain).squareRoot()
        let w0 = frequency * 2 * Double.pi / sampleRate
        let clamped = min(max(w0, 1e-6), Double.pi - 1e-6)
        let cosine = cos(clamped)
        let sine = sin(clamped)
        let alpha = sine / (2 * q)
        let alphaA = alpha * a
        let alphaOverA = alpha / a
        let negTwoCos = -2 * cosine

        let a0 = 1 + alphaOverA
        guard abs(a0) >= 1e-8 else { return nil }   // js:119-121 の A0_THRESHOLD
        let inverse = 1 / a0
        return Coefficients(b0: (1 + alphaA) * inverse,
                            b1: negTwoCos * inverse,
                            b2: (1 - alphaA) * inverse,
                            a1: negTwoCos * inverse,
                            a2: (1 - alphaOverA) * inverse)
    }

    /// |H(e^jw)| を dB で。js:429-439 と同じ。
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
        guard den > 1e-18 else { return -120 }
        let num = numRe * numRe + numIm * numIm
        return 10 * log10(max(1e-18, num / den))
    }
}

// MARK: - 値の行

/// 名前・数値欄・スライダーの 2 段。触る先が「選んでいるバンド」なので ParameterRow は使えない。
private struct GEQ15GainRow: View {
    let title: String
    let value: Double
    let onChange: (Double) -> Void

    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    private let range = GEQ15Math.gainRange

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                field
            }
            Slider(value: Binding(get: { min(max(value, range.lowerBound), range.upperBound) },
                                  set: { onChange($0) }),
                   in: range)
        }
    }

    private var text: String { String(format: "%+.1f dB", value) }

    /// 作りは ParameterRow.swift:104-134 と同じ。
    /// 触ったら TextField に差し替える形にすると 2 つ落ちる:
    ///   - Text は支援技術から操作できない（ボタンでもテキスト欄でもない）
    ///   - 打った後に他を触って抜けると、値が渡らないまま消える。
    ///     しかも editing が立ったままなので、次に選んだバンドへ古い draft が入る
    /// だから欄は常に置き、編集していない間は書式付きの値を出す。
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
                    draft = String(format: "%.1f", value)
                    editing = true
                } else if editing {
                    commit()
                }
            }
            .accessibilityLabel(title)
            .accessibilityValue(text)
    }

    private func commit() {
        editing = false
        focused = false
        guard let v = Double(draft.trimmingCharacters(in: .whitespaces)) else { return }
        onChange(min(max(v, range.lowerBound), range.upperBound))
    }
}

// MARK: - 本体

struct FifteenBandGEQView: View {

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    @Environment(\.etGraphOnly) private var graphOnly

    /// 下の一枚に出しているバンド。図を掴むとそこへ移る。
    @State private var selected = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            graph
            // **畳んだら札も消す。**畳んだ図は allowsHitTesting(false) で押せない
            // （EffectCardView の畳んだ図）ので、押せない札を残しても場所を取るだけ。
            if !graphOnly {
                bandStrip
                Divider()
                bandPanel
            }
        }
        // 畳むとこの View ごと消えるので、選んでいるバンドは外に覚えておく。
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
            height: 190,
            caption: "Drag a handle for that band's gain. Frequencies are fixed.",
            onMarkerChanged: { id, _, db in setGain(id, db) },
            onMarkerSelected: { selected = $0 })
    }

    /// 合成した特性と、選んでいるバンド 1 本ぶん。
    /// 15 本ぶんを全部薄く重ねると図が埋まるので、内訳は選んでいる 1 本だけにしてある。
    private var curves: [ETFrequencyCurve] {
        let rate = sampleRate
        let designed = (0..<bandCount).compactMap { i -> (Int, GEQ15Math.Coefficients)? in
            guard i < GEQ15Math.frequencies.count,
                  let c = GEQ15Math.coefficients(gain: gain(i),
                                                 frequency: GEQ15Math.frequencies[i],
                                                 sampleRate: rate) else { return nil }
            return (i, c)
        }
        var result: [ETFrequencyCurve] = []
        if designed.count > 1, let picked = designed.first(where: { $0.0 == selected }) {
            let c = picked.1
            result.append(ETFrequencyCurve.sampled(id: "band", count: 160,
                                                   width: 1, dashed: true, subdued: true) { hz in
                GEQ15Math.magnitudeDB(c, w: hz * 2 * Double.pi / rate)
            })
        }
        result.append(ETFrequencyCurve.sampled(id: "sum", count: 220) { hz in
            let w = hz * 2 * Double.pi / rate
            var total = 0.0
            for entry in designed { total += GEQ15Math.magnitudeDB(entry.1, w: w) }
            return total
        })
        return result
    }

    /// 印はバンドの周波数に釘付け。動くのは縦だけ。
    private var markers: [ETFrequencyMarker] {
        (0..<bandCount).map { i in
            ETFrequencyMarker(id: i,
                              hz: i < GEQ15Math.frequencies.count ? GEQ15Math.frequencies[i] : 1000,
                              db: gain(i),
                              label: "\(i + 1)")
        }
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
                textButton("Reset All") { resetAll() }
            }
            chips
        }
    }

    /// 15 個は横に収まらないので送る。選んだ番号は見える位置まで自分で寄せる
    /// （図を掴んで選ばれたときも同じ）。
    private var chips: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(Array(0..<bandCount), id: \.self) { i in
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
        let isPicked = selected == i
        // 0dB のバンドは素通し（js:84-86）。字を薄くしてそれが分かるようにする。
        let isFlat = abs(gain(i)) < GEQ15Math.bypassThreshold
        return Button {
            selected = i
        } label: {
            VStack(spacing: 1) {
                Text(i < GEQ15Math.names.count ? GEQ15Math.names[i] : "\(i + 1)")
                    .font(.system(size: 12, weight: isPicked ? .bold : .regular))
                Text(String(format: "%+.1f", gain(i)))
                    .font(.system(size: 10, design: .monospaced))
                    .opacity(isFlat ? 0.45 : 1)
            }
            .foregroundStyle(isPicked ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .frame(minWidth: ETMetrics.hitTarget, minHeight: ETMetrics.hitTarget)
            .padding(.horizontal, 6)
            .background(isPicked ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                        in: .rect(cornerRadius: ETMetrics.innerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(GEQ15Math.fullName(i))
    }

    // MARK: 選んでいるバンド

    private var bandPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("BAND \(selected + 1) · \(GEQ15Math.fullName(selected))")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                textButton("Reset Band") { setGain(selected, 0) }
            }

            // バンドを変えたら欄の中身は捨てる。id を付けないと打ちかけの draft が
            // そのまま残り、次のバンドへ入ってしまう。
            GEQ15GainRow(title: "Gain", value: gain(selected)) { v in
                setGain(selected, v)
            }
            .id(selected)
        }
    }

    /// 字だけのボタン。当たり判定は 44pt まで広げる。
    /// contentShape は label の中に置く。外に付けても Button の受ける面は label のままになる。
    private func textButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.tint)
                .frame(minWidth: ETMetrics.hitTarget, minHeight: ETMetrics.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 値の出し入れ

    /// カタログの bandGain は offset 0 / count 15（Generated/EffectCatalog.swift:406）。
    /// 生成物が変わっても壊れないように名前で引く。
    private var gainOffset: Int {
        node.spec.params.first(where: { $0.name == "bandGain" })?.offset ?? 0
    }

    private var bandCount: Int {
        let n = node.spec.params.first(where: { $0.name == "bandGain" })?.count ?? 15
        return min(max(n, 1), GEQ15Math.frequencies.count)
    }

    private func gain(_ i: Int) -> Double {
        let offset = gainOffset + i
        return node.values.indices.contains(offset) ? Double(node.values[offset]) : 0
    }

    /// params.json の step が 0.1 なので、図を掴んだときも 0.1 に丸める。
    private func setGain(_ i: Int, _ db: Double) {
        guard i >= 0, i < bandCount else { return }
        let clamped = min(max(db, GEQ15Math.gainRange.lowerBound), GEQ15Math.gainRange.upperBound)
        dsp.setValue(Float((clamped * 10).rounded() / 10), at: index, offset: gainOffset + i)
    }

    private func resetAll() {
        for i in 0..<bandCount {
            dsp.setValue(0, at: index, offset: gainOffset + i)
        }
    }

    /// 音が通るレート。web は _sampleRate をそのまま曲線に使っている（js:403）。
    /// こちらは実際に DSP を回しているレートを見る。
    private var sampleRate: Double {
        let rate = AudioIO.shared.processingRate
        return rate > 0 ? rate : 96000
    }
}
