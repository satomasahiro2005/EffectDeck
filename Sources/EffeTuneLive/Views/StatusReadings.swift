//  StatusReadings.swift
//  Status 節とツールバーの帯が出す数字と言い回し。**Foundation だけで書く。**
//
//  ここは AudioIO・EffeTuneDSP・ETLinkReceiver を直接読まない。読むのは
//  ETAudioSnapshot 1 つだけで、それを埋めるのは SettingsModel.swift の 1 か所。
//  だから Logic のテスト（Linux の swift test でも）からそのまま呼べる。
//
//  **帯（LiveStatusStrip）と Settings は同じ関数で丸める。**
//  以前は帯が I/O と Fx を別々に丸め、CPU を %.0f（ちょうど .5 は偶数へ）で
//  出していた。Settings は合計を 1 回だけ丸め、% は .rounded()（.5 は上へ）。
//  それで帯の I/O＋Fx と Settings の Total delay、帯と Settings の CPU が
//  1 ms / 1 % 食い違うことがあった。丸めは ETDelaySplit と ETLoadReading.percent の
//  2 つだけにして、両方の画面がそれを通る。

import Foundation

// MARK: - 読む値

/// 状態の行・問題の行・遅れ・負荷・Details・帯が読む値。
///
/// **埋めるのは SettingsModel.swift の `init(io:dsp:)` だけ。**ここで各所が
/// AudioIO を直接読んでいたので、同じ量の読み方が画面ごとに少しずつ違っていた。
/// 既定値は AudioIO と ETLinkReceiver の初期値に合わせてある（テストで欄を
/// 1 つずつ書き換えて使う）。
struct ETAudioSnapshot: Equatable {
    // AudioIO
    var status: String = "Stopped"
    var hasPeer = false
    var running = false
    var resting = false
    /// 出力ポート名の連結。無いときは "no output"、まだ読んでいなければ "—"。
    var route: String = "—"
    var outputRoute: String = "—"
    var loopback = false
    /// 締切に対して使った割合（1.0 で締切ちょうど）。端末の CPU 使用率ではない。
    var load: Double = 0
    var blockFrames: Int = 0
    var sampleRate: Double = 48000
    var processingRate: Double = 48000
    var resamplerLatency: Int = 0
    /// 鎖が足す遅れ。**処理レートの標本で数える。**
    var pipelineLatency: Int = 0
    var bufferedFrames: UInt32 = 0
    var received: UInt64 = 0
    var applied: Int = 0

    // ETLinkReceiver（拡張と本体のあいだ）
    /// 再同期で置き直す狙いの値（設定の Extension link）。その瞬間の溜まりではない。
    var linkTargetFrames: UInt32 = 0
    var starveCount: UInt32 = 0
    var starveFrames: UInt64 = 0
    var trimCount: UInt32 = 0
    var trimFrames: UInt64 = 0

    // EffeTuneDSP
    var bypass = false
    /// Section を除いた段の数。Section は descriptor に入らないので分母から外す。
    var effectCount = 0

    // Telemetry
    var telemetryDropped: UInt32 = 0
}

extension ETAudioSnapshot {
    /// sampleRate は start() で `session.sampleRate > 0 ? ... : 48000` としか
    /// 書かれないので 0 にも nan にもならないが、ここでも 0 と nan と inf を避けておく。
    /// **有限でない値は 0 と同じ「分からない」に読む。**inf を Int にすると落ちる。
    var hasDeviceRate: Bool { sampleRate.isFinite && sampleRate > 0 }
    var deviceRate: Double { hasDeviceRate ? sampleRate : 48000 }

    /// 効果を回しているレート。pipelineLatency はこちらで割る（sampleRate ではない）。
    var effectRate: Double { processingRate > 0 ? processingRate : deviceRate }

    /// 端末が 48 kHz を握れていない。速さと音程がずれている。
    /// 帯の Rate の色と、問題の行の "rate" が同じ条件を使う。
    var rateIsOff: Bool { hasDeviceRate && abs(sampleRate - 48000) >= 1 }
}

// MARK: - 行の見た目の区別

