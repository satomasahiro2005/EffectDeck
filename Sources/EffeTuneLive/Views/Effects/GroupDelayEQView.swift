//  GroupDelayEQView.swift
//  Group Delay EQ（GroupDelayEqPlugin）。
//
//  設計そのものは GroupDelayEQDesigner が全部持っている（DSP/Designers/
//  GroupDelayEQDesigner.swift）。ここはその designer を画面へ繋ぐだけ。
//  帯の遅延を受け取って designer の口へ渡し、designer が出す段（stage）と
//  注意書きを出す。係数を送るのは designer の中（:765-822 の stageFilter）。
//
//  --- ParameterRow を 1 つも出していない理由 ---
//  このエフェクトのパラメータは latencyMode(lt) と filterDelaySamples(fd) の 2 つだけで
//  （Generated/EffectCatalog.swift:520-531）、どちらも designer が握っている。
//  送り込む直前に pushKernelParameters が offset 0/1 を上書きする
//  （GroupDelayEQDesigner.swift:830-846）ので、ParameterRow で人が触っても
//  次の送り込みで designer の値に戻される。だから行ごと出さない。
//  latency を動かす口は下の Latency（setHeadBlock）の方。
//
//  帯の遅延 15 本と taps は**カーネルのパラメータではない**（designer:485）。
//  鎖にも PipelineStore にも載らないので、アプリを立ち上げ直すと消える。
//
//  --- 図を出していない理由 ---
//  材料はある。designer.filter?.response に目標と実測の群遅延（ms）が入っていて、
//  上流もその 2 本を重ねている（group_delay_eq.js:616-617 の Target / Realized）。
//  ここでは配線だけにして、数字（Latency と Ripple）で出す。描くならそこから。
//
//  --- 状態の置き場 ---
//  designer はビューの中では持てない。下の ETGroupDelayEQDesigners を参照。

import SwiftUI
import Foundation

// MARK: - designer の置き場

/// Group Delay EQ の designer を、ビューの外で instance ごとに持つ。
///
/// **@StateObject に持たせると壊れる。** カードは List の行で
/// （PipelineView.swift:157）、畳んだときと開いたときで別の枝に出るうえ、
/// 画面の外へ送るとビューごと捨てられる。designer をビューに持たせると
/// そのたびに帯の遅延が 0 へ戻るのに、カーネルへ送った係数は生きたまま残る。
/// 画面は素通しの顔で音は掛かったまま、という食い違いになる。
///
/// 身元は instance の番号ではなく Node.id にする。engine を用意し直すと
/// instance は全部作り直されるが（EffeTuneDSP.swift:594 の rebuildAll）、
/// Node は同じものが残る。作り直されたかどうかは tapId で見る。
/// tapId は instance を作るたびに必ず増える（同 :556-557 の nextTap）。
/// instance の番号の方は作り直しで同じものが返ってくることがあるので、
/// これを作り直しの合図には使えない。
@MainActor
final class ETGroupDelayEQDesigners {

    static let shared = ETGroupDelayEQDesigners()

    private final class Entry {
        let designer: GroupDelayEQDesigner
        /// 最後に面倒を見た instance の世代。
        var tapId: UInt32
        init(designer: GroupDelayEQDesigner, tapId: UInt32) {
            self.designer = designer
            self.tapId = tapId
        }
    }

    private var entries: [UUID: Entry] = [:]

    private init() {}

    /// この段の designer。無ければ作る。
    ///
    /// **ここでは繋がない。** ビューの init から呼ぶので、
    /// @Published を書くと「描いている最中に状態を変えた」になる。
    /// 繋ぐのは onAppear から呼ぶ sync(node:) の方。
    func designer(for node: EffeTuneDSP.Node) -> GroupDelayEQDesigner {
        if let found = entries[node.id] { return found.designer }
        let made = GroupDelayEQDesigner(sampleRate: EffeTuneDSP.shared.sampleRate,
                                        taps: Self.taps(of: node),
                                        headBlock: Self.headBlock(of: node))
        entries[node.id] = Entry(designer: made, tapId: 0)
        return made
    }

