//  StatusReadingsTests.swift
//  Status 節とツールバーの帯の判断と数字（Views/StatusReadings.swift）。
//  **AudioIO も実機も要らない。**ETAudioSnapshot を手で埋めて渡す。
//
//  ここが在る理由は 2 つ。
//   - SettingsModel.swift は「警告の検査を書けるように条件を集めた」と言いながら、
//     全部が AudioIO と EffeTuneDSP を直接読んでいて、検査が 1 本も無かった
//   - 帯と Settings が別々に丸めていて、同じ瞬間に 1 ms / 1 % 違う数字を出していた。
//     testStripAndSettingsAgree がそれを直接突く
import XCTest

final class StatusReadingsTests: XCTestCase {

    /// 鳴っている最中の、ありふれた形。各テストはここから欄を 1 つずつ変える。
    private func playing() -> ETAudioSnapshot {
        var s = ETAudioSnapshot()
        s.status = "Running"
        s.hasPeer = true
        s.running = true
        s.route = "Speaker"
        s.outputRoute = "Speaker"
        s.load = 0.3
        s.blockFrames = 256
        s.linkTargetFrames = 1024
        return s
    }

    // MARK: - 状態の行

    /// 順は 失敗 → Interrupted → 繋がっていない → 休み/再生 → 起動中。
    /// **失敗を hasPeer より先に見る。**逆だと、ソケットが開けないときに
    /// 「コントロールセンターで選べ」という、選んでも直らない案内が出る。
    /// Interrupted も hasPeer より先（着信で落ちても TCP は生きていて peer は残る）。
    func testFailureBeatsInterruptedBeatsNoPeerBeatsIdle() {
        var s = ETAudioSnapshot()

        // ソケットが開けない。peer はもちろん無い。
        s.status = "Cannot open the listening socket"
        s.hasPeer = false
        XCTAssertEqual(ETRunState.current(s), .failed("Cannot open the listening socket"))

        // 走っていて peer も居ても、失敗の字が入っていれば失敗。
        s.status = "Audio engine failed: com.apple.coreaudio.avfaudio -10868"
        s.hasPeer = true
        s.running = true
        XCTAssertEqual(ETRunState.current(s), .failed(s.status))
        s.status = "Audio session failed: NSOSStatusErrorDomain 561017449"
        XCTAssertEqual(ETRunState.current(s), .failed(s.status))

        // 割り込みは peer の有無より先。
        s.status = "Interrupted"
        s.running = false
        s.hasPeer = false
        XCTAssertEqual(ETRunState.current(s), .interrupted)
        s.hasPeer = true
        XCTAssertEqual(ETRunState.current(s), .interrupted)

        // 失敗でも割り込みでもなく、peer が無い。
        s.status = "Stopped"
        s.hasPeer = false
        XCTAssertEqual(ETRunState.current(s), .waiting)
        // 走っていても peer が無ければ待ち。
        s.status = "Running"
        s.running = true
        s.resting = true
        XCTAssertEqual(ETRunState.current(s), .waiting)

        // peer が来た。休んでいれば idle、鳴っていれば playing。
        s.hasPeer = true
        XCTAssertEqual(ETRunState.current(s), .idle)
        s.resting = false
        s.route = "Speaker"
        XCTAssertEqual(ETRunState.current(s), .playing(output: "Speaker"))

        // レート不一致の字は失敗ではない（問題の行が受け持つ）。
        s.status = "Running at 16000 Hz"
        XCTAssertEqual(ETRunState.current(s), .playing(output: "Speaker"))

        // peer は居るが、まだ走っていない。
        s.status = "Stopped"
        s.running = false
        XCTAssertEqual(ETRunState.current(s), .starting)
    }

