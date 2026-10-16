//  VisualizerSettings.swift
//  Visualizer の設定の保存。画面と Floating Meters の設定（ETVisualizerConfig）と、測る所を UserDefaults に置く。
//
//  **Preferences には入れない。**Preferences.shared は EffectCardView のすべてが観測している（:434）ので、
//  ここの値を入れると編集のたびにカードが全部組み直される。別の入れ物にして、観測するのは
//  Visualizer の画面と編集画面だけにする。
//  キーは CloudMirror にも書き出しにも入れない（`pref.*` と同じ）。

import Combine
import Foundation

@MainActor
final class ETVisualizerSettings: ObservableObject {

    static let shared = ETVisualizerSettings()

    enum Key {
        static let inApp = "pref.visualizer.inApp"
        static let floating = "pref.visualizer.floating"
        static let source = "pref.visualizer.source"
    }

    @Published var inApp: ETVisualizerConfig {
        didSet { defaults.set(inApp.encoded(), forKey: Key.inApp) }
    }
    @Published var floating: ETVisualizerConfig {
        didSet { defaults.set(floating.encoded(), forKey: Key.floating) }
    }
    /// 測る所。画面と Floating Meters で 1 つを分け合う（ETVisualizerTap）。
    @Published var source: ETVisualizerSource {
        didSet { defaults.set(source.rawValue, forKey: Key.source) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        inApp = ETVisualizerConfig.decode(defaults.data(forKey: Key.inApp), surface: .inApp)
        floating = ETVisualizerConfig.decode(defaults.data(forKey: Key.floating), surface: .floating)
        source = Self.storedSource(defaults)
    }

    private static func storedSource(_ defaults: UserDefaults) -> ETVisualizerSource {
        defaults.string(forKey: Key.source).flatMap(ETVisualizerSource.init(rawValue:)) ?? .output
    }

    func config(_ surface: ETVisualizerSurface) -> ETVisualizerConfig {
        surface == .inApp ? inApp : floating
    }

    /// 面の縦横比などの決まり（PiP は Fit を持てない）に直してから書く。
    func set(_ config: ETVisualizerConfig, for surface: ETVisualizerSurface) {
        let normalized = config.normalized(for: surface)
        switch surface {
        case .inApp: if inApp != normalized { inApp = normalized }
        case .floating: if floating != normalized { floating = normalized }
        }
    }

    /// 全部消したあと（ETFactoryReset）。init と同じ読み方で読み直す。変わったものだけ代入する。
    func reload() {
        let app = ETVisualizerConfig.decode(defaults.data(forKey: Key.inApp), surface: .inApp)
        if inApp != app { inApp = app }
        let pip = ETVisualizerConfig.decode(defaults.data(forKey: Key.floating), surface: .floating)
        if floating != pip { floating = pip }
        let measured = Self.storedSource(defaults)
        if source != measured { source = measured }
    }
}
