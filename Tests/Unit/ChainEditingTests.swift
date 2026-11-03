//  ChainEditingTests.swift
//  鎖をいじるときの決まりごと（ChainEditing.swift）。
//
//  模型（EffeTuneDSP）は os と et_* と AU/JSFX の host を連れてくるので入らない。
//  判断をあちらから出してあるので、並びと値だけで試す。
//
//  choice は前は `param.offset` ではなく並びの何番目か（params の添字）で値を読んでいた。
//  IR Reverb は今たまたま両方が同じなので鳴っていたが、配列の param が前にある型では別の値を読む。

import XCTest

final class ChainEditingTests: XCTestCase {

    // MARK: - 道具

    private func spec(_ type: String) throws -> ETEffect {
        try XCTUnwrap(ETCatalog.first { $0.type == type }, "カタログに無い: \(type)")
    }

    private func loaded(_ spec: ETEffect) -> PipelineStore.Loaded {
        PipelineStore.Loaded(spec: spec, values: spec.defaults, enabled: true,
                             inputBus: 0, outputBus: 0, channelSpec: -1)
    }

    private func externalLoaded(_ id: String, instance: String) -> PipelineStore.Loaded {
        PipelineStore.Loaded(spec: ETEffect.external(type: "External:\(id)", name: id, category: "Audio Units"),
                             values: [], enabled: true, inputBus: 0, outputBus: 0, channelSpec: -1,
                             externalID: id, externalInstanceID: instance)
    }

    private func role(_ item: PipelineStore.Loaded) -> ETItemRole {
        if item.isRootReset { return .rootReset }
        return ETSection.isSection(item.spec) ? .section : .effect
    }

    /// 配列の param が前にあり、並びの位置と float の位置がずれる型。
    private let shifted = ETEffect(
        type: "ShiftedPlugin", name: "Shifted", about: "", category: "test",
        paramsHash: 0, floatCount: 5, defaults: [0, 0, 0, 0, 0],
        params: [
            ETParam(name: "gains", key: "g", label: "Gain",
                    kind: .number(min: -12, max: 12, step: 0.1, unit: "dB", isInteger: false),
                    defaultValue: 0, offset: 0, count: 3),
            ETParam(name: "mode", key: "md", label: "Mode", kind: .enumeration(["a", "b", "c"]),
                    defaultValue: 0, offset: 3, count: 1),
            ETParam(name: "latency", key: "lt", label: "Latency", kind: .enumeration(["0", "128", "256"]),
                    defaultValue: 0, offset: 4, count: 1),
        ])

    // MARK: - 選択肢

    /// **値は param.offset から読む。**並びの位置（md は 2 番目）で読むと gains の 2 本目を読む。
    /// lt も並びの位置（3 番目）で読むと gains の 3 本目の 1 を読んで "128" になるので、offset の 2 と違える。
    func testChoiceUsesOffset() {
        let values: [Float] = [0, 0, 1, 2, 2]
        XCTAssertEqual(ETChainEditing.choice("md", params: shifted.params, values: values), "c")
        XCTAssertEqual(ETChainEditing.choice("lt", params: shifted.params, values: values), "256")
    }

    /// 読めないものは "auto"。知らない鍵・数の param・範囲の外・値が足りない・NaN。
    func testChoiceFallsBackToAuto() {
        let values: [Float] = [0, 0, 0, 7, .nan]
        XCTAssertEqual(ETChainEditing.choice("zz", params: shifted.params, values: values), "auto")
        XCTAssertEqual(ETChainEditing.choice("g", params: shifted.params, values: values), "auto")
        XCTAssertEqual(ETChainEditing.choice("md", params: shifted.params, values: values), "auto")
        XCTAssertEqual(ETChainEditing.choice("lt", params: shifted.params, values: values), "auto")
        XCTAssertEqual(ETChainEditing.choice("md", params: shifted.params, values: [0, 0, 0]), "auto")
        XCTAssertEqual(ETChainEditing.choice("md", params: shifted.params,
                                             values: [0, 0, 0, .infinity, 0]), "auto")
    }

