//  PEQBlendTests.swift
//  音量に追従する PEQ の鳴らし方（DSP/PEQBlend.swift）。15Band と 5Band で同じ試験をする。
//
//  見ているもの:
//    - 帯の並びと、素通し・利得を持たない種別の判定
//    - 区間の2組（A の全帯を (1−t) 倍・B の全帯を t 倍）と、周波数・Q・種別を補間しないこと
//    - 区間をまたぐときの2台への割り当て（B を持っている台はそのまま、素通しの台だけ C へ）
//    - 相方を持つ条件
//    - 種別・入切の切り替えの段取り（素通しの帯でだけ切り替える）

import XCTest

final class PEQBlendTests: XCTestCase {

    // MARK: - 道具

    private let types = ["FifteenBandPEQPlugin", "FiveBandPEQPlugin"]

    private func spec(_ type: String) throws -> ETEffect {
        try XCTUnwrap(ETCatalog.first { $0.type == type }, "カタログに無い: \(type)")
    }

    private func layout(_ type: String) throws -> (ETEffect, ETPEQBlend.Layout) {
        let s = try spec(type)
        return (s, try XCTUnwrap(ETPEQBlend.Layout(s), type))
    }

    /// 帯を書く。種別 0 pk / 1 lp / 2 hp / 3 ls / 4 hs / 5 bp / 6 no / 7 ap。
    private func put(_ v: inout [Float], _ l: ETPEQBlend.Layout, band: Int,
                     f: Float, g: Float, q: Float = 1, t: Float, e: Float = 1) {
        v[l.frequency + band] = f
        v[l.gain + band] = g
        v[l.q + band] = q
        v[l.type + band] = t
        v[l.enabled + band] = e
    }

    /// 帯 0 pk 6 dB、帯 1 hp、帯 2 ls -4 dB が入った値。ほかの帯は素通し。
    private func keyframeA(_ s: ETEffect, _ l: ETPEQBlend.Layout) -> [Float] {
        var v = s.defaults
        for i in 0..<l.bands { v[l.gain + i] = 0 }
        put(&v, l, band: 0, f: 1000, g: 6, q: 2, t: 0)
        put(&v, l, band: 1, f: 80, g: 3, q: 0.7, t: 2)
        put(&v, l, band: 2, f: 200, g: -4, q: 1, t: 3)
        return v
    }

    /// 帯 0 hs 8 dB、帯 1 lp、帯 2 pk 2 dB。
    private func keyframeB(_ s: ETEffect, _ l: ETPEQBlend.Layout) -> [Float] {
        var v = s.defaults
        for i in 0..<l.bands { v[l.gain + i] = 0 }
        put(&v, l, band: 0, f: 3000, g: 8, q: 1.5, t: 4)
        put(&v, l, band: 1, f: 9000, g: 5, q: 0.9, t: 1)
        put(&v, l, band: 2, f: 500, g: 2, q: 3, t: 0)
        return v
    }

    private func keyframeC(_ s: ETEffect, _ l: ETPEQBlend.Layout) -> [Float] {
        var v = s.defaults
        for i in 0..<l.bands { v[l.gain + i] = 0 }
        put(&v, l, band: 0, f: 400, g: -5, q: 1, t: 0)
        put(&v, l, band: 3, f: 6000, g: 0, q: 1, t: 5)
        return v
    }

    private func automation(_ s: ETEffect, _ list: [(Double, [Float])]) throws -> ETAutomation {
        try XCTUnwrap(ETAutomation(source: .outputVolume,
                                   keyframes: list.map { .init(position: $0.0, values: $0.1) },
                                   spec: s))
    }

    private func node(_ s: ETEffect, _ a: ETAutomation?, instance: UInt32 = 5) -> ETChainNode {
        var n = ETChainNode(spec: s, values: a?.topValues ?? s.defaults)
        n.automation = a
        n.instance = instance
        return n
    }

    // MARK: - 並びと判定

