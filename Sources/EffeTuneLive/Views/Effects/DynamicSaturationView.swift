//  DynamicSaturationView.swift
//  Dynamic Saturation（スピーカーのコーンの動きを真似た歪み）。
//
//  テレメトリは要らない。dsp/plugins/saturation/dynamic_saturation/kernel.cpp に
//  writeTelemetry は無い。
//
//  図に出せるのは歪ませる段だけ。横軸はコーンの変位で、音の入力ではない。
//  カーネル（kernel.cpp:104-107）はこう書いている:
//      wet   = tanh(distortionDrive * (position + bias)) - tanh(distortionDrive * bias)
//      xNl   = position + distortionMix * (wet - position)
//      delta = (xNl - position) * coneMotionMix
//      out   = (input + delta) * outputGain
//  position は 2 次系（質量・ばね・減衰）の出力で、いまの変位は params から決まらない。
//  だから曲線に出せるのは dd / db / dm の 3 つだけ。
//  sd・ss・sp・sm は変位そのものを、cm と og は出口を動かすので、この曲線には映らない。
//  web 版の canvas（plugins/saturation/dynamic_saturation.js:282-295）も同じ 3 つだけで引いている。
//
//  並べ方は web 版に合わせて、図を Distortion の下に置いた。
//  9 本のスライダーを一列にすると、どれがどこに効くのか読めなくなる。

import SwiftUI
import Foundation

struct DynamicSaturationView: View {
    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    @Environment(\.etGraphOnly) private var graphOnly

    var body: some View {
        let drive = SaturationShaperCurve.value(node, "dd")
        let bias = SaturationShaperCurve.value(node, "db")
        let mix = SaturationShaperCurve.value(node, "dm") / 100
        let biasTerm = tanh(drive * bias)

        return VStack(alignment: .leading, spacing: 12) {
            // **図だけの段では見出しも出さない。**ParameterRow は graphOnly のとき
            // 自分で消えるが、見出しは残って宙に浮く。
            if !graphOnly {
                label("Speaker")
                rows(["sd", "ss", "sp", "sm"])

                label("Distortion")
                rows(["dd", "db", "dm"])
            }

            SaturationShaperCurve(
                shape: { x in
                    let wet = tanh(drive * (x + bias)) - biasTerm
                    return x * (1 - mix) + wet * mix
                })

            if !graphOnly {
                label("Output")
                rows(["cm", "og"])
            }
        }
    }

    /// 区切りの見出し。ParameterRow のバンド見出しと同じ作りにしてある。
    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }

    /// key で選んだぶんだけ並べる。並び順はカタログのまま。
    private func rows(_ keys: [String]) -> some View {
        ForEach(node.spec.params.filter { keys.contains($0.key) }) { param in
            ParameterRow(param: param, nodeIndex: index, values: node.values, dsp: dsp)
        }
    }
}
