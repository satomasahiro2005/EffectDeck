//  PresetStore.swift
//  名前を付けた鎖の保管。
//
//  中身は EffeTune のユーザープリセットと同じショート形式の配列なので、
//  ここから書き出したものは web 版へそのまま持っていける。

import Foundation

@MainActor
final class PresetStore: ObservableObject {

    static let shared = PresetStore()

    /// **private ではない。** CloudMirror が iCloud 側を同じ鍵で読む
    /// （PipelineStore.lastKey と同じ理由）。
    static let key = "presets"

    @Published private(set) var names: [String] = []

    private init() { reload() }

    private func reload() {
        names = (dict().keys.sorted())
    }

    private func dict() -> [String: Any] {
        UserDefaults.standard.dictionary(forKey: Self.key) ?? [:]
    }

    /// 手元へ書いて一覧を引き直す。**iCloud へは写さない。**
    ///
    /// 写すのは触った名前だけ（CloudMirror.patch）。辞書をまるごと写すと、
    /// 手元の分が iCloud の分を置き換えて、別の端末に在るものが消える。
    private func write(_ d: [String: Any]) {
        UserDefaults.standard.set(d, forKey: Self.key)
        reload()
    }

    func save(_ name: String, chain: [EffeTuneDSP.Node]) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !chain.isEmpty else { return }
        var d = dict()
        let form = PipelineStore.shortForm(chain)
        d[trimmed] = form
        write(d)
        CloudMirror.patch(key: Self.key, path: [trimmed], value: form)
    }

    func load(_ name: String) -> [PipelineStore.Loaded] {
        guard let raw = dict()[name] else { return [] }
        return PipelineStore.parse(raw, catalog: ETCatalog)
    }

    func remove(_ name: String) {
        var d = dict()
        d.removeValue(forKey: name)
        write(d)
        CloudMirror.patch(key: Self.key, path: [name], value: nil)
    }

    func importFrom(_ text: String) -> [PipelineStore.Loaded] {
        ETShareLink.parse(text, catalog: ETCatalog)
    }

    // MARK: - ファイルとのやり取り（ETBackup）

    /// 書き出し用。入れ物の中身をそのまま返す。
    /// 上流の包み方（`{ plugins: [...] }`）は ETBackup が被せる。
    func exported() -> [String: Any] { dict() }

    /// 読み込み。**名前ごとに入れ替える。**ファイルに無い名前はそのまま残す。
    /// 返すのは入れた本数。
    @discardableResult
    func merge(_ incoming: [String: [[String: Any]]]) -> Int {
        var d = dict()
        var touched: [String: Any] = [:]
        for (name, entries) in incoming {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !entries.isEmpty else { continue }
            d[trimmed] = entries
            touched[trimmed] = entries
        }
        guard !touched.isEmpty else { return 0 }
        write(d)
        // 入れた名前だけ写す。まるごと写すと別の端末に在るものが消える。
        for (name, entries) in touched {
            CloudMirror.patch(key: Self.key, path: [name], value: entries)
        }
        return touched.count
    }
}