    func testFailureCarriesRawStatusAndRetry() {
        var s = ETAudioSnapshot()
        s.status = "Audio session failed: X 1"
        let state = ETRunState.current(s)
        XCTAssertEqual(state.mono, "Audio session failed: X 1")
        XCTAssertEqual(state.retryTitle, "Try again")
        XCTAssertEqual(state.tone, .warning)
        for other in [ETRunState.interrupted, .waiting, .idle, .playing(output: "A"), .starting] {
            XCTAssertNil(other.mono)
            XCTAssertNil(other.retryTitle)
        }
    }

    /// "—"（outputRoute がまだ無い）と "no output"（route が無い）は見出しに置かない。
    func testReadableRouteHidesDash() {
        for raw in ["—", "no output", "", "   ", " — \n"] {
            XCTAssertEqual(ETRunState.readableRoute(raw), "", "\(raw.debugDescription)")
            XCTAssertEqual(ETRunState.playing(output: raw).title, "Playing")
        }
        XCTAssertEqual(ETRunState.readableRoute("  AirPods Pro \n"), "AirPods Pro")
        XCTAssertEqual(ETRunState.playing(output: "AirPods Pro").title,
                       "Playing through AirPods Pro")
        // 名前の一部に含まれるだけなら落とさない。
        XCTAssertEqual(ETRunState.readableRoute("Speaker — USB"), "Speaker — USB")
    }

    /// **088e891 で戻した説明。**3cb7da7 で見出しだけにして、Status で何が起きているのか
    /// 読めなくなった。見出しだけに戻したらここが落ちる。
    func testStateDetailsRestored() {
        XCTAssertEqual(ETRunState.failed("x").detail,
                       "Close any other app that is holding the audio device, then try again.")
        XCTAssertEqual(ETRunState.interrupted.detail,
                       "A call or another app took the audio device. Play something again to restart.")
        // 07b4e89 のまま。「少し鳴らしてから選ぶ」は #1 で誤りだった。ConnectBanner と同じ字。
        XCTAssertEqual(ETRunState.waiting.detail,
                       "Pick EffectDeck as the output in Control Center.")
        XCTAssertEqual(ETRunState.idle.detail,
                       "The input has been silent, so the effects are paused. They start again "
                     + "the moment sound returns.")
        XCTAssertEqual(ETRunState.playing(output: "Speaker").detail,
                       "Audio is arriving and the effects are running.")
        XCTAssertEqual(ETRunState.starting.detail, "Waiting for the audio device.")
        XCTAssertFalse(ETRunState.waiting.detail!.contains("play something first"))
    }

    func testStateTitlesAndTones() {
        XCTAssertEqual(ETRunState.failed("x").title, "Audio could not start")
        XCTAssertEqual(ETRunState.interrupted.title, "Audio was interrupted")
        XCTAssertEqual(ETRunState.waiting.title, "Waiting for audio")
        // 帯の "idle" と同じ語。
        XCTAssertEqual(ETRunState.idle.title, "Idle")
        XCTAssertEqual(ETRunState.starting.title, "Starting")
        XCTAssertEqual(ETRunState.interrupted.tone, .warning)
        XCTAssertEqual(ETRunState.playing(output: "").tone, .active)
        for s in [ETRunState.waiting, .idle, .starting] { XCTAssertEqual(s.tone, .normal) }
    }

    // MARK: - 負荷

    /// "0%" を出すと、余裕があるのか止まっているのか区別できない。
    func testLoadNilWhenRestingOrStopped() {
        var s = playing()
        XCTAssertNotNil(ETLoadReading(s))

        s.running = false
        XCTAssertNil(ETLoadReading(s), "止まっている")
        s = playing()
        s.resting = true
        XCTAssertNil(ETLoadReading(s), "休んでいる")
        s = playing()
        s.blockFrames = 0
        XCTAssertNil(ETLoadReading(s), "ブロックの長さがまだ無い")
        s = playing()
        s.sampleRate = 0
        XCTAssertNil(ETLoadReading(s), "レートが 0")

        // 帯は休んでいる間 "idle" で、色を付けない。
        s = playing()
        s.resting = true
        s.load = 0.9
        let strip = ETStripReading(s)
        XCTAssertEqual(strip.loadText, "idle")
        XCTAssertNil(strip.loadLevel)
        XCTAssertEqual(strip.loadVoice, "CPU idle, running at 48 kHz")
    }

