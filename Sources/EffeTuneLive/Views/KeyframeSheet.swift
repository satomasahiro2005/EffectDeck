//  KeyframeSheet.swift
//  音量に追従するカードの値を、キーフレーム1つにつきカード1枚で並べるシート（カードの ⋯ の Follow Volume…）。
//
//  カードの中身は普通のカードと同じ画面（ETEffectBody）で、そのキーフレームの値だけを見せて直す。
//  75% のカードを直すと 75% のキーフレームだけが変わる。全部が同時に見えて、同時に直せる。
//  画面の部品は index と node しか見ないので、ETSlotAddress.keyframe の番号と、その値を載せた段
//  （EffeTuneDSP.node(at:)）を渡す。DSP の口は番号からキーフレームへ書く。
//  **音はキーフレームに替わらない。**鳴るのはいつも今の音量の補間（直しても試聴にならない）。
//  カードは音量の低い順。「+」は空いている5%の位置に足す（いまの音量の近くが既定）。
//  最後の1枚を消すと追従をやめ、その値がパイプラインのカードの普通の値になる。
//  追従していないカードで開くと、いまの音量に1枚目を作って今の値を載せる（空のシートを出さない）。
//  その1枚だけで何も直さずに閉じたら、追従をやめて元に戻す（開いただけで追従にしない）。
//  説明の字は置かない。
//
//  **字は英語のまま。**アプリの残りに揃える（String Catalog は作らない。ConnectionTipsView と同じ規則）。
//  日本語の用意: 音量に追従 / キーフレームを追加 / 音量 / 削除（カタログを入れる時まで保留）。

import SwiftUI

struct ETKeyframeSheet: View {
    @Environment(\.dismiss) private var dismiss

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP
    /// 「+」の既定の位置に、いまの音量を使う。
    @ObservedObject private var volume = ETVolumeFollower.shared
    /// PC の鎖を編集している間は触らせない（そのあいだ追従は動かない）。
    @ObservedObject private var remote = RemoteMirror.shared

    /// 開いたときに1枚目を作ったなら、その時の値。閉じるときに、直していなければ追従をやめる。
    @State private var startedValues: [Float]?

    /// 開いている間に直した最新の段。渡された写しは開いた時点のもの。
    private var current: EffeTuneDSP.Node { dsp.node(at: index) ?? node }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let a = current.automation {
                    // 位置を id にする。消したときに、別のカードへ @State が移らないように。
                    LazyVStack(spacing: 10) {
                        ForEach(Array(a.keyframes.enumerated()), id: \.element.position) { item in
                            ETKeyframeCard(index: index, keyframe: item.offset,
                                           label: a.source.label(item.element.position),
                                           node: current, dsp: dsp)
                        }
                    }
                    .frame(maxWidth: ETLayout.detailMaxWidth)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                }
            }
            .disabled(remote.isRemote)
            .onAppear(perform: startIfNeeded)
            .onDisappear(perform: undoIfUntouched)
            .navigationTitle("Follow Volume")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) { addMenu }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func startIfNeeded() {
        guard current.automation == nil, ETAutomation.isAutomatable(current), !remote.isRemote,
              let position = ETAutomation.addChoices(nil, current: volume.position).suggested
        else { return }
        startedValues = current.values
        dsp.addKeyframe(position: position, at: index)
    }

    private func undoIfUntouched() {
        guard let start = startedValues, let a = current.automation,
              a.keyframes.count == 1, a.keyframes[0].values == start else { return }
        dsp.removeKeyframe(0, at: index)
    }

    private var addMenu: some View {
        let choices = ETAutomation.addChoices(current.automation, current: volume.position)
        let source = current.automation?.source ?? .outputVolume
        return Menu {
            ForEach(choices.free, id: \.self) { position in
                Button {
                    dsp.addKeyframe(position: position, at: index)
                } label: {
                    if position == choices.suggested {
                        // いまの音量に近い位置に、スピーカーの印を付ける。
                        Label(source.label(position), systemImage: "speaker.wave.2.fill")
                    } else {
                        Text(source.label(position))
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Add Keyframe")
        .disabled(choices.free.isEmpty || remote.isRemote)
    }
}

/// キーフレーム1つぶんのカード。題は音量（"75%"）、⋯ に音量の変更・プリセット・既定へ戻す・削除。
private struct ETKeyframeCard: View {
    let index: Int
    let keyframe: Int
    let label: String
    /// 元の段（追従している）。
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    @State private var presets = false

    var body: some View {
        let address = ETSlotAddress.keyframe(slot: index, index: keyframe).raw
        if let shown = dsp.node(at: address) {
            Card(block: .alone) {
                VStack(alignment: .leading, spacing: 0) {
                    header(address: address)
                    ETEffectBody(index: address, node: shown, dsp: dsp)
                        .padding(ETMetrics.cardPadding)
                }
            }
            .sheet(isPresented: $presets) {
                EffectPresetsView(index: address, spec: node.spec, dsp: dsp)
            }
        }
    }

    private func header(address: Int) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 16, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            Menu {
                volumeMenu
                Button { presets = true } label: {
                    Label("Effect Presets", systemImage: "bookmark")
                }
                Button { dsp.resetParams(at: address) } label: {
                    Label("Reset Parameters", systemImage: "arrow.counterclockwise")
                }
                Divider()
                Button(role: .destructive) {
                    dsp.removeKeyframe(keyframe, at: index)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
        }
        .padding(.leading, ETMetrics.cardPadding)
        .padding(.trailing, 4)
        .padding(.vertical, 10)
    }

    /// 音量の変更。空いている5%の刻みと、いまの位置だけ（塞がっている位置へは動かせない）。
    @ViewBuilder
    private var volumeMenu: some View {
        if let a = node.automation, a.keyframes.indices.contains(keyframe) {
            let position = a.keyframes[keyframe].position
            Picker(selection: Binding(
                get: { position },
                set: { dsp.moveKeyframe(keyframe, to: $0, at: index) })) {
                ForEach((a.freePositions() + [position]).sorted(), id: \.self) { p in
                    Text(a.source.label(p)).tag(p)
                }
            } label: {
                Label("Volume", systemImage: "speaker.wave.2")
            }
            .pickerStyle(.menu)
        }
    }
}
