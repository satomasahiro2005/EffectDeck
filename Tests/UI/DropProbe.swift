//  DropProbe.swift
//  **ピッカーからつまんだエフェクトを、カードの外（余白）へ落として足せるか**を点ごとに測る。
//
//  余白に落とすと足せない、が何度も戻ってきた。1 か所ずつ手で試すと、どこが効いて
//  どこが効かないのかが毎回あいまいになるので、落とす点を名前で固定して全部回す。
//  **1 点が落ちても止めない。**点ごとに別のテストにして、xcodebuild の結果に
//  通った点と落ちた点が並ぶようにする（DROPPROBE の行も log に出す）。
//
//  点（鎖の右の列で測る。2 列は -ETLayout wide、1 列は撮影の既定の 393pt 幅）:
//    leftPad   カードの左の 14pt の余白（行の padding の中）
//    leftFar   カードの列の外の左（2 列では列の脇の余白。1 列では 393 の外＝ScrollView の外）
//    rightPad / rightFar  右も同じ
//    gap       2 枚目のカードの上の、カードとカードの間（10pt）
//    tail      画面の下の方の、最後のカードより下の空き
//    card      2 枚目のカードの頭（対照。ここで落ちるならドラッグそのものが効いていない）
//    empty*    鎖が空（-ETSeed none）の No effects の上・脇・下
//    mini*     2 列の左の一覧（2 列だけ）。miniTail は最後の行（Output Correction）より下の空き、
//              miniCorrection は Output Correction の行の名前の上。どちらも鎖の末尾へ足す
//
//  足せたかは、つまんだもの（Volume）の電源（switch、ラベルはエフェクト名）の数で見る。
//  2 列では左の一覧にも 1 つ出るので、増えたかどうかだけを見る。
//
//  起動のたびに鎖を引数から組み直すので、点どうしは影響し合わない。

import XCTest
import UIKit

final class DropProbe: XCTestCase {

    private let effect = ProcessInfo.processInfo.environment["DROPPROBE_EFFECT"] ?? "Volume"

    override func setUp() {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
    }

    private var shotDir: String? { ProcessInfo.processInfo.environment["DROPPROBE_SHOTS"] }

    private func snap(_ name: String) {
        guard let dir = shotDir else { return }
        let img = XCUIScreen.main.screenshot()
        let url = URL(fileURLWithPath: dir).appendingPathComponent("drop-\(name).png")
        try? img.pngRepresentation.write(to: url)
    }

    /// 読み上げの木を残す。点の位置を部品の枠から出しているので、外れたときに枠を見直すため。
    private func dumpTree(_ app: XCUIApplication, _ name: String) {
        guard let dir = shotDir else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("tree-\(name).txt")
        try? app.debugDescription.write(to: url, atomically: true, encoding: .utf8)
    }

    private func launch(wide: Bool, empty: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["-ETSeed", empty ? "none" : "VolumePlugin,ToneControlPlugin", "-ETDiag", "1"]
        if wide { args += ["-ETLayout", "wide"] }
        app.launchArguments = args
        app.launch()
        // 鎖が並ぶまで待つ。空の鎖は No effects、そうでなければ電源。
        if empty {
            _ = app.staticTexts["No effects"].waitForExistence(timeout: 30)
        } else {
            _ = app.switches[effect].waitForExistence(timeout: 30)
        }
        Thread.sleep(forTimeInterval: 2)
        return app
    }

    /// 足したものの数。電源（switch）はエフェクト名をラベルに持つ。
    private func count(_ app: XCUIApplication) -> Int {
        app.switches.matching(NSPredicate(format: "label == %@", effect)).count
    }

    /// 鎖の右の列のカードの電源（上から）。電源は 44pt 角。ツールバーの All effects（幅 80）と、
    /// 2 列の左の一覧（右の枠は x=260 から）の電源を除く。
    private func cardSwitches(_ app: XCUIApplication, wide: Bool) -> [XCUIElement] {
        let all = app.switches.allElementsBoundByIndex.filter {
            $0.exists && $0.frame.width == 44 && $0.frame.minY > 80
        }
        let right = all.filter { !wide || $0.frame.minX > 270 }
        guard let x0 = right.map(\.frame.minX).min() else { return [] }
        return right.filter { abs($0.frame.minX - x0) < 4 }.sorted { $0.frame.minY < $1.frame.minY }
    }

