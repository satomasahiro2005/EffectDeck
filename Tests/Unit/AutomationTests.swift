//  AutomationTests.swift
//  音量に追従するカードのキーフレームと補間（DSP/Automation.swift）。
//
//  見ているもの:
//    - 補間の種類（Hz と Q は対数、dB は直線、選択肢と入切は真ん中で切り替え、遅延の設定は補間しない）
//    - PEQ の帯は補間せず、真ん中で近い方のキーフレームの値に切り替わる（音は ETPEQBlend）
//    - 時間軸の帯の道具（segment・nearestKeyframe・dragTarget）
//    - キーフレームの足し引きと既定の位置
//    - 保存形式の往復（ショート・ロング）と、読めないものの扱い
//    - 上流（EffeTune）・PC・エフェクトのプリセットへはキーフレームを出さず、EffectDeck のリンクには出す
//    - 貼られた字のキーフレームも範囲へ寄せる

import XCTest

final class AutomationTests: XCTestCase {

    // MARK: - 道具

    private func spec(_ type: String) throws -> ETEffect {
        try XCTUnwrap(ETCatalog.first { $0.type == type }, "カタログに無い: \(type)")
    }

    private let peq15 = "FifteenBandPEQPlugin"
    private let peq5 = "FiveBandPEQPlugin"
    private let volume = "VolumePlugin"

    /// 2つのキーフレーム（50% と 100%）から作る。
    private func automation(_ spec: ETEffect, _ a: [Float], _ b: [Float]) throws -> ETAutomation {
        try XCTUnwrap(ETAutomation(source: .outputVolume,
                                   keyframes: [.init(position: 50, values: a), .init(position: 100, values: b)],
                                   spec: spec))
    }

    private func vol(_ db: Float) throws -> [Float] {
        var v = try spec(volume).defaults
        v[0] = db
        return v
    }

    private func node(_ spec: ETEffect, _ a: ETAutomation? = nil) -> ETChainNode {
        var n = ETChainNode(spec: spec, values: a?.topValues ?? spec.defaults)
        n.automation = a
        return n
    }

    private func roundTrip(_ json: Any) throws -> Any {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        return try JSONSerialization.jsonObject(with: data)
    }

    // MARK: - 補間の種類

    func testBlendKinds() throws {
        let peq = try spec(peq15)
        func blend(_ key: String) throws -> ETAutomation.Blend {
            ETAutomation.blend(of: try XCTUnwrap(peq.params.first { $0.key == key }))
        }
        XCTAssertEqual(try blend("f"), .logarithmic)
        XCTAssertEqual(try blend("g"), .linear)
        XCTAssertEqual(try blend("q"), .logarithmic)
        XCTAssertEqual(try blend("t"), .step)
        XCTAssertEqual(try blend("e"), .step)

        func named(_ type: String, _ name: String) throws -> ETParam {
            try XCTUnwrap(try spec(type).params.first { $0.name == name })
        }
        // Tilt の Pivot は保存値が ln(Hz)。保存値の直線が Hz の対数になる。
        XCTAssertEqual(ETAutomation.blend(of: try named("TiltEQPlugin", "pivotExponent")), .linear)
        // 遅延を変える設定と、実行時の旗は補間しない。
        XCTAssertEqual(ETAutomation.blend(of: try named("BrickwallLimiterPlugin", "oversampling")), .hold)
        XCTAssertEqual(ETAutomation.blend(of: try named("BrickwallLimiterPlugin", "lookahead")), .hold)
        XCTAssertEqual(ETAutomation.blend(of: try named("AdaptivePredictionEffectPlugin", "resetToken")), .hold)
        // 下限が0の Hz も対数。両端が正でなければ mix が直線に落とす。
        let lfo = ETParam(name: "modulationRate", key: "mr", label: "Mod Rate",
                          kind: .number(min: 0, max: 10, step: 0.1, unit: "Hz", isInteger: false),
                          defaultValue: 1, offset: 0, count: 1)
        XCTAssertEqual(ETAutomation.blend(of: lfo), .logarithmic)
        // 選択肢は、名前が oversampling でなければ補間しない側ではなく切り替え。
        XCTAssertEqual(ETAutomation.blend(of: try named("TubeSimulatorPlugin", "outputStage")), .step)
    }

    func testIsAutomatable() throws {
        XCTAssertTrue(ETAutomation.isAutomatable(try spec(volume)))
        XCTAssertTrue(ETAutomation.isAutomatable(try spec(peq15)))
        XCTAssertTrue(ETAutomation.isAutomatable(try spec("FiveBandDynamicEQ")))
        XCTAssertFalse(ETAutomation.isAutomatable(try spec("IRReverbPlugin")))
        XCTAssertFalse(ETAutomation.isAutomatable(try spec("FiveBandFIRPEQPlugin")))
        XCTAssertFalse(ETAutomation.isAutomatable(try spec("LevelMeterPlugin")))
        XCTAssertFalse(ETAutomation.isAutomatable(ETSection.spec))

        XCTAssertTrue(ETAutomation.isAutomatable(node(try spec(volume))))
        var external = ETChainNode(spec: ETEffect.external(type: "External:au:x", name: "X", category: "Audio Units"),
                                   values: [])
        external.externalID = "au:x"
        XCTAssertFalse(ETAutomation.isAutomatable(external))
        var jsfx = ETChainNode(spec: ETEffect.external(type: "External:jsfx:y", name: "Y", category: "JSFX"),
                               values: [])
        jsfx.externalID = "jsfx:y"
        XCTAssertFalse(ETAutomation.isAutomatable(jsfx))
        XCTAssertFalse(ETAutomation.isAutomatable(ETChainNode(spec: ETSection.spec, values: [])))
    }

    // MARK: - 補間

    func testLinearInterpolationAndEnds() throws {
        let s = try spec(volume)
        let a = try automation(s, try vol(-10), try vol(0))
        func sound(_ p: Double?) -> Float { a.values(at: p, spec: s, current: s.defaults)[0] }
        XCTAssertEqual(sound(75), -5, accuracy: 1e-5)
        XCTAssertEqual(sound(60), -8, accuracy: 1e-5)
        XCTAssertEqual(sound(40), -10)         // 下の外は端のまま
        XCTAssertEqual(sound(50), -10)
        XCTAssertEqual(sound(100), 0)
        XCTAssertEqual(sound(100.0 + 1), 0)
        XCTAssertEqual(sound(nil), 0)          // 読めていなければ一番上
    }

