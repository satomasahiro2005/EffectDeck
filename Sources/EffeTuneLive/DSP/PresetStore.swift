//  PresetStore.swift
//  名前を付けた鎖の保管。
//
//  中身は EffeTune のユーザープリセットと同じショート形式の配列なので、
//  ここから書き出したものは web 版へそのまま持っていける。

import Foundation

@MainActor
final class PresetStore: ObservableObject {

    static let shared = PresetStore()

    private static let key = "presets"

    @Published private(set) var names: [String] = []

    private init() { reload() }

    private func reload() {
        names = (dict().keys.sorted())
    }

    private func dict() -> [String: Any] {
        UserDefaults.standard.dictionary(forKey: Self.key) ?? [:]
    }

    func save(_ name: String, chain: [EffeTuneDSP.Node]) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !chain.isEmpty else { return }
        var d = dict()
        d[trimmed] = PipelineStore.shortForm(chain)
        UserDefaults.standard.set(d, forKey: Self.key)
        reload()
    }

    func load(_ name: String) -> [PipelineStore.Loaded] {
        guard let raw = dict()[name] else { return [] }
        return PipelineStore.parse(raw, catalog: ETCatalog)
    }

    func remove(_ name: String) {
        var d = dict()
        d.removeValue(forKey: name)
        UserDefaults.standard.set(d, forKey: Self.key)
        reload()
    }

    func importFrom(_ text: String) -> [PipelineStore.Loaded] {
        ETShareLink.parse(text, catalog: ETCatalog)
    }
}
