//  ETShareLink.swift
//  EffeTune の共有リンクの読み書き。
//
//  形は単純で、`?p=` に UTF-8 の JSON をそのまま base64 にしたもの。
//  圧縮も URL-safe への置換も入らない（js/utils/pipeline-state-codec.js）。
//  中身はショート形式の配列（js/ui/pipeline/clipboard-manager.js:114 が
//  Array であることを要求している）。
//
//  web 版は受け取り側で base64 の文字集合を /^[A-Za-z0-9+/=]+$/ で検査するので、
//  こちらも素の base64 で書く。

import Foundation
import os

enum ETShareLink {

    private static let log = Logger(subsystem: "ai.nemut.effetune", category: "share")

    /// web 版の置き場。ここに `?p=` を付けたものが共有リンクになる。
    static let base = "https://effetune.frieve.com/effetune.html"

    // MARK: - 書く

    static func url(for chain: [EffeTuneDSP.Node]) -> URL? {
        let short = PipelineStore.shortForm(chain)
        guard !short.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: short,
                                                     options: [.withoutEscapingSlashes]),
              var comps = URLComponents(string: base) else { return nil }
        comps.queryItems = [URLQueryItem(name: "p", value: data.base64EncodedString())]
        return comps.url
    }

    // MARK: - 読む

    /// 共有リンクでも、`p=` の中身そのものでも、JSON そのものでも受ける。
    /// 人がクリップボードから貼るときに、どれが来るか分からないため。
    static func parse(_ text: String, catalog: [ETEffect]) -> [PipelineStore.Loaded] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // 1. URL として読めるなら p を取る
        if let comps = URLComponents(string: trimmed),
           let p = comps.queryItems?.first(where: { $0.name == "p" })?.value,
           let loaded = fromBase64(p, catalog: catalog), !loaded.isEmpty {
            return loaded
        }

        // 2. base64 そのもの
        if let loaded = fromBase64(trimmed, catalog: catalog), !loaded.isEmpty {
            return loaded
        }

        // 3. JSON そのもの（ロング形式でもショート形式でも）
        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            return PipelineStore.parse(json, catalog: catalog)
        }

        return []
    }

    private static func fromBase64(_ s: String, catalog: [ETEffect]) -> [PipelineStore.Loaded]? {
        // 素の base64 以外の文字が混じっていたら諦める。web 版と同じ検査。
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        guard !s.isEmpty, s.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        guard let data = Data(base64Encoded: s),
              let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return PipelineStore.parse(json, catalog: catalog)
    }
}