    /// 閾値は上流の data-level と同じ 75 と 100
    /// （js/ui-manager.js の updatePipelineCpuUsage、e200e515 で 426–428 行）。
    func testLoadThresholds() {
        let table: [(Double, ETLoadReading.Level, Int)] = [
            (0, .normal, 0),
            (0.7499, .normal, 75),   // 字は 75 でも、色は閾値の手前
            // ちょうど .5 は上へ（2 進で割り切れる値）。偶数への丸めなら 12 と 62。
            (0.125, .normal, 13),
            (0.625, .normal, 63),
            (0.75, .high, 75),
            (0.999, .high, 100),
            (1.0, .over, 100),
            (1.5, .over, 150),
            (-0.2, .normal, 0),      // 負は 0
            (.nan, .normal, 0),
        ]
        var s = playing()
        for (load, level, percent) in table {
            s.load = load
            let r = ETLoadReading(s)!
            XCTAssertEqual(r.level, level, "load \(load)")
            XCTAssertEqual(r.percent, percent, "load \(load)")
            XCTAssertEqual(r.value, "\(percent)%")
            XCTAssertEqual(ETLoadReading.level(load), level)
        }
        // inf で落ちない。
        s.load = .infinity
        XCTAssertEqual(ETLoadReading(s)?.level, .over)

        // ms 2 つの文。256 / 48000 = 5.3 ms、その 50%。
        s.load = 0.5
        let r = ETLoadReading(s)!
        XCTAssertEqual(r.note, "The effects use 2.7 ms of the 5.3 ms each block of audio is given. "
                             + "Over 100% the sound breaks up.")
        XCTAssertEqual(r.accessibility, "CPU, 50 percent of each block")
    }

    // MARK: - 遅れ

    /// **合計は足してから 1 回だけ丸める。**帯の 2 つは足すとその合計になり、
    /// I/O はそれだけで丸め、Fx が残りを持つ。
    func testDelayRoundedOnceAfterSum() {
        let table: [(io: Double, fx: Double, ioMs: Int, fxMs: Int, total: Int)] = [
            (10.5, 0.5, 11, 0, 11),    // 別々なら 11＋1＝12
            (10.4, 0.4, 10, 1, 11),    // 別々なら 10＋0＝10
            (21.3, 0, 21, 0, 21),
            (20.2, 10, 20, 10, 30),    // Fx が整数なら Fx はそのまま
            (0.49, 0.49, 0, 1, 1),
            (48.5, 0.5, 49, 0, 49),
            (25, 0.5, 25, 1, 26),
            // I/O を動かさず足すと合計になる代金。Fx の字は上にも下にも 1 ms 近くずれる。
            (10.4, 0.2, 10, 1, 11),     // 0.2 が 1
            (10.5, 20.998, 11, 20, 31), // 20.998 が 20
        ]
        for row in table {
            let d = ETDelaySplit(ioMs: row.io, fxMs: row.fx)
            XCTAssertEqual(d.ioMs, row.ioMs, "\(row)")
            XCTAssertEqual(d.fxMs, row.fxMs, "\(row)")
            XCTAssertEqual(d.totalMs, row.total, "\(row)")
            XCTAssertEqual(d.totalMs, Int((row.io + row.fx).rounded()))
            XCTAssertGreaterThanOrEqual(d.fxMs, 0)
        }

        // 標本から。link 2048 + block 256 + filter 24 = 2328 = 48.5 ms、Fx 24 = 0.5 ms。
        var s = playing()
        s.linkTargetFrames = 2048
        s.blockFrames = 256
        s.resamplerLatency = 24
        s.pipelineLatency = 24
        let r = ETDelayReading(s)!
        XCTAssertEqual(r.totalMs, 49)
        XCTAssertEqual(r.value, "49 ms")
        XCTAssertEqual(r.split, ETDelaySplit(ioMs: 48.5, fxMs: 0.5))
        XCTAssertEqual(r.summary, "Total delay 49 ms · input 42.7 · buffer 5.3 · filter 0.5 · Fx 0.5")
    }

