//  VisualizerSceneEditing.swift
//  編集の規則。当たり判定・動かす・大きさを替える・つまむ・合わせる・重なりの順・複製・足す要素の既定・取り消し。
//  画面にも UIKit にも触らない（編集画面のキャンバスが呼ぶ）。Foundation だけ
//  （Tests/Unit/VisualizerSceneEditingTests.swift）。
//
//  座標は舞台に対する 0〜1。合わせる幅（threshold）は点の幅をキャンバスの大きさで割って呼び手が渡す。
//  動かす・大きさを替えるは、合わせたあとに枠の中へ収める（収まらなかった分の案内線は捨てる）。

import Foundation

enum ETVisualizerArrange {
    case front, forward, backward, back
}

enum ETVisualizerEditing {

    // MARK: 当たり判定

    /// 点の下の要素（手前から）。端も含む。
    static func hits(at p: (x: Double, y: Double), in elements: [ETVisualizerElement]) -> [UUID] {
        elements.reversed().filter { element in
            let r = element.rect
            return p.x >= r.x && p.x <= r.x + r.w && p.y >= r.y && p.y <= r.y + r.h
        }.map(\.id)
    }

    /// 叩いたときの次の選択。いま選んでいるものが下にあれば、その後ろの 1 つ（一巡する）。無ければ手前。
    static func nextSelection(hits: [UUID], current: UUID?) -> UUID? {
        guard let first = hits.first else { return nil }
        guard let current, let index = hits.firstIndex(of: current) else { return first }
        return hits[(index + 1) % hits.count]
    }

    // MARK: 合わせる

    struct Snap: Equatable {
        var xs: [Double]
        var ys: [Double]
    }

    /// 合わせる先。舞台の端と中央、ほかの要素の左・中・右（上・中・下）。
    /// `safe` は安全領域の内側の余白（舞台に対する割合。画面いっぱいのときだけ）。
    static func snapTargets(excluding id: UUID, in elements: [ETVisualizerElement],
                            safe: (l: Double, t: Double, r: Double, b: Double)?) -> Snap {
        var xs: [Double] = [0, 0.5, 1], ys: [Double] = [0, 0.5, 1]
        for element in elements where element.id != id {
            let r = element.rect
            xs += [r.x, r.x + r.w / 2, r.x + r.w]
            ys += [r.y, r.y + r.h / 2, r.y + r.h]
        }
        if let safe {
            xs += [safe.l, 1 - safe.r]
            ys += [safe.t, 1 - safe.b]
        }
        return Snap(xs: xs, ys: ys)
    }

    struct Result: Equatable {
        var rect: ETVisualizerRect
        var guidesX: [Double]
        var guidesY: [Double]
    }

    /// 3 つの印（小・中・大）のうち、いちばん近い 1 つが threshold 以内なら合わせる量と先。
    /// 同じ近さなら印の早いほう、次に先の早いほう。
    private static func snapAxis(anchors: [Double], targets: [Double], threshold: Double) -> (delta: Double, guide: Double)? {
        var best: (delta: Double, guide: Double)?
        for anchor in anchors {
            for target in targets {
                let d = target - anchor
                guard abs(d) <= threshold else { continue }
                if best == nil || abs(d) < abs(best!.delta) { best = (d, target) }
            }
        }
        return best
    }

    private static func matches(_ guide: Double, _ values: [Double]) -> Bool {
        values.contains { abs($0 - guide) < 1e-9 }
    }

    /// 動かす。左・中・右（上・中・下）のうち最も近い 1 つが threshold 以内なら合わせる。軸ごとに別。最後に枠の中へ収める。
    static func move(_ r: ETVisualizerRect, dx: Double, dy: Double, snap: Snap,
                     thresholdX: Double, thresholdY: Double) -> Result {
        var moved = ETVisualizerRect(x: r.x + dx, y: r.y + dy, w: r.w, h: r.h)
        var guideX: Double?, guideY: Double?
        if let hit = snapAxis(anchors: [moved.x, moved.x + moved.w / 2, moved.x + moved.w],
                              targets: snap.xs, threshold: thresholdX) {
            moved.x += hit.delta
            guideX = hit.guide
        }
        if let hit = snapAxis(anchors: [moved.y, moved.y + moved.h / 2, moved.y + moved.h],
                              targets: snap.ys, threshold: thresholdY) {
            moved.y += hit.delta
            guideY = hit.guide
        }
        let clamped = clamp(moved)
        // 収めて動いたら、もう合っていない案内線は捨てる。
        let xs = [clamped.x, clamped.x + clamped.w / 2, clamped.x + clamped.w]
        let ys = [clamped.y, clamped.y + clamped.h / 2, clamped.y + clamped.h]
        return Result(rect: clamped,
                      guidesX: guideX.flatMap { matches($0, xs) ? [$0] : nil } ?? [],
                      guidesY: guideY.flatMap { matches($0, ys) ? [$0] : nil } ?? [])
    }

