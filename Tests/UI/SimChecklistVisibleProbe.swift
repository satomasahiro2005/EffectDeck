//  SimChecklistVisibleProbe.swift
//  確認リストのうち、2 列の iPad で同じラベルがいくつものカードに並ぶ項目を叩く。
//
//  書式は SimChecklistProbe の手順と同じ（1 行 1 手、置き場は SIMCHECK_STEPS）。
//  足したのは**画面に出ているものだけから選ぶ**手。2 列ではカードが全部開いていて、
//  「Log (HQ) frequency scale」や「Full Screen」が複数のカードに居る。上から n 番目を
//  数えると画面の外の要素まで数えてしまい、押すと Not hittable で落ちる。
//  左の一覧（tapxy）でカードへ飛んでから、見えている中で数える。
//
//  判定はここで決め切らない。撮った絵と SIMCHECK-VALUE の行で決める（SimChecklistProbe と同じ）。

import XCTest
import UIKit

final class SimChecklistVisibleProbe: XCTestCase {

    private var shotDir: String {
        ProcessInfo.processInfo.environment["SIMCHECK_SHOTS"]
            ?? "/Users/satoumasahiro/work/b38shots"
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

    /// "Label#2" を ("Label", 2) に分ける。# が無ければ 0 番。
    private func labelAndIndex(_ arg: String) -> (String, Int) {
        guard let h = arg.lastIndex(of: "#"), let n = Int(arg[arg.index(after: h)...]) else {
            return (arg, 0)
        }
        return (String(arg[..<h]), n)
    }

    /// 画面に出ている要素だけを、上から（同じ高さなら左から）並べる。
    /// 完全一致が無いときだけ前方一致に落とす。
    ///
    /// **isHittable では選ばない。**カードの中の SwiftUI の部品は、見えていて押せるのに
    /// isHittable が偽を返す（SimChecklistProbe の find が「無ければ exists だけで押す」に
    /// 落ちているのはそのため）。枠の中心が窓の中、ナビゲーションバーより下にあるかで見る。
    private func visible(_ app: XCUIApplication, _ label: String,
                         type: XCUIElement.ElementType = .any,
                         below top: CGFloat = 80) -> [XCUIElement] {
        let q = app.descendants(matching: type)
        let screen = app.windows.firstMatch.exists ? app.windows.firstMatch.frame
                                                   : CGRect(x: 0, y: 0, width: 1032, height: 1376)
        func onScreen(_ e: XCUIElement) -> Bool {
            let f = e.frame
            return e.exists && !f.isEmpty && f.midY > top && f.midY < screen.maxY
                && f.midX > 0 && f.midX < screen.maxX
        }
        func hits(_ p: NSPredicate) -> [XCUIElement] {
            q.matching(p).allElementsBoundByIndex.filter(onScreen)
        }
        // 入力欄は題を持たず placeholder だけのものがある（Presets の Preset name）。
        var m = hits(NSPredicate(format: "label == %@ OR identifier == %@ OR placeholderValue == %@",
                                 label, label, label))
        if m.isEmpty { m = hits(NSPredicate(format: "label BEGINSWITH %@", label)) }
        return m.sorted {
            $0.frame.minY != $1.frame.minY ? $0.frame.minY < $1.frame.minY
                                           : $0.frame.minX < $1.frame.minX
        }
    }

    private func point(_ app: XCUIApplication, _ x: Double, _ y: Double) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }

