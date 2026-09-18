//  ParameterRow.swift
//  パラメータ 1 個ぶんの操作。EffeTune は「名前・スライダー・数値欄」を 1 行に並べているが、
//  iPhone の幅ではスライダーが潰れるので、名前と数値を上、スライダーを下の 2 段にした。
//
//  配列のパラメータ（マルチバンドのバンドごとの値など）は、
//  EffeTune が Band 1..5 のタブで切り替えているのと同じ形にしてある。
//  16 本のスライダーを縦に並べない。

import SwiftUI

/// つまみをどの目盛りで置くか。`型名.key` で引く。
///
/// EffectCatalog.swift は生成物なので印を足せない。だから表をここに持つ。
///
/// 範囲や単位から決める形にはしなかった。「min > 0 かつ max/min が 100 倍以上」を
/// EffectCatalog の number 全部に当てて上流の呼び出し箇所と突き合わせると、
/// 上流がリニアのまま置いている 62 本を拾う。例：
///   - Compressor の Attack 0.1-100ms（compressor.js:795 は createParameterControl）
///   - Multiband Compressor の Freq 1-4（multiband_compressor.js:1318-1326 は
///     min/max を range に直結した線形のスライダー）
///   - 5Band PEQ の Freq（five_band_peq.js:589-594 に数値欄しか無く、つまみが無い）
/// 逆に Rotary Speaker の Crossover 200-2000Hz（10 倍）は取りこぼす。
/// 上流はプラグインごとに呼び分けているので、呼び出し箇所をそのまま写す。
enum ETSliderScale {
    case linear
    case logarithmic
    /// 0 を含む対数。0 は左端の 1 目盛り。
    case zeroAwareLog

    /// 上流がこのパラメータをどれで作っているか。
    static func upstream(type: String, key: String) -> ETSliderScale {
        let id = type + "." + key
        if logKeys.contains(id) { return .logarithmic }
        if zeroAwareKeys.contains(id) { return .zeroAwareLog }
        return .linear
    }

    /// createLogarithmicParameterControl を呼んでいるもの。行は Vendor/effetune/plugins の下。
    private static let logKeys: Set<String> = [
        // delay/delay.js:318,323
        "DelayPlugin.hd", "DelayPlugin.ld",
        // dynamics/compressor.js:797、expander.js:754（どちらも Ratio）
        "CompressorPlugin.rt", "ExpanderPlugin.rt",
        // eq/band_pass_filter.js:340,352
        "BandPassFilterPlugin.hf", "BandPassFilterPlugin.lf",
        // eq/comb_filter.js:184
        "CombFilterPlugin.ff",
        // eq/hi_pass_filter.js:394、eq/lo_pass_filter.js:394
        "HiPassFilterPlugin.fr", "LoPassFilterPlugin.fr",
        // eq/narrow_range.js:456,462
        "NarrowRangePlugin.hf", "NarrowRangePlugin.lf",
        // eq/room_eq.js:1445,3335,3337,3382（この 4 本はまだ EffectCatalog に無い）
        "RoomEqPlugin.pl", "RoomEqPlugin.fl", "RoomEqPlugin.fh", "RoomEqPlugin.rf",
        // lofi/am_radio_simulator.js:2148,2157
        "AMRadioSimulatorPlugin.fd", "AMRadioSimulatorPlugin.dt",
        // lofi/fm_radio_simulator.js:1251
        "FMRadioSimulatorPlugin.dl",
        "TVAudioSimulatorPlugin.dl",
        // lofi/sw_radio_simulator.js:1901,1903,1909,1935
        "SWRadioSimulatorPlugin.fd", "SWRadioSimulatorPlugin.ds",
        "SWRadioSimulatorPlugin.io", "SWRadioSimulatorPlugin.dt",
        // lofi/vinyl_simulator.js:1530
        "VinylSimulatorPlugin.rg",
        // modulation/auto_filter.js:354,355,358,362,363
        "AutoFilterPlugin.lf", "AutoFilterPlugin.hf", "AutoFilterPlugin.rt",
        "AutoFilterPlugin.at", "AutoFilterPlugin.rl",
        // modulation/auto_pan.js:205
        "AutoPanPlugin.rt",
        // modulation/chorus.js:298
        "ChorusPlugin.rt",
        // modulation/frequency_shifter.js:345,349
        "FrequencyShifterPlugin.cf", "FrequencyShifterPlugin.rt",
        // modulation/phaser.js:323,325
        "PhaserPlugin.rt", "PhaserPlugin.cf",
        // modulation/rotary_speaker.js:312
        "RotarySpeakerPlugin.xo",
        // resonator/horn_resonator.js:465、resonator/horn_resonator_plus.js:496
        "HornResonatorPlugin.co", "HornResonatorPlusPlugin.co",
        // restoration/hum_remover.js:255
        "HumRemoverPlugin.hc",
        // saturation/exciter.js:398
        "ExciterPlugin.hf",
        // saturation/sub_synth.js:366,373,381
        "SubSynthPlugin.slf", "SubSynthPlugin.shf", "SubSynthPlugin.dhf",
        // spatial/crossfeed_filter.js:178
        "CrossfeedFilterPlugin.lf",
        // spatial/crosstalk_cancellation.js:744,746（この 2 本もまだ EffectCatalog に無い）
        "CrosstalkCancellationPlugin.fl", "CrosstalkCancellationPlugin.fh",

        // 同じ配置を自前の変換で書いているもの。位置の目盛り数が違うだけで写像は同じ。
        // basics/channel_divider.js:708-730 と 786-796（位置 0-1000、10-40000Hz）
        "ChannelDividerPlugin.f1", "ChannelDividerPlugin.f2", "ChannelDividerPlugin.f3",
        // basics/fir_crossover.js:720-763 と 777-783（位置 0-1000、10-40000Hz。
        // 周波数は EffectCatalog にまだ無い）
        "FIRCrossoverPlugin.f1", "FIRCrossoverPlugin.f2", "FIRCrossoverPlugin.f3",
        // others/oscillator.js:442-450 と 744-756（位置 0-100000、20-96000Hz）
        "OscillatorPlugin.fr",
    ]

