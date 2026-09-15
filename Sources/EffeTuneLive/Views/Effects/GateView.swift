//  GateView.swift
//  Gate。しきい値より下を落とす方の伝達曲線。
//
//  Compressor / Expander と違って軸が -96〜0 dB。しきい値の下限が -96 dB
//  （dsp/plugins/dynamics/gate/params.json の threshold）なので、
//  web 版も 96 dB で描いている（plugins/dynamics/gate.js:701-702, 733, 755）。
//  格子は web 版が -72/-48/-24 の 3 本。ここは 24 dB ごとに取って
//  -96/-72/-48/-24/0 の 5 本にしてある（端の 2 本が増えるだけ）。
//
//  式:
//    plugins/dynamics/gate.js:733-752（描く側）
//    dsp/plugins/dynamics/gate/kernel.cpp:70-86（音を作る側）
//  Compressor と向きが逆で、差は threshold - input。下へ行くほど深くなる。
//  kernel は ratio_slope = ratio - 1 が 0 以下のとき何もしない。
//  js は ratio === 1 を先に弾く。同じ意味になるので js の形で書いてある。
//
//  ゲインリダクションはテレメトリから。
//    枠の種類 2（gainReduction）・版 1・ペイロード 4 バイト
//    書く側 dsp/plugins/dynamics/compressor/dynamics_common.h:46-51 を
//           gate/kernel.cpp:108-112 が呼んでいる
//      値は kernel.cpp:104 の maximum_reduction（0 以上）
//    読む側 plugins/dynamics/gate.js:575-590
//  Gate は ratio 100 まで取れるので削れる量が大きい。棒の目盛りは 60 dB。

import SwiftUI

struct GateView: View {
    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP
    @ObservedObject private var telemetry = Telemetry.shared

    var body: some View {
        let threshold = DynamicsParams.value(node, "th")
        let ratio = DynamicsParams.value(node, "rt")
        let knee = DynamicsParams.value(node, "kn")
        let makeup = DynamicsParams.value(node, "gn")
        let amount = gainReduction

        return VStack(alignment: .leading, spacing: 12) {
            TransferCurveGraph(
                curve: ETTransferCurve.sampled(id: "gate", count: 192,
                                               from: -96, to: 0) { input in
                    GateCurve.output(input: input, threshold: threshold, ratio: ratio,
                                     knee: knee, makeup: makeup)
                },
                inputRange: -96...0,
                outputRange: -96...0,
                tickStep: 24,
                caption: amount.map { "GR \(ETFormat.db($0))" } ?? "GR —")

            if let amount {
                MeterView(channels: [ETMeterChannel(id: 0, label: "GR", levelDB: amount)],
                          range: 0...60,
                          ticks: [0, 12, 24, 36, 48, 60],
                          holdsPeak: false,
                          rowHeight: 14,
                          showsReadout: false)
            }

            ForEach(node.spec.params) { param in
                ParameterRow(param: param, nodeIndex: index, values: node.values, dsp: dsp)
            }
        }
    }

    private var gainReduction: Double? {
        guard let frame = telemetry.frame(tap: node.tapId, type: .gainReduction),
              frame.matches(version: 1),
              frame.hasPayload(bytes: 4),
              let amount = frame.payloadView.f32(at: 0),
              amount.isFinite, amount >= 0 else { return nil }
        return Double(amount)
    }
}

// MARK: - 曲線の式

/// gate.js:733-752 と kernel.cpp:70-86 をそのまま写したもの。
enum GateCurve {

    static func output(input: Double, threshold: Double, ratio: Double,
                       knee: Double, makeup: Double) -> Double {
        // 差の向きが Compressor と逆。しきい値より下で正になる。
        let difference = threshold - input

        var reduction = 0.0
        if ratio != 1 {
            if difference <= -knee / 2 {
                reduction = 0
            } else if difference >= knee / 2 {
                reduction = difference * (ratio - 1)
            } else {
                let position = (difference + knee / 2) / knee
                reduction = (ratio - 1) * knee * position * position / 2
            }
        }

        // js 版に clamp は無い。ratio 100 だと -96 dB の入力で -9000 dB まで行くので、
        // 描く座標が壊れないところで止める（軸は -96 までなので見た目は変わらない）。
        return min(max(input - reduction + makeup, -180), 60)
    }
}
