//  OutputCorrectionTests.swift
//  出力補正の、値だけで決まる判断（OutputCorrectionCore.swift・ETPipelineAnalysis.merged）と、
//  プリセットの付け替え・削除に紐付けが付いていくこと（PresetStoreCore）。
//
//  壊れると: main の終わりの OFF Section が補正まで止める、補正の Section が main を引き込む、
//  slot の数え違いで別の段を消す、別の出力先のプリセットが混ざる、名前を付け替えると紐付けが外れる、
//  消したプリセットを指したまま残る、OFF にしても効いたまま、共有した鎖で補正が最後の組に呑まれる。

import XCTest

final class OutputCorrectionTests: XCTestCase {

    // MARK: - 道具

    private func effect(_ type: String = "VolumePlugin") throws -> PipelineStore.Loaded {
        let spec = try XCTUnwrap(ETCatalog.first { $0.type == type }, "カタログに無い: \(type)")
        return PipelineStore.Loaded(spec: spec, values: spec.defaults, enabled: true,
                                    inputBus: 0, outputBus: 0, channelSpec: -1)
    }

    private func section(_ name: String, on: Bool = true) -> PipelineStore.Loaded {
        PipelineStore.Loaded(spec: ETSection.spec, values: [], enabled: on,
                             inputBus: 0, outputBus: 0, channelSpec: -1, sectionName: name)
    }

    private func rootReset() -> PipelineStore.Loaded {
        var item = section("")
        item.isRootReset = true
        return item
    }

    private func role(_ l: PipelineStore.Loaded) -> ETItemRole { ETOutputCorrectionForm.role(l) }

    /// 並びと id と分析。
    private func analyze(_ items: [PipelineStore.Loaded], ids: [UUID]? = nil)
        -> (ids: [UUID], a: ETPipelineAnalysis) {
        let ids = ids ?? items.map { _ in UUID() }
        let a = ETPipelineAnalysis.analyze(roles: items.map(role), ids: ids, enabled: items.map(\.enabled))
        return (ids, a)
    }

    // MARK: - slot

    func testLocateMainAndCorrection() {
        func at(_ s: Int) -> (ETChainPart, Int)? {
            ETChainSlots.locate(s, mainCount: 3, correctionCount: 2).map { ($0.part, $0.local) }
        }
        XCTAssertTrue(at(0)! == (.main, 0))
        XCTAssertTrue(at(2)! == (.main, 2))
        XCTAssertTrue(at(3)! == (.correction, 0))
        XCTAssertTrue(at(4)! == (.correction, 1))
        XCTAssertNil(at(5))
        XCTAssertNil(at(-1))
    }

    func testLocateEmptyMain() {
        let r = ETChainSlots.locate(0, mainCount: 0, correctionCount: 1)
        XCTAssertEqual(r?.part, .correction)
        XCTAssertEqual(r?.local, 0)
    }

    func testSplitOffsets() {
        let r = ETChainSlots.split(IndexSet([1, 3, 4]), mainCount: 3)
        XCTAssertEqual(r.main, IndexSet([1]))
        XCTAssertEqual(r.correction, IndexSet([0, 1]))
    }

    // MARK: - 合わせた分析

    func testOffSectionAtEndOfMainDoesNotGateCorrection() throws {
        let main = [section("S", on: false), try effect()]
        let corr = [try effect()]
        let m = analyze(main)
        let c = analyze(corr)
        let merged = ETPipelineAnalysis.merged([m.a, c.a])
        XCTAssertEqual(merged.gate(of: m.ids[1]), 0)
        XCTAssertEqual(merged.gate(of: c.ids[0]), 1)
        XCTAssertNil(merged.owner(of: c.ids[0]))
    }

    func testCorrectionSectionGatesOnlyItsMembers() throws {
        let main = [try effect()]
        let corr = [section("S", on: false), try effect(), rootReset(), try effect()]
        let m = analyze(main)
        let c = analyze(corr)
        let merged = ETPipelineAnalysis.merged([m.a, c.a])
        XCTAssertEqual(merged.gate(of: m.ids[0]), 1)
        XCTAssertEqual(merged.gate(of: c.ids[1]), 0)
        XCTAssertEqual(merged.gate(of: c.ids[3]), 1)
        XCTAssertEqual(merged.members(of: c.ids[0]), [c.ids[1]])
    }

