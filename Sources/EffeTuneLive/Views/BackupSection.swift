//  BackupSection.swift
//  鎖とプリセットを 1 本の JSON で持ち出す / 戻す。
//
//  **Presets の中に置く。**もとは Settings の 3 つ目のペインだった。
//  中身は Export と Import の 2 行しかないのにペインを 1 つ占めていて、
//  しかも扱っているのは設定ではなく、Presets と同じ「保存した鎖」だった。
//  Settings に残っているのは Audio と About の 2 つ。

import SwiftUI
import UniformTypeIdentifiers

struct ETBackupSection: View {
    /// 鎖を出し入れするので要る。Settings と違って読むだけではない。
    @StateObject private var dsp = EffeTuneDSP.shared

    /// 書き出し / 読み込み。
    /// **提示は行ごとに分ける。**fileExporter を Export の行、fileImporter を
    /// Import の行に付けてある。同じビューに重ねると後から付けた方しか出ない
    /// （IRReverbView.swift:81-86）。結果は提示ではなく節の中の 1 行で返す。
    @State private var exporting = false
    @State private var importing = false
    @State private var exportFile: ETBackupDocument?
    @State private var backupReport: String?
    /// 読めたが、まだ入れていないファイルの中身。押し直すまでここで待つ。
    @State private var pending: ETBackup.Contents?

    /// 鎖とプリセットを 1 本の JSON にする（中身は ETBackup）。
    ///
    /// **Settings の中身（Processing rate / Latency ほか）は入らない。**
    /// 入るのは鎖・保存した鎖・エフェクトごとのプリセットの 3 つだけなので、
    /// ボタンも "settings" とは名乗らない。
    ///
    /// すぐ上の共有リンク（"EffeTune on the web"）とは別物で、
    /// あちらは鎖 1 本を渡すためのもの。こちらは取っておくためのもの。
    ///
    /// **読み込みは 2 段。**選んだ瞬間には入れず、何が入って何が消えるかを
    /// 1 行出してからもう一度押させる。鎖ごと捨てる他の口（PipelineView.swift:117-127
    /// の "Reset Pipeline?"）と同じ重さにする。あちらより壊す量が多いのに
    /// 何も聞かない、という形にしない。
    ///
    /// **提示は増やさない。**聞くのは節の中の行で、confirmationDialog を
    /// 足さない。同じ View に提示を重ねて後ろが出なくなる踏み方を
    /// このリポジトリで 3 度している（PresetsView.swift:145-148）。
    /// 行なら潰し合わないし、出なかったことにも気づける。
    var body: some View {
        Section {
            Button {
                export()
            } label: {
                Label("Export presets & chain", systemImage: "square.and.arrow.up")
            }
            .fileExporter(isPresented: $exporting,
                          document: exportFile,
                          contentType: .json,
                          defaultFilename: "EffectDeck Presets") { result in
                switch result {
                case .success:
                    backupReport = "Exported."
                case .failure(let error):
                    backupReport = error.localizedDescription
                }
                exportFile = nil
            }

            Button {
                importing = true
            } label: {
                Label("Import presets & chain", systemImage: "square.and.arrow.down")
            }
            .fileImporter(isPresented: $importing,
                          allowedContentTypes: [.json, .text, .data],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first { importBackup(url) }
                case .failure(let error):
                    pending = nil
                    backupReport = error.localizedDescription
                }
            }

            // 出したままにせず、次の出し入れで置き換える（IRLibraryView と同じ扱い）。
            // **押す前の説明もここに出る。**読んでから下の 2 行を押す形にしたいので、
            // 順番はこちらが先。
            if let backupReport {
                Text(backupReport)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            // 読めたファイルが待っているあいだだけ出る 2 行。
            // 何が入って何が消えるかは、すぐ上の 1 行に出ている。
            if let waiting = pending {
                Button(role: .destructive) {
                    pending = nil
                    backupReport = apply(waiting)
                } label: {
                    Text("Import")
                }
                Button("Cancel") {
                    pending = nil
                    backupReport = nil
                }
            }
        } header: {
            Text("Backup")
        }
    }

    private func export() {
        let presets = PresetStore.shared.exported()
        let effectPresets = EffectPresetStore.shared.exported()

        // **「出すものが無い」と「書けなかった」を分ける。**
        // ETBackup.data は両方 nil で返すので、空かどうかはここで見る。
        // 一緒にすると、中身が在るのに書けなかったときに嘘を出すことになる。
        guard !dsp.chain.isEmpty || !presets.isEmpty || !effectPresets.isEmpty else {
            backupReport = "There is nothing to export yet."
            return
        }
        guard let data = ETBackup.data(chain: dsp.chain,
                                       presets: presets,
                                       effectPresets: effectPresets) else {
            backupReport = "That could not be written as JSON."
            return
        }
        exportFile = ETBackupDocument(data: data)
        exporting = true
    }

