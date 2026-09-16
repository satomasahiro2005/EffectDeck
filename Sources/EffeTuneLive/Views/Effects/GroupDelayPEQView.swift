//  GroupDelayPEQView.swift
//  Group Delay PEQ（GroupDelayPEQPlugin）。
//
//  バンドの形（t/f/d/q/e）とタップ数は **DSP のパラメータではない。**
//  instance へ行くのは lt と fd の 2 つだけで（Generated/EffectCatalog.swift:532-543、
//  plugins/eq/group_delay_peq.js:161-167 の _packedParameters）、群遅延そのものは
//  係数を資産として送り込んで作る。だから値の置き場は node.values ではなく
//  GroupDelayPEQDesigner の settings にある。
//
//  設計と送り込みは DSP/Designers/GroupDelayPEQDesigner.swift が全部持っている。
//  ここがやるのは 3 つだけ。
//    - 触る口を出す（バンド 5 本・Taps・Latency）
//    - designer に繋ぐ（attach）。**MainActor。designer 自体が @MainActor**
//    - designer の status と detailText を出す
//
//  --- lt と fd をこのループから外してある理由 ---
//  fd は designer が stage のたびに taps/2 で上書きする（GroupDelayPEQDesigner.swift:1032）。
//  ParameterRow でも書けるようにすると同じ枠に書き手が 2 人になり、指で動かした値は
//  次の送り直しで消える。lt も同じで、ParameterRow から直に書くと designer の
//  settings.latencySamples と instance の値が食い違うので、setLatencySamples を通す。
//  IRReverbView.swift:58 の stripKeys と同じ手。
//
//  --- 図は出していない ---
//  材料は揃った。designer が目標と実現の曲線を 128 点で返す
//  （GroupDelayPEQDesign.Response、design-core.js:25 RESPONSE_POINTS）。
//  ここでは描いていない。描くときのために、縦軸の決まりだけ控えておく。
//
//  この効果の縦軸は dB ではない。**群遅延（ms）** で、上が正・下が負。
//
//    plugins/eq/group_delay_peq.js:956-962
//        delayToY(ms)     = 50 - ms / scale.range * 50
//        yToDelay(percent) = (50 - percent) / 50 * scale.range
//
//  範囲は固定ではなく、いまの設定に合わせて広がる（同 975-987）。
//  GRID_STEPS_MS = [0.5, 1, 2, 5, 10, 20, 25, 50, 100] から
//  「step * 5 >= peak」を満たす最初の step を選び、range = step * 5。
//  peak は「全バンドの delayMs（切ってあるものも含む）」と target 曲線と realized 曲線の
//  絶対値の最大で、下限は MINIMUM_GRAPH_RANGE_MS = 5 ms（同 32）。
//  横軸は 10Hz〜40kHz の対数（同 36 GRAPH_FREQUENCY_RANGE, 943-948 freqToX）。
//  Swift 側の横軸は GroupDelayPEQDesignCore.responseFrequencies が同じ 128 点を返す。
//
//  --- 保存されないもの ---
//  バンドと Taps はプリセットに乗らない。node.values には lt と fd しか入らないので、
//  保存して読み直すと設計が消えて素通しに戻る。遅延の申告は資産が無ければ 0 なので
//  （kernel.cpp:162-163）、鎖の頭合わせが狂うことはない。消えるのは効果そのもの。

import SwiftUI

// MARK: - designer の置き場

/// 段ごとの designer を持っておく入れ物。
///
/// **ビューに持たせられない。** カードを畳むと開いていた側のビューは消える
/// （EffectCardView.swift:63-67 の `if isExpanded && hasBody`）ので、@StateObject は
/// そのたびに作り直される。作り直すと設定が既定（全バンド 0 ms）へ戻り、次の attach が
/// .flat の経路に入って AssetUpload.clear を呼ぶ（GroupDelayPEQDesigner.swift:902-911）。
/// つまり**カードを畳むだけで効果が消える。**
///
/// 鍵は instance ではなく Node.id にする。instance は prepare のたびに変わる
/// （EffeTuneDSP.swift:594-607 の rebuildAll が作り直し、engine.cpp:382 が
/// generation を上げるので番号も変わる）が、Node.id は残る。
/// レートが変わっても設定が生き延びるほうが正しい。
@MainActor
final class GroupDelayPEQDesigners {