    func testSinglePartEqualsAnalyze() throws {
        let items = [try effect(), section("A"), try effect(), rootReset(), try effect(),
                     section("B", on: false), try effect()]
        let one = analyze(items)
        let merged = ETPipelineAnalysis.merged([one.a])
        for (i, item) in items.enumerated() where role(item) == .effect {
            XCTAssertEqual(merged.gate(of: one.ids[i]), one.a.gate(of: one.ids[i]))
            XCTAssertEqual(merged.owner(of: one.ids[i]), one.a.owner(of: one.ids[i]))
        }
        for (i, item) in items.enumerated() where role(item) == .section {
            XCTAssertEqual(merged.members(of: one.ids[i]), one.a.members(of: one.ids[i]))
        }
    }

    func testMainMembersUnaffectedByCorrection() throws {
        let main = [section("S"), try effect(), try effect()]
        let corr = [try effect()]
        let m = analyze(main)
        let c = analyze(corr)
        let merged = ETPipelineAnalysis.merged([m.a, c.a])
        XCTAssertEqual(merged.members(of: m.ids[0]), [m.ids[1], m.ids[2]])
        XCTAssertNil(merged.owner(of: c.ids[0]))
    }

    // MARK: - 平らげ

    func testEmptyCorrectionReturnsMain() throws {
        let main = [section("S"), try effect()]
        let flat = ETOutputCorrectionForm.flatten(main: main, correction: [])
        XCTAssertEqual(flat.map(role), main.map(role))
        XCTAssertEqual(flat.count, 2)
    }

    func testMainAtRootNoMarker() throws {
        let flat = ETOutputCorrectionForm.flatten(main: [try effect()], correction: [try effect()])
        XCTAssertEqual(flat.map(role), [.effect, .effect])
    }

    func testMainEndingInSectionGetsMarker() throws {
        let flat = ETOutputCorrectionForm.flatten(main: [section("S"), try effect()],
                                                  correction: [try effect()])
        XCTAssertEqual(flat.map(role), [.section, .effect, .rootReset, .effect])
    }

    func testCorrectionStartingWithSectionNoMarker() throws {
        let flat = ETOutputCorrectionForm.flatten(main: [section("S"), try effect()],
                                                  correction: [section("T"), try effect()])
        XCTAssertEqual(flat.map(role), [.section, .effect, .section, .effect])
    }

    func testEmptyMainNoMarker() throws {
        let flat = ETOutputCorrectionForm.flatten(main: [], correction: [try effect()])
        XCTAssertEqual(flat.map(role), [.effect])
    }

    /// エンジンの模型（部分ごとに分析して gate を付ける）と、共有に出す 1 本の形の分析が、
    /// 段ごとの gate で一致する。
    func testFlattenGatesEqualMergedGates() throws {
        let shapes: [(main: [PipelineStore.Loaded], corr: [PipelineStore.Loaded])] = [
            ([section("S", on: false), try effect()], [try effect()]),
            ([section("S", on: true), try effect()], [try effect(), try effect()]),
            ([try effect(), section("S", on: false), try effect(), try effect()],
             [section("T", on: false), try effect(), rootReset(), try effect()]),
            ([section("S", on: false), try effect()],
             [section("T", on: true), try effect(), section("U", on: false), try effect()]),
            ([], [section("T", on: false), try effect()]),
            ([try effect()], [try effect(), section("T", on: false), try effect()]),
        ]
        for (n, shape) in shapes.enumerated() {
            let m = analyze(shape.main)
            let c = analyze(shape.corr)
            let merged = ETPipelineAnalysis.merged([m.a, c.a])
            var expected: [UInt8] = []
            for (i, item) in shape.main.enumerated() where role(item) == .effect {
                expected.append(merged.gate(of: m.ids[i]))
            }
            for (i, item) in shape.corr.enumerated() where role(item) == .effect {
                expected.append(merged.gate(of: c.ids[i]))
            }

            let flat = ETOutputCorrectionForm.flatten(main: shape.main, correction: shape.corr)
            let f = analyze(flat)
            var actual: [UInt8] = []
            for (i, item) in flat.enumerated() where role(item) == .effect {
                actual.append(f.a.gate(of: f.ids[i]))
            }
            XCTAssertEqual(actual, expected, "shape \(n)")
        }
    }

