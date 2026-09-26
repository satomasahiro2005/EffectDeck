//  CrosstalkCancellationView.swift
//  Crosstalk Cancellation（CrosstalkCancellationPlugin）。
//
//  カーネルは出来上がった 4 本の FIR を受け取るだけで、設計は外にある。
//  その設計は DSP/Designers/CrosstalkCancellationDesigner.swift に写してあったが、
//  **どこからも呼ばれていなかった。** このビューがその呼び手。
//
//  --- 何を触らせるか ---
//  上流のカードは「4 枠の測定・設計の 6 つ・Strength / Output Gain / Latency・状態行」
//  （plugins/spatial/crosstalk_cancellation.js:731-773）。
//  設計の 6 つ（Taps / Regularization / Max Gain / Freq Low / Freq High /
//  Direct Window）は **DSP のパラメータではない**。上流もプラグイン側の状態として
//  持っていて（同 :50-59）、カーネルへは行かない。EffectCatalog にも無い
//  （Generated/EffectCatalog.swift:1551-1554 は st / og / lt / fd の 4 つだけ）。
//  だからここでは画面の @State に置く。
//
//  fd（Filter Delay Samples）はカタログに載っているが出さない。
//  設計が山を置く位置＝taps/2 の派生で、外から来た値を勝たせてはいけない
//  （上流も常に導出する。同 :164 のコメント）。送る直前に controller へ書かせる。
//
//  --- 測定はどこから来るか ---
//  上流はブラウザの測定ストアから引く。こちらにはそれが無いので、
//  音のファイルを取り込む道を用意した（DSP/CrosstalkMeasurementLoader.swift）。
//  片耳ぶんの 2ch ファイルを 2 本、左耳と右耳。
//
//  **取り込んだ測定と設計の指示は CrosstalkStore が段ごとに持つ。**
//  ビューの @State に置くと、カードを畳んだ時点で捨てられる（理由は
//  CrosstalkStore.swift の頭）。端末には残さないので、アプリを終うと消える。
//  段のパラメータは float の並びしか持てないので（ETParam）、測定の参照を
//  プリセットに書く口がこのアプリにはまだ無い。
//
//  --- なぜ apply(chainIndex:) を呼ばないか ---
//  controller には鎖の位置だけ渡す口もある（CrosstalkCancellationDesigner.swift:1041）が、
//  そちらは設計のレートを AudioIO.shared.processingRate で上書きする（同 :1056-1059）。
//  カーネルがペイロードの +12 と突き合わせるのは **et_engine_prepare へ渡した値**、
//  つまり EffeTuneDSP.shared.sampleRate（DSP/EffeTuneDSP.swift:117, 137）。
//  この 2 つは音が走っている間しか一致しない。AudioIO は起動時に
//  48000×factor で DSP を用意する（Audio/AudioIO.swift:156-157）のに、
//  processingRate へ実際の値が入るのは engine.start が通った後（同 :493）。
//  既定の factor は 2 なので、音が走る前に設計すると 48000 と書いて 96000 を
//  期待され、commit が ET_ERR_ARGS で落ちる。
//  だから engine / instance を渡す口（同 :1085）を使い、レートは dsp.sampleRate を渡す。
//  IRReverbView も dsp.sampleRate を渡している（IRReverbView.swift:177）。
//  その口は fd の付け替えと publish のやり直しをしないので、
//  beforeSend / afterSend でこちらが渡す。
//
//  --- ステレオでないと効かない ---
//  カーネルは処理幅が 2 でないと process を素通しする
//  （dsp/plugins/spatial/crosstalk_cancellation/kernel.cpp:101）。
//  資産は入るが音は変わらないので、そのときは注記に理由を出す。

import SwiftUI
import UniformTypeIdentifiers

struct CrosstalkCancellationView: View {

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    /// 測定・設計の指示・送り込む係。畳んでも消えないよう段ごとの置き場に持つ
    /// （CrosstalkStore.swift の頭）。
    @StateObject private var store = CrosstalkStore.shared
    @StateObject private var library = IRLibrary.shared

