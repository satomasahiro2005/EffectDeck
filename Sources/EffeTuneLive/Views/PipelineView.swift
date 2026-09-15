//  PipelineView.swift
//  本画面。EffeTune の Effect Pipeline にあたる。
//
//  EffeTune との違いと、その理由:
//    - 左のエフェクト一覧は常時は出さない。iPhone の幅では鎖が読めなくなるので + から出す
//    - 再生の開始/停止は持たない。拡張が繋がったら自分で鳴らし始める。
//      鎖を切りたいときは頭の ON を切る（素通しになる）
//    - レベルメーターは下の帯に置かない。要る人は Level Meter を鎖に入れる

import SwiftUI

struct PipelineView: View {
    @StateObject private var io = AudioIO.shared
    @StateObject private var dsp = EffeTuneDSP.shared
    @State private var showPicker = false
    @State private var showSettings = false
    @State private var showRouting = false
    @State private var showPresets = false
    @AppStorage("welcome.seen") private var welcomeSeen = false
    @State private var showWelcome = false
    @State private var showIR = false
    /// 畳んだものだけを覚える。既定は開いた状態。
    @State private var collapsed: Set<UUID> = []

    /// 図を動かすための速い方。DSP が 30Hz で吐いているのでそれに合わせる。
    private let fast = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()
    /// 状態の見直し。ルートの問い合わせなど重いものはこちら。
    private let slow = Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                pipelineHeader
                chainList
            }
            .navigationTitle("EffeTune Live")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showPicker = true } label: { Image(systemName: "plus") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showPresets = true } label: {
                            Label("Presets…", systemImage: "square.stack")
                        }
                        Button { showRouting = true } label: {
                            Label("Routing…", systemImage: "arrow.triangle.branch")
                        }
                        .disabled(dsp.chain.isEmpty)
                        Button { showIR = true } label: {
                            Label("IR Library…", systemImage: "waveform")
                        }
                        Divider()
                        Button { showSettings = true } label: {
                            Label("Settings…", systemImage: "gearshape")
                        }
                        Button { showWelcome = true } label: {
                            Label("How it works", systemImage: "questionmark.circle")
                        }
                        Divider()
                        Button(role: .destructive) { dsp.clear() } label: {
                            Label("Remove All", systemImage: "trash")
                        }
                        .disabled(dsp.chain.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
            .sheet(isPresented: $showPicker) {
                EffectPickerView { spec in
                    dsp.add(spec)
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView(io: io) }
            .sheet(isPresented: $showRouting) { RoutingView(dsp: dsp) }
            .sheet(isPresented: $showPresets) { PresetsView(dsp: dsp) }
            .sheet(isPresented: $showWelcome, onDismiss: { welcomeSeen = true }) {
                WelcomeView(io: io)
            }
            .sheet(isPresented: $showIR) { IRLibraryView() }
            .onAppear {
                // 画面を撮るときは案内を出さない。後ろが見えなくなるので。
                if !welcomeSeen && ETScreenshotSeed.requested == nil { showWelcome = true }
            }
        }
        .onReceive(fast) { _ in io.pollTelemetry() }
        .onReceive(slow) { _ in io.tick() }
    }

    /// EffeTune の「ON  Effect Pipeline    96000 Hz」の帯にあたるもの。
    /// ナビゲーションの見出しが「EffeTune Live」なので、ここで名前をもう一度出さない。
    /// 鎖が空のときは出すものが無いので、帯ごと畳む。
    @ViewBuilder
    private var pipelineHeader: some View {
        if !dsp.chain.isEmpty {
            HStack(spacing: 10) {
                Button {
                    dsp.bypass.toggle()
                } label: {
                    PowerBadge(isOn: !dsp.bypass)
                }
                .buttonStyle(.plain)

                Text(dsp.bypass ? "Bypassed"
                                : "\(dsp.chain.count) effect\(dsp.chain.count == 1 ? "" : "s")")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)

                Spacer()

                if io.running {
                    Text("\(Int(io.processingRate / 1000)) kHz")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var chainList: some View {
        List {
            ClipboardBanner(dsp: dsp)
                .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

            if !io.hasPeer {
                ConnectBanner()
                    .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 8, trailing: 14))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            if dsp.chain.isEmpty {
                EmptyChainRow { showPicker = true }
                    .listRowInsets(EdgeInsets(top: 20, leading: 14, bottom: 20, trailing: 14))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(Array(dsp.chain.enumerated()), id: \.element.id) { index, node in
                    EffectCardView(
                        index: index,
                        node: node,
                        dsp: dsp,
                        isExpanded: !collapsed.contains(node.id),
                        toggleExpanded: {
                            if collapsed.contains(node.id) { collapsed.remove(node.id) }
                            else { collapsed.insert(node.id) }
                        })
                        .listRowInsets(EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .onDelete { dsp.remove(at: $0) }
                .onMove { dsp.move(from: $0, to: $1) }
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
    }
}

/// 拡張が繋がっていない間だけ、鎖の一番上に出る。
/// 2本構成は普通ではないので、黙っていると詰まる。
private struct ConnectBanner: View {
    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "airplayaudio")
                    .font(.system(size: 20))
                    .foregroundStyle(.tint)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 3) {
                    Text("No audio yet")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Play something in another app, then send it here.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)

                // 押すとシステムの出力先の一覧が出る。そこで EffeTune を選ぶと、
                // いま鳴っているアプリの音がこちらへ来る。
                // コントロールセンターを開くのと同じことを、ここでできる。
                RoutePicker()
                    .frame(width: 40, height: 40)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct EmptyChainRow: View {
    let add: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("No effects")
                .font(.system(size: 16, weight: .semibold))
            Text("The audio passes through untouched.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button("Add Effect", action: add)
                .buttonStyle(.borderedProminent)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
    }
}
