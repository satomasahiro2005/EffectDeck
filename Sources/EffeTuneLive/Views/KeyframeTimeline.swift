//  KeyframeTimeline.swift
//  音量に追従するカードのキーフレームを、横の帯で見せる（AE のタイムラインのように）。
//
//  横軸は音量 0〜100%。キーフレームの位置に菱形（◆）、いまの音量に縦の針（アクセント色）と、左にその数。
//  印は AE と同じく左右の半分でその側の変わり方を見せる。滑らかに変わる側は菱形の半分、
//  平らな側（その側にキーフレームが無い・Hold で保つ）は四角の半分。両側とも平らなら矩形。
//  いまの音量を挟む2つのキーフレームの間は薄く塗る。字はいまの音量の数だけ。
//
//  出す場所は追従しているカードの頭の下。
//  菱形を押すとそのキーフレームを選ぶ（カードの本文がその値になって直せる。左の数もその位置になる）。
//  選んでいる菱形をもう一度押すか、どの菱形でも長押しすると、その菱形を指す吹き出し（Smooth / Hold / Delete）が開く。
//  選びを外すのは、空いた所を押したときと、音量が変わったとき（カード側）だけ。
//  外すと、カードはいまの音量に一番近いキーフレームを選ぶ。
//  横へ引くと音量の位置を動かす（5% 刻み。ほかのキーフレームの位置には置けない）。選んでいる菱形はアクセント色。
//  カードの長押し（並べ替え）と払い（削除）に渡さないよう、引く面には etOwnsDrag() で印を敷く。
//  最小の距離を置いても、鎖の長押しと払いは SwiftUI のジェスチャが見えないので、印が無いと取り合う。
//  音量が読めていなければ針は出さない。
//
//  吹き出しは標準の popover。見えない出し口を対象の菱形に重ね、そこへ矢印を向ける。
//  出し口は触りを取らない（allowsHitTesting(false)）ので、菱形を横へ引く操作は今までどおり SwiftUI の引きに届く。
//  iPhone でも .presentationCompactAdaptation(.popover) でシートにせず吹き出しのまま出す。
//
//  UIKit を使うのは長押しだけ。押した所の菱形を知り、引きと同時に認識するため、UIKit の長押しを足す。
//
//  Foundation 以外に触るのは SwiftUI と UIKit（長押しだけ）。位置・刻み・近さ・押し方の判断は ETAutomation にある（AutomationTests）。

import SwiftUI
import UIKit

struct ETKeyframeTimeline: View {
    let automation: ETAutomation
    /// いまの音量。nil なら針を出さない（読めていない・PC 編集中）。
    let position: Double?
    /// 吹き出しを開いている菱形の位置。添字でなく位置で持つ（開いている間に添字がずれてもよい）。
    /// 持ち主はカード側。選ぶと帯の作り直しが起こることがあり（カードの分岐が替わる）、
    /// 帯の中で持つと長押しで置いた位置が作り直しで消えて何も開かない。
    @Binding var popoverPosition: Double?
    /// 色を変えて見せているキーフレームの添字（押して選んだものと、いまの音量で鳴っているもの）。
    var selected: Int? = nil
    /// 押して選んだキーフレームの添字。左の数はこの位置になり、2度目の押しで吹き出しが開く。
    var explicit: Int? = nil
    /// 押した。菱形ならその添字、外したなら nil。
    var select: ((Int?) -> Void)? = nil
    /// 菱形を離した先（刻みへ丸めた位置）。
    var move: ((Int, Double) -> Void)? = nil
    /// 吹き出しの Smooth / Hold。開いている間に添字がずれても当たるよう、位置で渡す。
    var setHold: ((Double, Bool) -> Void)? = nil
    /// 吹き出しの Delete。同じく位置で渡す。
    var delete: ((Double) -> Void)? = nil
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
    /// 長押しで吹き出しを開いたあとの指の動きは、菱形を動かさない。指を離すまで真。
    @State private var pressConsumed = false
    /// 帯の縦の真ん中（画面の座標）。吹き出しを上下どちらに開くかに使う。
    @State private var stripMidY: CGFloat = 0
    /// 色の違いに頼らない設定のとき、選んでいる菱形に輪を足す。
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    // MARK: 寸法

