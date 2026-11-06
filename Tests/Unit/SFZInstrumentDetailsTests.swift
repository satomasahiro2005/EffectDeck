//  SFZInstrumentDetailsTests.swift
//  Instrument Details の行と、鍵盤スイッチの枠（型 34・版 1）の読みの見張り。**Foundation だけ。**
//
//  壊れると: 範囲の外の鍵が入った枠を読んでしまい画面に無い名前を出す、i16 の -1 を 65535 と読んで
//  スイッチ無しが「押されている」ことになる、行の並びや字面が上流（sfz-instrument.js）とずれる、
//  Output の番号が 0 始まりのまま出る、開く欄が空のバンクにも出る。

import XCTest

final class SFZInstrumentDetailsTests: XCTestCase {

    // MARK: 道具

    /// 16 チャンネルぶんの鍵から枠の payload を作る（i16 のリトルエンディアン）。
    private func payload(_ keys: [Int]) -> [UInt8] {
        var bytes: [UInt8] = []
        for key in keys {
            let raw = UInt16(bitPattern: Int16(key))
            bytes.append(UInt8(raw & 0xff))
            bytes.append(UInt8(raw >> 8))
        }
        return bytes
    }

    private func keys(_ set: [Int: Int]) -> [Int] {
        (0..<16).map { set[$0] ?? -1 }
    }

    private func parse(_ keys: [Int], type: UInt16 = 34, version: UInt16 = 1) -> ETSFZKeyswitchFrame? {
        ETSFZKeyswitchFrame.parse(type: type, version: version, payload: payload(keys))
    }

    // MARK: 枠

    func testFrameTypeNumbersMatchUpstream() {
        XCTAssertEqual(ETFrameType.sfzScriptMessage.rawValue, 33)
        XCTAssertEqual(ETFrameType.sfzKeyswitches.rawValue, 34)
        XCTAssertEqual(ETSFZKeyswitchFrame.byteCount, 32)
        XCTAssertEqual(ETSFZKeyswitchFrame.channelCount, 16)
    }

    func testParsesSixteenChannelsOfInt16() throws {
        let frame = try XCTUnwrap(parse(keys([0: 0, 1: 127, 5: 36])))
        XCTAssertEqual(frame.keys.count, 16)
        XCTAssertEqual(frame.keys[0], 0)
        XCTAssertEqual(frame.keys[1], 127)
        XCTAssertEqual(frame.keys[5], 36)
        XCTAssertEqual(frame.keys[2], -1, "-1 は無し（FF FF）")
        XCTAssertEqual(frame.keys[15], -1)
    }

    func testMinusOneIsReadAsSignedNotAsUnsigned() throws {
        let bytes = [UInt8](repeating: 0xff, count: 32)
        let frame = try XCTUnwrap(ETSFZKeyswitchFrame.parse(type: 34, version: 1, payload: bytes))
        XCTAssertEqual(frame.keys, [Int](repeating: -1, count: 16))
    }

    func testKeysAreLittleEndian() throws {
        var bytes = [UInt8](repeating: 0xff, count: 32)
        bytes[6] = 0x40     // チャンネル 3 の下位バイト
        bytes[7] = 0x00
        let frame = try XCTUnwrap(ETSFZKeyswitchFrame.parse(type: 34, version: 1, payload: bytes))
        XCTAssertEqual(frame.keys[3], 0x40)
    }

    func testRejectsWrongTypeVersionAndLength() {
        XCTAssertNil(parse(keys([:]), type: 30))
        XCTAssertNil(parse(keys([:]), type: 33))
        XCTAssertNil(parse(keys([:]), version: 0))
        XCTAssertNil(parse(keys([:]), version: 2))
        XCTAssertNil(ETSFZKeyswitchFrame.parse(type: 34, version: 1, payload: [UInt8](repeating: 0xff, count: 31)))
        XCTAssertNil(ETSFZKeyswitchFrame.parse(type: 34, version: 1, payload: [UInt8](repeating: 0xff, count: 33)))
        XCTAssertNil(ETSFZKeyswitchFrame.parse(type: 34, version: 1, payload: []))
    }

    /// 上流は 1 チャンネルでも -1…127 の外なら枠ごと捨てる。
    func testRejectsTheWholeFrameWhenAnyKeyIsOutOfRange() {
        XCTAssertNil(parse(keys([0: 128])))
        XCTAssertNil(parse(keys([15: 128])), "最後のチャンネルも見る")
        XCTAssertNil(parse(keys([7: -2])))
        XCTAssertNil(parse(keys([3: 32767])))
        XCTAssertNil(parse(keys([3: -32768])))
        XCTAssertNotNil(parse(keys([0: 127, 1: -1])), "端は通る")
    }

    // MARK: 行

    private func label(_ index: Int, _ text: String) -> ETSFZScriptLabel { ETSFZScriptLabel(index: index, label: text) }

    func testRowsFollowUpstreamOrderAndWording() {
        var p = ETSFZScriptPresentation()
        p.keys = [label(36, "Kick"), label(38, "Snare")]
        p.controllers = [label(1, "Mod wheel")]
        p.outputs = [label(0, "Main"), label(3, "Room")]
        p.groups = ["Body", "Tail"]
        p.scopes = [(scope: "global", label: "All"), (scope: "master", label: "Layer"), (scope: "region", label: "Hit")]
        p.switches = [(first: 24, last: 24, label: "Legato"), (first: 25, last: 27, label: "Staccato")]
        XCTAssertEqual(ETSFZInstrumentDetails.rows(p), [
            .init(name: "Key 36", value: "Kick"),
            .init(name: "Key 38", value: "Snare"),
            .init(name: "CC 1", value: "Mod wheel"),
            .init(name: "Output 1", value: "Main"),
            .init(name: "Output 4", value: "Room"),
            .init(name: "Group", value: "Body"),
            .init(name: "Group", value: "Tail"),
            .init(name: "Global", value: "All"),
            .init(name: "Master", value: "Layer"),
            .init(name: "Region", value: "Hit"),
            .init(name: "Keyswitch 24", value: "Legato"),
            .init(name: "Keyswitch 25–27", value: "Staccato"),
        ])
    }

