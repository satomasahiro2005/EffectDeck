//  Upstream213Tests.swift
//  EffeTune 2.13.0（DSP 0.13.0）で増えた・変わったものの、保存形式と枠の読み。**実機もエンジンも要らない。**
//
//    - 新しい 2 種（Adaptive Prediction・SFZ Note Player）がカタログに入っていること
//    - Note Spectrogram の nc（Regular Note Limit）が無くなり、nc を持つ古い鎖も読めること
//    - Cassette Artifacts に md（Mode）が増え、書いていない鎖は All（今までの動き）で読むこと
//    - Adaptive Prediction の resetToken（実行時の数）を保存形式に書かず・読まず・比べないこと
//    - 読み込みで上流の setParameters と同じ所へ着地すること（Weight Decay、SFZ の音域と強さ）
//    - Adaptive Prediction は All（-2）に置くと素通し（上流の supportedChannelModes）
//    - 枠の版: Note Spectrogram は 24 / 5（8840 バイト）、Rhythm Analyzer は 28 / 4（1496 バイト）

import XCTest

final class Upstream213Tests: XCTestCase {

    private func spec(_ type: String) throws -> ETEffect {
        try XCTUnwrap(ETCatalog.first { $0.type == type }, "カタログに無い: \(type)")
    }

    private func param(_ s: ETEffect, _ key: String) throws -> ETParam {
        try XCTUnwrap(s.params.first { $0.key == key }, "\(s.type) に \(key) が無い")
    }

    private func load(_ s: ETEffect, _ dict: [String: Any], current: [Float]? = nil) -> [Float] {
        ETParamCoding.decode(params: s.params, defaults: current ?? s.defaults, from: dict, type: s.type)
    }

    // MARK: カタログ

    func testUpstreamVersionIs0_13_0() {
        XCTAssertEqual(ETUpstreamVersion, "0.13.0")
        XCTAssertEqual(ETUpstreamAppVersion, "2.13.0", "package.json の版。公式の PC との食い違いの表示に使う")
    }

    func testNewEffectsAreInTheCatalog() throws {
        XCTAssertEqual(ETCatalog.count, 112)

        let ape = try spec("AdaptivePredictionEffectPlugin")
        XCTAssertEqual(ape.name, "Adaptive Prediction")
        XCTAssertEqual(ape.category, "resonator")
        XCTAssertEqual(ape.paramsHash, 0xebd8a6f0)
        XCTAssertEqual(ape.floatCount, 10)
        XCTAssertEqual(ape.params.map(\.key),
                       ["gap", "learn", "weightDecay", "autonomy", "original", "residual", "prediction",
                        "freeze", "hold", "resetToken"])
        XCTAssertEqual(ape.defaults, [1, 0.02, 0, 0, 0, 1, 0, 0, 0, 0])
        // Gap の刻みは createUI の addParameter（0.1 ms）。params.json は 0.01。
        if case .number(let lo, let hi, let step, let unit, _) = try param(ape, "gap").kind {
            XCTAssertEqual([lo, hi, step], [0, 500, 0.1])
            XCTAssertEqual(unit, "ms")
        } else { XCTFail("gap は数") }
        // Weight Decay は 0 が無限大なので、範囲は params.json のまま（画面の目盛りは 0.5 から）。
        if case .number(let lo, let hi, _, let unit, _) = try param(ape, "weightDecay").kind {
            XCTAssertEqual([lo, hi], [0, 60])
            XCTAssertEqual(unit, "s")
        } else { XCTFail("weightDecay は数") }

        let sfz = try spec("SFZNotePlayerPlugin")
        XCTAssertEqual(sfz.name, "SFZ Note Player")
        XCTAssertEqual(sfz.category, "others")
        XCTAssertEqual(sfz.paramsHash, 0x0f17627c)
        XCTAssertEqual(sfz.floatCount, 16)
        // 並びと名前は createUI の表（sfz_note_player.js:522-539）。
        XCTAssertEqual(sfz.params.map(\.key),
                       ["hi", "md", "lo", "th", "rd", "nh", "vf", "vc", "pl", "dm", "wm", "os", "og", "tm",
                        "mn", "mx"])
        XCTAssertEqual(sfz.params.map(\.label),
                       ["Highest", "Middle", "Lowest", "Threshold", "Retrigger Drop", "Note Hold",
                        "Velocity 1 Level", "Velocity 127 Level", "Max Voices", "Dry", "Wet", "Octave",
                        "Output Gain", "Timing", "Lowest Note", "Highest Note"])
        if case .number(let lo, let hi, let step, let unit, _) = try param(sfz, "rd").kind {
            XCTAssertEqual([lo, hi, step], [1, 96, 1])
            XCTAssertEqual(unit, "dB")
        } else { XCTFail("rd は数") }
        if case .number(_, _, let step, let unit, _) = try param(sfz, "tm").kind {
            XCTAssertEqual(step, 1)
            XCTAssertEqual(unit, "ms")
        } else { XCTFail("tm は数") }
        XCTAssertEqual(try param(sfz, "dm").defaultValue, 20, "資産が無いと dry だけが鳴る（既定 20%）")
    }

