//  RoomEQView.swift
//  Room EQ（RoomEqPlugin）。
//
//  測った部屋の応答を読み、補正 FIR を設計して instance へ送り込む。
//  設計は RoomEQDesigner（DSP/Designers/RoomEQDesigner.swift）が持っていて、
//  ここはその呼び手。測定と設定は RoomEQStore（DSP/RoomEQStore.swift）に置く。
//
//  --- 図は出していない ---
//  上流の図は「測った周波数特性」と「それを打ち消す補正」を重ねたもので、
//  材料は測定ストアと designer の previews から来る
//  （plugins/eq/room_eq.js:1619-1620）。previews は移していない
//  （RoomEQDesigner.swift の頭「移していない: previews」）ので、曲線は描けない。
//  出せるのは入った内容の 1 行と状態。
//
//  --- DSP へ行くのは 4 つだけ ---
//  ETEffect.params は lt / fd / dy / gn（Generated/EffectCatalog.swift:599-612、
//  dsp/plugins/eq/room_eq/params.json:5-13）。taps も phase も smoothing も
//  DSP のパラメータではないので、設計の設定はこのビューが RoomEQStore に持つ。
//  補正そのものは資産（ET_ASSET_F32_MULTICH、32MiB）で渡す。
//
//  --- fd はここに出さない ---
//  filterDelaySamples は設計が決める値で、手で動かすと dry と wet がずれるだけ。
//  上流も UI に出していない（room_eq.js:3325-3332 の Filter タブは
//  Taps / Latency / Smoothing の 3 つ）。書くのは apply() の onDesigned の中。
//
//  --- channelDelay の単位はサンプル ---
//  web 版は ms で持っていて DSP へ渡すときに掛けている
//  （room_eq.js:1081 `dy: Math.round(this.delayMs * sampleRate / 1000)`）。
//  こちらは ParameterRow がそのまま出すのでサンプルのまま。

import SwiftUI
import UniformTypeIdentifiers

struct RoomEQView: View {

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    /// 測定・設定・送り込む係。カードを畳むとこのビューは作り直されるので、
    /// @State には置けない（RoomEQStore.swift の頭）。
    @StateObject private var store = RoomEQStore.shared

    /// 図だけ見る指定。ParameterRow は自分で畳むが、ボタンは畳まないのでここで見る。
    @Environment(\.etGraphOnly) private var graphOnly

    @State private var picking = false
    /// 読み込みで落ちた理由。設計と送り込みの失敗は correction.state に出る。
    @State private var failure: String?

    private var session: RoomEQStore.Session { store.session(for: node.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !graphOnly { measurement }
            notice
            if !graphOnly {
                settings

                ForEach(node.spec.params) { param in
                    if param.key != "fd" {
                        ParameterRow(param: param, nodeIndex: index,
                                     values: node.values, dsp: dsp)
                    }
                }
            }
        }
        // instance が作り直されると資産は消える（EffeTuneDSP.swift:577-586）。
        .onChange(of: node.instance) { _, _ in resend() }
        // independent は channels == processingChannels が条件なので、
        // 処理幅が 1↔2 で変わったら設計からやり直す（kernel.cpp validateBegin）。
        .onChange(of: node.channelSpec) { _, _ in resend() }
        // lt（headBlock）は begin の引数。資産を送り直さないと変わらない。
        .onChange(of: latencyParameterValue) { _, _ in resend() }
        .onChange(of: session.correction.state) { _, now in
            // commit で instance の遅延が変わる。鎖を組み直させないと
            // et_pipeline_configure が読み直さない（AssetUpload.swift:64-68）。
            // publish() は外から呼べないが、setRouting は何も変えずに呼んでも
            // そこまで進む（EffeTuneDSP.swift:667-675）。
            if now == .sent { dsp.setRouting(at: index) }
        }
        .onAppear { resendIfGone() }
    }

    // MARK: 測定を取り込む

    private var measurement: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                actionButton("Import measurement…") { picking = true }
                    .disabled(!AssetUpload.canStage)
                    .fileImporter(isPresented: $picking,
                                  allowedContentTypes: [.audio, .wav, .aiff,
                                                        .mpeg4Audio, .data],
                                  allowsMultipleSelection: true) { result in
                        if case .success(let urls) = result { load(urls) }
                    }

