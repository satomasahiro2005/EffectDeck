//  EffeTuneLiveApp.swift
//  EffeTune Live — 他のアプリの音を受けて、EffeTune のエフェクトを通して出し直す。

import SwiftUI

@main
struct EffeTuneLiveApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

struct RootView: View {
    @StateObject private var io = AudioIO.shared
    @StateObject private var dsp = EffeTuneDSP.shared
    @State private var showPicker = false
    @State private var showHelp = false

    private let timer = Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TransportRow(io: io, dsp: dsp)
                } header: {
                    Text("出力")
                } footer: {
                    if !io.hasPeer {
                        Text("コントロールセンターの出力先で EffeTune を選ぶと、そのアプリの音がここへ来る。")
                    }
                }

                Section {
                    if dsp.chain.isEmpty {
                        Button {
                            showPicker = true
                        } label: {
                            Label("エフェクトを足す", systemImage: "plus.circle")
                        }
                    } else {
                        ForEach(Array(dsp.chain.enumerated()), id: \.element.id) { index, node in
                            NavigationLink {
                                EffectDetailView(index: index)
                            } label: {
                                ChainRow(node: node) { dsp.setEnabled($0, at: index) }
                            }
                        }
                        .onDelete { dsp.remove(at: $0) }
                        .onMove { dsp.move(from: $0, to: $1) }
                    }
                } header: {
                    HStack {
                        Text("エフェクト")
                        Spacer()
                        if !dsp.chain.isEmpty {
                            Button("足す") { showPicker = true }.font(.caption)
                        }
                    }
                }

                Section("状態") {
                    StatusRows(io: io, dsp: dsp)
                }
            }
            .navigationTitle("EffeTune Live")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showHelp = true } label: { Image(systemName: "questionmark.circle") }
                }
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
            .sheet(isPresented: $showPicker) { EffectPickerView() }
            .sheet(isPresented: $showHelp) { HelpView() }
        }
        .onReceive(timer) { _ in io.tick() }
    }
}

private struct TransportRow: View {
    @ObservedObject var io: AudioIO
    @ObservedObject var dsp: EffeTuneDSP

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Button {
                    io.running ? io.stop() : io.start()
                } label: {
                    Label(io.running ? "停止" : "開始",
                          systemImage: io.running ? "stop.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(io.running ? .red : .accentColor)

                Toggle("素通し", isOn: $dsp.bypass)
                    .toggleStyle(.button)
                    .disabled(dsp.chain.isEmpty)
            }

            ProgressView(value: Double(min(io.level, 1)))
                .tint(io.level > 0.95 ? .red : .accentColor)
        }
        .padding(.vertical, 4)
    }
}

private struct ChainRow: View {
    let node: EffeTuneDSP.Node
    let setEnabled: (Bool) -> Void

    var body: some View {
        HStack {
            Button {
                setEnabled(!node.enabled)
            } label: {
                Image(systemName: node.enabled ? "power.circle.fill" : "power.circle")
                    .foregroundStyle(node.enabled ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text(node.spec.name)
                    .foregroundStyle(node.enabled ? .primary : .secondary)
                Text(node.spec.category)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct StatusRows: View {
    @ObservedObject var io: AudioIO
    @ObservedObject var dsp: EffeTuneDSP

    var body: some View {
        LabeledContent("状態", value: io.status)
        LabeledContent("出力先", value: io.route)
        LabeledContent("拡張と接続", value: io.hasPeer ? "はい" : "いいえ")
        LabeledContent("受信フレーム", value: "\(io.received)")
        LabeledContent("通したエフェクト", value: "\(io.applied) / \(dsp.chain.filter(\.enabled).count)")
    }
}

private struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("使い方") {
                    Text("1. このアプリを開いておく")
                    Text("2. 何かのアプリで音を鳴らす")
                    Text("3. コントロールセンターの出力先で EffeTune を選ぶ")
                    Text("4. ここで「開始」を押す")
                }
                Section("アプリが 2 つある理由") {
                    Text("""
                         音を横取りしているのは EffeTune Bridge に入っている拡張。
                         拡張を同梱したアプリは、iOS の決まりで自分から音を出せない。
                         だから鳴らす役をこちら（EffeTune Live）に分けてある。
                         Bridge は入れておくだけでよく、開く必要は無い。
                         """)
                }
                Section("音の加工") {
                    Text("""
                         エフェクトは EffeTune のものをそのまま動かしている。
                         移植や書き直しはしていないので、PC 版と同じ音になる。
                         """)
                }
            }
            .navigationTitle("EffeTune Live について")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
        }
    }
}