    enum Corner {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    /// 1 点を先へ合わせる。
    private static func snapPoint(_ value: Double, _ targets: [Double], _ threshold: Double) -> (value: Double, guide: Double?) {
        guard let hit = snapAxis(anchors: [value], targets: targets, threshold: threshold) else { return (value, nil) }
        return (value + hit.delta, hit.guide)
    }

    /// 角を動かす。動く 2 辺だけを合わせる。反対の角は動かない。幅と高さは 0.02 以上、枠の中。
    static func resize(_ r: ETVisualizerRect, corner: Corner, to p: (x: Double, y: Double), snap: Snap,
                       thresholdX: Double, thresholdY: Double) -> Result {
        let sx = snapPoint(p.x, snap.xs, thresholdX)
        let sy = snapPoint(p.y, snap.ys, thresholdY)
        let minSize = ETVisualizerScene.minSize
        let left = corner == .topLeft || corner == .bottomLeft
        let top = corner == .topLeft || corner == .topRight
        // 反対の角。
        let fx = left ? r.x + r.w : r.x
        let fy = top ? r.y + r.h : r.y
        let mx = left ? min(max(sx.value, 0), fx - minSize) : max(min(sx.value, 1), fx + minSize)
        let my = top ? min(max(sy.value, 0), fy - minSize) : max(min(sy.value, 1), fy + minSize)
        let rect = ETVisualizerRect(x: min(mx, fx), y: min(my, fy), w: abs(mx - fx), h: abs(my - fy))
        return Result(rect: rect,
                      guidesX: sx.guide.flatMap { abs($0 - mx) < 1e-9 ? [$0] : nil } ?? [],
                      guidesY: sy.guide.flatMap { abs($0 - my) < 1e-9 ? [$0] : nil } ?? [])
    }

    /// つまんで拡げる。中心は動かさず、縦横同じ倍率。0.02〜1 に収め、はみ出たら枠の中へ寄せる。
    static func scale(_ r: ETVisualizerRect, by k: Double) -> ETVisualizerRect {
        guard k.isFinite, k > 0 else { return clamp(r) }
        let small = min(r.w, r.h), large = max(r.w, r.h)
        guard small > 0, large > 0 else { return clamp(r) }
        let factor = min(max(k, ETVisualizerScene.minSize / small), 1 / large)
        let w = r.w * factor, h = r.h * factor
        let cx = r.x + r.w / 2, cy = r.y + r.h / 2
        return clamp(ETVisualizerRect(x: cx - w / 2, y: cy - h / 2, w: w, h: h))
    }

    static func clamp(_ r: ETVisualizerRect) -> ETVisualizerRect {
        ETVisualizerScene.clamp(r)
    }

    // MARK: 重なりの順

    static func arrange(_ elements: [ETVisualizerElement], _ id: UUID, _ op: ETVisualizerArrange) -> [ETVisualizerElement] {
        guard canArrange(elements, id, op), let index = elements.firstIndex(where: { $0.id == id }) else { return elements }
        var result = elements
        let element = result.remove(at: index)
        switch op {
        case .front: result.append(element)
        case .back: result.insert(element, at: 0)
        case .forward: result.insert(element, at: index + 1)
        case .backward: result.insert(element, at: index - 1)
        }
        return result
    }

    /// 動かす先があるか（端でさらに端へは動かせない）。
    static func canArrange(_ elements: [ETVisualizerElement], _ id: UUID, _ op: ETVisualizerArrange) -> Bool {
        guard let index = elements.firstIndex(where: { $0.id == id }) else { return false }
        switch op {
        case .front, .forward: return index < elements.count - 1
        case .back, .backward: return index > 0
        }
    }

    // MARK: 複製・足す

