//  FiveBandFIRPEQView.swift
//  5Band FIR PEQ（FiveBandFIRPEQPlugin）。
//
//  --- どこが繋がっているか ---
//  5 本の帯域はカーネルのパラメータではない。カーネルが持っているのは lt（頭ブロック）と
//  fd（足す遅延）の 2 つだけで（Generated/EffectCatalog.swift の FiveBandFIRPEQPlugin）、帯域から FIR を
//  設計して係数を資産として送り込むのは呼び手の仕事。その設計と送り込みは
//  BandFIRPEQDesigner が持っている（DSP/Designers/BandFIRPEQDesigner.swift）。
//  このビューは designer を作って settings を書き換えるだけで、AssetUpload は直に叩かない。
//  送る場所は designer の stage() 1 か所しかない。
//
//  --- lt と fd をスライダーに出さない理由 ---
//  fd は設計の結果から決まる値で、人が触る値ではない。最小位相なら 0、線形位相なら taps/2
//  （BandFIRPEQDesign.filterDelaySamples を決めるところ）。カーネルは beginAsset でこの値を見ている
//  （dsp/plugins/eq/five_band_fir_peq/kernel.cpp:274-275）ので、人が動かした値が入っていると
//  次の送り込みが黙って弾かれる。lt のほうは designer が settings.latency から書く
//  （BandFIRPEQDesigner の pushKernelParameters）ので、ParameterRow から二重に書かせない。
//  だから node.spec.params は 1 本も出していない。触る口は下の Latency の行。
//
//  --- つまみを離すまで書かない理由 ---
//  settings を 1 回書くたびに 150ms 後に staging が走り、そのあいだ鎖全体が素通しになる
//  （AssetUpload の holdOffAudioThread）。ドラッグ中に毎フレーム書くと素通しが連続して
//  音が切れる。だから BandFIRPEQSliderRow は onEditingChanged で離したときだけ渡す。
//
//  --- 図 ---
//  designer が応答の材料を持っている（BandFIRPEQDesign.Response。
//  10Hz〜40kHz を 512 点、responseLowFrequency / responseHighFrequency / responsePoints）。
//
//  **狙いはその場で引く。**latestDesign の応答しか見ていなかったので、つまみを触っても
//  設計が終わるまで図が動かなかった。狙いは BandFIRPEQCore.magnitude(of:at:sampleRate:)
//  で毎回引き、出来上がりは latestDesign の config が今の settings と一致するときだけ描く。
//
//  **掴める印を置いた。**ただし designer へ書くのは離した 1 回だけ。掴んでいるあいだは
//  dragBands に控え、図はその控えで引く。毎フレーム書くと素通しが連続して音が切れる。
//  ホイールが無いので Q は下のつまみのまま（5band も同じ割り切り）。

import Combine
import SwiftUI
import Foundation

// MARK: - designer の持ち主

/// designer を段ごとに 1 個だけ持つ。
///
/// ビューに @StateObject で持たせると 2 つの理由で壊れる。
///   1. カードは畳むと専用ビューを作り直す。EffectCardView の畳んだときの枝と
///      開いたときの枝は別物なので、開閉のたびに @State が捨てられる。
///      帯域の設定が既定へ戻り、開くたびに設計と送り込みがやり直しになる。
///   2. BandFIRPEQDesigner.instance は let。EffeTuneDSP.prepare は rebuildAll() で
///      全段の instance を作り直す（EffeTuneDSP.rebuildAll）ので、持ち越すと死んだ番号へ
///      送り続ける。
///
/// 鍵は Node.id。鎖を組み直しても Node の値は残るので id は変わらず、段を消して入れ直せば
/// 別の id になる。
///
/// **設定の正はNode.design（とvaluesのlt）。**置き場はメモリの中にしか無いので、ここにしか
/// 無い設定はアプリを開き直す・プリセットを読む・共有リンクを開くと既定へ戻っていた
/// （fd:16384を持つ鎖がMinimum Phase・遅延0で戻った）。作るときは段の材料から組み、
/// settingsが変わるたびにNode.designへ書き戻す（DSP/DesignParams.swift）。
@MainActor
final class BandFIRPEQDesignerStore {

    static let shared = BandFIRPEQDesignerStore()

