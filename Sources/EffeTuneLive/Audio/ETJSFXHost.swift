// ETJSFXHost.swift
// JSFX discovery, portable EEL2 execution, parameters and state.

import Foundation

@MainActor
final class ETJSFXHost: ObservableObject {
    struct Entry: Identifiable, Hashable {
        let id: String
        let name: String
        let author: String
        let url: URL
    }

    struct Parameter: Identifiable {
        let id: UInt32
        let name: String
        let minimum: Double
        let maximum: Double
        let step: Double
        let visible: Bool
        var value: Double
    }

    private struct SavedState: Codable { var sliders: [String: Double] }
    private struct RenderConfiguration {
        let sampleRate: Double
        let outputChannels: Int
        let maxFrames: Int
    }

    private final class Instance {
        let id: String
        let entry: Entry
        var host: OpaquePointer?
        var parameters: [Parameter] = []
        var saved: [String: Double]
        var channels: Int
        var error: String?

        init(id: String, entry: Entry, state: Data?, channels: Int) {
            self.id = id
            self.entry = entry
            self.channels = channels
            saved = (state.flatMap { try? JSONDecoder().decode(SavedState.self, from: $0) })?.sliders ?? [:]
        }
    }

    static let shared = ETJSFXHost()

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var revision = 0
    private var instances: [String: Instance] = [:]
    // Descriptors may still be visible to an in-flight render callback. Keep
    // removed runtimes alive for the process lifetime, as the AU bridge does.
    private var retired: [OpaquePointer] = []
    private var renderConfiguration: RenderConfiguration?

    private init() { refresh() }

    func refresh() {
        #if DEBUG
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("DebugJSFXFactory", isDirectory: true),
              let enumerator = FileManager.default.enumerator(at: root,
                                                               includingPropertiesForKeys: nil,
                                                               options: [.skipsHiddenFiles]) else {
            entries = []
            return
        }
        entries = enumerator.compactMap { item -> Entry? in
            guard let url = item as? URL, url.pathExtension.lowercased() == "jsfx" else { return nil }
            let header = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let metadata = Self.metadata(header)
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            return Entry(id: "jsfx:" + relative,
                         name: metadata.name ?? url.deletingPathExtension().lastPathComponent,
                         author: metadata.author ?? "", url: url)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        #else
        entries = []
        #endif
    }

    func entry(id: String) -> Entry? { entries.first { $0.id == id } }

    func create(_ entry: Entry, instanceID: String, state: Data? = nil, channels: Int = 2) {
        guard instances[instanceID] == nil else { return }
        let instance = Instance(id: instanceID, entry: entry, state: state, channels: channels)
        instances[instanceID] = instance
        do {
            _ = try ETAUExternalBridge.shared.reserve(instanceID: instanceID)
            if let configuration = renderConfiguration { try load(instance, configuration: configuration) }
        } catch {
            instance.error = error.localizedDescription
        }
        revision &+= 1
    }

    func restore(componentID: String, instanceID: String, state: Data?, channels: Int = 2) {
        guard let entry = entry(id: componentID) else { return }
        create(entry, instanceID: instanceID, state: state, channels: channels)
    }

    func remove(instanceID: String) {
        ETAUExternalBridge.shared.remove(instanceID: instanceID)
        if let host = instances.removeValue(forKey: instanceID)?.host { retired.append(host) }
        revision &+= 1
    }

    func removeAll() {
        for id in Array(instances.keys) { remove(instanceID: id) }
    }

    func suspend() { renderConfiguration = nil }

    func resume(sampleRate: Double, outputChannels: Int, maxFrames: Int) {
        let configuration = RenderConfiguration(sampleRate: sampleRate,
                                                outputChannels: outputChannels,
                                                maxFrames: maxFrames)
        renderConfiguration = configuration
        for instance in instances.values {
            do { try load(instance, configuration: configuration) }
            catch { instance.error = error.localizedDescription }
        }
        revision &+= 1
    }

    func externalIndex(instanceID: String) -> UInt8? {
        ETAUExternalBridge.shared.index(for: instanceID)
    }

    func setChannels(_ channels: Int, instanceID: String) {
        instances[instanceID]?.channels = channels
    }

    func status(instanceID: String) -> String {
        guard let instance = instances[instanceID] else { return "JSFX unavailable" }
        if let error = instance.error { return error }
        return instance.host == nil ? "Waiting for audio…" : "Ready"
    }

    func parameters(instanceID: String) -> [Parameter] {
        instances[instanceID]?.parameters.filter(\.visible) ?? []
    }

    func setParameter(instanceID: String, parameterID: UInt32, value: Double) {
        guard let instance = instances[instanceID], let host = instance.host,
              let offset = instance.parameters.firstIndex(where: { $0.id == parameterID }) else { return }
        let parameter = instance.parameters[offset]
        let clamped = min(max(value, parameter.minimum), parameter.maximum)
        ETJSFX_SetSlider(host, parameterID, clamped)
        instance.parameters[offset].value = clamped
        instance.saved[String(parameterID)] = clamped
        revision &+= 1
        EffeTuneDSP.shared.externalStateDidChange(instanceID: instanceID)
    }

    func stateData(instanceID: String) -> Data? {
        guard let instance = instances[instanceID] else { return nil }
        return try? JSONEncoder().encode(SavedState(sliders: instance.saved))
    }

    private func load(_ instance: Instance, configuration: RenderConfiguration) throws {
        if let host = instance.host {
            ETJSFX_Configure(host, configuration.sampleRate, UInt32(configuration.maxFrames))
            _ = try ETAUExternalBridge.shared.install(ETJSFX_Processor(host), instanceID: instance.id)
            instance.error = nil
            return
        }

        var message = [CChar](repeating: 0, count: 2048)
        let importRoot = instance.entry.url.deletingLastPathComponent().path
        let host = instance.entry.url.path.withCString { path in
            importRoot.withCString { root in
                ETJSFX_Create(path, root, configuration.sampleRate,
                              UInt32(configuration.maxFrames), &message, message.count)
            }
        }
        guard let host else {
            let text = String(cString: message)
            throw NSError(domain: "ETJSFXHost", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: text.isEmpty
                                     ? "Could not load JSFX." : text])
        }
        instance.host = host
        instance.parameters = Self.readParameters(host)
        for (key, value) in instance.saved {
            if let index = UInt32(key) { ETJSFX_SetSlider(host, index, value) }
        }
        instance.parameters = Self.readParameters(host)
        _ = try ETAUExternalBridge.shared.install(ETJSFX_Processor(host), instanceID: instance.id)
        instance.error = nil
    }

    private static func readParameters(_ host: OpaquePointer) -> [Parameter] {
        (0..<ETJSFX_SliderCount(host)).compactMap { ordinal in
            var index: UInt32 = 0
            var name: UnsafePointer<CChar>?
            var value = 0.0, minimum = 0.0, maximum = 1.0, step = 0.0
            var visible = true
            guard ETJSFX_SliderInfo(host, ordinal, &index, &name, &value,
                                    &minimum, &maximum, &step, &visible) else { return nil }
            return Parameter(id: index, name: name.map(String.init(cString:)) ?? "Slider \(index + 1)",
                             minimum: minimum, maximum: maximum, step: step,
                             visible: visible, value: value)
        }
    }

    private static func metadata(_ source: String) -> (name: String?, author: String?) {
        var name: String?, author: String?
        for rawLine in source.split(whereSeparator: { $0.isNewline }).prefix(80) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("desc:") { name = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
            if line.hasPrefix("author:") { author = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        }
        return (name, author)
    }
}