    func testFlattenRoundTripKeepsMarker() throws {
        let flat = ETOutputCorrectionForm.flatten(main: [section("S"), try effect()],
                                                  correction: [try effect()])
        XCTAssertEqual(flat.map(role), [.section, .effect, .rootReset, .effect])

        let back = PipelineStore.parse(PipelineStore.shortForm(flat), catalog: ETCatalog)
        XCTAssertEqual(back.map(role), [.section, .effect, .rootReset, .effect])
        XCTAssertTrue(back[2].isRootReset)

        // EffeTune へ出す形には印が無く、名前の空の Section になる。
        let upstream = ETShareLink.effeTuneForm(flat)
        XCTAssertEqual(upstream.count, 4)
        XCTAssertNil(upstream[2][ETSection.rootResetKey])
        XCTAssertEqual(upstream[2]["nm"] as? String, ETSection.name)
        XCTAssertEqual(upstream[2][ETSection.commentKey] as? String, "")
        // 本物の Section は名前を持ったまま。
        XCTAssertEqual(upstream[0][ETSection.commentKey] as? String, "S")
    }

    // MARK: - 入れ物

    private let dev = ETOutputCorrectionDevice(key: "bluetooth:AA", name: "AirPods", kind: "bluetooth")
    private let speaker = ETOutputCorrectionDevice(key: "speaker", name: "iPhone Speaker", kind: "speaker")

    /// ショート形式の 1 本。中身は見ないので、見分けが付けば何でもよい。
    private func form(_ vl: Double = 0) -> [[String: Any]] {
        [["nm": "Volume", "en": true, "vl": vl]]
    }

    func testDefaultsOffAndNoDevice() {
        let core = ETOutputCorrectionStoreCore(storage: ETMemoryStorage())
        XCTAssertFalse(core.isOn)
        XCTAssertNil(core.currentDevice)
        XCTAssertNil(core.binding(for: "x"))
        XCTAssertEqual(core.bindings(existing: ["P"]), [])
    }

    func testSetOnRoundTripAndSkipsSameValue() {
        let s = ETMemoryStorage()
        let core = ETOutputCorrectionStoreCore(storage: s)
        core.setOn(false)
        XCTAssertEqual(s.writes, 0)
        core.setOn(true)
        XCTAssertTrue(core.isOn)
        XCTAssertEqual(s.writes, 1)
        core.setOn(true)
        XCTAssertEqual(s.writes, 1)
        XCTAssertTrue(ETOutputCorrectionStoreCore(storage: s).isOn)
        core.setOn(false)
        XCTAssertFalse(core.isOn)
    }

    func testCurrentDeviceRoundTripAndSkipsSame() {
        let s = ETMemoryStorage()
        let core = ETOutputCorrectionStoreCore(storage: s)
        core.setCurrentDevice(dev)
        XCTAssertEqual(core.currentDevice, dev)
        XCTAssertEqual(s.writes, 1)
        core.setCurrentDevice(dev)
        XCTAssertEqual(s.writes, 1)
        core.setCurrentDevice(speaker)
        XCTAssertEqual(ETOutputCorrectionStoreCore(storage: s).currentDevice, speaker)
        XCTAssertEqual(s.writes, 2)
        XCTAssertTrue(s.rejected.isEmpty)
    }

    // MARK: - 紐付け

    func testBindRoundTripIsPlistSafe() throws {
        let s = ETMemoryStorage()
        let core = ETOutputCorrectionStoreCore(storage: s)
        core.bind(dev, preset: "EQ/AirPods")
        XCTAssertEqual(core.binding(for: dev.key),
                       ETOutputCorrectionBinding(key: dev.key, name: "AirPods", kind: "bluetooth",
                                                 preset: "EQ/AirPods"))
        let all = try XCTUnwrap(s.dictionary(forKey: ETOutputCorrectionStoreCore.devicesKey))
        let raw = try XCTUnwrap(all[dev.key] as? [String: String])
        XCTAssertEqual(Set(raw.keys), ["preset", "name", "kind"])
        XCTAssertTrue(s.rejected.isEmpty)
        XCTAssertEqual(s.writes, 1)
    }

    func testBindSameValueDoesNotWrite() {
        let s = ETMemoryStorage()
        let core = ETOutputCorrectionStoreCore(storage: s)
        core.bind(dev, preset: "A")
        core.bind(dev, preset: "A")
        XCTAssertEqual(s.writes, 1)
        // 別のプリセットなら書く。
        core.bind(dev, preset: "B")
        XCTAssertEqual(s.writes, 2)
        XCTAssertEqual(core.binding(for: dev.key)?.preset, "B")
    }

