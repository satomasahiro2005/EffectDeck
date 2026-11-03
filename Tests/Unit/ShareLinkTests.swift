//  ShareLinkTests.swift
//  共有リンクを書く側（ETShareLink.swift）。読む側は ChainTextTests と PipelineStoreTests。
//
//  見ているもの:
//    - `+` を %2B で書く。web 版は `p=` を URLSearchParams で読むので、素の `+` は空白に化けて
//      /^[A-Za-z0-9+/=]+$/ に落ちる（error.invalidUrl）。こちらの parse は URLComponents 経由で
//      読めてしまうので、送った側では気付けない。ここでは URLSearchParams と同じ読み方で読む
//    - effetune.frieve.com へのリンクから外部の段（AU / JSFX）を外す。同じバスの中の段は消し、
//      バスを渡る段は 0 dB の Volume に替えて ib / ob / ch と入切を残す
//    - effectdeck.nemut.ai へのリンクは外部の段をそのまま運ぶ

import XCTest

final class ShareLinkTests: XCTestCase {

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

    private func external(inputBus: UInt8, outputBus: UInt8, channelSpec: Int8 = -1,
                          enabled: Bool = true) -> PipelineStore.Loaded {
        PipelineStore.Loaded(
            spec: ETEffect.external(type: "External:au:aufx-dely-abcd", name: "My Delay",
                                    category: "Audio Units"),
            values: [], enabled: enabled, inputBus: inputBus, outputBus: outputBus,
            channelSpec: channelSpec, externalID: "au:aufx-dely-abcd",
            externalInstanceID: "inst-1", externalState: Data([1, 2, 3]))
    }

