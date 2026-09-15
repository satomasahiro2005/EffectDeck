//  AudioIO.swift
//  拡張から届いた PCM を EffeTune の鎖へ通して、スピーカーへ返す。
//
//  なぜこのアプリが鳴らす役なのか（実機のログで確定）:
//    Media Device Extension を同梱したアプリは AVAudioSession を開けない（'!pla'）。
//    拡張プロセス自身も開けない（'msrv'）。
//    だから拡張は EffeTune Live Bridge が運び、音はこのアプリが出す。
//
//  開始/停止のボタンは持たない。拡張が繋がったら自分で鳴らし始め、切れたら畳む。
//  鎖を切りたいときは Effect Pipeline の ON を切る（素通しになる）。
//
//  DSP は入力より高いレートで回せる。EffeTune が AudioContext を 96kHz で開いて
//  非線形エフェクトの折り返しを減らしているのと同じことを、両端のリサンプラでやる。

import AVFoundation
import Darwin
import os

/// 音のスレッドだけが触る置き場。確保はここで先に済ませる。
private final class RenderState {
    let capacity: Int          // 入力レートでのフレーム数の上限
    let factor: Int
    let sampleRate: Double     // 出力（＝入力）レート

    let interleaved: UnsafeMutablePointer<Float>   // capacity * 2
    let planar: UnsafeMutablePointer<Float>        // capacity * 2
    let hi: UnsafeMutablePointer<Float>            // capacity * factor * 2
    var resampler: OpaquePointer?

    var meter: Float = 0
    var applied: UInt32 = 0
    var elapsed: Double = 0
    var load: Double = 0
    var gate = PowerGate()
    var resting = false

    private var timebase = mach_timebase_info_data_t()

    init(capacity: Int, sampleRate: Double, factor: Int) {
        self.capacity = capacity
        self.sampleRate = sampleRate
        self.factor = factor

        interleaved = .allocate(capacity: capacity * 2)
        planar      = .allocate(capacity: capacity * 2)
        hi          = .allocate(capacity: capacity * factor * 2)
        interleaved.initialize(repeating: 0, count: capacity * 2)
        planar.initialize(repeating: 0, count: capacity * 2)
        hi.initialize(repeating: 0, count: capacity * factor * 2)

        if factor > 1 {
            resampler = ETResampler_Create(UInt32(factor), 2, UInt32(capacity))
        }
    }

    deinit {
        interleaved.deallocate()
        planar.deallocate()
        hi.deallocate()
        ETResampler_Destroy(resampler)
    }

    func now() -> Double {
        if timebase.denom == 0 { mach_timebase_info(&timebase) }
        return Double(mach_absolute_time()) * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }
}

@MainActor
final class AudioIO: ObservableObject {

    static let shared = AudioIO()

    private let log = Logger(subsystem: "ai.nemut.effetune", category: "audio")
    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode?
    private var render: RenderState?

    private static let capacity = 4096

    @Published var running = false
    @Published var sampleRate: Double = 48000
    @Published var processingRate: Double = 48000
    @Published var status = "Stopped"
    @Published var route = "—"
    @Published var listening = false
    @Published var hasPeer = false
    @Published var received: UInt64 = 0
    @Published var level: Float = 0
    @Published var applied: Int = 0
    @Published var load: Double = 0
    @Published var bufferedFrames: UInt32 = 0
    @Published var blockFrames: Int = 0
    /// リサンプラが増やす遅延（入力レートのサンプル数）。
    @Published var resamplerLatency: Int = 0
    /// 無音で休んでいるか。
    @Published var resting = false

    private var ticks = 0

    private init() {
        // 拡張はいつ繋いでくるか分からないので、起動と同時に待ち受ける。
        _ = ETLinkReceiver.shared.start()
        Preferences.shared.onAudioChange = { [weak self] in self?.rebuild() }
        // ロック画面の再生/一時停止は、曲ではなく鎖の入切に割り当てる。
        NowPlaying.start { on in EffeTuneDSP.shared.bypass = !on }
    }

    /// 音の経路に関わる設定が変わったら組み直す。一瞬切れる。
    private func rebuild() {
        guard running else { return }
        stop(keepListening: true)
        start()
    }

    /// 拡張が繋がったら自分で鳴らし始め、切れたら畳む。
    private func followPeer() {
        let peer = ETLinkReceiver.shared.hasPeer
        if peer && !running {
            start()
        } else if !peer && running {
            stop(keepListening: true)
        }
    }

