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
                                                     options: [.withoutEscapingSlashes,
                                                               .sortedKeys]),
              var comps = URLComponents(string: base) else { return nil }

        // **`+` は自分で %2B にする。**
        // URLComponents は `+` をクエリの正しい文字と見て素通しするが、
        // 受け側の web 版は URLSearchParams で読むので `+` が空白に復号され、
        // ui-manager.js:573 と clipboard-manager.js:120 の
        // /^[A-Za-z0-9+/=]+$/ が落ちて error.invalidUrl になる。
        // 出るのは Section 名に ASCII 以外を入れたとき（UTF-8 のバイト並びが
        // base64 で `+` を生む位置に来る）で、ASCII 名だけだと出ない。
        // こちら（ETShareLink.parse）は URLComponents 経由なので読めてしまい、
        // 送った側では気づけない。
        //
        // `/` はクエリでも `URLSearchParams` でもそのまま通るので触らない。
        // base64 に `&` `#` `?` は出ない。
        let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "%2B")
        comps.percentEncodedQuery = "p=" + encoded
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
