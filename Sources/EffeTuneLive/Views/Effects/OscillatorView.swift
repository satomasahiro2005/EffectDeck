//  OscillatorView.swift
//  Oscillator（OscillatorPlugin）。
//
//  図は無い。専用の画面にしたのは、上流が波形と Mode を見て操作を殺しているのと、
//  Panning と Mode をラジオで出していて、汎用の ParameterRow では出せないため。
//
//  --- 上流の規則（plugins/others/oscillator.js）---
//    683-697 updateControlStates()
//      Frequency  波形が impulse / white / pink のときは触れない
//      Continuous 波形が impulse のときは触れない
//      Interval   Mode が pulsed のときだけ触れる
//      Width      Mode が pulsed かつ波形が impulse でないときだけ触れる
//    375, 381  波形が impulse なら Mode は pulsed。setWaveform も setMode も書き潰すので、
//              impulse かつ continuous という組み合わせは上流では作れない
//    396-399   clampWidthToInterval。Width の上限は Interval の半分
//    490-512   Panning は Center / Left / Right の 3 択。値は 0 / -1 / 1
//    530-538   波形の並びと表示名
//    563-591   Mode は Continuous / Pulsed の 2 択
//
//  カーネルも同じ切り分けをしている
//  （dsp/plugins/others/oscillator/kernel.cpp:99-118）。
//  waveform 6（impulse）は pulsed の掛け算を通らないので Width を読まない。
//  同 116-118 は width と interval/2 の小さい方を使う。
//  waveform 4（white）と 5（pink）は frequency を読まない。
//
//  周波数の対数つまみは ParameterRow 側が持っている
//  （ParameterRow.swift:95-96 の OscillatorPlugin.fr）。ここでは足さない。

import SwiftUI

/// 選択肢 1 つ。保存値の綴りと、画面に出す名前。
private struct ETOscChoice: Identifiable {
    let value: String
    let label: String
    var id: String { value }
}

/// Panning の選択肢。こちらは値が数。
private struct ETOscPan: Identifiable {
    let value: Float
    let label: String
    var id: String { label }
}

struct OscillatorView: View {

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    /// 波形の並びと表示名。oscillator.js:530-538 の waveformOptions。
    /// value は保存値の綴りで、EffectCatalog の enumeration はこれとは別の順で持っている
    /// （保存値の並び＝oscillator.js:371-375 の isAllowedEnum）。並べ替えるのは表示だけ。
    private static let waveforms: [ETOscChoice] = [
        ETOscChoice(value: "sine", label: "Sine"),
        ETOscChoice(value: "sawtooth", label: "Sawtooth"),
        ETOscChoice(value: "triangle", label: "Triangle"),
        ETOscChoice(value: "square", label: "Square"),
        ETOscChoice(value: "impulse", label: "Impulse"),
        ETOscChoice(value: "white", label: "White Noise"),
        ETOscChoice(value: "pink", label: "Pink Noise")
    ]

    /// oscillator.js:567
    private static let modes: [ETOscChoice] = [
        ETOscChoice(value: "continuous", label: "Continuous"),
        ETOscChoice(value: "pulsed", label: "Pulsed")
    ]