    func testLayout() throws {
        let l15 = try XCTUnwrap(ETPEQBlend.Layout(try spec(types[0])))
        XCTAssertEqual([l15.bands, l15.frequency, l15.gain, l15.q, l15.type, l15.enabled], [15, 0, 15, 30, 45, 60])
        let l5 = try XCTUnwrap(ETPEQBlend.Layout(try spec(types[1])))
        XCTAssertEqual([l5.bands, l5.frequency, l5.gain, l5.q, l5.type, l5.enabled], [5, 0, 5, 10, 15, 20])
        XCTAssertNil(ETPEQBlend.Layout(try spec("VolumePlugin")))
        XCTAssertNil(ETPEQBlend.Layout(try spec("FiveBandDynamicEQ")))
    }

    func testIdentityAndGainless() throws {
        for type in types {
            let (s, l) = try layout(type)
            var v = s.defaults
            for i in 0..<l.bands { v[l.gain + i] = 0 }
            put(&v, l, band: 0, f: 1000, g: 0.009, t: 0)       // 0.01 dB 未満
            put(&v, l, band: 1, f: 1000, g: 0.01, t: 0)        // ちょうど 0.01 は素通しでない
            put(&v, l, band: 2, f: 1000, g: -0.011, t: 3)
            put(&v, l, band: 3, f: 1000, g: 6, t: 0, e: 0)     // 切
            put(&v, l, band: 4, f: 1000, g: 0, t: 2)           // hp は利得を見ない
            XCTAssertTrue(ETPEQBlend.isIdentity(v, band: 0, l))
            XCTAssertFalse(ETPEQBlend.isIdentity(v, band: 1, l))
            XCTAssertFalse(ETPEQBlend.isIdentity(v, band: 2, l))
            XCTAssertTrue(ETPEQBlend.isIdentity(v, band: 3, l))
            XCTAssertFalse(ETPEQBlend.isIdentity(v, band: 4, l))
            XCTAssertTrue(ETPEQBlend.isIdentity(v, band: 99, l), "範囲の外は素通し扱い")

            for t in [0, 3, 4] as [Float] { XCTAssertFalse(ETPEQBlend.isGainless(t), "\(t)") }
            for t in [1, 2, 5, 6, 7] as [Float] { XCTAssertTrue(ETPEQBlend.isGainless(t), "\(t)") }
            XCTAssertFalse(ETPEQBlend.isGainless(.nan))
        }
    }

    // MARK: - 区間の2組

    func testPairBlendsGainsWithoutPairingBands() throws {
        for type in types {
            let (s, l) = try layout(type)
            let a = keyframeA(s, l), b = keyframeB(s, l)
            let k = try automation(s, [(50, a), (100, b)])

            for (x, wa, wb) in [(0.0, Float(1), Float(0)), (0.25, 0.75, 0.25),
                                (0.5, 0.5, 0.5), (1.0, 0, 1)] {
                let p = ETPEQBlend.pair(k, at: 50 + 50 * x, mainHeld: nil, companionHeld: nil)
                XCTAssertEqual(p.main.keyframe, 0, "x=\(x)")
                XCTAssertEqual(p.companion.keyframe, 1, "x=\(x)")
                let m = ETPEQBlend.values(p.main, in: k, layout: l)
                let c = ETPEQBlend.values(p.companion, in: k, layout: l)
                // 周波数・Q・種別は自分のキーフレームのまま（補間しない・入れ替えない）。
                for i in 0..<l.bands {
                    XCTAssertEqual(m[l.frequency + i], a[l.frequency + i])
                    XCTAssertEqual(m[l.q + i], a[l.q + i])
                    XCTAssertEqual(m[l.type + i], a[l.type + i])
                    XCTAssertEqual(c[l.frequency + i], b[l.frequency + i])
                    XCTAssertEqual(c[l.q + i], b[l.q + i])
                    XCTAssertEqual(c[l.type + i], b[l.type + i])
                }
                // 利得を持つ帯は倍率だけ。
                XCTAssertEqual(m[l.gain + 0], a[l.gain + 0] * wa, accuracy: 1e-6, "x=\(x)")
                XCTAssertEqual(m[l.gain + 2], a[l.gain + 2] * wa, accuracy: 1e-6)
                XCTAssertEqual(c[l.gain + 0], b[l.gain + 0] * wb, accuracy: 1e-6)
                XCTAssertEqual(c[l.gain + 2], b[l.gain + 2] * wb, accuracy: 1e-6)
                // 利得を持たない帯（A の hp・B の lp）は t が近い方だけ。
                XCTAssertEqual(m[l.enabled + 1], x < 0.5 ? 1 : 0, "A の hp x=\(x)")
                XCTAssertEqual(c[l.enabled + 1], x < 0.5 ? 0 : 1, "B の lp x=\(x)")
            }
        }
    }

