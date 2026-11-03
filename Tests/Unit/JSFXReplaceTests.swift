//  JSFXReplaceTests.swift
//  取り込み直したJSFXで前の版を置き換える規則（Sources/EffeTuneLive/Audio/JSFXReplace.swift）。
//  **ホストもエンジンも要らない。**同じ1本かの判定・付け替えの表（辿り方と輪の落とし方・
//  置き換えを戻したときの付け替え）・保存の形・置き場の見直し・つまみを持ち越すかを見る。
//  ファイルを動かす・段を建て直すのはETJSFXHost（importFile・commitReplacement・
//  rollBackReplacement）で、そちらは実機で見る。

import XCTest
import Foundation

final class JSFXReplaceTests: XCTestCase {

    private func identity(_ source: String) -> JSFXReplace.Identity? {
        JSFXReplace.Identity(source: source)
    }

    private func candidate(_ id: String, _ source: String?, bundled: Bool = false) -> JSFXReplace.Candidate {
        JSFXReplace.Candidate(id: id, identity: source.flatMap(identity), isBundled: bundled)
    }

    // MARK: - 頭の読み方

    func testMetadataReadsDescAndAuthorTrimmed() {
        let found = JSFXReplace.metadata("desc:  Tape Wobble  \nauthor:\tMasa \n@init\n")
        XCTAssertEqual(found.name, "Tape Wobble")
        XCTAssertEqual(found.author, "Masa")
    }

    /// BOMと見えない字は落とす（ETJSFXHost.looksLikeJSFXと同じ）。CRLFでも読める。
    func testMetadataSkipsBOMAndReadsCRLF() {
        let found = JSFXReplace.metadata("\u{FEFF}desc:Gain\r\nauthor:Masa\r\n@sample\r\n")
        XCTAssertEqual(found.name, "Gain")
        XCTAssertEqual(found.author, "Masa")
    }

    /// 同じ行が2つあれば後のほう。一覧の名前（ETJSFXHost.metadata）と同じ読み方。
    func testMetadataLaterLineWins() {
        XCTAssertEqual(JSFXReplace.metadata("desc:A\ndesc:B\n").name, "B")
    }

    /// 頭80行より後の`desc:`は読まない。
    func testMetadataReadsOnlyFirstEightyLines() {
        let source = String(repeating: "// x\n", count: 80) + "desc:Late\n"
        XCTAssertNil(JSFXReplace.metadata(source).name)
    }

    // MARK: - 同じ1本か

    func testIdentityNeedsDesc() {
        XCTAssertNil(identity("@init\nx = 1;\n"))
        XCTAssertNil(identity("desc:   \n@init\n"))
    }

    /// `author:`が無いのと空なのは同じ。
    func testMissingAndEmptyAuthorAreTheSame() {
        XCTAssertEqual(identity("desc:Gain\n@init\n"), identity("desc:Gain\nauthor:\n@init\n"))
        XCTAssertEqual(identity("desc:Gain\n")?.author, "")
    }

    /// 前後の空白だけ違うものは同じ。中身（コード）は比べない。
    func testIdentityIgnoresSurroundingSpaceAndCode() {
        let v1 = "desc:Gain\nauthor:Masa\nslider1:0<-12,12>dB\n@sample\nspl0 *= 1;\n"
        let v2 = "desc: Gain \nauthor:  Masa\t\nslider1:0<-24,24>dB\n@sample\nspl0 *= 2;\n"
        XCTAssertEqual(identity(v1), identity(v2))
    }

    /// 大文字小文字は区別する（消すほうへ倒さない）。
    func testIdentityIsCaseSensitive() {
        XCTAssertNotEqual(identity("desc:Gain\n"), identity("desc:gain\n"))
    }

    /// 一覧を作るときに読んだ頭から作っても、ソースから作ったのと同じ鍵（ETJSFXHost.Entry.identity）。
    func testIdentityFromMetadataMatchesSource() {
        let source = "desc: Gain \nauthor:Masa\n@init\n"
        XCTAssertEqual(JSFXReplace.Identity(metadata: JSFXReplace.metadata(source)), identity(source))
        XCTAssertNil(JSFXReplace.Identity(metadata: (name: nil, author: "Masa")))
        XCTAssertNil(JSFXReplace.Identity(metadata: (name: "  ", author: nil)))
        XCTAssertEqual(JSFXReplace.Identity(metadata: (name: "Gain", author: nil))?.author, "")
    }