    static let shared = GroupDelayPEQDesigners()

    private var designers: [UUID: GroupDelayPEQDesigner] = [:]
    /// いまどの instance へ繋いであるか。繋ぎ直しを 1 回だけにする。
    /// attach は毎回 start(debounce: 0) を回す（GroupDelayPEQDesigner.swift:810）ので、
    /// body が走るたびに呼ぶと音が細かく途切れる。
    private var attached: [UUID: UInt32] = [:]

    private init() {}

    /// 段の designer。無ければ作る。`initial` は**作るときだけ**使う。
    func designer(for id: UUID, initial: GroupDelayPEQSettings) -> GroupDelayPEQDesigner {
        if let existing = designers[id] { return existing }
        prune()
        let made = GroupDelayPEQDesigner(settings: initial)
        designers[id] = made
        return made
    }

    func attachedInstance(for id: UUID) -> UInt32 { attached[id] ?? 0 }

    func markAttached(_ id: UUID, instance: UInt32) { attached[id] = instance }

    /// 鎖から消えた段のぶんを落とす。
    /// instance は EffeTuneDSP が壊している（EffeTuneDSP.swift:689 の et_instance_destroy）ので、
    /// ここでは参照を外すだけでよい。detach を呼ぶと死んだ instance へ触りに行く。
    private func prune() {
        let live = Set(EffeTuneDSP.shared.chain.map(\.id))
        designers = designers.filter { live.contains($0.key) }
        attached = attached.filter { live.contains($0.key) }
    }
}

// MARK: - 選択肢 1 つ

/// Taps と Latency の札。ForEach に渡すので Identifiable にする。
private struct GroupDelayPEQChoice: Identifiable {
    let id: Int
    let label: String
}

// MARK: - 入口

struct GroupDelayPEQView: View {

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    var body: some View {
        GroupDelayPEQBody(index: index, node: node, dsp: dsp,
                          designer: GroupDelayPEQDesigners.shared.designer(for: node.id,
                                                                          initial: initialSettings))
    }

    /// designer を初めて作るときの設定。
    ///
    /// レートは **dsp.sampleRate**。engine に渡った値がそれで（EffeTuneDSP.swift:117-118 が
    /// 控えて :137 で et_engine_prepare へ渡している）、カーネルはペイロードの +12 を
    /// その値と突き合わせる（kernel.cpp:286 `readU32(bytes+12) == (uint32)(sample_rate_ + 0.5F)`）。
    /// AudioIO.processingRate は音が始まるまで 48000 のままなので、こちらは使わない。
    private var initialSettings: GroupDelayPEQSettings {
        GroupDelayPEQSettings(latencySamples: seededLatency,
                              sampleRate: dsp.sampleRate,
                              processingChannels: GroupDelayPEQSettings.routedChannels(
                                  channelSpec: node.channelSpec, engineChannels: 2))
    }

    /// lt の初期値。node.values の lt は選択肢の添字（EffectCatalog.swift:541）。
    private var seededLatency: Int {
        let choices = GroupDelayPEQDesignCore.latencyChoices
        guard let param = node.spec.params.first(where: { $0.key == "lt" }),
              node.values.indices.contains(param.offset) else { return 128 }
        let i = Int(node.values[param.offset].rounded())
        return choices.indices.contains(i) ? choices[i] : 128
    }
}

// MARK: - 中身

private struct GroupDelayPEQBody: View {

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP
    @ObservedObject var designer: GroupDelayPEQDesigner

    @Environment(\.etGraphOnly) private var graphOnly
    /// いま触っているバンド。ParameterRow の bandPicker と同じ考え方で、
    /// 5 本ぶんのつまみを縦に並べない。
    @State private var band = 0

