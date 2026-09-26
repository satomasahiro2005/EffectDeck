//  JSFXSourceView.swift
//  JSFXのソースを読む画面。行番号・色分け・検索・節への移動。
//
//  **行は遅延で描く。**1 MBのスクリプトを1本のTextにすると開くだけで固まる。
//  色は開いたときに1回だけ裏で作り、以後は作り直さない。

import SwiftUI
import UniformTypeIdentifiers

struct JSFXSourceView: View {
    @Environment(\.dismiss) private var dismiss
    let instanceID: String

    @State private var source: String?
    @State private var rendered: JSFXRenderedSource?
    @State private var unavailable = false
    @State private var query = ""
    /// **閉じる前に畳む。**検索が出ている間のdismiss()は検索だけを閉じ、シートが残る（EffectPickerViewと同じ）。
    @State private var searching = false
    @State private var matches: [Int] = []
    @State private var matchSet: Set<Int> = []
    @State private var current = 0
    @ScaledMetric(relativeTo: .caption) private var fontSize: CGFloat = 12

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                content
                    .toolbar { toolbar(proxy) }
                    .task(id: query) { await search(proxy) }
            }
            .navigationTitle("JSFX Source")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, isPresented: $searching)
        }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let rendered {
            let charWidth = Self.charWidth(fontSize)
            let gutter = CGFloat(String(rendered.document.lines.count).count) * charWidth
            let width = gutter + 12 + CGFloat(rendered.document.maxColumns + 1) * charWidth + 32
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(0..<rendered.document.lines.count, id: \.self) { i in
                        row(i, rendered: rendered, gutter: gutter)
                            .frame(width: width, alignment: .leading)
                            .background(highlight(i))
                    }
                }
                .padding(.vertical, 12)
            }
            .font(.system(size: fontSize, design: .monospaced))
        } else if unavailable {
            ContentUnavailableView("Source Unavailable", systemImage: "doc.text")
        } else {
            ProgressView()
        }
    }

    private func row(_ i: Int, rendered: JSFXRenderedSource, gutter: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: String(i + 1))
                .foregroundStyle(.tertiary)
                .frame(width: gutter, alignment: .trailing)
            rendered.text(i)
                .lineLimit(1)
                .fixedSize()
                .textSelection(.enabled)
        }
        .padding(.horizontal, 16)
    }

    private func highlight(_ i: Int) -> Color {
        guard matchSet.contains(i) else { return .clear }
        return Color.accentColor.opacity(matches.indices.contains(current) && matches[current] == i ? 0.3 : 0.12)
    }

    @ToolbarContentBuilder
    private func toolbar(_ proxy: ScrollViewProxy) -> some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") {
                searching = false
                // 畳むのが効くのは次の回。
                Task { @MainActor in dismiss() }
            }
        }
        if let rendered, !rendered.document.sections.isEmpty {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    ForEach(rendered.document.sections) { section in
                        Button(section.name) { scroll(proxy, to: section.line) }
                    }
                } label: {
                    Label("Sections", systemImage: "list.bullet")
                }
            }
        }
        if let source {
            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    UIPasteboard.general.string = source
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                ShareLink(item: JSFXSourceFile(text: source, name: fileName),
                          preview: SharePreview(fileName))
                Spacer()
                if !query.isEmpty {
                    Text(verbatim: matches.isEmpty ? "0" : "\(current + 1)/\(matches.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button {
                        step(-1, proxy)
                    } label: {
                        Label("Previous", systemImage: "chevron.up")
                    }
                    .disabled(matches.isEmpty)
                    Button {
                        step(1, proxy)
                    } label: {
                        Label("Next", systemImage: "chevron.down")
                    }
                    .disabled(matches.isEmpty)
                }
            }
        }
    }

    private var fileName: String {
        // 題をそのままファイル名に使う。区切りになる字だけ落とす。
        let base = (rendered?.document.desc ?? "JSFX")
            .components(separatedBy: CharacterSet(charactersIn: "/\\:"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return (base.isEmpty ? "JSFX" : base) + ".jsfx"
    }

    // MARK: - 動き

    private func load() async {
        guard rendered == nil, !unavailable else { return }
        guard let text = ETJSFXHost.shared.sourceText(instanceID: instanceID) else {
            unavailable = true
            return
        }
        source = text
        rendered = await Task.detached(priority: .userInitiated) {
            JSFXRenderedSource(source: text)
        }.value
    }

    private func search(_ proxy: ScrollViewProxy) async {
        guard let document = rendered?.document, !query.isEmpty else {
            matches = []
            matchSet = []
            current = 0
            return
        }
        let q = query
        let found = await Task.detached(priority: .userInitiated) { document.matchingLines(q) }.value
        guard !Task.isCancelled else { return }
        matches = found
        matchSet = Set(found)
        current = 0
        if let first = found.first { scroll(proxy, to: first) }
    }

    private func step(_ delta: Int, _ proxy: ScrollViewProxy) {
        guard !matches.isEmpty else { return }
        current = (current + delta + matches.count) % matches.count
        scroll(proxy, to: matches[current])
    }

    private func scroll(_ proxy: ScrollViewProxy, to line: Int) {
        // **横は頭へ戻す。**anchorのxを中央にすると長い行の真ん中へ飛ぶ。
        proxy.scrollTo(line, anchor: UnitPoint(x: 0, y: 0.4))
    }

    private static func charWidth(_ size: CGFloat) -> CGFloat {
        let font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        return ceil(("0" as NSString).size(withAttributes: [.font: font]).width * 10) / 10
    }
}

/// 色を付け終えた行。**裏で1回だけ作る。**
private struct JSFXRenderedSource: @unchecked Sendable {
    let document: JSFXSourceDocument
    let attributed: [AttributedString]?

    init(source: String) {
        let document = JSFXSourceDocument(source: source)
        self.document = document
        guard document.highlighted else {
            attributed = nil
            return
        }
        // 種類ごとの属性は1回だけ作って使い回す。
        let styles = Dictionary(uniqueKeysWithValues: JSFXSyntaxTheme.Role.allCases.map { ($0, JSFXSyntaxTheme.attributes($0)) })
        attributed = zip(document.lines, document.tokens).map { Self.attributed($0, $1, styles) }
    }

    func text(_ i: Int) -> Text {
        let line = document.lines[i]
        // 空のTextは高さを持たないので、行が詰まる。
        if let attributed { return attributed[i].characters.isEmpty ? Text(verbatim: " ") : Text(attributed[i]) }
        return Text(verbatim: line.isEmpty ? " " : line)
    }

    /// **同じ見た目が続く字句は1本の区間にまとめる。**`);`や`] = `で区間が細切れになるのを防ぐ。
    private static func attributed(_ line: String, _ tokens: [JSFXToken],
                                   _ styles: [JSFXSyntaxTheme.Role: AttributeContainer]) -> AttributedString {
        guard !tokens.isEmpty else { return AttributedString(line) }
        let bytes = Array(line.utf8)
        var out = AttributedString()
        var runStart = 0
        var runStyle: JSFXSyntaxTheme.Role?
        func flush(to end: Int) {
            guard end > runStart else { return }
            let text = String(decoding: bytes[runStart..<end], as: UTF8.self)
            if let runStyle, let attributes = styles[runStyle] {
                out += AttributedString(text, attributes: attributes)
            } else {
                out += AttributedString(text)
            }
            runStart = end
        }
        var pos = 0
        for token in tokens {
            let role = JSFXSyntaxTheme.role(token.kind)
            // 間の空白は前の区間に付ける。色の無い字があるときだけ区切る。
            if token.range.lowerBound > pos {
                let gap = bytes[pos..<token.range.lowerBound]
                if runStyle != nil && !gap.allSatisfy({ $0 == 0x20 }) {
                    flush(to: pos)
                    runStyle = nil
                }
            }
            if role != runStyle {
                flush(to: token.range.lowerBound)
                runStyle = role
            }
            pos = token.range.upperBound
        }
        flush(to: pos)
        runStyle = nil
        flush(to: bytes.count)
        return out
    }
}

/// 字句の色。**色の対応はここだけ。**XcodeのDefaultテーマに寄せる。
/// 色はシステムの意味色だけ。**明るい画面では高コントラスト版に替える**（白地に細い等幅の字でも読めるように）。
enum JSFXSyntaxTheme {
    /// 見た目の種類。字句の種類より少ない。
    enum Role: Hashable, CaseIterable {
        case keyword, directive, section, string, number, range, enumItem, stringName
        case builtinFunction, builtinVariable, declaration, call, muted, comment
    }

    static func role(_ kind: JSFXTokenKind) -> Role {
        switch kind {
        case .keyword: .keyword
        case .headerKey, .sliderKey: .directive
        case .section: .section
        case .headerValue, .string, .sliderLabel, .sliderPath: .string
        case .number, .constant, .character, .sliderDefault: .number
        case .sliderRange: .range
        case .sliderEnum: .enumItem
        case .stringName: .stringName
        case .builtinFunction: .builtinFunction
        case .builtinVariable, .sliderVariable: .builtinVariable
        case .functionDefinition: .declaration
        case .functionCall: .call
        case .operator, .punctuation: .muted
        case .comment: .comment
        }
    }

    static func attributes(_ role: Role) -> AttributeContainer {
        var a = AttributeContainer()
        switch role {
        case .keyword:
            a.foregroundColor = system(.systemPink)
            a.inlinePresentationIntent = .stronglyEmphasized
        case .directive:
            a.foregroundColor = system(.systemOrange)
        case .section:
            a.foregroundColor = system(.systemOrange)
            a.inlinePresentationIntent = .stronglyEmphasized
        case .string:
            a.foregroundColor = system(.systemRed)
        case .number:
            a.foregroundColor = system(.systemBlue)
        case .range:
            a.foregroundColor = system(.systemCyan)
        case .enumItem, .stringName:
            a.foregroundColor = system(.systemBrown)
        case .builtinFunction:
            a.foregroundColor = system(.systemPurple)
        case .builtinVariable:
            a.foregroundColor = system(.systemTeal)
        case .declaration:
            a.foregroundColor = system(.systemGreen)
            a.inlinePresentationIntent = .stronglyEmphasized
        case .call:
            a.foregroundColor = system(.systemGreen)
        case .muted:
            a.foregroundColor = Color.secondary
        case .comment:
            a.foregroundColor = Color.secondary
            a.inlinePresentationIntent = .emphasized
        }
        return a
    }

    private static func system(_ base: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? base.resolvedColor(with: traits)
                : base.resolvedColor(with: traits.modifyingTraits { $0.accessibilityContrast = .high })
        })
    }
}

/// 共有するときのファイル。中身は平文。
private struct JSFXSourceFile: Transferable {
    let text: String
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .plainText) { Data($0.text.utf8) }
            .suggestedFileName { $0.name }
    }
}
