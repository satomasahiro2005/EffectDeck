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

    /// **処理まわりを 1 つの節にまとめる。**レートとブロックは
    /// どちらも「どれだけ計算して、どれだけ遅れるか」の話で、
    /// 節を分けると見出しのぶんだけ縦が伸びる。
    private var processing: some View {
        Section {
            // 同じものを選び直しても組み直さない。押すたびに音が切れると故障に見える。
            ETSegmentedChoice(title: "Processing rate",
                              values: ETProcessingRate.allCases,
                              label: \.label,
                              selection: Binding(get: { prefs.processingRate },
                                                 set: { if $0 != prefs.processingRate {
                                                            prefs.processingRate = $0 } }))
            // preferredIOBufferDuration は要求で、約束ではない。
            // 実際に通った長さは下の "Total delay" で返す。
            ETSegmentedChoice(title: "Latency to aim for",
                              values: ETLatency.allCases,
                              // **ms を出す。**Low / Mid / High だけだと、
                              // 何がどれだけ動くのかが画面のどこにも無い。
                              label: \.msLabel,
                              selection: Binding(get: { prefs.latency },
                                                 set: { if $0 != prefs.latency {
                                                            prefs.latency = $0 } }))
            // **操作子を先、読む数字を後ろ。**あいだに数字を挟むと、
            // 2 つの操作子が離れて一組に見えなくなる。
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
private struct DelayRow: View {
    @ObservedObject var io: AudioIO

    var body: some View {
        // **名前は中の言葉にしない。**"Block" は使う人の語ではない。
        // サンプル数で出すのは、Low / Mid / High で動いているのがここで、
        // ms だけだと何が変わったのか見えないから。
        let d = ETDelayReading(io: io)
        LabeledContent("Buffer size") {
            Text(d.map { String(format: "%d samples · %.1f ms", $0.blockFrames, $0.blockMs) }
                 ?? "—")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        // 実際に耳へ届くまでの遅れ。内訳（Extension link / Oversampling filter）は
        // Details に在る。あそこは畳んであるので縦を食わない。
        LabeledContent("Total delay") {
            Text(d?.value ?? "—")
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