    /// 段と designer の繋がりを合わせる。カードが出たときと、instance が
    /// 作り直されたときに呼ぶ。
    func sync(node: EffeTuneDSP.Node) {
        release()
        guard let entry = entries[node.id] else { return }
        let designer = entry.designer

        if entry.tapId != node.tapId {
            entry.tapId = node.tapId
            // 番号が同じでも別の instance なので、attach の
            // `guard self.instance != instance`（designer:587）を通すために
            // いったん 0 へ落とす。
            //
            // **detach() は使わない。** detach は古い番号へ
            // AssetUpload.clear（abort）を撃つが、その番号は作り直しで
            // もう別の段のものになっている可能性がある。
            // 古い instance は EffeTuneDSP が壊すので、外す必要もない。
            designer.attach(instance: 0)
        }

        // ペイロードの +12 に入る値。et_engine_prepare へ渡した値と
        // ずれていると commit が ET_ERR_ARGS で落ちる（designer:526-528）。
        // AudioIO.processingRate と同じ値だが、prepare へ渡している
        // こちらを正とする（AudioIO.swift:383 と :493）。
        designer.setSampleRate(EffeTuneDSP.shared.sampleRate)
        designer.attach(instance: node.instance)
    }

    /// 鎖から消えた段の designer を捨てる。
    ///
    /// ここでも detach() は呼ばない。段を消すと EffeTuneDSP が instance ごと
    /// 壊す（EffeTuneDSP.swift:678-689 の retire）ので資産も一緒に消える。
    /// attach(instance: 0) は走っている設計を止めて番号を手放すだけで、
    /// engine には触らない（designer:684-685 の refresh が頭で cancel する）。
    private func release() {
        guard !entries.isEmpty else { return }
        let alive = Set(EffeTuneDSP.shared.chain.map(\.id))
        let doomed = entries.filter { !alive.contains($0.key) }
        for (id, entry) in doomed {
            entry.designer.attach(instance: 0)
            entries.removeValue(forKey: id)
        }
    }

    // MARK: 鎖に残っている値から戻す

    /// taps は fd（filterDelaySamples）= taps/2 から戻せる（designer:832）。
    private static func taps(of node: EffeTuneDSP.Node) -> Int {
        guard let param = node.spec.params.first(where: { $0.name == "filterDelaySamples" }),
              node.values.indices.contains(param.offset) else { return 16384 }
        return Int(node.values[param.offset].rounded()) * 2
    }

    /// headBlock は lt（latencyMode）の**添字**から戻せる（designer:831）。
    private static func headBlock(of node: EffeTuneDSP.Node) -> UInt32 {
        guard let param = node.spec.params.first(where: { $0.name == "latencyMode" }),
              node.values.indices.contains(param.offset) else { return 128 }
        let index = Int(node.values[param.offset].rounded())
        guard GroupDelayEQDesign.headBlockChoices.indices.contains(index) else { return 128 }
        return GroupDelayEQDesign.headBlockChoices[index]
    }
}

// MARK: - 帯の名前

private enum GroupDelayEQBands {

    /// 帯に出す字。GroupDelayEQDesign.bands と同じ並び。
    static let short = ["25", "40", "63", "100", "160", "250", "400", "630",
                        "1k", "1.6k", "2.5k", "4k", "6.3k", "10k", "16k"]

    /// group_delay_eq.js:2-18 の BANDS の name。
    static let full = ["25 Hz", "40 Hz", "63 Hz", "100 Hz", "160 Hz", "250 Hz",
                       "400 Hz", "630 Hz", "1.0 kHz", "1.6 kHz", "2.5 kHz",
                       "4.0 kHz", "6.3 kHz", "10 kHz", "16 kHz"]

    static func fullName(_ band: Int) -> String {
        full.indices.contains(band) ? full[band] : "Band \(band + 1)"
    }

    static func shortName(_ band: Int) -> String {
        short.indices.contains(band) ? short[band] : "\(band + 1)"
    }

    /// group_delay_eq.js:666 の _formatDelay。
    static func delayText(_ milliseconds: Double) -> String {
        let sign = milliseconds > 0 ? "+" : ""
        return sign + String(format: "%.1f ms", milliseconds)
    }

    /// 遅延をその帯の周波数での位相の回転として読む。
    /// group_delay_eq.js:673-686 の _formatAngle。1 周を超えても読めるように
    /// 「何周と残りの角度」で出す。
    static func angleText(band: Int, milliseconds: Double) -> String {
        guard GroupDelayEQDesign.bands.indices.contains(band) else { return "" }
        let degrees = 0.36 * GroupDelayEQDesign.bands[band] * milliseconds
        let magnitude = degrees < 0 ? -degrees : degrees
        let sign = degrees < 0 ? "-" : "+"
        var cycles = Int((magnitude / 360).rounded(.down))
        var angle = Int(((magnitude - Double(cycles) * 360)).rounded())
        if angle == 360 {
            angle = 0
            cycles += 1
        }
        return cycles == 0 ? "\(sign)\(angle)°" : "\(sign)\(cycles)c\(angle)°"
    }
}

