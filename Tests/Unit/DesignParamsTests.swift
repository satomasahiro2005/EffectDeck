//  DesignParamsTests.swift
//  designerで作る4種の設計の材料（DesignParams.swiftのETDesignParam）。
//
//  5Band FIR PEQの帯域・位相・タップ数はカーネルのパラメータではないので、前は置き場（メモリ）にしか
//  無かった。再起動・プリセット・共有リンク・バックアップを通すと既定へ戻り、fd:16384を持つ鎖が
//  Minimum Phase・遅延0で戻っていた。上流と同じ綴りでNode.designに持ち、鎖に書いて読み戻せるかを見る。

import XCTest

final class DesignParamsTests: XCTestCase {

    private let fir = ETDesignParam.fiveBandFIRPEQ

    // MARK: -道具

    private func spec(_ type: String) throws -> ETEffect {
        try XCTUnwrap(ETCatalog.first { $0.type == type }, "カタログに無い: \(type)")
    }

    private func loaded(_ type: String, design: [String: String],
                        values: [Float]? = nil) throws -> PipelineStore.Loaded {
        let spec = try spec(type)
        return PipelineStore.Loaded(spec: spec, values: values ?? spec.defaults, enabled: true,
                                    inputBus: 0, outputBus: 0, channelSpec: -1, design: design)
    }

