//  FiveBandFIRPEQView.swift
//  5Band FIR PEQ（FiveBandFIRPEQPlugin）。
//
//  --- どこが繋がっているか ---
//  5 本の帯域はカーネルのパラメータではない。カーネルが持っているのは lt（頭ブロック）と
//  fd（足す遅延）の 2 つだけで（Generated/EffectCatalog.swift:446-457）、帯域から FIR を
//  設計して係数を資産として送り込むのは呼び手の仕事。その設計と送り込みは
//  BandFIRPEQDesigner が持っている（DSP/Designers/BandFIRPEQDesigner.swift:631-959）。
//  このビューは designer を作って settings を書き換えるだけで、AssetUpload は直に叩かない。
//  送る場所は designer の stage(:814-856) 1 か所しかない。
//
//  --- lt と fd をスライダーに出さない理由 ---
//  fd は設計の結果から決まる値で、人が触る値ではない。最小位相なら 0、線形位相なら taps/2
//  （BandFIRPEQDesigner.swift:497）。カーネルは beginAsset でこの値を見ている
//  （dsp/plugins/eq/five_band_fir_peq/kernel.cpp:274-275）ので、人が動かした値が入っていると
//  次の送り込みが黙って弾かれる。lt のほうは designer が settings.latency から書く
//  （BandFIRPEQDesigner.swift:877-888）ので、ParameterRow から二重に書かせない。
//  だから node.spec.params は 1 本も出していない。触る口は下の Latency の行。
//
//  --- つまみを離すまで書かない理由 ---
//  settings を 1 回書くたびに 150ms 後に staging が走り、そのあいだ鎖全体が素通しになる
//  （AssetUpload.swift:678 の holdOffAudioThread）。ドラッグ中に毎フレーム書くと素通しが連続して
//  音が切れる。だから BandFIRPEQSliderRow は onEditingChanged で離したときだけ渡す。
//
//  --- 図 ---
//  designer が応答の材料を持っている（BandFIRPEQDesign.Response、:225-246。
//  10Hz〜40kHz を 512 点、BandFIRPEQDesigner.swift:571-586）。
//
//  **狙いはその場で引く。**latestDesign の応答しか見ていなかったので、つまみを触っても
//  設計が終わるまで図が動かなかった。狙いは BandFIRPEQDesigner.magnitude(of:at:sampleRate:)
//  で毎回引き、出来上がりは latestDesign の config が今の settings と一致するときだけ描く。
//
//  **掴める印を置いた。**ただし designer へ書くのは離した 1 回だけ。掴んでいるあいだは
//  dragBands に控え、図はその控えで引く。毎フレーム書くと素通しが連続して音が切れる。
//  ホイールが無いので Q は下のつまみのまま（5band も同じ割り切り）。

import SwiftUI
import Foundation

// MARK: - designer の持ち主

/// designer を段ごとに 1 個だけ持つ。
///
/// ビューに @StateObject で持たせると 2 つの理由で壊れる。
///   1. カードは畳むと専用ビューを作り直す。畳んだときの枝（EffectCardView.swift:49-60）と
///      開いたときの枝（:61-77）は別物なので、開閉のたびに @State が捨てられる。
///      帯域の設定が既定へ戻り、開くたびに設計と送り込みがやり直しになる。
///   2. BandFIRPEQDesigner.instance は let（:679-680）。EffeTuneDSP.prepare は rebuildAll() で
///      全段の instance を作り直す（EffeTuneDSP.swift:594-607）ので、持ち越すと死んだ番号へ
///      送り続ける。
///
/// 鍵は Node.id。鎖を組み直しても Node の値は残るので id は変わらず、段を消して入れ直せば
/// 別の id になる。
@MainActor
final class BandFIRPEQDesignerStore {

    static let shared = BandFIRPEQDesignerStore()

    /// 作ったときの tapId を控える。instance の番号は engine が使い回すことがあるが、
    /// tapId は作るたびに増える（EffeTuneDSP.swift:556-559 の nextTap）ので、
    /// 作り直しを見落とさない。
    private struct Entry {
        let tapId: UInt32
        let designer: BandFIRPEQDesigner
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
            // （BandFIRPEQDesigner.swift:726-728 の guard）。
            entry.designer.update(sampleRate: sampleRate,
                                  outputChannelCount: outputChannelCount)
            return entry.designer
        }

