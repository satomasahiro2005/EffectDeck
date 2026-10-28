//  FIRCrossoverView.swift
//  FIR Crossover（FIRCrossoverPlugin）。
//
//  --- 何を繋いだか ---
//  FIRCrossoverDesigner は在るのに呼び手が居なかった。ここがその呼び手。
//  やることは 3 つで、designer の口に合わせてあるだけ。
//    1. parameterWriter を EffeTuneDSP.setValue へ向ける
//    2. onAssetCommitted を EffeTuneDSP.republish へ向ける
//    3. attach(Target) を呼ぶ。以後つまみは designer.update{} を通す
//  designer も AssetUpload.send も @MainActor なので、ここから呼ぶぶんには
//  「音のスレッドからは絶対に呼ばない」（AssetUpload.swift の頭）を満たしている。
//
//  --- designer をビューに持たせない理由 ---
//  EffectCardView はこのビューを 2 か所で作る。畳んでいるとき（図だけの形）と
//  開いているときで、位置が違うので @StateObject にすると別物が 2 つできる。
//  しかも畳む／開くたびに作り直されるので、そのたびに designer の既定へ戻って
//  262144 点 FFT を 3 回やり直すことになる。
//  周波数・傾き・位相・tapsはETParamに席が無く、それも畳んだ瞬間に消える。
//  だから段（Node.id）ごとの置き場に入れて、両方の位置から同じものを引く。
//  Matrix の経路が同じ理由で MatrixRouting（MatrixView.swift）に入っている。
//
//  --- 出力IFの本数 ---
//  帯ごとにステレオ 1 対を吐くので、出口が 4〜16 の偶数でないと成り立たない。
//  カーネルは channelCount == 2 のとき何もせずに戻り
//  （dsp/plugins/basics/fir_crossover/kernel.cpp:105-106）、
//  validateBegin も processingChannels < 4 と > max_channels_ を弾く（同 :323-325）。
//  engine と処理幅は接続中の出力IFに合わせる。4ch 以上のIFを接続し、
//  Routing を All にしたときだけ designer が資産を送れる。
//  上流も同じ条件で _renderBusError（fir_crossover.js:615-622）を出すので、
//  文言はそれに合わせた。
//
//  --- 図は出していない ---
//  上流の図（fir_crossover.js:681-695 の canvas と 839-924 の drawGraph）は、
//  bc / f1..f3 / s1..s3 だけから帯ごとの線を引いている。このうち鎖が持っているのは
//  bc だけで、周波数と傾きはパラメータではない。上流でも DSP へは行かず
//  （fir_crossover.js:86-92 の _packedParameters は lt / fd / bc の 3 つだけ）、
//  係数の中に溶けて資産として流し込まれる。
//  dsp/generated/cpp/FIRCrossoverPluginParams.h も float 3 つで、
//  Generated/EffectCatalog.swift の FIRCrossoverPlugin はそれを写したもの。
//
//  Phase（pm、fir_crossover.js:635-638）と Taps（tp、同 639-645）も同じ。
//  これらは上流が鎖に書くので（fir_crossover.js:96-121のgetParameters）、Node.designに
//  同じ綴りで持つ（DSP/DesignParams.swift）。web版やプリセットから来た値は
//  FIRCrossoverDesigners.syncが読んで設計に使い、保存するときもそのまま書き戻す。
//  操作はまだ出していないので、この画面から変えることはできない。
//
//  Filter Delay Samples（fd）は逆に、パラメータなのに画面へ出さない。
//  上流は fir_crossover.js:90 の `fd: this.pm === 'min' ? 0 : this.tp / 2` で
//  pm と tp から計算するだけで、createUI に操作は無い
//  （getSerializableParameters も同 123-127 で fd を消している）。
//  こちらでは designer が同じ式で書き戻す（FIRCrossoverDesigner.pushParameters）。
//
//  並びは上流と同じで、error → Latency → Band Count。
//  error の場所には、出口が足りているときだけ designer の状態を出す。
//  .unavailable の文は busError と同じことを言うので、重ねない。