    /// 複製は元のすぐ上（index+1）に、右下へ 0.03 ずらして（枠の中へ収める）。id は新しく。
    static func duplicate(_ elements: [ETVisualizerElement], _ id: UUID, newID: UUID) -> [ETVisualizerElement] {
        guard let index = elements.firstIndex(where: { $0.id == id }) else { return elements }
        var copy = elements[index]
        copy.id = newID
        copy.rect = clamp(ETVisualizerRect(x: copy.rect.x + 0.03, y: copy.rect.y + 0.03, w: copy.rect.w, h: copy.rect.h))
        var result = elements
        result.insert(copy, at: index + 1)
        return result
    }

    /// 足す要素の既定の矩形（舞台の縦横比 aspect = 幅/高さ）。中央に置く。
    static func defaultRect(_ kind: ETVisualizerElementKind, aspect: Double) -> ETVisualizerRect {
        let aspect = aspect.isFinite && aspect > 0 ? aspect : 1
        let size: (w: Double, h: Double)
        switch kind {
        case .spectrum, .spectrogram, .waveform, .oscilloscope: size = (0.6, 0.3)
        case .stereo, .artwork:
            // 点で正方形になるよう、幅と高さを縦横比で割り振る。
            let s = 0.4 * min(1, 1 / aspect)
            size = (s, s * aspect)
        case .levelMeter: size = (0.6, 0.05)
        case .analogMeter: size = (0.5, 0.3)
        case .title: size = (0.6, 0.06)
        case .artist: size = (0.6, 0.04)
        case .jsfx: size = (0.6, 0.4)
        }
        return clamp(ETVisualizerRect(x: (1 - size.w) / 2, y: (1 - size.h) / 2, w: size.w, h: size.h))
    }

    /// 足せるか。並び 1 つあたり 24 まで、JSFX は 2 まで。
    static func canAdd(_ kind: ETVisualizerElementKind, to elements: [ETVisualizerElement]) -> Bool {
        guard elements.count < ETVisualizerScene.maxElements else { return false }
        if kind == .jsfx { return elements.filter { $0.kind == .jsfx }.count < ETVisualizerScene.maxJSFX }
        return true
    }

    /// 新しい要素の既定の中身。
    static func newElement(_ kind: ETVisualizerElementKind, id: UUID, aspect: Double,
                           jsfx: ETVisualizerJSFXElement?) -> ETVisualizerElement {
        ETVisualizerElement(
            id: id, kind: kind, rect: defaultRect(kind, aspect: aspect), look: .effetune,
            color: ETVisualizerElement.defaultColor(kind: kind, look: .effetune),
            bold: kind == .title, jsfx: kind == .jsfx ? jsfx : nil)
    }

    // MARK: 画素

    /// 矩形の辺を画素に丸める。x0 = round(x·W)、x1 = round((x+w)·W)（y も）。返すのは (x, y, 幅, 高さ)。
    /// 隣り合う矩形は同じ辺を共有するので隙間も重なりも出ず、Classic の帯は昔の整数の矩形とぴったり同じになる。
    static func pixelEdges(_ r: ETVisualizerRect, width: Double, height: Double) -> (Int, Int, Int, Int) {
        let x0 = (r.x * width).rounded(), x1 = ((r.x + r.w) * width).rounded()
        let y0 = (r.y * height).rounded(), y1 = ((r.y + r.h) * height).rounded()
        return (Int(x0), Int(y0), Int(x1 - x0), Int(y1 - y0))
    }
}

/// 取り消しの記録。全体の写しを積む。同じ coalesce の鍵が 1 秒以内に続いたら積み直さない
/// （つまみを回し続けても 1 回で戻る）。新しい記録でやり直しは消える。
struct ETVisualizerHistory<Value: Equatable> {
    private let limit: Int
    private var undoStack: [Value] = []
    private var redoStack: [Value] = []
    private var lastKey: String?
    private var lastTime = -Double.infinity

    init(limit: Int) { self.limit = max(1, limit) }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// 変える前の値を記録する。
    mutating func record(_ before: Value, coalesce: String?, now: Double) {
        redoStack.removeAll()
        defer {
            lastKey = coalesce
            lastTime = now
        }
        if let coalesce, coalesce == lastKey, now - lastTime <= 1 { return }
        if coalesce == lastKey, undoStack.last == before { return }
        undoStack.append(before)
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
    }

    mutating func undo(current: Value) -> Value? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        lastKey = nil
        return previous
    }

    mutating func redo(current: Value) -> Value? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        lastKey = nil
        return next
    }
}