    /// Fx は**処理レートの標本**で数える。96 kHz で 96 標本 = 1 ms。
    func testFxCountedAtProcessingRate() {
        var s = playing()
        s.processingRate = 96000
        s.pipelineLatency = 96
        XCTAssertEqual(ETDelayReading(s)!.fxMs, 1, accuracy: 1e-12)
        // 処理レートが無ければデバイスのレート。
        s.processingRate = 0
        XCTAssertEqual(ETDelayReading(s)!.fxMs, 2, accuracy: 1e-12)
    }

    /// 0 のもの（filter・Fx）は足し算に出さない。blockFrames が無ければ作らない。
    func testDelaySummaryHidesZeroParts() {
        var s = playing()
        XCTAssertEqual(ETDelayReading(s)!.summary, "Total delay 27 ms · input 21.3 · buffer 5.3")
        XCTAssertEqual(ETDelayReading(s)!.note,
                       "21.3 ms between the extension and this app, 5.3 ms in the block iOS gave "
                     + "(256 samples), 0.0 ms in the oversampling filter, 0.0 ms in the effects themselves.")
        s.resamplerLatency = 2   // 0.04 ms は 0.05 以下なので出さない
        XCTAssertFalse(ETDelayReading(s)!.summary.contains("filter"))
        s.blockFrames = 0
        XCTAssertNil(ETDelayReading(s))
        // 帯は走り始めの一瞬（ブロックの長さがまだ無い）でも数字を出す。
        XCTAssertEqual(ETStripReading(s).ioMs, 21)
    }

    /// 帯の I/O は設定で決まり、鎖では動かない。エフェクトを足しても動かないこと。
    func testStripIODoesNotMoveWithChain() {
        var s = playing()
        let before = ETStripReading(s)
        for latency in [1, 7, 24, 25, 47, 48, 480, 4801] {
            s.pipelineLatency = latency
            let after = ETStripReading(s)
            XCTAssertEqual(after.ioMs, before.ioMs, "Fx \(latency) 標本で I/O が動いた")
            XCTAssertEqual(after.ioMs + after.fxMs, ETDelayReading(s)!.totalMs)
        }
    }

    // MARK: - 帯と Settings