    func testZeroMinimumHzBlendsLogarithmically() throws {
        let s = try spec("DattorroPlateReverbPlugin")
        let p = try XCTUnwrap(s.params.first { $0.name == "modulationRate" })
        guard case .number(let lo, _, _, _, _) = p.kind else { return XCTFail("数でない") }
        XCTAssertEqual(lo, 0)
        var a = s.defaults, b = s.defaults
        a[p.offset] = 0.5; b[p.offset] = 5
        let k = try automation(s, a, b)
        // 50% と 100% の真ん中は 0.5 Hz と 5 Hz の幾何平均。直線なら 2.75。
        XCTAssertEqual(k.values(at: 75, spec: s, current: s.defaults)[p.offset], Float(sqrt(2.5)), accuracy: 1e-3)
        // 片方が0なら直線。
        a[p.offset] = 0
        let z = try automation(s, a, b)
        XCTAssertEqual(z.values(at: 75, spec: s, current: s.defaults)[p.offset], 2.5, accuracy: 1e-5)
    }

    /// 刻みが粗い数（フィルタの傾きは12 dB/oct 刻み）は、どの位置でも刻みの上に乗る。
    /// 中間の値はカーネルが受けず、フィルタが切れる。
    func testSteppedNumbersStayOnGrid() throws {
        func check(_ type: String, _ key: String, _ from: Float, _ to: Float, step: Float) throws {
            let s = try spec(type)
            let p = try XCTUnwrap(s.params.first { $0.key == key }, "\(type).\(key)")
            var a = s.defaults, b = s.defaults
            a[p.offset] = from; b[p.offset] = to
            let k = try automation(s, a, b)
            for pos in stride(from: 50.0, through: 100.0, by: 5.0) {
                let v = k.values(at: pos, spec: s, current: s.defaults)[p.offset]
                XCTAssertEqual(v.truncatingRemainder(dividingBy: step), 0, "\(type).\(key) @\(pos) = \(v)")
                XCTAssertTrue((min(from, to)...max(from, to)).contains(v), "\(type).\(key) @\(pos) = \(v)")
            }
        }
        try check("HiPassFilterPlugin", "sl", -24, -48, step: 12)
        try check("LoPassFilterPlugin", "sl", -12, -96, step: 12)
        try check("BandPassFilterPlugin", "hs", -12, -48, step: 12)
        try check("BandPassFilterPlugin", "ls", -48, -24, step: 12)
        try check("ChannelDividerPlugin", "s1", -24, -96, step: 12)
        try check("ChannelDividerPlugin", "s3", -96, -12, step: 12)

        // 60% の傾きは -28.8 でなく -24 か -36（-29 でなく）。
        let s = try spec("HiPassFilterPlugin")
        var a = s.defaults, b = s.defaults
        a[1] = -24; b[1] = -48
        let v = try automation(s, a, b).values(at: 60, spec: s, current: s.defaults)[1]
        XCTAssertEqual(v, -24)
    }

    func testSingleKeyframeIsConstant() throws {
        let s = try spec(volume)
        let a = ETAutomation(source: .outputVolume, position: 50, values: try vol(-7))
        for p in [nil, 0, 50, 51, 100] as [Double?] {
            XCTAssertEqual(a.values(at: p, spec: s, current: s.defaults)[0], -7)
        }
    }

    // MARK: - PEQ の帯

    /// 15Band と 5Band で同じ試験をする。(周波数, 利得, Q, 種別, 入切) の位置と帯の数。
    private func layouts() throws -> [(ETEffect, Int, Int, Int, Int, Int)] {
        [(try spec(peq15), 0, 15, 30, 45, 60), (try spec(peq5), 0, 5, 10, 15, 20)]
    }

    /// 帯は補間しない。周波数・利得・Q・種別・入切は、真ん中で A から B へまとめて切り替わる。
    func testPEQValuesAreNearestKeyframe() throws {
        for (s, f, g, q, t, e) in try layouts() {
            var a = s.defaults, b = s.defaults
            a[f + 2] = 100; b[f + 2] = 1000
            a[g + 2] = 6; b[g + 2] = -4
            a[q + 2] = 0.5; b[q + 2] = 8
            a[t + 2] = 0; b[t + 2] = 3
            a[e + 1] = 0; b[e + 1] = 1
            let k = try automation(s, a, b)
            func at(_ x: Double) -> [Float] { k.values(at: 50 + 50 * x, spec: s, current: s.defaults) }

            XCTAssertEqual(at(0.25), a, "0.5 より前は A のまま")
            XCTAssertEqual(at(0.49), a)
            XCTAssertEqual(at(0.5), b, "0.5 からは B")
            XCTAssertEqual(at(0.75), b)
            XCTAssertEqual(k.values(at: 40, spec: s, current: s.defaults), a)
            XCTAssertEqual(k.values(at: nil, spec: s, current: s.defaults), b)
        }
    }

    // MARK: - 時間軸の帯

    func testSegmentAt() throws {
        let s = try spec(volume)
        var k = try automation(s, try vol(-10), try vol(0))
        k.add(at: 75)
        XCTAssertEqual(k.keyframes.map(\.position), [50, 75, 100])
        XCTAssertNil(k.segment(at: nil))
        XCTAssertNil(k.segment(at: .nan))
        XCTAssertNil(k.segment(at: 30), "下の外")
        XCTAssertNil(k.segment(at: 50), "端ちょうど")
        XCTAssertNil(k.segment(at: 100), "端ちょうど")
        XCTAssertNil(k.segment(at: 120))
        let low = try XCTUnwrap(k.segment(at: 60))
        XCTAssertEqual([low.lower, low.upper], [0, 1])
        XCTAssertEqual(low.t, 0.4, accuracy: 1e-9)
        let on = try XCTUnwrap(k.segment(at: 75), "真ん中のキーフレームの上は次の区間の頭")
        XCTAssertEqual([on.lower, on.upper], [1, 2])
        XCTAssertEqual(on.t, 0, accuracy: 1e-9)
        let high = try XCTUnwrap(k.segment(at: 90))
        XCTAssertEqual([high.lower, high.upper], [1, 2])
        XCTAssertEqual(high.t, 0.6, accuracy: 1e-9)
        // 1つだけ
        let single = ETAutomation(source: .outputVolume, position: 50, values: try vol(0))
        XCTAssertNil(single.segment(at: 50))
        XCTAssertNil(single.segment(at: 60))
    }

    func testNearestKeyframe() throws {
        let s = try spec(volume)
        var k = try automation(s, try vol(-10), try vol(0))
        k.add(at: 60)
        XCTAssertEqual(k.keyframes.map(\.position), [50, 60, 100])
        XCTAssertEqual(k.nearestKeyframe(to: 52, within: 5), 0)
        XCTAssertEqual(k.nearestKeyframe(to: 58, within: 5), 1)
        XCTAssertEqual(k.nearestKeyframe(to: 55, within: 5), 0, "同じ近さなら低い方")
        XCTAssertEqual(k.nearestKeyframe(to: 55, within: 4.999), nil, "許す幅の外")
        XCTAssertEqual(k.nearestKeyframe(to: 105, within: 5), 2, "ちょうど幅の端は入る")
        XCTAssertNil(k.nearestKeyframe(to: 80, within: 5))
        XCTAssertNil(k.nearestKeyframe(to: .nan, within: 5))
    }

