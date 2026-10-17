//  VisualizerJSFX.swift
//  Visualizer の JSFX の要素。取り込んだ JSFX のうち @gfx を持つものを、Visualizer の音で動かして絵だけ取る。
//
//  **要素ごとに専用の VM を建てる。鎖には載せない**（ETAUExternalBridge の slot を取らない）。
//  鎖に載った段の影にはしない: 鎖の段は音のスレッドが回し、@gfx はその段が処理した音で動く。
//  ここは Visualizer が輪（ETMeterTap）から 1 回だけ読んだ標本を、主スレッドが要素の列へ写し、
//  要素の直列キューが @block/@sample を回して（出力は捨てる）@gfx を走らせる。
//  **音のスレッドには何も足さない。**主スレッドは標本を写すだけ。
//
//  VM は鎖に載らないので、処理の締切の判定（自動バイパス）は外す（ETJSFX_SetOffline）。
//  重さは、標本を捨てる（溜めは 4096 フレームまで）ことと、遅すぎる要素を止める（EMA 25ms）ことで抑える。
//  同時に動かすのは 2 つまで。EEL の RAM が大きいときは新しく建てない。
//  マウス・キー・@serialize の状態は扱わない（絵を出すだけ）。

import Combine
import CoreGraphics
import Foundation
import os

private let jsfxLog = Logger(subsystem: "ai.nemut.effetune", category: "visualizer")

// MARK: - @gfx を持つ JSFX の一覧

/// 取り込んだ JSFX のうち @gfx を持つもの。中身を読むのは主でない所で、id と更新日で覚える。
@MainActor
final class ETVisualizerJSFXCatalog: ObservableObject {

    static let shared = ETVisualizerJSFXCatalog()

    @Published private(set) var graphical: [ETJSFXHost.Entry] = []
    /// id + 更新日 → @gfx を持つか。
    private var known: [String: Bool] = [:]

    private init() {}

    private static func included(_ entry: ETJSFXHost.Entry) -> Bool {
#if DEBUG
        return true
#else
        return !entry.isDebugFixture
#endif
    }

    private static func key(_ entry: ETJSFXHost.Entry) -> String {
        let date = (try? entry.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return entry.id + "|" + String(date?.timeIntervalSince1970 ?? 0)
    }

    /// 追加の画面が開いたときに呼ぶ。まだ読んでいないものだけ、主でない所で読む。
    func refresh() {
        let list = ETJSFXHost.shared.entries.filter(Self.included)
        let keyed = list.map { ($0, Self.key($0)) }
        let missing = keyed.filter { known[$0.1] == nil }
        publish(keyed)
        guard !missing.isEmpty else { return }
        Task.detached(priority: .utility) {
            var found: [String: Bool] = [:]
            for (entry, key) in missing {
                let has = ETJSFXHost.sourceText(for: entry).map { text in
                    JSFXSourceDocument(source: text).sections.contains { $0.name == "@gfx" }
                } ?? false
                found[key] = has
            }
            await MainActor.run {
                let catalog = ETVisualizerJSFXCatalog.shared
                catalog.known.merge(found) { _, new in new }
                catalog.publish(keyed)
            }
        }
    }

    private func publish(_ keyed: [(ETJSFXHost.Entry, String)]) {
        let list = keyed.filter { known[$0.1] == true }.map(\.0)
        if list != graphical { graphical = list }
    }
}

// MARK: - 状態

enum ETVisualizerJSFXStatus: Equatable {
    case starting, running, missing, limit, memory, failed, tooSlow

    var label: String {
        switch self {
        case .starting: return "Starting"
        case .running: return "Running"
        case .missing: return "Not Found"
        case .limit: return "Limit Reached"
        case .memory: return "Out of Memory"
        case .failed: return "Failed"
        case .tooSlow: return "Too Slow"
        }
    }
}

extension ETJSFXHost.Parameter: Equatable {
    static func == (a: ETJSFXHost.Parameter, b: ETJSFXHost.Parameter) -> Bool {
        a.id == b.id && a.name == b.name && a.minimum == b.minimum && a.maximum == b.maximum && a.step == b.step
            && a.shape == b.shape && a.visible == b.visible && a.enumNames == b.enumNames && a.value == b.value
    }
}

struct ETVisualizerJSFXInfo: Equatable {
    var status: ETVisualizerJSFXStatus
    /// 見えるつまみだけ。
    var parameters: [ETJSFXHost.Parameter]
}

private struct JSFXMakeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - 要素 1 つぶんの VM

/// 要素 1 つぶんの VM。鎖には載せない（slot を取らない）。音のスレッドは触らない。
final class ETVisualizerJSFXRuntime: @unchecked Sendable {

