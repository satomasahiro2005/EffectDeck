//  VirtualRoomTests.swift
//  Virtual Room のうち、音にも画面にも触らない部分だけ。
//
//  見るのは 3 つ。
//    - §12 の seed の割り方（Float32 に 32bit 整数を載せる）
//    - §53 の「壁の外へ出さない」配置
//    - §41 の出荷時プリセットが catalog と食い違っていないこと
//
//  図の描画と DSP はここでは見ない（前者は画面、後者は実機）。

import CoreGraphics
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
}
