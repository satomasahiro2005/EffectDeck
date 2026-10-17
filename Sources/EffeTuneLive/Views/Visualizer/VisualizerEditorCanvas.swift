//  VisualizerEditorCanvas.swift
//  編集画面のキャンバス。本物の面（ETVisualizerSurfaceView）に、要素の輪郭・選択の枠と角のつまみ・案内線を重ねる。
//  プレビューは本物の描画なので、見えているものがそのまま出る。
//
//  置き場: **どの並びでも、その形の枠を、端末の安全領域と上下のバーを除いた中に収めて中央に置く**
//  （画面の向きと同じ並びは、画面を縮めた写しになる。バーが要素に被って、角のつまみに触れなくなるのを避ける）。
//  枠は両端を 22pt（つまみの半分）ずつ内に入れる。端いっぱいの要素の外向きのつまみが画面の外へ出ないように。
//
//  操作: タップで選ぶ（重なっていれば後ろのものへ巡る）、ダブルタップでインスペクタ、ドラッグで動かす、
//  角のつまみで大きさ、つまむで拡縮。端・中央・ほかの要素の辺に吸い付き、黄色の線で見せる。
//  ドラッグ中は下書きだけを舞台へ見せ（preview）、離したときに 1 回だけ書く（commit。取り消しは 1 回で戻る）。

import SwiftUI
import UIKit

struct ETVisualizerEditorCanvas: View {
    @ObservedObject var editor: ETVisualizerEditorModel
    /// キャンバスの大きさ（点）。追加のときの既定の矩形に使う。
    @Binding var canvasSize: CGSize
    /// 選んだ要素の上をダブルタップしたとき（インスペクタを開く）。
    let onInspect: (UUID) -> Void

    /// 上のバー（ナビゲーションバー）と下のバー（ツールバー）の高さ。安全領域の外側に積む。
    private static let topBarHeight: CGFloat = 44
    private static let bottomBarHeight: CGFloat = 56
    /// 角のつまみの触れる広さの半分。
    private static let handleInset: CGFloat = 22

    /// 端末の安全領域（バーを含まない）。NavigationStack の中の geo.safeAreaInsets はバーの高さを含むので、窓から読む。
    @MainActor
    private static func deviceInsets() -> EdgeInsets {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let insets = scene?.keyWindow?.safeAreaInsets ?? .zero
        return EdgeInsets(top: insets.top, leading: insets.left, bottom: insets.bottom, trailing: insets.right)
    }

    var body: some View {
        GeometryReader { geo in
            let screen = geo.size
            let safe = Self.deviceInsets()
            let physical = ETVisualizerLayoutKey.of(width: Double(screen.width), height: Double(screen.height))
            let placement = Self.placement(editor: editor, floatingRatio: ETVisualizerSettings.shared.floating.aspect.ratio ?? 5,
                                           screen: screen, safe: safe, physical: physical)
            ZStack {
                Color.black
                ETVisualizerSurfaceView(stage: editor.stage)
                    .frame(width: placement.rect.width, height: placement.rect.height)
                    .position(x: placement.rect.midX, y: placement.rect.midY)
                Rectangle()
                    .stroke(Color.white.opacity(0.25), lineWidth: 1)
                    .frame(width: placement.rect.width, height: placement.rect.height)
                    .position(x: placement.rect.midX, y: placement.rect.midY)
                    .allowsHitTesting(false)
                CanvasOverlay(
                    editor: editor, size: placement.rect.size,
                    safe: placement.ownLayout
                        ? (l: Double(safe.leading / screen.width), t: Double(safe.top / screen.height),
                           r: Double(safe.trailing / screen.width), b: Double(safe.bottom / screen.height))
                        : nil,
                    onInspect: onInspect)
                    .position(x: placement.rect.midX, y: placement.rect.midY)
            }
            .onChange(of: physical, initial: true) { _, new in editor.reportPhysical(new) }
            .onChange(of: placement.rect.size, initial: true) { _, new in canvasSize = new }
        }
        .ignoresSafeArea()
    }

    private struct Placement {
        var rect: CGRect
        /// 画面の向きと同じ並びの写し（安全領域が画面の割合で分かる）。
        var ownLayout: Bool
    }