    /// IR Reverb（資産の解決に使う 3 つ）。既定は auto / 128 / auto。
    func testChoiceOnIRReverb() throws {
        let ir = try spec("IRReverbPlugin")
        XCTAssertEqual(ETChainEditing.choice("cm", params: ir.params, values: ir.defaults), "auto")
        XCTAssertEqual(ETChainEditing.choice("lt", params: ir.params, values: ir.defaults), "128")
        XCTAssertEqual(ETChainEditing.choice("cr", params: ir.params, values: ir.defaults), "auto")
        var v = ir.defaults
        let cm = try XCTUnwrap(ir.params.first { $0.key == "cm" })
        v[cm.offset] = 3
        XCTAssertEqual(ETChainEditing.choice("cm", params: ir.params, values: v), "true")
    }

    /// 資産を送り直さないと効かない値の位置。素材を持っていない段は空。
    func testAssetConfigOffsets() throws {
        let ir = try spec("IRReverbPlugin")
        XCTAssertEqual(ETChainEditing.assetConfigOffsets(params: ir.params, irId: ""), [])
        let expected = Set(ir.params.filter { ["cm", "lt", "cr"].contains($0.key) }.map(\.offset))
        XCTAssertEqual(expected.count, 3)
        XCTAssertEqual(ETChainEditing.assetConfigOffsets(params: ir.params, irId: "abc"), expected)
        XCTAssertEqual(ETChainEditing.assetConfigOffsets(params: shifted.params, irId: "abc"), [4],
                       "offset で返す（lt は並びの 3 番目だが float の 4 番目）")
        XCTAssertEqual(ETChainEditing.assetConfigOffsets(params: try spec("VolumePlugin").params, irId: "abc"), [])
    }

    // MARK: - 送り直したあとのカードの1行

    /// **engine が回さない段（幅 0）へ送り直したら、前の 1 行を残さない。**
    /// 入れ直しは instance を作り直した後（出力先の切り替え）に走り、資産は instance と一緒に消えている。
    /// 6ch から 2ch の IF に替えて "56" の IR Reverb が外れたのに「4ch True Stereo / 48000 Hz / 1.23 s」が
    /// 残っていた。冷えた起動（前の行が無い）でも nil にするとカードは「Loaded」と出すので、理由の 1 行を置く。
    func testReloadIntoSkippedStageDropsTheOldLine() {
        let old = "4ch True Stereo / 48000 Hz / 1.23 s"
        XCTAssertEqual(ETChainEditing.assetLineAfterReload(sent: nil, previous: old, processedWidth: 0),
                       ETChainEditing.unroutedAssetLine)
        XCTAssertEqual(ETChainEditing.assetLineAfterReload(sent: nil, previous: nil, processedWidth: 0),
                       ETChainEditing.unroutedAssetLine)
    }

    /// 送れたらその 1 行。幅 1 以上で送れなかったときは前のまま（選択肢を選び直して resolve に
    /// 断られた回は、送る前に止まるので前の資産がカーネルに残って鳴っている）。
    func testReloadOnRoutedStage() {
        let old = "2ch Independent / 48000 Hz / 0.80 s"
        let new = "4ch True Stereo / 48000 Hz / 1.23 s"
        XCTAssertEqual(ETChainEditing.assetLineAfterReload(sent: new, previous: old, processedWidth: 2), new)
        XCTAssertEqual(ETChainEditing.assetLineAfterReload(sent: new, previous: nil, processedWidth: 6), new)
        XCTAssertEqual(ETChainEditing.assetLineAfterReload(sent: nil, previous: old, processedWidth: 2), old)
        XCTAssertNil(ETChainEditing.assetLineAfterReload(sent: nil, previous: nil, processedWidth: 2))
    }