    // MARK: - 置き換える相手

    func testSameDescAndAuthorIsReplaced() {
        let new = identity("desc:Gain\nauthor:Masa\n")
        let replaced = JSFXReplace.replaced(by: "jsfx:v2", identity: new, among: [
            candidate("jsfx:v1", "desc:Gain\nauthor:Masa\n@init\n"),
            candidate("jsfx:other", "desc:Delay\nauthor:Masa\n"),
        ])
        XCTAssertEqual(replaced, ["jsfx:v1"])
    }

    func testDifferentAuthorIsKept() {
        let new = identity("desc:Gain\nauthor:Masa\n")
        XCTAssertEqual(JSFXReplace.replaced(by: "jsfx:v2", identity: new, among: [
            candidate("jsfx:v1", "desc:Gain\nauthor:Someone\n"),
            candidate("jsfx:v0", "desc:Gain\n"),
        ]), [])
    }

    /// 両方とも作者が無ければ同じ1本。
    func testBothWithoutAuthorAreReplaced() {
        let new = identity("desc:Gain\n@init\n")
        XCTAssertEqual(JSFXReplace.replaced(by: "jsfx:v2", identity: new,
                                            among: [candidate("jsfx:v1", "desc:Gain\nauthor:\n")]),
                       ["jsfx:v1"])
    }

    /// 同梱の見本は、同じ名前と作者でも置き換えない。
    func testBundledSampleIsNeverReplaced() {
        let new = identity("desc:EffectDeck DSP Filter + Drive\nauthor:EffectDeck\n")
        XCTAssertEqual(JSFXReplace.replaced(by: "jsfx:mine", identity: new, among: [
            candidate("jsfx:debug:abc", "desc:EffectDeck DSP Filter + Drive\nauthor:EffectDeck\n",
                      bundled: true),
        ]), [])
    }

    /// 同じidは同じ中身（sha256）。入れ直しても自分は消さない。
    func testSameIDIsNotReplaced() {
        let source = "desc:Gain\nauthor:Masa\n"
        XCTAssertEqual(JSFXReplace.replaced(by: "jsfx:v1", identity: identity(source),
                                            among: [candidate("jsfx:v1", source)]), [])
    }

    /// 同じ中身を入れ直したときも、前から並んでいた別の版は片付ける。
    func testSameIDStillReplacesOlderDuplicates() {
        let v2 = "desc:Gain\nauthor:Masa\n@init\nx=2;\n"
        XCTAssertEqual(JSFXReplace.replaced(by: "jsfx:v2", identity: identity(v2), among: [
            candidate("jsfx:v1", "desc:Gain\nauthor:Masa\n@init\nx=1;\n"),
            candidate("jsfx:v2", v2),
        ]), ["jsfx:v1"])
    }

    /// desc:の無いものは相手にもならず、相手も探さない。
    func testNoDescReplacesNothing() {
        XCTAssertEqual(JSFXReplace.replaced(by: "jsfx:new", identity: identity("@init\n"),
                                            among: [candidate("jsfx:old", "@init\n")]), [])
        XCTAssertEqual(JSFXReplace.replaced(by: "jsfx:new", identity: identity("desc:Gain\n"),
                                            among: [candidate("jsfx:old", nil)]), [])
    }

    /// 前からv1とv2が並んでいれば、v3でまとめて置き換える。順は一覧のまま。
    func testAllOlderDuplicatesAreReplaced() {
        let new = identity("desc:Gain\n")
        XCTAssertEqual(JSFXReplace.replaced(by: "jsfx:v3", identity: new, among: [
            candidate("jsfx:v1", "desc:Gain\n"),
            candidate("jsfx:x", "desc:Other\n"),
            candidate("jsfx:v2", "desc:Gain\n"),
        ]), ["jsfx:v1", "jsfx:v2"])
    }

    // MARK: - 付け替えの表

    func testResolveFollowsAlias() {
        var aliases = JSFXReplace.Aliases()
        aliases.redirect(from: "jsfx:v1", to: "jsfx:v2")
        XCTAssertEqual(aliases.resolve("jsfx:v1"), "jsfx:v2")
        XCTAssertNil(aliases.resolve("jsfx:v2"), "生きた1本は付け替えを持たない")
        XCTAssertNil(aliases.resolve("jsfx:unknown"))
    }