    func testPairIsExactlyAAndBAtTheEnds() throws {
        for type in types {
            let (s, l) = try layout(type)
            let a = keyframeA(s, l), b = keyframeB(s, l)
            let k = try automation(s, [(50, a), (100, b)])

            let start = ETPEQBlend.pair(k, at: 50, mainHeld: nil, companionHeld: nil)
            XCTAssertEqual(ETPEQBlend.values(start.main, in: k, layout: l), a)
            XCTAssertEqual(ETPEQBlend.values(start.companion, in: k, layout: l),
                           ETPEQBlend.silenced(b, layout: l), "もう片方は全部素通し")

            let end = ETPEQBlend.pair(k, at: 100, mainHeld: nil, companionHeld: nil)
            XCTAssertEqual(ETPEQBlend.values(end.companion, in: k, layout: l), b)
            XCTAssertEqual(ETPEQBlend.values(end.main, in: k, layout: l),
                           ETPEQBlend.silenced(a, layout: l))

            // 端の外と、音量が読めていないとき: 一番上のキーフレームだけ。
            for pos in [nil, 100, 120, Double.nan] as [Double?] {
                let p = ETPEQBlend.pair(k, at: pos, mainHeld: nil, companionHeld: nil)
                let sounding = [p.main, p.companion].filter { $0.weight == 1 }
                XCTAssertEqual(sounding.count, 1)
                XCTAssertEqual(sounding[0].keyframe, 1)
                XCTAssertTrue(sounding[0].gainless)
                XCTAssertEqual(ETPEQBlend.values(sounding[0], in: k, layout: l), b)
            }
            for pos in [0.0, 30, 50] {
                let p = ETPEQBlend.pair(k, at: pos, mainHeld: nil, companionHeld: nil)
                XCTAssertEqual([p.main, p.companion].filter { $0.weight == 1 }.map(\.keyframe), [0])
            }
        }
    }

    func testSilencedIsIdentityEverywhere() throws {
        for type in types {
            let (s, l) = try layout(type)
            let v = ETPEQBlend.silenced(keyframeA(s, l), layout: l)
            for i in 0..<l.bands { XCTAssertTrue(ETPEQBlend.isIdentity(v, band: i, l), "band \(i)") }
            XCTAssertEqual(v[l.frequency + 0], 1000, "周波数・種別は残す")
            XCTAssertEqual(v[l.type + 2], 3)
        }
    }

    // MARK: - 区間をまたぐ

    func testCrossingSegmentsKeepsTheInstanceHoldingB() throws {
        for type in types {
            let (s, l) = try layout(type)
            let a = keyframeA(s, l), b = keyframeB(s, l), c = keyframeC(s, l)
            let k = try automation(s, [(50, a), (75, b), (100, c)])

            // (A,B) の区間: main=A・companion=B。
            let first = ETPEQBlend.pair(k, at: 60, mainHeld: nil, companionHeld: nil)
            XCTAssertEqual([first.main.keyframe, first.companion.keyframe], [0, 1])

            // (B,C) の区間へ移る: B を持っている companion はそのまま、A を持っていた main が C へ。
            let moved = ETPEQBlend.pair(k, at: 85, mainHeld: 50, companionHeld: 75)
            XCTAssertEqual([moved.main.keyframe, moved.companion.keyframe], [2, 1])
            XCTAssertEqual(moved.companion.weight, 1 - moved.main.weight, accuracy: 1e-6)

            // 逆（main が B を持っている）なら main はそのまま。
            let swapped = ETPEQBlend.pair(k, at: 85, mainHeld: 75, companionHeld: 50)
            XCTAssertEqual([swapped.main.keyframe, swapped.companion.keyframe], [1, 2])

            // もう片方が何も持っていなくても B の台は動かさない。
            XCTAssertEqual(ETPEQBlend.pair(k, at: 85, mainHeld: nil, companionHeld: 75).companion.keyframe, 1)
            XCTAssertEqual(ETPEQBlend.pair(k, at: 85, mainHeld: 75, companionHeld: nil).main.keyframe, 1)

            // 付け替わる側（A を持っていた台）は、B の位置（t=1）で全部素通しだった。
            let atB = ETPEQBlend.pair(k, at: 74.999, mainHeld: nil, companionHeld: nil)
            let silentVoice = ETPEQBlend.Voice(keyframe: 0, weight: 0, gainless: false)
            let silent = ETPEQBlend.values(silentVoice, in: k, layout: l)
            for i in 0..<l.bands { XCTAssertTrue(ETPEQBlend.isIdentity(silent, band: i, l), "band \(i)") }
            XCTAssertEqual(atB.main.keyframe, 0)
            XCTAssertEqual(atB.main.weight, 0, accuracy: 1e-3)

            // 位置が B ちょうど: B が lower で重み 1、upper(C) は 0。
            let on = ETPEQBlend.pair(k, at: 75, mainHeld: 50, companionHeld: 75)
            XCTAssertEqual([on.main.keyframe, on.companion.keyframe], [2, 1])
            XCTAssertEqual(on.companion.weight, 1)
            XCTAssertEqual(on.main.weight, 0)
        }
    }

