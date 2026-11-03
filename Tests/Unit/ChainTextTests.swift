//  ChainTextTests.swift
//  貼られた鎖の下ごしらえ（ETChainText）。**実機もエンジンも要らない。**
//
//  見張るのは3つ:
//    - 字からJSONを取り出す道。返事ごとコピーしたもの（囲いの有無）、base64url、
//      末尾の=が無いもの、途中で折り返したもの
//    - 読む前に直す規則。範囲、選択肢、決まった値、バス、名前の綴り、知らない鍵、JSFXの名前
//    - **本物のデータには触らないこと。**同梱の鎖（ETSystemPresets）と出荷時プリセット
//      （ETEffectPresetList）を全部通して、値が1つも変わらないこと。落ちたら直すのは
//      このテストではなく、カタログの範囲（gen_catalog.py）かETChainTextの規則
//  CHAIN.mdの見本と、chain/v<版>/effects.json（gen_catalog.pyが書く語彙）も本物を読む。
//
//  ETChainText.swiftと、それが引くSectionSupport / DisplayParams / SystemPresets /
//  UpstreamVersion、CHAIN.mdとchain/はこのバンドルへ直接入れてある（project.yml）。
//  ETShareLinkは入っていないので、確かめるのはPipelineStore.parseの手前まで。
//  parseを通した往復はPipelineStoreTests（PipelineForm.swiftも入れてある）。

import XCTest

final class ChainTextTests: XCTestCase {

    // MARK: - 道具

    /// 字からJSONを取り出して直す。
    private func prepared(_ text: String, jsfx: ETChainText.JSFXResolver? = nil) throws
        -> (list: [[String: Any]], report: ETChainText.Report) {
        let json = try XCTUnwrap(ETChainText.json(from: text), "読めない: \(text)")
        let result = ETChainText.prepare(json, catalog: ETCatalog, jsfx: jsfx)
        let list = try XCTUnwrap(result.json as? [[String: Any]], "配列でない: \(text)")
        return (list, result.report)
    }

    private func number(_ any: Any?) -> Double? { (any as? NSNumber)?.doubleValue }

    private func names(_ list: [[String: Any]]) -> [String?] { list.map { $0["nm"] as? String } }

    // MARK: - 字から取り出す

    private let chain = #"[{"nm":"Hi Pass Filter","fr":30},{"nm":"Volume","vl":-3}]"#

    /// ChatGPTの返事を丸ごとコピーしたもの。囲いが残っている。
    func testWholeReplyWithFence() throws {
        let reply = """
        Here is a chain for warmer vocals.

        ```json
        \(chain)
        ```

        Copy it, then in EffectDeck open Presets and tap Import from clipboard.
        - Hi Pass Filter: removes rumble below 30 Hz.
        """
        let (list, report) = try prepared(reply)
        XCTAssertEqual(names(list), ["Hi Pass Filter", "Volume"])
        XCTAssertTrue(report.isEmpty, report.message)
    }

    /// 囲いが外れて文だけが残ったもの（「Copy」は囲いを落とすことがある）。
    /// 文中の`[1]`は鎖の形でないので飛ばす。
    func testWholeReplyWithoutFence() throws {
        let reply = "Here is your chain [1]:\n\(chain)\nWhy: the Volume at the end takes the gain back out."
        let (list, report) = try prepared(reply)
        XCTAssertEqual(names(list), ["Hi Pass Filter", "Volume"])
        XCTAssertTrue(report.isEmpty, report.message)
    }

    /// 同じ返事にJSFXの囲いが先に来ても、鎖を探しに行く。
    func testChainAfterAnotherCodeBlock() throws {
        let reply = """
        ```jsfx
        desc:Tape Wobble
        @sample
        buf[0] = spl0;
        ```
        Then the chain:
        \(chain)
        """
        let (list, _) = try prepared(reply)
        XCTAssertEqual(names(list), ["Hi Pass Filter", "Volume"])
    }

    /// 括弧だらけの長いJSFXやPythonの囲いが先にあっても、後ろの囲いの鎖を取る。
    /// 括弧を試す数には上限があるので、囲いを全部見ないとここまで届かない。
    func testChainInALaterFenceAfterManyBrackets() throws {
        let body = (0..<300).map { "buf[\($0)] = spl0;" }.joined(separator: "\n")
        let reply = """
        ```jsfx
        desc:Tape Wobble
        @sample
        \(body)
        ```
        ```python
        chain = [...]
        ```
        ```
        \(chain)
        ```
        """
        let (list, report) = try prepared(reply)
        XCTAssertEqual(names(list), ["Hi Pass Filter", "Volume"])
        XCTAssertTrue(report.isEmpty, report.message)
    }

