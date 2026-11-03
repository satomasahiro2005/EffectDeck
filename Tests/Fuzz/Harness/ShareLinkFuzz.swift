//  ShareLinkFuzz.swift（Tests/Fuzz）
//  的 sharelink: 鎖のリンク・貼られた字を読む口（ETShareLink.parseChecked）と、
//  読んだものを上流のリンク・こちらのリンクへ書き戻す口。
//  的 fxdlink: 開かれた URL の振り分け（ETFXDLink.route）と JSFX 1 本のリンク（/j#…）。
//
//  約束（sharelink）:
//    - 直してから読んだ鎖なので、値は有限で数は範囲の中
//    - 書き戻せて、こちらのリンクで往復しても段の数が変わらない（FormOracle）
//  約束（fxdlink）:
//    - route が返す JSFX のソースは空でなく、64 KB 以下
//    - decode できた payload は、そのソースを encode して decode し直すと同じソースに戻る
//    - inflate は上限を超えたものを返さない
//    - base64url は往復で同じバイトに戻る

import Foundation

enum ShareLinkFuzz {
    static func run(_ data: UnsafeRawBufferPointer) {
        let text = Fuzz.text(data)
        if let json = ETChainText.json(from: text), Fuzz.hasNonFinite(json) { return }
        let checked = ETShareLink.parseChecked(text, catalog: ETCatalog,
                                               jsfx: ETChainText.jsfxResolver(Fuzz.jsfxLibrary))
        _ = checked.report.message
        FormOracle.checkRanges(checked.items, "sharelink")
        FormOracle.check(checked.items, "sharelink")
    }
}

enum FXDLinkFuzz {
    static func run(_ data: UnsafeRawBufferPointer) {
        let text = Fuzz.text(data)

        if let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            switch ETFXDLink.route(url) {
            case .jsfx(let source)?:
                Fuzz.oracle(!source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                            "route が空のソースを返した")
                Fuzz.oracle(source.utf8.count <= ETFXDLink.sourceLimit,
                            "route が上限を超えるソースを返した: \(source.utf8.count)")
            case .chain(let link)?:
                _ = ETShareLink.parse(link, catalog: ETCatalog)
            case .failed?, .ignored?, nil:
                break
            }
        }

        if let source = try? ETFXDLink.decode(text) {
            Fuzz.oracle(source.utf8.count <= ETFXDLink.sourceLimit, "decode が上限を超えた")
            guard let payload = try? ETFXDLink.encode(source) else {
                Fuzz.oracle(false, "decode できたソースを encode できない")
                return
            }
            Fuzz.oracle((try? ETFXDLink.decode(payload)) == source, "decode → encode → decode が戻らない")
        }

        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let payload = try? ETFXDLink.encode(text) {
            Fuzz.oracle((try? ETFXDLink.decode(payload)) == text, "encode → decode が戻らない")
        }

        let raw = Data(data)
        if let out = ETFXDLink.inflate(raw, limit: 4096) {
            Fuzz.oracle(out.count <= 4096, "inflate が上限を超えた: \(out.count)")
        }
        if !raw.isEmpty {
            Fuzz.oracle(ETFXDLink.data(base64url: ETFXDLink.base64url(raw)) == raw, "base64url が往復しない")
        }
    }
}
