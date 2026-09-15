//  RoutingView.swift
//  鎖の形（バスとチャンネル）を組む画面。
//
//  バスは「このエフェクトだけの設定」ではなく鎖の形そのものなので、
//  カードを1枚ずつ開いて設定すると分岐の全体像が見えない。
//  だから普段は隠しておき、この画面では全部のエフェクトのバスを一度に出す。
//
//  バスは5本で、0番が本線。1〜4は毎ブロック消されるので、
//  そこへ書いたものは同じブロックのうちに誰かが読まないと消える。
//  入力バスと出力バスが**同じ**なら置き換え、**違う**なら出力バスへ加算される
//  （dsp/core/engine.cpp:977 で memcpy と += に分かれている）。

import SwiftUI

struct RoutingView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var dsp: EffeTuneDSP

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(dsp.chain.enumerated()), id: \.element.id) { index, node in
                        RoutingRow(index: index, node: node, dsp: dsp)
                    }
                } header: {
                    Text("Signal flow")
                } footer: {
                    Text("""
                         Bus 0 is the main path. Buses 1–4 are cleared at the start of every \
                         block, so whatever an effect writes there has to be read back within \
                         the same block. When the input and output bus differ, the result is \
                         added to that bus instead of replacing what is already on it.
                         """)
                }

                if dsp.chain.contains(where: { !$0.isDefaultRouting }) {
                    Section {
                        Button("Reset routing", role: .destructive) {
                            for i in dsp.chain.indices {
                                dsp.setRouting(at: i, inputBus: 0, outputBus: 0,
                                               channelSpec: -1, sectionGate: 1)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Routing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .overlay {
                if dsp.chain.isEmpty {
                    ContentUnavailableView("Nothing to route", systemImage: "arrow.triangle.branch")
                }
            }
        }
    }
}

private struct RoutingRow: View {
    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(node.spec.name)
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                if !node.isDefaultRouting {
                    Text(ETRouting.badge(node))
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.tint, in: .capsule)
                        .foregroundStyle(.white)
                }
            }

            HStack(spacing: 10) {
                busMenu(title: "In", value: node.inputBus) {
                    dsp.setRouting(at: index, inputBus: $0)
                }
                Image(systemName: "arrow.right")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                busMenu(title: "Out", value: node.outputBus) {
                    dsp.setRouting(at: index, outputBus: $0)
                }

                Spacer()

                Menu {
                    Picker("", selection: Binding(
                        get: { node.channelSpec },
                        set: { dsp.setRouting(at: index, channelSpec: $0) })
                    ) {
                        ForEach(ETRouting.channelOptions, id: \.0) { value, name in
                            Text(name).tag(value)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(ETRouting.channelName(node.channelSpec))
                            .font(.system(size: 13))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9))
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func busMenu(title: String, value: UInt8,
                         set: @escaping (UInt8) -> Void) -> some View {
        Menu {
            Picker("", selection: Binding(get: { value }, set: set)) {
                ForEach(0..<5, id: \.self) { b in
                    Text(b == 0 ? "0 (main)" : "\(b)").tag(UInt8(b))
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                Text("\(value)")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.quaternary, in: .rect(corners: .concentric))
        }
    }
}

/// バスとチャンネルの見せ方。カードの頭でも使う。
enum ETRouting {
    /// 画面に出す選択肢。このアプリは 2ch しか扱わないので、
    /// EffeTune が持っている 3ch 目以降の選択肢は出さない。
    /// ただし取り込んだプリセットがそれらを持っていても値は保つ。
    static var channelOptions: [(Int8, String)] {
        [(-1, "Stereo"), (-2, "All"), (0, "Left"), (1, "Right")]
    }

    static func channelName(_ spec: Int8) -> String {
        switch spec {
        case -2: return "All"
        case -1: return "Stereo"
        case 0:  return "Left"
        case 1:  return "Right"
        case 2...15: return "Ch \(spec + 1)"
        case 17...23: return ETChannel.pairName(spec)
        default: return "?"
        }
    }

    /// 既定から外れたものだけカードに出す短い印。
    static func badge(_ node: EffeTuneDSP.Node) -> String {
        var parts: [String] = []
        if node.inputBus != 0 || node.outputBus != 0 {
            parts.append("\(node.inputBus)→\(node.outputBus)")
        }
        if node.channelSpec != -1 {
            parts.append(channelName(node.channelSpec))
        }
        if node.sectionGate == 0 {
            parts.append("gated")
        }
        return parts.joined(separator: " ")
    }
}
