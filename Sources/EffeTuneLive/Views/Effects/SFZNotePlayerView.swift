//  SFZNotePlayerView.swift
//  SFZ Note Player（SFZNotePlayerPlugin。検出した音の高さで SFZ の楽器を鳴らす）。
//
//  上流 plugins/others/sfz_note_player.js（2.14.0）の createUI。並びは
//    SFZ: [SFZ Library…] 選んでいる名前 [Clear]
//    赤い状態行
//    Color（Normal / Note Colors）
//    Highest / Middle / Lowest（音域の帯）→ Threshold → Retrigger Drop → Note Hold → Velocity 1 Level →
//    Velocity 127 Level → Max Voices → Dry → Wet → Octave → Sample Shift → Output Gain → Timing →
//    Lowest Note → Highest Note
//    声の図（SFZVoiceGraph。触ると鳴る）
//  つまみは汎用の ParameterRow、Lowest / Highest Note だけ音名で読ませる（Note Spectrogram と同じ ETNoteRangeRow）。
//  試し弾きの Preview Midi / Velocity は保存しない値なので行を出さない（runtimeOnly）。
//
//  バンクの出し入れは SFZ Library（SFZLibraryView）。2.13.0 の選択欄・Import Folder…・Remove はそこへ移った。
//  Clear は段を None に戻すだけで、置き場からは消さない。
//  PC と同じフォルダなら同じ鍵になる（SFZBank の注記）が、バンクの中身は PC と送り合わない。
//  鍵が指すバンクがこちらに無いときは、名前の所に Missing SFZ と出す（上流と同じ）。
//
//  読み込みの知らせ（飛ばした領域・補正したループや時間・縮めたバンク）は読み込んだ後に一度だけ警告で出す。
//  バンクが無いあいだ、効果音の側は鳴らず（wet が無音）、dry（既定 20%）だけが通る。上流も同じ。

import SwiftUI

struct SFZNotePlayerView: View {

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    @ObservedObject private var library = SFZLibrary.shared
    @ObservedObject private var loader = SFZLoader.shared
    /// PC の鎖を編集している間は取り込ませない。PC へ届くのはバンクの鍵だけで、サンプルは送れない
    /// （上流に送る手が無い。docs/notes/effetune-2.13.0.md）。
    @ObservedObject private var remote = RemoteMirror.shared
    @Environment(\.etGraphOnly) private var graphOnly
    @State private var browsing = false
    /// Color（cl）。表示の設定なので display に持つ（DisplayParams.swift）。
    @State private var color: String

    init(index: Int, node: EffeTuneDSP.Node, dsp: EffeTuneDSP) {
        self.index = index
        self.node = node
        self.dsp = dsp
        _color = State(initialValue: node.display["cl"] == "Rainbow" ? "Rainbow" : "Normal")
    }

    private var state: SFZNodeState { loader.state(of: node.id) }
    private var loading: Bool { state == .loading }
    private var ready: Bool { if case .ready = state { return true } else { return false } }

    var body: some View {
        if graphOnly {
            graph(canPreview: false)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                bankRow
                if let line = errorLine {
                    Text(line)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ETDisplayChoiceRow(title: "Color",
                                   options: [("Normal", "Normal"), ("Rainbow", "Note Colors")],
                                   selection: Binding(get: { color }, set: { value in
                                       color = value
                                       dsp.setDisplay(value, key: "cl", at: index)
                                   }))
                ForEach(node.spec.params.filter { !$0.runtimeOnly }) { param in
                    if param.key == "mn" || param.key == "mx" {
                        ETNoteRangeRow(param: param, nodeIndex: index, values: node.values, dsp: dsp)
                    } else {
                        ParameterRow(param: param, nodeIndex: index, values: node.values, dsp: dsp)
                    }
                }
                graph(canPreview: ready && node.enabled && !dsp.bypass && !remote.isRemote)
            }
            .alert("SFZ Note Player", isPresented: Binding(
                get: { loader.notice != nil },
                set: { if !$0 { loader.notice = nil } })
            ) {
                Button("Close", role: .cancel) { loader.notice = nil }
            } message: {
                Text(loader.notice ?? "")
            }
            .sheet(isPresented: $browsing) {
                SFZLibraryView { entry in loader.choose(bankID: entry.id, for: node.id, dsp: dsp) }
            }
            .onAppear { library.reload() }
        }
    }

    private func graph(canPreview: Bool) -> some View {
        SFZVoiceGraph(index: index, node: node, dsp: dsp, canPreview: canPreview)
    }

    // MARK: 選択欄

    private var bankName: String {
        guard !node.irId.isEmpty else { return "None" }
        return library.entry(id: node.irId)?.name ?? "Missing SFZ"
    }

    private var bankRow: some View {
        HStack(spacing: 8) {
            Text("SFZ").font(.system(size: 14))
            ETMeasurementButton(title: "SFZ Library…", isEnabled: !loading && !remote.isRemote) {
                browsing = true
            }
            Text(loading ? "Loading…" : bankName)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            ETMeasurementButton(title: "Clear", isEnabled: !node.irId.isEmpty && !loading) {
                loader.choose(bankID: "", for: node.id, dsp: dsp)
            }
        }
    }

    /// 赤い状態行。失敗した段だけ。
    private var errorLine: String? {
        if case .failed(let code) = state { return SFZLoader.errorMessage(code) }
        return nil
    }
}