/// 状態の行と問題の行が使う色の区別。**新しい色は定義しない。**
enum ETNoticeTone {
    /// 読むだけ。secondary。
    case normal
    /// 鳴っている。tint。
    case active
    /// 直す手がある。orange。
    case warning
}

// MARK: - いま何が起きているか

/// Status 節の 1 行目。6 つのうちどれか 1 つだけが出る。
///
/// **失敗を hasPeer より先に見る。** 逆にすると、ソケットが開けないときに
/// 「コントロールセンターで EffeTune を選べ」という、選んでも直らない案内が出る。
/// その次が Interrupted で、hasPeer より先。着信で落ちても TCP は生きているので
/// peer は true のまま、落ちたときに peer が無くても「割り込まれた」を先に出す。
enum ETRunState: Equatable {
    case failed(String)
    case interrupted
    case waiting
    case idle
    case playing(output: String)
    case starting

    /// AudioIO.status に入る文字列は 7 種類。
    /// そのうち「人が何かすれば変わる失敗」はこの 3 つで、あとの
    /// "Stopped" / "Running" / "Running at … Hz" / "Interrupted" は失敗ではない。
    /// （"Running at … Hz" はレート不一致で、下の ETIssue が受け持つ）
    static let failurePrefixes = [
        "Cannot open the listening socket",
        "Audio session failed",
        "Audio engine failed",
    ]

    static func current(_ s: ETAudioSnapshot) -> ETRunState {
        if Self.failurePrefixes.contains(where: { s.status.hasPrefix($0) }) {
            return .failed(s.status)
        }
        if s.status == "Interrupted" { return .interrupted }
        if !s.hasPeer { return .waiting }
        if s.running { return s.resting ? .idle : .playing(output: s.route) }
        return .starting
    }

    var systemImage: String {
        switch self {
        case .failed, .interrupted: return "exclamationmark.triangle.fill"
        case .waiting, .starting:   return "circle.dotted"
        case .idle:                 return "pause.circle"
        case .playing:              return "waveform"
        }
    }

    var tone: ETNoticeTone {
        switch self {
        case .failed, .interrupted: return .warning
        case .playing:              return .active
        case .waiting, .idle, .starting: return .normal
        }
    }

    var title: String {
        switch self {
        case .failed:      return "Audio could not start"
        case .interrupted: return "Audio was interrupted"
        case .waiting:     return "Waiting for audio"
        // ツールバーの帯が同じ状態を "idle" と出していて、あちらは触れない。
        // 3 つ目の言い方を作らないよう、こちらも Idle に合わせる。
        case .idle:        return "Idle"
        case .starting:    return "Starting"
        case .playing(let output):
            let name = Self.readableRoute(output)
            return name.isEmpty ? "Playing" : "Playing through \(name)"
        }
    }

    /// 状態の説明。**削らない。**3cb7da7 で見出しだけにしたが、Status で
    /// 何が起きているのか読めなくなったので戻した（088e891、2026-09-27、オーナーの判断）。
    /// StatusReadingsTests.testStateDetailsRestored が字を押さえている。
    var detail: String? {
        switch self {
        case .failed:
            return "Close any other app that is holding the audio device, then try again."
        case .interrupted:
            return "A call or another app took the audio device. Play something again to restart."
        // **「少し鳴らしてから選ぶ」は書かない**（#1 の訂正）。
        // 何も鳴らしていない間や一時停止中に選んでも基本的に戻されない。
        // 一時停止が原因と確かめた失敗は無い（A-10 の非動画の切断 3 回も
        // `mediaIsPlaying=YES` だった）。続けて通らないのは MediaToolbox が
        // `isPlayingVideoOutput = YES` と分類した回（Canvas は #1 / #4、YouTube は #3）。
        // 外し方は ConnectionTipsView に置いて、ここは手順だけにする。
        //
        // **ConnectBanner と同じ字にする。**同じ「まだ音が来ていない」間に出る。
        case .waiting:
            return "Pick EffectDeck as the output in Control Center."
        case .idle:
            return "The input has been silent, so the effects are paused. They start again "
                 + "the moment sound returns."
        case .playing:
            return "Audio is arriving and the effects are running."
        case .starting:
            return "Waiting for the audio device."
        }
    }

