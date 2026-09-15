//  SaturationView.swift
//  Saturation（tanh の波形整形）。
//
//  伝達曲線は params から引ける。テレメトリは要らない。
//  dsp/plugins/saturation/saturation/kernel.cpp は writeTelemetry を持っていない
//  （saturation 分類で枠を出しているのは tube_simulator だけ）。
//
//  式は DSP と同じもの:
//    kernel.cpp:35-39
//      shaped = drive * (dry + bias)
//      wet    = tanh(shaped) - biasOffset
//      out    = (dry * (1 - mix) + wet * mix) * gain
//    kernel.cpp:48-51
//      mix        = mx / 100
//      gain       = 10^(gn / 20)
//      biasOffset = tanh(drive * bias)
//  web 版の canvas（plugins/saturation/saturation.js:201-206）も同じ式で引いている。
//
//  曲線は見るだけ。値はスライダーで動かす。

import SwiftUI
import Foundation

struct SaturationView: View {
    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    var body: some View {
        // 閉包へ node ごと渡さないよう、先に数値にしておく。
        let drive = SaturationShaperCurve.value(node, "dr")
        let bias = SaturationShaperCurve.value(node, "bs")
        let mix = SaturationShaperCurve.value(node, "mx") / 100
        let gain = pow(10, SaturationShaperCurve.value(node, "gn") / 20)
        let biasOffset = tanh(drive * bias)

        return VStack(alignment: .leading, spacing: 12) {
            SaturationShaperCurve(
                shape: { x in
                    let wet = tanh(drive * (x + bias)) - biasOffset
                    return (x * (1 - mix) + wet * mix) * gain
                },
                caption: "Drive, bias and mix shape the curve. Gain scales it.")

            ForEach(node.spec.params) { param in
                ParameterRow(param: param, nodeIndex: index, values: node.values, dsp: dsp)
            }
        }
    }
}
