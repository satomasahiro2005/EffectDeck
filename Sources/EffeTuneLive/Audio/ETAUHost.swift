// ETAUHost.swift
// Audio Unit discovery, instance lifecycle, state and UI hosting.

import AVFoundation
import AudioToolbox
import CoreAudioKit
import UIKit

@MainActor
final class ETAUHost: ObservableObject {
    struct Entry: Identifiable, Hashable {
        let description: AudioComponentDescription
        let name: String
        let manufacturer: String

        var id: String {
            "\(description.componentType):\(description.componentSubType):\(description.componentManufacturer)"
        }

        var title: String { manufacturer.isEmpty ? name : "\(manufacturer): \(name)" }

        static func == (lhs: Entry, rhs: Entry) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    private final class Instance {
        let id: String
        let componentID: String
        let entry: Entry
        var unit: AUAudioUnit?
        var viewController: UIViewController?
        var parameterObserver: AUParameterObserverToken?
        var loadTask: Task<Void, Never>?
        var loading = true
        var error: String?
        var channels: Int
        var latencySamples: UInt32 = 0

        init(id: String, componentID: String, entry: Entry, channels: Int) {
            self.id = id
            self.componentID = componentID
            self.entry = entry
            self.channels = channels
        }
    }

    static let shared = ETAUHost()

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var revision = 0
    private var instances: [String: Instance] = [:]
    private struct RenderConfiguration {
        let sampleRate: Double
        let outputChannels: Int
        let maxFrames: Int
    }
    private var renderConfiguration: RenderConfiguration?

    private init() { refresh() }

