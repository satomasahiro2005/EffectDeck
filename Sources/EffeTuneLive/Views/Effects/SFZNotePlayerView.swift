//  SFZNotePlayerView.swift
//  SFZ Note Player（SFZNotePlayerPlugin。検出した音の高さで SFZ の楽器を鳴らす）。
//
//  上流 plugins/others/sfz_note_player.js の createUI（図は無い）。並びは
//    SFZ の選択欄 + Import Folder… + Remove
//    （フォルダに SFZ が複数あるときだけ）どれを取り込むかの選択欄 + Import
//    赤い状態行
//    Highest / Middle / Lowest（音域の帯）→ Threshold → Retrigger Drop → Note Hold → Velocity 1 Level →
//    Velocity 127 Level → Max Voices → Dry → Wet → Octave → Output Gain → Timing → Lowest Note → Highest Note
//  つまみは汎用の ParameterRow、Lowest / Highest Note だけ音名で読ませる（Note Spectrogram と同じ ETNoteRangeRow）。
//
//  フォルダは .fileImporter（UIDocumentPickerViewController の公開 API。フォルダ）で選ぶ。取り込みは
//  SFZLoader が別のスレッドで走らせ、置き場（Application Support/SFZ）に入れてから、段のバンクの鍵（`sf`）にする。
//  PC の EffeTune と同じフォルダなら同じ鍵になる（SFZBank の注記）が、バンクの中身は PC と送り合わない。
//  鍵が指すバンクがこちらに無いときは、選択欄に Missing SFZ と出す（上流と同じ）。
//
//  読み込みの知らせ（飛ばした領域・補正したループ・縮めたバンク）は取り込みの後に一度だけ警告で出す。
//  バンクが無いあいだ、効果音の側は鳴らず（wet が無音）、dry（既定 20%）だけが通る。上流も同じ。

import SwiftUI
import UniformTypeIdentifiers

struct SFZNotePlayerView: View {

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    @ObservedObject private var library = SFZLibrary.shared
    @ObservedObject private var loader = SFZLoader.shared
    @State private var picking = false
    /// フォルダに SFZ が複数あるとき、どれを取り込むかを選ぶ間の控え。
    @State private var pending: PendingFolder?
    @State private var choice = ""
    /// フォルダを開く段階の失敗（段の状態には載らない）。
    @State private var folderError: String?

    private struct PendingFolder {
        var folder: URL
        var files: [ETSFZFolderFile]
        var paths: [String]
    }

    private var state: SFZNodeState { loader.state(of: node.id) }
    private var loading: Bool { state == .loading }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            bankRow
            if let pending { instrumentRow(pending) }
            if let line = errorLine {
                Text(line)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(node.spec.params) { param in
                if param.key == "mn" || param.key == "mx" {
                    ETNoteRangeRow(param: param, nodeIndex: index, values: node.values, dsp: dsp)
                } else {
                    ParameterRow(param: param, nodeIndex: index, values: node.values, dsp: dsp)
                }
            }
        }
        .alert("SFZ Note Player", isPresented: Binding(
            get: { loader.notice != nil },
            set: { if !$0 { loader.notice = nil } })
        ) {
            Button("Close", role: .cancel) { loader.notice = nil }
        } message: {
            Text(loader.notice ?? "")
        }
        .onAppear { library.reload() }
    }

    // MARK: 選択欄

    private var bankRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SFZ").font(.system(size: 14))
                Spacer(minLength: 8)
                Picker("SFZ", selection: Binding(
                    get: { node.irId },
                    set: { select($0) })
                ) {
                    Text("None").tag("")
                    ForEach(library.entries) { entry in
                        Text(entry.name).tag(entry.id)
                    }
                    if !node.irId.isEmpty && library.entry(id: node.irId) == nil {
                        Text("Missing SFZ").tag(node.irId)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .disabled(loading)
            }
            HStack(spacing: 8) {
                ETMeasurementButton(title: "Import Folder…", isEnabled: !loading) {
                    folderError = nil
                    pending = nil
                    picking = true
                }
                // fileImporter と alert は別のビューに付ける（同じビューに重ねると後から付けた方しか出ない。
                // IRReverbView.swift の fileImporter の注記）。
                .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
                    folderChosen(result)
                }
                ETMeasurementButton(title: "Remove", isEnabled: !node.irId.isEmpty && !loading) {
                    folderError = nil
                    pending = nil
                    loader.remove(bankID: node.irId, for: node.id, dsp: dsp)
                }
            }
        }
    }

    private func instrumentRow(_ pending: PendingFolder) -> some View {
        HStack(spacing: 8) {
            Picker("SFZ", selection: $choice) {
                ForEach(pending.paths, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            Spacer(minLength: 8)
            ETMeasurementButton(title: "Import") {
                self.pending = nil
                loader.importFolder(pending.files, selectedPath: choice, into: node.id, dsp: dsp,
                                    keepAccessTo: pending.folder)
            }
        }
    }

    /// 赤い状態行。失敗した段か、フォルダを開く段階で外れたとき。
    private var errorLine: String? {
        if let folderError { return folderError }
        if case .failed(let code) = state { return SFZLoader.errorMessage(code) }
        return nil
    }

    // MARK: 操作

    private func select(_ id: String) {
        folderError = nil
        pending = nil
        loader.choose(bankID: id, for: node.id, dsp: dsp)
    }

    private func folderChosen(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        Task {
            do {
                let files = try await Task.detached(priority: .userInitiated) {
                    try SFZLoader.enumerate(folder: url)
                }.value
                let paths = try ETSFZBank.folderSFZPaths(files.map(\.path))
                guard !paths.isEmpty else {
                    folderError = SFZLoader.errorMessage(.noRegions)
                    return
                }
                if paths.count == 1 {
                    loader.importFolder(files, selectedPath: paths[0], into: node.id, dsp: dsp, keepAccessTo: url)
                } else {
                    choice = paths[0]
                    pending = PendingFolder(folder: url, files: files, paths: paths)
                }
            } catch {
                folderError = SFZLoader.errorMessage((error as? ETSFZError)?.code ?? .prepare)
            }
        }
    }
}
