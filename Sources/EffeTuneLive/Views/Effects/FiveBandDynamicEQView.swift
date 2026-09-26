//  FiveBandDynamicEQView.swift
//  5Band Dynamic EQ。バンドごとに動くぶんを含めた周波数特性。
//
//  web 版（plugins/eq/five_band_dynamic_eq.js:949-1128 の _drawGraph）は 3 本引いている。
//    1. 選んでいるバンドのサイドチェーン（同 1058 行・bp を 0dB で引いた形）
//       ＝そのバンドが「どこを聴いているか」
//    2. 選んでいるバンドが目一杯効いたときの形（同 1072-1075 行）
//       ゲインの向きは ratio < 1 なら +mg、そうでなければ -mg（同 1072 行）
//    3. いま実際に効いている量での合成（同 1087-1105 行）
//  ここも同じ 3 本。1 と 2 は薄く、3 を主線にしてある。
//
//  軸も web 版に合わせて 10Hz〜40kHz、-12〜+12 dB（同 980-983 行）。
//
//  効いている量はテレメトリから来る。曲線の形だけこちらで計算する。
//    枠の種類 14（fiveBandDynamicEQ）・版 1・ペイロード 24 バイト
//    書く側 dsp/plugins/eq/five_band_dynamic_eq/kernel.cpp:417-427
//      payload[0]    = u8 バンド数（5）
//      payload[1..3] = 0 のまま（std::array{} で 0 埋め、書いていない）
//      payload[4+4i] = f32 バンド i のゲイン（dB・符号つき）
//    読む側 plugins/eq/five_band_dynamic_eq.js:1358-1378
//      byteLength === 24 / getUint8(0) === 5 / getUint8(1) === 0 /
//      getUint16(2, true) === 0 を確かめ、-24..24 の外は捨てている
//    値は kernel.cpp:372 の smoothed_gain。ブロック最後のフレームの値で、
//    ratio >= 1 なら負（下げる）、ratio < 1 なら正（上げる）になる（同 369 行）。
//
//  フィルタの式は js の _calculateBandResponse（同 1402-1485 行）をそのまま写した。
//  シェルフの Q を 0.7071 に固定するところも web 版と同じ（同 1407 行）。
//
//  曲線は見るだけ。値はバンドを選んでからスライダーで動かす。

import SwiftUI
import Foundation

struct FiveBandDynamicEQView: View {
    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    @Environment(\.etGraphOnly) private var graphOnly

    /// 選んでいるバンド。web 版の既定も Band 3（js:26 の currentBandIndex = 2）。
    @State private var band = 2

    private static let bandCount = 5
    private static let lowHz: Double = 10
    private static let highHz: Double = 40000
    private static let samples = 192

    /// 生成されたカタログは配列の既定値を拾えていない（Tools/gen_catalog.py が list を
    /// float に直せず 0 を入れる）。frequency と sidechainFrequency が 0 のままだと
    /// 図が平らなまま何も出ず、スライダーも範囲（20Hz〜）の外から始まる。
    /// web 版の初期値（five_band_dynamic_eq.js:11 の [100, 300, 1000, 3000, 10000]。
    /// scf は同 22 行で f と同じ値）を最初の 1 回だけ入れる。
    /// enabled と threshold には触らない。あれは音が変わる
    /// （web の既定は en が Band 3 だけ、th が -18 - 3i）。
    private static let initialFrequencies: [Float] = [100, 300, 1000, 3000, 10000]

