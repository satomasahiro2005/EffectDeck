//  BackupTests.swift
//  鎖とプリセットのファイル（ETBackupFormat.swift）。
//
//  書き出したものを web 版の EffeTune がそのまま開けること（上流の綴りと包み方）、
//  読むときに理由を取り違えないこと、読めなかった要素を数えて返すことを見る。
//  壊れると、バックアップからプリセットが消えるか、web で開けないファイルになる。

import XCTest

final class BackupTests: XCTestCase {

    // MARK: - 道具

    private func spec(_ type: String) throws -> ETEffect {
        try XCTUnwrap(ETCatalog.first { $0.type == type }, "カタログに無い: \(type)")
    }

    private func loaded(_ type: String) throws -> PipelineStore.Loaded {
        let spec = try spec(type)
        return PipelineStore.Loaded(spec: spec, values: spec.defaults, enabled: true,
                                    inputBus: 0, outputBus: 0, channelSpec: -1)
    }

    private func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private func read(_ object: Any) throws -> Result<ETBackup.Contents, ETBackup.Failure> {
        ETBackup.read(try json(object), catalog: ETCatalog)
    }

    private func failure(_ result: Result<ETBackup.Contents, ETBackup.Failure>) -> ETBackup.Failure? {
        if case .failure(let f) = result { return f }
        return nil
    }

    private func contents(_ result: Result<ETBackup.Contents, ETBackup.Failure>,
                          file: StaticString = #filePath, line: UInt = #line) throws -> ETBackup.Contents {
        switch result {
        case .success(let c): return c
        case .failure(let f):
            XCTFail("読めなかった: \(f)", file: file, line: line)
            throw f
        }
    }

