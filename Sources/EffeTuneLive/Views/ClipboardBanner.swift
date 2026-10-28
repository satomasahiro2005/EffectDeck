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
    /// 貼った鎖で直したもの・落としたもの（ETChainText.Report.message）。空でなければ1行で出す。
    /// Presets → Import from clipboardと同じ。**黙って直さない。**
    @State private var note = ""
    /// 大きい文字サイズでは、字と貼り付けのボタンを縦に積む。
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                             : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        Group {
            if looksLikeLink {
                Card {
                    layout {
                        Image(systemName: "link")
                            // 大きさは Connect / Remote / Bypass の帯（icon 20・幅 26・題 15・説明 12・余白 14）に揃える。
                            .etFont(size: 20)
                            .foregroundStyle(.tint)
                            .frame(width: stacked ? nil : 26)

                        VStack(alignment: .leading, spacing: 2) {
                            // 中身は読んでいない。**「鎖が乗っている」とは言えない。**
                            // detectPatterns が見ているのは「URL らしきものがあるか」
                            // だけで、EffeTune のリンクかどうかは押すまで分からない。
                            Text(failed ? "That link had no chain in it"
                                         : "A link is on the clipboard")
                                .etFont(size: 15, weight: .semibold)
                                .fixedSize(horizontal: false, vertical: true)
                            // 押すと今の鎖が消えることを、押す前に言う。
                            if !failed {
                                Text("Pasting replaces the current chain.")
                                    .etFont(size: 12)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        if !stacked { Spacer(minLength: 4) }

                        PasteButton(payloadType: String.self) { items in
                            guard let text = items.first else { return }
                            // ChatGPTに作らせたリンクは`{"jsfx":"<名前>"}`の段を持つことがある（CHAIN.md）。
                            let checked = ETShareLink.parseChecked(
                                text, catalog: ETCatalog,
                                jsfx: ETJSFXHost.shared.chainResolver())
                            if checked.items.isEmpty {
                                failed = true
                            } else {
                                dsp.replaceChain(with: checked.items)
                                failed = false
                                // 知らせがあれば、閉じるまで帯を残す（知らせは帯に付いている）。
                                if checked.report.isEmpty {
                                    looksLikeLink = false
                                } else {
                                    note = checked.report.message
                                }
                            }
                        }
                        .labelStyle(.iconOnly)
                        .buttonBorderShape(.capsule)
                    }
                    .padding(14)
                }
                .alert("Chain imported", isPresented: Binding(
                    get: { !note.isEmpty },
                    set: { shown in
                        if !shown {
                            note = ""
                            looksLikeLink = false
                        }
                    })) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(note)
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
