//  PipelineFormTests.swift
//  鎖を渡す形（ショート・ロング）へ書いて読み戻す（PipelineForm.swift）。
//
//  終端（rootReset）の往復は PipelineStoreTests が見ている。ここはそれ以外の形:
//    - カタログの全部がショートでもロングでも同じ値に戻る
//    - Section は `cm` を必ず書く（空でも）
//    - 既定の鎖の形（0→0、Stereo）は鍵ごと書かない
//    - バスの番号は 0…4 に寄せる（engine は 5 以上が 1 本でもあると鎖ごと拒む）
//    - 外部の段（AU / JSFX）の鍵が往復する
//    - 知らないエフェクトは落とす
//
//  書いたものは saveLast と同じく JSON のバイトにしてから読む（Bool と数の見分けを実物と同じにする）。

import XCTest

final class PipelineFormTests: XCTestCase {

    // MARK: - 道具

    private func item(_ spec: ETEffect, values: [Float]? = nil,
                      inputBus: UInt8 = 0, outputBus: UInt8 = 0,
                      channelSpec: Int8 = -1, enabled: Bool = true) -> PipelineStore.Loaded {
        PipelineStore.Loaded(spec: spec, values: values ?? spec.defaults, enabled: enabled,
                             inputBus: inputBus, outputBus: outputBus, channelSpec: channelSpec)
    }

    private func spec(_ type: String) throws -> ETEffect {
        try XCTUnwrap(ETCatalog.first { $0.type == type }, "カタログに無い: \(type)")
    }

    private func throughJSON(_ object: Any) throws -> Any {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try JSONSerialization.jsonObject(with: data)
    }

    private func parse(_ text: String) throws -> [PipelineStore.Loaded] {
        PipelineStore.parse(try JSONSerialization.jsonObject(with: Data(text.utf8)), catalog: ETCatalog)
    }

    /// 既定から外した値。数は上限（整数なら丸め）、許される値が決まっていればその最後、
    /// 選択肢は最後、入切は反対。
    private func altered(_ spec: ETEffect) -> [Float] {
        var v = spec.defaults
        for p in spec.params {
            // 保存形式に書かない実行時の旗（Tonal Balance EQ の mp）は往復しない。
            if p.runtimeOnly { continue }
            var value: Float
            switch p.kind {
            case .number(_, let hi, _, _, let isInteger):
                if let allowed = ETAllowedValues.upstream(type: spec.type, key: p.key), let last = allowed.last {
                    value = last
                } else {
                    value = isInteger ? hi.rounded() : hi
                }
            case .enumeration(let options):
                value = Float(max(0, options.count - 1))
            case .toggle:
                value = p.defaultValue >= 0.5 ? 0 : 1
            }
            // Tonal Balance EQ のシェルフ（ta の最後 = hs）の Q は 2 までに寄る。上限の 10 は戻らない。
            if spec.type == "TonalBalanceEQPlugin" && p.key == "qa" { value = 2 }
            for i in 0..<p.count where v.indices.contains(p.offset + i) {
                v[p.offset + i] = value
            }
        }
        return v
    }

    // MARK: - カタログの全部

    /// 既定の値が書くと丸められてしまう param（`型.key`）。**見つけたもので、直していない。**
    ///
    /// Multiband Expander の Release は上流の params.json で `"kind": "float", "step": 1`、既定が
    /// `[100, 87.5, 75, 62.5, 50]`。カタログは step 1 から整数（isInteger）と読むので、
    /// ETParamCoding.tidy が 87.5 → 88、62.5 → 63 と丸めて書く。上流の getParameters は 87.5 の
    /// まま書く（multiband_expander.js:994）。既定のまま保存・共有しただけで値が変わる。
    /// 直すのはカタログを作る側（Tools/gen_catalog.py の isInteger の読み方）。
    /// ここに無い param が丸められたら落ちる（版を上げて増えたときに気付くため）。
    private let knownRoundedDefaults: Set<String> = ["MultibandExpanderPlugin.rl"]

