//  TestResource.swift
//  テストが読む資源（見本・fixture）の場所を引く。
//
//  Mac（Xcodeのバンドル）ではBundle(for:)から引く。project.ymlでbuildPhase: resourcesにした
//  ファイルはバンドルの根に、type: folderにしたフォルダはその名前の下に入る。
//  Linux（Tests/Linux/run.sh）にはバンドルが無いので、見つからなければこのファイルの場所
//  （#filePath）からリポジトリの根を辿り、次の順に探す:
//    1. 根/<subdirectory>/<name>.<ext>            CHAIN.md、chain/v<版>/effects.json
//    2. 根/site/<subdirectory>/<name>.<ext>       site/test-vector.json
//    3. 根/Tests/Fixtures/**/<subdirectory>/<name>.<ext>   Tests/Fixtures/<Area>/...
//  run.shは登録された資源だけをリポジトリと同じ相対パスへ写すので、登録を忘れた資源は
//  Linuxでも見つからない。
//
//    let file = try XCTUnwrap(TestResource.url("CHAIN", "md"))

import Foundation

enum TestResource {
    private final class Token {}

    static func url(_ name: String, _ ext: String, subdirectory: String? = nil) -> URL? {
        if let url = Bundle(for: Token.self).url(forResource: name, withExtension: ext,
                                                 subdirectory: subdirectory) {
            return url
        }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/Unit
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // リポジトリの根
        let tail = [subdirectory, "\(name).\(ext)"].compactMap { $0 }.joined(separator: "/")
        for base in [root, root.appendingPathComponent("site")] {
            let candidate = base.appendingPathComponent(tail)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        let fixtures = root.appendingPathComponent("Tests/Fixtures")
        guard let walker = fm.enumerator(atPath: fixtures.path) else { return nil }
        let matches = walker.compactMap { $0 as? String }
            .filter { $0 == tail || $0.hasSuffix("/" + tail) }
            .sorted()
        return matches.first.map { fixtures.appendingPathComponent($0) }
    }
}