    /// 理由の 1 行は、カードから入れたときに resolve が断る文と同じ。
    func testUnroutedLineMatchesTheResolver() {
        XCTAssertThrowsError(try ETIRPreparation.resolve(sampleRate: 48000, channelCount: 2, routedChannels: 0,
                                                         channelMode: "auto", latency: "128",
                                                         convolutionRate: "auto")) { error in
            XCTAssertEqual((error as? LocalizedError)?.errorDescription, ETChainEditing.unroutedAssetLine)
        }
    }

    // MARK: - 上流が受けない Ch

    func testChannelBypassTable() {
        for ch in Int8(-2)...23 {
            XCTAssertEqual(ETChainEditing.isChannelBypassed(type: "BassExtenderPlugin", channelSpec: ch),
                           !(ch == -1 || ch >= 16), "Bass Extender ch \(ch)")
            XCTAssertEqual(ETChainEditing.isChannelBypassed(type: "BassManagementPlugin", channelSpec: ch),
                           ch != -2, "Bass Management ch \(ch)")
            XCTAssertFalse(ETChainEditing.isChannelBypassed(type: "VolumePlugin", channelSpec: ch))
            XCTAssertFalse(ETChainEditing.isChannelBypassed(type: "External:au:x", channelSpec: ch))
        }
    }

    /// 型名はカタログと一字も違えない（違うと外すべき段が鳴る）。
    func testTypeNamesAreInTheCatalog() {
        for type in [ETChainEditing.defaultType, ETChainEditing.bassExtenderType,
                     ETChainEditing.bassManagementType] {
            XCTAssertTrue(ETCatalog.contains { $0.type == type }, type)
        }
    }

    // MARK: - 既定の鎖

    /// restore() が置いた Level Meter 1 本は、まだ何も残していなければ書かない。
    func testDefaultLevelMeterNotSaved() {
        let meter = [ETChainEditing.defaultType]
        XCTAssertTrue(ETChainEditing.isDefaultChain(types: meter))
        XCTAssertFalse(ETChainEditing.shouldPersist(types: meter, hasSaved: false))
        // 人が既定へ戻したもの（前に何か残している）は書く。
        XCTAssertTrue(ETChainEditing.shouldPersist(types: meter, hasSaved: true))
        // 既定でない鎖はいつでも書く。
        for types in [["VolumePlugin"], meter + meter, meter + ["VolumePlugin"], [ETSection.type]] {
            XCTAssertFalse(ETChainEditing.isDefaultChain(types: types), "\(types)")
            XCTAssertTrue(ETChainEditing.shouldPersist(types: types, hasSaved: false), "\(types)")
        }
        // 空の鎖は既定ではない（書かないのは rebuildAll が publish を通さないことで守っている）。
        XCTAssertFalse(ETChainEditing.isDefaultChain(types: []))
        XCTAssertTrue(ETChainEditing.shouldPersist(types: [], hasSaved: false))
    }

    // MARK: - プリセットを足す

    /// 先頭にプリセット名の Section。入っていて、鎖の形は既定（Left ではなく Stereo）。
    func testAddPresetLeadingSectionNamedAfterPreset() throws {
        let items = [loaded(try spec("VolumePlugin")), loaded(try spec("DelayPlugin"))]
        let plan = ETChainEditing.presetInsertion(named: "Warm", items: items, at: nil, roles: [])
        XCTAssertEqual(plan.target, 0)
        XCTAssertEqual(plan.items.map(\.spec.type), [ETSection.type, "VolumePlugin", "DelayPlugin"])
        let head = plan.items[0]
        XCTAssertEqual(head.sectionName, "Warm")
        XCTAssertTrue(head.enabled)
        XCTAssertFalse(head.isRootReset)
        XCTAssertEqual(head.channelSpec, -1)
        XCTAssertEqual(head.inputBus, 0)
        XCTAssertEqual(head.outputBus, 0)
        // 書くと `cm` にプリセット名、ch は書かない。
        XCTAssertEqual(PipelineStore.shortForm([head])[0] as NSDictionary,
                       ["cm": "Warm", "nm": "Section", "en": true] as NSDictionary)
    }