    /// _createZeroAwareLogControl を呼んでいるもの。
    private static let zeroAwareKeys: Set<String> = [
        // lofi/am_radio_simulator.js:2149
        "AMRadioSimulatorPlugin.st",
        // lofi/sw_radio_simulator.js:1905
        "SWRadioSimulatorPlugin.st",
        // lofi/vinyl_simulator.js:1531,1532,1533
        "VinylSimulatorPlugin.dr", "VinylSimulatorPlugin.st", "VinylSimulatorPlugin.sc",
    ]
}

struct ParameterRow: View {
    let param: ETParam
    let nodeIndex: Int
    let values: [Float]

    @ObservedObject var dsp: EffeTuneDSP
    @State private var slot = 0
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var offset: Int { param.offset + (param.isArray ? slot : 0) }
    private var value: Float { values.indices.contains(offset) ? values[offset] : 0 }

    private func set(_ v: Float) {
        dsp.setValue(v, at: nodeIndex, offset: offset)
    }

    @Environment(\.etGraphOnly) private var graphOnly

    var body: some View {
        if graphOnly {
            EmptyView()
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            headRow
            // 要素を選ぶ札は名前の下に置く。上に置くと、何の番号なのかを言わないまま
            // 数字だけが並ぶ。
            if param.isArray {
                bandPicker
            }
            valueSlider
        }
        .padding(.vertical, 2)
    }

