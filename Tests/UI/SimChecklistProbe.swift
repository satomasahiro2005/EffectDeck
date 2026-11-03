//  SimChecklistProbe.swift
//  確認リストのうち、シミュレータでタップやドラッグが要る項目を機械で叩く。
//
//  判定はここで決め切らない。**画面を撮って残し、人（か読む側）が絵で決める。**
//  撮った絵はテストランナーからホストの置き場（SIMCHECK_SHOTS、既定は ~/work/b0shots）へ
//  書く。シミュレータのプロセスはホストのパスへ書ける。
//
//  端末は iPad Pro 13-inch (M5) の 2 列（左に一覧、右に全部開いたカード）を前提にする。

import XCTest
import UIKit

final class SimChecklistProbe: XCTestCase {

    // MARK: - 道具

    private var shotDir: String {
        ProcessInfo.processInfo.environment["SIMCHECK_SHOTS"]
            ?? "/Users/satoumasahiro/work/b0shots"
    }

    private func snap(_ name: String) {
        let img = XCUIScreen.main.screenshot()
        let url = URL(fileURLWithPath: shotDir).appendingPathComponent("ui-\(name).png")
        try? img.pngRepresentation.write(to: url)
        print("SIMCHECK-SNAP \(url.path)")
    }

    private func dumpTree(_ app: XCUIApplication, _ name: String) {
        let url = URL(fileURLWithPath: shotDir).appendingPathComponent("tree-\(name).txt")
        try? app.debugDescription.write(to: url, atomically: true, encoding: .utf8)
        print("SIMCHECK-TREE \(url.path)")
    }

    @discardableResult
    private func launch(_ args: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = args
        app.launch()
        return app
    }

    /// 木を見るだけ。起動の引数は SIMCHECK_ARGS（| 区切り）で渡す。
    func test00Dump() {
        let raw = ProcessInfo.processInfo.environment["SIMCHECK_ARGS"] ?? "-ETSeed|none"
        let app = launch(raw.split(separator: "|").map(String.init))
        Thread.sleep(forTimeInterval: 8)
        snap("dump")
        dumpTree(app, "dump")
    }

    // MARK: - 手順を読んで叩く

    /// ラベルで要素を引く。完全一致を先に、無ければ前方一致。画面に出ているものを優先する。
    private func find(_ app: XCUIApplication, _ label: String,
                      in query: XCUIElementQuery? = nil) -> XCUIElement? {
        let q = query ?? app.descendants(matching: .any)
        for pred in [NSPredicate(format: "label == %@", label),
                     NSPredicate(format: "identifier == %@", label),
                     NSPredicate(format: "label BEGINSWITH %@", label)] {
            let m = q.matching(pred)
            let all = m.allElementsBoundByIndex
            if let hit = all.first(where: { $0.exists && $0.isHittable }) { return hit }
            if let any = all.first(where: { $0.exists }) { return any }
        }
        return nil
    }