    /// iOS が返した生の文字列。文章に混ぜず、下に 1 行で置く（報告に貼るため）。
    var mono: String? {
        if case .failed(let status) = self { return status }
        return nil
    }

    var retryTitle: String? {
        if case .failed = self { return "Try again" }
        return nil
    }

    /// AudioIO.route は出力ポート名の連結で、無いときは "no output"、
    /// outputRoute 側は "—"。どちらも見出しに置くと読めないので落とす。
    static func readableRoute(_ raw: String) -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "—" || name == "no output" { return "" }
        return name
    }
}

// MARK: - 締切に対する余裕

/// AudioIO.swift の load をそのまま出すための読み。
///
///   spent  = 1 ブロックを作るのにかかった実時間
///   budget = そのブロックぶんの再生時間（frames / sampleRate）
///   load  += (spent/budget - load) * 0.1
///
/// つまり**締切に対してどれだけ使ったか**で、端末の CPU 使用率ではない。
/// 名前を "DSP" としか書いていなかったので CPU と読まれた。
/// ここでしか名前と言い回しを持たないので、直すならこの 1 か所。
struct ETLoadReading {
    /// ここから色を変える。締切に届く前に気づける位置。
    /// 上流の data-level と同じ 75 と 100（js/ui-manager.js の updatePipelineCpuUsage、
    /// e200e515 で 426–428 行）。
    static let high = 0.75
    /// ここを超えると音が途切れる。
    static let over = 1.0

    enum Level { case normal, high, over }

    let fraction: Double
    let percent: Int
    let usedMs: Double
    let blockMs: Double

    /// **帯と Settings が同じ値を使う。**負は 0、nan は 0。
    /// 上を 1000（100000%）で止めるのは、inf を Int にして落ちないためだけ。
    static func fraction(_ load: Double) -> Double { min(max(0, load), 1000) }

    /// **% の丸めはここだけ。**.rounded() なので、ちょうど .5 は上へ。
    /// 帯は以前 %.0f で出していて、12.5% を帯は 12、Settings は 13 と出していた。
    static func percent(_ load: Double) -> Int { Int((fraction(load) * 100).rounded()) }

    static func level(_ load: Double) -> Level {
        let f = fraction(load)
        if f >= Self.over { return .over }
        if f >= Self.high { return .high }
        return .normal
    }

    /// 休んでいる間と鳴っていない間は作らない。
    /// "0%" を出すと、締切に余裕があるのか止まっているのか区別できない。
    init?(_ s: ETAudioSnapshot) {
        guard s.running, !s.resting, s.blockFrames > 0, s.sampleRate > 0 else { return nil }
        fraction = Self.fraction(s.load)
        percent = Self.percent(s.load)
        blockMs = Double(s.blockFrames) / s.sampleRate * 1000
        usedMs = blockMs * fraction
    }

    var level: Level { Self.level(fraction) }

    /// **"of each block" は中の言葉なので出さない。**
    /// 何の何 % かは Details の内訳（Buffer size）で引ける。
    var value: String { "\(percent)%" }

    /// **語は上流に合わせて "CPU"。** 上流の右下が "CPU: Avg {average}%"
    /// （js/locales/en.json5 の ui.pipelineCpuUsage、e200e515 で 74 行）。ツールバーの帯も同じ語を使っている。
    /// 1 つの量に 2 つの名前を付けないこと。
    /// 中身が端末の CPU 使用率ではないことは、ms 2 つの文で伝わる。
    /// 数字は Latency 設定で 5.0 / 10.0 / 23.0 と動くので、設定との因果も同時に伝わる。
    var note: String {
        String(format: "The effects use %.1f ms of the %.1f ms each block of audio is given. "
                     + "Over 100%% the sound breaks up.",
               usedMs, blockMs)
    }

    var accessibility: String { "CPU, \(percent) percent of each block" }
}

// MARK: - 出るまでの遅れ

