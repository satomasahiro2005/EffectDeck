//  ParamTabsTests.swift
//  汎用の一覧をタブに分ける表（ETParamTabs.swift）。**実機は要らない。**
//
//  約束は 2 つ。
//    1. 表の key がカタログに全部ある。**カタログの全パラメータがどれか 1 枚に載っている**
//       （載っていないと、タブに分けた途端にそのツマミが画面から消える）。
//    2. 最初に開くタブと並びが上流の createUI の definitions のまま。

import XCTest
import Foundation

final class ParamTabsTests: XCTestCase {

    func testTypesAreTheThreeUpstreamTabbedEffects() {
        XCTAssertEqual(ETParamTabs.types,
                       ["AMRadioSimulatorPlugin", "TVAudioSimulatorPlugin", "VinylSimulatorPlugin"])
    }

    /// 表の key はカタログにあり、どのツマミも 1 度ずつ、ちょうど 1 枚に載る。
    func testEveryCatalogParameterAppearsExactlyOnce() throws {
        for type in ETParamTabs.types {
            let effect = try XCTUnwrap(ETCatalog.first { $0.type == type }, type)
            let tabs = try XCTUnwrap(ETParamTabs.tabs(for: type), type)
            let listed = tabs.flatMap(\.keys)
            XCTAssertEqual(Set(listed).count, listed.count, "\(type): key が重複している")
            XCTAssertEqual(Set(listed), Set(effect.params.map(\.key)), "\(type): カタログと合わない")
        }
    }

    func testTabTitlesAndDefaultTabMatchUpstream() {
        let expected: [String: [String]] = [
            "AMRadioSimulatorPlugin": ["Station", "Path", "Receiver", "Output"],
            "TVAudioSimulatorPlugin": ["Standard", "Programme", "Reception", "Video Buzz", "Output"],
            "VinylSimulatorPlugin": ["Cutting", "Record", "Stylus", "Output"],
        ]
        for (type, titles) in expected {
            XCTAssertEqual(ETParamTabs.tabs(for: type)?.map(\.title), titles, type)
        }
        XCTAssertNil(ETParamTabs.tabs(for: "SWRadioSimulatorPlugin"))
    }
}