    /// つまみで値を直している間も、同じキーフレームは同じ台に居続ける（位置で見る）。
    func testAssignmentSurvivesEditingTheHeldKeyframe() throws {
        let (s, l) = try layout(types[0])
        let a = keyframeA(s, l), c = keyframeC(s, l)
        var b = keyframeB(s, l)
        let before = try automation(s, [(50, a), (75, b), (100, c)])
        let p0 = ETPEQBlend.pair(before, at: 85, mainHeld: 50, companionHeld: 75)
        b[l.gain + 0] = 1.5
        let after = try automation(s, [(50, a), (75, b), (100, c)])
        let p1 = ETPEQBlend.pair(after, at: 85, mainHeld: 50, companionHeld: 75)
        XCTAssertEqual(p0, p1)
        XCTAssertEqual(p1.companion.keyframe, 1)
    }

    func testJumpAcrossSegmentsFallsBackToLowerOnMain() throws {
        let (s, l) = try layout(types[0])
        let a = keyframeA(s, l), b = keyframeB(s, l), c = keyframeC(s, l)
        var d = c
        put(&d, l, band: 0, f: 700, g: 3, t: 0)
        let k = try automation(s, [(40, a), (60, b), (80, c), (100, d)])
        // (A,B) を鳴らしていて、(C,D) へ飛ぶ。どの台も C・D を持っていない。
        let p = ETPEQBlend.pair(k, at: 90, mainHeld: 50, companionHeld: 75)
        XCTAssertEqual([p.main.keyframe, p.companion.keyframe], [2, 3])
    }

    // MARK: - 相方が無いとき

    func testSoloFadesThroughFlatAtTheMiddle() throws {
        for type in types {
            let (s, l) = try layout(type)
            let a = keyframeA(s, l), b = keyframeB(s, l)
            let k = try automation(s, [(50, a), (100, b)])

            let q = ETPEQBlend.solo(k, at: 62.5)
            XCTAssertEqual(q.keyframe, 0)
            XCTAssertEqual(q.weight, 0.5, accuracy: 1e-6)
            let v = ETPEQBlend.values(q, in: k, layout: l)
            XCTAssertEqual(v[l.gain + 0], 3, accuracy: 1e-5)
            XCTAssertEqual(v[l.enabled + 1], 1, "利得を持たない帯は自分のキーフレームのまま")

            let mid = ETPEQBlend.solo(k, at: 75)
            XCTAssertEqual(mid.keyframe, 1)
            XCTAssertEqual(mid.weight, 0, accuracy: 1e-6)
            let flat = ETPEQBlend.values(mid, in: k, layout: l)
            XCTAssertEqual(flat[l.gain + 0], 0, accuracy: 1e-6)

            let late = ETPEQBlend.solo(k, at: 87.5)
            XCTAssertEqual(late.keyframe, 1)
            XCTAssertEqual(late.weight, 0.5, accuracy: 1e-6)

            XCTAssertEqual(ETPEQBlend.values(ETPEQBlend.solo(k, at: 50), in: k, layout: l), a)
            XCTAssertEqual(ETPEQBlend.values(ETPEQBlend.solo(k, at: 100), in: k, layout: l), b)
            XCTAssertEqual(ETPEQBlend.values(ETPEQBlend.solo(k, at: nil), in: k, layout: l), b)
            XCTAssertEqual(ETPEQBlend.values(ETPEQBlend.solo(k, at: 10), in: k, layout: l), a)

            // キーフレーム1つ: そのまま。
            let one = try automation(s, [(70, a)])
            XCTAssertEqual(ETPEQBlend.values(ETPEQBlend.solo(one, at: 30), in: one, layout: l), a)
        }
    }

