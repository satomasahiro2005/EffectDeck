//  ConnectionTipsView.swift
//  こちらから直せない iOS 側の制約と、その外し方。issue 1 本につき 1 節。
//
//  **説明はこの画面にだけ置く。**他の画面には入口の札が 1 つずつあるだけ
//  （Settings の Known limitations と ConnectBanner の Help）。footer や注記は足さない。
//
//  **日英はこのファイルの中だけで持つ。**アプリの残りは英語のまま。
//  String Catalog も Localizable.strings も作らない。言語は
//  Locale.preferredLanguages の先頭で決める。Bundle.main.preferredLocalizations は
//  バンドルに en しか無いので常に en を返す。
//
//  字は全部 Text(verbatim:) で渡す。LocalizedStringKey として引かせない。
//
//  **押しても push しない。**リンクは Safari を開くだけなので、
//  Settings のシートの中でも 1 段で済む（LicensesView の頭と同じ理由）。

import SwiftUI

struct ConnectionTipsView: View {
    /// 言語はここで決めて、題・本文・リンク・読み上げで揃える。
    private let ja = ETTips.isJapanese

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
                    // **読み上げでは題を付ける。**見た目の字だけだと同じリンクが 4 本並ぶ。
                    .accessibilityLabel(Text(verbatim: ja ? "\(c.title)。GitHub の説明（英語）"
                                                          : "\(c.title), details on GitHub"))
                }
            }
        }
        .navigationTitle(Text(verbatim: ja ? ETTips.pageTitle.ja : ETTips.pageTitle.en))
        .navigationBarTitleDisplayMode(.inline)
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
    static var isJapanese: Bool { Locale.preferredLanguages.first?.hasPrefix("ja") ?? false }

    /// **口語にしない。**題も本文も落ち着いた語で書く（真面目な道具として出している）。
    static let pageTitle = (en: "Known limitations", ja: "接続に関する既知の制限")
    static let linkLabel = (en: "Details (GitHub)", ja: "詳細（GitHub・英語）")

    /// **よく当たる順。**#2 は 2026.09.17 から上げた人にしか起きないので最後。
    /// 09.17 のままの人がいなくなったら消してよい。
    static let all: [ETTip] = [
        ETTip(issue: 1,
              en: .init(title: "Output reverts right after selection",
                        act: "Keep playback running for a few seconds, then select EffectDeck again. "
                           + "The same applies if it reverts after pausing and resuming.",
                        why: "iOS may not accept a switch to EffectDeck until playback has run "
                           + "for a few seconds."),
              ja: .init(title: "選択直後に元の出力先へ戻る",
                        act: "再生を数秒続けてからもう一度 EffectDeck を選択してください。一時停止から再開した際に外れた場合も同様です。",
                        why: "iOS は再生開始から数秒が経過するまで EffectDeck への切り替えを受け付けない場合があります。")),
        ETTip(issue: 4,
              en: .init(title: "Spotify does not stay connected",
                        act: "Close Spotify in the App Switcher and reopen it, then select "
                           + "EffectDeck while a track without a Canvas is playing.",
                        why: "After a track with a Canvas (the short video behind the player) has "
                           + "played, iOS treats Spotify's playback as video until Spotify is restarted."),
              ja: .init(title: "Spotify で接続が維持されない",
                        act: "アプリスイッチャーで Spotify を終了して再度起動し、Canvas のない曲を再生している間に EffectDeck を選択してください。",
                        why: "Canvas（再生画面の背景に表示される短い動画）のある曲を一度再生すると、Spotify を再起動するまで iOS はその再生を動画として扱います。")),
        ETTip(issue: 3,
              en: .init(title: "YouTube video playback does not connect",
                        act: "Play music in YouTube Music with Song selected. For video, closing "
                           + "YouTube and reopening it before selecting EffectDeck may allow a "
                           + "temporary connection.",
                        why: "When iOS treats YouTube's playback as video, it returns the output "
                           + "to the previous device."),
              ja: .init(title: "YouTube の動画再生中に接続できない",
                        act: "音楽は YouTube Music の「曲」表示で再生してください。動画の場合は YouTube を終了して再度起動してから選択すると、一時的に接続できることがあります。",
                        why: "iOS は YouTube の再生を動画として扱うと出力先を元に戻します。")),
        ETTip(issue: 2,
              en: .init(title: "No audio after updating from 2026.09.17",
                        act: "If EffectDeck can be selected but no audio arrives, restart the iPhone once.",
                        why: "EffectDeck's registration details changed in 2026.09.18, and iOS "
                           + "reads them only at startup."),
              ja: .init(title: "2026.09.17 からの更新後に音声が届かない",
                        act: "EffectDeck を選択できるのに音声が届かない場合は、iPhone を一度再起動してください。",
                        why: "2026.09.18 で変更された EffectDeck の登録情報は、iPhone の起動時にのみ読み込まれます。")),
    ]
}