    private let diamond: CGFloat = 14
    /// 菱形が端でも欠けないよう、軸の両端を菱形の半分だけ内側に取る。
    private var inset: CGFloat { diamond / 2 }
    /// 帯の高さ。文字サイズに追従する（既定のサイズでは 30pt のまま。左の数字が切れないように）。
    @ScaledMetric(relativeTo: .caption2) private var height: CGFloat = 30
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
        // 開いている菱形が消えた・選びが外れた・触れなくなったら、覚えている位置も捨てる。
        // 捨てないと、同じ位置にキーフレームを作り直して選んだとき勝手に開き直る。
        .onChange(of: popoverTarget) { _, now in
            if now == nil { popoverPosition = nil }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Keyframes")
        .accessibilityValue(accessibilityText)
        // 音量の数字が変わり続けるので、読み上げに常に変わるものだと伝える。
        .accessibilityAddTraits(.updatesFrequently)
        // 上下のスワイプ・キーボードで選ぶ菱形を順に切り替える。いまは触るしか選ぶ手段が無く、
        // 下の Smooth / Hold / Delete に辿り着けなかった。触ったときと同じ select を呼ぶ。
        .accessibilityAdjustableAction { direction in
            guard interactive, !automation.keyframes.isEmpty else { return }
            let last = automation.keyframes.count - 1
            let current = selected ?? explicit
            switch direction {
            case .increment: select?(current.map { min($0 + 1, last) } ?? 0)
            case .decrement: select?(current.map { max($0 - 1, 0) } ?? last)
            @unknown default: break
            }
        }
        // 菱形の吹き出しは触りでしか開かない。⋯ から消えた Hold と削除の代わりに、読み上げ操作で渡す。
        .accessibilityActions {
            if interactive, let k = selected, automation.keyframes.indices.contains(k) {
                let p = automation.keyframes[k].position
                Button("Smooth") { setHold?(p, false) }
                if automation.canHold(k) {
                    Button("Hold") { setHold?(p, true) }
                }
                Button("Delete") { delete?(p) }
                // 引く代わりの 1 刻み。刻みと、ほかのキーフレームに重ならない判定は引くときと同じ（dragTarget）。
                Button("Move Left") { nudge(k, by: -automation.source.step) }
                Button("Move Right") { nudge(k, by: automation.source.step) }
            }
        }
    }

    /// 選んでいるキーフレームを 1 刻みだけ動かす。置けない所（端の外・ほかのキーフレームの上）では何もしない。
    private func nudge(_ k: Int, by delta: Double) {
        guard automation.keyframes.indices.contains(k),
              let to = automation.dragTarget(k, to: automation.keyframes[k].position + delta),
              abs(automation.keyframes[k].position - to) > 0.0005 else { return }
        move?(k, to)
    }

