//  AcknowledgementsView.swift
//  借りているものへの礼と、その条文。
//
//  外へリンクを張らず本文を同梱する。配布物の中身と表示が食い違わないようにするため。
//
//  **本文をさらに push しない。** ここはシートの中で、Settings から数えて 1 回目の
//  push に当たる。ここからもう 1 回潜ると、戻り方が分からなくなる（HIG Modality）。
//  代わりに行をその場で開く。開くのは階層ではないので、戻る場所を失わない。
//  条文を別の画面に分けなかったのもこれが理由。
//
//  **礼を先、条文を後。**以前は Open source licenses という 1 行で、開くと
//  機械が吐いた条文だけが並んでいた。条文は義務で、読みに来る人はほとんど居ない。
//  誰の何の上に乗っているのかは名前で言うべきなので、短い礼を上に置いて、
//  条文はその下に畳む。

import SwiftUI

/// 礼を言う相手。**条文（ETLicenses）とは別に書く。**
/// 向こうは Tools/gen_licenses.py が置き場から作るもので、名前と条文しか持たない。
/// 「何をしてもらっているか」は人が書くしかない。
///
/// 並びは、このアプリにとって欠かせない順。
private struct ETCredit: Identifiable {
    var id: String { name }
    let name: String
    let who: String
    let what: String
}

private let ETCredits: [ETCredit] = [
    ETCredit(name: "EffeTune",
             who: "Yoshiyuki Kobayashi",
             what: "Every effect here is EffeTune's own DSP, running unmodified. This app puts it on iOS; the sound is theirs."),
    ETCredit(name: "ysfx",
             who: "Jean Pierre Cimalando, Joep Vanlier and contributors",
             what: "Runs JSFX scripts outside REAPER, which is what lets you drop your own .jsfx into the chain."),
    ETCredit(name: "JSFX, WDL and EEL2",
             who: "Cockos Incorporated",
             what: "The language those scripts are written in, and the small interpreter underneath it."),
    ETCredit(name: "PFFFT",
             who: "Julien Pommier",
             what: "The FFT behind the analyzers and the convolution reverb."),
]

struct AcknowledgementsView: View {
    var body: some View {
        List {
            Section {
                ForEach(ETCredits) { credit in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(credit.name)
                            .font(.system(size: 15, weight: .medium))
                        Text(credit.who)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text(credit.what)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Thanks to")
            } footer: {
                // 名前を出すことと、認めてもらっていることは別。
                // About の footer と同じ断りをここでも 1 行だけ置く。
                Text("Named here because this app is built on their work, not because they are involved in it.")
            }

            Section {
                ForEach(ETLicenses) { item in
                    DisclosureGroup {
                        Text(item.text)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name)
                                .font(.system(size: 15, weight: .medium))
                            Text("\(item.license) · \(item.author)")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Licenses")
            }
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }
}