    func testSingleKeyKeyswitchHasNoRange() {
        var p = ETSFZScriptPresentation()
        p.switches = [(first: 0, last: 0, label: "A")]
        XCTAssertEqual(ETSFZInstrumentDetails.rows(p).map(\.name), ["Keyswitch 0"])
    }

    func testIsEmptyOnlyWithoutImageAndRows() {
        XCTAssertTrue(ETSFZInstrumentDetails.isEmpty(nil))
        XCTAssertTrue(ETSFZInstrumentDetails.isEmpty(ETSFZScriptPresentation()))
        var withImagePath = ETSFZScriptPresentation()
        withImagePath.image = "art.png"
        XCTAssertTrue(ETSFZInstrumentDetails.isEmpty(withImagePath), "道だけで中身が読めていなければ出さない")
        var withImage = ETSFZScriptPresentation()
        withImage.imageData = Data([1, 2, 3])
        XCTAssertFalse(ETSFZInstrumentDetails.isEmpty(withImage))
        var withRow = ETSFZScriptPresentation()
        withRow.groups = ["G"]
        XCTAssertFalse(ETSFZInstrumentDetails.isEmpty(withRow))
        var withScope = ETSFZScriptPresentation()
        withScope.scopes = [(scope: "region", label: "R")]
        XCTAssertFalse(ETSFZInstrumentDetails.isEmpty(withScope))
    }

    // MARK: 押されているスイッチの 1 行

    private let switches: [(first: Int, last: Int, label: String)] = [
        (first: 24, last: 24, label: "Legato"),
        (first: 25, last: 27, label: "Staccato"),
        (first: 26, last: 30, label: "Pizzicato"),
        (first: 26, last: 26, label: "Staccato"),
    ]

    func testActiveLineListsChannelsInOrder() throws {
        let frame = try XCTUnwrap(parse(keys([0: 24, 2: 25])))
        XCTAssertEqual(ETSFZInstrumentDetails.activeLine(frame: frame, switches: switches),
                       "Keyswitch · Channel 1: Legato · Channel 3: Staccato")
    }

    /// 範囲が重なると名前を全部出し、同じ名前は 1 度だけ（上流の Set）。
    func testActiveLineJoinsOverlappingNamesWithoutRepeats() throws {
        let frame = try XCTUnwrap(parse(keys([0: 26])))
        XCTAssertEqual(ETSFZInstrumentDetails.activeLine(frame: frame, switches: switches),
                       "Keyswitch · Channel 1: Staccato, Pizzicato")
    }

    func testActiveLineSkipsChannelsWithNoSwitchOrNoLabel() throws {
        XCTAssertNil(ETSFZInstrumentDetails.activeLine(frame: try XCTUnwrap(parse(keys([:]))), switches: switches),
                     "全部 -1 なら行ごと出さない")
        XCTAssertNil(ETSFZInstrumentDetails.activeLine(frame: try XCTUnwrap(parse(keys([0: 60]))), switches: switches),
                     "どの範囲にも入らない鍵は出さない")
        let mixed = try XCTUnwrap(parse(keys([0: 60, 1: 24])))
        XCTAssertEqual(ETSFZInstrumentDetails.activeLine(frame: mixed, switches: switches), "Keyswitch · Channel 2: Legato")
    }

    func testActiveLineNeedsFrameAndSwitches() throws {
        let frame = try XCTUnwrap(parse(keys([0: 24])))
        XCTAssertNil(ETSFZInstrumentDetails.activeLine(frame: nil, switches: switches))
        XCTAssertNil(ETSFZInstrumentDetails.activeLine(frame: frame, switches: []))
    }

    func testActiveLineHonoursMixerChannel() throws {
        let frame = try XCTUnwrap(parse(keys([0: 24, 1: 25])))
        XCTAssertEqual(ETSFZInstrumentDetails.activeLine(frame: frame, switches: switches, mixerChannel: 2),
                       "Keyswitch · Channel 2: Staccato")
        XCTAssertEqual(ETSFZInstrumentDetails.activeLine(frame: frame, switches: switches, mixerChannel: 1),
                       "Keyswitch · Channel 1: Legato")
        XCTAssertNil(ETSFZInstrumentDetails.activeLine(frame: frame, switches: switches, mixerChannel: 3))
        XCTAssertEqual(ETSFZInstrumentDetails.activeLine(frame: frame, switches: switches, mixerChannel: 0),
                       "Keyswitch · Channel 1: Legato · Channel 2: Staccato", "0 は全チャンネル")
    }

    // MARK: 取り込み

    func testPresentationEqualityCoversScopes() {
        var a = ETSFZScriptPresentation()
        var b = ETSFZScriptPresentation()
        XCTAssertEqual(a, b)
        a.scopes = [(scope: "region", label: "R")]
        XCTAssertNotEqual(a, b)
        b.scopes = [(scope: "region", label: "R")]
        XCTAssertEqual(a, b)
        b.scopes = [(scope: "master", label: "R")]
        XCTAssertNotEqual(a, b)
    }
}