                if !session.sources.isEmpty {
                    actionButton("Remove") { remove() }
                }
            }

            Text(session.sources.isEmpty ? Self.importHint : session.measurement)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static let importHint = """
        Import a measured impulse response: one file per channel, or one \
        multi-channel file. A single channel is applied to every channel.
        """

    /// 読んで、面をチャンネルへ割り当てて、設計を予約する。
    private func load(_ urls: [URL]) {
        failure = nil
        let width = processingChannels
        guard width > 0 else {
            failure = Self.notRouted
            return
        }

        var sources = [RoomEQSource?]()
        var names = [String]()
        var rate = 0
        var frames = 0
        do {
            for url in urls {
                let decoded = try ETIRLoader.decode(url)
                // **伸縮しない。** config とレートが違えば designer 側の
                // 窓付き sinc が直す（RoomEQDesigner の impulseMagnitude）。
                let sampleRate = Int(decoded.sampleRate.rounded())
                for plane in decoded.channels {
                    sources.append(RoomEQSource(impulses: [
                        RoomEQImpulse(data: plane, sampleRate: sampleRate)
                    ]))
                }
                names.append(url.lastPathComponent)
                rate = sampleRate
                frames = max(frames, decoded.frames)
            }
        } catch {
            failure = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            return
        }
        guard !sources.isEmpty else {
            failure = ETIRLoadError.emptyFile.errorDescription
            return
        }

        // 読んだ面は全部持っておく。処理幅に合わせて削るのは送るときで（apply）、
        // ここで落とすと、後で幅が 1→2 に戻ったときに測り直しになる。
        let line = "\(names.joined(separator: ", ")) · \(sources.count) ch measured"
            + " · \(rate) Hz · \(frames) frames"
        store.update(node.id) {
            $0.sources = sources
            $0.measurement = line
        }
        apply()
    }

    /// 資産を外して素通しへ戻す。
    private func remove() {
        failure = nil
        session.correction.clear(engine: dsp.engine, instance: node.instance)
        store.update(node.id) {
            $0.sources = []
            $0.measurement = ""
        }
        // clear は fd を戻さない。資産が無ければカーネルは読まないが、
        // 画面にも保存にも残るので 0 へ戻す（次の設計が上書きする）。
        dsp.setValue(0, at: index,
                     offset: RoomEQDesigner.ParameterOffset.filterDelaySamples)
        // 資産を外すと instance の遅延が変わる。鎖を組み直させる。
        dsp.setRouting(at: index)
    }

    // MARK: 設計を頼む

    /// 設計し直して送り直す。schedule が 150ms まとめて 1 回にするので、
    /// つまみを動かし続けても設計は 1 回で済む（RoomEQDesigner.swift:1265-1276）。
    private func apply() {
        // 下の onDesigned は escaping なので、捕まえるものを先に出しておく。
        let dsp = self.dsp
        let session = self.session
        guard !session.sources.isEmpty else { return }
        guard dsp.engine != 0, node.instance != 0 else { return }
        let width = processingChannels
        guard width > 0 else {
            failure = Self.notRouted
            return
        }
        failure = nil

        var config = session.config
        // **ヘッダ +12 は処理レート。割らない。** RoomEQ の rateDivider は 1 固定で、
        // カーネルは readU32(bytes+12) == lround(sample_rate_) を見る
        // （dsp/plugins/eq/room_eq/kernel.cpp の validatePayload）。
        // 処理レートは 48000 とは限らない（AudioIO.swift:157/383 の factor）。
        config.sampleRate = Int(dsp.sampleRate.rounded())

        // **要素数が topology を決める。** 1 なら mono（1 本を全チャンネルへ）、
        // 2 以上は independent で、処理幅と一致していないと send が
        // channelCountMismatch で弾く（RoomEQDesigner.swift:437-442、
        // kernel.cpp validateBegin の independent）。余った面はここで落とす。
        // 段を動かして幅が 2→1 になったときも、これで通る。
        var sources = session.sources
        if sources.count > width { sources = Array(sources.prefix(width)) }

        let mode = latencyMode
        let instance = node.instance
        session.correction.schedule(config: config,
                                    sources: sources,
                                    engine: dsp.engine,
                                    instance: instance,
                                    processingChannels: UInt32(width),
                                    latencyMode: mode) { design in
            // 設計が終わって、送る直前。ここが fd を書ける唯一の隙間。
            // カーネルは begin の時点の fd で遅延を決める
            // （kernel.cpp beginAsset の candidate_latency_）ので、
            // 後から書いても遅延だけ前の設計のまま残る。
            //
            // 並べ替えを跨ぐので、位置は instance から引き直す
            // （CrosstalkCancellationDesigner.swift:1202-1208 と同じ）。
            guard let at = dsp.chain.firstIndex(where: { $0.instance == instance }) else { return }
            // lt は普通そのまま戻る値なので、外れているときだけ直す。
            // 毎回書くと node.values が変わり、それを見張っている onChange が
            // もう一度送り直しに来る。
            let offset = RoomEQDesigner.ParameterOffset.latencyMode
            let want = RoomEQDesigner.parameterValue(forLatencyMode: mode)
            if dsp.chain[at].values.indices.contains(offset),
               dsp.chain[at].values[offset] != want {
                dsp.setValue(want, at: at, offset: offset)
            }
            dsp.setValue(Float(design.filterDelaySamples),
                         at: at, offset: RoomEQDesigner.ParameterOffset.filterDelaySamples)
        }
    }

    /// 測定が入っているときだけ設計し直す。
    private func resend() {
        guard !session.sources.isEmpty else { return }
        apply()
    }

    /// 画面へ戻ったときに、カーネルから資産が消えていたら送り直す。
    /// instance が作り直されるのは prepare のときで、そのときこのカードが
    /// 組み立てられていなければ onChange は来ない。
    private func resendIfGone() {
        guard !session.sources.isEmpty, dsp.engine != 0, node.instance != 0 else { return }
        // 送っている最中は触らない。送っているあいだ鎖全体が素通しになるので
        // （AssetUpload.swift:48-60）、重ねて頼まない。
        switch session.correction.state {
        case .designing, .sending: return
        default: break
        }
        let state = AssetUpload.status(engine: dsp.engine, instance: node.instance).state
        if state == ETAssetState.none || state == ETAssetState.error { apply() }
    }

    // MARK: 状態

    private var notice: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(headline)
                .font(.system(size: 12, weight: .semibold))

            if let failure {
                Text(failure)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if case .failed(let why) = session.correction.state {
                Text(why)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if session.sources.isEmpty {
                Text("""
                     Room correction is an FIR built from a room measurement. Import one \
                     to design it. Channel Delay and Output Gain work without it; the \
                     delay is counted in samples.
                     """)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(warnings, id: \.self) { warning in
                Text(warning)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: .rect(cornerRadius: ETMetrics.innerRadius, style: .continuous))
    }

    /// 入った内容の 1 行、あるいはいま何をしているか。
    ///
    /// **.sent は「鳴っている」ではない。** commit の直後は preparing で、
    /// 音が何ブロックか通ってから active になる（AssetUpload.swift:561-565）。
    /// 無音のあいだは preparing のまま進まないので、そう書く。
    private var headline: String {
        // 資産を staging へ写す口が無い build では何も始まらない
        // （AssetUpload.swift:624-636 の stagingAddressUnavailable）。
        guard AssetUpload.canStage else { return "This build cannot load correction assets" }
        guard !session.sources.isEmpty else { return "No correction curve" }

        switch session.correction.state {
        case .idle:      return "Correction not sent"
        case .designing: return "Designing correction…"
        case .sending:   return "Sending correction…"
        case .failed:    return "Correction failed"
        case .sent:
            switch session.correction.assetState {
            case .active:              return summary ?? "Correction active"
            case .preparing, .staged:  return "Correction sent; it starts once audio runs"
            case .error:               return "The kernel rejected the correction"
            case .none:                return "No correction loaded"
            }
        }
    }

    /// 入った内容の 1 行。IRReverbView の loaded と同じ形。
    private var summary: String? {
        guard let design = session.correction.design else { return nil }
        let phase = design.appliedPhase == .minimum ? "minimum" : "linear"
        // カーネルの遅延は headBlock + fd（kernel.cpp beginAsset）。
        let latency = Int(latencyMode) + design.filterDelaySamples
        return "\(design.channels.count) ch · \(design.taps) taps · \(phase) phase"
            + " · \(String(format: "%.2f", design.resolutionHz)) Hz"
            + " · \(latency) samples latency"
    }

    private var warnings: [String] {
        (session.correction.design?.qualityWarnings ?? []).map { (warning: RoomEQQualityWarning) -> String in
            switch warning {
            case .filterAccuracy:
                return "The synthesised filter misses the target. Raise Taps or Smoothing."
            case .impulseResponseRequired:
                return "Full phase correction needs an impulse response on every channel."
            case .fullPhaseNotPorted:
                return "Full phase correction is not available here. The filter was built with linear phase."
            }
        }
    }

    private static let notRouted =
        "This effect is not routed to any channel. Change Routing first."

    // MARK: 設計の設定

    /// 上流の Filter / Level / Phase タブ（room_eq.js:3325-3356）のうち、
    /// min / lin で効くものだけ。full 専用のつまみは出さない。
    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            tapsRow
            phaseRow

            slider("Smoothing",
                   value: configBinding(\.smoothing),
                   range: 0.02...1, step: 0.01,
                   text: String(format: "%.2f oct", session.config.smoothing))

            slider("Correction Low",
                   value: configBinding(\.lowFrequency),
                   range: 20...1000, logarithmic: true,
                   text: "\(Int(session.config.lowFrequency.rounded())) Hz")

            slider("Correction High",
                   value: configBinding(\.highFrequency),
                   range: 1000...20000, logarithmic: true,
                   text: "\(Int(session.config.highFrequency.rounded())) Hz")

            slider("Max Boost",
                   value: configBinding(\.maxBoostDb),
                   range: 0...18, step: 0.1,
                   text: String(format: "%.1f dB", session.config.maxBoostDb))

            slider("Level Correction",
                   value: Binding(
                       get: { session.config.correctionAmount * 100 },
                       set: { now in
                           store.update(node.id) { $0.config.correctionAmount = now / 100 }
                           apply()
                       }),
                   range: 0...100, step: 1,
                   text: "\(Int((session.config.correctionAmount * 100).rounded())) %")
        }
    }

    /// 32MiB の枠に入るものだけ出す（RoomEQDesigner.swift:504-506）。
    private var tapsRow: some View {
        let limit = RoomEQDesigner.largestUsableTaps(
            channelCount: assetChannels,
            processingChannels: max(1, processingChannels),
            latencyMode: latencyMode) ?? 0
        // 1 つも入らないときは一番小さいものを出す。押せば checkCapacity が
        // 理由付きで落としてくれる（黙って選べない札より分かる）。
        var options = RoomEQConfig.allowedTaps.filter { $0 <= limit }
        if options.isEmpty { options = [RoomEQConfig.allowedTaps[0]] }

        return VStack(alignment: .leading, spacing: 6) {
            Text("Taps").font(.system(size: 14))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 6)],
                      alignment: .leading, spacing: 6) {
                ForEach(options, id: \.self) { taps in
                    choice(String(taps), selected: session.config.taps == taps) {
                        store.update(node.id) { $0.config.taps = taps }
                        apply()
                    }
                }
            }
        }
    }

    /// full は出さない。設計できない（design が黙って .linear に落とす。
    /// RoomEQDesigner.swift:290-297）ので、選べる札にしない。
    private var phaseRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Phase").font(.system(size: 14))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 6)],
                      alignment: .leading, spacing: 6) {
                ForEach([RoomEQPhase.minimum, RoomEQPhase.linear], id: \.self) { phase in
                    choice(phase == .minimum ? "Minimum" : "Linear",
                           selected: session.config.phase == phase) {
                        store.update(node.id) { $0.config.phase = phase }
                        apply()
                    }
                }
            }
        }
    }

    private func configBinding(_ path: WritableKeyPath<RoomEQConfig, Double>) -> Binding<Double> {
        Binding(get: { session.config[keyPath: path] },
                set: { now in
                    store.update(node.id) { $0.config[keyPath: path] = now }
                    apply()
                })
    }

    // MARK: 数

    /// このエフェクトが処理する幅。engine は 2ch で組んである
    /// （AudioIO.swift:157 と :383 がどちらも maxChannels: 2 で prepare する）。
    private var processingChannels: Int {
        BandFIRPEQDesigner.processingChannels(channelSpec: node.channelSpec,
                                              engineChannels: 2)
    }

    /// 実際に送る面の数。処理幅を超えた測定は落とす（apply と同じ数え方）。
    private var assetChannels: Int {
        max(1, min(session.sources.count, max(1, processingChannels)))
    }

    /// lt の**保存値**（列挙の番号）。カーネルの headBlock は中身の数なので、
    /// 読み替えは RoomEQDesigner.latencyMode(fromParameterValue:) に任せる。
    private var latencyParameterValue: Float {
        let offset = RoomEQDesigner.ParameterOffset.latencyMode
        return node.values.indices.contains(offset) ? node.values[offset] : 1
    }

    private var latencyMode: UInt32 {
        RoomEQDesigner.latencyMode(fromParameterValue: latencyParameterValue)
    }

    // MARK: 部品

    private func slider(_ title: String,
                        value: Binding<Double>,
                        range: ClosedRange<Double>,
                        step: Double = 0,
                        logarithmic: Bool = false,
                        text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                ValueBox(text: text)
            }
            if logarithmic {
                ETLogSlider(value: value, range: range)
            } else {
                ETSlider(value: value, range: range, step: step)
            }
        }
        .padding(.vertical, 2)
    }

    private func choice(_ name: String,
                        selected: Bool,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(name)
                .font(.system(size: 13, weight: selected ? .bold : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .frame(maxWidth: .infinity, minHeight: ETMetrics.hitTarget)
                .background(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                            in: .rect(cornerRadius: ETMetrics.innerRadius, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
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
