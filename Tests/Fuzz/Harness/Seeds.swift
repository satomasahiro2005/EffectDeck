//  Seeds.swift（Tests/Fuzz）
//  カタログから種を作る。**エフェクトごとに 1 本、既定の値で書いた鎖。**
//  手で書いた種（Tests/Fuzz/Corpus）だけでは、整数・選択肢・配列のパラメータを持つ型に
//  なかなか届かない。ここで全部の型を 1 度ずつ渡しておく。
//
//  run.sh が ET_FUZZ_SEEDS_OUT=<dir> を付けて 1 度だけ起動し、ここが書いて終わる
//  （libFuzzer の本体は回らない）。種は作業用の置き場に書き、リポジトリには入れない。

import Foundation

enum Seeds {
    /// `target` の種を `dir` へ書く。書いた数を返す。
    static func write(target: String, to dir: URL) throws -> Int {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var written = 0
        func put(_ text: String) throws {
            try Data(text.utf8).write(to: dir.appendingPathComponent(String(format: "gen-%04d", written)))
            written += 1
        }

        let each = ETCatalog.map { effect in
            PipelineStore.Loaded(spec: effect, values: effect.defaults, enabled: true,
                                 inputBus: 0, outputBus: 0, channelSpec: -1)
        }
        var mixed = Array(each.prefix(6))
        mixed.insert(PipelineStore.Loaded(spec: ETSection.spec, values: [], enabled: true, inputBus: 0,
                                          outputBus: 0, channelSpec: -1, sectionName: "Drive"), at: 0)
        mixed.append(PipelineStore.Loaded(spec: ETSection.spec, values: [], enabled: true, inputBus: 0,
                                          outputBus: 0, channelSpec: -1, isRootReset: true))
        mixed.append(PipelineStore.Loaded(
            spec: .external(type: "External:jsfx:" + String(repeating: "a", count: 64), name: "Chat Soft Clip",
                            category: "JSFX"),
            values: [], enabled: true, inputBus: 1, outputBus: 2, channelSpec: 0,
            externalID: "jsfx:" + String(repeating: "a", count: 64), externalInstanceID: "i1",
            externalState: Data([1, 2, 3])))

        func json(_ object: Any) -> String {
            String(decoding: Fuzz.canonical(object) ?? Data("[]".utf8), as: UTF8.self)
        }

        switch target {
        case "pipelineform":
            for item in each { try put(json(PipelineStore.shortForm([item]))) }
            try put(json(PipelineStore.shortForm(mixed)))
            try put(json(PipelineStore.longForm(mixed)))
            if let backup = ETBackup.data(chain: mixed,
                                          presets: ["Warm": PipelineStore.shortForm(Array(mixed.prefix(3)))],
                                          effectPresets: ["Volume": ["Quiet": ["vl": -6]]]) {
                try put(String(decoding: backup, as: UTF8.self))
            }
        case "chaintext":
            for item in each {
                try put("Here is a chain for you:\n\n```json\n\(json(PipelineStore.shortForm([item])))\n```\n")
            }
            try put(json(PipelineStore.longForm(mixed)))
        case "sharelink":
            for item in each {
                if let url = ETShareLink.deckURL(for: [item]) { try put(url.absoluteString) }
            }
            if let url = ETShareLink.url(for: mixed) { try put(url.absoluteString) }
            if let url = ETShareLink.deckURL(for: mixed) { try put(url.absoluteString) }
        case "fxdlink":
            let source = "desc:Seed Gain\nslider1:0<-24,24,0.1>Gain (dB)\n@sample\nspl0 *= 10^(slider1/20);\n"
            if let url = try? ETFXDLink.jsfxURL(source: source) { try put(url.absoluteString) }
            if let url = ETShareLink.deckURL(for: mixed) {
                try put(url.absoluteString.replacingOccurrences(of: "effectdeck.nemut.ai", with: "fxd.nemut.ai"))
            }
        default:
            break
        }
        return written
    }
}
