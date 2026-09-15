//  EffectCardView.swift
//  エフェクト 1 個ぶんのカード。
//
//  EffeTune は頭に「⋮ / ON / 名前」を置き、その下にパラメータを並べている。
//  そこは同じにした。違うのは操作の出し方で、EffeTune が横に並べている
//  ▲▼・複製・削除といったボタンは、iPhone では場所を食うので ⋯ にまとめ、
//  並べ替えと削除はリストの標準の動き（長押しで移動・横に払って削除）に任せている。
//
//  パラメータが多いエフェクトがあるので、頭を触ると畳めるようにしてある。

import SwiftUI

struct EffectCardView: View {
    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    @State private var collapsed = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                header
                if !collapsed && !node.spec.params.isEmpty {
                    Divider().padding(.horizontal, ETMetrics.cardPadding)
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(node.spec.params) { param in
                            ParameterRow(param: param, nodeIndex: index,
                                         values: node.values, dsp: dsp)
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
                Text(node.spec.category.categoryLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !node.spec.params.isEmpty {
                Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
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
            guard !node.spec.params.isEmpty else { return }
            withAnimation(.snappy(duration: 0.2)) { collapsed.toggle() }
        }
    }
}
