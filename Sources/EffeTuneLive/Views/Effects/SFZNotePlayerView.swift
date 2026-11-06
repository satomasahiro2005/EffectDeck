//  SFZNotePlayerView.swift
//  SoundFont Note Player（SFZNotePlayerPlugin。検出した音の高さで SF2・SFZ の楽器を鳴らす。2.17.0 で SFZ Note Player から改名）。
//
//  上流 plugins/others/sfz_note_player.js（2.17.0）の createUI。並びは
//    SoundFont: [SoundFont Library…] 選んでいる名前 [Clear]
//    赤い状態行
//    Preset（SoundFont を読めたときだけ）
//    Detection（Classic / Event）
//    Color（Normal / Note Colors）
//    Highest / Middle / Lowest（音域の帯）→ Threshold → Retrigger Drop → Note Hold → Velocity 1 Level →
//    Velocity 127 Level → Max Voices → Dry → Wet → Octave → Sample Shift → Output Gain → Timing →
//    Lowest Note → Highest Note
//    声の図（SFZVoiceGraph。触ると鳴る）
//    Instrument Details（バンクにラベルか画像があるときだけ。押されている鍵盤スイッチの 1 行と、標準の開閉の欄）
//  つまみは汎用の ParameterRow、Lowest / Highest Note だけ音名で読ませる（Note Spectrogram と同じ ETNoteRangeRow）。
//  Preset（sp0）は数の行にしない（生の bank × 128 + program が見える）。SoundFont を読めたときだけ、音源の持つ Preset の
//  一覧から選ぶ欄を出す（既存のメニューの行 ETDisplayChoiceRow。Default = -1、続きは Bank b · p+1. 名前。SFZ のバンクでは
//  欄ごと隠す。一覧の組み立ては ETSFZPresetMenu）。sp0 は読み込みのたびに一覧に照らして直す（SFZLoader）。
//  Detection（dt）は音の拾い方。Event は PC 側の値なので etLocalAudioOnly にしない。Event の間は
//  Threshold と Retrigger Drop を止める（ETParamGate。値は残す）。Event は約 140 ms 遅れる。
//  試し弾きの Preview Midi / Velocity は保存しない値なので行を出さない（runtimeOnly）。
//
//  バンクの出し入れは SoundFont Library（SFZLibraryView）。2.13.0 の選択欄・Import Folder…・Remove はそこへ移った。
//  Clear は段を None に戻すだけで、置き場からは消さない。
//  PC と同じフォルダなら同じ鍵になる（上流の js/sfz/bank.js が鍵を決める）が、バンクの中身は PC と送り合わない。
//  鍵が指すバンクがこちらに無いときは、名前の所に Missing SoundFont と赤い状態行に見つからない旨を出す（上流 2.17.0 と同じ）。
//  文面は ETSFZMessages（上流の sfzNotePlayer.*）。
//
//  Instrument Details は上流の sfz-instrument.js の _renderInstrumentDetails。行の並びと字面は ETSFZInstrumentDetails
//  （Key n・CC n・Output n・Group・Global/Master/Region・Keyswitch a–b）。押されている鍵盤スイッチの 1 行は
//  テレメトリの型 34（ETSFZKeyswitchFrame）。段が入っていて鳴らせるあいだだけ出す。
//
//  読み込みの知らせ（飛ばした領域・補正したループや時間・縮めたバンク）は読み込んだ後に一度だけ警告で出す。
//  バンクが無いあいだ、効果音の側は鳴らず（wet が無音）、dry（既定 20%）だけが通る。上流も同じ。