    /// 閉じる名前の無い Section は、**差し込む先の次が普通の段のときだけ**。
    /// 末尾・次が Section・次が終端（rootReset）なら足さない。
    func testClosingUnnamedOnlyBeforeNonSection() throws {
        let items = [loaded(try spec("VolumePlugin"))]
        func plan(_ roles: [ETItemRole], at index: Int?) -> ETChainEditing.PresetInsertion {
            ETChainEditing.presetInsertion(named: "P", items: items, at: index, roles: roles)
        }
        func closes(_ p: ETChainEditing.PresetInsertion) -> Bool {
            guard p.items.count == 3, let last = p.items.last else { return false }
            return ETSection.isSection(last.spec) && last.sectionName.isEmpty && !last.isRootReset
                && last.enabled
        }
        let chain: [ETItemRole] = [.effect, .section, .effect, .rootReset, .effect]
        XCTAssertTrue(closes(plan(chain, at: 0)), "次が段")
        XCTAssertFalse(closes(plan(chain, at: 1)), "次が Section")
        XCTAssertTrue(closes(plan(chain, at: 2)), "次が段（組の中）")
        XCTAssertFalse(closes(plan(chain, at: 3)), "次が終端")
        XCTAssertTrue(closes(plan(chain, at: 4)), "次が段（root）")
        XCTAssertFalse(closes(plan(chain, at: 5)), "末尾")
        XCTAssertFalse(closes(plan(chain, at: nil)), "末尾（nil）")
        XCTAssertEqual(plan(chain, at: nil).items.count, 2)
    }

    /// 位置は鎖の範囲へ寄せる。
    func testAddPresetClampsTheIndex() throws {
        let items = [loaded(try spec("VolumePlugin"))]
        let roles: [ETItemRole] = [.effect, .effect]
        let low = ETChainEditing.presetInsertion(named: "P", items: items, at: -5, roles: roles)
        XCTAssertEqual(low.target, 0)
        XCTAssertEqual(low.items.count, 3, "先頭の前（次が段）なので閉じる")
        let high = ETChainEditing.presetInsertion(named: "P", items: items, at: 99, roles: roles)
        XCTAssertEqual(high.target, 2)
        XCTAssertEqual(high.items.count, 2, "末尾なので閉じない")
    }

    /// 足した鎖を並びの意味で読むと、中身は先頭の Section の配下で、後ろの段は巻き込まれない。
    func testAddedPresetDoesNotSwallowWhatFollows() throws {
        let existing = [loaded(try spec("VolumePlugin")), loaded(try spec("DelayPlugin"))]
        let items = [loaded(try spec("VolumePlugin"))]
        let plan = ETChainEditing.presetInsertion(named: "P", items: items, at: 1,
                                                  roles: existing.map(role))
        var chain = existing
        chain.insert(contentsOf: plan.items, at: plan.target)
        let ids = chain.map { _ in UUID() }
        let a = ETPipelineAnalysis.analyze(roles: chain.map(role), ids: ids, enabled: chain.map(\.enabled))
        // [Volume, S("P"), Volume, S(""), Delay]
        XCTAssertEqual(chain.map(role), [.effect, .section, .effect, .section, .effect])
        XCTAssertEqual(a.members(of: ids[1]), [ids[2]])
        XCTAssertNotEqual(a.owner(of: ids[4]), ids[1], "後ろの段がプリセットの組に入った")
    }