    private var session: CrosstalkStore.Session { store.session(for: node.id) }
    private var controller: CrosstalkCancellationController { session.controller }

    /// どちらの耳で測ったものか。枠の組は crosstalk_cancellation.js:20-23。
    private enum Side: String, Identifiable {
        case left, right

        var id: String { rawValue }

        /// 上流の group title（同 :21-22）。
        var title: String {
            self == .left ? "Left-ear measurement" : "Right-ear measurement"
        }
    }

    private var leftEar: ETCrosstalkLoader.Ear? { session.leftEar }
    private var rightEar: ETCrosstalkLoader.Ear? { session.rightEar }

    @State private var picking = false
    /// ファイルを選んだとき、どちらの耳へ入れるか。
    @State private var target: Side = .left
    @State private var browsing: Side?
    /// 取り込みで転んだ理由。設計で転んだ理由は controller.phase が持つ。
    @State private var importFailure: String?
    /// 資産が本当に効き始めたか。commit の直後は preparing で、音が何ブロックか
    /// 通るまで active にならない（DSP/AssetUpload.swift:563-565）。
    @State private var active = false

    // 設計の指示は session が持つ。既定は上流の初期値
    // （crosstalk_cancellation.js:50-59。CrosstalkStore.Session を見ること）。
    private var taps: Int { session.taps }
    private var regularization: Double { session.regularization }
    private var maxGainDb: Double { session.maxGainDb }
    private var lowFrequency: Double { session.lowFrequency }
    private var highFrequency: Double { session.highFrequency }
    private var directWindowMs: Double { session.directWindowMs }

