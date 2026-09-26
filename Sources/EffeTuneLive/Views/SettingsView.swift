//  SettingsView.swift
//  右上の ⋯ から出す 1 枚。EffeTune も設定は右上に置いてある。
//
//  **画面は 1 枚。押して進むのは 1 段だけ（Licenses・Report a problem・Known limitations）。**
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
                    // **Status の中に入れない。**あちらは 3.3Hz で作り直されるので、
                    // 押して進む行を置くと提示の途中で作り直すことになる。
                    // 説明は開いた先にだけ書く。ここは札 1 行。
                    Section {
                        NavigationLink("Known limitations") { ConnectionTipsView() }
                    }
                    // **音 → 電池 → 見た目 → 数字の順に並べる。**
                    // 以前は Processing と Power のあいだに見た目の設定
                    // （Sync Visuals・JSFX canvas）が挟まっていて、音の話が
                    // 2 つに割れていた。種類ごとに固めて、読むだけの数字を末尾に置く。
                    processing
                    power
                    graphs
                    plugins
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

    /// **絵の話。**音そのものは変わらない。見出しの無い節だったので、
    /// 上の Power とも下の Plug-ins とも切れておらず、どこまでが何の設定か
    /// 読めなかった。名前を付けて、同じ見た目の設定である Plug-ins と並べる。
    private var graphs: some View {
        Section {
            Toggle("Sync Visuals to Audio", isOn: $prefs.syncVisualsToAudio)
        } header: {
            Text("Graphs")
        } footer: {
            Text("Delay graphs to match the audio output latency.")
        }
    }

    // JSFX が無い版ではこの節ごと消える（ETJSFXHost.isEnabled）。
    // 節の中身が JSFX の設定 1 つしか無いので、空の見出しだけが残らないようにする。
    @ViewBuilder
    private var plugins: some View {
        if ETJSFXHost.isEnabled {
            pluginsSection
        }
    }

    private var pluginsSection: some View {
        Section {
            ETSegmentedChoice(title: "JSFX canvas",
                              values: ETJSFXCanvasMode.allCases,
                              label: \.label,
                              selection: $prefs.jsfxCanvasMode)
        } header: {
            Text("Plug-ins")
        } footer: {
            Text("Adaptive scales the canvas up to fill the card. Pixel Perfect stops at one canvas pixel per screen pixel, so most canvases look smaller and sharper. Either way the whole canvas stays on screen.")
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
            // **Special Thanks はまだ置かない。**一度 4 件（EffeTune / ysfx /
            // JSFX・WDL・EEL2 / PFFFT）を並べたが、全部ライブラリで、下の
            // Licenses が作者名つきで既に出しているものだった。EffeTune は
            // この節の footer でも名指ししている。名前が重なるだけで、
            // 読んで増えるものが無い。
            //
            // 載せたいのは**人**（Twitter で不具合を知らせてくれた人）。
            // その人がライブラリの下に並ぶのは性質が違う。最初の 1 人が
            // 出たときに、人だけのページとして作る。
            NavigationLink("Licenses") { LicensesView() }
        } header: {
            Text("About")
        } footer: {
            // **権利の話はここで終える。**Privacy policy を押せる行にすると、
            // 版と並んで「設定の項目」に見える。読む物なので、同じ段落の続きに
            // リンクとして置く（Text の markdown リンクはそのまま開く）。
            Text("""
                 The effects are EffeTune's own DSP by Yoshiyuki Kobayashi, running \
                 unmodified under the MIT license. This app is a separate project by \
                 nemut.ai. It is not affiliated with, endorsed by, or supported by \
                 EffeTune or its author. \
                 [Privacy policy](https://nemut.ai/effetune-live/privacy.html)
                 """)
        }

        // **問い合わせ先をここに置く。**
        // 置かないと、困った人は EffeTune の作者に聞きに行く。
        // 向こうはこのアプリを作っていないので答えようがない。
        //
        // **道具をこの節に並べない。**以前は Contact という見出しの下に
        // 報告先 2 つ・Attach log・Copy details・Privacy policy の 5 行が
        // 並んでいた。連絡先はそのうち 2 行だけで、残りは連絡ではない。
        // 見出しと中身が合っていないので、何をさせたい節なのか読めなかった。
        //
        // いまは「報告する」という 1 つの用に対して 1 行。行き先の選択も
        // ログの添え方も、報告すると決めた人だけが入る画面（ETReportView）へ
        // 送る。押す手数は 1 つ増えるが、増えるのは本気で報告する人だけ。
        Section {
            NavigationLink("Report a problem") {
                ETReportView(io: io, dsp: dsp, prefs: prefs)
            }
            // **軽いほうの口。**GitHub の口座を持っていない人と、
            // 「なんか変」までしか言えない段階の話はここへ来る。
            //
            // **上の報告先と同じ節には入れない。**診断もログも付かないので、
            // Where to send it に並べると、いちばん押しやすい口がいちばん
            // 情報の付かない口になる。報告すると決めた人は上の行へ入るので、
            // こちらはその下に 1 行だけ置く。
            ETReportDestinationButton(title: "Ask on Twitter", detail: "@ainemut") {
                URL(string: "https://twitter.com/ainemut")
            }
        } header: {
            Text("Feedback")
        } footer: {
            Text("Report a problem opens with the diagnostics already filled in.")
        }

        // 名前が 1 つも無いうちは節ごと出さない。
        if !ETReporterThanks.isEmpty {
            Section {
            } footer: {
                Text(ETReporterThanks.line)
            }
        }
    }
}

