//  OutputCorrectionView.swift
//  出力補正（Output Correction）の画面。中身は 1 つ（OutputCorrectionList）で、出し方が 2 つある。
//    - 鎖の下の出力補正の行から: 専用のシート（OutputCorrectionView。NavigationStack と Done を足す）
//    - Presets のシートの Output Correction の行から: Presets の NavigationStack の中へ押して進む
//      （OutputCorrectionList をそのまま。NavigationStack を入れ子にせず、Done も付けない。戻るのは < で）
//  鎖の下の行は紐付けが無くても出る（None）ので、最初の紐付けはどちらからでも始められる。
//  前はツールバーの ⋯ にも口を置いていたが、「…のメニューに置くのは変」で外した。
//  補正の中身はユーザープリセットなので、プリセットを扱うシートの中に口があるのが自然。
//
//  前は Presets のシートの中の節で直に選ばせていた。そこではプリセットの行を押すと
//  鎖ごと読み込まれる（Presets の本来の動き）ので、補正を選ぶつもりで使う人の鎖を置き換えてしまった。
//  いまは Presets から入っても別の画面へ進むだけで、押した時点では何も読み込まない。
//  **ここには main の鎖へ何かを読み込む操作を置かない。**できるのは出力先ごとの紐付けだけ。
//  入切は鎖の下の行の電源が持つ（ここに同じスイッチを並べると、題と同じ字の行が 1 つ増えるだけになる）。
//
//  行は「どの出力先にどの補正か」を読む場所なので、目立つ字はプリセットの名前にし、出力先は 2 行目に置く。
//  前は Picker の行で、出力先が見出し・プリセットが右端の小さな灰色の字になっていた。
//
//  **AudioIO は観測しない**（3.3Hz で publish する）。いまの出力先も紐付けも
//  OutputCorrection が publish しているものを読む。

import SwiftUI

/// 専用のシートとして出す形（鎖の下の出力補正の行から）。中身に NavigationStack と Done を足すだけ。
struct OutputCorrectionView: View {
    @Environment(\.dismiss) private var dismiss

    /// PC の鎖を編集している間（PipelineView が渡す）。OutputCorrectionList へそのまま渡す。
    let isRemote: Bool

    init(isRemote: Bool = false) {
        self.isRemote = isRemote
    }

    var body: some View {
        NavigationStack {
            OutputCorrectionList(isRemote: isRemote)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
    }
}

/// 出力補正の中身。**NavigationStack を持たない。**Presets のシートからはその NavigationStack の中へ
/// 押して進む形で出すので、ここで包むと入れ子になる。題はここで付ける（どちらの出し方でも同じ）。
struct OutputCorrectionList: View {
    @ObservedObject private var oc = OutputCorrection.shared
    @ObservedObject private var store = PresetStore.shared
    /// 出力先の絵の枠。文字サイズに合わせて広げる（既定のサイズでは 30pt のまま）。
    @ScaledMetric(relativeTo: .title3) private var iconWidth: CGFloat = 30
    /// 大きい文字サイズでだけ、長い Bluetooth 機器名と要約の折り返しを許す。
    @Environment(\.dynamicTypeSize) private var typeSize

    /// PC の鎖を編集している間（PipelineView・PresetsView が渡す）。補正は外してあるので、
    /// いまの出力先を「使っている」とは出さず、紐付けてあれば他の出力先と同じ並びに置く。
    let isRemote: Bool

    init(isRemote: Bool = false) {
        self.isRemote = isRemote
    }

    /// いま使っている出力先。まだ落ち着いた出力先が無い・リモート中は nil。
    private var current: ETOutputCorrectionDevice? { isRemote ? nil : oc.device }

    /// 内蔵スピーカー。**いつも並べる。**どの端末にもあり、イヤホンを挿した状態で初めて開いても
    /// 「スピーカーはつながないと設定できないのか」と読まれないように。名前は紐付けに残った名前があればそれ。
    private static let speakerKey = "speaker"

    /// 並べる出力先。いまの出力先を先頭に（紐付けが無くても出す。選ぶのはたいていここ）、
    /// 次に内蔵スピーカー（いまの出力先でなければ）、続けて紐付けてある他の出力先
    /// （紐付けの無い他の出力先は覚えていないので出せない）。
    private var devices: [ETOutputCorrectionDevice] {
        let key = current?.key
        let bound = oc.bindings.map { ETOutputCorrectionDevice(key: $0.key, name: $0.name, kind: $0.kind) }
        let speaker = bound.first { $0.key == Self.speakerKey }
            ?? ETOutputCorrectionDevice(key: Self.speakerKey, name: "Speaker", kind: "speaker")
        let others = bound.filter { $0.key != key && $0.key != Self.speakerKey }
        return (current.map { [$0] } ?? []) + (key == Self.speakerKey ? [] : [speaker]) + others
    }