    // MARK: Note Spectrogram の nc

    func testNoteSpectrogramLostRegularNoteLimit() throws {
        let s = try spec("NoteSpectrogramPlugin")
        XCTAssertEqual(s.paramsHash, 0x9d70750b)
        XCTAssertEqual(s.floatCount, 2)
        XCTAssertEqual(s.params.map(\.key), ["mn", "mx"])
        // 2.12.0 までの鎖は nc を持つ。読めて、ほかの値は残る。
        let loaded = PipelineStore.parse([["nm": "Note Spectrogram", "nc": 4, "mn": 40, "mx": 80]],
                                         catalog: ETCatalog)
        let item = try XCTUnwrap(loaded.first)
        XCTAssertEqual(item.spec.type, s.type)
        XCTAssertEqual(item.values, [40, 80])
        XCTAssertNil(PipelineStore.shortForm(loaded)[0]["nc"])
    }

    // MARK: Cassette Artifacts の Mode

    func testCassetteModeDefaultsToAll() throws {
        let s = try spec("CassetteArtifactsPlugin")
        XCTAssertEqual(s.paramsHash, 0x328491ae)
        XCTAssertEqual(s.floatCount, 13)
        let md = try param(s, "md")
        XCTAssertEqual(md.offset, 12)
        XCTAssertEqual(s.params.first?.key, "md", "画面では先頭")
        guard case .enumeration(let modes) = md.kind else { return XCTFail("md は選択") }
        XCTAssertEqual(modes, ["Encode Only", "Encode + Artifacts", "All", "Artifacts + Decode", "Decode Only"])
        XCTAssertEqual(md.defaultValue, 2)
        // 書いていなければ All（2.12.0 までの動き）。
        XCTAssertEqual(load(s, ["dg": "Hi-Fi"])[md.offset], 2)
        XCTAssertEqual(load(s, ["md": "Decode Only"])[md.offset], 4)
        XCTAssertEqual(ETParamCoding.encode(params: s.params, values: s.defaults)["md"] as? String, "All")
        // 出荷時プリセット 5 件は md を書いている。
        let presets = ETEffectPresetList.filter { $0.effect == "Cassette Artifacts" }
        XCTAssertEqual(presets.count, 5)
        for preset in presets { XCTAssertEqual(preset.params["md"] as? String, "All", preset.presetId) }
    }

    // MARK: Adaptive Prediction

    func testResetTokenIsRuntimeOnly() throws {
        let s = try spec("AdaptivePredictionEffectPlugin")
        let token = try param(s, "resetToken")
        XCTAssertTrue(token.runtimeOnly)
        XCTAssertEqual(token.offset, 9)
        XCTAssertEqual(s.params.filter(\.runtimeOnly).map(\.key), ["resetToken"])
        var values = s.defaults
        values[token.offset] = 7
        XCTAssertNil(ETParamCoding.encode(params: s.params, values: values)["resetToken"], "書かない")
        XCTAssertEqual(load(s, ["resetToken": 9])[token.offset], 0, "読まない")
        XCTAssertEqual(load(s, ["resetToken": 9], current: values)[token.offset], 7, "今の値のまま")
        // 比べない。Reset を押した後（token が 0 でない）も Surprise と一致する。
        XCTAssertEqual(EffectPresetApply.matchingPresetId(for: s, current: values), "surprise")
    }