    /// **帯と Settings は同じ瞬間に同じ数字を出す。**以前の帯は I/O と Fx を
    /// 別々に丸め、CPU を %.0f（.5 は偶数へ）で出していて、Settings の
    /// Total delay と CPU から 1 ms / 1 % ずれることがあった（.5 の行）。
    func testStripAndSettingsAgree() {
        // link, block, filter, Fx（処理レートの標本）, デバイスのレート, 処理レート, load
        let table: [(UInt32, Int, Int, Int, Double, Double, Double)] = [
            (1024, 256, 0, 0, 48000, 48000, 0.30),
            (2048, 256, 24, 24, 48000, 48000, 0.125),   // I/O 48.5 + Fx 0.5、CPU 12.5%
            (1024, 512, 31, 48, 48000, 96000, 0.625),   // Fx 0.5 ms（96 kHz）、CPU 62.5%
            (1024, 1024, 0, 72, 48000, 48000, 0.745),   // Fx 1.5 ms
            (1024, 256, 40, 0, 48000, 48000, 0.875),    // I/O 27.5 だけ
            (1008, 192, 0, 24, 48000, 48000, 0.5),      // I/O 25.0 + Fx 0.5
            (2048, 128, 0, 0, 16000, 16000, 0.99),      // 16 kHz に落ちた
            (1024, 256, 32, 12, 44100, 88200, 1.5),     // 44.1 kHz、割れている
        ]
        for (link, block, filter, fx, rate, proc, load) in table {
            var s = playing()
            s.linkTargetFrames = link
            s.blockFrames = block
            s.resamplerLatency = filter
            s.pipelineLatency = fx
            s.sampleRate = rate
            s.processingRate = proc
            s.load = load
            let label = "link \(link) block \(block) filter \(filter) Fx \(fx) @\(rate)/\(proc) load \(load)"

            let strip = ETStripReading(s)
            let delay = ETDelayReading(s)!
            let cpu = ETLoadReading(s)!
            let issues = ETIssue.current(s).map(\.id)
            let details = ETDiagnostics.make(s, version: "v", abi: "0", device: "d", settings: [])

            XCTAssertEqual(strip.ioMs + strip.fxMs, delay.totalMs, "遅れ: " + label)
            XCTAssertTrue(delay.summary.hasPrefix("Total delay \(strip.ioMs + strip.fxMs) ms"), label)
            XCTAssertEqual(strip.loadText, cpu.value, "CPU: " + label)
            XCTAssertEqual(strip.loadLevel, cpu.level, "CPU の色: " + label)
            XCTAssertEqual(strip.rateIsOff, issues.contains("rate"), "レートの色: " + label)
            XCTAssertEqual(strip.rate,
                           details.lines.first { $0.label == "Processing rate" }?.value, label)
            XCTAssertEqual(strip.delayVoice,
                           "Effects add \(strip.fxMs) milliseconds, audio path adds \(strip.ioMs) milliseconds")
            XCTAssertEqual(strip.loadVoice, "CPU \(cpu.percent) percent, running at \(strip.rate)")
        }
    }

