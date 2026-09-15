//  BridgeApp.swift
//  EffeTune Live Bridge — Media Device Extension を運ぶためだけのアプリ。
//
//  拡張を同梱したアプリは AVAudioSession を開けない（'!pla'）。
//  だからここに UI も DSP も置けない。音は EffeTune Live が出す。
//  ユーザーはこれを入れておくだけでよく、普段は開かない。

import AVFoundation
import SwiftUI
import os

@main
struct EffeTuneLiveBridgeApp: App {
    var body: some Scene {
        WindowGroup { BridgeView() }
    }
}

/// **1 本にできるかの検証。**
///
/// 拡張を同梱したアプリは AVAudioSession が '!pla' で拒否される、と記録してある。
/// ただし逆アセンブルまで下りた調べでは、判定は
///   MediaExperience の _cmsBeginInterruptionGuts
///   → -[MXCoreSession hasMediaDeviceEntitlement] が YES なら -16980
/// で、そのフラグの入力は**アプリプロセスの署名 entitlement
/// com.apple.developer.media-device-extension ただ一つ**。
/// 同梱している .appex の有無でも Info.plist でもない。
///
/// そこで本体の entitlement を落とし、.appex 側にだけ残した状態で鳴るか試す。
/// 通れば 2 本に分ける理由が消える。
@MainActor
final class PlaybackProbe: ObservableObject {
    @Published var result = "not tried"

    private let log = Logger(subsystem: "ai.nemut.effetune", category: "probe")
    private var engine: AVAudioEngine?

    func run() {
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try s.setActive(true)
        } catch {
            let ns = error as NSError
            result = "session NG \(ns.domain) \(ns.code)"
            log.error("ET probe session NG \(ns.domain, privacy: .public) \(ns.code)")
            return
        }

        // 実際に音を出すところまで見る。setActive が通っても鳴らないことがある。
        let e = AVAudioEngine()
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        var phase: Float = 0
        let src = AVAudioSourceNode { _, _, frames, ablPtr -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
            for i in 0..<Int(frames) {
                let v = sinf(phase) * 0.08
                phase += 2 * .pi * 440 / 48000
                if phase > 2 * .pi { phase -= 2 * .pi }
                for b in 0..<abl.count {
                    abl[b].mData!.assumingMemoryBound(to: Float.self)[i] = v
                }
            }
            return noErr
        }
        e.attach(src)
        e.connect(src, to: e.mainMixerNode, format: fmt)
        do {
            try e.start()
        } catch {
            let ns = error as NSError
            result = "engine NG \(ns.domain) \(ns.code)"
            log.error("ET probe engine NG \(ns.domain, privacy: .public) \(ns.code)")
            return
        }
        engine = e
        result = "playing @ \(s.currentRoute.outputs.map(\.portName).joined(separator: ","))"
        log.notice("ET probe OK route=\(s.currentRoute.outputs.map(\.portName).joined(separator: ","), privacy: .public)")
    }

    func stop() {
        engine?.stop()
        engine = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        result = "stopped"
    }
}

struct BridgeView: View {
    @StateObject private var probe = PlaybackProbe()

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

            // 検証用。1 本にできるか分かったら消す。
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    Button("Play test tone") { probe.run() }
                        .buttonStyle(.borderedProminent)
                    Button("Stop") { probe.stop() }
                }
                Text(probe.result)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.bottom, 10)

            VStack(alignment: .leading, spacing: 8) {
                Label("Play something in another app", systemImage: "1.circle")
                Label("Pick EffeTune as the output in Control Center", systemImage: "2.circle")
                Label("Open EffeTune Live", systemImage: "3.circle")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(.regularMaterial, in: .rect(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
    }
}
