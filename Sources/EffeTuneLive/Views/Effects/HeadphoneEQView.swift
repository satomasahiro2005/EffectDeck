import SwiftUI
import UniformTypeIdentifiers

struct HeadphoneEQView: View {
    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP
    @ObservedObject private var assets = ETCorrectionAssets.shared
    @Environment(\.etGraphOnly) private var graphOnly
    @State private var importing = false
    @State private var importingTarget = false
    @State private var query = ""
    @State private var matches: [ETHeadphoneEQ.AutoEQEntry] = []
    @State private var entries: [ETHeadphoneEQ.AutoEQEntry] = []
    @State private var download: Task<Void, Never>?
    @State private var busy = false
    @State private var failure: String?
    @State private var band = 0

    private var settings: ETHeadphoneEQ.Settings {
        .init(node.design, sampleRate: Int(dsp.sampleRate.rounded()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !graphOnly {
                imports.etLocalAudioOnly()
                Text(failure ?? assets.status[node.id] ?? "Load a headphone measurement to start.")
                    .etFont(size: 11).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).etLocalAudioOnly()
                controls
                ForEach(node.spec.params.filter { $0.key != "fd" }) { param in
                    ParameterRow(param: param, nodeIndex: index, values: node.values, dsp: dsp)
                }
            }
            graph.etLocalAudioOnly()
        }
        .onAppear { assets.sync(node) }
        .onDisappear { download?.cancel() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                try apply(String(contentsOf: url, encoding: .utf8), name: url.deletingPathExtension().lastPathComponent,
                          target: importingTarget)
            } catch {
                if (error as? CocoaError)?.code != .userCancelled { failure = error.localizedDescription }
            }
        }
    }

    private var imports: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Search headphones (AutoEQ) or paste a URL", text: $query)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().onSubmit(search)
                Button(action: search) { Image(systemName: "magnifyingglass") }
                    .accessibilityLabel("Search headphones").disabled(busy || query.trimmingCharacters(in: .whitespaces).isEmpty)
                if busy { ProgressView().controlSize(.small) }
            }
            ForEach(Array(matches.prefix(20))) { entry in
                Button(entry.label) { fetch(entry.url, name: entry.name) }
                    .font(.caption).multilineTextAlignment(.leading)
            }
            ViewThatFits(in: .horizontal) {
                HStack { importButton(target: false); importButton(target: true); clearButton }
                VStack(alignment: .leading) { importButton(target: false); importButton(target: true); clearButton }
            }
            Text("Measurement: " + (settings.measurementName.isEmpty ? "None" : settings.measurementName))
                .etFont(size: 11).foregroundStyle(.secondary)
            Text("Target: " + (settings.targetName.isEmpty ? "None" : settings.targetName))
                .etFont(size: 11).foregroundStyle(.secondary)
            Link("Measurements from AutoEQ by Jaakko Pasanen", destination: URL(string: "https://github.com/jaakkopasanen/AutoEq")!)
                .font(.caption)
        }
    }

    private func importButton(target: Bool) -> some View {
        ETTextActionButton(title: target ? "Load Target" : "Load Measurement") {
            importingTarget = target; importing = true
        }
    }

    private var clearButton: some View {
        ETTextActionButton(title: "Remove") {
            download?.cancel(); busy = false; matches = []; failure = nil
            change(["mr": "[]", "mt": "[]", "mn": "", "tn": ""])
        }.disabled(settings.measurement.isEmpty && settings.target.isEmpty)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Phase", selection: text("pm", default: "min")) {
                Text("Minimum Phase").tag("min"); Text("Linear Phase").tag("lin")
            }.pickerStyle(.menu)
            Picker("Taps", selection: number("tp", default: 32768)) {
                ForEach(RoomEQConfig.allowedTaps, id: \.self) { Text(String($0)).tag(Double($0)) }
            }.pickerStyle(.menu)
            numeric("Correction Amount", key: "ca", value: settings.config.correctionAmount * 100, range: -100...100, step: 1, unit: "%")
            numeric("Upper Limit", key: "uf", value: settings.config.highFrequency, range: 1000...20000, step: 100, unit: "Hz")
            numeric("Max Boost", key: "mb", value: settings.config.maxBoostDb, range: 0...18, step: 0.1, unit: "dB")
            numeric("Smoothing", key: "sm", value: settings.config.smoothing, range: 0.02...1, step: 0.01, unit: "oct")
            Toggle("Auto Headroom", isOn: flag("ah", default: true))
            targetAdjust
        }
        .disabled(!settings.hasCorrection)
    }

    private var targetAdjust: some View {
        let selected = settings.config.bands[band]
        return VStack(alignment: .leading, spacing: 8) {
            Text("Target Adjust").etFont(size: 11, weight: .semibold)
            Picker("Band", selection: $band) {
                ForEach(0..<5) { Text(String($0 + 1)).tag($0) }
            }.pickerStyle(.segmented)
            Toggle("Enabled", isOn: flag("ea\(band)", default: true))
            Picker("Type", selection: text("ta\(band)", default: "pk")) {
                Text("Peaking").tag("pk"); Text("LowShelv").tag("ls"); Text("HighShel").tag("hs")
            }.pickerStyle(.menu)
            numeric("Frequency", key: "fa\(band)", value: selected.frequency, range: 20...20000, step: 1, unit: "Hz")
            numeric("Gain", key: "ga\(band)", value: selected.gain, range: -20...20, step: 0.1, unit: "dB")
            numeric("Q", key: "qa\(band)", value: selected.q, range: 0.1...(selected.type == .peaking ? 10 : 2), step: 0.01, unit: "")
        }
    }

    private var graph: some View {
        let curves: [ETFrequencyCurve]
        if let preview = assets.designs[node.id]?.previews.first.flatMap({ $0 }) {
            let frequencies = preview.frequencies
            func curve(_ id: String, _ name: String, _ values: [Double], subdued: Bool) -> ETFrequencyCurve {
                ETFrequencyCurve(id: id, points: zip(frequencies, values).map { ETFreqPoint($0, $1) },
                                 subdued: subdued, name: name)
            }
            curves = [
                curve("measurement", "Measurement relative to target", preview.measuredDb.map { $0 - preview.referenceLevelDb }, subdued: true),
                curve("correction", "Correction", zip(preview.baseCorrectionDb, preview.equalizerDb).map { $0 + $1 + preview.headroomDb }, subdued: false)
            ]
        } else { curves = [] }
        return FrequencyResponseGraph(curves: curves, frequencyRange: 20...20000,
                                      decibelRange: -20...20, decibelStep: 6, height: 190)
    }

    private func numeric(_ title: String, key: String, value: Double,
                         range: ClosedRange<Double>, step: Double, unit: String) -> some View {
        VStack(spacing: 3) {
            HStack { Text(title); Spacer(); Text(String(format: "%.2f", value) + " " + unit).monospacedDigit() }
                .etFont(size: 11)
            Slider(value: Binding(get: { value }, set: { change([key: ETDesignParam.format($0)]) }), in: range, step: step)
                .accessibilityLabel(title)
        }
    }
    private func text(_ key: String, default fallback: String) -> Binding<String> {
        Binding(get: { node.design[key] ?? fallback }, set: { change([key: $0]) })
    }
    private func number(_ key: String, default fallback: Double) -> Binding<Double> {
        Binding(get: { ETDesignParam.number(node.design, key) ?? fallback }, set: { change([key: ETDesignParam.format($0)]) })
    }
    private func flag(_ key: String, default fallback: Bool) -> Binding<Bool> {
        Binding(get: { ETDesignParam.flag(node.design, key) ?? fallback }, set: { change([key: ETDesignParam.flag($0)]) })
    }
    private func change(_ values: [String: String]) {
        guard let slot = dsp.slot(of: node.id), let current = dsp.node(at: slot) else { return }
        dsp.setDesign(current.design.merging(values) { _, new in new }, nodeID: node.id)
    }
    private func apply(_ content: String, name: String, target: Bool = false) throws {
        let parsed = try ETHeadphoneEQ.parseResponse(content, target: target)
        var patch = [target ? "mt" : "mr": ETHeadphoneEQ.encodeCurve(parsed.response), target ? "tn" : "mn": name]
        if let embedded = parsed.target {
            patch["mt"] = ETHeadphoneEQ.encodeCurve(embedded); patch["tn"] = name + " target"
        }
        change(patch); failure = nil; matches = []
    }

    private func search() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        if let url = URL(string: term), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
            fetch(ETHeadphoneEQ.rawURL(url), name: url.deletingPathExtension().lastPathComponent); return
        }
        download?.cancel(); busy = true; failure = nil
        download = Task { @MainActor in
            defer { if !Task.isCancelled { busy = false } }
            do {
                if entries.isEmpty { entries = ETHeadphoneEQ.parseAutoEQIndex(try await read(ETHeadphoneEQ.autoEQIndexURL)) }
                guard !Task.isCancelled else { return }
                matches = entries.filter { $0.label.localizedCaseInsensitiveContains(term) }
                if matches.isEmpty { failure = "No matching headphones found." }
            } catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
    }
    private func fetch(_ url: URL, name: String) {
        download?.cancel(); busy = true; failure = nil
        download = Task { @MainActor in
            defer { if !Task.isCancelled { busy = false } }
            do {
                let content = try await read(url)
                guard !Task.isCancelled else { return }
                try apply(content, name: name)
            } catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
    }
    private func read(_ url: URL) async throws -> String {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              data.count <= 16 * 1024 * 1024, let text = String(data: data, encoding: .utf8) else {
            throw URLError(.badServerResponse)
        }
        return text
    }
}
