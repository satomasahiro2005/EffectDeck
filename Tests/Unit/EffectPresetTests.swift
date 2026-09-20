//  EffectPresetTests.swift
//  エフェクト 1 個ぶんのプリセット。**実機もエンジンも要らない。**
//
//  見張るのは 3 つ。どれも静的に読んだだけでは取り違えたところ:
//    - 焼いた 131 件の鍵が catalog の ETParam に届いているか
//      （届かない鍵は decode が黙って飛ばすので、画面では既定のまま載る）
//    - 適用 → 一致判定が元の id を返すか（往復）
//    - Tube Simulator だけの規則（rl は Ω の数・sg は 0・ag は触らない）
//
//  ETParamCoding を測っている ParamCodingTests と同じで、本物の ETCatalog と
//  本物の ETEffectPresetList に対して測る。

import XCTest

final class EffectPresetTests: XCTestCase {

    private func spec(named name: String) throws -> ETEffect {
        try XCTUnwrap(ETCatalog.first { $0.name == name }, "\(name) が catalog に無い")
    }

    /// その ETEffect が保存形式で読める鍵の集合。
    /// ETParamCoding.decode が見る場所と同じ数え方
    /// （オブジェクト配列は外側の名前・添字付きは `f0 f1 …`）。
    private func readableKeys(of spec: ETEffect) -> Set<String> {
        var keys: Set<String> = []
        for p in spec.params {
            if p.isObjectMember, let group = p.objectArrayKey {
                keys.insert(group)
            } else if let key = p.flatArrayKey {
                keys.insert(key)
            } else if p.isArray {
                for i in 0..<p.count { keys.insert(p.key + String(i)) }
            } else {
                keys.insert(p.key)
            }
        }
        return keys
    }

    // MARK: - 焼いたもの

    /// プリセットを持つエフェクトは、全部 catalog に居ること。
    /// 表示名で引くので、上流が名前を変えたらここで落ちる。
    func testEveryEffectWithPresetsIsInTheCatalog() throws {
        let names = Set(ETEffectPresetList.map(\.effect))
        for name in names.sorted() {
            XCTAssertNotNil(ETCatalog.first { $0.name == name }, "\(name) が catalog に無い")
        }
        // 数が変わったら、上流を進めたということ。意図した変更か確かめる。
        XCTAssertEqual(names.count, 28)
        XCTAssertEqual(ETEffectPresetList.count, 146)
    }

    /// 131 件の params が全部読めて、鍵が catalog に届いていること。
    ///
    /// **落ちてよいのは Modal Resonator の `sr` だけ。**
    /// あれは選択中タブの添字で、音に効かないので params.json に無い。
    /// 上流も比較から外している（modal_resonator.js:30-32）。
    func testEveryPresetKeyReachesTheCatalog() throws {
        var unknown: [String] = []
        for preset in ETEffectPresetList {
            let s = try spec(named: preset.effect)
            let params = preset.params
            XCTAssertFalse(params.isEmpty, "\(preset.id) の json が読めない")
            let keys = readableKeys(of: s)
            for key in params.keys where !keys.contains(key) {
                unknown.append("\(preset.effect).\(preset.presetId).\(key)")
            }
        }
        XCTAssertEqual(unknown.sorted(), [
            "Modal Resonator.metal-can.sr",
            "Modal Resonator.plastic-enclosure.sr",
            "Modal Resonator.wooden-body.sr",
        ])
    }

