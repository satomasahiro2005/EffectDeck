//  AUCensusTests.swift
//  Audio Unit の数え上げを報告用の行にする所（ETAUCensus.swift）。**実機は要らない。**
//
//  約束は 3 つ。
//    1. 4 文字の識別子は字で、字にできない値は 16 進で出る（作り手の値は任意）。
//    2. Apple 以外の部品だけが名前つきで並び、どちらの数え上げで見えたかが判る。
//    3. 名前は上限で切れ、残りは数だけになる（報告を埋めない）。

import XCTest
import Foundation

final class AUCensusTests: XCTestCase {

    private let delay = ETAUCensus.Item(type: 0x6175_6678, subType: 0x6463_6C79,
                                        manufacturer: 0x6170_706C,
                                        name: "AUDelay", maker: "Apple")
    private let reverb = ETAUCensus.Item(type: 0x6175_6678, subType: 0x7276_6232,
                                         manufacturer: 0x4175_4B74,
                                         name: "Reverb", maker: "AudioKit")
    private let synth = ETAUCensus.Item(type: 0x6175_6D75, subType: 0x7379_6E31,
                                        manufacturer: 0x0000_0001,
                                        name: "Synth", maker: "")

    func testFourCCPrintsLettersAndFallsBackToHex() {
        XCTAssertEqual(ETAUCensus.fourCC(0x6175_6678), "aufx")
        XCTAssertEqual(ETAUCensus.fourCC(0x6170_706C), "appl")
        XCTAssertEqual(ETAUCensus.fourCC(0x0000_0001), "0x00000001")
    }

    func testSplitNameSeparatesMakerOnlyOnce() {
        XCTAssertEqual(ETAUCensus.splitName("Apple: AUDelay").maker, "Apple")
        XCTAssertEqual(ETAUCensus.splitName("Apple: AUDelay").name, "AUDelay")
        XCTAssertEqual(ETAUCensus.splitName("TB: Morphit: Pro").name, "Morphit: Pro")
        XCTAssertEqual(ETAUCensus.splitName("NoMaker").maker, "")
        XCTAssertEqual(ETAUCensus.splitName("NoMaker").name, "NoMaker")
    }

    func testSummaryCountsTypesAndMakersAcrossBothScans() {
        let line = ETAUCensus.summary(reason: "launch", listed: 1, manager: [delay],
                                      scanned: [delay, reverb], count: 2, added: 1)
        XCTAssertEqual(line, "au refresh=launch listed=1 mgr=1 find=2 count=2 added=1"
                       + " other=1 otherFx=1 types=aufx:2 makers=AuKt:1,appl:1")
    }

    func testOutsiderLineIsEmptyWhenOnlyAppleIsSeen() {
        XCTAssertEqual(ETAUCensus.outsiderLine(manager: [delay], scanned: [delay]), "")
    }

    func testOutsiderLineMarksWhichScanSawIt() {
        let line = ETAUCensus.outsiderLine(manager: [delay, synth], scanned: [delay, reverb])
        XCTAssertEqual(line, "au other: AudioKit: Reverb [aufx/rvb2/AuKt find-only],"
                       + " Synth [aumu/syn1/0x00000001 mgr-only]")
    }

    func testOutsiderLineStopsAtTheLimit() {
        let many = (0..<(ETAUCensus.nameLimit + 5)).map {
            ETAUCensus.Item(type: 0x6175_6678, subType: UInt32(0x6100_0000 + $0),
                            manufacturer: 0x4175_4B74, name: "FX\($0)", maker: "AudioKit")
        }
        let line = ETAUCensus.outsiderLine(manager: many, scanned: many)
        XCTAssertTrue(line.hasSuffix(" +5 more"))
        XCTAssertEqual(line.components(separatedBy: "AudioKit: ").count - 1, ETAUCensus.nameLimit)
    }
}
