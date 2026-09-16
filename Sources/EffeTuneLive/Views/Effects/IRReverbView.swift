//  IRReverbView.swift
//  IR Reverb（IRReverbPlugin）。
//
//  上流はカードの頭に「Import file… / Choose from library…」と状態行・情報行を置き、
//  その下に EDC（エネルギー減衰）グラフを出す
//  （Vendor/effetune/plugins/reverb/ir_reverb.js:1952-1987）。
//  ここで作ったのは IR を取り込む口までで、グラフは出していない。
//
//  --- グラフを出していない理由 ---
//  上流のグラフは IR の PCM から包絡と EDC を計算して描いている
//  （ir_reverb.js:1787-1934）。テレメトリでは来ない値なので、材料は IR そのもの。
//  その IR が iOS 側ではカーネルに入らない:
//    - 資産を送る口は AssetUpload.send（DSP/AssetUpload.swift:421）にあるが、
//      呼び手は FIR 系の designer だけで、IRReverbPlugin へ送る側が居ない。
//    - IRLibrary（DSP/IRLibrary.swift）は取り込んだファイルを Documents/IR に
//      置くところで止まっていて、instance へは繋がっていない。
//  カーネルは資産が ACTIVE でない間 wet を出さず dry だけ通す
//  （dsp/plugins/reverb/ir_reverb/kernel.cpp:205-208 の applyDryWithWetFadeOut）。
//  描く材料も鳴らす IR も無いので、曲線の代わりに理由を出す。
//
//  上流の metadata 行（ir_reverb.js:1719-1741。秒数・ch 数・トポロジ・レート変換・
//  レイテンシ・MiB）も、その値が _prepared から来る。IR を用意する側が無いので
//  出せるのは「入っていない」だけ。上流も IR が無いときは
//  'No impulse response loaded.'（:1721）の 1 行なので、その 1 行を下の注記に出す。
//
//  Channel Mode / Conv Rate が auto のとき解決後の値を横に出す副表示
//  （:1765-1785 の _updateResolvedModeDisplay）も _prepared.config を読む。
//  上流も IR が無い間は span を hidden にするので、こちらでも出さない。
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

import SwiftUI
import UniformTypeIdentifiers

struct IRReverbView: View {

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    @StateObject private var library = IRLibrary.shared
    @State private var picking = false
    @State private var browsing = false
    /// 送り込めたときの 1 行。nil なら入っていない。
    @State private var loaded: String?
    /// 送り込めなかった理由。上流の文をそのまま出す。
    @State private var failure: String?

    /// ボタンの帯で出す選択肢。残りは ParameterRow に任せる。
    private static let stripKeys: Set<String> = ["cm", "lt", "cr"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            source
            notice

            ForEach(node.spec.params) { param in
                if case .enumeration(let options) = param.kind,
                   Self.stripKeys.contains(param.key) {
                    choiceRow(param, options: options)
                } else {
                    ParameterRow(param: param, nodeIndex: index,
                                 values: node.values, dsp: dsp)
                }
            }
        }
        .sheet(isPresented: $browsing) {
            IRLibraryView { entry in apply(entry.url, id: entry.id) }
        }
    }

    // MARK: IR を取り込む

    private var source: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                // fileImporter と sheet を同じビューに重ねない。
                // 重ねると後から付けた方しか出ない（PipelineView.swift:29-32）。
                actionButton("Import file…") { picking = true }
                    .fileImporter(isPresented: $picking,
                                  allowedContentTypes: [.audio, .wav, .aiff,
                                                        .mpeg4Audio, .data],
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

                actionButton("Choose from library…") { browsing = true }
            }

            Text(status)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 上流の status 行（ir_reverb.js:1963-1970）に当たるもの。
    private var status: String {
        switch library.entries.count {
        case 0:  return "Import an impulse response to use IR Reverb."
        case 1:  return "1 impulse response in the library."
        case let n: return "\(n) impulse responses in the library."
        }
    }

    /// 上流の metadata 行（ir_reverb.js:1719-1741）に当たるもの。
    /// 入っていれば「4ch True Stereo / 48000 Hz / 1.23 s」、
    /// 入っていなければ上流と同じ 1 行（:1721）を出す。
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
            } else if node.irId.isEmpty {
                Text("""
                     Import a file or choose one from the library. Four-channel true \
                     stereo impulse responses work: with Channel Mode on Auto they are \
                     routed as True Stereo.
                     """)
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

    // MARK: 畳み込みへ渡す

    /// カードに出す 1 行。
    ///
    /// **正は鎖の `irId`。** ビューの `loaded` はいま読み込んだときの
    /// 詳しい 1 行（4ch True Stereo / 48000 Hz / 1.23 s）で、
    /// アプリを開き直したときは入っていない。入れ直しは DSP がやっていて
    /// （EffeTuneDSP.reloadAssets）、ビューはその結果を知らないため。
    /// そのときは鍵からライブラリを引いて名前を出す。
    /// いま使っている素材の名前。鍵からライブラリを引く。
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

    /// このエフェクトが処理する幅。descriptor の channelSpec から出す。
    /// 既定（Stereo）と All と組の指定は 2、単独のチャンネルは 1。
    private var routedChannels: Int {
        switch node.channelSpec {
        case -1, -2: return 2
        case 17...23: return 2
        default: return 1
        }
    }

    /// 読んで、解決して、送る。失敗したら理由をカードに出す。
    /// 通ったら鍵を段に残す。**そうしないと開き直したときに素通しへ戻る。**
    private func apply(_ url: URL, id: String? = nil) {
        failure = nil
        do {
            loaded = try ETIRLoader.load(url: url,
                                         engine: dsp.engine,
                                         instance: node.instance,
                                         processingRate: dsp.sampleRate,
                                         routedChannels: routedChannels,
                                         channelMode: choice("cm"),
                                         latency: choice("lt"),
                                         convolutionRate: choice("cr"))
            // 鍵は取り込んだときの戻り値か、ライブラリから選んだ entry の id。
            // どちらも無ければ、いま置いた中身から引き直す。
            let key = id ?? IRLibrary.shared.entries
                .first(where: { $0.url == url })?.id
            if ETConsoleLog.on { print("IR apply index=\(index) key=\(key ?? "nil") url=\(url.lastPathComponent)") }
            if let key { dsp.setIRId(key, at: index) }
            if let loaded { dsp.assetInfo[node.id] = loaded }
        } catch {
            loaded = nil
            failure = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
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