    let id: UUID
    let sampleRate: Double
    /// @gfx が gfx_ext_retina を名乗るか。
    let retina: Bool
    let frameRate: Double
    /// 建てた直後（つまみを渡す前）の実値。つまみの印が要素から消えたとき（取り消し）に、これへ戻す。
    let defaults: [UInt32: Double]

    private let host: OpaquePointer
    private let queue = DispatchQueue(label: "ai.nemut.effetune.visualizer.jsfx", qos: .userInitiated)
    private let lock = OSAllocatedUnfairLock()
    /// 左右交互。溜めは 4096 フレーム（8192 個）まで。あふれたら古いほうを捨てる。
    private var pending: [Float] = []
    private var planar = [Float](repeating: 0, count: 2 * 1024)
    private var sampleTime = 0.0
    /// lock の中でだけ読み書きする。
    private var latest: CGImage?
    private var slow = false
    private var slowMillis = 0.0
    /// 主スレッドだけ。
    private var inFlight = false
    /// 頼みを出した時刻（CACurrentMediaTime）。EEL には割り込みが無いので、返らない処理はこれの古さで見つける。
    private var inFlightSince = 0.0
    private var lastRequest = 0.0
    private var stopped = false
    private var sentSize: (w: Int, h: Int, scale: Double)?
    private var wantedSize: (w: Int, h: Int, scale: Double, since: Double)?
    /// キューだけ。
    private var appliedSize: (Int, Int, Double)?
    private var pixels: [UInt8] = []
    private var stepMillisEMA = 0.0
    private var steps = 0

    private static let maxPendingFrames = 4096
    private static let sizeSettle = 0.3

    fileprivate init(id: UUID, sampleRate: Double, host: OpaquePointer, retina: Bool, frameRate: Double,
                     defaults: [UInt32: Double]) {
        self.id = id
        self.defaults = defaults
        self.sampleRate = sampleRate
        self.host = host
        self.retina = retina
        self.frameRate = frameRate
        pending.reserveCapacity(2 * Self.maxPendingFrames)
    }

    deinit {
        if !stopped { ETJSFX_Destroy(host) }
    }

    /// 建てる。専用スレッドでコンパイルと @init を回す（ETJSFXLoader）。
    static func make(entry: ETJSFXHost.Entry, element: ETVisualizerJSFXElement, id: UUID,
                     sampleRate: Double) async -> Result<(ETVisualizerJSFXRuntime, [ETJSFXHost.Parameter]), Error> {
        let path = entry.url.path
        let sliders = element.sliders
        let built = await ETJSFXLoader.run { () -> (OpaquePointer?, String, Bool, Double, [ETJSFXHost.Parameter], [UInt32: Double]) in
            var message = [CChar](repeating: 0, count: 512)
            let created = path.withCString { ETJSFX_Create($0, sampleRate, 1024, &message, message.count) }
            guard let host = created else { return (nil, String(cString: message), false, 30, [], [:]) }
            ETJSFX_SetOffline(host, true)
            let defaults = readDefaults(host)
            for (index, value) in sliders { ETJSFX_SetSlider(host, index, value) }
            // 描かせるには「見えている」と伝える。
            ETJSFX_GFXWindowState(host, false, true, false)
            guard ETJSFX_HasGFX(host) else {
                ETJSFX_Destroy(host)
                return (nil, "No @gfx section.", false, 30, [], [:])
            }
            let rate = Double(ETJSFX_GFXFrameRate(host))
            return (host, "", ETJSFX_GFXWantsRetina(host), rate > 0 ? min(rate, 60) : 30, readParameters(host), defaults)
        }
        guard let host = built.0 else { return .failure(JSFXMakeError(message: built.1)) }
        let runtime = ETVisualizerJSFXRuntime(id: id, sampleRate: sampleRate, host: host, retina: built.2,
                                              frameRate: built.3, defaults: built.5)
        return .success((runtime, built.4))
    }

