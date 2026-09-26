//  ConnectionTipsView.swift
//  こちらから直せない iOS 側の制約と、その外し方。
//  issue 1 本につき 1 節、最後に共通の手順（番号付き 3 段）。
//
//  **手順の節にはリンクを付けない。**どの issue にも属さない。
//
//  **説明はこの画面にだけ置く。**他の画面には入口の札が 1 つずつあるだけ
//  （Settings の Known limitations と ConnectBanner の Help）。footer や注記は足さない。
//
//  **日英はこのファイルの中だけで持つ。**アプリの残りは英語のまま。
//  String Catalog も Localizable.strings も作らない。
//
//  **言語はバーの真ん中のセグメントで選ばせる。**Settings の面の切り替えと同じ部品。
//  選んだ側を "tips.language"（"en" / "ja"）に残す。一度も選んでいなければ
//  Locale.preferredLanguages の先頭で決める。
//  先頭だけで決めていたころは、端末を英語のまま使っている日本の人（en-JP）が
//  日本語に辿り着けなかった。Bundle.main.preferredLocalizations は
//  バンドルに en しか無いので常に en を返す。
//
//  字は全部 Text(verbatim:) で渡す。LocalizedStringKey として引かせない。
//
//  **押しても push しない。**リンクは Safari を開くだけなので、
//  Settings のシートの中でも 1 段で済む（LicensesView の頭と同じ理由）。

import SwiftUI

struct ConnectionTipsView: View {
    /// 選んだ側だけ覚える。**一度も選んでいなければ nil** で、端末の言語に従う。
    @AppStorage("tips.language") private var chosen: ETTips.Language?

    /// 言語はここで決めて、題・本文・リンク・読み上げで揃える。
    private var ja: Bool { (chosen ?? ETTips.defaultLanguage) == .ja }

