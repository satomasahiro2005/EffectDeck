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

    /// 監査を 1 回かける。指摘は全部ここで文面にし、落とす分（strict の種類）は別に返す。
    /// ハンドラは常に true（処理した）を返す。落とすのは呼び出し側が要素つきの文面で XCTFail する
    /// （ハンドラで false を返すと、失敗の文面に要素が入らず CI のログで特定できなかった）。
    private func auditOnce(_ app: XCUIApplication, tag: String,
                           strict: XCUIAccessibilityAuditType) throws -> (lines: [String], failures: [String]) {
        var lines: [String] = []
        var failures: [String] = []
        try app.performAccessibilityAudit(for: .all) { issue in
            let kind = self.name(of: issue.auditType)
            let line = "[\(kind)] \(issue.compactDescription) | \(self.describe(issue.element)) | \(issue.detailedDescription)"
            lines.append(line)
            print("A11Y-ISSUE[\(tag)] \(line)")
            if strict.contains(issue.auditType) { failures.append(line) }
            return true
        }
        return (lines, failures)
    }

    /// 監査をかけ、全部の指摘を添付する。落とすのは strict の種類だけ。
    ///
    /// **時間切れ（-56）は 1 回だけ取り直す。**CI の VM は遅く、1 回目は描画が落ち着く前に当たることがある。
    /// 2 回目も時間切れなら、黙って飛ばさず「監査が終わらなかった」で落とす。
    private func audit(_ app: XCUIApplication, _ tag: String) throws {
        let strict = self.strict
        var result: (lines: [String], failures: [String])?
        for attempt in 1...2 {
            do {
                result = try auditOnce(app, tag: tag, strict: strict)
                break
            } catch {
                guard isTimeout(error) else { throw error }
                print("A11Y-AUDIT[\(tag)] timeout attempt=\(attempt): \(error.localizedDescription)")
                if attempt == 1 { Thread.sleep(forTimeInterval: 3) }
            }
        }
        guard let result else {
            XCTFail("アクセシビリティ監査が 2 回とも時間切れ（Code=-56）で終わらなかった: \(tag)")
            return
        }
        let body = result.lines.isEmpty ? "no issues" : result.lines.joined(separator: "\n")
        print("A11Y-AUDIT[\(tag)] issues=\(result.lines.count) failing=\(result.failures.count)")
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

    private func run(seed: String, sheet: String? = nil, variant: A11yVariant, tag: String) throws {
        // 動き続ける図・数字は木を毎回変え、監査が落ち着くのを待ちきれない。止めて起動する。
        let app = A11yLaunch.launch(seed: seed, sheet: sheet, variant: variant, freezeLive: true)
        defer { app.terminate() }
        try audit(app, "\(tag)-\(variant.name)")
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

    func testPicker() throws {
        try run(seed: "demo", sheet: "picker", variant: .large, tag: "picker")
    }

    func testSettings() throws {
        try run(seed: "demo", sheet: "settings", variant: .large, tag: "settings")
    }

    func testPresets() throws {
        try run(seed: "demo", sheet: "presets", variant: .large, tag: "presets")
    }
}
