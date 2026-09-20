//  VirtualRoomView.swift
//  Virtual Room のカード（docs/virtual-room-design.md §4〜§11、§42）。
//
//  専用のカードの殻は作らない。EffectCardView の中身だけを差し替える。
//  入切・Routing・Effect Presets・Reset Parameters・移動・削除は既存のまま。
//
//  畳んだとき（etGraphOnly）は真上から見た図だけを出す（§5、§6）。

import SwiftUI
import UniformTypeIdentifiers

struct VirtualRoomView: View {
    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    @Environment(\.etGraphOnly) private var graphOnly
    @State private var advanced = false
    @State private var exporting = false
    @State private var rendering = false
    @State private var exportFile: ETBRIRDocument?
    @State private var report = ""

    var body: some View {
        if graphOnly {
            VirtualRoomSceneView(layout: layout, interactive: false)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                VirtualRoomSceneView(layout: layout, interactive: true,
                                     moveListener: moveListener,
                                     moveSpeaker: moveSpeaker)
                if layout.clamped {
                    Text("The speakers do not fit in this room, so they are being placed as far out as the walls allow. Widen the room to get the distance back.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                group("Room", [ETVirtualRoom.Key.width, ETVirtualRoom.Key.depth,
                               ETVirtualRoom.Key.height])
                group("Speakers", [ETVirtualRoom.Key.speakerAngle,
                                   ETVirtualRoom.Key.speakerDistance])
                group("Acoustics", [ETVirtualRoom.Key.roomAmount,
                                    ETVirtualRoom.Key.decayScale])
                DisclosureGroup("Advanced", isExpanded: $advanced) {
                    VStack(alignment: .leading, spacing: 12) {
                        group("Listener", ETVirtualRoom.listenerKeys)
                        group("Speakers", ETVirtualRoom.speakerAdvancedKeys)
                        group("Surfaces", ETVirtualRoom.surfaceKeys)
                        group("Binaural", ETVirtualRoom.binauralKeys)
                        group("Rendering", ETVirtualRoom.renderingKeys)
                        randomization
                        group("Output", ETVirtualRoom.outputKeys)
                    }
                    .padding(.top, 8)
                }
                .font(.system(size: 14))
                exportRow
            }
        }
    }

    // MARK: - 節

    @ViewBuilder
    private func group(_ title: String, _ keys: [String]) -> some View {
        let params = keys.compactMap(param)
        if !params.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                ForEach(params) { param in
                    ParameterRow(param: param, nodeIndex: index,
                                 values: node.values, dsp: dsp)
                }
            }
        }
    }

    /// §11 Randomization。seed は 16 進で見せる。
    /// 押したときだけ変える。**部屋の形は変わらない**（後ろの拡散だけ）。
    private var randomization: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Randomization").font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Diffusion Seed").font(.system(size: 14))
                Spacer(minLength: 8)
                Text(ETVirtualRoom.seedText(seed))
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button("Randomize") { randomize() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            Text("Changes how the late field is scattered. The room itself stays the same.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// §42。押したときだけ作る。IR Library へは登録しない。
    private var exportRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                exportBRIR()
            } label: {
                if rendering {
                    Label("Rendering…", systemImage: "waveform")
                } else {
                    Label("Export 4-channel BRIR…", systemImage: "square.and.arrow.up")
                }
            }
            .disabled(rendering)
            .fileExporter(isPresented: $exporting, document: exportFile,
                          contentType: .wav,
                          defaultFilename: "Virtual Room BRIR") { result in
                if case .failure(let error) = result { report = error.localizedDescription }
                exportFile = nil
            }
            if !report.isEmpty {
                Text(report).font(.caption).foregroundStyle(.secondary)
            }
            Text("Renders the room you are hearing now as LL, LR, RL, RR — the channel order EffeTune's IR Reverb expects.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - 値

    private func param(_ key: String) -> ETParam? {
        node.spec.params.first { $0.key == key }
    }

    private func value(_ key: String) -> Double {
        guard let p = param(key), node.values.indices.contains(p.offset) else { return 0 }
        return Double(node.values[p.offset])
    }

    private func set(_ key: String, _ v: Double) {
        guard let p = param(key) else { return }
        dsp.setValue(Float(clamp(v, to: p)), at: index, offset: p.offset)
    }

    private func clamp(_ v: Double, to param: ETParam) -> Double {
        guard case .number(let lo, let hi, _, _, _) = param.kind else { return v }
        return min(max(v, Double(lo)), Double(hi))
    }

    private var seed: UInt32 {
        ETVirtualRoom.seed(low: Float(value(ETVirtualRoom.Key.seedLow)),
                           high: Float(value(ETVirtualRoom.Key.seedHigh)))
    }

    private var layout: ETVirtualRoom.Layout {
        ETVirtualRoom.layout(width: value(ETVirtualRoom.Key.width),
                             depth: value(ETVirtualRoom.Key.depth),
                             listenerX: value(ETVirtualRoom.Key.listenerX),
                             listenerY: value(ETVirtualRoom.Key.listenerY),
                             angle: value(ETVirtualRoom.Key.speakerAngle),
                             distance: value(ETVirtualRoom.Key.speakerDistance))
    }

    // MARK: - 図から触る

    private func moveListener(_ point: CGPoint) {
        let percent = ETVirtualRoom.listenerPercent(point, width: layout.width,
                                                    depth: layout.depth)
        // 2 本同時に動くので 1 回の set_params にまとめる（§36）。
        var values = node.values
        write(&values, ETVirtualRoom.Key.listenerX, percent.x)
        write(&values, ETVirtualRoom.Key.listenerY, percent.y)
        dsp.setValues(values, at: index)
    }

    private func moveSpeaker(_ point: CGPoint) {
        let polar = ETVirtualRoom.speakerPolar(point, listener: layout.listener)
        var values = node.values
        write(&values, ETVirtualRoom.Key.speakerAngle, polar.angle)
        write(&values, ETVirtualRoom.Key.speakerDistance, polar.distance)
        dsp.setValues(values, at: index)
    }

    private func randomize() {
        let parts = ETVirtualRoom.seedParts(UInt32.random(in: UInt32.min...UInt32.max))
        var values = node.values
        write(&values, ETVirtualRoom.Key.seedLow, Double(parts.low))
        write(&values, ETVirtualRoom.Key.seedHigh, Double(parts.high))
        dsp.setValues(values, at: index)
    }

    private func write(_ values: inout [Float], _ key: String, _ v: Double) {
        guard let p = param(key), values.indices.contains(p.offset) else { return }
        values[p.offset] = Float(clamp(v, to: p))
    }

    // MARK: - 書き出す

    private func exportBRIR() {
        report = ""
        rendering = true
        let spec = node.spec
        let values = node.values
        let rate = dsp.sampleRate
        Task.detached(priority: .userInitiated) {
            do {
                let url = try ETVirtualRoomBRIR.export(spec: spec, values: values,
                                                       sampleRate: rate)
                let data = try Data(contentsOf: url)
                try? FileManager.default.removeItem(at: url)
                await MainActor.run {
                    exportFile = ETBRIRDocument(data: data)
                    rendering = false
                    exporting = true
                }
            } catch {
                await MainActor.run {
                    report = error.localizedDescription
                    rendering = false
                }
            }
        }
    }
}

/// .fileExporter へ渡す入れ物。中身は ETVirtualRoomBRIR が書いた WAV そのまま。
struct ETBRIRDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.wav] }

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
