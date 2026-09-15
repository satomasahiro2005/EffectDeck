//  EffectDetailView.swift
//  パラメータの画面。中身は EffeTune の params.json から生成したカタログで組み立てる。
//  エフェクトごとに手で画面を書いていない。

import SwiftUI

struct EffectDetailView: View {
    let index: Int
    @StateObject private var dsp = EffeTuneDSP.shared

    private var node: EffeTuneDSP.Node? {
        dsp.chain.indices.contains(index) ? dsp.chain[index] : nil
    }

    var body: some View {
        Group {
            if let node {
                List {
                    if !node.spec.about.isEmpty {
                        Section { Text(node.spec.about).font(.footnote).foregroundStyle(.secondary) }
                    }

                    Section {
                        Toggle("有効", isOn: Binding(
                            get: { node.enabled },
                            set: { dsp.setEnabled($0, at: index) }))
                    }

                    ForEach(node.spec.params) { param in
                        Section(param.isArray ? param.label : "") {
                            if param.isArray {
                                ForEach(0..<param.count, id: \.self) { i in
                                    ParamControl(param: param, slot: i, index: index,
                                                 value: value(node, param.offset + i),
                                                 label: "\(i + 1)")
                                }
                            } else {
                                ParamControl(param: param, slot: 0, index: index,
                                             value: value(node, param.offset),
                                             label: param.label)
                            }
                        }
                    }

                    if !node.spec.params.isEmpty {
                        Section {
                            Button("既定値に戻す") { dsp.resetParams(at: index) }
                        }
                    }
                }
                .navigationTitle(node.spec.name)
                .navigationBarTitleDisplayMode(.inline)
            } else {
                ContentUnavailableView("このエフェクトは外された", systemImage: "trash")
            }
        }
    }

    private func value(_ node: EffeTuneDSP.Node, _ offset: Int) -> Float {
        node.values.indices.contains(offset) ? node.values[offset] : 0
    }
}

private struct ParamControl: View {
    let param: ETParam
    let slot: Int
    let index: Int
    let value: Float
    let label: String

    @StateObject private var dsp = EffeTuneDSP.shared

    private var offset: Int { param.offset + slot }

    private func set(_ v: Float) {
        dsp.setValue(v, at: index, offset: offset)
    }

    var body: some View {
        switch param.kind {
        case .toggle:
            Toggle(label, isOn: Binding(get: { value >= 0.5 },
                                        set: { set($0 ? 1 : 0) }))

        case .enumeration(let values):
            Picker(label, selection: Binding(
                get: { min(max(Int(value.rounded()), 0), max(values.count - 1, 0)) },
                set: { set(Float($0)) })
            ) {
                ForEach(Array(values.enumerated()), id: \.offset) { i, name in
                    Text(name).tag(i)
                }
            }

        case .number(let lo, let hi, let step, _, let isInteger):
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(label).font(.subheadline)
                    Spacer()
                    Text(param.format(value))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if hi > lo {
                    Slider(
                        value: Binding(get: { Double(value) },
                                       set: { set(isInteger ? Float($0.rounded()) : Float($0)) }),
                        in: Double(lo)...Double(hi),
                        step: step > 0 ? Double(step) : (isInteger ? 1 : 0.0001))
                } else {
                    // 範囲が無いものは直接打つ
                    TextField(param.label, value: Binding(get: { value },
                                                          set: { set($0) }),
                              format: .number)
                        .keyboardType(.decimalPad)
                }
            }
        }
    }
}