    /// 全部のつまみの、いまの値（番号 → 実値）。
    private static func readDefaults(_ host: OpaquePointer) -> [UInt32: Double] {
        var values: [UInt32: Double] = [:]
        for ordinal in 0..<ETJSFX_SliderCount(host) {
            var index: UInt32 = 0, shape: UInt8 = 0
            var name: UnsafePointer<CChar>?
            var value = 0.0, minimum = 0.0, maximum = 1.0, step = 0.0
            var visible = true
            if ETJSFX_SliderInfo(host, ordinal, &index, &name, &value, &minimum, &maximum, &step, &shape, &visible),
               value.isFinite {
                values[index] = value
            }
        }
        return values
    }

    /// 見えるつまみだけ。
    private static func readParameters(_ host: OpaquePointer) -> [ETJSFXHost.Parameter] {
        (0..<ETJSFX_SliderCount(host)).compactMap { ordinal in
            var index: UInt32 = 0, shape: UInt8 = 0
            var name: UnsafePointer<CChar>?
            var value = 0.0, minimum = 0.0, maximum = 1.0, step = 0.0
            var visible = true
            guard ETJSFX_SliderInfo(host, ordinal, &index, &name, &value, &minimum, &maximum, &step, &shape, &visible),
                  visible else { return nil }
            let enumNames = (0..<ETJSFX_SliderEnumCount(host, index)).compactMap { item -> String? in
                ETJSFX_SliderEnumName(host, index, item).map(String.init(cString:))
            }
            return ETJSFXHost.Parameter(
                id: index, name: name.map(String.init(cString:)) ?? "Slider \(index + 1)",
                minimum: minimum, maximum: maximum, step: step, shape: shape, visible: visible,
                enumNames: enumNames, value: value)
        }
    }

    var image: CGImage? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    /// 遅すぎると見て止めるか（主スレッドが読む）。
    var isTooSlow: Bool {
        lock.lock()
        defer { lock.unlock() }
        return slow
    }

    /// 主スレッド。頼みを出したまま返ってこない秒数（返っているなら 0）。
    func hungSeconds(now: Double) -> Double {
        inFlight ? max(0, now - inFlightSince) : 0
    }

    /// 止めたときの 1 回あたりの時間の EMA（ミリ秒。ログ用）。
    var tooSlowMillis: Double {
        lock.lock()
        defer { lock.unlock() }
        return slowMillis
    }

    /// 主スレッド。Visualizer が輪から読んだ標本（左右交互）を溜める。
    func feed(_ interleaved: UnsafeBufferPointer<Float>, frames: Int) {
        guard !stopped, frames > 0 else { return }
        lock.lock()
        pending.append(contentsOf: interleaved.prefix(2 * frames))
        let limit = 2 * Self.maxPendingFrames
        if pending.count > limit { pending.removeFirst(pending.count - limit) }
        lock.unlock()
    }

