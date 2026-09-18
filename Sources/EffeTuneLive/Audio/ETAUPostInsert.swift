//  ETAUPostInsert.swift
//  AUv3をEffeTuneの後段へ挿すためのホスト層。
//
//  実行経路はAudioIOが所有する。ここはAUの発見・非同期生成・状態と
//  パラメータの橋渡しだけを担当し、JSFXホストとは共有しない。

import AVFoundation
import AudioToolbox

@MainActor
final class ETAUPostInsert: ObservableObject {

    struct Entry: Identifiable {
        let description: AudioComponentDescription
        let name: String
        let manufacturer: String

        var id: String {
            "\(description.componentType):\(description.componentSubType):\(description.componentManufacturer)"
        }

        var title: String {
            manufacturer.isEmpty ? name : "\(manufacturer): \(name)"
        }
    }

    static let shared = ETAUPostInsert()

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var loadedTitle: String?
    @Published private(set) var status = "Off"
    @Published var bypass = false

    private(set) var audioUnit: AVAudioUnit?
    private var units: [String: AVAudioUnit] = [:]
    private let selectedKey = "audio.auPostInsert"
    private let bypassKey = "audio.auPostInsert.bypass"
    private let parametersKey = "audio.auPostInsert.parameters"

    private init() {
        refresh()
        selectedID = UserDefaults.standard.string(forKey: selectedKey)
        bypass = UserDefaults.standard.bool(forKey: bypassKey)
        if let selectedID,
           let entry = entries.first(where: { $0.id == selectedID }) {
            Task { await load(entry) }
        }
    }

    func refresh() {
        let description = AudioComponentDescription(componentType: kAudioUnitType_Effect,
                                                     componentSubType: 0,
                                                     componentManufacturer: 0,
                                                     componentFlags: 0,
                                                     componentFlagsMask: 0)
        entries = AVAudioUnitComponentManager.shared().components(matching: description)
            .map { Entry(description: $0.audioComponentDescription,
                         name: $0.name,
                         manufacturer: $0.manufacturerName) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func choose(_ entry: Entry) {
        Task { await load(entry) }
    }

    /// Restore an AU referenced by an external pipeline node without changing
    /// the picker selection. Multiple AU nodes can therefore coexist.
    func ensureLoaded(id: String) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        Task { await load(entry, select: false) }
    }

    func externalIndex(for entry: Entry) -> UInt8 {
        ETAUExternalBridge.shared.index(for: entry.id)
    }

    func clear() {
        audioUnit = nil
        units.removeAll()
        ETAUExternalBridge.shared.clear()
        selectedID = nil
        loadedTitle = nil
        status = "Off"
        UserDefaults.standard.removeObject(forKey: selectedKey)
        AudioIO.shared.rebuildForExternalProcessor()
    }

    func setBypass(_ value: Bool) {
        bypass = value
        UserDefaults.standard.set(value, forKey: bypassKey)
        audioUnit?.auAudioUnit.shouldBypassEffect = value
    }

    var parameters: [AUParameter] {
        audioUnit?.auAudioUnit.parameterTree?.allParameters ?? []
    }

    func parameterValue(_ parameter: AUParameter) -> Double {
        Double(parameter.value)
    }

    func setParameter(_ parameter: AUParameter, value: Double) {
        parameter.value = AUValue(value)
        var values = UserDefaults.standard.dictionary(forKey: parametersKey) ?? [:]
        values[String(parameter.address)] = NSNumber(value: value)
        UserDefaults.standard.set(values, forKey: parametersKey)
        objectWillChange.send()
    }

    private func load(_ entry: Entry, select: Bool = true) async {
        status = "Loading…"
        do {
            let unit: AVAudioUnit
            if let cached = units[entry.id] {
                unit = cached
            } else {
                unit = try await AVAudioUnit.instantiate(with: entry.description)
                units[entry.id] = unit
            }
            ETAUExternalBridge.shared.install(unit,
                                              index: ETAUExternalBridge.shared.index(for: entry.id))
            unit.auAudioUnit.shouldBypassEffect = bypass
            if select {
                audioUnit = unit
                restoreParameters()
                selectedID = entry.id
                loadedTitle = entry.title
                UserDefaults.standard.set(entry.id, forKey: selectedKey)
                AudioIO.shared.rebuildForExternalProcessor()
            }
            status = "Loaded"
        } catch {
            status = "Failed: \(error.localizedDescription)"
        }
    }

    private func restoreParameters() {
        guard let values = UserDefaults.standard.dictionary(forKey: parametersKey) else { return }
        for parameter in parameters {
            if let number = values[String(parameter.address)] as? NSNumber {
                let value = number.doubleValue
                parameter.value = AUValue(min(max(value, Double(parameter.minValue)),
                                             Double(parameter.maxValue)))
            }
        }
    }
}
