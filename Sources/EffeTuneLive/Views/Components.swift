//  Components.swift
//  画面の部品と寸法。色はまだ決めていないので、ここでは持たない。
//  いまはシステムの意味づけ（primary / secondary / tint）に任せてある。
//
//  角丸は器に追従させる。iOS 26 以降の concentric がそれを担う。
//
//  ただし concentric は「一番近い器の丸みから、そこまでの距面を引いた値」。
//  器を名乗らないと画面そのものが器になり、深い位置の小さな部品は
//  引き算の結果 0 になって角が消える。実際これで消えていた。
//  そこで Card が containerShape で器を名乗り、中の部品はそこから引く。
//  さらに minimum を付けて、どんな場所でも 0 には落ちないようにしてある。

import SwiftUI

enum ETMetrics {
    static let cardPadding: CGFloat = 14
    static let valueWidth: CGFloat = 68
    static let controlHeight: CGFloat = 30
    /// 押せる面の下限。HIG は 44×44pt を求めている。
    /// 見た目はこれより小さくてよいが、当たり判定はここまで広げる。
    static let hitTarget: CGFloat = 44
    /// カードの丸み。**ここだけが数値を持つ。**
    /// 中の部品はこれから concentric で引くので、変えるのはこの 1 行。
    static let cardRadius: CGFloat = 16
    /// 内側の部品の丸みの下限。器から遠いところでも角を残す。
    /// concentric(minimum:) は CGFloat ではなく Edge.Corner.Style を取る。
    @available(iOS 26.0, *)
    static let innerMinRadius: Edge.Corner.Style = .fixed(8)
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
            .background(.quaternary, in: .rect(corners: .concentric(minimum: ETMetrics.innerMinRadius)))
    }
}

/// エフェクト 1 個ぶんの枠。
///
/// これ自身が器になるので、丸みを数値で持つのはここだけ。
/// containerShape を名乗っておかないと、中の concentric が画面を器と見て
/// 引き算で 0 になる。
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(.regularMaterial,
                        in: .rect(cornerRadius: ETMetrics.cardRadius, style: .continuous))
            .containerShape(.rect(cornerRadius: ETMetrics.cardRadius, style: .continuous))
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


/// エフェクトの入切。
///
/// 見た目は EffeTune の ON バッジに寄せているが、中身は Toggle。
/// Button で作ると支援技術からはただのボタンに見え、入っているのか切れて
/// いるのかが伝わらない（HIG: Toggles）。
/// 状態を色だけで伝えないよう、字形も変える（入は塗り、切は輪郭）。
/// 当たり判定は 44pt を確保する。
struct PowerToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            Image(systemName: configuration.isOn ? "power.circle.fill" : "power.circle")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(configuration.isOn ? AnyShapeStyle(.tint)
                                                    : AnyShapeStyle(.secondary))
                .frame(width: ETMetrics.hitTarget, height: ETMetrics.hitTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

extension ToggleStyle where Self == PowerToggleStyle {
    static var power: PowerToggleStyle { PowerToggleStyle() }
}

/// 図だけを見たいとき true。Analyzer 系のカードが立てる。
/// ParameterRow がこれを見て自分を消すので、専用の画面を 1 つずつ直さずに済む。
extension EnvironmentValues {
    @Entry var etGraphOnly: Bool = false
}
