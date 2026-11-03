// ETAUHost.swift
// Audio Unit discovery, instance lifecycle, state and UI hosting.

import AVFoundation
import AudioToolbox
import CoreAudioKit
import UIKit
import os

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

    private let log = Logger(subsystem: "ai.nemut.effetune", category: "au")
    private var observers: [NSObjectProtocol] = []
    /// 通知の束をまとめる待ち（scheduleRefresh）。
    private var pendingRefresh: Task<Void, Never>?
    /// 前に報告へ書いた Apple 以外の名前の行。同じなら書き直さない（前面へ戻るたびに増えないように）。
    private var lastOutsiderLine: String?

    /// 鎖を戻したときに一覧に無かった AU。登録が後から届いたらここから作る。
    ///
    /// **捨てずに覚えておく理由。**AUv3 は他のアプリの拡張で、登録は系が後から
    /// 届けることがある（登録変更の通知はそのために在る）。起動直後の一覧に無いだけで
    /// 諦めると、保存した鎖のカードが起動のたびに「Audio Unit unavailable」のままになる。
    /// 消えたノードは remove / removeAll で一緒に消すので、ここに残り続けることは無い。
    private struct PendingRestore {
        let componentID: String
        let state: Data?
        var channels: Int
    }
    private var pendingRestores: [String: PendingRestore] = [:]

    private init() {
        refresh(reason: "launch")
        observeRegistrations()
    }

    /// 一覧を作り直すきっかけを張る。
    ///
    /// **以前は起動直後に 1 回聞くだけだった。**その後に入れた AU も、後から登録が
    /// 届いた AU も、アプリを作り直すまで一覧に出なかった（Issue #10）。
    /// 通知は 2 つとも張る。AVFoundation の方は manager が一覧を更新したとき、
    /// AudioToolbox の方は系の登録が変わったときに出る。どちらが先に来るかは
    /// 決まっていないので、両方で数え直す（数え直しは安い）。
    /// 前面へ戻ったときも数え直す。AU のアプリを入れてから戻ってくる流れで、
    /// 通知を取りこぼしていても一覧が追いつく。
    /// 起動 5 秒後の 1 回は、通知が来ないまま登録だけ遅れて届く場合を報告で
    /// 見分けるため（launch の行と launch+5s の行の数が違えばそれ）。
    private func observeRegistrations() {
        let center = NotificationCenter.default
        let triggers: [(Notification.Name, String)] = [
            (AVAudioUnitComponentManager.registrationsChangedNotification, "avf-registrations"),
            (Notification.Name(kAudioComponentRegistrationsChangedNotification as String),
             "ac-registrations"),
            (UIApplication.willEnterForegroundNotification, "foreground"),
        ]
        for (name, reason) in triggers {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                Task { @MainActor in self?.scheduleRefresh(reason: reason) }
            })
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            self?.refresh(reason: "launch+5s")
        }
    }

    /// 通知からの数え直しはまとめてから 1 回にする。
    ///
    /// **登録の変更通知は束で来る。**シミュレータの起動直後に avf-registrations が
    /// 20ms のあいだに 81 回届き、そのたびに全部の部品を数えて同じ報告の行を 81 本残した。
    /// 最後の通知から少し待って 1 回だけ数える。理由は最後に来たものを残す。
    private func scheduleRefresh(reason: String) {
        pendingRefresh?.cancel()
        pendingRefresh = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }
            self.pendingRefresh = nil
            self.refresh(reason: reason)
        }
    }

    func refresh(reason: String = "manual") {
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

        // **型を 0（全部）にして 2 通りで数える。**一覧の 2 種の絞り込みより前で、
        // 系がこのプロセスに何を返しているかを報告に残すため（ETAUCensus の頭を参照）。
        let wildcard = AudioComponentDescription(componentType: 0,
                                                 componentSubType: 0,
                                                 componentManufacturer: 0,
                                                 componentFlags: 0,
                                                 componentFlagsMask: 0)
        let managerAll = manager.components(matching: wildcard).map {
            ETAUCensus.Item(type: $0.audioComponentDescription.componentType,
                            subType: $0.audioComponentDescription.componentSubType,
                            manufacturer: $0.audioComponentDescription.componentManufacturer,
                            name: $0.name, maker: $0.manufacturerName)
        }
        let scanned = Self.scanComponents(matching: wildcard)
        var countQuery = wildcard
        let count = AudioComponentCount(&countQuery)

        // FindNext だけが見つけた効果も一覧へ足す。
        // manager がどこかで取りこぼしても、系に登録があれば選べるようにするため。
        // 作るのは同じ description からの AUAudioUnit.instantiate なので、経路は変わらない。
        let listedIDs = Set(found.map(\.id))
        let added = scanned.filter {
            ETAUCensus.effectTypes.contains($0.type) && !listedIDs.contains($0.key)
        }
        found += added.map {
            Entry(description: AudioComponentDescription(componentType: $0.type,
                                                         componentSubType: $0.subType,
                                                         componentManufacturer: $0.manufacturer,
                                                         componentFlags: 0,
                                                         componentFlagsMask: 0),
                  name: $0.name, manufacturer: $0.maker)
        }

        let sorted = Array(Set(found)).sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        // 同じなら差し替えない。Plugins の面を開くたびに数え直すので、
        // 毎回差し替えると開いている一覧が描き直される。
        if sorted != entries { entries = sorted }

        record(ETAUCensus.summary(reason: reason, listed: sorted.count, manager: managerAll,
                                  scanned: scanned, count: count, added: added.count))
        let outsiders = ETAUCensus.outsiderLine(manager: managerAll, scanned: scanned)
        if outsiders != lastOutsiderLine {
            lastOutsiderLine = outsiders
            if !outsiders.isEmpty { record(outsiders) }
        }

        restorePending()
    }

    /// AudioComponentFindNext で系の登録を頭から辿る。
    /// manager とは別の口なので、片方だけが取りこぼしていれば報告で判る。
    private static func scanComponents(matching description: AudioComponentDescription)
        -> [ETAUCensus.Item] {
        var query = description
        var items: [ETAUCensus.Item] = []
        var current: AudioComponent?
        // 上限は念のため。辿り方を間違えて同じものを返し続けても止まるように。
        while items.count < 4096, let next = AudioComponentFindNext(current, &query) {
            current = next
            var found = AudioComponentDescription()
            guard AudioComponentGetDescription(next, &found) == noErr else { continue }
            var copied: Unmanaged<CFString>?
            let full = AudioComponentCopyName(next, &copied) == noErr
                ? (copied?.takeRetainedValue() as String?) ?? ""
                : ""
            let parts = ETAUCensus.splitName(full)
            items.append(ETAUCensus.Item(type: found.componentType,
                                         subType: found.componentSubType,
                                         manufacturer: found.componentManufacturer,
                                         name: parts.name, maker: parts.maker))
        }
        return items
    }

    /// 報告に添える行（ETLogTap）と os_log と、-ETConsole 1 のときの標準出力。
    /// AudioIO の診断の行と同じ 3 か所へ出す。
    private func record(_ line: String) {
        log.notice("\(line, privacy: .public)")
        ETLogTap.record(line)
        if ETConsoleLog.on { print(line) }
    }

    /// 一覧に載るようになった AU を、戻せなかったノードへ作る。
    private func restorePending() {
        for (instanceID, pending) in pendingRestores {
            guard let entry = entry(id: pending.componentID) else { continue }
            pendingRestores[instanceID] = nil
            record("au late restore \(pending.componentID)")
            create(entry, instanceID: instanceID, state: pending.state,
                   channels: pending.channels)
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
            pendingRestores[instanceID] = PendingRestore(componentID: componentID,
                                                         state: state, channels: channels)
            revision &+= 1
            return
        }
        pendingRestores[instanceID] = nil
        create(entry, instanceID: instanceID, state: state, channels: channels)
    }

    func remove(instanceID: String) {
        pendingRestores[instanceID] = nil
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
        pendingRestores.removeAll()
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
        pendingRestores[instanceID]?.channels = channels
    }

    func status(instanceID: String) -> String {
        guard let instance = instances[instanceID] else { return "Audio Unit unavailable" }
        if let error = instance.error { return error }
        return instance.loading ? "Loading…" : "Ready"
    }

    /// 画面をCoreAudioKitに頼むか。nilは読み込み中。
    ///
    /// **シミュレータでは、AppleのAU（AUDelayなど）には頼まない。**カードのパラメータ行で出す
    /// （ExternalProcessorView。実機では頼む: usesParameterRows）。iOS 27のシミュレータでは、CoreAudioKitがAUDelayに付けるAUDelayViewControllerが
    /// viewDidLoadで落ちる。自分の資源の画像（DelayModeNormal / DelayModeInverted）が引けず、
    /// nilがNSNullになってUISegmentedControl(items:)へ渡り、字として読まれる
    /// （2026-09-28のクラッシュレポート。こちらはviewを読んだだけ）。
    /// Objective-Cの例外なので捕まえられず、カードを開いたまま保存した鎖は起動のたびに落ちる。
    func providesUserInterface(instanceID: String) -> Bool? {
        guard let instance = instances[instanceID], !instance.loading else { return nil }
        guard !Self.usesParameterRows(instance.entry) else { return false }
        return instance.unit?.providesUserInterface ?? false
    }

    /// CoreAudioKitの画面を使わず、パラメータ行で出すAU。**シミュレータの Apple の AU だけ。**
    /// 落ちたのは iOS 27 のシミュレータで、実機では Apple の AU も自分の画面で動く
    /// （d850d29 で実機まで止めてしまい、利用者が使っていた AUDelay などの画面が出なくなっていた）。
    private static func usesParameterRows(_ entry: Entry) -> Bool {
        #if targetEnvironment(simulator)
        entry.description.componentManufacturer == kAudioUnitManufacturer_Apple
        #else
        false
        #endif
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
        // providesUserInterfaceと同じ理由で、AppleのAUには頼まない。
        guard unit.providesUserInterface, !Self.usesParameterRows(instance.entry) else {
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