    func testAdaptivePredictionPresets() throws {
        let s = try spec("AdaptivePredictionEffectPlugin")
        let presets = ETEffectPresetList.filter { $0.effect == "Adaptive Prediction" }
        XCTAssertEqual(presets.map(\.presetId), ["surprise", "prediction", "resonator", "hold"])
        for preset in presets {
            let applied = EffectPresetApply.values(for: s, params: preset.params, current: s.defaults)
            XCTAssertEqual(EffectPresetApply.matchingPresetId(for: s, current: applied), preset.presetId)
        }
    }

    /// adaptive_prediction_effect.js:120-124。0 は無限大のまま、0.5 未満は 0.5。
    func testWeightDecayFloorOnLoad() throws {
        let s = try spec("AdaptivePredictionEffectPlugin")
        let wd = try param(s, "weightDecay")
        XCTAssertEqual(load(s, ["weightDecay": 0])[wd.offset], 0)
        XCTAssertEqual(load(s, ["weightDecay": 0.2])[wd.offset], 0.5)
        XCTAssertEqual(load(s, ["weightDecay": 0.5])[wd.offset], 0.5)
        XCTAssertEqual(load(s, ["weightDecay": 12])[wd.offset], 12)
        var current = s.defaults
        current[wd.offset] = 0.1
        XCTAssertEqual(load(s, [:], current: current)[wd.offset], 0.1, "書いていなければ触らない")
    }

    func testAdaptivePredictionIsBypassedOnAll() {
        let type = "AdaptivePredictionEffectPlugin"
        XCTAssertTrue(ETChainEditing.isChannelBypassed(type: type, channelSpec: -2))
        for ch: Int8 in [-1, 0, 1, 5, 16, 17, 23] {
            XCTAssertFalse(ETChainEditing.isChannelBypassed(type: type, channelSpec: ch), "\(ch)")
        }
    }

    // MARK: SFZ Note Player

    /// sfz_note_player.js:45-60。Highest Note は Lowest Note より下にしない、Velocity 127 は 1 より 1 dB 以上上、
    /// 音域・声数・Octave は Math.round。
    func testSFZRulesOnLoad() throws {
        let s = try spec("SFZNotePlayerPlugin")
        func at(_ v: [Float], _ key: String) throws -> Float { v[try param(s, key).offset] }
        var v = load(s, ["mn": 70, "mx": 60])
        XCTAssertEqual(try at(v, "mn"), 70)
        XCTAssertEqual(try at(v, "mx"), 70)
        v = load(s, ["vf": -20, "vc": -30])
        XCTAssertEqual(try at(v, "vf"), -20)
        XCTAssertEqual(try at(v, "vc"), -19)
        v = load(s, ["vf": 0])
        XCTAssertEqual(try at(v, "vc"), 1, "既定の -10 は 0 + 1 に上がる")
        v = load(s, ["mn": 40.4, "mx": 80.5, "pl": 7.6, "os": -1.5])
        XCTAssertEqual(try at(v, "mn"), 40)
        XCTAssertEqual(try at(v, "mx"), 81)
        XCTAssertEqual(try at(v, "pl"), 8)
        XCTAssertEqual(try at(v, "os"), -1, "Math.round は .5 を +∞ 側へ")
        // 範囲の外の値は、寄せてから規則をかける（上流の parseFiniteNumber が先）。
        v = load(s, ["vf": 5, "vc": -10])
        XCTAssertEqual(try at(v, "vf"), 0)
        XCTAssertEqual(try at(v, "vc"), 1, "vf は 0 に寄り、vc は 0 + 1")
        v = load(s, ["vf": -200, "vc": 99])
        XCTAssertEqual(try at(v, "vf"), -96)
        XCTAssertEqual(try at(v, "vc"), 24)
        v = load(s, ["mn": 5, "mx": 500])
        XCTAssertEqual(try at(v, "mn"), 21)
        XCTAssertEqual(try at(v, "mx"), 108)
        // 画面からの編集にも同じ規則（setValue から）。
        var edited = s.defaults
        edited[try param(s, "mx").offset] = 10
        edited[try param(s, "vc").offset] = -100
        edited = ETUpstreamNormalize.sfzCrossRules(params: s.params, values: edited)
        XCTAssertEqual(try at(edited, "mx"), try at(edited, "mn"))
        XCTAssertEqual(try at(edited, "vc"), try at(edited, "vf") + 1)
        // 書いていなくても毎回かける（上流と同じ）。
        var current = s.defaults
        current[try param(s, "mn").offset] = 90
        current[try param(s, "mx").offset] = 50
        XCTAssertEqual(try at(load(s, [:], current: current), "mx"), 90)
    }

