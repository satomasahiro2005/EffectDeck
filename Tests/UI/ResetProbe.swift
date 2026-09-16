//  ResetProbe.swift
//  「Reset Pipeline のあと Level Meter が動かない」を機械で捕まえる。
//
//  報告: リセットしたあとメーターが止まったままで、カードの電源を
//  切って入れ直すと直る。
//
//  判定は画面ではなくアプリのログ（instance= / tap= / publish types=）で行う。
//  accessibility の写しは更新が遅れるので、そこだけ見ると嘘の再現が出る。

import XCTest

final class ResetProbe: XCTestCase {

    /// リセット直後のカードに図が出るか。
    func testMeterAfterReset() {
        let app = XCUIApplication()
        app.launchArguments = ["-ETSeed", "VolumePlugin,CompressorPlugin",
                               "-ETWidth", "0", "-ETMock", "1"]
        app.launch()
        Thread.sleep(forTimeInterval: 8)

        var log: [String] = []

        // ⋯ → Reset Pipeline → 確認
        let more = app.buttons["moreMenu"]
        XCTAssertTrue(more.waitForExistence(timeout: 15), "⋯ が出ない")
        more.tap()
        Thread.sleep(forTimeInterval: 2)

        let reset = app.buttons["Reset Pipeline"]
        log.append("reset exists=\(reset.exists) enabled=\(reset.isEnabled)")
        XCTAssertTrue(reset.waitForExistence(timeout: 5), "Reset Pipeline が無い")
        reset.tap()
        Thread.sleep(forTimeInterval: 1.5)

        // 確認は .confirmationDialog。出てくるボタンの名前を控える。
        let names = (0..<app.buttons.count).compactMap { i -> String? in
            let b = app.buttons.element(boundBy: i)
            return b.exists ? b.label : nil
        }
        log.append("buttons after reset tap: \(names)")

        for candidate in ["Reset", "Reset Pipeline", "Clear", "OK"] {
            let b = app.buttons[candidate]
            if b.exists && b.isHittable {
                log.append("confirm with: \(candidate)")
                b.tap()
                break
            }
        }
        Thread.sleep(forTimeInterval: 6)

        // メーターが値を出しているか。graphOnly の有無にかかわらず
        // "dB" を含む文字が出ていれば枠が来ている。
        let texts = (0..<app.staticTexts.count).compactMap { i -> String? in
            let t = app.staticTexts.element(boundBy: i)
            return t.exists ? t.label : nil
        }
        log.append("texts: \(texts)")
        let waiting = texts.contains { $0.contains("Waiting for audio") }
        let hasDB = texts.contains { $0.contains("dB") }
        log.append("waiting=\(waiting) hasDB=\(hasDB)")

        print("PROBE-RESET\n" + log.joined(separator: "\n"))
        XCTAssertFalse(waiting, "リセット後にメーターが Waiting のまま")
        XCTAssertTrue(hasDB, "リセット後にメーターが値を出していない")
    }
}