/// 帯の 2 つ（I/O と Fx）と Settings の Total delay を、**1 回の丸めで**作る。
///
/// 合計は足してから 1 回だけ丸める（Settings の Total delay）。
/// 帯の 2 つは足すと必ずその合計になる:
///   - I/O はそれだけで丸める。設定で決まり、鎖では動かない数なので、
///     エフェクトを足しても動かないこと
///   - Fx は合計から I/O を引いた残り。丸めのずれはこちらが持つ。上にも下にも
///     1 ms 近くずれうる（I/O 10.4＋Fx 0.2 で Fx 1、I/O 10.5＋Fx 20.998 で Fx 20）。
///     別々に丸めれば 0.5 ms 以内だが、それでは足しても合計にならない
/// 以前は 2 つを別々に丸めていて、I/O 10.5 と Fx 0.5 を帯は 11＋1、
/// Settings は合計 11 と出していた。
struct ETDelaySplit: Equatable {
    let ioMs: Int
    let fxMs: Int
    var totalMs: Int { ioMs + fxMs }

    init(ioMs: Double, fxMs: Double) {
        let total = Int((ioMs + fxMs).rounded())
        let io = Int(ioMs.rounded())
        self.ioMs = io
        // 丸めは単調なので、fxMs ≥ 0 なら total ≥ io で、ここは負にならない。
        self.fxMs = total - io
    }
}

/// Latency を選んだ結果、実際に何 ms 遅れているか。
///
/// 「Low を選んだのに 48 ms なのはなぜか」に答えられる形にしてある。
/// 合計はツールバーの帯（LiveStatusStrip の I/O と Fx）と同じ 4 つの和で、
/// 丸めも同じく合計してから 1 回だけ（ETDelaySplit）。帯と食い違うと、
/// どちらも信用されなくなる。
struct ETDelayReading {
    let totalMs: Int
    let linkMs: Double
    let blockMs: Double
    let filterMs: Double
    /// 積んでいるエフェクトが足す遅れ。**処理レートで数える。**
    let fxMs: Double
    let blockFrames: Int
    /// 帯に出す 2 つ。足すと totalMs。
    let split: ETDelaySplit

    /// 鎖の外。リンク・iOS のブロック・オーバーサンプリングの変換。
    /// **標本を足してから ms にする。**ms を 3 つ足すと、ちょうど .5 の近くで
    /// 帯と丸めが割れることがある。
    static func ioMs(_ s: ETAudioSnapshot) -> Double {
        // 拡張と本体のあいだ。再同期でここへ置き直すので、その瞬間の
        // 溜まりではなく狙いの値（設定の Extension link）。
        let frames = Double(s.linkTargetFrames) + Double(s.blockFrames) + Double(s.resamplerLatency)
        return frames / s.deviceRate * 1000
    }

    /// **エフェクト自身の遅延。**足さないと I/O と同じ値になり、Fx のぶんだけ
    /// 実際より短く出る。pipelineLatency は処理レートのサンプル数なので、そちらで割る。
    static func fxMs(_ s: ETAudioSnapshot) -> Double {
        Double(s.pipelineLatency) / s.effectRate * 1000
    }

    /// 帯とこれが使う丸め。blockFrames が 0（走り始めの一瞬）でも作る。
    static func split(_ s: ETAudioSnapshot) -> ETDelaySplit {
        ETDelaySplit(ioMs: ioMs(s), fxMs: fxMs(s))
    }

    init?(_ s: ETAudioSnapshot) {
        guard s.blockFrames > 0 else { return nil }
        let rate = s.deviceRate
        fxMs = Self.fxMs(s)
        split = Self.split(s)
        totalMs = split.totalMs
        linkMs = Double(s.linkTargetFrames) / rate * 1000
        blockMs = Double(s.blockFrames) / rate * 1000
        filterMs = Double(s.resamplerLatency) / rate * 1000
        blockFrames = s.blockFrames
    }

    var value: String { "\(totalMs) ms" }

