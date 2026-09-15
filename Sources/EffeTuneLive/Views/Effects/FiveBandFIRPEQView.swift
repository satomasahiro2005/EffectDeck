//  FiveBandFIRPEQView.swift
//  5Band FIR PEQ（FiveBandFIRPEQPlugin）。
//
//  **図は出していない。** 出せないので出していない。理由を先に書く。
//
//  web 版は 5 本のバンド（f/g/q/s/t/e）を掴んで動かす図を持っているが、
//  その値は DSP へ行かない。JS 側が FIR を設計して、係数をアセットとして流し込む。
//
//    plugins/eq/five_band_fir_peq.js:96-103   _packedParameters() が DSP へ渡すのは
//                                             lt / fd / dy / gn の 4 つだけ
//    plugins/eq/five_band_fir_peq.js:230-236  designer.js を読み込み
//    plugins/eq/five_band_fir_peq.js:264-281  設計して _stageDesign でアセットへ
//    dsp/plugins/eq/five_band_fir_peq/params.json:6-12
//                                             fields は latencyMode と filterDelaySamples の 2 つ。
//                                             バンドは assets（ET_ASSET_F32_MULTICH, 32MiB）
//
//  カーネル側もそのとおりで、kernel.cpp は畳み込みだけを持っていて
//  バンドという概念が無い（dsp/plugins/eq/five_band_fir_peq/kernel.cpp:16-27 の
//  kAssetSlot / kAssetCapacity / kAssetMagic）。writeTelemetry も無い。
//
//  つまり Swift 側で描ける曲線が存在しない。
//  ETEffect.params は 2 つで、そこにバンドは入っていない（Generated/EffectCatalog.swift:445-456）。
//  アセットを積む口（et_instance_asset_begin / commit、Vendor/effetune/dsp/include/effetune/abi.h:135-144）
//  は abi.h 経由で Swift から見えてはいるが、EffeTuneDSP にはまだ通っていない。
//  FIR の設計そのものも移っていない。ここを埋めない限り図は嘘になる。
//
//  なので触れるものだけ並べる。

import SwiftUI

struct FiveBandFIRPEQView: View {

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    /// EffectCardView が params を並べている VStack と同じ形にしてある。
    /// 外側の padding は入れない（置き換える側が持っている）。
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            notice

            ForEach(node.spec.params) { param in
                ParameterRow(param: param, nodeIndex: index, values: node.values, dsp: dsp)
            }
        }
    }

    /// 画面の中でも「なぜ曲線が無いのか」が分かるようにしておく。
    /// 何も言わずに空にすると、壊れているように見える。
    private var notice: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No response curve")
                .font(.system(size: 12, weight: .semibold))
            Text("""
                 The five bands are not parameters of this effect. The kernel convolves \
                 an FIR impulse response supplied as an asset, and this build has no \
                 filter designer, so there is nothing to plot and nothing to drag.
                 """)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}
