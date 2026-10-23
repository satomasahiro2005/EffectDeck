//  KeyframeTimeline.swift
//  音量に追従するカードのキーフレームを、横の帯で見せる（AE のタイムラインのように）。
//
//  横軸は音量 0〜100%。キーフレームの位置に菱形（◆）、いまの音量に縦の針（アクセント色）。
//  いまの音量を挟む2つのキーフレームの間は薄く塗る。字は目盛りの数字だけ。
//
//  出す場所:
//    - Follow Volume のシートの一番上（style .sheet）。菱形を押すとそのキーフレームのカードへ送り、
//      横へ引くと音量の位置を動かす（5% 刻み。ほかのキーフレームの位置には置けない）。
//    - 追従しているカードの頭の下（style .card）。読むだけ。押すとシートが開く（呼び手の onTapGesture）。
//      カードの長押し（並べ替え）・横に払う（削除）と取り合わないよう、ここは単純な押す・引くだけ
//      （引くのはシートの帯だけで、最小の距離を置く）。
//  音量が読めていなければ針は出さない。
//
//  Foundation 以外に触るのは SwiftUI だけ。位置・刻み・近さの判断は ETAutomation にある（AutomationTests）。

import SwiftUI

struct ETKeyframeTimeline: View {
    enum Style { case sheet, card }

    let automation: ETAutomation
    /// いまの音量。nil なら針を出さない（読めていない・PC 編集中）。
    let position: Double?
    var style: Style = .card
    /// シート: 菱形を押した（キーフレームの添字）。
    var select: ((Int) -> Void)? = nil
    /// シート: 菱形を離した先（刻みへ丸めた位置）。
    var move: ((Int, Double) -> Void)? = nil

    /// 引いている途中の菱形。離すまで DSP へは渡さない。
    private struct Drag: Equatable {
        var keyframe: Int
        var to: Double
    }

    @State private var dragging: Drag?
    /// 引き始めに掴んだ菱形。掴めなかった引きは無視する。
    @State private var grabbed: Int?
    @State private var dragStarted = false

    // MARK: 寸法

    private var isSheet: Bool { style == .sheet }
    private var diamond: CGFloat { isSheet ? 16 : 12 }
    /// 菱形が端でも欠けないよう、軸の両端を菱形の半分だけ内側に取る。
    private var inset: CGFloat { diamond / 2 }
    private var height: CGFloat { isSheet ? 48 : 20 }
    /// 軸の縦の位置（シートは下に目盛りの字を置く）。
    private var trackY: CGFloat { isSheet ? 18 : 10 }
    /// 押して菱形を掴める距離。
    private let grabDistance: CGFloat = 22

    private static let ticks: [Double] = [0, 25, 50, 75, 100]

    // MARK: 本体

    var body: some View {
        Group {
            if isSheet {
                strip.frame(height: height)
            } else {
                HStack(spacing: 4) {
                    edgeLabel("0")
                    strip
                    edgeLabel("100")
                }
                .frame(height: height)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Keyframes")
        .accessibilityValue(accessibilityText)
    }

    private func edgeLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9).monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    private var accessibilityText: String {
        var text = automation.keyframes.map { automation.source.label($0.position) }.joined(separator: ", ")
        if let position {
            text += ", Volume \(automation.source.label(position))"
        }
        return text
    }

    private var strip: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            ZStack(alignment: .topLeading) {
                // 軸
                Capsule()
                    .fill(.quaternary)
                    .frame(width: max(w - 2 * inset, 0), height: 2)
                    .position(x: w / 2, y: trackY)
                // 目盛り
                ForEach(Self.ticks, id: \.self) { p in
                    Rectangle()
                        .fill(.tertiary)
                        .frame(width: 1, height: isSheet ? 10 : 8)
                        .position(x: x(p, w), y: trackY)
                }
                // いまの音量を挟む2つのキーフレームの間
                if let s = automation.segment(at: position) {
                    let x0 = x(automation.keyframes[s.lower].position, w)
                    let x1 = x(automation.keyframes[s.upper].position, w)
                    Capsule()
                        .fill(Color.accentColor.opacity(0.35))
                        .frame(width: max(x1 - x0, 0), height: 4)
                        .position(x: (x0 + x1) / 2, y: trackY)
                }
                // 目盛りの数字（シートだけ。カードは両脇に 0 と 100）
                if isSheet {
                    ForEach(Self.ticks, id: \.self) { p in
                        Text("\(Int(p))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .position(x: x(p, w), y: h - 8)
                    }
                }
                // 菱形。引いているものは最後に描いて、色を変える。
                ForEach(automation.keyframes.indices, id: \.self) { k in
                    if dragging?.keyframe != k {
                        diamondView(tinted: false)
                            .position(x: x(automation.keyframes[k].position, w), y: trackY)
                    }
                }
                if let d = dragging {
                    diamondView(tinted: true)
                        .position(x: x(d.to, w), y: trackY)
                }
                // 針
                if let position {
                    Rectangle()
                        .fill(.tint)
                        .frame(width: 2, height: h)
                        .position(x: x(min(max(position, 0), 100), w), y: h / 2)
                }
            }
            .frame(width: w, height: h, alignment: .topLeading)
            .contentShape(Rectangle())
            .modifier(SheetGestures(enabled: isSheet,
                                    tap: { handleTap(at: $0, width: w) },
                                    changed: { handleDrag($0, width: w) },
                                    ended: { handleDragEnd() },
                                    cancelled: { resetDrag() },
                                    feedback: dragging?.to))
        }
    }

