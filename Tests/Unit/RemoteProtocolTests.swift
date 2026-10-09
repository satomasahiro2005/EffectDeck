//  RemoteProtocolTests.swift
//  PC の EffeTune を LAN から操る PoC の、通信に触らない部分（DSP/RemoteProtocol.swift）。
//
//  見ているもの:
//    - 外部の段（AU / JSFX）は、同じバスの中なら落ち、バスを渡るなら 0 dB の Volume になる
//    - 落ちた段のぶん、手元の番号 → PC の番号の対応表がずれる（params の宛先）
//    - 外部の段の externalState は PC へ渡す形に入らない（符号化する前に振り分ける）
//    - params には動かせるパラメータのショートキーだけが入る
//    - 接続先の字の読み方（host:port/token・ws:// の URL・読めない字）
//    - v2: QR のリンク（ws://host:port/?t=token）、state の origin / seq の振り分け、
//      プリセットの足し合わせ（名前の付け足し・2 回目は何もしない・PC の字と手元の保存が同じ中身）、
//      IR の塊の切り方と継ぎ方、PC の変更を値だけで当てられるか
//    - telemetry: PC の枠のヘッダの読み方・壊れた項目を落とす・tapId の付け替え・番号の対応表の裏返し
//      PEQ の重ね表示: role の読み方、段ごとの行き先（5Band・15Band・FIR・探りの無い PEQ）、名前違いを落とす
//    - Connected は hello の返事を受けてからだけ（控えの「つなぎたい」では塗らない）。黙った PC を見回りで切る

import XCTest

final class RemoteProtocolTests: XCTestCase {

    // MARK: - 道具

    private func effect(_ type: String) throws -> PipelineStore.Loaded {
        let spec = try XCTUnwrap(ETCatalog.first { $0.type == type }, "カタログに無い: \(type)")
        return PipelineStore.Loaded(spec: spec, values: spec.defaults, enabled: true,
                                    inputBus: 0, outputBus: 0, channelSpec: -1)
    }

    private func section(_ name: String) -> PipelineStore.Loaded {
        PipelineStore.Loaded(spec: ETSection.spec, values: [], enabled: true,
                             inputBus: 0, outputBus: 0, channelSpec: -1, sectionName: name)
    }

    private func external(inputBus: UInt8, outputBus: UInt8, enabled: Bool = true,
                          state: Data? = Data([1, 2, 3])) -> PipelineStore.Loaded {
        PipelineStore.Loaded(
            spec: ETEffect.external(type: "External:au:aufx-dely-abcd", name: "My Delay",
                                    category: "Audio Units"),
            values: [], enabled: enabled, inputBus: inputBus, outputBus: outputBus,
            channelSpec: -1, externalID: "au:aufx-dely-abcd",
            externalInstanceID: "inst-1", externalState: state)
    }

    // MARK: - 鎖の写し

    func testInPlaceExternalIsDroppedAndIndexMapSkipsIt() throws {
        let chain = [try effect("VolumePlugin"),
                     external(inputBus: 0, outputBus: 0),
                     try effect("DelayPlugin")]
        let projected = ETRemoteProjection.project(chain)
        XCTAssertEqual(projected.pipeline.count, 2)
        XCTAssertEqual(projected.pipeline.map { $0["nm"] as? String },
                       [chain[0].spec.name, chain[2].spec.name])
        // 手元の 2 番目（Delay）は PC では 1 番目。落ちた段は nil。
        XCTAssertEqual(projected.remoteIndex, [0, nil, 1])
    }

    func testBusCrossingExternalBecomesZeroDbVolumeKeepingRouting() throws {
        let chain = [external(inputBus: 1, outputBus: 2, enabled: false)]
        let projected = ETRemoteProjection.project(chain)
        XCTAssertEqual(projected.remoteIndex, [0])
        let entry = try XCTUnwrap(projected.pipeline.first)
        XCTAssertEqual(entry["nm"] as? String, "Volume")
        XCTAssertEqual(entry["en"] as? Bool, false)
        XCTAssertEqual(entry["vl"] as? Double, 0)
        XCTAssertEqual(entry["ib"] as? Int, 1)
        XCTAssertEqual(entry["ob"] as? Int, 2)
        XCTAssertNil(entry["external"])
    }