    func testDragTarget() throws {
        let s = try spec(volume)
        var k = try automation(s, try vol(-10), try vol(0))
        k.add(at: 75)
        XCTAssertEqual(k.dragTarget(1, to: 62.4), 60, "刻みへ丸める")
        XCTAssertEqual(k.dragTarget(1, to: 63), 65)
        XCTAssertEqual(k.dragTarget(1, to: -30), 0, "範囲へ収める")
        XCTAssertNil(k.dragTarget(1, to: 400), "上限へ収まると別のキーフレームの位置")
        XCTAssertNil(k.dragTarget(1, to: 51), "ほかのキーフレームの位置は不可")
        XCTAssertNil(k.dragTarget(0, to: 100))
        XCTAssertEqual(k.dragTarget(1, to: 76), 75, "自分の位置は返す")
        XCTAssertNil(k.dragTarget(9, to: 10))
        XCTAssertNil(k.dragTarget(-1, to: 10))
        XCTAssertNil(k.dragTarget(0, to: .nan))
    }

    // MARK: - 補間しない設定

    func testHeldValuesComeFromCurrentAndAreSharedByStore() throws {
        let s = try spec("BrickwallLimiterPlugin")
        let os = try XCTUnwrap(s.params.first { $0.name == "oversampling" }).offset
        var a = s.defaults, b = s.defaults
        a[os] = 1; b[os] = 4
        var k = try automation(s, a, b)
        // store すると、書いたキーフレームの値が全キーフレームの held になる。
        XCTAssertEqual(k.keyframes[0].values[os], 4, "読み込みで一番上のキーフレームに揃う")
        var cur = k.keyframes[0].values
        cur[os] = 8
        k.store(cur, at: 0, spec: s)
        XCTAssertEqual(k.keyframes.map { $0.values[os] }, [8, 8])
        // 鳴らす値は current から。
        var current = s.defaults
        current[os] = 2
        XCTAssertEqual(k.values(at: 75, spec: s, current: current)[os], 2)
    }

    func testRuntimeOnlyIsHeld() throws {
        let s = try spec("AdaptivePredictionEffectPlugin")
        let token = try XCTUnwrap(s.params.first { $0.name == "resetToken" }).offset
        var a = s.defaults, b = s.defaults
        a[token] = 1; b[token] = 9
        let k = try automation(s, a, b)
        var current = s.defaults
        current[token] = 5
        XCTAssertEqual(k.values(at: 75, spec: s, current: current)[token], 5)
        XCTAssertEqual(k.values(at: 100, spec: s, current: current)[token], 5)
    }

    func testStoreIgnoresWrongLength() throws {
        let s = try spec(volume)
        var k = try automation(s, try vol(-10), try vol(0))
        k.store([1, 2, 3], at: 0, spec: s)
        XCTAssertEqual(k.keyframes[0].values, try vol(-10))
        k.store(try vol(-3), at: 5, spec: s)
        k.store(try vol(-3), at: -1, spec: s)
        XCTAssertEqual(k.keyframes.map(\.values), [try vol(-10), try vol(0)], "範囲の外の k は何もしない")
        k.store(try vol(-3), at: 0, spec: s)
        XCTAssertEqual(k.keyframes[0].values, try vol(-3))
        XCTAssertEqual(k.keyframes[1].values, try vol(0))
    }

    func testStoreAtNonTopSharesHeldIncludingTop() throws {
        let s = try spec("BrickwallLimiterPlugin")
        let os = try XCTUnwrap(s.params.first { $0.name == "oversampling" }).offset
        var k = try automation(s, s.defaults, s.defaults)
        var low = k.keyframes[0].values
        low[os] = 4
        k.store(low, at: 0, spec: s)
        XCTAssertEqual(k.keyframes.map { $0.values[os] }, [4, 4], "下のものを直しても一番上へ写る")
        XCTAssertEqual(k.topValues[os], 4)
    }

    // MARK: - キーフレームの足し引き

    func testAddCopiesNearestAndReturnsIndex() throws {
        let s = try spec(volume)
        var k = try automation(s, try vol(-10), try vol(0))
        XCTAssertEqual(k.add(at: 62), 1)           // 刻みで 60。50 の方が近い
        XCTAssertEqual(k.keyframes.map(\.position), [50, 60, 100])
        XCTAssertEqual(k.keyframes[1].values, try vol(-10))
        XCTAssertEqual(k.add(at: 90), 2)
        XCTAssertEqual(k.keyframes.map(\.position), [50, 60, 90, 100])
        XCTAssertEqual(k.keyframes[2].values, try vol(0))
        // 同じ近さなら位置の低い方（75 は 50 と 100 の真ん中）
        var m = try automation(s, try vol(-10), try vol(0))
        XCTAssertEqual(m.add(at: 75), 1)
        XCTAssertEqual(m.keyframes[1].values, try vol(-10))
        // あるものを足すと、その添字を返すだけ
        XCTAssertEqual(k.add(at: 50), 0)
        XCTAssertEqual(k.keyframes.count, 4)
        XCTAssertEqual(k.add(at: 101), 3, "範囲外は 100 に寄る")
        XCTAssertEqual(k.keyframes.count, 4)
        // いっぱいなら nil。ただし、あるものは添字を返す
        let v = try vol(-1)
        let many = (0..<100).map { ETAutomation.Keyframe(position: Double($0), values: v) }
        var full = try XCTUnwrap(ETAutomation(source: .outputVolume, keyframes: many, spec: s))
        XCTAssertEqual(full.keyframes.count, ETAutomation.maxKeyframes)
        XCTAssertNil(full.add(at: 100))
        XCTAssertEqual(full.keyframes.count, ETAutomation.maxKeyframes)
        XCTAssertEqual(full.add(at: 5), 5)
    }

    func testRemoveAt() throws {
        let s = try spec(volume)
        var k = try automation(s, try vol(-10), try vol(0))
        XCTAssertFalse(k.remove(at: 5))
        XCTAssertFalse(k.remove(at: -1))
        XCTAssertEqual(k.keyframes.count, 2)
        XCTAssertTrue(k.remove(at: 1))
        XCTAssertEqual(k.keyframes.count, 1)
        XCTAssertEqual(k.topValues, try vol(-10))
        XCTAssertFalse(k.remove(at: 0), "最後の1つは消さない")
        XCTAssertEqual(k.keyframes.count, 1)
    }

