//  DeleteProbe.swift
//  スワイプ削除の壊れ方を機械で捕まえる。
//
//  報告: 「プリセット（Rear Reverb）を読んで順番に消していくとバグる。
//  変なところに divider が出てきて、下の要素が削除できなくなる」
//
//  **数え方に注意。** app.cells は画面に出ている行しか数えない
//  （List は CollectionView で、見えているぶんだけ作る）。
//  鎖が 5 本でも cells は 4 になる。最初の版はこれで嘘の再現を出した。
//  数えるのはカードの電源スイッチで、label にエフェクト名が入っている。
//  マスターだけは鎖のものではないので除く。label は昔 "Effect pipeline" で、
//  いまは "All effects"。どちらで出ても数に入らないよう両方を落とす。

import XCTest

final class DeleteProbe: XCTestCase {

    /// Rear Reverb と同じ並び。SystemPresets.swift の 5 本。
    private static let rearReverb =
        "MatrixPlugin,VolumePlugin,RSReverbPlugin,HiPassFilterPlugin,StereoBlendPlugin"

    /// 鎖のカードではないスイッチの label。ツールバーのマスターがこれ。
    private static let notACard = ["Effect pipeline", "All effects"]

    /// 画面に出ている名前ではなく、**鎖に残っているカードの名前**を取る。
    /// 電源スイッチはカードごとに 1 個で、畳んでいても出る。
    private func cardNames(_ app: XCUIApplication) -> [String] {
        var out: [String] = []
        for i in 0..<app.switches.count {
            let s = app.switches.element(boundBy: i)
            guard s.exists else { continue }
            let label = s.label
            if label.isEmpty || Self.notACard.contains(label) { continue }
            out.append(label)
        }
        return out
    }

    /// 鎖の先頭のカード（マスターではない最初のスイッチ）。
    private func firstCard(_ app: XCUIApplication) -> XCUIElement {
        let excluded = Self.notACard + [""]
        return app.switches.matching(
            NSPredicate(format: "NOT (label IN %@)", excluded)
        ).firstMatch
    }

