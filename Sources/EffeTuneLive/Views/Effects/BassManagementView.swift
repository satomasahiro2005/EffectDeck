//  BassManagementView.swift
//  Bass Management（BassManagementPlugin）。2.11.0 で増えた。
//
//  上流は plugins/basics/bass_management.js の createUI（:690-814）。並びもそれに合わせた:
//    設定の誤り（:693-696）
//    Phase / Linear Quality / Sub Outputs / LFE Low-pass / LFE LP / LFE Slope /
//      Bass Gain / LFE Gain / Headroom（:698-755。append の順は :751-754）
//    Bass Matrix（:757-764、表は _buildRoutingMatrix :903-1017）
//    図（:766-780、drawGraph :1098-1262）
//    経路の要約（:782-785）と、状態・遅延の行（:786-797）
//
//  **汎用の行では出せない。**ro / rt / ri / su はロールと bit の並びで、
//  数値スライダーにすると意味を持たない。sl / ls も 24 / 48 / 96 以外を入れると
//  カーネルが設定ごと無効にする（kernel.cpp:33, 41-71）。
//
//  --- 幅 ---
//  行も Sub の候補も、この段が実際に処理する幅（EffeTuneDSP.routedChannels）まで。
//  上流は type 9 のテレメトリで数えるが（:598-618）、カーネルが受け取る幅は
//  descriptor の channelSpec で決まっていて、そちらは音が来る前から分かる。
//  **All でないときは段ごと外れる**（上流と同じ bypass。EffeTuneDSP.isChannelBypassed）。
//  そのときは Spatial Mapper と同じく「Use all output channels」を出す。
//
//  --- 表の形 ---
//  上流は Ch / Role / Freq / Slope / Sub ごとの ON・Ø を 1 行に並べる。
//  iPhone の幅には入らないので、Ch ごとに 3 段（Role、Freq と Slope、Sub ごとの ON・Ø）にした。
//  押せる条件は _syncControls（:1062-1080）と同じ。Freq と Slope は Managed のときだけ、
//  ON は Managed か LFE のときだけ、Ø は ON が入っているときだけ。
//
//  --- 値の書き方 ---
//  1 つだけ変わるもの（Role・Freq・Slope・Ø）は setValue、複数の配列にまたがるもの
//  （Sub の入切、ON）は setValues で 1 回に渡す。判断は BassManagementSettings が持つ。
//  Linear の係数は BassManagementDesigners が値の変化を見て作り直す。

import SwiftUI

struct BassManagementView: View {

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    // designer を引くのは body の中（@MainActor の置き場。FIRCrossoverView と同じ）。
    var body: some View {
        BassManagementBody(index: index,
                           node: node,
                           dsp: dsp,
                           designer: BassManagementDesigners.shared.designer(for: node.id))
    }
}

// MARK: - 中身

private struct BassManagementBody: View {

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP
    @ObservedObject var designer: BassManagementDesigner

    @Environment(\.etGraphOnly) private var graphOnly
    /// 図に出す Ch。上流の _graphChannel（:71, :1019-1028）。音には関係しない。
    @State private var graphChannel = 0

