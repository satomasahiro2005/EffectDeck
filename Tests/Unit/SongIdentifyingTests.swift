//  SongIdentifyingTests.swift
//  曲の取得中の見せ方の状態（SongIdentifying）。
//
//  壊れると: 曲を飛ばしても粒が出ない、新しい曲が決まっても粒が居座る、間違いだったのにアートワークが戻らない、
//  粒の色が前の曲の色から戻らない。

import XCTest

final class SongIdentifyingTests: XCTestCase {

    private let red = ETVisualizerColor(0xFF0000)
    private let blue = ETVisualizerColor(0x032457)

    func testIdleIsZero() {
        let s = ETSongIdentifying()
        XCTAssertEqual(s.phase, .idle)
        XCTAssertEqual(s.weight(now: 5), 0)
    }

    func testBeginGivesFullWeight() {
        var s = ETSongIdentifying()
        s.begin(now: 10, tint: red)
        XCTAssertEqual(s.phase, .identifying(since: 10))
        XCTAssertEqual(s.weight(now: 10), 1)
        XCTAssertEqual(s.weight(now: 100), 1)
    }

    func testRevealFadesOverSixTenthsThenSettles() {
        var s = ETSongIdentifying()
        s.begin(now: 0, tint: nil)
        s.reveal(now: 3)
        XCTAssertEqual(s.weight(now: 3), 1, accuracy: 1e-12)
        XCTAssertEqual(s.weight(now: 3.3), 0.5, accuracy: 1e-9)
        XCTAssertEqual(s.weight(now: 3.6), 0, accuracy: 1e-12)
        XCTAssertEqual(s.weight(now: 9), 0, accuracy: 1e-12)
        s.settle(now: 3.5)
        XCTAssertEqual(s.phase, .revealing(since: 3))
        s.settle(now: 3.6)
        XCTAssertEqual(s.phase, .idle)
    }

    func testCancelReturnsToZeroAtOnce() {
        var s = ETSongIdentifying()
        s.begin(now: 0, tint: red)
        s.cancel()
        XCTAssertEqual(s.phase, .idle)
        XCTAssertEqual(s.weight(now: 0.1), 0)
        // 切り替えの途中でも
        s.begin(now: 1, tint: red)
        s.reveal(now: 2)
        s.cancel()
        XCTAssertEqual(s.weight(now: 2.1), 0)
    }

    func testBeginWhileIdentifyingKeepsStartAndTint() {
        var s = ETSongIdentifying()
        s.begin(now: 1, tint: red)
        s.begin(now: 4, tint: blue)
        XCTAssertEqual(s.phase, .identifying(since: 1))
        XCTAssertEqual(s.startedAt, 1)
        XCTAssertEqual(s.tint, red)
    }

    func testRevealWhenIdleDoesNothing() {
        var s = ETSongIdentifying()
        s.reveal(now: 1)
        XCTAssertEqual(s.phase, .idle)
        XCTAssertEqual(s.weight(now: 1), 0)
    }

    func testBeginDuringRevealingRestartsIdentifying() {
        var s = ETSongIdentifying()
        s.begin(now: 0, tint: red)
        s.reveal(now: 2)
        s.begin(now: 2.2, tint: blue)
        XCTAssertEqual(s.phase, .identifying(since: 2.2))
        XCTAssertEqual(s.startedAt, 2.2)
        XCTAssertEqual(s.tint, blue)
        XCTAssertEqual(s.weight(now: 2.3), 1)
    }

    func testColorFadesFromTintToFallback() {
        var s = ETSongIdentifying()
        s.begin(now: 0, tint: red)
        XCTAssertEqual(s.color(now: 0, fallback: blue), red)
        XCTAssertEqual(s.color(now: ETSongIdentifying.tintFade, fallback: blue), blue)
        XCTAssertEqual(s.color(now: 100, fallback: blue), blue)
        let mid = s.color(now: ETSongIdentifying.tintFade / 2, fallback: blue)
        // 真ん中で 2 色の平均（smoothstep(0.5) = 0.5）
        XCTAssertEqual(Double((mid.rgb >> 16) & 0xFF), (255.0 + 3.0) / 2, accuracy: 1)
        // 色が無いときは最初から fallback
        var plain = ETSongIdentifying()
        plain.begin(now: 0, tint: nil)
        XCTAssertEqual(plain.color(now: 0, fallback: blue), blue)
    }
}