    /// 合計と足し算を 1 行で。**合計だけの行は置かない。**link と buffer は
    /// 操作子の名前の右に出ていて、同じ数字をもう一度並べることになる。
    /// 足し算が見えないと、どれを削れば効くのか分からない。Fx は
    /// エフェクト自身の遅れで、鎖の中身で変わる。
    /// 0 のものは出さない（オーバーサンプルを切っていれば filter は無い）。
    var summary: String {
        var parts = [String(format: "input %.1f", linkMs),
                     String(format: "buffer %.1f", blockMs)]
        if filterMs > 0.05 { parts.append(String(format: "filter %.1f", filterMs)) }
        if fxMs > 0.05     { parts.append(String(format: "Fx %.1f", fxMs)) }
        return "Total delay \(totalMs) ms · " + parts.joined(separator: " · ")
    }

    var note: String {
        String(format: "%.1f ms between the extension and this app, %.1f ms in the block "
                     + "iOS gave (%d samples), %.1f ms in the oversampling filter, "
                     + "%.1f ms in the effects themselves.",
               linkMs, blockMs, blockFrames, filterMs, fxMs)
    }
}

// MARK: - ツールバーの帯

/// LiveStatusStrip の 4 つの数字と読み上げ。**丸めは Settings と同じ関数。**
/// 帯は走っている間しか出ない（io.running）。
struct ETStripReading: Equatable {
    /// 鎖の外（リンク・ブロック・変換）。
    let ioMs: Int
    /// 鎖が足すぶん。ioMs + fxMs は Settings の Total delay と同じ。
    let fxMs: Int
    /// 休んでいる間は nil。帯は "idle" と出し、色を付けない
    /// （たまたま 75 を跨いだ古い値で色を付けないため）。
    let loadPercent: Int?
    let loadLevel: ETLoadReading.Level?
    /// 効果を回しているレート（入口 × オーバーサンプリング倍率）。
    let rate: String
    let rateIsOff: Bool

    init(_ s: ETAudioSnapshot) {
        let d = ETDelayReading.split(s)
        ioMs = d.ioMs
        fxMs = d.fxMs
        loadPercent = s.resting ? nil : ETLoadReading.percent(s.load)
        loadLevel = s.resting ? nil : ETLoadReading.level(s.load)
        rate = ETRateText.kHz(s.processingRate)
        rateIsOff = s.rateIsOff
    }

    var ioText: String { "\(ioMs) ms" }
    var fxText: String { "\(fxMs) ms" }
    /// 休んでいるときは数字を出さない（0% と紛らわしいため）。
    var loadText: String { loadPercent.map { "\($0)%" } ?? "idle" }

    /// 読み上げでは略さない。"%" や "ms" をそのまま読ませると意味が通らない。
    var delayVoice: String {
        "Effects add \(fxMs) milliseconds, audio path adds \(ioMs) milliseconds"
    }
    var loadVoice: String {
        let cpu = loadPercent.map { "\($0) percent" } ?? "idle"
        return "CPU \(cpu), running at \(rate)"
    }
}

/// kHz の字。帯の Rate と Details の Processing rate が同じ丸めで出す。
enum ETRateText {
    static func kHz(_ hz: Double) -> String {
        guard hz.isFinite else { return "— kHz" }
        return "\(Int((hz / 1000).rounded())) kHz"
    }
}

// MARK: - 問題の行

/// Status 節の 2 行目以降。当てはまるものを**全部**、固定の順で出す。
///
/// 順は深刻さ。音が出ない → 音程がずれる → 途切れる → 効いていない。
/// 条件をビューの if に散らすと、どれがいつ出るのか誰にも分からなくなる。
struct ETIssue: Identifiable {
    let id: String
    let tone: ETNoticeTone
    let systemImage: String
    let title: String
    /// 説明。**削らない**（088e891 で戻した。ETRunState.detail と同じ）。
    let detail: String?

