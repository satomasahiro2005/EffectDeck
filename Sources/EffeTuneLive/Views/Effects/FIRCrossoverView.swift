//  FIRCrossoverView.swift
//  FIR Crossover（FIRCrossoverPlugin）。
//
//  **図は出していない。** 出せないので出していない。理由を先に書く。
//
//  上流の図（fir_crossover.js:681-695 の canvas と 839-924 の drawGraph）は、
//  bc / f1..f3 / s1..s3 だけから帯ごとの線を引いている。このうち app が持っているのは
//  bc だけで、周波数と傾きはパラメータではない。上流でも DSP へは行かず
//  （fir_crossover.js:86-92 の _packedParameters は lt / fd / bc の 3 つだけ）、
//  係数の中に溶けて資産として流し込まれる。
//  dsp/generated/cpp/FIRCrossoverPluginParams.h も float 3 つで、
//  EffectCatalog.swift:115-126 はそれを写したもの。
//  既定値で線を引くことはできるが、動かせないうえに音と関係が無い絵になる。
//
//  Phase（pm、fir_crossover.js:635-638）と Taps（tp、同 639-645）も同じ理由で出していない。
//  どちらも設計の入力で、鎖に保存される値は ETParam しか通らない
//  （PipelineStore.swift:158-166 が spec.params を見て values を埋める）。
//  画面の中だけで持つと、カードを畳んだ時点で消える。
//
//  Filter Delay Samples（fd）は逆に、パラメータなのに画面へ出さない。
//  上流は fir_crossover.js:90 の `fd: this.pm === 'min' ? 0 : this.tp / 2` で
//  pm と tp から計算するだけで、createUI に操作は無い
//  （getSerializableParameters も同 123-127 で fd を消している）。
//  pm の既定は 'min' なので、この画面での fd は 0 のまま。
//
//  出しているのは上流と同じ並びで、error → Latency → Band Count。
//
//  --- この build では音が変わらない ---
//  帯ごとにステレオ 1 対を吐くので、出口が 4〜16 の偶数でないと成り立たない。
//  カーネルは channelCount == 2 のとき何もせずに戻る
//  （dsp/plugins/basics/fir_crossover/kernel.cpp:105-106）。
//  この app は et_engine_prepare に maxChannels: 2 を渡し（AudioIO.swift:135,319）、
//  ETPipeline_Process にも 2 を渡している（同 357,361）。
//  上流も同じ条件で _renderBusError（fir_crossover.js:615-622）を出すので、文言はそれに合わせた。

import SwiftUI

struct FIRCrossoverView: View {

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    /// この app が engine に渡している幅。AudioIO.swift:135,319 と 357,361。
    private static let processingChannels = 2

    /// fir_crossover.js:76-78 の _maximumBandCount。0 なら成り立たない。
    private var maximumBandCount: Int {
        FIRCrossoverSettings.maximumBandCount(processingChannels: Self.processingChannels)
    }

    /// fir_crossover.js:26 の maxBands（出口が変わると同 561 で入れ直す）。0 のときは 2 に倒れる。
    /// 押せるのは先頭からこの本数まで（同 790-791 の radio.disabled）。
    private var maxBands: Int { maximumBandCount == 0 ? 2 : maximumBandCount }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if maximumBandCount == 0 {
                busError
            }
            latencyRow
            bandCountRow
            notice
        }
    }

    // MARK: Latency

    /// fir_crossover.js:646-652。選択肢の表示は `${value} samples`。
    /// lt は enum なので values に入っているのは添字のほう。
    private var latencyRow: some View {
        let latency = param("lt")
        let options = FIRCrossoverSettings.latencyModeValues
        let selected = min(max(Int(value(latency).rounded()), 0), options.count - 1)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Latency")
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                Text("\(options[selected]) samples")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            FIRCrossoverChoiceStrip(
                options: options,
                selectedIndex: selected,
                enabledCount: options.count,
                accessibilityUnit: "samples",
                onSelect: { i in set(latency, Float(i)) })
        }
    }

    // MARK: Band Count

    /// fir_crossover.js:655-676。2/3/4 のラジオで、使えない本数は押せない。
    /// bc は enum ではなく数なので、values には 2/3/4 がそのまま入る。
    private var bandCountRow: some View {
        let bands = param("bc")
        let options = [2, 3, 4]
        let current = Int(value(bands).rounded())

        return VStack(alignment: .leading, spacing: 6) {
            Text("Band Count")
                .font(.system(size: 14))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            FIRCrossoverChoiceStrip(
                options: options,
                selectedIndex: options.firstIndex(of: current),
                enabledCount: max(0, maxBands - 1),
                accessibilityUnit: "bands",
                onSelect: { i in set(bands, Float(options[i])) })
        }
    }

    // MARK: 出口の幅が足りない

    /// fir_crossover.js:615-622 の _renderBusError。1 文目は上流と同じ文言。
    private var busError: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("This effect needs an even number of output channels from 4 to 16.")
                .font(.system(size: 12, weight: .semibold))
            Text("""
                 This build processes two channels, so the kernel passes audio through \
                 unchanged and the band controls do nothing.
                 """)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: .rect(cornerRadius: ETMetrics.innerRadius, style: .continuous))
    }

    // MARK: 図が無い理由

    /// 何も言わずに空にすると、壊れているように見える。
    private var notice: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No band response curve")
                .font(.system(size: 12, weight: .semibold))
            Text("""
                 Phase, taps, crossover frequencies and slopes are not parameters of this \
                 effect. They shape the FIR coefficients that reach the kernel as an asset, \
                 and this build does not carry them, so there is nothing to plot.
                 """)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: .rect(cornerRadius: ETMetrics.innerRadius, style: .continuous))
    }

    // MARK: 値の読み書き

    private func param(_ key: String) -> ETParam? {
        node.spec.params.first { $0.key == key }
    }

    private func value(_ param: ETParam?) -> Float {
        guard let param, node.values.indices.contains(param.offset) else { return 0 }
        return node.values[param.offset]
    }

    private func set(_ param: ETParam?, _ v: Float) {
        guard let param else { return }
        dsp.setValue(v, at: index, offset: param.offset)
    }
}

// MARK: - 選択肢の帯

/// 数の選択肢を横に並べたもの。上流のラジオと select に当たる。
/// Menu は足さない。選択肢は全部その場に出す。
private struct FIRCrossoverChoiceStrip: View {

    let options: [Int]
    /// 選んでいる添字。どれにも当たらないときは nil。
    let selectedIndex: Int?
    /// 先頭から何個まで押せるか。上流の radio.disabled（fir_crossover.js:790-791）。
    let enabledCount: Int
    /// 読み上げに付ける単位。
    let accessibilityUnit: String
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, option in
                let isSelected = i == selectedIndex
                let isEnabled = i < enabledCount
                Button {
                    onSelect(i)
                } label: {
                    Text(String(option))
                        .font(.system(size: 13,
                                      weight: isSelected ? .bold : .regular,
                                      design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white)
                                                    : AnyShapeStyle(.secondary))
                        .frame(maxWidth: .infinity, minHeight: ETMetrics.hitTarget)
                        .background(isSelected ? AnyShapeStyle(.tint)
                                               : AnyShapeStyle(.quaternary),
                                    in: .rect(cornerRadius: ETMetrics.innerRadius,
                                              style: .continuous))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1 : 0.4)
                .accessibilityLabel("\(option) \(accessibilityUnit)")
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
    }
}
