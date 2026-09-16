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
    /// 直近の ETPipeline_Process の戻り値（et_status）。ET_OK は 0。
    var pipeStatus: Int32 = 0
    var elapsed: Double = 0
    var load: Double = 0
    var gate = PowerGate()
    var resting = false


    /// 撮影用の作り物の信号。-ETMock 1 のときだけ入る。
    /// 実機では常に nil なので、音のスレッドでは nil 判定 1 回ぶんしか増えない。
    var mock: ETMockSource?

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
        if ETMockSource.enabled { mock = ETMockSource(sampleRate: sampleRate) }
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

/// `-ETConsole 1` のときだけ、測るための行を標準出力にも出す。
/// os_log は無線では取り出せないので、`devicectl device process launch --console`
/// から読めるようにするためだけに在る。
///
/// **AudioIO の @MainActor より前に置くこと。** 属性とクラス宣言の間に
/// 挟むと属性がこちらへ付いて、AudioIO が非隔離になり全体が崩れる。
enum ETConsoleLog {
    nonisolated static let on = UserDefaults.standard.string(forKey: "ETConsole") != nil
}

@MainActor
final class AudioIO: ObservableObject {

    static let shared = AudioIO()

    private let log = Logger(subsystem: "ai.nemut.effetune", category: "audio")
    /// mediaServicesWereReset のあとは古い engine が死んでいて二度と start しない。
    /// 作り直せるように let ではなく var。
    private var engine = AVAudioEngine()
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
    /// 出力のピーク。**@Published ではない。**
    /// Sources のどのビューも読んでいない（メーターは Telemetry の枠を読む）のに
    /// 30Hz で publish していて、観測している側の body を 33ms ごとに作り直していた。
    /// 読み手が増えるときは、ここではなく Telemetry を見ること。
    private(set) var level: Float = 0
    @Published var applied: Int = 0
    /// このアプリの音がどこへ出ているか。
    /// 仮想デバイス「EffeTune」を指していたら帰還ループ。
    @Published var outputRoute: String = "—"
    /// 出力先が仮想デバイスのままなら true。鎖が自分に戻っている。
    @Published var loopback = false
    @Published var load: Double = 0
    @Published var bufferedFrames: UInt32 = 0
    @Published var blockFrames: Int = 0
    /// リサンプラが増やす遅延（入力レートのサンプル数）。
    @Published var resamplerLatency: Int = 0
    /// 鎖そのものが持つ遅延（処理レートのサンプル数）。
    ///
    /// `et_pipeline_latency`（abi.h:125）を `ETPipeline_Latency()` 越しに読む。
    /// 読んでいなかったので、Phase Select EQ のように実際に遅延を増やす
    /// エフェクトを入れても帯の数字が動かなかった。
    @Published var pipelineLatency: Int = 0
    /// 無音で休んでいるか。
    @Published var resting = false

    private var ticks = 0

    /// 中断中は再開しない。中断中の setActive(true) は失敗するだけなので、
    /// followPeer が 3.3Hz で叩き続けることになる。
    private var interrupted = false
    /// start() が失敗したとき、次を試すまでの間隔（秒）を稼ぐ。
    private var lastStartAttempt: Double = 0
    /// ハードウェアのレートが組んだときと食い違っている目盛りの数。
    /// 一瞬の食い違いで組み直すと音が切れ続けるので、続いたものだけを見る。
    private var rateMismatchTicks = 0
    /// NotificationCenter の購読。singleton なので外す機会は無いが、持っておく。
    private var observers: [NSObjectProtocol] = []

    private init() {
        // 拡張はいつ繋いでくるか分からないので、起動と同時に待ち受ける。
        _ = ETLinkReceiver.shared.start()
        Preferences.shared.onAudioChange = { [weak self] in self?.rebuild() }
        observeSession()

        // DSP のエンジンは音と関係なく用意しておく。
        // 音が来るまで待っていると、その間エフェクトを足しても作れず一覧に出ない。
        // 実際のレートが分かったら start() で用意し直す。
        let factor = Double(Preferences.shared.processingRate.factor)
        EffeTuneDSP.shared.prepare(sampleRate: 48000 * factor, maxChannels: 2,
                                   maxFrames: UInt32(Double(Self.capacity) * factor))
        // ロック画面の再生/一時停止は、曲ではなく鎖の入切に割り当てる。
        NowPlaying.start { on in EffeTuneDSP.shared.bypass = !on }
        // 測るためだけ。`-ETNowPlaying first` のときだけ、start()（setCategory）より
        // 前に now playing を名乗る。前後の入れ替わりがループバックの原因なら
        // 毎回 rsp=1 になるはず。
        NowPlaying.claimBeforeSession()
    }

