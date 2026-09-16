//  SettingsModel.swift
//  Settings 1 枚が読むものを、ビューの外で作る。
//
//  条件の判断と言い回しをここへ集めてある。理由は 2 つ。
//   - 同じ数字の呼び方が 2 か所にあると、片方だけ直って食い違う。
//     負荷の名前（"CPU"）と 1 文は ETLoadReading にしか無い。
//   - 「どの警告がいつ出るか」がビューの中の if に散らばっていると、
//     誤爆の検査が書けない。ETIssue.current が配列を返す形にしてある。
//
//  ここは AudioIO を**読むだけ**で、観測（@ObservedObject）はしない。
//  観測を置くのは SettingsView 側の小さな View（StatusSection / ProcessingTimeRow /
//  DelayRow / DetailsRows）だけで、List 全体には効かせない。

import Foundation
import Darwin
import UIKit

// MARK: - 版と端末

/// 版・ABI・端末。以前は SettingsView と AboutView が同じ private var version を
/// 1 つずつ持っていた。貼り付け用の文と画面の表示が食い違わないよう 1 か所にする。
enum ETAppInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }
    /// "2.9.0 (5)"
    static var display: String { "\(version) (\(build))" }

    /// DSP のバイナリ互換の番号。コンパイル時の定数で、使う人には意味が無い。
    /// 報告を受け取る側だけが読むので、Details と貼り付け用の文にしか出さない。
    static var abi: String { "\(et_abi_version())" }

    /// "iPhone17,2"。報告を 1 回で受け取るにはこれが要る。
    /// UIDevice.model は "iPhone" としか返さないので uname を使う。
    static var device: String {
        var info = utsname()
        uname(&info)
        let bytes = withUnsafeBytes(of: &info.machine) { raw -> [UInt8] in
            Array(raw.prefix(while: { $0 != 0 }))
        }
        let name = String(decoding: bytes, as: UTF8.self)
        return name.isEmpty ? "unknown" : name
    }

    @MainActor static var system: String { "iOS " + UIDevice.current.systemVersion }
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
enum ETRunState {
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
    private static let failurePrefixes = [
        "Cannot open the listening socket",
        "Audio session failed",
        "Audio engine failed",
    ]