    private func diamondView(tinted: Bool) -> some View {
        Image(systemName: "diamond.fill")
            .resizable()
            .scaledToFit()
            .frame(width: diamond, height: diamond)
            .foregroundStyle(tinted ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .allowsHitTesting(false)
    }

    // MARK: 位置と x

    private func x(_ p: Double, _ width: CGFloat) -> CGFloat {
        let usable = max(width - 2 * inset, 1)
        return inset + CGFloat(p / 100) * usable
    }

    private func volume(forX x: CGFloat, width: CGFloat) -> Double {
        let usable = max(width - 2 * inset, 1)
        return Double((x - inset) / usable) * 100
    }

    /// 押して掴める距離を、音量の幅（%）にしたもの。
    private func tolerance(width: CGFloat) -> Double {
        Double(grabDistance / max(width - 2 * inset, 1)) * 100
    }

    // MARK: 操作（シートだけ）

    private func handleTap(at location: CGPoint, width: CGFloat) {
        let p = volume(forX: location.x, width: width)
        guard let k = automation.nearestKeyframe(to: p, within: tolerance(width: width)) else { return }
        select?(k)
    }

    private func handleDrag(_ value: DragGesture.Value, width: CGFloat) {
        if !dragStarted {
            dragStarted = true
            let start = volume(forX: value.startLocation.x, width: width)
            grabbed = automation.nearestKeyframe(to: start, within: tolerance(width: width))
        }
        guard let k = grabbed, automation.keyframes.indices.contains(k) else { return }
        // 塞がっている位置の上では、直前の置ける位置のまま。
        if let p = automation.dragTarget(k, to: volume(forX: value.location.x, width: width)) {
            dragging = Drag(keyframe: k, to: p)
        }
    }

    /// 引きの状態を捨てる。離したあとと、離さずに打ち切られたとき（onEnded が呼ばれない）の両方。
    private func resetDrag() {
        dragging = nil
        grabbed = nil
        dragStarted = false
    }

    private func handleDragEnd() {
        defer { resetDrag() }
        guard let d = dragging, automation.keyframes.indices.contains(d.keyframe),
              abs(automation.keyframes[d.keyframe].position - d.to) > 0.0005 else { return }
        move?(d.keyframe, d.to)
    }
}

/// シートの帯だけに付ける、押す・引く。カードの帯には何も付けない
/// （カードは呼び手が押すだけを付け、並べ替えの長押しや横に払う削除と取り合わない）。
private struct SheetGestures: ViewModifier {
    let enabled: Bool
    let tap: (CGPoint) -> Void
    let changed: (DragGesture.Value) -> Void
    let ended: () -> Void
    /// 引きが終わった（離した・打ち切られた）あとの後始末。
    let cancelled: () -> Void
    let feedback: Double?

    /// 引いている間だけ真。打ち切られても自動で偽に戻るので、そこで状態を捨てる。
    @GestureState private var active = false

    func body(content: Content) -> some View {
        if enabled {
            content
                .onTapGesture(coordinateSpace: .local, perform: tap)
                .gesture(DragGesture(minimumDistance: 6)
                    .updating($active) { _, state, _ in state = true }
                    .onChanged(changed)
                    .onEnded { _ in ended() })
                .onChange(of: active) { _, now in
                    if !now { cancelled() }
                }
                .sensoryFeedback(.selection, trigger: feedback)
        } else {
            content
        }
    }
}
