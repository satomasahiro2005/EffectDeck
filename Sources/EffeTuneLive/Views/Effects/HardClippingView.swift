//  HardClippingView.swift
//  Hard Clipping（しきい値で頭を落とす）。
//
//  伝達曲線は params から引ける。テレメトリは要らない。
//  dsp/plugins/saturation/hard_clipping/kernel.cpp に writeTelemetry は無い。
//
//  式は DSP と同じもの:
//    kernel.cpp:153-157  threshold = (th == 0) ? 1 : 10^(th / 20)
//    kernel.cpp:76-80, 104-125  mode 0=both / 1=positive / 2=negative で、
//                        超えた側だけ threshold に留める
//  mode の番号は dsp/plugins/saturation/hard_clipping/params.json の values の並び
//  （both, positive, negative）。EffectCatalog.swift も同じ並びで持っている。
//
//  ただしこの曲線は静的な形で、実際のカーネルは上げてから折って戻す。角は音では少し鈍る。
//  **何倍で折るかは os で変わる。**
//    os = 1       4 倍に線形補間して折り、FIR と 1 次 IIR で戻す（kernel.cpp:87-141）。遅れ 0
//    os = 2〜16   その倍率の polyphase で上げて折り、FIR で戻す（kernel.cpp:68-85、
//                 dsp/include/effetune/dsp/oversampled_shaper.h）。遅れ 64 サンプル
//  許されない os はカーネルが 1 として扱う（OversampledShaper::factor）。
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
        // 折る倍率。os = 1 は線形補間の 4 倍（上の注）。
        let os = Int(SaturationShaperCurve.value(node, "os"))
        let factor = [2, 4, 8, 16].contains(os) ? os : 4

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
                caption: "Static curve. The kernel clips at \(factor)x, then filters back down.")

            ForEach(node.spec.params) { param in
                ParameterRow(param: param, nodeIndex: index, values: node.values, dsp: dsp)
            }
        }
    }
}