    /// カードの左右の端。電源の左 2pt がカードの左（EffectCardView.header の padding.leading）、
    /// ⋯ の右 4pt がカードの右。⋯ は電源と同じ高さに居るボタンのうち一番右のもの。
    private func cardEdges(_ app: XCUIApplication, _ sw: XCUIElement) -> (CGFloat, CGFloat) {
        let left = sw.frame.minX - 2
        let y = sw.frame.midY
        let row = app.buttons.allElementsBoundByIndex.filter {
            $0.exists && abs($0.frame.midY - y) < 12 && $0.frame.minX > sw.frame.maxX
                && $0.frame.width < 80
        }
        let right = (row.map(\.frame.maxX).max() ?? (left + 365)) + 4
        return (left, right)
    }

    /// ピッカーを開き、行を長押しで持ち上げて、点まで運んで放す。
    private func dragEffect(_ app: XCUIApplication, to point: CGPoint, tag: String) {
        let add = app.navigationBars.buttons["Add Effect"]
        XCTAssertTrue(add.waitForExistence(timeout: 20), "Add Effect が出ない")
        add.tap()
        // シートか popover が出きるのを待つ。出かけの行は isHittable が偽になり、検索へ回ってしまう。
        Thread.sleep(forTimeInterval: 1.5)
        let pred = NSPredicate(format: "label BEGINSWITH %@", effect + ",")
        var row = app.buttons.matching(pred).firstMatch
        if !(row.waitForExistence(timeout: 5) && row.isHittable) {
            dumpTree(app, "\(tag)-picker-nohit")
            // 1 列のシートは帯（カテゴリ）の頭が New で、Volume は Basics の帯にしか出ない。
            // 検索は使わない（検索中に運び出すと、検索を畳む動きがドラッグの手前に挟まる）。
            let basics = app.buttons["Basics"]
            if basics.exists && basics.isHittable {
                basics.tap()
                Thread.sleep(forTimeInterval: 1.0)
                row = app.buttons.matching(pred).firstMatch
            }
        }
        if !(row.waitForExistence(timeout: 3) && row.isHittable) {
            let search = app.searchFields.firstMatch
            if search.waitForExistence(timeout: 5) {
                search.tap()
                search.typeText(effect)
            }
            row = app.buttons.matching(pred).firstMatch
        }
        XCTAssertTrue(row.waitForExistence(timeout: 10), "ピッカーに \(effect) が出ない")
        Thread.sleep(forTimeInterval: 0.8)
        snap("\(tag)-picker")
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let from = row.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        let to = origin.withOffset(CGVector(dx: point.x, dy: point.y))
        // 持ち上げてから運ぶ。ピッカーはドラッグが始まると自分で閉じる（dismissAfterDragBegins）。
        // ゆっくり運び、着いてから少し留まって落とし先が決まるのを待つ。
        from.press(forDuration: 1.2, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 1.0)
        Thread.sleep(forTimeInterval: 2.0)
    }

