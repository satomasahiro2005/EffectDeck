//  PipelineStoreTests.swift
//  鎖を書いて読み戻す（PipelineForm.swift）。**Sectionの終端（rootReset）が往復で残るか。**
//
//  前は終端を素の`Section("")`で書いていたので、再起動・自分のプリセット・
//  effectdeck.nemut.aiのリンクを通ると名前の無いSectionとして戻り、下の段を組に呑んでいた。
//  畳んだまま戻る（開いている段は位置で覚えていて、終端は開かない）ので、
//  組から出した段とその下が画面から消えていた。
//
//  模型（EffeTuneDSP）はAVFoundationとSwiftUIを連れてくるので入らない。
//  leaveSectionの代わりにETRootResetRule.insertionで印の位置を決め、
//  書く形はNodeを写した先のPipelineStore.Loadedから作る（Node版もLoadedへ写して書く）。

import XCTest

final class PipelineStoreTests: XCTestCase {

    // MARK: - 道具

    private func effect(_ type: String) throws -> PipelineStore.Loaded {
        let spec = try XCTUnwrap(ETCatalog.first { $0.type == type }, "カタログに無い: \(type)")
        return PipelineStore.Loaded(spec: spec, values: spec.defaults, enabled: true,
                                    inputBus: 0, outputBus: 0, channelSpec: -1)
    }

    private func section(_ name: String, on: Bool = true) -> PipelineStore.Loaded {
        PipelineStore.Loaded(spec: ETSection.spec, values: [], enabled: on,
                             inputBus: 0, outputBus: 0, channelSpec: -1, sectionName: name)
    }

    /// leaveSectionが挿すものと同じ（specはSection、入っている、名前は空）。
    private func rootReset() -> PipelineStore.Loaded {
        var item = section("")
        item.isRootReset = true
        return item
    }

    private func role(_ item: PipelineStore.Loaded) -> ETItemRole {
        if item.isRootReset { return .rootReset }
        return ETSection.isSection(item.spec) ? .section : .effect
    }

    /// `Drums Section / Volume / Delay`のDelayを組から出した鎖。
    /// 印の位置はETRootResetRule.insertionが決める（EffeTuneDSP.leaveSectionと同じ）。
    private func movedOut() throws -> [PipelineStore.Loaded] {
        var chain = [section("Drums"), try effect("VolumePlugin"), try effect("DelayPlugin")]
        let at = try XCTUnwrap(ETRootResetRule.insertion(roles: chain.map(role),
                                                         enabled: chain.map(\.enabled),
                                                         at: 2))
        chain.insert(rootReset(), at: at)
        return chain
    }

    /// 読み戻したものが「Delayはrootに居て、組の配下はVolumeだけ」になっているか。
    /// 名前の無いSectionが1本も無いことも見る（それが下の段を呑んでいた）。
    private func assertMovedOut(_ loaded: [PipelineStore.Loaded],
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(loaded.map(role), [.section, .effect, .rootReset, .effect],
                       file: file, line: line)
        XCTAssertEqual(loaded.map(\.spec.type),
                       [ETSection.type, "VolumePlugin", ETSection.type, "DelayPlugin"],
                       file: file, line: line)
        let unnamed = loaded.filter { role($0) == .section && $0.sectionName.isEmpty }
        XCTAssertTrue(unnamed.isEmpty, "名前の無い Section が戻った", file: file, line: line)

        let ids = loaded.map { _ in UUID() }
        let a = ETPipelineAnalysis.analyze(roles: loaded.map(role), ids: ids,
                                           enabled: loaded.map(\.enabled))
        XCTAssertEqual(a.members(of: ids[0]), [ids[1]], "組の配下が変わった", file: file, line: line)
        XCTAssertNil(a.owner(of: ids[3]), "出した段が組に戻った", file: file, line: line)
    }

    // MARK: - 書く形

    /// 終端は`Section(cm: "")`に印を付けたもの。**他の鍵は足さない。**
    func testRootResetIsWrittenAsMarkedEmptySection() throws {
        let form = PipelineStore.shortForm(try movedOut())
        XCTAssertEqual(form[2] as NSDictionary,
                       ["cm": "", "nm": "Section", "en": true, "rr": true] as NSDictionary)
        // 普通のSectionには付けない。
        XCTAssertNil(form[0][ETSection.rootResetKey])
    }

    /// effetune.frieve.comのリンクでは印を外し、上流が組の終わりに使う素のSection("")にする。
    /// 読み戻せば普通のSectionになる（外から来た空Sectionは推測しない）。
    func testUpstreamFormDropsTheMarker() throws {
        let form = PipelineStore.shortForm(try movedOut()).map(PipelineStore.upstreamEntry)
        XCTAssertEqual(form[2] as NSDictionary, ["cm": "", "nm": "Section", "en": true] as NSDictionary)
        let back = PipelineStore.parse(form, catalog: ETCatalog)
        XCTAssertEqual(back.map(role), [.section, .effect, .section, .effect])
    }

