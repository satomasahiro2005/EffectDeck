//  Components.swift
//  画面の部品と寸法。色はまだ決めていないので、ここでは持たない。
//  いまはシステムの意味づけ（primary / secondary / tint）に任せてある。
//
//  角丸を数値で決めない。iOS 26 以降は親の器の丸みに内側が追従する作りになっていて、
//  ConcentricRectangle がそれを担う。RoundedRectangle(cornerRadius: 10) のように
//  自分で決め打ちすると、器の中で丸みが揃わず古く見える。

import SwiftUI

enum ETMetrics {
    static let cardPadding: CGFloat = 14
    static let valueWidth: CGFloat = 68
    static let controlHeight: CGFloat = 30
}

/// エフェクトの入切。EffeTune は各エフェクトの頭に ON のバッジを置いている。
struct PowerBadge: View {
    let isOn: Bool

    var body: some View {
        Text("ON")
            .font(.system(size: 11, weight: .heavy))
            .tracking(0.5)
            .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .frame(width: 42, height: 26)
            .background(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                        in: .capsule)
    }
}

/// スライダーの右に出す数値。EffeTune は打ち込みもできる欄にしている。
struct ValueBox: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, design: .monospaced))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: ETMetrics.valueWidth, height: ETMetrics.controlHeight)
            .background(.quaternary, in: .rect(corners: .concentric))
    }
}

/// エフェクト 1 個ぶんの枠。丸みは器に追従させる。
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(.regularMaterial, in: .rect(corners: .concentric))
    }
}

extension String {
    /// dsp/plugins の下の名前を、EffeTune の一覧に出ている見出しへ。
    var categoryLabel: String {
        switch self {
        case "eq":   return "EQ"
        case "lofi": return "Lo-Fi"
        default:     return prefix(1).uppercased() + dropFirst()
        }
    }
}

/// 刻みが 0 のときに落ちない Slider。
///
/// SwiftUI の Slider(value:in:step:) は step が 0 だと落ちる。
/// params.json に step を持たないパラメータがあるので、そのまま渡すと
/// カードを開いた瞬間に死ぬ。刻みが無いものは step を取らない方を使う。
struct ETSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0

    var body: some View {
        if step > 0 {
            Slider(value: $value, in: range, step: step)
        } else {
            Slider(value: $value, in: range)
        }
    }
}
