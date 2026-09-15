//  EffectCardView.swift
//  エフェクト 1 個ぶんのカード。
//
//  EffeTune は頭に「⋮ / ON / 名前」を置き、その下にパラメータを並べている。そこは同じ。
//  違うのは開閉で、頭を触ると畳める。既定は開いた状態。
//
//  ▲▼・削除は EffeTune では横に並んでいるが、場所を食うので ⋯ にまとめ、
//  並べ替えと削除はリストの標準の動き（長押しで移動・横に払って削除）に任せている。
//
//  Section だけは別の見た目にする（下の SectionCardView）。上流も同じ骨で作りつつ、
//  class に section を足して枠の色を変えている（js/ui/pipeline/pipeline-item-builder.js:28-29）。

import SwiftUI

struct EffectCardView: View {
    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP
    let isExpanded: Bool
    let toggleExpanded: () -> Void

    var body: some View {
        if node.isSection {
            SectionCardView(index: index, node: node, dsp: dsp,
                            isExpanded: isExpanded, toggleExpanded: toggleExpanded)
        } else {
            effectCard
        }
    }

    private var effectCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                header
                if isExpanded && hasBody {
                    Group {
                        if ETEffectViews.has(node.spec.type) {
                            // 専用の画面を持つものは、そちらがパラメータまで面倒を見る。
                            ETEffectViews.view(index: index, node: node, dsp: dsp)
                                .environment(\.etGraphOnly, node.graphOnly)
                        } else {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(node.spec.params) { param in
                                    ParameterRow(param: param, nodeIndex: index,
                                                 values: node.values, dsp: dsp)
                                }
                            }
                        }
                    }
                    .padding(ETMetrics.cardPadding)
                }
            }
        }
        .opacity(isMuted ? 0.55 : 1)
    }

    /// 音が通らない状態か。自分の入切と、上にある Section の入切の両方で決まる。
    ///
    /// 上流も同じ掛け算で、鎖の中の位置から区切りの入切を引いて
    /// plugin-disabled を付けている（js/ui/pipeline/pipeline-core.js:309-323）。
    /// 区切りの側の答えは sectionGate に入っている。
    /// DSP も `node.enabled == 0 || node.sectionGate == 0` で読み飛ばす
    /// （dsp/core/engine.cpp:919）ので、見た目の条件をそれに合わせる。
    private var isMuted: Bool { !node.enabled || node.sectionGate == 0 }

    private var header: some View {
        HStack(spacing: 10) {
            // Button ではなく Toggle。支援技術に入切が伝わるようにする。
            Toggle("Enabled", isOn: Binding(
                get: { node.enabled },
                set: { dsp.setEnabled($0, at: index) }))
                .toggleStyle(.power)
                .labelsHidden()
                .accessibilityLabel(node.spec.name)

            VStack(alignment: .leading, spacing: 1) {
                Text(node.spec.name)
                    .font(.system(size: 16, weight: .semibold))
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            // 既定（0→0 の All）から外れたものだけ出す。
            // 普通の鎖は一直線なので、普段は何も出ない。
            if !node.isDefaultRouting || node.isGated {
                Text(ETRouting.badge(node))
                    .font(.system(size: 10, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.tint, in: .capsule)
                    .foregroundStyle(.white)
            }

            // Analyzer は図だけ見たいことが多いので、目盛りを畳められるようにする。
            // ⻳ の中ではなく直のボタンにしてある。1 手で切り替えたいものだから。
            if isAnalyzer {
                Button {
                    dsp.setGraphOnly(!node.graphOnly, at: index)
                } label: {
                    Image(systemName: node.graphOnly
                          ? "chart.xyaxis.line" : "slider.horizontal.3")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: ETMetrics.hitTarget, height: ETMetrics.hitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(node.graphOnly ? AnyShapeStyle(.tint)
                                                : AnyShapeStyle(.secondary))
                .accessibilityLabel(node.graphOnly ? "Show controls" : "Graph only")
            }

            if hasBody {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }

            Menu {
                Button { dsp.resetParams(at: index) } label: {
                    Label("Reset Parameters", systemImage: "arrow.counterclockwise")
                }
                Button { dsp.move(from: IndexSet(integer: index), to: index - 1) } label: {
                    Label("Move Up", systemImage: "arrow.up")
                }
                .disabled(index == 0)
                Button { dsp.move(from: IndexSet(integer: index), to: index + 2) } label: {
                    Label("Move Down", systemImage: "arrow.down")
                }
                .disabled(index >= dsp.chain.count - 1)
                Divider()
                Button(role: .destructive) {
                    dsp.remove(at: IndexSet(integer: index))
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
        .padding(.horizontal, ETMetrics.cardPadding)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            guard hasBody else { return }
            withAnimation(.snappy(duration: 0.2)) { toggleExpanded() }
        }
    }

    /// 図で見せるもの。パラメータを畳んでも中身が残る。
    private var isAnalyzer: Bool {
        node.spec.category == "analyzer" && ETEffectViews.has(node.spec.type)
    }

    /// 開いて出すものがあるか。図だけのエフェクト（Level Meter など）も開ける。
    private var hasBody: Bool {
        !node.spec.params.isEmpty || ETEffectViews.has(node.spec.type)
    }

    /// 畳んでいるときに何をしているかが分かるよう、主要な値を 1 行にする。
    private var summary: String {
        guard !node.spec.params.isEmpty else { return node.spec.category.categoryLabel }
        let shown = node.spec.params.prefix(3).compactMap { param -> String? in
            guard !param.isArray,
                  node.values.indices.contains(param.offset) else { return nil }
            let v = node.values[param.offset]
            if case .number = param.kind, v == param.defaultValue { return nil }
            if case .toggle = param.kind, v == param.defaultValue { return nil }
            return "\(param.label) \(param.format(v))"
        }
        return shown.isEmpty ? node.spec.category.categoryLabel : shown.joined(separator: " · ")
    }
}

/// Section の行。音は触らず、下に続くエフェクトをひとまとまりにする。
///
/// 上流との対応:
///   - 枠を緑にして普通の行と分ける（effetune.css:1103-1108 の
///     `.pipeline-item.section` が 2px 実線の `--et-success`、
///      その値は effetune-theme.css:6 の #4CAF50）。
///     こちらはシステムの緑で、同じ値ではない。数値の色を持たないのは
///     Components.swift の方針に合わせたもの
///   - 頭に出すのは `"<cm> Section"`。cm が空なら `"Section"` だけ
///     （js/ui/pipeline/pipeline-item-builder.js:238-242）
///   - 名前を打ち込む欄は上流ではカードの中（plugins/control/section.js の createUI）。
///     こちらは開く中身が他に無いので頭へ出す
///   - ルーティングのボタンは出さない（pipeline-item-builder.js:133）
///   - プリセットの UI も出さない（section.js の `hidePresetUI = true`）
///
/// 畳みは上流と意味が違う。上流の Shift+Click は区切りの範囲ぶんの
/// **パラメータ UI** をまとめて開閉するだけで、行そのものは残る
/// （pipeline-item-builder.js:795-836）。iPhone は縦しか無いので、
/// こちらは行ごと隠す（隠すのは PipelineView）。何本隠れているかを頭に出すのは、
/// 行が消える以上どこへ行ったのかが分からなくなるため。
private struct SectionCardView: View {
    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP
    let isExpanded: Bool
    let toggleExpanded: () -> Void

    /// 打ち込み中の文字。確定するまで dsp へ渡さない。
    ///
    /// 上流は input のたびに updateParameters() を呼んでいる（section.js）が、
    /// こちらで同じことをすると 1 打鍵ごとに @Published chain が変わり、
    /// 画面が丸ごと作り直される。ツールバーと ⋯ の Menu が "Loading…" のまま
    /// 固まるのがこれなので、確定（改行・欄から離れる）でだけ書く。
    @State private var draft = ""
    @FocusState private var editing: Bool

    var body: some View {
        Card {
            HStack(spacing: 10) {
                // Section 自身の入切。切ると次の Section の手前までが止まる
                // （dsp-pipeline-descriptor.js:190-201 / engine.cpp:919）。
                Toggle("Enabled", isOn: Binding(
                    get: { node.enabled },
                    set: { dsp.setEnabled($0, at: index) }))
                    .toggleStyle(.power)
                    .labelsHidden()
                    .accessibilityLabel(accessibilityName)

                VStack(alignment: .leading, spacing: 1) {
                    // 上流の placeholder は "Enter the section name"（section.js）。
                    // 幅が無いので短くしてある。
                    TextField("Section name", text: $draft)
                        .font(.system(size: 16, weight: .semibold))
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($editing)
                        .onSubmit { commit() }

                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                // 畳む・開く。Menu にはしない（提示が終わらない件を追っている最中で、
                // 原因は高頻度の再描画）。1 手で効く直のボタンにする。
                Button {
                    if editing { commit() }
                    withAnimation(.snappy(duration: 0.2)) { toggleExpanded() }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .frame(width: ETMetrics.hitTarget, height: ETMetrics.hitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(isExpanded ? "Collapse section" : "Expand section")
            }
            .padding(.horizontal, ETMetrics.cardPadding)
            .padding(.vertical, 10)
            // 器は Card。角丸は containerShape から引く。
            .overlay(RoundedRectangle(cornerRadius: ETMetrics.innerRadius, style: .continuous)
                .stroke(.green, lineWidth: 1.5))
        }
        .opacity(node.enabled ? 1 : 0.55)
        .onAppear { draft = node.sectionName }
        .onChange(of: node.sectionName) { _, now in
            // プリセットや共有リンクの取り込みで名前が外から変わる。
            // 打ち込んでいる最中は上書きしない（section.js の registerUIRefresh と同じ）。
            if !editing { draft = now }
        }
        .onChange(of: editing) { _, now in
            if !now { commit() }
        }
    }

    private func commit() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = name
        guard name != node.sectionName else { return }
        dsp.setSectionName(name, at: index)
    }

    /// 頭に出す行。Section の名前は欄そのものなので、ここには種別と中身の数を出す。
    private var subtitle: String {
        let n = ETSection.range(after: index, types: dsp.chain.map(\.spec.type)).count
        guard n > 0 else { return "Section" }
        let effects = "\(n) effect\(n == 1 ? "" : "s")"
        return isExpanded ? "Section · \(effects)" : "Section · \(effects) hidden"
    }

    /// 支援技術へ渡す名前。上流の表示と同じ組み立て
    /// （pipeline-item-builder.js:238-242）。
    private var accessibilityName: String {
        node.sectionName.isEmpty ? "Section" : "\(node.sectionName) Section"
    }
}
