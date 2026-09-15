//  Components.swift
//  画面の部品と寸法だけ。色はまだ決めていないので、ここでは持たない。
//  いまはシステムの意味づけ（primary / secondary / tint）に任せてある。
//  配色を入れるときはこのファイルに 1 か所だけ足せば済むようにしておく。

import SwiftUI

enum ETMetrics {
    static let radius: CGFloat = 10
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
            .foregroundStyle(isOn ? Color.white : .secondary)
            .frame(width: 42, height: 26)
            .background(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                        in: RoundedRectangle(cornerRadius: 5))
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
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
    }
}

/// エフェクト 1 個ぶんの枠。
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: ETMetrics.radius))
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