    /// 比べるための字。鍵を並べた JSON にする（数の型の違いを均す）。
    private func canonical(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - 書く

    /// 名前を付けた鎖は上流の包み（`effetune_presets.<名前>.plugins`）で書く
    /// （preset-manager.js:216）。こちらの入れ物は生の配列なので、書くときに被せる。
    func testDataWrapsEffetunePresetsPlugins() throws {
        let volume = PipelineStore.shortForm([try loaded("VolumePlugin")])
        let data = try XCTUnwrap(ETBackup.data(chain: [],
                                              presets: ["Mine": volume],
                                              effectPresets: ["Volume": ["warm": ["vl": 1.0]]]))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(Set(root.keys), [ETBackup.presetsKey, ETBackup.effectPresetsKey],
                       "鎖が空なら pipeline は書かない")
        let wrapped = try XCTUnwrap((root[ETBackup.presetsKey] as? [String: Any])?["Mine"] as? [String: Any])
        XCTAssertEqual(Set(wrapped.keys), [ETBackup.pluginsKey])
        XCTAssertEqual(try canonical(try XCTUnwrap(wrapped[ETBackup.pluginsKey])), try canonical(volume))

        let effect = (root[ETBackup.effectPresetsKey] as? [String: Any])?["Volume"] as? [String: Any]
        XCTAssertEqual((effect?["warm"] as? [String: Any])?["vl"] as? Double, 1.0)
    }

    /// 鎖は上流の `.effetune_preset` と同じロング形式（`pipeline`）。
    func testDataWritesChainLongForm() throws {
        let chain = [try loaded("VolumePlugin")]
        let data = try XCTUnwrap(ETBackup.data(chain: chain, presets: [:], effectPresets: [:]))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(Set(root.keys), [ETBackup.pipelineKey])
        let first = try XCTUnwrap((root[ETBackup.pipelineKey] as? [[String: Any]])?.first)
        XCTAssertEqual(first["name"] as? String, "Volume")
        XCTAssertNotNil(first["parameters"] as? [String: Any])
    }

    func testDataNilWhenNothingToWrite() {
        XCTAssertNil(ETBackup.data(chain: [], presets: [:], effectPresets: [:]))
    }

    // MARK: - 読む

    /// 理由は notJSON → notBackup → noEffects → nothingUsable の順で決まる。
    func testReadErrorOrder() throws {
        // JSON でない。
        XCTAssertEqual(failure(ETBackup.read(Data("not json".utf8), catalog: ETCatalog)), .notJSON)
        XCTAssertEqual(failure(ETBackup.read(Data(), catalog: ETCatalog)), .notJSON)

        // JSON だがこの形ではない。
        XCTAssertEqual(failure(try read([String: Any]())), .notBackup)
        XCTAssertEqual(failure(try read([Any]())), .notBackup)
        XCTAssertEqual(failure(try read(["unrelated": 1])), .notBackup)
        XCTAssertEqual(failure(try read([1, 2])), .notBackup)
        XCTAssertEqual(failure(try read([ETBackup.pipelineKey: 5])), .notBackup)
        XCTAssertEqual(failure(try read([ETBackup.presetsKey: [1]])), .notBackup)
        XCTAssertEqual(failure(try read([ETBackup.effectPresetsKey: "x"])), .notBackup)

        // 鎖は載っているが、こちらに在るエフェクトが 1 つも無い。
        XCTAssertEqual(failure(try read([["nm": "No Such Effect"]])), .noEffects)
        XCTAssertEqual(failure(try read([ETBackup.pipelineKey: [["name": "No Such Effect"]]])), .noEffects)
        // 鎖で断るのが先。後ろのプリセットが読めなくても noEffects。
        XCTAssertEqual(failure(try read([ETBackup.pipelineKey: [["nm": "No Such Effect"]],
                                         ETBackup.presetsKey: ["x": 5]])), .noEffects)

        // 形は合っているが、読めた中身が 1 つも残らない。
        XCTAssertEqual(failure(try read([ETBackup.presetsKey: ["x": 5]])), .nothingUsable)
        XCTAssertEqual(failure(try read([ETBackup.effectPresetsKey: ["Volume": ["a": 5]]])), .nothingUsable)
    }

    /// 形が崩れた鍵が 1 つでもあれば、他が読めても notBackup（途中まで読めたもので潰さない）。
    func testMalformedSectionRejectsWholeFile() throws {
        let volume = PipelineStore.shortForm([try loaded("VolumePlugin")])
        XCTAssertEqual(failure(try read([ETBackup.pipelineKey: volume, ETBackup.presetsKey: 5])), .notBackup)
    }

    /// 根が配列（鎖だけ、上流の古い形・共有リンクの中身）、根に `plugins`（上流の 1 本）、
    /// ロング形式のプリセット（ショート形式へ直して入れる）を受ける。
    func testAcceptsRootArrayRootPluginsLongForm() throws {
        let volume = PipelineStore.shortForm([try loaded("VolumePlugin")])

        let bare = try contents(try read(volume + [["nm": "No Such Effect"]]))
        XCTAssertEqual(bare.chain.map(\.spec.type), ["VolumePlugin"])
        XCTAssertEqual(bare.chainDropped, 1)

        let plugins = try contents(try read([ETBackup.pluginsKey: volume]))
        XCTAssertEqual(plugins.chain.map(\.spec.type), ["VolumePlugin"])
        XCTAssertEqual(plugins.chainDropped, 0)

        let long = PipelineStore.longForm([try loaded("VolumePlugin")])
        let presets = try contents(try read([ETBackup.presetsKey: [
            "Long": long,
            "Wrapped": [ETBackup.pluginsKey: volume],
            "Bare": volume,
        ]]))
        XCTAssertEqual(Set(presets.presets.keys), ["Long", "Wrapped", "Bare"])
        // ロング形式は nm を持つショート形式に直っている（上流の読み手は nm しか見ない）。
        let converted = try XCTUnwrap(presets.presets["Long"]?.first)
        XCTAssertEqual(converted["nm"] as? String, "Volume")
        XCTAssertNil(converted["name"])
        XCTAssertEqual(try canonical(try XCTUnwrap(presets.presets["Long"])), try canonical(volume))
        XCTAssertEqual(presets.skipped, 0)
    }

    /// JSON の null は plist に入らない。読めない要素は飛ばして数え、残りは入れる。
    func testNullSkippedAndCounted() throws {
        let volume = PipelineStore.shortForm([try loaded("VolumePlugin")])
        var nulled = volume
        nulled[0]["extra"] = NSNull()

        let c = try contents(try read([
            ETBackup.presetsKey: [
                "Good": [ETBackup.pluginsKey: volume],
                "Null": [ETBackup.pluginsKey: nulled],
                "Unknown": [ETBackup.pluginsKey: [["nm": "No Such Effect"]]],
                "Scalar": 5,
            ],
            ETBackup.effectPresetsKey: [
                "Volume": ["ok": ["vl": 1.0], "null": ["vl": NSNull()], "scalar": 3],
                "Broken": 7,
            ],
        ]))

        XCTAssertEqual(Set(c.presets.keys), ["Good"])
        XCTAssertEqual(Set(c.effectPresets.keys), ["Volume"])
        XCTAssertEqual(Set(c.effectPresets["Volume"]?.keys.map { $0 } ?? []), ["ok"])
        XCTAssertEqual(c.effectPresetCount, 1)
        // プリセット 3（Null・Unknown・Scalar）＋エフェクトのプリセット 3（null・scalar・Broken）。
        XCTAssertEqual(c.skipped, 6)
        // 入れるものは全部 plist に載る（UserDefaults へ書いて落ちない）。
        XCTAssertTrue(PropertyListSerialization.propertyList(c.presets, isValidFor: .binary))
        XCTAssertTrue(PropertyListSerialization.propertyList(c.effectPresets, isValidFor: .binary))
    }

    /// 書き出して読み戻すと同じものが返る。
    func testExportImportIdentity() throws {
        let section = PipelineStore.Loaded(spec: ETSection.spec, values: [], enabled: true,
                                           inputBus: 0, outputBus: 0, channelSpec: -1, sectionName: "Drums")
        var routed = try loaded("DelayPlugin")
        routed.inputBus = 1
        routed.outputBus = 2
        routed.channelSpec = 0
        let chain = [section, try loaded("VolumePlugin"), routed]
        let presets: [String: Any] = [
            "Folder/One": PipelineStore.shortForm([try loaded("VolumePlugin")]),
            "Two": PipelineStore.shortForm([section, try loaded("DelayPlugin")]),
        ]
        let effectPresets: [String: Any] = [
            "Volume": ["warm": ["vl": -3.0], "hot": ["vl": 2.0]],
            "Delay": ["long": ["dt": 500.0]],
        ]

        let data = try XCTUnwrap(ETBackup.data(chain: chain, presets: presets, effectPresets: effectPresets))
        let back = try contents(ETBackup.read(data, catalog: ETCatalog))

        XCTAssertEqual(try canonical(PipelineStore.shortForm(back.chain)),
                       try canonical(PipelineStore.shortForm(chain)))
        XCTAssertEqual(back.chainDropped, 0)
        XCTAssertEqual(try canonical(back.presets), try canonical(presets))
        XCTAssertEqual(try canonical(back.effectPresets), try canonical(effectPresets))
        XCTAssertEqual(back.skipped, 0)

        // 2 周目も同じ字になる（読んだものをそのまま書き戻して変わらない）。
        let again = try XCTUnwrap(ETBackup.data(chain: back.chain, presets: back.presets,
                                                effectPresets: back.effectPresets))
        XCTAssertEqual(again, data)
    }
}