    var body: some View {
        List {
            ForEach(ETTips.all) { tip in
                let c = ja ? tip.ja : tip.en
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        // 題は ETNoticeRow と同じ字の大きさ。
                        Text(verbatim: c.title)
                            .font(.system(size: 15, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        Text(verbatim: c.act)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(verbatim: c.why)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                    Link(destination: tip.url) {
                        Text(verbatim: ja ? ETTips.linkLabel.ja : ETTips.linkLabel.en)
                    }
                    .font(.footnote)
                    // **読み上げでは題を付ける。**見た目の字だけでは同じリンクが 3 本並ぶ。
                    // 見た目の字も残す（音声コントロールはその字で押す）。
                    .accessibilityLabel(Text(verbatim: ja ? "\(c.title)。\(ETTips.linkLabel.ja)"
                                                          : "\(c.title), details on GitHub"))
                }
            }
            // **最後に共通の手順。**どの節にも当てはまらないときに上から順に試す。
            // Canvas の曲はこの手順では直らないので、節より先に置かない。
            Section {
                let p = ja ? ETTips.procedure.ja : ETTips.procedure.en
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: p.title)
                        .font(.system(size: 15, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(Array(p.steps.enumerated()), id: \.offset) { i, step in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(verbatim: "\(i + 1).")
                                .monospacedDigit()
                            Text(verbatim: step)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.subheadline)
                        // 番号と本文を 1 回で読ませる。
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // **Settings の面の切り替えと同じ部品を同じ場所に置く**（SettingsView の toolbar）。
            // 行の頭に置いていたころは、同じアプリの中で切り替えが 2 通りの見た目になっていた。
            // principal は題の場所なので題は持たない。Settings も持っていない。
            // Done はシートを出す側（PipelineView）が足す。Settings から押したときは戻るだけ。
            // セグメントは UISegmentedControl で Menu ではない（SettingsRows.swift の頭）。
            ToolbarItem(placement: .principal) {
                Picker("", selection: Binding(get: { chosen ?? ETTips.defaultLanguage },
                                              set: { chosen = $0 })) {
                    Text(verbatim: "English").tag(ETTips.Language.en)
                    Text(verbatim: "日本語").tag(ETTips.Language.ja)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }
}

private struct ETTip: Identifiable {
    let issue: Int
    let en: Copy
    let ja: Copy
    var id: Int { issue }
    var url: URL { URL(string: "https://github.com/satomasahiro2005/EffectDeck/issues/\(issue)")! }

    /// 題・やること・理由を 1 つずつ。**理由は 1 節まで。**詳しい話は issue にある。
    struct Copy {
        let title, act, why: String
    }
}

/// **修飾子を付けない。**private にすると同じファイルの ConnectionTipsView からも
/// 見えなくなる。ファイルの外へ出さないのは、この enum 自体の private が受け持つ。
private enum ETTips {
    /// 値はそのまま "tips.language" に入る字。
    enum Language: String { case en, ja }

    /// **既定を広げない。**地域（JP）や 2 番目以降の言語は見ない。
    /// 外れてもバーのセグメントで 1 回選べば直る。
    static var defaultLanguage: Language {
        (Locale.preferredLanguages.first?.hasPrefix("ja") ?? false) ? .ja : .en
    }

    /// **口語にしない。**題も本文も落ち着いた語で書く（真面目な道具として出している）。
    static let linkLabel = (en: "Details (GitHub)", ja: "詳細（GitHub・英語）")

    /// 題と手順。**軽い順に並べる。**先の段で直れば次へ進まない。
    /// 2026.09.17 から上げた後に音声が届かない件（#2）は 3 段目で直るので節を持たない。
    static let procedure = (
        en: (title: "If none of the above applies",
             steps: ["Restart the player app.",
                     "Restart EffectDeck.",
                     "Restart the iPhone."]),
        ja: (title: "上記のいずれにも当てはまらない場合",
             steps: ["プレイヤーアプリを再起動する",
                     "EffectDeckを再起動する",
                     "iPhoneを再起動する"])
    )

    /// **よく当たる順。**Canvas の 2 件は続けて置く。
    /// **止めている間に選んだら戻る、という節は置かない**（#1 の訂正）。
    /// 止めている間や何も鳴らしていない間に選んでも基本的に戻されない。
    /// 一時停止が原因と確かめた失敗は無い（A-10 の非動画の切断も mediaIsPlaying=YES だった）。
    /// **問題は接続する時に起きる。**題は「再生されない」でなく「接続できない」「接続が切れる」で書く。
    /// **日本語と英数字のあいだに空白を入れない。**
    static let all: [ETTip] = [
        ETTip(issue: 1,
              en: .init(title: "Spotify tracks with a Canvas cannot connect to EffectDeck",
                        act: "Select EffectDeck while a track without a Canvas is playing, "
                           + "or turn Canvas off in Spotify's settings.",
                        why: "iOS treats a track with a Canvas (the short video behind the player) "
                           + "as video."),
              ja: .init(title: "CanvasのあるSpotifyの曲はEffectDeckに接続できない",
                        act: "Canvasのついていない曲でEffectDeckを選択するか、Spotifyの設定でCanvasをオフにしてください。",
                        why: "iOSはCanvas（再生画面の背景に表示される短い動画）のある曲を動画として扱います。")),
        // #4 は Canvas と関係ない。Canvas の無い曲でも Spotify が動画を再生中と判定され、
        // Spotify のプロセスが変わると同じ曲で通った（issue #4 の本文）。
        ETTip(issue: 4,
              en: .init(title: "Spotify sometimes cannot connect to EffectDeck",
                        act: "Restart Spotify.",
                        why: "iOS sometimes treats Spotify as playing video even on a track "
                           + "without a Canvas. After a restart, the same track connects."),
              ja: .init(title: "SpotifyがEffectDeckに接続できないことがある",
                        act: "Spotifyを再起動してください。",
                        why: "iOSはCanvasのない曲でもSpotifyを動画の再生中と判定することがあります。再起動すると同じ曲でも接続できます。")),
        ETTip(issue: 3,
              en: .init(title: "Playing a YouTube video disconnects EffectDeck",
                        act: "Restart YouTube, then play the video.",
                        why: "When iOS treats YouTube as playing video, it disconnects EffectDeck. "
                           + "After a restart, the same video may stay connected."),
              ja: .init(title: "YouTubeの動画を再生するとEffectDeckとの接続が切れる",
                        act: "YouTubeを再起動してから、動画を再生してください。",
                        why: "iOSがYouTubeを動画の再生中として扱うと、EffectDeckとの接続が切れます。YouTubeを再起動すると、同じ動画でも接続が続く場合があります。")),
    ]
}
