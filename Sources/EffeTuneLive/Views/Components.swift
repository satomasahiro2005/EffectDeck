//  Components.swift
//  画面の部品と寸法。色はまだ決めていないので、ここでは持たない。
//  いまはシステムの意味づけ（primary / secondary / tint）に任せてある。
//
//  角丸は数値で持つ。
//
//  iOS 26 の concentric（器の丸みに追従させる）を一度入れたが、
//  器から遠い小さな部品では引き算の結果 0 になり、
//  minimum を付けても実機で角が消えていた。
//  見た目が先なので、値は cardRadius / innerRadius の 2 つだけに寄せてある。

import SwiftUI
import Foundation

enum ETMetrics {
    static let cardPadding: CGFloat = 14
    static let valueWidth: CGFloat = 68
    static let controlHeight: CGFloat = 30
    /// 押せる面の下限。HIG は 44×44pt を求めている。
    /// 見た目はこれより小さくてよいが、当たり判定はここまで広げる。
    static let hitTarget: CGFloat = 44
    /// カードの丸み。**ここだけが数値を持つ。**
    /// 外枠の丸み。
    static let cardRadius: CGFloat = 16
    /// 内側の部品の丸み。
    ///
    /// concentric をやめて数値で持っている。
    /// 器の丸みに追従させるのが筋だが、器から遠い小さな部品では
    /// 引き算の結果 0 になり、minimum を付けても実機で角が消えていた。
    /// 見た目が先なので数値にしてある。変えるのはこの 1 行。
    static let innerRadius: CGFloat = 8
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
            .background(.quaternary, in: .rect(cornerRadius: ETMetrics.innerRadius, style: .continuous))
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

/// 対数目盛りのスライダー。周波数や Rate のつまみに使う。
///
/// EffeTune は createLogarithmicParameterControl でこの形を作っている。
/// つまみの位置は log10 で決まり（plugin-base.js:1405-1420
/// `const logMin = Math.log10(min)` … `((logValue - logMin) / logRange) * 100`）、
/// 値は位置から `Math.pow(10, logMin + (sliderPos / 100) * logRange)` で戻す。
/// 値そのものは線形のまま持つので、DSP に渡す数はリニア版と変わらない。
///
/// 刻みは位置側にしか無い。plugin-base.js:1413 が `slider.step = 0.1`（可動域 0-100 の 1/1000）
/// を置くだけで、パラメータの step は数値欄の矢印と表示桁数にしか効かず
/// （plugin-base.js:1443-1448 の `toFixed(step < 0.1 ? 2 : …)`）、
/// つまみが返す値は丸めていない。だからここでも値は丸めない。
/// 位置の 1/1000 は iPhone の幅では 0.3pt を切るので、位置は連続で持つ。
/// 整数で持つパラメータの丸めは、呼ぶ側が渡す Binding が受け持つ。
struct ETLogSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        Slider(value: Binding(get: { position }, set: { move(to: $0) }), in: 0...1)
    }

    private var lower: Double { range.lowerBound }
    private var upper: Double { range.upperBound }
    /// 何桁ぶんの幅か。
    private var decades: Double { log10(upper) - log10(lower) }

    private var position: Double {
        guard lower > 0, decades > 0 else { return 0 }
        let v = min(max(value, lower), upper)
        return (log10(v) - log10(lower)) / decades
    }

    private func move(to p: Double) {
        guard lower > 0, decades > 0 else { return }
        let clamped = min(max(p, 0), 1)
        value = min(max(pow(10, log10(lower) + clamped * decades), lower), upper)
    }
}

/// 0 を含む対数スライダー。左端の 1 目盛りだけが 0 で、その右は下限から上限までの対数。
///
/// Static Rate のように、0（鳴らさない）と 0.01 から上の広い範囲を同じつまみで扱う値に使う。
/// 上流は各プラグインが同じ _createZeroAwareLogControl を持っている
/// （am_radio_simulator.js:2060-2100 / sw_radio_simulator.js:1785-1825 /
/// vinyl_simulator.js:1413-1453。3 本とも中身は同じ）。
///
/// 位置は 0-1000 の 1 刻みで、0 だけが値 0。1 以上は
/// `floor * Math.pow(max / floor, (position - 1) / 999)`。
/// 下限は 3 本とも 0.001 に固定してある（am_radio_simulator.js:2085 の `const floor = 0.001;`）。
struct ETZeroAwareLogSlider: View {
    @Binding var value: Double
    let maximum: Double

    /// 0 の次の目盛りが取る値。
    private static let floor = 0.001
    private static let steps = 1000.0

    var body: some View {
        Slider(value: Binding(get: { position }, set: { move(to: $0) }),
               in: 0...Self.steps, step: 1)
    }

    private var position: Double {
        guard maximum > Self.floor, value > 0 else { return 0 }
        let v = min(max(value, Self.floor), maximum)
        return 1 + (Self.steps - 1) * log(v / Self.floor) / log(maximum / Self.floor)
    }

    private func move(to p: Double) {
        guard maximum > Self.floor else { return }
        let clamped = min(max(p, 0), Self.steps)
        if clamped < 1 {
            value = 0
            return
        }
        let ratio = (clamped - 1) / (Self.steps - 1)
        value = min(Self.floor * pow(maximum / Self.floor, ratio), maximum)
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
