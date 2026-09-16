//  ClipboardBanner.swift
//  クリップボードに URL らしきものが乗っているときに出す帯。
//  **鎖が乗っているかどうかは分からない。** 文言もそう書くこと。
//
//  effetune.frieve.com の共有リンクを、Safari から直接このアプリで開くことはできない。
//  Universal Links には apple-app-site-association をあの置き場に置く必要があって、
//  ドメインはこちらのものではないため。
//
//  代わりに、リンクをコピーしてアプリへ戻ってきたときに気づく形にした。
//  detectPatterns は**中身を読まずに**「URL らしきものが乗っているか」だけを見るので、
//  貼り付けの同意ダイアログが出ない。実際に読むのは PasteButton を押したときだけで、
//  これも同意ダイアログを出さずに済む（押したこと自体が同意になる）。

import SwiftUI
import UIKit

struct ClipboardBanner: View {
    @ObservedObject var dsp: EffeTuneDSP
    @State private var looksLikeLink = false
    @State private var failed = false

    var body: some View {
        Group {
            if looksLikeLink {
                Card {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: "link")
                            .font(.system(size: 17))
                            .foregroundStyle(.tint)
                            .frame(width: 22)

                        VStack(alignment: .leading, spacing: 2) {
                            // 中身は読んでいない。**「鎖が乗っている」とは言えない。**
                            // detectPatterns が見ているのは「URL らしきものがあるか」
                            // だけで、EffeTune のリンクかどうかは押すまで分からない。
                            Text(failed ? "That link had no chain in it"
                                         : "A link is on the clipboard")
                                .font(.system(size: 14, weight: .semibold))
                                .fixedSize(horizontal: false, vertical: true)
                            // 押すと今の鎖が消えることを、押す前に言う。
                            Text(failed ? "Copy an EffeTune share link and try again."
                                        : "Paste it to replace the current chain.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 4)

                        PasteButton(payloadType: String.self) { items in
                            guard let text = items.first else { return }
                            let loaded = ETShareLink.parse(text, catalog: ETCatalog)
                            if loaded.isEmpty {
                                failed = true
                            } else {
                                dsp.replaceChain(with: loaded)
                                looksLikeLink = false
                                failed = false
                            }
                        }
                        .labelStyle(.iconOnly)
                        .buttonBorderShape(.capsule)
                    }
                    .padding(12)
                }
            }
        }
        .onAppear { check() }
        // 戻ってきたら「読めなかった」を畳む。
        // 外で別のリンクをコピーしてきたかもしれず、それでも
        // detectPatterns の答えは URL のまま変わらないので、
        // 変化で判断すると古い失敗表示が居座る。
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didBecomeActiveNotification)) { _ in
            failed = false
            check()
        }
    }

    /// 中身は読まない。URL らしきものが乗っているかだけを見る。
    private func check() {
        UIPasteboard.general.detectPatterns(for: [.probableWebURL]) { result in
            let found = (try? result.get())?.contains(.probableWebURL) ?? false
            Task { @MainActor in
                if found != looksLikeLink { looksLikeLink = found }
            }
        }
    }
}