    func testExternalStateNeverReachesTheWire() throws {
        let chain = [try effect("VolumePlugin"),
                     external(inputBus: 1, outputBus: 2, state: Data(repeating: 7, count: 4096)),
                     external(inputBus: 0, outputBus: 0, state: Data(repeating: 9, count: 4096))]
        let projected = ETRemoteProjection.project(chain)
        let data = try JSONSerialization.data(withJSONObject: projected.pipeline)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("externalState"))
        XCTAssertFalse(text.contains("external"))
        XCTAssertFalse(text.contains(Data(repeating: 7, count: 4096).base64EncodedString()))
    }

    func testSectionAndRootResetProjectWithoutTheMark() throws {
        var reset = section("")
        reset.isRootReset = true
        let projected = ETRemoteProjection.project([section("A"), try effect("VolumePlugin"), reset])
        XCTAssertEqual(projected.remoteIndex, [0, 1, 2])
        XCTAssertEqual(projected.pipeline[0]["cm"] as? String, "A")
        XCTAssertEqual(projected.pipeline[2]["cm"] as? String, "")
        XCTAssertNil(projected.pipeline[2][ETSection.rootResetKey])
    }

    // MARK: - params

    func testParamsHoldOnlyParameterKeys() throws {
        var volume = try effect("VolumePlugin")
        let spec = volume.spec
        let param = try XCTUnwrap(spec.params.first { $0.key == "vl" })
        volume.values[param.offset] = -3
        let params = try XCTUnwrap(ETRemoteProjection.params(for: volume))
        XCTAssertEqual((params["vl"] as? NSNumber)?.doubleValue, -3)
        XCTAssertNil(params["nm"])
        XCTAssertNil(params["en"])
    }

    /// float に載らない鍵（IR の素材）も params に入る。落とすと控えの鎖だけが進み、PC へ届かない。
    func testParamsCarryKeysOutsideTheFloats() throws {
        var ir = try effect("IRReverbPlugin")
        ir.irId = "user:hall"
        ir.inputBus = 1
        let params = try XCTUnwrap(ETRemoteProjection.params(for: ir))
        XCTAssertEqual(params["ir"] as? String, "user:hall")
        XCTAssertNil(params["ib"])
        XCTAssertNil(params["nm"])
    }

    func testParamsAreNilForStagesWithoutParameters() throws {
        XCTAssertNil(ETRemoteProjection.params(for: section("A")))
        XCTAssertNil(ETRemoteProjection.params(for: external(inputBus: 0, outputBus: 0)))
    }

    // MARK: - PC の版

    func testHostInfoOfANewHost() {
        let info = ETRemoteHostInfo(state: ["app": "2.11.0", "appName": "EffeTune", "build": "abc1234",
                                            "features": ["origin", "telemetry", "overlays"]])
        XCTAssertEqual(info.name, "EffeTune")
        XCTAssertEqual(info.label, "2.11.0 (abc1234)")
        XCTAssertTrue(info.supports("telemetry"))
        XCTAssertTrue(info.supports("overlays"))
    }

    func testHostInfoOfAnOldHostWithoutTelemetry() {
        let info = ETRemoteHostInfo(state: ["app": "2.11.0", "features": ["origin", "savePreset", "irSync"]])
        XCTAssertEqual(info.name, "EffeTune")
        XCTAssertEqual(info.label, "2.11.0")
        XCTAssertFalse(info.supports("telemetry"))
        XCTAssertEqual(info.unsupportedText, "Not supported by EffeTune 2.11.0 on the PC")
    }

    func testHostInfoWithoutAnyVersionFields() {
        let info = ETRemoteHostInfo(state: [:])
        XCTAssertEqual(info.label, "Unknown")
        XCTAssertFalse(info.supports("telemetry"))
        XCTAssertEqual(info.unsupportedText, "Not supported by EffeTune on the PC")
    }

    func testHelloCarriesOurVersionWhenKnown() {
        let m = ETRemoteHello.message(info: ["CFBundleShortVersionString": "2026.09.28", "CFBundleVersion": "31"])
        XCTAssertEqual(m["op"] as? String, "hello")
        XCTAssertEqual(m["v"] as? Int, 1)
        XCTAssertEqual(m["app"] as? String, "EffectDeck")
        XCTAssertEqual(m["version"] as? String, "2026.09.28")
        XCTAssertEqual(m["build"] as? String, "31")
    }

    func testHelloLeavesOutWhatItCannotFind() {
        let m = ETRemoteHello.message(info: nil)
        XCTAssertEqual(m["app"] as? String, "EffectDeck")
        XCTAssertNil(m["version"])
        XCTAssertNil(m["build"])
    }

    // MARK: - 版と効果の食い違い

    /// 2.11.0 の PC が読み込める効果。手元のカタログから 2.12.0 で入った 3 つを引いたもの。
    private var effects211: [String] {
        let added: Set<String> = ["Analog Meter", "Rhythm Analyzer", "Tonal Balance EQ"]
        return ETRemoteHostInfo.localEffectNames.filter { !added.contains($0) }
    }

    private func oldHost(dsp: String? = "0.11.0", effects: [String]? = nil) -> ETRemoteHostInfo {
        var state: [String: Any] = ["app": "2.11.0", "appName": "EffeTune", "build": "abc1234",
                                    "features": ["origin", "telemetry", "overlays"]]
        if let dsp { state["dsp"] = dsp }
        if let effects { state["effects"] = effects }
        return ETRemoteHostInfo(state: state)
    }

    func testHelloCarriesOurDspVersion() {
        XCTAssertEqual(ETRemoteHello.message(info: nil)["dsp"] as? String, ETUpstreamVersion)
        XCTAssertEqual(ETRemoteHello.message(info: nil, dsp: "0.12.0")["dsp"] as? String, "0.12.0")
        XCTAssertNil(ETRemoteHello.message(info: nil, dsp: "")["dsp"])
    }

    func testHostInfoReadsDspAndEffects() {
        let info = oldHost(effects: ["Volume", "Delay"])
        XCTAssertEqual(info.dsp, "0.11.0")
        XCTAssertEqual(info.effects, ["Volume", "Delay"])
        XCTAssertFalse(info.lacks("Volume"))
        XCTAssertTrue(info.lacks("Analog Meter"))
    }

    func testHostWithoutEffectsListNeverRefuses() {
        let info = ETRemoteHostInfo(state: ["app": "2.11.0"])
        XCTAssertNil(info.dsp)
        XCTAssertNil(info.effects)
        XCTAssertFalse(info.lacks("Analog Meter"))
        // 上流の版が分からないとき（localApp が空）は、比べるものが無い。
        XCTAssertNil(info.mismatch(localDSP: "0.12.0", localEffects: ETRemoteHostInfo.localEffectNames,
                                   localApp: ""))
    }

    func testMismatchNamesTheEffectsTheOldHostLacks() throws {
        let info = oldHost(effects: effects211)
        let m = try XCTUnwrap(info.mismatch(localDSP: "0.12.0", localEffects: ETRemoteHostInfo.localEffectNames))
        XCTAssertEqual(m.missingOnHost, ["Analog Meter", "Rhythm Analyzer", "Tonal Balance EQ"])
        XCTAssertTrue(m.missingHere.isEmpty)
        XCTAssertTrue(m.dspDiffers)
        XCTAssertEqual(m.headline, "DSP 0.11.0 on the PC, 0.12.0 here")
        XCTAssertEqual(m.missingOnHostText, "Not on the PC: Analog Meter, Rhythm Analyzer, Tonal Balance EQ")
    }

    func testMismatchWithTheSameDspAndEffectsIsNil() {
        let local = ETRemoteHostInfo.localEffectNames
        let info = oldHost(dsp: "0.12.0", effects: local)
        XCTAssertNil(info.mismatch(localDSP: "0.12.0", localEffects: local))
    }

    func testMismatchOfEffectsAloneSaysEffectsDiffer() throws {
        let info = oldHost(dsp: "0.12.0", effects: effects211)
        let m = try XCTUnwrap(info.mismatch(localDSP: "0.12.0", localEffects: ETRemoteHostInfo.localEffectNames))
        XCTAssertFalse(m.dspDiffers)
        XCTAssertEqual(m.headline, "Effects differ")
    }

    func testMismatchReportsEffectsOnlyThePcHas() throws {
        let local = ["Volume", "Delay"]
        let info = oldHost(dsp: "0.12.0", effects: ["Volume", "Delay", "Future Effect"])
        let m = try XCTUnwrap(info.mismatch(localDSP: "0.12.0", localEffects: local))
        XCTAssertEqual(m.missingHere, ["Future Effect"])
        XCTAssertEqual(m.missingHereText, "Not here: Future Effect")
        XCTAssertNil(m.missingOnHostText)
    }

    func testMismatchWithoutEffectsListComparesDspOnly() throws {
        let info = oldHost(dsp: "0.11.0", effects: nil)
        let m = try XCTUnwrap(info.mismatch(localDSP: "0.12.0", localEffects: ETRemoteHostInfo.localEffectNames))
        XCTAssertTrue(m.missingOnHost.isEmpty)
        XCTAssertEqual(m.headline, "DSP 0.11.0 on the PC, 0.12.0 here")
        XCTAssertNil(oldHost(dsp: "0.12.0", effects: nil).mismatch(localDSP: "0.12.0", localEffects: []))
        XCTAssertNil(oldHost(dsp: nil, effects: nil).mismatch(localDSP: "0.12.0", localEffects: [], localApp: ""))
    }

    // MARK: 公式の EffeTune 2.13.0（dsp を出さない）

    /// 公式 2.13.0 の hello の返事（electron/remote-control-host.cjs、docs/remote-v1.md）。
    /// dsp も build も無く、features は origin / savePreset / irSync / sync1。telemetry と overlays は無い。
    private func official(app: String = "2.13.0", effects: [String]? = ETRemoteHostInfo.localEffectNames)
        -> ETRemoteHostInfo {
        var state: [String: Any] = ["app": app, "appName": "EffeTune",
                                    "features": ["origin", "savePreset", "irSync", "sync1"],
                                    "epoch": "e1", "slot": "A", "host": "desk"]
        if let effects { state["effects"] = effects }
        return ETRemoteHostInfo(state: state)
    }

    func testOfficialHostReadsWithoutDsp() {
        let info = official()
        XCTAssertNil(info.dsp)
        XCTAssertNil(info.build)
        XCTAssertEqual(info.label, "2.13.0")
        XCTAssertTrue(info.supports("sync1"))
        XCTAssertFalse(info.supports("telemetry"), "公式に telemetry は無い")
        XCTAssertFalse(info.supports("overlays"))
        XCTAssertEqual(info.hostName, "desk")
    }

    func testOfficial213HasNoMismatchAgainstTheLocalCatalog() {
        // 公式 2.13.0 の効果の一覧は 113 個（カタログの 112 と Section）。
        XCTAssertEqual(ETRemoteHostInfo.localEffectNames.count, 113)
        XCTAssertNil(official().mismatch(localDSP: ETUpstreamVersion,
                                         localEffects: ETRemoteHostInfo.localEffectNames,
                                         localApp: "2.13.0"))
        XCTAssertEqual(ETUpstreamAppVersion, "2.13.0", "Vendor/effetune/package.json の版")
    }

    func testOfficialHostOfAnotherAppVersionSaysSo() throws {
        let m = try XCTUnwrap(official(app: "2.14.0").mismatch(
            localDSP: "0.13.0", localEffects: ETRemoteHostInfo.localEffectNames, localApp: "2.13.0"))
        XCTAssertEqual(m.headline, "EffeTune 2.14.0 on the PC, 2.13.0 here")
        XCTAssertTrue(m.appDiffers)
        XCTAssertFalse(m.dspDiffers)
        XCTAssertTrue(m.missingOnHost.isEmpty)
        // 古い公式（2.12.0）は新しい 2 つの効果を持たない。版を先に言い、効果の差は下の行に出る。
        let added: Set<String> = ["Adaptive Prediction", "SFZ Note Player"]
        let old = official(app: "2.12.0", effects: ETRemoteHostInfo.localEffectNames.filter { !added.contains($0) })
        let m2 = try XCTUnwrap(old.mismatch(localDSP: "0.13.0", localEffects: ETRemoteHostInfo.localEffectNames,
                                            localApp: "2.13.0"))
        XCTAssertEqual(m2.headline, "EffeTune 2.12.0 on the PC, 2.13.0 here")
        XCTAssertEqual(m2.missingOnHost, ["Adaptive Prediction", "SFZ Note Player"])
    }

    func testSameAppWithDifferentEffectsSaysEffectsDiffer() throws {
        let m = try XCTUnwrap(official(effects: ["Volume"]).mismatch(
            localDSP: "0.13.0", localEffects: ["Volume", "Delay"], localApp: "2.13.0"))
        XCTAssertEqual(m.headline, "Effects differ")
        XCTAssertFalse(m.appDiffers)
    }

    /// dsp の版を出す PC は、それを言う。アプリの版は比べない（dsp が同じなら食い違いではない）。
    func testAHostThatReportsDspIsComparedByDspNotByApp() throws {
        let fork = oldHost(dsp: "0.13.0", effects: ETRemoteHostInfo.localEffectNames)   // app は 2.11.0
        XCTAssertNil(fork.mismatch(localDSP: "0.13.0", localEffects: ETRemoteHostInfo.localEffectNames,
                                   localApp: "2.13.0"))
        let m = try XCTUnwrap(oldHost(dsp: "0.12.0").mismatch(
            localDSP: "0.13.0", localEffects: ETRemoteHostInfo.localEffectNames, localApp: "2.13.0"))
        XCTAssertEqual(m.headline, "DSP 0.12.0 on the PC, 0.13.0 here")
    }

    // MARK: 前に送った形から消えた鍵（params では消せない）

    func testRemovedKeysFindsWhatParamsCannotUnset() {
        let sent: [String: Any] = ["nm": "Room EQ", "en": true, "ib": 1, "ms0": "abc", "mn0": "x", "vl": 3]
        // 値が変わっただけ・鍵が増えただけは消えたに入らない。
        XCTAssertEqual(ETRemoteProjection.removedKeys(sent: sent, now: ["nm": "Room EQ", "ms0": "abc", "mn0": "y",
                                                                       "vl": 4, "extra": 1]), [])
        // 測定が消えた。段の鍵（en / ib）は params の話ではないので数えない。
        XCTAssertEqual(ETRemoteProjection.removedKeys(sent: sent, now: ["nm": "Room EQ", "vl": 3]),
                       ["mn0", "ms0"])
        XCTAssertEqual(ETRemoteProjection.removedKeys(sent: nil, now: ["vl": 1]), [])
        XCTAssertEqual(ETRemoteProjection.removedKeys(sent: ["rr": true, "nm": "Section"], now: [:]), [])
    }

    func testClearingAnIRIsDetectedAsARemovedKey() throws {
        var node = try effect("IRReverbPlugin")
        node.irId = "0123456789abcdef01234567"
        let withIR = try XCTUnwrap(ETRemoteProjection.entry(for: node))
        XCTAssertNotNil(withIR["ir"])
        node.irId = ""
        let cleared = try XCTUnwrap(ETRemoteProjection.entry(for: node))
        XCTAssertNil(cleared["ir"])
        XCTAssertEqual(ETRemoteProjection.removedKeys(sent: withIR, now: cleared), ["ir"])
        // つまみだけ動かしても消えた鍵は無い。
        node.irId = "0123456789abcdef01234567"
        let moved = try XCTUnwrap(ETRemoteProjection.entry(for: node))
        XCTAssertEqual(ETRemoteProjection.removedKeys(sent: withIR, now: moved), [])
    }

    func testProjectionRefusesEffectsTheHostLacks() throws {
        let host = oldHost(effects: effects211)
        let chain = [try effect("VolumePlugin"),
                     try effect("AnalogMeterPlugin"),
                     external(inputBus: 0, outputBus: 0),
                     try effect("RhythmAnalyzerPlugin"),
                     try effect("DelayPlugin")]
        let projected = ETRemoteProjection.project(chain, host: host)
        XCTAssertEqual(projected.pipeline.map { $0["nm"] as? String },
                       [chain[0].spec.name, chain[4].spec.name])
        XCTAssertEqual(projected.remoteIndex, [0, nil, nil, nil, 1])
    }

    func testProjectionKeepsEverythingWithoutAnEffectsList() throws {
        let chain = [try effect("VolumePlugin"), try effect("AnalogMeterPlugin")]
        for host in [nil, oldHost(effects: nil)] {
            let projected = ETRemoteProjection.project(chain, host: host)
            XCTAssertEqual(projected.remoteIndex, [0, 1])
        }
    }

    func testProjectionKeepsASectionTheHostKnows() throws {
        let host = oldHost(effects: effects211)
        let projected = ETRemoteProjection.project([section("A"), try effect("AnalogMeterPlugin")], host: host)
        XCTAssertEqual(projected.remoteIndex, [0, nil])
    }

    // MARK: - 接続先

    func testAddressHostPortToken() {
        let a = ETRemoteAddress.parse("192.168.1.10:47300/ab12cd34")
        XCTAssertEqual(a, ETRemoteAddress(host: "192.168.1.10", port: 47300, token: "ab12cd34"))
        XCTAssertEqual(a?.url?.absoluteString, "ws://192.168.1.10:47300/?t=ab12cd34")
    }

    func testAddressDefaultsThePortAndTrims() {
        XCTAssertEqual(ETRemoteAddress.parse("  pc.local/tok \n"),
                       ETRemoteAddress(host: "pc.local", port: 47300, token: "tok"))
    }

    func testAddressFullWebSocketURL() {
        XCTAssertEqual(ETRemoteAddress.parse("ws://10.0.0.5:47301/?t=abc"),
                       ETRemoteAddress(host: "10.0.0.5", port: 47301, token: "abc"))
        XCTAssertEqual(ETRemoteAddress.parse("ws://10.0.0.5/abc"),
                       ETRemoteAddress(host: "10.0.0.5", port: 47300, token: "abc"))
    }

    func testAddressRejectsWhatItCannotRead() {
        XCTAssertNil(ETRemoteAddress.parse(""))
        XCTAssertNil(ETRemoteAddress.parse("192.168.1.10:47300"))          // トークンが無い
        XCTAssertNil(ETRemoteAddress.parse("192.168.1.10:99999/tok"))      // ポートが範囲の外
        XCTAssertNil(ETRemoteAddress.parse("192.168.1.10:abc/tok"))
        XCTAssertNil(ETRemoteAddress.parse("wss://192.168.1.10:47300/?t=x"))  // ws しか作らない
        XCTAssertNil(ETRemoteAddress.parse("https://192.168.1.10:47300/?t=x"))  // PC は http しか出さない
        XCTAssertNil(ETRemoteAddress.parse("http://192.168.1.10:47300/?x=1"))   // トークンが無い
        XCTAssertNil(ETRemoteAddress.parse("http://192.168.1.10:47300/other?t=x"))  // 行き先が違う
        XCTAssertNil(ETRemoteAddress.parse("http://192.168.1.10:99999/?t=x"))
    }

    func testAddressPCLinkHTTP() {
        // PC がブラウザにもアプリにも出す 1 つのリンク。ws:// を作る。
        let a = ETRemoteAddress.parse("http://192.168.1.10:47300/?t=ab12cd34")
        XCTAssertEqual(a, ETRemoteAddress(host: "192.168.1.10", port: 47300, token: "ab12cd34"))
        XCTAssertEqual(a?.url?.absoluteString, "ws://192.168.1.10:47300/?t=ab12cd34")
        XCTAssertEqual(ETRemoteAddress.parse("http://10.0.0.5:47301?t=abc"),
                       ETRemoteAddress(host: "10.0.0.5", port: 47301, token: "abc"))
        XCTAssertEqual(ETRemoteAddress.parse("HTTP://10.0.0.5:47301/remote.html?t=abc"),
                       ETRemoteAddress(host: "10.0.0.5", port: 47301, token: "abc"))
        XCTAssertEqual(ETRemoteAddress.parse("  http://10.0.0.5/?t=abc \n"),
                       ETRemoteAddress(host: "10.0.0.5", port: 47300, token: "abc"))
        // 控えた字から読み戻せる。
        XCTAssertEqual(a.flatMap { ETRemoteAddress.parse($0.text) }, a)
    }

    // MARK: - v2: QR のリンク

    func testPairingLinkReadsHostPortAndToken() throws {
        let url = try XCTUnwrap(URL(string: "ws://192.168.1.10:47300/?t=ab12cd34"))
        let a = ETRemoteAddress.pairingLink(url)
        XCTAssertEqual(a, ETRemoteAddress(host: "192.168.1.10", port: 47300, token: "ab12cd34"))
        // 控える字は parse がそのまま読み戻せる。
        XCTAssertEqual(a.flatMap { ETRemoteAddress.parse($0.text) }, a)
    }

    func testPairingLinkReadsThePCHTTPLink() throws {
        for (text, port) in [("http://192.168.1.10:47300/?t=ab12cd34", 47300),
                             ("http://192.168.1.10:47300?t=ab12cd34", 47300),
                             ("http://192.168.1.10:47300/remote.html?t=ab12cd34", 47300),
                             ("http://192.168.1.10/?t=ab12cd34", 47300),
                             ("http://192.168.1.10:47305/?t=ab12cd34", 47305)] {
            let url = try XCTUnwrap(URL(string: text))
            XCTAssertEqual(ETRemoteAddress.pairingLink(url),
                           ETRemoteAddress(host: "192.168.1.10", port: port, token: "ab12cd34"), text)
        }
    }

    func testPairingLinkDefaultsThePort() throws {
        let url = try XCTUnwrap(URL(string: "WS://10.0.0.5?t=tok"))
        XCTAssertEqual(ETRemoteAddress.pairingLink(url),
                       ETRemoteAddress(host: "10.0.0.5", port: 47300, token: "tok"))
    }

    func testPairingLinkRejectsOtherLinks() throws {
        for text in ["https://effectdeck.nemut.ai/remote?h=1.2.3.4:47300&t=x",   // 共有リンクの側
                     "effectdeck://remote?h=1.2.3.4:47300&t=x",                  // 前の形（使わない）
                     "ws://1.2.3.4:47300/chain?t=x",                             // 行き先が違う
                     "ws://1.2.3.4:47300/",                                      // トークンが無い
                     "wss://1.2.3.4:47300/?t=x",                                 // 暗号つき（作らない）
                     "https://1.2.3.4:47300/?t=x",                               // PC は http しか出さない
                     "http://1.2.3.4:47300/?x=1",                                // トークンが無い
                     "http://1.2.3.4:47300/chain?t=x",                           // 行き先が違う
                     "ws://1.2.3.4:47300/remote.html?t=x",                       // /remote.html は http だけ
                     "ws://1.2.3.4:99999/?t=x"] {                                // ポートが範囲の外
            let url = try XCTUnwrap(URL(string: text))
            XCTAssertNil(ETRemoteAddress.pairingLink(url), text)
        }
    }

    // MARK: - v2: state の出どころ

    func testStateOriginFiltering() {
        let ours: Set<Int> = [3, 4]
        XCTAssertTrue(ETRemoteStateFilter.follows(origin: "local", seq: nil, ours: ours))
        XCTAssertTrue(ETRemoteStateFilter.follows(origin: "local", seq: 3, ours: ours))
        // 自分のコマンドの結果は捨てる。ほかの端末のコマンドの結果は追う。
        XCTAssertFalse(ETRemoteStateFilter.follows(origin: "remote", seq: 4, ours: ours))
        XCTAssertTrue(ETRemoteStateFilter.follows(origin: "remote", seq: 9, ours: ours))
        XCTAssertTrue(ETRemoteStateFilter.follows(origin: "remote", seq: nil, ours: ours))
        // v1 の PC（origin が無い）は読み捨てる。
        XCTAssertFalse(ETRemoteStateFilter.follows(origin: nil, seq: nil, ours: ours))
    }

    // MARK: - v2: プリセットの足し合わせ（EffectDeck → PC）

    func testPresetPushCopiesOnlyWhatPCLacks() {
        let plan = ETRemotePresetSync.plan(pc: ["A": "a", "Same": "s"],
                                           local: ["B": "b", "Same": "s"])
        XCTAssertEqual(plan, [.init(source: "B", target: "B")])
    }

    func testPresetNameClashGetsATagOnPC() {
        let plan = ETRemotePresetSync.plan(pc: ["N": "pc"], local: ["N": "pad"])
        XCTAssertEqual(plan, [.init(source: "N", target: "N (iPad)")])
    }

    func testPresetTaggedNameThatIsTakenCountsUp() {
        let plan = ETRemotePresetSync.plan(pc: ["N": "pc", "N (iPad)": "other"], local: ["N": "pad"])
        XCTAssertEqual(plan, [.init(source: "N", target: "N (iPad 2)")])
    }

    func testPresetBlockedLocalIsNotSent() {
        let plan = ETRemotePresetSync.plan(pc: [:], local: ["AU": "x", "Plain": "y"], localBlocked: ["AU"])
        XCTAssertEqual(plan, [.init(source: "Plain", target: "Plain")])
    }

    /// PC には何も戻さない（PC → EffectDeck は plan に無い。写しのフォルダ）。
    func testPresetPushNeverTouchesTheLocalSide() {
        let plan = ETRemotePresetSync.plan(pc: ["OnlyPC": "p"], local: [:])
        XCTAssertEqual(plan, [])
    }

    /// 1 回目の結果を PC へ当てて、2 回目は何もしない。
    func testPresetPushIsIdempotent() {
        var pc = ["N": "pc", "OnlyPC": "p"]
        let local = ["N": "pad", "OnlyPad": "q", "AU": "x"]
        let first = ETRemotePresetSync.plan(pc: pc, local: local, localBlocked: ["AU"])
        for copy in first { pc[copy.target] = local[copy.source] }
        XCTAssertEqual(ETRemotePresetSync.plan(pc: pc, local: local, localBlocked: ["AU"]), [])
        XCTAssertEqual(Set(pc.keys), ["N", "N (iPad)", "OnlyPC", "OnlyPad"])
    }

    func testPresetTagSplit() {
        XCTAssertEqual(ETRemotePresetSync.split("Rock (iPad 3)")?.tag, "iPad")
        XCTAssertEqual(ETRemotePresetSync.split("Rock (iPad)")?.base, "Rock")
        // 前の版が作った `(PC)` も読む（PC へ送り返さないため）。
        XCTAssertEqual(ETRemotePresetSync.split("Rock (PC)")?.base, "Rock")
        XCTAssertNil(ETRemotePresetSync.split("Rock (live)"))
        XCTAssertNil(ETRemotePresetSync.split("Rock (PC 1)"))
        XCTAssertNil(ETRemotePresetSync.split("Rock"))
    }

    /// 前の版が手元に残した `Rock (PC)` が PC の `Rock` と同じ中身なら、PC へ送り返さない。
    func testLegacyPCCopyIsNotSentBack() {
        let plan = ETRemotePresetSync.plan(pc: ["Rock": "r"], local: ["Rock (PC)": "r", "Rock (PC) 2": "z"])
        XCTAssertEqual(plan, [.init(source: "Rock (PC) 2", target: "Rock (PC) 2")])
    }

    // MARK: - v2: プリセットの写し（PC → EffectDeck）

    func testMirrorFolderNameIsHostNameThenAddressHost() {
        XCTAssertEqual(ETRemotePresetMirror.folderName(hostName: "WIN-SE", address: "192.168.1.10:47300/ab12cd34"), "WIN-SE")
        XCTAssertEqual(ETRemotePresetMirror.folderName(hostName: " a/b ", address: "192.168.1.10/ab12cd34"), "a b")
        XCTAssertEqual(ETRemotePresetMirror.folderName(hostName: nil, address: "192.168.1.10:47300/ab12cd34"), "192.168.1.10")
        XCTAssertEqual(ETRemotePresetMirror.folderName(hostName: "  ", address: "192.168.1.10/ab12cd34"), "192.168.1.10")
        XCTAssertEqual(ETRemotePresetMirror.folderName(hostName: nil, address: ""), "")
        // PC から来る字なので、制御文字は落として長さを切る。
        XCTAssertEqual(ETRemotePresetMirror.folderName(hostName: "WIN\n-SE\u{7}", address: ""), "WIN-SE")
        XCTAssertEqual(ETRemotePresetMirror.folderName(hostName: String(repeating: "a", count: 200), address: "").count,
                       ETRemotePresetMirror.maxFolderName)
    }

    func testHelloAsksForPresetsChangedAndHostInfoReadsHostName() {
        XCTAssertEqual(ETRemoteHello.message(info: nil)["sync"] as? Int, 1)
        let info = ETRemoteHostInfo(state: ["host": " WIN-SE ", "features": ["origin", "sync1"]])
        XCTAssertEqual(info.hostName, "WIN-SE")
        XCTAssertTrue(ETRemotePresetMirror.isLive(info))
        // sync1 を持たない PC は presetsChanged を送らない。host も無い。
        let old = ETRemoteHostInfo(state: ["features": ["origin", "telemetry"]])
        XCTAssertNil(old.hostName)
        XCTAssertFalse(ETRemotePresetMirror.isLive(old))
        XCTAssertFalse(ETRemotePresetMirror.isLive(nil))
    }

    /// PC の字（0.1）と、手元に保存して読み戻したもの（Float を経た 0.10000000149…）が同じ中身になる。
    func testPresetCanonicalSurvivesALocalRoundTrip() throws {
        let volume = try effect("VolumePlugin")
        let fromPC = "[{\"nm\":\"\(volume.spec.name)\",\"en\":true,\"vl\":-3.1}]"
        let loaded = ETShareLink.parse(fromPC, catalog: ETCatalog)
        XCTAssertEqual(loaded.count, 1)
        let pcCanon = ETRemotePresetSync.canonical(ETRemoteProjection.project(loaded).pipeline)
        // 手元の保存（PresetStore.save → shortForm）と読み戻し（PresetStore.load → parse）。
        let stored = PipelineStore.shortForm(loaded)
        let data = try JSONSerialization.data(withJSONObject: stored)
        let reloaded = PipelineStore.parse(try JSONSerialization.jsonObject(with: data), catalog: ETCatalog)
        let localCanon = ETRemotePresetSync.canonical(ETRemoteProjection.project(reloaded).pipeline)
        XCTAssertEqual(pcCanon, localCanon)
        XCTAssertFalse(pcCanon.isEmpty)
    }

    // MARK: - v2: IR

    func testIRPlanAndChunks() {
        let plan = ETRemoteIRSync.plan(pc: ["b", "a", "c"], local: ["c", "d"])
        XCTAssertEqual(plan.download, ["a", "b"])
        XCTAssertEqual(plan.upload, ["d"])
        XCTAssertEqual(ETRemoteIRSync.chunks(0), [0..<0])
        XCTAssertEqual(ETRemoteIRSync.chunks(10, size: 4), [0..<4, 4..<8, 8..<10])
        XCTAssertEqual(ETRemoteIRSync.chunks(8, size: 4), [0..<4, 4..<8])
    }

    func testIRPlanSkipsKeysThatAlreadyFailed() {
        // ライブのときは、このつなぎで失敗した鍵を取り直さない・送り直さない。
        let plan = ETRemoteIRSync.plan(pc: ["a", "b", "c"], local: ["c", "d", "e"], skip: ["b", "e"])
        XCTAssertEqual(plan.download, ["a"])
        XCTAssertEqual(plan.upload, ["d"])
        // skip を渡さなければ、つないだ直後の足し合わせと同じ。
        let all = ETRemoteIRSync.plan(pc: ["a", "b"], local: ["b", "z"])
        XCTAssertEqual(all.download, ["a"])
        XCTAssertEqual(all.upload, ["z"])
    }

    func testIRPlanIsAddOnly() {
        // 片方にしか無いものは足すだけ。消す指図は出ない（返すのは取る鍵と送る鍵だけ）。
        let plan = ETRemoteIRSync.plan(pc: [], local: ["x"])
        XCTAssertEqual(plan.download, [])
        XCTAssertEqual(plan.upload, ["x"])
        let none = ETRemoteIRSync.plan(pc: ["x"], local: ["x"])
        XCTAssertTrue(none.download.isEmpty && none.upload.isEmpty)
    }

    func testIRLivePlanDoesNotUndoDeletions() {
        // PC で消した IR を手元の写しから送り直さない（前に見た手元の一覧に在った）。
        let pcDeleted = ETRemoteIRSync.livePlan(pc: ["a"], local: ["a", "b"],
                                                knownPC: ["a", "b"], knownLocal: ["a", "b"], skip: [])
        XCTAssertEqual(pcDeleted.upload, [])
        XCTAssertEqual(pcDeleted.download, [])
        // 手元で消した IR を PC から取り直さない（前に見た PC の一覧に在った）。
        let localDeleted = ETRemoteIRSync.livePlan(pc: ["a", "b"], local: ["a"],
                                                   knownPC: ["a", "b"], knownLocal: ["a"], skip: [])
        XCTAssertEqual(localDeleted.download, [])
        XCTAssertEqual(localDeleted.upload, [])
        // 増えた分は両方向に足す。
        let added = ETRemoteIRSync.livePlan(pc: ["a", "p"], local: ["a", "l"],
                                            knownPC: ["a"], knownLocal: ["a"], skip: [])
        XCTAssertEqual(added.download, ["p"])
        XCTAssertEqual(added.upload, ["l"])
        // 失敗した鍵は増えた分でも飛ばす。
        let skipped = ETRemoteIRSync.livePlan(pc: ["a", "p"], local: ["a", "l"],
                                              knownPC: ["a"], knownLocal: ["a"], skip: ["p", "l"])
        XCTAssertTrue(skipped.download.isEmpty && skipped.upload.isEmpty)
        // まだ見ていない側（つないだ直後に一覧が取れなかった）は plan と同じ。
        let unseen = ETRemoteIRSync.livePlan(pc: ["a", "p"], local: ["a", "l"],
                                             knownPC: nil, knownLocal: nil, skip: [])
        XCTAssertEqual(unseen.download, ["p"])
        XCTAssertEqual(unseen.upload, ["l"])
        // 同じ中身は名前が違っても鍵が同じなので、どちらへも動かない。
        let same = ETRemoteIRSync.livePlan(pc: ["k"], local: ["k"], knownPC: [], knownLocal: [], skip: [])
        XCTAssertTrue(same.download.isEmpty && same.upload.isEmpty)
    }

    func testIRLocalAdditionsOnly() {
        // 手元で増えたときだけ足し合わせ直す。消した・減っただけ・同じなら何もしない。
        XCTAssertTrue(ETRemoteIRSync.hasAdditions(known: ["a"], current: ["a", "b"]))
        XCTAssertTrue(ETRemoteIRSync.hasAdditions(known: [], current: ["a"]))
        XCTAssertFalse(ETRemoteIRSync.hasAdditions(known: ["a", "b"], current: ["a"]))
        XCTAssertFalse(ETRemoteIRSync.hasAdditions(known: ["a"], current: ["a"]))
        XCTAssertFalse(ETRemoteIRSync.hasAdditions(known: ["a"], current: []))
        // 足し合わせで自分が取り込んだ分は、終わりに known へ入れるので、また増えたことにならない。
        let known: Set<String> = ["a", "downloaded"]
        XCTAssertFalse(ETRemoteIRSync.hasAdditions(known: known, current: ["downloaded", "a"]))
    }

    func testIRUploadSizeLimit() {
        XCTAssertFalse(ETRemoteIRSync.canUpload(bytes: 0))
        XCTAssertTrue(ETRemoteIRSync.canUpload(bytes: 1))
        XCTAssertTrue(ETRemoteIRSync.canUpload(bytes: ETRemoteIRSync.maxBytes))
        XCTAssertFalse(ETRemoteIRSync.canUpload(bytes: ETRemoteIRSync.maxBytes + 1))
        // 1 本は塊の数が PC の上限（上限バイト数 / 塊）を超えない。
        XCTAssertEqual(ETRemoteIRSync.chunks(ETRemoteIRSync.maxBytes).count,
                       ETRemoteIRSync.maxBytes / ETRemoteIRSync.chunkSize)
        XCTAssertEqual(ETRemoteIRSync.liveDebounceNanoseconds, 1_000_000_000)
    }

    func testIRFileName() {
        XCTAssertEqual(ETRemoteIRSync.fileName(name: "Hall", ext: "wav"), "Hall.wav")
        XCTAssertEqual(ETRemoteIRSync.fileName(name: "Hall.WAV", ext: "wav"), "Hall.wav")
        XCTAssertEqual(ETRemoteIRSync.fileName(name: "a/b:c", ext: "flac"), "a-b-c.flac")
        XCTAssertEqual(ETRemoteIRSync.fileName(name: "", ext: "wav"), "IR.wav")
    }

    func testIRAssemblyNeedsEveryChunkInOrder() {
        var ok = ETRemoteIRSync.Assembly()
        ok.add(index: 0, total: 2, data: Data([1]))
        XCTAssertFalse(ok.isComplete)
        ok.add(index: 1, total: 2, data: Data([2]))
        XCTAssertTrue(ok.isComplete)
        XCTAssertEqual(ok.data, Data([1, 2]))

        var skipped = ETRemoteIRSync.Assembly()
        skipped.add(index: 1, total: 2, data: Data([2]))
        skipped.add(index: 0, total: 2, data: Data([1]))
        XCTAssertFalse(skipped.isComplete)
    }

    // MARK: - v2: PC の変更を追う

    func testSameShapeOnlyWhenValuesAloneDiffer() throws {
        let a = [try effect("VolumePlugin"), section("S")]
        var b = a
        b[0].values = b[0].values.map { $0 - 1 }
        XCTAssertTrue(ETRemoteFollow.sameShape(a, b))
        var c = a
        c[0].enabled = false
        XCTAssertFalse(ETRemoteFollow.sameShape(a, c))
        XCTAssertFalse(ETRemoteFollow.sameShape(a, [a[0]]))
        XCTAssertFalse(ETRemoteFollow.sameShape([external(inputBus: 0, outputBus: 0)],
                                                [external(inputBus: 0, outputBus: 0)]))
    }

    // MARK: - telemetry: PC のアナライザの枠

    /// dsp/core/telemetry.cpp:109-117 と同じ 16 バイトのヘッダ（リトルエンディアン）＋ペイロード。
    private func wire(type: UInt16, version: UInt16, tap: UInt32, sequence: UInt32,
                      flags: UInt16, payload: [UInt8], payloadBytes: UInt16? = nil) -> String {
        var b: [UInt8] = []
        func put16(_ v: UInt16) { b += [UInt8(v & 0xff), UInt8(v >> 8)] }
        func put32(_ v: UInt32) { for s in stride(from: 0, to: 32, by: 8) { b.append(UInt8((v >> UInt32(s)) & 0xff)) } }
        put16(type); put16(version); put32(tap); put32(sequence)
        put16(payloadBytes ?? UInt16(payload.count)); put16(flags)
        b += payload
        return Data(b).base64EncodedString()
    }

    func testTelemetryParseReadsHeaderAndPayload() {
        let message: [String: Any] = ["op": "telemetry", "frames": [
            ["index": 3, "nm": "Spectrum Analyzer", "type": 4,
             "data": wire(type: 4, version: 2, tap: 0x01020304, sequence: 0xA0B0C0D0,
                          flags: 1, payload: [9, 8, 7, 6, 5])],
        ]]
        let entries = ETRemoteTelemetry.parse(message)
        XCTAssertEqual(entries.count, 1)
        guard let e = entries.first else { return }
        XCTAssertEqual(e.index, 3)
        XCTAssertEqual(e.nm, "Spectrum Analyzer")
        XCTAssertEqual(e.frame.type, 4)
        XCTAssertEqual(e.frame.version, 2)
        XCTAssertEqual(e.frame.tapId, 0x01020304)
        XCTAssertEqual(e.frame.sequence, 0xA0B0C0D0)
        XCTAssertTrue(e.frame.dropped)
        XCTAssertEqual(e.frame.payload, [9, 8, 7, 6, 5])

        let local = ETRemoteTelemetry.frame(e, tap: 42)
        XCTAssertEqual(local.tapId, 42)
        XCTAssertEqual(local.type, 4)
        XCTAssertEqual(local.version, 2)
        XCTAssertEqual(local.sequence, 0xA0B0C0D0)
        XCTAssertTrue(local.dropped)
        XCTAssertEqual(local.payload, [9, 8, 7, 6, 5])
    }

    func testTelemetryParseDropsBrokenEntries() {
        let good = wire(type: 1, version: 1, tap: 1, sequence: 1, flags: 0, payload: [1, 2, 3, 4])
        let message: [String: Any] = ["op": "telemetry", "frames": [
            ["nm": "Level Meter", "type": 1, "data": good],                       // index が無い
            ["index": 0, "type": 1, "data": good],                                // nm が無い
            ["index": 0, "nm": "Level Meter", "type": 1, "data": "%%%"],          // base64 でない
            ["index": 0, "nm": "Level Meter", "type": 1,
             "data": Data([1, 0, 1, 0]).base64EncodedString()],                   // 16 バイトに満たない
            ["index": 0, "nm": "Level Meter", "type": 1,
             "data": wire(type: 1, version: 1, tap: 1, sequence: 1, flags: 0,
                          payload: [1, 2, 3, 4], payloadBytes: 8)],               // 長さがヘッダと合わない
            ["index": 0, "nm": "Level Meter", "type": 1,
             "data": wire(type: 1, version: 1, tap: 1, sequence: 1, flags: 0,
                          payload: [1, 2, 3, 4, 0, 0, 0, 0], payloadBytes: 4)],   // 余りがある
            ["index": 5, "nm": "Level Meter", "type": 1, "data": good],
        ]]
        let entries = ETRemoteTelemetry.parse(message)
        XCTAssertEqual(entries.map(\.index), [5])
        XCTAssertFalse(entries[0].frame.dropped)
        XCTAssertTrue(ETRemoteTelemetry.parse(["op": "telemetry"]).isEmpty)
    }

    func testTelemetryParseAcceptsEmptyPayload() {
        let message: [String: Any] = ["frames": [
            ["index": 0, "nm": "Level Meter", "type": 1,
             "data": wire(type: 1, version: 1, tap: 1, sequence: 7, flags: 0, payload: [])],
        ]]
        XCTAssertEqual(ETRemoteTelemetry.parse(message).first?.frame.payload, [])
    }

    // MARK: - telemetry: PEQ の重ね表示

    func testTelemetryParseReadsRole() {
        let frame = wire(type: 4, version: 1, tap: 9, sequence: 1, flags: 0, payload: [0, 0, 0, 0])
        let message: [String: Any] = ["frames": [
            ["index": 0, "nm": "Spectrum Analyzer", "type": 4, "data": frame],
            ["index": 1, "nm": "5Band PEQ", "type": 4, "role": "before", "data": frame],
            ["index": 1, "nm": "5Band PEQ", "type": 4, "role": "after", "data": frame],
            ["index": 1, "nm": "5Band PEQ", "type": 4, "role": "middle", "data": frame],   // 知らない向き
            ["index": 1, "nm": "5Band PEQ", "type": 4, "role": 1, "data": frame],          // 字でない
            ["index": 1, "nm": "5Band PEQ", "type": 4, "role": NSNull(), "data": frame],   // null
        ]]
        let entries = ETRemoteTelemetry.parse(message)
        XCTAssertEqual(entries.map(\.index), [0, 1, 1])
        XCTAssertEqual(entries.map(\.role), [nil, "before", "after"])
    }

    private func node(_ type: String, tap: UInt32) throws -> ETChainNode {
        let spec = try XCTUnwrap(ETCatalog.first { $0.type == type }, "カタログに無い: \(type)")
        var n = ETChainNode(spec: spec, values: spec.defaults)
        n.tapId = tap
        return n
    }

    func testOverlayTapsPerStageType() throws {
        let probes: (before: UInt32, after: UInt32) = (before: 100, after: 101)
        // 探りのある PEQ は探りの前後。段の tapId は使わない。
        XCTAssertEqual(ETRemoteTelemetry.overlayTaps(try node("FiveBandPEQPlugin", tap: 5), probes: probes),
                       .init(before: 100, after: 101))
        XCTAssertEqual(ETRemoteTelemetry.overlayTaps(try node("FifteenBandPEQPlugin", tap: 6), probes: probes),
                       .init(before: 100, after: 101))
        // 探りの無い PEQ（バスを分けている・枠が足りない）は受けない。
        XCTAssertEqual(ETRemoteTelemetry.overlayTaps(try node("FiveBandPEQPlugin", tap: 5), probes: nil),
                       .init(before: nil, after: nil))
        // FIR PEQ は段の tapId に after だけ。探りを渡されても使わない。
        XCTAssertEqual(ETRemoteTelemetry.overlayTaps(try node("FiveBandFIRPEQPlugin", tap: 7), probes: nil),
                       .init(before: nil, after: 7))
        XCTAssertEqual(ETRemoteTelemetry.overlayTaps(try node("FiveBandFIRPEQPlugin", tap: 7), probes: probes),
                       .init(before: nil, after: 7))
        XCTAssertEqual(ETRemoteTelemetry.overlayTaps(try node("FiveBandFIRPEQPlugin", tap: 0), probes: nil),
                       .init(before: nil, after: nil))
        // PEQ でない段は受けない。
        XCTAssertEqual(ETRemoteTelemetry.overlayTaps(try node("SpectrumAnalyzerPlugin", tap: 8), probes: probes),
                       .init(before: nil, after: nil))
    }

    func testRouteOverlayFrames() throws {
        // 手元: 0 = 5Band PEQ（探り 100/101）、1 = 外部の段（PC に無い）、2 = FIR PEQ（tap 7）、3 = Spectrum Analyzer（tap 8）
        // PC:   0 = 5Band PEQ、1 = FIR PEQ、2 = Spectrum Analyzer
        let peq = try node("FiveBandPEQPlugin", tap: 5)
        let fir = try node("FiveBandFIRPEQPlugin", tap: 7)
        let sa = try node("SpectrumAnalyzerPlugin", tap: 8)
        let ext = ETChainNode(spec: ETEffect.external(type: "External:au:aufx-dely-abcd", name: "My Delay",
                                                      category: "Audio Units"),
                              values: [])
        let chain = [peq, ext, fir, sa]
        let sentMap: [Int?] = [0, nil, 1, 2]
        let sent: [[String: Any]] = [["nm": peq.spec.name], ["nm": fir.spec.name], ["nm": sa.spec.name]]
        let probes: (Int) -> (before: UInt32, after: UInt32)? = { $0 == 0 ? (before: 100, after: 101) : nil }
        func entry(_ index: Int, _ nm: String, role: String?, type: UInt16 = 4, seq: UInt32) -> ETRemoteTelemetry.Entry {
            ETRemoteTelemetry.Entry(index: index, nm: nm,
                                    frame: ETFrame(type: type, version: 1, tapId: 999, sequence: seq,
                                                   dropped: false, payload: []),
                                    role: role)
        }
        let entries = [
            entry(0, peq.spec.name, role: "before", seq: 1),
            entry(0, peq.spec.name, role: "after", seq: 2),
            entry(1, fir.spec.name, role: "before", seq: 3),         // FIR に入口は無い
            entry(1, fir.spec.name, role: "after", seq: 4),
            entry(2, sa.spec.name, role: nil, seq: 5),               // アナライザはそのまま
            entry(0, "15Band PEQ", role: "after", seq: 6),           // 名前違い（PC の鎖が変わった直後）
            entry(0, peq.spec.name, role: "after", type: 1, seq: 7), // Spectrum Analyzer の枠でない
            entry(2, sa.spec.name, role: "after", seq: 8),           // PEQ でない段に向き付き
            entry(5, peq.spec.name, role: "after", seq: 9),          // PC の番号が手元に無い
        ]
        let all: Set<UInt32> = [7, 8, 100, 101]
        let frames = ETRemoteTelemetry.route(entries, chain: chain, sentMap: sentMap, sent: sent,
                                             mirrored: all, probes: probes)
        XCTAssertEqual(frames.map(\.sequence), [1, 2, 4, 5])
        XCTAssertEqual(frames.map(\.tapId), [100, 101, 7, 8])

        // 映していない tap へは差し込まない（Mirror Analyzers を切った・PC が overlays を持たない）。
        let analyzersOnly = ETRemoteTelemetry.route(entries, chain: chain, sentMap: sentMap, sent: sent,
                                                    mirrored: [8], probes: probes)
        XCTAssertEqual(analyzersOnly.map(\.sequence), [5])

        // 手元で段を足して、まだ鎖を送っていない。
        XCTAssertTrue(ETRemoteTelemetry.route(entries, chain: chain + [sa], sentMap: sentMap, sent: sent,
                                              mirrored: all, probes: probes).isEmpty)
    }

    func testTelemetryInverseSkipsDroppedStages() {
        // 手元 0 → PC 0、手元 1 は外部の段で落ちた、手元 2 → PC 1。
        XCTAssertEqual(ETRemoteTelemetry.inverse([0, nil, 1]), [0: 0, 1: 2])
        XCTAssertEqual(ETRemoteTelemetry.inverse([]), [:])
    }

    // MARK: - つなぐ・切る（入切のスイッチは無い）

    func testIntentLayoutByState() {
        // 控えが無い: つなぎたいが残っていても Scan QR Code だけ。
        XCTAssertEqual(ETRemoteIntent(hasAddress: false, wantsConnection: false).layout, .unpaired)
        XCTAssertEqual(ETRemoteIntent(hasAddress: false, wantsConnection: true).layout, .unpaired)
        // 控えがあって、つなぎたい: PC / Options / Disconnect。
        XCTAssertEqual(ETRemoteIntent(hasAddress: true, wantsConnection: true).layout, .active)
        // 控えがあって、つなぎたくない: PC / Connect / Scan QR Code / Forget。
        XCTAssertEqual(ETRemoteIntent(hasAddress: true, wantsConnection: false).layout, .idle)
    }

    func testIntentPairConnectsImmediatelyAndClearsRejection() {
        var i = ETRemoteIntent(hasAddress: false, wantsConnection: false)
        i.pair()
        XCTAssertEqual(i, ETRemoteIntent(hasAddress: true, wantsConnection: true))
        XCTAssertEqual(i.layout, .active)

        // 4401 で止まっていても、読み直したらつなぐ。
        var rejected = ETRemoteIntent(hasAddress: true, wantsConnection: false, tokenRejected: true)
        rejected.pair()
        XCTAssertEqual(rejected, ETRemoteIntent(hasAddress: true, wantsConnection: true))
    }

    func testIntentDisconnectKeepsTheAddressAndConnectComesBack() {
        var i = ETRemoteIntent(hasAddress: true, wantsConnection: true)
        i.disconnect()
        XCTAssertEqual(i.layout, .idle)
        XCTAssertTrue(i.hasAddress)
        XCTAssertTrue(i.canConnect)
        XCTAssertTrue(i.connect())
        XCTAssertEqual(i.layout, .active)
        // つながっている（つなぎたい）あいだは Connect を出さない。
        XCTAssertFalse(i.canConnect)
    }

    func testIntentConnectNeedsAnAddressAndAnAcceptedToken() {
        var none = ETRemoteIntent(hasAddress: false, wantsConnection: false)
        XCTAssertFalse(none.connect())
        XCTAssertFalse(none.wantsConnection)

        var rejected = ETRemoteIntent(hasAddress: true, wantsConnection: false, tokenRejected: true)
        XCTAssertFalse(rejected.canConnect)
        XCTAssertFalse(rejected.connect())
        XCTAssertFalse(rejected.wantsConnection)
    }

    func testIntentForgetDropsEverything() {
        var i = ETRemoteIntent(hasAddress: true, wantsConnection: true, tokenRejected: true)
        i.forget()
        XCTAssertEqual(i, ETRemoteIntent(hasAddress: false, wantsConnection: false))
        XCTAssertEqual(i.layout, .unpaired)
    }

    func testIntentRejectedStopsWantingButKeepsTheAddress() {
        var i = ETRemoteIntent(hasAddress: true, wantsConnection: true)
        i.rejected()
        XCTAssertEqual(i.layout, .idle)
        XCTAssertTrue(i.tokenRejected)
        XCTAssertFalse(i.canConnect, "同じ字でつなぎ直しても通らない")
    }

    func testIntentLaunchReconnectsOnlyWhenNotDisconnectedAndPaired() {
        // Disconnect していなかった: 控えた PC へつなぎ直す。
        var kept = ETRemoteIntent(hasAddress: true, wantsConnection: true)
        kept.launch()
        XCTAssertTrue(kept.wantsConnection)
        // Disconnect した: つながない。
        var off = ETRemoteIntent(hasAddress: true, wantsConnection: false)
        off.launch()
        XCTAssertFalse(off.wantsConnection)
        // 控えが無いのに残っていた（前の版の enabled=true など）: 落とす。
        var orphan = ETRemoteIntent(hasAddress: false, wantsConnection: true)
        orphan.launch()
        XCTAssertFalse(orphan.wantsConnection)
    }

    func testLastHostRoundTripsAndFollowsTheHostInfo() throws {
        let info = ETRemoteHostInfo(state: ["appName": "EffeTune", "app": "2.11.0", "build": "db06db0e"])
        let last = ETRemoteLastHost(info)
        XCTAssertEqual(last, ETRemoteLastHost(name: "EffeTune", label: "2.11.0 (db06db0e)"))
        let data = try JSONEncoder().encode(last)
        XCTAssertEqual(try JSONDecoder().decode(ETRemoteLastHost.self, from: data), last)
    }

    func testLastHostKeepsTheHostNameAndReadsOldRecords() throws {
        let info = ETRemoteHostInfo(state: ["appName": "EffeTune", "app": "2.12.0", "host": "WIN-SE"])
        XCTAssertEqual(ETRemoteLastHost(info).hostName, "WIN-SE")
        // ホスト名を持たない前の記録も読める。
        let old = Data(#"{"name":"EffeTune","label":"2.11.0"}"#.utf8)
        let decoded = try JSONDecoder().decode(ETRemoteLastHost.self, from: old)
        XCTAssertNil(decoded.hostName)
        XCTAssertEqual(decoded.label, "2.11.0")
    }

    // MARK: - つながっているか（控えとは別）

    func testOnlyAnAnsweredHelloCountsAsConnected() {
        XCTAssertTrue(ETRemoteStatus.connected.isLive)
        for status in [ETRemoteStatus.disconnected, .connecting, .error("Can't connect")] {
            XCTAssertFalse(status.isLive, status.label)
        }
    }

    func testIndicatorIsBlueOnlyWhileLiveNotWhileMerelyWanted() {
        // 前の起動でつないだまま閉じた: 控えは「つなぎたい」でも、起動した直後はつながっていない。
        XCTAssertEqual(ETRemoteIndicator(wantsConnection: true, status: .disconnected), .connecting)
        XCTAssertEqual(ETRemoteIndicator(wantsConnection: true, status: .connecting), .connecting)
        // 開けなかった・応答が途絶えた。つなぎ直しを待つあいだも塗らない。
        XCTAssertEqual(ETRemoteIndicator(wantsConnection: true, status: .error("Can't connect")), .connecting)
        XCTAssertEqual(ETRemoteIndicator(wantsConnection: true, status: .connected), .live)
        XCTAssertEqual(ETRemoteIndicator(wantsConnection: false, status: .disconnected), .off)
        // 4401 で止まった: つなぎたくない側へ倒れているので脈も打たない。
        XCTAssertEqual(ETRemoteIndicator(wantsConnection: false, status: .error("Wrong token")), .off)
    }

    func testHeartbeatDeclaresTheHostGoneAfterTheDeadlineOfSilence() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        var hb = ETRemoteHeartbeat(now: t0)
        var now = t0
        // 何も聞こえないまま interval ごとに見回る。deadline を越えた回で切れたとみなす。
        while true {
            now += ETRemoteHeartbeat.interval
            let action = hb.tick(at: now)
            if now.timeIntervalSince(t0) <= ETRemoteHeartbeat.deadline {
                XCTAssertEqual(action, .ping, "deadline までは ping を送るだけ")
            } else {
                XCTAssertEqual(action, .dead)
                break
            }
        }
    }

    func testHeartbeatStaysAliveWhileTheHostAnswers() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        var hb = ETRemoteHeartbeat(now: t0)
        var now = t0
        for _ in 0..<50 {
            now += ETRemoteHeartbeat.interval
            XCTAssertEqual(hb.tick(at: now), .ping)
            hb.heard(at: now + 0.05)   // pong
        }
    }

    func testHeartbeatDoesNotCountTimeSpentSuspended() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        var hb = ETRemoteHeartbeat(now: t0)
        // 背景で止められて、見回りが 10 分ぶん飛んだ。戻った回は切らずに聞き直す。
        let back = t0 + 600
        XCTAssertEqual(hb.tick(at: back), .ping)
        XCTAssertEqual(hb.lastHeard, back)
        // そこから黙ったままなら、いつもどおり deadline で切れる。
        var now = back
        var last: ETRemoteHeartbeat.Action = .ping
        while now.timeIntervalSince(back) <= ETRemoteHeartbeat.deadline {
            now += ETRemoteHeartbeat.interval
            last = hb.tick(at: now)
        }
        XCTAssertEqual(last, .dead)
    }

    func testHeartbeatIgnoresAnOlderHeard() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        var hb = ETRemoteHeartbeat(now: t0)
        hb.heard(at: t0 + 10)
        hb.heard(at: t0 + 3)   // 遅れて届いた古い pong
        XCTAssertEqual(hb.lastHeard, t0 + 10)
    }
}