    var body: some View {
        // 曲線を引く閉包へ self を渡さないよう、要る値だけ控える。
        let bands = (0..<Self.bandCount).map { setting($0) }
        let selected = min(max(band, 0), Self.bandCount - 1)

        return VStack(alignment: .leading, spacing: 12) {
            // **Telemetry を見るのはこの中だけ。**
            // ここで観測していたのを struct ごと外へ出した。30Hz の publish で
            // このビュー全体が作り直されると、下の Filter Type の Picker
            // （iOS では Menu）が提示を終えられず「読み込み中」で固まる。
            // 実機で同じ形を踏んでいる（PipelineView.swift の頭を読むこと）。
            FiveBandDynamicEQGraph(tapId: node.tapId, bands: bands, selected: selected,
                                   lowHz: Self.lowHz, highHz: Self.highHz,
                                   bandCount: Self.bandCount)

            // **畳んだら札も消す。**畳んだ図は allowsHitTesting(false) で押せない
            // （EffectCardView の畳んだ図）ので、押せない札を残しても場所を取るだけ。
            if !graphOnly {
                bandPicker(bands: bands)

                bandParameters
            }
        }
        // 畳むとこの View ごと消えるので、選んでいるバンドは外に覚えておく。
        .etRemembers($band, key: "band", node: node.id)
    }

    // MARK: 曲線

    static func curves(bands: [ETDynamicEQBand], gains: [Double],
                       selected: Int, sampleRate: Double) -> [ETFrequencyCurve] {
        var out: [ETFrequencyCurve] = []
        let current = bands[selected]

        if current.enabled {
            // 1. サイドチェーンの帯。どこを聴いているか。
            out.append(.sampled(id: "sidechain", count: Self.samples,
                                from: Self.lowHz, to: Self.highHz,
                                width: 1, dashed: true, subdued: true) { hz in
                ETDynamicEQResponse.magnitudeDB(hz: hz, centerHz: current.sidechainHz, gainDB: 0,
                                                q: current.sidechainQ, shape: .bandPass,
                                                sampleRate: sampleRate)
            })

            // 2. 目一杯効いたときの形。ratio < 1 は持ち上げ、そうでなければ下げ。
            let limit = current.ratio < 1 ? current.maxGain : -current.maxGain
            out.append(.sampled(id: "limit", count: Self.samples,
                                from: Self.lowHz, to: Self.highHz,
                                width: 1, subdued: true) { hz in
                ETDynamicEQResponse.magnitudeDB(hz: hz, centerHz: current.hz, gainDB: limit,
                                                q: current.q, shape: current.shape,
                                                sampleRate: sampleRate)
            })
        }

        // 3. いま効いている量での合成。
        out.append(.sampled(id: "sum", count: Self.samples,
                            from: Self.lowHz, to: Self.highHz) { hz in
            var total = 0.0
            for (i, b) in bands.enumerated() where b.enabled {
                total += ETDynamicEQResponse.magnitudeDB(hz: hz, centerHz: b.hz,
                                                         gainDB: gains[i], q: b.q,
                                                         shape: b.shape, sampleRate: sampleRate)
            }
            return total
        })

        return out
    }

    static func caption(selected: Int, gains: [Double], live: Bool) -> String {
        let name = "Band \(selected + 1)"
        guard live else { return "\(name)  —" }
        return "\(name)  \(ETFormat.gain(gains[selected]))"
    }

    // MARK: テレメトリ

    /// 読めなければ nil。0 を返すと「効いていない」と「値が無い」の区別がつかない。
    /// 図の struct から呼ぶので static にしてある。
    static func liveGains(telemetry: Telemetry, tapId: UInt32,
                          bandCount: Int) -> [Double]? {
        guard let frame = telemetry.frame(tap: tapId, type: .fiveBandDynamicEQ),
              frame.matches(version: 1),
              frame.hasPayload(bytes: 24) else { return nil }
        let payload = frame.payloadView
        guard payload.u8(at: 0) == UInt8(Self.bandCount),
              payload.u8(at: 1) == 0,
              payload.u16(at: 2) == 0,
              let values = payload.floats(at: 4, count: bandCount) else { return nil }
        var out: [Double] = []
        out.reserveCapacity(values.count)
        for value in values {
            guard value.isFinite, value >= -24, value <= 24 else { return nil }
            out.append(Double(value))
        }
        return out
    }