    /// 足したあとの形（`Drums Section / Volume`の末尾へ Delay を足す）も同じ書き方で往復する。
    /// 位置と印は ETChainEditing.addition が決める。
    func testRootResetFromAddingSurvivesRestart() throws {
        var chain = [section("Drums"), try effect("VolumePlugin")]
        let plan = ETChainEditing.addition(roles: chain.map(role), adding: .effect, to: .end)
        XCTAssertTrue(plan.leavesSection)
        chain.insert(rootReset(), at: plan.index)
        chain.insert(try effect("DelayPlugin"), at: plan.index + 1)

        let form = PipelineStore.shortForm(chain)
        XCTAssertEqual(form[2] as NSDictionary,
                       ["cm": "", "nm": "Section", "en": true, "rr": true] as NSDictionary)
        let data = try JSONSerialization.data(withJSONObject: form, options: [.sortedKeys])
        let back = PipelineStore.parse(try JSONSerialization.jsonObject(with: data), catalog: ETCatalog)
        XCTAssertEqual(back.map(role), [.section, .effect, .rootReset, .effect])
        // effetune.frieve.com へは印を外す。
        XCTAssertNil(PipelineStore.upstreamEntry(form[2])[ETSection.rootResetKey])
    }

    // MARK: - 往復

    /// 再起動（pipeline.last）。saveLastと同じく鍵を並べてJSONにし、loadLastと同じく読む。
    func testRootResetSurvivesRestart() throws {
        let data = try JSONSerialization.data(withJSONObject: PipelineStore.shortForm(try movedOut()),
                                              options: [.sortedKeys])
        let json = try JSONSerialization.jsonObject(with: data)
        assertMovedOut(PipelineStore.parse(json, catalog: ETCatalog))
    }

    /// 自分のプリセット。PresetStoreはショート形式をそのままUserDefaultsの辞書に入れる。
    func testRootResetSurvivesUserPreset() throws {
        let form = PipelineStore.shortForm(try movedOut())
        let data = try PropertyListSerialization.data(fromPropertyList: ["Mine": form],
                                                      format: .binary, options: 0)
        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        assertMovedOut(PipelineStore.parse(try XCTUnwrap(plist["Mine"]), catalog: ETCatalog))
    }

    /// effectdeck.nemut.aiのリンク。ETShareLink.deckURLと同じ形に書き、
    /// parseCheckedと同じ道（ETChainText.json → prepare → parse）で読む。
    /// **印を「読まなかった鍵」として出さない**（入れ替えの確認にIgnored: Section.rrが出る）。
    func testRootResetSurvivesDeckLink() throws {
        let data = try JSONSerialization.data(withJSONObject: PipelineStore.shortForm(try movedOut()),
                                              options: [.withoutEscapingSlashes, .sortedKeys])
        let link = "https://effectdeck.nemut.ai/?p="
            + data.base64EncodedString().replacingOccurrences(of: "+", with: "%2B")
        let json = try XCTUnwrap(ETChainText.json(from: link))
        let prepared = ETChainText.prepare(json, catalog: ETCatalog)
        XCTAssertTrue(prepared.report.isEmpty, prepared.report.message)
        assertMovedOut(PipelineStore.parse(prepared.json, catalog: ETCatalog))
    }

    /// バックアップ（ロング形式）。印は`parameters`の中ではなく段の鍵に置く。
    func testRootResetSurvivesBackup() throws {
        let long = PipelineStore.longForm(try movedOut())
        let list = try XCTUnwrap(long["pipeline"] as? [[String: Any]])
        XCTAssertEqual(list[2][ETSection.rootResetKey] as? Bool, true)
        XCTAssertEqual(list[2]["parameters"] as? NSDictionary, ["cm": ""] as NSDictionary)
        let data = try JSONSerialization.data(withJSONObject: long, options: [.sortedKeys])
        assertMovedOut(PipelineStore.parse(try JSONSerialization.jsonObject(with: data),
                                           catalog: ETCatalog))
        // ロングで貼られても印を「読まなかった鍵」として出さない。
        let prepared = ETChainText.prepare(try JSONSerialization.jsonObject(with: data),
                                           catalog: ETCatalog)
        XCTAssertTrue(prepared.report.isEmpty, prepared.report.message)
    }

    // MARK: - 推測しない

    /// 印の無い空Sectionは、名前を付けなかっただけの普通のSectionとして読む（web版の鎖）。
    func testBareEmptySectionStaysASection() throws {
        let json = try JSONSerialization.jsonObject(with: Data(#"""
            [{"nm":"Section","cm":"Drums","en":true},{"nm":"Volume","vl":0},
             {"nm":"Section","cm":"","en":true},{"nm":"Delay"}]
            """#.utf8))
        let back = PipelineStore.parse(json, catalog: ETCatalog)
        XCTAssertEqual(back.map(role), [.section, .effect, .section, .effect])
    }

    /// 印が付いていても、名前がある・切ってあるものは普通のSectionのまま。
    /// 終端にすると名前が消え、切ってあれば止まっていた段が鳴り出す（上流の読み方と食い違う）。
    func testMarkerOnANamedOrDisabledSectionIsIgnored() throws {
        let json = try JSONSerialization.jsonObject(with: Data(#"""
            [{"nm":"Section","cm":"Bass","en":true,"rr":true},{"nm":"Volume"},
             {"nm":"Section","cm":"","en":false,"rr":true},{"nm":"Delay"}]
            """#.utf8))
        let back = PipelineStore.parse(json, catalog: ETCatalog)
        XCTAssertEqual(back.map(role), [.section, .effect, .section, .effect])
        XCTAssertEqual(back[0].sectionName, "Bass")
        XCTAssertFalse(back[2].enabled)
    }
}
