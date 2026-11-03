//  UndoTests.swift
//  鎖の取り消しの控え（ETUndo.swift）。
//
//  模型（EffeTuneDSP）は入らないので、控えの比べ方と、戻すときの段取りだけを試す。

import XCTest

final class UndoTests: XCTestCase {

    private func node(_ type: String) throws -> ETChainNode {
        let spec = try XCTUnwrap(ETCatalog.first { $0.type == type }, "カタログに無い: \(type)")
        return ETChainNode(spec: spec, values: spec.defaults)
    }

    private func types() -> [String] {
        Array(ETCatalog.filter { $0.floatCount > 0 }.prefix(3).map(\.type))
    }

    func testSameChainIsSameContent() throws {
        let a = try node(types()[0])
        XCTAssertTrue(ETUndoSnapshot(nodes: [a]).sameContent(as: ETUndoSnapshot(nodes: [a])))
    }

    /// つまみ 1 つ動かしたら 1 手。
    func testValueChangeIsDifferent() throws {
        let a = try node(types()[0])
        var b = a
        b.values[0] += 1
        XCTAssertFalse(ETUndoSnapshot(nodes: [a]).sameContent(as: ETUndoSnapshot(nodes: [b])))
    }

    /// その場で振る番号や、host から読み直す state では手を増やさない。
    func testRuntimeFieldsAreIgnored() throws {
        let a = try node(types()[0])
        var b = a
        b.instance = 42
        b.tapId = 7
        b.sectionGate = 0
        b.resetCount = 3
        b.externalState = Data([1, 2, 3])
        XCTAssertTrue(ETUndo.sameContent(a, b))
    }

    /// 開閉は手に数えない。
    func testExpansionIsIgnored() throws {
        let a = try node(types()[0])
        let open = ETUndoSnapshot(nodes: [a], expanded: [a.id])
        let closed = ETUndoSnapshot(nodes: [a], expanded: [])
        XCTAssertTrue(open.sameContent(as: closed))
    }

    /// 消したのを戻す: 残っている段は使い回し、消した段だけ作り直す。
    func testPlanRecreatesRemovedNode() throws {
        let t = types()
        let a = try node(t[0]), b = try node(t[1]), c = try node(t[2])
        let plan = ETUndo.plan(current: [a, c], target: [a, b, c])
        XCTAssertEqual(plan, ETUndo.Plan(kept: [a.id, c.id], created: [b.id], dropped: []))
    }

    /// 足したのを戻す: 足した段だけ外す。
    func testPlanDropsAddedNode() throws {
        let t = types()
        let a = try node(t[0]), b = try node(t[1])
        let plan = ETUndo.plan(current: [a, b], target: [a])
        XCTAssertEqual(plan, ETUndo.Plan(kept: [a.id], created: [], dropped: [b.id]))
    }

    /// 動かしたのを戻す: 作り直さず、並びだけ控えの順にする。
    func testPlanKeepsMovedNodes() throws {
        let t = types()
        let a = try node(t[0]), b = try node(t[1])
        let plan = ETUndo.plan(current: [b, a], target: [a, b])
        XCTAssertEqual(plan, ETUndo.Plan(kept: [a.id, b.id], created: [], dropped: []))
    }

    /// 同じ id で型が違えば、別の型の instance へ値を流さず作り直す。
    func testPlanRecreatesWhenTypeDiffers() throws {
        let t = types()
        let a = try node(t[0])
        var other = try node(t[1])
        other.id = a.id
        let plan = ETUndo.plan(current: [a], target: [other])
        XCTAssertEqual(plan, ETUndo.Plan(kept: [], created: [a.id], dropped: [a.id]))
    }

    /// 値を写しても、段の番号は残す。
    func testAdoptKeepsInstance() throws {
        var now = try node(types()[0])
        now.instance = 9
        now.tapId = 4
        var saved = now
        saved.values[0] += 1
        saved.enabled = false
        saved.sectionName = "x"
        saved.instance = 0
        ETUndo.adopt(saved, into: &now)
        XCTAssertEqual(now.values, saved.values)
        XCTAssertFalse(now.enabled)
        XCTAssertEqual(now.sectionName, "x")
        XCTAssertEqual(now.instance, 9)
        XCTAssertEqual(now.tapId, 4)
    }
}