import SwiftUI
import Foundation

struct FIRCrossoverView: View {

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    // designer を引くのは body の中。View の init は MainActor ではないが
    // body はそうなので、@MainActor の置き場へはここから触る。
    var body: some View {
        FIRCrossoverBody(index: index,
                         node: node,
                         dsp: dsp,
                         designer: FIRCrossoverDesigners.shared.designer(for: node.id))
    }
}

// MARK: - 中身

private struct FIRCrossoverBody: View {

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP
    @ObservedObject var designer: FIRCrossoverDesigner

    private var processingChannels: Int { EffeTuneDSP.routedChannels(of: node) }

    /// fir_crossover.js:76-78 の _maximumBandCount。0 なら成り立たない。
    private var maximumBandCount: Int {
        FIRCrossoverSettings.maximumBandCount(processingChannels: processingChannels)
    }

    /// fir_crossover.js:26 の maxBands（出口が変わると同 561 で入れ直す）。0 のときは 2 に倒れる。
    /// 押せるのは先頭からこの本数まで（同 790-791 の radio.disabled）。
    private var maxBands: Int { maximumBandCount == 0 ? 2 : maximumBandCount }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // FIRCrossoverDesigner の .unavailable の文は busError と
            // 同じことを言う。出口が足りないときは busError だけ出す。
            if maximumBandCount == 0 {
                busError
            } else {
                progress.etLocalAudioOnly()
            }
            latencyRow
            bandCountRow
        }
        .onAppear { connect() }
        // 鎖を組み直すと instance が変わる（EffeTuneDSP.rebuildAll）。
        // 送り先が別物になっているので繋ぎ直す。
        .onChange(of: node.instance) { _, _ in connect() }
        // Routing を Stereo / All 間で切り替えたときも instance は同じなので、
        // Target が持つ処理チャンネル数だけを更新する。
        .onChange(of: processingChannels) { _, _ in connect() }
    }

    // MARK: designer へ繋ぐ

    /// 何度呼んでもよい。attach は同じ Target なら何もしない
    /// （FIRCrossoverDesigner.attach）。
    private func connect() {
        FIRCrossoverDesigners.shared.prune(keeping: dsp.nodes.map(\.id))
        FIRCrossoverDesigners.shared.sync(node: node)
    }

    // MARK: Latency

    /// fir_crossover.js:646-652。選択肢の表示は `${value} samples`。
    /// lt は enum なので values に入っているのは添字のほう。
    private var latencyRow: some View {
        let latency = param("lt")
        let options = FIRCrossoverSettings.latencyModeValues
        let selected = min(max(Int(value(latency).rounded()), 0), options.count - 1)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Latency")
                    .etFont(size: 14)
                    .etRowTitle()
                Spacer(minLength: 4)
                Text("\(options[selected]) samples")
                    .etFont(size: 13, design: .monospaced)
                    .foregroundStyle(.secondary)
            }
            FIRCrossoverChoiceStrip(
                options: options,
                selectedIndex: selected,
                enabledCount: options.count,
                accessibilityUnit: "samples",
                onSelect: { i in
                    apply { $0.latencyModeIndex = i }
                    set(latency, Float(i))
                })
        }
    }

    // MARK: Band Count

    /// fir_crossover.js:655-676。2/3/4 のラジオで、使えない本数は押せない。
    /// bc は enum ではなく数なので、values には 2/3/4 がそのまま入る。
    private var bandCountRow: some View {
        let bands = param("bc")
        let options = [2, 3, 4]
        let current = Int(value(bands).rounded())

        return VStack(alignment: .leading, spacing: 6) {
            Text("Band Count")
                .etFont(size: 14)
                .etRowTitle()
            FIRCrossoverChoiceStrip(
                options: options,
                selectedIndex: options.firstIndex(of: current),
                enabledCount: max(0, maxBands - 1),
                accessibilityUnit: "bands",
                onSelect: { i in
                    apply { $0.bandCount = options[i] }
                    set(bands, Float(options[i]))
                })
        }
    }

    // MARK: designer がどこまで進んだか

    /// 状態と、入った内容の 1 行。IR Reverb の loaded 行（IRReverbView の notice）と同じ形。
    private var progress: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(designer.status.message)
                .etFont(size: 12, weight: .semibold)
                .fixedSize(horizontal: false, vertical: true)

            if let detail = designer.status.detail {
                // stageFailed の中身。validateBegin は理由を返さないので、
                // ここに出るのは AssetUpload 側で分かったぶんだけ。
                Text(detail)
                    .etFont(size: 11)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let line = designLine {
                Text(line)
                    .etFont(size: 11, design: .monospaced)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: .rect(cornerRadius: ETMetrics.innerRadius, style: .continuous))
    }

    /// 送り込んだものの中身。latencyInfo は stage が入った後にしか付かない
    /// （FIRCrossoverDesigner.stage）ので、それを「入ったか」の印に使う。
    private var designLine: String? {
        guard let info = designer.latencyInfo else { return nil }
        let settings = designer.settings
        let phase = settings.phase == .minimum ? "minimum phase" : "linear phase"
        // Int は %d へ渡さない（arm64 の varargs で幅が食い違う）。数は補間で出す。
        return "\(settings.bandCount) bands / \(settings.taps) taps / \(phase) / "
            + "\(info.filterDelaySamples) samples delay / "
            + String(format: "%.2f Hz per bin / %+.1f dB peak",
                     info.resolutionHz,
                     designer.powerGainUpperBoundDecibels)
    }

    // MARK: 出口の幅が足りない

    /// fir_crossover.js:615-622 の _renderBusError の 1 文目。文言は上流と同じ。
    private var busError: some View {
        Text("This effect needs an even number of output channels from 4 to 16.")
            .etFont(size: 12, weight: .semibold)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: .rect(cornerRadius: ETMetrics.innerRadius, style: .continuous))
    }

    // MARK: 値の読み書き

    /// designer へ入れる。丸めと作り直しの間引きは designer が持っている
    /// （FIRCrossoverDesigner.update）。
    ///
    /// この後に set() で鎖へも書く。二度書きに見えるが、designer が値を書き戻すのは
    /// 送り込みが通ったときだけ（FIRCrossoverDesigner.pushParameters）で、出口が 2ch の
    /// あいだはそこまで行かない。designer だけに入れると、押した値が端末に残らない。
    private func apply(_ change: (inout FIRCrossoverSettings) -> Void) {
        designer.update(change)
    }

    private func param(_ key: String) -> ETParam? {
        node.spec.params.first { $0.key == key }
    }

    private func value(_ param: ETParam?) -> Float {
        guard let param, node.values.indices.contains(param.offset) else { return 0 }
        return node.values[param.offset]
    }

    private func set(_ param: ETParam?, _ v: Float) {
        guard let param else { return }
        dsp.setValue(v, at: index, offset: param.offset)
    }
}