    /// v1→v2→v3は、どちらの古いidからもv3へ。表は潰して持つ。
    func testRedirectChainsToLatest() {
        var aliases = JSFXReplace.Aliases()
        aliases.redirect(from: "jsfx:v1", to: "jsfx:v2")
        aliases.redirect(from: "jsfx:v2", to: "jsfx:v3")
        XCTAssertEqual(aliases.resolve("jsfx:v1"), "jsfx:v3")
        XCTAssertEqual(aliases.resolve("jsfx:v2"), "jsfx:v3")
        XCTAssertEqual(aliases.map, ["jsfx:v1": "jsfx:v3", "jsfx:v2": "jsfx:v3"])
    }

    /// 前の版を入れ直した（v1→v2のあとにv1でv2を置き換えた）。輪を作らない。
    func testReimportingOldVersionDoesNotLoop() {
        var aliases = JSFXReplace.Aliases()
        aliases.redirect(from: "jsfx:v1", to: "jsfx:v2")
        aliases.redirect(from: "jsfx:v2", to: "jsfx:v1")
        XCTAssertNil(aliases.resolve("jsfx:v1"), "v1はいま生きた1本")
        XCTAssertEqual(aliases.resolve("jsfx:v2"), "jsfx:v1")
        XCTAssertEqual(aliases.map, ["jsfx:v2": "jsfx:v1"])
    }

    /// 手で書かれた（先の版が書いた）辿りの長い表も、辿った先へ潰して読む。
    func testRawChainIsFlattened() {
        let aliases = JSFXReplace.Aliases(["a": "b", "b": "c", "c": "d"])
        XCTAssertEqual(aliases.map, ["a": "d", "b": "d", "c": "d"])
    }

    /// 輪になるものと、辿ると輪に入るもの・自分を指すもの・空の字は落とす。
    func testCyclesAreDropped() {
        let aliases = JSFXReplace.Aliases([
            "a": "b", "b": "a",          // 輪
            "c": "a",                    // 輪に入る
            "d": "d",                    // 自分
            "": "x", "y": "",            // 空の字
            "e": "f",                    // 残る
        ])
        XCTAssertEqual(aliases.map, ["e": "f"])
        XCTAssertNil(aliases.resolve("a"))
        XCTAssertNil(aliases.resolve("c"))
    }

    /// 同じもの・空の字への付け替えは何もしない。
    func testRedirectIgnoresSelfAndEmpty() {
        var aliases = JSFXReplace.Aliases()
        aliases.redirect(from: "jsfx:v1", to: "jsfx:v1")
        aliases.redirect(from: "", to: "jsfx:v1")
        aliases.redirect(from: "jsfx:v1", to: "")
        XCTAssertTrue(aliases.isEmpty)
    }

    // MARK: - 置き換えを戻す

    /// v2が建たなかった。戻したv1の鍵は外れ、v1は自分のidで引ける（付け替えなし）。
    func testRollBackDropsRestoredKeys() {
        var aliases = JSFXReplace.Aliases()
        aliases.redirect(from: "jsfx:v1", to: "jsfx:v2")
        aliases.redirect(from: "jsfx:x", to: "jsfx:y")
        aliases.rollBack(target: "jsfx:v2", restored: ["jsfx:v1"])
        XCTAssertNil(aliases.resolve("jsfx:v1"))
        XCTAssertEqual(aliases.map, ["jsfx:x": "jsfx:y"], "ほかの1本の付け替えは残る")
    }

    /// v0→v1を置き換え終えたあと、v2で置き換えて建たなかった。v0はv1へ戻る（v2へ残さない）。
    func testRollBackRepointsOlderAliasesToRestored() {
        var aliases = JSFXReplace.Aliases()
        aliases.redirect(from: "jsfx:v0", to: "jsfx:v1")
        aliases.redirect(from: "jsfx:v1", to: "jsfx:v2")
        XCTAssertEqual(aliases.resolve("jsfx:v0"), "jsfx:v2")
        aliases.rollBack(target: "jsfx:v2", restored: ["jsfx:v1"])
        XCTAssertEqual(aliases.map, ["jsfx:v0": "jsfx:v1"])
    }