    func testMoveKeyframe() throws {
        let s = try spec(volume)
        var k = try automation(s, try vol(-10), try vol(0))
        k.add(at: 75)
        XCTAssertEqual(k.keyframes.map(\.position), [50, 75, 100])
        // 空きへ動かすと並べ直す。値は一緒に動く
        XCTAssertEqual(k.move(0, to: 90), 1)
        XCTAssertEqual(k.keyframes.map(\.position), [75, 90, 100])
        XCTAssertEqual(k.keyframes[1].values, try vol(-10))
        // 塞がっている所へは動かさない
        XCTAssertNil(k.move(1, to: 100))
        XCTAssertEqual(k.keyframes.map(\.position), [75, 90, 100])
        // 自分の位置は何もせず自分の添字
        XCTAssertEqual(k.move(1, to: 90), 1)
        XCTAssertEqual(k.move(1, to: 91), 1, "刻みへ丸めると自分の位置")
        // 範囲の外の k
        XCTAssertNil(k.move(9, to: 10))
        XCTAssertNil(k.move(-1, to: 10))
        XCTAssertEqual(k.keyframes.map(\.position), [75, 90, 100])
        // 刻みの外・範囲の外は丸めて収める
        XCTAssertEqual(k.move(2, to: -40), 0)
        XCTAssertEqual(k.keyframes.map(\.position), [0, 75, 90])
        XCTAssertEqual(k.move(0, to: 62), 0)
        XCTAssertEqual(k.keyframes.map(\.position), [60, 75, 90])
        XCTAssertEqual(k.move(0, to: 400), 2, "上限へ収まる")
        XCTAssertEqual(k.keyframes.map(\.position), [75, 90, 100])
        XCTAssertNil(k.move(0, to: .nan), "有限でない位置は上限へ寄るが、塞がっていれば動かさない")
        XCTAssertEqual(k.keyframes.map(\.position), [75, 90, 100])
    }

    func testAddChoices() throws {
        let none = ETAutomation.addChoices(nil, current: 63)
        XCTAssertEqual(none.free.count, 21)
        XCTAssertEqual(none.free.first, 0)
        XCTAssertEqual(none.free.last, 100)
        XCTAssertEqual(none.suggested, 65)
        XCTAssertEqual(ETAutomation.addChoices(nil, current: nil).suggested, 100)
        XCTAssertEqual(ETAutomation.addChoices(nil, current: 400).suggested, 100)

        let s = try spec(volume)
        let k = try automation(s, try vol(-10), try vol(0))
        let c = ETAutomation.addChoices(k, current: 52)
        XCTAssertEqual(c.free, k.freePositions())
        XCTAssertEqual(c.suggested, k.defaultAddPosition(current: 52))
        XCTAssertEqual(c.free.count, 19)
        XCTAssertEqual(c.suggested, 45, "50 は塞がっているので近い空き（同じ近さなら低い方）")
    }

    func testSlotAddressRoundTrip() throws {
        let all: [ETSlotAddress] = [.slot(0), .slot(7), .sounding(slot: 0), .sounding(slot: 3),
                                    .keyframe(slot: 0, index: 0), .keyframe(slot: 5, index: 63),
                                    .keyframe(slot: 0, index: 63), .keyframe(slot: 1, index: 0)]
        for a in all { XCTAssertEqual(ETSlotAddress(a.raw), a, "\(a)") }
        XCTAssertEqual(Set(all.map(\.raw)).count, all.count, "番号は重ならない")
        XCTAssertEqual(ETSlotAddress.slot(7).raw, 7)
        for raw in -5000...(-1) {
            if case .slot = ETSlotAddress(raw) { XCTFail("負の番号は slot でない: \(raw)") }
        }
        // 段ごとの組が重ならない
        var seen = Set<Int>()
        for slot in 0..<4 {
            XCTAssertTrue(seen.insert(ETSlotAddress.sounding(slot: slot).raw).inserted)
            for k in 0..<ETAutomation.maxKeyframes {
                XCTAssertTrue(seen.insert(ETSlotAddress.keyframe(slot: slot, index: k).raw).inserted)
            }
        }
        // 端でも落ちない
        if case .slot = ETSlotAddress(Int.min) { XCTFail("Int.min は slot でない") }
        if case .slot = ETSlotAddress(-1) { XCTFail("-1 は slot でない") }
        XCTAssertEqual(ETSlotAddress(Int.max), .slot(Int.max))
    }

    func testDefaultAddPositionAndFree() throws {
        let s = try spec(volume)
        var k = ETAutomation(source: .outputVolume, position: 100, values: try vol(0))
        XCTAssertEqual(k.defaultAddPosition(current: 63), 65)
        XCTAssertEqual(k.defaultAddPosition(current: nil), 95, "100 は塞がっているので近い空き")
        k.add(at: 65)
        XCTAssertEqual(k.defaultAddPosition(current: 63), 60, "同じ近さなら低い方")
        XCTAssertFalse(k.freePositions().contains(65))
        XCTAssertFalse(k.freePositions().contains(100))
        XCTAssertTrue(k.freePositions().contains(0))
        XCTAssertEqual(k.freePositions(), k.freePositions().sorted())
        // 全部埋めたら nil
        for p in stride(from: 0.0, through: 100.0, by: 5.0) { k.add(at: p) }
        XCTAssertNil(k.defaultAddPosition(current: 50))
        XCTAssertTrue(k.freePositions().isEmpty)
        _ = s
    }

    func testInitNormalizes() throws {
        let s = try spec(volume)
        let v = try vol(-1)
        let k = ETAutomation(source: .outputVolume,
                             keyframes: [.init(position: 80, values: try vol(-3)),
                                         .init(position: .nan, values: v),
                                         .init(position: 80, values: v),
                                         .init(position: 20, values: try vol(-2)),
                                         .init(position: 40, values: [1, 2]),          // 数が違う
                                         .init(position: 500, values: try vol(-4))],
                             spec: s)
        let a = try XCTUnwrap(k)
        XCTAssertEqual(a.keyframes.map(\.position), [20, 80, 100])
        XCTAssertEqual(a.keyframes[1].values, try vol(-3), "同じ位置は先のものを残す")
        XCTAssertNil(ETAutomation(source: .outputVolume, keyframes: [], spec: s))
        let many = (0..<100).map { ETAutomation.Keyframe(position: Double($0), values: v) }
        XCTAssertEqual(ETAutomation(source: .outputVolume, keyframes: many, spec: s)?.keyframes.count,
                       ETAutomation.maxKeyframes)
    }

    // MARK: - 保存形式の往復

    private func loaded(_ s: ETEffect, _ a: ETAutomation) -> PipelineStore.Loaded {
        PipelineStore.Loaded(spec: s, values: a.topValues, enabled: true,
                             inputBus: 0, outputBus: 0, channelSpec: -1, automation: a)
    }