// MARK: - 本体

struct GroupDelayEQView: View {

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP
    /// 持ち主は ETGroupDelayEQDesigners。ここは見ているだけ。
    @ObservedObject private var designer: GroupDelayEQDesigner

    /// 図だけ見る指定。畳んだカードにはこの下の操作を出さない。
    @Environment(\.etGraphOnly) private var graphOnly

    /// 下の一枚に出している帯。
    @State private var selected = 0

    /// designer を置き場から引くために init を書いている。
    /// @MainActor は置き場が MainActor だから。
    @MainActor
    init(index: Int, node: EffeTuneDSP.Node, dsp: EffeTuneDSP) {
        self.index = index
        self.node = node
        _dsp = ObservedObject(wrappedValue: dsp)
        _designer = ObservedObject(wrappedValue: ETGroupDelayEQDesigners.shared.designer(for: node))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            status

            if !graphOnly {
                bandStrip
                Divider()
                bandPanel
                Divider()
                tapsRow
                latencyRow
            }
        }
        // 初めて繋いだときだけ、全部 0ms なので designer が資産を外しに行く
        // （designer:697 の refresh）。AssetUpload.clear は master bypass を上げて
        // 音のスレッドが 2 周するのを待つので、そこで音が一瞬途切れる。
        // 2 度目からは attach が同じ番号で弾く（designer:587）ので起きない。
        .onAppear { ETGroupDelayEQDesigners.shared.sync(node: node) }
        // instance を作り直したら繋ぎ直す。番号は同じものが返り得るので
        // tapId も見る（どちらか片方では取りこぼす）。
        .onChange(of: node.tapId) { _, _ in ETGroupDelayEQDesigners.shared.sync(node: node) }
        .onChange(of: node.instance) { _, _ in ETGroupDelayEQDesigners.shared.sync(node: node) }
    }

    // MARK: 状態

    /// 上流の status 行と details 行（group_delay_eq.js:637-650）に当たるもの。
    private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(designer.stage.message)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(failed ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                .fixedSize(horizontal: false, vertical: true)

            if let warning = designer.warning {
                Text(warning)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let details = details {
                Text(details)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary,
                    in: .rect(cornerRadius: ETMetrics.innerRadius, style: .continuous))
    }

    private var failed: Bool {
        if case .failed = designer.stage { return true }
        return false
    }

    /// 入ったものの 1 行。設計が出来ていないあいだは出さない。
    /// 数え方は group_delay_eq.js:519-531 の _renderDetails と同じで、
    /// 遅延は headBlock + taps/2。
    private var details: String? {
        guard let filter = designer.filter else { return nil }
        let samples = Int(designer.headBlock) + designer.taps / 2
        let rate = designer.sampleRate > 0 ? designer.sampleRate : 48000
        let milliseconds = String(format: "%.1f", Double(samples) * 1000 / rate)
        let ripple = String(format: "%.2f", filter.rippleDb)
        return "Latency \(samples) samples / \(milliseconds) ms · Ripple \(ripple) dB"
    }

    // MARK: 帯を選ぶ

    private var bandStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("BANDS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                textButton("Reset") { designer.reset() }
            }
            chips
        }
    }

    /// 15 個は横に収まらないので送る。選んだ番号は見える位置まで寄せる。
    /// 作りは 15BandGEQView.swift:265-279 と同じ。
    private var chips: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(Array(0..<bandCount), id: \.self) { band in
                        chip(band).id(band)
                    }
                }
                .padding(.vertical, 1)
            }
            .onChange(of: selected) { _, new in
                withAnimation(.snappy(duration: 0.2)) { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }

    private func chip(_ band: Int) -> some View {
        let isPicked = selected == band
        let isFlat = delay(band) == 0
        return Button {
            selected = band
        } label: {
            VStack(spacing: 1) {
                Text(GroupDelayEQBands.shortName(band))
                    .font(.system(size: 12, weight: isPicked ? .bold : .regular))
                Text(String(format: "%+.1f", delay(band)))
                    .font(.system(size: 10, design: .monospaced))
                    .opacity(isFlat ? 0.45 : 1)
            }
            .foregroundStyle(isPicked ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .frame(minWidth: ETMetrics.hitTarget, minHeight: ETMetrics.hitTarget)
            .padding(.horizontal, 6)
            .background(isPicked ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                        in: .rect(cornerRadius: ETMetrics.innerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(GroupDelayEQBands.fullName(band))
        .accessibilityValue(GroupDelayEQBands.delayText(delay(band)))
    }

    // MARK: 選んでいる帯

    private var bandPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("BAND \(selected + 1) · \(GroupDelayEQBands.fullName(selected))")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                textButton("Reset Band") { designer.setDelay(0, band: selected) }
            }

            HStack(spacing: 8) {
                Text("Delay")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(GroupDelayEQBands.delayText(delay(selected)))
                    .font(.system(size: 13, design: .monospaced))
                Text(GroupDelayEQBands.angleText(band: selected, milliseconds: delay(selected)))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            // 動かしているあいだ何度も設計しないよう、designer の側が 150ms 待つ
            // （designer:683 の refresh）。掴んだまま毎フレーム呼んでよい。
            Slider(value: Binding(get: { clampedDelay(selected) },
                                  set: { designer.setDelay($0, band: selected) }),
                   in: -limit...limit,
                   step: 0.1)
                .accessibilityLabel(GroupDelayEQBands.fullName(selected))
                .accessibilityValue(GroupDelayEQBands.delayText(delay(selected)))
        }
    }

    // MARK: taps と latency

    private var tapsRow: some View {
        let current = designer.taps
        let options = GroupDelayEQDesign.tapsChoices.map { taps -> (name: String, selected: Bool) in
            (name: "\(taps)", selected: taps == current)
        }
        return choiceRow(title: "Taps", options: options) { position in
            designer.setTaps(GroupDelayEQDesign.tapsChoices[position])
        }
    }

    /// latency を変えても設計はやり直さない。出来ている係数を送り直すだけ
    /// （designer:641-653 の setHeadBlock）。
    /// 表示名は IRReverbView.swift:246 と同じ形にする。
    private var latencyRow: some View {
        let current = designer.headBlock
        let options = GroupDelayEQDesign.headBlockChoices
            .map { block -> (name: String, selected: Bool) in
                (name: (block == 0 ? "Zero" : "\(block) samples"), selected: block == current)
            }
        return choiceRow(title: "Latency", options: options) { position in
            designer.setHeadBlock(GroupDelayEQDesign.headBlockChoices[position])
        }
    }

    /// 選択肢の帯。名前が長いので横 1 列に詰めず、幅に合わせて折り返す
    /// （IRReverbView.swift:208-241 と同じ作り）。
    private func choiceRow(title: String,
                           options: [(name: String, selected: Bool)],
                           action: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 14))

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 6)],
                      alignment: .leading, spacing: 6) {
                ForEach(Array(options.enumerated()), id: \.offset) { position, option in
                    Button {
                        action(position)
                    } label: {
                        Text(option.name)
                            .font(.system(size: 13, weight: option.selected ? .bold : .regular))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundStyle(option.selected ? AnyShapeStyle(.white)
                                                             : AnyShapeStyle(.secondary))
                            .frame(maxWidth: .infinity, minHeight: ETMetrics.hitTarget)
                            .background(option.selected ? AnyShapeStyle(.tint)
                                                        : AnyShapeStyle(.quaternary),
                                        in: .rect(cornerRadius: ETMetrics.innerRadius,
                                                  style: .continuous))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(title) \(option.name)")
                    .accessibilityAddTraits(option.selected ? [.isSelected] : [])
                }
            }
        }
    }

    /// 字だけのボタン。当たり判定は 44pt まで広げる
    /// （15BandGEQView.swift:329-338 と同じ）。
    private func textButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.tint)
                .frame(minWidth: ETMetrics.hitTarget, minHeight: ETMetrics.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 値の出し入れ

    private var bandCount: Int { GroupDelayEQDesign.bands.count }

    private func delay(_ band: Int) -> Double {
        designer.delaysMs.indices.contains(band) ? designer.delaysMs[band] : 0
    }

    /// スライダの上限。taps とレートで決まる（designer:546）。
    private var limit: Double {
        let value = designer.delayLimitMs
        return value > 0 ? value : 1
    }

    /// designer も同じ上限で切っているが、範囲の外の値を Binding に渡すと
    /// Slider が落ちるので、ここでも入れておく。
    private func clampedDelay(_ band: Int) -> Double {
        min(max(delay(band), -limit), limit)
    }
}