    var body: some View {
        List {
            Section {
                ForEach(devices, id: \.key) { d in
                    let isCurrent = d.key == current?.key
                    // 外しても行が残るもの（いまの出力先・内蔵スピーカー）は Remove を出さない。None で選び直す。
                    let stays = isCurrent || d.key == Self.speakerKey
                    // 選ぶ画面はさらに押して進む。どちらの出し方でも、外側の NavigationStack に積まれる。
                    NavigationLink {
                        OutputCorrectionChooser(oc: oc, store: store, device: d,
                                                removable: !stays)
                    } label: {
                        deviceRow(d, isCurrent: isCurrent)
                    }
                    // いまの出力先以外は紐付けがあるから並んでいる。外すと行ごと無くなる
                    // （選ぶ画面の Remove・None と同じ）。いまの出力先は外しても行が残るので、None で選び直す。
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if !stays {
                            Button("Remove", role: .destructive) { oc.bind(d, preset: nil) }
                        }
                    }
                }
            }
        }
        .etNavigationTitle("Output Correction")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 出力先 1 台の行。1 行目がプリセット（無ければ灰色の None）、2 行目が出力先、
    /// 紐付けがあれば 3 行目に中身のエフェクトの名前。いまの出力先には右に In use。
    private func deviceRow(_ d: ETOutputCorrectionDevice, isCurrent: Bool) -> some View {
        let preset = oc.preset(for: d.key)
        // 中身は PresetStore の形をその場で読む。oc.bindings は名前だけなので、上書きにも付いていく
        // （PresetStore は書くたびに publish するので、この画面も読み直される）。
        let summary = preset.map { ETOutputCorrectionForm.summary(store.load($0)) } ?? ""
        return HStack(spacing: 12) {
            Image(systemName: ETOutputDevice.Kind(rawValue: d.kind)?.symbol ?? "speaker")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: iconWidth)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                if let preset {
                    Text(ETUserPresetName.leaf(preset))
                        .etFont(size: 15)
                        .foregroundStyle(.primary)
                        .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                } else {
                    Text("None")
                        .etFont(size: 15)
                        .foregroundStyle(.secondary)
                }
                Text(d.name)
                    .etFont(size: 12)
                    .foregroundStyle(.secondary)
                    .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                if !summary.isEmpty {
                    Text(summary)
                        .etFont(size: 11)
                        .foregroundStyle(.secondary)
                        .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                }
            }

            Spacer(minLength: 8)

            // 状態の札。説明ではなく、どの行がいま鳴っている出力先かを示す。
            if isCurrent {
                Text("In use")
                    .etFont(size: 12)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// 出力先 1 台のプリセットを選ぶ画面。None を先頭に、ユーザープリセットを Presets のシートと同じ
/// フォルダの束ね方で並べる（前は `フォルダ/名前` の字を 1 本の平らな一覧に並べていて、探しにくかった）。
/// 選ぶと紐付けて戻る。選ぶのは紐付けだけで、main の鎖には触らない。切のときも選べる（鳴らすのは入のときだけ）。
/// 戻るのは dismiss で、押して進んだ画面なので 1 段だけ戻る（Presets から入ったときも Presets のシートは閉じない）。
private struct OutputCorrectionChooser: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var oc: OutputCorrection
    @ObservedObject var store: PresetStore
    let device: ETOutputCorrectionDevice
    /// いまの出力先でないとき。外すと一覧から行ごと消えるので、None とは別に Remove を置く。
    let removable: Bool

    var body: some View {
        let selected = oc.preset(for: device.key)
        List {
            Section {
                choice("None", isSelected: selected == nil) { pick(nil) }
            }
            ForEach(ETOutputCorrectionForm.presetFolders(store.names), id: \.name) { folder in
                Section {
                    ForEach(folder.items, id: \.self) { full in
                        choice(ETUserPresetName.leaf(full), isSelected: selected == full) { pick(full) }
                    }
                } header: {
                    // フォルダに入っていないものは見出しを付けない（Presets でも見出しの上に並ぶ）。
                    if !folder.name.isEmpty { Text(folder.name) }
                }
            }
            if removable && selected != nil {
                Section {
                    Button("Remove", role: .destructive) { pick(nil) }
                        .etFont(size: 15)
                }
            }
        }
        .etNavigationTitle(device.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 選べる 1 行。選んでいるものに印。
    private func choice(_ title: String, isSelected: Bool,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .etFont(size: 15)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        // **List の中の Button は字を tint で塗る**（中の Text に .primary を付けても負ける）。
        // 全部が青いとリンクの並びに見えるので、tint を字の色にして、印だけアクセントの色を名指しする。
        .tint(.primary)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// 紐付けて（nil なら外して）戻る。
    private func pick(_ preset: String?) {
        oc.bind(device, preset: preset)
        dismiss()
    }
}
