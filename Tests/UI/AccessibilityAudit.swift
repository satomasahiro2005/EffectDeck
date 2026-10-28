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

    /// 監査をかけ、全部の指摘を添付する。落とすのは strict の種類だけ。
    private func audit(_ app: XCUIApplication, _ tag: String) throws {
        let strict = self.strict
        var lines: [String] = []
        try app.performAccessibilityAudit(for: .all) { issue in
            let element = issue.element
            let label = element?.label ?? "-"
            let kind = self.name(of: issue.auditType)
            lines.append("[\(kind)] \(issue.compactDescription) | label=\(label) | \(issue.detailedDescription)")
            // true は「処理した（落とさない）」。strict の種類だけ false を返して落とす。
            return strict.contains(issue.auditType) ? false : true
        }
        let body = lines.isEmpty ? "no issues" : lines.joined(separator: "\n")
        print("A11Y-AUDIT[\(tag)] issues=\(lines.count)")
        let att = XCTAttachment(string: body)
        att.name = "accessibility-\(tag).txt"
        att.lifetime = .keepAlways
        add(att)
    }

    private func run(seed: String, sheet: String? = nil, variant: A11yVariant, tag: String) throws {
        let app = A11yLaunch.launch(seed: seed, sheet: sheet, variant: variant)
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
