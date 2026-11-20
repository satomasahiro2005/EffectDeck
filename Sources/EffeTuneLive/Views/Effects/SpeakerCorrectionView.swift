import SwiftUI
import UniformTypeIdentifiers

struct SpeakerCorrectionView: View {
    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP
    @ObservedObject private var assets = ETCorrectionAssets.shared
    @ObservedObject private var telemetry = Telemetry.shared
    @State private var importing = false
    @State private var failure: String?
    @State private var overloadUntil = Date.distantPast

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    ETTextActionButton(title: "Import measurement…") { importing = true }
                    if node.design["ms"]?.isEmpty == false {
                        ETTextActionButton(title: "Remove") { change(["ms": "", "mn": ""]) }
                    }
                }
                Text("Import the measurement JSON from EffeTune's Acoustic Measurement. Keep the same speakers and amplifier settings used for that measurement.")
                    .etFont(size: 11).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(failure ?? assets.status[node.id] ?? "No measurement loaded.")
                    .etFont(size: 11).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if context.date < overloadUntil {
                        Text("Correction exceeded the measured range. Lower the input level.")
                            .etFont(size: 11).foregroundStyle(.orange)
                    }
                }
            }.etLocalAudioOnly()
            Picker("Filter Length", selection: Binding(get: { node.design["fl"] ?? "Short" }, set: { change(["fl": $0]) })) {
                Text("Short").tag("Short"); Text("Long").tag("Long")
            }.pickerStyle(.segmented)
            ForEach(node.spec.params.filter { !$0.runtimeOnly }) { param in
                ParameterRow(param: param, nodeIndex: index, values: node.values, dsp: dsp)
            }
            if let model = assets.model(node.design["ms"] ?? "") {
                ForEach(model.channels, id: \.index) { channel in
                    VStack(alignment: .leading) {
                        Text(channel.label.isEmpty ? "Ch \(channel.index + 1)" : channel.label).etFont(size: 11, weight: .semibold)
                        channelPicker(channel.index, odd: false)
                        if channel.odd != nil { channelPicker(channel.index, odd: true) }
                    }
                }
            }
        }
        .onAppear { assets.sync(node) }
        .onChange(of: telemetry.frame(tap: node.tapId, type: .level)?.sequence) { _, _ in
            if let frame = telemetry.frame(tap: node.tapId, type: .level), frame.version == 1,
               frame.payload.count == 4, let peak = frame.floats.first, peak.isFinite, peak > 1 {
                overloadUntil = Date().addingTimeInterval(5)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                try assets.importMeasurement(Data(contentsOf: url), nodeID: node.id)
                failure = nil
            } catch {
                if (error as? CocoaError)?.code != .userCancelled { failure = error.localizedDescription }
            }
        }
    }

    private func channelPicker(_ channel: Int, odd: Bool) -> some View {
        Picker(odd ? "Odd-order correction" : "Even-order correction", selection: Binding(
            get: { ETSpeakerCorrection.Settings(node.design).position(channel, odd: odd) },
            set: { position in
                let settings = ETSpeakerCorrection.Settings(node.design)
                var on = odd ? settings.cn3 : settings.cn
                var off = odd ? settings.co3 : settings.co
                on &= ~(1 << channel); off &= ~(1 << channel)
                if position == "on" { on |= 1 << channel }
                if position == "off" { off |= 1 << channel }
                change([odd ? "cn3" : "cn": String(on), odd ? "co3" : "co": String(off)])
            })) {
                Text("Auto").tag("auto"); Text("On").tag("on"); Text("Off").tag("off")
            }.pickerStyle(.menu)
    }

    private func change(_ values: [String: String]) {
        guard let slot = dsp.slot(of: node.id), let current = dsp.node(at: slot) else { return }
        dsp.setDesign(current.design.merging(values) { _, new in new }, nodeID: node.id)
    }
}
