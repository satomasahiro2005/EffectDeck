//  SpeakerProbe.swift
//  根本的な問いを1つだけ測る。
//
//  システムの出力先が EffeTune（自作の仮想デバイス）になっている状態で、
//  入れ物のアプリは内蔵スピーカー／ヘッドホンへ音を出せるか。
//
//  出せない = ループが原理的に閉じない（受け取った音を鳴らす先が無い）
//  出せる   = 拡張で受けて App Group 経由でアプリへ渡し、アプリが鳴らせばよい
//
//  判定は耳で。440Hz が聞こえるかどうか。
//  合わせて、そのときの出力ルートをログと画面に出す。

import AVFoundation
import os

@MainActor
final class SpeakerProbe: ObservableObject {

    static let shared = SpeakerProbe()

    private let log = Logger(subsystem: "ai.nemut.effetune", category: "speakerprobe")
    private let engine = AVAudioEngine()
    private var player: AVAudioPlayerNode?

    @Published var status: String = "未実行"
    @Published var route: String = "-"

    private init() {}

    func routeNow() -> String {
        let outs = AVAudioSession.sharedInstance().currentRoute.outputs
        if outs.isEmpty { return "(出力なし)" }
        return outs.map { "\($0.portName) [\($0.portType.rawValue)]" }.joined(separator: ", ")
    }

    /// 指定のやり方でセッションを組んで 440Hz を鳴らす。
    func play(mode: Int) {
        stop()
        let s = AVAudioSession.sharedInstance()
        var how = ""
        do {
            switch mode {
            case 0:
                how = "playAndRecord + defaultToSpeaker + override(.speaker)"
                try s.setCategory(.playAndRecord, mode: .default,
                                  options: [.defaultToSpeaker, .mixWithOthers])
                try s.setActive(true)
                try s.overrideOutputAudioPort(.speaker)
            case 1:
                how = "playAndRecord + defaultToSpeaker"
                try s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
                try s.setActive(true)
            case 2:
                how = "playback + mixWithOthers"
                try s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                try s.setActive(true)
            default:
                how = "playback"
                try s.setCategory(.playback, mode: .default, options: [])
                try s.setActive(true)
            }
        } catch {
            let ns = error as NSError
            status = "セッション失敗 [\(how)]: \(ns.domain) \(ns.code)"
            log.error("session NG [\(how, privacy: .public)]: \(ns.domain, privacy: .public) \(ns.code)")
            route = routeNow()
            return
        }

        let fmt = AVAudioFormat(standardFormatWithSampleRate: s.sampleRate, channels: 2)!
        let p = AVAudioPlayerNode()
        engine.attach(p)
        engine.connect(p, to: engine.mainMixerNode, format: fmt)

        let frames = AVAudioFrameCount(fmt.sampleRate)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return }
        buf.frameLength = frames
        for i in 0..<Int(frames) {
            let v = 0.2 * sinf(2.0 * .pi * 440.0 * Float(i) / Float(fmt.sampleRate))
            buf.floatChannelData![0][i] = v
            if fmt.channelCount > 1 { buf.floatChannelData![1][i] = v }
        }

        do {
            try engine.start()
        } catch {
            let ns = error as NSError
            status = "engine 失敗 [\(how)]: \(ns.domain) \(ns.code)"
            log.error("engine NG [\(how, privacy: .public)]: \(ns.domain, privacy: .public) \(ns.code)")
            route = routeNow()
            return
        }
        p.scheduleBuffer(buf, at: nil, options: .loops)
        p.play()
        player = p
        route = routeNow()
        status = "再生中: \(how)"
        log.info("再生開始 [\(how, privacy: .public)] route=\(self.route, privacy: .public)")
    }

    func stop() {
        player?.stop()
        if let p = player { engine.detach(p) }
        player = nil
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
        status = "停止"
    }
}