    /// 名前でカードを探してスワイプし、Delete を押す。
    /// 見えていなければ先にスクロールして出す。
    @discardableResult
    private func swipeDelete(_ app: XCUIApplication, named name: String,
                             log: inout [String]) -> Bool {
        let sw = app.switches.matching(NSPredicate(format: "label == %@", name)).firstMatch
        guard sw.waitForExistence(timeout: 5) else {
            log.append("  \(name): スイッチが見つからない")
            return false
        }
        // 画面の外にあるなら寄せる。
        var tries = 0
        while !sw.isHittable && tries < 8 {
            app.collectionViews.firstMatch.swipeUp()
            Thread.sleep(forTimeInterval: 0.4)
            tries += 1
        }
        guard sw.isHittable else {
            log.append("  \(name): 画面に出せない")
            return false
        }
        // スイッチそのものではなく、その行を横に払う。
        sw.coordinate(withNormalizedOffset: CGVector(dx: 6, dy: 0.5))
            .press(forDuration: 0.05,
                   thenDragTo: sw.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        Thread.sleep(forTimeInterval: 0.8)

        let delete = app.buttons["Delete"]
        guard delete.waitForExistence(timeout: 3) else {
            log.append("  \(name): **Delete が出ない**")
            return false
        }
        delete.tap()
        // **落ち着くまで待つ。** 消した直後の accessibility の写しは
        // 古い行を含んでいることがあり、それを読むと嘘の再現が出る。
        Thread.sleep(forTimeInterval: 2.5)
        return true
    }

    /// 同じ名前が 2 つ以上出ていないか。出ていたら残骸のセルが居座っている。
    private func duplicates(_ names: [String]) -> [String] {
        var seen: [String: Int] = [:]
        for n in names { seen[n, default: 0] += 1 }
        return seen.filter { $0.value > 1 }.map(\.key).sorted()
    }

    /// 上から順に消す。**毎回その 1 本だけが消えるか**を見る。
    func testDeleteFromTop() {
        let app = XCUIApplication()
        app.launchArguments = ["-ETSeed", Self.rearReverb, "-ETWidth", "0"]
        app.launch()
        Thread.sleep(forTimeInterval: 6)

        var log: [String] = []
        var names = cardNames(app)
        log.append("start: \(names)")
        let started = names

        var rounds = 0
        while let head = names.first, rounds < 8 {
            rounds += 1
            let ok = swipeDelete(app, named: head, log: &log)
            let now = cardNames(app)
            let dup = duplicates(now)
            log.append("消した=\(head) ok=\(ok) 残り=\(now)"
                       + (dup.isEmpty ? "" : "  **同じ名前が 2 つ以上: \(dup)**"))
            if !ok { break }
            if now.contains(head) {
                log.append("  **消したはずのものが残っている**")
                break
            }
            names = now
        }

        print("PROBE-DELETE-TOP\n" + log.joined(separator: "\n"))
        XCTAssertTrue(cardNames(app).isEmpty,
                      "全部消えない。始め \(started) / 残り \(cardNames(app))")
    }

    /// **速く消す。** 人は 2.5 秒も待たない。
    /// ゆっくり消せば通ることは確かめたので、壊れるとしたらここ。
    /// 消えるアニメーションが終わる前に次を払う。
    func testDeleteFast() {
        let app = XCUIApplication()
        app.launchArguments = ["-ETSeed", Self.rearReverb, "-ETWidth", "0"]
        app.launch()
        Thread.sleep(forTimeInterval: 6)

        var log: [String] = []
        log.append("start: \(cardNames(app))")

        // 先頭を 5 回、間を空けずに払い続ける。
        for step in 0..<5 {
            let sw = firstCard(app)
            guard sw.waitForExistence(timeout: 3), sw.isHittable else {
                log.append("step=\(step) 掴めない 残り=\(cardNames(app))")
                break
            }
            let name = sw.label
            sw.coordinate(withNormalizedOffset: CGVector(dx: 6, dy: 0.5))
                .press(forDuration: 0.05,
                       thenDragTo: sw.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
            Thread.sleep(forTimeInterval: 0.35)
            let delete = app.buttons["Delete"]
            if delete.waitForExistence(timeout: 2) {
                delete.tap()
            } else {
                log.append("step=\(step) **Delete が出ない** 掴んだ=\(name)")
                break
            }
            Thread.sleep(forTimeInterval: 0.35)   // アニメーションの途中で次へ
            log.append("step=\(step) 消した=\(name)")
        }

        Thread.sleep(forTimeInterval: 3)
        let onScreen = cardNames(app)
        // **上まで戻してから数える。** List は見えている行しか accessibility に出さない。
        // 下に居るまま数えると、上に残っているカードを見落として通ってしまう。
        for _ in 0..<4 {
            app.collectionViews.firstMatch.swipeDown()
            Thread.sleep(forTimeInterval: 0.3)
        }
        let left = cardNames(app)
        log.append("落ち着いてから: \(onScreen) / 上へ戻して: \(left)")
        print("PROBE-DELETE-FAST\n" + log.joined(separator: "\n"))
        XCTAssertTrue(left.isEmpty, "速く消すと残る: \(left)")
    }

    /// 真ん中から消す。順序で変わるかを見る。
    func testDeleteFromMiddle() {
        let app = XCUIApplication()
        app.launchArguments = ["-ETSeed", Self.rearReverb, "-ETWidth", "0"]
        app.launch()
        Thread.sleep(forTimeInterval: 6)

        var log: [String] = []
        var names = cardNames(app)
        log.append("start: \(names)")

        while !names.isEmpty {
            let target = names[names.count / 2]
            let ok = swipeDelete(app, named: target, log: &log)
            let now = cardNames(app)
            log.append("消した=\(target) ok=\(ok) 残り=\(now)")
            if !ok || now.count >= names.count { break }
            names = now
        }

        print("PROBE-DELETE-MID\n" + log.joined(separator: "\n"))
        XCTAssertTrue(cardNames(app).isEmpty, "真ん中から消すと残る: \(cardNames(app))")
    }
}