        // instance が作り直された。帯域の設定は人が置いたものなので引き継ぐ。
        let made = BandFIRPEQDesigner(instance: node.instance,
                                      settings: entries[node.id]?.designer.settings ?? .default,
                                      sampleRate: sampleRate,
                                      outputChannelCount: outputChannelCount)
        entries[node.id] = Entry(tapId: node.tapId, designer: made)
        prune()
        made.start()
        return made
    }

    /// 鎖から消えた段を捨てる。instance は段と一緒に破棄されるので、資産を外す手当ては要らない。
    private func prune() {
        let live = Set(EffeTuneDSP.shared.chain.map(\.id))
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
        // 担当するチャンネルが変わると begin へ渡す proc が変わる（AssetUpload.swift:209）。
        // 設計そのものは同じなので控えから戻るが、送り直しは要る。
        .onChange(of: node.channelSpec) { _, _ in designer?.refresh() }
    }

    /// engine を組むときに渡している幅。AudioIO.swift:157 と :383 のどちらも 2 の直値で、
    /// engine 側の値を外に出している property は無い。段ごとの担当幅は designer が
    /// chain の channelSpec から自分で引く（BandFIRPEQDesigner.swift:928-931）。
    private static let engineChannels = 2

    private func attach() {
        designer = BandFIRPEQDesignerStore.shared.designer(
            for: node,
            sampleRate: dsp.sampleRate,
            outputChannelCount: Self.engineChannels)
    }

    /// designer がまだ無いとき。instance が出来ていないか、作り直しの最中。
    private var pendingNotice: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No filter loaded")
                .font(.system(size: 12, weight: .semibold))
            // 上の文は BandFIRPEQDesignError.instanceMissing（:259）と同じ言い方にしてある。
            Text(node.instance == 0
                 ? "The equalizer is not running."
                 : "Preparing the FIR filter…")
                .font(.system(size: 11))
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

    /// 図だけ見る指定。カードを畳むと立つ（EffectCardView.swift:55）。
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
                statusCard
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
            caption: "Drag a handle for frequency and gain. Target is dashed.",
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
    /// BandFIRPEQDesigner.magnitude(of:at:sampleRate:) は「画面の曲線を引くのに使う」と
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
                sum + 20 * log10(max(BandFIRPEQDesigner.magnitude(of: band, at: hz,
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
                .font(.system(size: 12, weight: .semibold))
            Text(designer.status.message)
                .font(.system(size: 11))
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

    /// 入った内容の 1 行。IRLoader が返す行と同じ切り方（IRLoader.swift:297-299）。
    /// レートは設計に使った処理レートで、これがヘッダ +12 に入る値と同じ
    /// （BandFIRPEQDesigner.swift:31 の但し書き）。
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
                .font(.system(size: 14))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
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

    /// どの帯域を触っているかを選ぶ帯。5Band PEQ と同じ形（FiveBandPEQView.swift:397-420）。
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
                .font(.system(size: 13, weight: isPicked ? .bold : .regular))
                .foregroundStyle(isPicked ? AnyShapeStyle(.white)
                                          : (isOn ? AnyShapeStyle(.primary)
                                                  : AnyShapeStyle(.secondary)))
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(isPicked ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                            in: .rect(cornerRadius: ETMetrics.innerRadius, style: .continuous))
                .opacity(isOn ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Band \(i + 1)")
        .accessibilityAddTraits(isPicked ? [.isSelected] : [])
    }

    /// 選んでいる 1 本。範囲は上流の入力欄と同じ
    /// （five_band_fir_peq.js:788-795 の Q、:831-838 の Slope、:890-897 の Freq、
    ///  :907-914 の Gain）。
    private var bandPanel: some View {
        let slot = min(max(selected, 0), BandFIRPEQSettings.bandCount - 1)
        let current = band(slot)
        return VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { current.enabled },
                                 set: { on in edit(slot) { $0.enabled = on } })) {
                Text("Band \(slot + 1)").font(.system(size: 14))
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
    /// didSet が拾って設計し直す（BandFIRPEQDesigner.swift:686-688 と :751-762）。
    private func edit(_ slot: Int, _ change: (inout BandFIRPEQBand) -> Void) {
        guard designer.settings.bands.indices.contains(slot) else { return }
        change(&designer.settings.bands[slot])
    }
}

// MARK: - つまみの 1 行

/// 名前・値・つまみ。**離すまで commit を呼ばない。**
///
/// settings を 1 回書くたびに 150ms 後に staging が走り、そのあいだ鎖が素通しになる
/// （AssetUpload.swift:678 の holdOffAudioThread）。ドラッグ中に毎フレーム書くと素通しが
/// 連続して音が切れるので、指を離したときだけ渡す。
private struct BandFIRPEQSliderRow: View {

    /// 単位は名前の側に付ける。数値欄には付けない（ParameterRow.swift:220-230 と同じ）。
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
    /// 数値欄に打ち込み中。形は FiveBandPEQView.swift:251-271 と同じ。
    @State private var typing = false
    @State private var typed = ""

    private var shown: Double { draft ?? value }
    private var text: String { String(format: "%.\(decimals)f", shown) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
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

    private var field: some View {
        Group {
            if typing {
                TextField("", text: $typed)
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(width: ETMetrics.valueWidth, height: ETMetrics.controlHeight)
                    .background(.quaternary,
                                in: .rect(cornerRadius: ETMetrics.innerRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: ETMetrics.innerRadius,
                                              style: .continuous).stroke(.tint, lineWidth: 1))
                    .submitLabel(.done)
                    .onSubmit { commitTyped() }
            } else {
                ValueBox(text: text)
                    .onTapGesture {
                        typed = String(format: "%.\(decimals)f", value)
                        typing = true
                    }
            }
        }
    }

    /// 打ち込みは 1 回で決まるので、そのまま渡す。
    private func commitTyped() {
        typing = false
        guard let typedValue = Double(typed.trimmingCharacters(in: .whitespaces)) else { return }
        commit(min(max(typedValue, range.lowerBound), range.upperBound))
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