    /// 主スレッド。1 枚描く頼みを出せたら true。
    /// 前の頼みが終わっていない・間隔が足りないときは出さない。大きさが替わっても、同じ大きさが 0.3 秒続くまでは
    /// 前の大きさで描く（絵は引き伸ばして出る）。
    @discardableResult
    func requestFrame(logical: CGSize, surfaceScale: CGFloat, now: Double) -> Bool {
        guard !stopped, !inFlight, now - lastRequest >= 1 / frameRate - 0.002 else { return false }
        let width = max(1, Double(logical.width)), height = max(1, Double(logical.height))
        // ETJSFXHost.gfxPixelScale と同じ規則（縦横比を保って 2048 と 16 MiB に収める）。
        let requested = retina ? Double(surfaceScale) : 1
        let limit = min(2048 / width, 2048 / height, (Double(16 * 1024 * 1024) / (width * height * 4)).squareRoot())
        let scale = max(0.01, min(requested, limit))
        let wanted = (w: max(1, Int(width * scale)), h: max(1, Int(height * scale)), scale: scale)
        if let current = wantedSize, current.w == wanted.w, current.h == wanted.h, current.scale == wanted.scale {
            // 同じ大きさが続いている。
        } else {
            wantedSize = (wanted.w, wanted.h, wanted.scale, now)
        }
        var size = sentSize ?? wanted
        if let current = wantedSize, now - current.since >= Self.sizeSettle {
            size = (current.w, current.h, current.scale)
        }
        sentSize = size
        inFlight = true
        inFlightSince = now
        lastRequest = now
        queue.async { [self] in
            step(width: size.w, height: size.h, scale: size.scale)
            DispatchQueue.main.async { self.inFlight = false }
        }
        return true
    }

    /// キューの上。溜めた標本を回して（出力は捨てる）@gfx を走らせ、絵を取る。
    private func step(width: Int, height: Int, scale: Double) {
        let started = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let samples = pending
        pending.removeAll(keepingCapacity: true)
        lock.unlock()

        var processor = ETJSFX_Processor(host)
        let total = samples.count / 2
        var offset = 0
        while offset < total {
            let n = min(1024, total - offset)
            for i in 0..<n {
                planar[i] = samples[2 * (offset + i)]
                planar[n + i] = samples[2 * (offset + i) + 1]
            }
            planar.withUnsafeMutableBufferPointer { buffer in
                _ = ETExternalProcessor_Process(&processor, buffer.baseAddress, 2, UInt32(n), sampleRate, sampleTime)
            }
            sampleTime += Double(n) / sampleRate
            offset += n
        }

        let dirty = ETJSFX_RunGFX(host, UInt32(width), UInt32(height), retina ? scale : 1)
        let changed = appliedSize == nil || appliedSize! != (width, height, scale)
        if dirty || changed || image == nil {
            copyImage(width: width, height: height)
            appliedSize = (width, height, scale)
        }

        let millis = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        stepMillisEMA = steps == 0 ? millis : stepMillisEMA * 0.9 + millis * 0.1
        steps += 1
        if steps >= 60 && stepMillisEMA > 25 {
            lock.lock()
            slow = true
            slowMillis = stepMillisEMA
            lock.unlock()
        }
    }

    private func copyImage(width: Int, height: Int) {
        let count = width * height * 4
        if pixels.count != count { pixels = [UInt8](repeating: 0, count: count) }
        var actualWidth: UInt32 = 0, actualHeight: UInt32 = 0, stride: UInt32 = 0
        guard ETJSFX_CopyGFX(host, &pixels, pixels.count, &actualWidth, &actualHeight, &stride),
              actualWidth > 0, actualHeight > 0 else { return }
        let bytes = Int(stride) * Int(actualHeight)
        guard bytes <= pixels.count,
              let provider = CGDataProvider(data: Data(pixels[0..<bytes]) as CFData),
              let image = CGImage(
                width: Int(actualWidth), height: Int(actualHeight), bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: Int(stride), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                         | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return }
        lock.lock()
        latest = image
        lock.unlock()
    }

    /// つまみを動かす（どのスレッドからでもよい。次の処理の頭で渡る）。
    func setSlider(_ index: UInt32, _ value: Double) {
        guard !stopped else { return }
        ETJSFX_SetSlider(host, index, value)
    }

    func normalized(_ index: UInt32, _ value: Double) -> Double {
        stopped ? 0 : ETJSFX_SliderToNormalized(host, index, value)
    }

    func fromNormalized(_ index: UInt32, _ n: Double) -> Double {
        stopped ? 0 : ETJSFX_SliderFromNormalized(host, index, n)
    }

    /// 主スレッド。止める。壊すのはキューの最後（走っている処理の後）。
    func stop() {
        guard !stopped else { return }
        stopped = true
        let host = host
        queue.async { ETJSFX_Destroy(host) }
    }
}

// MARK: - 持ち主

/// 要素 UUID → VM。面（アプリの画面・PiP）が acquire し、誰も要らなくなったら止める。
@MainActor
final class ETVisualizerJSFXPool: ObservableObject {