    /// 外部の段には新しい身元を付ける。普通の段は触らない。
    func testAddPresetGivesExternalsFreshIds() throws {
        var counter = 0
        let items = [externalLoaded("au:x", instance: "saved-1"), loaded(try spec("VolumePlugin")),
                     externalLoaded("au:x", instance: "saved-1")]
        let plan = ETChainEditing.presetInsertion(named: "P", items: items, at: nil, roles: [],
                                                  makeID: { counter += 1; return "new-\(counter)" })
        XCTAssertEqual(plan.items.map(\.externalInstanceID), ["", "new-1", "", "new-2"])
        XCTAssertEqual(plan.items.map(\.externalID), ["", "au:x", "", "au:x"])
    }

    // MARK: - 外部の段の身元

    /// 保存した鎖から戻すときは入っていた身元を使う。空か、鎖に居る身元とぶつかれば作り直す。
    func testDuplicateExternalGetsNewId() {
        XCTAssertEqual(ETChainEditing.externalInstanceID(requested: "a", taken: [], makeID: { "n" }), "a")
        XCTAssertEqual(ETChainEditing.externalInstanceID(requested: "a", taken: ["b"], makeID: { "n" }), "a")
        XCTAssertEqual(ETChainEditing.externalInstanceID(requested: "a", taken: ["a"], makeID: { "n" }), "n")
        XCTAssertEqual(ETChainEditing.externalInstanceID(requested: "", taken: [], makeID: { "n" }), "n")
        XCTAssertFalse(ETChainEditing.externalInstanceID(requested: "", taken: []).isEmpty)
    }

    // MARK: - descriptor

    /// publish() と republish() が前に持っていたループの写し（型名の判定もそのまま写す）。
    private func legacyDescriptors(_ chain: [ETChainNode],
                                   probes: [UUID: UInt32]) -> [ETChainEditing.Descriptor] {
        func bypassed(_ n: ETChainNode) -> Bool {
            switch n.spec.type {
            case "BassExtenderPlugin": return !(n.channelSpec == -1 || n.channelSpec >= 16)
            case "BassManagementPlugin": return n.channelSpec != -2
            default: return false
            }
        }
        var nodes: [ETChainEditing.Descriptor] = []
        for n in chain where n.instance != 0 || n.isExternal {
            if let probe = probes[n.id] {
                nodes.append(.init(instance: probe, enabled: 2, inputBus: n.inputBus,
                                   outputBus: n.inputBus, channelSpec: n.channelSpec,
                                   sectionGate: n.sectionGate, kind: .native, externalIndex: 0))
            }
            nodes.append(.init(instance: n.isExternal ? 0 : n.instance,
                               enabled: n.enabled && !bypassed(n) ? 1 : 0,
                               inputBus: n.inputBus, outputBus: n.outputBus,
                               channelSpec: n.channelSpec, sectionGate: n.sectionGate,
                               kind: n.isExternal ? .external : .native,
                               externalIndex: n.externalIndex))
        }
        return nodes
    }

    private func node(_ spec: ETEffect, instance: UInt32, _ edit: (inout ETChainNode) -> Void = { _ in }) -> ETChainNode {
        var n = ETChainNode(spec: spec, values: spec.defaults)
        n.instance = instance
        edit(&n)
        return n
    }

