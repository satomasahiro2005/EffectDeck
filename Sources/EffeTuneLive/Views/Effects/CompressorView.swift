//  CompressorView.swift
//  Compressor。入出力の伝達曲線と、いまのゲインリダクション。
//
//  曲線は params から引ける。web 版と同じ式を同じ順で書いてある:
//    plugins/dynamics/compressor.js:705-722（描く側）
//    dsp/plugins/dynamics/compressor/kernel.cpp:92-108（音を作る側）
//  枝の順番を写しているのは、Knee = 0 のとき真ん中の枝（knee で割る）に
//  入らないようにするため。-0.0 と +0.0 の比較で両端の枝が全部拾う。
//
//  範囲は web 版に合わせて入力 -60〜0 dB、出力も -60〜0 dB
//  （compressor.js:674-675 の (db+60)/60 が縦横とも同じ式）。
//  makeup gain を足した出力は上へ出るが、そこは枠で切る。
//
//  ゲインリダクションはテレメトリから来る。自前で包絡は追わない。
//    枠の種類 2（gainReduction）・版 1・ペイロード 4 バイト
//    書く側 dsp/plugins/dynamics/compressor/dynamics_common.h:46-51
//      payload[0..3] = f32 amount_db（0 以上の大きさ。符号は乗らない）
//    読む側 plugins/dynamics/compressor.js:528-540
//      byteLength === 4 と getFloat32(0, true) >= 0 を確かめている
//  値は kernel.cpp:123 の maximum_reduction、そのブロック・全チャンネルで
//  最も深く削れた量。web 版はこれを平滑してから棒に描くが（compressor.js:564-600）、
//  こちらは DSP が出したそのままを出す。

import SwiftUI

struct CompressorView: View {
    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP
    @ObservedObject private var telemetry = Telemetry.shared

    var body: some View {
        // 曲線を引く閉包へ self を渡さないよう、要る値だけ控える。
        let threshold = DynamicsParams.value(node, "th")
        let ratio = DynamicsParams.value(node, "rt")
        let knee = DynamicsParams.value(node, "kn")
        let makeup = DynamicsParams.value(node, "gn")
        let amount = gainReduction

        return VStack(alignment: .leading, spacing: 12) {
            TransferCurveGraph(
                curve: ETTransferCurve.sampled(id: "compressor", count: 192,
                                               from: -60, to: 0) { input in
                    CompressorCurve.output(input: input, threshold: threshold, ratio: ratio,
                                           knee: knee, makeup: makeup)
                },
                inputRange: -60...0,
                outputRange: -60...0,
                tickStep: 12,
                caption: amount.map { "GR \(ETFormat.db($0))" } ?? "GR —")

            if let amount {
                MeterView(channels: [ETMeterChannel(id: 0, label: "GR", levelDB: amount)],
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

    /// 枠が無い・版が違う・長さが違う・負の値なら nil。読めないものは描かない。
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

/// compressor.js:705-722 と kernel.cpp:92-108 をそのまま写したもの。
enum CompressorCurve {

    static func output(input: Double, threshold: Double, ratio: Double,
                       knee: Double, makeup: Double) -> Double {
        let difference = input - threshold
        // kernel.cpp:97 と同じ。ratio == 1 のときだけ 0 に落とす。
        let inverseRatio = ratio == 1 ? 0 : 1 - 1 / ratio

        var reduction = 0.0
        if difference <= -knee / 2 {
            reduction = 0
        } else if difference >= knee / 2 {
            reduction = difference * inverseRatio
        } else {
            let position = (difference + knee / 2) / knee
            reduction = inverseRatio * knee * position * position * 0.5
        }

        // compressor.js:719-720 の clamp。音の側と揃えてある。
        let total = min(max(makeup - reduction, -60), 20)
        return input + total
    }
}

// MARK: - params の読み出し

/// Compressor / Expander / Gate は保存名（th / rt / kn / gn）が同じなので、
/// 読み方も 1 か所にしてある。offset は EffectCatalog.swift が持っている。
@MainActor
enum DynamicsParams {

    static func value(_ node: EffeTuneDSP.Node, _ key: String) -> Double {
        guard let param = node.spec.params.first(where: { $0.key == key }) else { return 0 }
        guard node.values.indices.contains(param.offset) else { return Double(param.defaultValue) }
        return Double(node.values[param.offset])
    }

    /// 配列のパラメータ（5Band Dynamic EQ）の band 番目。
    static func value(_ node: EffeTuneDSP.Node, _ key: String, band: Int) -> Double {
        guard let param = node.spec.params.first(where: { $0.key == key }),
              band >= 0, band < param.count else { return 0 }
        let offset = param.offset + band
        guard node.values.indices.contains(offset) else { return Double(param.defaultValue) }
        return Double(node.values[offset])
    }
}