    func testBindNilUnbinds() {
        let s = ETMemoryStorage()
        let core = ETOutputCorrectionStoreCore(storage: s)
        core.bind(dev, preset: "A")
        core.bind(dev, preset: nil)
        XCTAssertNil(core.binding(for: dev.key))
        // 無いものを外しても書かない。
        let w = s.writes
        core.bind(dev, preset: nil)
        core.bind(speaker, preset: nil)
        XCTAssertEqual(s.writes, w)
    }

    func testDevicesAreIndependent() {
        let core = ETOutputCorrectionStoreCore(storage: ETMemoryStorage())
        core.bind(dev, preset: "A")
        core.bind(speaker, preset: "B")
        XCTAssertEqual(core.binding(for: dev.key)?.preset, "A")
        XCTAssertEqual(core.binding(for: speaker.key)?.preset, "B")
        core.bind(speaker, preset: nil)
        XCTAssertNil(core.binding(for: speaker.key))
        XCTAssertEqual(core.binding(for: dev.key)?.preset, "A")
    }

    func testBindingsHideMissingPresetsAndSort() {
        let core = ETOutputCorrectionStoreCore(storage: ETMemoryStorage())
        core.bind(ETOutputCorrectionDevice(key: "k3", name: "C", kind: "wired"), preset: "P")
        core.bind(ETOutputCorrectionDevice(key: "k2", name: "b", kind: "wired"), preset: "P")
        core.bind(ETOutputCorrectionDevice(key: "k1", name: "b", kind: "wired"), preset: "P")
        core.bind(ETOutputCorrectionDevice(key: "k0", name: "a", kind: "wired"), preset: "Gone")
        let list = core.bindings(existing: ["P"])
        XCTAssertEqual(list.map(\.key), ["k1", "k2", "k3"])
        // 隠すだけで、紐付けは残っている（プリセットが戻れば出る）。
        XCTAssertEqual(core.binding(for: "k0")?.preset, "Gone")
    }

    func testNoteNameUpdatesOnlyBound() {
        let s = ETMemoryStorage()
        let core = ETOutputCorrectionStoreCore(storage: s)
        core.noteName(dev)
        XCTAssertEqual(s.writes, 0)
        XCTAssertNil(core.binding(for: dev.key))

        core.bind(dev, preset: "A")
        let w = s.writes
        let renamed = ETOutputCorrectionDevice(key: dev.key, name: "AirPods Pro", kind: dev.kind)
        core.noteName(renamed)
        XCTAssertEqual(s.writes, w + 1)
        XCTAssertEqual(core.binding(for: dev.key)?.name, "AirPods Pro")
        XCTAssertEqual(core.binding(for: dev.key)?.preset, "A")
        core.noteName(renamed)
        XCTAssertEqual(s.writes, w + 1)
    }

    func testRetargetRenames() {
        let core = ETOutputCorrectionStoreCore(storage: ETMemoryStorage())
        core.bind(dev, preset: "A")
        core.retarget([(from: "A", to: "B")])
        XCTAssertEqual(core.binding(for: dev.key)?.preset, "B")
    }

    func testRetargetNilUnbinds() {
        let core = ETOutputCorrectionStoreCore(storage: ETMemoryStorage())
        core.bind(dev, preset: "A")
        core.bind(speaker, preset: "B")
        core.retarget([(from: "A", to: nil)])
        XCTAssertNil(core.binding(for: dev.key))
        XCTAssertEqual(core.binding(for: speaker.key)?.preset, "B")
    }

    func testRetargetSwapResolvesOnce() {
        let core = ETOutputCorrectionStoreCore(storage: ETMemoryStorage())
        core.bind(dev, preset: "A")
        core.bind(speaker, preset: "B")
        core.retarget([(from: "A", to: "B"), (from: "B", to: "A")])
        XCTAssertEqual(core.binding(for: dev.key)?.preset, "B")
        XCTAssertEqual(core.binding(for: speaker.key)?.preset, "A")
    }

    func testRetargetNoMatchDoesNotWrite() {
        let s = ETMemoryStorage()
        let core = ETOutputCorrectionStoreCore(storage: s)
        core.bind(dev, preset: "A")
        let w = s.writes
        core.retarget([(from: "X", to: "Y"), (from: "Z", to: nil)])
        core.retarget([])
        XCTAssertEqual(s.writes, w)
        XCTAssertEqual(core.binding(for: dev.key)?.preset, "A")
    }