    func testShortAndLongRoundTrip() throws {
        let s = try spec(peq15)
        var a = s.defaults, b = s.defaults
        a[g(s: s, 0)] = 3; b[g(s: s, 0)] = -4
        a[45 + 1] = 0; b[45 + 1] = 3
        let k = try automation(s, a, b)
        let item = loaded(s, k)

        let short = try roundTrip(PipelineStore.shortForm([item]))
        let fromShort = PipelineStore.parse(short, catalog: ETCatalog)
        XCTAssertEqual(fromShort.count, 1)
        XCTAssertEqual(fromShort[0].automation, k)
        XCTAssertEqual(fromShort[0].values, k.topValues)

        let long = try roundTrip(PipelineStore.longForm([item]))
        let fromLong = PipelineStore.parse(long, catalog: ETCatalog)
        XCTAssertEqual(fromLong[0].automation, k)
        XCTAssertEqual(fromLong[0].values, k.topValues)

        // ロングでは段の鍵として name の隣に置き、parameters の中には入れない。
        let entry = try XCTUnwrap(((long as? [String: Any])?["pipeline"] as? [[String: Any]])?.first)
        XCTAssertNotNil(entry[ETAutomation.key])
        XCTAssertNil((entry[ETAutomation.key] as? [String: Any])?["sel"], "選んでいるキーフレームは書かない")
        XCTAssertNil((entry["parameters"] as? [String: Any])?[ETAutomation.key])
    }

    private func g(s: ETEffect, _ band: Int) -> Int {
        (s.params.first { $0.key == "g" }?.offset ?? 0) + band
    }

    func testTopLevelValuesAreIgnoredOnRead() throws {
        // 上の値は一番上のキーフレームと違っていても、読むときはキーフレームを使う。
        let s = try spec(volume)
        let k = try automation(s, try vol(-10), try vol(0))
        var entries = PipelineStore.shortForm([loaded(s, k)])
        entries[0]["vl"] = -33
        let item = try XCTUnwrap(PipelineStore.parse(try roundTrip(entries), catalog: ETCatalog).first)
        XCTAssertEqual(item.values[0], 0)
        XCTAssertEqual(item.values, item.automation?.topValues)
    }

    func testUnreadableAutomationIsDropped() throws {
        let s = try spec(volume)
        func parse(_ automation: Any?, name: String = "Volume") -> PipelineStore.Loaded? {
            var entry: [String: Any] = ["nm": name, "en": true, "vl": -5]
            if let automation { entry[ETAutomation.key] = automation }
            return PipelineStore.parse([entry], catalog: ETCatalog).first
        }
        let kf: [[String: Any]] = [["at": 50, "p": ["vl": -10]], ["at": 100, "p": ["vl": 0]]]

        let ok = try XCTUnwrap(parse(["src": "outputVolume", "sel": 0, "kf": kf]))
        XCTAssertEqual(ok.automation?.keyframes.count, 2)
        XCTAssertEqual(ok.values[0], 0, "sel は読まない。上の値は一番上のキーフレーム")

        // 知らない src（将来の元）・kf が配列でない・空・辞書でない
        XCTAssertNil(parse(["src": "timeOfDay", "sel": 0, "kf": kf])?.automation)
        XCTAssertNil(parse(["src": "outputVolume", "kf": "x"])?.automation)
        XCTAssertNil(parse(["src": "outputVolume", "kf": [Any]()])?.automation)
        XCTAssertNil(parse("on")?.automation)
        // その場合は普通のカードとして読む（上の値のまま）
        XCTAssertEqual(parse(["src": "x", "kf": kf])?.values[0], -5)

        // 位置が数でないキーフレームは捨てる
        let mixed: [[String: Any]] = [["at": "x", "p": ["vl": 1]], ["at": Double.nan, "p": ["vl": 2]],
                                      ["at": 70, "p": ["vl": -2]]]
        let m = try XCTUnwrap(parse(["src": "outputVolume", "kf": mixed]))
        XCTAssertEqual(m.automation?.keyframes.map(\.position), [70])
        XCTAssertNil(parse(["src": "outputVolume", "kf": [["at": Double.nan, "p": [String: Any]()]]])?.automation)

        // 重なる位置と範囲外の sel
        let dup: [[String: Any]] = [["at": 50, "p": ["vl": -1]], ["at": 50, "p": ["vl": -9]]]
        let d = try XCTUnwrap(parse(["src": "outputVolume", "sel": 9, "kf": dup]))
        XCTAssertEqual(d.automation?.keyframes.count, 1)
        XCTAssertEqual(d.values[0], -1)

        // p に無いパラメータは上の値のまま
        let partial = try XCTUnwrap(parse(["src": "outputVolume", "kf": [["at": 50]]]))
        XCTAssertEqual(partial.values[0], -5)

        // 使えないカード（IR Reverb）は読まない
        let ir = try spec("IRReverbPlugin")
        let irEntry: [String: Any] = ["nm": ir.name, "en": true,
                                      ETAutomation.key: ["src": "outputVolume", "kf": [["at": 50, "p": [String: Any]()]]]]
        XCTAssertNil(PipelineStore.parse([irEntry], catalog: ETCatalog).first?.automation)
        _ = s
    }

