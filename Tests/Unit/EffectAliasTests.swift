//  EffectAliasTests.swift
//  2.17.0 の SFZ Note Player → SoundFont Note Player の改名（ETEffectAliases）。**Foundation だけ。**
//
//  壊れると: 旧い名前の鎖・共有リンク・バックアップが読めず段が消える、保存してあったカードごとのプリセットが
//  見えなくなる、2.16.0 までの PC に新しい名前の段を送って鎖ごと断られる、
//  2.16.0 までの PC なのに「SFZ が無い」と食い違いに出る。

import XCTest

final class EffectAliasTests: XCTestCase {

    private let sfzType = "SFZNotePlayerPlugin"
    private let oldName = "SFZ Note Player"
    private let newName = "SoundFont Note Player"
    private let bank = "68c841b111e6a7a1d174ec98"

    private func sfz() throws -> ETEffect {
        try XCTUnwrap(ETCatalog.first { $0.type == sfzType })
    }

    private func loaded(_ spec: ETEffect) -> PipelineStore.Loaded {
        PipelineStore.Loaded(spec: spec, values: spec.defaults, enabled: true,
                             inputBus: 0, outputBus: 0, channelSpec: -1)
    }

    // MARK: 表

    func testTableAgreesWithTheCatalog() throws {
        XCTAssertEqual(try sfz().name, newName)
        XCTAssertEqual(ETEffectAliases.type(forLegacyName: oldName), sfzType)
        XCTAssertNil(ETEffectAliases.type(forLegacyName: newName))
        XCTAssertEqual(ETEffectAliases.legacyName(forType: sfzType), oldName)
        XCTAssertEqual(ETEffectAliases.legacyName(forCurrentName: newName), oldName)
        XCTAssertNil(ETEffectAliases.legacyName(forCurrentName: "Volume"))
        XCTAssertEqual(ETEffectAliases.current(oldName), newName)
        XCTAssertEqual(ETEffectAliases.current(newName), newName)
        XCTAssertEqual(ETEffectAliases.current("Volume"), "Volume")
        // 旧い名前がいまの表示名と重ならない（重なると読み分けられない）。
        for rename in ETEffectAliases.renames {
            XCTAssertFalse(ETCatalog.contains { $0.name == rename.legacyName }, rename.legacyName)
            XCTAssertNotNil(ETCatalog.first { $0.type == rename.type }, rename.type)
        }
    }

    func testVersionOrder() {
        XCTAssertTrue(ETEffectAliases.isBefore("0.16.0", "0.17.0"))
        XCTAssertTrue(ETEffectAliases.isBefore("0.9.5", "0.17.0"))
        XCTAssertFalse(ETEffectAliases.isBefore("0.17.0", "0.17.0"))
        XCTAssertFalse(ETEffectAliases.isBefore("0.17.1", "0.17.0"))
        XCTAssertFalse(ETEffectAliases.isBefore("0.17", "0.17.0"))
        XCTAssertFalse(ETEffectAliases.isBefore("unknown", "0.17.0"), "読めない版は旧いと見ない")
    }

    // MARK: 鎖を読む

    func testLegacyNameLoadsAsTheSameEffectWithTheSameBank() throws {
        let short = PipelineStore.parse([["nm": oldName, "sf": bank, "en": true]], catalog: ETCatalog)
        XCTAssertEqual(short.count, 1)
        XCTAssertEqual(short[0].spec.type, sfzType)
        XCTAssertEqual(short[0].irId, bank)
        let long = PipelineStore.parse(["pipeline": [["name": oldName, "enabled": true,
                                                       "parameters": ["sf": bank]]]], catalog: ETCatalog)
        XCTAssertEqual(long.count, 1)
        XCTAssertEqual(long[0].irId, bank)
        // 書き戻すのは新しい名前。
        XCTAssertEqual(PipelineStore.shortForm(short)[0]["nm"] as? String, newName)
        XCTAssertEqual(PipelineStore.shortForm(short)[0]["sf"] as? String, bank)
    }

    func testChainTextPrepareFindsTheLegacyName() throws {
        let json: [[String: Any]] = [["nm": oldName, "sf": bank], ["nm": "sfz note player"]]
        let result = ETChainText.prepare(json, catalog: ETCatalog)
        XCTAssertEqual(result.report.notFound, [])
        let list = try XCTUnwrap(result.json as? [[String: Any]])
        XCTAssertEqual(list.count, 2)
        let loaded = PipelineStore.parse(list, catalog: ETCatalog)
        XCTAssertEqual(loaded.map(\.spec.type), [sfzType, sfzType])
        XCTAssertEqual(loaded[0].irId, bank)
    }

