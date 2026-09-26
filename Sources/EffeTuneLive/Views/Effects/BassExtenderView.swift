//  BassExtenderView.swift
//  Bass Extender（薄い低域に生成した低音を足す）。
//
//  つまみは生成したものをそのまま並べる（Amount / Output。bass_extender.js の createUI と同じ）。
//  専用の画面にしたのは、効かない状態を出すためだけ。
//
//  **上流は mono と stereo-pair しか受けない**（bass_extender.js:15-19）。All は幅によらず、
//  L / R / 単独の Ch も bypass し、状態行に bypassed と出す（:63-67）。
//  カーネルは 1〜2ch なら処理してしまう（kernel.cpp:152-154 は 3ch 以上だけ素通し）ので、
//  descriptor で段ごと外す（EffeTuneDSP.isChannelBypassed）。ここでは状態の一語だけを出す。
//
//  テレメトリは無い。図も無いので ETEffectViews.withoutGraph に入れてある。

import SwiftUI

struct BassExtenderView: View {
    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if EffeTuneDSP.isChannelBypassed(node) {
                Text("Bypassed")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            ForEach(node.spec.params) { param in
                ParameterRow(param: param, nodeIndex: index, values: node.values, dsp: dsp)
            }
        }
    }
}