    /// 2.13.0 で Rhythm Analyzer の vt / ve の既定は false になったが、2.12 以前の保存（鍵が無い）は
    /// 触っていない段でも Tempogram と Echo を出していた。鍵の無い保存は true で読み、
    /// 2.13.0 からは触っていなくても毎回書く（上流の getParameters と同じ）。
    func testRhythmAnalyzerLegacyChainKeepsTempogramAndEcho() throws {
        let s = try spec("RhythmAnalyzerPlugin")
        XCTAssertEqual(ETDisplayParam.legacyRead([:], type: s.type)["vt"], "true")
        XCTAssertEqual(ETDisplayParam.legacyRead([:], type: s.type)["ve"], "true")
        XCTAssertEqual(ETDisplayParam.legacyRead(["vt": false], type: s.type)["vt"], "false")
        XCTAssertNil(ETDisplayParam.legacyRead([:], type: "StereoMeterPlugin")["vt"])
        let node = ETChainNode(spec: s, values: s.defaults)
        let written = PipelineStore.shortForm([PipelineStore.Loaded(node)])
        XCTAssertEqual(written[0]["vt"] as? Bool, false, "触っていない 2.13.0 の段は false を書く")
        XCTAssertEqual(written[0]["ve"] as? Bool, false)
        let back = PipelineStore.parse(written, catalog: ETCatalog)
        XCTAssertEqual(back.first?.display["vt"], "false", "書いて読み戻しても false のまま")
        var old = written[0]
        old["vt"] = nil
        old["ve"] = nil
        XCTAssertEqual(PipelineStore.parse([old], catalog: ETCatalog).first?.display["vt"], "true")
        XCTAssertEqual(PipelineStore.parse([old], catalog: ETCatalog).first?.display["ve"], "true")
    }

    /// バンクの鍵は段の `irId` に載せ、保存の綴りは型で決まる（SFZ は `sf`、IR Reverb は `ir`）。
    /// 24 桁の小文字の 16 進でないものは空に戻す（上流の setParameters と同じ）。
    func testSFZBankKeyIsSavedAsSf() throws {
        let id = "0123456789abcdef01234567"
        XCTAssertEqual(ETChainText.assetKey(forType: "SFZNotePlayerPlugin"), "sf")
        XCTAssertEqual(ETChainText.assetKey(forType: "IRReverbPlugin"), "ir")
        var node = ETChainNode(spec: try spec("SFZNotePlayerPlugin"), values: try spec("SFZNotePlayerPlugin").defaults)
        node.irId = id
        let written = PipelineStore.shortForm([PipelineStore.Loaded(node)])
        XCTAssertEqual(written[0]["sf"] as? String, id)
        XCTAssertNil(written[0]["ir"])
        let back = PipelineStore.parse(written, catalog: ETCatalog)
        XCTAssertEqual(back.first?.irId, id, "書いて読み戻すと鍵が残る")
        // 外れた鍵は読まない。
        for bad in ["0123456789ABCDEF01234567", "0123", "", "zzzzzzzzzzzzzzzzzzzzzzzz"] {
            var stage = written[0]
            stage["sf"] = bad
            XCTAssertEqual(PipelineStore.parse([stage], catalog: ETCatalog).first?.irId, "", bad)
        }
        // IR Reverb は今までどおり `ir`。
        var ir = ETChainNode(spec: try spec("IRReverbPlugin"), values: try spec("IRReverbPlugin").defaults)
        ir.irId = "abc"
        let irWritten = PipelineStore.shortForm([PipelineStore.Loaded(ir)])
        XCTAssertEqual(irWritten[0]["ir"] as? String, "abc")
        XCTAssertNil(irWritten[0]["sf"])
        // 利用者のプリセットも同じ綴り。
        XCTAssertEqual(EffectPresetStoreCore.params(for: node)["sf"] as? String, id)
        // PC へ送る形からバンクの鍵が消えたら、params では消せないので鎖ごと送り直す。
        let cleared = try XCTUnwrap(ETRemoteProjection.entry(for: PipelineStore.Loaded({ var n = node; n.irId = ""; return n }())))
        let with = try XCTUnwrap(ETRemoteProjection.entry(for: PipelineStore.Loaded(node)))
        XCTAssertEqual(ETRemoteProjection.removedKeys(sent: with, now: cleared), ["sf"])
    }

