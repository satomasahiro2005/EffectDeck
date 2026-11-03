//  DebugPresetsTests.swift
//  Debug ビルドだけに出る見本の鎖（DebugPresets.swift）が、1 段も落とさずに読めるか。
//
//  名前が Generated/EffectCatalog.swift の `name` と一字でも違うと、PipelineStore.parse が
//  「知らないエフェクト」で黙って落とす。上流の版を上げて名前が変わったときに、ここで気付く。

import XCTest

final class DebugPresetsTests: XCTestCase {

    private func entries(_ json: String) throws -> [[String: Any]] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
    }

    /// どの `nm` もカタログの表示名か Section。
    func testEveryNameIsInTheCatalog() throws {
        let names = Set(ETCatalog.map(\.name)).union([ETSection.name])
        XCTAssertFalse(ETDebugPresets.all.isEmpty)
        for preset in ETDebugPresets.all {
            for entry in try entries(preset.json) {
                let nm = try XCTUnwrap(entry["nm"] as? String, preset.name)
                XCTAssertTrue(names.contains(nm), "\(preset.name): カタログに無い \(nm)")
            }
        }
    }

    /// 共有リンクと同じ道（ETShareLink.parseChecked）で読み、段の数が変わらず、
    /// 直したこと・落としたことの控えも空。
    func testEveryPresetLoadsWithoutDropsOrFixes() throws {
        for preset in ETDebugPresets.all {
            let count = try entries(preset.json).count
            let checked = ETShareLink.parseChecked(preset.json, catalog: ETCatalog)
            XCTAssertEqual(checked.items.count, count, preset.name)
            XCTAssertTrue(checked.report.isEmpty, "\(preset.name): \(checked.report.message)")
        }
    }

    /// 一覧の名前はぶつからない（ピッカーの行の身元に使う）。
    func testPresetNamesAreUnique() {
        let names = ETDebugPresets.all.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
    }
}