    func testDescriptorsMatchLegacyLoop() throws {
        let volume = try spec("VolumePlugin")
        let peq = try spec("FiveBandPEQPlugin")
        let extender = try spec("BassExtenderPlugin")
        let management = try spec("BassManagementPlugin")
        var section = ETChainNode(spec: ETSection.spec, values: [])
        section.sectionName = "A"
        var reset = ETChainNode(spec: ETSection.spec, values: [])
        reset.isRootReset = true
        var external = ETChainNode(spec: ETEffect.external(type: "External:au:x", name: "X", category: "Audio Units"),
                                   values: [])
        external.externalID = "au:x"
        external.externalIndex = 3
        external.inputBus = 1
        external.outputBus = 2
        external.channelSpec = 17

        let chain: [ETChainNode] = [
            node(volume, instance: 11),
            section,
            node(volume, instance: 12) { $0.enabled = false },
            node(peq, instance: 13) { $0.inputBus = 1; $0.outputBus = 1; $0.channelSpec = 0 },
            node(volume, instance: 0),                                  // 作れなかった段
            reset,
            external,
            node(extender, instance: 14) { $0.channelSpec = -2 },       // All は外す
            node(extender, instance: 15) { $0.channelSpec = 18 },
            node(management, instance: 16) { $0.channelSpec = -2 },
            node(management, instance: 17) { $0.channelSpec = 0 },      // All 以外は外す
            node(volume, instance: 18) { $0.sectionGate = 0 },
            node(peq, instance: 19) { $0.inputBus = 2; $0.outputBus = 3 },
        ]
        let probes: [UUID: UInt32] = [chain[3].id: 101, chain[12].id: 102, chain[4].id: 103]

        let got = ETChainEditing.descriptors(chain: chain, probes: probes)
        XCTAssertEqual(got, legacyDescriptors(chain, probes: probes))

        // 中身も見る。落ちるのは Section・終端・作れなかった段（とその探り）。
        XCTAssertEqual(got.map(\.instance), [11, 12, 101, 13, 0, 14, 15, 16, 17, 18, 102, 19])
        XCTAssertEqual(got.map(\.enabled), [1, 0, 2, 1, 1, 0, 1, 1, 0, 1, 2, 1])
        XCTAssertEqual(got[2].outputBus, 1, "探りは入口の bus に置く")
        XCTAssertEqual(got[10].inputBus, 2)
        XCTAssertEqual(got[10].outputBus, 2, "探りは入口の bus に置く（出口ではない）")
        XCTAssertEqual(got[4].kind, .external)
        XCTAssertEqual(got[4].externalIndex, 3)
        XCTAssertEqual(got[9].sectionGate, 0)
        XCTAssertTrue(ETChainEditing.descriptors(chain: [], probes: [:]).isEmpty)
    }

    /// 出口の探りは相手の直後・出口の bus・enabled 2。入口の探りと挟む形になる。
    /// 作れなかった段（instance 0）の探りは相手ごと落ちる。
    func testAfterProbesFollowTheirNode() throws {
        let volume = try spec("VolumePlugin")
        let peq = try spec("FiveBandPEQPlugin")
        let chain = [
            node(volume, instance: 11),
            node(peq, instance: 12) { $0.inputBus = 1; $0.outputBus = 1; $0.channelSpec = 3 },
            node(peq, instance: 0),
            node(volume, instance: 13),
        ]
        let before: [UUID: UInt32] = [chain[1].id: 101, chain[2].id: 102]
        let after: [UUID: UInt32] = [chain[1].id: 201, chain[2].id: 202]

        let got = ETChainEditing.descriptors(chain: chain, probes: before, afterProbes: after)
        XCTAssertEqual(got.map(\.instance), [11, 101, 12, 201, 13])
        XCTAssertEqual(got.map(\.enabled), [1, 2, 1, 2, 1])
        XCTAssertEqual([got[3].inputBus, got[3].outputBus], [1, 1], "出口の探りは出口の bus に置く")
        XCTAssertEqual(got[3].channelSpec, 3)
        XCTAssertEqual(got[3].kind, .native)

        // 出口の探りを渡さなければ、前と同じ並び。
        XCTAssertEqual(ETChainEditing.descriptors(chain: chain, probes: before),
                       legacyDescriptors(chain, probes: before))
    }