    static let shared = ETVisualizerJSFXPool()
    static let maxLive = 2
    /// EEL の RAM の全体がこれを超えているときは、新しく建てない。
    static let eelLimit = 32 * 1024 * 1024
    /// 1 枚の頼みがこの秒数を過ぎても返らなければ、止まらない処理とみなして止める。
    static let hangLimit = 2.0
    /// 建てる（コンパイルと @init）がこの秒数を過ぎても終わらなければ、失敗とみなして枠を空ける。
    static let startLimit = 10.0

    /// 起動・停止・状態が替わったときだけ変わる。
    @Published private(set) var info: [UUID: ETVisualizerJSFXInfo] = [:]

    private var holderOrder: [ObjectIdentifier] = []
    private var lists: [ObjectIdentifier: [ETVisualizerElement]] = [:]
    private var runtimes: [UUID: ETVisualizerJSFXRuntime] = [:]
    private var starting: [UUID: Task<Void, Never>] = [:]
    /// 建て始めの印。古い建て（待っているうちに止めた・時間切れにした）の結果を捨てるのに使う。
    private var tokens: [UUID: UUID] = [:]
    private var startTimeouts: [UUID: Task<Void, Never>] = [:]
    /// 建てているか動いている要素の、建てたときの入口 id。
    private var started: [UUID: String] = [:]
    /// 失敗・遅すぎ・上限・メモリで止めた要素 → そのときの入口 id。同じ id のうちは建て直さない。
    private var blocked: [UUID: String] = [:]
    /// 動いている VM へ最後に渡したつまみ（実値）。要素のつまみとの違いを見て、取り消しやプリセットの分も渡す。
    private var applied: [UUID: [UInt32: Double]] = [:]
    private var entriesSink: AnyCancellable?

    private init() {
        // 取り込みが済んだら、見つからなかった要素をもう一度試す。@Published は値が入る前に流れるので 1 回遅らせる。
        entriesSink = ETJSFXHost.shared.$entries
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { _ in
                MainActor.assumeIsolated { ETVisualizerJSFXPool.shared.reconcile() }
            }
    }

    /// その持ち主の要素の並びを置き換える。
    func acquire(_ holder: AnyObject, elements: [ETVisualizerElement]) {
        let key = ObjectIdentifier(holder)
        if lists[key] == nil {
            holderOrder.append(key)
            // 持ち主が新しく取り直した。止めていた要素は建て直す。
            for element in elements { blocked[element.id] = nil }
        }
        lists[key] = elements.filter { $0.kind == .jsfx && $0.jsfx != nil }
        reconcile()
    }

    func release(_ holder: AnyObject) {
        let key = ObjectIdentifier(holder)
        guard lists.removeValue(forKey: key) != nil else { return }
        holderOrder.removeAll { $0 == key }
        reconcile()
    }

    /// 標本を全部の VM へ渡す。VM が無ければ何もしない。
    func feed(_ scratch: UnsafeBufferPointer<Float>, frames: Int) {
        guard !runtimes.isEmpty else { return }
        for runtime in runtimes.values { runtime.feed(scratch, frames: frames) }
    }

    /// 同じ要素を持っている持ち主のうち、いちばん後に取った（いま前にある）もの。絵の大きさはこの持ち主が決める。
    private func driver(of id: UUID) -> ObjectIdentifier? {
        holderOrder.last { key in lists[key]?.contains(where: { $0.id == id }) == true }
    }

