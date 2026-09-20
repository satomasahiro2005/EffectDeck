//  DynamicProbe.swift
//  主要な操作を機械で一通り叩く。判定はアプリのログ（publish …）を正とする。
//  1 テスト = 1 回の xcodebuild で走らせ、その間のログをそのまま読む。

import XCTest
import UIKit

final class DynamicProbe: XCTestCase {

    // MARK: - 道具

    @discardableResult
    private func launch(_ args: [String] = ["-ETSeed", "none"]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = args
        app.launch()
        XCTAssertTrue(app.navigationBars.buttons["Add Effect"].waitForExistence(timeout: 60),
                      "本画面が出ない")
        return app
    }

    /// ピッカーの行。ラベルは "名前, 分類, 説明" で組まれている。
    private func pickerRow(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name + ",")).firstMatch
    }

    private func openPicker(_ app: XCUIApplication) {
        app.navigationBars.buttons["Add Effect"].tap()
        XCTAssertTrue(app.navigationBars["Available Effects"].waitForExistence(timeout: 15),
                      "ピッカーが開かない")
    }

    private func dump(_ app: XCUIApplication, _ tag: String) {
        print("PROBE[\(tag)] buttons=\(app.buttons.count) cells=\(app.cells.count) "
              + "switches=\(app.switches.count) sliders=\(app.sliders.count) "
              + "fields=\(app.textFields.count)")
    }

    /// 当たり判定の調査に使う道具。落ちた所の木を見たいときだけ走らせる。
    func test00DumpTree() {
        let app = launch(["-ETSeed", "VolumePlugin"])
        Thread.sleep(forTimeInterval: 3)
        print("PROBE TREE BEGIN")
        print(app.debugDescription)
        print("PROBE TREE END")
    }

    // MARK: - 1. エフェクトを足す

    /// 期待: + → 検索 → 行を押すと鎖に入り、シートが閉じ、開いた状態で出る。
    func test01AddEffectBySearch() {
        let app = launch()
        openPicker(app)

        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "検索欄が無い")
        field.tap()
        field.typeText("Volume")
        Thread.sleep(forTimeInterval: 1.5)

        let row = pickerRow(app, "Volume")
        print("PROBE search row exists=\(row.exists) label=\(row.exists ? row.label : "-")")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "検索しても Volume が出ない")
        row.tap()

        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertFalse(app.navigationBars["Available Effects"].exists, "選んでもシートが閉じない")
        dump(app, "afterAdd")

        // 足したカードの電源。読み上げ名がエフェクト名。
        XCTAssertTrue(app.switches["Volume"].waitForExistence(timeout: 10), "鎖に Volume が出ない")
        // 開いているか。Volume はスライダー 1 本。
        XCTAssertTrue(app.sliders.firstMatch.waitForExistence(timeout: 10),
                      "足した直後に開いていない（つまみが出ない）")
    }

    /// 期待: カテゴリの帯を押すと一覧がそこへ飛ぶ。
    ///       帯は横に払えて、後ろのカテゴリにも届く。
    func test02AddEffectByCategoryStrip() {
        let app = launch()
        openPicker(app)
        Thread.sleep(forTimeInterval: 1.5)

        // 帯は Text だけのボタン。行は "名前, 分類, 説明" なので混ざらない。
        func chip(_ name: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
        }

        let dyn = chip("Dynamics")
        XCTAssertTrue(dyn.waitForExistence(timeout: 10), "Dynamics の帯が無い")
        print("PROBE chip Dynamics frame=\(dyn.frame) hittable=\(dyn.isHittable)")
        dyn.tap()
        Thread.sleep(forTimeInterval: 2.5)

        let comp = pickerRow(app, "Compressor")
        print("PROBE Compressor exists=\(comp.exists) hittable=\(comp.exists ? comp.isHittable : false) "
              + "frame=\(comp.exists ? "\(comp.frame)" : "-")")
        XCTAssertTrue(comp.exists, "帯を押しても Dynamics の節へ飛んでいない")
        XCTAssertTrue(comp.isHittable, "飛び先の行が画面に出ていない")

        // 後ろのカテゴリは帯を払って出す。
        let rev = chip("Reverb")
        let y = dyn.frame.midY
        var tries = 0
        while tries < 8 && !(rev.exists && rev.frame.minX > 0 && rev.frame.maxX < 430) {
            let a = app.coordinate(withNormalizedOffset: .zero)
                       .withOffset(CGVector(dx: 400, dy: y))
            let b = app.coordinate(withNormalizedOffset: .zero)
                       .withOffset(CGVector(dx: 40, dy: y))
            a.press(forDuration: 0.05, thenDragTo: b)
            Thread.sleep(forTimeInterval: 0.8)
            print("PROBE strip swipe \(tries) reverbFrame=\(rev.exists ? "\(rev.frame)" : "-")")
            tries += 1
        }
        print("PROBE chip Reverb tries=\(tries) exists=\(rev.exists) "
              + "frame=\(rev.exists ? "\(rev.frame)" : "-")")
        XCTAssertTrue(rev.exists && rev.frame.minX > 0 && rev.frame.maxX < 440,
                      "帯を払っても Reverb まで届かない")
        rev.tap()
        Thread.sleep(forTimeInterval: 2.5)

        let rs = pickerRow(app, "RS Reverb")
        XCTAssertTrue(rs.exists && rs.isHittable, "Reverb の節へ飛んでいない")
        rs.tap()
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertFalse(app.navigationBars["Available Effects"].exists, "選んでもシートが閉じない")
        XCTAssertTrue(app.switches["RS Reverb"].waitForExistence(timeout: 10), "鎖に入らない")
    }

    // MARK: - 2. カードを開く・閉じる

    /// 期待: 行のどこを押しても開閉が切り替わる。開閉は鎖の中身を変えない。
    func test03ExpandCollapse() {
        let app = launch(["-ETSeed", "VolumePlugin,CompressorPlugin"])
        Thread.sleep(forTimeInterval: 2)

        let name = app.staticTexts["Volume"]
        XCTAssertTrue(name.waitForExistence(timeout: 15), "Volume のカードが無い")
        let openCount = app.sliders.count
        print("PROBE expand start sliders=\(openCount)")
        XCTAssertGreaterThan(openCount, 0, "既定で開いていない")

        // 名前を押す。
        name.tap()
        Thread.sleep(forTimeInterval: 1.5)
        let afterName = app.sliders.count
        print("PROBE after tap name sliders=\(afterName)")
        XCTAssertLessThan(afterName, openCount, "名前を押しても畳まれない")

        // もう一度で戻る。
        name.tap()
        Thread.sleep(forTimeInterval: 1.5)
        print("PROBE after tap name again sliders=\(app.sliders.count)")
        XCTAssertEqual(app.sliders.count, openCount, "もう一度押しても開かない")

        // 山印のあたり（右端の ⋯ の左）を押す。押し所ではないが行の一部。
        let cell = app.cells.containing(.staticText, identifier: "Volume").firstMatch
        XCTAssertTrue(cell.exists, "Volume の行が取れない")
        let f = cell.frame
        // ⋯ は右端 34pt、その左が山印。行の右から 60pt の所。
        let chevron = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: f.maxX - 60, dy: f.minY + 26))
        print("PROBE cell frame=\(f) chevronAt=(\(f.maxX - 60),\(f.minY + 26))")
        chevron.tap()
        Thread.sleep(forTimeInterval: 1.5)
        print("PROBE after tap chevron sliders=\(app.sliders.count)")
        XCTAssertLessThan(app.sliders.count, openCount, "山印のあたりを押しても畳まれない")
    }

    // MARK: - 3. つまみを動かす

    /// 期待: つまみを動かすと数値欄が追う。欄に打ち込むと値が入る。
    ///       範囲の外は端で止まる（EffectCatalog: Volume は -60..24 dB）。
    func test04SliderAndField() {
        let app = launch(["-ETSeed", "VolumePlugin"])
        Thread.sleep(forTimeInterval: 2)

        let slider = app.sliders.firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 15), "つまみが無い")
        let field = app.textFields["Volume (dB)"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "数値欄が無い")
        print("PROBE start field=\(String(describing: field.value)) slider=\(String(describing: slider.value))")

        // つまみを掴んで右へ引く。0 dB のつまみは軌道の (0+60)/84 = 0.714。
        // **長押しから引いてはいけない。** List が .onMove を持っているので
        // 0.6 秒の押し込みは行の入れ替えになり、つまみは動かない（器具の話）。
        let f = slider.frame
        let from = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: f.minX + f.width * 0.714, dy: f.midY))
        let to = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: f.minX + f.width * 0.95, dy: f.midY))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow,
                   thenHoldForDuration: 0.3)
        Thread.sleep(forTimeInterval: 1.5)
        let afterDrag = (field.value as? String) ?? ""
        print("PROBE after drag field=\(afterDrag) slider=\(String(describing: slider.value))")
        XCTAssertNotEqual(afterDrag, "0.00", "つまみを動かしても数値欄が動かない")
        // 引いた距離は軌道の 0.236 ぶん = 84 dB * 0.236 = 19.8 dB。
        if let v = Float(afterDrag) {
            XCTAssertEqual(v, 19.8, accuracy: 4.0, "つまみの移動量と値が合わない")
        } else {
            XCTFail("数値欄が数として読めない: \(afterDrag)")
        }
        // 読み上げの値も画面と揃っているか。
        XCTAssertEqual(slider.value as? String, afterDrag, "つまみの読み上げ値が数値欄と違う")

        // 欄に打ち込む。
        func type(_ text: String) -> String {
            field.tap()
            Thread.sleep(forTimeInterval: 1.0)
            let now = (field.value as? String) ?? ""
            for _ in 0..<(now.count + 4) { field.typeText(XCUIKeyboardKey.delete.rawValue) }
            field.typeText(text + "\n")
            Thread.sleep(forTimeInterval: 1.5)
            return (field.value as? String) ?? ""
        }

        let typed = type("12")
        print("PROBE after type 12 field=\(typed)")
        XCTAssertEqual(Float(typed) ?? -999, 12.0, accuracy: 0.05, "打ち込んだ値が入らない")

        // 範囲の外。
        let over = type("999")
        print("PROBE after type 999 field=\(over)")
        XCTAssertEqual(Float(over) ?? -999, 24.0, accuracy: 0.05, "上限で止まらない")

        let under = type("-999")
        print("PROBE after type -999 field=\(under)")
        XCTAssertEqual(Float(under) ?? 999, -60.0, accuracy: 0.05, "下限で止まらない")

        // 数でないもの。
        let junk = type("abc")
        print("PROBE after type abc field=\(junk)")
        XCTAssertEqual(Float(junk) ?? 999, -60.0, accuracy: 0.05,
                       "数でない字を打つと値が壊れる")
    }

    // MARK: - 4. 入切

    /// 期待: カードの電源を切ると鎖からは落ちず active が減る。
    ///       マスターを切ると帯が出て、読み上げが Bypassed になる。
    func test05Power() {
        let app = launch(["-ETSeed", "VolumePlugin,CompressorPlugin"])
        Thread.sleep(forTimeInterval: 2)

        let vol = app.switches["Volume"]
        XCTAssertTrue(vol.waitForExistence(timeout: 15), "Volume の電源が無い")
        print("PROBE power before value=\(String(describing: vol.value))")
        vol.tap()
        Thread.sleep(forTimeInterval: 2)
        print("PROBE power after value=\(String(describing: vol.value))")
        XCTAssertTrue(app.switches["Volume"].exists, "切ったらカードごと消えた")

        // マスター。
        let master = app.switches["All effects"]
        XCTAssertTrue(master.exists, "マスターの電源が無い")
        print("PROBE master before value=\(String(describing: master.value))")
        master.tap()
        Thread.sleep(forTimeInterval: 2)
        print("PROBE master after value=\(String(describing: master.value))")
        XCTAssertTrue(app.staticTexts["All effects bypassed"].waitForExistence(timeout: 10),
                      "マスターを切っても帯が出ない")
        XCTAssertTrue((master.value as? String ?? "").contains("Bypassed"),
                      "マスターの読み上げが Bypassed にならない: \(String(describing: master.value))")

        // 帯の Turn On で戻る。
        app.buttons["Turn On"].tap()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(app.staticTexts["All effects bypassed"].exists, "Turn On で帯が消えない")
    }

    // MARK: - 5. 図だけ表示

    func test07SystemPreset() {
        let app = launch(["-ETSeed", "VolumePlugin"])
        Thread.sleep(forTimeInterval: 2)
        openPresets(app)
        Thread.sleep(forTimeInterval: 1.5)

        let group = app.buttons["Visualize"].firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 10), "Visualize の節が無い")
        group.tap()
        Thread.sleep(forTimeInterval: 1.5)

        let preset = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "All Analyzers")).firstMatch
        print("PROBE preset exists=\(preset.exists) label=\(preset.exists ? preset.label : "-")")
        XCTAssertTrue(preset.waitForExistence(timeout: 10), "All Analyzers が無い")
        preset.tap()
        Thread.sleep(forTimeInterval: 3)

        XCTAssertFalse(app.navigationBars["Presets"].exists, "読み込んでもシートが閉じない")
        // 元の Volume が残っているか（置き換えでないこと）。
        XCTAssertTrue(app.switches["Volume"].waitForExistence(timeout: 10),
                      "プリセットが鎖を置き換えた（Volume が消えた）")
        // 名前付きの Section で包まれているか。
        let section = app.textFields["Section name"].firstMatch
        print("PROBE section value=\(String(describing: section.value))")
        XCTAssertTrue(section.exists, "Section が入っていない")
        XCTAssertEqual(section.value as? String, "All Analyzers",
                       "Section にプリセット名が入っていない")
    }

    /// 期待: 名前を付けて保存でき、押すと足され、払って消せる。空のときは空と言う。
    func test08UserPreset() {
        let app = launch(["-ETSeed", "VolumePlugin"])
        Thread.sleep(forTimeInterval: 2)
        openPresets(app)
        Thread.sleep(forTimeInterval: 1.5)

        print("PROBE user empty text=\(app.staticTexts["No saved presets"].exists)")

        let name = app.textFields["Preset name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10), "名前の欄が無い")
        name.tap()
        name.typeText("Probe A")
        Thread.sleep(forTimeInterval: 0.5)
        let save = app.buttons["Save"]
        print("PROBE save enabled=\(save.isEnabled)")
        XCTAssertTrue(save.isEnabled, "名前を入れても Save が押せない")
        save.tap()
        Thread.sleep(forTimeInterval: 2)

        let row = app.buttons["Probe A"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "保存しても一覧に出ない")
        row.tap()
        Thread.sleep(forTimeInterval: 3)
        XCTAssertFalse(app.navigationBars["Presets"].exists, "読み込んでもシートが閉じない")
        let section = app.textFields["Section name"].firstMatch
        print("PROBE user section value=\(String(describing: section.value))")
        XCTAssertEqual(section.value as? String, "Probe A", "Section に名前が入らない")

        // 後始末も兼ねて、払って消す。
        openPresets(app)
        Thread.sleep(forTimeInterval: 1.5)
        let row2 = app.buttons["Probe A"].firstMatch
        XCTAssertTrue(row2.waitForExistence(timeout: 10), "保存したものが残っていない")
        row2.swipeLeft()
        Thread.sleep(forTimeInterval: 1)
        let del = app.buttons["Delete"].firstMatch
        print("PROBE delete exists=\(del.exists)")
        XCTAssertTrue(del.waitForExistence(timeout: 5), "払っても Delete が出ない")
        del.tap()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(app.buttons["Probe A"].exists, "消しても残っている")
    }

    // MARK: - 8. 共有リンク

    /// 期待: 貼り付けを押したら、取り込むか・読めないかを必ず言う。黙って閉じない。
    func test09ImportFromClipboard() {
        // 空の貼り板。読み取りの許可を挟まずに済む。
        UIPasteboard.general.items = []

        let app = launch(["-ETSeed", "VolumePlugin"])
        Thread.sleep(forTimeInterval: 2)
        openPresets(app)
        Thread.sleep(forTimeInterval: 1.5)

        // 一覧の一番下にある。出るまで払う。
        let importButton = app.buttons["Import from clipboard"].firstMatch
        var tries = 0
        while tries < 10 && !(importButton.exists && importButton.isHittable) {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.6)
            tries += 1
        }
        print("PROBE import tries=" + String(tries) + " exists=" + String(importButton.exists))
        XCTAssertTrue(importButton.exists, "貼り付けの項目が無い")
        importButton.tap()
        Thread.sleep(forTimeInterval: 3)

        print("PROBE empty-clipboard alerts=\(app.alerts.count) "
              + "labels=\(app.alerts.allElementsBoundByIndex.map(\.label))")
        print("PROBE sheet still open=\(app.navigationBars["Presets"].exists)")
        XCTAssertGreaterThan(app.alerts.count, 0,
                             "貼り板が空でも何も言わない（押しても無反応）")
    }

    // MARK: - 7. Reset Pipeline

    /// 期待: ⋯ から出し、確認を挟み、押すと Level Meter 1 本になる。
    ///       既に 1 本なら押せない。
    func test10ResetPipeline() {
        let app = launch(["-ETSeed", "VolumePlugin,CompressorPlugin"])
        Thread.sleep(forTimeInterval: 2)

        app.buttons["moreMenu"].tap()
        Thread.sleep(forTimeInterval: 1.5)
        let reset = app.buttons["Reset Pipeline"].firstMatch
        print("PROBE reset exists=\(reset.exists) enabled=\(reset.exists ? reset.isEnabled : false)")
        XCTAssertTrue(reset.waitForExistence(timeout: 10), "⋯ に Reset Pipeline が無い")
        XCTAssertTrue(reset.isEnabled, "鎖が 2 本あるのに押せない")
        reset.tap()
        Thread.sleep(forTimeInterval: 2)

        // 確認が出るか。
        print("PROBE confirm sheets=\(app.sheets.count) alerts=\(app.alerts.count)")
        XCTAssertGreaterThan(app.sheets.count + app.alerts.count, 0, "確認が出ない")
        XCTAssertTrue(app.staticTexts["Reset Pipeline?"].exists
                      || app.staticTexts["Removes every effect and leaves a single Level Meter."].exists,
                      "確認の文面が出ない")

        let confirm = app.sheets.buttons["Reset Pipeline"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "確認に Reset Pipeline が無い")
        confirm.tap()
        Thread.sleep(forTimeInterval: 3)

        XCTAssertFalse(app.switches["Volume"].exists, "戻しても Volume が残る")
        XCTAssertTrue(app.switches["Level Meter"].waitForExistence(timeout: 10),
                      "Level Meter 1 本にならない")

        // もう一度開くと押せないこと。
        app.buttons["moreMenu"].tap()
        Thread.sleep(forTimeInterval: 1.5)
        let reset2 = app.buttons["Reset Pipeline"].firstMatch
        XCTAssertTrue(reset2.waitForExistence(timeout: 10), "⋯ が開かない")
        print("PROBE reset again enabled=\(reset2.isEnabled)")
        XCTAssertFalse(reset2.isEnabled, "既に既定なのに押せてしまう")
    }

    // MARK: - 9. Settings

    /// 期待: 音が鳴っている最中でも設定を一通り触れて、値が残る。
    func test11Settings() {
        let app = launch(["-ETSeed", "LevelMeterPlugin", "-ETMock", "1"])
        Thread.sleep(forTimeInterval: 3)

        func openSettings() {
            app.buttons["moreMenu"].tap()
            Thread.sleep(forTimeInterval: 1.5)
            app.buttons["Settings"].firstMatch.tap()
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 20),
                          "Settings が開かない")
            Thread.sleep(forTimeInterval: 2)
        }
        /// 一覧の下にあるものを出すまで払う。
        func reveal(_ e: XCUIElement, _ name: String) -> Bool {
            var tries = 0
            while tries < 10 && !(e.exists && e.isHittable) {
                app.swipeUp()
                Thread.sleep(forTimeInterval: 0.6)
                tries += 1
            }
            print("PROBE reveal \(name) tries=\(tries) exists=\(e.exists)")
            return e.exists
        }

        openSettings()

        // セグメントを全部押す。名前は Preferences / PowerPolicy の label。
        for name in ["96 kHz", "192 kHz", "48 kHz",
                     "5 ms", "23 ms", "10 ms",
                     "Never", "1 s", "3 s"] {
            let seg = app.buttons[name].firstMatch
            if !seg.exists {
                print("PROBE segment missing: \(name)")
                continue
            }
            seg.tap()
            Thread.sleep(forTimeInterval: 1.5)
            print("PROBE segment \(name) selected=\(seg.isSelected)")
        }

        // Silence threshold の Stepper。
        let stepper = app.steppers.firstMatch
        XCTAssertTrue(reveal(stepper, "stepper"), "Stepper が無い")
        // **" dB" で終わる字は他にもある**（生の測定値は小数）。整数の行だけを見る。
        func dbLabel() -> String {
            let e = app.staticTexts.matching(
                NSPredicate(format: "label MATCHES %@", "^-?[0-9]+ dB$")).firstMatch
            return e.exists ? e.label : "-"
        }
        let beforeText = dbLabel()
        stepper.buttons.element(boundBy: 1).tap()
        Thread.sleep(forTimeInterval: 1.5)
        let afterText = dbLabel()
        print("PROBE stepper \(beforeText) -> \(afterText)")
        XCTAssertNotEqual(beforeText, afterText, "Stepper を押しても値が動かない")

        // 画面を消さない。
        let keep = app.switches["Keep the screen on"]
        XCTAssertTrue(reveal(keep, "keep"), "Keep the screen on が無い")
        // **入切そのものは test21 が見ている。** ここは見付かることだけ確かめる。
        // 行の真ん中を叩いても反応しない（つまみだけが反応する。iOS の設定と同じ）ので、
        // ここで叩くと当たり所で結果が変わる。
        let keepBefore = keep.value as? String
        print("PROBE keep value=\(String(describing: keepBefore)) frame=\(keep.frame)")

        // Details。
        let details = app.buttons["Details"].firstMatch
        print("PROBE details revealed=\(reveal(details, "details"))")
        if details.exists {
            details.tap()
            Thread.sleep(forTimeInterval: 2)
            print("PROBE details opened rows=\(app.staticTexts.count)")
        }

        // 条文。
        let lic = app.buttons["Licenses"].firstMatch
        XCTAssertTrue(reveal(lic, "licenses"), "Licenses の項目が無い")
        lic.tap()
        Thread.sleep(forTimeInterval: 2.5)
        let bar = app.navigationBars["Licenses"]
        print("PROBE licenses bar=\(bar.exists) cells=\(app.cells.count)")
        XCTAssertTrue(bar.waitForExistence(timeout: 15), "Licenses が開かない")
        let first = app.cells.firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10), "ライセンスの一覧が空")
        let textsBefore = app.staticTexts.count
        first.tap()
        Thread.sleep(forTimeInterval: 2.5)
        print("PROBE license body before=\(textsBefore) after=\(app.staticTexts.count)")
        XCTAssertGreaterThan(app.staticTexts.count, textsBefore, "本文が開かない")

        // 戻って閉じる。
        app.navigationBars["Licenses"].buttons.element(boundBy: 0).tap()
        Thread.sleep(forTimeInterval: 2)
        let done = app.navigationBars["Settings"].buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), "Settings へ戻れない")
        done.tap()
        Thread.sleep(forTimeInterval: 2)

        // 残っているか。開き直して確かめる。
        openSettings()
        let keep2 = app.switches["Keep the screen on"]
        XCTAssertTrue(reveal(keep2, "keep2"), "開き直すと Keep the screen on が無い")
        print("PROBE keep after reopen=\(String(describing: keep2.value))")
        XCTAssertEqual(keep2.value as? String, keepBefore, "開き直すと値が変わっている")
    }

    // MARK: - 10. Routing

    /// 期待: バスとチャンネルを変えると、カードの札に出る。
    func test12Routing() {
        let app = launch(["-ETSeed", "VolumePlugin,CompressorPlugin"])
        Thread.sleep(forTimeInterval: 2)

        app.buttons["moreMenu"].tap()
        Thread.sleep(forTimeInterval: 1.5)
        app.buttons["Routing"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Routing"].waitForExistence(timeout: 15),
                      "Routing が開かない")
        Thread.sleep(forTimeInterval: 2)

        // 1 段目の Out を 1 にする。
        let outMenu = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Out")).firstMatch
        print("PROBE out exists=\(outMenu.exists) label=\(outMenu.exists ? outMenu.label : "-")")
        XCTAssertTrue(outMenu.waitForExistence(timeout: 10), "Out の操作子が無い")
        outMenu.tap()
        Thread.sleep(forTimeInterval: 1.5)
        let one = app.buttons["1"].firstMatch
        XCTAssertTrue(one.waitForExistence(timeout: 5), "バスの選択肢が出ない")
        one.tap()
        Thread.sleep(forTimeInterval: 2)

        // 1 段目の Channel を Left にする。
        let ch = app.buttons["Channel"].firstMatch
        XCTAssertTrue(ch.waitForExistence(timeout: 10), "Channel の操作子が無い")
        ch.tap()
        Thread.sleep(forTimeInterval: 1.5)
        let left = app.buttons["Left"].firstMatch
        XCTAssertTrue(left.waitForExistence(timeout: 5), "チャンネルの選択肢が出ない")
        left.tap()
        Thread.sleep(forTimeInterval: 2)

        // 閉じてカードの札を見る。
        app.navigationBars["Routing"].buttons["Done"].tap()
        Thread.sleep(forTimeInterval: 2.5)
        let all = app.staticTexts.allElementsBoundByIndex.compactMap {
            $0.label.contains("→") ? $0.label : nil
        }
        print("PROBE badges=\(all)")
        XCTAssertTrue(all.contains("0→1 Left"), "カードの札が期待と違う: \(all)")
    }

    // MARK: - 11. 向きを変える

    /// 期待: 横にしても鎖と開閉が保たれる。
    func test13Rotation() {
        let app = launch(["-ETSeed", "VolumePlugin,CompressorPlugin"])
        Thread.sleep(forTimeInterval: 2)

        // 1 枚畳んでおく。
        app.staticTexts["Volume"].tap()
        Thread.sleep(forTimeInterval: 1.5)
        let collapsed = app.sliders.count
        print("PROBE rotate before sliders=\(collapsed) switches=\(app.switches.count)")

        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 4)
        print("PROBE landscape sliders=\(app.sliders.count) switches=\(app.switches.count) "
              + "volume=\(app.switches["Volume"].exists) comp=\(app.switches["Compressor"].exists)")
        XCTAssertTrue(app.switches["Volume"].exists, "横にすると Volume が消える")
        XCTAssertTrue(app.switches["Compressor"].exists, "横にすると Compressor が消える")

        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 4)
        let after = app.sliders.count
        print("PROBE portrait sliders=\(after) switches=\(app.switches.count)")
        XCTAssertTrue(app.switches["Volume"].exists, "戻すと Volume が消える")
        XCTAssertEqual(after, collapsed, "向きを変えると開閉が変わる")
    }

    // MARK: - 12. たくさん並べる

    /// 期待: 20 本ほど並べても、払って消す・開閉する・設定を開くが通る。
    func test14ManyEffects() {
        let names = ["Volume", "Tone Control", "Compressor", "RS Reverb", "Level Meter",
                     "Spectrum Analyzer", "5Band PEQ", "Delay", "Chorus", "Phaser",
                     "Expander", "Auto Pan", "Tremolo", "Exciter", "Sub Synth",
                     "Stereo Blend", "Narrow Range", "Hi Pass Filter", "Lo Pass Filter",
                     "Saturation"]
        let app = launch(["-ETSeed",
                          "VolumePlugin,ToneControlPlugin,CompressorPlugin,RSReverbPlugin,"
                          + "LevelMeterPlugin,SpectrumAnalyzerPlugin,FiveBandPEQPlugin,"
                          + "DelayPlugin,ChorusPlugin,PhaserPlugin,ExpanderPlugin,"
                          + "AutoPanPlugin,TremoloPlugin,ExciterPlugin,SubSynthPlugin,"
                          + "StereoBlendPlugin,NarrowRangePlugin,HiPassFilterPlugin,"
                          + "LoPassFilterPlugin,SaturationPlugin",
                          "-ETCollapsed", "1"])
        Thread.sleep(forTimeInterval: 5)

        // 一覧は遅延で作られるので、払いながら名前を集める。
        var seen = Set<String>()
        for step in 0..<40 {
            for s in app.switches.allElementsBoundByIndex { seen.insert(s.label) }
            if seen.isSuperset(of: names) { break }
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.5)
            if step == 39 { break }
        }
        let missing = names.filter { !seen.contains($0) }
        print("PROBE many seen=\(seen.count) missing=\(missing)")
        XCTAssertTrue(missing.isEmpty, "払っても出てこない段がある: \(missing)")

        // 上へ戻す。
        for _ in 0..<40 { app.swipeDown() }
        Thread.sleep(forTimeInterval: 2)

        // 開閉。
        let comp = app.staticTexts["Compressor"]
        XCTAssertTrue(comp.waitForExistence(timeout: 15), "Compressor の行が無い")
        let start = Date()
        comp.tap()
        Thread.sleep(forTimeInterval: 2)
        print("PROBE many expand took=\(Date().timeIntervalSince(start))s sliders=\(app.sliders.count)")
        XCTAssertGreaterThan(app.sliders.count, 0, "20 本あると開けない")
        comp.tap()
        Thread.sleep(forTimeInterval: 1.5)

        // 払って消す。画面に出るまで送ってから。
        let chorusText = app.staticTexts["Chorus"]
        var tries = 0
        while tries < 20 && !(chorusText.exists && chorusText.isHittable) {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.5)
            tries += 1
        }
        print("PROBE many chorus tries=\(tries) exists=\(chorusText.exists)")
        let card = app.cells.containing(.staticText, identifier: "Chorus").firstMatch
        XCTAssertTrue(card.exists, "Chorus の行が無い")
        card.swipeLeft()
        Thread.sleep(forTimeInterval: 1.5)
        let del = app.buttons["Delete"].firstMatch
        XCTAssertTrue(del.waitForExistence(timeout: 5), "払っても Delete が出ない")
        del.tap()
        Thread.sleep(forTimeInterval: 2.5)
        print("PROBE many after delete chorus=\(app.switches["Chorus"].exists)")
        XCTAssertFalse(app.switches["Chorus"].exists, "払って消しても残っている")

        // 設定を開く。
        app.buttons["moreMenu"].tap()
        Thread.sleep(forTimeInterval: 2)
        let settings = app.buttons["Settings"].firstMatch
        print("PROBE many settings exists=\(settings.exists) hittable=\(settings.exists ? settings.isHittable : false)")
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "20 本あると ⋯ が開かない")
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 25),
                      "20 本あると Settings が開かない")
    }

    // MARK: - 13. 図が並んだときの重さ

    /// 同じ瞬間・同じ機械で、素のエフェクト 5 本と analyzer 5 本を比べる。
    /// 機械の混み具合は両方に等しくかかるので、差が出れば鎖の中身の話。
    private func timeQuery(_ app: XCUIApplication, _ tag: String) -> Double {
        var worst = 0.0
        var total = 0.0
        for i in 0..<5 {
            let t0 = Date()
            _ = app.switches.count
            let dt = Date().timeIntervalSince(t0)
            total += dt
            worst = max(worst, dt)
            print("PROBE[\(tag)] query \(i) = \(String(format: "%.2f", dt))s")
        }
        print("PROBE[\(tag)] avg=\(String(format: "%.2f", total / 5))s worst=\(String(format: "%.2f", worst))s")
        return total / 5
    }

    func test15AnalyzerCost() {
        // A: 図を持たないエフェクト 5 本。
        let a = XCUIApplication()
        a.launchArguments = ["-ETSeed",
                             "VolumePlugin,ToneControlPlugin,CompressorPlugin,"
                             + "ExpanderPlugin,StereoBlendPlugin"]
        a.launch()
        XCTAssertTrue(a.navigationBars.buttons["Add Effect"].waitForExistence(timeout: 90),
                      "A の本画面が出ない")
        Thread.sleep(forTimeInterval: 4)
        let plain = timeQuery(a, "plain")
        a.terminate()
        Thread.sleep(forTimeInterval: 2)

        // B: All Analyzers と同じ顔ぶれ。
        let b = XCUIApplication()
        b.launchArguments = ["-ETSeed",
                             "SpectrogramPlugin,SpectrumAnalyzerPlugin,StereoMeterPlugin,"
                             + "OscilloscopePlugin,LevelMeterPlugin"]
        b.launch()
        let up = b.navigationBars.buttons["Add Effect"].waitForExistence(timeout: 180)
        print("PROBE analyzers screenUp=\(up)")
        XCTAssertTrue(up, "analyzer 5 本だと本画面が 180 秒待っても掴めない")
        Thread.sleep(forTimeInterval: 4)
        let analyzers = timeQuery(b, "analyzers")

        print("PROBE cost plain=\(String(format: "%.2f", plain))s "
              + "analyzers=\(String(format: "%.2f", analyzers))s "
              + "ratio=\(String(format: "%.1f", analyzers / max(plain, 0.001)))")
        XCTAssertLessThan(analyzers, max(plain * 8, 3.0),
                          "analyzer を 5 本並べると画面が掴めなくなる "
                          + "(plain=\(plain)s analyzers=\(analyzers)s)")
    }

    // MARK: - 6b. 畳んでも図は出るか（analyzer の重さの逃げ道があるか）

    func test16AnalyzerCollapsed() {
        let app = XCUIApplication()
        app.launchArguments = ["-ETSeed",
                               "SpectrogramPlugin,SpectrumAnalyzerPlugin,StereoMeterPlugin,"
                               + "OscilloscopePlugin,LevelMeterPlugin",
                               "-ETCollapsed", "1"]
        app.launch()
        let up = app.navigationBars.buttons["Add Effect"].waitForExistence(timeout: 180)
        print("PROBE collapsed screenUp=\(up)")
        XCTAssertTrue(up, "畳んでも本画面が掴めない")
        Thread.sleep(forTimeInterval: 4)
        _ = timeQuery(app, "collapsedAnalyzers")
    }

    // MARK: - 3b. ⋯ の Reset Parameters と、配列のパラメータ

    /// 期待: 値を変えてから ⋯ の Reset Parameters を押すと既定へ戻る。
    func test17ResetParameters() {
        let app = launch(["-ETSeed", "VolumePlugin"])
        Thread.sleep(forTimeInterval: 2)

        let field = app.textFields["Volume (dB)"]
        XCTAssertTrue(field.waitForExistence(timeout: 15), "数値欄が無い")
        field.tap()
        Thread.sleep(forTimeInterval: 1.0)
        let now = (field.value as? String) ?? ""
        for _ in 0..<(now.count + 4) { field.typeText(XCUIKeyboardKey.delete.rawValue) }
        field.typeText("7\n")
        Thread.sleep(forTimeInterval: 1.5)
        print("PROBE reset-params before=\(String(describing: field.value))")
        XCTAssertEqual(Float((field.value as? String) ?? "") ?? -999, 7.0, accuracy: 0.05,
                       "打ち込めていない")

        // カードの ⋯。ツールバーの moreMenu とは別物なので、行の中から拾う。
        let cell = app.cells.containing(.staticText, identifier: "Volume").firstMatch
        XCTAssertTrue(cell.exists, "Volume の行が無い")
        let cardMenu = cell.buttons.element(boundBy: cell.buttons.count - 1)
        print("PROBE card menu label=\(cardMenu.label) frame=\(cardMenu.frame) "
              + "buttons=\(cell.buttons.allElementsBoundByIndex.map(\.label))")
        cardMenu.tap()
        Thread.sleep(forTimeInterval: 1.5)

        let reset = app.buttons["Reset Parameters"].firstMatch
        print("PROBE resetParams exists=\(reset.exists)")
        XCTAssertTrue(reset.waitForExistence(timeout: 10), "⋯ に Reset Parameters が無い")
        reset.tap()
        Thread.sleep(forTimeInterval: 2)

        print("PROBE reset-params after=\(String(describing: field.value))")
        XCTAssertEqual(Float((field.value as? String) ?? "") ?? -999, 0.0, accuracy: 0.05,
                       "Reset Parameters で既定へ戻らない")
    }

    /// 期待: 配列のパラメータは札で要素を選べて、選んだ要素の値だけが動く。
    /// Multiband Balance の Balance は 5 要素・既定は全部 0・範囲 -100..100 の整数
    /// （EffectCatalog.swift:1583）。
    ///
    /// 打ち込みは 1 打ずつ確かめる。前の走りで "55" と打って 100 が入ったので、
    /// どこで化けるかを見る。
    func test18ArrayParameter() {
        let app = launch(["-ETSeed", "MultibandBalancePlugin"])
        Thread.sleep(forTimeInterval: 3)

        func field(_ i: Int) -> XCUIElement {
            app.textFields.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Balance \(i)")).firstMatch
        }
        func chip(_ i: Int) -> XCUIElement {
            app.buttons.matching(
                NSPredicate(format: "label == %@", "Balance \(i)")).firstMatch
        }
        func allFields() -> [String] {
            app.textFields.allElementsBoundByIndex.map {
                "\($0.label)=\(String(describing: $0.value))"
            }
        }

        let f1 = field(1)
        XCTAssertTrue(f1.waitForExistence(timeout: 20), "配列の 1 番の欄が無い")
        print("PROBE array fields at start = \(allFields())")

        // 3 番へ切り替える。
        let c3 = chip(3)
        XCTAssertTrue(c3.waitForExistence(timeout: 10), "要素を選ぶ札が無い")
        c3.tap()
        Thread.sleep(forTimeInterval: 1.5)
        print("PROBE array fields after chip3 = \(allFields())")

        let f3 = field(3)
        XCTAssertTrue(f3.exists, "3 番を選んでも欄の名前が変わらない")

        f3.tap()
        Thread.sleep(forTimeInterval: 1.2)
        print("PROBE step tap        -> \(String(describing: field(3).value))")

        for k in 0..<3 {
            f3.typeText(XCUIKeyboardKey.delete.rawValue)
            Thread.sleep(forTimeInterval: 0.6)
            print("PROBE step delete \(k)   -> \(String(describing: field(3).value))")
        }
        f3.typeText("5")
        Thread.sleep(forTimeInterval: 0.8)
        print("PROBE step type 5     -> \(String(describing: field(3).value))")
        f3.typeText("5")
        Thread.sleep(forTimeInterval: 0.8)
        print("PROBE step type 55    -> \(String(describing: field(3).value))")
        f3.typeText("\n")
        Thread.sleep(forTimeInterval: 2.0)
        print("PROBE step submit     -> \(String(describing: field(3).value))")
        print("PROBE array fields after submit = \(allFields())")

        XCTAssertEqual(Float((field(3).value as? String) ?? "") ?? -999, 55, accuracy: 0.5,
                       "3 番に 55 と打ったのに別の値が入る")

        // 1 番へ戻して、巻き添えになっていないこと。
        chip(1).tap()
        Thread.sleep(forTimeInterval: 1.5)
        print("PROBE array f1 after=\(String(describing: field(1).value))")
        XCTAssertEqual(Float((field(1).value as? String) ?? "") ?? -999, 0, accuracy: 0.5,
                       "3 番へ打ったら 1 番まで変わった")

        // 3 番が残っていること。
        chip(3).tap()
        Thread.sleep(forTimeInterval: 1.5)
        print("PROBE array f3 back=\(String(describing: field(3).value))")
        XCTAssertEqual(Float((field(3).value as? String) ?? "") ?? -999, 55, accuracy: 0.5,
                       "戻ってくると 3 番の値が変わっている")
    }

    // MARK: - 4b. Section の入切（gated）

    /// 期待: Section を切ると配下は鎖に残ったまま gated へ回る。
    ///       types= は動かず、active が減って gated が増える。
    func test19SectionGate() {
        let app = launch(["-ETSeed", "SectionPlugin,VolumePlugin,CompressorPlugin"])
        Thread.sleep(forTimeInterval: 3)

        // Section の電源。名前が空なら読み上げは "Section"。
        let gate = app.switches["Section"]
        print("PROBE section switch exists=\(gate.exists) "
              + "all=\(app.switches.allElementsBoundByIndex.map(\.label))")
        XCTAssertTrue(gate.waitForExistence(timeout: 15), "Section の電源が無い")
        gate.tap()
        Thread.sleep(forTimeInterval: 2.5)

        // 配下が画面から消えていないこと（畳んだのではなく切っただけ）。
        XCTAssertTrue(app.switches["Volume"].exists, "Section を切ったら配下が画面から消えた")
        XCTAssertTrue(app.switches["Compressor"].exists, "Section を切ったら配下が画面から消えた")

        // カードに gated の札が出るか。
        let badges = app.staticTexts.allElementsBoundByIndex.compactMap {
            $0.label.contains("gated") ? $0.label : nil
        }
        print("PROBE gated badges=\(badges)")
        XCTAssertGreaterThan(badges.count, 0, "止まっている段に印が出ない")

        // 畳むと配下の行が消えること（PipelineView の rows）。
        let collapse = app.buttons["Collapse section"].firstMatch
        print("PROBE collapse exists=\(collapse.exists)")
        XCTAssertTrue(collapse.waitForExistence(timeout: 10), "Section を畳むボタンが無い")
        collapse.tap()
        Thread.sleep(forTimeInterval: 2.5)
        print("PROBE after collapse volume=\(app.switches["Volume"].exists) "
              + "comp=\(app.switches["Compressor"].exists)")
        XCTAssertFalse(app.switches["Volume"].exists, "Section を畳んでも配下が残る")
    }

    // MARK: - 3c. 数値欄に 1 桁だけ打つ

    /// 欄の中の字がどう扱われるかを、1 桁だけ打って見る。
    /// 欄の読み上げ値は **確定した値**（ParameterRow.swift の
    /// .accessibilityValue(displayValue)）なので、打っている途中は見えない。
    /// 既定 0 の欄に "7" を 1 文字だけ打って確定したとき:
    ///   7  → 既にある字が消えてから入る（または末尾に付いて "07"）
    ///   70 → 既にある "0" の**前**へ入った（"70"）
    func test20SingleDigitIntoField() {

        /// 掴めるまで押す。キーボードが出ていれば掴めている。
        func focus(_ app: XCUIApplication, _ e: XCUIElement, _ tag: String) -> Bool {
            for attempt in 0..<4 {
                e.tap()
                Thread.sleep(forTimeInterval: 1.8)
                if app.keyboards.count > 0 {
                    print("PROBE[\(tag)] focused attempt=\(attempt)")
                    return true
                }
                print("PROBE[\(tag)] キーボードが出ない attempt=\(attempt)")
            }
            return false
        }

        // (A) Multiband Balance（配列・整数・既定 0・範囲 -100..100）
        let app = launch(["-ETSeed", "MultibandBalancePlugin"])
        Thread.sleep(forTimeInterval: 3)

        func balance() -> XCUIElement {
            app.textFields.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Balance 1")).firstMatch
        }

        let b = balance()
        XCTAssertTrue(b.waitForExistence(timeout: 20), "Balance の欄が無い")
        print("PROBE frame balance=\(b.frame) value=\(String(describing: b.value))")

        XCTAssertTrue(focus(app, b, "balance-1digit"), "Balance の欄を掴めない")
        b.typeText("7")
        Thread.sleep(forTimeInterval: 0.8)
        b.typeText("\n")
        Thread.sleep(forTimeInterval: 2.0)
        print("PROBE balance 既定 0 に 7 を 1 桁だけ -> \(String(describing: balance().value))")

        // 消してから 2 桁。
        let b2 = balance()
        XCTAssertTrue(focus(app, b2, "balance-42"), "Balance の欄を掴めない（2 回目）")
        for _ in 0..<6 { b2.typeText(XCUIKeyboardKey.delete.rawValue) }
        b2.typeText("42")
        Thread.sleep(forTimeInterval: 0.8)
        b2.typeText("\n")
        Thread.sleep(forTimeInterval: 2.0)
        print("PROBE balance 消してから 42 -> \(String(describing: balance().value))")

        // (B) Volume（配列でない・小数・既定 0・範囲 -60..24）
        let v = XCUIApplication()
        v.launchArguments = ["-ETSeed", "VolumePlugin"]
        v.launch()
        XCTAssertTrue(v.navigationBars.buttons["Add Effect"].waitForExistence(timeout: 60),
                      "Volume の画面が出ない")
        Thread.sleep(forTimeInterval: 3)

        let vf = v.textFields["Volume (dB)"]
        XCTAssertTrue(vf.waitForExistence(timeout: 20), "Volume の欄が無い")
        print("PROBE frame volume=\(vf.frame) value=\(String(describing: vf.value))")

        XCTAssertTrue(focus(v, vf, "volume-1digit"), "Volume の欄を掴めない")
        vf.typeText("7")
        Thread.sleep(forTimeInterval: 0.8)
        vf.typeText("\n")
        Thread.sleep(forTimeInterval: 2.0)
        print("PROBE volume 既定 0.00 に 7 を 1 桁だけ -> \(String(describing: v.textFields["Volume (dB)"].value))")
    }

    // MARK: - 9b. Settings の Toggle と Stepper だけを、ゆっくり

    /// 期待: Keep the screen on を押すと入切が変わる。
    ///       Silence threshold の Stepper で dB が動く。
    func test21SettingsToggleAndStepper() {
        let app = launch(["-ETSeed", "LevelMeterPlugin"])
        Thread.sleep(forTimeInterval: 3)

        app.buttons["moreMenu"].tap()
        Thread.sleep(forTimeInterval: 1.5)
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 20),
                      "Settings が開かない")
        Thread.sleep(forTimeInterval: 3)

        // --- Keep the screen on ---
        // 一覧の下の方にある。出るまで払う。
        let keep = app.switches["Keep the screen on"]
        var up = 0
        while up < 10 && !(keep.exists && keep.isHittable) {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.7)
            up += 1
        }
        print("PROBE keep reveal tries=" + String(up) + " exists=" + String(keep.exists))
        XCTAssertTrue(keep.exists, "Keep the screen on が無い")
        let v0 = keep.value as? String
        print("PROBE keep frame=\(keep.frame) hittable=\(keep.isHittable) v0=\(String(describing: v0))")

        // (1) 要素の真ん中を叩く。
        keep.tap()
        Thread.sleep(forTimeInterval: 3)
        let v1 = app.switches["Keep the screen on"].value as? String
        print("PROBE keep after center tap = \(String(describing: v1))")

        // (2) 変わらなければ、右端のつまみを叩く。
        var v2 = v1
        if v1 == v0 {
            let f = keep.frame
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: f.maxX - 30, dy: f.midY)).tap()
            Thread.sleep(forTimeInterval: 3)
            v2 = app.switches["Keep the screen on"].value as? String
            print("PROBE keep after switch tap = \(String(describing: v2))")
        }
        XCTAssertNotEqual(v2, v0, "Keep the screen on が切り替わらない")

        // --- Silence threshold ---
        // 整数 dB の行だけを見る（生の測定値は小数なので混ざらない）。
        let db = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES %@", "^-?[0-9]+ dB$")).firstMatch
        XCTAssertTrue(db.waitForExistence(timeout: 10), "Silence threshold の値が無い")
        let d0 = db.label
        let stepper = app.steppers.firstMatch
        XCTAssertTrue(stepper.exists, "Stepper が無い")
        print("PROBE stepper buttons=\(stepper.buttons.allElementsBoundByIndex.map(\.label)) d0=\(d0)")
        stepper.buttons.element(boundBy: 1).tap()
        Thread.sleep(forTimeInterval: 2)
        let d1 = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES %@", "^-?[0-9]+ dB$")).firstMatch.label
        print("PROBE stepper up   \(d0) -> \(d1)")
        XCTAssertNotEqual(d0, d1, "Stepper の + で動かない")

        stepper.buttons.element(boundBy: 0).tap()
        Thread.sleep(forTimeInterval: 2)
        let d2 = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES %@", "^-?[0-9]+ dB$")).firstMatch.label
        print("PROBE stepper down \(d1) -> \(d2)")
        XCTAssertEqual(d2, d0, "Stepper の - で戻らない")
    }
}