    /// 押して選んだキーフレームがあればその位置、無ければいまの音量（針と同じ色）。
    /// 幅は "100%" で取り、数が変わっても帯が動かないようにする。
    private var currentLabel: some View {
        let shown = automation.stripLabelPosition(explicit: explicit, volume: position)
        return ZStack(alignment: .leading) {
            Text("100%").hidden()
            Text(shown.map { automation.source.label($0) } ?? "–")
                .foregroundStyle(shown == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
        }
        .etFont(size: 11, weight: .semibold)
        .monospacedDigit()
        .fixedSize()
    }

    private var accessibilityText: String {
        var text = automation.keyframes.map {
            automation.source.label($0.position) + ($0.hold ? " Hold" : "")
        }.joined(separator: ", ")
        // 選んでいるものを先に読ませる（長い一覧の終わりまで聞かないと分からないので）。
        if let k = selected, automation.keyframes.indices.contains(k) {
            let frame = automation.keyframes[k]
            text = "Selected \(automation.source.label(frame.position))\(frame.hold ? " Hold" : ""), " + text
        }
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
                        diamondView(tinted: k == selected, sides: automation.sides(k))
                            .position(x: x(automation.keyframes[k].position, w), y: trackY)
                    }
                }
                if let d = dragging, automation.keyframes.indices.contains(d.keyframe) {
                    diamondView(tinted: true, sides: automation.sides(d.keyframe))
                        .position(x: x(d.to, w), y: trackY)
                }
                // 針
                if let position {
                    Rectangle()
                        .fill(.tint)
                        .frame(width: 2, height: h)
                        .position(x: x(min(max(position, 0), 100), w), y: h / 2)
                }
                // 吹き出しの出し口。見えないまま対象の菱形の上に置く。触りは取らない。
                // **いつも置いておく。**開くのと同じ回で出し口を作ると、出し元がまだ無くて開かないことがある。
                Color.clear
                    .frame(width: diamond, height: diamond)
                    .allowsHitTesting(false)
                    // 左右には開かない（菱形の横に出ると帯と針が隠れ、どの菱形の話か分かりにくい）。
                    // 上下は帯の位置で決める（画面の下半分なら上へ、上半分なら下へ。収まる側に開く）。
                    .popover(isPresented: popoverBinding, attachmentAnchor: .rect(.bounds), arrowEdge: popoverArrowEdge) {
                        if let k = popoverTarget { popoverContent(at: k) }
                    }
                    .position(x: x(popoverTarget.map { automation.keyframes[$0].position } ?? popoverPosition ?? 0, w),
                              y: trackY)
                    .accessibilityHidden(true)
            }
            .frame(width: w, height: h, alignment: .topLeading)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).midY } action: { stripMidY = $0 }
            .contentShape(Rectangle())
            .modifier(StripGestures(enabled: interactive,
                                    tap: { handleTap(at: $0, width: w) },
                                    longPress: { handleLongPress(at: $0, width: w) },
                                    longPressEnded: { pressConsumed = false },
                                    changed: { handleDrag($0, width: w) },
                                    ended: { handleDragEnd() },
                                    cancelled: { resetDrag() },
                                    feedback: dragging?.to))
        }
    }

    private func diamondView(tinted: Bool, sides: (leftFlat: Bool, rightFlat: Bool)) -> some View {
        KeyframeShape(leftFlat: sides.leftFlat, rightFlat: sides.rightFlat)
            .fill(tinted ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .frame(width: diamond, height: diamond)
            // 色の違いに頼らない設定のときだけ、選んでいる菱形に外側の輪を足す（通常の見た目は変えない）。
            .overlay {
                if tinted && differentiateWithoutColor {
                    KeyframeShape(leftFlat: sides.leftFlat, rightFlat: sides.rightFlat)
                        .stroke(.primary, lineWidth: 1.5)
                        .padding(-3)
                }
            }
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
        perform(ETAutomation.stripAction(hit: hit(at: location, width: width),
                                         explicit: explicit, longPress: false))
    }

    private func handleLongPress(at location: CGPoint, width: CGFloat) {
        let action = ETAutomation.stripAction(hit: hit(at: location, width: width),
                                              explicit: explicit, longPress: true)
        perform(action)
        // 開いたあとに指を動かしても、そのキーフレームを動かさない。
        if case .openMenu = action { pressConsumed = true }
    }

    private func hit(at location: CGPoint, width: CGFloat) -> Int? {
        automation.nearestKeyframe(to: volume(forX: location.x, width: width),
                                   within: tolerance(width: width))
    }

    private func perform(_ action: ETAutomation.StripAction?) {
        switch action {
        case nil:
            break
        case .select(let k):
            select?(k)
        case .deselect:
            select?(nil)
        case .openMenu(let k):
            guard automation.keyframes.indices.contains(k) else { return }
            // 長押しは選んでいない菱形にも来る。選んでから吹き出しを開く（左の数もその位置になる）。
            let p = automation.keyframes[k].position
            guard k != explicit else {
                popoverPosition = p
                return
            }
            select?(k)
            // 選ぶとカードの分岐が替わって帯ごと作り直されることがある。作り直した帯の出し口が
            // 置かれてから開くよう、1回遅らせる（出し口ができる回に開くと開かないことがある）。
            let binding = $popoverPosition
            DispatchQueue.main.async { binding.wrappedValue = p }
        }
    }

    /// 吹き出しを開いている菱形の添字。位置から引き直す。
    /// 菱形がもう無い・押して選んだ菱形でなくなった（音量が変わって選びが外れた）・触れないときは nil で、吹き出しは閉じる。
    /// 矢印を付ける出し口の辺。.top なら吹き出しは菱形の上、.bottom なら下に出る。
    private var popoverArrowEdge: Edge {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        let height = scene?.screen.bounds.height ?? 0
        return height > 0 && stripMidY > height / 2 ? .top : .bottom
    }

    private var popoverTarget: Int? {
        guard interactive, let p = popoverPosition,
              let k = automation.keyframeIndex(at: p), k == explicit else { return nil }
        return k
    }

    /// 閉じる操作（外を押す・Delete）で位置を捨てる。開く側は popoverPosition を置くだけ。
    private var popoverBinding: Binding<Bool> {
        Binding(get: { popoverTarget != nil },
                set: { if !$0 { popoverPosition = nil } })
    }

    /// 吹き出しの中身。見出しは音量、Smooth / Hold は押した瞬間に効いて開いたまま、Delete は効かせて閉じる。
    /// 動作は位置を持ち、実行時に添字を引き直す。
    @ViewBuilder
    private func popoverContent(at k: Int) -> some View {
        if automation.keyframes.indices.contains(k) {
            let p = automation.keyframes[k].position
            VStack(spacing: 12) {
                Text(automation.source.label(p))
                    .monospacedDigit()
                    .etFont(size: 15, weight: .semibold)
                    .accessibilityAddTraits(.isHeader)
                Picker("Interpolation", selection: Binding(
                    get: { automation.keyframes.indices.contains(k) && automation.keyframes[k].hold },
                    set: { setHold?(p, $0) })) {
                    Text("Smooth").tag(false)
                    Text("Hold").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // 一番上は次が無いので Hold を選べない。分節ごとの無効化は標準の Picker に無いので、
                // 隠さず部品ごと灰色にする（Smooth のまま動かない）。
                .disabled(!automation.canHold(k))
                Button(role: .destructive) {
                    delete?(p)
                    popoverPosition = nil
                } label: {
                    Label("Delete", systemImage: "trash")
                        .etFont(size: 14, weight: .semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(16)
            // 文字が大きいとき、分節の字と Delete が切れないよう広がれるようにする。
            .frame(minWidth: 240)
            // iPhone でもシートにせず、矢印つきの吹き出しのまま出す。
            .presentationCompactAdaptation(.popover)
        }
    }

    private func handleDrag(_ value: DragGesture.Value, width: CGFloat) {
        // 長押しで吹き出しを開いたあとの動きは菱形を動かさない。
        guard !pressConsumed else { return }
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
        pressConsumed = false
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
    /// 長押しが始まった点（帯の中）と、指を離した・打ち切られたとき。
    let longPress: (CGPoint) -> Void
    let longPressEnded: () -> Void
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
                .gesture(KeyframeLongPress(began: longPress, finished: longPressEnded))
                // 菱形を横へ引いたときに行が払われない・長押しで掴まれないように。
                // 触れないとき（else）は印を敷かない。掴めない面に印があると、カードの払いと長押しまで止める。
                .etOwnsDrag()
                .onChange(of: active) { _, now in
                    if !now { cancelled() }
                }
                .sensoryFeedback(.selection, trigger: feedback)
        } else {
            content
        }
    }
}

/// 菱形の長押し。押した所の菱形を知るのと、SwiftUI の押し・引きと同時に認識するために UIKit のものを足す。
/// 0.5 秒・6pt は引きの最小の距離に合わせる（6pt 動いたら長押しは外れ、引きが始まる）。
private struct KeyframeLongPress: UIGestureRecognizerRepresentable {
    let began: (CGPoint) -> Void
    let finished: () -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// 押しと引きを遅らせたり止めたりしない。
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = 0.5
        recognizer.allowableMovement = 6
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began:
            let location: CGPoint? = context.converter.localLocation
            if let location { began(location) }
        case .ended, .cancelled, .failed:
            finished()
        default:
            break
        }
    }
}
