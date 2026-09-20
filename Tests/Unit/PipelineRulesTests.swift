//  PipelineRulesTests.swift
//  鎖の意味と正規形を、並びだけで確かめる。
//
//  ここで試すのは **Node を知らない純粋関数だけ**（ETPipelineAnalysis と
//  ETRootResetRule）。模型（EffeTuneDSP）は AVFoundation と SwiftUI を連れてくるので
//  実機なしでは動かせない。判断をあちらから出してあるのはそのため。
//
//  記法（設計の議論と揃えてある）:
//
//      X, Y, Z   段
//      A+        Section("A", 入)
//      A-        Section("A", 切)
//      O+        名前の無い普通の Section（入）
//      O-        同（切）
//      R         rootReset
//
//  **O+ と R を取り違えないことが、この一式のいちばんの目的。**
//  渡す形ではどちらも `Section(cm: "")` になるが、こちらの中では別物で、
//  R だけが掃除の対象になる。

import XCTest

// MARK: - 並びを組み立てる

/// 試すための 1 段。`ETPipelineAnalysis` が要るのは役目・身元・入切だけ。
private struct Item {
    let id = UUID()
    let role: ETItemRole
    let name: String
    let enabled: Bool
    /// 見出し（失敗したときにどの段かが分かるように）。
    let label: String
}

private func effect(_ label: String) -> Item {
    Item(role: .effect, name: "", enabled: true, label: label)
}
private func section(_ label: String, _ name: String, on: Bool = true) -> Item {
    Item(role: .section, name: name, enabled: on, label: label)
}
private func reset() -> Item {
    Item(role: .rootReset, name: "", enabled: true, label: "R")
}

private extension Array where Element == Item {
    var roles: [ETItemRole] { map(\.role) }
    var ids: [UUID] { map(\.id) }
    var flags: [Bool] { map(\.enabled) }
    var analysis: ETPipelineAnalysis {
        ETPipelineAnalysis.analyze(roles: roles, ids: ids, enabled: flags)
    }
    /// 正規形へ落とした並び。
    var normalized: [Item] {
        let keep = ETRootResetRule.keep(roles: roles)
        return indices.filter { keep[$0] }.map { self[$0] }
    }
    /// 見た目の記号。失敗したときに読めるように。
    var shape: String {
        map { item in
            switch item.role {
            case .effect:    return item.label
            case .rootReset: return "R"
            case .section:
                let body = item.name.isEmpty ? "O" : item.name
                return body + (item.enabled ? "+" : "-")
            }
        }.joined(separator: " ")
    }
}

// MARK: - 1. 不変条件

/// 設計で決めた「正しい形」。**すべての変形のあとでこれを通す。**
private func assertCanonical(_ items: [Item],
                             _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
    let roles = items.roles

    // 頭に印は来ない（まだ root に居る）。
    if roles.first == .rootReset {
        XCTFail("頭に R が居る: \(items.shape) \(message)", file: file, line: line)
    }
    // 末尾に印は来ない（戻した先に何も無い）。
    if roles.last == .rootReset {
        XCTFail("末尾に R が居る: \(items.shape) \(message)", file: file, line: line)
    }
    // 印は並ばない。
    for i in roles.indices.dropLast() where roles[i] == .rootReset && roles[i + 1] == .rootReset {
        XCTFail("R が並んでいる: \(items.shape) \(message)", file: file, line: line)
    }
    // 印の後ろ、次の Section より前に段が在る。
    for i in roles.indices where roles[i] == .rootReset {
        var found = false
        var j = i + 1
        while j < roles.count, roles[j] != .section {
            if roles[j] == .effect { found = true; break }
            j += 1
        }
        if !found {
            XCTFail("R の後ろに段が無い: \(items.shape) \(message)", file: file, line: line)
        }
    }
    // 身元が重なっていない。
    XCTAssertEqual(Set(items.ids).count, items.count,
                   "身元が重なっている: \(items.shape) \(message)", file: file, line: line)
    // もう一度通しても変わらない。
    XCTAssertEqual(items.normalized.shape, items.shape,
                   "正規形ではない: \(items.shape) \(message)", file: file, line: line)
}