    func testMalformedBindingsIgnored() {
        let s = ETMemoryStorage([
            ETOutputCorrectionStoreCore.devicesKey: [
                "x": "oops",
                "y": ["name": "Y"],
                // 前の形（写しを持っていた）。
                "z": ["name": "Z", "chain": Data()] as [String: Any],
                "g": ["preset": "G", "name": "Good", "kind": "wired"],
            ] as [String: Any],
        ])
        let core = ETOutputCorrectionStoreCore(storage: s)
        XCTAssertNil(core.binding(for: "x"))
        XCTAssertNil(core.binding(for: "y"))
        XCTAssertNil(core.binding(for: "z"))
        XCTAssertEqual(core.binding(for: "g")?.preset, "G")
        // 壊れたものが居ても、別の出力先は紐付けられて、読めたものは残る。
        core.bind(dev, preset: "A")
        XCTAssertEqual(core.binding(for: dev.key)?.preset, "A")
        XCTAssertEqual(core.binding(for: "g")?.name, "Good")
        XCTAssertTrue(s.rejected.isEmpty)
    }

    // MARK: - プリセットの出し入れに付いていく

    /// 同じ入れ物の PresetStoreCore と紐付け。patch に渡された鍵を `patchedKeys` に残す。
    private func stores(_ initial: [String: Any] = [:])
        -> (s: ETMemoryStorage, presets: PresetStoreCore, oc: ETOutputCorrectionStoreCore) {
        let s = ETMemoryStorage()
        if !initial.isEmpty { s.set(initial, forKey: PresetStoreCore.key) }
        let presets = PresetStoreCore(storage: s, patch: { [unowned self] key, _ in
            self.patchedKeys.append(key)
        })
        return (s, presets, ETOutputCorrectionStoreCore(storage: s))
    }

    private var patchedKeys: [String] = []

    override func setUp() {
        super.setUp()
        patchedKeys = []
    }

    func testPresetRenameFollows() {
        let x = stores(["A": form(1)])
        x.oc.bind(dev, preset: "A")
        XCTAssertTrue(x.presets.rename("A", to: "B"))
        XCTAssertEqual(x.oc.binding(for: dev.key)?.preset, "B")
    }

    func testPresetRenameFolderFollows() {
        let x = stores(["F/A": form(1), "Solo": form(2)])
        x.oc.bind(dev, preset: "F/A")
        x.oc.bind(speaker, preset: "Solo")
        XCTAssertTrue(x.presets.renameFolder("F", to: "G"))
        XCTAssertEqual(x.oc.binding(for: dev.key)?.preset, "G/A")
        XCTAssertEqual(x.oc.binding(for: speaker.key)?.preset, "Solo")
    }

    func testFailedRenameKeepsBinding() {
        let x = stores(["A": form(1), "B": form(2)])
        x.oc.bind(dev, preset: "A")
        XCTAssertFalse(x.presets.rename("A", to: "B"))
        XCTAssertEqual(x.oc.binding(for: dev.key)?.preset, "A")
    }

    func testFailedRenameFolderKeepsBinding() {
        let x = stores(["F/A": form(1), "G/B": form(2)])
        x.oc.bind(dev, preset: "F/A")
        XCTAssertFalse(x.presets.renameFolder("F", to: "G"))
        XCTAssertEqual(x.oc.binding(for: dev.key)?.preset, "F/A")
    }

    func testPresetRemoveUnbinds() {
        let x = stores(["A": form(1), "B": form(2)])
        x.oc.bind(dev, preset: "A")
        x.oc.bind(speaker, preset: "B")
        x.presets.remove("A")
        XCTAssertNil(x.oc.binding(for: dev.key))
        XCTAssertEqual(x.oc.binding(for: speaker.key)?.preset, "B")
    }

    func testMirrorFolderDeleteUnbinds() {
        let x = stores()
        let f = form(1)
        // 先に 1 回写して "PC" を PC のものにする（前から在る人の "PC" なら "PC 2" へずれる）。
        XCTAssertEqual(x.presets.mirrorFolder("PC", incoming: ["Keep": f, "Gone": f]).folder, "PC")
        x.oc.bind(dev, preset: "PC/Keep")
        x.oc.bind(speaker, preset: "PC/Gone")
        x.presets.mirrorFolder("PC", incoming: ["Keep": f])
        XCTAssertEqual(x.oc.binding(for: dev.key)?.preset, "PC/Keep")
        XCTAssertNil(x.oc.binding(for: speaker.key))
    }

