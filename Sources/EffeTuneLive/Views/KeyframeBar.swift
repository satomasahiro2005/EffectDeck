//  KeyframeBar.swift
//  音量に追従するカードの頭に出す、キーフレームの切り替え。
//
//  標準の部品だけ。分節の Picker でキーフレームを選び、「+」の Menu で足す。
//  消すのは同じ Menu の底に置く（Remove 50%）。カードの並べ替えは祖先の長押しで動くので、
//  この帯に長押しのメニューは付けない。
//  **音は選んだキーフレームに替わらない。**鳴るのはいつも今の音量の補間（EffeTuneDSP.selectKeyframe）。
//  説明の字は置かない。
//
//  **字は英語のまま。**アプリの残りに揃える（String Catalog は作らない。ConnectionTipsView と同じ規則）。
//  日本語の用意: 音量に追従 / キーフレーム / キーフレームを追加 / %@を削除（カタログを入れる時まで保留）。

import SwiftUI

struct ETKeyframeBar: View {
    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP
    /// 「+」の既定の位置に、いまの音量を使う。
    @ObservedObject private var volume = ETVolumeFollower.shared
    /// PC の鎖を編集している間は触らせない（そのあいだ追従は動かない）。
    @ObservedObject private var remote = RemoteMirror.shared

    var body: some View {
        if let a = node.automation {
            HStack(spacing: 8) {
                Picker("Keyframe", selection: Binding(
                    get: { a.selected },
                    set: { dsp.selectKeyframe($0, at: index) })) {
                    ForEach(a.keyframes.indices, id: \.self) { k in
                        Text(a.source.label(a.keyframes[k].position)).tag(k)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Menu {
                    let suggested = a.defaultAddPosition(current: volume.position)
                    ForEach(a.freePositions(), id: \.self) { position in
                        Button {
                            dsp.addKeyframe(position: position, at: index)
                        } label: {
                            if position == suggested {
                                // いまの音量に近い位置に、スピーカーの印を付ける。
                                Label(a.source.label(position), systemImage: "speaker.wave.2.fill")
                            } else {
                                Text(a.source.label(position))
                            }
                        }
                    }
                    Divider()
                    Button(role: .destructive) {
                        dsp.removeSelectedKeyframe(at: index)
                    } label: {
                        Label("Remove \(a.source.label(a.keyframes[a.selected].position))",
                              systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .menuOrder(.fixed)
                // 中に「足す」も「消す」もあるので、VoiceOver には中立の名前を付ける。
                .accessibilityLabel("Keyframes")
            }
            .disabled(remote.isRemote)
        }
    }
}