// MARK: - 2. 所属と gate

final class PipelineAnalysisTests: XCTestCase {

    /// A01〜A12。**O+ / O- と R を取り違えない**ことをここで直に押さえる。
    func testOwnerAndGate() {
        let cases: [(name: String, items: [Item], owner: [String?], gate: [UInt8])] = [
            ("A01 X Y",            [effect("X"), effect("Y")],                                   [nil, nil],    [1, 1]),
            ("A02 A+ X Y",         [section("A", "A"), effect("X"), effect("Y")],                ["A", "A"],    [1, 1]),
            ("A03 A- X Y",         [section("A", "A", on: false), effect("X"), effect("Y")],     ["A", "A"],    [0, 0]),
            ("A04 A+ X B- Y",      [section("A", "A"), effect("X"),
                                    section("B", "B", on: false), effect("Y")],                  ["A", "B"],    [1, 0]),
            ("A05 A+ X R Y",       [section("A", "A"), effect("X"), reset(), effect("Y")],       ["A", nil],    [1, 1]),
            ("A06 A- X R Y",       [section("A", "A", on: false), effect("X"),
                                    reset(), effect("Y")],                                        ["A", nil],    [0, 1]),
            ("A07 A- X R Y B- Z",  [section("A", "A", on: false), effect("X"), reset(),
                                    effect("Y"), section("B", "B", on: false), effect("Z")],     ["A", nil, "B"], [0, 1, 0]),
            ("A08 O+ X",           [section("O", ""), effect("X")],                              ["O"],         [1]),
            ("A09 O- X",           [section("O", "", on: false), effect("X")],                   ["O"],         [0]),
            ("A10 A+ R X",         [section("A", "A"), reset(), effect("X")],                    [nil],         [1]),
            ("A11 A- R X",         [section("A", "A", on: false), reset(), effect("X")],         [nil],         [1]),
            ("A12 A+ R X B+ Y",    [section("A", "A"), reset(), effect("X"),
                                    section("B", "B"), effect("Y")],                             [nil, "B"],    [1, 1]),
        ]

        for c in cases {
            let a = c.items.analysis
            let effects = c.items.filter { $0.role == .effect }
            XCTAssertEqual(effects.count, c.owner.count, "\(c.name) の数が合わない")

            for (i, e) in effects.enumerated() {
                let owner = a.owner(of: e.id)
                let expected = c.owner[i].flatMap { label in
                    c.items.first { $0.role == .section && $0.label == label }?.id
                }
                XCTAssertEqual(owner, expected,
                               "\(c.name): \(e.label) の持ち主。並びは \(c.items.shape)")
                XCTAssertEqual(a.gate(of: e.id), c.gate[i],
                               "\(c.name): \(e.label) の gate。並びは \(c.items.shape)")
            }
        }
    }

    /// **切ってある名前無し Section は配下を止める。**R と同じに扱うと音が変わる。
    func testDisabledUnnamedSectionStillGates() {
        let items = [section("O", "", on: false), effect("X")]
        XCTAssertEqual(items.analysis.gate(of: items[1].id), 0)

        // 同じ形を R にすると止まらない。**この差が O と R を分ける理由。**
        let asReset = [reset(), effect("X")]
        XCTAssertEqual(asReset.analysis.gate(of: asReset[1].id), 1)
    }

    /// 配下は Analysis だけが知っている（画面は range を数えない）。
    func testMembers() {
        let a = section("A", "A"), x = effect("X"), y = effect("Y")
        let items = [a, x, reset(), y]
        XCTAssertEqual(items.analysis.members(of: a.id), [x.id])
    }
}

// MARK: - 3. 正規形

final class RootResetNormalizeTests: XCTestCase {