    /// 文字列で書かれた値が、catalog の選択肢にあること（数の文字列なら数に読めること）。
    ///
    /// **往復テストでは捕まらない。** 綴りが 1 字違えば decode は既定へ落ちるが、
    /// 適用も一致判定も同じ decode を通るので、そこは不動点になって
    /// 「一致している」と出てしまう。選択肢の集合そのものを物差しにする。
    /// （Vinyl Simulator の `rp` は "33⅓"。こういうものが在る）
    func testEveryStringValueIsAKnownChoice() throws {
        var checked = 0
        var bad: [String] = []

        func walk(_ dict: [String: Any], _ params: [ETParam], _ label: String) {
            for (key, value) in dict {
                // オブジェクト配列は中へ降りる。鍵は member の名前になる。
                if let rows = value as? [[String: Any]] {
                    for row in rows { walk(row, params, label) }
                    continue
                }
                guard let text = value as? String,
                      let p = params.first(where: { $0.key == key || $0.memberKey == key })
                else { continue }
                checked += 1
                if case .enumeration(let options) = p.kind {
                    if !options.contains(text) {
                        bad.append("\(label).\(key)=\(text) は選択肢に無い \(options)")
                    }
                } else if Float(text) == nil {
                    bad.append("\(label).\(key)=\(text) は数に読めない")
                }
            }
        }

        for preset in ETEffectPresetList {
            let s = try spec(named: preset.effect)
            walk(preset.params, s.params, preset.id)
        }
        XCTAssertEqual(bad, [])
        // **数を留める。**上の `bad` が空でも、数えた口が減っていれば
        // 見ていないものが増えたということ。416 → 449 は EffeTune 2.10.0 で
        // 効果が 3 本増えたぶん（Pitch Meter / Spatial Mapper / TV Audio Simulator）。
        XCTAssertEqual(checked, 449, "数えた文字列の数が変わった")
    }

    // MARK: - 適用

    /// 長さを変えないこと。**et_instance_set_params は floatCount を渡していて
    /// 配列の長さを見ない**ので、短いものを作ると確保していない先を読ませる。
    func testAppliedValuesKeepTheirLength() throws {
        for preset in ETEffectPresetList {
            let s = try spec(named: preset.effect)
            let out = EffectPresetApply.values(for: s, params: preset.params,
                                               current: s.defaults)
            XCTAssertEqual(out.count, s.defaults.count, preset.id)
            XCTAssertEqual(out.count, s.floatCount, preset.id)
        }
    }

    /// 書かれていない鍵は**今の値のまま**。既定へ戻さない。
    /// 上流の setParameters は `if (params.xx !== undefined)` で書くので
    /// 触れられていないものは残る（power_amp_sag.js:372-395）。
    func testUnwrittenKeysKeepTheCurrentValue() throws {
        let s = try spec(named: "Power Amp Sag")
        let ss = try XCTUnwrap(s.params.first { $0.key == "ss" })
        let ps = try XCTUnwrap(s.params.first { $0.key == "ps" })

        var current = s.defaults
        current[ps.offset] = ps.defaultValue + 7   // 既定から離しておく

        // 9.0 は ss の既定（3.0）とは別の数。既定と同じ数で測ると、
        // 何も書かれていなくても通ってしまう。
        let out = EffectPresetApply.values(for: s, params: ["ss": 9.0], current: current)
        XCTAssertEqual(out[ss.offset], 9.0)
        XCTAssertEqual(out[ps.offset], current[ps.offset], "書いていない ps が動いた")
        XCTAssertNotEqual(current[ps.offset], ps.defaultValue, "測れていない")
    }

    /// 適用したあと、一致判定が元の id を返すこと（131 件）。
    func testEveryPresetRoundTrips() throws {
        for preset in ETEffectPresetList {
            let s = try spec(named: preset.effect)
            let applied = EffectPresetApply.values(for: s, params: preset.params,
                                                   current: s.defaults)
            XCTAssertEqual(EffectPresetApply.matchingPresetId(for: s, current: applied),
                           preset.presetId, "\(preset.id) が往復しない")
        }
    }

    // MARK: - Tube Simulator

    /// 新しく足した Tube Simulator は、最初からピン留めのプリセットに一致する。
    ///
    /// 上流は params.json の既定を `listening-power-el84-pentode-thd2` に
    /// 合わせてピン留めしている（tube_simulator.js:308-313 の PINNED 注記。
    /// 「fresh instance opens on this preset instead of Custom」）。
    /// catalog の defaults がそこからずれたらここで落ちる。
    func testTubeSimulatorDefaultsMatchThePinnedPreset() throws {
        let s = try spec(named: "Tube Simulator")
        XCTAssertEqual(EffectPresetApply.matchingPresetId(for: s, current: s.defaults),
                       "listening-power-el84-pentode-thd2")
    }

