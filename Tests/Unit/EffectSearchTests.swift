//  EffectSearchTests.swift
//  ピッカーの検索の順位（DSP/EffectSearch.swift）。
//
//  見ているもの:
//    - "eq" で 15Band PEQ が先頭に近く、Group Delay EQ が PEQ・GEQ より下
//    - 名前に無い呼び名（"snail"・"peq"・"verb"・"high pass"）で見つかる
//    - 名前そのもの・頭からの当たりが、定番の順位より強い
//    - 空の探し方は名前順のまま
//    - 手で決めた表（定番・別名）の型が、全部カタログに居る

import XCTest

final class EffectSearchTests: XCTestCase {

    private func names(_ q: String) -> [String] {
        ETEffectSearch.search(ETCatalog, query: q).map(\.name)
    }

    private func index(_ name: String, in list: [String], file: StaticString = #filePath, line: UInt = #line) -> Int {
        guard let i = list.firstIndex(of: name) else {
            XCTFail("\(name) が結果に無い: \(list.prefix(12))", file: file, line: line)
            return Int.max
        }
        return i
    }

    // MARK: - eq

    func testEQPutsFifteenBandPEQInTopTwo() {
        let r = names("EQ")
        XCTAssertLessThan(index("15Band PEQ", in: r), 2)
    }

    func testEQPutsGroupDelayEQBelowPEQsAndGEQ() {
        let r = names("eq")
        let gd = index("Group Delay EQ", in: r)
        for n in ["15Band PEQ", "15Band GEQ", "5Band PEQ"] {
            XCTAssertLessThan(index(n, in: r), gd, n)
        }
    }

    func testEQBelongsToAcronymWordsNotJustSuffixes() {
        // PEQ・GEQ は語の頭でなくても「語の当たり」。名前のどこかに過ぎない当たりより上。
        let hit = ETEffectSearch.nameHit("15Band PEQ", "eq")
        XCTAssertEqual(hit, .word)
        // 余る頭が 2 字以上の偶然は入れない。小文字の語（"Peq"）も略語とは見ない。
        XCTAssertEqual(ETEffectSearch.nameHit("Foo ABCD", "cd"), .inside)
        XCTAssertEqual(ETEffectSearch.nameHit("Foo Peq", "eq"), .inside)
    }

    func testDigitToLetterStartsAWord() {
        XCTAssertEqual(ETEffectSearch.nameHit("15Band PEQ", "band"), .word)
        XCTAssertEqual(ETEffectSearch.nameHit("15Band PEQ", "band peq"), .word)
    }

    // MARK: - 別名

    func testSnailFindsChromaSpiral() {
        XCTAssertEqual(names("snail").first, "Chroma Spiral")
    }

    func testAliasesFindEffects() {
        XCTAssertEqual(names("high pass").first, "Hi Pass Filter")
        XCTAssertEqual(names("lpf").first, "Lo Pass Filter")
        XCTAssertTrue(names("verb").prefix(4).contains("Dattorro Plate Reverb"))
        XCTAssertEqual(names("peq").first, "15Band PEQ")
        XCTAssertEqual(names("graphic eq").first, "15Band GEQ")
    }

    func testVUFindsAnalogMeterOnly() {
        // VU の針があるのは Analog Meter。Level Meter はピークホールドの表示で VU ではない。
        XCTAssertEqual(names("vu").first, "Analog Meter")
        XCTAssertFalse(names("vu").contains("Level Meter"))
    }

    func testExactSynonymBeatsLooseNameHit() {
        // "pan" の同義語の持ち主は、"Panel" が語の頭で当たるエフェクトより上。
        let r = names("pan")
        XCTAssertEqual(r.first, "Stereo Balance")
        XCTAssertLessThan(index("Stereo Balance", in: r), index("Auto Pan", in: r))
    }

    func testAliasDoesNotMatchInsideAnAlias() {
        // 別名の途中の字では当てない（"ail" で Chroma Spiral を出さない）。
        XCTAssertFalse(names("ail").contains("Chroma Spiral"))
    }

    // MARK: - 当たり方と定番

    func testCompFindsCompressorFirst() {
        let r = names("comp")
        XCTAssertEqual(r.first, "Compressor")
        XCTAssertLessThan(index("Compressor", in: r), index("Multiband Compressor", in: r))
    }

