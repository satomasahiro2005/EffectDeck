//  SimChecklistGestureProbe.swift
//  確認リストのうち、ラベルの付いた部品の上で払う・長押しで運ぶ・押し続ける項目を叩く。
//
//  書式は SimChecklistVisibleProbe の手順と同じ（1 行 1 手、置き場は SIMCHECK_STEPS）。
//  足したのは**座標ではなく部品を起点にした手**。Plugins の見本の行を左へ払う、
//  1 列の鎖で AU のカードを長押しで運ぶ、のように、先に木を取って座標を拾わないと
//  打てなかった手を 1 回で打てるようにする。
//
//  部品の引き方は SimChecklistVisibleProbe と同じ（画面に出ているものだけ、上から、
//  完全一致が無ければ前方一致）。ラベルに , が入るもの（"EffectDeck DSP Filter + Drive"
//  の行の字など）があるので、ラベルと数の区切りは | にする。
//
//  判定はここで決め切らない。撮った絵と SIMCHECK-VALUE / SIMCHECK-LABEL の行で決める。
//  運んでいる最中・押している最中の絵はホスト側で撮る（SIMCHECK-MARK / SIMCHECK-HOLD の行に時刻を出す）。

import XCTest
import UIKit

final class SimChecklistGestureProbe: XCTestCase {

    private var shotDir: String {
        ProcessInfo.processInfo.environment["SIMCHECK_SHOTS"]
            ?? "/Users/satoumasahiro/work/b57shots"
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

    /// "Label#n|a,b,c|d" を (Label, n, [[a,b,c],[d]]) に分ける。
    private func parts(_ arg: String) -> (String, Int, [[Double]]) {
        let pieces = arg.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let (label, nth) = labelAndIndex(pieces.first ?? "")
        let numbers = pieces.dropFirst().map { $0.split(separator: ",").compactMap { Double($0) } }
        return (label, nth, Array(numbers))
    }

    /// 画面に出ている要素だけを、上から（同じ高さなら左から）並べる。
    /// SimChecklistVisibleProbe の visible と同じ引き方（isHittable では選ばない）。
    private func visible(_ app: XCUIApplication, _ label: String,
                         type: XCUIElement.ElementType = .any,
                         below top: CGFloat = 0) -> [XCUIElement] {
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
        var m = hits(NSPredicate(format: "label == %@ OR identifier == %@ OR placeholderValue == %@",
                                 label, label, label))
        if m.isEmpty { m = hits(NSPredicate(format: "label BEGINSWITH %@", label)) }
        return m.sorted {
            $0.frame.minY != $1.frame.minY ? $0.frame.minY < $1.frame.minY
                                           : $0.frame.minX < $1.frame.minX
        }
    }

    /// いまの時刻（1970 年からの秒）。シミュレータの時計は Mac と同じなので、
    /// ホストで撮った動画（simctl io recordVideo）のどこを見ればよいかがこれで決まる。
    private static var now: String { String(format: "%.3f", Date().timeIntervalSince1970) }

    private func point(_ app: XCUIApplication, _ x: Double, _ y: Double) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }

    /// 部品の中の点（0...1 の割合）。部品の座標はアプリの窓で測ったものなので、
    /// アプリの原点から足して打つ（シートの中の部品でも同じ）。
    private func point(_ app: XCUIApplication, in e: XCUIElement, _ fx: Double, _ fy: Double) -> XCUICoordinate {
        let f = e.frame
        return point(app, Double(f.minX) + Double(f.width) * fx, Double(f.minY) + Double(f.height) * fy)
    }