    /// designer が持つので ParameterRow から外すもの。
    private static let stripKeys: Set<String> = ["lt", "fd"]

    var body: some View {
        content
            // 段を足した直後と、engine を用意し直して instance が変わった後に繋ぐ。
            .onChange(of: node.instance, initial: true) { _, _ in connect() }
            // 鎖の形を変えると処理するチャンネル数が変わる。係数は同じなので送り直すだけ。
            .onChange(of: node.channelSpec) { _, _ in pushRouting() }
    }

    @ViewBuilder
    private var content: some View {
        if graphOnly {
            // 畳んだカード。触れないので状態だけ出す。
            statusBox
        } else {
            VStack(alignment: .leading, spacing: 12) {
                statusBox
                bandPicker
                bandControls
                tapsRow
                latencyRow

                // 残りは ParameterRow に任せる。いまは lt と fd しか無いので
                // この輪は何も出さない。params.json が増えたときのために残してある。
                ForEach(node.spec.params) { param in
                    if !Self.stripKeys.contains(param.key) {
                        ParameterRow(param: param, nodeIndex: index,
                                     values: node.values, dsp: dsp)
                    }
                }
            }
        }
    }

    // MARK: 繋ぐ

    /// instance に繋ぐ。ただし**送るものがあるときだけ。**
    ///
    /// attach は即 start(debounce: 0) を回す（GroupDelayPEQDesigner.swift:810）。
    /// 遅延が 1 本も無ければ .flat の経路へ行って AssetUpload.clear を呼び
    /// （同 902-911）、clear は master bypass を上げて音のスレッドが 2 ブロック進むまで
    /// 待つ（AssetUpload.swift:553-558, 676-692）。送るものが無いのに繋ぐと、
    /// カードを出しただけで鎖全体の音が一瞬切れる。
    private func connect() {
        guard designer.settings.hasDelay else { return }
        attachIfNeeded()
    }

    /// 触る直前に呼ぶ。繋がっていなければここで繋ぐ。
    private func attachIfNeeded() {
        guard dsp.engine != 0, node.instance != 0 else { return }
        let store = GroupDelayPEQDesigners.shared
        guard store.attachedInstance(for: node.id) != node.instance else { return }

        // **繋ぐ前にレートとチャンネル数を入れる。**
        // 繋いでいないあいだの update は設定に入るだけで送り込みまで行かない
        // （GroupDelayPEQDesigner.swift:898-901）ので、ここで直すのは只。
        // 既定の 48000 のまま attach して engine が 96000 だと、ペイロードの +12 が
        // 合わずに commit が ET_ERR_ARGS で落ちる（kernel.cpp:286）。
        //
        // 繋ぎ直し（prepare で instance が変わった）のときは、この update が古い instance へ
        // 送りに行きかける。すぐ下の attach が start を呼んで work をキャンセルし世代を
        // 上げる（同 889-895）ので、あいだに await が無いこの並びなら走り出さない。
        var next = designer.settings
        next.sampleRate = dsp.sampleRate
        next.processingChannels = routedChannels
        designer.update(next.clampingDelaysToLimit(), debounce: 0)

        store.markAttached(node.id, instance: node.instance)
        designer.attach(instance: node.instance, nodeIndex: index)
    }

    /// この効果が処理する幅。
    ///
    /// **IRReverbView.swift:164-167 から写さないこと。** あちらは `case 17...23` で
    /// 1 つずれている。engine.cpp:760 は `channelSpec == -1 || channelSpec >= 16 ? 2u : 1u`
    /// で 16 も対に数える。designer 側の routedChannels（GroupDelayPEQDesigner.swift:206-213）が
    /// そちらに合わせてあるので、それを呼ぶ。
    private var routedChannels: Int {
        GroupDelayPEQSettings.routedChannels(channelSpec: node.channelSpec, engineChannels: 2)
    }

