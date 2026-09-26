//  MultibandSaturationView.swift
//  Multiband Saturation。3 バンドに割ってから、バンドごとに tanh で歪ませる。
//
//  テレメトリは要らない。dsp/plugins/saturation/multiband_saturation/kernel.cpp に
//  writeTelemetry は無く、図は全部 params から引ける。
//
//  上流（Vendor/effetune/plugins/saturation/multiband_saturation.js:632-849 の createUI）は
//    - Freq 1 / Freq 2 のスライダー（同 704-705）
//    - Low / Mid / High のタブ（同 716-787）。選んだバンドの dr/bs/mx/gn だけ出す
//    - バンドごとの伝達曲線を 3 つ横に並べる（同 794-836。図を押してもバンドが移る）
//  を持っている。こちらはタブをセグメントにし、3 つ並べた曲線は選んだ 1 本だけにした。
//  iPhone の幅に 3 つ並べると 1 つ 100pt を切り、曲がり方が読めない。
//
//  伝達曲線の式は上流の updateTransferGraphs（同 602-615）と同じで、
//  音を作る側（dsp/plugins/saturation/multiband_saturation/kernel.cpp:141-146）とも一致する:
//      biasOffset = tanh(drive * bias)
//      wet        = tanh(drive * (x + bias)) - biasOffset
//      out        = (x * (1 - mix) + wet * mix) * 10^(gain / 20)
//  軸は上流と同じ線形の振幅 -1..1（同 605-608）。描く土台は SaturationShaperCurve。
//
//  クロスオーバーの図は上流に無い。足したのは、f1 / f2 が数字だけだと
//  どのバンドがどこを担当しているのか読めないため。
//  形は音が通る側と同じ Linkwitz-Riley 4 次（Butterworth 2 次を 2 回。js:126-172 と
//  kernel.cpp の applyFilterBlock が 2 段）で、1 段ぶんの振幅を 2 倍して出している。
//  バンドのゲイン（gn）はこの曲線に足していない。出口の gn は歪ませた後に掛かるので、
//  足すと「フィルタの分け方」と「バンドの音量」が 1 本に混ざる。
//  drive による増減は入力の大きさで変わるので、そもそも 1 本には描けない。

import SwiftUI
import Foundation

struct MultibandSaturationView: View {
    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    @Environment(\.etGraphOnly) private var graphOnly

    /// 選んでいるバンド。上流の既定も Low（js:16 の selectedBand = 0）。
    @State private var band = 0

    /// 上流のタブと同じ並び（js:716）。
    private static let names = ["Low", "Mid", "High"]

    var body: some View {
        // 曲線を引く閉包へ self を渡さないよう、要る値だけ控える。
        let f1 = DynamicsParams.value(node, "f1")
        let f2 = DynamicsParams.value(node, "f2")
        let selected = min(max(band, 0), Self.names.count - 1)
        let drive = DynamicsParams.value(node, "dr", band: selected)
        let bias = DynamicsParams.value(node, "bs", band: selected)
        let mix = DynamicsParams.value(node, "mx", band: selected) / 100
        let gain = pow(10, DynamicsParams.value(node, "gn", band: selected) / 20)
        let biasOffset = tanh(drive * bias)
        let rate = AudioIO.shared.processingRate
        let ranges = Self.ranges(f1: f1, f2: f2)

        // 並べる順は上流と同じ（周波数 → バンドを選ぶ → バンドの値 → 曲線）。
        return VStack(alignment: .leading, spacing: 12) {
            FrequencyResponseGraph(
                curves: MBSCrossover.curves(f1: f1, f2: f2,
                                            sampleRate: rate > 0 ? rate : 96000,
                                            selected: selected),
                markers: [ETFrequencyMarker(id: 0, hz: f1, db: -6, label: "1"),
                          ETFrequencyMarker(id: 1, hz: f2, db: -6, label: "2")],
                decibelRange: -24...6,
                decibelStep: 6,
                height: ETGraphMetrics.compactHeight,
                onMarkerChanged: { marker, hz, _ in
                    moveCrossover(marker, to: hz, f1: f1, f2: f2)
                })

            // f1 / f2 は配列ではないので汎用の行でよい。graph only では自分で消える。
            ForEach(node.spec.params.filter { !$0.isArray }) { param in
                ParameterRow(param: param, nodeIndex: index, values: node.values, dsp: dsp)
            }

            if !graphOnly {
                Divider()

                bandStrip(ranges: ranges, selected: selected)

                // 選んだバンドの dr / bs / mx / gn。行ごとにバンドを選ばせない。
                // DynamicEQParameterRow は 5Band Dynamic EQ 用に書かれたものだが、
                // 中身は「上で選んだバンドへ offset + band で書く ParameterRow」なので
                // そのまま使える（FiveBandDynamicEQView.swift:338）。
                ForEach(node.spec.params.filter { $0.isArray }) { param in
                    DynamicEQParameterRow(param: param, band: selected, nodeIndex: index,
                                          values: node.values, dsp: dsp)
                }
            }

            SaturationShaperCurve(
                shape: { x in
                    let wet = tanh(drive * (x + bias)) - biasOffset
                    return (x * (1 - mix) + wet * mix) * gain
                },
                caption: "\(Self.names[selected]) band, \(ranges[selected]) Hz")
        }
    }

