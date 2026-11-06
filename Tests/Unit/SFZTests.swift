//  SFZTests.swift
//  SFZ・SoundFont の読み込み側が共に引く小さな型（DSP/SFZCommon）。
//  2.16.0 まで Swift に写していた上流の js/sfz（パーサ・バンクの入れ物・資産の並び・置き場）の照合は、
//  2.17.0 で外した。SFZ の読みは上流の JS そのものを JavaScriptCore で動かし、見本（Tests/Fixtures/SFZ/sfz-golden.json）の
//  全件は SFZScriptHostTests と Tools/sfzjs/bundle.test.mjs が通す。

import XCTest

final class SFZTests: XCTestCase {

    func testIDShape() {
        XCTAssertTrue(ETSFZ.isValidID("0123456789abcdef01234567"))
        XCTAssertFalse(ETSFZ.isValidID("0123456789ABCDEF01234567"))
        XCTAssertFalse(ETSFZ.isValidID("0123456789abcdef0123456"))
        XCTAssertFalse(ETSFZ.isValidID("0123456789abcdef012345678"))
        XCTAssertFalse(ETSFZ.isValidID("0123456789abcdef0123456g"))
        XCTAssertFalse(ETSFZ.isValidID(""))
    }

    /// 上限は上流の既定（256 MiB）とカーネルの最大（1 GiB）。既定は最大を越えない。
    func testLimits() {
        XCTAssertEqual(ETSFZ.defaultMaxBytes, 256 * 1024 * 1024)
        XCTAssertEqual(ETSFZ.maxSupportedBytes, 1024 * 1024 * 1024)
        XCTAssertLessThanOrEqual(ETSFZ.defaultMaxBytes, ETSFZ.maxSupportedBytes)
    }

    /// 誤りの code は JS の側が返す綴りのまま（ハイフンつき）。文言は ETSFZMessages が引く。
    func testErrorCodesKeepUpstreamSpelling() {
        XCTAssertEqual(ETSFZErrorCode.tooLarge.rawValue, "too-large")
        XCTAssertEqual(ETSFZErrorCode.noRegions.rawValue, "no-regions")
        XCTAssertEqual(ETSFZErrorCode.sampleRead.rawValue, "sample-read")
        XCTAssertEqual(ETSFZErrorCode.unsupportedRuntime.rawValue, "unsupported-runtime")
        for raw in ["prepare", "storage", "cancelled"] { XCTAssertEqual(ETSFZErrorCode(rawValue: raw)?.rawValue, raw) }
        XCTAssertEqual(ETSFZError.prepare("x"), ETSFZError(code: .prepare, message: "x"))
        XCTAssertNotEqual(ETSFZError.prepare("x"), ETSFZError.tooLarge("x"))
        XCTAssertEqual(ETSFZError.tooLarge("big").errorDescription, "big")
    }

    func testLibraryEntryIdentityIsTheKey() {
        let a = ETSFZLibraryEntry(id: "0123456789abcdef01234567", name: "Piano", regionCount: 3)
        XCTAssertEqual(a.id, "0123456789abcdef01234567")
        XCTAssertNil(a.size)
        XCTAssertNil(a.format)
        var b = a
        b.format = "sf2"
        XCTAssertNotEqual(a, b)
    }
}
