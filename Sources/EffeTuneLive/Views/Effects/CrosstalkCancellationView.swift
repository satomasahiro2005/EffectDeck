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
//  **取り込んだ測定は画面の @State にしか残らない。** カードを畳むと消える。
//  段のパラメータは float の並びしか持てないので（ETParam）、測定の参照を
//  プリセットに書く口がこのアプリにはまだ無い。カーネルへ送った係数は残るので、
//  畳んでも音は掛かったまま。
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

    @StateObject private var controller = CrosstalkCancellationController()
    @StateObject private var library = IRLibrary.shared

    /// どちらの耳で測ったものか。枠の組は crosstalk_cancellation.js:20-23。
    private enum Side: String, Identifiable {
        case left, right

        var id: String { rawValue }

        /// 上流の group title（同 :21-22）。
        var title: String {
            self == .left ? "Left-ear measurement" : "Right-ear measurement"
        }

        /// 「左スピーカーの枠は下のチャンネルを取る」（同 :30-31）。
        /// 枠の呼び名は同 :9-14 の SLOT_LABELS。
        var hint: String {
            self == .left
                ? "Channel 1 becomes LL (L speaker → left ear), channel 2 becomes RL (R speaker → left ear)."
                : "Channel 1 becomes LR (L speaker → right ear), channel 2 becomes RR (R speaker → right ear)."
        }
    }

    @State private var leftEar: ETCrosstalkLoader.Ear?
    @State private var rightEar: ETCrosstalkLoader.Ear?

    @State private var picking = false
    /// ファイルを選んだとき、どちらの耳へ入れるか。
    @State private var target: Side = .left
    @State private var browsing: Side?
    /// 取り込みで転んだ理由。設計で転んだ理由は controller.phase が持つ。
    @State private var importFailure: String?
    /// 資産が本当に効き始めたか。commit の直後は preparing で、音が何ブロックか
    /// 通るまで active にならない（DSP/AssetUpload.swift:563-565）。
    @State private var active = false

    // 設計の指示。既定は上流の初期値（crosstalk_cancellation.js:50-59）。
    @State private var taps = 4096
    @State private var regularization = 50.0
    @State private var maxGainDb = 12.0
    @State private var lowFrequency = 200.0
    @State private var highFrequency = 6000.0
    @State private var directWindowMs = 8.0

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
                      allowedContentTypes: [.audio, .wav, .aiff, .mpeg4Audio, .data],
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

            Text(side.hint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
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
            switch side {
            case .left: leftEar = measured
            case .right: rightEar = measured
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
    private var headBlock: UInt32 {
        guard let param = node.spec.params.first(where: { $0.key == "lt" }),
              node.values.indices.contains(param.offset) else { return 128 }
        return CrosstalkCancellationDesigner.headBlock(forLatencyMode: node.values[param.offset])
    }

    /// 4 枠が揃っていれば設計して送る。**MainActor で呼ぶ**
    /// （AssetUpload.send がそれを求めている。AssetUpload.swift 冒頭）。
    private func design() {
        guard let left = leftEar, let right = rightEar else {
            // 上流も全枠が埋まるまで設計しない（crosstalk_cancellation.js:281-287）。
            if controller.phase != .idle { controller.clear(instance: node.instance) }
            return
        }
        guard dsp.ready, dsp.engine != 0, node.instance != 0 else { return }

        // 枠の割り当ては crosstalk_cancellation.js:20-31。
        // 同じ耳の 2 本は 1 つの測定の 2 チャンネルで、左スピーカーが下のチャンネル。
        let sources = CrosstalkCancellationController.Sources(ll: left.leftSpeaker,
                                                             lr: right.leftSpeaker,
                                                             rl: left.rightSpeaker,
                                                             rr: right.rightSpeaker)
        let config = CrosstalkCancellationController.Config(
            sampleRate: Int(dsp.sampleRate.rounded()),
            taps: taps,
            regularization: regularization,
            maxGainDb: maxGainDb,
            lowFrequency: lowFrequency,
            highFrequency: highFrequency,
            directWindowMs: directWindowMs)

        controller.apply(
            engine: dsp.engine,
            instance: node.instance,
            headBlock: headBlock,
            config: config,
            sources: sources,
            beforeSend: { built in
                // 設計が置いた山の位置を dry 側の遅延にも入れる。
                // beginAsset は applyPendingParameters() を先に通るので、
                // 送る直前に書けば同じ begin で効く（kernel.cpp:156）。
                guard let param = node.spec.params.first(where: { $0.key == "fd" }) else { return }
                dsp.setValue(Float(built.config.filterDelaySamples),
                             at: index, offset: param.offset)
            },
            afterSend: {
                // commit で instance の遅延が変わるので、鎖を組み直させる。
                // setRouting は何も変えずに呼んでも publish まで進む。
                dsp.setRouting(at: index)
            })
    }

    // MARK: - 状態

    /// このエフェクトが処理する幅。IRReverbView.swift:162-168 と同じ引き方。
    private var routedChannels: Int {
        switch node.channelSpec {
        case -1, -2: return 2
        case 17...23: return 2
        default: return 1
        }
    }

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
            let state = active ? "active" : "preparing — starts once audio is running"
            return String(format: "%d samples / %.1f ms latency · %@",
                          samples, milliseconds, state)
        }
        return controller.phase.message
    }

    // MARK: - 設計の指示

    private var designControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            tapsRow

            controlRow("Regularization (%)", value: decimals(regularization, 0)) {
                Slider(value: $regularization, in: 0...100, step: 1)
                    .accessibilityLabel("Regularization")
                    .accessibilityValue(decimals(regularization, 0))
            }
            controlRow("Max Gain (dB)", value: decimals(maxGainDb, 1)) {
                Slider(value: $maxGainDb, in: 0...24, step: 0.1)
                    .accessibilityLabel("Max Gain")
                    .accessibilityValue(decimals(maxGainDb, 1))
            }
            // 上流は周波数の 2 本だけ対数のつまみで作っている（同 :744, 746）。
            controlRow("Freq Low (Hz)", value: decimals(lowFrequency, 0)) {
                ETLogSlider(value: $lowFrequency, range: 20...2000)
                    .accessibilityLabel("Freq Low")
                    .accessibilityValue(decimals(lowFrequency, 0))
            }
            controlRow("Freq High (Hz)", value: decimals(highFrequency, 0)) {
                ETLogSlider(value: $highFrequency, range: 1000...20000)
                    .accessibilityLabel("Freq High")
                    .accessibilityValue(decimals(highFrequency, 0))
            }
            controlRow("Direct Window (ms)", value: decimals(directWindowMs, 1)) {
                Slider(value: $directWindowMs, in: 2...50, step: 0.1)
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
                        taps = value
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
    private func controlRow<Control: View>(_ title: String,
                                           value: String,
                                           @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                Text(value)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(width: ETMetrics.valueWidth, height: ETMetrics.controlHeight)
                    .background(.quaternary,
                                in: .rect(cornerRadius: ETMetrics.innerRadius,
                                          style: .continuous))
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