    /// 図の縦（:1159-1161）。
    private static let decibelRange: ClosedRange<Double> = -60...12
    private static let samples = 256
    /// :1167 の格子と、幅が狭いときに字を出すもの（:1169-1171）。
    private static let gridFrequencies: [Double] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]
    private static let labeledFrequencies: Set<Double> = [20, 100, 500, 2000, 10000]
    /// effetune.css の parameter-disabled と同じ薄さ（SWRadioSimulatorView と同じ）。
    private static let disabledOpacity = 0.52

    private static let roleChoices = BassManagementSettings.roleNames.enumerated().map {
        BassManagementChoice(id: $0.offset, label: $0.element)
    }
    /// 表の Slope は "24dB"（:889-894）、LFE Slope は "24 dB/oct"（:724-726）。
    private static let slopeChoices = BassManagementSettings.slopeChoices.map {
        BassManagementChoice(id: $0, label: "\($0)dB")
    }
    private static let lfeSlopeChoices = BassManagementSettings.slopeChoices.map {
        BassManagementChoice(id: $0, label: "\($0) dB/oct")
    }
    /// tp は enum なので値は添字（:704-706 の `${value} taps`）。
    private static let tapChoices = BassManagementSettings.tapChoices.enumerated().map {
        BassManagementChoice(id: $0.offset, label: "\($0.element) taps")
    }

    private var layout: BassManagementSettings.Layout? {
        BassManagementSettings.Layout(params: node.spec.params)
    }

    private var settings: BassManagementSettings {
        guard let layout else { return BassManagementSettings() }
        return BassManagementSettings(values: node.values, layout: layout)
    }

    /// この段が処理する幅。
    private var width: Int { EffeTuneDSP.routedChannels(of: node) }

    private var selectedChannel: Int { min(max(graphChannel, 0), max(width - 1, 0)) }

    var body: some View {
        let s = settings
        VStack(alignment: .leading, spacing: 12) {
            if !graphOnly {
                configuration(s)
                globalSettings(s)
                matrix(s)
            }
            graph(s)
            if !graphOnly {
                Text(s.routeSummary(width: width))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                statusRow(s)
            }
        }
        .onAppear { sync() }
        // 値・instance・幅のどれが変わっても designer に渡す。同じなら designer が何もしない。
        .onChange(of: node.values) { _, _ in sync() }
        .onChange(of: node.instance) { _, _ in sync() }
        .onChange(of: width) { _, _ in sync() }
        .onChange(of: node.channelSpec) { _, _ in sync() }
        .etRemembers($graphChannel, key: "bassManagement.graphChannel", node: node.id)
    }

    // MARK: 設定の誤り

    @ViewBuilder
    private func configuration(_ s: BassManagementSettings) -> some View {
        // All 以外では段ごと外れる（EffeTuneDSP.isChannelBypassed）。それは上のボタンが言う。
        // 誤りの行は All のとき、カーネルが受け取る幅での誤りだけ。
        if node.channelSpec != -2 {
            Button("Use all output channels") {
                dsp.setRouting(at: index, channelSpec: -2)
            }
        } else if let error = s.configurationError(allChannels: true, width: width) {
            Text(error.message)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 全体の設定

    private func globalSettings(_ s: BassManagementSettings) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            row("ph")
            menuRow("Linear Quality",
                    choices: Self.tapChoices,
                    selection: s.tapsIndex) { set("tp", Float($0)) }
                .disabled(!s.linear)
                .opacity(s.linear ? 1 : Self.disabledOpacity)
            subOutputs(s)
            row("lo")
            row("lf", gated: !s.lfeLowpass)
            menuRow("LFE Slope",
                    choices: Self.lfeSlopeChoices,
                    selection: s.lfeSlope) { set("ls", Float($0)) }
                .disabled(!s.lfeLowpass)
                .opacity(s.lfeLowpass ? 1 : Self.disabledOpacity)
            row("bg")
            row("lg")
            row("hg")
        }
    }

    /// Sub Outputs（:729-750）。候補は処理幅の中だけ（:1044-1049）。
    private func subOutputs(_ s: BassManagementSettings) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sub Outputs").font(.system(size: 14))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 6)],
                      alignment: .leading, spacing: 6) {
                ForEach(0..<width, id: \.self) { ch in
                    Toggle("Ch \(ch + 1)", isOn: Binding(
                        get: { s.subs & (1 << ch) != 0 },
                        set: { on in
                            let w = width
                            edit { $0.settingSubOutput(ch, enabled: on, width: w) }
                        }))
                        .toggleStyle(.button)
                        .accessibilityLabel("Sub output Ch \(ch + 1)")
                }
            }
        }
    }

    // MARK: Bass Matrix

    private func matrix(_ s: BassManagementSettings) -> some View {
        let subs = s.selectedSubs(width: width)
        return VStack(alignment: .leading, spacing: 10) {
            Text("BASS MATRIX")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            ForEach(0..<width, id: \.self) { ch in
                channelBlock(ch, s, subs: subs)
                if ch < width - 1 { Divider() }
            }
        }
    }

    private func channelBlock(_ ch: Int, _ s: BassManagementSettings, subs: [Int]) -> some View {
        let role = s.roles[ch]
        let managed = role == BassManagementSettings.Role.managed.rawValue
        let routed = managed || role == BassManagementSettings.Role.lfe.rawValue
        let name = "Ch \(ch + 1)"
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(name).font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 8)
                Picker("\(name) Role", selection: Binding(
                    get: { role },
                    set: { set("ro", channel: ch, Float($0)) })) {
                    ForEach(Self.roleChoices) { Text($0.label).tag($0.id) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            frequencyRow(ch, s, name: name)
                .disabled(!managed)
                .opacity(managed ? 1 : Self.disabledOpacity)

            if !subs.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6)],
                          alignment: .leading, spacing: 6) {
                    ForEach(subs, id: \.self) { output in
                        routeCell(input: ch, output: output, s)
                    }
                }
                .disabled(!routed)
                .opacity(routed ? 1 : Self.disabledOpacity)
            }
        }
    }

    /// Freq は 20〜300Hz の対数（:872-882 と :1058 の 100·log(f/20)/log(15)）、整数に丸める
    /// （:152-153）。Slope は同じ行の select（:883-899）。
    private func frequencyRow(_ ch: Int, _ s: BassManagementSettings, name: String) -> some View {
        // 範囲の外は Int(_:) で落ちるので、出すのは 20〜300 に寄せた値（カーネルもその外は受けない）。
        let hz = min(max(s.frequencies[ch], 20), 300)
        return HStack(spacing: 8) {
            ETLogSlider(value: Binding(
                get: { hz },
                set: { set("fc", channel: ch, Float($0.rounded())) }), range: 20...300)
                .accessibilityLabel("\(name) Freq")
                .accessibilityValue("\(Int(hz.rounded())) Hz")
            ETValueField(text: "\(Int(hz.rounded())) Hz",
                         label: "\(name) Freq",
                         editText: { ETNumberText.draft(hz.rounded()) }) { typed in
                set("fc", channel: ch, Float(min(max(typed.rounded(), 20), 300)))
            }
            Picker("\(name) crossover slope", selection: Binding(
                get: { s.slopes[ch] },
                set: { set("sl", channel: ch, Float($0)) })) {
                ForEach(Self.slopeChoices) { Text($0.label).tag($0.id) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    /// Sub 1 つぶんの ON と Ø（:969-1004）。
    private func routeCell(input: Int, output: Int, _ s: BassManagementSettings) -> some View {
        let bit = 1 << output
        let on = s.routes[input] & bit != 0
        let inverted = on && s.inversions[input] & bit != 0
        return HStack(spacing: 6) {
            Text("→ Sub \(output + 1)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Toggle("ON", isOn: Binding(
                get: { on },
                set: { _ in edit { $0.togglingRoute(input: input, output: output) } }))
                .toggleStyle(.button)
                .accessibilityLabel("Route Ch \(input + 1) to Sub Ch \(output + 1)")
            Toggle("Ø", isOn: Binding(
                get: { inverted },
                set: { _ in edit { $0.togglingInversion(input: input, output: output) } }))
                .toggleStyle(.button)
                .disabled(!on)
                .accessibilityLabel("Invert Ch \(input + 1) route to Sub Ch \(output + 1)")
        }
    }

    // MARK: 図

    private func graph(_ s: BassManagementSettings) -> some View {
        let channel = selectedChannel
        let upper = min(20000, dsp.sampleRate * 0.48)
        let traces = curves(s, channel: channel, upper: upper)
        return VStack(alignment: .leading, spacing: 6) {
            if !graphOnly && width > 1 {
                menuRow("Response",
                        choices: (0..<width).map { BassManagementChoice(id: $0, label: "Ch \($0 + 1)") },
                        selection: channel) { graphChannel = $0 }
            }
            GraphCanvas(
                x: Self.frequencyAxis(upper: upper),
                y: ETAxis.decibels(Self.decibelRange, step: 12),
                height: ETGraphMetrics.height,
                insets: .standard,
                caption: caption(s, channel: channel),
                clipsContent: true,
                draw: { context, plot in
                    for trace in traces {
                        guard trace.points.count > 1 else { continue }
                        var path = Path()
                        for (i, point) in trace.points.enumerated() {
                            let position = plot.point(point.hz, point.db)
                            if i == 0 { path.move(to: position) } else { path.addLine(to: position) }
                        }
                        context.stroke(path,
                                       with: trace.subdued ? ETGraphShading.muted
                                                           : ETGraphShading.curve,
                                       style: StrokeStyle(lineWidth: 2, lineCap: .round,
                                                          lineJoin: .round))
                    }
                })
        }
    }

    private static func frequencyAxis(upper: Double) -> ETAxis {
        let ticks = gridFrequencies.filter { $0 <= upper }.map { hz in
            ETAxisTick(hz, labeledFrequencies.contains(hz) ? ETFormat.hzTick(hz) : nil)
        }
        return ETAxis(scale: .logarithmic, lower: 10, upper: upper, ticks: ticks)
    }

    /// 見出し。LP の掛からない Ch は上流が図の中に書く文（:1230-1237）を出す。
    private func caption(_ s: BassManagementSettings, channel: Int) -> String {
        let name = "Ch \(channel + 1)"
        if s.filter(for: channel) != nil {
            return "\(name) LP and HP, Level (dB) over Frequency (Hz)"
        }
        switch s.role(channel) {
        case .fullRange: return "\(name) Full Range · Main pass-through"
        case .lfe: return "\(name) LFE · Unfiltered Sub routing"
        default: return "\(name) Unused · No output"
        }
    }

    /// :1115-1157。LP は下へ残る分、HP は |1 - LP|。
    /// Linear で係数が入っていれば設計した応答（design-core.js:84-88）を、
    /// 無ければ _lowWeight（:1084-1090。FIRCrossoverDesignCore.lowWeight と同じ式）を使う。
    private func curves(_ s: BassManagementSettings, channel: Int, upper: Double) -> [ETFrequencyCurve] {
        guard let filter = s.filter(for: channel) else { return [] }
        let rate = s.designKey(sampleRate: dsp.sampleRate, width: width).sampleRate
        let design = s.linear ? designer.design : nil
        let response = design?.response(channel: channel, cutoff: filter.cutoff,
                                        slope: filter.slope, sampleRate: rate)
        let frequencies = design?.responseFrequencies ?? []

        func low(_ hz: Double) -> Double {
            if let response, response.count == frequencies.count {
                return Self.interpolate(response, frequencies, at: hz)
            }
            return FIRCrossoverDesignCore.lowWeight(frequency: hz, cutoff: filter.cutoff,
                                                    slope: Double(filter.slope))
        }
        let floor = Self.decibelRange.lowerBound - 60
        let lowPass = ETFrequencyCurve.sampled(id: "lp", count: Self.samples,
                                               from: 10, to: upper) { hz in
            ETdB.fromAmplitude(abs(low(hz)), floor: floor)
        }
        let highPass = ETFrequencyCurve.sampled(id: "hp", count: Self.samples,
                                                from: 10, to: upper, subdued: true) { hz in
            ETdB.fromAmplitude(abs(1 - low(hz)), floor: floor)
        }
        return [lowPass, highPass]
    }

    /// :1130-1143。対数周波数で隣の 2 点を線形に補う。
    private static func interpolate(_ response: [Float], _ frequencies: [Double],
                                    at hz: Double) -> Double {
        guard let first = frequencies.first else { return 1 }
        if hz <= first { return Double(response[0]) }
        var upperIndex = frequencies.count - 1
        var lowerIndex = 0
        // 単調に並んでいるので二分で探す。
        while upperIndex - lowerIndex > 1 {
            let middle = (lowerIndex + upperIndex) / 2
            if frequencies[middle] < hz { lowerIndex = middle } else { upperIndex = middle }
        }
        guard hz < frequencies[upperIndex] else { return Double(response[upperIndex]) }
        let lowerLog = log(frequencies[lowerIndex])
        let upperLog = log(frequencies[upperIndex])
        let fraction = (log(hz) - lowerLog) / (upperLog - lowerLog)
        let a = Double(response[lowerIndex])
        return a + (Double(response[upperIndex]) - a) * fraction
    }

    // MARK: 状態と遅延

    /// :655-663。Linear は taps/2 + 128 を処理レートで ms にしたもの、IIR は 0。
    private func statusRow(_ s: BassManagementSettings) -> some View {
        let samples = s.latencySamples
        let latency = samples == 0
            ? "0 samples"
            : "\(samples) samples / " + String(format: "%.1f ms", Double(samples) * 1000 / dsp.sampleRate)
        return HStack(spacing: 8) {
            Text(designer.status.label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(designer.status.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            Spacer(minLength: 8)
            Text(latency)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    // MARK: 部品

    @ViewBuilder
    private func row(_ key: String, gated: Bool = false) -> some View {
        if let param = param(key) {
            ParameterRow(param: param, nodeIndex: index, values: node.values, dsp: dsp)
                .disabled(gated)
                .opacity(gated ? Self.disabledOpacity : 1)
        }
    }

    /// ParameterRow の enumeration と同じ形（名前と menu の Picker）。
    private func menuRow(_ title: String,
                         choices: [BassManagementChoice],
                         selection: Int,
                         onSelect: @escaping (Int) -> Void) -> some View {
        HStack {
            Text(title).font(.system(size: 14))
            Spacer(minLength: 8)
            Picker(title, selection: Binding(get: { selection }, set: onSelect)) {
                ForEach(choices) { Text($0.label).tag($0.id) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    // MARK: 値の読み書き

    private func sync() {
        BassManagementDesigners.shared.sync(node: node)
    }

    private func param(_ key: String) -> ETParam? {
        node.spec.params.first { $0.key == key }
    }

    /// 1 つだけ変える。配列なら channel 番目。
    private func set(_ key: String, channel: Int = 0, _ value: Float) {
        guard let param = param(key) else { return }
        dsp.setValue(value, at: index, offset: param.offset + channel)
    }

    /// 複数の配列にまたがる変更。鎖の今の値から作り、1 回で渡す。
    private func edit(_ change: (BassManagementSettings) -> BassManagementSettings) {
        guard let layout, dsp.chain.indices.contains(index),
              dsp.chain[index].id == node.id else { return }
        var values = dsp.chain[index].values
        let current = BassManagementSettings(values: values, layout: layout)
        let next = change(current)
        guard next != current else { return }
        next.write(into: &values, layout: layout)
        dsp.setValues(values, at: index)
    }
}

/// menu の Picker に並べる 1 つ。
private struct BassManagementChoice: Identifiable, Sendable {
    let id: Int
    let label: String
}