    func refresh() {
        let manager = AVAudioUnitComponentManager.shared()
        let types: [OSType] = [kAudioUnitType_Effect, kAudioUnitType_MusicEffect]
        var found: [Entry] = []
        for type in types {
            let query = AudioComponentDescription(componentType: type,
                                                   componentSubType: 0,
                                                   componentManufacturer: 0,
                                                   componentFlags: 0,
                                                   componentFlagsMask: 0)
            found += manager.components(matching: query).map {
                Entry(description: $0.audioComponentDescription,
                      name: $0.name,
                      manufacturer: $0.manufacturerName)
            }
        }
        entries = Array(Set(found)).sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    func entry(id: String) -> Entry? { entries.first { $0.id == id } }

    func create(_ entry: Entry, instanceID: String, state: Data? = nil,
                channels: Int = 2) {
        guard instances[instanceID] == nil else { return }
        let instance = Instance(id: instanceID, componentID: entry.id,
                                entry: entry, channels: channels)
        instances[instanceID] = instance
        revision &+= 1

        instance.loadTask = Task { @MainActor [weak self, weak instance] in
            guard let self, let instance else { return }
            do {
                _ = try ETAUExternalBridge.shared.reserve(instanceID: instanceID)
                let unit = try await AUAudioUnit.instantiate(with: entry.description,
                                                             options: [])
                guard !Task.isCancelled, self.instances[instanceID] === instance else { return }
                if let state, let decoded = try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(state)
                    as? [String: Any] {
                    unit.fullStateForDocument = decoded
                }
                instance.unit = unit
                if let configuration = self.renderConfiguration {
                    try self.install(instance, configuration: configuration)
                }
                if let tree = unit.parameterTree {
                    instance.parameterObserver = tree.token(byAddingParameterObserver: {
                        [weak self] _, _ in
                        Task { @MainActor in
                            guard let self,
                                  self.instances[instanceID] === instance else { return }
                            self.revision &+= 1
                            let latency = self.latencySamples(for: instance)
                            if latency != instance.latencySamples {
                                instance.latencySamples = latency
                                EffeTuneDSP.shared.republish(reason: "Audio Unit latency changed")
                            }
                            EffeTuneDSP.shared.externalStateDidChange(instanceID: instanceID)
                        }
                    })
                }
                instance.loading = false
                instance.error = nil
            } catch {
                guard self.instances[instanceID] === instance else { return }
                instance.loading = false
                instance.error = error.localizedDescription
                ETAUExternalBridge.shared.remove(instanceID: instanceID)
            }
            instance.loadTask = nil
            self.revision &+= 1
        }
    }

    func restore(componentID: String, instanceID: String, state: Data?, channels: Int = 2) {
        guard let entry = entry(id: componentID) else {
            revision &+= 1
            return
        }
        create(entry, instanceID: instanceID, state: state, channels: channels)
    }

    func remove(instanceID: String) {
        if let instance = instances.removeValue(forKey: instanceID) {
            instance.loadTask?.cancel()
            if let token = instance.parameterObserver,
               let tree = instance.unit?.parameterTree {
                tree.removeParameterObserver(token)
            }
        }
        ETAUExternalBridge.shared.remove(instanceID: instanceID)
        revision &+= 1
    }

    func removeAll() {
        ETAUExternalBridge.shared.clear()
        for instance in instances.values {
            instance.loadTask?.cancel()
            if let token = instance.parameterObserver,
               let tree = instance.unit?.parameterTree {
                tree.removeParameterObserver(token)
            }
        }
        instances.removeAll()
        revision &+= 1
    }

    func suspend() {
        renderConfiguration = nil
        ETAUExternalBridge.shared.suspend()
    }

    func resume(sampleRate: Double, outputChannels: Int, maxFrames: Int) {
        let configuration = RenderConfiguration(sampleRate: sampleRate,
                                                outputChannels: outputChannels,
                                                maxFrames: maxFrames)
        renderConfiguration = configuration
        for instance in instances.values {
            guard let unit = instance.unit else { continue }
            do {
                _ = unit // keep the guard explicit: unloaded instances resume after instantiate
                try install(instance, configuration: configuration)
                instance.error = nil
            } catch {
                instance.error = error.localizedDescription
            }
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
        guard let instance = instances[instanceID] else { return "Audio Unit unavailable" }
        if let error = instance.error { return error }
        return instance.loading ? "Loading…" : "Ready"
    }

    func providesUserInterface(instanceID: String) -> Bool? {
        guard let instance = instances[instanceID], !instance.loading else { return nil }
        return instance.unit?.providesUserInterface ?? false
    }

    func parameters(instanceID: String) -> [AUParameter] {
        instances[instanceID]?.unit?.parameterTree?.allParameters ?? []
    }

    func setParameter(_ parameter: AUParameter, value: Double) {
        parameter.value = AUValue(min(max(value, Double(parameter.minValue)),
                                      Double(parameter.maxValue)))
        revision &+= 1
    }

    func stateData(instanceID: String) -> Data? {
        guard let state = instances[instanceID]?.unit?.fullStateForDocument else {
            return nil
        }
        return try? NSKeyedArchiver.archivedData(withRootObject: state,
                                                  requiringSecureCoding: false)
    }

    func requestViewController(instanceID: String,
                               completion: @escaping (UIViewController?) -> Void) {
        guard let instance = instances[instanceID], let unit = instance.unit else {
            completion(nil)
            return
        }
        if let controller = instance.viewController {
            completion(controller)
            return
        }
        guard unit.providesUserInterface else {
            completion(nil)
            return
        }
        unit.requestViewController { [weak self, weak instance] controller in
            Task { @MainActor in
                instance?.viewController = controller
                self?.revision &+= 1
                completion(controller)
            }
        }
    }

    func viewSnapshot(instanceID: String) -> UIImage? {
        guard let view = instances[instanceID]?.viewController?.view,
              view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = view.window?.screen.scale ?? UIScreen.main.scale
        return UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            if !view.drawHierarchy(in: view.bounds, afterScreenUpdates: false) {
                view.layer.render(in: UIGraphicsGetCurrentContext()!)
            }
        }
    }

    private func install(_ instance: Instance,
                         configuration: RenderConfiguration) throws {
        guard let unit = instance.unit else { return }
        _ = try ETAUExternalBridge.shared.install(
            unit,
            instanceID: instance.id,
            sampleRate: configuration.sampleRate,
            channels: min(instance.channels, configuration.outputChannels),
            maxFrames: configuration.maxFrames)
        instance.latencySamples = UInt32(max(
            0, (unit.latency * configuration.sampleRate).rounded(.up)))
    }

    private func latencySamples(for instance: Instance) -> UInt32 {
        guard let unit = instance.unit else { return 0 }
        let sampleRate = renderConfiguration?.sampleRate ?? EffeTuneDSP.shared.sampleRate
        return UInt32(max(0, (unit.latency * sampleRate).rounded(.up)))
    }
}
