//  VirtualRoomTests.swift
//  Virtual Room のうち、音にも画面にも触らない部分だけ。
//
//  見るのは 3 つ。
//    - §12 の seed の割り方（Float32 に 32bit 整数を載せる）
//    - §53 の「壁の外へ出さない」配置
//    - §41 の出荷時プリセットが catalog と食い違っていないこと
//
//  図の描画と DSP はここでは見ない（前者は画面、後者は実機）。

#if canImport(CoreGraphics)
import CoreGraphics
#endif
import XCTest


final class VirtualRoomTests: XCTestCase {

    // MARK: - Seed（§12）

    /// 上下 16bit へ割って戻す。**Float32 のままでは 32bit 整数を表せない**ので、
    /// 割らずに持つと大きい seed が別の値に化ける。
    func testSeedSurvivesTheRoundTripThroughFloats() {
        for seed in [UInt32.min, 1, 0xFFFF, 0x10000, 0xA39F7C21, UInt32.max] {
            let parts = ETVirtualRoom.seedParts(seed)
            XCTAssertEqual(ETVirtualRoom.seed(low: parts.low, high: parts.high), seed,
                           "seed \(seed) が往復で変わった")
        }
    }

    /// 割った側はどちらも 16bit に収まる。収まらないと float の丸めで化ける。
    func testSeedPartsStayInSixteenBits() {
        let parts = ETVirtualRoom.seedParts(UInt32.max)
        XCTAssertEqual(parts.low, 65535)
        XCTAssertEqual(parts.high, 65535)
    }

    func testSeedIsShownAsEightHexDigits() {
        XCTAssertEqual(ETVirtualRoom.seedText(0xA39F7C21), "A39F7C21")
        XCTAssertEqual(ETVirtualRoom.seedText(0), "00000000")
    }

    // MARK: - 配置（§53）

    /// 既定の部屋ではどこも詰まっていない。
    func testDefaultRoomNeedsNoClamping() {
        let layout = ETVirtualRoom.layout(width: 4.2, depth: 3.6,
                                          listenerX: 50, listenerY: 36,
                                          angle: 30, distance: 1.8)
        XCTAssertFalse(layout.clamped)
        // ±30° で 1.8m。左右対称で、listener より奥。
        XCTAssertEqual(Double(layout.left.x), 2.1 - 0.9, accuracy: 1e-6)
        XCTAssertEqual(Double(layout.right.x), 2.1 + 0.9, accuracy: 1e-6)
        XCTAssertEqual(Double(layout.left.y), Double(layout.right.y), accuracy: 1e-9)
        XCTAssertGreaterThan(layout.left.y, layout.listener.y)
    }

    /// 部屋より遠い距離を頼んでも、スピーカーは壁の内側に留まる。
    /// **保存値は書き換えない**ので、ここで見るのは描く位置だけ。
    func testSpeakersStayInsideTheWalls() {
        let layout = ETVirtualRoom.layout(width: 3, depth: 3,
                                          listenerX: 50, listenerY: 30,
                                          angle: 45, distance: 6)
        XCTAssertTrue(layout.clamped)
        for point in [layout.left, layout.right] {
            XCTAssertGreaterThanOrEqual(Double(point.x), -1e-6)
            XCTAssertLessThanOrEqual(Double(point.x), 3 + 1e-6)
            XCTAssertGreaterThanOrEqual(Double(point.y), -1e-6)
            XCTAssertLessThanOrEqual(Double(point.y), 3 + 1e-6)
        }
    }

    /// 部屋を広げれば、頼んだ距離がそのまま戻る（§53）。
    func testWideningTheRoomGivesTheDistanceBack() {
        let narrow = ETVirtualRoom.layout(width: 3, depth: 3,
                                          listenerX: 50, listenerY: 30,
                                          angle: 45, distance: 4)
        XCTAssertTrue(narrow.clamped)
        let wide = ETVirtualRoom.layout(width: 20, depth: 20,
                                        listenerX: 50, listenerY: 30,
                                        angle: 45, distance: 4)
        XCTAssertFalse(wide.clamped)
        let dx = Double(wide.right.x - wide.listener.x)
        let dy = Double(wide.right.y - wide.listener.y)
        XCTAssertEqual((dx * dx + dy * dy).squareRoot(), 4, accuracy: 1e-6)
    }