    /// 手順のファイルを読んで叩く。SimChecklistVisibleProbe の手に加えて:
    ///
    ///   swipeel:Label#n|dx,dy             その部品の中心から (dx,dy) だけすぐ払う
    ///   dragel:Label#n|dx,dy,p,h          中心を p 秒押してからゆっくり運び、h 秒止めて離す
    ///   holdel:Label#n|sec|fx,fy          部品の (fx,fy) の点を sec 秒押し続ける
    ///   tapel:Label#n|fx,fy               部品の (fx,fy) の点を押す（行の右端のボタンなど）
    ///   tapbelow:見出しの字|押すもの       見出しより下で一番近い同名の部品を押す
    ///   tapnear:行の字|押すもの            同じ高さに居る部品を押す（行の … など）
    ///   labels:字                         その字を含むラベルの部品を SIMCHECK-LABEL で出す
    ///   search:字                         検索の欄を押して打つ
    ///   wait:Label|sec                    出るまで待つ（出なければ SIMCHECK-MISS）
    ///   pbfile:ホストのパス                ファイルの中身を貼り板へ
    ///   fling:x1,y1,x2,y2                 速く払って離す（流れている最中を作る）
    ///   scrollto:字                       その字が画面の 6 割より上に来るまで払う（シートの下端より上）
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
                XCUIDevice.shared.press(.home)
            case "app":
                app = XCUIApplication(bundleIdentifier: arg)
                app.activate()
            case "tap":
                let seen = visible(app, arg)
                if let e = seen.first(where: \.isHittable) ?? seen.first {
                    e.tap()
                } else if let e = visible(springboard, arg).first {
                    e.tap()
                } else {
                    print("SIMCHECK-MISS \(line)")
                }
            case "tapvis", "fieldvis":
                let (label, nth) = labelAndIndex(arg)
                let m = visible(app, label, type: cmd == "fieldvis" ? .textField : .any, below: 80)
                guard nth < m.count else {
                    print("SIMCHECK-MISS \(line) count=\(m.count)"); continue
                }
                if cmd == "fieldvis" {
                    m[nth].coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
                } else {
                    m[nth].tap()
                }
            case "press":
                let (label, nth) = labelAndIndex(arg)
                let m = visible(app, label)
                guard nth < m.count else {
                    print("SIMCHECK-MISS \(line) count=\(m.count)"); continue
                }
                m[nth].press(forDuration: 1.2)
            case "togglevis":
                // 行ぜんぶの Switch ではなく、同じ高さの小さい Switch を押す（VisibleProbe と同じ）。
                let (label, nth) = labelAndIndex(arg)
                let rows = visible(app, label, type: .switch, below: 80)
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
            case "labels":
                let all = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label CONTAINS %@", arg))
                    .allElementsBoundByIndex.filter { $0.exists }
                for e in all {
                    print("SIMCHECK-LABEL type=\(e.elementType.rawValue) frame=\(e.frame) "
                          + "label=\(e.label) value=\(String(describing: e.value))")
                }
                if all.isEmpty { print("SIMCHECK-LABEL none \(arg)") }
            case "swipeel", "dragel", "holdel", "tapel":
                let (label, nth, n) = parts(arg)
                let m = visible(app, label)
                guard nth < m.count else {
                    print("SIMCHECK-MISS \(line) count=\(m.count)"); continue
                }
                let e = m[nth]
                let first = n.first ?? []
                switch cmd {
                case "swipeel":
                    let a = point(app, in: e, 0.5, 0.5)
                    a.press(forDuration: 0.05,
                            thenDragTo: a.withOffset(CGVector(dx: first.count > 0 ? first[0] : 0,
                                                              dy: first.count > 1 ? first[1] : 0)))
                case "dragel":
                    let a = point(app, in: e, 0.5, 0.5)
                    let b = a.withOffset(CGVector(dx: first.count > 0 ? first[0] : 0,
                                                  dy: first.count > 1 ? first[1] : 0))
                    print("SIMCHECK-MARK drag-\(label) t=\(Self.now)")
                    a.press(forDuration: first.count > 2 ? first[2] : 1.0, thenDragTo: b,
                            withVelocity: .slow,
                            thenHoldForDuration: first.count > 3 ? first[3] : 1.5)
                case "holdel":
                    let sec = first.first ?? 2
                    let at = n.count > 1 && n[1].count > 1 ? n[1] : [0.5, 0.5]
                    print("SIMCHECK-HOLD \(label) \(sec) t=\(Self.now)")
                    point(app, in: e, at[0], at[1]).press(forDuration: sec)
                default:
                    let at = first.count > 1 ? first : [0.5, 0.5]
                    point(app, in: e, at[0], at[1]).tap()
                }
            case "tapbelow", "tapnear":
                let pair = arg.split(separator: "|").map(String.init)
                guard pair.count == 2, let anchor = visible(app, pair[0]).first else {
                    print("SIMCHECK-MISS \(line)"); continue
                }
                let a = anchor.frame
                let cands = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label == %@ OR identifier == %@", pair[1], pair[1]))
                    .allElementsBoundByIndex.filter { $0.exists && !$0.frame.isEmpty }
                let pick: XCUIElement?
                if cmd == "tapbelow" {
                    pick = cands.filter { $0.frame.minY >= a.midY && $0.frame.minY - a.maxY < 120 }
                        .min { ($0.frame.minY - a.maxY) < ($1.frame.minY - a.maxY) }
                } else {
                    pick = cands.filter { abs($0.frame.midY - a.midY) < 40 }
                        .min { abs($0.frame.midY - a.midY) < abs($1.frame.midY - a.midY) }
                }
                if let pick { pick.tap() } else { print("SIMCHECK-MISS \(line) cands=\(cands.count)") }
            case "search":
                let field = app.searchFields.firstMatch
                if field.waitForExistence(timeout: 5) {
                    field.tap()
                    Thread.sleep(forTimeInterval: 0.6)
                    app.typeText(arg)
                } else {
                    print("SIMCHECK-MISS \(line)")
                }
            case "wait":
                let pair = arg.split(separator: "|").map(String.init)
                let e = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", pair[0], pair[0]))
                    .firstMatch
                if !e.waitForExistence(timeout: pair.count > 1 ? Double(pair[1]) ?? 10 : 10) {
                    print("SIMCHECK-MISS \(line)")
                }
            case "scrollto":
                // その字が画面の高さの 6 割より上に来るまで、画面の中ほどを上へ払う（最大 10 回）。
                // 2 列の iPad ではシート（Presets など）が中ほどに居るので、払うのはシートになる。
                let screen = app.windows.firstMatch.frame
                var tries = 0
                while tries < 10 {
                    if let e = visible(app, arg).first, e.frame.midY < screen.maxY * 0.6 { break }
                    // 払う所はシートの中に収める（2 列ではシートの下端が 0.7 あたり）。
                    point(app, Double(screen.midX), Double(screen.maxY) * 0.6)
                        .press(forDuration: 0.05,
                               thenDragTo: point(app, Double(screen.midX), Double(screen.maxY) * 0.35))
                    Thread.sleep(forTimeInterval: 0.6)
                    tries += 1
                }
                if tries == 10 { print("SIMCHECK-MISS \(line)") }
            case "tapxy":
                point(app, nums[0], nums[1]).tap()
            case "hold":
                print("SIMCHECK-HOLD \(arg) t=\(Self.now)")
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
            case "fling":
                // 速く払って指を止めずに離す（SimChecklistFlingProbe と同じ速さ）。慣性で流れ続ける。
                point(app, nums[0], nums[1]).press(forDuration: 0.02,
                                                   thenDragTo: point(app, nums[2], nums[3]),
                                                   withVelocity: XCUIGestureVelocity(rawValue: 8000),
                                                   thenHoldForDuration: 0)
            case "type":
                app.typeText(arg)
            case "return":
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
                print("SIMCHECK-MARK \(arg) t=\(Self.now)")
            case "pb":
                UIPasteboard.general.string = arg
            case "pbfile":
                UIPasteboard.general.string = try String(contentsOfFile: arg, encoding: .utf8)
            case "open":
                if let url = URL(string: arg) { XCUIDevice.shared.system.open(url) }
            default:
                print("SIMCHECK-UNKNOWN \(line)")
            }
        }
    }
}