    /// 2本戻したときは、ほかの付け替えはいちばん新しい版（先頭）へ。戻した2本は鍵から外れる。
    func testRollBackWithSeveralRestoredPrefersNewest() {
        var aliases = JSFXReplace.Aliases()
        aliases.redirect(from: "jsfx:v0", to: "jsfx:v1")
        aliases.redirect(from: "jsfx:v1", to: "jsfx:v3")
        aliases.redirect(from: "jsfx:v2", to: "jsfx:v3")
        aliases.rollBack(target: "jsfx:v3", restored: ["jsfx:v2", "jsfx:v1"])
        XCTAssertEqual(aliases.map, ["jsfx:v0": "jsfx:v2"])
    }

    /// 戻したものが無ければ何もしない（付け替えをv2に残す）。
    func testRollBackWithNothingRestoredKeepsAliases() {
        var aliases = JSFXReplace.Aliases()
        aliases.redirect(from: "jsfx:v1", to: "jsfx:v2")
        aliases.rollBack(target: "jsfx:v2", restored: [])
        XCTAssertEqual(aliases.map, ["jsfx:v1": "jsfx:v2"])
    }

    /// 戻したあとにもう一度直した版を入れれば、戻した版も建たなかった版もまとめて付け替わる。
    func testFixAfterRollBackRedirectsBoth() {
        var aliases = JSFXReplace.Aliases()
        aliases.redirect(from: "jsfx:v1", to: "jsfx:v2")
        aliases.rollBack(target: "jsfx:v2", restored: ["jsfx:v1"])
        aliases.redirect(from: "jsfx:v1", to: "jsfx:v3")
        aliases.redirect(from: "jsfx:v2", to: "jsfx:v3")
        XCTAssertEqual(aliases.map, ["jsfx:v1": "jsfx:v3", "jsfx:v2": "jsfx:v3"])
    }

    // MARK: - 置き場の見直し

    func testShelvedVersionWaitsForLiveTarget() {
        var aliases = JSFXReplace.Aliases()
        aliases.redirect(from: "jsfx:v1", to: "jsfx:v2")
        XCTAssertEqual(JSFXReplace.shelfFate(of: "jsfx:v1", aliases: aliases, live: ["jsfx:v2"]),
                       .waiting("jsfx:v2"))
    }

    /// 行き先を消したなら、待っていた前の版も要らない。
    func testShelvedVersionOfDeletedTargetIsDiscarded() {
        var aliases = JSFXReplace.Aliases()
        aliases.redirect(from: "jsfx:v1", to: "jsfx:v2")
        XCTAssertEqual(JSFXReplace.shelfFate(of: "jsfx:v1", aliases: aliases, live: ["jsfx:other"]),
                       .discard)
    }

    /// 同じ中身が一覧に居る（前の版を入れ直した）なら、置き場の写しは要らない。
    func testShelvedCopyOfLiveVersionIsDiscarded() {
        var aliases = JSFXReplace.Aliases()
        aliases.redirect(from: "jsfx:v1", to: "jsfx:v2")
        XCTAssertEqual(JSFXReplace.shelfFate(of: "jsfx:v1", aliases: aliases, live: ["jsfx:v1", "jsfx:v2"]),
                       .discard)
    }

    /// 付け替えの無いもの（表が読めなかった・戻す途中で落ちた）は消さずに一覧へ戻す。
    func testShelvedVersionWithoutAliasIsRestored() {
        XCTAssertEqual(JSFXReplace.shelfFate(of: "jsfx:v1", aliases: JSFXReplace.Aliases(), live: ["jsfx:v2"]),
                       .restore)
    }

    // MARK: - 保存の形