    /// 描いた後に呼ぶ。遅すぎる VM と返らない VM と標本率が替わった VM を止め、まだなら 1 枚頼む。
    /// `logical` は要素の枠（点）、`surfaceScale` は画素 / 点。
    /// 同じ要素を 2 つの面（編集画面と PiP）が回しているときは、頼むのは 1 つの面だけ
    /// （大きさが交互に替わって、落ち着く前の大きさのまま引き伸ばされるのを避ける）。
    func step(_ id: UUID, holder: AnyObject, logical: CGSize, surfaceScale: CGFloat, now: Double) {
        guard let runtime = runtimes[id] else { return }
        if runtime.isTooSlow {
            jsfxLog.notice("jsfx too slow id=\(id.uuidString, privacy: .public) ema=\(runtime.tooSlowMillis, privacy: .public)")
            stopTooSlow(id)
            return
        }
        let hung = runtime.hungSeconds(now: now)
        if hung > Self.hangLimit {
            jsfxLog.notice("jsfx hung id=\(id.uuidString, privacy: .public) seconds=\(hung, privacy: .public)")
            stopTooSlow(id)
            return
        }
        let rate = AudioIO.shared.sampleRate
        if rate > 0, rate != runtime.sampleRate {
            stopRuntime(id, reason: "sampleRate")
            reconcile()
            return
        }
        guard driver(of: id) == ObjectIdentifier(holder) else { return }
        runtime.requestFrame(logical: logical, surfaceScale: surfaceScale, now: now)
    }

    func images(for ids: [UUID]) -> [UUID: CGImage] {
        guard !runtimes.isEmpty else { return [:] }
        var result: [UUID: CGImage] = [:]
        for id in ids {
            if let image = runtimes[id]?.image { result[id] = image }
        }
        return result
    }

    func runtime(_ id: UUID) -> ETVisualizerJSFXRuntime? { runtimes[id] }

    func setSlider(_ id: UUID, index: UInt32, value: Double) {
        guard let runtime = runtimes[id] else { return }
        runtime.setSlider(index, value)
        applied[id, default: [:]][index] = value
    }

    // MARK: 揃える

    private func set(_ id: UUID, _ status: ETVisualizerJSFXStatus, parameters: [ETJSFXHost.Parameter]? = nil) {
        let next = ETVisualizerJSFXInfo(status: status, parameters: parameters ?? info[id]?.parameters ?? [])
        if info[id] != next { info[id] = next }
    }

    private func stopRuntime(_ id: UUID, reason: String) {
        starting.removeValue(forKey: id)?.cancel()
        startTimeouts.removeValue(forKey: id)?.cancel()
        tokens[id] = nil
        if let runtime = runtimes.removeValue(forKey: id) {
            runtime.stop()
            jsfxLog.notice("jsfx stop id=\(id.uuidString, privacy: .public) reason=\(reason, privacy: .public)")
        }
        started[id] = nil
        applied[id] = nil
    }

    /// 遅すぎる・返らない VM を止め、同じ入口のうちは建て直さない。
    /// **入口 id は止める前に控える**（止めると started から消える。空のまま入れると次の reconcile で解けて、建て直しを繰り返す）。
    private func stopTooSlow(_ id: UUID) {
        let entryID = started[id]
        stopRuntime(id, reason: "tooSlow")
        if let entryID { blocked[id] = entryID }
        // つまみの欄は止まった VM を指すので、出さない。
        set(id, .tooSlow, parameters: [])
    }