    static func current(_ s: ETAudioSnapshot) -> [ETIssue] {
        var out: [ETIssue] = []

        // 1. 出力が仮想デバイスへ戻っている。音が 1 つも聞こえない。
        if s.loopback {
            out.append(ETIssue(
                id: "loopback",
                tone: .warning,
                systemImage: "arrow.triangle.2.circlepath",
                title: "Output is set to EffectDeck",
                // 長押しの手順は実機で確かめていないので書かない（ETRunState.waiting と同じ）。
                detail: "The processed sound is going back into this app instead of to a "
                      + "speaker, so you hear nothing and the level keeps rising. Pick a real "
                      + "output for this device in Control Center."))
        }

        // 2. 端末のレートが 48kHz でない。速さと音程がずれる。
        if s.running, s.rateIsOff {
            let hz = Int(s.sampleRate.rounded()).formatted()
            out.append(ETIssue(
                id: "rate",
                tone: .warning,
                systemImage: "exclamationmark.triangle.fill",
                title: "The device is running at \(hz) Hz",
                // **マイクも名指しする。**16 k / 32 k は Bluetooth のハンズフリーで、
                // そこに落ちるのは通話用のマイクを掴むアプリが動いているとき。
                // 「他のアプリが握っている」だけでは、何を止めればいいのか分からない。
                detail: s.sampleRate <= 32000
                      ? "Audio arrives at 48 kHz, so pitch and speed are off. Bluetooth "
                      + "headphones drop to this rate when an app takes their microphone "
                      + "— a call, voice input or a recorder. Quit it, then play again."
                      : "Audio arrives at 48 kHz, so pitch and speed are off. Another app is "
                      + "holding the hardware at that rate. Stop it, then play again."))
        }

        // 3. **割れているときだけ出す。**「締切に近い」は CPU の数字が
        //    橙になることで既に言っている。近いだけで行が生えると、
        //    レートや遅延を触っている最中に一覧が飛んで、触っている操作子が動く。
        if let load = ETLoadReading(s), load.level == .over {
            out.append(ETIssue(
                id: "load",
                tone: .warning,
                systemImage: "gauge.with.needle",
                title: "The sound is breaking up",
                detail: "The effects need more time than each buffer has "
                      + "(\(load.percent)% of it). Lower the processing rate, "
                      + "raise the latency, or remove an effect."))
        }

        // 4. 鎖が切ってある。警告ではなく事実の確認なので色を付けない。
        //    「エフェクトが効いていない」の原因のうち、これだけは断定できる。
        //    applied == 0 は撮影や起動直後にも起きるので数えない。
        if s.bypass, s.hasPeer {
            out.append(ETIssue(
                id: "bypass",
                tone: .normal,
                systemImage: "power",
                title: "Effects are switched off",
                detail: "The sound is passing through untouched. The power button at the top "
                      + "left of the main screen turns them back on."))
        }

        return out
    }
}

// MARK: - 報告用の数字

struct ETDiagnosticLine: Identifiable, Equatable {
    var id: String { label }
    let label: String
    let value: String
}

/// Details の行と "Copy details" が貼る文が、同じ配列から作られる。
/// 見えているものと貼ったものが食い違わないようにするため。
struct ETDiagnostics {
    /// "2.9.0 (5)"。貼り付け用の文の 1 行目に入る。
    let version: String
    /// 画面に出す行。そのまま貼り付け用の文にも入る。
    let lines: [ETDiagnosticLine]
    /// 貼り付け用にだけ足す、いまの設定。
    let settings: [ETDiagnosticLine]
    let device: String

    /// 貼り付け用の文。形は StatusReadingsTests.testDiagnosticsLayout が押さえている。
    ///
    ///     EffectDeck 2.9.0 (5) diagnostics
    ///     iPhone17,2 · iOS 27.0
    ///
    ///     Settings
    ///       Latency: Low
    ///
    ///     Details
    ///       Version: 2.9.0 (5)
    var text: String {
        var out = ["EffectDeck \(version) diagnostics", device, ""]
        out.append("Settings")
        out += settings.map { "  \($0.label): \($0.value)" }
        out.append("")
        out.append("Details")
        out += lines.map { "  \($0.label): \($0.value)" }
        return out.joined(separator: "\n")
    }