    /// N01〜N12。
    func testNormalizeTable() {
        let cases: [(name: String, before: [Item], after: String)] = [
            ("N01 R X",          [reset(), effect("X")],                                    "X"),
            ("N02 A+ X R",       [section("A", "A"), effect("X"), reset()],                 "A+ X"),
            ("N03 A+ R X",       [section("A", "A"), reset(), effect("X")],                 "A+ R X"),
            ("N04 A+ X R Y",     [section("A", "A"), effect("X"), reset(), effect("Y")],    "A+ X R Y"),
            ("N05 A+ X R R Y",   [section("A", "A"), effect("X"), reset(), reset(), effect("Y")],
                                                                                            "A+ X R Y"),
            ("N06 A+ X R B+ Y",  [section("A", "A"), effect("X"), reset(),
                                  section("B", "B"), effect("Y")],                          "A+ X B+ Y"),
            ("N07 A+ R B+ X",    [section("A", "A"), reset(), section("B", "B"), effect("X")],
                                                                                            "A+ B+ X"),
            ("N08 A+ R X B+ Y",  [section("A", "A"), reset(), effect("X"),
                                  section("B", "B"), effect("Y")],                          "A+ R X B+ Y"),
            ("N09 A+ R X Y",     [section("A", "A"), reset(), effect("X"), effect("Y")],    "A+ R X Y"),
            ("N10 O+ R X",       [section("O", ""), reset(), effect("X")],                  "O+ R X"),
            ("N11 O- R X",       [section("O", "", on: false), reset(), effect("X")],       "O- R X"),
            ("N12 A+ R R R X",   [section("A", "A"), reset(), reset(), reset(), effect("X")],
                                                                                            "A+ R X"),
        ]

        for c in cases {
            XCTAssertEqual(c.before.normalized.shape, c.after, c.name)
            assertCanonical(c.before.normalized, c.name)
        }
    }

    /// **`A+ R X` を `A+ X` に戻してはいけない。**A が空でも印は要る。
    /// 消すと X が A のものになり、あとで A を切ったときに X まで止まる。
    func testEmptySectionKeepsItsReset() {
        let items = [section("A", "A"), reset(), effect("X")]
        XCTAssertEqual(items.normalized.shape, "A+ R X")

        // 意味が変わっていないことも直に見る。
        let before = items.analysis
        let after = items.normalized.analysis
        XCTAssertNil(before.owner(of: items[2].id))
        XCTAssertNil(after.owner(of: items[2].id))
    }

    /// 2 度掛けても変わらない。
    func testIdempotent() {
        for items in Self.everyShape(upTo: 5) {
            let once = items.normalized
            let twice = once.normalized
            XCTAssertEqual(twice.shape, once.shape, "2 度目で変わった: \(items.shape)")
        }
    }

    /// **段と普通の Section は触らない。**落としてよいのは R だけ。
    func testOnlyResetsAreRemoved() {
        for items in Self.everyShape(upTo: 5) {
            let kept = items.normalized
            let before = items.filter { $0.role != .rootReset }.map(\.id)
            let after = kept.filter { $0.role != .rootReset }.map(\.id)
            XCTAssertEqual(before, after, "R 以外が動いた: \(items.shape) → \(kept.shape)")
        }
    }

    /// 意味（段ごとの持ち主と gate）が変わらない。
    func testSemanticsPreserved() {
        for items in Self.everyShape(upTo: 5) {
            let before = items.analysis
            let after = items.normalized.analysis
            for e in items where e.role == .effect {
                XCTAssertEqual(before.owner(of: e.id), after.owner(of: e.id),
                               "持ち主が変わった: \(items.shape)")
                XCTAssertEqual(before.gate(of: e.id), after.gate(of: e.id),
                               "gate が変わった: \(items.shape)")
            }
        }
    }

    /// 長さ n までの並びを全部作る。**数が少ないので総当たりできる。**
    fileprivate static func everyShape(upTo n: Int) -> [[Item]] {
        var out: [[Item]] = []
        func build(_ current: [Item]) {
            if !current.isEmpty { out.append(current) }
            guard current.count < n else { return }
            build(current + [effect("X\(current.count)")])
            build(current + [section("S\(current.count)", "S\(current.count)")])
            build(current + [section("O\(current.count)", "")])
            build(current + [section("D\(current.count)", "", on: false)])
            build(current + [reset()])
        }
        build([])
        return out
    }
}

// MARK: - 4. 組から出す

final class LeaveSectionTests: XCTestCase {