import SwiftUI
import UIKit

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
            graph(canPreview: false).etLocalAudioOnly()
        } else {
            VStack(alignment: .leading, spacing: 12) {
                // バンクは手元の SoundFont Library、声の図は手元の音。PC の鎖を編集しているあいだは
                // 出さない（上流 2.14.0。バンクは PC で選ぶ）。
                bankRow.etLocalAudioOnly()
                if let line = errorLine {
                    Text(line)
                        .etFont(size: 11)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                presetRow.etLocalAudioOnly()
                detectionRow
                ETDisplayChoiceRow(title: "Color",
                                   options: [("Normal", "Normal"), ("Rainbow", "Note Colors")],
                                   selection: Binding(get: { color }, set: { value in
                                       color = value
                                       dsp.setDisplay(value, key: "cl", at: index)
                                   }))
                ForEach(node.spec.params.filter { !$0.runtimeOnly && $0.key != "dt" && $0.key != "sp0" }) { param in
                    if param.key == "mn" || param.key == "mx" {
                        ETNoteRangeRow(param: param, nodeIndex: index, values: node.values, dsp: dsp)
                    } else {
                        ParameterRow(param: param, nodeIndex: index, values: node.values, dsp: dsp)
                    }
                }
                graph(canPreview: ready && node.enabled && !dsp.bypass && !remote.isRemote)
                    .etLocalAudioOnly()
                if let presentation = loader.presentation(of: node.id) {
                    SFZInstrumentDetailsView(node: node, presentation: presentation, name: bankName,
                                             live: ready && node.enabled && !dsp.bypass)
                        .etLocalAudioOnly()
                }
            }
            .alert(ETSFZMessages.playerTitle, isPresented: Binding(
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

    // MARK: Preset

    private var presetParam: ETParam? { node.spec.params.first { $0.key == "sp0" } }

    /// 上流の createSelectControl('Preset', …)。選べる Preset が無ければ欄ごと出さない。読み込み中は触れない（上流の pending）。
    @ViewBuilder
    private var presetRow: some View {
        let list = loader.presets(of: node.id)
        let items = ETSFZPresetMenu.items(list)
        if let sp0 = presetParam, !items.isEmpty {
            ETDisplayChoiceRow(
                title: "Preset",
                options: items.map { (value: $0.key, label: $0.label) },
                selection: Binding(
                    get: {
                        guard node.values.indices.contains(sp0.offset) else { return ETSFZPresetMenu.defaultKey }
                        return Int(ETSFZPresetMenu.validatedSelection(current: node.values[sp0.offset], presets: list))
                    },
                    set: { dsp.setValue(Float($0), at: index, offset: sp0.offset) }),
                style: .menu)
            .disabled(loading)
        }
    }

    // MARK: Detection

    private var detectionParam: ETParam? { node.spec.params.first { $0.key == "dt" } }

    /// 上流の createRadioGroup('Detection', …)。値は DSP の dt（0 = Classic・1 = Event）。カーネルは 1 だけを Event と読む（範囲の外・小数は Classic）。
    @ViewBuilder
    private var detectionRow: some View {
        if let dt = detectionParam {
            ETDisplayChoiceRow(
                title: "Detection",
                options: [(0, "Classic (Low Latency)"), (1, "Event (+140 ms)")],
                selection: Binding(
                    get: { node.values.indices.contains(dt.offset) && node.values[dt.offset] == 1 ? 1 : 0 },
                    set: { dsp.setValue(Float($0), at: index, offset: dt.offset) }))
        }
    }

    // MARK: 選択欄

    private var bankName: String {
        guard !node.irId.isEmpty else { return ETSFZMessages.noBankName }
        return library.entry(id: node.irId)?.name ?? ETSFZMessages.missingBankName
    }

    private var bankRow: some View {
        HStack(spacing: 8) {
            Text(ETSFZMessages.bankLabel).etFont(size: 14)
            ETMeasurementButton(title: ETSFZMessages.libraryButton, isEnabled: !loading && !remote.isRemote) {
                browsing = true
            }
            Text(loading ? "Loading…" : bankName)
                .etFont(size: 14)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            ETMeasurementButton(title: "Clear", isEnabled: !node.irId.isEmpty && !loading) {
                loader.choose(bankID: "", for: node.id, dsp: dsp)
            }
        }
    }

    /// 赤い状態行。失敗した段と、鍵が指すバンクが置き場に無い段（上流 2.17.0 の sfzNotePlayer.error.missing）。
    private var errorLine: String? {
        switch state {
        case .failed(let code): return ETSFZMessages.error(code.rawValue)
        case .missing: return ETSFZMessages.error("missing")
        default: return nil
        }
    }
}

/// Instrument Details（上流の _createInstrumentDetails）。押されている鍵盤スイッチの 1 行と、標準の開閉の欄。
/// 枠を見るのは 1 行の部品（SFZKeyswitchLine）だけ。ここ（画像と行の一覧）は枠のたびに組み直さない。
private struct SFZInstrumentDetailsView: View {
    let node: EffeTuneDSP.Node
    let presentation: ETSFZScriptPresentation
    /// 画像の読み上げ名（上流の alt。空なら Instrument）。
    let name: String
    /// 型 34 の枠を信じてよいか（バンクが読めていて、段が入っている）。
    let live: Bool

    @State private var open = false
    /// 画像は presentation が変わったときだけ復号する（body の中で毎回 UIImage(data:) を作らない）。
    @State private var image: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !presentation.switches.isEmpty {
                SFZKeyswitchLine(node: node, presentation: presentation, live: live)
            }
            DisclosureGroup(isExpanded: $open) {
                VStack(alignment: .leading, spacing: 8) {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .accessibilityLabel(name.isEmpty ? "Instrument" : name)
                    }
                    ForEach(Array(ETSFZInstrumentDetails.rows(presentation).enumerated()), id: \.offset) { _, row in
                        LabeledContent(row.name) { Text(row.value) }
                            .etFont(size: 12)
                    }
                }
            } label: {
                Text("Instrument Details").etFont(size: 13, weight: .semibold)
            }
        }
        .onAppear { decodeImage() }
        .onChange(of: presentation) { _, _ in decodeImage() }
    }

    private func decodeImage() {
        image = presentation.imageData.flatMap { UIImage(data: $0) }
    }
}

/// 押されている鍵盤スイッチの 1 行。テレメトリを見るのはこの部品だけ。
/// 上流は表示やバンクの版が変わると押下状態を捨て、古い版の枠を無視する（_activeSwitches = null）。
/// こちらは版を持たないので、表示が変わった時点（と段が鳴らせなくなった時点）の枠の連番を覚え、
/// それより新しい枠だけを信じる。前のバンクの枠が新しいバンクの範囲に当たって一瞬違う名前が出るのを防ぐ。
private struct SFZKeyswitchLine: View {
    let node: EffeTuneDSP.Node
    let presentation: ETSFZScriptPresentation
    let live: Bool

    @ETTelemetryFeed private var telemetry
    /// これ以前の連番の枠は捨てる。nil は捨てるものが無かった（まだ枠が来ていなかった）。
    @State private var floor: UInt32?

    private var line: String? {
        guard live, let raw = telemetry.frame(tap: node.tapId, type: .sfzKeyswitches) else { return nil }
        if let floor, raw.sequence <= floor { return nil }
        return ETSFZInstrumentDetails.activeLine(
            frame: ETSFZKeyswitchFrame.parse(type: raw.type, version: raw.version, payload: raw.payload),
            switches: presentation.switches)
    }

    var body: some View {
        Group {
            if let line {
                Text(line).etFont(size: 12)
            }
        }
        .onAppear { resetFloor() }
        .onChange(of: presentation) { _, _ in resetFloor() }
        .onChange(of: live) { _, now in if !now { resetFloor() } }
    }

    private func resetFloor() {
        floor = telemetry.frame(tap: node.tapId, type: .sfzKeyswitches)?.sequence
    }
}