    func testSectionAndExternalDoNotCarryAutomation() throws {
        let s = try spec(volume)
        let k = try automation(s, try vol(-10), try vol(0))
        let section = PipelineStore.Loaded(spec: ETSection.spec, values: [], enabled: true,
                                           inputBus: 0, outputBus: 0, channelSpec: -1,
                                           sectionName: "A", automation: k)
        let external = PipelineStore.Loaded(
            spec: ETEffect.external(type: "External:au:x", name: "X", category: "Audio Units"),
            values: [], enabled: true, inputBus: 0, outputBus: 0, channelSpec: -1,
            externalID: "au:x", externalInstanceID: "i", automation: k)
        for entry in PipelineStore.shortForm([section, external]) {
            XCTAssertNil(entry[ETAutomation.key])
        }
        // 読むときも付けない
        let raw: [[String: Any]] = [
            ["nm": "Section", "cm": "A", "en": true, ETAutomation.key: ["src": "outputVolume", "kf": [["at": 50]]]],
            ["nm": "X", "external": "au:x", "externalInstance": "i",
             ETAutomation.key: ["src": "outputVolume", "kf": [["at": 50]]]],
        ]
        let items = PipelineStore.parse(raw, catalog: ETCatalog)
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.allSatisfy { $0.automation == nil })
    }

    // MARK: - 上流・PC・プリセットへは出さない

    func testUpstreamAndRemoteGetNoKeyframes() throws {
        let s = try spec(volume)
        let k = try automation(s, try vol(-10), try vol(0))
        let item = loaded(s, k)

        XCTAssertNotNil(PipelineStore.shortForm([item])[0][ETAutomation.key])
        XCTAssertNil(ETShareLink.effeTuneForm([item])[0][ETAutomation.key])
        XCTAssertNil(PipelineStore.upstreamEntry(PipelineStore.shortForm([item])[0])[ETAutomation.key])
        XCTAssertNil(ETRemoteProjection.entry(for: item)?[ETAutomation.key])
        XCTAssertNil(ETRemoteProjection.params(for: item)?[ETAutomation.key])
        XCTAssertNil(ETRemoteProjection.params(for: node(s, k))?[ETAutomation.key])
        XCTAssertEqual(ETRemoteProjection.removedKeys(sent: [ETAutomation.key: 1, "vl": 1], now: ["vl": 1]), [])
        XCTAssertEqual(ETRemoteProjection.project([item]).pipeline.count, 1)
        XCTAssertNil(ETRemoteProjection.project([item]).pipeline[0][ETAutomation.key])
    }

    func testDeckLinkKeepsKeyframes() throws {
        let s = try spec(volume)
        let k = try automation(s, try vol(-10), try vol(0))
        let url = try XCTUnwrap(ETShareLink.deckURL(for: [node(s, k)]))
        let items = ETShareLink.parse(url.absoluteString, catalog: ETCatalog)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].automation, k)
        XCTAssertEqual(items[0].values[0], 0)
    }

    func testDeckLinkCarriesSoundingValuesAtTheTop() throws {
        // 共有の画面は鳴らしている値に置き換えた鎖で作る。上の値が鳴っている値になり、キーフレームも運ぶ。
        let s = try spec(volume)
        let k = try automation(s, try vol(-10), try vol(0))
        let sounding = ETAutomation.sounding([node(s, k)], at: 75)
        XCTAssertEqual(sounding[0].values[0], -5, accuracy: 1e-5)
        XCTAssertEqual(sounding[0].automation, k)
        let entry = PipelineStore.shortForm(sounding)[0]
        XCTAssertEqual((entry["vl"] as? NSNumber)?.floatValue ?? 99, -5, accuracy: 1e-5)
        XCTAssertNotNil(entry[ETAutomation.key])
        // EffeTune へは同じ鎖から automation を外した鳴っている値だけ
        let upstream = ETShareLink.effeTuneForm(sounding)[0]
        XCTAssertNil(upstream[ETAutomation.key])
        XCTAssertEqual((upstream["vl"] as? NSNumber)?.floatValue ?? 99, -5, accuracy: 1e-5)
    }

    // MARK: - 貼られた字

    func testPrepareClampsKeyframeValues() throws {
        let s = try spec(peq15)
        let entry: [String: Any] = [
            "nm": s.name, "en": true,
            ETAutomation.key: ["src": "outputVolume", "sel": 0,
                               "kf": [["at": 50, "p": ["g0": 99]], ["at": 100, "p": ["g0": 3]]]],
        ]
        let (json, report) = ETChainText.prepare([entry], catalog: ETCatalog)
        XCTAssertTrue(report.limited.contains { $0.hasSuffix("g0") }, "\(report)")
        XCTAssertFalse(report.ignored.contains { $0.contains(ETAutomation.key) }, "\(report)")
        let items = PipelineStore.parse(json, catalog: ETCatalog)
        XCTAssertEqual(items[0].automation?.keyframes[0].values[15], 20)
        XCTAssertEqual(items[0].automation?.keyframes[1].values[15], 3)
    }

    func testPrepareDropsMalformedAutomation() throws {
        let short: [String: Any] = ["nm": "Volume", "en": true, ETAutomation.key: "x"]
        let (json, report) = ETChainText.prepare([short], catalog: ETCatalog)
        XCTAssertTrue(report.ignored.contains("Volume.\(ETAutomation.key)"), "\(report)")
        XCTAssertNil((json as? [[String: Any]])?.first?[ETAutomation.key])

        // ロング形式の段の鍵は、知らない鍵として数えない
        let long: [String: Any] = ["pipeline": [[
            "name": "Volume", "enabled": true, "parameters": ["vl": 1],
            ETAutomation.key: ["src": "outputVolume", "kf": [["at": 50, "p": ["vl": -2]]]],
        ] as [String: Any]]]
        let (_, longReport) = ETChainText.prepare(long, catalog: ETCatalog)
        XCTAssertTrue(longReport.isEmpty, "\(longReport)")
    }

    func testPrepareFollowsDecode() throws {
        let kf: [[String: Any]] = [["at": 50, "p": ["vl": -10]], ["at": 100, "p": ["vl": 0]]]
        let auto: [String: Any] = ["src": "outputVolume", "kf": kf]

        // 使えないカード（IR Reverb）の automation は外して報告する。decode も読まない。
        let ir = try spec("IRReverbPlugin")
        let irEntry: [String: Any] = ["nm": ir.name, "en": true, ETAutomation.key: auto]
        let (irJSON, irReport) = ETChainText.prepare([irEntry], catalog: ETCatalog)
        XCTAssertTrue(irReport.ignored.contains("\(ir.name).\(ETAutomation.key)"), "\(irReport)")
        XCTAssertNil((irJSON as? [[String: Any]])?.first?[ETAutomation.key])

        // 知らない src は外して報告する。
        let unknown: [String: Any] = ["nm": "Volume", "en": true,
                                      ETAutomation.key: ["src": "timeOfDay", "kf": kf]]
        let (unJSON, unReport) = ETChainText.prepare([unknown], catalog: ETCatalog)
        XCTAssertTrue(unReport.ignored.contains("Volume.\(ETAutomation.key)"), "\(unReport)")
        XCTAssertNil((unJSON as? [[String: Any]])?.first?[ETAutomation.key])

        // 辞書でない kf の要素があっても、読める要素は残る。
        let mixed: [String: Any] = ["nm": "Volume", "en": true,
                                    ETAutomation.key: ["src": "outputVolume",
                                                       "kf": ["x", ["at": 50, "p": ["vl": -10]] as [String: Any]] as [Any]]]
        let (mxJSON, mxReport) = ETChainText.prepare([mixed], catalog: ETCatalog)
        XCTAssertTrue(mxReport.isEmpty, "\(mxReport)")
        let items = PipelineStore.parse(mxJSON, catalog: ETCatalog)
        XCTAssertEqual(items.first?.automation?.keyframes.map(\.position), [50])
    }

    // MARK: - Hold（次のキーフレームまで保って、そこで一度に切り替える）

    /// 50 / 75 / 100% の3つ。50% だけ Hold。
    private func holdAutomation(_ s: ETEffect, _ a: [Float], _ b: [Float], _ c: [Float]) throws -> ETAutomation {
        var k = try XCTUnwrap(ETAutomation(source: .outputVolume,
                                           keyframes: [.init(position: 50, values: a),
                                                       .init(position: 75, values: b),
                                                       .init(position: 100, values: c)],
                                           spec: s))
        XCTAssertTrue(k.setHold(true, at: 0))
        return k
    }

    func testHoldStepsAtNextKeyframe() throws {
        let s = try spec(volume)
        let k = try holdAutomation(s, try vol(-12), try vol(-6), try vol(0))
        func sound(_ p: Double?) -> Float { k.values(at: p, spec: s, current: s.defaults)[0] }
        XCTAssertEqual(sound(50), -12)
        XCTAssertEqual(sound(55), -12)
        XCTAssertEqual(sound(70), -12, "Hold の区間は下のキーフレームのまま")
        XCTAssertEqual(sound(75), -6, "次のキーフレームの位置で一度に切り替わる")
        // 75→100 は Hold でないので今までどおり直線。
        XCTAssertEqual(sound(90), -2.4, accuracy: 1e-4)
        XCTAssertEqual(sound(100), 0)

        // Hold を外すと直線に戻る。
        var linear = k
        XCTAssertTrue(linear.setHold(false, at: 0))
        XCTAssertEqual(linear.values(at: 70, spec: s, current: s.defaults)[0], -7.2, accuracy: 1e-4)
    }

    func testHoldJumpsAtFloatVolumeStepsThatFallJustBelowTheGrid() throws {
        let s = try spec(volume)
        // 70% の Float は 69.9999988 になる。Hold の切り替えは 70% ちょうどで起きる。
        var k = try XCTUnwrap(ETAutomation(source: .outputVolume,
                                           keyframes: [.init(position: 50, values: try vol(-12)),
                                                       .init(position: 70, values: try vol(-6)),
                                                       .init(position: 100, values: try vol(0))],
                                           spec: s))
        XCTAssertTrue(k.setHold(true, at: 0))
        let raw = Double(Float(0.70)) * 100
        XCTAssertLessThan(raw, 70, "前提 Float(0.70) は 70 を下回る")
        let pos = ETAutomation.Source.outputVolume.position(fromVolume: 0.70)
        XCTAssertEqual(pos, 70)
        XCTAssertEqual(k.values(at: pos, spec: s, current: s.defaults)[0], -6)
        for pct in [35, 45, 65, 90, 95] {
            XCTAssertEqual(ETAutomation.Source.outputVolume.position(fromVolume: Float(pct) / 100), Double(pct))
        }
    }

    func testHoldAppliesToToggleAndPEQBandsAtNextKeyframeNotMidpoint() throws {
        for (s, f, g, q, t, e) in try layouts() {
            var a = s.defaults, b = s.defaults
            a[f + 2] = 100; b[f + 2] = 1000
            a[g + 2] = 6; b[g + 2] = -4
            a[q + 2] = 0.5; b[q + 2] = 8
            a[t + 2] = 0; b[t + 2] = 3
            a[e + 1] = 0; b[e + 1] = 1
            var k = try automation(s, a, b)
            XCTAssertTrue(k.setHold(true, at: 0))
            func at(_ x: Double) -> [Float] { k.values(at: 50 + 50 * x, spec: s, current: s.defaults) }
            XCTAssertEqual(at(0.1), a)
            XCTAssertEqual(at(0.5), a, "真ん中を過ぎても切り替わらない")
            XCTAssertEqual(at(0.9), a)
            XCTAssertEqual(at(1), b, "次のキーフレームで切り替わる")
        }
    }

    func testHoldKeepsHzUnchangedInsideTheSegment() throws {
        let s = try spec("DattorroPlateReverbPlugin")
        let p = try XCTUnwrap(s.params.first { $0.name == "modulationRate" })
        var a = s.defaults, b = s.defaults
        a[p.offset] = 0.5; b[p.offset] = 5
        var k = try automation(s, a, b)
        XCTAssertTrue(k.setHold(true, at: 0))
        XCTAssertEqual(k.values(at: 75, spec: s, current: s.defaults)[p.offset], 0.5)
        XCTAssertEqual(k.values(at: 100, spec: s, current: s.defaults)[p.offset], 5)
    }

    func testTopKeyframeNeverHolds() throws {
        let s = try spec(volume)
        var k = try holdAutomation(s, try vol(-12), try vol(-6), try vol(0))
        XCTAssertFalse(k.setHold(true, at: 2), "一番上には付けない")
        XCTAssertFalse(k.setHold(true, at: 3), "範囲の外")
        XCTAssertFalse(k.setHold(true, at: -1))
        XCTAssertFalse(k.setHold(true, at: 0), "変わらないなら false")
        XCTAssertEqual(k.keyframes.map(\.hold), [true, false, false])

        // 消して一番上になったものは外れる。
        XCTAssertTrue(k.remove(at: 2))
        XCTAssertEqual(k.keyframes.map(\.hold), [true, false])

        // Hold のキーフレームを一番上へ動かすと外れる。
        XCTAssertEqual(k.move(0, to: 100), 1)
        XCTAssertEqual(k.keyframes.map(\.hold), [false, false])

        // 整えて作るときも、一番上の旗は外す。
        let made = try XCTUnwrap(ETAutomation(source: .outputVolume,
                                              keyframes: [.init(position: 50, values: try vol(-5), hold: true),
                                                          .init(position: 100, values: try vol(0), hold: true)],
                                              spec: s))
        XCTAssertEqual(made.keyframes.map(\.hold), [true, false])
    }

    func testRemovingTopClearsTheNewTop() throws {
        let s = try spec(volume)
        var k = try holdAutomation(s, try vol(-12), try vol(-6), try vol(0))
        XCTAssertTrue(k.setHold(true, at: 1))
        XCTAssertTrue(k.remove(at: 2))
        XCTAssertEqual(k.keyframes.map(\.hold), [true, false])
    }

    func testInitPreservesHold() throws {
        let s = try spec(volume)
        let made = try XCTUnwrap(ETAutomation(source: .outputVolume,
                                              keyframes: [.init(position: 80, values: try vol(-3), hold: true),
                                                          .init(position: 20, values: try vol(-2), hold: true),
                                                          .init(position: 90, values: try vol(-1))],
                                              spec: s))
        XCTAssertEqual(made.keyframes.map(\.position), [20, 80, 90])
        XCTAssertEqual(made.keyframes.map(\.hold), [true, true, false])
    }

    func testAddInheritsHoldOfSplitSegment() throws {
        let s = try spec(volume)
        // Hold の区間の中: 両側とも Hold のまま。
        var inside = try holdAutomation(s, try vol(-12), try vol(-6), try vol(0))
        XCTAssertEqual(inside.add(at: 60), 1)
        XCTAssertEqual(inside.keyframes.map(\.hold), [true, true, false, false])
        // 直線の区間の中: 直線。
        var linear = try holdAutomation(s, try vol(-12), try vol(-6), try vol(0))
        XCTAssertEqual(linear.add(at: 85), 2)
        XCTAssertEqual(linear.keyframes.map(\.hold), [true, false, false, false])
        // 一番下より下: 直線。
        var below = try holdAutomation(s, try vol(-12), try vol(-6), try vol(0))
        XCTAssertEqual(below.add(at: 20), 0)
        XCTAssertEqual(below.keyframes.map(\.hold), [false, true, false, false])
        // 一番上より上: 直線（新しい一番上は Hold にならない）。
        var above = try XCTUnwrap(ETAutomation(source: .outputVolume,
                                               keyframes: [.init(position: 40, values: try vol(-12)),
                                                           .init(position: 60, values: try vol(-6))],
                                               spec: s))
        XCTAssertTrue(above.setHold(true, at: 0))
        XCTAssertEqual(above.add(at: 90), 2)
        XCTAssertEqual(above.keyframes.map(\.hold), [true, false, false])
    }

    func testRemoveAndMoveKeepHold() throws {
        let s = try spec(volume)
        var k = try holdAutomation(s, try vol(-12), try vol(-6), try vol(0))
        XCTAssertTrue(k.setHold(true, at: 1))
        // 真ん中を消すと、つないだ区間は下のキーフレームの設定に従う。
        var r = k
        XCTAssertTrue(r.remove(at: 1))
        XCTAssertEqual(r.keyframes.map(\.position), [50, 100])
        XCTAssertEqual(r.keyframes.map(\.hold), [true, false])
        // 一番下を消す。
        var r0 = k
        XCTAssertTrue(r0.remove(at: 0))
        XCTAssertEqual(r0.keyframes.map(\.hold), [true, false])
        // 動かすと旗も一緒に動く。
        var m = k
        XCTAssertEqual(m.move(0, to: 80), 1)
        XCTAssertEqual(m.keyframes.map(\.position), [75, 80, 100])
        XCTAssertEqual(m.keyframes.map(\.hold), [true, true, false])
        XCTAssertEqual(m.move(1, to: 60), 0)
        XCTAssertEqual(m.keyframes.map(\.position), [60, 75, 100])
        XCTAssertEqual(m.keyframes.map(\.hold), [true, true, false])
    }

    func testHoldRoundTrip() throws {
        let s = try spec(volume)
        let k = try holdAutomation(s, try vol(-12), try vol(-6), try vol(0))
        let item = loaded(s, k)

        let forms: [Any] = [PipelineStore.shortForm([item]), PipelineStore.longForm([item])]
        for form in forms {
            let back = PipelineStore.parse(try roundTrip(form), catalog: ETCatalog)
            XCTAssertEqual(back.count, 1)
            XCTAssertEqual(back[0].automation, k)
            XCTAssertEqual(back[0].automation?.keyframes.map(\.hold), [true, false, false])
        }

        // 書くのは Hold のキーフレームだけ。
        let list = try XCTUnwrap(k.encoded(spec: s)["kf"] as? [[String: Any]])
        XCTAssertEqual(list.map { $0["hold"] as? Bool }, [true, nil, nil])

        // Hold が無ければ今までと同じ形。
        let plain = try automation(s, try vol(-10), try vol(0))
        for kf in try XCTUnwrap(plain.encoded(spec: s)["kf"] as? [[String: Any]]) {
            XCTAssertEqual(Set(kf.keys), ["at", "p"])
        }

        // 読めない hold は直線として読み、automation は捨てない。
        let p: [String: Any] = ["vl": -10]
        let garbage: [[String: Any]] = [
            ["at": 25, "hold": "yes", "p": p],
            ["at": 50, "hold": 2, "p": p],
            ["at": 75, "hold": [String: Any](), "p": p],
            ["at": 100, "hold": true, "p": p],
        ]
        let raw: [String: Any] = ["src": "outputVolume", "kf": garbage]
        let a = try XCTUnwrap(ETAutomation.decode(raw, spec: s, values: s.defaults))
        XCTAssertEqual(a.keyframes.map(\.position), [25, 50, 75, 100])
        XCTAssertEqual(a.keyframes.map(\.hold), [false, false, false, false], "一番上の true も外れる")
        let noHold: [[String: Any]] = [["at": 50, "p": p]]
        let none: [String: Any] = ["src": "outputVolume", "kf": noHold]
        let missing = try XCTUnwrap(ETAutomation.decode(none, spec: s, values: s.defaults))
        XCTAssertEqual(missing.keyframes.map(\.hold), [false])
    }

    func testPrepareKeepsHold() throws {
        let kf: [[String: Any]] = [["at": 50, "hold": true, "p": ["vl": -10]], ["at": 100, "p": ["vl": 0]]]
        let entry: [String: Any] = ["nm": "Volume", "en": true,
                                    ETAutomation.key: ["src": "outputVolume", "kf": kf]]
        let (json, report) = ETChainText.prepare([entry], catalog: ETCatalog)
        XCTAssertTrue(report.isEmpty, "\(report)")
        let items = PipelineStore.parse(json, catalog: ETCatalog)
        XCTAssertEqual(items.first?.automation?.keyframes.map(\.hold), [true, false])
    }

    func testSoundingAtHoldPositionIsLowerKeyframe() throws {
        let s = try spec(volume)
        let k = try holdAutomation(s, try vol(-12), try vol(-6), try vol(0))
        let held = ETAutomation.sounding([node(s, k)], at: 70)
        XCTAssertEqual(held[0].values[0], -12)
        XCTAssertEqual(held[0].automation, k)
        let switched = ETAutomation.sounding([node(s, k)], at: 75)
        XCTAssertEqual(switched[0].values[0], -6)
    }

    // MARK: - 段

    func testSoundingSwapsValuesAndKeepsIdentity() throws {
        let s = try spec(volume)
        let k = try automation(s, try vol(-10), try vol(0))
        let n = node(s, k)
        let plain = ETChainNode(spec: s, values: try vol(-3))
        let out = ETAutomation.sounding([n, plain], at: 75)
        XCTAssertEqual(out[0].id, n.id)
        XCTAssertEqual(out[0].values[0], -5, accuracy: 1e-5)
        XCTAssertEqual(out[0].automation, k)
        XCTAssertEqual(out[1].values, plain.values)
        XCTAssertEqual(n.values[0], 0, "元の段は変えない（一番上のキーフレームのまま）")
        XCTAssertEqual(PipelineStore.Loaded(n).automation, k)
    }

    func testEffectPresetsStoreTopKeyframe() throws {
        let s = try spec(volume)
        let k = try automation(s, try vol(-10), try vol(0))
        let params = EffectPresetStoreCore.params(for: node(s, k))
        XCTAssertNil(params[ETAutomation.key])
        XCTAssertEqual((params["vl"] as? NSNumber)?.floatValue, 0, "一番上のキーフレーム")
    }
}