    /// **読むだけ。**入れるのは、下の 1 行を読んでもう一度押してから。
    private func importBackup(_ url: URL) {
        // ファイルアプリから来た URL は囲いの外にある（IRLibrary.importFile と同じ）。
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else {
            pending = nil
            backupReport = "That file could not be read."
            return
        }

        switch ETBackup.read(data, catalog: ETCatalog) {
        case .failure(let why):
            pending = nil
            backupReport = why.message
        case .success(let contents):
            pending = contents
            backupReport = summary(of: contents)
        }
    }

    /// 押す前に出す 1 行。**消えるものを先に言う。**
    private func summary(of contents: ETBackup.Contents) -> String {
        var has: [String] = []
        if !contents.chain.isEmpty { has.append(amount(contents.chain.count, "effect")) }
        if !contents.presets.isEmpty { has.append(amount(contents.presets.count, "preset")) }
        if contents.effectPresetCount > 0 {
            has.append(amount(contents.effectPresetCount, "effect preset"))
        }

        var text = ["This file has " + has.joined(separator: ", ") + "."]

        if contents.chainDropped > 0 {
            let verb = contents.chainDropped == 1 ? "is" : "are"
            text.append("\(amount(contents.chainDropped, "effect")) in it \(verb) "
                        + "not available here and will be left out.")
        }
        if contents.skipped > 0 {
            text.append(amount(contents.skipped, "preset") + " could not be read.")
        }
        if !contents.chain.isEmpty {
            // **ready は押す前に見る。**押してから「エンジンが立っていない」と
            // 言われても、ファイルが悪いのかどうか読めない。
            text.append(dsp.ready
                        ? "Importing replaces the current chain."
                        : "The audio engine is not running, so the chain will be left out.")
        }
        let clashes = collisions(contents)
        if clashes > 0 {
            text.append(amount(clashes, "preset") + " here with the same name will be replaced.")
        }
        return text.joined(separator: " ")
    }

    /// ファイルの中に、手元と同じ名前がいくつ在るか。入れると置き換わる。
    private func collisions(_ contents: ETBackup.Contents) -> Int {
        let mine = Set(PresetStore.shared.names)
        var n = contents.presets.keys.filter { mine.contains(trimmed($0)) }.count

        // 入れ物の鍵は normalize 済み（EffectPresetStore.merge）なので、
        // 突き合わせる側も同じ形にしてから引く。
        let saved = EffectPresetStore.shared.saved
        for (effect, presets) in contents.effectPresets {
            let here = Set(saved[trimmed(effect)] ?? [])
            n += presets.keys.filter { here.contains(trimmed($0)) }.count
        }
        return n
    }

    private func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "1 effect" / "3 effects"。
    private func amount(_ n: Int, _ noun: String) -> String {
        n == 1 ? "1 \(noun)" : "\(n) \(noun)s"
    }

    /// 入れて、何が入ったかの 1 行を返す。
    private func apply(_ contents: ETBackup.Contents) -> String {
        var parts: [String] = []
        var engineDown = false

        // **ready を見る。** replaceChain は ready でなければ何もしないので、
        // 見ないと「入れた」と書いたのに鎖が変わっていないことになる。
        if !contents.chain.isEmpty {
            if dsp.ready {
                dsp.replaceChain(with: contents.chain)
                // 鎖に載っている IR を入れ直す。畳んだカードにはビューが無いので
                // DSP 側で呼ぶ（EffeTuneDSP.swift:406、restore() の第一の枝と同じ）。
                dsp.reloadAssets()
                parts.append(amount(contents.chain.count, "effect"))
            } else {
                engineDown = true
            }
        }

        let presets = PresetStore.shared.merge(contents.presets)
        if presets > 0 { parts.append(amount(presets, "preset")) }

        let effectPresets = EffectPresetStore.shared.merge(contents.effectPresets)
        if effectPresets > 0 { parts.append(amount(effectPresets, "effect preset")) }

        var line = parts.isEmpty ? "" : "Imported " + parts.joined(separator: ", ") + "."

        // **ファイルのせいにしない。**落ちたのはエンジンが立っていないからで、
        // ファイルは読めている。少し待って押し直せば通る。
        if engineDown {
            let why = "The audio engine is not running, so the chain was not imported."
            line = line.isEmpty ? why : line + " " + why
        }

        return line.isEmpty ? "Nothing in that file could be used." : line
    }
}

// MARK: - 書き出すファイル

/// .fileExporter へ渡す入れ物。中身は ETBackup が作った JSON そのまま。
///
/// 読む側では使わない。取り込みは .fileImporter が URL をくれるので、
/// この節が自分で Data にして ETBackup.read へ渡す。
private struct ETBackupDocument: FileDocument {

    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        data = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