    @MainActor
    private static func placement(editor: ETVisualizerEditorModel, floatingRatio: Double, screen: CGSize,
                                  safe: EdgeInsets, physical: ETVisualizerLayoutKey) -> Placement {
        let layout = editor.target == .inApp ? (editor.editingLayout ?? physical) : editor.layout
        let ownLayout = editor.target == .inApp && layout == physical
        // 画面の向きと同じ並びは画面の形、反対の向きは縦横を入れ替えた形、Floating Meters は縦横比の形。
        let aspect: Double
        if editor.target == .floating {
            aspect = floatingRatio
        } else if ownLayout {
            aspect = Double(screen.width / max(screen.height, 1))
        } else {
            aspect = Double(screen.height / max(screen.width, 1))
        }
        let available = CGRect(
            x: safe.leading + handleInset, y: safe.top + topBarHeight + handleInset,
            width: max(1, screen.width - safe.leading - safe.trailing - 2 * handleInset),
            height: max(1, screen.height - safe.top - safe.bottom - topBarHeight - bottomBarHeight - 2 * handleInset))
        var width = available.width
        var height = width / CGFloat(aspect)
        if height > available.height {
            height = available.height
            width = height * CGFloat(aspect)
        }
        return Placement(rect: CGRect(x: available.midX - width / 2, y: available.midY - height / 2,
                                      width: width, height: height), ownLayout: ownLayout)
    }
}

// MARK: - 重ねるもの

private struct CanvasOverlay: View {
    @ObservedObject var editor: ETVisualizerEditorModel
    let size: CGSize
    /// 画面の向きと同じ並びのときの、端末の安全領域の余白（舞台に対する割合）。
    let safe: (l: Double, t: Double, r: Double, b: Double)?
    let onInspect: (UUID) -> Void

    private struct MoveState {
        let id: UUID
        let rect0: ETVisualizerRect
        let snap: ETVisualizerEditing.Snap
    }
    private struct HandleState {
        let id: UUID
        let rect0: ETVisualizerRect
        let corner: ETVisualizerEditing.Corner
        let snap: ETVisualizerEditing.Snap
    }
    private struct PinchState {
        let id: UUID
        let rect0: ETVisualizerRect
    }

    /// ドラッグ・つまみ中の矩形（設定にはまだ書いていない）。
    @State private var live: [UUID: ETVisualizerRect] = [:]
    @State private var guidesX: [Double] = []
    @State private var guidesY: [Double] = []
    @State private var move: MoveState?
    @State private var handle: HandleState?
    @State private var pinch: PinchState?
    /// つまみが始まった。そのあいだの（終わるまでの）ドラッグは捨てる。
    @State private var interrupted = false

    private static let handleSide: CGFloat = 44
    private static let handleDot: CGFloat = 12

    // MARK: 座標

    private func points(_ r: ETVisualizerRect) -> CGRect {
        CGRect(x: r.x * size.width, y: r.y * size.height, width: r.w * size.width, height: r.h * size.height)
    }

    private func normalized(_ p: CGPoint) -> (x: Double, y: Double) {
        (Double(p.x / max(size.width, 1)), Double(p.y / max(size.height, 1)))
    }

    private var thresholdX: Double { 8 / Double(max(size.width, 1)) }
    private var thresholdY: Double { 8 / Double(max(size.height, 1)) }

    private func snap(excluding id: UUID) -> ETVisualizerEditing.Snap {
        ETVisualizerEditing.snapTargets(excluding: id, in: editor.elements, safe: safe)
    }

    private func rect(of element: ETVisualizerElement) -> ETVisualizerRect { live[element.id] ?? element.rect }

    private func contains(_ r: ETVisualizerRect, _ p: (x: Double, y: Double)) -> Bool {
        p.x >= r.x && p.x <= r.x + r.w && p.y >= r.y && p.y <= r.y + r.h
    }

    // MARK: 書く

    private func commitRect(_ id: UUID, _ rect: ETVisualizerRect) {
        let layout = editor.layout
        editor.commit { scene in
            guard let i = scene[layout].firstIndex(where: { $0.id == id }) else { return }
            scene[layout][i].rect = rect
        }
        live = [:]
        guidesX = []
        guidesY = []
    }

    private func show(_ id: UUID, _ result: ETVisualizerEditing.Result) {
        live = [id: result.rect]
        guidesX = result.guidesX
        guidesY = result.guidesY
        editor.preview(live)
    }

    // MARK: 操作

    private func tap(at point: CGPoint) {
        let hits = ETVisualizerEditing.hits(at: normalized(point), in: editor.elements)
        editor.select(ETVisualizerEditing.nextSelection(hits: hits, current: editor.selection))
    }