    /// WHATWG の application/x-www-form-urlencoded の読み方（URLSearchParams と同じ）。
    /// `+` は空白、`%XX` はバイト、読めない `%` はそのまま。最後に UTF-8。
    private func searchParam(_ name: String, in url: URL) -> String? {
        guard let query = rawQuery(url) else { return nil }
        for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if formDecode(String(parts[0])) == name {
                return formDecode(parts.count > 1 ? String(parts[1]) : "")
            }
        }
        return nil
    }

    /// 符号化されたままのクエリ。
    private func rawQuery(_ url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery
    }

    private func formDecode(_ s: String) -> String {
        let bytes = Array(s.utf8)
        var out: [UInt8] = []
        var i = 0
        func hex(_ b: UInt8) -> UInt8? {
            switch b {
            case 0x30...0x39: return b - 0x30
            case 0x41...0x46: return b - 0x41 + 10
            case 0x61...0x66: return b - 0x61 + 10
            default: return nil
            }
        }
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x2B {
                out.append(0x20)
                i += 1
            } else if b == 0x25, i + 2 < bytes.count, let h = hex(bytes[i + 1]), let l = hex(bytes[i + 2]) {
                out.append(h << 4 | l)
                i += 3
            } else {
                out.append(b)
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// web 版（ui-manager.js:573 / clipboard-manager.js:120）が通す base64 か。
    private func passesUpstreamCheck(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy {
            ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0)
                || $0 == "+" || $0 == "/" || $0 == "="
        }
    }

    /// base64 の `p=` を JSON の配列へ。
    private func decodedList(_ base64: String) throws -> [[String: Any]] {
        let data = try XCTUnwrap(Data(base64Encoded: base64), "base64 でない: \(base64)")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    /// base64 にしたときに `+` が出る Section 名。候補を順に試して最初のものを使う。
    ///
    /// `+`（0b111110）が出るかは UTF-8 のバイトが 3 バイトの区切りのどこに来るかで決まる。
    /// `[{"cm":"` の直後から始まる和文だけの名前は、どの字でも `+` を生まない（先頭のバイト
    /// 0xE3 の上 2 bit が 11 なので、手前の 6 bit の下 2 bit が 10 にならない）。ASCII を前に置いて
    /// 区切りをずらした名前で出る（"Low 低音" など）。実際の鎖では前に別の段が並ぶので、
    /// 和文だけの名前でも出る。
    private func nameWhoseLinkHasPlus() throws -> String {
        let candidates = ["", "x", "Low ", "ab", "Vo "].flatMap { head in
            ["低音", "ドラム", "ボーカル", "声", "空間"].map { head + $0 }
        }
        for name in candidates {
            let form = PipelineStore.shortForm([section(name)])
            let data = try JSONSerialization.data(withJSONObject: form,
                                                  options: [.withoutEscapingSlashes, .sortedKeys])
            if data.base64EncodedString().contains("+") { return name }
        }
        XCTFail("どの候補も base64 に + を生まない")
        return candidates[0]
    }

    // MARK: - %2B

    /// ASCII 以外の Section 名で `+` が出るリンクを、URLSearchParams と同じ読み方で読む。
    func testPlusEncodedAsPercent2B() throws {
        let name = try nameWhoseLinkHasPlus()
        let chain = [section(name), try effect("VolumePlugin")]
        for (label, url) in [("effetune", ETShareLink.url(for: chain)),
                             ("deck", ETShareLink.deckURL(for: chain))] {
            let link = try XCTUnwrap(url, label)
            let query = try XCTUnwrap(rawQuery(link), label)
            XCTAssertFalse(query.contains("+"), "\(label): 素の + が残っている: \(query)")
            XCTAssertTrue(query.contains("%2B"), label)

            let p = try XCTUnwrap(searchParam("p", in: link), label)
            XCTAssertTrue(passesUpstreamCheck(p), "\(label): web 版の検査に落ちる: \(p)")
            let list = try decodedList(p)
            XCTAssertEqual(list.first?["cm"] as? String, name, label)
            XCTAssertEqual(list.count, 2, label)
        }
    }

    /// 直さなければ web 版で落ちることの確かめ（上の試験が本当に `+` を踏んでいるか）。
    func testUnescapedPlusWouldBreakUpstream() throws {
        let name = try nameWhoseLinkHasPlus()
        let data = try JSONSerialization.data(withJSONObject: PipelineStore.shortForm([section(name)]),
                                              options: [.withoutEscapingSlashes, .sortedKeys])
        let raw = data.base64EncodedString()
        let url = try XCTUnwrap(URL(string: ETShareLink.base + "?p=" + raw))
        let p = try XCTUnwrap(searchParam("p", in: url))
        XCTAssertTrue(p.contains(" "))
        XCTAssertFalse(passesUpstreamCheck(p))
    }

    /// こちらの読む側（parse）でも同じ鎖に戻る。
    func testLinksParseBack() throws {
        let name = try nameWhoseLinkHasPlus()
        let chain = [section(name), try effect("VolumePlugin"), try effect("DelayPlugin")]
        for url in [ETShareLink.url(for: chain), ETShareLink.deckURL(for: chain)] {
            let link = try XCTUnwrap(url)
            let back = ETShareLink.parse(link.absoluteString, catalog: ETCatalog)
            XCTAssertEqual(back.map(\.spec.type), [ETSection.type, "VolumePlugin", "DelayPlugin"])
            XCTAssertEqual(back.first?.sectionName, name)
        }
    }

    // MARK: - 外部の段（effetune.frieve.com）

    /// 同じバスの中の外部の段は消す（素通しは削除と同じ）。
    func testExternalOnOneBusRemoved() throws {
        let chain = [try effect("VolumePlugin"), external(inputBus: 0, outputBus: 0),
                     external(inputBus: 2, outputBus: 2), try effect("DelayPlugin")]
        let form = ETShareLink.effeTuneForm(chain)
        XCTAssertEqual(form.compactMap { $0["nm"] as? String }, ["Volume", "Delay"])
        for entry in form {
            for key in ["external", "externalInstance", "externalState"] {
                XCTAssertNil(entry[key], key)
            }
        }
    }

    /// バスを渡る外部の段は 0 dB の Volume。ib / ob / ch と入切を残し、ほかの鍵は付けない。
    func testExternalCrossingBusesBecomes0dBVolume() throws {
        let chain = [external(inputBus: 1, outputBus: 2, channelSpec: 0, enabled: false),
                     external(inputBus: 0, outputBus: 3)]
        let form = ETShareLink.effeTuneForm(chain)
        XCTAssertEqual(form.count, 2)
        XCTAssertEqual(form[0] as NSDictionary,
                       ["nm": "Volume", "en": false, "vl": 0.0, "ib": 1, "ob": 2, "ch": "L"] as NSDictionary)
        XCTAssertEqual(form[1] as NSDictionary,
                       ["nm": "Volume", "en": true, "vl": 0.0, "ob": 3] as NSDictionary)
        // web 版と同じ読み方で Volume として戻る（こちらの parse でも）。
        let back = PipelineStore.parse(form, catalog: ETCatalog)
        XCTAssertEqual(back.map(\.spec.type), ["VolumePlugin", "VolumePlugin"])
        XCTAssertEqual(back.map(\.inputBus), [1, 0])
        XCTAssertEqual(back.map(\.outputBus), [2, 3])
        XCTAssertEqual(back.map(\.channelSpec), [0, -1])
        XCTAssertEqual(back.map(\.enabled), [false, true])
    }

    /// リンクの中身に外部の段の鍵と終端の印が一つも残らない。外部の段しか無ければリンクを作らない。
    func testUpstreamLinkCarriesNoEffectDeckKeys() throws {
        var reset = section("")
        reset.isRootReset = true
        let chain = [section("A"), try effect("VolumePlugin"), reset,
                     external(inputBus: 0, outputBus: 1), try effect("DelayPlugin")]
        let link = try XCTUnwrap(ETShareLink.url(for: chain))
        XCTAssertTrue(link.absoluteString.hasPrefix(ETShareLink.base + "?p="))
        let list = try decodedList(try XCTUnwrap(searchParam("p", in: link)))
        XCTAssertEqual(list.count, 5)
        for entry in list {
            for key in ["external", "externalInstance", "externalState", ETSection.rootResetKey] {
                XCTAssertNil(entry[key], "\(key) in \(entry)")
            }
        }
        XCTAssertNil(ETShareLink.url(for: [external(inputBus: 0, outputBus: 0)]))
        XCTAssertNil(ETShareLink.url(for: [PipelineStore.Loaded]()))
    }

    // MARK: - effectdeck.nemut.ai

    /// こちらどうしのリンクは外部の段をそのまま運ぶ。
    func testDeckLinkKeepsExternals() throws {
        let chain = [try effect("VolumePlugin"), external(inputBus: 0, outputBus: 0, channelSpec: 17)]
        let link = try XCTUnwrap(ETShareLink.deckURL(for: chain))
        XCTAssertTrue(link.absoluteString.hasPrefix(ETShareLink.deckBase + "?p="))
        let back = ETShareLink.parse(link.absoluteString, catalog: ETCatalog)
        XCTAssertEqual(back.count, 2)
        XCTAssertEqual(back[1].externalID, "au:aufx-dely-abcd")
        XCTAssertEqual(back[1].externalInstanceID, "inst-1")
        XCTAssertEqual(back[1].externalState, Data([1, 2, 3]))
        XCTAssertEqual(back[1].channelSpec, 17)
    }

    /// 鎖の段（ETChainNode）から書いても、写した Loaded から書いても同じリンク。
    func testNodeOverloadsMatchLoaded() throws {
        let volume = try XCTUnwrap(ETCatalog.first { $0.type == "VolumePlugin" })
        var a = ETChainNode(spec: volume, values: volume.defaults)
        a.inputBus = 1
        a.outputBus = 2
        var b = ETChainNode(spec: ETEffect.external(type: "External:jsfx:x", name: "x", category: "JSFX"),
                            values: [])
        b.externalID = "jsfx:x"
        b.externalInstanceID = "j1"
        b.inputBus = 0
        b.outputBus = 1
        let nodes = [a, b]
        let loaded = nodes.map { PipelineStore.Loaded($0) }
        XCTAssertEqual(ETShareLink.url(for: nodes), ETShareLink.url(for: loaded))
        XCTAssertEqual(ETShareLink.deckURL(for: nodes), ETShareLink.deckURL(for: loaded))
        XCTAssertEqual(ETShareLink.effeTuneForm(nodes).map { $0 as NSDictionary },
                       ETShareLink.effeTuneForm(loaded).map { $0 as NSDictionary })
    }
}