    /// 既定の値で、ショートとロングがどちらも同じ値に戻る。
    func testEveryCatalogEntryRoundTripsShortAndLong() throws {
        XCTAssertGreaterThan(ETCatalog.count, 100)
        var drift: [String] = []
        for spec in ETCatalog {
            let written = item(spec)
            let short = PipelineStore.parse(try throughJSON(PipelineStore.shortForm([written])),
                                            catalog: ETCatalog)
            let long = PipelineStore.parse(try throughJSON(PipelineStore.longForm([written])),
                                           catalog: ETCatalog)
            XCTAssertEqual(short.count, 1, spec.type)
            XCTAssertEqual(long.count, 1, spec.type)
            guard let s = short.first, let l = long.first else { continue }
            XCTAssertEqual(s.spec.type, spec.type)
            XCTAssertEqual(l.spec.type, spec.type)
            XCTAssertEqual(s.values, l.values, "\(spec.type) ショートとロングが違う")
            for p in spec.params {
                let range = p.offset..<min(p.offset + p.count, written.values.count)
                let changed = range.filter { s.values[$0] != written.values[$0] }
                guard !changed.isEmpty else { continue }
                let name = spec.type + "." + p.key
                // 許すのは「整数の param の端数の既定が丸められた」ことだけ。
                let rounded = changed.allSatisfy { s.values[$0] == written.values[$0].rounded() }
                if !(knownRoundedDefaults.contains(name) && rounded) {
                    drift.append("\(name): \(changed.map { "\(written.values[$0]) → \(s.values[$0])" })")
                }
            }
        }
        XCTAssertTrue(drift.isEmpty, drift.joined(separator: "\n"))
    }