    /// oscillator.js:494。並びは Center / Left / Right で、値は 0 / -1 / 1。
    private static let pannings: [ETOscPan] = [
        ETOscPan(value: 0, label: "Center"),
        ETOscPan(value: -1, label: "Left"),
        ETOscPan(value: 1, label: "Right")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(node.spec.params) { param in
                row(param)
            }
        }
        // Interval を縮めたら Width も詰める。上流は setInterval と setWidth の両方が
        // clampWidthToInterval を通し、数値欄にも書き戻す（oscillator.js:385-399, 623-624）。
        // 打ち込みでもつまみでも同じ所を通るよう、値そのものを見ている。
        .onChange(of: value("it"), initial: true) { _, _ in clampWidth() }
        .onChange(of: value("wd")) { _, _ in clampWidth() }
        // 共有リンクやプリセットは値をそのまま流し込むので、impulse なのに Mode が
        // continuous のまま来ることがある（ETShareLink → PipelineStore.parse は
        // 上流の setter を通らない）。上流は setWaveform も setMode も書き潰していて
        // その組み合わせを持たない（oscillator.js:375,381）。合わせないと Interval が
        // 触れないままになるが、impulse は Interval でしか音が変わらない
        // （kernel.cpp:187-199 の generateImpulse は mode を見ずに interval を読む）。
        .onChange(of: value("wf"), initial: true) { _, _ in forcePulsedForImpulse() }
    }

    /// 並びは EffectCatalog の params と同じ。上流の createUI が並べる順でもある
    /// （oscillator.js:702-708）。
    @ViewBuilder
    private func row(_ param: ETParam) -> some View {
        switch param.key {
        case "pn":
            panningRow(param)
        case "wf":
            waveformRow(param)
        case "md":
            modeRow(param)
        default:
            ParameterRow(param: param, nodeIndex: index, values: node.values, dsp: dsp)
                .disabled(isLocked(param.key))
        }
    }

    // MARK: 触れる・触れない

    /// oscillator.js:683-697。上流は slider と数値欄だけを disabled にして、名前は残す。
    private func isLocked(_ key: String) -> Bool {
        switch key {
        case "fr": return waveform == "impulse" || waveform == "white" || waveform == "pink"
        case "it": return !isPulsed
        case "wd": return !isPulsed || waveform == "impulse"
        default:   return false
        }
    }

    // MARK: 選ぶ行

    private func panningRow(_ param: ETParam) -> some View {
        choiceGroup(param.label) {
            HStack(spacing: 6) {
                ForEach(Self.pannings) { option in
                    choiceButton(option.label,
                                 selected: value("pn") == option.value,
                                 enabled: true) {
                        set(param, option.value)
                    }
                }
            }
        }
    }

    private func waveformRow(_ param: ETParam) -> some View {
        choiceGroup(param.label) {
            // 7 つある。iPhone の幅では 1 行に並ばないので折り返す。
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], spacing: 6) {
                ForEach(Self.waveforms) { option in
                    if let slot = optionIndex(param, option.value) {
                        choiceButton(option.label,
                                     selected: choice(param) == slot,
                                     enabled: true) {
                            selectWaveform(param, slot: slot, value: option.value)
                        }
                    }
                }
            }
        }
    }

    private func modeRow(_ param: ETParam) -> some View {
        choiceGroup(param.label) {
            HStack(spacing: 6) {
                ForEach(Self.modes) { option in
                    if let slot = optionIndex(param, option.value) {
                        choiceButton(option.label,
                                     selected: choice(param) == slot,
                                     enabled: !(option.value == "continuous" && waveform == "impulse")) {
                            set(param, Float(slot))
                        }
                    }
                }
            }
        }
    }

    /// 波形に impulse を選ぶと Mode は pulsed になる（oscillator.js:375）。
    ///
    /// ここで `waveform` を読み直さないのは、node が親から渡された写しで、
    /// set() の書き先（dsp.chain）とは別物だから。押した選択肢の綴りで判じる。
    private func selectWaveform(_ param: ETParam, slot: Int, value name: String) {
        set(param, Float(slot))
        guard name == "impulse" else { return }
        setPulsed()
    }

    /// 波形が impulse なら Mode を pulsed に揃える（oscillator.js:381）。
    /// node が入れ替わった後に呼ばれるので、こちらは保存値を読んで判じてよい。
    private func forcePulsedForImpulse() {
        guard waveform == "impulse", !isPulsed else { return }
        setPulsed()
    }

    private func setPulsed() {
        guard let mode = parameter("md"),
              let pulsed = optionIndex(mode, "pulsed") else { return }
        set(mode, Float(pulsed))
    }

    // MARK: 部品

    private func choiceGroup<Content: View>(_ label: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 14))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            content()
        }
        .padding(.vertical, 2)
    }

    /// 直のボタン。上流はラジオと select だが、どちらも選択肢が全部見えている。
    /// 押せる面は 44pt を確保する。
    private func choiceButton(_ label: String, selected: Bool, enabled: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, minHeight: ETMetrics.hitTarget)
                .background(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                            in: .rect(cornerRadius: ETMetrics.innerRadius, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        // 自前の label は disabled でも薄くならないので、ここで落とす。
        .opacity(enabled ? 1 : 0.4)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: 値

    /// Width の上限は Interval の半分（oscillator.js:396-399）。
    /// カーネルも同じ上限で鳴らす（kernel.cpp:116-118）ので、音は元から詰まっている。
    /// ここで直すのは表示と保存値。
    private func clampWidth() {
        guard let width = parameter("wd") else { return }
        let maximum = value("it") * 0.5
        guard maximum > 0, value("wd") > maximum else { return }
        set(width, maximum)
    }

    /// 保存名で引く。offset を直に書くと、カタログを作り直したときに黙ってずれる。
    private func parameter(_ key: String) -> ETParam? {
        node.spec.params.first { $0.key == key }
    }

    private func value(_ key: String) -> Float {
        guard let param = parameter(key), node.values.indices.contains(param.offset) else { return 0 }
        return node.values[param.offset]
    }

    private func set(_ param: ETParam, _ newValue: Float) {
        dsp.setValue(newValue, at: index, offset: param.offset)
    }

    /// enumeration のいまの添字。
    private func choice(_ param: ETParam) -> Int {
        Int(value(param.key).rounded())
    }

    /// 綴りが enumeration の何番目か。並びは EffectCatalog が持っている。
    private func optionIndex(_ param: ETParam, _ name: String) -> Int? {
        guard case .enumeration(let options) = param.kind else { return nil }
        return options.firstIndex(of: name)
    }

    /// いまの波形の綴り。
    private var waveform: String {
        guard let param = parameter("wf"), case .enumeration(let options) = param.kind else { return "" }
        let slot = choice(param)
        return options.indices.contains(slot) ? options[slot] : ""
    }

    private var isPulsed: Bool {
        guard let param = parameter("md"), case .enumeration(let options) = param.kind else { return false }
        let slot = choice(param)
        return options.indices.contains(slot) && options[slot] == "pulsed"
    }
}
