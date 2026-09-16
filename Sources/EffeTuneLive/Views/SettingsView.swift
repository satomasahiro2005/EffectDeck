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

    /// 書き出し / 読み込み。
    /// **提示は行ごとに分ける。**fileExporter を Export の行、fileImporter を
    /// Import の行に付けてある。同じビューに重ねると後から付けた方しか出ない
    /// （IRReverbView.swift:81-86）。結果は提示ではなく節の中の 1 行で返す。
    @State private var exporting = false
    @State private var importing = false
    @State private var exportFile: ETBackupDocument?
    @State private var backupReport: String?
    /// 読めたが、まだ入れていないファイルの中身。押し直すまでここで待つ。
    @State private var pending: ETBackup.Contents?

    var body: some View {
        NavigationStack {
            List {
                StatusSection(io: io, dsp: dsp)
                processingRate
                latency
                pauseWhileSilent
                screen
                backup
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
            Text("The screen will not lock while EffectDeck is in front.")
        }
    }

    // MARK: - 持ち出す

    /// 鎖とプリセットを 1 本の JSON にする（中身は ETBackup）。
    ///
    /// **この画面の設定そのもの（Processing rate / Latency ほか）は入らない。**
    /// 入るのは鎖・保存した鎖・エフェクトごとのプリセットの 3 つだけなので、
    /// ボタンも "settings" とは名乗らない。同じ画面に並んでいる設定が
    /// 一緒に出ると読めてしまう。
    ///
    /// 共有リンク（PresetsView の "EffeTune on the web"）とは別物で、
    /// あちらは鎖 1 本を渡すためのもの。こちらは取っておくためのもの。
    ///
    /// **読み込みは 2 段。**選んだ瞬間には入れず、何が入って何が消えるかを
    /// 1 行出してからもう一度押させる。鎖ごと捨てる他の口（PipelineView.swift:117-127
    /// の "Reset Pipeline?"）と同じ重さにする。あちらより壊す量が多いのに
    /// 何も聞かない、という形にしない。
    ///
    /// **提示は増やさない。**聞くのは節の中の行で、confirmationDialog を
    /// 足さない。同じ View に提示を重ねて後ろが出なくなる踏み方を
    /// このリポジトリで 3 度している（PresetsView.swift:145-148）。
    /// 行なら潰し合わないし、出なかったことにも気づける。
    private var backup: some View {
        Section {
            Button {
                export()
            } label: {
                Label("Export presets & chain", systemImage: "square.and.arrow.up")
            }
            .fileExporter(isPresented: $exporting,
                          document: exportFile,
                          contentType: .json,
                          defaultFilename: "EffeTune Live Settings") { result in
                switch result {
                case .success:
                    backupReport = "Exported."
                case .failure(let error):
                    backupReport = error.localizedDescription
                }
                exportFile = nil
            }

            Button {
                importing = true
            } label: {
                Label("Import presets & chain", systemImage: "square.and.arrow.down")
            }
            .fileImporter(isPresented: $importing,
                          allowedContentTypes: [.json, .text, .data],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first { importBackup(url) }
                case .failure(let error):
                    pending = nil
                    backupReport = error.localizedDescription
                }
            }

            // 出したままにせず、次の出し入れで置き換える（IRLibraryView と同じ扱い）。
            // **押す前の説明もここに出る。**読んでから下の 2 行を押す形にしたいので、
            // 順番はこちらが先。
            if let backupReport {
                Text(backupReport)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            // 読めたファイルが待っているあいだだけ出る 2 行。
            // 何が入って何が消えるかは、すぐ上の 1 行に出ている。
            if let waiting = pending {
                Button(role: .destructive) {
                    pending = nil
                    backupReport = apply(waiting)
                } label: {
                    Text("Import")
                }
                Button("Cancel") {
                    pending = nil
                    backupReport = nil
                }
            }
        } header: {
            Text("Backup")
        } footer: {
            Text("""
                 The file holds the current chain, the presets you saved, and the presets you \
                 saved on individual effects. Audio settings such as Processing rate are not \
                 included. Impulse responses stay in the IR Library: a chain that uses one \
                 keeps its key, not the audio. Importing replaces the current chain, and a \
                 preset in the file replaces the one here with the same name. The chain is \
                 written the way the web version writes a preset file, so renaming the file \
                 to .effetune_preset opens it there.
                 """)
        }
    }

    private func export() {
        let presets = PresetStore.shared.exported()
        let effectPresets = EffectPresetStore.shared.exported()

        // **「出すものが無い」と「書けなかった」を分ける。**
        // ETBackup.data は両方 nil で返すので、空かどうかはここで見る。
        // 一緒にすると、中身が在るのに書けなかったときに嘘を出すことになる。
        guard !dsp.chain.isEmpty || !presets.isEmpty || !effectPresets.isEmpty else {
            backupReport = "There is nothing to export yet."
            return
        }
        guard let data = ETBackup.data(chain: dsp.chain,
                                       presets: presets,
                                       effectPresets: effectPresets) else {
            backupReport = "That could not be written as JSON."
            return
        }
        exportFile = ETBackupDocument(data: data)
        exporting = true
    }

    /// **読むだけ。**入れるのは、下の 1 行を読んでもう一度押してから。
    private func importBackup(_ url: URL) {
        // ファイルアプリから来た URL は囲いの外にある（IRLibrary.importFile と同じ）。
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else {
            pending = nil
            backupReport = "That file could not be read."
            return
        }

        switch ETBackup.read(data, catalog: ETCatalog) {
        case .failure(let why):
            pending = nil
            backupReport = why.message
        case .success(let contents):
            pending = contents
            backupReport = summary(of: contents)
        }
    }

    /// 押す前に出す 1 行。**消えるものを先に言う。**
    private func summary(of contents: ETBackup.Contents) -> String {
        var has: [String] = []
        if !contents.chain.isEmpty { has.append(amount(contents.chain.count, "effect")) }
        if !contents.presets.isEmpty { has.append(amount(contents.presets.count, "preset")) }
        if contents.effectPresetCount > 0 {
            has.append(amount(contents.effectPresetCount, "effect preset"))
        }

        var text = ["This file has " + has.joined(separator: ", ") + "."]

        if contents.chainDropped > 0 {
            let verb = contents.chainDropped == 1 ? "is" : "are"
            text.append("\(amount(contents.chainDropped, "effect")) in it \(verb) "
                        + "not available here and will be left out.")
        }
        if contents.skipped > 0 {
            text.append(amount(contents.skipped, "preset") + " could not be read.")
        }
        if !contents.chain.isEmpty {
            // **ready は押す前に見る。**押してから「エンジンが立っていない」と
            // 言われても、ファイルが悪いのかどうか読めない。
            text.append(dsp.ready
                        ? "Importing replaces the current chain."
                        : "The audio engine is not running, so the chain will be left out.")
        }
        let clashes = collisions(contents)
        if clashes > 0 {
            text.append(amount(clashes, "preset") + " here with the same name will be replaced.")
        }
        return text.joined(separator: " ")
    }

    /// ファイルの中に、手元と同じ名前がいくつ在るか。入れると置き換わる。
    private func collisions(_ contents: ETBackup.Contents) -> Int {
        let mine = Set(PresetStore.shared.names)
        var n = contents.presets.keys.filter { mine.contains(trimmed($0)) }.count

        // 入れ物の鍵は normalize 済み（EffectPresetStore.merge）なので、
        // 突き合わせる側も同じ形にしてから引く。
        let saved = EffectPresetStore.shared.saved
        for (effect, presets) in contents.effectPresets {
            let here = Set(saved[trimmed(effect)] ?? [])
            n += presets.keys.filter { here.contains(trimmed($0)) }.count
        }
        return n
    }

    private func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "1 effect" / "3 effects"。
    private func amount(_ n: Int, _ noun: String) -> String {
        n == 1 ? "1 \(noun)" : "\(n) \(noun)s"
    }

    /// 入れて、何が入ったかの 1 行を返す。
    private func apply(_ contents: ETBackup.Contents) -> String {
        var parts: [String] = []
        var engineDown = false

        // **ready を見る。** replaceChain は ready でなければ何もしないので、
        // 見ないと「入れた」と書いたのに鎖が変わっていないことになる。
        if !contents.chain.isEmpty {
            if dsp.ready {
                dsp.replaceChain(with: contents.chain)
                // 鎖に載っている IR を入れ直す。畳んだカードにはビューが無いので
                // DSP 側で呼ぶ（EffeTuneDSP.swift:406、restore() の第一の枝と同じ）。
                dsp.reloadAssets()
                parts.append(amount(contents.chain.count, "effect"))
            } else {
                engineDown = true
            }
        }

        let presets = PresetStore.shared.merge(contents.presets)
        if presets > 0 { parts.append(amount(presets, "preset")) }

        let effectPresets = EffectPresetStore.shared.merge(contents.effectPresets)
        if effectPresets > 0 { parts.append(amount(effectPresets, "effect preset")) }

        var line = parts.isEmpty ? "" : "Imported " + parts.joined(separator: ", ") + "."

        // **ファイルのせいにしない。**落ちたのはエンジンが立っていないからで、
        // ファイルは読めている。少し待って押し直せば通る。
        if engineDown {
            let why = "The audio engine is not running, so the chain was not imported."
            line = line.isEmpty ? why : line + " " + why
        }

        return line.isEmpty ? "Nothing in that file could be used." : line
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
                 through the EffectDeck output in Control Center.
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

// MARK: - 書き出すファイル

/// .fileExporter へ渡す入れ物。中身は ETBackup が作った JSON そのまま。
///
/// 読む側では使わない。取り込みは .fileImporter が URL をくれるので、
/// SettingsView が自分で Data にして ETBackup.read へ渡す。
private struct ETBackupDocument: FileDocument {

    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        data = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