    // MARK: params

    private func setting(_ index: Int) -> ETDynamicEQBand {
        let type = Int(DynamicsParams.value(node, "ft", band: index).rounded())
        return ETDynamicEQBand(
            enabled: DynamicsParams.value(node, "en", band: index) >= 0.5,
            shape: ETDynamicEQResponse.shape(forFilterType: type),
            hz: DynamicsParams.value(node, "f", band: index),
            q: DynamicsParams.value(node, "q", band: index),
            maxGain: DynamicsParams.value(node, "mg", band: index),
            ratio: DynamicsParams.value(node, "r", band: index),
            sidechainHz: DynamicsParams.value(node, "scf", band: index),
            sidechainQ: DynamicsParams.value(node, "scq", band: index))
    }

    // MARK: バンドを選ぶ

    /// web 版のバンドタブと同じ。切ってあるバンドは薄くする。
    private func bandPicker(bands: [ETDynamicEQBand]) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<Self.bandCount, id: \.self) { i in
                let isSelected = band == i
                Button {
                    band = i
                } label: {
                    VStack(spacing: 1) {
                        Text("\(i + 1)")
                            .font(.system(size: 13, weight: isSelected ? .bold : .regular))
                        Text(ETFormat.hzTick(bands[i].hz))
                            .font(.system(size: 8, design: .monospaced))
                    }
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .background(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                                in: .rect(cornerRadius: ETMetrics.innerRadius, style: .continuous))
                    .opacity(bands[i].enabled ? 1 : 0.45)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: 選んだバンドの値

    private var bandParameters: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(node.spec.params) { param in
                if let label = Self.groupLabel(before: param.key) {
                    Text(label)
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                DynamicEQParameterRow(param: param, band: min(max(band, 0), Self.bandCount - 1),
                                      nodeIndex: index, values: node.values, dsp: dsp)
            }
        }
    }

    /// 12 本を 3 つに割る。並びは EffectCatalog.swift（＝params.json）の順。
    private static func groupLabel(before key: String) -> String? {
        switch key {
        case "en":  return "FILTER"
        case "th":  return "DYNAMICS"
        case "scf": return "SIDECHAIN"
        default:    return nil
        }
    }
}

// MARK: - バンド 1 本ぶんの形

/// 曲線を引くのに要る値だけ。閉包へ持ち込むので View からは切り離してある。
struct ETDynamicEQBand {
    var enabled: Bool
    var shape: ETDynamicEQResponse.Shape
    var hz: Double
    var q: Double
    var maxGain: Double
    var ratio: Double
    var sidechainHz: Double
    var sidechainQ: Double
}

// MARK: - フィルタの形

/// five_band_dynamic_eq.js:1402-1485 の _calculateBandResponse を写したもの。
/// RBJ の双二次を組んで、単位円の上で振幅を測る。
enum ETDynamicEQResponse {

    enum Shape {
        case peaking
        case lowShelf
        case highShelf
        /// サイドチェーンの帯。params.json の filterType には無く、図にだけ出る。
        case bandPass
    }

    /// params.json の filterType は ["pk", "ls", "hs"] の順（EffectCatalog.swift も同じ）。
    static func shape(forFilterType index: Int) -> Shape {
        switch index {
        case 1:  return .lowShelf
        case 2:  return .highShelf
        default: return .peaking
        }
    }

