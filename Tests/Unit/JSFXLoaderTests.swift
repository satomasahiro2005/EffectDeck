//  JSFXLoaderTests.swift
//  読み込みのスレッドと、列挙つまみの選択（Sources/EffeTuneLive/Audio/ETJSFXLoader.swift）。
//
//  **括弧の無い長い式は、コンパイラの再帰で C のスタックを食う。**
//  EEL2 は演算子 1 つにつき 1 段再帰するので、`x = 0+1+1+…` を 2000 個並べると
//  512 KB のスレッド（協調プール・macOS/iOS の副スレッド）で溢れてアプリごと落ちる。
//  sourceWithinBudgets は括弧しか数えないので素通しになる。
//  ここは ETJSFXLoader.run を通せば落ちずに建つことを見る。

import XCTest

final class JSFXLoaderTests: XCTestCase {

    /// 5000 個（10 KB）。512 KB のスレッドなら必ず溢れる長さ。
    func testFlatOperatorChainBuildsOnLoaderThread() async throws {
        let count = 5000
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flat-\(UUID().uuidString).jsfx")
        let source = "desc:Flat\n@init\nx = 0" + String(repeating: "+1", count: count)
            + ";\n@sample\nspl0 = spl0;\n"
        try source.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let path = url.path
        let result = await ETJSFXLoader.run { () -> String? in
            var message = [CChar](repeating: 0, count: 1024)
            let raw = path.withCString {
                ETJSFX_Create($0, JSFX.sampleRate, JSFX.maxFrames, &message, message.count)
            }
            guard let raw else { return String(cString: message) }
            ETJSFX_Destroy(raw)
            return nil
        }
        XCTAssertNil(result, "flat chain failed to load: \(result ?? "")")
    }

    /// 結果は呼んだ側へ返る（continuation を 1 度だけ resume する）。
    func testRunReturnsValue() async {
        let value = await ETJSFXLoader.run { 6 * 7 }
        XCTAssertEqual(value, 42)
    }

    /// Int(Double) に渡る前に寄せる。どれも落ちずに tag の範囲へ入る。
    func testEnumIndexClampsNonFiniteAndOutOfRange() {
        XCTAssertEqual(ETJSFXLoader.enumIndex(.nan, count: 4), 0)
        XCTAssertEqual(ETJSFXLoader.enumIndex(.infinity, count: 4), 3)
        XCTAssertEqual(ETJSFXLoader.enumIndex(-.infinity, count: 4), 0)
        XCTAssertEqual(ETJSFXLoader.enumIndex(1e30, count: 4), 3)
        XCTAssertEqual(ETJSFXLoader.enumIndex(-1e30, count: 4), 0)
        XCTAssertEqual(ETJSFXLoader.enumIndex(9.3e18, count: 4), 3)   // 2^63 を超える
        XCTAssertEqual(ETJSFXLoader.enumIndex(-2, count: 4), 0)
        XCTAssertEqual(ETJSFXLoader.enumIndex(7, count: 4), 3)
        XCTAssertEqual(ETJSFXLoader.enumIndex(.nan, count: 0), 0)
    }

    /// 普通の値は今までどおり（丸めて tag へ）。
    func testEnumIndexKeepsWellBehavedValues() {
        XCTAssertEqual(ETJSFXLoader.enumIndex(0, count: 4), 0)
        XCTAssertEqual(ETJSFXLoader.enumIndex(2, count: 4), 2)
        XCTAssertEqual(ETJSFXLoader.enumIndex(1.4, count: 4), 1)
        XCTAssertEqual(ETJSFXLoader.enumIndex(1.6, count: 4), 2)
        XCTAssertEqual(ETJSFXLoader.enumIndex(3, count: 4), 3)
    }
}