    /// つまみが書き戻す先。Session は class なので、store 越しに書いて
    /// objectWillChange を出させる。
    private func bind(_ path: ReferenceWritableKeyPath<CrosstalkStore.Session, Double>)
        -> Binding<Double> {
        Binding(get: { self.session[keyPath: path] },
                set: { new in self.store.update(self.node.id) { $0[keyPath: path] = new } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            measurements
            notice
            designControls

            ForEach(node.spec.params) { param in
                // fd は taps から導くので出さない。上の注記を参照。
                if param.key != "fd" {
                    ParameterRow(param: param, nodeIndex: index,
                                 values: node.values, dsp: dsp)
                }
            }
        }
        .sheet(item: $browsing) { side in
            IRLibraryView { entry in
                take(entry.url, id: entry.id, name: entry.name, into: side)
            }
        }
        // 上流は id + config が変わったら設計し直す（同 :167-168, 194）。
        // こちらの注文は headBlock と instance も含む
        // （CrosstalkCancellationDesigner.swift:1103-1106）ので、そこまで見る。
        // controller が 150ms のデバウンスと同一注文の抑止を持っているので、
        // 変わるたび素で呼んでよい（同 :1019, 1107-1110）。
        .onChange(of: designSignature) { _, _ in design() }
        .onAppear { design() }
        .task(id: controller.phase) {
            guard controller.phase == .sent else {
                active = false
                return
            }
            active = await AssetUpload.waitForActive(engine: dsp.engine,
                                                     instance: node.instance).isActive
        }
    }

    // MARK: - 測定を取り込む

    private var measurements: some View {
        VStack(alignment: .leading, spacing: 12) {
            earRow(.left)
            earRow(.right)
            if let importFailure {
                Text(importFailure)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // fileImporter と sheet は同じビューに重ねない（IRReverbView.swift:85-86）。
        // シートの方は上の VStack に付けてある。
        .fileImporter(isPresented: $picking,
                      allowedContentTypes: [.item],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                importFile(url, into: target)
            }
        }
    }

    private func earRow(_ side: Side) -> some View {
        let loaded = measurement(for: side)
        return VStack(alignment: .leading, spacing: 6) {
            Text(side.title)
                .font(.system(size: 13, weight: .semibold))

            Text(loaded.map(Self.describe) ?? "Not assigned")
                .font(.system(size: 11))
                .foregroundStyle(loaded == nil ? AnyShapeStyle(.secondary)
                                               : AnyShapeStyle(.primary))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                actionButton("Import file…") {
                    target = side
                    picking = true
                }
                actionButton("Choose from library…") { browsing = side }
            }
        }
    }

    private func measurement(for side: Side) -> ETCrosstalkLoader.Ear? {
        side == .left ? leftEar : rightEar
    }

    private static func describe(_ ear: ETCrosstalkLoader.Ear) -> String {
        let seconds = ear.sampleRate > 0 ? Double(ear.frames) / Double(ear.sampleRate) : 0
        return String(format: "%@ / %d Hz / %.2f s", ear.name, ear.sampleRate, seconds)
    }

    /// 選ばれたファイルをライブラリへ写してから読む。
    /// 鍵（中身の sha256 先頭 24 桁）をそのまま測定の id に使う。
    private func importFile(_ url: URL, into side: Side) {
        importFailure = nil
        guard let id = library.importFile(at: url), let entry = library.entry(id: id) else {
            // importFile は読めない・書けないときに nil を返すだけで何も言わない。
            importFailure = "Could not read that file."
            return
        }
        take(entry.url, id: entry.id, name: entry.name, into: side)
    }

    private func take(_ url: URL, id: String, name: String, into side: Side) {
        importFailure = nil
        do {
            let measured = try ETCrosstalkLoader.load(url: url, id: id, name: name)
            store.update(node.id) { session in
                switch side {
                case .left: session.leftEar = measured
                case .right: session.rightEar = measured
                }
            }
            // 設計は designSignature の変化を見ている onChange が始める。
        } catch {
            importFailure = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    // MARK: - 設計して送る

    /// 上流の _designSignature（crosstalk_cancellation.js:194）と同じ考え方。
    private var designSignature: String {
        [leftEar?.id ?? "-", rightEar?.id ?? "-",
         String(taps), String(regularization), String(maxGainDb),
         String(lowFrequency), String(highFrequency), String(directWindowMs),
         String(node.instance), String(headBlock), String(dsp.sampleRate)]
            .joined(separator: "|")
    }

    /// latencyMode（lt）の添字を begin の headBlock へ。
    private var headBlock: UInt32 { CrosstalkStore.headBlock(of: node) }

    /// 設計して送る。中身は CrosstalkStore が持っている（畳んだ状態からも
    /// 呼ばれるので、ビューの外に置いてある）。
    private func design() { store.design(node: node) }

    // MARK: - 状態

    /// このエフェクトが処理する幅。
    private var routedChannels: Int { EffeTuneDSP.routedChannels(of: node) }

    /// 入ったときの 1 行。入っていなければ nil。
    private var loaded: String? {
        guard controller.phase == .sent, let diagnostics = controller.diagnostics else {
            return nil
        }
        return String(format: "4 paths / %d taps / %d Hz / %.1f dB peak gain",
                      taps, Int(dsp.sampleRate.rounded()), diagnostics.maxGainDb)
    }

    private var notice: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(loaded ?? "No crosstalk filter loaded")
                .font(.system(size: 12, weight: .semibold))

            if case .failed(let reason) = controller.phase {
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(detail)
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

    private var detail: String {
        if routedChannels != 2 {
            // 上流の bypass の文面（crosstalk_cancellation.js:514-515）。
            return "Crosstalk Cancellation requires a stereo channel pair and is bypassed."
        }
        if controller.phase.isBusy { return controller.phase.message }
        if leftEar == nil || rightEar == nil {
            // 上流 :285。
            return "Assign all four measurements to begin."
        }
        if controller.phase == .sent {
            // 上流の details 行（同 :550-558）。遅延は latency + taps/2。
            let samples = Int(headBlock) + taps / 2
            let milliseconds = dsp.sampleRate > 0
                ? Double(samples) * 1000 / dsp.sampleRate
                : 0
            let state = active ? "active" : "preparing, starts once audio is running"
            return String(format: "%d samples / %.1f ms latency · %@",
                          samples, milliseconds, state)
        }
        return controller.phase.message
    }

    // MARK: - 設計の指示

    private var designControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            tapsRow

            controlRow("Regularization (%)", value: decimals(regularization, 0),
                       number: regularization, range: 0...100,
                       commit: { bind(\.regularization).wrappedValue = $0 }) {
                Slider(value: bind(\.regularization), in: 0...100, step: 1)
                    .accessibilityLabel("Regularization")
                    .accessibilityValue(decimals(regularization, 0))
            }
            controlRow("Max Gain (dB)", value: decimals(maxGainDb, 1),
                       number: maxGainDb, range: 0...24,
                       commit: { bind(\.maxGainDb).wrappedValue = $0 }) {
                Slider(value: bind(\.maxGainDb), in: 0...24, step: 0.1)
                    .accessibilityLabel("Max Gain")
                    .accessibilityValue(decimals(maxGainDb, 1))
            }
            // 上流は周波数の 2 本だけ対数のつまみで作っている（同 :744, 746）。
            controlRow("Freq Low (Hz)", value: decimals(lowFrequency, 0),
                       number: lowFrequency, range: 20...2000,
                       commit: { bind(\.lowFrequency).wrappedValue = $0 }) {
                ETLogSlider(value: bind(\.lowFrequency), range: 20...2000)
                    .accessibilityLabel("Freq Low")
                    .accessibilityValue(decimals(lowFrequency, 0))
            }
            controlRow("Freq High (Hz)", value: decimals(highFrequency, 0),
                       number: highFrequency, range: 1000...20000,
                       commit: { bind(\.highFrequency).wrappedValue = $0 }) {
                ETLogSlider(value: bind(\.highFrequency), range: 1000...20000)
                    .accessibilityLabel("Freq High")
                    .accessibilityValue(decimals(highFrequency, 0))
            }
            controlRow("Direct Window (ms)", value: decimals(directWindowMs, 1),
                       number: directWindowMs, range: 2...50,
                       commit: { bind(\.directWindowMs).wrappedValue = $0 }) {
                Slider(value: bind(\.directWindowMs), in: 2...50, step: 0.1)
                    .accessibilityLabel("Direct Window")
                    .accessibilityValue(decimals(directWindowMs, 1))
            }
        }
    }

    /// taps は 5 つから選ぶ（CrosstalkCancellationDesigner.swift:88 の allowedTaps）。
    private var tapsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Taps").font(.system(size: 14))

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 6)],
                      alignment: .leading, spacing: 6) {
                ForEach(CrosstalkCancellationDesigner.allowedTaps, id: \.self) { value in
                    let selected = value == taps
                    Button {
                        store.update(node.id) { $0.taps = value }
                    } label: {
                        Text(String(value))
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
                    .accessibilityLabel("Taps \(value)")
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
        }
    }

    /// ParameterRow と同じ 2 段（名前と数が上、つまみが下）。
    /// あちらは ETParam と鎖の値に繋がっているので、ここは同じ形を素で書く。
    /// - Parameters:
    ///   - number: 打ち込みの下書きに渡す**数**。表示の字ではない。
    ///   - range: 打たれた数を挟む範囲。
    ///   - commit: 打たれた数の行き先。3 つ揃って初めて打ち込める欄になる。
    private func controlRow<Control: View>(_ title: String,
                                           value: String,
                                           number: Double? = nil,
                                           range: ClosedRange<Double>? = nil,
                                           commit: ((Double) -> Void)? = nil,
                                           @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                if let number, let range, let commit {
                    ETValueField(text: value, label: title,
                                 editText: { ETNumberText.draft(number) }) { typed in
                        commit(min(max(typed, range.lowerBound), range.upperBound))
                    }
                } else {
                    Text(value)
                        .font(.system(size: 13, design: .monospaced))
                        .frame(width: ETMetrics.valueWidth, height: ETMetrics.controlHeight)
                        .background(.quaternary,
                                    in: .rect(cornerRadius: ETMetrics.innerRadius,
                                              style: .continuous))
                }
            }
            control()
        }
    }

    private func decimals(_ value: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", value)
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
}