    func start() {
        stop(keepListening: true)

        if !ETLinkReceiver.shared.listening {
            guard ETLinkReceiver.shared.start() else {
                status = "Cannot open the listening socket"
                return
            }
        }

        let prefs = Preferences.shared
        let session = AVAudioSession.sharedInstance()
        do {
            // .playAndRecord は既定で Bluetooth の出力を候補から外す。
            // .allowBluetoothA2DP を足さないとワイヤレスイヤホンへ出せない
            // （足さずに .allowBluetooth だけだと HFP のモノラルに落ちる）。
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .mixWithOthers,
                                              .allowBluetoothA2DP, .allowAirPlay])
            try session.setPreferredSampleRate(48000)
            try session.setPreferredIOBufferDuration(prefs.latency.bufferDuration)
            try session.setActive(true)
            // 出力先はシステムに任せる。こちらから指定しない。
            //
            // 普通のアプリに「自分だけの出力先」を選ぶ手段は無い。
            // AVRoutePickerView はシステムのルートピッカーそのもので、
            // Spotify が出しているのと同じ画面。そこで選ぶと、Spotify が
            // MediaDevice で EffeTune へ向けていたアプリごとの上書きまで外れる。
            // overrideOutputAudioPort も同じ理由で使わない。
            // イヤホンを繋いでいるのにスピーカーから鳴る事故も、これで起きない。
            try session.overrideOutputAudioPort(.none)
        } catch {
            let ns = error as NSError
            status = "Audio session failed: \(ns.domain) \(ns.code)"
            log.error("session NG \(ns.domain, privacy: .public) \(ns.code)")
            return
        }

        let sr = session.sampleRate > 0 ? session.sampleRate : 48000
        let factor = Int(prefs.processingRate.factor)
        let state = RenderState(capacity: Self.capacity, sampleRate: sr, factor: factor)
        state.gate.idleSeconds = prefs.powerMode.idleSeconds
        state.gate.thresholdLinear = Float(pow(10.0, prefs.silenceThresholdDb / 20.0))
        render = state

        EffeTuneDSP.shared.prepare(sampleRate: sr * Double(factor), maxChannels: 2,
                                   maxFrames: UInt32(Self.capacity * factor))

        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        let src = AVAudioSourceNode { _, _, frameCount, ablPtr -> OSStatus in
            let began = state.now()
            let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
            let n = min(Int(frameCount), state.capacity)
            let f = state.factor

            // 1. リンクから受ける（インターリーブ・48kHz）
            _ = ETLinkReceiver.shared.readInterleaved(state.interleaved, frames: UInt32(n))

            // 2. プレーナへ並べ替える。
            //    EffeTune のカーネルは offset = channel * frame_count で読む。
            let p = state.planar
            let s = state.interleaved
            for i in 0..<n {
                p[i]     = s[i * 2]
                p[n + i] = s[i * 2 + 1]
            }

            // 3. 無音が続いていたら鎖を通さない。
            //    無音に何を掛けても無音なので、聞こえ方は変わらない。
            //    セッションは手放さない。手放すと出力先が戻ってしまう。
            var inPeak: Float = 0
            for i in 0..<(n * 2) {
                let a = abs(p[i])
                if a > inPeak { inPeak = a }
            }
            let awake = state.gate.update(peak: inPeak, seconds: Double(n) / state.sampleRate)
            state.resting = !awake

            // 4. 本線のバスへ書いて、鎖を通して、読み戻す。
            //    バスの置き場は engine が持っているので、そこへ直接書く。
            if awake, let main = ETPipeline_MainBus() {
                if f > 1, let rs = state.resampler {
                    ETResampler_Up(rs, p, main, UInt32(n))
                    state.applied = ETPipeline_Process(2, UInt32(n * f), state.elapsed)
                    ETResampler_Down(rs, main, p, UInt32(n))
                } else {
                    main.update(from: p, count: n * 2)
                    state.applied = ETPipeline_Process(2, UInt32(n), state.elapsed)
                    p.update(from: main, count: n * 2)
                }
            } else {
                state.applied = 0
            }
            state.elapsed += Double(n) / state.sampleRate

            // 5. 出力へ書く
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

            let spent = state.now() - began
            let budget = Double(n) / state.sampleRate
            state.load += (spent / max(budget, 1e-9) - state.load) * 0.1
            return noErr
        }

        engine.attach(src)
        engine.connect(src, to: engine.mainMixerNode, format: fmt)
        node = src

        do {
            try engine.start()
        } catch {
            let ns = error as NSError
            status = "Audio engine failed: \(ns.domain) \(ns.code)"
            return
        }

        running = true
        sampleRate = sr
        processingRate = sr * Double(factor)
        resamplerLatency = Int(ETResampler_LatencySamples(state.resampler))
        status = "Running"
        route = routeNow()
        updateNowPlaying()
        log.notice("start sr=\(sr) x\(factor) route=\(self.route, privacy: .public)")
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
        status = "Stopped"
        NowPlaying.stop()
    }

    /// 描画用の値だけを速く取る。図が滑らかに動くのはこちらの速さで決まる。
    /// DSP は 30Hz で吐いているので、それに合わせる。
    /// 重い問い合わせ（ルートやセッション）はここでやらない。
    func pollTelemetry() {
        Telemetry.shared.poll(engine: EffeTuneDSP.shared.engine)
        level = render?.meter ?? 0
    }

    /// 状態の見直し。重いものはこちら。
    func tick() {
        ticks += 1
        followPeer()
        if ticks % 20 == 0 {
            log.notice("tick applied=\(self.applied) chain=\(EffeTuneDSP.shared.chain.count) peer=\(self.hasPeer) recv=\(self.received) load=\(self.load)")
        }
        route = routeNow()
        level = render?.meter ?? 0
        applied = Int(render?.applied ?? 0)
        load = render?.load ?? 0
        resting = render?.resting ?? false
        updateNowPlaying()
        listening = ETLinkReceiver.shared.listening
        hasPeer = ETLinkReceiver.shared.hasPeer
        received = ETLinkReceiver.shared.receivedFrames
        bufferedFrames = ETLinkReceiver.shared.bufferedFrames
        let session = AVAudioSession.sharedInstance()
        blockFrames = Int((session.ioBufferDuration * session.sampleRate).rounded())
    }

    private var lastNowPlaying: (Bool, Bool, Int) = (false, false, -1)

    /// 変わったときだけ出す。毎回書き換えるとロック画面がちらつく。
    private func updateNowPlaying() {
        let active = !EffeTuneDSP.shared.bypass && applied > 0
        let count = applied
        let now = (running, active, count)
        guard now != lastNowPlaying else { return }
        lastNowPlaying = now
        NowPlaying.update(running: running, active: active, count: count)
    }

    private func routeNow() -> String {
        let outs = AVAudioSession.sharedInstance().currentRoute.outputs
        if outs.isEmpty { return "no output" }
        return outs.map(\.portName).joined(separator: ", ")
    }
}