    static func magnitudeDB(hz: Double, centerHz: Double, gainDB: Double,
                            q: Double, shape: Shape, sampleRate: Double) -> Double {
        guard sampleRate > 0, centerHz > 0, hz > 0 else { return 0 }

        let w0 = 2 * Double.pi * centerHz / sampleRate
        let w = 2 * Double.pi * hz / sampleRate
        // シェルフの Q は web 版が 0.7071 に固定している（js:1407）。
        let qValue = (shape == .lowShelf || shape == .highShelf) ? 0.7071 : max(q, 1e-6)
        let alpha = sin(w0) / (2 * qValue)
        let cosw0 = cos(w0)
        let a = pow(10, gainDB / 40)

        var b0 = 1.0, b1 = 0.0, b2 = 0.0
        var a0 = 1.0, a1 = 0.0, a2 = 0.0

        // ゲインが 0 に近いものは素通し扱い。帯域通過だけは形が要るので外す（js:1413）。
        if abs(gainDB) >= 0.01 || shape == .bandPass {
            switch shape {
            case .peaking:
                b0 = 1 + alpha * a
                b1 = -2 * cosw0
                b2 = 1 - alpha * a
                a0 = 1 + alpha / a
                a1 = -2 * cosw0
                a2 = 1 - alpha / a
            case .lowShelf:
                let shelfAlpha = 2 * (a > 0 ? sqrt(a) : 0.0) * alpha
                b0 = a * ((a + 1) - (a - 1) * cosw0 + shelfAlpha)
                b1 = 2 * a * ((a - 1) - (a + 1) * cosw0)
                b2 = a * ((a + 1) - (a - 1) * cosw0 - shelfAlpha)
                a0 = (a + 1) + (a - 1) * cosw0 + shelfAlpha
                a1 = -2 * ((a - 1) + (a + 1) * cosw0)
                a2 = (a + 1) + (a - 1) * cosw0 - shelfAlpha
            case .highShelf:
                let shelfAlpha = 2 * (a > 0 ? sqrt(a) : 0.0) * alpha
                b0 = a * ((a + 1) + (a - 1) * cosw0 + shelfAlpha)
                b1 = -2 * a * ((a - 1) + (a + 1) * cosw0)
                b2 = a * ((a + 1) + (a - 1) * cosw0 - shelfAlpha)
                a0 = (a + 1) - (a - 1) * cosw0 + shelfAlpha
                a1 = 2 * ((a - 1) - (a + 1) * cosw0)
                a2 = (a + 1) - (a - 1) * cosw0 - shelfAlpha
            case .bandPass:
                b0 = alpha
                b1 = 0
                b2 = -alpha
                a0 = 1 + alpha
                a1 = -2 * cosw0
                a2 = 1 - alpha
            }
        }

        let cosw = cos(w)
        let sinw = sin(w)
        let z1re = cosw
        let z1im = -sinw
        let z2re = cosw * cosw - sinw * sinw
        let z2im = -2 * cosw * sinw

        let numeratorRe = b0 + b1 * z1re + b2 * z2re
        let numeratorIm = b1 * z1im + b2 * z2im
        let denominatorRe = a0 + a1 * z1re + a2 * z2re
        let denominatorIm = a1 * z1im + a2 * z2im

        let denominatorSquared = denominatorRe * denominatorRe + denominatorIm * denominatorIm
        guard denominatorSquared > 0, denominatorSquared.isFinite else { return 0 }

        let re = (numeratorRe * denominatorRe + numeratorIm * denominatorIm) / denominatorSquared
        let im = (numeratorIm * denominatorRe - numeratorRe * denominatorIm) / denominatorSquared
        let magnitude = (re * re + im * im).squareRoot()
        guard magnitude > 0, magnitude.isFinite else { return 0 }
        return 20 * log10(magnitude)
    }
}

// MARK: - 値 1 個ぶんの操作

/// ParameterRow のバンド版。あちらは 1 行ごとにバンドを選ぶ作りなので、
/// 12 本並べるとタブが 12 段になる。ここは上で 1 回選んだバンドに全部を向ける。
/// 見た目と打ち込みの動きは ParameterRow に合わせてある。
struct DynamicEQParameterRow: View {
    let param: ETParam
    let band: Int
    let nodeIndex: Int
    let values: [Float]

    @ObservedObject var dsp: EffeTuneDSP
    @State private var editing = false
    @State private var draft = ""