    /// 形は固定。鍵は並べて書く（同じ表なら同じ字）。
    func testEncodedFormat() throws {
        var aliases = JSFXReplace.Aliases()
        aliases.redirect(from: "jsfx:b", to: "jsfx:c")
        aliases.redirect(from: "jsfx:a", to: "jsfx:c")
        let text = String(decoding: aliases.encoded(), as: UTF8.self)
        XCTAssertEqual(text, #"{"aliases":{"jsfx:a":"jsfx:c","jsfx:b":"jsfx:c"},"version":1}"#)
    }

    func testRoundTrip() throws {
        var aliases = JSFXReplace.Aliases()
        aliases.redirect(from: "jsfx:v1", to: "jsfx:v2")
        aliases.redirect(from: "jsfx:v2", to: "jsfx:v3")
        aliases.redirect(from: "jsfx:x", to: "jsfx:y")
        let back = try XCTUnwrap(JSFXReplace.Aliases(data: aliases.encoded()))
        XCTAssertEqual(back, aliases)
        XCTAssertEqual(back.resolve("jsfx:v1"), "jsfx:v3")
    }

    func testEmptyRoundTrip() throws {
        let back = try XCTUnwrap(JSFXReplace.Aliases(data: JSFXReplace.Aliases().encoded()))
        XCTAssertTrue(back.isEmpty)
    }

    /// 読めない字はnil（呼び手は空の表にする）。
    func testGarbageDoesNotDecode() {
        XCTAssertNil(JSFXReplace.Aliases(data: Data("not json".utf8)))
        XCTAssertNil(JSFXReplace.Aliases(data: Data(#"{"version":1}"#.utf8)))
        XCTAssertNil(JSFXReplace.Aliases(data: Data(#"{"version":1,"aliases":{"a":1}}"#.utf8)))
    }

    /// 版の数は見ない。知らない鍵は無視する。読んだ表も輪を落として潰す。
    func testDecodeToleratesOtherVersionsAndCleansUp() throws {
        let data = Data(#"{"version":2,"note":"x","aliases":{"a":"b","b":"c","p":"q","q":"p"}}"#.utf8)
        let aliases = try XCTUnwrap(JSFXReplace.Aliases(data: data))
        XCTAssertEqual(aliases.map, ["a": "c", "b": "c"])
    }

    // MARK: - つまみの持ち越し

    private func slider(_ index: UInt32, _ minimum: Double, _ maximum: Double,
                        _ value: Double) -> JSFXReplace.Slider {
        JSFXReplace.Slider(index: index, minimum: minimum, maximum: maximum, value: value)
    }

    private func range(_ index: UInt32, _ minimum: Double, _ maximum: Double) -> JSFXReplace.SliderRange {
        JSFXReplace.SliderRange(index: index, minimum: minimum, maximum: maximum)
    }

    private func carried(_ previous: [JSFXReplace.Slider],
                         _ fresh: [JSFXReplace.SliderRange]) -> [String] {
        JSFXReplace.carriedSliderValues(from: previous, to: fresh).map { "\($0.index)=\($0.value)" }
    }

    func testSameLayoutCarriesValues() {
        XCTAssertEqual(carried([slider(0, -12, 12, -3), slider(1, 0, 1, 0.25)],
                               [range(0, -12, 12), range(1, 0, 1)]),
                       ["0=-3.0", "1=0.25"])
    }

    /// 並び順は問わない（番号で比べる）。
    func testOrderDoesNotMatter() {
        XCTAssertEqual(carried([slider(4, 0, 10, 7), slider(1, 0, 1, 1)],
                               [range(1, 0, 1), range(4, 0, 10)]),
                       ["1=1.0", "4=7.0"])
    }

    /// 数が違えば全部既定から。
    func testDifferentCountStartsFromDefaults() {
        XCTAssertEqual(carried([slider(0, -12, 12, -3)],
                               [range(0, -12, 12), range(1, 0, 1)]), [])
        XCTAssertEqual(carried([slider(0, -12, 12, -3), slider(1, 0, 1, 1)],
                               [range(0, -12, 12)]), [])
    }

    /// 範囲が1本でも違えば全部既定から。
    func testDifferentRangeStartsFromDefaults() {
        XCTAssertEqual(carried([slider(0, -12, 12, -3), slider(1, 0, 1, 1)],
                               [range(0, -24, 12), range(1, 0, 1)]), [])
        XCTAssertEqual(carried([slider(0, -12, 12, -3)], [range(0, -12, 6)]), [])
    }

    /// 数と範囲が同じでも番号がずれていれば既定から（別のつまみに入る）。
    func testShiftedIndexStartsFromDefaults() {
        XCTAssertEqual(carried([slider(0, 0, 1, 0.5)], [range(1, 0, 1)]), [])
    }

    /// NaNと無限は持ち越さない（残りは持ち越す）。
    func testNonFiniteValuesAreSkipped() {
        XCTAssertEqual(carried([slider(0, 0, 1, .nan), slider(1, 0, 1, .infinity), slider(2, 0, 1, 0.5)],
                               [range(0, 0, 1), range(1, 0, 1), range(2, 0, 1)]),
                       ["2=0.5"])
    }

    /// つまみの無いものどうしは、持ち越すものも無い。
    func testNoSliders() {
        XCTAssertEqual(carried([], []), [])
    }
}