    /// 作ったときの tapId を控える。instance の番号は engine が使い回すことがあるが、
    /// tapId は作るたびに増える（EffeTuneDSP の nextTap）ので、
    /// 作り直しを見落とさない。
    private struct Entry {
        let tapId: UInt32
        let designer: BandFIRPEQDesigner
        /// settingsが変わるたびにNode.designへ書き戻す見張り。Entryと一緒に捨てる。
        let watch: AnyCancellable
    }

    private var entries: [UUID: Entry] = [:]

    private init() {}

    /// この段の designer。無ければ作って start() まで済ませる。
    func designer(for node: EffeTuneDSP.Node,
                  sampleRate: Double,
                  outputChannelCount: Int) -> BandFIRPEQDesigner? {
        guard node.instance != 0 else { return nil }

        if let entry = entries[node.id],
           entry.tapId == node.tapId,
           entry.designer.instance == node.instance {
            // レートやチャンネル数が変わっていれば設計からやり直す。同じなら何もしない
            // （BandFIRPEQDesigner.update(sampleRate:outputChannelCount:) の guard）。
            entry.designer.update(sampleRate: sampleRate,
                                  outputChannelCount: outputChannelCount)
            return entry.designer
        }

        // instance が作り直された。帯域の設定は人が置いたものなので引き継ぐ。
        // 初めて作るときは段が持っている材料から組む。
        let made = BandFIRPEQDesigner(instance: node.instance,
                                      settings: entries[node.id]?.designer.settings
                                          ?? Self.settings(of: node),
                                      sampleRate: sampleRate,
                                      outputChannelCount: outputChannelCount)
        let id = node.id
        // @Publishedは書く直前に新しい値を流すので、受けた値をそのまま書く。
        // 最初の1回（今の値）は落とす。作っただけでは材料は変わっていない。
        let watch = made.$settings.dropFirst().sink { settings in
            EffeTuneDSP.shared.setDesign(settings.designParams, nodeID: id)
        }
        entries[node.id] = Entry(tapId: node.tapId, designer: made, watch: watch)
        prune()
        made.start()
        return made
    }

    /// 段に繋ぎ直す（instanceの作り直し・鎖を読んだ直後。ETAssetReattach.one）。
    /// **置き場が無く、段も材料を持っていなければ作らない。**作ると既定の平らな設計を
    /// 送り込みに行き、そのあいだ鎖全体が素通しになる（AssetUploadのholdOffAudioThread）。
    func sync(node: EffeTuneDSP.Node) {
        guard entries[node.id] != nil || Self.carriesDesign(node) else { return }
        let dsp = EffeTuneDSP.shared
        _ = designer(for: node, sampleRate: dsp.sampleRate,
                     outputChannelCount: Int(dsp.maxChannels))
    }

    /// 段の材料が外から変わった（プリセットの適用・既定へ戻す）。
    /// ltとNode.designから組み直して、違っていればdesignerへ渡す。
    func adopt(node: EffeTuneDSP.Node) {
        guard entries[node.id] != nil || Self.carriesDesign(node) else { return }
        let dsp = EffeTuneDSP.shared
        guard let designer = designer(for: node, sampleRate: dsp.sampleRate,
                                      outputChannelCount: Int(dsp.maxChannels)) else { return }
        let next = Self.settings(of: node)
        if designer.settings != next { designer.settings = next }
    }

    /// 段が持っている材料から組んだ設定。ltとfdはvaluesから読む。
    static func settings(of node: EffeTuneDSP.Node) -> BandFIRPEQSettings {
        BandFIRPEQSettings(designParams: node.design,
                           latency: BandFIRPEQLatency(parameterIndex: value("latencyMode", of: node) ?? 1),
                           filterDelaySamples: value("filterDelaySamples", of: node))
    }

    /// 既定（平ら）でない設計を持っているか。材料を書いていなかった頃の鎖はfdだけで
    /// 線形位相を持っている（BandFIRPEQSettings.init(designParams:)の但し書き）。
    static func carriesDesign(_ node: EffeTuneDSP.Node) -> Bool {
        guard node.spec.type == BandFIRPEQDesigner.kernelType else { return false }
        return !node.design.isEmpty || (value("filterDelaySamples", of: node) ?? 0) > 0
    }

    private static func value(_ name: String, of node: EffeTuneDSP.Node) -> Float? {
        guard let param = node.spec.params.first(where: { $0.name == name }),
              node.values.indices.contains(param.offset) else { return nil }
        return node.values[param.offset]
    }

    /// 鎖から消えた段を捨てる。instance は段と一緒に破棄されるので、資産を外す手当ては要らない。
    private func prune() {
        let live = Set(EffeTuneDSP.shared.nodes.map(\.id))
        entries = entries.filter { live.contains($0.key) }
    }
}