    /// 既定から外した値でも同じ。ショートとロングは同じ値に読める。
    func testEveryCatalogEntryRoundTripsAlteredValues() throws {
        var failures: [String] = []
        for spec in ETCatalog {
            let written = item(spec, values: altered(spec))
            let short = PipelineStore.parse(try throughJSON(PipelineStore.shortForm([written])),
                                            catalog: ETCatalog)
            let long = PipelineStore.parse(try throughJSON(PipelineStore.longForm([written])),
                                           catalog: ETCatalog)
            guard let s = short.first, let l = long.first else {
                failures.append("\(spec.type): 落ちた")
                continue
            }
            if s.values != l.values { failures.append("\(spec.type): ショートとロングが違う") }
            let changed = written.values.indices.filter { s.values[$0] != written.values[$0] }
            if !changed.isEmpty {
                let keys = spec.params.filter { p in changed.contains { $0 >= p.offset && $0 < p.offset + p.count } }
                    .map(\.key)
                failures.append("\(spec.type): \(keys.joined(separator: ","))")
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    // MARK: - Section

    /// Section は `cm` を必ず書く。名前が空でも鍵ごと落とさない（上流の getParameters と同じ）。
    func testSectionAlwaysWritesComment() throws {
        for name in ["", "Drums", "低音"] {
            let section = PipelineStore.Loaded(spec: ETSection.spec, values: [], enabled: true,
                                               inputBus: 0, outputBus: 0, channelSpec: -1,
                                               sectionName: name)
            let short = PipelineStore.shortForm([section])
            XCTAssertEqual(short[0] as NSDictionary,
                           ["cm": name, "nm": "Section", "en": true] as NSDictionary)
            let long = try XCTUnwrap(PipelineStore.longForm([section])["pipeline"] as? [[String: Any]])
            XCTAssertEqual(long[0] as NSDictionary,
                           ["name": "Section", "enabled": true, "parameters": ["cm": name]] as NSDictionary)
            let back = PipelineStore.parse(try throughJSON(short), catalog: ETCatalog)
            XCTAssertEqual(back.first?.sectionName, name)
            XCTAssertEqual(back.first?.isRootReset, false, "印の無い空 Section は終端にしない")
        }
    }

    // MARK: - 鎖の形

    /// 既定（0→0、Stereo）は鍵ごと書かない。外れたものだけ書く。
    func testDefaultRoutingKeysAreLeftOut() throws {
        let volume = try spec("VolumePlugin")
        let plain = item(volume)
        let short = PipelineStore.shortForm([plain])[0]
        for key in ["ib", "ob", "ch"] { XCTAssertNil(short[key], key) }
        let long = try XCTUnwrap((PipelineStore.longForm([plain])["pipeline"] as? [[String: Any]])?.first)
        for key in ["inputBus", "outputBus", "channel"] { XCTAssertNil(long[key], key) }

        let routed = item(volume, inputBus: 1, outputBus: 2, channelSpec: 17)
        let s = PipelineStore.shortForm([routed])[0]
        XCTAssertEqual(s["ib"] as? Int, 1)
        XCTAssertEqual(s["ob"] as? Int, 2)
        XCTAssertEqual(s["ch"] as? String, "34")
        let l = try XCTUnwrap((PipelineStore.longForm([routed])["pipeline"] as? [[String: Any]])?.first)
        XCTAssertEqual(l["inputBus"] as? Int, 1)
        XCTAssertEqual(l["outputBus"] as? Int, 2)
        XCTAssertEqual(l["channel"] as? String, "34")

        for form in [try throughJSON(PipelineStore.shortForm([routed])),
                     try throughJSON(PipelineStore.longForm([routed]))] {
            let back = try XCTUnwrap(PipelineStore.parse(form, catalog: ETCatalog).first)
            XCTAssertEqual(back.inputBus, 1)
            XCTAssertEqual(back.outputBus, 2)
            XCTAssertEqual(back.channelSpec, 17)
        }
    }

    /// バスの番号は 0…4 に寄せる。数でないものは 0。
    func testBusNumbersClampToZeroThroughFour() throws {
        let short = try parse(#"[{"nm":"Volume","ib":7,"ob":-3},{"nm":"Volume","ib":"2","ob":4}]"#)
        XCTAssertEqual(short.map(\.inputBus), [4, 0])
        XCTAssertEqual(short.map(\.outputBus), [0, 4])
        let long = try parse(#"{"pipeline":[{"name":"Volume","inputBus":9,"outputBus":2,"parameters":{}}]}"#)
        XCTAssertEqual(long.map(\.inputBus), [4])
        XCTAssertEqual(long.map(\.outputBus), [2])
        let external = try parse(#"[{"nm":"My AU","external":"au:x","ib":200,"ob":5}]"#)
        XCTAssertEqual(external.map(\.inputBus), [4])
        XCTAssertEqual(external.map(\.outputBus), [4])
    }

    // MARK: - 外部の段

    /// 外部の段の鍵（external / externalInstance / externalState）と入切・鎖の形が往復する。
    func testExternalProcessorFieldsRoundTrip() throws {
        let state = Data([0, 1, 2, 250, 255])
        for (id, category) in [("au:aufx-abcd-efgh", "Audio Units"), ("jsfx:My Delay", "JSFX")] {
            let written = PipelineStore.Loaded(
                spec: ETEffect.external(type: "External:\(id)", name: "Mine", category: category),
                values: [], enabled: false, inputBus: 1, outputBus: 2, channelSpec: 0,
                externalID: id, externalInstanceID: "inst-1", externalState: state)
            let short = PipelineStore.shortForm([written])[0]
            XCTAssertEqual(short["external"] as? String, id)
            XCTAssertEqual(short["externalInstance"] as? String, "inst-1")
            XCTAssertEqual(short["externalState"] as? String, state.base64EncodedString())
            for form in [try throughJSON(PipelineStore.shortForm([written])),
                         try throughJSON(PipelineStore.longForm([written]))] {
                let back = try XCTUnwrap(PipelineStore.parse(form, catalog: ETCatalog).first)
                XCTAssertEqual(back.externalID, id)
                XCTAssertEqual(back.externalInstanceID, "inst-1")
                XCTAssertEqual(back.externalState, state)
                XCTAssertEqual(back.spec.type, "External:\(id)")
                XCTAssertEqual(back.spec.name, "Mine")
                XCTAssertEqual(back.spec.category, category)
                XCTAssertFalse(back.enabled)
                XCTAssertEqual(back.inputBus, 1)
                XCTAssertEqual(back.outputBus, 2)
                XCTAssertEqual(back.channelSpec, 0)
            }
        }
    }

    /// 状態を持たない外部の段は `externalState` を書かない。身元が無ければ読むときに作る。
    func testExternalWithoutStateOrInstance() throws {
        let written = PipelineStore.Loaded(
            spec: ETEffect.external(type: "External:au:x", name: "X", category: "Audio Units"),
            values: [], enabled: true, inputBus: 0, outputBus: 0, channelSpec: -1,
            externalID: "au:x", externalInstanceID: "i")
        XCTAssertNil(PipelineStore.shortForm([written])[0]["externalState"])
        let back = try parse(#"[{"nm":"X","external":"au:x"}]"#)
        XCTAssertEqual(back.count, 1)
        XCTAssertFalse(back[0].externalInstanceID.isEmpty)
        XCTAssertNil(back[0].externalState)
    }

    // MARK: - 知らないもの

    /// 知らないエフェクトは落とす。前後の段は残る。
    func testUnknownEffectsAreDropped() throws {
        let short = try parse(#"[{"nm":"Volume"},{"nm":"No Such Effect"},{"nm":"Delay"}]"#)
        XCTAssertEqual(short.map(\.spec.type), ["VolumePlugin", "DelayPlugin"])
        let long = try parse(#"{"pipeline":[{"name":"No Such Effect","parameters":{}},{"name":"Volume","parameters":{}}]}"#)
        XCTAssertEqual(long.map(\.spec.type), ["VolumePlugin"])
        XCTAssertTrue(try parse(#"{"nothing":[]}"#).isEmpty)
        XCTAssertTrue(try parse("[]").isEmpty)
    }
}