    private var tapGesture: some Gesture {
        SpatialTapGesture(count: 2).onEnded { value in
            // 選んでいる要素の上ならインスペクタ。そうでなければ 1 回叩いたのと同じ。
            if let selected = editor.selectedElement, contains(selected.rect, normalized(value.location)) {
                onInspect(selected.id)
            } else {
                tap(at: value.location)
            }
        }
        .exclusively(before: SpatialTapGesture().onEnded { value in tap(at: value.location) })
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard !interrupted, handle == nil else { return }
                if move == nil {
                    let start = normalized(value.startLocation)
                    var target: ETVisualizerElement?
                    if let selected = editor.selectedElement, contains(selected.rect, start) {
                        target = selected
                    } else if let hit = ETVisualizerEditing.hits(at: start, in: editor.elements).first {
                        editor.select(hit)
                        target = editor.element(hit)
                    }
                    guard let target else { return }
                    move = MoveState(id: target.id, rect0: target.rect, snap: snap(excluding: target.id))
                }
                guard let state = move else { return }
                let result = ETVisualizerEditing.move(
                    state.rect0, dx: Double(value.translation.width / max(size.width, 1)),
                    dy: Double(value.translation.height / max(size.height, 1)), snap: state.snap,
                    thresholdX: thresholdX, thresholdY: thresholdY)
                show(state.id, result)
            }
            .onEnded { _ in
                defer {
                    move = nil
                    interrupted = false
                }
                guard let state = move, !interrupted, let rect = live[state.id] else {
                    live = [:]
                    guidesX = []
                    guidesY = []
                    return
                }
                commitRect(state.id, rect)
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard let selected = editor.selectedElement else { return }
                interrupted = true
                if pinch == nil { pinch = PinchState(id: selected.id, rect0: selected.rect) }
                guard let state = pinch else { return }
                live = [state.id: ETVisualizerEditing.scale(state.rect0, by: Double(value.magnification))]
                guidesX = []
                guidesY = []
                editor.preview(live)
            }
            .onEnded { _ in
                if let state = pinch, let rect = live[state.id] { commitRect(state.id, rect) }
                pinch = nil
                // ドラッグがまだ続いているなら、そちらが終わるまで捨て続ける。
                if move == nil { interrupted = false }
            }
    }

    private func handleGesture(_ corner: ETVisualizerEditing.Corner) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if handle == nil, let selected = editor.selectedElement {
                    handle = HandleState(id: selected.id, rect0: selected.rect, corner: corner,
                                         snap: snap(excluding: selected.id))
                }
                guard let state = handle else { return }
                let r = state.rect0
                let origin: (x: Double, y: Double)
                switch state.corner {
                case .topLeft: origin = (r.x, r.y)
                case .topRight: origin = (r.x + r.w, r.y)
                case .bottomLeft: origin = (r.x, r.y + r.h)
                case .bottomRight: origin = (r.x + r.w, r.y + r.h)
                }
                let target = (x: origin.x + Double(value.translation.width / max(size.width, 1)),
                              y: origin.y + Double(value.translation.height / max(size.height, 1)))
                show(state.id, ETVisualizerEditing.resize(r, corner: state.corner, to: target, snap: state.snap,
                                                          thresholdX: thresholdX, thresholdY: thresholdY))
            }
            .onEnded { _ in
                defer { handle = nil }
                guard let state = handle, let rect = live[state.id] else { return }
                commitRect(state.id, rect)
            }
    }

    // MARK: 見た目

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .gesture(tapGesture)
                .simultaneousGesture(dragGesture)
                .simultaneousGesture(magnifyGesture)
            ForEach(editor.elements) { element in
                let frame = points(rect(of: element))
                Rectangle()
                    .stroke(Color.white.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                    .allowsHitTesting(false)
            }
            if let selected = editor.selectedElement {
                selection(selected)
            }
            ForEach(guidesX, id: \.self) { x in
                Rectangle().fill(Color.yellow)
                    .frame(width: 1, height: size.height)
                    .position(x: CGFloat(x) * size.width, y: size.height / 2)
                    .allowsHitTesting(false)
            }
            ForEach(guidesY, id: \.self) { y in
                Rectangle().fill(Color.yellow)
                    .frame(width: size.width, height: 1)
                    .position(x: size.width / 2, y: CGFloat(y) * size.height)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    @ViewBuilder
    private func selection(_ element: ETVisualizerElement) -> some View {
        let frame = points(rect(of: element))
        Rectangle()
            .stroke(Color.accentColor, lineWidth: 2)
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
            .allowsHitTesting(false)
        // 角のつまみ。見えるのは小さい丸で、触れる広さは 44pt。中心は角から斜めに外へ 11pt。
        let out = 11 / 2.0.squareRoot()
        cornerHandle(.topLeft, at: CGPoint(x: frame.minX - out, y: frame.minY - out))
        cornerHandle(.topRight, at: CGPoint(x: frame.maxX + out, y: frame.minY - out))
        cornerHandle(.bottomLeft, at: CGPoint(x: frame.minX - out, y: frame.maxY + out))
        cornerHandle(.bottomRight, at: CGPoint(x: frame.maxX + out, y: frame.maxY + out))
    }

    private func cornerHandle(_ corner: ETVisualizerEditing.Corner, at center: CGPoint) -> some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().stroke(Color.accentColor, lineWidth: 1))
            .frame(width: Self.handleDot, height: Self.handleDot)
            .frame(width: Self.handleSide, height: Self.handleSide)
            .contentShape(Rectangle())
            .gesture(handleGesture(corner))
            .position(center)
    }
}
