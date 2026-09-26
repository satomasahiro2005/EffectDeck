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
             steps: ["Restart the app that is playing: close it in the App Switcher and open it again.",
                     "Restart EffectDeck.",
                     "Restart the iPhone."]),
        ja: (title: "上記のいずれにも当てはまらない場合",
             steps: ["再生しているアプリを再起動する（アプリスイッチャーで終了して再度開く）",
                     "EffectDeck を再起動する",
                     "iPhone を再起動する"])
    )

    /// **よく当たる順。**Canvas の 2 件は続けて置く。
    /// **止めている間に選んだら戻る、という節は置かない**（#1 の訂正）。
    /// 止めている間や何も鳴らしていない間に選んでも基本的に戻されない。
    /// 一時停止が原因と確かめた失敗は無い（A-10 の非動画の切断も mediaIsPlaying=YES だった）。
    /// **#1 でも Spotify の再起動まで書く。**Canvas の曲を鳴らした後は #4 の状態が残る。
    static let all: [ETTip] = [
        ETTip(issue: 1,
              en: .init(title: "Spotify tracks with a Canvas do not play through EffectDeck",
                        act: "Turn Canvas off in Spotify's settings, then close Spotify in the "
                           + "App Switcher and open it again.",
                        why: "iOS treats a track with a Canvas (the short video behind the player) "
                           + "as video."),
              ja: .init(title: "Canvas のある Spotify の曲は EffectDeck で再生されない",
                        act: "Spotify の設定で Canvas をオフにしてから、アプリスイッチャーで Spotify を終了して再度開いてください。",
                        why: "iOS は Canvas（再生画面の背景に表示される短い動画）のある曲を動画として扱います。")),
        ETTip(issue: 4,
              en: .init(title: "After a track with a Canvas, other Spotify tracks do not play "
                             + "through EffectDeck either",
                        act: "Close Spotify in the App Switcher and open it again.",
                        why: "Once a track with a Canvas has played, iOS treats Spotify's playback "
                           + "as video until Spotify is restarted."),
              ja: .init(title: "Canvas のある曲を再生した後は Spotify の他の曲も EffectDeck で再生されない",
                        act: "アプリスイッチャーで Spotify を終了して再度開いてください。",
                        why: "Canvas のある曲を一度再生すると、iOS は Spotify を再起動するまでその後の再生も動画として扱います。")),
        ETTip(issue: 3,
              en: .init(title: "YouTube video does not play through EffectDeck",
                        act: "For music, use YouTube Music with Song selected. For video, "
                           + "restarting YouTube may allow a temporary connection.",
                        why: "iOS does not hand video playback to EffectDeck."),
              ja: .init(title: "YouTube の動画は EffectDeck で再生されない",
                        act: "音楽は YouTube Music で「曲」を選択して再生してください。動画は YouTube を再起動すると一時的に接続できる場合があります。",
                        why: "iOS は動画の再生を EffectDeck へ渡しません。")),
    ]
}
