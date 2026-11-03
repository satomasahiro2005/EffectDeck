//  AccessibilityAudit.swift
//  主要な画面に XCUIApplication.performAccessibilityAudit をかける。
//
//  **全部を落とす印にはしない。**監査は画面の外の事情（シミュレータの描画、システムの部品）でも
//  指摘を出すので、見つけたものはすべて文面にして添付し（accessibility-<画面>.txt）、
//  落とすのは「名前が無い要素」（sufficientElementDescription）だけにしている。
//  スライダーや数値欄に名前が無い、という VoiceOver で一番困る壊れ方を再発させないための線。
//  ほかの種類（contrast・hitRegion・dynamicType・textClipped・trait など）は添付で読む。
//
//  落とす種類は環境変数 ET_A11Y_STRICT（カンマ区切り。all / none も可）で変えられる。
//  例: ET_A11Y_STRICT=sufficientElementDescription,hitRegion
//
//  **長い一覧の画面（Picker・Settings・Presets）は、落とす種類だけで監査する。**
//  全種類（contrast・hitRegion・dynamicType…）は要素ごとに当たり判定や色を調べるので、行が増えると
//  XCTest の内側の時間切れ（Code=-56）に当たる。実際に本文の字を大きくして行が縦に伸びた回から、
//  Picker と Settings が 2 回とも切れて落ちた。落とす種類だけなら要素の名前を読むだけで軽い。
//  どの画面でも「名前が無い要素」の検査は外さない（省くのは添付で読むだけの種類）。
//  全種類の監査が切れた画面も、落とす種類だけでやり直す（同じ重さを繰り返して 2 回切れるのを避ける）。

import XCTest

final class AccessibilityAudit: XCTestCase {

    override func setUp() {
        continueAfterFailure = true
    }

    // MARK: - 落とす種類

    private static let typeNames: [(String, XCUIAccessibilityAuditType)] = [
        ("sufficientElementDescription", .sufficientElementDescription),
        ("contrast", .contrast),
        ("dynamicType", .dynamicType),
        ("hitRegion", .hitRegion),
        ("textClipped", .textClipped),
        ("trait", .trait),
        ("elementDetection", .elementDetection),
    ]

    private var strict: XCUIAccessibilityAuditType {
        let raw = (ProcessInfo.processInfo.environment["ET_A11Y_STRICT"] ?? "sufficientElementDescription")
            .trimmingCharacters(in: .whitespaces)
        if raw == "all" { return .all }
        if raw == "none" { return [] }
        var out: XCUIAccessibilityAuditType = []
        for part in raw.split(separator: ",") {
            let key = part.trimmingCharacters(in: .whitespaces)
            if let hit = Self.typeNames.first(where: { $0.0 == key }) { out.insert(hit.1) }
        }
        return out
    }

    private func name(of type: XCUIAccessibilityAuditType) -> String {
        Self.typeNames.first(where: { $0.1 == type })?.0 ?? "type(\(type.rawValue))"
    }

    // MARK: - 監査

    /// 監査が時間切れで投げたエラーか（"Audit failed to complete in time"、Code=-56）。
    /// ドメインは確かめられていないので、番号と文面の両方で見る。
    private func isTimeout(_ error: Error) -> Bool {
        let e = error as NSError
        return e.code == -56 || e.localizedDescription.localizedCaseInsensitiveContains("complete in time")
    }

    /// 指摘された要素を 1 行にする。**CI のログで「どの要素か」が読めるようにするため。**
    /// 消えた要素に触ると XCTest が失敗を足すので、存在を確かめてから読む。
    private func describe(_ element: XCUIElement?) -> String {
        guard let element else { return "element=nil" }
        guard element.exists else { return "element=gone" }
        let f = element.frame
        return "element(id=\(element.identifier) label=\(element.label) type=\(element.elementType.rawValue) "
            + "frame=\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)))"
    }

    /// 要素の木（debugDescription）の頭。**名前も ID も無い要素（SwiftUI.AccessibilityNode）は
    /// 1 行の文面では枠しか分からず、どの view か当てられなかった。**子と祖先の並びがあれば絞れる。
    /// 長い木はログを埋めるので頭の 1500 字だけ。消えた要素に触ると失敗が足されるので、在るときだけ読む。
    private func subtree(_ element: XCUIElement?) -> String {
        guard let element, element.exists else { return "" }
        let text = element.debugDescription
        let head = text.count > 1500 ? String(text.prefix(1500)) + "…" : text
        return " | subtree:\n" + head
    }

    /// 監査の範囲。
    enum Scope {
        /// 全種類。切れたら落とす種類だけでやり直す。
        case full
        /// 落とす種類だけ。行が多く、全種類だと切れる画面向け。
        case strictOnly
    }

    /// 監査を 1 回かける。指摘は全部ここで文面にし、落とす分（strict の種類）は別に返す。
    /// ハンドラは常に true（処理した）を返す。落とすのは呼び出し側が要素つきの文面で XCTFail する
    /// （ハンドラで false を返すと、失敗の文面に要素が入らず CI のログで特定できなかった）。
    private func auditOnce(_ app: XCUIApplication, tag: String, types: XCUIAccessibilityAuditType,
                           strict: XCUIAccessibilityAuditType) throws -> (lines: [String], failures: [String]) {
        var lines: [String] = []
        var failures: [String] = []
        try app.performAccessibilityAudit(for: types) { issue in
            let kind = self.name(of: issue.auditType)
            let line = "[\(kind)] \(issue.compactDescription) | \(self.describe(issue.element)) | \(issue.detailedDescription)"
            lines.append(line)
            print("A11Y-ISSUE[\(tag)] \(line)")
            // 木を読むのは落とす分だけ。全部の指摘で読むと遅く、添付も膨らむ。
            if strict.contains(issue.auditType) { failures.append(line + self.subtree(issue.element)) }
            return true
        }
        return (lines, failures)
    }