// MARK: - 選択肢の帯

/// 数の選択肢を横に並べたもの。上流のラジオと select に当たる。
/// Menu は足さない。選択肢は全部その場に出す。
private struct FIRCrossoverChoiceStrip: View {

    let options: [Int]
    /// 選んでいる添字。どれにも当たらないときは nil。
    let selectedIndex: Int?
    /// 先頭から何個まで押せるか。上流の radio.disabled（fir_crossover.js:790-791）。
    let enabledCount: Int
    /// 読み上げに付ける単位。
    let accessibilityUnit: String
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, option in
                let isSelected = i == selectedIndex
                let isEnabled = i < enabledCount
                Button {
                    onSelect(i)
                } label: {
                    Text(String(option))
                        .etFont(size: 13,
                                weight: isSelected ? .bold : .regular,
                                design: .monospaced)
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
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1 : 0.4)
                .accessibilityLabel("\(option) \(accessibilityUnit)")
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
    }
}

// MARK: - designer の置き場

/// 段ごとの FIRCrossoverDesigner。
///
/// designer は周波数・傾き・位相・taps を持っていて、それらは float ではないので
/// Node.valuesに席が無い。ビューの@StateObjectに置くと、
/// EffectCardView が畳んだとき／開いたときで別のビューを作るぶん
/// 別々の designer ができ、しかも畳むたびに設計からやり直しになる。
/// 保存するほうはNode.designが持つ（DSP/DesignParams.swift）。syncのたびにそこから読む。
/// Matrixの経路も同じ形で逃がしてある（MatrixView.swiftのMatrixRouting）。
///
/// 鍵は Node.id。rebuildAll は instance を作り直すが id は据え置く
/// （EffeTuneDSP.rebuildAll）ので、engine を組み直しても同じ designer が残る。
@MainActor
final class FIRCrossoverDesigners {