    /// listener も壁から余白を取る。潰れた部屋を渡しても落ちない。
    func testListenerKeepsAMarginFromTheWalls() {
        let layout = ETVirtualRoom.layout(width: 2, depth: 2,
                                          listenerX: 0, listenerY: 100,
                                          angle: 30, distance: 1)
        XCTAssertGreaterThanOrEqual(Double(layout.listener.x), ETVirtualRoom.margin - 1e-9)
        XCTAssertLessThanOrEqual(Double(layout.listener.y), 2 - ETVirtualRoom.margin + 1e-9)
    }

    /// 一次反射は必ず壁の上に乗る。乗っていなければ鏡像の計算が壊れている。
    func testFirstOrderReflectionsLandOnAWall() {
        let layout = ETVirtualRoom.layout(width: 5, depth: 4,
                                          listenerX: 50, listenerY: 35,
                                          angle: 30, distance: 1.8)
        XCTAssertFalse(layout.reflections.isEmpty)
        for hit in layout.reflections {
            let onSide = abs(Double(hit.x)) < 1e-6 || abs(Double(hit.x) - 5) < 1e-6
            let onFront = abs(Double(hit.y) - 4) < 1e-6
            XCTAssertTrue(onSide || onFront, "反射点 \(hit) がどの壁にも乗っていない")
        }
    }

    // MARK: - 図から戻す

    /// 掴んだスピーカーは角度と距離になる。**左右は区別しない**（§7）。
    func testGrabbingEitherSpeakerGivesTheSameAngle() {
        let listener = CGPoint(x: 2, y: 1)
        let left = ETVirtualRoom.speakerPolar(CGPoint(x: 1, y: 2), listener: listener)
        let right = ETVirtualRoom.speakerPolar(CGPoint(x: 3, y: 2), listener: listener)
        XCTAssertEqual(left.angle, 45, accuracy: 1e-6)
        XCTAssertEqual(right.angle, 45, accuracy: 1e-6)
        XCTAssertEqual(left.distance, right.distance, accuracy: 1e-9)
    }

    func testListenerPercentIsRelativeToTheRoom() {
        let p = ETVirtualRoom.listenerPercent(CGPoint(x: 2.1, y: 1.8),
                                              width: 4.2, depth: 3.6)
        XCTAssertEqual(p.x, 50, accuracy: 1e-6)
        XCTAssertEqual(p.y, 50, accuracy: 1e-6)
    }

    // MARK: - Routing の幅（§52）

    func testVirtualRoomOnlyAcceptsTwoChannelRoutings() {
        XCTAssertEqual(ETRoutingConstraint.channelWidth(of: ETVirtualRoom.type), 2)
        XCTAssertNil(ETRoutingConstraint.channelWidth(of: "VolumePlugin"))
        XCTAssertTrue(ETRoutingConstraint.allows(-1, width: 2))   // Stereo
        XCTAssertTrue(ETRoutingConstraint.allows(17, width: 2))   // 3/4 の組
        XCTAssertFalse(ETRoutingConstraint.allows(-2, width: 2))  // All
        XCTAssertFalse(ETRoutingConstraint.allows(0, width: 2))   // Left だけ
    }

    /// **いま入っている値は外れていても残す。**消すと Picker が別の値へ飛ぶ。
    func testAnOutOfSpecRoutingStaysVisible() {
        let all: [(Int8, String)] = [(-1, "Stereo"), (-2, "All"), (0, "Left"), (1, "Right")]
        let options = ETRoutingConstraint.options(all, type: ETVirtualRoom.type, current: 0)
        XCTAssertTrue(options.contains { $0.0 == 0 })
        XCTAssertFalse(options.contains { $0.0 == 1 })
    }

