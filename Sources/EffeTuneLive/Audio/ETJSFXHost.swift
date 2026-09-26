import CryptoKit
import Foundation
import UIKit

private final class ETJSFXMenuResult: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value: Int32 = 0
    private var finished = false
    /// 出した action sheet。畳むときに閉じる。main からしか触らない。
    weak var alert: UIAlertController?
    func finish(_ newValue: Int32) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        finished = true; value = newValue; semaphore.signal()
    }
    func read() -> Int32 { lock.withLock { value } }
    var isFinished: Bool { lock.withLock { finished } }
    /// 0 で返して、出ていれば閉じる。
    func cancel() {
        finish(0)
        DispatchQueue.main.async { [self] in alert?.presentingViewController?.dismiss(animated: true) }
    }
}

/// 保守の前に `gfx_showmenu` を畳む。
///
/// **開いている間 GFX スレッドは gfxActive を立てたまま待つ。**beginMaintenance は
/// それが降りるまで回り続けるので、状態保存・再設定・破棄が最長 30 秒止まり、
/// その間このスクリプトは素通しになっていた。保守に入る側が先にここを閉じる。
/// 閉じている間に開こうとした menu は即 0 を返す。
///
/// **畳むのは止められない保守（再設定・破棄）だけ。**状態保存は holdIfIdle で入り、
/// 出ている menu は畳まずに閉じるのを待つ（snapshotState を読むこと）。
final class ETJSFXMenuGate: @unchecked Sendable {
    private let lock = NSLock()
    private var holds = 0
    private var shown: ETJSFXMenuResult?

    fileprivate func open(_ result: ETJSFXMenuResult) -> Bool {
        lock.withLock {
            guard holds == 0 else { return false }
            shown = result
            return true
        }
    }
    fileprivate func close(_ result: ETJSFXMenuResult) {
        lock.withLock { if shown === result { shown = nil } }
    }
    func hold() {
        let current: ETJSFXMenuResult? = lock.withLock { holds += 1; return shown }
        current?.cancel()
    }
    /// menu が出ていなければ閉じて true。出ていれば何もせず false。
    func holdIfIdle() -> Bool {
        lock.withLock {
            guard shown == nil else { return false }
            holds += 1
            return true
        }
    }
    var isShowing: Bool { lock.withLock { shown != nil } }
    func release() { lock.withLock { holds -= 1 } }
}

/// 状態保存の結果。menuShown は書かずに戻った（menu が出ていた）。
private enum Snapshot: Sendable {
    case menuShown
    case saved(Data?)
}

