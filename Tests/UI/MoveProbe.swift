//  MoveProbe.swift
//  長押しでの並べ替えを機械で確かめる。
//
//  報告: 「長押しでの並べ替えができない」「並べ替えられたときも bypass される」
//
//  **並びの正は applog の `publish ... types=`。** 画面の写しは遅れるので、
//  ここで読むカード名は「落ち着いてから」取る（1 手ごとに 5 秒待つ）。
//  screenshot と突き合わせて、この読み方が画面と一致することは確かめてある。
//  数えるのはカードの電源スイッチの label で、畳んでいても出る（DeleteProbe と同じ）。
//
//  壊れていたときの姿（直す前に測ったもの）:
//    鎖 V,T,C,R で「一番上を一番下へ」を 1 回 → 鎖は T,C,R,V、画面は C,R,V,T。
//    List が自分でセルを動かして残すので、同じ移動が 2 回かかっていた。

import XCTest

final class MoveProbe: XCTestCase {

    /// 名前が全部違う 4 本。並びが変わったかを label で読むため。
    private static let four =
        "VolumePlugin,ToneControlPlugin,CompressorPlugin,RSReverbPlugin"

    /// 鎖のカードではないスイッチの label。ツールバーのマスターがこれ。
    private static let notACard = ["Effect pipeline", "All effects"]

