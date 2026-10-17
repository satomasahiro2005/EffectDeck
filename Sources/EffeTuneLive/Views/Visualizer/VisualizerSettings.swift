//  VisualizerSettings.swift
//  Visualizer の設定の保存。画面の場面（scene）・Floating Meters の場面（縦横比つき）・自分で作った場面の一覧・
//  測る所を UserDefaults に置く。
//
//  **Preferences には入れない。**Preferences.shared は EffectCardView のすべてが観測している（:434）ので、
//  ここの値を入れると編集のたびにカードが全部組み直される。別の入れ物にして、観測するのは
//  Visualizer の画面と編集画面だけにする。
//  キーは CloudMirror にも書き出しにも入れない（`pref.*` と同じ）。
//
//  旧い保存（v1。パネルの on/off）: Floating Meters のものは読んで 1 回だけ場面へ移して消す
//  （ETVisualizerMigration）。画面のものは読まずに消す（新しい既定の Studio に替わる）。

import Combine
import Foundation

@MainActor
final class ETVisualizerSettings: ObservableObject {

    static let shared = ETVisualizerSettings()

    enum Key {
        /// ETVisualizerScene v2（画面の、いま使っている場面）。
        static let scene = "pref.visualizer.scene"
        /// ETFloatingMetersScene v2。
        static let floatingScene = "pref.visualizer.floatingScene"
        /// {"v":2,"scenes":[…]}。自分で作った場面。
        static let userScenes = "pref.visualizer.userScenes"
        static let source = "pref.visualizer.source"
        /// 読まずに消す。
        static let legacyInApp = "pref.visualizer.inApp"
        /// 1 回だけ移して消す。
        static let legacyFloating = "pref.visualizer.floating"
    }

    @Published var scene: ETVisualizerScene {
        didSet { defaults.set(scene.encoded(), forKey: Key.scene) }
    }
    @Published var floating: ETFloatingMetersScene {
        didSet { defaults.set(floating.encoded(), forKey: Key.floatingScene) }
    }
    /// 保存した順。見せるときは名前の順に並べ直す。
    @Published var userScenes: [ETVisualizerScene] {
        didSet { defaults.set(ETVisualizerScene.encodeList(userScenes), forKey: Key.userScenes) }
    }
    /// 測る所。画面と Floating Meters で 1 つを分け合う（ETVisualizerTap）。
    @Published var source: ETVisualizerSource {
        didSet { defaults.set(source.rawValue, forKey: Key.source) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        scene = Self.storedScene(defaults)
        floating = Self.storedFloating(defaults)
        userScenes = Self.storedUserScenes(defaults)
        source = Self.storedSource(defaults)
    }

    // MARK: 読む

    private static func storedScene(_ defaults: UserDefaults) -> ETVisualizerScene {
        defaults.removeObject(forKey: Key.legacyInApp)
        return ETVisualizerScene.decode(defaults.data(forKey: Key.scene))?.normalized() ?? ETVisualizerPresets.studio
    }

    private static func storedFloating(_ defaults: UserDefaults) -> ETFloatingMetersScene {
        if let stored = ETFloatingMetersScene.decode(defaults.data(forKey: Key.floatingScene)) { return stored }
        guard let legacy = defaults.data(forKey: Key.legacyFloating) else {
            return ETFloatingMetersScene(aspect: .strip, scene: ETVisualizerPresets.classic)
        }
        // 移したらすぐ新しい鍵に書いて、旧い鍵を消す（次からは読まない）。
        let migrated = ETVisualizerMigration.floating(from: ETVisualizerConfig.decode(legacy, surface: .floating))
        defaults.set(migrated.encoded(), forKey: Key.floatingScene)
        defaults.removeObject(forKey: Key.legacyFloating)
        return migrated
    }

    private static func storedUserScenes(_ defaults: UserDefaults) -> [ETVisualizerScene] {
        var names = Set<String>()
        return ETVisualizerScene.decodeList(defaults.data(forKey: Key.userScenes))
            .filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { $0.normalized() }
            .filter { names.insert($0.name).inserted }
    }

    private static func storedSource(_ defaults: UserDefaults) -> ETVisualizerSource {
        defaults.string(forKey: Key.source).flatMap(ETVisualizerSource.init(rawValue:)) ?? .output
    }

    // MARK: 書く

    /// 範囲を直してから書く。変わらないなら書かない。
    func set(_ scene: ETVisualizerScene) {
        let normalized = scene.normalized()
        if self.scene != normalized { self.scene = normalized }
    }

    /// 縦横比は Fit を持てない（Strip に直す）。
    func set(_ floating: ETFloatingMetersScene) {
        let normalized = floating.normalized()
        if self.floating != normalized { self.floating = normalized }
    }

    /// 同じ名前（前後の空白を除いた綴りが同じ）があれば置き換え、無ければ足す。空の名前は何もしない。
    func saveUserScene(_ scene: ETVisualizerScene, name: String) {
        var saved = scene
        saved.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !saved.name.isEmpty else { return }
        saved = saved.normalized()
        if let index = userScenes.firstIndex(where: { $0.name == saved.name }) {
            userScenes[index] = saved
        } else {
            userScenes.append(saved)
        }
    }

    func deleteUserScene(named name: String) {
        userScenes.removeAll { $0.name == name }
    }

    /// 付け替えられたら true。新しい名前が空か、もう使われているときは false。
    func renameUserScene(_ old: String, to new: String) -> Bool {
        let name = String(new.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        guard !name.isEmpty, !userScenes.contains(where: { $0.name == name }),
              let index = userScenes.firstIndex(where: { $0.name == old }) else { return false }
        userScenes[index].name = name
        return true
    }

    /// 全部消したあと（ETFactoryReset）。init と同じ読み方で読み直す。変わったものだけ代入する。
    func reload() {
        let stored = Self.storedScene(defaults)
        if scene != stored { scene = stored }
        let pip = Self.storedFloating(defaults)
        if floating != pip { floating = pip }
        let list = Self.storedUserScenes(defaults)
        if userScenes != list { userScenes = list }
        let measured = Self.storedSource(defaults)
        if source != measured { source = measured }
    }
}