    /// 音の経路に関わる設定が変わったら組み直す。一瞬切れる。
    private func rebuild() {
        guard running else { return }
        stop(keepListening: true)
        start()
    }

    // MARK: - セッション側の出来事

    /// AVAudioSession から来る通知を拾う。
    /// 購読が無かったので、経路が変わっても中断から戻っても誰も気づかなかった。
    private func observeSession() {
        let nc = NotificationCenter.default
        // 経路変更も中断もメインスレッド以外から飛ぶことがあるので queue: .main で受ける。
        // userInfo は Sendable ではないので、ブロックの中で数に落としてから渡す。
        observers.append(nc.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main) { [weak self] note in
                // **理由を落とさない。**
                // tick は約 6 秒おきなので、EffeTune を指している 1.5 秒の窓が
                // まるごと映らない。実際 2026-09-16 の 1 往復では tick が
                // 一度も out=EffeTune を捉えず、recv だけが 146432 で止まった。
                // 通知で撃てば窓の長さごと取れる。
                let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 99
                Task { @MainActor in self?.refreshRoute(reason: reason) }
            })

        observers.append(nc.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main) { [weak self] note in
                // 既定値を 0 にしない。rawValue 0 は .began なので、
                // 型の入っていない通知が来たら音を止めることになる。
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                else { return }
                let opts = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                Task { @MainActor in self?.handleInterruption(raw: raw, options: opts) }
            })

        observers.append(nc.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.handleMediaServicesReset() }
            })
    }

    /// 着信などで OS がセッションを落としたとき。
    ///
    /// これを見ていないと、engine は止まっているのに running は true のまま
    /// （stop() を通っていないので）、peer も TCP が生きているので true のままになり、
    /// followPeer の条件が両方とも成り立たず**永久に音が戻らない**。
    /// 受信側の timer は別系統なので recv だけが増え続ける。
    private func handleInterruption(raw: UInt, options: UInt) {
        guard let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            interrupted = true
            log.notice("interruption began")
            if running { stop(keepListening: true) }
            status = "Interrupted"
        case .ended:
            interrupted = false
            let resume = AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
            log.notice("interruption ended resume=\(resume)")
            // shouldResume が無いときは何もしない。拡張が繋がったままなら followPeer が拾う。
            if resume { start() }
        @unknown default:
            interrupted = false
        }
    }

    /// メディアサービスが落ちて作り直されたとき。
    /// 古い AVAudioEngine も古いセッションの設定も死んでいるので、全部作り直す。
    private func handleMediaServicesReset() {
        log.notice("media services were reset")
        stop(keepListening: true)
        interrupted = false
        engine = AVAudioEngine()
        node = nil
        // ロック画面の割り当ても作り直す（wired が立っていれば有効化だけ）。
        NowPlaying.start { on in EffeTuneDSP.shared.bypass = !on }
        // 拡張が繋がっていなければ鳴らし始めない。判断は followPeer に任せる。
        lastStartAttempt = 0
        followPeer()
    }

    /// **拡張が繋がる前から鳴らしておく。**
    ///
    /// 以前は peer が立ってから start() していたが、それだと鶏と卵になる。
    /// UIBackgroundModes の audio は「実際に鳴らしている間」だけアプリを生かす。
    /// 鳴らしていないと背景で止められ、127.0.0.1:47101 が受け付けなくなる:
    ///   et.log:49001 04:29:50.925840 EffeTuneLiveExtension[587] ET connect 失敗 errno=61
    ///   et.log:51268 04:29:51.934152 受信 frames=39936 接続=false 送信=0
    /// 拡張が requiredNetworkEndpoints として名乗るのもこの 47101 なので
    /// （Sources/Extension/EffeTuneLiveExtension.swift の linkEndpoint）、
    /// ここが止まると名乗った口が実在しなくなる。
    ///
    /// **訂正。** ここには「繋がらないからシステムが 1.5 秒で諦めて Unable to Connect に
    /// なる」と書いてあったが、違う。本体が居ない区間——04:29:47.817036 の
    /// destroy_session(EffeTune Live(530)) から 04:30:25.812872 の create_session まで
    /// ——でも endpoint は同じように切られている:
    ///   et.log:51269 04:29:52.648007 / et.log:56349 04:29:57.736604
    ///     FigRoutingManagerDeactivateEndpointFromPickedContexts ... a different endpoint got picked
    /// finishActivation からの差は接続=false の回で 1.520 / 1.520 / 1.519 / 1.553 / 1.522、
    /// 接続=true の回で 1.533 / 1.504 / 1.541 / 1.517 / 1.499 / 1.528 / 1.484。区別がつかない。
    /// TCP の成否は切断の条件に入っていない。AudioIO は引き金ではないので触らない。
    ///
    /// なので、繋がっていなくても無音を出し続ける。
    /// PowerGate が休むので演算はほぼ使わないし、.mixWithOthers なので
    /// 他のアプリの音を止めない。
    private func followPeer() {
        // running だけを見ると取りこぼす。中断で OS が engine を止めても
        // stop() を通らないので running は true のまま残る。食い違いを直接見る。
        let alive = running && engine.isRunning

        if !alive {
            guard !interrupted else { return }
            // start() が失敗し続けるとき（中断中の setActive など）に
            // 3.3Hz で叩かないよう、1 秒は空ける。
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastStartAttempt >= 1 else { return }
            start()
        } else if false {
            stop(keepListening: true)
        }
    }

    func start() {
        // 失敗しても次まで 1 秒空けるため、入口で押しておく（followPeer が見る）。
        lastStartAttempt = ProcessInfo.processInfo.systemUptime
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
            // （.allowBluetooth だけだと HFP のモノラルに落ちる）。
            //
            // 一度これを外していた。帰還ループの犯人だと疑ったから。
            // 真犯人は AVRoutePickerView を画面に置いていたことで、
            // このアプリが共有の出力コンテキストへ参加してしまっていた。
            // ピッカーを外して解決したので、BT も override も戻す。
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .mixWithOthers,
                                              .allowBluetoothA2DP])
            try session.setPreferredSampleRate(48000)
            try session.setPreferredIOBufferDuration(prefs.latency.bufferDuration)
            try session.setActive(true)
            // 出力先はシステムに任せる。
            // .speaker を無条件に当てると、イヤホンを繋いでいても
            // 内蔵スピーカーから鳴る。
            // 仮想デバイスへ引きずられていないかは
            // refreshRoute() の loopback で見て、Settings に出す。
            //
            // **いま仮想デバイスを指しているときは触らない。**
            // followPeer() は engine が上がらない間 1 秒おきに start() を
            // 呼び直す（下の 270-279）。ここで無条件に .none と reset() を撃つと
            // escape.attempts が毎秒 0 に戻り、打ち止め（maxAttempts = 3）が
            // 一度も効かない。しかも経路の再計算は setCategory / setActive の側で
            // 起きるので、いちばん効かせたい瞬間に「システムの選択に従う」と
            // 宣言していることになる。
            let onVirtualNow = session.currentRoute.outputs.contains {
                $0.portName.localizedCaseInsensitiveContains("EffeTune")
            }
            if !onVirtualNow {
                try session.overrideOutputAudioPort(.none)
                escape.reset()
                reportedGaveUp = false
            }


            // このアプリの音がどこへ出ているか。
            // 仮想デバイス自身を指していたら帰還ループ。
            let outs = session.currentRoute.outputs
                .map { "\($0.portType.rawValue):\($0.portName)" }
                .joined(separator: ",")
            // **経路が決まった直後の rsp を残す。**
            // routeSharingPolicy はこちらが一度も設定していないので、
            // 1 (LongFormAudio) が出たら系が SystemMusic へ移したということ。
            // np は NowPlaying を止めているか（-ETNoNowPlaying 1）。
            let line = "session out=\(outs) rsp=\(session.routeSharingPolicy.rawValue) np=\(NowPlaying.mode.rawValue)"
            log.notice("\(line, privacy: .public)")
            if ETConsoleLog.on { print(line) }
            refreshRoute()
        } catch {
            let ns = error as NSError
            status = "Audio session failed: \(ns.domain) \(ns.code)"
            log.error("session NG \(ns.domain, privacy: .public) \(ns.code)")
            return
        }

        let sr = session.sampleRate > 0 ? session.sampleRate : 48000
        // リンクは 48kHz 固定（LocalLink.h、EffeTuneDriver.m の kSampleRate）。
        // setPreferredSampleRate は要求でしかなく、.mixWithOthers なので
        // 先に鳴らしているアプリがハードウェアのレートを握っていれば通らない。
        // 通らないまま進むと 48kHz のフレームを別のレートで出すことになり、
        // 音程と速さがずれて、受信の輪も溜まるか枯れるかする。
        // 止めると打つ手が無くなるので鳴らすが、黙って進めない
        // （status と log と Settings の Device に出る）。
        let rateOK = abs(sr - 48000) < 1
        if !rateOK {
            log.notice("device rate \(sr) != 48000, link is fixed at 48k")
        }
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
            //    撮影のときはリンクの代わりに作り物を流す。シミュレータには
            //    拡張が無く、そのままだと止まった画面しか撮れないため。
            if let mock = state.mock {
                mock.fill(state.interleaved, frames: n)
            } else {
                _ = ETLinkReceiver.shared.readInterleaved(state.interleaved, frames: UInt32(n))
            }

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
            //
            //    **鎖の差し替えは休んでいても通す。**
            //    configure を呼ぶのは ETPipeline_Process の中だけで、その Process は
            //    下の `if awake` の内側にある。無音で PowerGate が休むと Process ごと
            //    飛ぶので、**無音の間に足したエフェクトが永久に反映されない。**
            //    足しても効かない／リセットしてもメーターが動かない、の本体がこれ。
            //    反映は処理と別の仕事なので、ゲートの外で呼ぶ。
            //    溜まっていなければ atomic を 1 回読むだけで戻る。
            ETPipeline_ApplyPending()

            if awake, let main = ETPipeline_MainBus() {
                if f > 1, let rs = state.resampler {
                    ETResampler_Up(rs, p, main, UInt32(n))
                    state.pipeStatus = ETPipeline_Process(2, UInt32(n * f), state.elapsed)
                    ETResampler_Down(rs, main, p, UInt32(n))
                } else {
                    main.update(from: p, count: n * 2)
                    state.pipeStatus = ETPipeline_Process(2, UInt32(n), state.elapsed)
                    p.update(from: main, count: n * 2)
                }
                // ETPipeline_Process が返すのは et_status で、ET_OK は 0（ETPipeline.h）。
                // これを件数として読むと「効いている数」が成功時にちょうど 0 になる。
                // 通ったノード数は ETPipeline_ActiveNodes()。atomic の読みだけなので
                // 音のスレッドから呼んでよい。
                state.applied = state.pipeStatus == 0 ? ETPipeline_ActiveNodes() : 0
            } else {
                state.pipeStatus = 0
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
        interrupted = false
        sampleRate = sr
        processingRate = sr * Double(factor)
        resamplerLatency = Int(ETResampler_LatencySamples(state.resampler))
        status = rateOK ? "Running"
                        : String(format: "Running at %.0f Hz, input is 48000 Hz", sr)
        refreshRoute()
        updateNowPlaying()
        log.notice("start sr=\(sr) x\(factor) route=\(self.route, privacy: .public)")
    }

    func stop(keepListening: Bool = false) {
        escape.reset()
        reportedGaveUp = false
        node.map { engine.detach($0) }
        node = nil
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
        if !keepListening { ETLinkReceiver.shared.stop() }
        EffeTuneDSP.shared.reset()
        render = nil
        level = 0
        // start() は毎回ここを通るので、同じ値を書かない（publish が増えるだけ）。
        if running { running = false }
        if status != "Stopped" { status = "Stopped" }
        NowPlaying.stop()
        // 覚えている値も捨てる。捨てないと stop→start で同じ組になったとき
        // updateNowPlaying() が「変わっていない」と見て、いま外したばかりの
        // ロック画面の割り当てを付け直さない（設定変更やレート組み直しで毎回起きる）。
        lastNowPlaying = (false, false, -1)
    }

    /// 描画用の値だけを速く取る。図が滑らかに動くのはこちらの速さで決まる。
    /// DSP は 30Hz で吐いているので、それに合わせる。
    /// 重い問い合わせ（ルートやセッション）はここでやらない。
    ///
    /// ここから @Published を書かないこと。30Hz の publish は観測している側の
    /// body を 33ms ごとに作り直し、開いた Menu が提示を終えられなくなる。
    /// 図は Telemetry を直接読んでいるので、ここは poll だけでよい。
    func pollTelemetry() {
        Telemetry.shared.poll(engine: EffeTuneDSP.shared.engine)
    }

    /// 状態の見直し。重いものはこちら。
    ///
    /// 代入はすべて「変わったときだけ」。@Published は同じ値でも publish するので、
    /// 無条件に書くと 3.3Hz の再描画がそのまま出ていた。
    func tick() {
        ticks += 1
        followPeer()
        if ticks % 20 == 0 {
            // configure の結果（LastStatus）と process の戻り値（proc）は別物。
            // applied が 0 のとき、どちらで止まっているかをここで分ける。
            // rsp は routeSharingPolicy の生値。**こちらは Default(0) しか設定していない。**
            // 1 (LongFormAudio) になっていたら、MediaExperience の
            // _CMSUtility_UpdateRoutingContextForSession が now playing 能力を見て
            // SystemMusic コンテキストへ移し、setByClient:0 で書き換えたということ。
            // SystemMusic は non-groupable な経路が選ばれると SystemAudio へ追従するので、
            // どちらに居ても仮想デバイスを指す。ループバックに入る条件の判別に使う。
            let session = AVAudioSession.sharedInstance()
            let ports = session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: "+")
            let line = "tick out=\(route) rsp=\(session.routeSharingPolicy.rawValue) np=\(NowPlaying.mode.rawValue) ports=\(ports) ovr=\(overriding) applied=\(applied) active=\(ETPipeline_ActiveNodes()) chain=\(EffeTuneDSP.shared.chain.count) peer=\(hasPeer) recv=\(received) load=\(load) cfgStatus=\(ETPipeline_LastStatus()) proc=\(render?.pipeStatus ?? 0)"
            log.notice("\(line, privacy: .public)")
            // **無線だとログが取れない。**
            // log stream --device はこの Xcode で無くなり、devicectl にも
            // ログの口が無い。USB を挿さないと idevicesyslog が使えず、
            // ルートの取り回しを測れなかった。標準出力へ出しておけば
            // devicectl device process launch --console で無線でも読める。
            if ETConsoleLog.on { print(line) }
        }

        refreshRoute()

        // level は publish しないので、そのまま書いてよい。
        level = render?.meter ?? 0

        let nowApplied = Int(render?.applied ?? 0)
        if applied != nowApplied { applied = nowApplied }

        // 負荷は平滑化された実数で毎回わずかに動く。0.1% まで丸めて、
        // 落ち着いているときは publish が止まるようにする（表示は整数 %）。
        let nowLoad = ((render?.load ?? 0) * 1000).rounded() / 1000
        if load != nowLoad { load = nowLoad }

        let nowLatency = Int(ETPipeline_Latency())
        if pipelineLatency != nowLatency { pipelineLatency = nowLatency }

        let nowResting = render?.resting ?? false
        if resting != nowResting { resting = nowResting }

        updateNowPlaying()

        let nowListening = ETLinkReceiver.shared.listening
        if listening != nowListening { listening = nowListening }

        // 撮影のときは繋がっている扱いにする。そうしないと
        // 「No audio yet」の帯が出たままで、鳴っている画面が撮れない。
        let nowPeer = ETLinkReceiver.shared.hasPeer || ETMockSource.enabled
        if hasPeer != nowPeer {
            // **繋ぎ目そのものを撃つ。**
            // tick は 20 ブロックに 1 回（約 6 秒）なので、1.5 秒しか続かない
            // 接続はまるごと飛ぶ。2026-09-16 の 1 往復では tick が一度も
            // peer=true を捉えず、recv の増分（73728 と 72704 フレーム
            // ＝ 1.536 秒と 1.515 秒）だけが 2 回の接続の痕跡だった。
            // 立ち上がりと立ち下がりを時刻つきで出せば、窓の長さが直に読める。
            let up = ProcessInfo.processInfo.systemUptime
            let line = String(format: "peer %@ t=%.3f recv=%llu",
                              nowPeer ? "up" : "down", up,
                              ETLinkReceiver.shared.receivedFrames)
            log.notice("\(line, privacy: .public)")
            if ETConsoleLog.on { print(line) }
            hasPeer = nowPeer
        }

        let nowReceived = ETLinkReceiver.shared.receivedFrames
        if received != nowReceived { received = nowReceived }

        let nowBuffered = ETLinkReceiver.shared.bufferedFrames
        if bufferedFrames != nowBuffered { bufferedFrames = nowBuffered }

        let session = AVAudioSession.sharedInstance()
        let nowBlock = Int((session.ioBufferDuration * session.sampleRate).rounded())
        if blockFrames != nowBlock { blockFrames = nowBlock }

        // イヤホンを挿すとハードウェアのレートごと変わる。組んだときのレートと
        // 食い違ったまま流すと出力の速さがずれるので、組み直す。
        // sampleRate は「いま組んであるレート」なので、ここでは書き換えない。
        //
        // 1 回の食い違いでは組み直さない。engine.start() のあとにレートが落ち着く
        // ことがあり、そこで即座に組み直すと stop→start を毎秒繰り返して音が切れ続ける。
        // 3 目盛り（約 0.9 秒）続いたものだけを本物として扱う。
        let built = render?.sampleRate
        if running, let built, session.sampleRate > 0,
           abs(session.sampleRate - built) >= 1 {
            rateMismatchTicks += 1
        } else {
            rateMismatchTicks = 0
        }
        if rateMismatchTicks >= 3,
           ProcessInfo.processInfo.systemUptime - lastStartAttempt >= 1 {
            rateMismatchTicks = 0
            log.notice("hardware rate \(session.sampleRate) != built \(built ?? 0), rebuilding")
            rebuild()
        }
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

    /// 自分の音が仮想デバイスへ戻らないようにする。
    ///
    /// MediaDevice で「EffeTune」を選ぶと、それは**システム全体の出力先**になる。
    /// このアプリも例外ではなく、何もしなければ出力先は EffeTune になる。
    /// 実機のログで確かめた: `start sr=48000 x2 route=EffeTune`。
    /// そうなると
    ///   出力 → ドライバ → TCP → 自分の入力 → 出力 …
    /// の環を float32 のまま回る。整数への丸めもクリップも起きないので、
    /// レベルだけが上がり続けてスピーカーには何も届かない。
    ///
    /// 普通のアプリに「自分だけの出力先」を選ぶ手段は無いが、
    /// overrideOutputAudioPort(.speaker) だけはこのセッションに限って効く。
    /// 他のアプリの出力先（EffeTune）は変えない。
    ///
    /// 代償として、イヤホンを繋いでいても本体のスピーカーから鳴る。
    /// 無音で暴走するよりはよいと判断している。
    /// 仮想デバイスを指していないときは何もしないので、
    /// イヤホンが選ばれている場合はそのまま鳴る。
    /// 引き剥がしの判断。**中身は ETRouteEscape が持つ。**
    /// AVAudioSession に触らない形にしてあるので、こちらの穴は
    /// Tests/Unit/RouteEscapeTests.swift が実機なしで見張る。
    private var escape = ETRouteEscape()

    /// 打ち止めをログに出したか。3.3Hz で同じ行を吐かないため。
    private var reportedGaveUp = false

    /// tick のログに出す用。
    private var overriding: Bool { escape.overriding }

    private func escapeVirtualDevice(_ session: AVAudioSession) {
        let outs = session.currentRoute.outputs
        let onVirtual = outs.contains {
            $0.portName.localizedCaseInsensitiveContains("EffeTune")
        }
        let onSpeaker = outs.contains { $0.portType == .builtInSpeaker }
        let now = ProcessInfo.processInfo.systemUptime

        switch escape.decide(onVirtual: onVirtual, onSpeaker: onSpeaker, now: now) {
        case .speaker:
            apply(.speaker, on: session, reason: "仮想デバイスを指している")
        case .clear:
            apply(.none, on: session, reason: "仮想デバイスを指していない")
            reportedGaveUp = false
        case nil:
            // **打ち止めに達したことを 1 度だけ残す。**
            // `gaveUp` は定義だけで誰からも読まれておらず、3 回外したあとは
            // 何の痕跡も残らないまま輪が回り続けていた。
            // ここで消音はしない（症状に蓋をするだけで、32bit float なので
            // 出るときは出る）。**引き剥がせなかったという事実だけを残す。**
            if onVirtual && escape.gaveUp && !reportedGaveUp {
                reportedGaveUp = true
                let line = "escape 打ち止め attempts=\(escape.attempts) route=\(outs.map(\.portName).joined(separator: ","))"
                log.notice("\(line, privacy: .public)")
                if ETConsoleLog.on { print(line) }
            }
        }
    }

    private func apply(_ port: AVAudioSession.PortOverride,
                       on session: AVAudioSession, reason: String) {
        do {
            try session.overrideOutputAudioPort(port)
            let line = "escape \(reason) -> \(port == .speaker ? "speaker" : "none") route=\(session.currentRoute.outputs.map(\.portName).joined(separator: ","))"
            log.notice("\(line, privacy: .public)")
            if ETConsoleLog.on { print(line) }
        } catch {
            let ns = error as NSError
            let line = "escape 失敗 \(reason) code=\(ns.code) \(ns.domain)"
            log.error("\(line, privacy: .public)")
            if ETConsoleLog.on { print(line) }
        }
    }

    /// 出力先の見直し。route / outputRoute / loopback は同じ 1 回の問い合わせから作る。
    ///
    /// 以前は start() の中で 1 回だけ outputRoute と loopback を組んでいて、
    /// routeChangeNotification も購読していなかった。
    /// そのため Settings の警告は起動直後にしか当たらず、走っている間に
    /// 出力先が EffeTune へ移っても（レベルが上がり続ける状態）気づけなかった。
    /// - Parameter reason: `AVAudioSessionRouteChangeReasonKey` の生値。
    ///   通知以外から呼ぶときは 99（＝通知ではない）。
    private func refreshRoute(reason: UInt = 99) {
        // 走っている途中で出力先が仮想デバイスへ移ることがある。
        // （他のアプリがルートピッカーで EffeTune を選んだときなど）
        // そのときも当て直す。
        let sess = AVAudioSession.sharedInstance()
        if running { escapeVirtualDevice(sess) }

        let outs = sess.currentRoute.outputs
        let names = outs.map(\.portName).joined(separator: ", ")

        let nowRoute = outs.isEmpty ? "no output" : names
        if route != nowRoute {
            // **経路が変わった瞬間を時刻つきで残す。**
            // tick（約 6 秒）では 1.5 秒で戻される往復が映らない。
            // reason は override(1) / categoryChange(3) / routeConfigurationChange(8)
            // などの生値。誰の都合で戻されたのかが、これで初めて区別できる。
            let up = ProcessInfo.processInfo.systemUptime
            let ports = outs.map(\.portType.rawValue).joined(separator: "+")
            let line = String(format: "route t=%.3f reason=%llu out=%@ ports=%@ rsp=%ld ovr=%@ recv=%llu",
                              up, UInt64(reason), nowRoute, ports,
                              Int(sess.routeSharingPolicy.rawValue),
                              overriding ? "true" : "false",
                              ETLinkReceiver.shared.receivedFrames)
            log.notice("\(line, privacy: .public)")
            if ETConsoleLog.on { print(line) }
            route = nowRoute
        }

        let nowOutput = names.isEmpty ? "—" : names
        if outputRoute != nowOutput { outputRoute = nowOutput }

        // 仮想デバイスを指していたら、自分の音が自分へ戻る。
        // 名前で見る。ドライバは kAudioDeviceTransportTypeRemoteStreaming で名乗るので
        // portType は .airPlay になるが、本物の AirPlay スピーカーも同じ型で出る。
        // 型だけで判ると、実際には鳴っている相手に「戻っている」と警告してしまう。
        // ドライバが出す名前は "EffeTune" 固定（EffeTuneDriver.m:407）。
        let nowLoopback = outs.contains {
            $0.portName.localizedCaseInsensitiveContains("EffeTune")
        }
        if loopback != nowLoopback { loopback = nowLoopback }

    }
}