    private static let filterTypeNames = ["pk": "Peak", "ls": "Low Shelf", "hs": "High Shelf"]

    private var offset: Int { param.offset + band }
    private var value: Float { values.indices.contains(offset) ? values[offset] : 0 }

    private func set(_ v: Float) {
        dsp.setValue(v, at: nodeIndex, offset: offset)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch param.kind {
            case .toggle:
                Toggle(isOn: Binding(get: { value >= 0.5 }, set: { set($0 ? 1 : 0) })) {
                    Text(title).font(.system(size: 14))
                }

            case .enumeration(let options):
                HStack {
                    Text(title).font(.system(size: 14))
                    Spacer(minLength: 8)
                    Picker("", selection: Binding(
                        get: { min(max(Int(value.rounded()), 0), max(options.count - 1, 0)) },
                        set: { set(Float($0)) })
                    ) {
                        ForEach(Array(options.enumerated()), id: \.offset) { i, name in
                            Text(Self.filterTypeNames[name] ?? name).tag(i)
                        }
                    }
                    .pickerStyle(.menu)
                }

            case .number(let lo, let hi, let step, _, let isInteger):
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 14))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 4)
                    valueField
                }
                if hi > lo {
                    Slider(
                        value: Binding(get: { Double(value) },
                                       set: { set(isInteger ? Float($0.rounded()) : Float($0)) }),
                        in: Double(lo)...Double(hi),
                        step: step > 0 ? Double(step) : (isInteger ? 1 : 0.0001))
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var title: String { param.label + unitSuffix }

    private var unitSuffix: String {
        if case .number(_, _, _, let unit, _) = param.kind, !unit.isEmpty { return " (\(unit))" }
        return ""
    }

    private var valueField: some View {
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
                ValueBox(text: param.format(value))
                    .onTapGesture {
                        draft = trimmed(value)
                        editing = true
                    }
            }
        }
    }

    private func commit() {
        editing = false
        guard let v = Float(draft.trimmingCharacters(in: .whitespaces)) else { return }
        if case .number(let lo, let hi, _, _, let isInteger) = param.kind {
            let clamped = min(max(v, lo), hi)
            set(isInteger ? clamped.rounded() : clamped)
        } else {
            set(v)
        }
    }

    private func trimmed(_ v: Float) -> String {
        if case .number(_, _, _, _, let isInteger) = param.kind, isInteger {
            return String(Int(v.rounded()))
        }
        return v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
    }
}

/// 図だけ。**Telemetry を観測するのはここだけ。**
///
/// 親（FiveBandDynamicEQView）で観測していたのを切り出した。あちらの配下には
/// Filter Type の Picker があり、iOS では Menu になる。30Hz の publish で
/// 親ごと作り直されると、その Menu が提示を終えられず固まる。
/// 同じ形を MultibandCompressorView と SpectrumAnalyzerView でも使っている。
private struct FiveBandDynamicEQGraph: View {
    let tapId: UInt32
    let bands: [ETDynamicEQBand]
    let selected: Int
    let lowHz: Double
    let highHz: Double
    let bandCount: Int

    @ETTelemetryFeed private var telemetry

    var body: some View {
        let live = FiveBandDynamicEQView.liveGains(telemetry: telemetry,
                                                   tapId: tapId, bandCount: bandCount)
        let gains = live ?? Array(repeating: 0, count: bandCount)
        let rate = AudioIO.shared.processingRate
        let sampleRate = rate > 0 ? rate : 96000

        FrequencyResponseGraph(
            curves: FiveBandDynamicEQView.curves(bands: bands, gains: gains,
                                                 selected: selected, sampleRate: sampleRate),
            frequencyRange: lowHz...highHz,
            decibelRange: -12...12,
            decibelStep: 6,
            caption: FiveBandDynamicEQView.caption(selected: selected, gains: gains,
                                                   live: live != nil))
    }
}