/// **知らせてくれた人への礼。**
///
/// **コントリビューターは載せない。**線は「GitHub が記録するか」で引いている。
/// PR を送った人は commit とコントリビューターの一覧に名前が永久に残るので、
/// アプリに重ねて出す必要が無い。Twitter で知らせてくれた人はどこにも残らない
/// （#3 も #5 も本文は "A user reported…" で、issue を立てたのはこちら）。
/// あとから PR が来ても、この規則なら迷わない。
///
/// **画面を作らない。**2 人のために 1 枚作ると、名前より器のほうが大きくなる。
/// 一覧のいちばん下に小さい 1 行だけ置く。増えたら節へ昇格させればよい。
///
/// 番号は押せる。名前だけだと何を見つけた人なのか分からないが、文で説明すると
/// 1 行に収まらない。issue を開かせれば、こちらが書く字は増えない。
enum ETReporterThanks {

    /// 載せる前に**本人の了解を取る。**報告した時点では、公開アプリに名前が
    /// 出ることを想定していない。
    static let people: [(handle: String, issue: Int)] = [
    ]

    static var isEmpty: Bool { people.isEmpty }

    private static let issues = "https://github.com/satomasahiro2005/EffectDeck/issues/"

    /// markdown を自分で組んで `AttributedString` にする。
    /// **`Text` の markdown は文字列リテラルのときだけ効く。**組み立てた字を
    /// `LocalizedStringKey` に入れてもリンクにならない。
    static var line: AttributedString {
        let names = people.map {
            "[@\($0.handle)](https://twitter.com/\($0.handle)) ([#\($0.issue)](\(issues)\($0.issue)))"
        }
        let joined: String
        switch names.count {
        case 0:  return AttributedString("")
        case 1:  joined = names[0]
        default: joined = names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
        let text = "Thanks to \(joined) for the detailed bug reports."
        return (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}

// MARK: - 報告する

/// 報告すると決めた人だけが入る画面。
///
/// **行き先を先に、道具を後に。**やることは「報告先を選ぶ → 必要ならログを添える」
/// なので、報告先を上に、道具を下に置く。以前は Copy details と Attach log が
/// 先頭に並んでいて、報告する口はその下に隠れていた。道具が先に来ると、
/// 何をさせたい画面なのか読めない。
///
/// **Copy details を先に押させない。**本文には診断もログの末尾も
/// ETReportLink が既に詰めている。貼り直しは要らないので、Copy details は
/// 本文に入りきらなかったぶんを自分で足したい人のための道具として下に置く。
///
/// io は観測しない。押した瞬間に ETDiagnostics を作るので要らない。
private struct ETReportView: View {
    let io: AudioIO
    let dsp: EffeTuneDSP
    let prefs: Preferences

    var body: some View {
        List {
            // **本文を先に詰めて開く。**押してから診断を貼らせると、たいてい
            // 何も付かない報告が来る。1 MB のログは URL に載らないので、
            // 入るだけの直近ぶんと「添付してほしい」の 1 行を入れる。
            Section {
                ETReportDestinationButton(title: "Open an issue", detail: "GitHub") {
                    ETReportLink.github(ETDiagnostics.current(io: io, dsp: dsp, prefs: prefs).text)
                }
                ETReportDestinationButton(title: "Email", detail: "support@nemut.ai") {
                    ETReportLink.mail(ETDiagnostics.current(io: io, dsp: dsp, prefs: prefs).text)
                }
            } header: {
                Text("Where to send it")
            } footer: {
                Text("Either one opens with the diagnostics and the end of the log already written in.")
            }

            // **Copy details をここに置かない。**診断は上の 2 つが本文へ
            // 丸ごと詰めているので、貼り直しても足されるものが無い。
            // 並べると Attach log との違いが読めず、どちらを押す場面なのか
            // 決められなくなる（数字を自分で持ち出したい人のための Copy details は
            // Audio の Details に在る。数字が並んでいるのもあちら）。
            //
            // ここに残るのは、本文に入りきらないもの＝ログの全体だけ。
            Section {
                ETShareLogButton()
            } footer: {
                Text("Only a few kilobytes of the log fit in a link.")
            }
        }
        .navigationTitle("Report a problem")
        .navigationBarTitleDisplayMode(.inline)
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

/// 報告先を開く札。**URL は押した瞬間に組む。**
/// Link に渡す形だと body の評価が再描画のたびになり、走っている最中に動く数字が
/// 古いまま貼られる（About は io を観測していない）。
private struct ETReportDestinationButton: View {
    let title: String
    let detail: String
    let make: () -> URL?

    var body: some View {
        Button {
            if let url = make() { UIApplication.shared.open(url) }
        } label: {
            LabeledContent(title, value: detail)
        }
    }
}

/// 問題報告の宛先を、本文つきで組む。
///
/// **1 MB のログは本文に入らない。**GitHub は認証済みで 8153 バイトまで通り 8193 で 414、
/// 未認証の経路は 7042 バイトで 500（実測）。パーセント符号化で ASCII でも 1.5 倍、
/// 日本語混じりで 2.3 倍に膨らむので、URL に載る生ログは 2〜4 KB。
/// mailto は HTTP を通らないので同じ壁ではないが、受け入れ長は測っていないので同じ予算で切る。
/// 1 MB は添付（Attach log）でしか渡さない。
enum ETReportLink {

    /// URL 全体の予算。未認証の 7042 から余裕を取る。
    private static let budget = 6000

    /// `+` も符号化する。URLComponents は素通しするので、受け側で空白に化ける
    /// （同じ罠の対処が ETShareLink に在る）。
    private static func encode(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=?#")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    /// 診断と、予算に入るだけの直近のログ。
    private static func body(_ diagnostics: String) -> String {
        let head = """
            (Describe what happened here.)

            ---
            \(diagnostics)
            """
        var text = head
        let log = ETLogTap.text
        if !log.isEmpty {
            // 直近から入るだけ入れる。encode 後の長さで測る。
            var tail = String(log.suffix(4000))
            let marker = """


                --- log (tail) ---

                """
            while !tail.isEmpty && encode(text + marker + tail).count > budget {
                tail = String(tail.dropFirst(256))
            }
            if !tail.isEmpty {
                text += marker + tail
                text += """


                    (The full log is longer. Attach it with "Attach log" in Settings.)
                    """
            }
        }
        return text
    }

    static func github(_ diagnostics: String) -> URL? {
        URL(string: "https://github.com/satomasahiro2005/EffectDeck/issues/new"
            + "?title=" + encode("") + "&body=" + encode(body(diagnostics)))
    }

    static func mail(_ diagnostics: String) -> URL? {
        URL(string: "mailto:support@nemut.ai"
            + "?subject=" + encode("EffectDeck")
            + "&body=" + encode(body(diagnostics)))
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
///
/// **1 タップで共有シートまで出す。**以前は file が nil のあいだ "Prepare log" を
/// 出し、押すと同じ行が ShareLink（"Attach log"）に化けていた。押しても何も開かず
/// 名前だけ変わるので、何のための札か読めないまま 2 回押させていた。
/// ShareLink は item を先に要求するので、押した瞬間に書く形には使えない
/// （PresetsView で使えているのは、鎖の URL が押す前から在るから）。
/// Button で書いてから UIActivityViewController を出す。
///
/// **提示はこの札の中だけに付ける。**同じ View に提示を重ねると後から付けた方しか
/// 出ない（BackupSection.swift:17-20）。Contact 節の他の行には付けない。
private struct ETShareLogButton: View {
    /// 押した瞬間に作ったもの。終わったら nil に戻す（戻さないと次が開かない）。
    @State private var sharing: ETLogAttachment?

    var body: some View {
        if ETLogTap.byteCount > 0 {
            Button {
                // **押した瞬間に書く。**ログは走っている間も伸びるので、
                // 先に書いて持っておくと、開いたときには古い末尾が付く。
                //
                // **書けなくても共有シートは出す。**writeAttachment は一時置き場に
                // 書けなければ nil を返す。そこで黙って終わると、押しても何も
                // 起きない札に戻る。ファイルが作れないときは本文そのものを渡す。
                if let file = ETLogTap.writeAttachment() {
                    sharing = ETLogAttachment(items: [file])
                } else {
                    sharing = ETLogAttachment(items: [ETLogTap.text])
                }
            } label: {
                LabeledContent("Attach log", value: Self.size(ETLogTap.byteCount))
            }
            .sheet(item: $sharing) { attachment in
                ETActivityView(items: attachment.items) { sharing = nil }
            }
        }
    }

    private static func size(_ bytes: Int) -> String {
        bytes >= 1_000_000 ? String(format: "%.1f MB", Double(bytes) / 1_000_000)
                           : String(format: "%d KB", max(1, bytes / 1000))
    }
}

/// .sheet(item:) へ渡す入れ物。URL も String も Identifiable ではないので包む
/// （.fileExporter へ渡す入れ物が BackupSection に在るのと同じ理由）。
///
/// **id は毎回新しくする。**ログは同じ名前のファイルに上書きするので
/// （ETLogTap.writeAttachment）、URL を id にすると 2 回目を同じものと見なされて
/// 開かなくなる。
private struct ETLogAttachment: Identifiable {
    let id = UUID()
    let items: [Any]
}

/// 共有シート。ShareLink が item を先に要求するので、押してから中身を作る
/// ここだけ UIKit で出す。
private struct ETActivityView: UIViewControllerRepresentable {
    let items: [Any]
    /// 閉じたことを知らせる口。下の completionWithItemsHandler から呼ぶ。
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let sheet = UIActivityViewController(activityItems: items,
                                             applicationActivities: nil)
        // **終わりを自分で知らせる。**SwiftUI の提示の中身として出しているので、
        // 共有シート側が閉じても item の binding は立ったまま残る。
        // 戻さないと、次に押したときに開かない札になる。
        sheet.completionWithItemsHandler = { _, _, _, _ in onFinish() }
        // iPad は popover で出ようとする。出所を指していないと落ちるので、
        // シートの中に収まるよう自分の view を出所にしておく。
        sheet.popoverPresentationController?.sourceView = sheet.view
        return sheet
    }

    func updateUIViewController(_ sheet: UIActivityViewController, context: Context) {}
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
