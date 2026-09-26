//  HarmonicDistortionView.swift
//  Harmonic Distortion（2〜5 次の多項式で歪ませる）。
//
//  伝達曲線は params から引ける。テレメトリは要らない。
//  dsp/plugins/saturation/harmonic_distortion/kernel.cpp に writeTelemetry は無い。
//
//  式は DSP と同じもの（kernel.cpp:29-63）:
//    a2..a5 = -h2..-h5 * 0.01      符号を反転させるのは意図されたもの
//    s      = x * sensitivity
//    y      = s + a2*s^2 + a3*s^3 + a4*s^4 + a5*s^5
//    out    = y * (1 / (sensitivity + 1e-9))
//  web 版の canvas（plugins/saturation/harmonic_distortion.js:231-253）も同じ。
//  1/(sn + 1e-9) の 1e-9 はカーネルの書き方をそのまま写している（sn は 0.1 以上）。

import SwiftUI
import Foundation

struct HarmonicDistortionView: View {
    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    var body: some View {
        let a2 = -SaturationShaperCurve.value(node, "h2") * 0.01
        let a3 = -SaturationShaperCurve.value(node, "h3") * 0.01
        let a4 = -SaturationShaperCurve.value(node, "h4") * 0.01
        let a5 = -SaturationShaperCurve.value(node, "h5") * 0.01
        let sensitivity = SaturationShaperCurve.value(node, "sn")
        let inverse = 1 / (sensitivity + 1e-9)

        return VStack(alignment: .leading, spacing: 12) {
            SaturationShaperCurve(
                shape: { x in
                    let s = x * sensitivity
                    let s2 = s * s
                    let s3 = s2 * s
                    let s4 = s2 * s2
                    let s5 = s4 * s
                    return (s + a2 * s2 + a3 * s3 + a4 * s4 + a5 * s5) * inverse
                })

            ForEach(node.spec.params) { param in
                ParameterRow(param: param, nodeIndex: index, values: node.values, dsp: dsp)
            }
        }
    }
}
