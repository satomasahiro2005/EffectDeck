//  AutomationTests.swift
//  音量に追従するカードのキーフレームと補間（DSP/Automation.swift）。
//
//  見ているもの:
//    - 補間の種類（Hz と Q は対数、dB は直線、選択肢と入切は真ん中で切り替え、遅延の設定は補間しない）
//    - PEQ の帯でフィルタ種別か入切が違うときは0 dBを通って移る
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
    private func automation(_ spec: ETEffect, _ a: [Float], _ b: [Float],
                            selected: Int? = nil) throws -> ETAutomation {
        try XCTUnwrap(ETAutomation(source: .outputVolume,
                                   keyframes: [.init(position: 50, values: a), .init(position: 100, values: b)],
                                   selected: selected, spec: spec))
    }

    private func vol(_ db: Float) throws -> [Float] {
        var v = try spec(volume).defaults
        v[0] = db
        return v
    }

    private func node(_ spec: ETEffect, _ a: ETAutomation? = nil) -> ETChainNode {
        var n = ETChainNode(spec: spec, values: a?.selectedValues ?? spec.defaults)
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

    func testLogarithmicAndStepOnPEQ() throws {
        let s = try spec(peq15)
        var a = s.defaults, b = s.defaults
        a[3] = 100; b[3] = 1000                    // 帯3の周波数
        a[33] = 0.5; b[33] = 8                     // 帯3の Q: 幾何平均は2
        a[49] = 0; b[49] = 3                       // 帯4のフィルタ種別は pk と ls（帯3は種別が同じ）
        let k = try automation(s, a, b)
        let mid = k.values(at: 75, spec: s, current: s.defaults)
        XCTAssertEqual(mid[3], 316)                // 整数なので丸め
        XCTAssertEqual(mid[33], 2, accuracy: 1e-4)
        // 選択肢は真ん中で切り替わる。0.49 は A、0.5 は B。
        let before = k.values(at: 50 + 50 * 0.49, spec: s, current: s.defaults)
        let after = k.values(at: 75, spec: s, current: s.defaults)
        XCTAssertEqual(before[49], 0)
        XCTAssertEqual(after[49], 3)
    }

    // MARK: - PEQ の帯

    /// 15Band と 5Band で同じ試験をする。(周波数, 利得, Q, 種別, 入切) の位置と帯の数。
    private func layouts() throws -> [(ETEffect, Int, Int, Int, Int, Int)] {
        [(try spec(peq15), 0, 15, 30, 45, 60), (try spec(peq5), 0, 5, 10, 15, 20)]
    }

    func testPEQFadesThroughZeroWhenTypeChanges() throws {
        for (s, f, g, q, t, e) in try layouts() {
            let band = 2
            var a = s.defaults, b = s.defaults
            a[f + band] = 1000; b[f + band] = 3000
            a[g + band] = 6; b[g + band] = 4
            a[t + band] = 0; b[t + band] = 3       // pk → ls
            a[e + band] = 1; b[e + band] = 1
            let k = try automation(s, a, b)
            func at(_ t: Double) -> [Float] { k.values(at: 50 + 50 * t, spec: s, current: s.defaults) }

            let quarter = at(0.25)
            XCTAssertEqual(quarter[t + band], 0, "pk のまま")
            XCTAssertEqual(quarter[g + band], 3, accuracy: 1e-5)
            XCTAssertEqual(quarter[f + band], 1000)
            XCTAssertEqual(quarter[q + band], a[q + band])

            let half = at(0.5)
            XCTAssertEqual(half[t + band], 3, "後半は B の帯")
            XCTAssertEqual(half[g + band], 0, accuracy: 1e-5)
            XCTAssertEqual(half[f + band], 3000)

            let late = at(0.75)
            XCTAssertEqual(late[t + band], 3)
            XCTAssertEqual(late[g + band], 2, accuracy: 1e-5)

            // 種別が同じ帯は普通に補間する。
            XCTAssertEqual(quarter[f + 0], s.defaults[f + 0])
        }
    }

    func testPEQFadesWhenEnabledChanges() throws {
        for (s, f, g, _, t, e) in try layouts() {
            let band = 1
            var a = s.defaults, b = s.defaults
            a[e + band] = 0; b[e + band] = 1
            a[g + band] = 9; b[g + band] = 6
            let k = try automation(s, a, b)
            let early = k.values(at: 62.5, spec: s, current: s.defaults)
            XCTAssertEqual(early[e + band], 0, "切のまま")
            let late = k.values(at: 87.5, spec: s, current: s.defaults)
            XCTAssertEqual(late[e + band], 1)
            XCTAssertEqual(late[g + band], 3, accuracy: 1e-5)
            XCTAssertEqual(late[t + band], s.defaults[t + band])
            _ = f
        }
    }

    func testPEQDoesNotFadeWhenBothDisabled() throws {
        for (s, _, g, _, t, e) in try layouts() {
            var a = s.defaults, b = s.defaults
            a[e] = 0; b[e] = 0
            a[t] = 0; b[t] = 3
            a[g] = 4; b[g] = 8
            let k = try automation(s, a, b)
            let early = k.values(at: 62.5, spec: s, current: s.defaults)
            XCTAssertEqual(early[g], 5, accuracy: 1e-5, "どちらも切なら普通の直線")
        }
    }

    // MARK: - 補間しない設定

    func testHeldValuesComeFromCurrentAndAreSharedByStore() throws {
        let s = try spec("BrickwallLimiterPlugin")
        let os = try XCTUnwrap(s.params.first { $0.name == "oversampling" }).offset
        var a = s.defaults, b = s.defaults
        a[os] = 1; b[os] = 4
        var k = try automation(s, a, b, selected: 0)
        // store すると、選んでいるものの値が全キーフレームの held になる。
        XCTAssertEqual(k.keyframes[1].values[os], 1, "読み込みで選んでいるキーフレームに揃う")
        var cur = k.selectedValues
        cur[os] = 8
        k.store(selected: cur, spec: s)
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
        var k = try automation(s, try vol(-10), try vol(0), selected: 0)
        k.store(selected: [1, 2, 3], spec: s)
        XCTAssertEqual(k.selectedValues, try vol(-10))
        k.store(selected: try vol(-3), spec: s)
        XCTAssertEqual(k.selectedValues, try vol(-3))
        XCTAssertEqual(k.keyframes[1].values, try vol(0))
    }

    // MARK: - キーフレームの足し引き

    func testAddCopiesNearestAndSelects() throws {
        let s = try spec(volume)
        var k = try automation(s, try vol(-10), try vol(0), selected: 0)
        k.add(at: 62)                              // 刻みで 60。50 の方が近い
        XCTAssertEqual(k.keyframes.map(\.position), [50, 60, 100])
        XCTAssertEqual(k.selected, 1)
        XCTAssertEqual(k.selectedValues, try vol(-10))
        k.add(at: 90)
        XCTAssertEqual(k.keyframes.map(\.position), [50, 60, 90, 100])
        XCTAssertEqual(k.keyframes[2].values, try vol(0))
        XCTAssertEqual(k.selected, 2)
        // 同じ近さなら位置の低い方（75 は 50 と 100 の真ん中）
        var m = try automation(s, try vol(-10), try vol(0))
        m.add(at: 75)
        XCTAssertEqual(m.selectedValues, try vol(-10))
        // あるものを足すと、選ぶだけ
        k.add(at: 50)
        XCTAssertEqual(k.keyframes.count, 4)
        XCTAssertEqual(k.selected, 0)
        k.add(at: 101)                             // 範囲外は 100 に寄る
        XCTAssertEqual(k.keyframes.count, 4)
        XCTAssertEqual(k.selected, 3)
    }

    func testRemoveSelected() throws {
        let s = try spec(volume)
        var k = try automation(s, try vol(-10), try vol(0), selected: 1)
        XCTAssertTrue(k.removeSelected())
        XCTAssertEqual(k.keyframes.count, 1)
        XCTAssertEqual(k.selected, 0)
        XCTAssertEqual(k.selectedValues, try vol(-10))
        XCTAssertFalse(k.removeSelected(), "最後の1つは消さない")
        XCTAssertEqual(k.keyframes.count, 1)
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
                             selected: 99, spec: s)
        let a = try XCTUnwrap(k)
        XCTAssertEqual(a.keyframes.map(\.position), [20, 80, 100])
        XCTAssertEqual(a.keyframes[1].values, try vol(-3), "同じ位置は先のものを残す")
        XCTAssertEqual(a.selected, 2, "選択は範囲へ寄る")
        XCTAssertNil(ETAutomation(source: .outputVolume, keyframes: [], selected: nil, spec: s))
        let many = (0..<100).map { ETAutomation.Keyframe(position: Double($0), values: v) }
        XCTAssertEqual(ETAutomation(source: .outputVolume, keyframes: many, selected: 0, spec: s)?.keyframes.count,
                       ETAutomation.maxKeyframes)
    }

    // MARK: - 保存形式の往復

    private func loaded(_ s: ETEffect, _ a: ETAutomation) -> PipelineStore.Loaded {
        PipelineStore.Loaded(spec: s, values: a.selectedValues, enabled: true,
                             inputBus: 0, outputBus: 0, channelSpec: -1, automation: a)
    }

    func testShortAndLongRoundTrip() throws {
        let s = try spec(peq15)
        var a = s.defaults, b = s.defaults
        a[g(s: s, 0)] = 3; b[g(s: s, 0)] = -4
        a[45 + 1] = 0; b[45 + 1] = 3
        let k = try automation(s, a, b, selected: 0)
        let item = loaded(s, k)

        let short = try roundTrip(PipelineStore.shortForm([item]))
        let fromShort = PipelineStore.parse(short, catalog: ETCatalog)
        XCTAssertEqual(fromShort.count, 1)
        XCTAssertEqual(fromShort[0].automation, k)
        XCTAssertEqual(fromShort[0].values, k.keyframes[0].values)

        let long = try roundTrip(PipelineStore.longForm([item]))
        let fromLong = PipelineStore.parse(long, catalog: ETCatalog)
        XCTAssertEqual(fromLong[0].automation, k)
        XCTAssertEqual(fromLong[0].values, k.selectedValues)

        // ロングでは段の鍵として name の隣に置き、parameters の中には入れない。
        let entry = try XCTUnwrap(((long as? [String: Any])?["pipeline"] as? [[String: Any]])?.first)
        XCTAssertNotNil(entry[ETAutomation.key])
        XCTAssertNil((entry["parameters"] as? [String: Any])?[ETAutomation.key])
    }

    private func g(s: ETEffect, _ band: Int) -> Int {
        (s.params.first { $0.key == "g" }?.offset ?? 0) + band
    }

    func testTopLevelValuesAreIgnoredOnRead() throws {
        // 上の値は選んでいるキーフレームと違っていても、読むときはキーフレームを使う。
        let s = try spec(volume)
        let k = try automation(s, try vol(-10), try vol(0), selected: 1)
        var entries = PipelineStore.shortForm([loaded(s, k)])
        entries[0]["vl"] = -33
        let item = try XCTUnwrap(PipelineStore.parse(try roundTrip(entries), catalog: ETCatalog).first)
        XCTAssertEqual(item.values[0], 0)
        XCTAssertEqual(item.automation?.selected, 1)
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
        XCTAssertEqual(ok.values[0], -10)

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
        XCTAssertEqual(d.automation?.selected, 0)
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
        let k = try automation(s, try vol(-10), try vol(0), selected: 1)
        let url = try XCTUnwrap(ETShareLink.deckURL(for: [node(s, k)]))
        let items = ETShareLink.parse(url.absoluteString, catalog: ETCatalog)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].automation, k)
        XCTAssertEqual(items[0].values[0], 0)
    }

    func testDeckLinkCarriesSoundingValuesAtTheTop() throws {
        // 共有の画面は鳴らしている値に置き換えた鎖で作る。上の値が鳴っている値になり、キーフレームも運ぶ。
        let s = try spec(volume)
        let k = try automation(s, try vol(-10), try vol(0), selected: 0)
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

    // MARK: - 段

    func testSoundingSwapsValuesAndKeepsIdentity() throws {
        let s = try spec(volume)
        let k = try automation(s, try vol(-10), try vol(0), selected: 0)
        let n = node(s, k)
        let plain = ETChainNode(spec: s, values: try vol(-3))
        let out = ETAutomation.sounding([n, plain], at: 75)
        XCTAssertEqual(out[0].id, n.id)
        XCTAssertEqual(out[0].values[0], -5, accuracy: 1e-5)
        XCTAssertEqual(out[0].automation, k)
        XCTAssertEqual(out[1].values, plain.values)
        XCTAssertEqual(n.values[0], -10, "元の段は変えない")
        XCTAssertEqual(PipelineStore.Loaded(n).automation, k)
    }

    func testEffectPresetsStoreOnlySelectedKeyframe() throws {
        let s = try spec(volume)
        let k = try automation(s, try vol(-10), try vol(0), selected: 1)
        let params = EffectPresetStoreCore.params(for: node(s, k))
        XCTAssertNil(params[ETAutomation.key])
        XCTAssertEqual((params["vl"] as? NSNumber)?.floatValue, 0)
    }
}