    /// 並びと位置を渡して、印を挿した後の形を返す。nil なら何も起きない。
    private func leave(_ items: [Item], _ label: String) -> [Item]? {
        guard let at = items.firstIndex(where: { $0.label == label }) else { return nil }
        guard let insert = ETRootResetRule.insertion(roles: items.roles,
                                                     enabled: items.flags, at: at) else { return nil }
        var out = items
        out.insert(reset(), at: insert)
        return out
    }

    /// L01 組にただ 1 つの段を外へ。
    func testL01() {
        let items = [section("A", "A"), effect("X")]
        let after = leave(items, "X")
        XCTAssertEqual(after?.shape, "A+ R X")
        assertCanonical(after ?? [])
        XCTAssertNil(after?.analysis.owner(of: items[1].id))
    }

    /// L02 組の最後の段を外へ。
    func testL02() {
        let items = [section("A", "A"), effect("X"), effect("Y")]
        XCTAssertEqual(leave(items, "Y")?.shape, "A+ X R Y")
    }

    /// L03 **途中の段を外すと、後ろも一緒に出る。**
    /// 上流の形には組の終わりが無いので、これは避けられない。仕様として固定する。
    func testL03() {
        let items = [section("A", "A"), effect("X"), effect("Y")]
        let after = leave(items, "X")
        XCTAssertEqual(after?.shape, "A+ R X Y")
        let a = after!.analysis
        XCTAssertNil(a.owner(of: items[1].id))
        XCTAssertNil(a.owner(of: items[2].id), "Y も root へ出る（形式の制約）")
    }

    /// L04 もう外に居るなら何もしない。
    func testL04() {
        XCTAssertNil(leave([section("A", "A"), reset(), effect("X")], "X"))
    }

    /// L05 root の段は何もしない。
    func testL05() {
        XCTAssertNil(leave([effect("X")], "X"))
    }

    /// L06 切ってある組から出すと、**音が戻る**。
    func testL06() {
        let items = [section("A", "A", on: false), effect("X")]
        let after = leave(items, "X")
        XCTAssertEqual(after?.shape, "A- R X")
        XCTAssertEqual(after?.analysis.gate(of: items[1].id), 1)
    }

    /// L07 **何度繰り返しても増えない。**今回の不具合そのもの。
    func testL07_noGrowth() {
        var items = [section("A", "A"), effect("X")]
        for step in 1...1000 {
            if let next = leave(items, "X") { items = next.normalized }
            XCTAssertEqual(items.shape, "A+ R X", "\(step) 回目で形が変わった")
            assertCanonical(items, "\(step) 回目")
        }
        XCTAssertEqual(items.filter { $0.role == .rootReset }.count, 1)
    }

    /// 印そのものや Section を「外へ出す」ことはできない。
    func testOnlyEffectsLeave() {
        let items = [section("A", "A"), effect("X"), reset(), effect("Y")]
        XCTAssertNil(ETRootResetRule.insertion(roles: items.roles, enabled: items.flags, at: 0))
        XCTAssertNil(ETRootResetRule.insertion(roles: items.roles, enabled: items.flags, at: 2))
    }
}

// MARK: - 8. 上流との突き合わせ

/// **上流そのままの走り方**（dsp-pipeline-descriptor.js:190-212）。
/// こちらの Analyzer を使い回さない。使い回すと同じ間違いを 2 回して一致してしまう。
private func referenceGates(section: [Bool?], enabled: [Bool]) -> [UInt8] {
    var out: [UInt8] = []
    var insideSection = false
    var sectionEnabled = true
    for i in section.indices {
        if let isOn = section[i] {          // Section（R も渡す形では Section）
            insideSection = true
            sectionEnabled = isOn
            continue
        }
        out.append(!insideSection || sectionEnabled ? 1 : 0)
    }
    return out
}

final class WireCodecTests: XCTestCase {

