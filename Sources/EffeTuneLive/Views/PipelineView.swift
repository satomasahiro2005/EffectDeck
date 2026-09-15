//  PipelineView.swift
//  本画面。EffeTune の Effect Pipeline にあたる。
//
//  EffeTune との違い:
//    - 左のエフェクト一覧は常時は出さない。iPhone の幅では鎖が読めなくなるので、
//      + から出すシートにしてある
//    - 音源はファイルではなく他のアプリなので、下の帯は再生位置ではなく
//      「音が来ているか」と「出している先」を出す

import SwiftUI

struct PipelineView: View {
    @StateObject private var io = AudioIO.shared
    @StateObject private var dsp = EffeTuneDSP.shared
    @State private var showPicker = false
    @State private var showHelp = false
    @State private var showSettings = false

    private let timer = Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                pipelineHeader
                chainList
                transportBar
            }
            .navigationTitle("EffeTune Live")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showHelp = true } label: { Image(systemName: "questionmark.circle") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showPicker = true } label: { Image(systemName: "plus") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showPicker) { EffectPickerView() }
            .sheet(isPresented: $showHelp) { HelpView() }
            .sheet(isPresented: $showSettings) { SettingsView(io: io) }
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var chainList: some View {
        Group {
            if dsp.chain.isEmpty {
                ContentUnavailableView {
                    Label("No Effects", systemImage: "slider.horizontal.3")
                } description: {
                    Text("Add an effect to start shaping the audio coming from other apps.")
                } actions: {
                    Button("Add Effect") { showPicker = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach(Array(dsp.chain.enumerated()), id: \.element.id) { index, node in
                        EffectCardView(index: index, node: node, dsp: dsp)
                            .listRowInsets(EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    .onDelete { dsp.remove(at: $0) }
                    .onMove { dsp.move(from: $0, to: $1) }
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 0)
            }
        }
    }

    /// 下の帯。音がどこから来てどこへ出ているか。
    private var transportBar: some View {
        VStack(spacing: 8) {
            Divider()
            HStack(spacing: 12) {
                Button {
                    io.running ? io.stop() : io.start()
                } label: {
                    Image(systemName: io.running ? "stop.fill" : "play.fill")
                        .font(.system(size: 17, weight: .bold))
                        .frame(width: 46, height: 38)
                }
                .buttonStyle(.borderedProminent)
                .tint(io.running ? .red : .accentColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text(sourceLine)
                        .font(.system(size: 12))
                        .foregroundStyle(io.hasPeer ? .primary : .secondary)
                        .lineLimit(1)
                    LevelBar(level: io.level)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
        .background(.bar)
    }

    private var sourceLine: String {
        if !io.running { return "Stopped" }
        if !io.hasPeer { return "Waiting — pick EffeTune in Control Center" }
        return "Receiving · \(io.route)"
    }
}

/// 出ている音の大きさ。EffeTune の Level Meter ほどの情報は無いが、
/// 音が通っているかどうかはここで分かる。
struct LevelBar: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(level > 0.95 ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
                    .frame(width: geo.size.width * CGFloat(min(max(level, 0), 1)))
            }
        }
        .frame(height: 4)
    }
}

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("How to use") {
                    Text("1. Keep this app open.")
                    Text("2. Play something in another app.")
                    Text("3. In Control Center, set the output to EffeTune.")
                    Text("4. Press play here.")
                }
                Section("Why there are two apps") {
                    Text("""
                         The audio is captured by an extension that ships inside \
                         EffeTune Live Bridge. iOS does not let an app that contains \
                         such an extension open an audio session of its own, so \
                         playback lives here instead. Bridge only needs to be installed; \
                         you never have to open it.
                         """)
                }
                Section("Effects") {
                    Text("""
                         The effects are EffeTune's own DSP, running unmodified. \
                         Nothing was ported or rewritten, so it sounds like the \
                         desktop version.
                         """)
                }
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