    static let shared = FIRCrossoverDesigners()

    private var byNode: [UUID: FIRCrossoverDesigner] = [:]

    private init() {}

    func designer(for id: UUID) -> FIRCrossoverDesigner {
        if let existing = byNode[id] { return existing }
        let made = FIRCrossoverDesigner()
        byNode[id] = made
        return made
    }

    /// 既にビューで作られた designer だけを、現在の engine / instance / 処理幅へ繋ぐ。
    /// rebuildAll 後はカードが畳まれていても ETAssetReattach から呼ばれる。
    func sync(node: EffeTuneDSP.Node) {
        // カードがまだ出ていなくても、段が材料を持っていれば作って繋ぐ（鎖を読んだ直後・
        // instanceの作り直し。ETAssetReattach.one）。
        if byNode[node.id] == nil, !node.design.isEmpty { _ = designer(for: node.id) }
        guard let designer = byNode[node.id] else { return }

        // index ではなく instance で引き直す。並べ替え後も正しい段へ書き戻せる。
        let instance = node.instance
        designer.parameterWriter = { values in
            let shared = EffeTuneDSP.shared
            guard let at = shared.nodes.firstIndex(where: { $0.instance == instance }) else {
                return
            }
            for (offset, value) in values.enumerated() {
                shared.setValue(value, at: at, offset: offset)
            }
        }

        // commit で変わった遅延を pipeline descriptor に反映する。
        designer.onAssetCommitted = { EffeTuneDSP.shared.republish() }

        func parameterValue(_ key: String, fallback: Float) -> Float {
            guard let parameter = node.spec.params.first(where: { $0.key == key }),
                  node.values.indices.contains(parameter.offset) else {
                return fallback
            }
            return node.values[parameter.offset]
        }

        // Nodeに保存されるlt / bcと、Node.designの周波数・傾き・位相・tapsを
        // attachより先に復元する。材料が無ければ既定（applying(designParams:)）。
        designer.update {
            $0 = $0.applying(designParams: node.design)
            $0.latencyModeIndex = Int(parameterValue("lt", fallback: 1).rounded())
            $0.bandCount = Int(parameterValue("bc", fallback: 2).rounded())
        }

        let dsp = EffeTuneDSP.shared
        designer.attach(FIRCrossoverDesigner.Target(
            engine: dsp.engine,
            instance: node.instance,
            // FIR 資産は rate divider 前ではなく DSP の処理レートで設計する。
            sampleRate: dsp.sampleRate,
            processingChannels: EffeTuneDSP.routedChannels(of: node)))
    }

    /// 鎖から外れた段のぶんを捨てる。
    /// detach は走っている設計を打ち切り、資産も外す（FIRCrossoverDesigner.detach）。
    /// 段が消えているなら instance ももう無いので、外すほうは空振りする
    /// （engine.cpp:524-529 の findInstance が nullptr）。打ち切りのほうが要る。
    func prune(keeping ids: [UUID]) {
        let live = Set(ids)
        for (id, designer) in byNode where !live.contains(id) {
            designer.detach()
            byNode.removeValue(forKey: id)
        }
    }
}
