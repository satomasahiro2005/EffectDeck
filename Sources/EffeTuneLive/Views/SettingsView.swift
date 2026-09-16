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

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    /// 観測しない（上のコメント）。読む節に渡すだけ。
    let io: AudioIO
    @StateObject private var prefs = Preferences.shared
    @StateObject private var dsp = EffeTuneDSP.shared

    var body: some View {
        NavigationStack {
            List {
                StatusSection(io: io, dsp: dsp)
                processingRate
                latency
                pauseWhileSilent
                screen
                DetailsSection(io: io, dsp: dsp, prefs: prefs)
                about
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    // MARK: - 変えるもの

    private var processingRate: some View {
        Section {
            // 同じものを選び直しても組み直さない。押すたびに音が切れると故障に見える。
            ETSegmentedChoice(title: "Processing rate",
                              values: ETProcessingRate.allCases,
                              label: \.label, note: \.note,
                              selection: Binding(get: { prefs.processingRate },
                                                 set: { if $0 != prefs.processingRate {
                                                            prefs.processingRate = $0 } }))
            // 選んだものが本当に効いたかを、その場で確かめられるようにする。
            // 選んだ値（上のセグメント）と、いま回っている値は別物で、
            // 端末が別のレートを握っていると食い違う。
            RunningRateRow(io: io)
            // 負荷はレートで動く。**それを動かす操作子の直下に置く。**
            ProcessingTimeRow(io: io)
        } header: {
            Text("Processing rate")
        } footer: {
            Text("Changing an audio setting restarts the sound for a moment.")
        }
    }

    private var latency: some View {
        Section {
            ETSegmentedChoice(title: "Latency to aim for",
                              values: ETLatency.allCases,
                              label: \.msLabel, note: \.note,
                              selection: Binding(get: { prefs.latency },
                                                 set: { if $0 != prefs.latency {
                                                            prefs.latency = $0 } }))
            DelayRow(io: io)
        } header: {
            // preferredIOBufferDuration は要求で、約束ではない。
            // 実際に通った長さは下の "Right now" で返す。
            Text("Latency to aim for")
        } footer: {
            Text("iOS gives the block size it can. Right now is what it actually gave.")
        }
    }

    private var pauseWhileSilent: some View {
        Section {
            ETSegmentedChoice(title: "Pause while silent",
                              values: ETPowerMode.allCases,
                              label: \.label, note: \.note,
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
        } header: {
            Text("Pause while silent")
        } footer: {
            Text("""
                 The effects start again the moment sound returns. Anything quieter than the \
                 threshold counts as silence: -90 dB is about the noise a quiet recording \
                 carries on its own, and -20 dB is already audible music.
                 """)
        }
    }

    private var screen: some View {
        Section {
            Toggle("Keep the screen on", isOn: $prefs.keepScreenAwake)
        } footer: {
            Text("The screen will not lock while EffeTune Live is in front.")
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
                 EffeTune or its author, and it stops shipping if an official iOS \
                 version appears.
                 """)
        }

        // **問い合わせ先をここに置く。**
        // 置かないと、困った人は EffeTune の作者に聞きに行く。
        // 向こうはこのアプリを作っていないので答えようがない。
        Section {
            Link(destination: URL(string: "https://github.com/satomasahiro2005/effetune-live/issues")!) {
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
            Text("Send anything about this app here, not to EffeTune.")
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
        } footer: {
            Text("""
                 Audio from the player you are listening to arrives here at 48 kHz \
                 through the EffeTune output in Control Center.
                 """)
        }
    }
}

/// いま実際に回っているレート。
///
/// 上のセグメントは「何を選んだか」で、こちらは「何になったか」。
/// 拡張から来る音は 48 kHz 固定で、そこにオーバーサンプリング倍率が掛かる。
/// 端末が別のレートを握っていると 48 kHz にならず、速さと音程がずれる
/// （そのときは Status に警告が出る）。
private struct RunningRateRow: View {
    @ObservedObject var io: AudioIO

    var body: some View {
        // 鳴っていないときは出さない。止まっている値は嘘になる。
        if io.running {
            LabeledContent("Running at") {
                Text(text)
                    .monospacedDigit()
                    .foregroundStyle(mismatch ? AnyShapeStyle(.orange)
                                              : AnyShapeStyle(.secondary))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Running at \(text)")
        }
    }

    /// "96 kHz（48 kHz × 2）"ではなく、入口と出口を並べる。
    /// 倍率は選んだレートから読めるので書かない。
    private var text: String {
        let device = io.sampleRate > 0 ? Int(io.sampleRate.rounded()) : 0
        let processing = Int((io.processingRate / 1000).rounded())
        guard device > 0 else { return "\(processing) kHz" }
        return "\(device.formatted()) Hz in · \(processing) kHz through the effects"
    }

    /// 端末が 48 kHz を握れていない。
    private var mismatch: Bool {
        io.sampleRate > 0 && abs(io.sampleRate - 48000) >= 1
    }
}

/// 締切に対してどれだけ使ったか。名前と言い回しは ETLoadReading が持っている。
private struct ProcessingTimeRow: View {
    @ObservedObject var io: AudioIO

    var body: some View {
        // 休んでいる間は出さない。状態の行が既に "Idle" と言っているし、
        // "0%" は「余裕がある」と見分けが付かない。
        if let reading = ETLoadReading(io: io) {
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("CPU") {
                    Text(reading.value)
                        .monospacedDigit()
                        .foregroundStyle(style(reading.level))
                }
                Text(reading.note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(reading.accessibility)
        }
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
private struct DelayRow: View {
    @ObservedObject var io: AudioIO

    var body: some View {
        if let reading = ETDelayReading(io: io) {
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Right now") {
                    Text(reading.value)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Text(reading.note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
        } footer: {
            Text("These numbers are for bug reports.")
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

        Button {
            // 貼るほうには端末と iOS と設定も入れる。報告を 1 回で受け取るため。
            UIPasteboard.general.string = diagnostics.text
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
