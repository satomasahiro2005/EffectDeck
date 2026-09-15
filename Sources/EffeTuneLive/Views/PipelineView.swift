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
    @State private var expanded: Set<UUID> = []

    private let timer = Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()

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
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showPicker) {
                EffectPickerView { spec in
                    dsp.add(spec)
                    // 足した直後のものだけ開いておく。他は畳んだまま。
                    if let last = dsp.chain.last { expanded = [last.id] }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView(io: io) }
            .sheet(isPresented: $showRouting) { RoutingView(dsp: dsp) }
        }
        .onReceive(timer) { _ in io.tick() }
    }

    /// EffeTune の「ON  Effect Pipeline    96000 Hz」の帯。
    private var pipelineHeader: some View {
        HStack(spacing: 10) {
            Button {
                dsp.bypass.toggle()
            } label: {
                PowerBadge(isOn: !dsp.bypass)
            }
            .buttonStyle(.plain)
            .disabled(dsp.chain.isEmpty)

            Text("Effect Pipeline")
                .font(.system(size: 17, weight: .semibold))

            Spacer()

            Text(io.running ? "\(Int(io.sampleRate)) Hz" : "—")
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.secondary)

            Menu {
                Button { showRouting = true } label: {
                    Label("Routing…", systemImage: "arrow.triangle.branch")
                }
                .disabled(dsp.chain.isEmpty)
                Button(role: .destructive) { dsp.clear() } label: {
                    Label("Remove All", systemImage: "trash")
                }
                .disabled(dsp.chain.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 16))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var chainList: some View {
        List {
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
                        isExpanded: expanded.contains(node.id),
                        toggleExpanded: {
                            if expanded.contains(node.id) { expanded.remove(node.id) }
                            else { expanded.insert(node.id) }
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
                    Text("Play something in another app, then pick **EffeTune** as the output in Control Center.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
