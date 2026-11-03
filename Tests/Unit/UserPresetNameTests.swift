//  UserPresetNameTests.swift
//  ユーザープリセットの名前の読み方（SectionSupport.swift の ETUserPresetName）。
//
//  フォルダは名前の付け方だけで作る（`Rock/Heavy` なら `Rock` の中の `Heavy`）。
//  保存の鍵は名前そのままなので、ここを読み違えると一覧の束ね方と改名の行き先がずれる。

import XCTest

final class UserPresetNameTests: XCTestCase {

    func testFolder() {
        XCTAssertEqual(ETUserPresetName.folder("Rock/Heavy"), "Rock")
        XCTAssertEqual(ETUserPresetName.folder("Heavy"), "")
        XCTAssertEqual(ETUserPresetName.folder("/Heavy"), "")
        XCTAssertEqual(ETUserPresetName.folder("A/B/C"), "A", "最初の / で切る")
        XCTAssertEqual(ETUserPresetName.folder(""), "")
        XCTAssertEqual(ETUserPresetName.folder("日本語/名前"), "日本語")
    }

    func testLeaf() {
        XCTAssertEqual(ETUserPresetName.leaf("Rock/Heavy"), "Heavy")
        XCTAssertEqual(ETUserPresetName.leaf("Heavy"), "Heavy")
        XCTAssertEqual(ETUserPresetName.leaf("A/B/C"), "B/C", "2 つ目からの / は葉に残る")
        XCTAssertEqual(ETUserPresetName.leaf("Rock/"), "")
    }

    /// `/` は空白に替え、前後の空白と改行を落とす。
    func testClean() {
        XCTAssertEqual(ETUserPresetName.clean(" A/B "), "A B")
        XCTAssertEqual(ETUserPresetName.clean("a//b"), "a  b")
        XCTAssertEqual(ETUserPresetName.clean("\nWarm\t"), "Warm")
        XCTAssertEqual(ETUserPresetName.clean("/"), "")
    }

    /// `フォルダ/名前` の形へ。2 段目より深い `/` は落とし、空の側は捨てる。
    func testNormalized() {
        XCTAssertEqual(ETUserPresetName.normalized(" Rock / Heavy "), "Rock/Heavy")
        XCTAssertEqual(ETUserPresetName.normalized("A/B/C"), "A/B C")
        XCTAssertEqual(ETUserPresetName.normalized("/x"), "x")
        XCTAssertEqual(ETUserPresetName.normalized("x/"), "x")
        XCTAssertEqual(ETUserPresetName.normalized("  "), "")
        XCTAssertEqual(ETUserPresetName.normalized("plain"), "plain")
        XCTAssertEqual(ETUserPresetName.normalized("/"), "")
        // 正規形は正規形のまま。
        for s in ["Rock/Heavy", "A/B C", "x", ""] {
            XCTAssertEqual(ETUserPresetName.normalized(ETUserPresetName.normalized(s)),
                           ETUserPresetName.normalized(s), s)
        }
    }

    /// フォルダごとに束ねる。**並びは渡された順のまま**（フォルダも中身も）。
    func testFoldersKeepGivenOrder() {
        let got = ETUserPresetName.folders(["b/1", "a/1", "2", "b/2", "1"])
        XCTAssertEqual(got.map(\.name), ["b", "a", ""])
        XCTAssertEqual(got.map(\.items), [["b/1", "b/2"], ["a/1"], ["2", "1"]])
        XCTAssertTrue(ETUserPresetName.folders([]).isEmpty)
    }
}