    /// - Parameters:
    ///   - version: ETAppInfo.display
    ///   - abi: ETAppInfo.abi（DSP のバイナリ互換の番号）
    ///   - device: "iPhone17,2 · iOS 27.0"
    ///   - settings: Preferences から作る設定の行（SettingsModel.swift）
    static func make(_ s: ETAudioSnapshot, version: String, abi: String, device: String,
                     settings: [ETDiagnosticLine]) -> ETDiagnostics {
        let sr = s.deviceRate

        func samples(_ frames: Int, decimals: Int) -> String {
            let ms = Double(frames) / sr * 1000
            return String(format: "%d samples (%.\(decimals)f ms)", frames, ms)
        }

        var lines: [ETDiagnosticLine] = [
            ETDiagnosticLine(label: "Version", value: version),
            // 拡張から来る形は LocalLink.h の定数で、走っている間も変わらない。
            // **ここから音が通る順に並べる。**設定の節と同じ順にしておくと、
            // どれを動かすとどの行が変わるかが引き合わせられる。
            ETDiagnosticLine(label: "Incoming", value: "48 kHz · 32-bit float · 2 ch"),
            // 拡張から本体へ TCP で渡すぶん。再同期でここへ置き直すので
            // 狙いの値（設定の Extension link）。遅延の大半はここ。
            ETDiagnosticLine(label: "Extension link",
                             value: samples(Int(s.linkTargetFrames), decimals: 1)),
            // 拡張と本体のあいだに溜まっているぶん。払うたびに動くので、
            // 判断には使えない。だから常設ではなくここに置いてある。
            ETDiagnosticLine(label: "Queued from the extension",
                             value: samples(Int(s.bufferedFrames), decimals: 0)),
            // **詰めすぎたかはこれで決まる。**尽きたら無音を書いて黙って
            // 進むので、耳では数えられない。繋ぎ直すと 0 に戻る。
            ETDiagnosticLine(label: "Ran dry",
                             value: s.starveCount == 0
                                    ? "never"
                                    : "\(s.starveCount)× · "
                                      + samples(Int(clamping: s.starveFrames), decimals: 0)),
            // 送り手と読み手のクロックのずれで溜まりが漂うぶん。
            // 頻度がそのままずれの速さになる。
            ETDiagnosticLine(label: "Trimmed",
                             value: s.trimCount == 0
                                    ? "never"
                                    : "\(s.trimCount)× · "
                                      + samples(Int(clamping: s.trimFrames), decimals: 0)),
            ETDiagnosticLine(label: "DSP buffer",
                             value: s.blockFrames > 0 ? samples(s.blockFrames, decimals: 1) : "—"),
            ETDiagnosticLine(label: "Processing rate", value: ETRateText.kHz(s.processingRate)),
            ETDiagnosticLine(label: "Device rate",
                             value: s.hasDeviceRate
                                    ? "\(Int(s.sampleRate.rounded()).formatted()) Hz" : "—"),
            ETDiagnosticLine(label: "Oversampling filter",
                             value: s.resamplerLatency > 0
                                    ? samples(s.resamplerLatency, decimals: 2) : "none"),
            ETDiagnosticLine(label: "Frames received",
                             value: Int(clamping: s.received).formatted()),
            // Section は descriptor に入らないので分母から外す（effectCount）。
            ETDiagnosticLine(label: "Effects running", value: "\(s.applied) of \(s.effectCount)"),
            ETDiagnosticLine(label: "Output", value: s.outputRoute),
            // **名乗っている字はここに出さない。**
            // ET_ROUTE_NAME も ET_DRIVER_NAME もコンパイル時の定数で、
            // 出しても定数を書き戻すだけ。動的に取る手も無い:
            //   - 仮想デバイスの名前はそこへ繋がっているときしか
            //     AVAudioSession から読めない。繋がっていれば上の Output に出る
            //   - MediaOutputDevice.displayName は拡張のプロセスが持っていて、
            //     アプリから問い合わせる口が無い
            // 字そのものは Sources/Shared/ETNames.h。
            ETDiagnosticLine(label: "Engine state", value: s.status),
            ETDiagnosticLine(label: "DSP ABI", value: abi),
        ]

        // 描画用テレメトリの取りこぼし。音とは関係が無いので、落ちたときだけ出す。
        if s.telemetryDropped > 0 {
            lines.append(ETDiagnosticLine(label: "Telemetry dropped", value: "\(s.telemetryDropped)"))
        }

        return ETDiagnostics(version: version, lines: lines, settings: settings, device: device)
    }
}
