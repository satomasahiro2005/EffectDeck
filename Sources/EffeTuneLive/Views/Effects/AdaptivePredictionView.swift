//  AdaptivePredictionView.swift
//  Adaptive Prediction（AdaptivePredictionEffectPlugin。音の予測を学び、残りか共鳴を取り出す）。
//
//  上流 plugins/resonator/adaptive_prediction_effect.js の createUI（図は無い）。並びは
//  Gap → Learn → Weight Decay + Infinity → Autonomy → Original → Residual → Prediction →
//  Freeze → Hold → Reset。つまみは汎用のものと同じ ParameterRow で、止める規則は ETParamGate
//  （Foundation だけ。ParamGateTests）。
//
//  上流の画面に合わせた所:
//    - Weight Decay の目盛りは 0.5〜60 秒。**0 は無限大**で、Infinity の札が持つ。札を戻すと
//      覚えている有限の値（既定 10、保存しない）へ戻る。無限大のあいだつまみは覚えている値を指す。
//    - Hold の間は Autonomy を 1 と見せ（動かせない）、Freeze も入れて見せる。
//    - Reset は resetToken を 1 進める（16777215 の次は 0）。カーネルが値の変わりを見て
//      学習と履歴を捨てる。resetToken は保存せず、プリセットの比べにも入れない（runtimeOnly）。
//    - 上流は処理の事故（cause 1）が残っていると「Press Reset …」の一文を赤で出す。
//      et_instance_runtime_event を 0.5 秒ごとに見て同じ一文を出す。
//
//  **出さないもの。**上流の Hold の説明の段落（説明文は足さない）。
//
//  mono / single / stereo-pair しか受けないので、Ch が All の間は素通し。状態の一語だけ出す
//  （BassExtenderView と同じ。段ごと外すのは EffeTuneDSP.isChannelBypassed）。

import SwiftUI

struct AdaptivePredictionView: View {
    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    /// 上流の _finiteWeightDecay。Infinity を戻したときに返す値。保存しない。
    @State private var finiteDecay: Float = 10
    @State private var faulted = false

    /// 上流が事故の一文を出す条件と同じ文面（_renderStatus）。
    static let faultMessage = "Adaptive Prediction encountered a processing problem. Press Reset, then play audio to learn again."

    private func param(_ key: String) -> ETParam? {
        node.spec.params.first { $0.key == key }
    }

    private func value(_ key: String) -> Float {
        guard let p = param(key), node.values.indices.contains(p.offset) else { return 0 }
        return node.values[p.offset]
    }

    private var hold: Bool { value("hold") >= 0.5 }
    private var freeze: Bool { value("freeze") >= 0.5 }
    private var learningStopped: Bool { freeze || hold }
    private var decayInfinite: Bool { value("weightDecay") <= 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if EffeTuneDSP.isChannelBypassed(node) {
                Text("Bypassed")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            row("gap")
            row("learn")
            if let decay = param("weightDecay") {
                ParameterRow(param: decay, nodeIndex: index, values: node.values, dsp: dsp,
                             shown: decayInfinite ? finiteDecay : nil, lowerBound: 0.5)
                Toggle(isOn: Binding(
                    get: { decayInfinite },
                    set: { setDecay(infinite: $0) })
                ) {
                    Text("Infinity").font(.system(size: 14))
                }
                .padding(.vertical, 2)
                .disabled(learningStopped)
            }
            ParameterRowOrEmpty(param: param("autonomy"), index: index, node: node, dsp: dsp,
                                shown: hold ? 1 : nil)
            row("original")
            row("residual")
            row("prediction")
            ParameterRowOrEmpty(param: param("freeze"), index: index, node: node, dsp: dsp,
                                shown: hold ? 1 : nil)
            row("hold")
            ETMeasurementButton(title: "Reset") { reset() }
            if faulted {
                Text(Self.faultMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { remember() }
        .onChange(of: value("weightDecay")) { _, _ in remember() }
        .task {
            // 事故は実行時にだけ立つので、見えている間だけ 0.5 秒ごとに見る。
            while !Task.isCancelled {
                let now = dsp.runtimeFault(at: index)
                if now != faulted { faulted = now }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    @ViewBuilder
    private func row(_ key: String) -> some View {
        if let p = param(key) {
            ParameterRow(param: p, nodeIndex: index, values: node.values, dsp: dsp)
        }
    }

    /// 有限の値が入っているあいだ覚えておく（上流 :122）。
    private func remember() {
        let now = value("weightDecay")
        if now > 0, now != finiteDecay { finiteDecay = now }
    }

    private func setDecay(infinite: Bool) {
        guard let p = param("weightDecay") else { return }
        dsp.setValue(infinite ? 0 : max(0.5, finiteDecay), at: index, offset: p.offset)
    }

    /// resetToken を 1 進める。上流 resetLearning は 16777215 の次を 0 にする。
    private func reset() {
        guard let p = param("resetToken") else { return }
        let current = value("resetToken")
        let next: Float = current >= 16_777_215 ? 0 : current + 1
        dsp.setValue(next, at: index, offset: p.offset)
        // 保存しない値で、鎖の短い形に載らない。PC の段へは別に渡す。
        RemoteMirror.shared.sendRuntimeParams(at: index, ["resetToken": Int(next)])
        faulted = false
    }
}

/// キーが無い（古いカタログ）ときは何も出さない。
private struct ParameterRowOrEmpty: View {
    let param: ETParam?
    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP
    var shown: Float?

    var body: some View {
        if let param {
            ParameterRow(param: param, nodeIndex: index, values: node.values, dsp: dsp, shown: shown)
        }
    }
}