    /// 手順のファイルを読んで叩く。SimChecklistProbe の手に加えて:
    ///
    ///   tapvis:Label#n          見えているもののうち上から n 番目を押す
    ///   rightvis:Label#n        見えている Switch の右の端を押す（行ぜんぶが 1 つの Toggle）
    ///   fieldvis:Label#n        見えている入力欄の右の端を押す（カーソルを末尾へ）
    ///   value:Label             見えている同名の要素の value を SIMCHECK-VALUE で出す
    ///   hold:x,y,sec            その点を押し続ける（図に触る音の確かめ）
    ///   dragxy:x1,y1,x2,y2,p,h  p 秒押してからゆっくり運び、h 秒止めてから離す
    ///   mark:text               ホスト側の連写の合図に SIMCHECK-MARK を出す
    func testSteps() throws {
        let path = ProcessInfo.processInfo.environment["SIMCHECK_STEPS"]
            ?? (shotDir + "/steps.txt")
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var app = XCUIApplication()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // 貼り付けの許可は割り込みとして来る（SimChecklistProbe と同じ扱い）。
        addUIInterruptionMonitor(withDescription: "paste") { alert in
            let names = alert.buttons.allElementsBoundByIndex.map(\.label)
            print("SIMCHECK-INTERRUPT label=\(alert.label) buttons=\(names)")
            for want in ["Allow Paste", "ペーストを許可", "Allow", "許可", "OK"]
            where alert.buttons[want].exists {
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
            let nums = arg.split(separator: ",").compactMap { Double($0) }
            switch cmd {
            case "launch":
                app = XCUIApplication()
                app.launchArguments = arg.split(separator: "|").map(String.init)
                app.launch()
            case "activate":
                app = XCUIApplication()
                app.activate()
            case "home":
                // 殺さずに裏へ回す。共有シートの Copy は約束（Promised）で、中身を出すのは
                // このアプリなので、launch で殺すと貼り板が空になる。戻ると didBecomeActive で
                // 貼り板の札（ClipboardBanner）が見直される。
                XCUIDevice.shared.press(.home)
            case "app":
                app = XCUIApplication(bundleIdentifier: arg)
                app.activate()
            case "tap":
                // 見えているもののうち押せると言うものを先に（シートの下の同名を避ける）。
                // 無ければ SpringBoard（共有シートなど）を探す。
                // ツールバーの Presets などはナビゲーションバーの高さに居るので、上端で切らない。
                let seen = visible(app, arg, below: 0)
                if let e = seen.first(where: \.isHittable) ?? seen.first {
                    e.tap()
                } else if let e = visible(springboard, arg, below: 0).first {
                    e.tap()
                } else {
                    print("SIMCHECK-MISS \(line)")
                }
            case "tapvis", "rightvis", "fieldvis":
                let (label, nth) = labelAndIndex(arg)
                let type: XCUIElement.ElementType =
                    cmd == "rightvis" ? .switch : cmd == "fieldvis" ? .textField : .any
                let m = visible(app, label, type: type)
                guard nth < m.count else {
                    print("SIMCHECK-MISS \(line) count=\(m.count)"); continue
                }
                switch cmd {
                case "rightvis":
                    m[nth].coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
                case "fieldvis":
                    m[nth].coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
                default:
                    m[nth].tap()
                }
            case "press":
                // press:Label#n  見えているもののうち n 番目を長押しする（Files の項目のメニュー）。
                let (label, nth) = labelAndIndex(arg)
                let m = visible(app, label, below: 0)
                guard nth < m.count else {
                    print("SIMCHECK-MISS \(line) count=\(m.count)"); continue
                }
                m[nth].press(forDuration: 1.2)
            case "togglevis":
                // 行ぜんぶの Switch（ラベル付き・幅いっぱい）を座標で押しても切り替わらない。
                // 同じ高さに居る小さい Switch（本物の UISwitch）を要素として押す。
                let (label, nth) = labelAndIndex(arg)
                let rows = visible(app, label, type: .switch)
                guard nth < rows.count else {
                    print("SIMCHECK-MISS \(line) count=\(rows.count)"); continue
                }
                let y = rows[nth].frame.midY
                let knobs = app.switches.allElementsBoundByIndex.filter {
                    $0.exists && $0.frame.width < 120 && abs($0.frame.midY - y) < 20
                }
                if let k = knobs.first {
                    k.tap()
                    Thread.sleep(forTimeInterval: 0.8)
                    print("SIMCHECK-VALUE \(label) after=\(String(describing: k.value))")
                } else {
                    print("SIMCHECK-MISS \(line) knob")
                }
            case "value":
                for (k, e) in visible(app, arg).enumerated() {
                    print("SIMCHECK-VALUE \(arg)#\(k) type=\(e.elementType.rawValue) "
                          + "frame=\(e.frame) value=\(String(describing: e.value))")
                }
            case "tapxy":
                point(app, nums[0], nums[1]).tap()
            case "hold":
                print("SIMCHECK-HOLD \(arg)")
                point(app, nums[0], nums[1]).press(forDuration: nums[2])
            case "dragxy":
                let a = point(app, nums[0], nums[1])
                let b = point(app, nums[2], nums[3])
                a.press(forDuration: nums.count > 4 ? nums[4] : 0.5, thenDragTo: b,
                        withVelocity: .slow,
                        thenHoldForDuration: nums.count > 5 ? nums[5] : 0.5)
            case "swipe":
                point(app, nums[0], nums[1]).press(forDuration: 0.05,
                                                   thenDragTo: point(app, nums[2], nums[3]))
            case "type":
                app.typeText(arg)
            case "return":
                // キーボードの確定（.onSubmit）。外を押して確定するのとは別の道。
                app.typeText("\n")
            case "clear":
                app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue,
                                    count: Int(arg) ?? 12))
            case "sleep":
                Thread.sleep(forTimeInterval: Double(arg) ?? 1)
            case "snap":
                snap(arg)
            case "tree":
                dumpTree(app, arg)
            case "mark":
                print("SIMCHECK-MARK \(arg)")
            case "pb":
                UIPasteboard.general.string = arg
            default:
                print("SIMCHECK-UNKNOWN \(line)")
            }
        }
    }
}
