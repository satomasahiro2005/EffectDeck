//  AudioIO.swift
//  拡張から届いた PCM を EffeTune の鎖へ通して、内蔵スピーカーへ返す。
//
//  なぜこのアプリが鳴らす役なのか（実機のログで確定）:
//    Media Device Extension を同梱したアプリは AVAudioSession を開けない（'!pla'）。
//    拡張プロセス自身も開けない（'msrv'）。
//    だから拡張は EffeTune Bridge が運び、音はこのアプリが出す。
//
//  拡張を同梱していないので、EffeTune がシステムの出力先になっていても
//  こちらは内蔵スピーカーを掴んだままでいられる。回り込まない。

import AVFoundation
import os

/// 音のスレッドだけが触る置き場。確保はここで先に済ませる。
private final class RenderState {
    let capacity: Int
    let interleaved: UnsafeMutablePointer<Float>
    let planar: UnsafeMutablePointer<Float>
    let sampleRate: Double

    var meter: Float = 0
    var applied: UInt32 = 0
    var elapsed: Double = 0

    init(capacity: Int, sampleRate: Double) {
        self.capacity = capacity
        self.sampleRate = sampleRate
        interleaved = .allocate(capacity: capacity * 2)
        planar = .allocate(capacity: capacity * 2)
        interleaved.initialize(repeating: 0, count: capacity * 2)
        planar.initialize(repeating: 0, count: capacity * 2)
    }

    deinit {
        interleaved.deallocate()
        planar.deallocate()
    }
}

@MainActor
final class AudioIO: ObservableObject {

    static let shared = AudioIO()

    private let log = Logger(subsystem: "ai.nemut.effetune", category: "audio")
    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode?
    private var render: RenderState?

    private static let capacity = 8192

    @Published var running = false
    @Published var status = "停止中"
    @Published var route = "-"
    @Published var listening = false
    @Published var hasPeer = false
    @Published var received: UInt64 = 0
    @Published var level: Float = 0
    @Published var applied: Int = 0

    private init() {
        // 拡張はいつ繋いでくるか分からないので、起動と同時に待ち受ける。
        _ = ETLinkReceiver.shared.start()
    }

    func start() {
        stop(keepListening: true)

        if !ETLinkReceiver.shared.listening {
            guard ETLinkReceiver.shared.start() else {
                status = "待ち受けを開けない"
                return
            }
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .mixWithOthers])
            try session.setPreferredSampleRate(48000)
            try session.setActive(true)
            try session.overrideOutputAudioPort(.speaker)
        } catch {
            let ns = error as NSError
            status = "セッション失敗 \(ns.domain) \(ns.code)"
            log.error("session NG \(ns.domain, privacy: .public) \(ns.code)")
            return
        }

        let sr = session.sampleRate > 0 ? session.sampleRate : 48000
        let state = RenderState(capacity: Self.capacity, sampleRate: sr)
        render = state

        EffeTuneDSP.shared.prepare(sampleRate: sr, maxChannels: 2,
                                   maxFrames: UInt32(Self.capacity))

        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        let src = AVAudioSourceNode { _, _, frameCount, ablPtr -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
            let n = min(Int(frameCount), state.capacity)

            // 1. リンクから受ける（インターリーブ）
            _ = ETLinkReceiver.shared.readInterleaved(state.interleaved, frames: UInt32(n))

            // 2. プレーナへ並べ替える
            //    EffeTune のカーネルは offset = channel * frame_count で読むため。
            let p = state.planar
            let s = state.interleaved
            for i in 0..<n {
                p[i]     = s[i * 2]
                p[n + i] = s[i * 2 + 1]
            }

            // 3. EffeTune の鎖を通す
            state.applied = ETChain_Process(p, 2, UInt32(n), state.elapsed)
            state.elapsed += Double(n) / state.sampleRate

            // 4. 出力へ書く
            var peak: Float = 0
            let l = abl[0].mData!.assumingMemoryBound(to: Float.self)
            let r = abl.count > 1 ? abl[1].mData!.assumingMemoryBound(to: Float.self) : l
            for i in 0..<n {
                let a = p[i], b = p[n + i]
                l[i] = a
                if abl.count > 1 { r[i] = b }
                let m = max(abs(a), abs(b))
                if m > peak { peak = m }
            }
            for i in n..<Int(frameCount) {
                l[i] = 0
                if abl.count > 1 { r[i] = 0 }
            }
            state.meter = peak
            return noErr
        }

        engine.attach(src)
        engine.connect(src, to: engine.mainMixerNode, format: fmt)
        node = src

        do {
            try engine.start()
        } catch {
            let ns = error as NSError
            status = "engine 失敗 \(ns.domain) \(ns.code)"
            return
        }

        running = true
        status = "再生中"
        route = routeNow()
        log.info("開始 sr=\(sr) route=\(self.route, privacy: .public)")
    }

    func stop(keepListening: Bool = false) {
        node.map { engine.detach($0) }
        node = nil
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
        if !keepListening { ETLinkReceiver.shared.stop() }
        EffeTuneDSP.shared.reset()
        render = nil
        running = false
        level = 0
        status = "停止中"
    }

    func tick() {
        route = routeNow()
        level = render?.meter ?? 0
        applied = Int(render?.applied ?? 0)
        listening = ETLinkReceiver.shared.listening
        hasPeer = ETLinkReceiver.shared.hasPeer
        received = ETLinkReceiver.shared.receivedFrames
    }

    private func routeNow() -> String {
        let outs = AVAudioSession.sharedInstance().currentRoute.outputs
        if outs.isEmpty { return "(出力なし)" }
        return outs.map { "\($0.portName)[\($0.portType.rawValue)]" }.joined(separator: ",")
    }
}