    /// W01/W02 **R も名前無し Section も、渡す形では同じ**になる。
    /// W03/W04 戻すときに R とは推測しない（模型の側の約束。ここでは形だけ見る）。
    func testBothBecomeEmptySection() {
        // 渡す形へ落としたときの「Section か・入っているか」。
        func wire(_ items: [Item]) -> [Bool?] {
            items.map { item in
                switch item.role {
                case .effect:    return nil
                case .section:   return item.enabled
                case .rootReset: return true      // Section(cm: "", enabled: true)
                }
            }
        }
        XCTAssertEqual(wire([reset()]), [true])
        XCTAssertEqual(wire([section("O", "")]), [true])
    }

    /// **音の意味が上流と一致する。**総当たりで確かめる。
    func testGatesMatchUpstream() {
        for items in RootResetNormalizeTests.everyShape(upTo: 6) {
            let mine = items.analysis
            let wire: [Bool?] = items.map { item in
                switch item.role {
                case .effect:    return nil
                case .section:   return item.enabled
                case .rootReset: return true
                }
            }
            let theirs = referenceGates(section: wire, enabled: items.flags)
            let effects = items.filter { $0.role == .effect }
            XCTAssertEqual(effects.count, theirs.count)
            for (i, e) in effects.enumerated() {
                XCTAssertEqual(mine.gate(of: e.id), theirs[i],
                               "上流と違う: \(items.shape) の \(e.label)")
            }
        }
    }
}

// MARK: - 12/13. 乱数と繰り返し

final class PipelineFuzzTests: XCTestCase {

    /// 決まった目を出す乱数。**失敗したら同じ種で再現できる。**
    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }

    /// 操作をでたらめに積んで、毎回 assertCanonical を通す。
    func testRandomMutations() {
        for seed in 1...60 {
            var rng = Seeded(state: UInt64(seed) &* 0x9E3779B97F4A7C15 | 1)
            var items: [Item] = [effect("X0")]
            var serial = 1

            for step in 1...300 {
                switch Int.random(in: 0..<6, using: &rng) {
                case 0:
                    items.insert(effect("X\(serial)"),
                                 at: Int.random(in: 0...items.count, using: &rng))
                    serial += 1
                case 1:
                    let on = Bool.random(using: &rng)
                    let named = Bool.random(using: &rng)
                    items.insert(section("S\(serial)", named ? "S\(serial)" : "", on: on),
                                 at: Int.random(in: 0...items.count, using: &rng))
                    serial += 1
                case 2:
                    guard !items.isEmpty else { break }
                    items.remove(at: Int.random(in: 0..<items.count, using: &rng))
                case 3:
                    guard items.count >= 2 else { break }
                    let from = Int.random(in: 0..<items.count, using: &rng)
                    let to = Int.random(in: 0..<items.count, using: &rng)
                    let moved = items.remove(at: from)
                    items.insert(moved, at: to)
                case 4:
                    guard !items.isEmpty else { break }
                    let at = Int.random(in: 0..<items.count, using: &rng)
                    if let insert = ETRootResetRule.insertion(roles: items.roles,
                                                              enabled: items.flags, at: at) {
                        items.insert(reset(), at: insert)
                    }
                default:
                    break
                }
                items = items.normalized
                assertCanonical(items, "seed=\(seed) step=\(step)")
            }
        }
    }

    /// 出して戻してを繰り返しても、印が積み上がらない。
    func testLeaveAndReturnTorture() {
        let a = section("A", "A")
        let x = effect("X"), y = effect("Y"), z = effect("Z")
        var items = [a, x, y, z]

        for round in 1...300 {
            for target in ["Z", "Y", "X"] {
                // 外へ。
                if let at = items.firstIndex(where: { $0.label == target }),
                   let insert = ETRootResetRule.insertion(roles: items.roles,
                                                          enabled: items.flags, at: at) {
                    items.insert(reset(), at: insert)
                    items = items.normalized
                }
                assertCanonical(items, "round=\(round) 外へ \(target)")
                XCTAssertLessThanOrEqual(items.filter { $0.role == .rootReset }.count, 1,
                                         "印が積み上がった: \(items.shape)")
                // 戻す（印を外す）。
                items = items.filter { $0.role != .rootReset }.normalized
                assertCanonical(items, "round=\(round) 戻す \(target)")
            }
            XCTAssertEqual(items.shape, "A+ X Y Z", "round=\(round) で元に戻らない")
        }
    }
}