    /// 「Copy code」で取ったもの。JSONそのもの（前からの道）。
    func testBareJSON() throws {
        let (list, report) = try prepared(chain)
        XCTAssertEqual(names(list), ["Hi Pass Filter", "Volume"])
        XCTAssertTrue(report.isEmpty, report.message)
    }

    func testCodeBlockIsTheFirstFence() {
        XCTAssertEqual(ETCodeBlock.first(in: "a\n```jsfx\ndesc:x\n```\nb\n```\nother\n```"), "desc:x\n")
        XCTAssertEqual(ETCodeBlock.first(in: "```\nopen"), "open")
        XCTAssertNil(ETCodeBlock.first(in: "no fence"))
    }

    func testCodeBlocksAreListedInOrder() {
        let blocks = ETCodeBlock.all(in: "a\n```jsfx\ndesc:x\n```\nb\n``` json \n[1]\n```\n```\nopen")
        XCTAssertEqual(blocks.map(\.info), ["jsfx", "json", ""])
        XCTAssertEqual(blocks.map(\.body), ["desc:x\n", "[1]\n", "open"])
        XCTAssertTrue(ETCodeBlock.all(in: "no fence").isEmpty)
    }

    func testGarbageIsNotRead() {
        for text in ["", "  \n", "hello world", "[1, 2, 3", "https://effectdeck.nemut.ai/"] {
            XCTAssertNil(ETChainText.json(from: text), text)
        }
    }

    // MARK: - リンクとbase64

    /// 素のbase64にすると`+` `/` `=`が全部出るように選んだ見本。
    private let linkSample = #"[{"nm":"Section","cm":"??>>~~"},{"nm":"Volume","vl":-3}]"#

    /// アプリが作る形のほかに、base64url、=の無いもの、折り返したもの、p=の中身だけ、
    /// 文の中のリンクも読む。ChatGPTにリンクを作らせると、どれで来るか分からない。
    func testLinkInEveryShapeDecodes() throws {
        let standard = Data(linkSample.utf8).base64EncodedString()
        XCTAssertTrue(standard.contains("+") && standard.contains("/") && standard.hasSuffix("="),
                      standard)
        let urlSafe = standard.replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let middle = urlSafe.index(urlSafe.startIndex, offsetBy: urlSafe.count / 2)
        let wrapped = String(urlSafe[..<middle]) + "\n" + String(urlSafe[middle...])
        let escaped = standard.replacingOccurrences(of: "+", with: "%2B")
        let base = "https://effectdeck.nemut.ai/?p="
        let texts = [
            base + escaped,                    // アプリが作る形（ETShareLink.deckURL）
            base + standard,                   // `+`のまま
            base + urlSafe,                    // base64url、=無し
            base + wrapped,                    // 途中で折り返したもの
            standard,                          // p=の中身だけ
            urlSafe,
            wrapped,
            "Tap this link: \(base)\(escaped).",  // 文の中のリンク
        ]
        for text in texts {
            let (list, report) = try prepared(text)
            XCTAssertEqual(names(list), ["Section", "Volume"], text)
            XCTAssertEqual(list.first?["cm"] as? String, "??>>~~", text)
            XCTAssertTrue(report.isEmpty, report.message)
        }
    }

    // MARK: - 直す