    private func pushRouting() {
        guard designer.settings.processingChannels != routedChannels else { return }
        var next = designer.settings
        next.processingChannels = routedChannels
        designer.update(next, debounce: 0)
    }

    // MARK: 触る

    /// バンド 1 本を書き換える。
    ///
    /// **先に値を入れて、後から繋ぐ。** 逆にすると、まだ全部 0 ms の状態で attach が走って
    /// AssetUpload.clear が 1 回余計に入る。繋いだ後は setBand が 150ms 待ってから
    /// 設計するので（GroupDelayPEQDesigner.swift:845, 832-842）、指で動かしているあいだ
    /// 毎回呼んでよい。
    private func edit(_ i: Int, _ change: (inout GroupDelayPEQBand) -> Void) {
        guard designer.settings.bands.indices.contains(i) else { return }
        var next = designer.settings.bands[i]
        change(&next)
        designer.setBand(i, next)
        attachIfNeeded()
    }

    private func setTaps(_ taps: Int) {
        designer.setTaps(taps)
        attachIfNeeded()
    }

    private func setLatency(_ samples: Int) {
        designer.setLatencySamples(samples)
        attachIfNeeded()
    }

    // MARK: 状態

    /// 上の 1 行は「入っているもの」、下は designer の言い分。
    /// 失敗は赤、注意は橙（group_delay_peq.js:366-377 の _qualityWarning が出す文）。
    private var statusBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(headline)
                .font(.system(size: 12, weight: .semibold))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(messageStyle)
                .fixedSize(horizontal: false, vertical: true)
            if designer.design != nil {
                // group_delay_peq.js:616-629 の details 行。
                Text(designer.detailText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: .rect(cornerRadius: ETMetrics.innerRadius, style: .continuous))
    }

    /// 入った内容の 1 行。IRReverbView の loaded と同じ形。
    private var headline: String {
        guard designer.design != nil else { return "No group delay filter" }
        let settings = designer.settings
        return "\(settings.taps) taps / \(Int(settings.sampleRate.rounded())) Hz"
            + " / \(settings.processingChannels) ch"
    }

    /// designer の .detached は「engine に繋がっていない」だが、ここでは
    /// 「送るものが無いので繋いでいない」ほうが普通なので、そちらの文を出す。
    /// 文は designer の .flat のもの（GroupDelayPEQDesigner.swift:745）をそのまま使う。
    private var message: String {
        if case .detached = designer.status, !designer.settings.hasDelay {
            return GroupDelayPEQDesigner.Status.flat.message
        }
        return designer.status.message
    }

    private var messageStyle: AnyShapeStyle {
        if designer.status.isError { return AnyShapeStyle(.red) }
        if designer.status.isWarning { return AnyShapeStyle(.orange) }
        return AnyShapeStyle(.secondary)
    }

    // MARK: バンド

    /// どのバンドを触るか。ParameterRow.bandPicker と同じ形。
    private var bandPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(0..<GroupDelayPEQDesignCore.bandCount, id: \.self) { i in
                    Button { band = i } label: {
                        Text("\(i + 1)")
                            .font(.system(size: 12, weight: band == i ? .bold : .regular))
                            .foregroundStyle(band == i ? AnyShapeStyle(.white)
                                                       : AnyShapeStyle(.secondary))
                            .frame(minWidth: 30, minHeight: 26)
                            .background(band == i ? AnyShapeStyle(.tint)
                                                  : AnyShapeStyle(.quaternary),
                                        in: .rect(cornerRadius: ETMetrics.innerRadius,
                                                  style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Band \(i + 1)")
                    .accessibilityAddTraits(band == i ? [.isSelected] : [])
                }
            }
        }
    }