    /// 処理レートが有限でなければ "— kHz"。Int(nan) / Int(inf) で落とさない。
    /// 帯の Rate と Details の Processing rate の両方がここを通る。
    func testRateTextNonFinite() {
        for hz in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(ETRateText.kHz(hz), "— kHz", "\(hz)")
            var s = playing()
            s.processingRate = hz
            let details = ETDiagnostics.make(s, version: "v", abi: "0", device: "d", settings: [])
            XCTAssertEqual(ETStripReading(s).rate, "— kHz", "\(hz)")
            XCTAssertEqual(details.lines.first { $0.label == "Processing rate" }?.value, "— kHz", "\(hz)")
        }
        XCTAssertEqual(ETRateText.kHz(47_500), "48 kHz")
        XCTAssertEqual(ETRateText.kHz(0), "0 kHz")
    }

    /// 端末のレートが有限でないときは 0 と同じ「分からない」に読む。
    /// inf は 0 より大きく 48000 から離れているので、以前は問題の行と Device rate で
    /// Int(inf) に落ちていた。
    func testDeviceRateNonFinite() {
        var unknown = playing()
        unknown.sampleRate = 0
        let fallback = ETDelayReading(unknown)!
        for hz in [Double.nan, .infinity, -.infinity] {
            var s = playing()
            s.sampleRate = hz
            XCTAssertFalse(s.rateIsOff, "\(hz)")
            XCTAssertEqual(s.deviceRate, 48000, "\(hz)")
            XCTAssertNil(ETIssue.current(s).first { $0.id == "rate" }, "\(hz)")
            XCTAssertFalse(ETStripReading(s).rateIsOff, "\(hz)")
            let details = ETDiagnostics.make(s, version: "v", abi: "0", device: "d", settings: [])
            XCTAssertEqual(details.lines.first { $0.label == "Device rate" }?.value, "—", "\(hz)")
            XCTAssertEqual(ETDelayReading(s)?.totalMs, fallback.totalMs, "\(hz)")
        }
    }

    // MARK: - 問題の行

    /// 深刻さの順。音が出ない → 音程がずれる → 途切れる → 効いていない。
    func testIssueOrder() {
        var s = playing()
        XCTAssertEqual(ETIssue.current(s).map(\.id), [])

        s.loopback = true
        s.sampleRate = 44100
        s.load = 1.2
        s.bypass = true
        let all = ETIssue.current(s)
        XCTAssertEqual(all.map(\.id), ["loopback", "rate", "load", "bypass"])
        XCTAssertEqual(all.map(\.tone), [.warning, .warning, .warning, .normal])
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "id は ForEach の鍵")

        // 1 つずつ外しても、残りの順は変わらない。
        s.sampleRate = 48000
        XCTAssertEqual(ETIssue.current(s).map(\.id), ["loopback", "load", "bypass"])
        s.loopback = false
        XCTAssertEqual(ETIssue.current(s).map(\.id), ["load", "bypass"])

        // 割れているときだけ。近いだけ（high）では行を生やさない。
        s.load = 0.99
        XCTAssertEqual(ETIssue.current(s).map(\.id), ["bypass"])
        // 休んでいる間の古い load では出さない。
        s.load = 1.3
        s.resting = true
        XCTAssertEqual(ETIssue.current(s).map(\.id), ["bypass"])
    }

    /// 16 k / 32 k は Bluetooth のハンズフリー。マイクを掴むアプリを名指しする。
    func testRateMessageAt32kAndBelow() {
        var s = playing()
        func rate(_ hz: Double) -> ETIssue? {
            s.sampleRate = hz
            return ETIssue.current(s).first { $0.id == "rate" }
        }
        for hz in [8000.0, 16000, 24000, 32000] {
            let issue = rate(hz)
            XCTAssertNotNil(issue, "\(hz)")
            XCTAssertEqual(issue?.detail,
                           "Audio arrives at 48 kHz, so pitch and speed are off. Bluetooth "
                         + "headphones drop to this rate when an app takes their microphone "
                         + "— a call, voice input or a recorder. Quit it, then play again.")
        }
        for hz in [32001.0, 44100, 96000] {
            XCTAssertEqual(rate(hz)?.detail,
                           "Audio arrives at 48 kHz, so pitch and speed are off. Another app is "
                         + "holding the hardware at that rate. Stop it, then play again.", "\(hz)")
        }
        XCTAssertEqual(rate(44100)?.title, "The device is running at \(44100.formatted()) Hz")
        XCTAssertEqual(rate(16000)?.title, "The device is running at \(16000.formatted()) Hz")

        // 48 kHz から 1 Hz 未満のずれは数えない。
        XCTAssertNil(rate(48000))
        XCTAssertNil(rate(48000.5))
        XCTAssertNil(rate(47999.2))
        XCTAssertNotNil(rate(47999))
        // 走っていなければ出さない。レート 0 も出さない。
        XCTAssertNil(rate(0))
        s.running = false
        XCTAssertNil(rate(16000))
    }

    /// 鎖が切ってあるのは、音が来ているときだけ言う。
    func testBypassOnlyWhenConnected() {
        var s = ETAudioSnapshot()
        s.bypass = true
        s.hasPeer = false
        XCTAssertEqual(ETIssue.current(s).map(\.id), [])
        s.hasPeer = true
        XCTAssertEqual(ETIssue.current(s).map(\.id), ["bypass"])
        // 走っていなくても、peer が居れば言う（切ってあるのは事実）。
        XCTAssertFalse(s.running)
        s.bypass = false
        XCTAssertEqual(ETIssue.current(s).map(\.id), [])
    }

    /// **088e891 で戻した問題の説明。**見出しだけに戻したらここが落ちる。
    func testIssueDetailsRestored() {
        var s = playing()
        s.loopback = true
        s.sampleRate = 44100
        s.load = 1.234
        s.bypass = true
        let byId = Dictionary(uniqueKeysWithValues: ETIssue.current(s).map { ($0.id, $0) })

        XCTAssertEqual(byId["loopback"]?.title, "Output is set to EffectDeck")
        XCTAssertEqual(byId["loopback"]?.detail,
                       "The processed sound is going back into this app instead of to a "
                     + "speaker, so you hear nothing and the level keeps rising. Pick a real "
                     + "output for this device in Control Center.")
        // 長押しの手順は実機で確かめていないので書かない。
        XCTAssertFalse(byId["loopback"]!.detail!.lowercased().contains("press"))

        XCTAssertEqual(byId["load"]?.title, "The sound is breaking up")
        XCTAssertEqual(byId["load"]?.detail,
                       "The effects need more time than each buffer has (123% of it). "
                     + "Lower the processing rate, raise the latency, or remove an effect.")

        XCTAssertEqual(byId["bypass"]?.title, "Effects are switched off")
        XCTAssertEqual(byId["bypass"]?.detail,
                       "The sound is passing through untouched. The power button at the top "
                     + "left of the main screen turns them back on.")

        for issue in byId.values {
            XCTAssertFalse(issue.detail?.isEmpty ?? true, "\(issue.id) の説明が無い")
        }
    }

    // MARK: - 報告用の文

    /// 貼り付け用の文の形。報告を受け取る側がこの形で読む。
    func testDiagnosticsLayout() {
        var s = playing()
        s.bufferedFrames = 512
        s.starveCount = 3
        s.starveFrames = 96
        s.processingRate = 96000
        s.resamplerLatency = 31
        s.received = 999
        s.applied = 2
        s.effectCount = 3
        s.telemetryDropped = 4
        let settings = [ETDiagnosticLine(label: "Latency", value: "Low"),
                        ETDiagnosticLine(label: "Effect pipeline", value: "On")]
        let d = ETDiagnostics.make(s, version: "2.9.0 (5)", abi: "7",
                                   device: "iPhone17,2 · iOS 27.0", settings: settings)

        let expected = """
            EffectDeck 2.9.0 (5) diagnostics
            iPhone17,2 · iOS 27.0

            Settings
              Latency: Low
              Effect pipeline: On

            Details
              Version: 2.9.0 (5)
              Incoming: 48 kHz · 32-bit float · 2 ch
              Extension link: 1024 samples (21.3 ms)
              Queued from the extension: 512 samples (11 ms)
              Ran dry: 3× · 96 samples (2 ms)
              Trimmed: never
              DSP buffer: 256 samples (5.3 ms)
              Processing rate: 96 kHz
              Device rate: \(48000.formatted()) Hz
              Oversampling filter: 31 samples (0.65 ms)
              Frames received: 999
              Effects running: 2 of 3
              Output: Speaker
              Engine state: Running
              DSP ABI: 7
              Telemetry dropped: 4
            """
        XCTAssertEqual(d.text, expected)
        // 画面の行と貼る文は同じ配列。
        XCTAssertEqual(d.lines.map(\.label).first, "Version")
        XCTAssertEqual(Set(d.lines.map(\.id)).count, d.lines.count, "id は ForEach の鍵")
    }

    /// 無いものは "—" / "none" / "never"。取りこぼしが 0 なら行ごと出さない。
    func testDiagnosticsQuietWhenNothingHappened() {
        var s = ETAudioSnapshot()
        s.sampleRate = 0
        s.trimCount = 2
        s.trimFrames = 64
        let d = ETDiagnostics.make(s, version: "v", abi: "a", device: "d", settings: [])
        let value = Dictionary(uniqueKeysWithValues: d.lines.map { ($0.label, $0.value) })
        XCTAssertEqual(value["DSP buffer"], "—")
        XCTAssertEqual(value["Device rate"], "—")
        XCTAssertEqual(value["Oversampling filter"], "none")
        XCTAssertEqual(value["Ran dry"], "never")
        // レートが 0 なら 48 kHz で ms にする。
        XCTAssertEqual(value["Trimmed"], "2× · 64 samples (1 ms)")
        XCTAssertEqual(value["Output"], "—")
        XCTAssertEqual(value["Engine state"], "Stopped")
        XCTAssertNil(value["Telemetry dropped"])
        XCTAssertEqual(d.lines.last?.label, "DSP ABI")
    }
}
