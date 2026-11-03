//  FeedbackLoopTests.swift
//  出力先が自分の仮想デバイスか（ETAudioSessionRules.isOwnDevice）。
//
//  これが外れると帰還ループ（出力 → ドライバ → TCP → 自分の入力 → 出力 …）に
//  気づけず、レベルだけ上がってスピーカーに何も届かない状態が続く。
//  名前で見ているので、ドライバやルートピッカーの名前を変えたときに壊れる。

import XCTest

final class FeedbackLoopTests: XCTestCase {

    func testExactNameMatches() {
        XCTAssertTrue(ETAudioSessionRules.isOwnDevice(portName: "EffectDeck"))
    }

    /// 大文字小文字を区別しない。
    func testCaseInsensitive() {
        XCTAssertTrue(ETAudioSessionRules.isOwnDevice(portName: "effectdeck"))
        XCTAssertTrue(ETAudioSessionRules.isOwnDevice(portName: "EFFECTDECK"))
        XCTAssertTrue(ETAudioSessionRules.isOwnDevice(portName: "eFfEcTdEcK"))
    }

    /// 前方一致ではなく包含で見る。系が名前の前後に何か付けても拾う。
    func testContainsNotPrefix() {
        XCTAssertTrue(ETAudioSessionRules.isOwnDevice(portName: "EffectDeck (2)"))
        XCTAssertTrue(ETAudioSessionRules.isOwnDevice(portName: "iPhone → EffectDeck"))
        XCTAssertTrue(ETAudioSessionRules.isOwnDevice(portName: "My EffectDeck Bridge"))
    }

    /// 普通の出力先は自分ではない。AirPlay の型で出る本物のスピーカーも名前で分ける。
    func testOtherOutputsAreNotOwnDevice() {
        for name in ["Speaker", "iPhone Speaker", "AirPods Pro", "Living Room", "HomePod",
                     "USB Audio CODEC", "Effect", "Deck", "Effect Deck", "EffeTune", ""] {
            XCTAssertFalse(ETAudioSessionRules.isOwnDevice(portName: name), name)
        }
    }

    /// Swift の写しが ETNames.h の ET_NAME_STEM と同じ字であること。
    /// 食い違うと、ドライバが名乗る名前に写しが含まれず、帰還ループを見逃す。
    /// ETNames.h はこのバンドルに資源として入れてある（project.yml）。
    func testNameStemMatchesETNamesHeader() throws {
        let url = try XCTUnwrap(TestResource.url("ETNames", "h")
                                ?? TestResource.url("ETNames", "h", subdirectory: "Sources/Shared"),
                                "ETNames.h が資源に無い")
        let header = try String(contentsOf: url, encoding: .utf8)
        func define(_ name: String) -> String? {
            for line in header.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: "\"", omittingEmptySubsequences: false)
                let head = parts.first.map { $0.split(separator: " ").filter { !$0.isEmpty } } ?? []
                if head.count == 2, head[0] == "#define", head[1] == name, parts.count >= 3 {
                    return String(parts[1])
                }
            }
            return nil
        }
        let stem = try XCTUnwrap(define("ET_NAME_STEM"))
        XCTAssertEqual(stem, ETAudioSessionRules.nameStem)
        // ドライバとルートピッカーが名乗る名前は、どちらも写しで拾えること。
        for name in ["ET_ROUTE_NAME", "ET_DRIVER_NAME"] {
            let value = try XCTUnwrap(define(name), name)
            XCTAssertTrue(ETAudioSessionRules.isOwnDevice(portName: value), "\(name) = \(value)")
        }
    }
}
