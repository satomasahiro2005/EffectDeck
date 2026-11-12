//  Upstream218Tests.swift
//  EffeTune 2.18.0（DSP 0.18.0）で変わったものの見張り。**Foundation だけ。**
//
//  2.18.0 が足したのは Live Audio Receive / Send（EffeTune どうしで音を送り合う位置の印。カーネルは素通し）と、
//  SoundFont Player の 4 つのパラメーター。効果は 113 から 115 種になった。
//  どちらもこのアプリでは一覧に出さない（Tests/Tools/test_picker_hidden.py が字で見張る）。
//  壊れると: hash が食い違って PC から届いた鎖の set_params が断られる、印の型が鎖を読めなくする、
//  標本の多い音源（2.18.0 で上限が 10000 から 65536）を流し込みの表が断る。

import XCTest

final class Upstream218Tests: XCTestCase {

    private func spec(_ type: String) throws -> ETEffect {
        try XCTUnwrap(ETCatalog.first { $0.type == type }, "\(type) が目録に無い")
    }

    func testUpstreamVersionIs0_18_0() {
        XCTAssertEqual(ETUpstreamVersion, "0.18.0")
        XCTAssertEqual(ETUpstreamAppVersion, "2.18.0", "package.json の版。公式の PC との食い違いの表示に使う")
        XCTAssertEqual(ETCatalog.count, 115)
        XCTAssertEqual(ETCatalog.reduce(0) { $0 + $1.params.count }, 730)
    }

    // MARK: Live Audio Receive / Send

    func testLiveAudioMarkersAreInTheCatalogWithNoParameters() throws {
        for (type, name) in [("NetworkReceivePlugin", "Live Audio Receive"), ("NetworkSendPlugin", "Live Audio Send")] {
            let s = try spec(type)
            XCTAssertEqual(s.name, name)
            XCTAssertEqual(s.category, "control")
            XCTAssertEqual(s.floatCount, 0)
            XCTAssertTrue(s.params.isEmpty)
            XCTAssertEqual(s.paramsHash, 0x811c9dc5, "空の並びの FNV-1a。カーネルと食い違うと set_params が断られる")
            XCTAssertFalse(ETAutomation.isAutomatable(s))
        }
    }

    func testChainWithLiveAudioMarkersLoadsAndWritesBack() throws {
        // PC の鎖に印が居ても読める（音は素通し）。書き戻しても名前が残る。
        let loaded = PipelineStore.parse([["nm": "Live Audio Receive"], ["nm": "Volume"], ["nm": "Live Audio Send"]],
                                         catalog: ETCatalog)
        XCTAssertEqual(loaded.map(\.spec.type), ["NetworkReceivePlugin", "VolumePlugin", "NetworkSendPlugin"])
        let written = PipelineStore.shortForm(loaded)
        XCTAssertEqual(written.map { $0["nm"] as? String }, ["Live Audio Receive", "Volume", "Live Audio Send"])
    }

    // MARK: SoundFont Player（一覧に出さない型。hash と並びだけ）

    func testSoundFontPlayerLayout() throws {
        let s = try spec("SoundFontPlayerPlugin")
        XCTAssertEqual(s.paramsHash, 0xf271de51)
        XCTAssertEqual(s.floatCount, 8)
        XCTAssertEqual(s.params.sorted { $0.offset < $1.offset }.map(\.key),
                       ["mc", "pl", "og", "sq", "af", "pm", "pc", "sc"])
        XCTAssertEqual(s.defaults, [0, 256, 0, 1, 1, -1, 0, 0])
    }

    // MARK: 流し込みの表

    func testStreamTableSampleLimitFollowsUpstream() {
        XCTAssertEqual(ETSFZStreamTable.maxSamples, 65536, "上流 SFZ_MAX_SAMPLES・SamplePageCache::kMaxSamples")
    }
}