    // MARK: バンドを選ぶ帯

    /// 上流のタブ（js:716-736）に当たるもの。Menu にはしない。
    private func bandStrip(ranges: [String], selected: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(Self.names.indices), id: \.self) { i in
                let isSelected = selected == i
                Button {
                    band = i
                } label: {
                    VStack(spacing: 2) {
                        Text(Self.names[i])
                            .font(.system(size: 13, weight: isSelected ? .bold : .regular))
                        Text(ranges[i])
                            .font(.system(size: 9, design: .monospaced))
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .frame(maxWidth: .infinity, minHeight: ETMetrics.hitTarget)
                    .background(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                                in: .rect(cornerRadius: ETMetrics.innerRadius, style: .continuous))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(Self.names[i]) band")
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
    }

    /// タブに出す担当範囲。20k まで書くと字が潰れるので、境目だけ出す。
    private static func ranges(f1: Double, f2: Double) -> [String] {
        let low = ETFormat.hzTick(f1)
        let high = ETFormat.hzTick(f2)
        return ["< \(low)", "\(low) – \(high)", "> \(high)"]
    }

    // MARK: クロスオーバーを動かす

    /// 丸め方は上流の _normalizeCrossoverFrequencies（js:381-391）と同じ順。
    /// f1 を上げると f2 が押し上げられる。刻みは上流のスライダーと同じ 1Hz。
    private func moveCrossover(_ marker: Int, to hz: Double, f1: Double, f2: Double) {
        guard hz.isFinite else { return }
        var low = f1
        var high = f2
        if marker == 0 { low = hz.rounded() } else { high = hz.rounded() }
        low = min(max(low, 20), 2000)
        high = min(max(high, max(low, 200)), 20000)

        if low != f1, let offset = offset(of: "f1") {
            dsp.setValue(Float(low), at: index, offset: offset)
        }
        if high != f2, let offset = offset(of: "f2") {
            dsp.setValue(Float(high), at: index, offset: offset)
        }
    }

    private func offset(of key: String) -> Int? {
        node.spec.params.first { $0.key == key }?.offset
    }
}

// MARK: - クロスオーバーの形

/// 双二次 1 段ぶんの係数。
private struct MBSBiquad {
    var b0: Double
    var b1: Double
    var b2: Double
    var a1: Double
    var a2: Double
}

/// multiband_saturation.js:126-172 の係数計算をそのまま写したもの。
/// 音が通る側（kernel.cpp）も同じ式で、同じ係数を 2 段掛けている。
private enum MBSCrossover {

    /// Butterworth 2 次の Q。js:133 の 1/(2*sin(π/4)) と同じ。
    private static let q = 1.0 / (2.0 * sin(Double.pi / 4.0))

    private struct Pair {
        var lowpass: MBSBiquad
        var highpass: MBSBiquad
    }

    /// 双一次変換の前に周波数を曲げる（js:140-142）。
    private static func design(_ frequency: Double, sampleRate: Double) -> Pair {
        let maxFreq = max(20.0, sampleRate * 0.5 - 1.0)
        let f = min(max(frequency, 20.0), maxFreq)

        let k = 2.0 * sampleRate
        let om = 2.0 * sampleRate * tan(Double.pi * f / sampleRate)
        let k2 = k * k
        let om2 = om * om
        let k2q = k2 * q
        let om2q = om2 * q
        let a0 = k2q + k * om + om2q
        guard abs(a0) > 1e-18 else {
            let flat = MBSBiquad(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)
            return Pair(lowpass: flat, highpass: flat)
        }
        let a1 = (-2.0 * k2q + 2.0 * om2q) / a0
        let a2 = (k2q - k * om + om2q) / a0

        return Pair(
            lowpass: MBSBiquad(b0: om2q / a0, b1: 2.0 * om2q / a0, b2: om2q / a0, a1: a1, a2: a2),
            highpass: MBSBiquad(b0: k2q / a0, b1: -2.0 * k2q / a0, b2: k2q / a0, a1: a1, a2: a2))
    }

    /// |H(e^jw)| を dB で。1 段ぶん。
    /// 20*log10(sqrt(num/den)) は 10*log10(num/den) と同じなので平方根は取らない。
    private static func magnitudeDB(_ c: MBSBiquad, w: Double) -> Double {
        let cw = cos(w)
        let sw = sin(w)
        let cos2 = 2 * cw * cw - 1
        let sin2 = 2 * sw * cw
        let numeratorRe = c.b0 + c.b1 * cw + c.b2 * cos2
        let numeratorIm = -c.b1 * sw - c.b2 * sin2
        let denominatorRe = 1 + c.a1 * cw + c.a2 * cos2
        let denominatorIm = -c.a1 * sw - c.a2 * sin2
        let den = denominatorRe * denominatorRe + denominatorIm * denominatorIm
        guard den > 1e-18 else { return -120 }
        let num = numeratorRe * numeratorRe + numeratorIm * numeratorIm
        return 10 * log10(max(1e-18, num / den))
    }

    /// 3 本ぶん。選んでいるバンドだけ濃く、最後に描く（他と重なっても見えるように）。
    /// 経路は kernel.cpp と同じで、低域は LP(f1)、中域は HP(f1)→LP(f2)、
    /// 高域は HP(f1)→HP(f2)。どれも 2 段なので 2 倍する。
    static func curves(f1: Double, f2: Double, sampleRate: Double,
                       selected: Int) -> [ETFrequencyCurve] {
        let lower = design(f1, sampleRate: sampleRate)
        let upper = design(f2, sampleRate: sampleRate)
        let scale = 2 * Double.pi / sampleRate

        let shapes: [(String, (Double) -> Double)] = [
            ("low", { hz in
                2 * Self.magnitudeDB(lower.lowpass, w: hz * scale)
            }),
            ("mid", { hz in
                let w = hz * scale
                return 2 * (Self.magnitudeDB(lower.highpass, w: w)
                            + Self.magnitudeDB(upper.lowpass, w: w))
            }),
            ("high", { hz in
                let w = hz * scale
                return 2 * (Self.magnitudeDB(lower.highpass, w: w)
                            + Self.magnitudeDB(upper.highpass, w: w))
            })
        ]

        var out = shapes.enumerated().map { i, entry in
            ETFrequencyCurve.sampled(id: entry.0, count: 200,
                                     width: i == selected ? 2 : 1,
                                     subdued: i != selected,
                                     magnitude: entry.1)
        }
        if out.indices.contains(selected) {
            let picked = out.remove(at: selected)
            out.append(picked)
        }
        return out
    }
}
