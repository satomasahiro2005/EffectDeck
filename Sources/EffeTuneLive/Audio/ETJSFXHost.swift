import CryptoKit
import Foundation
import UIKit

private final class ETJSFXMenuResult: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value: Int32 = 0
    private var finished = false
    func finish(_ newValue: Int32) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        finished = true; value = newValue; semaphore.signal()
    }
    func read() -> Int32 { lock.withLock { value } }
}

/// `gfx_showmenu` is synchronous by definition. Only the calling instance's
/// private GFX queue waits; audio and other JSFX instances keep running.
private let etJSFXMenuCallback: @convention(c)
    (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, Int32, Int32) -> Int32 = { _, menu, _, _ in
        guard let menu else { return 0 }
        let spec = String(cString: menu)
        let result = ETJSFXMenuResult()
        DispatchQueue.main.async {
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                    .first(where: { $0.activationState == .foregroundActive }),
                  let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController else {
                result.finish(0); return
            }
            var presenter = root
            while let shown = presenter.presentedViewController { presenter = shown }
            let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
            var identifier: Int32 = 1
            var depth = 0
            for raw in spec.split(separator: "|", omittingEmptySubsequences: false) {
                var text = String(raw), disabled = false, checked = false
                if text.hasPrefix("<") { depth = max(0, depth - 1); continue }
                var submenu = false
                while let first = text.first, ">#!".contains(first) {
                    text.removeFirst()
                    if first == ">" { submenu = true }
                    else if first == "#" { disabled = true }
                    else if first == "!" { checked = true }
                }
                guard !text.isEmpty else { continue }
                if submenu { depth += 1; continue }
                let itemID = identifier; identifier += 1
                let prefix = String(repeating: "  ", count: depth) + (checked ? "✓ " : "")
                let action = UIAlertAction(title: prefix + text, style: .default) { _ in result.finish(itemID) }
                action.isEnabled = !disabled
                alert.addAction(action)
            }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in result.finish(0) })
            if let popover = alert.popoverPresentationController {
                popover.sourceView = presenter.view
                popover.sourceRect = CGRect(x: presenter.view.bounds.midX,
                                            y: presenter.view.bounds.midY, width: 1, height: 1)
            }
            presenter.present(alert, animated: true)
        }
        _ = result.semaphore.wait(timeout: .now() + 30)
        return result.read()
    }

@MainActor
final class ETJSFXHost: ObservableObject {
    enum HostError: LocalizedError {
        case audioNotReady
        var errorDescription: String? { "Audio is not ready to prepare this JSFX." }
    }
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
        let shape: UInt8
        let visible: Bool
        let enumNames: [String]
        var value: Double