    /// 要る要素（持ち主の登録順に和集合）と動いているものを合わせる。
    private func reconcile() {
        var wanted: [ETVisualizerElement] = []
        var seen = Set<UUID>()
        for key in holderOrder {
            for element in lists[key] ?? [] where seen.insert(element.id).inserted { wanted.append(element) }
        }
        let wantedIDs = Set(wanted.map(\.id))

        // 要らなくなったもの、入口が替わったものを止める。
        var freed = false
        for id in Array(started.keys) {
            let entryID = wanted.first { $0.id == id }?.jsfx?.entryID
            if !wantedIDs.contains(id) || entryID != started[id] {
                stopRuntime(id, reason: wantedIDs.contains(id) ? "entry" : "removed")
                freed = true
            }
        }
        for id in Array(info.keys) where !wantedIDs.contains(id) { info[id] = nil }
        for (id, entryID) in blocked where wanted.first(where: { $0.id == id })?.jsfx?.entryID != entryID {
            blocked[id] = nil
        }
        // 空きができたら、上限・メモリで断った要素はもう一度試す。
        if freed {
            for (id, _) in blocked where info[id]?.status == .limit || info[id]?.status == .memory { blocked[id] = nil }
        }

        for element in wanted {
            guard let payload = element.jsfx, runtimes[element.id] == nil, starting[element.id] == nil,
                  blocked[element.id] == nil else { continue }
            guard let entry = ETJSFXHost.shared.entry(id: payload.entryID) else {
                // 見つからない間は reconcile のたびに通る（ドラッグ中は毎フレーム）。変わったときだけ記す。
                if info[element.id]?.status != .missing {
                    set(element.id, .missing, parameters: [])
                    jsfxLog.notice("jsfx refused id=\(element.id.uuidString, privacy: .public) reason=missing")
                }
                continue
            }
            if runtimes.count + starting.count >= Self.maxLive {
                set(element.id, .limit, parameters: [])
                blocked[element.id] = payload.entryID
                jsfxLog.notice("jsfx refused id=\(element.id.uuidString, privacy: .public) reason=limit")
                continue
            }
            if ETJSFX_EELMemoryUsed() > Self.eelLimit {
                set(element.id, .memory, parameters: [])
                blocked[element.id] = payload.entryID
                jsfxLog.notice("jsfx refused id=\(element.id.uuidString, privacy: .public) reason=memory")
                continue
            }
            start(element, payload: payload, entry: entry)
        }

        syncSliders(wanted)
    }

    /// 動いている VM のつまみを、要素のつまみに合わせる（取り消し・やり直し・プリセット・写しで要素の値だけが替わったとき）。
    /// つまみの印が要素から消えたときは、建てた直後の値に戻す。
    private func syncSliders(_ wanted: [ETVisualizerElement]) {
        for element in wanted {
            guard let payload = element.jsfx, let runtime = runtimes[element.id] else { continue }
            let target = payload.sliders
            let current = applied[element.id] ?? [:]
            guard target != current else { continue }
            for (index, value) in target where current[index] != value {
                runtime.setSlider(index, value)
            }
            for index in current.keys where target[index] == nil {
                if let value = runtime.defaults[index] { runtime.setSlider(index, value) }
            }
            applied[element.id] = target
        }
    }

    private func start(_ element: ETVisualizerElement, payload: ETVisualizerJSFXElement, entry: ETJSFXHost.Entry) {
        let id = element.id
        let rate = AudioIO.shared.sampleRate > 0 ? AudioIO.shared.sampleRate : 48000
        let token = UUID()
        set(id, .starting, parameters: [])
        started[id] = payload.entryID
        tokens[id] = token
        jsfxLog.notice("jsfx start id=\(id.uuidString, privacy: .public) entry=\(entry.id, privacy: .public) rate=\(rate, privacy: .public)")
        starting[id] = Task { @MainActor in
            let result = await ETVisualizerJSFXRuntime.make(entry: entry, element: payload, id: id, sampleRate: rate)
            guard !Task.isCancelled, tokens[id] == token, started[id] == payload.entryID else {
                // 待っているあいだに要らなくなった（時間切れにした）。建ったものは捨てる。
                if case .success(let made) = result { made.0.stop() }
                return
            }
            starting[id] = nil
            startTimeouts.removeValue(forKey: id)?.cancel()
            switch result {
            case .success(let made):
                runtimes[id] = made.0
                // 建てるときに渡したつまみ。建てている間に要素が替わっていたら、reconcile が差を渡す。
                applied[id] = payload.sliders
                set(id, .running, parameters: made.1)
                reconcile()
            case .failure(let error):
                started[id] = nil
                tokens[id] = nil
                blocked[id] = payload.entryID
                set(id, .failed, parameters: [])
                jsfxLog.notice("jsfx failed id=\(id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
        // @init が返らないスクリプトで枠を持ち続けない。
        startTimeouts[id] = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.startLimit))
            guard !Task.isCancelled, tokens[id] == token, starting[id] != nil else { return }
            jsfxLog.notice("jsfx start timeout id=\(id.uuidString, privacy: .public)")
            stopRuntime(id, reason: "startTimeout")
            blocked[id] = payload.entryID
            set(id, .failed, parameters: [])
        }
    }
}
