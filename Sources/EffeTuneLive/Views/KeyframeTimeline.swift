//  KeyframeTimeline.swift
//  音量に追従するカードのキーフレームを、横の帯で見せる（AE のタイムラインのように）。
//
//  横軸は音量 0〜100%。キーフレームの位置に菱形（◆）、いまの音量に縦の針（アクセント色）と、左にその数。
//  印は AE と同じく左右の半分でその側の変わり方を見せる。滑らかに変わる側は菱形の半分、
//  平らな側（その側にキーフレームが無い・Hold で保つ）は四角の半分。両側とも平らなら矩形。
//  いまの音量を挟む2つのキーフレームの間は薄く塗る。字は目盛りの数字だけ。
//
//  出す場所は追従しているカードの頭の下。
//  菱形を押すとそのキーフレームを選び（カードの本文がその値になって直せる）、同じ菱形か空いた所を押すと外す
//  （外すと、カードはいまの音量に一番近いキーフレームを選ぶ）。
//  横へ引くと音量の位置を動かす（5% 刻み。ほかのキーフレームの位置には置けない）。選んでいる菱形はアクセント色。
//  カードの長押し（並べ替え）と取り合わないよう、引くのは最小の距離を置いた横の引きだけ。
//  音量が読めていなければ針は出さない。
//
//  Foundation 以外に触るのは SwiftUI だけ。位置・刻み・近さの判断は ETAutomation にある（AutomationTests）。

import SwiftUI

struct ETKeyframeTimeline: View {
    let automation: ETAutomation
    /// いまの音量。nil なら針を出さない（読めていない・PC 編集中）。
    let position: Double?
    /// 選んでいるキーフレームの添字。
    var selected: Int? = nil
    /// 押した。菱形ならその添字、外したなら nil。
    var select: ((Int?) -> Void)? = nil
    /// 菱形を離した先（刻みへ丸めた位置）。
    var move: ((Int, Double) -> Void)? = nil
    /// 押す・引くを受けるか（並べ替えの浮いたカード・PC 編集中は受けない）。
    var interactive = true

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

    private let diamond: CGFloat = 14
    /// 菱形が端でも欠けないよう、軸の両端を菱形の半分だけ内側に取る。
    private var inset: CGFloat { diamond / 2 }
    private let height: CGFloat = 30
    private var trackY: CGFloat { height / 2 }
    /// 押して菱形を掴める距離。
    private let grabDistance: CGFloat = 22

    private static let ticks: [Double] = [0, 25, 50, 75, 100]

    // MARK: 本体

    var body: some View {
        HStack(spacing: 6) {
            currentLabel
            strip
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Keyframes")
        .accessibilityValue(accessibilityText)
    }

    /// いまの音量（針と同じ色）。幅は "100%" で取り、数が変わっても帯が動かないようにする。
    private var currentLabel: some View {
        ZStack(alignment: .leading) {
            Text("100%").hidden()
            Text(position.map { automation.source.label(min(max($0, 0), 100)) } ?? "–")
                .foregroundStyle(position == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
        }
        .font(.system(size: 11, weight: .semibold).monospacedDigit())
        .fixedSize()
    }

    private var accessibilityText: String {
        var text = automation.keyframes.map {
            automation.source.label($0.position) + ($0.hold ? " Hold" : "")
        }.joined(separator: ", ")
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
                        .frame(width: 1, height: 8)
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
                // 菱形。選んでいるものは色を変え、引いているものは最後に描く。
                ForEach(automation.keyframes.indices, id: \.self) { k in
                    if dragging?.keyframe != k {
                        diamondView(tinted: k == selected, sides: sides(k))
                            .position(x: x(automation.keyframes[k].position, w), y: trackY)
                    }
                }
                if let d = dragging, automation.keyframes.indices.contains(d.keyframe) {
                    diamondView(tinted: true, sides: sides(d.keyframe))
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
            .modifier(StripGestures(enabled: interactive,
                                    tap: { handleTap(at: $0, width: w) },
                                    changed: { handleDrag($0, width: w) },
                                    ended: { handleDragEnd() },
                                    cancelled: { resetDrag() },
                                    feedback: dragging?.to))
        }
    }

    /// k 番目の印の左右が平らか。左は左隣が無いか左隣が Hold、右は右隣が無いか自分が Hold。
    private func sides(_ k: Int) -> (leftFlat: Bool, rightFlat: Bool) {
        let keys = automation.keyframes
        return (k == 0 || keys[k - 1].hold, k == keys.count - 1 || keys[k].hold)
    }

    private func diamondView(tinted: Bool, sides: (leftFlat: Bool, rightFlat: Bool)) -> some View {
        KeyframeShape(leftFlat: sides.leftFlat, rightFlat: sides.rightFlat)
            .fill(tinted ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .frame(width: diamond, height: diamond)
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

    // MARK: 操作

    private func handleTap(at location: CGPoint, width: CGFloat) {
        let p = volume(forX: location.x, width: width)
        let k = automation.nearestKeyframe(to: p, within: tolerance(width: width))
        select?(k == selected ? nil : k)
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

/// キーフレームの印。左右の半分を、滑らかな側は菱形の半分、平らな側は四角の半分で描く。
/// 四角の半分は菱形の半分より細くして、矩形が菱形より大きく見えないようにする。
private struct KeyframeShape: Shape {
    let leftFlat: Bool
    let rightFlat: Bool

    func path(in rect: CGRect) -> Path {
        let flat = rect.width / 2 * 0.7
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        if leftFlat {
            path.addLine(to: CGPoint(x: rect.midX - flat, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX - flat, y: rect.maxY))
        } else {
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        }
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        if rightFlat {
            path.addLine(to: CGPoint(x: rect.midX + flat, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX + flat, y: rect.minY))
        } else {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
        path.closeSubpath()
        return path
    }
}

/// 帯の押す・引く。並べ替えの浮いたカードと PC 編集中は付けない。
private struct StripGestures: ViewModifier {
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