// MARK: - 本体

struct FiveBandFIRPEQView: View {

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    /// この段の designer。作るのは onAppear / onChange の中（どちらもメインスレッド）。
    @State private var designer: BandFIRPEQDesigner?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let designer {
                FiveBandFIRPEQPanel(designer: designer, tapId: node.tapId, nodeId: node.id)
            } else {
                pendingNotice
            }
        }
        .onAppear { attach() }
        // tapId は instance を作り直すたびに増える。instance の番号だけを見ていると、
        // engine が同じ番号を返したときに作り直しを見落として、資産の入っていない instance へ
        // 送ったつもりになる。
        .onChange(of: node.tapId) { _, _ in attach() }
        // 担当するチャンネルが変わると begin へ渡す proc が変わる（AssetUpload.BeginInfo.processingChannels）。
        // 設計そのものは同じなので控えから戻るが、送り直しは要る。
        .onChange(of: node.channelSpec) { _, _ in designer?.refresh() }
    }

    /// engineの幅は置き場のsync / adoptと同じEffeTuneDSP.maxChannelsを渡す（AudioIOが
    /// engineを組んだ出力の幅、2〜16）。前はここだけ2で、3ch以上の出力ではカードが出るたびに
    /// 2と出力の幅を行き来し、そのたびに設計と送り込みをやり直していた（鎖全体が一瞬素通しになる）。
    /// 段ごとの担当幅はdesignerがchainのchannelSpecから自分で引く
    /// （BandFIRPEQDesigner.processingChannels）。
    private func attach() {
        designer = BandFIRPEQDesignerStore.shared.designer(
            for: node,
            sampleRate: dsp.sampleRate,
            outputChannelCount: Int(dsp.maxChannels))
    }

    /// designer がまだ無いとき。instance が出来ていないか、作り直しの最中。
    private var pendingNotice: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No filter loaded")
                .etFont(size: 12, weight: .semibold)
            // 上の文は BandFIRPEQDesignError.instanceMissing と同じ言い方にしてある。
            Text(node.instance == 0
                 ? "The equalizer is not running."
                 : "Preparing the FIR filter…")
                .etFont(size: 11)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary,
                    in: .rect(cornerRadius: ETMetrics.innerRadius, style: .continuous))
    }
}

// MARK: - designer を観測する側

/// designer は class なので、optional の @State では観測できない。ここで受け直す。
private struct FiveBandFIRPEQPanel: View {

    @ObservedObject var designer: BandFIRPEQDesigner
    /// 図に音を重ねるための番号。
    let tapId: UInt32
    /// 畳んでも消えない選択の鍵。
    let nodeId: UUID

    /// 図だけ見る指定。カードを畳むと立つ（EffectCardView の畳んだ枝）。
    @Environment(\.etGraphOnly) private var graphOnly

    /// 下の一枚に出している帯域。
    @State private var selected = 0

