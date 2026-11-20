// Asset lifetime belongs to the DSP, so collapsed cards, undo and route changes
// restore these effects too. UI state only observes the result.
import Foundation
import Combine

@MainActor
final class ETCorrectionAssets: ObservableObject {
    static let shared = ETCorrectionAssets()
    @Published private(set) var status: [UUID: String] = [:]
    @Published private(set) var designs: [UUID: RoomEQDesign] = [:]
    private var signatures: [UUID: String] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var models: [String: ETSpeakerCorrection.Model] = [:]

    private var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DistortionCorrection", isDirectory: true)
    }

    private func modelURL(_ id: String) -> URL? {
        guard !id.isEmpty, id.count <= 128,
              id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0) }) else { return nil }
        return folder.appendingPathComponent(id).appendingPathExtension("json")
    }

    func model(_ id: String) -> ETSpeakerCorrection.Model? {
        if let cached = models[id] { return cached }
        guard let url = modelURL(id), let bytes = try? Data(contentsOf: url) else { return nil }
        guard let decoded = try? JSONDecoder().decode(ETSpeakerCorrection.Model.self, from: bytes) else { return nil }
        models[id] = decoded
        return decoded
    }

    func importMeasurement(_ data: Data, nodeID: UUID) throws {
        let measurement = try ETSpeakerCorrection.importMeasurement(data)
        guard let url = modelURL(measurement.id), let index = EffeTuneDSP.shared.slot(of: nodeID),
              let node = EffeTuneDSP.shared.node(at: index), node.spec.type == ETSpeakerCorrection.type else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(measurement).write(to: url, options: .atomic)
        models[measurement.id] = measurement
        // Like upstream's selection parameters: a new measurement starts in
        // Reduce at 0 dB, then adopts its saved amplifier check when present.
        let values = ETSpeakerCorrection.selectionValues(node, model: measurement)
        signatures[nodeID] = nil
        EffeTuneDSP.shared.setValues(values, at: index, design: measurement.selectionParameters)
        if measurement.usesSurround { EffeTuneDSP.shared.setRouting(at: index, channelSpec: -2) }
        // The same measurement can be used by several cards. Re-importing it
        // refreshes every reference, including cards that are currently folded.
        for other in EffeTuneDSP.shared.nodes where other.spec.type == ETSpeakerCorrection.type
            && other.design["ms"] == measurement.id {
            signatures[other.id] = nil
            sync(other)
        }
    }

    func eraseAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll(); signatures.removeAll(); designs.removeAll(); status.removeAll()
        models.removeAll()
        try? FileManager.default.removeItem(at: folder)
    }

    func sync(_ node: ETChainNode) {
        guard [ETHeadphoneEQ.type, ETSpeakerCorrection.type].contains(node.spec.type),
              node.instance != 0, !RemoteMirror.shared.isRemote else { return }
        let dsp = EffeTuneDSP.shared
        let lt = node.spec.params.first(where: { $0.key == "lt" }).map { node.values[$0.offset] } ?? 0
        let designKey = node.design.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "|")
        let signature = "\(dsp.prepareGeneration):\(node.instance):\(node.tapId):\(dsp.sampleRate):\(dsp.maxChannels):\(node.channelSpec):\(lt):\(designKey)"
        guard signatures[node.id] != signature else { return }
        signatures[node.id] = signature
        tasks[node.id]?.cancel()
        tasks = tasks.filter { dsp.slot(of: $0.key) != nil }
        signatures = signatures.filter { dsp.slot(of: $0.key) != nil }
        designs = designs.filter { dsp.slot(of: $0.key) != nil }
        status = status.filter { dsp.slot(of: $0.key) != nil }
        status[node.id] = "Preparing correction…"
        let sampleRate = Int(dsp.sampleRate.rounded())
        let generation = dsp.prepareGeneration
        let width = max(1, EffeTuneDSP.routedChannels(of: node))
        let outputChannels = dsp.maxChannels
        tasks[node.id] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self, self.signatures[node.id] == signature,
                  dsp.prepareGeneration == generation, !RemoteMirror.shared.isRemote,
                  let slot = dsp.slot(of: node.id), dsp.node(at: slot)?.instance == node.instance else { return }
            do {
                if node.spec.type == ETHeadphoneEQ.type {
                    let settings = ETHeadphoneEQ.Settings(node.design, sampleRate: sampleRate)
                    let latency = RoomEQDesigner.latencyMode(fromParameterValue: lt)
                    try RoomEQDesigner.checkCapacity(config: settings.config, channelCount: 1,
                                                     processingChannels: width, latencyMode: latency)
                    let result = await Task.detached(priority: .userInitiated) { settings.design() }.value
                    guard !Task.isCancelled, self.signatures[node.id] == signature,
                          dsp.prepareGeneration == generation, !RemoteMirror.shared.isRemote, let slot = dsp.slot(of: node.id),
                          let current = dsp.node(at: slot), current.instance == node.instance else { return }
                    if let fd = current.spec.params.first(where: { $0.key == "fd" }) {
                        dsp.setValue(Float(result.filterDelaySamples), at: slot, offset: fd.offset)
                    }
                    try AssetUpload.send(engine: dsp.engine, instance: node.instance, channels: result.channels,
                                         sampleRate: sampleRate, topology: .mono, headBlock: latency,
                                         processingChannels: UInt32(width))
                    self.designs[node.id] = result
                    let headroom = result.previews.first.flatMap { $0 }?.headroomDb ?? 0
                    self.status[node.id] = settings.hasCorrection
                        ? String(format: "Correction prepared. Headroom: %.1f dB.", headroom)
                        : (settings.measurement.isEmpty ? "Load a headphone measurement to start." : "Load a target curve to apply the correction.")
                } else {
                    guard let measurement = self.model(node.design["ms"] ?? "") else {
                        AssetUpload.clear(engine: dsp.engine, instance: node.instance)
                        self.status[node.id] = "Import a speaker distortion measurement from EffeTune."
                        if let slot = dsp.slot(of: node.id) { dsp.setRouting(at: slot) }
                        return
                    }
                    let payload = try ETSpeakerCorrection.payload(measurement, settings: .init(node.design),
                                                                  outputChannels: Int(outputChannels))
                    let info = AssetUpload.BeginInfo(headBlock: 0, processingChannels: outputChannels,
                                                    footprintBytes: UInt32(payload.count))
                    try AssetUpload.send(engine: dsp.engine, instance: node.instance, payload: payload, info: info)
                    self.status[node.id] = sampleRate < 44100
                        ? "This sample rate is not supported. Distortion Correction is bypassed."
                        : "Correction prepared for \(measurement.name)."
                }
                if let slot = dsp.slot(of: node.id) { dsp.setRouting(at: slot) }
                let active = await AssetUpload.waitForActive(engine: dsp.engine, instance: node.instance)
                guard !Task.isCancelled, self.signatures[node.id] == signature,
                      dsp.prepareGeneration == generation, !RemoteMirror.shared.isRemote else { return }
                if active.state == .error { throw ETAssetUploadError.commitFailed(status: Int32(active.raw)) }
            } catch {
                guard !Task.isCancelled, self.signatures[node.id] == signature,
                      dsp.prepareGeneration == generation, !RemoteMirror.shared.isRemote else { return }
                self.status[node.id] = error.localizedDescription
                // A changed measurement must never keep an unrelated old correction.
                AssetUpload.clear(engine: dsp.engine, instance: node.instance)
                self.designs[node.id] = nil
                if let slot = dsp.slot(of: node.id) { dsp.setRouting(at: slot) }
            }
        }
    }
}
