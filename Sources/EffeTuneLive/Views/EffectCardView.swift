//  EffectCardView.swift
//  エフェクト 1 個ぶんのカード。
//
//  EffeTune は頭に「⋮ / ON / 名前」を置き、その下にパラメータを並べている。そこは同じ。
//  違うのは開閉で、iPhone だと 5Band PEQ 1 個で画面が埋まるので既定では畳んである。
//  足した直後のものだけ開く。
//
//  ▲▼・削除は EffeTune では横に並んでいるが、場所を食うので ⋯ にまとめ、
//  並べ替えと削除はリストの標準の動き（長押しで移動・横に払って削除）に任せている。

import SwiftUI

struct EffectCardView: View {
    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP
    let isExpanded: Bool
    let toggleExpanded: () -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                header
                if isExpanded && hasBody {
                    Divider().padding(.horizontal, ETMetrics.cardPadding)
                    Group {
                        if ETEffectViews.has(node.spec.type) {
                            // 専用の画面を持つものは、そちらがパラメータまで面倒を見る。
                            ETEffectViews.view(index: index, node: node, dsp: dsp)
                        } else {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(node.spec.params) { param in
                                    ParameterRow(param: param, nodeIndex: index,
                                                 values: node.values, dsp: dsp)
                                }
                            }
                        }
                    }
                    .padding(ETMetrics.cardPadding)
                }
            }
        }
        .opacity(node.enabled ? 1 : 0.55)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                dsp.setEnabled(!node.enabled, at: index)
            } label: {
                PowerBadge(isOn: node.enabled)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text(node.spec.name)
                    .font(.system(size: 16, weight: .semibold))
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            // 既定（0→0 の All）から外れたものだけ出す。
            // 普通の鎖は一直線なので、普段は何も出ない。
            if !node.isDefaultRouting {
                Text(ETRouting.badge(node))
                    .font(.system(size: 10, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.tint, in: .capsule)
                    .foregroundStyle(.white)
            }

            if hasBody {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }

            Menu {
                Button { dsp.resetParams(at: index) } label: {
                    Label("Reset Parameters", systemImage: "arrow.counterclockwise")
                }
                Button { dsp.move(from: IndexSet(integer: index), to: index - 1) } label: {
                    Label("Move Up", systemImage: "arrow.up")
                }
                .disabled(index == 0)
                Button { dsp.move(from: IndexSet(integer: index), to: index + 2) } label: {
                    Label("Move Down", systemImage: "arrow.down")
                }
                .disabled(index >= dsp.chain.count - 1)
                Divider()
                Button(role: .destructive) {
                    dsp.remove(at: IndexSet(integer: index))
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, ETMetrics.cardPadding)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            guard hasBody else { return }
            withAnimation(.snappy(duration: 0.2)) { toggleExpanded() }
        }
    }

    /// 開いて出すものがあるか。図だけのエフェクト（Level Meter など）も開ける。
    private var hasBody: Bool {
        !node.spec.params.isEmpty || ETEffectViews.has(node.spec.type)
    }

    /// 畳んでいるときに何をしているかが分かるよう、主要な値を 1 行にする。
    private var summary: String {
        guard !node.spec.params.isEmpty else { return node.spec.category.categoryLabel }
        let shown = node.spec.params.prefix(3).compactMap { param -> String? in
            guard !param.isArray,
                  node.values.indices.contains(param.offset) else { return nil }
            let v = node.values[param.offset]
            if case .number = param.kind, v == param.defaultValue { return nil }
            if case .toggle = param.kind, v == param.defaultValue { return nil }
            return "\(param.label) \(param.format(v))"
        }
        return shown.isEmpty ? node.spec.category.categoryLabel : shown.joined(separator: " · ")
    }
}
