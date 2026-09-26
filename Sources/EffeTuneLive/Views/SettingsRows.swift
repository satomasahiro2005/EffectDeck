//  SettingsRows.swift
//  Settings の行の器。2 種類しかない。
//
//   ETChoiceRow — 選ぶもの。3 つしかない選択肢を全部見せる。
//   ETNoticeRow — 読むもの。いまの状態と、当てはまっている問題。
//
//  **ピッカー（iOS では中身が Menu）を置かない。**
//  シートの中で Menu を開いている最中に List が作り直されると、
//  UIDeferredMenuElement が「読み込み中」のまま固まる。実機で踏んでいる。
//  観測の置き場所を決める規律でも防げるが、規律は後から誰かが 1 行足せば破れる。
//  選択肢は 3 つずつしかないので、その場に並べれば Menu 自体が要らなくなる。

import SwiftUI

/// 3 つの選択肢を**1 行**に並べる。説明は付けない。
///
/// 選択肢ごとに行を立てない。3 設定で 9 行になり、設定が縦に伸びる。
///
/// `.pickerStyle(.segmented)` は UISegmentedControl で、**Menu ではない**。
/// この画面が Picker を避けているのは Menu が固まるからなので、
/// セグメントはその理由に当たらない。
struct ETSegmentedChoice<Value: Hashable & Identifiable>: View {
    let title: String
    let values: [Value]
    let label: (Value) -> String
    /// 名前の右に出す実測。**要求と実測を別の行にしない。**分けると同じ
    /// 名前が画面に 2 度出て、どちらが効いている値なのか読めなくなる。
    var detail: String? = nil
    @Binding var selection: Value

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // **名前は出す。**セグメントだけ並べると、何の設定なのかが
            // 画面のどこにも書いていない状態になる（節を束ねたときにそうなった）。
            // 消してよかったのは選択肢ごとの説明であって、設定の名前ではない。
            HStack(spacing: 8) {
                Text(title)
                if let detail {
                    Spacer(minLength: 8)
                    Text(detail)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Picker(title, selection: $selection) {
                ForEach(values) { v in
                    Text(label(v)).tag(v)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// 選択肢 1 つぶん。いまは使っていない（ETSegmentedChoice に畳んだ）。
/// 選択肢が 4 つ以上になって 1 行に入らなくなったときのために残してある。
struct ETChoiceRow: View {
    let title: String
    let note: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16))
                        .foregroundStyle(.primary)
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.tint)
                    // 消さずに透かす。消すと選び直すたびに行の幅が動く。
                    .opacity(selected ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
    }
}

/// いまの状態、または当てはまっている問題 1 つ。
///
/// 生の文字列（iOS が返した失敗の文）は本文に混ぜず、下に等幅の 1 行で置く。
/// 報告に貼るとき、文章の途中から抜き出さずに済む。
struct ETNoticeRow: View {
    let systemImage: String
    let tone: ETNoticeTone
    let title: String
    let detail: String?
    var mono: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            icon

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let mono {
                    Text(mono)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .font(.footnote)
                        .buttonStyle(.bordered)
                        .padding(.top, 2)
                }
            }
        }
    }

    /// **動いていることを動きで出す。**止まった絵だと、待っているのか
    /// 固まっているのかが見分けられない。効果は tone で決める。
    /// 記号ごとに指定を足さないのは、記号が増えるたびに書く場所が増えるため。
    @ViewBuilder
    private var icon: some View {
        let base = Image(systemName: systemImage)
            .font(.system(size: 15))
            .foregroundStyle(iconStyle)
            .frame(width: 20)
        switch tone {
        // **記号ぜんぶを動かさない。**breathe（拡大縮小）と wiggle（揺れ）は
        // 記号そのものが動くので、一覧の中で目に刺さる。
        // 層を順に光らせる variableColor だけにする。indefinite なので
        // 引き金を渡さなくても回り続ける。
        case .active:  base.symbolEffect(.variableColor.iterative.reversing)
        case .normal:  base.symbolEffect(.variableColor.iterative)
        case .warning: base
        }
    }

    /// 色は semantic なものだけ。**新しい色を定義しない。**
    private var iconStyle: AnyShapeStyle {
        switch tone {
        case .normal:  return AnyShapeStyle(.secondary)
        case .active:  return AnyShapeStyle(.tint)
        case .warning: return AnyShapeStyle(.orange)
        }
    }
}

extension ETNoticeRow {
    init(state: ETRunState, retry: @escaping () -> Void) {
        var action: (() -> Void)? = nil
        if state.retryTitle != nil { action = retry }
        self.init(systemImage: state.systemImage,
                  tone: state.tone,
                  title: state.title,
                  detail: state.detail,
                  mono: state.mono,
                  actionTitle: state.retryTitle,
                  action: action)
    }

    init(issue: ETIssue) {
        self.init(systemImage: issue.systemImage,
                  tone: issue.tone,
                  title: issue.title,
                  detail: issue.detail)
    }
}
