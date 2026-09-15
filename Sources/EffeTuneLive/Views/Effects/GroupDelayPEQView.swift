//  GroupDelayPEQView.swift
//  Group Delay PEQ（GroupDelayPEQPlugin）。
//
//  **図は出していない。** 5Band FIR PEQ と同じ理由で、描く材料が Swift 側に無い。
//
//    plugins/eq/group_delay_peq.js:161-167  _packedParameters() が DSP へ渡すのは lt と fd だけ。
//                                           fd も tp/2（タップ数の半分）を書いているだけで、
//                                           バンドの値ではない
//    plugins/eq/group_delay_peq.js:279      js/group-delay-peq/designer.js を読み込み
//    plugins/eq/group_delay_peq.js:335-355  設計して _stageDesign でアセットへ
//    dsp/plugins/eq/group_delay_peq/params.json:5-11
//                                           fields は latencyMode と filterDelaySamples の 2 つ。
//                                           群遅延の形は assets（ET_ASSET_F32_MULTICH）
//
//  kernel.cpp にテレメトリは無い。ETEffect.params も 2 つだけ
//  （Generated/EffectCatalog.swift:531-542）。バンドの t/f/d/q/e は JS の中にしか無い。
//
//  --- 縦軸のこと（材料が揃ったときに間違えないように控えておく）---
//
//  この効果の縦軸は dB ではない。**群遅延（ms）** で、上が正・下が負。
//
//    plugins/eq/group_delay_peq.js:956-962
//        delayToY(ms)     = 50 - ms / scale.range * 50
//        yToDelay(percent) = (50 - percent) / 50 * scale.range
//
//  範囲は固定ではなく、いまの設定に合わせて広がる（同 975-987）。
//  GRID_STEPS_MS = [0.5, 1, 2, 5, 10, 20, 25, 50, 100] から
//  「step * 5 >= peak」を満たす最初の step を選び、range = step * 5。
//  peak は「全バンドの delayMs（切ってあるものも含む）」と target 曲線と realized 曲線の
//  絶対値の最大で、下限は MINIMUM_GRAPH_RANGE_MS = 5 ms（同 32）。
//  横軸は 10Hz〜40kHz の対数（同 36 GRAPH_FREQUENCY_RANGE, 943-948 freqToX）。
//
//  目標曲線の式は js/group-delay-peq/design-core.js:75-118 の BAND_SHAPES にある。
//  pk は log2 軸のガウス、ls/hs はロジスティック、fl は 2 次の群遅延を正規化したもの。
//  掴んで動かすのは周波数と delayMs の 2 つ（同 js:1211-1235）。
//
//  ここまで分かっていても、いまは値の置き場所が無いので描かない。

import SwiftUI

struct GroupDelayPEQView: View {

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            notice

            ForEach(node.spec.params) { param in
                ParameterRow(param: param, nodeIndex: index, values: node.values, dsp: dsp)
            }
        }
    }

    private var notice: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No group delay curve")
                .font(.system(size: 12, weight: .semibold))
            Text("""
                 The five band shapes are not parameters of this effect. The kernel \
                 convolves an all-pass FIR supplied as an asset, and this build has no \
                 filter designer, so there is nothing to plot and nothing to drag.
                 """)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: .rect(corners: .concentric))
    }
}