    @MainActor
    static func current(io: AudioIO) -> ETRunState {
        if Self.failurePrefixes.contains(where: { io.status.hasPrefix($0) }) {
            return .failed(io.status)
        }
        if io.status == "Interrupted" { return .interrupted }
        if !io.hasPeer { return .waiting }
        if io.running { return io.resting ? .idle : .playing(output: io.route) }
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

    var detail: String {
        switch self {
        case .failed:
            return "Close any other app that is holding the audio device, then try again."
        case .interrupted:
            return "A call or another app took the audio device. Play something again to restart."
        case .waiting:
            return "Open Control Center, press and hold the audio card, then choose EffeTune "
                 + "as the output for the app you are playing."
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
    private static func readableRoute(_ raw: String) -> String {
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
    static let high = 0.75
    /// ここを超えると音が途切れる。
    static let over = 1.0

    enum Level { case normal, high, over }

    let fraction: Double
    let percent: Int
    let usedMs: Double
    let blockMs: Double

    /// 休んでいる間と鳴っていない間は作らない。
    /// "0%" を出すと、締切に余裕があるのか止まっているのか区別できない。
    @MainActor
    init?(io: AudioIO) {
        guard io.running, !io.resting, io.blockFrames > 0, io.sampleRate > 0 else { return nil }
        fraction = max(0, io.load)
        percent = Int((fraction * 100).rounded())
        blockMs = Double(io.blockFrames) / io.sampleRate * 1000
        usedMs = blockMs * fraction
    }

    var level: Level {
        if fraction >= Self.over { return .over }
        if fraction >= Self.high { return .high }
        return .normal
    }

    /// **単位を % で終わらせない。** 何の何 % かを同じ行に書く。
    var value: String { "\(percent)% of each block" }

    /// **語は上流に合わせて "CPU"。** 上流の右下が "CPU: Avg {average}%"
    /// （js/locales/en.json5:69）。ツールバーの帯も同じ語を使っている。
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

/// Latency を選んだ結果、実際に何 ms 遅れているか。
///
/// 「Low を選んだのに 48 ms なのはなぜか」に答えられる形にしてある。
/// 合計はツールバーの帯（LiveStatusStrip の "Delay"）と同じ 3 つの和で、
/// 丸めも同じく合計してから 1 回だけ。帯と食い違うと、どちらも信用されなくなる。
struct ETDelayReading {
    let totalMs: Int
    let linkMs: Double
    let blockMs: Double
    let filterMs: Double
    let blockFrames: Int

    @MainActor
    init?(io: AudioIO) {
        guard io.blockFrames > 0 else { return nil }
        let rate = io.sampleRate > 0 ? io.sampleRate : 48000
        // 拡張と本体のあいだ。再同期でここへ置き直すので設計上の定数
        // （LocalLink.m の +targetFrames は 2048 固定＝48kHz で 43ms）。
        let link = Double(ETLinkReceiver.targetFrames)
        let block = Double(io.blockFrames)
        let filter = Double(io.resamplerLatency)
        totalMs = Int(((link + block + filter) / rate * 1000).rounded())
        linkMs = link / rate * 1000
        blockMs = block / rate * 1000
        filterMs = filter / rate * 1000
        blockFrames = io.blockFrames
    }

    var value: String { "\(totalMs) ms" }

    var note: String {
        String(format: "%.1f ms between the extension and this app, %.1f ms in the block "
                     + "iOS gave (%d samples), %.1f ms in the oversampling filter.",
               linkMs, blockMs, blockFrames, filterMs)
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
    let detail: String

    @MainActor
    static func current(io: AudioIO, dsp: EffeTuneDSP) -> [ETIssue] {
        var out: [ETIssue] = []

        // 1. 出力が仮想デバイスへ戻っている。音が 1 つも聞こえない。
        if io.loopback {
            out.append(ETIssue(
                id: "loopback",
                tone: .warning,
                systemImage: "arrow.triangle.2.circlepath",
                title: "Output is set to EffeTune",
                detail: "The processed sound is going back into this app instead of to a "
                      + "speaker, so you hear nothing and the level keeps rising. Open "
                      + "Control Center, press and hold the audio card, and pick a real "
                      + "output for this device."))
        }

        // 2. 端末のレートが 48kHz でない。速さと音程がずれる。
        if io.running, io.sampleRate > 0, abs(io.sampleRate - 48000) >= 1 {
            let hz = Int(io.sampleRate.rounded()).formatted()
            out.append(ETIssue(
                id: "rate",
                tone: .warning,
                systemImage: "exclamationmark.triangle.fill",
                title: "The device is running at \(hz) Hz",
                detail: "Audio arrives at 48 kHz, so pitch and speed are off. Another app is "
                      + "holding the hardware at that rate. Stop it, then play again."))
        }

        // 3. 締切に近い。色が変わるのと同じところで出す（閾値は ETLoadReading）。
        if let load = ETLoadReading(io: io), load.level != .normal {
            let over = load.level == .over
            let what = over
                ? "The effects need more time than each block has (\(load.percent)% of it)."
                : "The effects are using \(load.percent)% of the time each block has. "
                  + "Over 100% the sound breaks up."
            out.append(ETIssue(
                id: "load",
                tone: .warning,
                systemImage: "gauge.with.needle",
                title: over ? "The sound is breaking up" : "Running close to the limit",
                detail: what
                      + " Lower the processing rate, raise the latency, or remove an effect."))
        }

        // 4. 鎖が切ってある。警告ではなく事実の確認なので色を付けない。
        //    「エフェクトが効いていない」の原因のうち、これだけは断定できる。
        //    applied == 0 は撮影や起動直後にも起きるので数えない。
        if dsp.bypass, io.hasPeer {
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

struct ETDiagnosticLine: Identifiable {
    var id: String { label }
    let label: String
    let value: String
}

/// Details の行と "Copy details" が貼る文が、同じ配列から作られる。
/// 見えているものと貼ったものが食い違わないようにするため。
struct ETDiagnostics {
    /// 画面に出す行。そのまま貼り付け用の文にも入る。
    let lines: [ETDiagnosticLine]
    /// 貼り付け用にだけ足す、いまの設定。
    let settings: [ETDiagnosticLine]
    let device: String

    var text: String {
        var out = ["EffeTune Live \(ETAppInfo.display) diagnostics", device, ""]
        out.append("Settings")
        out += settings.map { "  \($0.label): \($0.value)" }
        out.append("")
        out.append("Details")
        out += lines.map { "  \($0.label): \($0.value)" }
        return out.joined(separator: "\n")
    }

    @MainActor
    static func current(io: AudioIO, dsp: EffeTuneDSP, prefs: Preferences) -> ETDiagnostics {
        let sr = io.sampleRate > 0 ? io.sampleRate : 48000

        func samples(_ frames: Int, decimals: Int) -> String {
            let ms = Double(frames) / sr * 1000
            return String(format: "%d samples (%.\(decimals)f ms)", frames, ms)
        }

        var lines: [ETDiagnosticLine] = [
            ETDiagnosticLine(label: "Version", value: ETAppInfo.display),
            // 拡張から来る形は LocalLink.h の定数で、走っている間も変わらない。
            ETDiagnosticLine(label: "Incoming", value: "48 kHz · 32-bit float · 2 ch"),
            ETDiagnosticLine(label: "Device rate",
                             value: io.sampleRate > 0
                                    ? "\(Int(io.sampleRate.rounded()).formatted()) Hz" : "—"),
            ETDiagnosticLine(label: "Processing rate",
                             value: "\(Int((io.processingRate / 1000).rounded())) kHz"),
            ETDiagnosticLine(label: "Block",
                             value: io.blockFrames > 0 ? samples(io.blockFrames, decimals: 1) : "—"),
            // 拡張と本体のあいだに溜まっているぶん。払うたびに動くので、
            // 判断には使えない。だから常設ではなくここに置いてある。
            ETDiagnosticLine(label: "Queued from the extension",
                             value: samples(Int(io.bufferedFrames), decimals: 0)),
            ETDiagnosticLine(label: "Oversampling filter",
                             value: io.resamplerLatency > 0
                                    ? samples(io.resamplerLatency, decimals: 2) : "none"),
            ETDiagnosticLine(label: "Frames received",
                             value: Int(clamping: io.received).formatted()),
            // Section は descriptor に入らないので分母から外す。
            ETDiagnosticLine(label: "Effects running",
                             value: "\(io.applied) of \(dsp.chain.filter { !$0.isSection }.count)"),
            ETDiagnosticLine(label: "Output", value: io.outputRoute),
            ETDiagnosticLine(label: "Engine state", value: io.status),
            ETDiagnosticLine(label: "DSP ABI", value: ETAppInfo.abi),
        ]

        // 描画用テレメトリの取りこぼし。音とは関係が無いので、落ちたときだけ出す。
        // ここは**読むだけ**で観測しない（30Hz で publish するため）。
        let dropped = Telemetry.shared.droppedFrames
        if dropped > 0 {
            lines.append(ETDiagnosticLine(label: "Telemetry dropped", value: "\(dropped)"))
        }

        let settings: [ETDiagnosticLine] = [
            ETDiagnosticLine(label: "Processing rate", value: prefs.processingRate.label),
            ETDiagnosticLine(label: "Latency", value: prefs.latency.choiceTitle),
            ETDiagnosticLine(label: "Pause while silent", value: prefs.powerMode.label),
            ETDiagnosticLine(label: "Silence threshold",
                             value: "\(Int(prefs.silenceThresholdDb)) dB"),
            ETDiagnosticLine(label: "Keep the screen on",
                             value: prefs.keepScreenAwake ? "On" : "Off"),
            ETDiagnosticLine(label: "Effect pipeline", value: dsp.bypass ? "Off" : "On"),
        ]

        return ETDiagnostics(lines: lines, settings: settings,
                             device: "\(ETAppInfo.device) · \(ETAppInfo.system)")
    }
}

// MARK: - 失敗からの復帰

extension AudioIO {
    /// "Try again" から呼ぶ。
    ///
    /// start() は入口で stop(keepListening:) を通るので、ビュー側で stop→start を
    /// 並べる必要は無い（並べると、その間に followPeer が割り込む形ができる）。
    /// AudioIO.swift は別の作業が走っているので、口だけここに足してある。
    func restart() { start() }
}