        var isEnumeration: Bool { !enumNames.isEmpty }
    }

    private struct RenderConfiguration: Sendable {
        let sampleRate: Double
        let outputChannels: Int
        let maxFrames: Int
    }

    private final class Instance {
        let id: String
        let entry: Entry
        var host: OpaquePointer?
        var parameters: [Parameter] = []
        var state: Data?
        var channels: Int
        var error: String?
        var loadTask: Task<Void, Never>?
        var stateTask: Task<Void, Never>?
        var ready: ((Result<UInt8, Error>) -> Void)?
        let gfxQueue: DispatchQueue

        init(id: String, entry: Entry, state: Data?, channels: Int) {
            self.id = id; self.entry = entry; self.state = state; self.channels = channels
            gfxQueue = DispatchQueue(label: "ai.nemut.effectdeck.jsfx.gfx.\(id)", qos: .userInteractive)
        }
    }

    static let shared = ETJSFXHost()
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var revision = 0
    private var instances: [String: Instance] = [:]
    private var retired: [OpaquePointer] = []
    private var renderConfiguration: RenderConfiguration?
    private var latencyTimer: Timer?

    private init() {
        refresh()
        latencyTimer = .scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in ETJSFXHost.shared.pollRuntimeChanges() }
        }
    }

    func refresh() {
        #if DEBUG
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("DebugJSFXFactory", isDirectory: true),
           let files = FileManager.default.enumerator(at: bundled, includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles]) {
            for case let source as URL in files where source.pathExtension.lowercased() == "jsfx" {
                _ = try? Self.ownedCopy(of: source)
            }
        }
        #endif
        entries = Self.ownedEntries()
    }

    /// Copies a security-scoped Files/iCloud URL into the app-owned sandbox.
    /// Runtime code never retains or reopens the original URL.
    @discardableResult
    func importFile(_ source: URL) throws -> Entry {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard source.pathExtension.lowercased() == "jsfx" || source.pathExtension.isEmpty else {
            throw NSError(domain: "ETJSFX", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "Choose a single-file JSFX source."])
        }
        let owned = try Self.ownedCopy(of: source)
        guard let entry = Self.entry(for: owned, fallbackName: source.deletingPathExtension().lastPathComponent) else {
            throw NSError(domain: "ETJSFX", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "The JSFX source is not valid UTF-8."])
        }
        refresh()
        return entry
    }

    func entry(id: String) -> Entry? { entries.first { $0.id == id } }

    func create(_ entry: Entry, instanceID: String, state: Data? = nil, channels: Int = 2) {
        create(entry, instanceID: instanceID, state: state, channels: channels, ready: nil)
    }

    /// Builds and installs before the caller publishes a pipeline node. A bad
    /// script therefore cannot leave an inert node in the active chain.
    func prepare(_ entry: Entry, instanceID: String, state: Data? = nil, channels: Int = 2,
                 completion: @escaping (Result<UInt8, Error>) -> Void) {
        guard renderConfiguration != nil else { completion(.failure(HostError.audioNotReady)); return }
        create(entry, instanceID: instanceID, state: state, channels: channels, ready: completion)
    }

    private func create(_ entry: Entry, instanceID: String, state: Data?, channels: Int,
                        ready: ((Result<UInt8, Error>) -> Void)?) {
        guard instances[instanceID] == nil else { return }
        let instance = Instance(id: instanceID, entry: entry, state: state, channels: channels)
        instance.ready = ready
        instances[instanceID] = instance
        do { _ = try ETAUExternalBridge.shared.reserve(instanceID: instanceID) }
        catch {
            instance.error = error.localizedDescription
            instance.ready?(.failure(error)); instance.ready = nil
            instances.removeValue(forKey: instanceID)
            revision &+= 1
            return
        }
        if let configuration = renderConfiguration { build(instance, configuration: configuration) }
        revision &+= 1
    }

    func restore(componentID: String, instanceID: String, state: Data?, channels: Int = 2) {
        guard let entry = entry(id: componentID) else { return }
        create(entry, instanceID: instanceID, state: state, channels: channels)
    }

    func remove(instanceID: String) {
        ETAUExternalBridge.shared.remove(instanceID: instanceID)
        if let instance = instances.removeValue(forKey: instanceID) {
            instance.loadTask?.cancel(); instance.stateTask?.cancel()
            if let host = instance.host { retired.append(host) }
        }
        revision &+= 1
    }

    func removeAll() { for id in Array(instances.keys) { remove(instanceID: id) } }
    func suspend() {
        renderConfiguration = nil
        // AudioIO stops AVAudioEngine before this call, so descriptors retired
        // after graph swaps can finally be destroyed without an RT reader.
        let garbage = retired
        retired.removeAll(keepingCapacity: true)
        Task.detached(priority: .utility) {
            for host in garbage { ETJSFX_Destroy(host) }
        }
    }

    func resume(sampleRate: Double, outputChannels: Int, maxFrames: Int) {
        let configuration = RenderConfiguration(sampleRate: sampleRate,
                                                outputChannels: outputChannels,
                                                maxFrames: maxFrames)
        renderConfiguration = configuration
        for instance in instances.values {
            if let host = instance.host { reconfigure(host, instance: instance, configuration: configuration) }
            else { build(instance, configuration: configuration) }
        }
        revision &+= 1
    }

    func externalIndex(instanceID: String) -> UInt8? { ETAUExternalBridge.shared.index(for: instanceID) }
    func setChannels(_ channels: Int, instanceID: String) { instances[instanceID]?.channels = channels }

    func status(instanceID: String) -> String {
        guard let instance = instances[instanceID] else { return "JSFX unavailable" }
        if let error = instance.error { return error }
        guard let host = instance.host else { return "Compiling…" }
        let diagnostic = String(cString: ETJSFX_Diagnostic(host))
        return diagnostic.isEmpty ? "Ready" : diagnostic
    }

    func parameters(instanceID: String) -> [Parameter] {
        guard let instance = instances[instanceID], let host = instance.host else { return [] }
        instance.parameters = Self.readParameters(host)
        return instance.parameters.filter(\.visible)
    }

    func setParameter(instanceID: String, parameterID: UInt32, value: Double) {
        guard let instance = instances[instanceID], let host = instance.host,
              let offset = instance.parameters.firstIndex(where: { $0.id == parameterID }) else { return }
        let p = instance.parameters[offset]
        let clamped = min(max(value, p.minimum), p.maximum)
        ETJSFX_SetSlider(host, parameterID, clamped)
        instance.parameters[offset].value = clamped
        revision &+= 1
        snapshotState(instance)
    }

    func normalizedValue(instanceID: String, parameterID: UInt32, value: Double) -> Double {
        guard let host = instances[instanceID]?.host else { return 0 }
        return ETJSFX_SliderToNormalized(host, parameterID, value)
    }

    func setNormalizedParameter(instanceID: String, parameterID: UInt32, value: Double) {
        guard let host = instances[instanceID]?.host else { return }
        setParameter(instanceID: instanceID, parameterID: parameterID,
                     value: ETJSFX_SliderFromNormalized(host, parameterID, value))
    }

    func sendTrigger(instanceID: String, index: UInt32) {
        guard let host = instances[instanceID]?.host else { return }
        _ = ETJSFX_SendTrigger(host, index)
    }

    func stateData(instanceID: String) -> Data? { instances[instanceID]?.state }

    func hasGFX(instanceID: String) -> Bool {
        instances[instanceID]?.host.map(ETJSFX_HasGFX) ?? false
    }

    func preferredGFXSize(instanceID: String) -> CGSize {
        guard let host = instances[instanceID]?.host else { return CGSize(width: 640, height: 360) }
        var width: UInt32 = 0, height: UInt32 = 0
        ETJSFX_PreferredGFXSize(host, &width, &height)
        return CGSize(width: width == 0 ? 640 : Int(width), height: height == 0 ? 360 : Int(height))
    }

    private nonisolated static func renderGFX(host: OpaquePointer, width: Int, height: Int,
                                              scale: Double) -> CGImage? {
        guard ETJSFX_RunGFX(host, UInt32(width), UInt32(height), scale) else { return nil }
        let count = width * height * 4
        var pixels = [UInt8](repeating: 0, count: count)
        var actualWidth: UInt32 = 0, actualHeight: UInt32 = 0, stride: UInt32 = 0
        guard ETJSFX_CopyGFX(host, &pixels, pixels.count, &actualWidth, &actualHeight, &stride),
              let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: Int(actualWidth), height: Int(actualHeight), bitsPerComponent: 8,
                       bitsPerPixel: 32, bytesPerRow: Int(stride),
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                           .union(.byteOrder32Little), provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }

    func runtime(instanceID: String) -> OpaquePointer? { instances[instanceID]?.host }
    func gfxFrameRate(instanceID: String) -> UInt32 {
        instances[instanceID]?.host.map(ETJSFX_GFXFrameRate) ?? 30
    }

    func renderGFX(instanceID: String, size: CGSize, scale: Double,
                   completion: @escaping (CGImage?) -> Void) {
        guard let instance = instances[instanceID], let host = instance.host else {
            completion(nil); return
        }
        let width = max(1, min(2048, Int(size.width * scale)))
        let height = max(1, min(2048, Int(size.height * scale)))
        instance.gfxQueue.async {
            let image = Self.renderGFX(host: host, width: width, height: height, scale: scale)
            DispatchQueue.main.async { completion(image) }
        }
    }

    func updateMouse(instanceID: String, point: CGPoint, buttons: UInt32) {
        guard let instance = instances[instanceID], let host = instance.host else { return }
        instance.gfxQueue.async {
            ETJSFX_GFXMouse(host, 0, Int32(point.x), Int32(point.y), buttons, 0, 0)
        }
    }

    func updateKey(instanceID: String, modifiers: UInt32, key: UInt32, pressed: Bool) {
        guard let instance = instances[instanceID], let host = instance.host else { return }
        instance.gfxQueue.async { ETJSFX_GFXKey(host, modifiers, key, pressed) }
    }

    func updateGFXWindow(instanceID: String, focused: Bool, visible: Bool) {
        guard let instance = instances[instanceID], let host = instance.host else { return }
        instance.gfxQueue.async { ETJSFX_GFXWindowState(host, focused, visible, false) }
    }

    private func build(_ instance: Instance, configuration: RenderConfiguration) {
        guard instance.loadTask == nil else { return }
        let path = instance.entry.url.path, state = instance.state, id = instance.id
        instance.loadTask = Task.detached(priority: .userInitiated) {
            var message = [CChar](repeating: 0, count: 4096)
            var host = path.withCString {
                ETJSFX_Create($0, configuration.sampleRate, UInt32(configuration.maxFrames),
                              &message, message.count)
            }
            var restoreFailed = false
            if let created = host, let state {
                restoreFailed = !state.withUnsafeBytes { raw in
                    if let base = raw.bindMemory(to: UInt8.self).baseAddress {
                        return ETJSFX_LoadState(created, base, state.count)
                    }
                    return false
                }
                if restoreFailed { ETJSFX_Destroy(created); host = nil }
            }
            let error = restoreFailed ? "Could not restore JSFX state."
                : (host == nil ? String(cString: message) : nil)
            await MainActor.run {
                guard let current = self.instances[id], current === instance else {
                    if let host { ETJSFX_Destroy(host) }; return
                }
                current.loadTask = nil
                guard let host else {
                    let failure = NSError(domain: "ETJSFX", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: error ?? "Could not load JSFX."])
                    current.error = failure.localizedDescription
                    current.ready?(.failure(failure)); current.ready = nil
                    ETAUExternalBridge.shared.remove(instanceID: id)
                    self.instances.removeValue(forKey: id)
                    self.revision &+= 1; return
                }
                do {
                    let index = try ETAUExternalBridge.shared.install(ETJSFX_Processor(host), instanceID: id)
                    ETJSFX_SetGFXMenuCallback(host, etJSFXMenuCallback, nil)
                    current.host = host; current.parameters = Self.readParameters(host); current.error = nil
                    self.snapshotState(current)
                    current.ready?(.success(index)); current.ready = nil
                } catch {
                    current.error = error.localizedDescription; self.retired.append(host)
                    current.ready?(.failure(error)); current.ready = nil
                    ETAUExternalBridge.shared.remove(instanceID: id)
                    self.instances.removeValue(forKey: id)
                }
                self.revision &+= 1
            }
        }
    }

    private func reconfigure(_ host: OpaquePointer, instance: Instance,
                             configuration: RenderConfiguration) {
        guard instance.loadTask == nil else { return }
        let id = instance.id
        instance.loadTask = Task.detached(priority: .userInitiated) {
            let ok = ETJSFX_Reconfigure(host, configuration.sampleRate, UInt32(configuration.maxFrames))
            await MainActor.run {
                guard let current = self.instances[id], current === instance else { return }
                current.loadTask = nil
                do {
                    guard ok else { throw NSError(domain: "ETJSFX", code: 2,
                                                  userInfo: [NSLocalizedDescriptionKey: "JSFX reconfiguration failed."]) }
                    _ = try ETAUExternalBridge.shared.install(ETJSFX_Processor(host), instanceID: id)
                    current.parameters = Self.readParameters(host); current.error = nil
                } catch { current.error = error.localizedDescription }
                self.revision &+= 1
            }
        }
    }

    private func snapshotState(_ instance: Instance) {
        instance.stateTask?.cancel()
        guard let host = instance.host else { return }
        let id = instance.id
        instance.stateTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let data = await Task.detached(priority: .utility) { () -> Data? in
                var bytes: UnsafeMutablePointer<UInt8>?, size = 0
                guard ETJSFX_SaveState(host, &bytes, &size), let bytes else { return nil }
                defer { ETJSFX_FreeBytes(bytes) }
                return Data(bytes: bytes, count: size)
            }.value
            guard let current = self.instances[id], current === instance else { return }
            current.stateTask = nil
            if let data { current.state = data; EffeTuneDSP.shared.externalStateDidChange(instanceID: id) }
        }
    }

    private func pollRuntimeChanges() {
        var pdcChanged = false
        var parametersChanged = false
        for instance in instances.values where instance.host != nil {
            guard let host = instance.host else { continue }
            if ETJSFX_ConsumeLatencyChange(host) { pdcChanged = true }
            if ETJSFX_ConsumeSliderChange(host) {
                parametersChanged = true
                instance.parameters = Self.readParameters(host)
                snapshotState(instance)
            }
        }
        if parametersChanged { revision &+= 1 }
        if pdcChanged { EffeTuneDSP.shared.republish(reason: "JSFX latency changed") }
    }

    private static func readParameters(_ host: OpaquePointer) -> [Parameter] {
        (0..<ETJSFX_SliderCount(host)).compactMap { ordinal in
            var index: UInt32 = 0, shape: UInt8 = 0
            var name: UnsafePointer<CChar>?
            var value = 0.0, minimum = 0.0, maximum = 1.0, step = 0.0
            var visible = true
            guard ETJSFX_SliderInfo(host, ordinal, &index, &name, &value, &minimum,
                                    &maximum, &step, &shape, &visible) else { return nil }
            let enumNames = (0..<ETJSFX_SliderEnumCount(host, index)).compactMap { item -> String? in
                ETJSFX_SliderEnumName(host, index, item).map(String.init(cString:))
            }
            return Parameter(id: index, name: name.map(String.init(cString:)) ?? "Slider \(index + 1)",
                             minimum: minimum, maximum: maximum, step: step,
                             shape: shape, visible: visible, enumNames: enumNames, value: value)
        }
    }

    private static func ownedEntries() -> [Entry] {
        guard let root = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                       in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("JSFX/Sources", isDirectory: true),
              let files = try? FileManager.default.contentsOfDirectory(at: root,
                  includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return files.compactMap { entry(for: $0, fallbackName: $0.deletingPathExtension().lastPathComponent) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func entry(for owned: URL, fallbackName: String) -> Entry? {
        guard owned.pathExtension.lowercased() == "jsfx",
              let text = try? String(contentsOf: owned, encoding: .utf8) else { return nil }
        let metadata = metadata(text)
        let hash = owned.deletingPathExtension().lastPathComponent
        return Entry(id: "jsfx:" + hash, name: metadata.name ?? fallbackName,
                     author: metadata.author ?? "", url: owned)
    }

    private static func ownedCopy(of source: URL) throws -> URL {
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        guard data.count <= 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let root = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("JSFX/Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent(hash).appendingPathExtension("jsfx")
        if !FileManager.default.fileExists(atPath: destination.path) {
            try data.write(to: destination, options: .atomic)
        }
        return destination
    }

    private static func metadata(_ source: String) -> (name: String?, author: String?) {
        var name: String?, author: String?
        for raw in source.split(whereSeparator: { $0.isNewline }).prefix(80) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("desc:") { name = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
            if line.hasPrefix("author:") { author = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        }
        return (name, author)
    }
}