    /// 画面に出ている順（上から下）でカードの名前を返す。
    private func cardNames(_ app: XCUIApplication) -> [String] {
        var out: [(CGFloat, String)] = []
        for i in 0..<app.switches.count {
            let s = app.switches.element(boundBy: i)
            guard s.exists else { continue }
            let label = s.label
            if label.isEmpty || Self.notACard.contains(label) { continue }
            out.append((s.frame.minY, label))
        }
        return out.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private func card(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.switches.matching(NSPredicate(format: "label == %@", name)).firstMatch
    }

    /// 鎖のカードの電源スイッチを、画面の上から順に。
    /// Section が 2 本あると label がどちらも "Section" になるので、
    /// 名前では指せない。位置で指すときはこちら。
    private func cardSwitches(_ app: XCUIApplication) -> [XCUIElement] {
        var out: [(CGFloat, XCUIElement)] = []
        for i in 0..<app.switches.count {
            let s = app.switches.element(boundBy: i)
            guard s.exists else { continue }
            if s.label.isEmpty || Self.notACard.contains(s.label) { continue }
            out.append((s.frame.minY, s))
        }
        return out.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// 鎖のカードの ⋯（上から順）。label は "More"（SF Symbol ellipsis の既定の読み上げ）で、
    /// ツールバーにも同じものが居るので、鎖より上にあるものは落とす。
    private func rowMenus(_ app: XCUIApplication) -> [XCUIElement] {
        let all = app.buttons.matching(NSPredicate(format: "label == %@", "More"))
        var out: [(CGFloat, XCUIElement)] = []
        for i in 0..<all.count {
            let b = all.element(boundBy: i)
            guard b.exists, b.frame.minY > 150 else { continue }
            out.append((b.frame.minY, b))
        }
        return out.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// カードの本体を指す点。電源スイッチの右 120pt、同じ高さ。
    /// スイッチそのものを掴むと入切が変わる。右端は ⋯ なので寄りすぎない。
    private func grip(_ sw: XCUIElement) -> XCUICoordinate {
        sw.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: 120, dy: 0))
    }

    /// 絶対座標の点。落とす先は行の**端**を指したいので、要素を介さない口が要る。
    private func point(_ app: XCUIApplication, _ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }

    /// そのカードの行（List のセル）の矩形。
    /// **開いたカードは背が高い。** 行の頭を狙って落とすと「そのカードの前」に
    /// 置かれて並びが変わらないので、落とす先は行の下端から決める。
    private func rowRect(_ app: XCUIApplication, of sw: XCUIElement) -> CGRect? {
        let f = sw.frame
        let mid = CGPoint(x: f.midX, y: f.midY)
        for i in 0..<app.cells.count {
            let c = app.cells.element(boundBy: i)
            guard c.exists else { continue }
            if c.frame.contains(mid) { return c.frame }
        }
        return nil
    }

    /// 画面をそのまま撮って残す。**accessibility の写しを疑うときの原本。**
    /// 置き場はテストランナーの tmp（シミュレータのデータの下に出る）。
    private func snap(_ name: String) {
        let img = XCUIScreen.main.screenshot()
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("moveprobe-\(name).png")
        try? img.pngRepresentation.write(to: url)
        print("PROBE-SNAP \(url.path)")
    }

    /// 長押しして掴み、落とす。掴んだ点と落とした点を必ず出す。
    /// 効かなかったときに、掴めていないのか置き場所が悪いのかを後から分けるため。
    private func dragCard(_ app: XCUIApplication, from: String, to: String,
                          below: Bool, tag: String) {
        let src = card(app, from)
        let dst = card(app, to)
        XCTAssertTrue(src.waitForExistence(timeout: 10), "\(from) が出ない")
        XCTAssertTrue(dst.waitForExistence(timeout: 10), "\(to) が出ない")
        guard let dstRect = rowRect(app, of: dst) else {
            return XCTFail("落とす先の行が取れない")
        }
        let y = below ? dstRect.maxY - 6 : dstRect.minY + 6
        print("PROBE\(tag) grab=\(src.frame) dstRow=\(dstRect) dropY=\(y)")
        grip(src).press(forDuration: 1.2,
                        thenDragTo: point(app, dstRect.midX, y),
                        withVelocity: .slow, thenHoldForDuration: 1.0)
        Thread.sleep(forTimeInterval: 2.5)
    }

    // MARK: - 1. 長押しの並べ替え

    /// **同じ持ち上げを繰り返す。** 1 回だけだと当たり外れが読めない。
    /// 毎回「画面の一番上を一番下へ」なので、画面は 1 つずつ回るはず。
    /// ずれた回数を数えて、1 回でもずれたら落とす。
    private func repeatedDrags(_ app: XCUIApplication, rounds: Int, tag: String) {
        var seen = cardNames(app)
        var bad: [String] = []
        print("PROBE\(tag) round=0 screen=\(seen)")
        for r in 1...rounds {
            guard let head = seen.first, let tail = seen.last, head != tail else { break }
            dragCard(app, from: head, to: tail, below: true, tag: "\(tag)-r\(r)")
            Thread.sleep(forTimeInterval: 5)
            let now = cardNames(app)
            let want = Array(seen.dropFirst()) + [head]
            let ok = now == want
            print("PROBE\(tag) round=\(r) 掴んだ=\(head) 画面=\(now) 期待=\(want)"
                  + (ok ? "" : "  **ずれ**"))
            if !ok { bad.append("r\(r): \(now) ではなく \(want)") }
            seen = now
        }
        snap("repeat\(tag)")
        XCTAssertTrue(bad.isEmpty, "落とした所に行かない\n" + bad.joined(separator: "\n"))
    }

    /// 音は流さない。
    func testDragKeepsOrderQuiet() {
        let app = XCUIApplication()
        app.launchArguments = ["-ETSeed", Self.four, "-ETWidth", "0", "-ETCollapsed", "1"]
        app.launch()
        Thread.sleep(forTimeInterval: 8)
        repeatedDrags(app, rounds: 4, tag: "-QUIET")
    }

    /// 音を流す。実機はこちら。
    func testDragKeepsOrderPlaying() {
        let app = XCUIApplication()
        app.launchArguments = ["-ETSeed", Self.four, "-ETWidth", "0",
                               "-ETCollapsed", "1", "-ETMock", "1"]
        app.launch()
        Thread.sleep(forTimeInterval: 10)
        repeatedDrags(app, rounds: 4, tag: "-PLAYING")
    }

    /// **開いた状態**で掴む。足した直後の段は開いているので、普段の形はこちら。
    /// 開いた Compressor は 860pt あって下端が画面の外なので、**上へ**運ぶ。
    func testDragExpanded() {
        let app = XCUIApplication()
        app.launchArguments = ["-ETSeed", "VolumePlugin,CompressorPlugin", "-ETWidth", "0"]
        app.launch()
        Thread.sleep(forTimeInterval: 8)

        let before = cardNames(app)
        dragCard(app, from: "Compressor", to: "Volume", below: false, tag: "-EXPANDED")
        Thread.sleep(forTimeInterval: 6)
        let after = cardNames(app)
        print("PROBE-EXPANDED before=\(before) after=\(after)")
        XCTAssertEqual(after.first, "Compressor", "開いた状態だと落とした所へ行かない")
    }

    /// **対照。** ⋯ の Move Down だけで動かす。List の掴みを通らない道。
    /// 壊れていたときも、こちらだけは鎖と画面が一致していた。
    func testRepeatedMenuMoves() {
        let app = XCUIApplication()
        app.launchArguments = ["-ETSeed", Self.four, "-ETWidth", "0", "-ETCollapsed", "1"]
        app.launch()
        Thread.sleep(forTimeInterval: 8)

        var seen = cardNames(app)
        var bad: [String] = []
        print("PROBE-MENU round=0 screen=\(seen)")
        for r in 1...3 {
            guard let m = rowMenus(app).first else { return XCTFail("⋯ が無い") }
            let head = seen.first ?? "?"
            m.tap()
            Thread.sleep(forTimeInterval: 1.5)
            let down = app.buttons["Move Down"]
            guard down.waitForExistence(timeout: 5) else { return XCTFail("Move Down が無い") }
            down.tap()
            Thread.sleep(forTimeInterval: 5)
            let now = cardNames(app)
            // 先頭を 1 つ下げるので、1 番目と 2 番目が入れ替わるだけ。
            var want = seen
            if want.count >= 2 { want.swapAt(0, 1) }
            let ok = now == want
            print("PROBE-MENU round=\(r) 押した=\(head) 画面=\(now) 期待=\(want)"
                  + (ok ? "" : "  **ずれ**"))
            if !ok { bad.append("r\(r): \(now) ではなく \(want)") }
            seen = now
        }
        XCTAssertTrue(bad.isEmpty, "⋯ の Move Down がずれる\n" + bad.joined(separator: "\n"))
    }

    // MARK: - 2. 動かした段が黙って素通しになる

    /// 切ってある Section の下へ落とすと、その段が止まる。
    /// **これは上流と同じ振る舞い**（dsp-pipeline-descriptor.js:190-212 の sectionGate）で、
    /// 直す対象ではない。ここで確かめるのは「落とした所へ行くこと」と
    /// 「行が画面から消えないこと」の 2 つ。
    /// 止まったこと自体は applog の `publish ... active= gated=` に出る。
    func testDropIntoDisabledSection() {
        let app = XCUIApplication()
        app.launchArguments = ["-ETSeed",
                               "VolumePlugin,ToneControlPlugin,CompressorPlugin,SectionPlugin",
                               "-ETWidth", "0", "-ETCollapsed", "1", "-ETMock", "1"]
        app.launch()
        Thread.sleep(forTimeInterval: 10)

        print("PROBE-GATE start=\(cardNames(app))")
        // Section を切る。
        let sec = card(app, "Section")
        XCTAssertTrue(sec.waitForExistence(timeout: 10), "Section の行が無い")
        sec.tap()
        Thread.sleep(forTimeInterval: 3)

        guard let head = cardNames(app).first else { return XCTFail("カードが無い") }
        dragCard(app, from: head, to: "Section", below: true, tag: "-GATE")
        Thread.sleep(forTimeInterval: 6)
        let after = cardNames(app)
        print("PROBE-GATE 運んだ=\(head) 画面=\(after)")
        snap("gate")

        XCTAssertEqual(after.last, head, "Section の下へ落としたのにそこに居ない")
        XCTAssertEqual(after.count, 4, "行が画面から消えた: \(after)")
    }

    /// 畳んだ Section を動かしたときに、**掴んでいない段**が画面から消えないか。
    ///
    /// 鎖 [SecA(畳), TC, SecB(開), Comp, RSRev] → 画面 [SecA, SecB, Comp, RSRev]。
    /// SecA を SecB の 1 つ下へ落とすと鎖は [SecB, SecA, TC, Comp, RSRev] になり、
    /// 畳んだままの SecA の範囲が Comp と RSRev まで伸びる。掴んでいないので
    /// EffeTuneDSP.move の revealHidden には入らず、行だけが消えていた。
    /// 同時に 2 本の sectionGate が SecB の入切から SecA の入切へ移る。
    func testMovingCollapsedSectionKeepsRowsVisible() {
        let app = XCUIApplication()
        // 先頭の Section だけ畳んだ状態で始めたいが、-ETCollapsed は全部畳む。
        // 全部畳んだ状態で始めて、2 本目の Section だけ開く。
        app.launchArguments = ["-ETSeed",
                               "SectionPlugin,ToneControlPlugin,SectionPlugin,"
                               + "CompressorPlugin,RSReverbPlugin",
                               "-ETWidth", "0", "-ETCollapsed", "1"]
        app.launch()
        Thread.sleep(forTimeInterval: 8)

        // 2 本目の Section を開く（配下の Compressor と RS Reverb を出す）。
        let expand = app.buttons.matching(
            NSPredicate(format: "label == %@", "Expand section"))
        print("PROBE-SEC expand buttons=\(expand.count) start=\(cardNames(app))")
        guard expand.count >= 2 else { return XCTFail("Section が 2 本出ていない") }
        expand.element(boundBy: 1).tap()
        Thread.sleep(forTimeInterval: 3)

        let before = cardNames(app)
        print("PROBE-SEC before=\(before)")
        let sws = cardSwitches(app)
        guard sws.count >= 3, let secB = rowRect(app, of: sws[1]) else {
            return XCTFail("行が足りない: \(before)")
        }
        // **Section の掴み所は名前の欄を避ける。** SectionCardView は電源の右が
        // TextField なので、いつもの掴み所（スイッチの右 120pt）だと長押しが
        // 文字の選択に食われる。畳む矢印の少し左、Spacer の上を掴む。
        let chevrons = app.buttons.matching(
            NSPredicate(format: "label == %@ OR label == %@",
                        "Expand section", "Collapse section"))
        guard chevrons.count >= 1 else { return XCTFail("Section の矢印が無い") }
        let ch = chevrons.element(boundBy: 0).frame
        let from = point(app, ch.minX - 24, ch.midY)
        // 1 本目の Section（画面の先頭）を、2 本目の Section の 1 つ下へ。
        print("PROBE-SEC grab=(\(ch.minX - 24), \(ch.midY)) dstRow=\(secB)")
        from.press(forDuration: 1.2,
                   thenDragTo: point(app, secB.midX, secB.maxY - 6),
                   withVelocity: .slow, thenHoldForDuration: 1.0)
        Thread.sleep(forTimeInterval: 8)

        let after = cardNames(app)
        print("PROBE-SEC after=\(after)")
        snap("section-move")

        // 見えていたものが 1 つも消えていないこと。数ではなく中身で見る
        // （開いた結果、隠れていた段が増えるのは構わない）。
        let lost = before.filter { !after.contains($0) }
        XCTAssertTrue(lost.isEmpty, "行が画面から消えた \(lost): \(before) → \(after)")
    }
}