    /// 名前と、値そのものを触る所。
    @ViewBuilder
    private var headRow: some View {
        switch param.kind {
        case .toggle:
            Toggle(isOn: Binding(get: { value >= 0.5 }, set: { set($0 ? 1 : 0) })) {
                Text(title).font(.system(size: 14))
            }

        case .enumeration(let options):
            HStack {
                Text(title).font(.system(size: 14))
                Spacer(minLength: 8)
                Picker(title, selection: Binding(
                    get: { min(max(Int(value.rounded()), 0), max(options.count - 1, 0)) },
                    set: { set(Float($0)) })
                ) {
                    ForEach(Array(options.enumerated()), id: \.offset) { i, name in
                        Text(name).tag(i)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

        case .number:
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                valueField
            }
        }
    }

    /// つまみ。数値のパラメータだけが持つ。
    @ViewBuilder
    private var valueSlider: some View {
        if case .number(let lo, let hi, let step, _, let isInteger) = param.kind, hi > lo {
            // step に 0 を渡すと Slider は落ちる。刻みが無いものは
            // step を取らない方を使う。params.json に step が無い
            // パラメータがあるので、ここを分けないと開いた瞬間に死ぬ。
            let stride = step > 0 ? Double(step) : (isInteger ? 1 : 0)
            let binding = Binding(
                get: { Double(value) },
                set: { set(isInteger ? Float($0.rounded()) : Float($0)) })
            switch scale(lo: lo, hi: hi) {
            case .logarithmic:
                // 位置は対数、値はリニアのまま。刻みは付けない（上流も値を丸めない）。
                // 読み上げは位置ではなく値を渡す（この 2 つは Binding が位置なので、
                // 黙っていると 0-1 や 0-1000 の位置が読まれる）。
                // 単位は名前の側に付いているので、ここも欄と同じ displayValue。
                ETLogSlider(value: binding, range: Double(lo)...Double(hi))
                    .accessibilityValue(displayValue)
            case .zeroAwareLog:
                ETZeroAwareLogSlider(value: binding, maximum: Double(hi))
                    .accessibilityValue(displayValue)
            case .linear:
                if stride > 0 {
                    Slider(value: binding, in: Double(lo)...Double(hi), step: stride)
                } else {
                    Slider(value: binding, in: Double(lo)...Double(hi))
                }
            }
        }
    }

    /// 行の名前。単位はここに付ける。上流も名前の側だけに付けていて、数値の欄には付けない
    /// （plugin-base.js:1305 と 1402 が `${label}${unit ? ' (' + unit + ')' : ''}:`、
    ///  1318-1326 で作る number 入力には単位が入らない）。
    ///
    /// 配列は「どの要素を触っているか」も名前に入れる（"Balance 3 (%)"）。
    /// 札の上に見出しを置く形にしていたが、それだと同じ名前が 2 回出るうえ、
    /// 単位が名前から落ちて（配列だけ unitSuffix を外していた）どこにも出なかった。
    private var title: String {
        let base = param.isArray ? "\(param.label) \(slot + 1)" : param.label
        return base + unitSuffix
    }

    /// この行のつまみをどの目盛りで置くか。
    ///
    /// 上流はプラグインごとに呼び分けているので型名が要る。ETParam は型を知らないので
    /// 鎖から引く。EffectCatalog.swift は生成物なので、そちらに印を足す形は取らない。
    private func scale(lo: Float, hi: Float) -> ETSliderScale {
        switch ETSliderScale.upstream(type: effectType, key: param.key) {
        case .logarithmic:
            // log10 を通すので下端が 0 以下では置けない。
            return lo > 0 ? .logarithmic : .linear
        case .zeroAwareLog:
            // 0 を持たない範囲に来たら普通の対数と変わらないので、表の想定と違う。
            return lo <= 0 && hi > 0 ? .zeroAwareLog : .linear
        case .linear:
            return .linear
        }
    }

    /// 上流のプラグイン名。
    private var effectType: String {
        dsp.chain.indices.contains(nodeIndex) ? dsp.chain[nodeIndex].spec.type : ""
    }

    private var unitSuffix: String {
        if case .number(_, _, _, let unit, _) = param.kind, !unit.isEmpty { return " (\(unit))" }
        return ""
    }

    /// 数値欄に出す文字列。単位は名前の側に付いているので、ここには付けない。
    ///
    /// 付けると単位が 1 行に 2 回出る（"Volume (dB)" と "0.00 dB"）うえ、
    /// 後ろに置けない単位が壊れる。Compressor と Expander の Ratio は単位が "1:" で、
    /// 値の後ろに回すと "2.00 1:" になる（EffectCatalog.swift:270,286。
    /// 上流は compressor.js:797 がこの "1:" を名前の側へ渡している）。
    /// Digital Error Emulator と G726 の Bit Error Rate の "10^x" も同じ。
    ///
    /// 桁数は ETParam.format と同じにしてある（EffectSpec.swift:43-46）。
    private var displayValue: String {
        guard case .number(_, _, _, _, let isInteger) = param.kind else {
            return param.format(value)
        }
        // 保存値と表示値がずれるものを通す（いまは Tilt EQ の Pivot Freq だけ）。
        let v = param.display(value)
        if isInteger { return String(Int(v.rounded())) }
        if abs(v) >= 100 { return String(format: "%.0f", v) }
        if abs(v) >= 10 { return String(format: "%.1f", v) }
        return String(format: "%.2f", v)
    }

    /// 数値欄。触ると打ち込める。
    ///
    /// Text に onTapGesture を足す形だと、支援技術から操作できない
    /// （ボタンでもテキスト欄でもないので、VoiceOver も Voice Control も届かない）。
    /// だから常に TextField を置く。編集していない間は書式付きの値を出す。
    private var valueField: some View {
        TextField(param.label, text: Binding(
            get: { editing ? draft : displayValue },
            set: { draft = $0 }))
            .keyboardType(.numbersAndPunctuation)
            .multilineTextAlignment(.center)
            .font(.system(size: 13, design: .monospaced))
            .focused($focused)
            .frame(width: ETMetrics.valueWidth, height: ETMetrics.controlHeight)
            .background(.quaternary, in: .rect(cornerRadius: ETMetrics.innerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: ETMetrics.innerRadius, style: .continuous).stroke(.tint, lineWidth: editing ? 1 : 0))
            .submitLabel(.done)
            .onSubmit { commit() }
            .onChange(of: focused) { _, now in
                if now {
                    // **画面に出ている数をそのまま渡す。**
                    // 生値を渡すと、保存値と表示値がずれるもの（Tilt EQ の Pivot は
                    // 自然対数）で、触った瞬間に 1000 が 6.91 へ飛ぶ。しかも
                    // 何も打たずに外すと commit() が store(6.91)=ln(6.91)≈1.93 を
                    // 下限 3.0 に挟むので、**触って外すだけでピボットが 20Hz になる。**
                    // commit() が store() で戻す側と対にしてある。
                    draft = trimmed(param.display(value))
                    editing = true
                } else if editing {
                    // 他を触ってキーボードが引っ込んだときも確定させる。
                    // これが無いと、打った値が渡らないまま消える。
                    commit()
                }
            }
            // 読み上げも画面と同じ切り方にする。単位は名前、数だけが値。
            .accessibilityLabel(title)
            .accessibilityValue(displayValue)
    }

    private func commit() {
        editing = false
        focused = false
        guard let typed = Float(draft.trimmingCharacters(in: .whitespaces)) else { return }
        // **挟むのは戻してから。** Tilt EQ の Pivot は 3.0〜9.9 の自然対数なので、
        // 打たれた 1000(Hz) をそのまま挟むと 9.9 = 約 19930Hz に飛ぶ。
        let v = param.store(typed)
        if case .number(let lo, let hi, _, _, let isInteger) = param.kind {
            let clamped = min(max(v, lo), hi)
            set(isInteger ? clamped.rounded() : clamped)
        } else {
            set(v)
        }
    }

    /// 打ち込み欄の初期値。**渡すのは画面に出ている数**（param.display 済み）。
    private func trimmed(_ v: Float) -> String {
        if case .number(_, _, _, _, let isInteger) = param.kind, isInteger {
            return String(Int(v.rounded()))
        }
        return v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
    }

    /// EffeTune のバンドタブと同じ考え方。要素を 1 つ選んで、その値だけを触る。
    ///
    /// 名前は上の行が出す（"Balance 3 (%)"）。ここで見出しとして繰り返さない。
    private var bandPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(0..<param.count, id: \.self) { i in
                    Button {
                        slot = i
                    } label: {
                        Text("\(i + 1)")
                            .font(.system(size: 12, weight: slot == i ? .bold : .regular))
                            .foregroundStyle(slot == i ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                            .frame(minWidth: 30, minHeight: 26)
                            .background(slot == i ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                                        in: .rect(cornerRadius: ETMetrics.innerRadius, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(param.label) \(i + 1)")
                }
            }
        }
    }
}
