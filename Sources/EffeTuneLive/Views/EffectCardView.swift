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
    /// ⋯ の Move Up / Move Down。**画面の隣の行**と入れ替える。
    ///
    /// 鎖の添字で 1 つ動かすと、隣が畳んだ Section の配下（画面に無い行）のときに
    /// そこへ入り込んで、動かした行が画面から消える。どこが隣かを知っているのは
    /// 行を組んでいる PipelineView なので、中身はあちらから渡してもらう。
    let moveUp: () -> Void
    let moveDown: () -> Void
    /// 画面の端の行か。鎖の本数ではなく**見えている行**で決める。
    let canMoveUp: Bool
    let canMoveDown: Bool

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
                // **畳んでいても図を出すもの。**
                // Level Meter は畳むと「Analyzer」という字だけが残るが、
                // この道具は音が来ているかを見るために置くので、
                // 字より棒のほうが要る。図だけの形で細く出す。
                if !isExpanded && showsCollapsedGraph && !inlinesGraph {
                    // 図だけの形で下に置く。切らない。
                    // 一度 150pt で切ってみたが、横軸の字まで落ちて壊れて見えた。
                    // 高さが要るのは図がそれだけの情報を持っているからで、
                    // 畳んだ状態でも見たいものはそこにある。
                    ETEffectViews.view(index: index, node: node, dsp: dsp)
                        .environment(\.etGraphOnly, true)
                        .padding(.horizontal, ETMetrics.cardPadding)
                        .padding(.bottom, ETMetrics.cardPadding)
                        .allowsHitTesting(false)
                }
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
        HStack(spacing: 6) {
            // Button ではなく Toggle。支援技術に入切が伝わるようにする。
            Toggle("Enabled", isOn: Binding(
                get: { node.enabled },
                set: { dsp.setEnabled($0, at: index) }))
                .toggleStyle(.power)
                .labelsHidden()
                .accessibilityLabel(node.spec.name)

            // **畳んだ Level Meter は図を名前の場所へ入れる。**
            // 横長の棒 2 本と目盛りなので、名前があった枠にそのまま収まる。
            // これでカードが 1 行になり、鎖の先頭に置いても場所を食わない。
            // 他の analyzer（図が縦に伸びるもの）は下に置く。
            if inlinesGraph {
                ETEffectViews.view(index: index, node: node, dsp: dsp)
                    .environment(\.etGraphOnly, true)
                    .allowsHitTesting(false)
                    .accessibilityLabel(node.spec.name)
            } else if !hidesName {
                VStack(alignment: .leading, spacing: 1) {
                    // 折り返さない。幅が足りないときは縮める。
                    // "Digital Error Emulator" や "Spectrum Analyzer" は iPhone 幅で
                    // 2 行に折れていた。
                    Text(node.spec.name)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                // 名前も図も頭には出さない（図は下に来る）。
                // 読み上げだけ残す。図は読み上げられないので。
                Color.clear.frame(width: 0, height: 0)
                    .accessibilityHidden(false)
                    .accessibilityLabel(node.spec.name)
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

            // 図を持つものは、図だけ見たいことがある。目盛りを畳められるようにする。
            // ⋯ の中ではなく直のボタンにしてある。1 手で切り替えたいものだから。
            //
            // 以前は analyzer だけに出していたが、PEQ のように図が主役のものでも
            // スライダーを畳みたい場面は同じだけある。図があるかどうかで決める。
            if canGraphOnly {
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
                // **印であって押し所ではない。**
                // 押すのは行そのもの（下の onTapGesture）。
                // 矢印にも当たり判定があると、行の手つきと取り合って
                // 押せたり押せなかったりに見える。しかも文字を押すのと
                // 結果が同じなので、分ける意味が無い。
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            Menu {
                Button { dsp.resetParams(at: index) } label: {
                    Label("Reset Parameters", systemImage: "arrow.counterclockwise")
                }
                Button(action: moveUp) {
                    Label("Move Up", systemImage: "arrow.up")
                }
                .disabled(!canMoveUp)
                Button(action: moveDown) {
                    Label("Move Down", systemImage: "arrow.down")
                }
                .disabled(!canMoveDown)
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
        // 両端の部品は 44pt / 34pt の当たり判定を取っていて、絵の周りに 12pt / 9pt の
        // 余白を自分で持っている。器の内側（cardPadding = 14）をそのまま足すと、
        // 電源の絵だけが本文より 12pt 内側に入るうえ、名前に回る幅が 28pt 減って
        // iPhone 幅で 2 行に折れる。ここでは足りない分だけを足して、
        // 電源の絵の左端を本文の左端に揃える。
        .padding(.leading, 2)
        .padding(.trailing, 4)
        // 名前を出していないときは詰める。字が無いのに 2 行ぶんの高さを
        // 取ると、頭の行が空白のまま 44pt 居座る。
        // 図をこの行に入れているときは、図のぶんだけ少し戻す。
        .padding(.vertical, inlinesGraph ? 8 : (hidesName ? 2 : 10))
        .contentShape(Rectangle())
        .onTapGesture {
            guard hasBody else { return }
            withAnimation(.snappy(duration: 0.2)) { toggleExpanded() }
        }
    }

    /// 頭に名前を出さないか。**図を名前の場所へ入れるときだけ。**
    ///
    /// 名前を消して図を下に置くと、頭の行が空のまま残って場所を食う。
    /// 名前が要らないのは、図がその場所に収まって 1 行になるものだけ。
    private var hidesName: Bool { inlinesGraph }

    /// 図を名前の場所へ入れるか。**横長で背の低い図だけ。**
    ///
    /// Level Meter は棒 2 本と目盛りで、名前 2 行ぶんの高さに収まる。
    /// しかも棒を見れば何かは分かるので、"Level Meter / Analyzer" の字は
    /// 同じことを二度書いている。
    /// Spectrum Analyzer や Stereo Meter は図が縦に伸びるので入らない。
    /// そちらは名前を残して、図はその下に置く。
    private var inlinesGraph: Bool {
        showsCollapsedGraph && !isExpanded && node.spec.type == "LevelMeterPlugin"
    }

    /// 図で見せるもの。パラメータを畳んでも中身が残る。
    private var isAnalyzer: Bool {
        node.spec.category == "analyzer" && ETEffectViews.has(node.spec.type)
    }

    /// 畳んでいるあいだも図を出すか。**analyzer は全部そうする。**
    ///
    /// 畳んで字だけにしても「Analyzer」としか出ない。この分類は見るために
    /// 鎖へ入れるものなので、畳んだ状態でも動いているものが見えたほうがよい。
    /// 出すのは図だけの形（つまみも目盛りも畳んだもの）なので、
    /// 一覧としての高さは字 1 行ぶんより少し増える程度に収まる。
    private var showsCollapsedGraph: Bool {
        node.spec.category == "analyzer" && ETEffectViews.has(node.spec.type)
    }

    /// 図だけにできるか。専用のビューを持っていれば図がある。
    ///
    /// **パラメータの有無で決めない。** Level Meter はパラメータを 1 つも
    /// 持たないが、畳めば見出しと目盛りと数値が消えて棒だけになる。
    /// 音が来ているかを見るために鎖の先頭へ置く道具なので、
    /// 細いまま機能することのほうが大事。
    private var canGraphOnly: Bool {
        ETEffectViews.has(node.spec.type)
    }

    /// 開いて出すものがあるか。図だけのエフェクト（Level Meter など）も開ける。
    private var hasBody: Bool {
        !node.spec.params.isEmpty || ETEffectViews.has(node.spec.type)
    }

    /// 畳んでいるときに何をしているかが分かるよう、主要な値を 1 行にする。
    ///
    /// 開いているときは同じ値がすぐ下に出ているので、分類の方を出す。
    /// そうしないと、どのエフェクトなのかを言う行が頭から消える。
    private var summary: String {
        if isExpanded && hasBody { return node.spec.category.categoryLabel }
        // 畳んだ状態で図を出すものは、その下に図が来る。
        // 字でも分類名しか出ないので、分類を出しておく（重複しない）。
        if !isExpanded && showsCollapsedGraph { return node.spec.category.categoryLabel }
        guard !node.spec.params.isEmpty else { return node.spec.category.categoryLabel }
        let shown = node.spec.params.prefix(3).compactMap { param -> String? in
            guard !param.isArray,
                  node.values.indices.contains(param.offset) else { return nil }
            let v = node.values[param.offset]
            // 既定のままの値は出さない。触った所だけを見せる。
            // 選択肢（.enumeration）にも同じ物差しを当てる。ここを抜いていたので、
            // SBC Codec Simulator は既定のまま "Channel Mode Joint Stereo" を出し、
            // Digital Error Emulator は "Mode 10A" を出して、分類を押し出していた。
            guard v != param.defaultValue else { return nil }
            return "\(param.label) \(valueText(param, v))"
        }
        return shown.isEmpty ? node.spec.category.categoryLabel : shown.joined(separator: " · ")
    }

    /// 値 1 個ぶんの文字列。
    ///
    /// ETParam.format は入切を「入 / 切」で返す（EffectSpec.swift:37-38）。
    /// 画面に出す文言は英語なので、入切だけここで組む。
    private func valueText(_ param: ETParam, _ v: Float) -> String {
        if case .toggle = param.kind { return v >= 0.5 ? "On" : "Off" }
        return param.format(v)
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
            // 間隔と余白はエフェクトの頭と同じ。隣り合う札なので、
            // 電源の絵と名前の左端が揃っていないと目に付く。
            HStack(spacing: 6) {
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
            .padding(.leading, 2)
            .padding(.vertical, 10)
            // 緑の枠は Card の縁そのもの。ここに乗せる面と Card が背景を敷く面は
            // 同じなので、丸みも Card と同じ cardRadius でないと角で線が縁から離れる
            // （innerRadius 8 と cardRadius 16 で、角のあたり最大 2pt ほどずれる）。
            .overlay(RoundedRectangle(cornerRadius: ETMetrics.cardRadius, style: .continuous)
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
