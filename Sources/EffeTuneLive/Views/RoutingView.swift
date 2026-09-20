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

    /// 「Reset routing」の確認を出しているか。
    /// 全部の段のバスとチャンネルを一度に既定へ戻すので、取り消せない。
    /// 1 本ずつ直して組んだ分岐が 1 回で消えるから、鎖を捨てるときと同じく一度確かめる。
    @State private var confirmingReset = false

    var body: some View {
        NavigationStack {
            Group {
                if dsp.chain.isEmpty {
                    // List の上に overlay で重ねない。段が無くても Section の見出しと
                    // 注記は描かれるので、その上に重なって二重に読める。
                    ContentUnavailableView(
                        "Nothing to route",
                        systemImage: "arrow.triangle.branch",
                        description: Text("""
                                          Add an effect first. Buses and channels belong to \
                                          the effects on the chain.
                                          """))
                } else {
                    list
                }
            }
            .navigationTitle("Routing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private var list: some View {
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
                    Button("Reset routing", role: .destructive) { confirmingReset = true }
                }
            }
        }
        .confirmationDialog("Reset routing?",
                            isPresented: $confirmingReset,
                            titleVisibility: .visible) {
            Button("Reset routing", role: .destructive) {
                for i in dsp.chain.indices {
                    dsp.setRouting(at: i, inputBus: 0, outputBus: 0,
                                   channelSpec: -1, sectionGate: 1)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Puts every effect back on bus 0 in stereo. This cannot be undone.")
        }
    }
}

struct RoutingRow: View {
    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(node.spec.name)
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                if !node.isDefaultRouting || node.isGated {
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

                // 値だけを出さない。In / Out と違って "Stereo" は何の設定か読めない。
                // 上流も "Channel:" と名前を付けている（js/locales/en.json5 の ui.channel）。
                Menu {
                    Picker("", selection: Binding(
                        get: { node.channelSpec },
                        set: { dsp.setRouting(at: index, channelSpec: $0) })
                    ) {
                        // §52。幅を要求するエフェクトでは満たすものだけ出す。
                        ForEach(ETRoutingConstraint.options(ETRouting.channelOptions,
                                                            type: node.spec.type,
                                                            current: node.channelSpec),
                                id: \.0) { value, name in
                            Text(name).tag(value)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Channel").font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(ETRouting.channelName(node.channelSpec))
                            .font(.system(size: 13))
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9))
                    }
                }
                .accessibilityLabel("Channel")
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
            .background(.quaternary, in: .rect(cornerRadius: ETMetrics.innerRadius, style: .continuous))
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
        case 16...23: return ETChannel.pairName(spec)
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

// MARK: - 1 段だけ

/// カードから開く、その段ぶんだけの Routing。
///
/// 全体の Routing（上の RoutingView）は分岐の形を見渡すためのもので、
/// 「いまいじっているカードの行き先を変えたい」ときに開くと、鎖の中から
/// その 1 行を探すことになる。カードの ⋯ と印から直に開けるようにした。
///
/// 中身は RoutingView の行をそのまま使う。**2 つの画面で作りを変えない。**
struct EffectRoutingSheet: View {
    @Environment(\.dismiss) private var dismiss
    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    var body: some View {
        NavigationStack {
            List {
                Section {
                    RoutingRow(index: index, node: node, dsp: dsp)
                }

                if !node.isDefaultRouting {
                    Section {
                        Button("Reset routing", role: .destructive) {
                            dsp.setRouting(at: index, inputBus: 0, outputBus: 0,
                                           channelSpec: -1, sectionGate: node.sectionGate)
                        }
                    }
                }
            }
            .navigationTitle("Routing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        // 行 1 本ぶんしか無いので、画面の半分も要らない。
        // 上へ引けば広がるように .large も残す。
        .presentationDetents([.medium, .large])
    }
}
