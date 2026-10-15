//  IRReverbView.swift
//  IR Reverb（IRReverbPlugin）。
//
//  上流はカードの頭に「Import file… / Choose from library…」と状態行・情報行を置き、
//  その下に EDC（エネルギー減衰）グラフを出す
//  （Vendor/effetune/plugins/reverb/ir_reverb.js:1952-1987）。
//  ここも同じ並びで、取り込む口・名前と情報行・グラフ・つまみの順に置く。
//
//  --- グラフ ---
//  描くのは IRReverbDecayGraph.swift。点は送った IR（カーネルが受け取った面）と、
//  decay・trim の前の面から ETIRGraphStore が裏で計算して持つ。
//  以前は出していなかった。ETIRLoader が読んだ面を送ったあとで手放していて、描く材料が
//  残っていなかったため。今は load が送ったあとに、送った面と decay・trim の前の面を
//  解析へ渡す（DSP/IRLoader.swift）。曲線は IR が無ければ描けないので、入っていないときは枠だけ。
//
//  **畳んだカード（etGraphOnly）ではグラフだけを返す。** 取り込む口・状態行・選択肢・つまみを
//  ここで返すと、畳んでいるのに隣のカードに重なってボタンを塞いだ（実機で確認。
//  EffectCardView の showsCollapsedGraph の注釈）。ParameterRow は畳むと自分で消えるが、
//  choiceRow・Toggle・スライダーは消えないので、行ごとでなく editor 丸ごと外す。
//
//  上流の metadata 行（ir_reverb.js:1719-1741。秒数・ch 数・トポロジ・レート変換・
//  レイテンシ・MiB）に当たるのが notice の 2 行目で、送り込めたときに
//  ETIRLoader が返す 1 行をそのまま出す。IR が無いときは上流と同じ
//  'No impulse response loaded.'（:1721）。
//
//  --- 選択肢は資産を送り直さないと効かない ---
//  Channel Mode / Latency / Conv Rate はカーネルが読まない。カーネルが
//  params_ から読むのは preDelay と wetLevel と dry だけで（kernel.cpp:433, :448）、
//  畳み込みの形は beginAsset に渡す AssetBeginInfo で決まる（:242-250）。
//  なので選び直したら送り直す。その後始末は EffeTuneDSP.setValue が持っている。
//
//  --- 取り込む口をここに置く理由 ---
//  IR Library はツールバーから外してある（PipelineView.swift:277 のコメント）。
//  PipelineView の sheet は private なので、シートはこのビューから出す。
//
//  --- 選択肢の表示名 ---
//  EffectCatalog の enumeration は保存値（"indep" や "128"）をそのまま持っていて、
//  ParameterRow はそれを Text にそのまま出す。上流は表示名を別に持っている
//  （ir_reverb.js:1995-2001 / 2010-2016 / 2017-2022）ので、ここで引き当てて出す。
//  切り替えは Menu ではなく直のボタン。
//
//  --- 下ごしらえのつまみ ---
//  Direct Cut / Cut Offset / Decay / Trim（dc / co / dt / tr）は上流と同じ並びで
//  Pre Delay の後に置く（ir_reverb.js:2035-2038）。カタログ（params.json）に席が無いので
//  ParameterRow は使えず、値は Node.design に持つ（DSP/DesignParams.swift）。
//  変えたら EffeTuneDSP.setIRPreparation が少し待ってから下ごしらえをやり直して送り直す。

import SwiftUI
import UniformTypeIdentifiers

struct IRReverbView: View {

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    @StateObject private var library = IRLibrary.shared
    @State private var picking = false
    @State private var browsing = false
    /// PC の鎖を編集しているとき、Choose from library… は PC の IR Library を開く（2.14.0 の selectIR）。
    /// 取り込みと消すのは PC でやる（上流の remote の画面と同じ）ので Import file… は出さない。
    @ObservedObject private var remote = RemoteMirror.shared
    @State private var browsingPC = false
    /// 送り込めたときの 1 行。nil なら入っていない。
    @State private var loaded: String?
    /// 送り込めなかった理由。上流の文をそのまま出す。
    @State private var failure: String?
    /// 畳んだカードのとき true。グラフだけを出す（上の「グラフ」の注釈）。
    @Environment(\.etGraphOnly) private var graphOnly

    /// ボタンの帯で出す選択肢。残りは ParameterRow に任せる。
    private static let stripKeys: Set<String> = ["cm", "lt", "cr"]