    /// PEQ の相方は本体の直後・出口の探りの前。enabled 2、本体と同じ bus・gate。
    /// 本体が切・instance 無し・外部のときは載せない。渡さなければ前と同じ並び。
    func testCompanionsFollowTheirNodeBeforeAfterProbes() throws {
        let volume = try spec("VolumePlugin")
        let peq = try spec("FiveBandPEQPlugin")
        var external = ETChainNode(spec: ETEffect.external(type: "External:au:x", name: "X", category: "Audio Units"),
                                   values: [])
        external.externalID = "au:x"
        let chain = [
            node(volume, instance: 11),
            node(peq, instance: 12) { $0.inputBus = 1; $0.outputBus = 1; $0.channelSpec = 3; $0.sectionGate = 0 },
            node(peq, instance: 13) { $0.enabled = false },
            node(peq, instance: 0),
            external,
            node(peq, instance: 14),
        ]
        let companions: [UUID: UInt32] = [chain[1].id: 301, chain[2].id: 302, chain[3].id: 303,
                                          chain[4].id: 304, chain[5].id: 305]
        let after: [UUID: UInt32] = [chain[1].id: 201]

        let got = ETChainEditing.descriptors(chain: chain, probes: [:], afterProbes: after,
                                             companions: companions)
        XCTAssertEqual(got.map(\.instance), [11, 12, 301, 201, 13, 0, 14, 305])
        XCTAssertEqual(got.map(\.enabled), [1, 1, 2, 2, 0, 1, 1, 2])
        XCTAssertEqual([got[2].inputBus, got[2].outputBus], [1, 1])
        XCTAssertEqual(got[2].channelSpec, 3)
        XCTAssertEqual(got[2].sectionGate, 0, "Section の OFF は本体と同じ gate で止まる")
        XCTAssertEqual(got[2].kind, .native)

        XCTAssertEqual(ETChainEditing.descriptors(chain: chain, probes: [:], afterProbes: after),
                       ETChainEditing.descriptors(chain: chain, probes: [:], afterProbes: after, companions: [:]))
    }

    // MARK: - 鎖の段から渡す形へ

    /// Node → Loaded の写しで落とすものが無い。
    func testLoadedFromNodeCopiesEveryField() throws {
        let ir = try spec("IRReverbPlugin")
        var n = ETChainNode(spec: ir, values: ir.defaults.map { $0 + 1 })
        n.enabled = false
        n.inputBus = 1
        n.outputBus = 2
        n.channelSpec = 18
        n.irId = "abc"
        n.display = ["cl": "x"]
        n.externalID = "au:y"
        n.externalInstanceID = "i"
        n.externalState = Data([9])
        let l = PipelineStore.Loaded(n)
        XCTAssertEqual(l.spec.type, ir.type)
        XCTAssertEqual(l.values, n.values)
        XCTAssertFalse(l.enabled)
        XCTAssertEqual([l.inputBus, l.outputBus], [1, 2])
        XCTAssertEqual(l.channelSpec, 18)
        XCTAssertEqual(l.irId, "abc")
        XCTAssertEqual(l.display, ["cl": "x"])
        XCTAssertEqual(l.externalID, "au:y")
        XCTAssertEqual(l.externalInstanceID, "i")
        XCTAssertEqual(l.externalState, Data([9]))
        XCTAssertFalse(l.isRootReset)

        var r = ETChainNode(spec: ETSection.spec, values: [])
        r.isRootReset = true
        let lr = PipelineStore.Loaded(r)
        XCTAssertTrue(lr.isRootReset)
        XCTAssertEqual(lr.externalID, "", "外部でない段は空")
        XCTAssertEqual(PipelineStore.shortForm([r]) .map { $0 as NSDictionary },
                       PipelineStore.shortForm([lr]).map { $0 as NSDictionary })
    }

    // MARK: - 1段を足す

    func testPresetIndexOfTarget() {
        XCTAssertNil(ETChainEditing.AddTarget.end.presetIndex)
        XCTAssertEqual(ETChainEditing.AddTarget.card(3).presetIndex, 3)
        XCTAssertEqual(ETChainEditing.AddTarget.gap(3).presetIndex, 3)
        // 見出しの真下は、プリセットなら見出しの下の行の手前（今までの .gap と同じ）。
        XCTAssertEqual(ETChainEditing.AddTarget.head(section: 1, next: 5).presetIndex, 5)
        XCTAssertNil(ETChainEditing.AddTarget.head(section: 1, next: nil).presetIndex)
    }
}
