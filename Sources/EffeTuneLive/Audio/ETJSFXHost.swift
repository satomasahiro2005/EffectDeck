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
        let isDebugFixture: Bool
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
        var lastGFXImage: CGImage?
        var visibleGFXOwners: Set<UUID> = []
        var focusedGFXOwners: Set<UUID> = []

        init(id: String, entry: Entry, state: Data?, channels: Int) {
            self.id = id; self.entry = entry; self.state = state; self.channels = channels
            gfxQueue = DispatchQueue(label: "ai.nemut.effectdeck.jsfx.gfx.\(id)", qos: .userInteractive)
        }
    }

    static let shared = ETJSFXHost()
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var revision = 0
    private var entryAliases: [String: Entry] = [:]
    private var instances: [String: Instance] = [:]
    private var retired: [OpaquePointer] = []
    private var renderConfiguration: RenderConfiguration?
    private var latencyTimer: Timer?

    private init() {
        refresh()
        // **init では張らない。**この型は singleton で、ピッカーを開くだけで
        // 生成される（EffectPickerView が生成式で shared を読む）。init から張ると、
        // JSFX を 1 つも読んでいなくても 10 回/秒でメインスレッドを起こし、
        // そのたびに Task を 1 つ作り続ける。止める口はどこにも無かった。
        // 生きたホストが在る間だけ回す。
    }

    /// 生きたホストが在る間だけ 10Hz で回す。
    ///
    /// 背景で止めるのは筋が悪い。つまみの変化は音のスレッド由来なので、
    /// 取りこぼすと PDC が合わなくなる。
    private func startLatencyTimerIfNeeded() {
        guard latencyTimer == nil else { return }
        latencyTimer = .scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in ETJSFXHost.shared.pollRuntimeChanges() }
        }
    }

    /// 取り込んだソースを消す。
    ///
    /// **消せる口が無かった。**IR には在るのに（IRLibraryView の swipe）、JSFX は
    /// 一覧に並ぶだけで消せず、置き場は Application Support なので Files からも見えない。
    /// 一度入れたものが恒久に残る形だった。取り込みの門を緩める前にここを開ける。
    ///
    /// 同梱の見本（isDebugFixture）は消さない。鎖に載っている段については何もしない。
    /// 既に建った instance は残るので鳴っている音は止まらず、表に出るのは鎖を
    /// 読み直したとき（restore が entry を引けずに instance を作らない経路）。
    @discardableResult
    func removeEntry(_ entry: Entry) -> Bool {
        guard !entry.isDebugFixture else { return false }
        // 消せなかったら一覧はそのまま。押しても消えない形になるが、
        // 消えたふりをして次の refresh で戻ってくるより分かりやすい。
        guard (try? FileManager.default.removeItem(at: entry.url)) != nil else { return false }
        refresh()
        return true
    }

    func refresh() {
        let debugRoot = try? Self.storageURL("JSFX/DebugFactory")
        if let debugRoot { try? FileManager.default.removeItem(at: debugRoot) }
        #if DEBUG
        if let debugRoot { try? FileManager.default.createDirectory(at: debugRoot, withIntermediateDirectories: true) }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("DebugJSFXFactory", isDirectory: true),
           let files = FileManager.default.enumerator(at: bundled, includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles]) {
            for case let source as URL in files where source.pathExtension.lowercased() == "jsfx" {
                _ = try? Self.debugCopy(of: source, root: debugRoot)
            }
        }
        #endif
        Self.removeLegacyDebugCopies()
        var discovered = Self.ownedEntries(at: try? Self.storageURL("JSFX/Sources"), debug: false)
        #if DEBUG
        discovered += Self.ownedEntries(at: debugRoot, debug: true)
        #endif
        entries = Dictionary(grouping: discovered, by: \.id).compactMap { $0.value.first }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        entryAliases = Self.debugAliases(for: entries)
    }

    /// Copies a security-scoped Files/iCloud URL into the app-owned sandbox.
    /// Runtime code never retains or reopens the original URL.
    @discardableResult
    func importFile(_ source: URL) throws -> Entry {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        // **中身で判定する。拡張子で弾かない。**
        // JSFX には拡張子が無いことがあり、メールや Files が付けた `.txt` も来る。
        // 前は `.jsfx` か拡張子なししか通さず、理由も分からずに弾いていた。
        //
        // **順番が肝。合格してから初めてディスクへ写す。**前は写してから
        // entry() で落としていたので、弾いたファイルが置き場に残り、
        // 置き場は名前で掃除しない（sha256 が同一性そのもの）ので恒久のゴミになっていた。
        //
        // 1 MB の判定を先に置くのは、それを超える物を String へ起こさないため。
        // importFile は @MainActor なので、鳴っている最中に画面が止まる。
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        guard data.count <= 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        // **UTF-8 だけに限らない。**REAPER から出たものは Windows の綴りのことがある。
        // ysfx は素のバイトを読むので、ここで起こすのは判定のためだけ。
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw NSError(domain: "ETJSFX", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "The JSFX source is not text."])
        }
        guard Self.looksLikeJSFX(text) else {
            throw NSError(domain: "ETJSFX", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "That file does not look like a JSFX source."])
        }

        let owned = try Self.ownedCopy(of: source)
        guard let entry = Self.entry(for: owned,
                                     fallbackName: source.deletingPathExtension().lastPathComponent,
                                     debug: false) else {
            throw NSError(domain: "ETJSFX", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "The JSFX source is not valid UTF-8."])
        }
        refresh()
        return entry
    }

    func entry(id: String) -> Entry? { entries.first { $0.id == id } ?? entryAliases[id] }

    func sourceText(instanceID: String) -> String? {
        guard let entry = instances[instanceID]?.entry else { return nil }
        return try? String(contentsOf: entry.url, encoding: .utf8)
    }

    func debugPresetItems() -> [PipelineStore.Loaded] {
        #if DEBUG
        let fixtures = entries.filter(\.isDebugFixture).sorted { lhs, rhs in
            func rank(_ entry: Entry) -> Int {
                if entry.name.contains("DSP") { return 0 }
                if entry.name.contains("Conformance") { return 1 }
                return 2
            }
            let a = rank(lhs), b = rank(rhs)
            return a == b ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending : a < b
        }
        return fixtures.map { entry in
            PipelineStore.Loaded(
                spec: ETEffect.external(type: "External:\(entry.id)", name: entry.name,
                                        category: "JSFX"),
                values: [], enabled: true, inputBus: 0, outputBus: 0, channelSpec: -1,
                externalID: entry.id, externalInstanceID: UUID().uuidString)
        }
        #else
        return []
        #endif
    }

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
        startLatencyTimerIfNeeded()
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

    /// 自動バイパスの診断。**空なら nil。**
    ///
    /// status(instanceID:) は host が在れば常に非空（"Ready"）を返すので、
    /// あれを条件に使うと全カードの頭に "Ready" が並ぶ。診断だけを別の口で出す。
    func diagnostic(instanceID: String) -> String? {
        guard let host = instances[instanceID]?.host else { return nil }
        let text = String(cString: ETJSFX_Diagnostic(host))
        return text.isEmpty ? nil : text
    }

    /// 自動バイパスを解く。解けたら true。
    /// 再設定や状態復元の最中（maintenance）は解かない。
    @discardableResult
    func clearDiagnostic(instanceID: String) -> Bool {
        guard let host = instances[instanceID]?.host else { return false }
        return ETJSFX_ClearDiagnostic(host)
    }

    /// 締切まわりの数。**閾値を決めるための計測器**で、画面には Details から出す。
    /// worst は 1 ブロックの持ち時間に対して使った割合（1.0 で使い切り）。
    func deadlineReading(instanceID: String) -> (trips: UInt32, worst: Double)? {
        guard let host = instances[instanceID]?.host else { return nil }
        return (ETJSFX_DeadlineTrips(host),
                Double(ETJSFX_DeadlineWorstPermille(host)) / 1000)
    }

    /// いま音を通しているか。trigger の札を出すかどうかに使う。
    func isRunning(instanceID: String) -> Bool {
        guard let host = instances[instanceID]?.host else { return false }
        return ETJSFX_IsRunning(host)
    }

    /// trigger を送る。**受け取られたかを返す。**
    /// running でない（自動バイパス中・状態保存中・再設定中）ときは捨てられる。
    /// 呼び出し側はそれを見せる（黙って溜めると再開時に一斉に鳴る）。
    @discardableResult
    func sendTrigger(instanceID: String, index: UInt32) -> Bool {
        guard let host = instances[instanceID]?.host else { return false }
        return ETJSFX_SendTrigger(host, index)
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

    func gfxWantsRetina(instanceID: String) -> Bool {
        instances[instanceID]?.host.map(ETJSFX_GFXWantsRetina) ?? false
    }

    /// Frozen copy used by PipelineView while a card is being reordered. A
    /// second live @gfx view for the same VM would race the real card over the
    /// framebuffer and window-visible state.
    func viewSnapshot(instanceID: String) -> UIImage? {
        guard let image = instances[instanceID]?.lastGFXImage else { return nil }
        return UIImage(cgImage: image)
    }

    /// Keep the framebuffer inside the native host limits without changing
    /// its aspect ratio. Large landscape Retina screens can be wider than the
    /// 2048-pixel safety cap; clamping width and height independently stretches
    /// the plug-in and also makes mouse coordinates miss their targets.
    func gfxPixelScale(instanceID: String, size: CGSize, screenScale: CGFloat) -> CGFloat {
        let requested = gfxWantsRetina(instanceID: instanceID) ? screenScale : 1
        let width = max(1, size.width), height = max(1, size.height)
        let dimensionLimit = min(2048 / width, 2048 / height)
        let byteLimit = sqrt(CGFloat(16 * 1024 * 1024) / (width * height * 4))
        return max(0.01, min(requested, dimensionLimit, byteLimit))
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
        // Classic JSFX coordinates are logical screen pixels. Giving those
        // scripts the physical Retina dimensions makes every control 2–3x
        // too small. Only scripts opting into gfx_ext_retina receive the
        // physical framebuffer and its scale factor.
        let retina = gfxWantsRetina(instanceID: instanceID)
        let pixelScale = gfxPixelScale(instanceID: instanceID, size: size,
                                       screenScale: scale)
        let width = max(1, min(2048, Int(size.width * pixelScale)))
        let height = max(1, min(2048, Int(size.height * pixelScale)))
        instance.gfxQueue.async {
            let image = Self.renderGFX(host: host, width: width, height: height,
                                       scale: retina ? pixelScale : 1)
            DispatchQueue.main.async {
                // Do not let a completion from an instance that has since been
                // removed populate a replacement which happens to reuse an ID.
                if self.instances[instanceID] === instance, let image {
                    instance.lastGFXImage = image
                }
                completion(image)
            }
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

    /// Aggregate window state across the inline and fullscreen presentations.
    /// SwiftUI can remove the old presentation after the new one has appeared;
    /// sending that late `visible=false` directly used to blank the live view.
    func updateGFXWindow(instanceID: String, owner: UUID,
                         focused: Bool, visible: Bool) {
        guard let instance = instances[instanceID], let host = instance.host else { return }
        if visible { instance.visibleGFXOwners.insert(owner) }
        else { instance.visibleGFXOwners.remove(owner) }
        if focused { instance.focusedGFXOwners.insert(owner) }
        else { instance.focusedGFXOwners.remove(owner) }
        let anyVisible = !instance.visibleGFXOwners.isEmpty
        let anyFocused = !instance.focusedGFXOwners.isEmpty
        instance.gfxQueue.async { ETJSFX_GFXWindowState(host, anyFocused, anyVisible, false) }
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
        // 生きたホストが 1 つも無ければ止める。**instances.isEmpty では足りない**
        // （ビルドに失敗した instance は host が nil のまま残る）。
        guard instances.values.contains(where: { $0.host != nil }) else {
            latencyTimer?.invalidate()
            latencyTimer = nil
            return
        }
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

    private static func ownedEntries(at root: URL?, debug: Bool) -> [Entry] {
        guard let root,
              let files = try? FileManager.default.contentsOfDirectory(at: root,
                  includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return files.compactMap { entry(for: $0,
            fallbackName: $0.deletingPathExtension().lastPathComponent, debug: debug) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func entry(for owned: URL, fallbackName: String, debug: Bool) -> Entry? {
        // **綴りは UTF-8 に限らない。**importFile はここへ来る前に Latin-1 でも
        // 起こしてみる。ここだけ UTF-8 に絞っていると、通ったはずのものが
        // 名前を引けずに nil になり、「字に起こせない」で弾かれていた。
        guard owned.pathExtension.lowercased() == "jsfx",
              let data = try? Data(contentsOf: owned, options: .mappedIfSafe),
              let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else { return nil }
        let metadata = metadata(text)
        let identifier: String
        if debug {
            let filename = owned.lastPathComponent.data(using: .utf8) ?? Data()
            let stable = SHA256.hash(data: filename).map { String(format: "%02x", $0) }.joined()
            identifier = "jsfx:debug:" + stable
        } else {
            identifier = "jsfx:" + owned.deletingPathExtension().lastPathComponent
        }
        return Entry(id: identifier, name: metadata.name ?? fallbackName,
                     author: metadata.author ?? "", url: owned, isDebugFixture: debug)
    }

    /// Bundled debug fixtures are developer-owned files, not user imports.
    /// Keep their filename so their component identity survives source edits.
    private static func debugCopy(of source: URL, root: URL?) throws -> URL {
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        guard data.count <= 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        guard let root else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent(source.lastPathComponent)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    /// Resolve presets saved by builds which used the source-content SHA as a
    /// debug component ID. Current content hashes are generated automatically;
    /// the two older edited fixtures need one historical alias each.
    private static func debugAliases(for entries: [Entry]) -> [String: Entry] {
        var aliases: [String: Entry] = [:]
        let debug = entries.filter(\.isDebugFixture)
        for entry in debug {
            if let data = try? Data(contentsOf: entry.url) {
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                aliases["jsfx:" + hash] = entry
            }
        }
        let historical: [String: String] = [
            "jsfx:ee9586c3927073dd554ed2dd82142364717917994503263040a3a8312a92d87e":
                "EffectDeck DSP Filter + Drive",
            "jsfx:a21a7c4b4f1ebcf3cf2562a39590ab5e496a4c612091dd4c8326b1edaaa95f6a":
                "EffectDeck JSFX Conformance"
        ]
        for (oldID, name) in historical {
            if let entry = debug.first(where: { $0.name == name }) { aliases[oldID] = entry }
        }
        return aliases
    }

    /// JSFX のソースらしいか。**コンパイルはしない。**
    ///
    /// ETJSFX_Create のコンパイル上限は 2 秒で、importFile は @MainActor なので
    /// ここで試すと鳴っている最中に画面が止まる。コンパイルの失敗は段に置いた時点で
    /// status() が出すので、報告の口は足りている。
    ///
    /// **`desc:` だけを必須にしない。**@init しか持たない実物を弾いてしまう。
    /// セクション記号との or を必ず残す。頭 80 行だけ見る。
    private static func looksLikeJSFX(_ text: String) -> Bool {
        let sections = ["@init", "@slider", "@block", "@sample", "@serialize", "@gfx"]
        for line in text.split(whereSeparator: { $0.isNewline }).prefix(80) {
            // **頭の見えない字を落とす。**メールや Files を通ると UTF-8 の印（BOM）が
            // 頭に付くことがある。付いたままだと 1 行目が `desc:` で始まらず、
            // **中身は JSFX なのに弾いていた**（`.txt` が受理されなかったのがこれ）。
            let t = line.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}\u{200B}"))
            if t.hasPrefix("desc:") { return true }
            if sections.contains(where: { t.hasPrefix($0) }) { return true }
        }
        return false
    }

    private static func ownedCopy(of source: URL) throws -> URL {
        try ownedCopy(of: source, root: storageURL("JSFX/Sources"))
    }

    private static func ownedCopy(of source: URL, root: URL?) throws -> URL {
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        guard data.count <= 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard let root else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent(hash).appendingPathExtension("jsfx")
        if !FileManager.default.fileExists(atPath: destination.path) {
            try data.write(to: destination, options: .atomic)
        }
        return destination
    }

    private static func storageURL(_ relativePath: String) throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory,
                                    in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(relativePath, isDirectory: true)
    }

    /// Builds before the dedicated DebugFactory directory wrote its three
    /// temporary probes into Sources. Remove exactly those known hashes once;
    /// user-imported sources are never swept by name or directory.
    private static func removeLegacyDebugCopies() {
        let hashes = [
            "36f889da0be41f69c91be9daa0aee12c1ec0de0edeedb0349ac31a28d2e7be2c",
            "fef732cf7ee5227217176631c5b65ab08e7c8eb1ab696ddee86c3f76daa8edae",
            "7c02bdbe8f4acd6f8c26105cdcd4bbb1ebc51b60bc0ee11821017ce041a522ed"
        ]
        guard let root = try? storageURL("JSFX/Sources") else { return }
        for hash in hashes {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(hash).appendingPathExtension("jsfx"))
        }
    }

    private static func metadata(_ source: String) -> (name: String?, author: String?) {
        var name: String?, author: String?
        for raw in source.split(whereSeparator: { $0.isNewline }).prefix(80) {
            // **見えない字も落とす。**looksLikeJSFX と同じ扱いにしないと、
            // BOM 付きの `.txt` は取り込めるのに 1 行目の `desc:` が読めず、
            // 一覧に題ではなくファイル名が並ぶ。U+FEFF は空白ではないので
            // .whitespaces だけでは落ちない。
            let line = raw.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}\u{200B}"))
            if line.hasPrefix("desc:") { name = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
            if line.hasPrefix("author:") { author = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        }
        return (name, author)
    }
}