    /// 選んだバンドのつまみ。名前は上流に合わせた
    /// （group_delay_peq.js:805, 830, 834, 852, 888 の Band / Type / Freq / Delay / Q）。
    @ViewBuilder
    private var bandControls: some View {
        let bands = designer.settings.bands
        if bands.indices.contains(band) {
            let current = bands[band]
            // 遅延の限界はタップ数とレートで決まる（GroupDelayPEQDesigner.swift:155-158）。
            // 0 になることは無いが、Slider は上下が同じ範囲で落ちるので下限を置く。
            let limit = max(designer.settings.delayLimitMs, 0.1)

            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: Binding(get: { current.enabled },
                                     set: { on in edit(band) { $0.enabled = on } })) {
                    Text("Band \(band + 1)").font(.system(size: 14))
                }

                HStack {
                    Text("Type").font(.system(size: 14))
                    Spacer(minLength: 8)
                    Picker("Type", selection: Binding(
                        get: { current.shape },
                        set: { shape in edit(band) { $0.shape = shape } })
                    ) {
                        ForEach(GroupDelayPEQBand.Shape.allCases, id: \.self) { shape in
                            Text(shape.label).tag(shape)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                valueRow("Freq (Hz)", text: String(Int(current.frequency.rounded()))) {
                    ETLogSlider(value: Binding(get: { current.frequency },
                                               set: { hz in edit(band) { $0.frequency = hz } }),
                                range: GroupDelayPEQDesignCore.minimumFrequency
                                    ... GroupDelayPEQDesignCore.maximumFrequency)
                }

                valueRow("Delay (ms)", text: String(format: "%.1f", current.delayMs)) {
                    Slider(value: Binding(get: { min(max(current.delayMs, -limit), limit) },
                                          set: { ms in edit(band) { $0.delayMs = ms } }),
                           in: -limit...limit)
                }

                valueRow("Q", text: String(format: "%.2f", current.q)) {
                    ETLogSlider(value: Binding(get: { current.q },
                                               set: { q in edit(band) { $0.q = q } }),
                                range: GroupDelayPEQDesignCore.minimumQ
                                    ... GroupDelayPEQDesignCore.maximumQ)
                }
            }
        }
    }

    // MARK: Taps と Latency

    private var tapsRow: some View {
        choiceRow("Taps",
                  options: GroupDelayPEQDesignCore.tapsChoices.map {
                      GroupDelayPEQChoice(id: $0, label: String($0))
                  },
                  selected: designer.settings.taps,
                  action: { setTaps($0) })
    }

    /// 上流は選択肢を `${value} samples` と書いている（group_delay_peq.js:648）。
    private var latencyRow: some View {
        choiceRow("Latency",
                  options: GroupDelayPEQDesignCore.latencyChoices.map {
                      GroupDelayPEQChoice(id: $0, label: "\($0) samples")
                  },
                  selected: designer.settings.latencySamples,
                  action: { setLatency($0) })
    }

    // MARK: 部品

    /// 名前・数値・つまみの 2 段。ParameterRow と同じ並びにしてある。
    private func valueRow<Control: View>(_ title: String, text: String,
                                         @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                ValueBox(text: text)
            }
            control()
                .accessibilityLabel(title)
                .accessibilityValue(text)
        }
    }

    /// 札の帯。IRReverbView.choiceRow と同じ形。
    private func choiceRow(_ title: String,
                           options: [GroupDelayPEQChoice],
                           selected: Int,
                           action: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 14))

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 6)],
                      alignment: .leading, spacing: 6) {
                ForEach(options) { option in
                    let isSelected = option.id == selected
                    Button { action(option.id) } label: {
                        Text(option.label)
                            .font(.system(size: 13, weight: isSelected ? .bold : .regular))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundStyle(isSelected ? AnyShapeStyle(.white)
                                                        : AnyShapeStyle(.secondary))
                            .frame(maxWidth: .infinity, minHeight: ETMetrics.hitTarget)
                            .background(isSelected ? AnyShapeStyle(.tint)
                                                   : AnyShapeStyle(.quaternary),
                                        in: .rect(cornerRadius: ETMetrics.innerRadius,
                                                  style: .continuous))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(title) \(option.label)")
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                }
            }
        }
    }
}