    /// 監査をかけ、全部の指摘を添付する。落とすのは strict の種類だけ。
    ///
    /// **時間切れ（-56）は 1 回だけ取り直す。**CI の VM は遅く、1 回目は描画が落ち着く前に当たることがある。
    /// ただし取り直しは軽いほう（落とす種類だけ）にする。重い全種類が切れたのに同じものを繰り返すと、
    /// 1 画面で切れる時間が倍になるだけで、job の時間も食う。
    /// 軽いほうも切れたら、黙って飛ばさず「監査が終わらなかった」で落とす。
    private func audit(_ app: XCUIApplication, _ tag: String, scope: Scope) throws {
        let strict = self.strict
        // strict が空（ET_A11Y_STRICT=none）のときは絞る種類が無いので全種類で回す。
        let light: XCUIAccessibilityAuditType = strict.isEmpty ? .all : strict
        let plan: [(label: String, types: XCUIAccessibilityAuditType)] = scope == .full
            ? [("all", .all), ("strict-only", light)]
            : [("strict-only", light), ("strict-only", light)]
        var result: (lines: [String], failures: [String])?
        var used = ""
        var timeouts: [String] = []
        for (index, step) in plan.enumerated() {
            let started = Date()
            do {
                result = try auditOnce(app, tag: tag, types: step.types, strict: strict)
                used = step.label
                print("A11Y-AUDIT[\(tag)] mode=\(step.label) seconds=\(Int(Date().timeIntervalSince(started)))")
                break
            } catch {
                guard isTimeout(error) else { throw error }
                let spent = Int(Date().timeIntervalSince(started))
                timeouts.append("\(step.label) \(spent)s")
                print("A11Y-AUDIT[\(tag)] timeout attempt=\(index + 1) mode=\(step.label) seconds=\(spent): \(error.localizedDescription)")
            }
        }
        guard let result else {
            XCTFail("アクセシビリティ監査が 2 回とも時間切れ（Code=-56）で終わらなかった: \(tag)（\(timeouts.joined(separator: " → "))）")
            return
        }
        // 全種類で見られなかった画面は、添付の頭に書く（contrast などの指摘が無いのは「無かった」でなく「見ていない」）。
        var header = ""
        if used == "strict-only", light != .all {
            let why = scope == .strictOnly ? "長い一覧のため落とす種類だけ" : "全種類が時間切れ（\(timeouts.joined())）のため落とす種類だけ"
            header = "audited: \(why)\n"
        }
        let body = header + (result.lines.isEmpty ? "no issues" : result.lines.joined(separator: "\n"))
        print("A11Y-AUDIT[\(tag)] issues=\(result.lines.count) failing=\(result.failures.count) mode=\(used)")
        XCTContext.runActivity(named: "accessibility audit \(tag): \(result.lines.count) issues") { activity in
            let att = XCTAttachment(string: body)
            att.name = "accessibility-\(tag).txt"
            att.lifetime = .keepAlways
            activity.add(att)
        }
        for failure in result.failures {
            XCTFail("[\(tag)] \(failure)")
        }
    }

    private func run(seed: String, sheet: String? = nil, variant: A11yVariant, tag: String,
                     scope: Scope = .full) throws {
        // 動き続ける図・数字は木を毎回変え、監査が落ち着くのを待ちきれない。止めて起動する。
        let app = A11yLaunch.launch(seed: seed, sheet: sheet, variant: variant, freezeLive: true)
        defer { app.terminate() }
        try audit(app, "\(tag)-\(variant.name)", scope: scope)
    }

    // MARK: - 画面

    /// 鎖（Section・PEQ・Compressor・Reverb など）。カードの開閉、電源、数値欄。
    func testChain() throws {
        try run(seed: "demo", variant: .large, tag: "chain")
        try run(seed: "demo", variant: .ax3Light, tag: "chain")
    }

    /// 5 バンド PEQ。正規化スライダーと数値欄、バンドのチップ、周波数応答の図。
    func testPEQ() throws {
        try run(seed: "peq", variant: .large, tag: "peq")
        try run(seed: "peq", variant: .ax3Light, tag: "peq")
    }

    /// 図が主役のカード（Level Meter・Spectrogram・Spectrum Analyzer・Stereo Meter）。
    func testAnalyzers() throws {
        try run(seed: "analyzers4", variant: .large, tag: "analyzers")
    }

    /// 長い一覧。落とす種類だけで監査する（上の説明）。
    func testPicker() throws {
        try run(seed: "demo", sheet: "picker", variant: .large, tag: "picker", scope: .strictOnly)
    }

    func testSettings() throws {
        try run(seed: "demo", sheet: "settings", variant: .large, tag: "settings", scope: .strictOnly)
    }

    func testPresets() throws {
        try run(seed: "demo", sheet: "presets", variant: .large, tag: "presets", scope: .strictOnly)
    }
}
