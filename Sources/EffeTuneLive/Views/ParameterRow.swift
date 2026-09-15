//  ParameterRow.swift
//  パラメータ 1 個ぶんの操作。EffeTune は「名前・スライダー・数値欄」を 1 行に並べているが、
//  iPhone の幅ではスライダーが潰れるので、名前と数値を上、スライダーを下の 2 段にした。
//
//  配列のパラメータ（マルチバンドのバンドごとの値など）は、
//  EffeTune が Band 1..5 のタブで切り替えているのと同じ形にしてある。
//  16 本のスライダーを縦に並べない。

import SwiftUI

struct ParameterRow: View {
    let param: ETParam
    let nodeIndex: Int
    let values: [Float]

    @ObservedObject var dsp: EffeTuneDSP
    @State private var slot = 0
    @State private var editing = false
    @State private var draft = ""

    private var offset: Int { param.offset + (param.isArray ? slot : 0) }
    private var value: Float { values.indices.contains(offset) ? values[offset] : 0 }

    private func set(_ v: Float) {
        dsp.setValue(v, at: nodeIndex, offset: offset)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if param.isArray {
                bandPicker
            }

            switch param.kind {
            case .toggle:
                Toggle(isOn: Binding(get: { value >= 0.5 }, set: { set($0 ? 1 : 0) })) {
                    Text(title).font(.system(size: 14))
                }

            case .enumeration(let options):
                HStack {
                    Text(title).font(.system(size: 14))
                    Spacer(minLength: 8)
                    Picker("", selection: Binding(
                        get: { min(max(Int(value.rounded()), 0), max(options.count - 1, 0)) },
                        set: { set(Float($0)) })
                    ) {
                        ForEach(Array(options.enumerated()), id: \.offset) { i, name in
                            Text(name).tag(i)
                        }
                    }
                    .pickerStyle(.menu)
                }

            case .number(let lo, let hi, let step, _, let isInteger):
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 14))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 4)
                    valueField
                }
                if hi > lo {
                    // step に 0 を渡すと Slider は落ちる。刻みが無いものは
                    // step を取らない方を使う。params.json に step が無い
                    // パラメータがあるので、ここを分けないと開いた瞬間に死ぬ。
                    let stride = step > 0 ? Double(step) : (isInteger ? 1 : 0)
                    let binding = Binding(
                        get: { Double(value) },
                        set: { set(isInteger ? Float($0.rounded()) : Float($0)) })
                    if stride > 0 {
                        Slider(value: binding, in: Double(lo)...Double(hi), step: stride)
                    } else {
                        Slider(value: binding, in: Double(lo)...Double(hi))
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var title: String {
        param.isArray ? param.label : param.label + unitSuffix
    }

    private var unitSuffix: String {
        if case .number(_, _, _, let unit, _) = param.kind, !unit.isEmpty { return " (\(unit))" }
        return ""
    }

    /// 数値欄。触ると打ち込める。
    private var valueField: some View {
        Group {
            if editing {
                TextField("", text: $draft)
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(width: ETMetrics.valueWidth, height: ETMetrics.controlHeight)
                    .background(.quaternary, in: .rect(corners: .concentric))
                    .overlay(ConcentricRectangle().stroke(.tint, lineWidth: 1))
                    .submitLabel(.done)
                    .onSubmit { commit() }
            } else {
                ValueBox(text: param.format(value))
                    .onTapGesture {
                        draft = trimmed(value)
                        editing = true
                    }
            }
        }
    }

    private func commit() {
        editing = false
        guard let v = Float(draft.trimmingCharacters(in: .whitespaces)) else { return }
        if case .number(let lo, let hi, _, _, let isInteger) = param.kind {
            let clamped = min(max(v, lo), hi)
            set(isInteger ? clamped.rounded() : clamped)
        } else {
            set(v)
        }
    }

    private func trimmed(_ v: Float) -> String {
        if case .number(_, _, _, _, let isInteger) = param.kind, isInteger {
            return String(Int(v.rounded()))
        }
        return v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
    }

    /// EffeTune のバンドタブと同じ考え方。要素を 1 つ選んで、その値だけを触る。
    private var bandPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(param.label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)

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
                                            in: .rect(corners: .concentric))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
