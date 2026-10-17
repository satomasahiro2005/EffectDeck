//  VisualizerSceneEditingTests.swift
//  Visualizer の編集の規則（VisualizerSceneEditing）。当たり判定・合わせる・大きさ・重なりの順・複製・取り消し。
//
//  壊れると: 重なった要素の後ろを選べない、端や中央に吸い付かない（吸い付きすぎる）、反対の角が動く、
//  最小の大きさを割る、要素が舞台の外へ出る、取り消しが 1 回で戻らない・多すぎる。

import XCTest

final class VisualizerSceneEditingTests: XCTestCase {

    private typealias R = ETVisualizerRect
    private typealias E = ETVisualizerEditing

    private func element(_ kind: ETVisualizerElementKind = .spectrum, _ r: R) -> ETVisualizerElement {
        ETVisualizerElement(id: UUID(), kind: kind, rect: r, color: ETVisualizerElement.defaultColor(kind: kind, look: .effetune))
    }

    private func assertRect(_ a: R, _ b: R, accuracy: Double = 1e-9, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, "x", line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, "y", line: line)
        XCTAssertEqual(a.w, b.w, accuracy: accuracy, "w", line: line)
        XCTAssertEqual(a.h, b.h, accuracy: accuracy, "h", line: line)
    }

    private let none = ETVisualizerEditing.Snap(xs: [], ys: [])

    // MARK: 当たり判定

    func testHitsAreFrontMostFirst() {
        let back = element(.spectrum, R(x: 0, y: 0, w: 0.6, h: 0.6))
        let middle = element(.waveform, R(x: 0.2, y: 0.2, w: 0.6, h: 0.6))
        let front = element(.stereo, R(x: 0.5, y: 0.5, w: 0.4, h: 0.4))
        let all = [back, middle, front]
        XCTAssertEqual(E.hits(at: (0.55, 0.55), in: all), [front.id, middle.id, back.id])
        XCTAssertEqual(E.hits(at: (0.3, 0.3), in: all), [middle.id, back.id])
        XCTAssertEqual(E.hits(at: (0.05, 0.05), in: all), [back.id])
        XCTAssertEqual(E.hits(at: (0.99, 0.01), in: all), [])
        // 端も当たる。
        XCTAssertEqual(E.hits(at: (0.6, 0.6), in: [back]), [back.id])
    }

    func testNextSelectionCyclesBehind() {
        let a = UUID(), b = UUID(), c = UUID()
        XCTAssertNil(E.nextSelection(hits: [], current: a))
        XCTAssertEqual(E.nextSelection(hits: [a, b, c], current: nil), a)
        XCTAssertEqual(E.nextSelection(hits: [a, b, c], current: UUID()), a)
        XCTAssertEqual(E.nextSelection(hits: [a, b, c], current: a), b)
        XCTAssertEqual(E.nextSelection(hits: [a, b, c], current: b), c)
        XCTAssertEqual(E.nextSelection(hits: [a, b, c], current: c), a)
        XCTAssertEqual(E.nextSelection(hits: [a], current: a), a)
    }

    // MARK: 合わせる

    func testSnapTargets() {
        let a = element(.spectrum, R(x: 0.1, y: 0.2, w: 0.3, h: 0.4))
        let b = element(.waveform, R(x: 0.5, y: 0.5, w: 0.2, h: 0.2))
        let snap = E.snapTargets(excluding: a.id, in: [a, b], safe: nil)
        XCTAssertEqual(snap.xs.count, 6)
        XCTAssertEqual(snap.ys.count, 6)
        for (value, expected) in zip(snap.xs, [0, 0.5, 1, 0.5, 0.6, 0.7]) { XCTAssertEqual(value, expected, accuracy: 1e-12) }
        for (value, expected) in zip(snap.ys, [0, 0.5, 1, 0.5, 0.6, 0.7]) { XCTAssertEqual(value, expected, accuracy: 1e-12) }
        let withSafe = E.snapTargets(excluding: a.id, in: [a, b], safe: (l: 0.05, t: 0.02, r: 0.05, b: 0.03))
        XCTAssertEqual(withSafe.xs.count, 8)
        XCTAssertEqual(withSafe.xs[6], 0.05, accuracy: 1e-12)
        XCTAssertEqual(withSafe.xs[7], 0.95, accuracy: 1e-12)
        XCTAssertEqual(withSafe.ys[6], 0.02, accuracy: 1e-12)
        XCTAssertEqual(withSafe.ys[7], 0.97, accuracy: 1e-12)
    }

    func testMoveSnapsToEdgeWithinThresholdOnly() {
        let r = R(x: 0.3, y: 0.3, w: 0.2, h: 0.2)
        let snap = ETVisualizerEditing.Snap(xs: [0, 0.5, 1], ys: [0, 0.5, 1])
        // 左辺が 0 から 0.01 以内。
        let near = E.move(r, dx: -0.295, dy: 0, snap: snap, thresholdX: 0.02, thresholdY: 0.02)
        XCTAssertEqual(near.rect.x, 0, accuracy: 1e-12)
        XCTAssertEqual(near.guidesX, [0])
        // 閾値の外では動かした量のまま。
        let far = E.move(r, dx: -0.2, dy: 0, snap: snap, thresholdX: 0.02, thresholdY: 0.02)
        XCTAssertEqual(far.rect.x, 0.1, accuracy: 1e-12)
        XCTAssertEqual(far.guidesX, [])
    }

    func testMoveSnapsCenterAndAxesAreIndependent() {
        let r = R(x: 0.3, y: 0.1, w: 0.2, h: 0.2)
        let snap = ETVisualizerEditing.Snap(xs: [0.5], ys: [0.9])
        // 中央（x）に合う。y は遠い。
        let result = E.move(r, dx: 0.105, dy: 0.01, snap: snap, thresholdX: 0.02, thresholdY: 0.02)
        XCTAssertEqual(result.rect.x + result.rect.w / 2, 0.5, accuracy: 1e-12)
        XCTAssertEqual(result.guidesX, [0.5])
        XCTAssertEqual(result.rect.y, 0.11, accuracy: 1e-12)
        XCTAssertEqual(result.guidesY, [])
    }

    func testMoveSnapsToAnotherElementsEdge() {
        let other = element(.waveform, R(x: 0.6, y: 0.1, w: 0.3, h: 0.3))
        let mover = element(.spectrum, R(x: 0.1, y: 0.5, w: 0.25, h: 0.2))
        let snap = E.snapTargets(excluding: mover.id, in: [other, mover], safe: nil)
        // 右辺が 0.6（other の左辺）の近くへ。中央（0.5）は閾値の外。
        let result = E.move(mover.rect, dx: 0.248, dy: 0, snap: snap, thresholdX: 0.02, thresholdY: 0.02)
        XCTAssertEqual(result.rect.x + result.rect.w, 0.6, accuracy: 1e-12)
        XCTAssertEqual(result.guidesX, [0.6])
    }

    func testMoveTieGoesToTheEarlierTarget() {
        // 左辺（0.5）から両側の先が同じ距離。先の早いほうを選ぶ。
        let r = R(x: 0.5, y: 0.2, w: 0, h: 0.2)
        let snap = ETVisualizerEditing.Snap(xs: [0.25, 0.75], ys: [])
        let result = E.move(r, dx: 0, dy: 0, snap: snap, thresholdX: 0.3, thresholdY: 0)
        XCTAssertEqual(result.rect.x, 0.25, accuracy: 1e-12)
        XCTAssertEqual(result.guidesX, [0.25])
    }

    func testMoveClampsAndDropsGuidesThatNoLongerMatch() {
        let r = R(x: 0.5, y: 0.5, w: 0.5, h: 0.2)
        // 右へ大きく動かすと枠の端で止まり、合わせた先（0.7）は外れる。
        let snap = ETVisualizerEditing.Snap(xs: [1.05], ys: [])
        let result = E.move(r, dx: 0.3, dy: 0, snap: snap, thresholdX: 0.1, thresholdY: 0.1)
        XCTAssertEqual(result.rect.x + result.rect.w, 1, accuracy: 1e-12)
        XCTAssertEqual(result.guidesX, [])
        // 動かさず端に合うなら案内線は残る。
        let edge = E.move(R(x: 0.4, y: 0.5, w: 0.5, h: 0.2), dx: 0.095, dy: 0,
                          snap: ETVisualizerEditing.Snap(xs: [1], ys: []), thresholdX: 0.02, thresholdY: 0.02)
        XCTAssertEqual(edge.rect.x + edge.rect.w, 1, accuracy: 1e-12)
        XCTAssertEqual(edge.guidesX, [1])
    }

    // MARK: 大きさ

    func testResizeKeepsTheOppositeCornerFixed() {
        let r = R(x: 0.2, y: 0.3, w: 0.4, h: 0.2)
        let tl = E.resize(r, corner: .topLeft, to: (0.1, 0.2), snap: none, thresholdX: 0, thresholdY: 0)
        assertRect(tl.rect, R(x: 0.1, y: 0.2, w: 0.5, h: 0.3))
        let tr = E.resize(r, corner: .topRight, to: (0.8, 0.1), snap: none, thresholdX: 0, thresholdY: 0)
        assertRect(tr.rect, R(x: 0.2, y: 0.1, w: 0.6, h: 0.4))
        let bl = E.resize(r, corner: .bottomLeft, to: (0.25, 0.9), snap: none, thresholdX: 0, thresholdY: 0)
        assertRect(bl.rect, R(x: 0.25, y: 0.3, w: 0.35, h: 0.6))
        let br = E.resize(r, corner: .bottomRight, to: (0.7, 0.6), snap: none, thresholdX: 0, thresholdY: 0)
        assertRect(br.rect, R(x: 0.2, y: 0.3, w: 0.5, h: 0.3))
    }

    func testResizeHasAMinimumSizeAndStaysInsideTheStage() {
        let r = R(x: 0.2, y: 0.3, w: 0.4, h: 0.2)
        // 反対の角を越えて引いても 0.02 で止まり、反転しない。
        let crossed = E.resize(r, corner: .topLeft, to: (0.9, 0.9), snap: none, thresholdX: 0, thresholdY: 0)
        assertRect(crossed.rect, R(x: 0.58, y: 0.48, w: 0.02, h: 0.02))
        let crossedBR = E.resize(r, corner: .bottomRight, to: (0, 0), snap: none, thresholdX: 0, thresholdY: 0)
        assertRect(crossedBR.rect, R(x: 0.2, y: 0.3, w: 0.02, h: 0.02))
        // 枠の外へ引いても枠の中。
        let outside = E.resize(r, corner: .bottomRight, to: (3, 3), snap: none, thresholdX: 0, thresholdY: 0)
        assertRect(outside.rect, R(x: 0.2, y: 0.3, w: 0.8, h: 0.7))
        let outsideTL = E.resize(r, corner: .topLeft, to: (-3, -3), snap: none, thresholdX: 0, thresholdY: 0)
        assertRect(outsideTL.rect, R(x: 0, y: 0, w: 0.6, h: 0.5))
    }

    func testResizeSnapsOnlyTheMovingEdges() {
        let r = R(x: 0.2, y: 0.3, w: 0.4, h: 0.2)
        let snap = ETVisualizerEditing.Snap(xs: [0.2, 0.7], ys: [0.5])
        // 動く辺は右と下。左の 0.2 には反応しない。
        let result = E.resize(r, corner: .bottomRight, to: (0.69, 0.51), snap: snap, thresholdX: 0.02, thresholdY: 0.02)
        assertRect(result.rect, R(x: 0.2, y: 0.3, w: 0.5, h: 0.2))
        XCTAssertEqual(result.guidesX, [0.7])
        XCTAssertEqual(result.guidesY, [0.5])
    }

    func testScaleKeepsTheCenterAndClamps() {
        let r = R(x: 0.3, y: 0.3, w: 0.4, h: 0.2)
        assertRect(E.scale(r, by: 1.5), R(x: 0.2, y: 0.25, w: 0.6, h: 0.3))
        assertRect(E.scale(r, by: 0.5), R(x: 0.4, y: 0.35, w: 0.2, h: 0.1))
        // 最小: 小さいほうの辺が 0.02 になるところまで。縦横比は保つ。
        let small = E.scale(r, by: 0.001)
        XCTAssertEqual(small.h, 0.02, accuracy: 1e-12)
        XCTAssertEqual(small.w, 0.04, accuracy: 1e-12)
        XCTAssertEqual(small.x + small.w / 2, 0.5, accuracy: 1e-12)
        // 最大: 大きいほうの辺が 1 まで。
        let big = E.scale(r, by: 100)
        XCTAssertEqual(big.w, 1, accuracy: 1e-12)
        XCTAssertEqual(big.h, 0.5, accuracy: 1e-12)
        // 枠の端に寄った要素は、中心を保てなければ枠の中へ寄せる。
        let corner = E.scale(R(x: 0.7, y: 0.7, w: 0.3, h: 0.3), by: 2)
        XCTAssertEqual(corner.x + corner.w, 1, accuracy: 1e-12)
        XCTAssertEqual(corner.y + corner.h, 1, accuracy: 1e-12)
        XCTAssertEqual(corner.w, 0.6, accuracy: 1e-12)
        XCTAssertEqual(E.scale(r, by: .nan), r)
    }

    // MARK: 重なりの順

    func testArrange() {
        let a = element(.spectrum, R(x: 0, y: 0, w: 0.1, h: 0.1))
        let b = element(.waveform, R(x: 0, y: 0, w: 0.1, h: 0.1))
        let c = element(.stereo, R(x: 0, y: 0, w: 0.1, h: 0.1))
        let list = [a, b, c]
        func ids(_ x: [ETVisualizerElement]) -> [UUID] { x.map(\.id) }
        XCTAssertEqual(ids(E.arrange(list, a.id, .front)), [b.id, c.id, a.id])
        XCTAssertEqual(ids(E.arrange(list, a.id, .forward)), [b.id, a.id, c.id])
        XCTAssertEqual(ids(E.arrange(list, c.id, .back)), [c.id, a.id, b.id])
        XCTAssertEqual(ids(E.arrange(list, c.id, .backward)), [a.id, c.id, b.id])
        XCTAssertEqual(ids(E.arrange(list, b.id, .front)), [a.id, c.id, b.id])
        XCTAssertEqual(ids(E.arrange(list, b.id, .back)), [b.id, a.id, c.id])
    }

    func testArrangeNoOpsAtTheEnds() {
        let a = element(.spectrum, R(x: 0, y: 0, w: 0.1, h: 0.1))
        let b = element(.waveform, R(x: 0, y: 0, w: 0.1, h: 0.1))
        let list = [a, b]
        XCTAssertFalse(E.canArrange(list, b.id, .front))
        XCTAssertFalse(E.canArrange(list, b.id, .forward))
        XCTAssertTrue(E.canArrange(list, b.id, .backward))
        XCTAssertTrue(E.canArrange(list, b.id, .back))
        XCTAssertFalse(E.canArrange(list, a.id, .back))
        XCTAssertFalse(E.canArrange(list, a.id, .backward))
        XCTAssertTrue(E.canArrange(list, a.id, .front))
        XCTAssertFalse(E.canArrange(list, UUID(), .front))
        XCTAssertEqual(E.arrange(list, b.id, .front), list)
        XCTAssertEqual(E.arrange(list, a.id, .back), list)
        XCTAssertEqual(E.arrange(list, UUID(), .front), list)
    }

    // MARK: 複製・足す

    func testDuplicate() {
        let a = element(.spectrum, R(x: 0.1, y: 0.1, w: 0.2, h: 0.2))
        let b = element(.waveform, R(x: 0.8, y: 0.8, w: 0.2, h: 0.2))
        let c = element(.stereo, R(x: 0, y: 0, w: 0.1, h: 0.1))
        let newID = UUID()
        let result = E.duplicate([a, b, c], a.id, newID: newID)
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result[0].id, a.id)
        XCTAssertEqual(result[1].id, newID)
        XCTAssertEqual(result[2].id, b.id)
        assertRect(result[1].rect, R(x: 0.13, y: 0.13, w: 0.2, h: 0.2))
        XCTAssertEqual(result[1].kind, .spectrum)
        // 枠の端のものは枠の中へ収める。
        let edge = E.duplicate([b], b.id, newID: UUID())
        assertRect(edge[1].rect, R(x: 0.8, y: 0.8, w: 0.2, h: 0.2))
        XCTAssertEqual(E.duplicate([a], UUID(), newID: UUID()), [a])
    }

    func testDefaultRectSquareKindsAreSquareInPoints() {
        for aspect in [852.0 / 393, 393.0 / 852, 1] {
            for kind in [ETVisualizerElementKind.stereo, .artwork, .ncs] {
                let r = E.defaultRect(kind, aspect: aspect)
                // 点にすると、幅 = r.w × aspect、高さ = r.h（高さを 1 として）。
                XCTAssertEqual(r.w * aspect, r.h, accuracy: 1e-9, "\(kind) \(aspect)")
                XCTAssertEqual(r.x + r.w / 2, 0.5, accuracy: 1e-9)
                XCTAssertEqual(r.y + r.h / 2, 0.5, accuracy: 1e-9)
            }
        }
    }

    func testDefaultRectSizes() {
        let sizes: [(ETVisualizerElementKind, Double, Double)] = [
            (.spectrum, 0.6, 0.3), (.spectrogram, 0.6, 0.3), (.waveform, 0.6, 0.3), (.oscilloscope, 0.6, 0.3),
            (.levelMeter, 0.6, 0.05), (.analogMeter, 0.5, 0.3), (.title, 0.6, 0.06), (.artist, 0.6, 0.04),
            (.jsfx, 0.6, 0.4),
        ]
        for (kind, w, h) in sizes {
            let r = E.defaultRect(kind, aspect: 1.5)
            XCTAssertEqual(r.w, w, accuracy: 1e-12, kind.rawValue)
            XCTAssertEqual(r.h, h, accuracy: 1e-12, kind.rawValue)
            XCTAssertEqual(r.x, (1 - w) / 2, accuracy: 1e-12)
            XCTAssertEqual(r.y, (1 - h) / 2, accuracy: 1e-12)
        }
    }

    func testCanAddLimits() {
        let full = (0..<24).map { _ in element(.spectrum, R(x: 0, y: 0, w: 0.1, h: 0.1)) }
        XCTAssertFalse(E.canAdd(.spectrum, to: full))
        XCTAssertTrue(E.canAdd(.spectrum, to: Array(full.prefix(23))))
        var jsfx = element(.jsfx, R(x: 0, y: 0, w: 0.1, h: 0.1))
        jsfx.jsfx = ETVisualizerJSFXElement(entryID: "x", name: "x")
        XCTAssertTrue(E.canAdd(.jsfx, to: [jsfx]))
        XCTAssertFalse(E.canAdd(.jsfx, to: [jsfx, jsfx]))
        XCTAssertTrue(E.canAdd(.spectrum, to: [jsfx, jsfx]))
        let ncs = element(.ncs, R(x: 0, y: 0, w: 0.1, h: 0.1))
        XCTAssertTrue(E.canAdd(.ncs, to: [ncs]))
        XCTAssertFalse(E.canAdd(.ncs, to: [ncs, ncs]))
        XCTAssertTrue(E.canAdd(.spectrum, to: [ncs, ncs]))
    }

    func testNewElement() {
        let id = UUID()
        let title = E.newElement(.title, id: id, aspect: 1, jsfx: nil)
        XCTAssertEqual(title.id, id)
        XCTAssertTrue(title.bold)
        XCTAssertEqual(title.look, .effetune)
        XCTAssertEqual(title.color.rgb, 0xFFFFFF)
        XCTAssertNil(title.jsfx)
        let payload = ETVisualizerJSFXElement(entryID: "e", name: "n")
        let js = E.newElement(.jsfx, id: id, aspect: 1, jsfx: payload)
        XCTAssertEqual(js.jsfx, payload)
        XCTAssertFalse(js.bold)
        let meter = E.newElement(.spectrum, id: id, aspect: 1, jsfx: payload)
        XCTAssertNil(meter.jsfx)
        XCTAssertEqual(meter.color.rgb, 0x40DFFF)
    }

    func testPixelEdgesRoundTheEdgesNotTheSizes() {
        // 辺を丸めるので、幅は 2 つの辺の差になる（0.5 の端は上へ丸める）。
        let r = R(x: 0.25, y: 0, w: 0.5, h: 1)
        let e = E.pixelEdges(r, width: 101, height: 10)
        XCTAssertEqual([e.0, e.1, e.2, e.3], [25, 0, 51, 10])
    }

    // MARK: 取り消し

    func testHistoryUndoRedo() {
        var history = ETVisualizerHistory<Int>(limit: 50)
        XCTAssertFalse(history.canUndo)
        XCTAssertFalse(history.canRedo)
        XCTAssertNil(history.undo(current: 0))
        history.record(1, coalesce: nil, now: 0)
        history.record(2, coalesce: nil, now: 0)
        XCTAssertTrue(history.canUndo)
        XCTAssertEqual(history.undo(current: 3), 2)
        XCTAssertTrue(history.canRedo)
        XCTAssertEqual(history.undo(current: 2), 1)
        XCTAssertNil(history.undo(current: 1))
        XCTAssertEqual(history.redo(current: 1), 2)
        XCTAssertEqual(history.redo(current: 2), 3)
        XCTAssertNil(history.redo(current: 3))
    }

    func testHistoryNewRecordClearsRedo() {
        var history = ETVisualizerHistory<Int>(limit: 50)
        history.record(1, coalesce: nil, now: 0)
        XCTAssertEqual(history.undo(current: 2), 1)
        XCTAssertTrue(history.canRedo)
        history.record(1, coalesce: nil, now: 5)
        XCTAssertFalse(history.canRedo)
    }

    func testHistoryLimit() {
        var history = ETVisualizerHistory<Int>(limit: 50)
        for i in 0..<80 { history.record(i, coalesce: nil, now: Double(i)) }
        var steps = 0
        var current = 80
        while let previous = history.undo(current: current) {
            current = previous
            steps += 1
        }
        XCTAssertEqual(steps, 50)
        XCTAssertEqual(current, 30)
    }

    func testHistoryCoalescesWithinOneSecondOnTheSameKey() {
        var history = ETVisualizerHistory<Int>(limit: 50)
        history.record(0, coalesce: "opacity:a", now: 0)
        history.record(1, coalesce: "opacity:a", now: 0.5)
        history.record(2, coalesce: "opacity:a", now: 1.2)
        // 1 回の取り消しで最初の値へ戻る。
        XCTAssertEqual(history.undo(current: 3), 0)
        XCTAssertNil(history.undo(current: 0))
    }

    func testHistoryDoesNotCoalesceAcrossKeysOrAfterOneSecond() {
        var history = ETVisualizerHistory<Int>(limit: 50)
        history.record(0, coalesce: "opacity:a", now: 0)
        history.record(1, coalesce: "color:a", now: 0.1)
        history.record(2, coalesce: "color:a", now: 2.5)
        history.record(3, coalesce: nil, now: 2.6)
        history.record(4, coalesce: nil, now: 2.7)
        var seen: [Int] = []
        var current = 5
        while let previous = history.undo(current: current) {
            seen.append(previous)
            current = previous
        }
        XCTAssertEqual(seen, [4, 3, 2, 1, 0])
    }

    func testHistoryUndoThenRedoRestoresTheValue() {
        var history = ETVisualizerHistory<String>(limit: 5)
        history.record("a", coalesce: nil, now: 0)
        let back = history.undo(current: "b")
        XCTAssertEqual(back, "a")
        XCTAssertEqual(history.redo(current: back ?? ""), "b")
        XCTAssertTrue(history.canUndo)
    }

    func testHistoryDropsAnIdenticalRepeat() {
        var history = ETVisualizerHistory<Int>(limit: 50)
        history.record(1, coalesce: nil, now: 0)
        history.record(1, coalesce: nil, now: 0.1)
        XCTAssertEqual(history.undo(current: 2), 1)
        XCTAssertNil(history.undo(current: 1))
    }
}