    func testWantsCompanion() throws {
        for type in types {
            let (s, l) = try layout(type)
            let two = try automation(s, [(50, keyframeA(s, l)), (100, keyframeB(s, l))])
            let one = try automation(s, [(50, keyframeA(s, l))])
            XCTAssertTrue(ETPEQBlend.wantsCompanion(node(s, two)))
            XCTAssertFalse(ETPEQBlend.wantsCompanion(node(s, one)), "キーフレーム1つ")
            XCTAssertFalse(ETPEQBlend.wantsCompanion(node(s, nil)), "追従していない")
            XCTAssertFalse(ETPEQBlend.wantsCompanion(node(s, two, instance: 0)), "instance が無い")
            var split = node(s, two)
            split.inputBus = 1; split.outputBus = 2
            XCTAssertFalse(ETPEQBlend.wantsCompanion(split), "バスを分けた段")
            var same = node(s, two)
            same.inputBus = 2; same.outputBus = 2
            XCTAssertTrue(ETPEQBlend.wantsCompanion(same))
        }
        let volume = try spec("VolumePlugin")
        let va = try automation(volume, [(50, volume.defaults), (100, volume.defaults)])
        XCTAssertFalse(ETPEQBlend.wantsCompanion(node(volume, va)), "PEQ でない")
        var external = node(try spec(types[0]), nil)
        external.externalID = "au:x"
        XCTAssertFalse(ETPEQBlend.wantsCompanion(external))
    }

    // MARK: - 切り替えの段取り

    func testStepsWithoutTopologyChangeIsOneStep() throws {
        for type in types {
            let (s, l) = try layout(type)
            let a = keyframeA(s, l)
            var b = a
            b[l.gain + 0] = 3
            b[l.frequency + 2] = 250
            XCTAssertEqual(ETPEQBlend.steps(from: a, to: b, layout: l), [b])
            XCTAssertEqual(ETPEQBlend.steps(from: a, to: a, layout: l), [])
            XCTAssertEqual(ETPEQBlend.steps(from: nil, to: b, layout: l), [b])
            XCTAssertEqual(ETPEQBlend.steps(from: [1, 2], to: b, layout: l), [b], "長さが違う")
            XCTAssertFalse(ETPEQBlend.changesTopology(from: a, to: b, layout: l))
            XCTAssertFalse(ETPEQBlend.changesTopology(from: nil, to: b, layout: l))
        }
    }

    func testStepsGoThroughIdentityWhenTypeChanges() throws {
        for type in types {
            let (s, l) = try layout(type)
            var from = s.defaults, to = s.defaults
            for i in 0..<l.bands { from[l.gain + i] = 0; to[l.gain + i] = 0 }
            put(&from, l, band: 0, f: 1000, g: 6, q: 1, t: 0)      // pk 6 dB
            put(&to, l, band: 0, f: 2000, g: 4, q: 2, t: 3)        // ls 4 dB

            let plan = ETPEQBlend.steps(from: from, to: to, layout: l)
            XCTAssertEqual(plan.count, 3)
            // s1: pk のまま利得だけ 0 へ（切り替えは無い）。
            XCTAssertEqual(plan[0][l.type], 0)
            XCTAssertEqual(plan[0][l.gain], 0)
            XCTAssertEqual(plan[0][l.frequency], 1000)
            XCTAssertFalse(ETPEQBlend.changesTopology(from: from, to: plan[0], layout: l))
            // s2: ls に切り替え、利得は 0（切り替えが起きるのはここだけ）。
            XCTAssertEqual(plan[1][l.type], 3)
            XCTAssertEqual(plan[1][l.gain], 0)
            XCTAssertEqual(plan[1][l.frequency], 2000)
            XCTAssertTrue(ETPEQBlend.changesTopology(from: plan[0], to: plan[1], layout: l))
            XCTAssertTrue(ETPEQBlend.isIdentity(plan[0], band: 0, l))
            // s3: 目標。利得を戻すだけ。
            XCTAssertEqual(plan[2], to)
            XCTAssertFalse(ETPEQBlend.changesTopology(from: plan[1], to: plan[2], layout: l))
        }
    }