    // MARK: カードごとのプリセット

    private final class Patches { var paths: [[[String]]] = [] }

    private func fixture(_ initial: [String: Any]) -> (core: EffectPresetStoreCore, device: ETMemoryStorage,
                                                       cloud: ETMemoryStorage, patches: Patches) {
        let device = ETMemoryStorage()
        let cloud = ETMemoryStorage()
        device.set(initial, forKey: EffectPresetStoreCore.key)
        let mirror = CloudMirrorCore(cloud: cloud, seeded: false)
        let patches = Patches()
        let core = EffectPresetStoreCore(storage: device, patch: { key, changes in
            patches.paths.append(changes.map(\.path))
            mirror.patch(key: key, changes: changes)
        })
        return (core, device, cloud, patches)
    }

    func testPresetKeysMoveWithOnePatchAndTheNewNameWinsACollision() throws {
        let f = fixture([
            oldName: ["Bright": ["ss": 1.0], "Dark": ["ss": 2.0]],
            newName: ["Bright": ["ss": 9.0]],
            "Volume": ["Loud": ["vl": 3.0]],
        ])
        // 旧い入れ物は iCloud にも在る（別の端末が 2.16.0 で書いたもの）。
        f.cloud.set([oldName: ["Bright": ["ss": 1.0], "Dark": ["ss": 2.0]]], forKey: EffectPresetStoreCore.key)

        XCTAssertEqual(f.core.migrateLegacyNames(), 1, "移したのは Dark だけ（Bright はいまの名前の側が残る）")
        XCTAssertEqual(f.patches.paths.count, 1, "iCloud への patch は 1 回")

        let device = f.device.dictionary(forKey: EffectPresetStoreCore.key) ?? [:]
        XCTAssertNil(device[oldName])
        let mine = try XCTUnwrap(device[newName] as? [String: Any])
        XCTAssertEqual(Set(mine.keys), ["Bright", "Dark"])
        XCTAssertEqual(((mine["Bright"] as? [String: Any])?["ss"] as? NSNumber)?.doubleValue, 9)
        XCTAssertEqual(((mine["Dark"] as? [String: Any])?["ss"] as? NSNumber)?.doubleValue, 2)
        XCTAssertNotNil(device["Volume"], "ほかの効果は触らない")
        XCTAssertEqual(f.core.saved[newName], ["Bright", "Dark"])

        let cloud = f.cloud.dictionary(forKey: EffectPresetStoreCore.key) ?? [:]
        XCTAssertNil(cloud[oldName], "iCloud の旧い鍵も消える")
        let cloudMine = (cloud[newName] as? [String: Any]) ?? [:]
        XCTAssertEqual(Set(cloudMine.keys), ["Dark"],
                       "iCloud へは移した分だけ（いまの名前の Bright は元から写してある）")
    }

    func testPresetMigrationIsOneTimeAndQuietWhenThereIsNothing() {
        let f = fixture([oldName: ["A": ["ss": 1.0]]])
        XCTAssertEqual(f.core.migrateLegacyNames(), 1)
        XCTAssertEqual(f.patches.paths.count, 1)
        XCTAssertEqual(f.core.migrateLegacyNames(), 0)
        XCTAssertEqual(f.patches.paths.count, 1, "2 回目は何も当てない")
        let none = fixture([:])
        XCTAssertEqual(none.core.migrateLegacyNames(), 0)
        XCTAssertEqual(none.patches.paths.count, 0)
    }

    func testBackupMergeFilesLegacyKeyUnderTheCurrentName() {
        let f = fixture([:])
        XCTAssertEqual(f.core.merge([oldName: ["A": ["ss": 1.0]]]), 1)
        XCTAssertEqual(f.core.saved, [newName: ["A"]])
    }

    func testBackupMergeTrimsLegacyKeyAndCurrentNameWinsWhenBothInFile() {
        let f = fixture([:])
        XCTAssertEqual(f.core.merge([" \(oldName) ": ["A": ["ss": 1.0]]]), 1)
        XCTAssertEqual(f.core.saved, [newName: ["A"]])
        for _ in 0..<20 {
            let g = fixture([:])
            g.core.merge([oldName: ["A": ["ss": 1.0]], newName: ["A": ["ss": 2.0]]])
            let mine = (g.core.exported()[newName] as? [String: Any]) ?? [:]
            let a = mine["A"] as? [String: Any]
            XCTAssertEqual(a?["ss"] as? Double, 2.0, "同じ名前が両方に在るときはいまの名前の側")
        }
    }