    func testVolumeIsLimitedToItsRange() throws {
        let (list, report) = try prepared(#"[{"nm":"Volume","vl":60},{"nm":"Volume","vl":-3}]"#)
        XCTAssertEqual(number(list[0]["vl"]), 24)
        XCTAssertEqual(number(list[1]["vl"]), -3)
        XCTAssertEqual(report.limited, ["Volume.vl"])
        XCTAssertEqual(report.notFound, [])
        XCTAssertEqual(report.ignored, [])
    }

    /// Tilt EQのPivotは自然対数で持つ。Hzで書かれても約1kHzに着く。
    /// **上限を超えた数は全部Hzと見る。**15Hzは対数にすると下の端より下なので、
    /// 下の端（約20Hz）へ寄せる。上の端（約20kHz）へ飛ばさない。
    func testTiltEQPivotInHzBecomesLog() throws {
        let (list, report) = try prepared(
            #"[{"nm":"Tilt EQ","f0":1000},{"nm":"Tilt EQ","f0":6.91},{"nm":"Tilt EQ","f0":15},{"nm":"Tilt EQ","f0":50000}]"#)
        XCTAssertEqual(try XCTUnwrap(number(list[0]["f0"])), log(1000), accuracy: 1e-9)
        XCTAssertEqual(number(list[1]["f0"]), 6.91)
        XCTAssertEqual(try XCTUnwrap(number(list[2]["f0"])), 3.0, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(number(list[3]["f0"])), 9.9, accuracy: 1e-6)
        XCTAssertEqual(report.limited, ["Tilt EQ.f0"])
    }

    /// Tilt EQのほかにも見た目と違う数で持つものがある。Modal Resonatorの周波数は自然対数、
    /// Digital Error EmulatorとG.726のBit Error Rateは10の指数。見た目の数で書かれても直す。
    func testOtherScaledValuesAreConverted() throws {
        let (list, report) = try prepared(
            #"[{"nm":"Modal Resonator","rs":[{"fr":440,"lp":8000,"hp":7}]},{"nm":"Digital Error Emulator","be":1e-6},{"nm":"G.726 Simulator","re":0.001},{"nm":"Digital Error Emulator","be":-8}]"#)
        let rows = try XCTUnwrap(list[0]["rs"] as? [[String: Any]])
        XCTAssertEqual(try XCTUnwrap(number(rows[0]["fr"])), log(440), accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(number(rows[0]["lp"])), log(8000), accuracy: 1e-9)
        XCTAssertEqual(number(rows[0]["hp"]), 7)
        XCTAssertEqual(try XCTUnwrap(number(list[1]["be"])), -6, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(number(list[2]["re"])), -3, accuracy: 1e-9)
        XCTAssertEqual(number(list[3]["be"]), -8)
        XCTAssertTrue(report.isEmpty, report.message)
    }

    func testNamesIgnoreCaseAndSpacesAndAcceptTypeNames() throws {
        let (list, report) = try prepared(
            #"[{"nm":"5band peq"},{"nm":"HI PASS FILTER"},{"nm":"VolumePlugin"},{"nm":"TiltEQ"},{"nm":"section","cm":"A"},{"nm":"Tape Warmth"}]"#)
        XCTAssertEqual(names(list), ["5Band PEQ", "Hi Pass Filter", "Volume", "Tilt EQ", "Section"])
        XCTAssertEqual(report.notFound, ["Tape Warmth"])
    }

    /// 大文字小文字と空白を無視しても、表示名と型名が別のエフェクトへ重ならないこと。
    /// 上流を進めると落ちうる。落ちたらETChainText.Namesの引き方を見直す。
    func testLooseNamesDoNotCollide() {
        var owner: [String: String] = [:]
        for e in ETCatalog {
            let bare = e.type.hasSuffix("Plugin") ? String(e.type.dropLast(6)) : e.type
            for key in Set([e.name, e.type, bare].map(ETChainText.fold)) {
                if let other = owner[key] {
                    XCTFail("\(key) が \(other) と \(e.name) の両方に当たる")
                }
                owner[key] = e.name
            }
        }
        XCTAssertNil(owner[ETChainText.fold(ETSection.name)], "Sectionと同じ綴りのエフェクトがある")
    }

    /// 知らない鍵は読まれないだけなので残し、控えに名前を出す。
    func testUnknownKeysAreListed() throws {
        let (list, report) = try prepared(#"[{"nm":"Saturation","xx":1,"dr":2}]"#)
        XCTAssertEqual(report.ignored, ["Saturation.xx"])
        XCTAssertEqual(number(list[0]["dr"]), 2)
        XCTAssertEqual(report.limited, [])
    }

    /// エンジンは5以上のバスが1本でもあると鎖ごと拒む。
    func testBusesAreClampedToFour() throws {
        let (list, report) = try prepared(#"[{"nm":"Volume","ib":7,"ob":-1},{"nm":"Volume","ib":4}]"#)
        XCTAssertEqual(list[0]["ib"] as? Int, 4)
        XCTAssertEqual(list[0]["ob"] as? Int, 0)
        XCTAssertEqual(number(list[1]["ib"]), 4)
        XCTAssertEqual(report.limited, ["Volume.ib", "Volume.ob"])
    }

    /// PipelineStore.parseはショートでもロングでも両方の綴り（en / enabled、ib / inputBusなど）を
    /// 読む。読まれる鍵を「Ignored」と言わない。バスはどの綴りでも寄せる。
    func testStageKeysInEitherSpellingAreRead() throws {
        let (list, report) = try prepared(#"[{"nm":"Volume","enabled":false,"inputBus":7,"channel":"L"}]"#)
        XCTAssertEqual(list[0]["enabled"] as? Bool, false)
        XCTAssertEqual(list[0]["inputBus"] as? Int, 4)
        XCTAssertEqual(report.ignored, [])
        XCTAssertEqual(report.limited, ["Volume.inputBus"])

        let long = #"{"pipeline":[{"name":"Volume","en":true,"ib":9,"ch":"R","parameters":{"vl":-3}}]}"#
        let json = try XCTUnwrap(ETChainText.json(from: long))
        let result = ETChainText.prepare(json, catalog: ETCatalog)
        let stage = try XCTUnwrap((result.json as? [String: Any])?["pipeline"] as? [[String: Any]]).first
        XCTAssertEqual(stage?["ib"] as? Int, 4)
        XCTAssertEqual(result.report.ignored, [])
        XCTAssertEqual(result.report.limited, ["Volume.ib"])
    }

    /// 上流が書くが音に効かない鍵は言わない。Brickwall Limiterの`pluginType`と、
    /// ロング形式の`parameters`に写されるバスとチャンネル（段のほうが読まれる）。
    func testUpstreamBookkeepingKeysAreQuiet() throws {
        let (_, report) = try prepared(
            #"[{"nm":"Brickwall Limiter","pluginType":"BrickwallLimiterPlugin","en":true}]"#)
        XCTAssertTrue(report.isEmpty, report.message)

        let long = #"{"pipeline":[{"name":"Volume","enabled":true,"inputBus":1,"channel":"L","parameters":{"vl":-3,"ib":1,"ch":"L","pluginType":"VolumePlugin"}}]}"#
        let result = ETChainText.prepare(try XCTUnwrap(ETChainText.json(from: long)), catalog: ETCatalog)
        XCTAssertTrue(result.report.isEmpty, result.report.message)
    }

    /// 2.16.0が全ての保存と共有の鎖に書く画面だけの鍵（`_uiCollapsed` `_uiLocked`）は言わない。
    /// ショート形式・ロング形式（`parameters`の中）・Sectionのどれでも。
    func testUiOnlyKeysFromUpstream216AreQuiet() throws {
        let (list, report) = try prepared(
            #"[{"nm":"Volume","vl":-3,"_uiCollapsed":true,"_uiLocked":true},{"nm":"Section","cm":"a","_uiCollapsed":true},{"nm":"Brickwall Limiter","_uiLocked":true}]"#)
        XCTAssertEqual(names(list), ["Volume", "Section", "Brickwall Limiter"])
        XCTAssertTrue(report.isEmpty, report.message)

        let long = #"{"pipeline":[{"name":"Volume","enabled":true,"parameters":{"vl":-3,"_uiCollapsed":true,"_uiLocked":true}},{"name":"Section","parameters":{"cm":"a","_uiCollapsed":true,"_uiLocked":true}}]}"#
        let result = ETChainText.prepare(try XCTUnwrap(ETChainText.json(from: long)), catalog: ETCatalog)
        XCTAssertTrue(result.report.isEmpty, result.report.message)
    }

    /// チャンネルは左右と全部の綴りを直し（"left" → "L"）、知らない綴りは外して言う。
    /// PipelineStore.parseは知らない綴りを黙ってStereoに落とす。
    func testChannelSpellingsAreCheckedAndFixed() throws {
        let (list, report) = try prepared(
            #"[{"nm":"Volume","ch":"left"},{"nm":"Volume","ch":"middle"},{"nm":"Volume","ch":"R"},{"nm":"Volume","ch":"34"}]"#)
        XCTAssertEqual(list[0]["ch"] as? String, "L")
        XCTAssertNil(list[1]["ch"])
        XCTAssertEqual(list[2]["ch"] as? String, "R")
        XCTAssertEqual(list[3]["ch"] as? String, "34")
        XCTAssertEqual(report.ignored, ["Volume.ch"])
    }

    /// 数で書かれた選択肢は、同じ数の選択肢を先に探す（上流も`String(params.br)`で綴りとして読む）。
    /// 無ければ添字と見る。
    func testNumbersMatchOptionsBeforeIndexes() throws {
        let (list, report) = try prepared(
            #"[{"nm":"Digital Error Emulator","md":8},{"nm":"Tape Artifacts","sp":7.5},{"nm":"Tube Simulator","zp":8},{"nm":"Digital Error Emulator","md":2}]"#)
        XCTAssertEqual(list[0]["md"] as? String, "8")
        XCTAssertEqual(list[1]["sp"] as? String, "7.5")
        XCTAssertEqual(list[2]["zp"] as? String, "8.0")
        XCTAssertEqual(number(list[3]["md"]), 2)
        XCTAssertTrue(report.isEmpty, report.message)
    }

    /// 前後に空白のある数の字は数にして渡す。ETParamCoding.numberはFloat(" -3")を読めず既定へ戻す。
    func testNumberStringsWithSpacesBecomeNumbers() throws {
        let (list, report) = try prepared(#"[{"nm":"Volume","vl":" -3"},{"nm":"Volume","vl":"-6"}]"#)
        XCTAssertEqual(list[0]["vl"] as? Double, -3)
        XCTAssertEqual(list[1]["vl"] as? String, "-6")
        XCTAssertTrue(report.isEmpty, report.message)
    }

    /// 選択肢に無い綴りと範囲の外の添字は外す（既定が残る）。
    func testOptionsOutsideTheListAreDropped() throws {
        let (list, report) = try prepared(#"[{"nm":"5Band PEQ","t0":"peak","t1":"ls","t2":9,"t3":3}]"#)
        XCTAssertNil(list[0]["t0"])
        XCTAssertEqual(list[0]["t1"] as? String, "ls")
        XCTAssertNil(list[0]["t2"])
        XCTAssertEqual(number(list[0]["t3"]), 3)
        XCTAssertEqual(report.ignored, ["5Band PEQ.t0", "5Band PEQ.t2"])
    }

    /// Oversamplingは範囲の中でも決まった値しか取らない（ETAllowedValues）。
    func testOversamplingTakesOnlyItsValues() throws {
        let (list, report) = try prepared(#"[{"nm":"Saturation","os":3},{"nm":"Saturation","os":4}]"#)
        XCTAssertNil(list[0]["os"])
        XCTAssertEqual(number(list[1]["os"]), 4)
        XCTAssertEqual(report.ignored, ["Saturation.os"])
    }

    func testObjectArrayRowsAreChecked() throws {
        let (list, report) = try prepared(#"[{"nm":"5Band Dynamic EQ","bs":[{"f":50000},{},{"zz":1}]}]"#)
        let rows = try XCTUnwrap(list[0]["bs"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(number(rows[0]["f"]), 20000)
        XCTAssertEqual(report.limited, ["5Band Dynamic EQ.bs.f"])
        XCTAssertEqual(report.ignored, ["5Band Dynamic EQ.bs.zz"])
    }

    /// EffectDeckどうしの共有リンクに乗る外部の段は、バス以外そのまま通す。
    func testExternalStagesPassThrough() throws {
        let (list, report) = try prepared(
            #"[{"nm":"Pro-Q","external":"au:aufx:abcd:efgh","externalInstance":"X","ob":6}]"#)
        XCTAssertEqual(list[0]["external"] as? String, "au:aufx:abcd:efgh")
        XCTAssertEqual(list[0]["externalInstance"] as? String, "X")
        XCTAssertEqual(list[0]["ob"] as? Int, 4)
        XCTAssertEqual(report.limited, ["Pro-Q.ob"])
    }

    // MARK: - JSFXを名前で引く

    /// `{"jsfx":"<desc:の名前>"}`は、PipelineStore.shortFormが外部の段に書くのと同じ形になる
    /// （nm・en・externalと、あればバス）。綴りが同じものが先で、次に大文字小文字を無視する。
    func testJSFXIsResolvedByDescName() throws {
        let resolver = ETChainText.jsfxResolver([(id: "jsfx:abc", name: "Tape Wobble"),
                                                (id: "jsfx:def", name: "tape wobble"),
                                                (id: "jsfx:ghi", name: "Air Band")])
        let (list, report) = try prepared(
            #"[{"jsfx":"Tape Wobble","ib":9},{"jsfx":"AIR BAND","en":false,"gain":3},{"jsfx":"Missing"},{"nm":"Volume"}]"#,
            jsfx: resolver)
        XCTAssertEqual(names(list), ["Tape Wobble", "Air Band", "Volume"])
        XCTAssertEqual(list[0]["external"] as? String, "jsfx:abc")
        XCTAssertEqual(list[0]["ib"] as? Int, 4)
        XCTAssertNil(list[0]["jsfx"])
        XCTAssertNil(list[0]["externalInstance"])
        XCTAssertEqual(list[1]["external"] as? String, "jsfx:ghi")
        XCTAssertEqual(list[1]["en"] as? Bool, false)
        XCTAssertNil(list[2]["external"])
        XCTAssertEqual(report.notFound, ["JSFX Missing"])
        XCTAssertEqual(report.ignored, ["Air Band.gain"])
        XCTAssertEqual(report.limited, ["Tape Wobble.ib"])
    }

    /// 引く先を渡さなければ置けない（ETShareLink.parseはそうしている）。
    func testJSFXWithoutResolverIsNotFound() throws {
        let (list, report) = try prepared(#"[{"jsfx":"Tape Wobble"},{"nm":"Volume"}]"#)
        XCTAssertEqual(names(list), ["Volume"])
        XCTAssertEqual(report.notFound, ["JSFX Tape Wobble"])
    }

    // MARK: - 控えの1行

    func testReportIsOneShortLine() {
        var report = ETChainText.Report()
        XCTAssertTrue(report.isEmpty)
        XCTAssertEqual(report.message, "")
        report.notFound = ["Tape Warmth"]
        report.ignored = ["Saturation.xx"]
        report.limited = ["Volume.vl"]
        XCTAssertEqual(report.message, "Not found: Tape Warmth. Ignored: Saturation.xx. Limited: Volume.vl.")
        report.ignored = ["a", "b", "c", "d", "e", "f"]
        XCTAssertEqual(report.message,
                       "Not found: Tape Warmth. Ignored: a, b, c, d and 2 more. Limited: Volume.vl.")
    }

    // MARK: - 本物のデータ

    /// 同梱の鎖は全部そのまま通る。**値は1つも変わらない。**
    /// 控えに残ってよいのはMatrixの経路（mx）だけ。あれはparamsに無く、実際に読まれずに
    /// 落ちている（gen_catalog.pyのCHAIN_UNSUPPORTEDの注記）。黙らせずに言うのが正しい。
    func testSystemPresetsPassUnchanged() throws {
        XCTAssertFalse(ETSystemPresets.isEmpty)
        var ignored: [String] = []
        for preset in ETSystemPresets {
            let json = try XCTUnwrap(ETChainText.json(from: preset.json), preset.id)
            let result = ETChainText.prepare(json, catalog: ETCatalog)
            let before = try XCTUnwrap(json as? [String: Any], preset.id)
            let after = try XCTUnwrap(result.json as? [String: Any], preset.id)
            XCTAssertTrue(NSDictionary(dictionary: after).isEqual(to: before), "\(preset.id) の値が変わった")
            XCTAssertEqual(result.report.notFound, [], preset.id)
            XCTAssertEqual(result.report.limited, [], preset.id)
            ignored += result.report.ignored.map { "\(preset.id): \($0)" }
        }
        XCTAssertEqual(ignored, ["4 Channel/Matrix: Matrix.mx", "4 Channel/Rear Reverb: Matrix.mx"])
    }

    /// 出荷時プリセット（エフェクト1個ぶん）も、段に包んで通すと何も変わらず、控えも空。
    /// 5Band PEQの端数の周波数やTube Simulatorの483.871のような値もそのまま残る
    /// （ETChainTextは整数へ丸めない）。
    func testEffectPresetsPassUnchanged() throws {
        XCTAssertFalse(ETEffectPresetList.isEmpty)
        for preset in ETEffectPresetList {
            var stage = preset.params
            XCTAssertFalse(stage.isEmpty, preset.id)
            stage["nm"] = preset.effect
            let result = ETChainText.prepare([stage], catalog: ETCatalog)
            let out = try XCTUnwrap(result.json as? [[String: Any]], preset.id)
            XCTAssertEqual(out.count, 1, preset.id)
            XCTAssertTrue(NSArray(array: out).isEqual(to: [stage]), "\(preset.id) の値が変わった")
            XCTAssertTrue(result.report.isEmpty, "\(preset.id): \(result.report.message)")
        }
    }

    /// CHAIN.mdの見本（最初の```jsonの囲い）はそのまま通る。見本の鍵を変えたらここで分かる。
    func testChainMDExampleImportsCleanly() throws {
        let file = try XCTUnwrap(TestResource.url("CHAIN", "md"))
        let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines)
        let open = try XCTUnwrap(lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "```json" },
                                 "CHAIN.mdに```jsonの見本が無い")
        let close = try XCTUnwrap(lines[(open + 1)...].firstIndex {
            $0.trimmingCharacters(in: .whitespaces) == "```"
        })
        let example = lines[(open + 1)..<close].joined(separator: "\n")
        let (list, report) = try prepared(example)
        XCTAssertTrue(report.isEmpty, report.message)
        XCTAssertGreaterThan(list.count, 1)
        for written in names(list) {
            let name = try XCTUnwrap(written)
            XCTAssertNotNil(ETCatalog.first { $0.name == name }, name)
        }
    }

    /// chain/v<版>/effects.json（gen_catalog.pyが書く語彙）がカタログと食い違わないこと。
    /// CHAIN.mdはChatGPTにこれを読ませるので、ずれると無い鍵や範囲の外の値を書かせる。
    func testVocabularyMatchesCatalog() throws {
        let file = try XCTUnwrap(
            TestResource.url("effects", "json", subdirectory: "chain/v\(ETUpstreamVersion)"),
            "chain/v\(ETUpstreamVersion)/effects.json が無い。Tools/gen_catalog.py を走らせる")
        let data = try Data(contentsOf: file)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["dsp"] as? String, ETUpstreamVersion)
        let effects = try XCTUnwrap(root["effects"] as? [[String: Any]])
        XCTAssertEqual(effects.count, ETCatalog.count)
        for e in effects {
            let name = try XCTUnwrap(e["nm"] as? String)
            let spec = try XCTUnwrap(ETCatalog.first { $0.name == name }, "\(name) がカタログに無い")
            XCTAssertEqual(e["type"] as? String, spec.type, name)
            let params = try XCTUnwrap(e["params"] as? [[String: Any]], name)
            // 保存形式に出さないもの（Tonal Balance EQ の mp。ETParam.runtimeOnly）は語彙にも載せない。
            let written = spec.params.filter { !$0.runtimeOnly }
            XCTAssertEqual(params.count, written.count, name)
            for (entry, p) in zip(params, written) {
                let label = "\(name).\(p.key)"
                XCTAssertEqual(entry["key"] as? String, jsonKey(p), label)
                XCTAssertEqual(entry["shape"] as? String, shape(p), label)
                switch p.kind {
                case .number(let lo, let hi, _, _, _):
                    XCTAssertEqual(entry["kind"] as? String, "number", label)
                    XCTAssertEqual((entry["min"] as? NSNumber)?.floatValue, lo, label)
                    XCTAssertEqual((entry["max"] as? NSNumber)?.floatValue, hi, label)
                case .enumeration(let options):
                    XCTAssertEqual(entry["kind"] as? String, "enum", label)
                    XCTAssertEqual(entry["options"] as? [String], options, label)
                case .toggle:
                    XCTAssertEqual(entry["kind"] as? String, "toggle", label)
                }
                let allowed = (entry["allowed"] as? [NSNumber])?.map(\.floatValue)
                XCTAssertEqual(allowed, ETAllowedValues.upstream(type: spec.type, key: p.key), label)
                // 語彙が印を付けたものだけを、取り込むときに見た目の数から直す（ETChainText.scaled）。
                let scaled = ETChainText.scale(type: spec.type, param: p)
                XCTAssertEqual(entry["scale"] as? String, scaled?.rawValue, label)
                if p.scale == .naturalExp { XCTAssertEqual(scaled, .lnHz, label) }
            }
        }
    }

    /// 保存形式で実際に書く鍵（ETParamCoding.encodeと同じ）。
    private func jsonKey(_ p: ETParam) -> String {
        if p.isObjectMember, let member = p.memberKey { return member }
        return p.flatArrayKey ?? p.key
    }

    private func shape(_ p: ETParam) -> String {
        if p.isObjectMember { return "object-array" }
        if p.flatArrayKey != nil { return "flat" }
        return p.isArray ? "indexed" : "scalar"
    }
}