    func testStepsSkipStepsThatChangeNothing() throws {
        for type in types {
            let (s, l) = try layout(type)
            func bands(_ f: (inout [Float]) -> Void) -> [Float] {
                var v = s.defaults
                for i in 0..<l.bands { v[l.gain + i] = 0 }
                f(&v)
                return v
            }
            // pk 0 → ls 4: 利得が元から 0 なので s1 は要らない。
            let from0 = bands { put(&$0, l, band: 1, f: 1000, g: 0, t: 0) }
            let to4 = bands { put(&$0, l, band: 1, f: 1000, g: 4, t: 3) }
            let p1 = ETPEQBlend.steps(from: from0, to: to4, layout: l)
            XCTAssertEqual(p1.count, 2)
            XCTAssertEqual(p1[0][l.type + 1], 3)
            XCTAssertEqual(p1[0][l.gain + 1], 0)
            XCTAssertEqual(p1[1], to4)

            // pk 6 → 切（利得 0）: [pk 0, 切]。
            let from6 = bands { put(&$0, l, band: 1, f: 1000, g: 6, t: 0) }
            let off = bands { put(&$0, l, band: 1, f: 1000, g: 0, t: 0, e: 0) }
            let p2 = ETPEQBlend.steps(from: from6, to: off, layout: l)
            XCTAssertEqual(p2.count, 2)
            XCTAssertEqual(p2[0][l.enabled + 1], 1)
            XCTAssertEqual(p2[0][l.gain + 1], 0)
            XCTAssertEqual(p2[1], off)

            // hp → pk 3: hp は利得で素通しにできない。s1 は何も変えない（省く）。
            let hp = bands { put(&$0, l, band: 1, f: 1000, g: 0, t: 2) }
            let pk3 = bands { put(&$0, l, band: 1, f: 1000, g: 3, t: 0) }
            let p3 = ETPEQBlend.steps(from: hp, to: pk3, layout: l)
            XCTAssertEqual(p3.count, 2)
            XCTAssertEqual(p3[0][l.type + 1], 0)
            XCTAssertEqual(p3[0][l.gain + 1], 0)
            XCTAssertEqual(p3[1], pk3)

            // pk → hp: s1 で利得 0、s2 で hp（利得を持たない目標はそのまま入る）。
            let hpTo = bands { put(&$0, l, band: 1, f: 2000, g: 0, t: 2) }
            let p4 = ETPEQBlend.steps(from: from6, to: hpTo, layout: l)
            XCTAssertEqual(p4.last, hpTo)
            XCTAssertEqual(p4[0][l.gain + 1], 0)
        }
    }

    func testStepsKeepUnchangedBandsAtTheirTargetFromTheFirstStep() throws {
        for type in types {
            let (s, l) = try layout(type)
            var from = s.defaults, to = s.defaults
            for i in 0..<l.bands { from[l.gain + i] = 0; to[l.gain + i] = 0 }
            put(&from, l, band: 0, f: 1000, g: 6, t: 0)
            put(&to, l, band: 0, f: 1000, g: 6, t: 3)              // 種別が変わる帯
            put(&from, l, band: 1, f: 300, g: 2, t: 0)
            put(&to, l, band: 1, f: 400, g: 5, t: 0)               // 変わらない帯（連続の変化）
            let plan = ETPEQBlend.steps(from: from, to: to, layout: l)
            XCTAssertEqual(plan.count, 3)
            for step in plan {
                XCTAssertEqual(step[l.frequency + 1], 400)
                XCTAssertEqual(step[l.gain + 1], 5)
            }
            // 切り替えが起きるのは s2 だけ。
            XCTAssertFalse(ETPEQBlend.changesTopology(from: from, to: plan[0], layout: l))
            XCTAssertTrue(ETPEQBlend.changesTopology(from: plan[0], to: plan[1], layout: l))
            XCTAssertFalse(ETPEQBlend.changesTopology(from: plan[1], to: plan[2], layout: l))
        }
    }
}
