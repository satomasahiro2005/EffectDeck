//  BridgeApp.swift
//  EffeTune Live Bridge — Media Device Extension を運ぶためだけのアプリ。
//
//  拡張を同梱したアプリは AVAudioSession を開けない（'!pla'）。
//  だからここに UI も DSP も置けない。音は EffeTune Live が出す。
//  ユーザーはこれを入れておくだけでよく、普段は開かない。

import SwiftUI

@main
struct EffeTuneLiveBridgeApp: App {
    var body: some Scene {
        WindowGroup { BridgeView() }
    }
}

struct BridgeView: View {
    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            Image(systemName: "airplayaudio")
                .font(.system(size: 46))
                .foregroundStyle(.tint)

            Text("EffeTune Live Bridge")
                .font(.title2.bold())

            Text("""
                 This app carries the audio device that shows up in Control Center. \
                 Keep it installed and leave it alone — there is nothing to do here.
                 """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                Label("Play something in another app", systemImage: "1.circle")
                Label("Pick EffeTune as the output in Control Center", systemImage: "2.circle")
                Label("Open EffeTune Live", systemImage: "3.circle")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
    }
}