    /// 手順のファイル（1 行 1 手）を読んで叩く。置き場は SIMCHECK_STEPS（既定は shotDir/steps.txt）。
    ///
    ///   launch:-ETSeed|VolumePlugin     起動し直す（引数は | 区切り）
    ///   activate                        いま出ているアプリにつなぐ（起動し直さない）
    ///   tap:Label / tapn:Label#2        ラベル（か identifier）で押す。#n は n 番目（上から）
    ///   tapright:Label                  その行の右の端を押す（Toggle）
    ///   tapxy:x,y                       画面の点を押す（pt）
    ///   type:text                       いまの入力欄へ打つ
    ///   clear                           いまの入力欄を空にする
    ///   drag:x1,y1,x2,y2,press          長押ししてから運ぶ
    ///   swipe:x1,y1,x2,y2               すぐ運ぶ（行を払う）
    ///   sleep:sec / snap:name / tree:name
    ///   allowpaste                      貼り付けの許可が出ていれば許す
    ///   open:url                        OS に URL を開かせる
    func test01Steps() throws {
        let path = ProcessInfo.processInfo.environment["SIMCHECK_STEPS"]
            ?? (shotDir + "/steps.txt")
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var app = XCUIApplication()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // **貼り付けの許可は割り込みとして来る。**既定の扱いは許さない側を押すので、
        // リンクの欄が空のまま開く（UIPasteboard を読む From Link の初期値）。
        addUIInterruptionMonitor(withDescription: "paste") { alert in
            let names = alert.buttons.allElementsBoundByIndex.map(\.label)
            print("SIMCHECK-INTERRUPT label=\(alert.label) buttons=\(names)")
            for want in ["Allow Paste", "Allow", "Continue", "OK"] where alert.buttons[want].exists {
                alert.buttons[want].tap()
                return true
            }
            return false
        }
        for rawLine in text.split(separator: "\n") {
            let line = String(rawLine)
            if line.hasPrefix("#") || line.isEmpty { continue }
            let (cmd, arg): (String, String) = {
                guard let i = line.firstIndex(of: ":") else { return (line, "") }
                return (String(line[..<i]), String(line[line.index(after: i)...]))
            }()
            print("SIMCHECK-STEP \(line)")
            switch cmd {
            case "launch":
                app = XCUIApplication()
                app.launchArguments = arg.split(separator: "|").map(String.init)
                app.launch()
            case "activate":
                app = XCUIApplication()
                app.activate()
            case "app":
                // 別のアプリ（Safari など）を叩く。以降の手はそのアプリに向く。
                app = XCUIApplication(bundleIdentifier: arg)
                app.activate()
            case "typeln":
                app.typeText(arg + "\n")
            case "tap", "tapn":
                var label = arg
                var nth = 0
                if cmd == "tapn", let h = arg.lastIndex(of: "#") {
                    label = String(arg[..<h])
                    nth = Int(arg[arg.index(after: h)...]) ?? 0
                }
                if cmd == "tapn" {
                    let m = app.descendants(matching: .any)
                        .matching(NSPredicate(format: "label == %@", label))
                        .allElementsBoundByIndex.filter { $0.exists }
                        .sorted { $0.frame.minY < $1.frame.minY }
                    guard nth < m.count else {
                        print("SIMCHECK-MISS \(line) count=\(m.count)"); continue
                    }
                    m[nth].tap()
                } else if let e = find(app, label) {
                    e.tap()
                } else if let e = find(springboard, label) {
                    e.tap()
                } else {
                    print("SIMCHECK-MISS \(line)")
                }
            case "tapnav":
                // tapnav:バーの題|ボタン  そのナビゲーションバーの中のボタンを押す。
                let parts = arg.split(separator: "|").map(String.init)
                let b = app.navigationBars[parts[0]].buttons[parts.count > 1 ? parts[1] : ""]
                if b.waitForExistence(timeout: 5) { b.tap() } else { print("SIMCHECK-MISS \(line)") }
            case "tapnear":
                // tapnear:行の字|押すもののラベル  同じ高さに居るものを押す（行の … など）。
                let parts = arg.split(separator: "|").map(String.init)
                guard parts.count == 2, let row = find(app, parts[0]) else {
                    print("SIMCHECK-MISS \(line)"); continue
                }
                let y = row.frame.midY
                let cands = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label == %@ OR identifier == %@",
                                          parts[1], parts[1]))
                    .allElementsBoundByIndex.filter { $0.exists && $0.isHittable }
                guard let hit = cands.min(by: { abs($0.frame.midY - y) < abs($1.frame.midY - y) }),
                      abs(hit.frame.midY - y) < 40 else {
                    print("SIMCHECK-MISS \(line) cands=\(cands.count)"); continue
                }
                hit.tap()
            case "tapfield":
                // 同じラベルの字と入力欄が並ぶので、入力欄だけを引く。#n で n 番目（上から）。
                var label = arg
                var nth = 0
                if let h = arg.lastIndex(of: "#") {
                    label = String(arg[..<h]); nth = Int(arg[arg.index(after: h)...]) ?? 0
                }
                let fields = app.textFields.matching(NSPredicate(format: "label == %@ OR placeholderValue == %@",
                                                                  label, label))
                    .allElementsBoundByIndex.filter { $0.exists }
                    .sorted { $0.frame.minY < $1.frame.minY }
                if nth < fields.count {
                    fields[nth].coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
                } else { print("SIMCHECK-MISS \(line)") }
            case "tapright":
                // 行の右の端を押す（SwiftUI の Toggle は行ぜんぶが 1 つの Switch になっている）。
                if let e = find(app, arg) {
                    e.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
                } else { print("SIMCHECK-MISS \(line)") }
            case "scrollto":
                // 見出しが画面の上半分に来るまで払う。
                var tries = 0
                while tries < 20 {
                    if let e = find(app, arg), e.isHittable, e.frame.midY < 600 { break }
                    app.swipeUp(velocity: .slow)
                    tries += 1
                }
            case "scrollup":
                for _ in 0..<(Int(arg) ?? 10) { app.swipeDown(velocity: .fast) }
            case "tapxy":
                let p = arg.split(separator: ",").compactMap { Double($0) }
                app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: p[0], dy: p[1])).tap()
            case "type":
                app.typeText(arg)
            case "clear":
                // いま打てる欄を空にする（tapfield が右端を押してカーソルを末尾に置いている）。
                app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue,
                                    count: Int(arg) ?? 12))
            case "drag", "swipe":
                let p = arg.split(separator: ",").compactMap { Double($0) }
                let origin = app.coordinate(withNormalizedOffset: .zero)
                let a = origin.withOffset(CGVector(dx: p[0], dy: p[1]))
                let b = origin.withOffset(CGVector(dx: p[2], dy: p[3]))
                if cmd == "drag" {
                    a.press(forDuration: p.count > 4 ? p[4] : 1.2, thenDragTo: b,
                            withVelocity: .slow, thenHoldForDuration: 0.8)
                } else {
                    a.press(forDuration: 0.05, thenDragTo: b)
                }
            case "sleep":
                Thread.sleep(forTimeInterval: Double(arg) ?? 1)
            case "snap":
                snap(arg)
            case "tree":
                dumpTree(app, arg)
            case "allowpaste":
                // 貼り付けの許可は、アプリの中に出ることも SpringBoard に出ることもある。
                let inApp = app.buttons["Allow Paste"]
                let onBoard = springboard.buttons["Allow Paste"]
                if inApp.waitForExistence(timeout: 3) { inApp.tap() }
                else if onBoard.waitForExistence(timeout: 1) { onBoard.tap() }
                else { print("SIMCHECK-NOPROMPT allowpaste") }
            case "pb":
                UIPasteboard.general.string = arg
            case "pbfile":
                // ホストのファイルの中身を貼り板へ（長い字を打たずに済ませる）。
                UIPasteboard.general.string = try String(contentsOfFile: arg, encoding: .utf8)
            case "open":
                if let url = URL(string: arg) { XCUIDevice.shared.system.open(url) }
            default:
                print("SIMCHECK-UNKNOWN \(line)")
            }
        }
    }
}