    func testSaveAndMergeKeepBinding() {
        let x = stores(["A": form(1)])
        x.oc.bind(dev, preset: "A")
        XCTAssertEqual(x.presets.save("A", form: form(2)), "A")
        XCTAssertEqual(x.oc.binding(for: dev.key)?.preset, "A")
        XCTAssertEqual(x.presets.merge(["A": form(3)]), 1)
        XCTAssertEqual(x.oc.binding(for: dev.key)?.preset, "A")
    }

    func testBindingsNeverPatchCloud() {
        let x = stores(["A": form(1), "F/B": form(2)])
        x.oc.bind(dev, preset: "A")
        x.oc.bind(speaker, preset: "F/B")
        x.presets.rename("A", to: "C")
        x.presets.renameFolder("F", to: "G")
        x.presets.remove("C")
        x.oc.bind(speaker, preset: nil)
        XCTAssertFalse(patchedKeys.isEmpty)
        XCTAssertFalse(patchedKeys.contains(ETOutputCorrectionStoreCore.devicesKey))
        XCTAssertEqual(Set(patchedKeys), [PresetStoreCore.key])
        XCTAssertTrue(x.s.rejected.isEmpty)
    }

    func testExportedExcludesBindings() {
        let x = stores(["A": form(1), "F/B": form(2)])
        x.oc.bind(dev, preset: "A")
        x.oc.setOn(true)
        x.oc.setCurrentDevice(dev)
        XCTAssertEqual(Set(x.presets.exported().keys), ["A", "F/B"])
    }

    // MARK: - 段取り

    private func t(_ dev: String = "A", _ preset: String = "P", _ s: UInt8 = 1) -> ETOutputCorrectionTarget {
        ETOutputCorrectionTarget(device: dev, preset: preset, stamp: Data([s]))
    }

    private func steps(on: Bool = true, remote: Bool = false, ready: Bool = true,
                       wanted: ETOutputCorrectionTarget?, loaded: ETOutputCorrectionTarget?)
        -> [ETOutputCorrectionStep] {
        ETOutputCorrectionPolicy.steps(ETOutputCorrectionState(
            isOn: on, isRemote: remote, ready: ready, wanted: wanted, loaded: loaded))
    }

    func testOffLoadsNothing() {
        XCTAssertEqual(steps(on: false, wanted: t(), loaded: nil), [])
    }

    func testOnLoadsWanted() {
        XCTAssertEqual(steps(wanted: t(), loaded: nil), [.load(t())])
    }

    func testUnboundLoadsNothing() {
        XCTAssertEqual(steps(wanted: nil, loaded: nil), [])
    }

    /// 出力先が替わったら、同じプリセットでも読み直す。
    func testDeviceSwitchReloadsSamePreset() {
        XCTAssertEqual(steps(wanted: t("B"), loaded: t("A")), [.load(t("B"))])
    }

    func testSwitchToUnboundUnloads() {
        XCTAssertEqual(steps(wanted: nil, loaded: t()), [.unload])
    }

    func testOverwriteReloads() {
        XCTAssertEqual(steps(wanted: t("A", "P", 2), loaded: t("A", "P", 1)), [.load(t("A", "P", 2))])
    }

    /// 名前の付け替え（フォルダへ動かすのも）は中身が同じなので、段に触らない。
    func testRenameRelabels() {
        XCTAssertEqual(steps(wanted: t("A", "Q", 1), loaded: t("A", "P", 1)), [.relabel(t("A", "Q", 1))])
    }

    func testRebindReloads() {
        XCTAssertEqual(steps(wanted: t("A", "Q", 2), loaded: t("A", "P", 1)), [.load(t("A", "Q", 2))])
    }

    func testTurningOffUnloads() {
        XCTAssertEqual(steps(on: false, wanted: t(), loaded: t()), [.unload])
    }

    func testEnteringRemoteUnloads() {
        XCTAssertEqual(steps(remote: true, wanted: t(), loaded: t()), [.unload])
    }

    func testLeavingRemoteReloads() {
        XCTAssertEqual(steps(remote: false, wanted: t(), loaded: nil), [.load(t())])
    }

