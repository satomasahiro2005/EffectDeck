//  ExpanderView.swift
//  Expander。しきい値より下を広げる方の伝達曲線。
//
//  Compressor と枠は同じだが、効くのが下側なので曲線は左端が垂れる。
//  式は web 版と同じ:
//    plugins/dynamics/expander.js:661-688（描く側）
//    dsp/plugins/dynamics/expander/kernel.cpp:69-92（音を作る側）
//  kernel の expansion_slope（同 71 行）= ratio - 1 が js の (ratio - 1) と同じもの。
//  knee の中は js:679-682 と kernel:82-85 が同じ二次式（下側の直線に
//  (1 - t)^2 を掛ける）。
//
//  範囲は入力 -60〜0 dB、出力も -60〜0 dB（expander.js:690 の (db+60)/60）。
//
//  テレメトリは Compressor と同じ枠を使う。
//    枠の種類 2（gainReduction）・版 1・ペイロード 4 バイト
//    書く側 dsp/plugins/dynamics/compressor/dynamics_common.h:46-51 を
//           expander/kernel.cpp:105-109 が呼んでいる
//    読む側 plugins/dynamics/expander.js:485-497
//  ただし中身は kernel.cpp:101 の maximum_boost、つまり「掛けた量の大きさ」で
//  符号が無い（同 89-92 行で abs を取っている）。ratio > 1 なら下を削った量、
//  ratio < 1 なら持ち上げた量。どちらか判らないので、表示も大きさだけにしてある。

import SwiftUI

struct ExpanderView: View {
    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP
    @ObservedObject private var telemetry = Telemetry.shared

    var body: some View {
        let threshold = DynamicsParams.value(node, "th")
        let ratio = DynamicsParams.value(node, "rt")
        let knee = DynamicsParams.value(node, "kn")
        let makeup = DynamicsParams.value(node, "gn")
        let amount = gainChange

        return VStack(alignment: .leading, spacing: 12) {
            TransferCurveGraph(
                curve: ETTransferCurve.sampled(id: "expander", count: 192,
                                               from: -60, to: 0) { input in
                    ExpanderCurve.output(input: input, threshold: threshold, ratio: ratio,
                                         knee: knee, makeup: makeup)
                },
                inputRange: -60...0,
                outputRange: -60...0,
                tickStep: 12,
                caption: amount.map { "GAIN CHANGE \(ETFormat.db($0))" } ?? "GAIN CHANGE —")

            if let amount {
                // 段の名前は枠の左 16pt の余白に入るので 2 文字まで。
                // GB は web 版の変数名（expander.js:15 の this.gb = gain boost）から。
                MeterView(channels: [ETMeterChannel(id: 0, label: "GB", levelDB: amount)],
                          range: 0...24,
                          ticks: [0, 6, 12, 18, 24],
                          holdsPeak: false,
                          rowHeight: 14,
                          showsReadout: false)
            }

            ForEach(node.spec.params) { param in
                ParameterRow(param: param, nodeIndex: index, values: node.values, dsp: dsp)
            }
        }
    }

    private var gainChange: Double? {
        guard let frame = telemetry.frame(tap: node.tapId, type: .gainReduction),
              frame.matches(version: 1),
              frame.hasPayload(bytes: 4),
              let amount = frame.payloadView.f32(at: 0),
              amount.isFinite, amount >= 0 else { return nil }
        return Double(amount)
    }
}

// MARK: - 曲線の式

/// expander.js:661-688 と kernel.cpp:69-92 をそのまま写したもの。
enum ExpanderCurve {

    static func output(input: Double, threshold: Double, ratio: Double,
                       knee: Double, makeup: Double) -> Double {
        let difference = input - threshold
        let slope = ratio - 1

        var boost = 0.0
        if difference <= -knee / 2 {
            // しきい値より下。ratio > 1 なら負（＝さらに小さくなる）。
            boost = difference * slope
        } else if difference >= knee / 2 {
            boost = 0
        } else {
            let position = (difference + knee / 2) / knee
            let belowKnee = (-knee / 2) * slope
            boost = belowKnee * (1 - position) * (1 - position)
        }

        // expander.js:685-687 の clamp。
        let total = min(max(boost + makeup, -60), 20)
        return input + total
    }
}
