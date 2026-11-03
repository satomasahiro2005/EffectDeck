//  DisplayParamRows.swift
//  表示だけの設定（DSP に渡さず、鎖の display に持つもの。DSP/DisplayParams.swift）の行。
//  Analog Meter の Reference / Range / Peak Hold / Target、Rhythm Analyzer の Span など。
//
//  上流の createParameterControl / createRadioGroup / createSelectControl に当たる。
//  ParameterRow は DSP の ETParam を触る行なので、こちらは Binding を触る別の行にしてある。

import SwiftUI

/// 行の題。通常の文字サイズでは今まで通り 1 行で、長ければ 0.8 倍まで縮める。
/// アクセシビリティサイズでは縮めると文字サイズの設定を打ち消すので、縮めずに折り返す。
private struct ETRowTitle: ViewModifier {
    @Environment(\.dynamicTypeSize) private var typeSize

    func body(content: Content) -> some View {
        content
            .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            .minimumScaleFactor(typeSize.isAccessibilitySize ? 1 : 0.8)
    }
}

extension View {
    /// Effects の各行の題に付ける（ETRowTitle）。
    func etRowTitle() -> some View {
        modifier(ETRowTitle())
    }
}

/// 数 1 つ。名前と数値欄を上、スライダーを下の 2 段（ParameterRow と同じ形）。
struct ETDisplayNumberRow: View {
    let title: String
    var unit: String = ""
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// 0 なら刻み無し。
    var step: Double = 0
    var isInteger: Bool = false
    /// 末尾の 0 を出さない（Peak Hold の 0 / 10。上流は値をそのまま出す）。
    var trimsZeros: Bool = false

    private var valueText: String {
        let text = ETNumberText.stepped(value, step: isInteger ? 1 : step)
        return trimsZeros ? ETAnalogMeter.trimZeros(text) : text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(unit.isEmpty ? title : "\(title) (\(unit))")
                    .etFont(size: 14)
                    .etRowTitle()
                Spacer(minLength: 4)
                ETValueField(text: valueText,
                             label: title,
                             editText: { ETNumberText.draft(value) }) { typed in
                    commit(typed)
                }
            }
            slider
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var slider: some View {
        let binding = Binding<Double>(
            get: { min(max(value, range.lowerBound), range.upperBound) },
            set: { commit($0) })
        // 画面の題と同じく単位つきで読ませる（値には単位が付かない）。
        let spokenTitle = unit.isEmpty ? title : "\(title) (\(unit))"
        if step > 0 || isInteger {
            Slider(value: binding, in: range, step: isInteger ? 1 : step)
                .accessibilityLabel(spokenTitle)
                .accessibilityValue(valueText)
        } else {
            Slider(value: binding, in: range)
                .accessibilityLabel(spokenTitle)
                .accessibilityValue(valueText)
        }
    }

    /// 打たれた値・スライダーの値を範囲へ挟む。**丸めない**（上流の parseFiniteNumber も挟むだけ）。
    private func commit(_ v: Double) {
        guard v.isFinite else { return }
        let clamped = min(max(v, range.lowerBound), range.upperBound)
        value = isInteger ? clamped.rounded() : clamped
    }
}

/// 選択肢から 1 つ。上流の createRadioGroup（横に並ぶ 2〜3 択）に当たる。
struct ETDisplayChoiceRow<Value: Hashable>: View {
    /// 並べ方。選択肢が多くて横に入らないもの（Note Spectrogram の Highlight 11 個）はメニュー。
    enum Style { case segmented, menu }

    let title: String
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    var style: Style = .segmented

    var body: some View {
        switch style {
        case .segmented:
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .etFont(size: 14)
                picker.pickerStyle(.segmented)
            }
            .padding(.vertical, 2)
        case .menu:
            HStack(spacing: 8) {
                Text(title)
                    .etFont(size: 14)
                Spacer(minLength: 8)
                picker.pickerStyle(.menu)
                    .etFont(size: 14)
            }
            .padding(.vertical, 2)
        }
    }

    private var picker: some View {
        Picker(title, selection: $selection) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Text(option.label).tag(option.value)
            }
        }
        .labelsHidden()
    }
}

/// 入切 1 つ。上流の createCheckboxControl に当たる。
struct ETDisplayToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title).etFont(size: 14)
        }
        .padding(.vertical, 2)
    }
}

/// 「Reset」のような 1 本のボタン。上流の `.analog-meter-reset-button`。
/// 図の下に置く（カードの頭のボタンとは別。測定をやり直すだけで値は変えない）。
struct ETMeasurementButton: View {
    let title: String
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .etFont(size: 14, weight: .medium)
                .frame(minHeight: ETMetrics.controlHeight)
                .padding(.horizontal, 14)
                .background(.quaternary, in: .rect(cornerRadius: ETMetrics.innerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }
}
