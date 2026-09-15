//  HardClippingView.swift
//  Hard Clipping（しきい値で頭を落とす）。
//
//  伝達曲線は params から引ける。テレメトリは要らない。
//  dsp/plugins/saturation/hard_clipping/kernel.cpp に writeTelemetry は無い。
//
//  式は DSP と同じもの:
//    kernel.cpp:123-125  threshold = (th == 0) ? 1 : 10^(th / 20)
//    kernel.cpp:81-101   mode 0=both / 1=positive / 2=negative で、
//                        超えた側だけ threshold に留める
//  mode の番号は dsp/plugins/saturation/hard_clipping/params.json の values の並び
//  （both, positive, negative）。EffectCatalog.swift も同じ並びで持っている。
//
//  ただしこの曲線は静的な形で、実際のカーネルは 4 倍に上げてから折り、
//  FIR と 1 次 IIR を通して戻す（kernel.cpp:61-110）。角は音では少し鈍る。
//  web 版の canvas（plugins/saturation/hard_clipping.js:258-275）も静的な形を出している。

import SwiftUI
import Foundation

struct HardClippingView: View {
    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    var body: some View {
        let db = SaturationShaperCurve.value(node, "th")
        let threshold = db == 0 ? 1.0 : pow(10, db / 20)
        let mode = SaturationShaperCurve.choice(node, "md")

        // 折れる高さ。留める側だけ線を引く。
        let knees: [Double]
        switch mode {
        case 1:  knees = [threshold]
        case 2:  knees = [-threshold]
        default: knees = [threshold, -threshold]
        }

        return VStack(alignment: .leading, spacing: 12) {
            SaturationShaperCurve(
                shape: { x in
                    switch mode {
                    case 1:  return x > threshold ? threshold : x
                    case 2:  return x < -threshold ? -threshold : x
                    default: return min(max(x, -threshold), threshold)
                    }
                },
                knees: knees,
                caption: "Static curve. The kernel clips at 4x, then filters back down.")

            ForEach(node.spec.params) { param in
                ParameterRow(param: param, nodeIndex: index, values: node.values, dsp: dsp)
            }
        }
    }
}
