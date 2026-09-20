//  SettingsView.swift
//  右上の ⋯ から出す 1 枚。EffeTune も設定は右上に置いてある。
//
//  **画面は 1 枚。押して進むのはライセンス本文の 1 回だけ。**
//  以前はシート（Settings）→ Status →（戻って）About → Licenses → 本文 と、
//  シートの中で 3 回潜っていた。Status も About も読むだけの画面で、
//  行数が足りないものを画面に昇格させた結果そうなっていた。
//  HIG の Modality が言うとおり、シートの中に階層を作ると戻り方が分からなくなる。
//
//  上から「いま何が起きているか（問題があればその対処）→ 変えるもの →
//  診断用の数字（畳んである）→ 版と出典」。
//
//  **io を画面全体で観測しない。** tick() が 3.3Hz で publish するので、
//  観測すると List ごと作り直される。io を読むのは下の 3 つの小さな View だけ。
//  設定の節は Preferences しか見ない。
//
//  設定を変えると音の経路を組み直す（Preferences.onAudioChange）。一瞬止まる。
//  その断りは Processing rate の footer に 1 回だけ置いてある。繰り返さない。

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    /// 観測しない（上のコメント）。読む節に渡すだけ。
    let io: AudioIO
    @StateObject private var prefs = Preferences.shared
    @StateObject private var dsp = EffeTuneDSP.shared

    /// **横で束ねる。**縦に全部並べると、一度に読めない長さになる。
    /// 下位画面へ押し出すと、よく見る Status まで 1 タップ遠くなる。
    /// バーの真ん中でセグメントを切り替える形なら、どちらも起きない。
    enum Pane: String, CaseIterable, Identifiable {
        case audio, about
        var id: String { rawValue }
        var label: String {
            switch self {
            case .audio:  return "Audio"
            case .about:  return "About"
            }
        }
    }

    @State private var pane: Pane = .audio

    var body: some View {
        NavigationStack {
            List {
                switch pane {
                case .audio:
                    StatusSection(io: io, dsp: dsp)
                    processing
                    Section {
                        Toggle("Sync Visuals to Audio", isOn: $prefs.syncVisualsToAudio)
                    } footer: {
                        Text("Delay graphs to match the audio output latency.")
                    }
                    power
                    // **音の数字は Audio に置く。**レート・バッファ・遅延の内訳・
                    // 出力先なので、探しに来るのはこの面。報告に貼る値でもあるが、
                    // 貼る前に読むのは音の話として読む。畳んであるので 1 行で済む。
                    DetailsSection(io: io, dsp: dsp, prefs: prefs)
                case .about:
                    about
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // **セグメントは UISegmentedControl で Menu ではない。**
                // この画面が Picker を避けているのは Menu が固まるからなので、
                // ここは当たらない（SettingsRows.swift の頭）。
                ToolbarItem(placement: .principal) {
                    Picker("", selection: $pane) {
                        ForEach(Pane.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    // MARK: - 変えるもの

    /// **入口から耳まで、通る順に並べる。**
    ///
    ///   Oversampling … 何倍にして計算するか
    ///   Input        … 届く形。選べないので読むだけ。下の spls の基準
    ///   Input buffer … 入口で溜める量。遅れの大半がここ。選べない
    ///   DSP buffer   … 一度に計算する量
    ///   CPU          … その枠にどれだけ使ったか。バッファと表裏
    ///   Total delay  … 上の足し算
    ///
    /// **一組にして並べる。**どの操作子も、名前の右にその結果の数字が来る。
    /// 要求と実測を別の行に分けると同じ名前が 2 度出て、どちらが効いて
    /// いる値なのか読めなくなる（前はそうなっていた）。
    private var processing: some View {
        Section {
            // 同じものを選び直しても組み直さない。押すたびに音が切れると故障に見える。
            //
            // **触るものを先に置く。**読むだけの Input を上に挟むと、
            // 操作子のあいだに動かない行が入って一組に見えない。
            // レートを選ばせるのは、倍率だけだと何 kHz になるのか
            // 出てこないから。下の spls がこのレートの数でないことは、
            // すぐ下の Input の行が受け持つ。
            ETSegmentedChoice(title: "Oversampling",
                              values: ETProcessingRate.allCases,
                              label: \.label,
                              detail: prefs.processingRate.factorLabel,
                              selection: Binding(get: { prefs.processingRate },
                                                 set: { if $0 != prefs.processingRate {
                                                            prefs.processingRate = $0 } }))
            // **基準を最初に置く。**この節の spls がどのレートで数えた数かは、
            // 入口のレートが見えていないと決められない。届く形は決まっていて
            // 選べないので、読むだけの行にする。
            LabeledContent("Input") {
                Text("48 kHz · 32-bit float")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            // **遅れの大半はここ。**選ばせるものではないので操作子は無いが、
            // 出さないと 21.3 ms がどこから来たのか辿れない。枯れて 2048 へ
            // 逃げたときに、それが見えるのもこの行だけ。
            InputBufferRow(io: io)
            // preferredIOBufferDuration は要求で、約束ではない。
            // 実際に通った長さを名前の右に出す。
            // **「DSP」を付ける。**入口の溜まり（Total delay の input）と
            // 区別が付かないと、どちらの話か読めない。実体は
            // preferredIOBufferDuration だが、それがそのまま鎖を通す単位。
            ETSegmentedChoice(title: "DSP buffer",
                              values: ETLatency.allCases,
                              // **フレーム数を出す。**DAW と同じ数字なので、
                              // 触っている人はそのまま読める。
                              label: \.label,
                              detail: ETDelayReading(io: io).map {
                                  String(format: "%d spls · %.1f ms", $0.blockFrames, $0.blockMs)
                              },
                              selection: Binding(get: { prefs.latency },
                                                 set: { if $0 != prefs.latency {
                                                            prefs.latency = $0 } }))
            // **バッファのすぐ下。**この 2 つは表裏で、詰めるほど 1 枠あたりの
            // 猶予が減り、同じ鎖でも間に合わなくなる。離すと結び付かない。
            ProcessingTimeRow(io: io)
            DelayRow(io: io)
        } header: {
            Text("Processing")
        }
    }

    /// **省エネまわり。**休む条件と、画面を点けたままにするか。
    private var power: some View {
        Section {
            ETSegmentedChoice(title: "Pause after",
                              values: ETPowerMode.allCases,
                              label: \.label,
                              selection: Binding(get: { prefs.powerMode },
                                                 set: { if $0 != prefs.powerMode {
                                                            prefs.powerMode = $0 } }))
            // **行を消さない。** 以前は Always on のときこの行が消えていて、
            // 一覧が飛ぶので何が減ったのか分からなかった。効かないときは薄くする。
            Stepper(value: $prefs.silenceThresholdDb,
                    in: Preferences.silenceRange,
                    step: Preferences.silenceStep) {
                HStack {
                    Text("Silence threshold")
                    Spacer(minLength: 8)
                    Text("\(Int(prefs.silenceThresholdDb)) dB")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(prefs.powerMode == .continuous)
            Toggle("Keep the screen on", isOn: $prefs.keepScreenAwake)
        } header: {
            Text("Power")
        }
    }

    // MARK: - 読むもの

    // 節が 2 つになるので ViewBuilder が要る。
    @ViewBuilder
    private var about: some View {
        Section {
            // 下の行と並ぶので、どちらの版かを名前で言い切る。
            LabeledContent("App version", value: ETAppInfo.display)
            // 積んでいる EffeTune の版。いまは上のアプリの版と同じ数字に
            // 揃えてあるが（Tools/gen_version.py）、指しているものが違う。
            // 効果の本数は出さない。増えても減っても使う人の判断は変わらない。
            LabeledContent("EffeTune DSP", value: ETUpstreamVersion)
            NavigationLink("Open source licenses") { LicensesView() }
        } header: {
            Text("About")
        } footer: {
            Text("""
                 The effects are EffeTune's own DSP by Yoshiyuki Kobayashi, running \
                 unmodified under the MIT license. This app is a separate project by \
                 nemut.ai. It is not affiliated with, endorsed by, or supported by \
                 EffeTune or its author.
                 """)
        }

        // **問い合わせ先をここに置く。**
        // 置かないと、困った人は EffeTune の作者に聞きに行く。
        // 向こうはこのアプリを作っていないので答えようがない。
        //
        // **診断を貼る札を同じ節の先頭に置く。**数字は Audio の Details にも在るが、
        // 報告する人はここに居る。別のペインへ取りに行かせると、たいてい何も付かない
        // 報告が来る。Details 節はそのまま残す（音の数字は Audio に置く、の判断は
        // 壊さない）。押した瞬間に作るので、ここで io を観測する必要は無い。
        Section {
            ETCopyDiagnosticsButton {
                ETDiagnostics.current(io: io, dsp: dsp, prefs: prefs)
            }
            ETShareLogButton()
            Link(destination: URL(string: "https://github.com/satomasahiro2005/EffectDeck/issues")!) {
                LabeledContent("Report a problem", value: "GitHub")
            }
            Link(destination: URL(string: "mailto:support@nemut.ai")!) {
                LabeledContent("Email", value: "support@nemut.ai")
            }
            Link(destination: URL(string: "https://nemut.ai/effetune-live/privacy.html")!) {
                Text("Privacy policy")
            }
        } header: {
            Text("Contact")
        } footer: {
            Text("Copy details first, then paste it into the report. It includes the app version, the device, and what the audio path is doing right now.")
        }
    }
}

// MARK: - いま何が起きているか

/// io を観測する 1 つ目の閉じ込め先。
/// 3.3Hz で作り直されるが、中は文字だけなので提示の途中のものが無い。
private struct StatusSection: View {
    @ObservedObject var io: AudioIO
    /// bypass だけ読む。SettingsView 側が観測しているので、ここでは観測しない。
    let dsp: EffeTuneDSP

    var body: some View {
        Section {
            ETNoticeRow(state: ETRunState.current(io: io), retry: { io.restart() })
            ForEach(ETIssue.current(io: io, dsp: dsp)) { issue in
                ETNoticeRow(issue: issue)
            }
        } header: {
            Text("Status")
        }
    }
}

/// 締切に対してどれだけ使ったか。名前と言い回しは ETLoadReading が持っている。
private struct ProcessingTimeRow: View {
    @ObservedObject var io: AudioIO

    var body: some View {
        // **行を消さない。** 休んでいる間 nil になるので、以前はここだけ
        // 一瞬出て消えていた。一覧が飛ぶのは故障に見える（Silence threshold で
        // 同じ踏み方を既に直している）。出ないときは薄く "—"。
        let reading = ETLoadReading(io: io)
        LabeledContent("CPU") {
            Text(reading?.value ?? "—")
                .monospacedDigit()
                .foregroundStyle(reading.map { style($0.level) } ?? AnyShapeStyle(.secondary))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(reading?.accessibility ?? "CPU")
    }

    /// 閾値は ETLoadReading が持っている。色はツールバーの帯と同じ段。
    private func style(_ level: ETLoadReading.Level) -> AnyShapeStyle {
        switch level {
        case .normal: return AnyShapeStyle(.primary)
        case .high:   return AnyShapeStyle(.orange)
        case .over:   return AnyShapeStyle(.red)
        }
    }
}

/// 実際に出るまでの遅れと、その内訳。
/// 入口で溜めている量。**選ばせない。**1024 で始めて、枯れたら黙って
/// 2048 へ逃げる（LocalLink.m）。その逃げた先が見えるのがこの行。
///
/// io を観測するのは、値が走っている最中に変わるから。
private struct InputBufferRow: View {
    @ObservedObject var io: AudioIO

    var body: some View {
        let frames = Int(ETLinkReceiver.targetFrames)
        LabeledContent("Input buffer") {
            Text(String(format: "%d spls · %.1f ms",
                        frames, Double(frames) / 48000 * 1000))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

private struct DelayRow: View {
    @ObservedObject var io: AudioIO

    var body: some View {
        // **名前の付いた行を作らない。**link も buffer も、選ぶ操作子の
        // 名前の右に同じ数字が出ている。合計だけの行を足すと、画面に
        // 同じ値が 2 度並ぶ。合計と足し算を 1 行にまとめる。
        if let d = ETDelayReading(io: io) {
            Text(d.summary)
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 報告用の数字

/// 畳んである。**開いている間だけ io を観測する。**
/// 畳んだまま 3.3Hz で作り直すと、読まない数字のために描き直すことになる。
private struct DetailsSection: View {
    let io: AudioIO
    let dsp: EffeTuneDSP
    let prefs: Preferences
    @State private var open = false

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $open) {
                if open { DetailsRows(io: io, dsp: dsp, prefs: prefs) }
            } label: {
                Text("Details")
            }
        }
    }
}

/// io を観測する 2 つ目の閉じ込め先。
private struct DetailsRows: View {
    @ObservedObject var io: AudioIO
    let dsp: EffeTuneDSP
    let prefs: Preferences
    @State private var copied = false

    /// 表示と貼り付けが同じ配列から作られる。食い違わせないため。
    private var diagnostics: ETDiagnostics {
        ETDiagnostics.current(io: io, dsp: dsp, prefs: prefs)
    }

    var body: some View {
        ForEach(diagnostics.lines) { line in
            LabeledContent(line.label) {
                Text(line.value)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.footnote)
        }

        // 貼るほうには端末と iOS と設定も入れる。報告を 1 回で受け取るため。
        ETCopyDiagnosticsButton { diagnostics }
    }
}

/// ログを添付として渡す札。
///
/// **本文には入れない。**メールの本文も GitHub の issue の URL もクエリに載るので、
/// パーセント符号化で 1.5〜2.3 倍に膨らむ。URL に載る生ログは数 KB が上限で、
/// 1 MB は入らない。ファイルならクエリを通らない。
/// ShareLink の前例は PresetsView。MessageUI は足さない。
///
/// 溜まっていないときは出さない。押せて何も付かない札は混乱の元。
private struct ETShareLogButton: View {
    @State private var file: URL?

    var body: some View {
        if ETLogTap.byteCount > 0 {
            if let file {
                ShareLink(item: file) {
                    LabeledContent("Attach log", value: Self.size(ETLogTap.byteCount))
                }
            } else {
                Button {
                    file = ETLogTap.writeAttachment()
                } label: {
                    LabeledContent("Prepare log", value: Self.size(ETLogTap.byteCount))
                }
            }
        }
    }

    private static func size(_ bytes: Int) -> String {
        bytes >= 1_000_000 ? String(format: "%.1f MB", Double(bytes) / 1_000_000)
                           : String(format: "%d KB", max(1, bytes / 1000))
    }
}

/// 診断を貼る札。Audio の Details と About の Report の両方から呼ぶ。
///
/// **診断は値ではなく閉包で受ける。**値で受けると評価は body を組み直した時点に
/// なる。About 側は io を観測していない（観測すると 3.3Hz で作り直される）ので、
/// 走っている最中に動く行――溜まり・枯れ・詰め――が数十秒前のまま貼られる。
/// 押した瞬間に読めば、観測せずに今の数字が入る。
private struct ETCopyDiagnosticsButton: View {
    let make: () -> ETDiagnostics
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = make().text
            copied = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                copied = false
            }
        } label: {
            Text(copied ? "Copied" : "Copy details")
        }
    }
}