/// `gfx_showmenu` is synchronous by definition. Only the calling instance's
/// private GFX queue waits; audio and other JSFX instances keep running.
/// context は instance の ETJSFXMenuGate（host より長く生かしてある）。
private let etJSFXMenuCallback: @convention(c)
    (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, Int32, Int32) -> Int32 = { context, menu, _, _ in
        guard let menu, let context else { return 0 }
        let gate = Unmanaged<ETJSFXMenuGate>.fromOpaque(context).takeUnretainedValue()
        let spec = String(cString: menu)
        let result = ETJSFXMenuResult()
        guard gate.open(result) else { return 0 }
        defer { gate.close(result) }
        DispatchQueue.main.async {
            // 出す前に畳まれていたら出さない。
            guard !result.isFinished,
                  let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
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
            result.alert = alert
            // 出している途中で畳まれたら、出し終えてから閉じる（途中の dismiss は効かない）。
            presenter.present(alert, animated: true) {
                if result.isFinished { alert.presentingViewController?.dismiss(animated: true) }
            }
        }
        // 時間切れのときも閉じる。残すと、押しても何も起きない sheet が居座る。
        if result.semaphore.wait(timeout: .now() + 30) == .timedOut { result.cancel() }
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

    private struct RenderConfiguration: Sendable, Equatable {
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
        /// 人の操作で保存を頼まれてから、まだ書いていない最初の時刻。snapshotState を読むこと。
        var snapshotSince: ContinuousClock.Instant?
        /// 最後の保存のあとに @gfx へ指か鍵が来た。そのあとの sliderchange は人の操作として扱う。
        var userTouched = false
        /// 保守（状態保存・再設定）の列の最後尾。enqueue を読むこと。
        var nativeTail: Task<Void, Never>?
        let menuGate = ETJSFXMenuGate()
        var ready: ((Result<UInt8, Error>) -> Void)?
        let gfxQueue: DispatchQueue
        var lastGFXImage: CGImage?
        /// 押しが 1 枚でも描かれたか。updateMouse の説明を読むこと。
        var pressSeen = false
        /// 描かれるまで待たせている離し。
        var pendingRelease: (Int32, Int32)?
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
        Self.setStalled(entry.id, false)
        refresh()
        return true
    }

    /// JSFX の口を開けるか。**いまは全部の版で開けている（店に出す版も）。**
    ///
    /// 閉じる形は残す。また閉じるときは false を返せば、ツールバー・空のときの案内・
    /// 一覧の頭の行・設定の JSFX canvas の節・importFile（共有シートもここへ来る）が
    /// まとめて閉じる。
    ///
    /// 店の版で閉じていた理由は中身で、開ける前に要ると書いていたのは次の 3 つ。
    /// - `ETJSFX_LoadState` が `ysfx_load_state` の後に `ysfx_init` を呼び、
    ///   `@init` と `@serialize` を両方使うスクリプトが復元した値を即座に失っていた。
    ///   **直した**（つまみ → @init → @serialize 読み → @slider。JSFXStateTests の
    ///   testInitDoesNotOverwriteSerializedStateOnLoad）。
    /// - 実機で長く回すこと。開けた時点で長時間運転の記録はリポジトリに無い。
    /// - **締切の閾値（続けて 3 回で自動バイパス）はまだ実測から決めていない。**
    ///   測る器具（deadlineReading、Details に出る）は在るが、数字は採っていない。
    static var isEnabled: Bool { true }

    /// 同梱の見本を出すか。**TestFlight と開発ビルドだけ。**
    ///
    /// 見本は配った相手が JSFX を試すための手がかりで、店で売る版に並べるものではない。
    /// **建てるときに決まる。**受領書（`appStoreReceiptURL`）は開発ビルドでも
    /// `sandboxReceipt` を返すので、店に出す側の挙動を手元で確かめられない。
    /// Scripts/archive.sh がアイコンと同じ引数で ET_BETA を立てる。
    /// **紫のアイコンなら見本が在る**、が必ず成り立つ。
    static var showsBundledSamples: Bool {
        #if DEBUG || ET_BETA
        return true
        #else
        return false
        #endif
    }

    func refresh() {
        // 閉じた版では JSFX を出さない（isEnabled）。一覧が空なら、
        // 取り込みの口も検索も vendor の段もまとめて消える。
        guard Self.isEnabled else {
            entries = []
            entryAliases = [:]
            return
        }
        // 同梱の見本。**TestFlight と開発ビルドだけに出す**（showsBundledSamples）。
        // 積んであるのは自前の 3 本だけで、第三者の実物は Debug のときしか
        // 写していない（Scripts/embed_debug_jsfx.sh。再配布しない）。
        // 毎回消してから写し直すのは、同梱の側を直したときに古いものが残らないため。
        // 出さない版でも消すのは、ベータから店の版へ入れ替えた端末に残さないため。
        let bundledRoot = try? Self.storageURL("JSFX/DebugFactory")
        if let bundledRoot { try? FileManager.default.removeItem(at: bundledRoot) }
        let showsBundled = Self.showsBundledSamples
        if showsBundled {
            if let bundledRoot { try? FileManager.default.createDirectory(at: bundledRoot, withIntermediateDirectories: true) }
            if let bundled = Bundle.main.resourceURL?.appendingPathComponent("DebugJSFXFactory", isDirectory: true),
               let files = FileManager.default.enumerator(at: bundled, includingPropertiesForKeys: nil,
                                                           options: [.skipsHiddenFiles]) {
                for case let source as URL in files where source.pathExtension.lowercased() == "jsfx" {
                    _ = try? Self.debugCopy(of: source, root: bundledRoot)
                }
            }
        }
        Self.removeLegacyDebugCopies()
        var discovered = Self.ownedEntries(at: try? Self.storageURL("JSFX/Sources"), debug: false)
        if showsBundled {
            discovered += Self.ownedEntries(at: bundledRoot, debug: true)
        }
        entries = Dictionary(grouping: discovered, by: \.id).compactMap { $0.value.first }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        entryAliases = Self.debugAliases(for: entries)
    }

    /// Copies a security-scoped Files/iCloud URL into the app-owned sandbox.
    /// Runtime code never retains or reopens the original URL.
    @discardableResult
    func importFile(_ source: URL) throws -> Entry {
        // 閉じた版では受けない（isEnabled）。画面の口は閉じてあるが、
        // 共有シートからも同じ関数へ来るので、ここでも止める。
        guard Self.isEnabled else {
            throw NSError(domain: "ETJSFX", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "JSFX is not available in this build."])
        }

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
        // 取り込み直したら 1 度は試す（同じ中身なら id も同じ）。
        Self.setStalled(entry.id, false)
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
        // 先に slot を空ける。retire の「音のスレッドが読み終えた」はここから数える。
        ETAUExternalBridge.shared.remove(instanceID: instanceID)
        if let instance = instances.removeValue(forKey: instanceID) {
            instance.loadTask?.cancel(); instance.stateTask?.cancel()
            retire(instance)
        }
        revision &+= 1
    }

    func removeAll() { for id in Array(instances.keys) { remove(instanceID: id) } }
    func suspend() {
        renderConfiguration = nil
    }

    /// 外した host を、誰も触らなくなった時点で壊す。
    ///
    /// **音が止まるまで待たない。**前は suspend() でしか壊さず、AudioIO は
    /// 起動中ずっと回っているので、消した段もプリセットで入れ替えた段も
    /// 生き残っていた。EEL の RAM は全体 64 MiB（NSEEL_RAM_limitmem）で数えるので、
    /// 重いスクリプトを 4 回入れ替えると上限に届き、以後の確保は全部
    /// 1 つの共有セル（nseel_ramalloc_onfail）へ落ちて音が壊れた（診断なし）。
    ///
    /// 壊してよいのは次の 3 つが済んでから:
    /// 1. 走っている状態保存・再設定（nativeTail）。途中で壊すと解放後に読む。
    /// 2. 音のスレッドが 2 周（EffeTuneDSP.retire と同じ数え方）。slot は
    ///    remove() で空けてあるので、その後に始まった周は古い descriptor を読まない。
    ///    鳴っていなければ周は進まないので 0.5 秒で諦める（鳴っていない＝誰も読んでいない）。
    /// 3. GFX の列に積まれた描画・マウス・鍵。**壊すのもその列で行う**ので、順番で済む。
    /// menu は先に畳む（開いたままだと 3 が最長 30 秒詰まる）。
    ///
    /// host がまだ無い（建てている最中）なら、建て終えた側が壊す（build を読むこと）。
    private func retire(_ instance: Instance) {
        guard let host = instance.host else { return }
        let gate = instance.menuGate, queue = instance.gfxQueue
        let pending = instance.nativeTail
        let mark = ETPipeline_ProcessCount()
        gate.hold()   // 戻さない。以後この host で menu は開かない。
        Task.detached(priority: .utility) {
            await pending?.value
            let deadline = Date().addingTimeInterval(0.5)
            while ETPipeline_ProcessCount() < mark + 2 && Date() < deadline {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            queue.async {
                ETJSFX_Destroy(host)
                withExtendedLifetime(gate) {}
            }
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
        // **NaN と無限は受けない。**Double("nan") は通り、min/max は NaN を素通しする。
        // 渡すと次の描画で列挙つまみの Int() が落ちていた。
        guard value.isFinite, let instance = instances[instanceID], let host = instance.host,
              let offset = instance.parameters.firstIndex(where: { $0.id == parameterID }) else { return }
        let p = instance.parameters[offset]
        let clamped = min(max(value, p.minimum), p.maximum)
        ETJSFX_SetSlider(host, parameterID, clamped)
        instance.parameters[offset].value = clamped
        revision &+= 1
        snapshotState(instance, user: true)
    }

    func normalizedValue(instanceID: String, parameterID: UInt32, value: Double) -> Double {
        guard let host = instances[instanceID]?.host else { return 0 }
        // 値はスクリプトが NaN や無限を書ける。Slider へは 0...1 の有限値だけ渡す。
        let normalized = ETJSFX_SliderToNormalized(host, parameterID, value)
        return normalized.isFinite ? min(max(normalized, 0), 1) : 0
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

    /// このスクリプトが `trigger` を読むか。**読まないものに札を出さない。**
    func usesTrigger(instanceID: String) -> Bool {
        guard let host = instances[instanceID]?.host else { return false }
        return ETJSFX_UsesTrigger(host)
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

    /// 原寸で貼るときの高さ（point）。
    ///
    /// framebuffer は `canvas × gfxPixelScale` 画素なので、それを画面の倍率で
    /// 割った点数が「framebuffer の 1 画素 = 画面の 1 画素」になる。
    /// `gfx_ext_retina` を名乗るものは pixelScale が画面の倍率なので宣言どおりの
    /// 点数、名乗らないものは画面の倍率だけ小さくなる。
    /// **canvas の点数をそのまま point として使ってはいけない**（3x の端末で
    /// 1 画素が 3x3 に膨らみ、原寸でも鮮明でもなくなる）。
    func gfxNativeHeight(instanceID: String, canvas: CGSize, screenScale: CGFloat) -> CGFloat {
        let pixels = gfxPixelScale(instanceID: instanceID, size: canvas, screenScale: screenScale)
        return max(1, canvas.height * pixels / max(1, screenScale))
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
                // 1 枚描けた。待たせていた離しが在ればここで渡す。
                if self.instances[instanceID] === instance { self.mouseFrameDrawn(instance) }
                completion(image)
            }
        }
    }

    /// 指の位置と押し下げを渡す。
    ///
    /// **離しは 1 枚描いてから渡す。**軽く叩いただけだと、押しと離しが
    /// 10 マイクロ秒と離れずに来る（実測: 02:27:27.663141 押し →
    /// .663149 離し → .671235 で初めて @gfx）。その間に @gfx が 1 度も回らないので、
    /// スクリプトから見た `mouse_cap` はずっと 0 のままになる。
    ///
    /// つまみの類は「押している間に座標が変わる」ことで動くので、押しを 1 枚も
    /// 見なくても最後の座標で動く。**`gfx_showmenu` だけが「押した瞬間」
    /// （`down && !last_down`）を要る**ので、そこだけが落ちていた。
    func updateMouse(instanceID: String, point: CGPoint, buttons: UInt32) {
        guard let instance = instances[instanceID], let host = instance.host else { return }
        instance.userTouched = true
        let x = Int32(point.x), y = Int32(point.y)
        guard buttons == 0 else {
            instance.pressSeen = false
            instance.gfxQueue.async { ETJSFX_GFXMouse(host, 0, x, y, buttons, 0, 0) }
            return
        }
        // 押しがまだ 1 枚も描かれていなければ、描かれるまで離さない。
        guard instance.pressSeen else {
            instance.pendingRelease = (x, y)
            return
        }
        instance.gfxQueue.async { ETJSFX_GFXMouse(host, 0, x, y, 0, 0, 0) }
    }

    /// 1 枚描き終えたときに呼ぶ。押しが見られたことを控え、
    /// 待たせていた離しが在ればここで渡す。
    private func mouseFrameDrawn(_ instance: Instance) {
        guard let host = instance.host else { return }
        instance.pressSeen = true
        guard let release = instance.pendingRelease else { return }
        instance.pendingRelease = nil
        instance.gfxQueue.async {
            ETJSFX_GFXMouse(host, 0, release.0, release.1, 0, 0, 0)
        }
    }

    func updateKey(instanceID: String, modifiers: UInt32, key: UInt32, pressed: Bool) {
        guard let instance = instances[instanceID], let host = instance.host else { return }
        instance.userTouched = true
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

    /// 建てきるまでの上限。**コンパイルと @init と状態の復元の合計。**
    ///
    /// コンパイルは C 側が 2 秒で切るが、測るのは終わった後で、@init には門が無い。
    /// EEL の実行を途中で切る口も無いので、REAPER 向けに書かれた重い @init は
    /// 帰ってこない。そのたびに段は "Compiling…" のまま、鎖は保存済みなので
    /// 次の起動でまた建て、スレッドを 1 本ずつ塞いでいた。
    /// 越えたら印（stalled）を付けて表示に出す。外さずに待ち、帰ってきたら載せて印を消す。
    /// 印が残ったまま終わった（帰ってこなかった）ものは、次の起動で建てない。
    /// スレッドは止められないので残るが、専用スレッドなので他の仕事は塞がない。
    private static let loadLimit: Duration = .seconds(10)
    private static let stalledMessage = "JSFX did not finish loading."

    private func build(_ instance: Instance, configuration: RenderConfiguration) {
        guard instance.loadTask == nil else { return }
        let path = instance.entry.url.path, state = instance.state, id = instance.id
        let entryID = instance.entry.id
        // 前に建ちきらなかったものは建てない。建てるたびに 1 本回り続ける。
        guard !Self.isStalled(entryID) else { fail(instance, Self.loadError(Self.stalledMessage)); return }
        // **時間切れでも外さない。**印と表示だけにして、帰ってきたら普通に載せる。
        // 外すと、PORTABLE で @init が重いだけのスクリプトが毎回ここで捨てられ、
        // 印も完了で消えるので、起動のたびに建てては捨てて二度と載らない。
        // 印は「建ちきらないまま終わった」ときだけ残り、次の起動で建てない理由になる。
        // 数えるのは起きている間だけ（SuspendingClock）。裏に回った間は数えない。
        let limit = Task { @MainActor [weak self] in
            try? await Task.sleep(until: .now + Self.loadLimit, clock: .suspending)
            guard !Task.isCancelled, let self,
                  let current = self.instances[id], current === instance, current.host == nil else { return }
            Self.setStalled(entryID, true)
            current.error = Self.stalledMessage
            // 足すのを待っている picker には段を出させる。建ち終われば同じ slot に入る
            // （restore と同じ、段はあって中身がまだの形）。
            if let ready = current.ready, let index = ETAUExternalBridge.shared.index(for: id) {
                current.ready = nil
                ready(.success(index))
            }
            self.revision &+= 1
        }
        instance.loadTask = Task { @MainActor in
            // **協調プールで回さない。**ETJSFXLoader を読むこと（スタックと、帰ってこない @init）。
            let (created, failure) = await ETJSFXLoader.run { () -> (OpaquePointer?, String?) in
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
                return (host, error)
            }
            limit.cancel()
            // 遅れてでも帰ってきたなら、止まらないスクリプトではない。
            Self.setStalled(entryID, false)
            guard let current = self.instances[id], current === instance else {
                // 外された。slot にも載せていないのでそのまま壊す。
                if let created { Task.detached(priority: .utility) { ETJSFX_Destroy(created) } }
                return
            }
            current.loadTask = nil
            guard let host = created else {
                self.fail(current, Self.loadError(failure ?? "Could not load JSFX.")); return
            }
            do {
                let index = try ETAUExternalBridge.shared.install(ETJSFX_Processor(host), instanceID: id)
                ETJSFX_SetGFXMenuCallback(host, etJSFXMenuCallback,
                                          Unmanaged.passUnretained(current.menuGate).toOpaque())
                current.host = host; current.parameters = Self.readParameters(host); current.error = nil
                self.snapshotState(current)
                current.ready?(.success(index)); current.ready = nil
                self.revision &+= 1
                self.followRenderConfiguration(current, built: configuration)
            } catch {
                // install は slot を取る前に投げる。音のスレッドは読んでいない。
                Task.detached(priority: .utility) { ETJSFX_Destroy(host) }
                self.fail(current, error)
            }
        }
    }

    /// 建てられなかった instance を外す。鎖の段は残る（status は "JSFX unavailable"）。
    private func fail(_ instance: Instance, _ error: Error) {
        instance.error = error.localizedDescription
        instance.ready?(.failure(error)); instance.ready = nil
        ETAUExternalBridge.shared.remove(instanceID: instance.id)
        instances.removeValue(forKey: instance.id)
        revision &+= 1
    }

    private static func loadError(_ message: String) -> Error {
        NSError(domain: "ETJSFX", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func reconfigure(_ host: OpaquePointer, instance: Instance,
                             configuration: RenderConfiguration) {
        guard instance.loadTask == nil else { return }
        let id = instance.id, entryID = instance.entry.id
        // ysfx_init が @init を回し直すので、建てるときと同じく帰ってこないことがある。
        // host は @init の途中なので壊せない。印と表示だけにして、loadTask は残す
        // （残せば resume が重ねない）。
        let limit = Task { @MainActor [weak self] in
            try? await Task.sleep(until: .now + Self.loadLimit, clock: .suspending)
            guard !Task.isCancelled, let self,
                  let current = self.instances[id], current === instance else { return }
            Self.setStalled(entryID, true)
            current.error = Self.stalledMessage
            self.revision &+= 1
        }
        let operation = enqueue(instance, onLoader: true) {
            ETJSFX_Reconfigure(host, configuration.sampleRate, UInt32(configuration.maxFrames))
        }
        instance.loadTask = Task { @MainActor in
            let ok = await operation.value
            limit.cancel()
            Self.setStalled(entryID, false)
            guard let current = self.instances[id], current === instance else { return }
            current.loadTask = nil
            do {
                guard ok else { throw NSError(domain: "ETJSFX", code: 2,
                                              userInfo: [NSLocalizedDescriptionKey: "JSFX reconfiguration failed."]) }
                _ = try ETAUExternalBridge.shared.install(ETJSFX_Processor(host), instanceID: id)
                current.parameters = Self.readParameters(host); current.error = nil
            } catch { current.error = error.localizedDescription }
            self.revision &+= 1
            if ok { self.followRenderConfiguration(current, built: configuration) }
        }
    }

    /// 建てた・組み直した設定が、いまの設定と違えば組み直す。
    ///
    /// **走っている間に来た resume は捨てられる**（build / reconfigure の頭の
    /// loadTask の門）。そのままだと古い srate / maxFrames で回り、ブロックが
    /// maxFrames を超えると ETExternalProcessor_Process が -2 を返して鎖ごと落ちる。
    /// 違わなければ何もしないので、繰り返しは設定が変わった回数で止まる。
    private func followRenderConfiguration(_ instance: Instance, built: RenderConfiguration) {
        guard let current = renderConfiguration, current != built, let host = instance.host else { return }
        reconfigure(host, instance: instance, configuration: current)
    }

    /// 保守を instance ごとの列に並べる。**頼んだ順に 1 本ずつ流す。**
    ///
    /// 状態保存と再設定は別々の Task から来る。C 側は入口を通ったものを 1 本ずつ
    /// 通すが、ETJSFX_Destroy が守れるのは「もう入口を通ったもの」だけで、
    /// これから呼ばれるものは守れない（ETJSFXHost.h）。retire はこの列の最後尾を
    /// 待ってから壊すので、頼んだのに走っていないものを置き去りにしない。
    /// 順番が決まるので、古い保存が新しい保存の後に書き戻すこともない。
    /// 入る前に menu を畳む（ETJSFXMenuGate）。onLoader は @init を回すもの。
    /// holdsMenu が false なら gate に触らない（状態保存。work の側で holdIfIdle する）。
    /// **並べるのは呼んだその場で**（await の後にすると、間に来た remove が取りこぼす）。
    private func enqueue<T: Sendable>(_ instance: Instance, onLoader: Bool = false,
                                      holdsMenu: Bool = true,
                                      _ work: @escaping @Sendable () -> T) -> Task<T, Never> {
        let previous = instance.nativeTail, gate = instance.menuGate
        let operation = Task.detached(priority: .utility) { () -> T in
            await previous?.value
            if holdsMenu { gate.hold() }
            defer { if holdsMenu { gate.release() } }
            if onLoader { return await ETJSFXLoader.run(work) }
            return work()
        }
        instance.nativeTail = Task.detached(priority: .utility) { _ = await operation.value }
        return operation
    }

    /// 状態を控える。つまみの連打をまとめるため 250 ms 待つ。
    ///
    /// **人の操作（user）には上限がある（最初に頼まれてから 2 秒）。**前は頼まれるたびに
    /// 待ちを捨てて測り直していた。毎ブロック sliderchange() を撃つメーター型の
    /// スクリプトでは 10Hz の見回りが 100 ms ごとに頼むので 250 ms が満ちず、
    /// つまみを動かしても保存されなかった（起動し直すと戻る）。
    /// **スクリプトからの頼みには上限を掛けない。**掛けるとメーター型が鳴っている間
    /// 2 秒ごとに保存し（そのたび素通し）、値が動くので persist と iCloud まで毎回走る。
    /// 人の操作が待っていれば、その期限を後ろへずらさないだけ。
    /// @gfx の中のつまみは sliderchange でしか分からないので、指か鍵が来たあと
    /// （userTouched）の頼みを人の操作として扱う。
    ///
    /// **menu を畳まない。**出ていれば閉じるまで待ってから書く。状態保存は急ぐものではなく、
    /// 開いたまま書けば SaveState は gfxActive を待って素通しが続く。
    ///
    /// 書き始めたら取り消さない。後から来た頼みは次の保存として後ろに並ぶ。
    private func snapshotState(_ instance: Instance, user: Bool = false) {
        guard instance.host != nil else { return }
        let now = ContinuousClock.now
        if user || instance.userTouched { instance.snapshotSince = instance.snapshotSince ?? now }
        var due = now + .milliseconds(250)
        if let since = instance.snapshotSince { due = min(due, since + .seconds(2)) }
        let id = instance.id, gate = instance.menuGate
        instance.stateTask?.cancel()
        instance.stateTask = Task { @MainActor in
            try? await Task.sleep(until: due, clock: .continuous)
            while true {
                guard !Task.isCancelled, let host = instance.host,
                      self.instances[id] === instance else { return }
                if !gate.isShowing {
                    let since = instance.snapshotSince, touched = instance.userTouched
                    instance.snapshotSince = nil; instance.userTouched = false
                    let result = await self.enqueue(instance, holdsMenu: false) { () -> Snapshot in
                        // 並んでいる間に開いたら書かない（畳まない）。
                        guard gate.holdIfIdle() else { return .menuShown }
                        defer { gate.release() }
                        var bytes: UnsafeMutablePointer<UInt8>?, size = 0
                        guard ETJSFX_SaveState(host, &bytes, &size), let bytes else { return .saved(nil) }
                        defer { ETJSFX_FreeBytes(bytes) }
                        return .saved(Data(bytes: bytes, count: size))
                    }.value
                    if case .saved(let data) = result {
                        // 同じ中身なら鎖を書き直さない（メーター型は値が動かなくても頼んでくる）。
                        guard let current = self.instances[id], current === instance,
                              let data, data != current.state else { return }
                        current.state = data
                        EffeTuneDSP.shared.externalStateDidChange(instanceID: id)
                        return
                    }
                    // 書けなかったので、人の操作の期限を戻す。
                    instance.snapshotSince = instance.snapshotSince ?? since
                    instance.userTouched = instance.userTouched || touched
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    // MARK: - 建ちきらなかったもの

    /// 時間切れになった source の id（中身の sha256 から作るので、直せば別の id になる）。
    private static let stalledKey = "jsfx.stalled"

    private static func isStalled(_ entryID: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: stalledKey) ?? []).contains(entryID)
    }

    private static func setStalled(_ entryID: String, _ stalled: Bool) {
        var list = UserDefaults.standard.stringArray(forKey: stalledKey) ?? []
        guard list.contains(entryID) != stalled else { return }
        if stalled { list.append(entryID) } else { list.removeAll { $0 == entryID } }
        UserDefaults.standard.set(list, forKey: stalledKey)
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
