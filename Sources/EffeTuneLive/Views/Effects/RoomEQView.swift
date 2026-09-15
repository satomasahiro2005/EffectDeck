//  RoomEQView.swift
//  Room EQ（RoomEqPlugin）。
//
//  **図は出していない。** 描く材料（測定）が iOS 側に無い。
//
//  web 版の図は「測った部屋の周波数特性」と「それを打ち消す補正」を重ねたもので、
//  測定はブラウザの測定ストアに入っている。
//
//    plugins/eq/room_eq.js:1619-1620   js/measurement-store/client.js と
//                                      js/room-eq/designer.js を読み込む
//    plugins/eq/room_eq.js:929         this.measurementId（測定の id。DSP へは行かない）
//    plugins/eq/room_eq.js:1075-1083   _packedParameters() が DSP へ渡すのは
//                                      lt / fd / gn / dy の 4 つだけ
//    dsp/plugins/eq/room_eq/params.json:5-13
//                                      fields はその 4 つ。補正そのものは assets
//                                      （ET_ASSET_F32_MULTICH, 32MiB）
//
//  掴む操作は web 版にはある（room_eq.js:236-298 の additional EQ のマーカー）。
//  ただしそれも測定に重ねる 5 本のバンドで、値は DSP のパラメータではなく
//  補正 FIR の設計に入る。だから iOS では動かしようがない。
//
//  ETEffect.params は 4 つ（Generated/EffectCatalog.swift:599-612）。
//  そのうち音に効くのは channelDelay と outputGain の 2 つで、これは本当に効く
//  （dsp/plugins/eq/room_eq/params.json の automation: true）。
//  latencyMode と filterDelaySamples はアセットが入って初めて意味を持つ。
//
//  channelDelay の単位は **サンプル** で、ms ではない。
//  web 版は ms で持っていて、DSP へ渡すときに掛けている
//  （room_eq.js:1081  dy: Math.round(this.delayMs * sampleRate / 1000)）。
//  こちらは EffeTuneDSP がサンプルレートを外に出していないので、サンプルのまま出す。

import SwiftUI

struct RoomEQView: View {

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
            Text("No correction curve")
                .font(.system(size: 12, weight: .semibold))
            Text("""
                 Room correction is built from a room measurement and loaded as an FIR \
                 asset. This build carries neither, so there is no curve to plot. \
                 Channel Delay and Output Gain still work; the delay is counted in samples.
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