    func testExactAndPrefixBeatCuratedRank() {
        // 名前そのもの・頭からは、定番でなくても定番の「語の当たり」より上。
        XCTAssertEqual(names("Group Delay EQ").first, "Group Delay EQ")
        let r = names("5band")
        XCTAssertEqual(Set(r.prefix(3)), ["5Band PEQ", "5Band FIR PEQ", "5Band Dynamic EQ"])
        XCTAssertEqual(r.first, "5Band PEQ", "頭からの当たりの中では定番が先")
    }

    func testCuratedOrderAppliesWithinATier() {
        let r = names("reverb")
        XCTAssertLessThan(index("Dattorro Plate Reverb", in: r), index("RS Reverb", in: r))
    }

    func testSurroundingSpaceIsIgnored() {
        XCTAssertEqual(names("  EQ "), names("eq"))
    }

    // MARK: - 空

    func testEmptyQueryKeepsNameOrder() {
        let r = names("")
        XCTAssertEqual(r.count, ETCatalog.count)
        let sorted = ETCatalog.map(\.name).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        XCTAssertEqual(r, sorted)
    }

    func testNonEffectsComeAfterEffectsInTheSameTier() {
        let effect = ETEffectSearch.key(hit: .prefix, type: "SomethingPlugin", name: "Zeta", query: "z")
        let other = ETEffectSearch.key(hit: .prefix, type: nil, name: "Alpha", query: "a")
        XCTAssertLessThan(effect, other)
        XCTAssertLessThan(ETEffectSearch.key(hit: .exact, type: nil, name: "B", query: "b"),
                          ETEffectSearch.key(hit: .prefix, type: "CompressorPlugin", name: "A", query: "b"))
    }

    // MARK: - 見出しごとの束

    func testGroupedOrdersBucketsAndKeepsRankWithinEach() {
        let ranked: [(ETEffectSearch.Bucket, String)] = [
            (.presets, "p1"), (.effects, "e1"), (.plugins, "a1"),
            (.effects, "e2"), (.presets, "p2"), (.plugins, "a2"),
        ]
        let g = ETEffectSearch.grouped(ranked)
        XCTAssertEqual(g.map(\.bucket), [.effects, .plugins, .presets])
        XCTAssertEqual(g.map(\.items), [["e1", "e2"], ["a1", "a2"], ["p1", "p2"]])
    }

    func testGroupedOmitsEmptyBuckets() {
        let g = ETEffectSearch.grouped([(.presets, 1), (.presets, 2)])
        XCTAssertEqual(g.map(\.bucket), [.presets])
        XCTAssertTrue(ETEffectSearch.grouped([(ETEffectSearch.Bucket, Int)]()).isEmpty)
    }

    func testBucketTitles() {
        XCTAssertEqual(ETEffectSearch.Bucket.allCases.map(\.title), ["Effects", "Plugins", "Presets"])
    }

    // MARK: - 表

    func testTablesOnlyNameEffectsInTheCatalog() {
        let types = Set(ETCatalog.map(\.type))
        for t in ETEffectSearch.curated { XCTAssertTrue(types.contains(t), "定番の型がカタログに無い: \(t)") }
        for t in ETEffectSearch.aliases.keys { XCTAssertTrue(types.contains(t), "別名の型がカタログに無い: \(t)") }
        XCTAssertEqual(Set(ETEffectSearch.curated).count, ETEffectSearch.curated.count, "定番に重複")
        XCTAssertEqual(ETEffectSearch.curated.first, "FifteenBandPEQPlugin")
        for (t, list) in ETEffectSearch.aliases {
            for a in list { XCTAssertEqual(a, a.lowercased(), "\(t): 別名は小文字で書く") }
        }
        // 名前の頭・語の頭で当たる別名は何もしない。表を読む人のノイズになるので書かない。
        for e in ETCatalog {
            for a in ETEffectSearch.aliases[e.type] ?? [] {
                let h = ETEffectSearch.nameHit(e.name, a)
                XCTAssertFalse(h.map { $0 <= .word } ?? false, "\(e.type): 別名 \(a) は名前で見つかる")
            }
        }
    }
}