    private func json(_ text: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    /// 既定から外した5Band FIR PEQ。どの鍵も既定と違う値にしてある。
    private var firSettings: BandFIRPEQSettings {
        var s = BandFIRPEQSettings.default
        s.phase = .linear
        s.taps = .taps16384
        s.latency = .block512
        s.bands[0] = BandFIRPEQBand(enabled: false, type: .highPass, frequency: 31.5,
                                    gain: 0, q: 0.5, slope: 24)
        s.bands[2] = BandFIRPEQBand(enabled: true, type: .peaking, frequency: 1234.5,
                                    gain: -6.3, q: 2.25, slope: 12)
        s.bands[4] = BandFIRPEQBand(enabled: true, type: .highShelf, frequency: 9000,
                                    gain: 4.5, q: 0.7, slope: 12)
        return s
    }

    /// 段から設定を組む（BandFIRPEQDesignerStore.settingsと同じ引き方）。
    private func firSettings(of item: PipelineStore.Loaded) -> BandFIRPEQSettings {
        func value(_ name: String) -> Float? {
            guard let p = item.spec.params.first(where: { $0.name == name }),
                  item.values.indices.contains(p.offset) else { return nil }
            return item.values[p.offset]
        }
        return BandFIRPEQSettings(designParams: item.design,
                                  latency: BandFIRPEQLatency(parameterIndex: value("latencyMode") ?? 1),
                                  filterDelaySamples: value("filterDelaySamples"))
    }

    /// designerが鎖へ書き戻したあとの5Band FIR PEQ。ltとfdはdesignerがstageで書く値。
    private func firItem() throws -> PipelineStore.Loaded {
        let s = firSettings
        var values = try spec(fir).defaults
        values[0] = s.latency.parameterIndex
        values[1] = Float(s.taps.rawValue / 2)
        return try loaded(fir, design: s.designParams, values: values)
    }

    // MARK: -表

    /// 表を持つのは4種だけ。鍵はcatalogの鍵とも表示の鍵とも重ならない（重なると値が二重に書かれる）。
    func testTablesCoverTheFourDesignerTypes() throws {
        XCTAssertEqual(ETDesignParam.table(for: fir).count, 2 + 6 * 5)
        XCTAssertEqual(Set(ETDesignParam.table(for: ETDesignParam.groupDelayEQ).keys),
                       Set(["tp"] + (0..<15).map { "d\($0)" }))
        XCTAssertEqual(ETDesignParam.table(for: ETDesignParam.groupDelayPEQ).count, 1 + 5 * 5)
        XCTAssertEqual(Set(ETDesignParam.table(for: ETDesignParam.firCrossover).keys),
                       ["pm", "tp", "f1", "f2", "f3", "s1", "s2", "s3"])
        for type in ["RoomEqPlugin", "CrosstalkCancellationPlugin", "BassManagementPlugin",
                     "VolumePlugin", ""] {
            XCTAssertTrue(ETDesignParam.table(for: type).isEmpty, type)
        }
        XCTAssertEqual(Set(ETDesignParam.table(for: ETDesignParam.irReverb).keys),
                       ["dc", "co", "dt", "tr"])
        for type in [fir, ETDesignParam.groupDelayEQ, ETDesignParam.groupDelayPEQ,
                     ETDesignParam.firCrossover, ETDesignParam.irReverb] {
            let spec = try spec(type)
            let keys = Set(ETDesignParam.table(for: type).keys)
            XCTAssertTrue(keys.isDisjoint(with: spec.params.map(\.key)), type)
            XCTAssertTrue(keys.isDisjoint(with: ETDisplayParam.table(for: type).keys), type)
        }
    }

    // MARK: - 5Band FIR PEQの往復

    /// 設定 → 材料 → 設定で同じものに戻る。
    func testFIRSettingsRoundTrip() {
        let s = firSettings
        XCTAssertEqual(BandFIRPEQSettings(designParams: s.designParams, latency: s.latency), s)
    }

    /// 再起動（pipeline.last）。saveLastと同じくJSONにして、loadLastと同じく読む。
    func testFIRSurvivesRestart() throws {
        let data = try JSONSerialization.data(withJSONObject: PipelineStore.shortForm([try firItem()]),
                                              options: [.sortedKeys])
        let back = PipelineStore.parse(try JSONSerialization.jsonObject(with: data), catalog: ETCatalog)
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(firSettings(of: back[0]), firSettings)
    }

    /// 自分のプリセット（鎖）。PresetStoreはショート形式をそのままUserDefaultsの辞書に入れる。
    func testFIRSurvivesUserPreset() throws {
        let form = PipelineStore.shortForm([try firItem()])
        let data = try PropertyListSerialization.data(fromPropertyList: ["Mine": form],
                                                      format: .binary, options: 0)
        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let back = PipelineStore.parse(try XCTUnwrap(plist["Mine"]), catalog: ETCatalog)
        XCTAssertEqual(firSettings(of: try XCTUnwrap(back.first)), firSettings)
    }

    /// effectdeck.nemut.aiのリンク。parseCheckedと同じ道（json → prepare → parse）で読む。
    /// **材料の鍵を「読まなかった鍵」として出さない。**
    func testFIRSurvivesDeckLink() throws {
        let data = try JSONSerialization.data(withJSONObject: PipelineStore.shortForm([try firItem()]),
                                              options: [.withoutEscapingSlashes, .sortedKeys])
        let link = "https://effectdeck.nemut.ai/?p="
            + data.base64EncodedString().replacingOccurrences(of: "+", with: "%2B")
        let json = try XCTUnwrap(ETChainText.json(from: link))
        let prepared = ETChainText.prepare(json, catalog: ETCatalog)
        XCTAssertTrue(prepared.report.isEmpty, prepared.report.message)
        let back = PipelineStore.parse(prepared.json, catalog: ETCatalog)
        XCTAssertEqual(firSettings(of: try XCTUnwrap(back.first)), firSettings)
    }

    /// effetune.frieve.comへ渡す形にも同じ綴りで載る（上流が読む鍵）。
    func testFIRUpstreamFormCarriesTheKeys() throws {
        let entry = try XCTUnwrap(ETShareLink.effeTuneForm([try firItem()]).first)
        XCTAssertEqual(entry["pm"] as? String, "lin")
        XCTAssertEqual(entry["tp"] as? Double, 16384)
        XCTAssertEqual(entry["t0"] as? String, "hp")
        XCTAssertEqual(entry["e0"] as? Bool, false)
        XCTAssertEqual(entry["f2"] as? Double, 1234.5)
        XCTAssertEqual(entry["g2"] as? Double, -6.3)
    }

    /// バックアップ（ロング形式）。材料は`parameters`の中に入る。
    func testFIRSurvivesBackup() throws {
        let long = PipelineStore.longForm([try firItem()])
        let list = try XCTUnwrap(long["pipeline"] as? [[String: Any]])
        let parameters = try XCTUnwrap(list.first?["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["pm"] as? String, "lin")
        let data = try JSONSerialization.data(withJSONObject: long, options: [.sortedKeys])
        let back = PipelineStore.parse(try JSONSerialization.jsonObject(with: data), catalog: ETCatalog)
        XCTAssertEqual(firSettings(of: try XCTUnwrap(back.first)), firSettings)
    }

    /// エフェクトのプリセット。保存する辞書に材料が入り、当てるときはETDesignParam.readで拾う
    /// （EffeTuneDSP.setValuesのdesign）。入れないとlt / fdしか残らなかった。
    func testFIRSurvivesEffectPreset() throws {
        let item = try firItem()
        var node = ETChainNode(spec: item.spec, values: item.values)
        node.design = item.design
        let core = EffectPresetStoreCore(storage: ETMemoryStorage(), patch: { _, _ in })
        XCTAssertTrue(core.save("Mine", effect: node.spec.name,
                                params: EffectPresetStoreCore.params(for: node)))
        let params = try XCTUnwrap(core.params(of: node.spec.name, name: "Mine"))
        let design = ETDesignParam.read(params, type: fir)
        let values = EffectPresetApply.values(for: item.spec, params: params, current: item.spec.defaults)
        let applied = try loaded(fir, design: design, values: values)
        XCTAssertEqual(firSettings(of: applied), firSettings)
    }

    /// プリセットが書いていない鍵は今のまま残る（上流のsetParametersと同じ）。
    /// 型の材料でない鍵（vlなど）と読めない値は拾わない。
    func testPresetOverlaysOnlyTheKeysItCarries() {
        let now = ["pm": "lin", "f0": "100.0", "tp": "4096.0"]
        let params: [String: Any] = ["f0": 200, "g1": "-3", "vl": 5, "q2": "abc"]
        XCTAssertEqual(ETDesignParam.applying(params, to: now, type: fir),
                       ["pm": "lin", "f0": "200.0", "g1": "-3.0", "tp": "4096.0"])
        XCTAssertEqual(ETDesignParam.applying([:], to: now, type: fir), now)
        XCTAssertEqual(ETDesignParam.applying(params, to: [:], type: "VolumePlugin"), [:])
    }

    // MARK: - 5Band FIR PEQの読み方

    /// web版が書く形そのもの。ltは添字ではなく綴りで来る。
    func testFIRReadsUpstreamJSON() throws {
        let back = PipelineStore.parse(try json(#"""
            [{"nm":"5Band FIR PEQ","en":true,"lt":"256","fd":16384,"dy":0,"gn":0,
              "pm":"lin","tp":32768,
              "f0":80,"g0":3,"q0":0.9,"s0":12,"t0":"ls","e0":true,
              "f1":316,"g1":0,"q1":0.7,"s1":48,"t1":"hp","e1":false,
              "f2":1000,"g2":-2.5,"q2":1.4,"s2":12,"t2":"pk","e2":true,
              "f3":3160,"g3":0,"q3":0.7,"s3":12,"t3":"pk","e3":true,
              "f4":10000,"g4":0,"q4":0.7,"s4":12,"t4":"pk","e4":true}]
            """#), catalog: ETCatalog)
        let s = firSettings(of: try XCTUnwrap(back.first))
        XCTAssertEqual(s.phase, .linear)
        XCTAssertEqual(s.taps, .taps32768)
        XCTAssertEqual(s.latency, .block256)
        XCTAssertEqual(s.bands[0], BandFIRPEQBand(enabled: true, type: .lowShelf, frequency: 80,
                                                  gain: 3, q: 0.9, slope: 12))
        XCTAssertEqual(s.bands[1].type, .highPass)
        XCTAssertEqual(s.bands[1].slope, 48)
        XCTAssertFalse(s.bands[1].enabled)
        XCTAssertEqual(s.bands[2].gain, -2.5)
    }

    /// シミュレータで見た形。材料を書いていなかった頃の鎖はfdだけを持つ。
    /// **pmもtpも無ければfdから線形位相とタップ数を戻す**（戻さないとMinimum Phase・遅延0になる）。
    func testFIROldChainWithOnlyFDComesBackLinear() throws {
        let back = PipelineStore.parse(try json(#"[{"nm":"5Band FIR PEQ","lt":"128","fd":16384}]"#),
                                       catalog: ETCatalog)
        let item = try XCTUnwrap(back.first)
        XCTAssertTrue(item.design.isEmpty)
        let s = firSettings(of: item)
        XCTAssertEqual(s.phase, .linear)
        XCTAssertEqual(s.taps, .taps32768)
        XCTAssertEqual(s.bands, BandFIRPEQSettings.default.bands)

        // fdが0なら最小位相のまま。pmがあればfdは見ない（上流はfdをpmとtpから作るだけ）。
        XCTAssertEqual(BandFIRPEQSettings(designParams: [:], filterDelaySamples: 0).phase, .minimum)
        XCTAssertEqual(BandFIRPEQSettings(designParams: ["pm": "min"],
                                          filterDelaySamples: 16384).phase, .minimum)
        // 選択肢に無いタップ数になるfdは、位相だけ戻す。
        let odd = BandFIRPEQSettings(designParams: [:], filterDelaySamples: 1000)
        XCTAssertEqual(odd.phase, .linear)
        XCTAssertEqual(odd.taps, BandFIRPEQSettings.default.taps)
    }

    /// 上流のsetParametersと同じ寄せ方。範囲の外は端、数でなければ前の値、知らない綴りは捨てる。
    func testFIRNormalizesLikeUpstream() {
        let s = BandFIRPEQSettings(designParams: [
            "pm": "linear", "tp": "12345",
            "f0": "5", "g0": "99", "q0": "0", "s0": "999",
            "f1": "nan", "g1": "abc", "t1": "zz", "e1": "maybe",
            "t2": "no", "tp ": "8192",
        ])
        let d = BandFIRPEQSettings.default
        XCTAssertEqual(s.phase, d.phase)
        XCTAssertEqual(s.taps, d.taps)
        XCTAssertEqual(s.bands[0].frequency, 20)
        XCTAssertEqual(s.bands[0].gain, 20)
        XCTAssertEqual(s.bands[0].q, 0.1)
        XCTAssertEqual(s.bands[0].slope, 384)
        XCTAssertEqual(s.bands[1], d.bands[1])
        XCTAssertEqual(s.bands[2].type, .notch)
    }

    /// 保存形式から読むとき。数は字でも受け（parseFiniteNumber）、真偽はBoolean(x)。
    func testReadAcceptsUpstreamLooseTypes() throws {
        let params = try XCTUnwrap(try json(#"""
            {"tp":"16384","f0":" 120 ","e0":0,"e1":"x","e2":"","t0":5,"g0":"inf","pm":"lin"}
            """#) as? [String: Any])
        let d = ETDesignParam.read(params, type: fir)
        XCTAssertEqual(d["tp"], "16384.0")
        XCTAssertEqual(d["f0"], "120.0")
        XCTAssertEqual(d["e0"], "false")
        XCTAssertEqual(d["e1"], "true")
        XCTAssertEqual(d["e2"], "false")
        XCTAssertNil(d["t0"])
        XCTAssertNil(d["g0"])
        XCTAssertEqual(d["pm"], "lin")
        XCTAssertEqual(BandFIRPEQSettings(designParams: d).taps, .taps16384)
        // 型の違う表の鍵は読まない。
        XCTAssertEqual(ETDesignParam.read(params, type: "VolumePlugin"), [:])
    }

    /// 書く型は上流のもの（字・数・真偽）。
    func testWriteUsesUpstreamTypes() {
        var o: [String: Any] = [:]
        ETDesignParam.write(firSettings.designParams, type: fir, into: &o)
        XCTAssertEqual(o.count, ETDesignParam.table(for: fir).count)
        for (key, kind) in ETDesignParam.table(for: fir) {
            switch kind {
            case .text: XCTAssertTrue(o[key] is String, key)
            case .number: XCTAssertTrue(o[key] is Double, key)
            case .flag: XCTAssertTrue(o[key] is Bool, key)
            }
        }
        // 表に無い鍵は書かない。
        var none: [String: Any] = [:]
        ETDesignParam.write(["zz": "1", "lt": "3"], type: fir, into: &none)
        XCTAssertTrue(none.isEmpty)
    }

    // MARK: - Group Delay EQ

    func testGroupDelayEQRoundTrip() throws {
        var delays = [Double](repeating: 0, count: GroupDelayEQDesign.bands.count)
        delays[0] = 12.5
        delays[7] = -3.2
        delays[14] = 0.1
        let item = try loaded(ETDesignParam.groupDelayEQ,
                              design: GroupDelayEQDesign.designParams(taps: 8192, delaysMs: delays))
        let data = try JSONSerialization.data(withJSONObject: PipelineStore.shortForm([item]))
        let back = try XCTUnwrap(PipelineStore.parse(try JSONSerialization.jsonObject(with: data),
                                                     catalog: ETCatalog).first)
        let taps = GroupDelayEQDesign.taps(designParams: back.design, filterDelaySamples: 8192)
        XCTAssertEqual(taps, 8192)
        XCTAssertEqual(GroupDelayEQDesign.delays(designParams: back.design, taps: taps,
                                                 sampleRate: 48000), delays)
    }

    /// tpが無ければfd（taps/2）から。遅延はタップ数とレートで決まる限界で挟む（group_delay_eq.js:154-160）。
    func testGroupDelayEQFallbackAndClamp() {
        XCTAssertEqual(GroupDelayEQDesign.taps(designParams: [:], filterDelaySamples: 2048), 4096)
        XCTAssertEqual(GroupDelayEQDesign.taps(designParams: [:], filterDelaySamples: 1000), 16384)
        XCTAssertEqual(GroupDelayEQDesign.taps(designParams: ["tp": "32768.0"],
                                               filterDelaySamples: 2048), 32768)
        XCTAssertEqual(GroupDelayEQDesign.taps(designParams: ["tp": "5000"], filterDelaySamples: nil),
                       16384)
        let limit = GroupDelayEQDesign.uiDelayLimitMs(taps: 4096, sampleRate: 48000)
        let delays = GroupDelayEQDesign.delays(designParams: ["d0": "999", "d1": "-999", "d2": "x"],
                                               taps: 4096, sampleRate: 48000)
        XCTAssertEqual(delays[0], limit)
        XCTAssertEqual(delays[1], -limit)
        XCTAssertEqual(delays[2], 0)
        XCTAssertEqual(delays.count, GroupDelayEQDesign.bands.count)
    }

    // MARK: - Group Delay PEQ

    func testGroupDelayPEQRoundTrip() throws {
        var s = GroupDelayPEQSettings(latencySamples: 256, sampleRate: 48000)
        s.taps = 8192
        s.bands[1] = GroupDelayPEQBand(shape: .lowShelf, frequency: 250, delayMs: 2.5, q: 1.2,
                                       enabled: false)
        s.bands[3] = GroupDelayPEQBand(shape: .filterGD, frequency: 4000, delayMs: -1.5, q: 3,
                                       enabled: true)
        let item = try loaded(ETDesignParam.groupDelayPEQ, design: s.designParams)
        let data = try JSONSerialization.data(withJSONObject: PipelineStore.shortForm([item]))
        let back = try XCTUnwrap(PipelineStore.parse(try JSONSerialization.jsonObject(with: data),
                                                     catalog: ETCatalog).first)
        let restored = GroupDelayPEQSettings(latencySamples: 256, sampleRate: 48000)
            .applying(designParams: back.design)
        XCTAssertEqual(restored, s)
    }

    /// 材料が空なら既定の帯域（Resetと同じ）。レート・処理幅・ltは材料ではないので残る。
    func testGroupDelayPEQEmptyDesignIsDefault() {
        var edited = GroupDelayPEQSettings(latencySamples: 512, sampleRate: 96000, processingChannels: 4)
        edited.taps = 4096
        edited.bands[0].delayMs = 3
        let reset = edited.applying(designParams: [:])
        XCTAssertEqual(reset.bands, GroupDelayPEQSettings.defaultBands)
        XCTAssertEqual(reset.taps, 16384)
        XCTAssertEqual(reset.latencySamples, 512)
        XCTAssertEqual(reset.sampleRate, 96000)
        XCTAssertEqual(reset.processingChannels, 4)
    }

    /// dはtpで決まる限界で挟む。qとfは上流の範囲、知らない形は捨てる。
    func testGroupDelayPEQNormalizes() {
        let s = GroupDelayPEQSettings().applying(designParams: [
            "tp": "4096", "d0": "500", "q0": "0.01", "f0": "1", "t0": "zz", "e0": "false",
        ])
        XCTAssertEqual(s.taps, 4096)
        XCTAssertEqual(s.bands[0].delayMs, s.delayLimitMs)
        XCTAssertEqual(s.bands[0].q, GroupDelayPEQDesignCore.minimumQ)
        XCTAssertEqual(s.bands[0].frequency, GroupDelayPEQDesignCore.minimumFrequency)
        XCTAssertEqual(s.bands[0].shape, .peak)
        XCTAssertFalse(s.bands[0].enabled)
    }

    // MARK: - FIR Crossover

    /// web版が書く形。bcとltはparamsに、残りはNode.designに入る。
    func testFIRCrossoverReadsUpstreamJSON() throws {
        let back = PipelineStore.parse(try json(#"""
            [{"nm":"FIR Crossover","lt":"256","bc":3,"pm":"lin","tp":65536,
              "f1":120,"s1":-48,"f2":2500,"s2":-96,"f3":8000,"s3":-24}]
            """#), catalog: ETCatalog)
        let item = try XCTUnwrap(back.first)
        var s = FIRCrossoverSettings().applying(designParams: item.design)
        s.bandCount = 3
        s.clamp()
        XCTAssertEqual(s.phase, .linear)
        XCTAssertEqual(s.taps, 65536)
        XCTAssertEqual(s.frequencies, [120, 2500, 8000])
        XCTAssertEqual(s.slopes, [-48, -96, -24])

        // 書き戻すと同じ綴りで残る（画面から変える口は無いので、読んだものをそのまま運ぶ）。
        let again = try XCTUnwrap(PipelineStore.shortForm([item]).first)
        XCTAssertEqual(again["pm"] as? String, "lin")
        XCTAssertEqual(again["f1"] as? Double, 120)
    }

    /// 傾きはMath.round(Number(x))が選択肢に入るときだけ。材料が空なら既定。
    func testFIRCrossoverNormalizes() {
        let s = FIRCrossoverSettings().applying(designParams: [
            "s1": "-47.6", "s2": "-50", "tp": "1234", "pm": "full", "f1": "nan",
        ])
        XCTAssertEqual(s.slopes, [-48, -24, -24])
        XCTAssertEqual(s.taps, FIRCrossoverSettings().taps)
        XCTAssertEqual(s.phase, .minimum)
        XCTAssertEqual(s.frequencies[0], 2000)

        var edited = FIRCrossoverSettings()
        edited.phase = .linear
        edited.frequencies = [100, 200, 300]
        edited.latencyModeIndex = 3
        edited.bandCount = 4
        let reset = edited.applying(designParams: [:])
        XCTAssertEqual(reset.phase, .minimum)
        XCTAssertEqual(reset.frequencies, FIRCrossoverSettings().frequencies)
        XCTAssertEqual(reset.latencyModeIndex, 3)
        XCTAssertEqual(reset.bandCount, 4)
    }

    // MARK: - IR Reverb

    /// dc / co / dt / trは上流の綴りと型で鎖に書き（ir_reverb.js:171-174）、読み戻せる。
    /// effectdeck.nemut.aiのリンクで読んでも「読まなかった鍵」として出さない。
    func testIRReverbPreparationRoundTrip() throws {
        let item = try loaded(ETDesignParam.irReverb,
                              design: ["dc": "false", "co": "-3.5", "dt": "250.0", "tr": "40.0"])
        let entry = try XCTUnwrap(PipelineStore.shortForm([item]).first)
        XCTAssertEqual(entry["dc"] as? Bool, false)
        XCTAssertEqual(entry["co"] as? Double, -3.5)
        XCTAssertEqual(entry["dt"] as? Double, 250)
        XCTAssertEqual(entry["tr"] as? Double, 40)

        let data = try JSONSerialization.data(withJSONObject: PipelineStore.shortForm([item]),
                                              options: [.withoutEscapingSlashes, .sortedKeys])
        let link = "https://effectdeck.nemut.ai/?p="
            + data.base64EncodedString().replacingOccurrences(of: "+", with: "%2B")
        let prepared = ETChainText.prepare(try XCTUnwrap(ETChainText.json(from: link)),
                                           catalog: ETCatalog)
        XCTAssertTrue(prepared.report.isEmpty, prepared.report.message)
        let back = try XCTUnwrap(PipelineStore.parse(prepared.json, catalog: ETCatalog).first)
        let o = ETIRPreparation.Options(designParams: back.design)
        XCTAssertFalse(o.directCut)
        XCTAssertEqual(o.cutOffsetMs, -3.5)
        XCTAssertEqual(o.decayPercent, 250)
        XCTAssertEqual(o.trimPercent, 40)
    }

    /// 鍵の無い鎖（つまみを出す前のもの）は上流の既定（ir_reverb.js:37-40）のまま。
    /// 範囲の外は端へ寄せる（:242-244のparseFiniteNumber）。
    func testIRReverbPreparationDefaultsAndClamp() {
        let d = ETIRPreparation.Options(designParams: [:])
        XCTAssertTrue(d.directCut)
        XCTAssertEqual(d.cutOffsetMs, 0)
        XCTAssertEqual(d.decayPercent, 100)
        XCTAssertEqual(d.trimPercent, 100)

        let c = ETIRPreparation.Options(designParams: ["co": "99", "dt": "1", "tr": "0"])
        XCTAssertTrue(c.directCut)
        XCTAssertEqual(c.cutOffsetMs, 50)
        XCTAssertEqual(c.decayPercent, 10)
        XCTAssertEqual(c.trimPercent, 1)
    }

    // MARK: - lt

    func testLatencyFromParameterIndex() {
        XCTAssertEqual(BandFIRPEQLatency(parameterIndex: 0), .zero)
        XCTAssertEqual(BandFIRPEQLatency(parameterIndex: 4), .block1024)
        XCTAssertEqual(BandFIRPEQLatency(parameterIndex: 2.4), .block256)
        XCTAssertEqual(BandFIRPEQLatency(parameterIndex: 9), .block128)
        XCTAssertEqual(BandFIRPEQLatency(parameterIndex: .nan), .block128)
    }
}