    func testNotReadyDoesNothing() {
        XCTAssertEqual(steps(ready: false, wanted: t("B"), loaded: t("A")), [])
        XCTAssertEqual(steps(on: false, ready: false, wanted: t(), loaded: t()), [])
        XCTAssertEqual(steps(ready: false, wanted: t(), loaded: nil), [])
    }

    func testSameTargetNoSteps() {
        XCTAssertEqual(steps(wanted: t(), loaded: t()), [])
    }

    func testStampIgnoresKeyOrder() {
        let a: [[String: Any]] = [["a": 1, "b": 2]]
        let b: [[String: Any]] = [["b": 2, "a": 1]]
        let c: [[String: Any]] = [["a": 1, "b": 3]]
        XCTAssertEqual(ETOutputCorrectionTarget.stamp(a), ETOutputCorrectionTarget.stamp(b))
        XCTAssertNotEqual(ETOutputCorrectionTarget.stamp(a), ETOutputCorrectionTarget.stamp(c))
        XCTAssertFalse(ETOutputCorrectionTarget.stamp(a).isEmpty)
        // JSON にできない値でも落ちない。
        let bad: [[String: Any]] = [["v": Double.nan]]
        XCTAssertEqual(ETOutputCorrectionTarget.stamp(bad), Data())
    }

    // MARK: - 中身の行

    func testLinesOfEmptyIsEmpty() {
        XCTAssertEqual(ETOutputCorrectionForm.lines([]), [])
    }

    func testLinesOfFlatPreset() throws {
        let peq = try effect("FifteenBandPEQPlugin")
        let vol = try effect()
        XCTAssertEqual(ETOutputCorrectionForm.lines([peq, vol]), [
            ETOutputCorrectionLine(id: 0, name: peq.spec.name, isSection: false, indented: false),
            ETOutputCorrectionLine(id: 1, name: vol.spec.name, isSection: false, indented: false),
        ])
    }

    /// Section の配下は字下げし、終端で戻す。終端そのものは行にしない。
    func testLinesIndentUnderSectionAndRootResetEndsIt() throws {
        let peq = try effect("FifteenBandPEQPlugin")
        let vol = try effect()
        XCTAssertEqual(ETOutputCorrectionForm.lines([section("Room"), peq, rootReset(), vol]), [
            ETOutputCorrectionLine(id: 0, name: "Room", isSection: true, indented: false),
            ETOutputCorrectionLine(id: 1, name: peq.spec.name, isSection: false, indented: true),
            ETOutputCorrectionLine(id: 2, name: vol.spec.name, isSection: false, indented: false),
        ])
    }

    /// 名前の無い Section は "Section"。
    func testLinesUnnamedSection() throws {
        let vol = try effect()
        XCTAssertEqual(ETOutputCorrectionForm.lines([section(""), vol]), [
            ETOutputCorrectionLine(id: 0, name: "Section", isSection: true, indented: false),
            ETOutputCorrectionLine(id: 1, name: vol.spec.name, isSection: false, indented: true),
        ])
    }

    // MARK: - シートの行

    /// エフェクトの名前だけを " · " でつなぐ。Section の見出しと終端は入れない。
    func testSummaryJoinsEffectNamesOnly() throws {
        let peq = try effect("FifteenBandPEQPlugin")
        let vol = try effect()
        XCTAssertEqual(ETOutputCorrectionForm.summary([section("Room"), peq, rootReset(), vol]),
                       "\(peq.spec.name) · \(vol.spec.name)")
        XCTAssertEqual(ETOutputCorrectionForm.summary([]), "")
        XCTAssertEqual(ETOutputCorrectionForm.summary([section("Room")]), "")
    }

    /// フォルダに入っていないものが先頭、あとはフォルダの名前順。中は渡された順のまま。
    func testPresetFoldersLooseFirstThenByName() {
        let folders = ETOutputCorrectionForm.presetFolders(
            ["Rock/Heavy", "Flat", "IEM/B", "IEM/A", "Bass"])
        XCTAssertEqual(folders.map { $0.name }, ["", "IEM", "Rock"])
        XCTAssertEqual(folders.map { $0.items }, [["Flat", "Bass"], ["IEM/B", "IEM/A"], ["Rock/Heavy"]])
        XCTAssertTrue(ETOutputCorrectionForm.presetFolders([]).isEmpty)
    }
}