    func testSFZIsNotForChains() throws {
        let url = try XCTUnwrap(TestResource.url("effects", "json", subdirectory: "chain/v0.13.0"))
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["dsp"] as? String, "0.13.0")
        let effects = try XCTUnwrap(root["effects"] as? [[String: Any]])
        let sfz = try XCTUnwrap(effects.first { $0["type"] as? String == "SFZNotePlayerPlugin" })
        XCTAssertEqual(sfz["unsupported"] as? String, "it needs an SFZ instrument that the user imports")
        let ape = try XCTUnwrap(effects.first { $0["type"] as? String == "AdaptivePredictionEffectPlugin" })
        XCTAssertNil(ape["unsupported"])
        let keys = (ape["params"] as? [[String: Any]] ?? []).compactMap { $0["key"] as? String }
        XCTAssertFalse(keys.contains("resetToken"))
        XCTAssertEqual(keys.count, 9)
    }

    // MARK: Note Spectrogram の枠（版 5）

    private func noteFrame(version: UInt16 = 5, bytes: Int = 8840, revisionAge: UInt32 = 8,
                           ages: (UInt32, UInt32) = (2, 4), confidence: Float = 0.5,
                           revised: Float = 0.75) -> ETFrame {
        var p = [UInt8](repeating: 0, count: max(bytes, 8840))
        func put(_ b: [UInt8], _ o: Int) { TelemetryBytes.put(b, at: o, into: &p) }
        put(TelemetryBytes.f32(48000), 0)
        put(TelemetryBytes.f32(1.5), 4)
        put([UInt8(440 & 0xff), UInt8(440 >> 8)], 8)
        put([21, 0], 10)
        put(TelemetryBytes.f32(0.02), 12)
        put(TelemetryBytes.u32(100), 16)
        put(TelemetryBytes.u32(5), 20)
        put(TelemetryBytes.u32(3), 24)
        put(TelemetryBytes.u32(revisionAge), 28)
        for i in 0..<440 {
            put(TelemetryBytes.f32(confidence), 32 + 4 * i)
            put(TelemetryBytes.f32(-30), 1792 + 4 * i)
            put(TelemetryBytes.f32(revisionAge == 0 ? 0 : revised), 3552 + 4 * i)
            put(TelemetryBytes.f32(ages.0 == 0 ? 0 : 0.25), 5316 + 4 * i)
            put(TelemetryBytes.f32(ages.1 == 0 ? 0 : 0.125), 7080 + 4 * i)
        }
        put(TelemetryBytes.u32(ages.0), 5312)
        put(TelemetryBytes.u32(ages.1), 7076)
        return ETFrame(type: 24, version: version, tapId: 3, sequence: 1, dropped: false,
                       payload: Array(p.prefix(bytes)))
    }

    func testNoteSpectrogramFrameVersion5() throws {
        XCTAssertEqual(ETNoteFrameLayout.payloadBytes, 8840)
        XCTAssertEqual(ETNoteFrameLayout.levelOffset, 1792)
        XCTAssertEqual(ETNoteFrameLayout.revisedOffset, 3552)
        XCTAssertEqual(ETNoteFrameLayout.intermediateOffset, 5312)
        let s = try XCTUnwrap(ETNoteSnapshot(noteFrame()))
        XCTAssertEqual(s.frameIndex, 100)
        XCTAssertEqual(s.generation, 3)
        XCTAssertEqual(s.hopSeconds, 0.02, accuracy: 1e-7)
        XCTAssertEqual(s.confidence.count, 440)
        XCTAssertEqual(s.confidence[0], 0.5)
        XCTAssertEqual(s.level[439], -30)
        // 並びは上流の MULTI_F0_REVISION_PLANES（2, 4, 8）。
        XCTAssertEqual(s.revisions.map(\.age), [2, 4, 8])
        XCTAssertEqual(s.revisions[0].confidence[10], 0.25)
        XCTAssertEqual(s.revisions[1].confidence[10], 0.125)
        XCTAssertEqual(s.revisions[2].confidence[10], 0.75)
        // 面の age が 0 なら、その直しは無い。
        let early = try XCTUnwrap(ETNoteSnapshot(noteFrame(revisionAge: 0, ages: (2, 0))))
        XCTAssertEqual(early.revisions.map(\.age), [2])
    }

    func testNoteSpectrogramRejectsOtherVersionsAndBadPlanes() {
        XCTAssertNil(ETNoteSnapshot(noteFrame(version: 3)), "2.12.0 の版")
        XCTAssertNil(ETNoteSnapshot(noteFrame(bytes: 3548)), "2.12.0 の長さ")
        XCTAssertNil(ETNoteSnapshot(noteFrame(revisionAge: 7)))
        XCTAssertNil(ETNoteSnapshot(noteFrame(ages: (4, 4))), "面の age は決まっている")
        XCTAssertNil(ETNoteSnapshot(noteFrame(confidence: 1.5)))
        XCTAssertNil(ETNoteSnapshot(noteFrame(revised: -0.1)))
        XCTAssertNil(ETNoteSnapshot(nil))
    }

    // MARK: 枠の版

    func testFrameVersions() {
        XCTAssertEqual(ETNoteFrameLayout.frameType, 24)
        XCTAssertEqual(ETNoteFrameLayout.version, 5)
        XCTAssertEqual(ETFrameType.rhythmAnalyzer.rawValue, 28)
        XCTAssertEqual(ETRhythm.version, 4)
        XCTAssertEqual(ETRhythm.payloadBytes, 1496)
    }

    // MARK: 直しの当て先の列

    /// 帯は 8 列で、10 枠入れた直後（head = 2）。最新の枠 109 は列 1、枠 108 は列 0、枠 107 は列 7。
    private func ledger(first: UInt32, count: Int, columns: Int = 8, generation: UInt32 = 1)
        -> (frames: [(generation: UInt32, index: UInt32)?], head: Int) {
        var frames = [(generation: UInt32, index: UInt32)?](repeating: nil, count: columns)
        var head = 0
        for step in 0..<count {
            frames[head] = (generation, first &+ UInt32(step))
            head = (head + 1) % columns
        }
        return (frames, head)
    }

    func testRevisionColumnFindsTheFrameAgeBack() {
        let l = ledger(first: 100, count: 10)
        XCTAssertEqual(l.head, 2)
        let latest: UInt32 = 109
        XCTAssertEqual(ETNoteFrameLayout.revisionColumn(frames: l.frames, head: l.head, count: 8,
                                                   generation: 1, index: latest &- 2), 7)
        XCTAssertEqual(ETNoteFrameLayout.revisionColumn(frames: l.frames, head: l.head, count: 8,
                                                   generation: 1, index: latest &- 4), 5)
        // 8 枠前は輪（8 列）の外。流れているので何もしない。
        XCTAssertNil(ETNoteFrameLayout.revisionColumn(frames: l.frames, head: l.head, count: 8,
                                                 generation: 1, index: latest &- 8))
    }

    func testRevisionColumnReachesEightFramesBackOnALargeBand() {
        let l = ledger(first: 1000, count: 40, columns: 64)
        XCTAssertEqual(ETNoteFrameLayout.revisionColumn(frames: l.frames, head: l.head, count: 40,
                                                   generation: 1, index: 1039 &- 8), 40 - 1 - 8)
    }

    func testRevisionColumnWrapsFrameIndex() {
        let l = ledger(first: UInt32.max - 3, count: 8, columns: 16)
        // 枠は ... max-1, max, 0, 1, 2, 3。最新（3）の 4 枠前は max。
        XCTAssertEqual(ETNoteFrameLayout.revisionColumn(frames: l.frames, head: l.head, count: 8,
                                                   generation: 1, index: UInt32(3) &- 4), 3)
        XCTAssertEqual(l.frames[3]?.index, UInt32.max)
    }

    func testRevisionColumnIgnoresDroppedFramesAndOtherGenerations() {
        var l = ledger(first: 10, count: 6, columns: 16)
        // 枠 13 を取りこぼした。
        l.frames[3] = nil
        XCTAssertNil(ETNoteFrameLayout.revisionColumn(frames: l.frames, head: l.head, count: 6,
                                                 generation: 1, index: 13))
        XCTAssertNil(ETNoteFrameLayout.revisionColumn(frames: l.frames, head: l.head, count: 6,
                                                 generation: 2, index: 12))
        XCTAssertNil(ETNoteFrameLayout.revisionColumn(frames: l.frames, head: l.head, count: 0,
                                                 generation: 1, index: 12))
    }
}
