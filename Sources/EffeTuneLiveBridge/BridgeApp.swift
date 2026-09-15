//  BridgeApp.swift
//  EffeTune Bridge — Media Device Extension を運ぶためだけのアプリ。
//
//  拡張を同梱したアプリは AVAudioSession を開けない（'!pla'）。
//  だからここに UI も DSP も置けない。音は EffeTune Live が出す。
//  ユーザーはこれを入れておくだけでよく、開く必要は無い。
//
//  下の SpeakerProbe は、その「開けない」を実機で確かめるために残してある。

import SwiftUI
import AVFoundation
import AVKit

@main
struct EffeTuneLiveBridgeApp: App {
    var body: some Scene {
        WindowGroup { StatusView() }
    }
}

struct StatusView: View {
    @StateObject private var probe = SpeakerProbe.shared
    @State private var route = "-"
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("EffeTune Live Bridge").font(.largeTitle.bold())

                Text("""
                     確かめること

                     1. 何かのアプリで音を鳴らす
                     2. 下のボタンか、コントロールセンターの出力先で「EffeTune」を選ぶ
                        → 音が消えれば、システムの出力がこちらへ移っている
                     3. このアプリに戻って、下の4つを順に押す
                        → 440Hz が聞こえたやり方が、加工後の音を返せる経路
                     """)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                GroupBox("いまの出力ルート") {
                    Text(route)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                RoutePickerView().frame(height: 44)

                VStack(spacing: 8) {
                    Button("① playAndRecord + defaultToSpeaker + override(.speaker)") {
                        probe.play(mode: 0)
                    }
                    Button("② playAndRecord + defaultToSpeaker") { probe.play(mode: 1) }
                    Button("③ playback + mixWithOthers") { probe.play(mode: 2) }
                    Button("④ playback") { probe.play(mode: 3) }
                    Button("停止") { probe.stop() }.tint(.red)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .frame(maxWidth: .infinity)

                GroupBox("結果") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(probe.status).font(.footnote)
                        Text("再生時のルート: \(probe.route)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
        .onReceive(timer) { _ in route = probe.routeNow() }
    }
}

/// システムのルートピッカー。
struct RoutePickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.prioritizesVideoDevices = false
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
