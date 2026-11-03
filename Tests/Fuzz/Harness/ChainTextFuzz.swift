//  ChainTextFuzz.swift（Tests/Fuzz）
//  的 chaintext: 貼られた字から鎖を探して直す（ETChainText.json(from:) → prepare）。
//
//  約束:
//    - extract（返事の中から探す段）は鎖の形のものだけを返す
//    - prepare の結果は JSON に書ける
//    - **prepare は冪等。**2 度目は何も外さず（notFound が空）、何も寄せず（limited が空）、
//      同じ JSON を返す（ignored は残る。知らない鍵は残したまま言うだけなので）
//    - 直した鎖を parse すると、値は有限で、数は範囲の中
//    - 読んだ鎖は書き戻せる（FormOracle）

import Foundation

enum ChainTextFuzz {
    static func run(_ data: UnsafeRawBufferPointer) {
        let text = Fuzz.text(data)
        // 返事の中から探す段（extract）は鎖の形のものだけを返す（辞書の空でない配列か、
        // pipeline に配列を持つ辞書）。文中の [1] や JSFX の buf[0] を鎖と取り違えない約束。
        if let found = ETChainText.extract(text) {
            let shaped = (found as? [Any]).map { !$0.isEmpty && $0.allSatisfy { $0 is [String: Any] } }
                ?? ((found as? [String: Any])?["pipeline"] is [Any])
            Fuzz.oracle(shaped, "extract が鎖の形でないものを返した: \(found)")
        }
        guard let json = ETChainText.json(from: text), !Fuzz.hasNonFinite(json) else { return }
        let resolver = ETChainText.jsfxResolver(Fuzz.jsfxLibrary)

        let first = ETChainText.prepare(json, catalog: ETCatalog, jsfx: resolver)
        _ = first.report.message
        guard let once = Fuzz.canonical(first.json) else {
            Fuzz.oracle(false, "prepare の結果が JSON に書けない")
            return
        }

        let second = ETChainText.prepare(first.json, catalog: ETCatalog, jsfx: resolver)
        Fuzz.oracle(second.report.notFound.isEmpty && second.report.limited.isEmpty,
                    "2 度目の prepare がまだ直す: \(second.report.message)")
        Fuzz.oracle(Fuzz.canonical(second.json) == once,
                    "prepare が冪等でない\n1: \(String(decoding: once, as: UTF8.self))")

        let loaded = PipelineStore.parse(first.json, catalog: ETCatalog)
        FormOracle.checkRanges(loaded, "chaintext")
        FormOracle.check(loaded, "chaintext")
    }
}