    /// 印を掴んでいるあいだの控え。**離すまで designer には書かない。**
    @State private var dragBands: [Int: BandFIRPEQBand] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            graph
            // 畳んでいるあいだは図だけにする。ただし失敗は隠さない。
            if !graphOnly || designer.status.isFailure {
                statusCard.etLocalAudioOnly()
            }
            if !graphOnly {
                globalRows
                Divider()
                bandStrip
                bandPanel
            }
        }
        // 畳むとこの View ごと消えるので、選んでいる帯域は外に覚えておく。
        .etRemembers($selected, key: "band", node: nodeId)
    }

    // MARK: 図

    private var graph: some View {
        FrequencyResponseGraph(
            curves: curves,
            markers: markers,
            frequencyRange: 20...20000,
            // **値域と軸を揃える。**打ち込みもドラッグも ±20 で挟むので、軸が ±24 だと
            // 上下 4dB ぶん「掴んだのに動かない帯」ができる。5band も ±20（FiveBandPEQView）。
            decibelRange: -20...20,
            decibelStep: 6,
            height: ETGraphMetrics.height,
            // 他の PEQ と同じく、入っている音を図に重ねる。
            spectrumTap: tapId,
            onMarkerChanged: { slot, hz, db in
                // **掴んでいるあいだは designer に書かない。**settings を 1 回書くと
                // 150ms 後に staging が走り、そのあいだ鎖が素通しになる。
                var b = shown(slot)
                b.frequency = min(max(hz, 20), 20000)
                b.gain = min(max(db, -20), 20)
                dragBands[slot] = b
            },
            onMarkerSelected: { selected = $0 },
            onMarkerReleased: { slot in
                if let b = dragBands[slot] {
                    // 周波数とゲインは**同じクロージャで**書く。別々に書くと didSet が
                    // 2 回走って素通しが 2 回起きる。
                    edit(slot) { $0.frequency = b.frequency; $0.gain = b.gain }
                }
                dragBands[slot] = nil
            })
    }

    /// 掴んでいるあいだの控えを重ねた帯域。
    private func shown(_ slot: Int) -> BandFIRPEQBand { dragBands[slot] ?? band(slot) }

    private var markers: [ETFrequencyMarker] {
        (0..<BandFIRPEQSettings.bandCount).map { slot in
            let b = shown(slot)
            return ETFrequencyMarker(id: slot, hz: b.frequency, db: b.gain,
                                     label: "\(slot + 1)", isActive: b.enabled)
        }
    }

    /// 狙いと出来上がり。上流の図も同じ 2 本（five_band_fir_peq.js:638-642 の legend）。
    ///
    /// **狙いはその場で引く。**前は latestDesign の応答しか見ていなかったので、
    /// つまみを触っても設計が終わる（150ms の debounce の後）まで図が動かなかった。
    /// BandFIRPEQCore.magnitude(of:at:sampleRate:) は「画面の曲線を引くのに使う」と
    /// 書かれたまま、どこからも呼ばれていなかった。
    ///
    /// **出来上がりは設定が一致するときだけ描く。**古い設計の曲線を新しい狙いの隣に
    /// 置くと、どちらが今の音か読めない。
    private var curves: [ETFrequencyCurve] {
        // 正規化を通した値で引く。範囲の詰めは Config の init の中でしか走らないので、
        // 生の settings を回すと狙いと出来上がりがずれる。
        var settings = designer.settings
        for (slot, b) in dragBands where settings.bands.indices.contains(slot) {
            settings.bands[slot] = b
        }
        let config = BandFIRPEQConfig(settings: settings, sampleRate: designer.sampleRate)
        // 効かない帯域は落とす（BandFIRPEQDesigner の activeBands と同条件）。
        let active = config.bands.filter {
            $0.enabled && ($0.type.changesResponseWithoutGain || $0.gain != 0)
        }
        let rate = Double(config.sampleRate)
        let target = ETFrequencyCurve.sampled(id: "target", count: 220,
                                              width: 1, dashed: true, subdued: true) { hz in
            active.reduce(0.0) { sum, band in
                sum + 20 * log10(max(BandFIRPEQCore.magnitude(of: band, at: hz,
                                                                  sampleRate: rate), 1e-6))
            }
        }

        guard let design = designer.latestDesign, design.config == config else { return [target] }
        let response = design.response
        let count = min(response.frequencies.count, response.realizedDb.count)
        guard count > 1 else { return [target] }
        let realized = (0..<count).map {
            ETFreqPoint(response.frequencies[$0], response.realizedDb[$0])
        }
        return [target, ETFrequencyCurve(id: "realized", points: realized)]
    }

    // MARK: 状態

    /// 上流の status 行（five_band_fir_peq.js:537-554）に当たるもの。
    /// 入っていれば設計の 1 行、失敗していれば理由を赤で出す。
    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(loaded ?? "No filter loaded")
                .etFont(size: 12, weight: .semibold)
            Text(designer.status.message)
                .etFont(size: 11)
                .foregroundStyle(designer.status.isFailure
                                 ? AnyShapeStyle(.red)
                                 : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary,
                    in: .rect(cornerRadius: ETMetrics.innerRadius, style: .continuous))
    }

    /// 入った内容の 1 行。IRLoader が返す行と同じ切り方（IRLoader の `%dch %@ / %d Hz / %.2f s`）。
    /// レートは設計に使った処理レートで、これがヘッダ +12 に入る値と同じ
    /// （BandFIRPEQDesigner.swift の頭、ヘッダ +12 の但し書き）。
    ///
    /// 出すのは失敗していないときだけ。設計し直しているあいだも出すのは、
    /// そのあいだカーネルに入っているのが直前の設計だから（差し替わるのは commit の瞬間）。
    private var loaded: String? {
        guard !designer.status.isFailure, let design = designer.latestDesign else { return nil }
        return String(format: "%d taps %@ / %d Hz / %.2f Hz per bin",
                      design.config.taps,
                      design.config.phase.displayName,
                      design.config.sampleRate,
                      design.resolutionHz)
    }

    // MARK: 全体の設定

    /// 上流の設定も同じ 3 つ（five_band_fir_peq.js:562-586）。
    private var globalRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            menuRow("Phase", selection: $designer.settings.phase,
                    options: BandFIRPEQPhase.allCases) { $0.displayName }
            menuRow("Taps", selection: $designer.settings.taps,
                    options: BandFIRPEQTaps.allCases) { $0.displayName }
            menuRow("Latency", selection: $designer.settings.latency,
                    options: BandFIRPEQLatency.allCases) { $0.displayName }
        }
    }

    private func menuRow<T: Hashable>(_ label: String,
                                      selection: Binding<T>,
                                      options: [T],
                                      name: @escaping (T) -> String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .etFont(size: 14)
                .etRowTitle()
            Spacer(minLength: 8)
            Picker(label, selection: selection) {
                ForEach(options, id: \.self) { option in
                    Text(name(option)).tag(option)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    // MARK: 帯域

    /// どの帯域を触っているかを選ぶ帯。5Band PEQ と同じ形（FiveBandPEQView の bandStrip）。
    private var bandStrip: some View {
        HStack(spacing: 6) {
            ForEach(Array(0..<BandFIRPEQSettings.bandCount), id: \.self) { i in
                chip(i)
            }
        }
    }

    private func chip(_ i: Int) -> some View {
        let isOn = band(i).enabled
        let isPicked = selected == i
        return Button {
            selected = i
        } label: {
            Text("\(i + 1)")
                .etFont(size: 13, weight: isPicked ? .bold : .regular)
                .foregroundStyle(isPicked ? AnyShapeStyle(.white)
                                          : (isOn ? AnyShapeStyle(.primary)
                                                  : AnyShapeStyle(.secondary)))
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(isPicked ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                            in: .rect(cornerRadius: ETMetrics.innerRadius, style: .continuous))
                .opacity(isOn ? 1 : 0.45)
                // 見た目は高さ 30 のまま、押せる面だけを 44pt まで広げる。
                // 横は隣の札との隙間（6pt）を半分ずつ使い、重ならないようにする。
                .padding(.vertical, 7)
                .padding(.horizontal, 3)
                .contentShape(.rect)
                .padding(.vertical, -7)
                .padding(.horizontal, -3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Band \(i + 1)")
        // 切ってあるバンドは不透明度だけで表しているので、VoiceOver には値として伝える。
        .accessibilityValue(isOn ? "" : "Off")
        .accessibilityAddTraits(isPicked ? [.isSelected] : [])
    }

    /// 選んでいる 1 本。範囲は上流の入力欄と同じ
    /// （five_band_fir_peq.js:788-795 の Q、:831-838 の Slope、:890-897 の Freq、
    ///  :907-914 の Gain）。
    private var bandPanel: some View {
        let slot = min(max(selected, 0), BandFIRPEQSettings.bandCount - 1)
        let current = band(slot)
        return VStack(alignment: .leading, spacing: 10) {
            // **下の一枚の頭を他の帯と同じ形にする。**ここだけラベル付きの素の
            // Toggle で、`BAND n` の見出しも電源の形も無かった
            // （5band / 15band / Modal Resonator はどれも見出し行＋power トグル）。
            HStack(spacing: 8) {
                Text("BAND \(slot + 1)")
                    .etFont(size: 10, weight: .semibold)
                    .tracking(0.6)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                Toggle("Enabled", isOn: Binding(get: { current.enabled },
                                                set: { on in edit(slot) { $0.enabled = on } }))
                    .toggleStyle(.power)
                    .labelsHidden()
            }

            menuRow("Type",
                    selection: Binding(get: { current.type },
                                       set: { type in edit(slot) { $0.type = type } }),
                    options: BandFIRPEQFilterType.allCases) { $0.displayName }

            BandFIRPEQSliderRow(label: "Freq (Hz)",
                                value: current.frequency,
                                range: 20...20000,
                                logarithmic: true,
                                decimals: 0,
                                commit: { hz in edit(slot) { $0.frequency = hz } })

            BandFIRPEQSliderRow(label: "Gain (dB)",
                                value: current.gain,
                                range: -20...20,
                                logarithmic: false,
                                decimals: 1,
                                commit: { db in edit(slot) { $0.gain = db } })

            BandFIRPEQSliderRow(label: "Q",
                                value: current.q,
                                range: 0.1...100,
                                logarithmic: true,
                                decimals: 2,
                                commit: { q in edit(slot) { $0.q = q } })

            // Slope が効くのは lp と hp だけ。上流も他の種類では触れなくしている
            // （five_band_fir_peq.js:937-942 の _setSlopeControlsState）。
            if current.type.usesSlope {
                BandFIRPEQSliderRow(label: "Slope (dB/oct)",
                                    value: current.slope,
                                    range: 0.1...384,
                                    logarithmic: true,
                                    decimals: 1,
                                    commit: { slope in edit(slot) { $0.slope = slope } })
            }
        }
    }

    private func band(_ slot: Int) -> BandFIRPEQBand {
        guard designer.settings.bands.indices.contains(slot) else {
            let fallback = BandFIRPEQSettings.defaultFrequencies
            return BandFIRPEQBand(frequency: fallback.indices.contains(slot) ? fallback[slot] : 1000)
        }
        return designer.settings.bands[slot]
    }

    /// 帯域 1 本を書き換える。**instance には触らない。** settings を書くだけで、
    /// didSet が拾って設計し直す（BandFIRPEQDesigner の settings の didSet と settingsChanged）。
    private func edit(_ slot: Int, _ change: (inout BandFIRPEQBand) -> Void) {
        guard designer.settings.bands.indices.contains(slot) else { return }
        change(&designer.settings.bands[slot])
    }
}

// MARK: - つまみの 1 行

/// 名前・値・つまみ。**離すまで commit を呼ばない。**
///
/// settings を 1 回書くたびに 150ms 後に staging が走り、そのあいだ鎖が素通しになる
/// （AssetUpload の holdOffAudioThread）。ドラッグ中に毎フレーム書くと素通しが
/// 連続して音が切れるので、指を離したときだけ渡す。
private struct BandFIRPEQSliderRow: View {

    /// 単位は名前の側に付ける。数値欄には付けない（ParameterRow と同じ）。
    let label: String
    /// designer が持っている値。触っていないあいだはこれをそのまま出す。
    let value: Double
    let range: ClosedRange<Double>
    /// 目盛り。周波数・Q・Slope は対数（five_band_fir_peq.js:22 の _logSliderPosition を
    /// :802 と :845 が呼んでいる）。
    let logarithmic: Bool
    /// 小数の桁。上流の入力欄の step に合わせる。
    let decimals: Int
    let commit: (Double) -> Void

    /// ドラッグ中の値。離したら nil に戻して designer の値へ戻る。
    @State private var draft: Double?

    private var shown: Double { draft ?? value }
    private var text: String { String(format: "%.\(decimals)f", shown) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(label)
                    .etFont(size: 14)
                    .etRowTitle()
                Spacer(minLength: 4)
                field
            }
            Slider(value: Binding(get: { position(of: shown) },
                                  set: { draft = number(at: $0) }),
                   in: 0...1,
                   onEditingChanged: { dragging in
                       guard !dragging else { return }
                       if let draft { commit(draft) }
                       draft = nil
                   })
                .accessibilityLabel(label)
                .accessibilityValue(text)
        }
    }

    /// ValueBox + onTapGesture だと VoiceOver・Voice Control・キーボードから打ち込めない。
    /// 下書きは単位なしの数だけ。
    private var field: some View {
        ETValueField(text: text, label: label,
                     editText: { String(format: "%.\(decimals)f", value) }) { typedValue in
            commit(min(max(typedValue, range.lowerBound), range.upperBound))
        }
    }

    private var lower: Double { range.lowerBound }
    private var upper: Double { range.upperBound }

    /// 値 → つまみの位置（0〜1）。
    private func position(of value: Double) -> Double {
        guard upper > lower else { return 0 }
        let clamped = min(max(value, lower), upper)
        if logarithmic, lower > 0 {
            return (log10(clamped) - log10(lower)) / (log10(upper) - log10(lower))
        }
        return (clamped - lower) / (upper - lower)
    }

    /// つまみの位置 → 値。
    private func number(at position: Double) -> Double {
        guard upper > lower else { return lower }
        let ratio = min(max(position, 0), 1)
        if logarithmic, lower > 0 {
            return pow(10, log10(lower) + ratio * (log10(upper) - log10(lower)))
        }
        return lower + ratio * (upper - lower)
    }
}