    /// `rl`（Actual Speaker Load）は **Ω の数**。enum の添字ではない。
    ///
    /// 上流は `rl: Number(preset.params.sl ?? this.sl)`（tube_simulator.js:6132）。
    /// `sl` の保存値は "15" という文字列で、catalog では選択肢の添字 2。
    /// decode の結果をそのまま入れると 15Ω が 2Ω になる。
    func testTubeSimulatorSpeakerLoadIsOhmsNotAnIndex() throws {
        let s = try spec(named: "Tube Simulator")
        let sl = try XCTUnwrap(s.params.first { $0.key == "sl" })
        let rl = try XCTUnwrap(s.params.first { $0.key == "rl" })

        // 既定は sl が "15"・rl が 15 で、そこだと添字と Ω を取り違えても
        // 同じ数になってしまう。8Ω に動かして測る。
        let out = EffectPresetApply.values(for: s, params: ["sl": "8"], current: s.defaults)
        XCTAssertEqual(out[sl.offset], 1, "sl は選択肢の添字（\"8\" は 2 番目）")
        XCTAssertEqual(out[rl.offset], 8, "rl に添字が入っている")

        // 焼いてある 35 件でも同じこと。sl が書いてあるなら rl はその数。
        for preset in ETEffectPresetList where preset.effect == "Tube Simulator" {
            guard let text = preset.params["sl"] as? String,
                  let ohms = Float(text) else {
                XCTFail("\(preset.presetId) が sl を文字列で持っていない")
                continue
            }
            let applied = EffectPresetApply.values(for: s, params: preset.params,
                                                   current: s.defaults)
            XCTAssertEqual(applied[rl.offset], ohms, preset.presetId)
        }
    }

    /// `sg`（安全減衰）は 0 に落とし、`ag` は触らない。
    /// プリセットは回路の記述であって保護設定ではない（tube_simulator.js:6117-6123）。
    /// 一致判定からも `sg` を外す。外さないと、減衰が一度でも効いた瞬間に
    /// どのプリセットにも一致しなくなる（:6142-6148）。
    func testTubeSimulatorClearsSafetyTrimAndKeepsAutoGain() throws {
        let s = try spec(named: "Tube Simulator")
        let sg = try XCTUnwrap(s.params.first { $0.key == "sg" })
        let ag = try XCTUnwrap(s.params.first { $0.key == "ag" })
        let preset = try XCTUnwrap(ETEffectPresetList.first {
            $0.effect == "Tube Simulator" && $0.presetId == "listening-line-12at7-thd0p01"
        })

        var current = s.defaults
        current[sg.offset] = -6          // 減衰が効いている
        current[ag.offset] = 0           // 自動減衰を切ってある

        let out = EffectPresetApply.values(for: s, params: preset.params, current: current)
        XCTAssertEqual(out[sg.offset], 0, "sg を 0 に落としていない")
        XCTAssertEqual(out[ag.offset], 0, "ag を書き換えている")

        // 減衰が残っていても一致は変わらない。
        var trimmed = out
        trimmed[sg.offset] = -3
        XCTAssertEqual(EffectPresetApply.matchingPresetId(for: s, current: trimmed),
                       preset.presetId)
        XCTAssertEqual(EffectPresetApply.excludedOffsets(for: s), [sg.offset])
    }

    /// 一致判定から外すのは Tube Simulator の `sg` だけ。
    func testOnlyTubeSimulatorExcludesAnOffset() {
        var excluding: [String] = []
        for s in ETCatalog where !EffectPresetApply.excludedOffsets(for: s).isEmpty {
            excluding.append(s.type)
        }
        XCTAssertEqual(excluding, ["TubeSimulatorPlugin"])
    }
}