    /// 点を 1 つ測る。名前の付いた点を、起動し直した鎖で 1 回だけ落とす。
    private func probe(wide: Bool, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let mode = wide ? "wide" : "phone"
        let empty = name.hasPrefix("empty")
        let app = launch(wide: wide, empty: empty)
        let window = app.windows.firstMatch.frame
        dumpTree(app, "\(mode)-\(name)")
        var point = CGPoint.zero
        var info = ""

        if name.hasPrefix("mini") {
            // 左の一覧の出力補正の行の電源。右の列にも同じ名前の電源があるので、左（x < 260）だけ。
            let oc = app.switches.matching(NSPredicate(format: "label == %@", "Output Correction"))
                .allElementsBoundByIndex.filter { $0.exists && $0.frame.minX < 260 }
            guard let sw = oc.first else {
                XCTFail("左の一覧に Output Correction の行が無い", file: file, line: line)
                return
            }
            let f = sw.frame
            switch name {
            case "miniTail": point = CGPoint(x: f.maxX + 60, y: window.maxY - 80)
            case "miniCorrection": point = CGPoint(x: f.maxX + 60, y: f.midY)
            default: XCTFail("知らない点 \(name)"); return
            }
            info = "miniCorrection=\(f)"
        } else if empty {
            let label = app.staticTexts["No effects"]
            XCTAssertTrue(label.exists, "No effects が出ない", file: file, line: line)
            let f = label.frame
            // 空の表示には列の端を言う部品が無いので、No effects の中央を列の中央とみなし、
            // 列の半分（2 列は 672 の半分、1 列は 393 の半分）から脇の余白の点を出す。
            let colHalf: CGFloat = wide ? 336 : 196.5
            switch name {
            case "emptyText": point = CGPoint(x: f.midX, y: f.midY)
            case "emptySide": point = CGPoint(x: f.midX - colHalf + 7, y: f.midY)
            case "emptyBelow": point = CGPoint(x: f.midX, y: window.maxY - 80)
            default: XCTFail("知らない点 \(name)"); return
            }
            info = "noEffects=\(f)"
        } else {
            let sws = cardSwitches(app, wide: wide)
            guard sws.count >= 2 else {
                XCTFail("カードの電源が 2 つ見つからない（\(sws.count)）", file: file, line: line)
                return
            }
            let (left, right) = cardEdges(app, sws[1])
            let mid = (left + right) / 2
            let head = sws[1].frame.midY
            let top2 = sws[1].frame.minY - 10   // 頭の padding.vertical 10
            switch name {
            case "leftPad": point = CGPoint(x: left - 7, y: head)
            case "leftFar": point = CGPoint(x: left - 30, y: head)
            case "rightPad": point = CGPoint(x: right + 7, y: head)
            case "rightFar": point = CGPoint(x: right + 30, y: head)
            case "gap": point = CGPoint(x: mid, y: top2 - 5)
            case "tail": point = CGPoint(x: mid, y: window.maxY - 80)
            case "card": point = CGPoint(x: mid, y: head)
            default: XCTFail("知らない点 \(name)"); return
            }
            info = "cardLeft=\(left) cardRight=\(right) sw1=\(sws[0].frame) sw2=\(sws[1].frame)"
        }

        let before = count(app)
        dragEffect(app, to: point, tag: "\(mode)-\(name)")
        let after = count(app)
        snap("\(mode)-\(name)-after")
        let pass = after > before
        print("DROPPROBE \(mode) \(name) \(pass ? "PASS" : "FAIL") point=(\(Int(point.x)),\(Int(point.y))) "
              + "before=\(before) after=\(after) window=\(window) \(info)")
        XCTAssertGreaterThan(after, before,
                             "\(mode) \(name): 落としても足されない point=\(point)", file: file, line: line)
        app.terminate()
    }

    // MARK: - 2 列（iPad の普段の形）

    func testWide1LeftPad()    { probe(wide: true, "leftPad") }
    func testWide2LeftFar()    { probe(wide: true, "leftFar") }
    func testWide3RightPad()   { probe(wide: true, "rightPad") }
    func testWide4RightFar()   { probe(wide: true, "rightFar") }
    func testWide5Gap()        { probe(wide: true, "gap") }
    func testWide6Tail()       { probe(wide: true, "tail") }
    func testWide7Card()       { probe(wide: true, "card") }
    func testWide8EmptyText()  { probe(wide: true, "emptyText") }
    func testWide9EmptySide()  { probe(wide: true, "emptySide") }
    func testWideAEmptyBelow() { probe(wide: true, "emptyBelow") }
    func testWideBMiniTail()   { probe(wide: true, "miniTail") }
    func testWideCMiniCorrection() { probe(wide: true, "miniCorrection") }

    // MARK: - 1 列（iPhone の幅。撮影の既定の 393pt）

    func testPhone1LeftPad()    { probe(wide: false, "leftPad") }
    func testPhone2LeftFar()    { probe(wide: false, "leftFar") }
    func testPhone3RightPad()   { probe(wide: false, "rightPad") }
    func testPhone4RightFar()   { probe(wide: false, "rightFar") }
    func testPhone5Gap()        { probe(wide: false, "gap") }
    func testPhone6Tail()       { probe(wide: false, "tail") }
    func testPhone7Card()       { probe(wide: false, "card") }
    func testPhone8EmptyText()  { probe(wide: false, "emptyText") }
    func testPhone9EmptySide()  { probe(wide: false, "emptySide") }
    func testPhoneAEmptyBelow() { probe(wide: false, "emptyBelow") }
}