    // MARK: - 出荷時プリセット（§41）

    private func virtualRoom() throws -> ETEffect {
        try XCTUnwrap(ETCatalog.first { $0.type == ETVirtualRoom.type },
                      "catalog に Virtual Room が無い")
    }

    /// 書いた鍵が全部 catalog に在り、値が範囲と選択肢に収まっている。
    /// 生成物（ETEffectPresetList）を見る EffectPresetTests はこちらを見ないので、
    /// 同じ検査をここで持つ。
    func testDeckPresetsMatchTheCatalog() throws {
        let spec = try virtualRoom()
        let byKey = Dictionary(spec.params.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var bad: [String] = []

        for preset in ETVirtualRoomPresets.list {
            for (key, raw) in preset.params {
                guard let param = byKey[key] else {
                    bad.append("\(preset.presetId).\(key) は catalog に無い"); continue
                }
                guard let value = (raw as? NSNumber)?.floatValue else {
                    bad.append("\(preset.presetId).\(key) が数でない"); continue
                }
                switch param.kind {
                case .number(let lo, let hi, _, _, _):
                    if value < lo || value > hi {
                        bad.append("\(preset.presetId).\(key)=\(value) が \(lo)…\(hi) の外")
                    }
                case .enumeration(let options):
                    if Int(value) < 0 || Int(value) >= options.count {
                        bad.append("\(preset.presetId).\(key)=\(value) は選択肢の外")
                    }
                case .toggle:
                    break
                }
            }
        }
        XCTAssertEqual(bad, [])
    }

    /// 適用しても長さが変わらない。**et_instance_set_params は floatCount を
    /// 渡していて配列の長さを見ない**ので、短いものを作ると確保していない先を読む。
    func testDeckPresetsKeepTheirLength() throws {
        let spec = try virtualRoom()
        for preset in ETVirtualRoomPresets.list {
            let applied = EffectPresetApply.values(for: spec, params: preset.params,
                                                     current: spec.defaults)
            XCTAssertEqual(applied.count, spec.floatCount, preset.presetId)
        }
    }

    /// §41。5 本とも在り、id が重なっていない。
    func testDeckPresetsAreTheFiveTheDesignAsksFor() {
        let ids = ETVirtualRoomPresets.list.map(\.presetId)
        XCTAssertEqual(Set(ids).count, ids.count, "id が重なっている")
        XCTAssertEqual(Set(ids), ["nearfield-studio", "living-room", "dry-room",
                                  "large-room", "anechoic-speakers"])
    }

    /// §41。Anechoic Speakers は Room Amount 0%。
    /// **dry stereo には戻らない**ので、direct を消す設定にはしない。
    func testAnechoicPresetTurnsTheRoomOffButKeepsTheSpeakers() throws {
        let preset = try XCTUnwrap(ETVirtualRoomPresets.list
            .first { $0.presetId == "anechoic-speakers" })
        XCTAssertEqual((preset.params["rm"] as? NSNumber)?.floatValue, 0)
        XCTAssertNotNil(preset.params["sd"], "スピーカーの距離まで消してはいけない")
    }

    /// 出荷時プリセットは seed を書く。書かないと「同じ設定なら同じ部屋」が崩れる（§32）。
    func testDeckPresetsPinTheSeed() {
        for preset in ETVirtualRoomPresets.list {
            XCTAssertNotNil(preset.params["s0"], preset.presetId)
            XCTAssertNotNil(preset.params["s1"], preset.presetId)
        }
    }

    /// §13。modelVersion は必ず入る。入れないと、将来のカーネルが
    /// どの版で作られた設定か分からなくなる。
    func testDeckPresetsCarryTheModelVersion() {
        for preset in ETVirtualRoomPresets.list {
            XCTAssertEqual((preset.params["mv"] as? NSNumber)?.intValue, 1, preset.presetId)
        }
    }

    // MARK: - 保存形式と上流へ渡す形（§39）

    private func loaded(_ spec: ETEffect, inputBus: UInt8 = 0, outputBus: UInt8 = 0,
                        channelSpec: Int8 = -1) -> PipelineStore.Loaded {
        PipelineStore.Loaded(spec: spec, values: spec.defaults, enabled: true,
                             inputBus: inputBus, outputBus: outputBus, channelSpec: channelSpec)
    }

    /// 書くときは `ed` の印を付け、読むときは `nm` より先に印で引く。
    /// 名前が上流のものとぶつかっても Virtual Room へ戻る。
    func testShortFormCarriesTheMarkerAndReadsItBack() throws {
        let spec = try virtualRoom()
        var entry = try XCTUnwrap(PipelineStore.shortForm([loaded(spec)]).first)
        XCTAssertEqual(entry[ETDeckEffect.markerKey] as? String, ETVirtualRoom.type)
        entry["nm"] = "Volume"
        let back = PipelineStore.parse([entry], catalog: ETCatalog)
        XCTAssertEqual(back.map(\.spec.type), [ETVirtualRoom.type])
    }

    /// 上流のエフェクトには印を書かない。
    func testUpstreamEffectsGetNoMarker() throws {
        let volume = try XCTUnwrap(ETCatalog.first { $0.type == "VolumePlugin" })
        let entry = try XCTUnwrap(PipelineStore.shortForm([loaded(volume)]).first)
        XCTAssertNil(entry[ETDeckEffect.markerKey])
    }

    /// 貼られた鎖の下ごしらえも印を段の鍵として通し、ignored に出さない。
    func testChainTextKeepsTheMarkerQuietly() throws {
        let spec = try virtualRoom()
        let entry = try XCTUnwrap(PipelineStore.shortForm([loaded(spec)]).first)
        let data = try JSONSerialization.data(withJSONObject: [entry])
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let checked = ETShareLink.parseChecked(text, catalog: ETCatalog)
        XCTAssertEqual(checked.items.map(\.spec.type), [ETVirtualRoom.type])
        XCTAssertFalse(checked.report.ignored.contains { $0.hasSuffix(".\(ETDeckEffect.markerKey)") },
                       "\(checked.report.ignored)")
    }

    /// effetune.frieve.com へ渡す形では外部の段と同じ扱い。同じバスなら消え、
    /// バスを跨ぐなら素通しの Volume に替わる。名前も印も上流へ出さない。
    func testUpstreamLinkProjectsVirtualRoomOut() throws {
        let spec = try virtualRoom()
        XCTAssertTrue(ETShareLink.effeTuneForm([loaded(spec)]).isEmpty)
        let routed = ETShareLink.effeTuneForm([loaded(spec, inputBus: 1, outputBus: 2)])
        XCTAssertEqual(routed.count, 1)
        XCTAssertEqual(routed.first?["nm"] as? String, "Volume")
        XCTAssertNil(routed.first?[ETDeckEffect.markerKey])
    }

    /// PC の EffeTune へも名前のまま送らない（送ると鎖ごと断られる）。
    /// PC の一覧に無いことを食い違いとも言わない。
    func testRemoteProjectionReplacesVirtualRoom() throws {
        let spec = try virtualRoom()
        XCTAssertNil(ETRemoteProjection.entry(for: loaded(spec)))
        XCTAssertEqual(ETRemoteProjection.entry(for: loaded(spec, inputBus: 1, outputBus: 2))?["nm"] as? String,
                       "Volume")
        XCTAssertNil(ETRemoteProjection.params(for: loaded(spec)))
        XCTAssertFalse(ETRemoteHostInfo.localEffectNames.contains(spec.name))
        let host = ETRemoteHostInfo(state: ["app": "2.16.0", "effects": ["Volume"]])
        let projected = ETRemoteProjection.project([loaded(spec, inputBus: 1, outputBus: 2)], host: host)
        XCTAssertEqual(projected.remoteIndex, [0], "PC に無いからと落とさず、素通しで送る")
    }

    // MARK: - Speaker Layout（§64）

    private func values(surround: Bool) throws -> [Float] {
        let spec = try virtualRoom()
        var v = spec.defaults
        let p = try XCTUnwrap(spec.params.first { $0.key == ETVirtualRoom.Key.speakerLayout })
        v[p.offset] = surround ? 1 : 0
        return v
    }

    /// 既定は Stereo。Speaker Layout を足す前の短い配列も Stereo として読む。
    func testSpeakerLayoutDefaultsToStereo() throws {
        let spec = try virtualRoom()
        XCTAssertFalse(ETVirtualRoom.isSurround(spec.defaults))
        XCTAssertFalse(ETVirtualRoom.isSurround(Array(spec.defaults.prefix(24))))
        XCTAssertTrue(ETVirtualRoom.isSurround(try values(surround: true)))
        XCTAssertEqual(spec.floatCount, 25)
    }

    /// 5.1 は All だけ。Stereo は今までどおり Stereo か対だけ。
    func testSurroundLayoutOnlyAcceptsAll() throws {
        let surround = try values(surround: true)
        XCTAssertEqual(ETRoutingConstraint.channelWidth(of: ETVirtualRoom.type, values: surround), 6)
        XCTAssertTrue(ETRoutingConstraint.allows(-2, width: 6))
        XCTAssertFalse(ETRoutingConstraint.allows(-1, width: 6))
        XCTAssertFalse(ETRoutingConstraint.allows(16, width: 6))
        let type = ETVirtualRoom.type
        XCTAssertFalse(ETChainEditing.isChannelBypassed(type: type, channelSpec: -2, values: surround))
        XCTAssertTrue(ETChainEditing.isChannelBypassed(type: type, channelSpec: -1, values: surround))
        let stereo = try values(surround: false)
        XCTAssertTrue(ETChainEditing.isChannelBypassed(type: type, channelSpec: -2, values: stereo))
        XCTAssertFalse(ETChainEditing.isChannelBypassed(type: type, channelSpec: -1, values: stereo))
    }

    /// 鎖が host に求める幅。入れていて、Section で止められておらず、All に居る 5.1 だけが 6。
    func testOnlyALiveSurroundRoomWidensTheHost() throws {
        let spec = try virtualRoom()
        var node = ETChainNode(spec: spec, values: try values(surround: true))
        node.channelSpec = -2
        XCTAssertEqual(ETChainEditing.requiredChannels([node]), 6)
        var off = node
        off.enabled = false
        XCTAssertEqual(ETChainEditing.requiredChannels([off]), 2)
        var gated = node
        gated.sectionGate = 0
        XCTAssertEqual(ETChainEditing.requiredChannels([gated]), 2)
        var stereoRouted = node
        stereoRouted.channelSpec = -1
        XCTAssertEqual(ETChainEditing.requiredChannels([stereoRouted]), 2)
        var stereo = ETChainNode(spec: spec, values: try values(surround: false))
        stereo.channelSpec = -1
        XCTAssertEqual(ETChainEditing.requiredChannels([stereo]), 2)
        XCTAssertEqual(ETChainEditing.requiredChannels([stereo, node]), 6)
        XCTAssertEqual(ETChainEditing.requiredChannels([]), 2)
    }

    /// 5.1 を作るのは Spatial Mapper だけではない（docs/virtual-room-design.md §65）。
    /// 上流の決まり: Matrix は今ある本数の中で振り分けるだけで本数を増やさない
    /// （Vendor/effetune/docs/dsp/effects/matrix/index.md）。2→6 のような変換は Channel = All
    /// （Vendor/effetune/docs/faq.md §6）。Bus 1〜4 も Main と同じ幅で、engine は全部のバスを
    /// 同じ channel_count で回す（engine.cpp の processPipeline）。
    ///   - 5.1 の Virtual Room があれば、前に置いた Matrix / Multi Channel Panel / Bass Management /
    ///     Spatial Mapper（All）も 6 本を受ける。Virtual Room がどのバスに居ても同じ
    ///   - Virtual Room が無ければ、それらだけでは広げない（2ch の機器で上流と同じ 2 本）
    ///   - Stereo（既定）に置いた Matrix は 2 本しか受けない（上流と同じ。All にする）
    func testUpstreamProducersSeeTheWidthTheVirtualRoomAsks() throws {
        func node(_ type: String, channelSpec: Int8 = -2) throws -> ETChainNode {
            let spec = try XCTUnwrap(ETCatalog.first { $0.type == type }, type)
            var n = ETChainNode(spec: spec, values: spec.defaults)
            n.channelSpec = channelSpec
            return n
        }
        let producers = try ["MatrixPlugin", "MultiChannelPanelPlugin", "BassManagementPlugin",
                             "SpatialMapperPlugin"].map { try node($0) }
        var room = ETChainNode(spec: try virtualRoom(), values: try values(surround: true))
        room.channelSpec = -2

        XCTAssertEqual(ETChainEditing.requiredChannels(producers), 2)
        let width = ETChainEditing.requiredChannels(producers + [room])
        XCTAssertEqual(width, 6)
        let engine = ETAudioSessionRules.processingChannels(forOutputChannels: 2, requiredByChain: width)
        XCTAssertEqual(engine, 6)
        for p in producers {
            XCTAssertEqual(ETChannel.processedWidth(spec: p.channelSpec, engineChannels: engine), 6,
                           p.spec.type)
        }
        let stereoMatrix = try node("MatrixPlugin", channelSpec: -1)
        XCTAssertEqual(ETChannel.processedWidth(spec: stereoMatrix.channelSpec, engineChannels: engine), 2)

        // バスに置いた 5.1 の Virtual Room も幅を求める（Main → Bus 1 へ Matrix、Bus 1 → Main で畳む形）。
        for (input, output) in [(UInt8(1), UInt8(0)), (1, 1), (0, 2)] {
            var bussed = room
            bussed.inputBus = input
            bussed.outputBus = output
            XCTAssertEqual(ETChainEditing.requiredChannels(producers + [bussed]), 6, "\(input)→\(output)")
        }
    }

    /// Speaker Layout を変えたら Ch を合う所へ移す。合っていれば触らない。
    func testLayoutChangeMovesTheChannel() {
        XCTAssertEqual(ETRoutingConstraint.channelSpecAfterLayoutChange(surround: true, current: -1), -2)
        XCTAssertEqual(ETRoutingConstraint.channelSpecAfterLayoutChange(surround: true, current: 17), -2)
        XCTAssertNil(ETRoutingConstraint.channelSpecAfterLayoutChange(surround: true, current: -2))
        XCTAssertEqual(ETRoutingConstraint.channelSpecAfterLayoutChange(surround: false, current: -2), -1)
        XCTAssertNil(ETRoutingConstraint.channelSpecAfterLayoutChange(surround: false, current: 17))
    }

    /// 音量に追従するカードでも Speaker Layout は音量で切り替わらない（held）。
    /// 下のキーフレームを 5.1 にすると全キーフレームと鳴らす値（topValues）が 5.1 になり、
    /// EffeTuneDSP.storeKeyframe → settleSpeakerLayout と同じ順で Ch が All、host が 6ch になる。
    /// 前は補間で段を踏み、Ch も幅も動かないまま低い音量の所だけ 5.1 になって素通しだった。
    func testAutomatedSpeakerLayoutIsHeldAndWidensTheHost() throws {
        let spec = try virtualRoom()
        let p = try XCTUnwrap(spec.params.first { $0.key == ETVirtualRoom.Key.speakerLayout })
        XCTAssertEqual(ETAutomation.blend(of: p), .hold)
        XCTAssertTrue(ETAutomation.isAutomatable(spec))
        let stereo = try values(surround: false)
        var a = try XCTUnwrap(ETAutomation(source: .outputVolume,
                                           keyframes: [.init(position: 50, values: stereo),
                                                       .init(position: 100, values: stereo)],
                                           spec: spec))
        var node = ETChainNode(spec: spec, values: a.topValues)
        node.channelSpec = -1
        let previous = node.values
        a.store(try values(surround: true), at: 0, spec: spec)
        XCTAssertEqual(a.keyframes.map { ETVirtualRoom.isSurround($0.values) }, [true, true])
        node.automation = a
        node.values = a.topValues
        XCTAssertNotEqual(ETVirtualRoom.isSurround(node.values), ETVirtualRoom.isSurround(previous))
        node.channelSpec = try XCTUnwrap(ETRoutingConstraint.channelSpecAfterLayoutChange(
            surround: true, current: node.channelSpec))
        XCTAssertEqual(node.channelSpec, -2)
        XCTAssertEqual(ETChainEditing.requiredChannels([node]), 6)
        // 音量をどこへ動かしても 5.1 のまま。
        for position in [0.0, 50.0, 75.0, 100.0] {
            XCTAssertTrue(ETVirtualRoom.isSurround(a.values(at: position, spec: spec, current: node.values)),
                          "\(position)")
        }
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = Double(a.x - b.x)
        let dy = Double(a.y - b.y)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// 5.1 の図: C は正面、Ls / Rs は listener より後ろ。5 本とも同じ距離。
    func testSurroundLayoutPlacesFiveSpeakersOnOneCircle() {
        let l = ETVirtualRoom.layout(width: 4.2, depth: 3.6, listenerX: 50, listenerY: 36,
                                     angle: 30, distance: 1.8, surround: true)
        XCTAssertEqual(l.surround.count, 3)
        let points = [l.left, l.right] + l.surround
        for p in points {
            XCTAssertEqual(distance(p, l.listener), 1.8, accuracy: 1e-9)
        }
        XCTAssertEqual(l.surround[0].x, l.listener.x, accuracy: 1e-9)
        XCTAssertGreaterThan(l.surround[0].y, l.listener.y)
        XCTAssertLessThan(l.surround[1].y, l.listener.y)
        XCTAssertLessThan(l.surround[1].x, l.listener.x)
        XCTAssertGreaterThan(l.surround[2].x, l.listener.x)
        XCTAssertFalse(l.clamped)
        let stereo = ETVirtualRoom.layout(width: 4.2, depth: 3.6, listenerX: 50, listenerY: 36,
                                          angle: 30, distance: 1.8)
        XCTAssertTrue(stereo.surround.isEmpty)
    }

    /// 後ろが狭い部屋では Ls / Rs が後ろの壁に当たり、5 本とも同じだけ詰める。
    func testSurroundLayoutPullsEveryoneInWhenTheBackIsShort() {
        let l = ETVirtualRoom.layout(width: 6, depth: 6, listenerX: 50, listenerY: 10,
                                     angle: 30, distance: 2, surround: true)
        XCTAssertTrue(l.clamped)
        XCTAssertEqual(distance(l.left, l.listener), distance(l.surround[1], l.listener),
                       accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(l.surround[1].y, ETVirtualRoom.margin - 1e-9)
        // Stereo なら同じ部屋で詰めない。
        XCTAssertFalse(ETVirtualRoom.layout(width: 6, depth: 6, listenerX: 50, listenerY: 10,
                                            angle: 30, distance: 2).clamped)
    }

    /// 幅の合わない Ch に置いた段は descriptor で切って渡す（Bass Extender と同じ）。
    func testNarrowRoutingBypassesTheKernel() {
        let type = ETVirtualRoom.type
        XCTAssertFalse(ETChainEditing.isChannelBypassed(type: type, channelSpec: -1))
        XCTAssertFalse(ETChainEditing.isChannelBypassed(type: type, channelSpec: 16))
        XCTAssertTrue(ETChainEditing.isChannelBypassed(type: type, channelSpec: 0))
        XCTAssertTrue(ETChainEditing.isChannelBypassed(type: type, channelSpec: -2))
    }
}
