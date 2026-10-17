//  VisualizerSettingsTests.swift
//  Visualizer の設定の保存（VisualizerSettings）。UserDefaults(suiteName:) の使い捨てで確かめる。
//  Combine が要るので Mac のバンドルだけで走る（Linux の写しからは外す。Tests/Linux/make_package.py）。
//
//  壊れると: 旧い Floating Meters の設定が起動で消える・毎回移される、新しい場面が保存されない、
//  全部消したあとに前の場面が残る、自分で作った場面が名前の重なりで増える。

import XCTest

@MainActor
final class VisualizerSettingsTests: XCTestCase {

    private var suites: [String] = []

    private func makeDefaults() -> UserDefaults {
        let name = "VisualizerSettingsTests.\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    override func tearDown() {
        for name in suites { UserDefaults().removePersistentDomain(forName: name) }
        suites.removeAll()
        super.tearDown()
    }

    func testEmptyDefaultsGiveStudioAndClassic() {
        let defaults = makeDefaults()
        let settings = ETVisualizerSettings(defaults: defaults)
        XCTAssertEqual(settings.scene, ETVisualizerPresets.studio)
        XCTAssertEqual(settings.floating, ETFloatingMetersScene(aspect: .strip, scene: ETVisualizerPresets.classic))
        XCTAssertEqual(settings.userScenes, [])
        XCTAssertEqual(settings.source, .output)
    }

    func testLegacyFloatingIsMigratedOnceAndRemoved() {
        let defaults = makeDefaults()
        var legacy = ETVisualizerConfig.defaults(for: .floating)
        legacy.aspect = .wide
        legacy.style = .effetune
        defaults.set(legacy.encoded(), forKey: ETVisualizerSettings.Key.legacyFloating)
        defaults.set(ETVisualizerConfig.defaults(for: .inApp).encoded(), forKey: ETVisualizerSettings.Key.legacyInApp)

        let settings = ETVisualizerSettings(defaults: defaults)
        XCTAssertEqual(settings.floating.aspect, .wide)
        XCTAssertEqual(settings.floating, ETVisualizerMigration.floating(from: legacy).normalized())
        XCTAssertNil(defaults.data(forKey: ETVisualizerSettings.Key.legacyFloating))
        XCTAssertNil(defaults.data(forKey: ETVisualizerSettings.Key.legacyInApp))
        XCTAssertNotNil(defaults.data(forKey: ETVisualizerSettings.Key.floatingScene))
        // 画面は新しい既定。
        XCTAssertEqual(settings.scene, ETVisualizerPresets.studio)

        // 2 回目は新しい鍵から読む。
        let again = ETVisualizerSettings(defaults: defaults)
        XCTAssertEqual(again.floating, settings.floating)
    }

    func testChangesArePersisted() {
        let defaults = makeDefaults()
        let settings = ETVisualizerSettings(defaults: defaults)
        settings.set(ETVisualizerPresets.neon)
        settings.set(ETFloatingMetersScene(aspect: .tall, scene: ETVisualizerPresets.spectral))
        settings.source = .input
        let again = ETVisualizerSettings(defaults: defaults)
        XCTAssertEqual(again.scene, ETVisualizerPresets.neon)
        XCTAssertEqual(again.floating.aspect, .tall)
        XCTAssertEqual(again.floating.scene, ETVisualizerPresets.spectral)
        XCTAssertEqual(again.source, .input)
    }

    func testReloadAfterRemovingKeysGivesDefaults() {
        let defaults = makeDefaults()
        let settings = ETVisualizerSettings(defaults: defaults)
        settings.set(ETVisualizerPresets.neon)
        settings.set(ETFloatingMetersScene(aspect: .tall, scene: ETVisualizerPresets.spectral))
        settings.saveUserScene(ETVisualizerPresets.vintage, name: "Mine")
        for key in [ETVisualizerSettings.Key.scene, ETVisualizerSettings.Key.floatingScene,
                    ETVisualizerSettings.Key.userScenes] {
            defaults.removeObject(forKey: key)
        }
        settings.reload()
        XCTAssertEqual(settings.scene, ETVisualizerPresets.studio)
        XCTAssertEqual(settings.floating, ETFloatingMetersScene(aspect: .strip, scene: ETVisualizerPresets.classic))
        XCTAssertEqual(settings.userScenes, [])
    }

    func testUserScenesSaveReplaceRenameDelete() {
        let settings = ETVisualizerSettings(defaults: makeDefaults())
        settings.saveUserScene(ETVisualizerPresets.neon, name: "  Mine ")
        settings.saveUserScene(ETVisualizerPresets.vintage, name: "Other")
        XCTAssertEqual(settings.userScenes.map(\.name), ["Mine", "Other"])
        // 同じ名前は置き換え。
        settings.saveUserScene(ETVisualizerPresets.spectral, name: "Mine")
        XCTAssertEqual(settings.userScenes.map(\.name), ["Mine", "Other"])
        XCTAssertTrue(settings.userScenes[0].sameLook(as: ETVisualizerPresets.spectral))
        // 空の名前は何もしない。
        settings.saveUserScene(ETVisualizerPresets.spectral, name: "   ")
        XCTAssertEqual(settings.userScenes.count, 2)
        // 付け替え。
        XCTAssertFalse(settings.renameUserScene("Mine", to: "Other"))
        XCTAssertFalse(settings.renameUserScene("Mine", to: " "))
        XCTAssertFalse(settings.renameUserScene("Nope", to: "Fresh"))
        XCTAssertTrue(settings.renameUserScene("Mine", to: "Fresh"))
        XCTAssertEqual(settings.userScenes.map(\.name), ["Fresh", "Other"])
        settings.deleteUserScene(named: "Other")
        XCTAssertEqual(settings.userScenes.map(\.name), ["Fresh"])
    }

    func testStoredUserScenesDropDuplicateAndEmptyNames() {
        let defaults = makeDefaults()
        func scene(_ name: String) -> ETVisualizerScene {
            var s = ETVisualizerPresets.studio
            s.name = name
            return s
        }
        // 書き込みの口は名前を直すので、保存の形を直に作る。
        let data = ETVisualizerScene.encodeList([scene("A"), scene("A"), scene("B")])
        var text = String(decoding: data, as: UTF8.self)
        text = text.replacingOccurrences(of: "\"name\":\"B\"", with: "\"name\":\"  \"")
        defaults.set(Data(text.utf8), forKey: ETVisualizerSettings.Key.userScenes)
        let settings = ETVisualizerSettings(defaults: defaults)
        XCTAssertEqual(settings.userScenes.map(\.name), ["A"])
    }
}