    var body: some View {
        if graphOnly {
            decayGraph.etLocalAudioOnly()
        } else {
            editor
        }
    }

    /// 上流の順（metadata → グラフ → Channel Mode…、ir_reverb.js:2018-2034）。
    private var decayGraph: some View {
        IRReverbDecayGraph(nodeID: node.id,
                           preDelayMs: value("pd"),
                           directCut: preparation.directCut)
    }

    /// Pre Delay などカタログのつまみの値。無ければ 0。
    private func value(_ key: String) -> Double {
        guard let param = node.spec.params.first(where: { $0.key == key }),
              node.values.indices.contains(param.offset) else { return 0 }
        return Double(node.values[param.offset])
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            source
            // **何も入っていなければ箱ごと出さない。**「No impulse response loaded」の 1 行のために
            // ファイル名の箱が場所を取っていた。入っていない段は Import file… の行だけで分かる。
            // 送り込めなかった理由は出すので、failure があるときは残す。
            // 名前・形・減衰の図・ライブラリの数は手元の IR の話。PC の鎖を編集しているあいだは
            // 出さない（上流 2.14.0 の local-audio-only）。IR は Choose from library… で PC から選ぶ。
            if hasNotice { notice.etLocalAudioOnly() }
            decayGraph.etLocalAudioOnly()

            ForEach(node.spec.params) { param in
                if case .enumeration(let options) = param.kind,
                   Self.stripKeys.contains(param.key) {
                    choiceRow(param, options: options)
                } else {
                    ParameterRow(param: param, nodeIndex: index,
                                 values: node.values, dsp: dsp)
                }
            }

            preparationControls
        }
        .sheet(isPresented: $browsing) {
            IRLibraryView { entry in apply(entry.url, id: entry.id) }
        }
        .sheet(isPresented: $browsingPC) {
            ETRemoteIRLibraryView(index: index)
        }
        // 下ごしらえや cm / lt / cr で DSP が入れ直すと、新しい 1 行は assetInfo に入る。
        // この画面で入れたときの `loaded` が残っていると前の 1 行を出し続けるので捨てる。
        .onChange(of: dsp.assetInfo[node.id]) { _, _ in loaded = nil }
    }

    // MARK: IR を取り込む

    private var source: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                // fileImporter と sheet を同じビューに重ねない。
                // 重ねると後から付けた方しか出ない（PipelineView.swift:29-32）。
                if !remote.canSelectPCIR {
                    actionButton("Import file…") { picking = true }
                        .fileImporter(isPresented: $picking,
                                      // **全部選べるようにする。**型で絞ると、拡張子が
                                      // 無いものや別の型を名乗るものが灰色になって選べない。
                                      // 音かどうかは IRLibrary が中身の頭を見て判じる。
                                      allowedContentTypes: [.item],
                                      allowsMultipleSelection: true) { result in
                            if case .success(let urls) = result {
                                // 複数選べるのはライブラリへ溜めるため。
                                // 畳み込みへ渡すのは最後の 1 本だけ（上流も同じ）。
                                // 取り込みは鍵を返す。最後の 1 本をそのまま使う。
                                var lastKey: String?
                                for url in urls { lastKey = library.importFile(at: url) }
                                if let url = urls.last { apply(url, id: lastKey) }
                            }
                        }
                }

                actionButton("Choose from library…") {
                    if remote.canSelectPCIR { browsingPC = true } else { browsing = true }
                }
            }

            Text(status)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .etLocalAudioOnly()
        }
    }

    /// 上流の status 行（ir_reverb.js:1963-1970）に当たるもの。
    private var status: String {
        switch library.entries.count {
        case 0:  return "No impulse responses in the library."
        case 1:  return "1 impulse response in the library."
        case let n: return "\(n) impulse responses in the library."
        }
    }

    /// 上流の metadata 行（ir_reverb.js:1719-1741）に当たるもの。
    /// 入っていれば「4ch True Stereo / 48000 Hz / 1.23 s」、
    /// 入っていなければ上流と同じ 1 行（:1721）を出す。
    private var hasNotice: Bool {
        !node.irId.isEmpty || loaded != nil || failure != nil || dsp.assetInfo[node.id] != nil
    }

    private var notice: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 名前が先。何を使っているかが分からないと、聴き比べのときに困る。
            if let name = fileName {
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(fileName == nil ? .primary : .secondary)
            if let failure {
                Text(failure)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary,
                    in: .rect(cornerRadius: ETMetrics.innerRadius, style: .continuous))
    }

    // MARK: 畳み込みへ渡す

    /// いま使っている素材の名前。
    ///
    /// **正は鎖の `irId`。** ビューの `loaded` はこの画面から入れたときにしか
    /// 入らないので、名前は鍵からライブラリを引く。
    private var fileName: String? {
        guard !node.irId.isEmpty else { return nil }
        return library.entries.first(where: { $0.id == node.irId })?.name
    }

    private var caption: String {
        if let loaded { return loaded }
        // 開き直したあとは DSP が入れ直していて、その 1 行がここに残っている。
        if let line = dsp.assetInfo[node.id] { return line }
        guard !node.irId.isEmpty else { return "No impulse response loaded" }
        // 名前は上の行が出す。ここは中身の説明だけ。
        guard library.entries.contains(where: { $0.id == node.irId }) else {
            return "Missing from the library"
        }
        return "Loaded"
    }

    /// 選択肢の param から、いま選ばれている綴りを引く。
    /// enumeration の値は選択肢の添字なので、そこから戻す。
    private func choice(_ key: String) -> String {
        guard let i = node.spec.params.firstIndex(where: { $0.key == key }),
              case .enumeration(let options) = node.spec.params[i].kind,
              i < node.values.count else { return "auto" }
        let n = Int(node.values[i].rounded())
        return options.indices.contains(n) ? options[n] : "auto"
    }

    /// このエフェクトが処理する幅。
    /// 入れ直す側（EffeTuneDSP.reloadAsset）と同じ数え方でないと、
    /// 開き直したときに別の形で送り込むことになる。
    private var routedChannels: Int { EffeTuneDSP.routedChannels(of: node) }

    /// 読んで、解決して、送る。失敗したら理由をカードに出す。
    /// 通ったら鍵を段に残す。**そうしないと開き直したときに素通しへ戻る。**
    private func apply(_ url: URL, id: String? = nil) {
        failure = nil
        do {
            loaded = try ETIRLoader.load(url: url,
                                         nodeID: node.id,
                                         engine: dsp.engine,
                                         instance: node.instance,
                                         processingRate: dsp.sampleRate,
                                         routedChannels: routedChannels,
                                         channelMode: choice("cm"),
                                         latency: choice("lt"),
                                         convolutionRate: choice("cr"),
                                         options: preparation)
            // 鍵は取り込んだときの戻り値か、ライブラリから選んだ entry の id。
            // どちらも無ければ、いま置いた中身から引き直す。
            let key = id ?? IRLibrary.shared.entries
                .first(where: { $0.url == url })?.id
            if let key { dsp.setIRId(key, at: index) }
            if let loaded { dsp.assetInfo[node.id] = loaded }
        } catch {
            loaded = nil
            failure = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    // MARK: 下ごしらえ

    /// いまの dc / co / dt / tr。鍵が無ければ上流の既定（ir_reverb.js:37-40）。
    private var preparation: ETIRPreparation.Options {
        ETIRPreparation.Options(designParams: node.design)
    }

    /// 範囲・刻み・名前・単位は上流の行のまま（ir_reverb.js:2035-2038）。
    @ViewBuilder
    private var preparationControls: some View {
        let o = preparation
        Toggle(isOn: Binding(get: { o.directCut },
                             set: { setPreparation(ETDesignParam.flag($0), key: "dc") })) {
            Text("Direct Cut").font(.system(size: 14))
        }
        .padding(.vertical, 2)
        preparationSlider("Cut Offset", unit: "ms", key: "co", value: o.cutOffsetMs,
                          range: -20...50, step: 0.1)
        preparationSlider("Decay", unit: "%", key: "dt", value: o.decayPercent,
                          range: 10...400, step: 1)
        preparationSlider("Trim", unit: "%", key: "tr", value: o.trimPercent,
                          range: 1...100, step: 1)
    }

    /// ParameterRow と同じ 2 段（名前と数が上、つまみが下）。
    /// あちらは ETParam と鎖の値に繋がっているので、ここは同じ形を素で書く
    /// （CrosstalkCancellationView.controlRow と同じ）。
    private func preparationSlider(_ label: String, unit: String, key: String, value: Double,
                                   range: ClosedRange<Double>, step: Double) -> some View {
        let title = "\(label) (\(unit))"
        let text = ETNumberText.stepped(value, step: step)
        // 刻みの格子へ寄せてから書く。0.1 刻みを掛け算で戻すと 0.30000000000000004 が残るので、
        // 刻みが 1 より細かいときは割り算で戻す（1 / 0.1 は 10 ちょうど）。
        let store: (Double) -> Void = { v in
            let clamped = min(max(v, range.lowerBound), range.upperBound)
            let n = (clamped / step).rounded()
            let snapped = step < 1 ? n / (1 / step).rounded() : n * step
            setPreparation(ETDesignParam.format(snapped), key: key)
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                ETValueField(text: text, label: title,
                             editText: { ETNumberText.draft(value) },
                             commit: store)
            }
            Slider(value: Binding(get: { value }, set: store), in: range, step: step)
                .accessibilityValue(text)
        }
        .padding(.vertical, 2)
    }

    private func setPreparation(_ raw: String, key: String) {
        dsp.setIRPreparation(raw, key: key, at: index)
    }

    private func actionButton(_ title: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(.tint)
                .frame(maxWidth: .infinity, minHeight: ETMetrics.hitTarget)
                .background(.quaternary,
                            in: .rect(cornerRadius: ETMetrics.innerRadius, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // MARK: 選択肢

    /// 選択肢の帯。名前が長いので横 1 列に詰めず、幅に合わせて折り返す。
    private func choiceRow(_ param: ETParam, options: [String]) -> some View {
        let current = min(max(intValue(param), 0), max(options.count - 1, 0))

        return VStack(alignment: .leading, spacing: 6) {
            Text(param.label).font(.system(size: 14))

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 6)],
                      alignment: .leading, spacing: 6) {
                ForEach(Array(options.enumerated()), id: \.offset) { i, option in
                    let selected = i == current
                    let name = optionLabel(key: param.key, option: option)
                    Button {
                        dsp.setValue(Float(i), at: index, offset: param.offset)
                    } label: {
                        Text(name)
                            .font(.system(size: 13, weight: selected ? .bold : .regular))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundStyle(selected ? AnyShapeStyle(.white)
                                                      : AnyShapeStyle(.secondary))
                            .frame(maxWidth: .infinity, minHeight: ETMetrics.hitTarget)
                            .background(selected ? AnyShapeStyle(.tint)
                                                 : AnyShapeStyle(.quaternary),
                                        in: .rect(cornerRadius: ETMetrics.innerRadius,
                                                  style: .continuous))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(param.label) \(name)")
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
        }
    }

    /// 保存値から上流の表示名へ。
    /// cm は ir_reverb.js:1995-2001、cr は :2017-2022、lt は :2010-2016。
    private func optionLabel(key: String, option: String) -> String {
        if key == "lt" { return option == "0" ? "Zero" : "\(option) samples" }
        return Self.optionNames[key]?[option] ?? option
    }

    private static let optionNames: [String: [String: String]] = [
        "cm": ["auto": "Auto", "mono": "Mono", "indep": "Independent",
               "true": "True Stereo", "multi": "Diagonal Matrix"],
        "cr": ["auto": "Auto", "full": "Full", "half": "Half", "quarter": "Quarter"],
    ]

    private func intValue(_ param: ETParam) -> Int {
        guard node.values.indices.contains(param.offset) else { return 0 }
        return Int(node.values[param.offset].rounded())
    }
}

/// PC の IR Library から選ぶ（2.14.0 の selectIR。上流 remote-ir-library.js）。選ぶだけで、取り込みと消すのは PC。
/// 2 本組（True Stereo の 2 ファイル）も選べる。選んだら PC が入れ、その鎖の state で手元も追う。
private struct ETRemoteIRLibraryView: View {
    let index: Int
    @Environment(\.dismiss) private var dismiss
    @State private var items: [ETRemoteIRItem]?
    @State private var query = ""
    @State private var failed = false
    @State private var working = false

    private var shown: [ETRemoteIRItem] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return (items ?? []).filter { needle.isEmpty || $0.name.lowercased().contains(needle) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                if failed {
                    Text("EffeTune could not apply this change. Try again.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                if items == nil {
                    ProgressView()
                } else if shown.isEmpty {
                    Text("No impulse responses in the library.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(shown) { item in
                    Button {
                        pick(item)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.system(size: 15)).lineLimit(2)
                            Text(item.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(working)
                }
            }
            .searchable(text: $query)
            .navigationTitle(RemoteMirror.shared.host?.name ?? "IR Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task { items = await RemoteMirror.shared.pcIRs() ?? [] }
        }
    }

    private func pick(_ item: ETRemoteIRItem) {
        working = true
        failed = false
        Task {
            let ok = await RemoteMirror.shared.selectPCIR(at: index, irId: item.id)
            working = false
            if ok { dismiss() } else { failed = true }
        }
    }
}
