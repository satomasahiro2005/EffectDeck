//  VirtualRoomSceneView.swift
//  Virtual Room を真上から見た図（docs/virtual-room-design.md §7）。
//
//  描くもの: 部屋の枠、左右の仮想スピーカー、listener、直接音の線、一次反射の線。
//  触れるもの: listener と、どちらかのスピーカー。**壁は掴めない。**
//  寸法は下のスライダーで触る。
//
//  掴んでいる間も指を離すまで待たずに値を送る（§8）。

import SwiftUI

struct VirtualRoomSceneView: View {
    let layout: ETVirtualRoom.Layout
    /// 触れるか。畳んだ図（etGraphOnly）では false。
    var interactive: Bool
    /// 掴んだ先を部屋の座標（m）で返す。
    var moveListener: (CGPoint) -> Void = { _ in }
    var moveSpeaker: (CGPoint) -> Void = { _ in }

    /// いま掴んでいるもの。指を離すまで持ち替えない。
    @State private var holding: Handle?

    private enum Handle { case listener, speaker }

    /// 掴める半径（pt）。指の太さに合わせる。
    private static let grab: CGFloat = 28

    var body: some View {
        GeometryReader { geo in
            let plot = Plot(size: geo.size, layout: layout)
            Canvas { context, _ in draw(in: &context, plot: plot) }
                .contentShape(Rectangle())
                .gesture(interactive ? drag(plot: plot) : nil)
        }
        .frame(height: interactive ? 200 : 120)
        .accessibilityLabel("Room layout")
    }

    // MARK: - 座標

    /// 部屋（m）と画面（pt）の間の変換。**縦横の比は保つ。**
    /// 部屋が細長いときに図だけ正方形へ潰れると、角度が嘘になる。
    private struct Plot {
        let scale: CGFloat
        let origin: CGPoint
        let size: CGSize

        init(size: CGSize, layout: ETVirtualRoom.Layout) {
            let inset: CGFloat = 12
            let w = max(size.width - inset * 2, 1)
            let h = max(size.height - inset * 2, 1)
            let s = min(w / max(layout.width, 1e-6), h / max(layout.depth, 1e-6))
            scale = s
            let drawn = CGSize(width: layout.width * s, height: layout.depth * s)
            origin = CGPoint(x: (size.width - drawn.width) / 2,
                             y: (size.height - drawn.height) / 2)
            self.size = drawn
        }

        /// 部屋の (x, y) → 画面。**奥（+y）が上**なので y は反転する。
        func point(_ p: CGPoint) -> CGPoint {
            CGPoint(x: origin.x + p.x * scale,
                    y: origin.y + size.height - p.y * scale)
        }

        /// 画面 → 部屋。
        func room(_ p: CGPoint) -> CGPoint {
            CGPoint(x: (p.x - origin.x) / scale,
                    y: (origin.y + size.height - p.y) / scale)
        }
    }

    // MARK: - 描く

    private func draw(in context: inout GraphicsContext, plot: Plot) {
        let room = CGRect(origin: plot.origin, size: plot.size)
        context.stroke(Path(roundedRect: room, cornerRadius: 3),
                       with: ETGraphShading.axis, lineWidth: 1)

        let listener = plot.point(layout.listener)
        let left = plot.point(layout.left)
        let right = plot.point(layout.right)

        // 一次反射の道。直接音より薄くする。
        var bounces = Path()
        for hit in layout.reflections {
            let wall = plot.point(hit)
            // どちらのスピーカーから来たかは、近い方で決めてよい（図なので）。
            let source = hypot(wall.x - left.x, wall.y - left.y)
                       < hypot(wall.x - right.x, wall.y - right.y) ? left : right
            bounces.move(to: source)
            bounces.addLine(to: wall)
            bounces.addLine(to: listener)
        }
        context.stroke(bounces, with: ETGraphShading.grid,
                       style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

        // 直接音。
        var direct = Path()
        direct.move(to: left); direct.addLine(to: listener)
        direct.move(to: right); direct.addLine(to: listener)
        context.stroke(direct, with: ETGraphShading.muted, lineWidth: 1)

        // スピーカー。壁の外へ出ていて寄せたときは中を抜く。
        let shading = ETGraphShading.curve
        for centre in [left, right] {
            let box = CGRect(x: centre.x - 6, y: centre.y - 6, width: 12, height: 12)
            let path = Path(roundedRect: box, cornerRadius: 2)
            if layout.clamped {
                context.stroke(path, with: shading, lineWidth: 1.5)
            } else {
                context.fill(path, with: shading)
            }
        }

        // listener。頭を丸、向きを短い線で出す。
        let head = CGRect(x: listener.x - 7, y: listener.y - 7, width: 14, height: 14)
        context.fill(Path(ellipseIn: head), with: ETGraphShading.muted)
        var nose = Path()
        nose.move(to: listener)
        nose.addLine(to: CGPoint(x: listener.x, y: listener.y - 12))
        context.stroke(nose, with: ETGraphShading.muted, lineWidth: 1.5)
    }

    // MARK: - 掴む

    private func drag(plot: Plot) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let listener = plot.point(layout.listener)
                let left = plot.point(layout.left)
                let right = plot.point(layout.right)
                if holding == nil {
                    // **近い方を 1 度だけ選ぶ。**動かしている途中で持ち替えると、
                    // 指が通り過ぎた所で別のものが飛ぶ。
                    let toListener = hypot(value.startLocation.x - listener.x,
                                           value.startLocation.y - listener.y)
                    let toSpeaker = min(hypot(value.startLocation.x - left.x,
                                              value.startLocation.y - left.y),
                                        hypot(value.startLocation.x - right.x,
                                              value.startLocation.y - right.y))
                    let nearest = min(toListener, toSpeaker)
                    guard nearest <= Self.grab else { return }
                    holding = toListener <= toSpeaker ? .listener : .speaker
                }
                switch holding {
                case .listener: moveListener(plot.room(value.location))
                case .speaker: moveSpeaker(plot.room(value.location))
                case nil: break
                }
            }
            .onEnded { _ in holding = nil }
    }
}