    // MARK: PC の効果の一覧

    private func official(app: String = "2.16.0", dsp: String? = nil, effects: [String]?) -> ETRemoteHostInfo {
        var state: [String: Any] = ["app": app, "appName": "EffeTune",
                                    "features": ["origin", "savePreset", "irSync", "sync1"]]
        if let dsp { state["dsp"] = dsp }
        if let effects { state["effects"] = effects }
        return ETRemoteHostInfo(state: state)
    }

    /// 2.16.0 の PC の一覧: SFZ は旧い名前で、SoundFont Player は無い。
    private var effects216: [String] {
        ETRemoteHostInfo.localEffectNames.filter { $0 != "SoundFont Player" }.map { $0 == newName ? oldName : $0 }
    }

    func testOldHostThatNamesSFZTheOldWayLacksNothingOfIt() throws {
        let host = official(effects: effects216)
        XCTAssertFalse(host.lacks(newName))
        XCTAssertTrue(host.lacks("SoundFont Player"))
        let m = try XCTUnwrap(host.mismatch(localDSP: ETUpstreamVersion,
                                            localEffects: ETRemoteHostInfo.localEffectNames,
                                            localApp: "2.17.0"))
        XCTAssertEqual(m.missingOnHost, ["SoundFont Player"])
        XCTAssertEqual(m.missingHere, [], "PC の SFZ Note Player を「手元に無い」と言わない")
        // 旧い名前だけが違う一覧は食い違いに出ない。
        let same = official(app: "2.17.0",
                            effects: ETRemoteHostInfo.localEffectNames.map { $0 == newName ? oldName : $0 })
        XCTAssertNil(same.mismatch(localDSP: ETUpstreamVersion, localEffects: ETRemoteHostInfo.localEffectNames,
                                   localApp: "2.17.0"))
    }

    func testHostWithNeitherNameStillLacksIt() {
        let host = official(effects: effects216.filter { $0 != oldName })
        XCTAssertTrue(host.lacks(newName))
    }

    // MARK: PC へ送る名前

    private func sentName(_ host: ETRemoteHostInfo?) throws -> String? {
        ETRemoteProjection.project([loaded(try sfz())], host: host).pipeline.first?["nm"] as? String
    }

    func testChainSentToAnOldHostCarriesTheOldName() throws {
        XCTAssertEqual(try sentName(official(effects: effects216)), oldName)
        // 一覧を出さない PC は dsp の版で決める。
        XCTAssertEqual(try sentName(official(dsp: "0.16.0", effects: nil)), oldName)
    }

    func testChainSentToANewOrUnknownHostCarriesTheNewName() throws {
        XCTAssertEqual(try sentName(official(app: "2.17.0", effects: ETRemoteHostInfo.localEffectNames)), newName)
        XCTAssertEqual(try sentName(official(dsp: "0.17.0", effects: nil)), newName)
        XCTAssertEqual(try sentName(official(dsp: nil, effects: nil)), newName, "版も一覧も無ければ新しい名前")
        XCTAssertEqual(try sentName(nil), newName, "つながっていない（host なし）")
        // 新しい名前も旧い名前も両方持つ PC は新しい名前。
        XCTAssertEqual(try sentName(official(effects: ETRemoteHostInfo.localEffectNames + [oldName])), newName)
    }

    func testOtherEffectNamesAreUntouchedAndAHostWithoutEitherNameDropsTheStage() throws {
        let volume = try XCTUnwrap(ETCatalog.first { $0.type == "VolumePlugin" })
        let host = official(effects: effects216)
        let p = ETRemoteProjection.project([loaded(volume), loaded(try sfz())], host: host)
        XCTAssertEqual(p.pipeline.map { $0["nm"] as? String }, ["Volume", oldName])
        let bare = official(effects: effects216.filter { $0 != oldName })
        let q = ETRemoteProjection.project([loaded(try sfz())], host: bare)
        XCTAssertEqual(q.pipeline.count, 0)
        XCTAssertEqual(q.remoteIndex.count, 1)
    }

    func testChainForAnOldHostReadsBackAsTheSameEffect() throws {
        let host = official(effects: effects216)
        let sent = ETRemoteProjection.project([loaded(try sfz())], host: host).pipeline
        let back = PipelineStore.parse(sent, catalog: ETCatalog)
        XCTAssertEqual(back.map(\.spec.type), [sfzType])
    }
}
