//  SFZLoader.swift
//  SoundFont Note Player（SFZNotePlayerPlugin）のバンクを、置き場から読んでカーネルへ送る。
//
//  **読み・コンパイル・パックは上流の js/sfz（Resources/SFZ/effetune-sfz.js）を JavaScriptCore で動かす**
//  （DSP/SFZScript/ETSFZScriptService）。2.16.0 まで Swift に写していた SFZParser・SFZAsset などは使わない。
//  ここは
//    - 音のファイルを開く（AVAudioFile。JS の decode の口）
//    - 置き場（Application Support/SFZ。バックアップから外す。一覧は index.json を ETSFZLibraryBackend が読む）
//    - 幾何（レート・処理チャンネル・maxFrames）を決め、見積りと begin に**同じ値**を渡す
//    - PCM を staging へ直に書いて送る（AssetUpload.send の fill。JS にも Swift の配列にも PCM を二重に持たない）
//    - commit の後で資産の状態を読み、ERROR を段の状態（.failed）にする
//    - SoundFont（v9。PCM は payload に無い）は、commit の直後（音のスレッドを締め出している間）に流しを繋ぎ
//      （ETSFZStream.attach）、ページを作る供給（ETSFZPageSource）を回す。供給が失敗したら資産を外して .failed にする
//    - SoundFont の Preset の一覧を段ごとに持つ（カードの Preset の欄。sp0 は読み込みのたびに一覧へ照らして直す）
//    - 段ごとの状態（読み込み中・入っている・見つからない・失敗）をカードへ知らせる
//  を持つ。IR Reverb の ETIRLoader と同じ位置づけ。
//
//  素材の鍵は段の `irId`（IR と同じ入れ物。保存の綴りは型で決まる: ETChainText.assetKey）に載せる。
//  鎖が戻った時点で EffeTuneDSP.reloadAssets が reloadAsset を呼び、ここへ来る。
//  処理幅（Ch）が変わったときも読み直す（見積りと begin の processingChannels が幅で決まるため）。
//
//  **上限は 256 MiB で固定**（上流の既定。設定は持たない）。バンクの入れ物・読んだ PCM・送る資産・カーネルの写しが
//  同時に居るので、取り込み中のピークは上限の 3〜4 倍になりうる。

import AVFoundation
import Combine
import Foundation
import os

// MARK: - 音を開く

enum ETSFZAudio {

    /// 音のファイル（WAV・AIFF・FLAC など）のバイト列を、一時ファイルに書いて AVAudioFile で開き、float の面へ読む。
    /// 上流の decode の口（ETSFZScriptDecode）。拡張子は中身から決める（ETSFZAudioSniff）。
    static func decode(_ data: Data) throws -> ETSFZScriptPCM {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("sfz-\(UUID().uuidString)")
            .appendingPathExtension(ETSFZAudioSniff.fileExtension(for: data))
        do { try data.write(to: temporary) } catch { throw ETSFZError.prepare("An SFZ sample could not be read.") }
        defer { try? FileManager.default.removeItem(at: temporary) }
        return try decode(url: temporary)
    }

    /// 開く前に長さを見て、上限（256 MiB）を越えるなら読まずに too-large にする。
    static func decode(url: URL) throws -> ETSFZScriptPCM {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch {
            throw ETSFZError.prepare("An SFZ sample could not be opened.")
        }
        let format = file.processingFormat
        let channelCount = Int(format.channelCount)
        let frames = Int(file.length)
        guard (1...2).contains(channelCount), frames > 0, format.sampleRate > 0 else {
            throw ETSFZError.prepare("SFZ samples must contain mono or stereo audio.")
        }
        if frames * channelCount * 4 > ETSFZ.defaultMaxBytes {
            throw ETSFZError.tooLarge("The SFZ samples are too large to load.")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            throw ETSFZError.prepare("An SFZ sample could not be read.")
        }
        do { try file.read(into: buffer) } catch { throw ETSFZError.prepare("An SFZ sample could not be read.") }
        let read = Int(buffer.frameLength)
        guard read > 0, let data = buffer.floatChannelData else {
            throw ETSFZError.prepare("An SFZ sample could not be read.")
        }
        let planes = (0..<channelCount).map { channel -> ETSFZPlane in
            let plane = ETSFZPlane(count: read)
            plane.pointer.update(from: data[channel], count: read)
            // 非有限は 0 にする（プールを書くとき、1 つでも混ざると上流と同じ文で止まる）。
            for index in 0..<read where !plane.pointer[index].isFinite { plane.pointer[index] = 0 }
            return plane
        }
        return ETSFZScriptPCM(channels: planes, sampleRate: Int(format.sampleRate.rounded()))
    }
}

// MARK: - 置き場

/// バンクの置き場。画面が観測する一覧を持つ。ファイルの出し入れは ETSFZLibraryBackend、取り込みと読み直しは
/// JS（ETSFZScriptService）。index.json は JS が書く（知らない鍵は backend が落とさない）。
@MainActor
final class SFZLibrary: ObservableObject {

    static let shared = SFZLibrary()

    @Published private(set) var entries: [ETSFZLibraryEntry] = []

    nonisolated let backend: ETSFZLibraryBackend
    /// JS の入口。文脈は使うときに建て、遊んでいれば捨てる。
    nonisolated let service: ETSFZScriptService
    /// 置き場を JS の外から書き換えた後、JS が持つ一覧を開き直す仕事。次の JS の仕事の前に待つ。
    private var resetTask: Task<Void, Never>?
    /// SoundFont Library の取り込みが走っている間は true。走っている間の削除は断る
    /// （JS が持つ一覧が古いまま、消したバンクを index.json へ書き戻さないため）。
    var isImporting = false

    /// Application Support/SFZ。Documents に置くとバックアップに入る（バンクは大きい）。
    nonisolated static var defaultRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SFZ", isDirectory: true)
    }

    init(root: URL = SFZLibrary.defaultRoot) {
        let backend = ETSFZLibraryBackend(root: root)
        self.backend = backend
        service = ETSFZScriptService(backend: ETSFZScriptBackendAdapter(backend: backend),
                                     decode: { try ETSFZAudio.decode($0) },
                                     estimate: { control, payloadBytes, geometry, formatTag in
                                         try ETSamplePlayerPreparation.scriptEstimate(
                                             control: control, payloadBytes: payloadBytes, geometry: geometry,
                                             formatTag: formatTag)
                                     },
                                     maxBytes: ETSFZ.defaultMaxBytes)
        Self.prepareFolder(root)
        reload()
    }

    /// 置き場のフォルダを作り、バックアップから外す。
    private static func prepareFolder(_ root: URL) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var folder = root
        try? folder.setResourceValues(excluded)
    }

    func reload() {
        let index = (try? backend.readIndex()) ?? ETSFZLibraryIndex()
        entries = index.entries.map {
            ETSFZLibraryEntry(id: $0.id, name: $0.name, regionCount: $0.regionCount, size: $0.size,
                              fileCount: $0.fileCount, importedAt: $0.importedAt, format: $0.format)
        }
    }

    /// 取り込んだバンクを全部消す（ETFactoryReset）。
    func eraseAll() {
        try? FileManager.default.removeItem(at: backend.root)
        Self.prepareFolder(backend.root)
        reload()
        invalidateScript()
    }

    func entry(id: String) -> ETSFZLibraryEntry? { entries.first { $0.id == id } }

    /// 置き場から消す（一覧と入れ物）。画面の削除ボタンが同期で呼ぶので、JS を通さず backend で書く。
    /// JS が持つ一覧は次の仕事の前に開き直させる（消し忘れた一覧を JS が index.json へ書き戻さないため）。
    func remove(id: String) throws {
        guard ETSFZ.isValidID(id) else { throw ETSFZError(code: .storage, message: "Invalid SFZ bank identifier.") }
        guard !isImporting else { throw ETSFZError(code: .storage, message: "The SFZ library is busy importing.") }
        do {
            try backend.writeIndex(try backend.readIndex().removing(id: id))
            try backend.remove("\(id).sfzbank")
        } catch {
            throw ETSFZScriptBackendAdapter.map(error)
        }
        reload()
        invalidateScript()
    }

    /// JS の仕事の入口。置き場を外から書き換えていたら、先に JS の一覧を開き直す。
    func scriptService() async -> ETSFZScriptService {
        if let resetTask { await resetTask.value }
        return service
    }

    private func invalidateScript() {
        let previous = resetTask
        let service = service
        resetTask = Task {
            await previous?.value
            try? await service.reset()
        }
    }
}

// MARK: - 読み込み

/// 段ごとの状態。カードが読む。
enum SFZNodeState: Equatable {
    /// 素材が無い（None）か、まだ何も始めていない。
    case idle
    case loading
    case ready(name: String, regions: Int)
    /// 鍵が指すバンクが置き場に無い（別の端末で作った鎖など）。カードは赤い状態行と選択欄の Missing SoundFont で知らせる。
    case missing
    case failed(ETSFZErrorCode)
}

/// 段ごとの、いま回っている流し込みの供給（SoundFont）。
private struct SFZActiveStream {
    let source: ETSFZPageSource
    let engine: UInt32
    let instance: UInt32
}

@MainActor
final class SFZLoader: ObservableObject {

    static let shared = SFZLoader()

    private let log = Logger(subsystem: "ai.nemut.effetune", category: "sfz")

    @Published private(set) var states: [UUID: SFZNodeState] = [:]
    /// 取り込みで出た知らせ（loop 点の補正・飛ばした領域など）。カードが一度だけ出して空にする。
    @Published var notice: String?
    /// SoundFont Library の取り込みの進み（done / total）。走っていなければ nil。
    @Published private(set) var libraryImport: (done: Int, total: Int)?
    /// 段ごとの、いま走っている読み込みの番号。古い読み込みの結果は捨てる。
    private var generation: [UUID: Int] = [:]
    private var counter = 0
    /// 段ごとの、いま走っている JS の仕事の取り消しの旗。
    private var tokens: [UUID: ETSFZCancelToken] = [:]
    /// commit の後で資産の状態を見張る仕事（段ごとに 1 つ）。
    private var watchers: [UUID: Task<Void, Never>] = [:]
    /// 段ごとの流し込みの供給（SoundFont のとき）。資産を替える・外すとき止める。
    private var streams: [UUID: SFZActiveStream] = [:]
    /// 段ごとの、読み込んだ SoundFont の Preset の一覧（カードの Preset の欄）。SFZ のバンクや、読み込み中・失敗の段には無い。
    @Published private(set) var presetLists: [UUID: [ETSFZPreset]] = [:]
    /// 直前に読んだバンク（小さいときだけ）。出力先の切り替えなどで instance が作り直されるたびに
    /// 読み直さないため。256MiB 級のバンクは持たない（メモリを食う）。
    private var recent = ETSFZPreparedCache()
    /// 同梱の JS の sha（覚えの鍵）。
    private lazy var bundleSHA: String = {
        guard let sources = try? ETSFZScriptSources.bundled() else { return "unknown" }
        return ETSFZBundleIdentity.sha(ofBundleAt: sources.bundle)
    }()

    private let maxBytes = ETSFZ.defaultMaxBytes
    /// commit の後、資産の状態を細かく（0.1 秒ごと）見る長さ。音が流れないと preparing のまま進まないので、
    /// その後は 1 秒ごとに見る（止まっている間に commit した資産の ERROR も、音が流れた後に拾う）。
    private static let fastWatchSeconds: TimeInterval = 3

    // MARK: 状態

    func state(of id: UUID) -> SFZNodeState { states[id] ?? .idle }

    private func set(_ state: SFZNodeState, for id: UUID) {
        if states[id] != state { states[id] = state }
        // Preset の一覧は読み込めた段のものだけ（読み込み中は前の一覧を残す。欄が点滅しないように）。
        switch state {
        case .ready, .loading: break
        default: if presetLists[id] != nil { presetLists[id] = nil }
        }
    }

    /// 段の Preset の一覧。SoundFont でなければ空（欄を出さない）。
    func presets(of id: UUID) -> [ETSFZPreset] { presetLists[id] ?? [] }

    /// 新しい読み込みを始める。**前の読み込みの結果は捨て、JS の仕事は取り消し、見張りも止める。**
    private func nextGeneration(_ id: UUID) -> Int {
        counter += 1
        generation[id] = counter
        tokens[id]?.cancel()
        tokens[id] = nil
        watchers[id]?.cancel()
        watchers[id] = nil
        return counter
    }

    private func current(_ id: UUID, _ number: Int) -> Bool { generation[id] == number }

    private func cacheKey(_ bankID: String) -> ETSFZPreparedCache.Key {
        ETSFZPreparedCache.Key(bankID: bankID, bundleSHA: bundleSHA)
    }

    // MARK: 幾何

    /// 見積りと begin が同じ値を見る幾何。**処理チャンネルは BeginInfo.processingChannels と同じ値**
    /// （commitSfzEffects が一致を要る）。engine が回さない Ch（幅 0）では作れず、投げる。
    private static func geometry(of node: EffeTuneDSP.Node, dsp: EffeTuneDSP) throws -> ETSFZPreparationRules.Geometry {
        try ETSFZPreparationRules.Geometry(
            sampleRate: dsp.sampleRate,
            processingChannels: EffeTuneDSP.routedChannels(of: node),
            maxFrames: Int(dsp.maximumFrames),
            minimumPhysicalBpm: 0,
            playerKind: try ETSFZPreparationRules.PlayerKind(typeName: node.spec.type))
    }

    private static func scriptGeometry(_ value: ETSFZPreparationRules.Geometry) -> ETSFZGeometry {
        ETSFZGeometry(sampleRate: value.sampleRate, processingChannels: value.processingChannels,
                      maxFrames: value.maxFrames, minimumPhysicalBpm: value.minimumPhysicalBpm,
                      playerKind: Int(value.playerKind.rawValue))
    }

    // MARK: 入れ直し

    /// 段が持つ鍵のバンクを置き場から読んで送る。鎖が戻ったとき・instance が作り直されたとき・処理幅が変わったときに呼ぶ。
    /// 鍵が空なら素通しに戻す。始められたら true。
    @discardableResult
    func reload(slot: Int, dsp: EffeTuneDSP) -> Bool {
        guard let node = dsp.node(at: slot), node.spec.type == ETChainText.sfzType else { return false }
        let id = node.id
        guard !node.irId.isEmpty, ETSFZ.isValidID(node.irId) else {
            _ = nextGeneration(id)
            set(.idle, for: id)
            return false
        }
        return start(nodeID: id, bankID: node.irId, dsp: dsp, announce: false)
    }

    @discardableResult
    private func start(nodeID: UUID, bankID: String, dsp: EffeTuneDSP, announce: Bool) -> Bool {
        let number = nextGeneration(nodeID)
        pruneRemovedNodes(dsp: dsp)
        guard SFZLibrary.shared.entry(id: bankID) != nil else {
            set(.missing, for: nodeID)
            return false
        }
        guard let slot = dsp.slot(of: nodeID), let node = dsp.node(at: slot) else {
            set(.idle, for: nodeID)
            return false
        }
        let geometry: ETSFZPreparationRules.Geometry
        do { geometry = try Self.geometry(of: node, dsp: dsp) } catch {
            // engine が回さない Ch（幅 0）。送る先が無い。幅が戻れば reload が呼ばれる。
            set(.idle, for: nodeID)
            return false
        }
        set(.loading, for: nodeID)
        if let cached = recent.get(cacheKey(bankID)) {
            finish(nodeID: nodeID, bankID: bankID, number: number, dsp: dsp, announce: announce, result: .success(cached))
            return true
        }
        let token = ETSFZCancelToken()
        tokens[nodeID] = token
        let scripted = Self.scriptGeometry(geometry)
        Task {
            let service = await SFZLibrary.shared.scriptService()
            let result: Result<ETSFZScriptPrepared?, Error>
            do { result = .success(try await service.prepare(id: bankID, geometry: scripted, cancel: token)) } catch {
                result = .failure(error)
            }
            self.finish(nodeID: nodeID, bankID: bankID, number: number, dsp: EffeTuneDSP.shared, announce: announce,
                        result: result)
        }
        return true
    }

    /// 読めた資産を送る。UI のスレッドで。段がもう別の鍵になっていたら捨てる。
    private func finish(nodeID: UUID, bankID: String, number: Int, dsp: EffeTuneDSP, announce: Bool,
                        result: Result<ETSFZScriptPrepared?, Error>) {
        guard current(nodeID, number) else { return }
        tokens[nodeID] = nil
        switch result {
        case .failure(let error):
            let code = (error as? ETSFZError)?.code ?? .prepare
            if code == .cancelled {
                set(.idle, for: nodeID)
                return
            }
            log.error("SFZ 読み込み失敗 \(String(describing: error), privacy: .public)")
            set(.failed(code), for: nodeID)
        case .success(nil):
            // 置き場の一覧にはあるが入れ物が無い（上流の prepare は null を返す）。
            set(.missing, for: nodeID)
        case .success(let prepared?):
            guard let slot = dsp.slot(of: nodeID), let node = dsp.node(at: slot), node.irId == bankID else {
                // 段が消えたか、鍵が呼び手に外された。読み込み中のまま残さない。
                set(.idle, for: nodeID)
                return
            }
            do {
                try send(prepared, to: node, dsp: dsp, number: number)
                recent.store(prepared, for: cacheKey(bankID))
                presetLists[nodeID] = prepared.soundFont.map(\.presets)
                reconcilePreset(prepared, nodeID: nodeID, dsp: dsp)
                set(.ready(name: prepared.name, regions: prepared.regionCount), for: nodeID)
                if announce, let text = ETSFZMessages.warning(prepared.warnings.map(\.code)) { notice = text }
                watch(nodeID: nodeID, number: number, instance: node.instance, dsp: dsp)
            } catch {
                log.error("SFZ 送り込み失敗 \(String(describing: error), privacy: .public)")
                let code: ETSFZErrorCode
                if let known = error as? ETSFZError {
                    code = known.code
                } else if case ETAssetUploadError.tooLarge = error {
                    code = .tooLarge
                } else {
                    code = .prepare
                }
                set(.failed(code), for: nodeID)
            }
        }
    }

    /// 資産をカーネルへ。begin の引数は SFZ 専用（channels 1・frames は payload の頭の値・topology 0・head 128・
    /// rate_divider 1・processing_channels は幾何と同じ）。**footprint は send のたびにエンジンへ聞き直す**
    /// （payload + 追加分。出力先・レート・幅が変わると変わる）。
    /// SoundFont（v9）は PCM が payload に無い。commit の直後（音のスレッドを締め出している間）に流しを繋ぎ（configure）、
    /// 送れたらページを作る供給を回す。SFZ（v6・v7 の常駐）は流しを持たないので、前の供給があれば止める。
    private func send(_ prepared: ETSFZScriptPrepared, to node: EffeTuneDSP.Node, dsp: EffeTuneDSP, number: Int) throws {
        // この版が扱えない音源・欠けのある音源は上流と同じく断る。標本の表が作れない流し込みの資産も断る
        // （流しを繋げないと、ページが来ず音が欠け続ける）。
        try ETSFZPreparedCheck.requireComplete(unsupportedOpcodes: prepared.unsupportedOpcodes,
                                               unsupportedRuntime: prepared.unsupportedRuntime,
                                               incomplete: prepared.incomplete)
        try ETSFZPreparedCheck.requireStreamSources(tableVersion: prepared.tableVersion, hasSources: prepared.soundFont != nil)
        let geometry = try Self.geometry(of: node, dsp: dsp)
        let control = [UInt8](prepared.control)
        let formatTag = UInt32(clamping: prepared.formatTag)
        let footprint = try ETSamplePlayerPreparation.footprint(
            control: control, payloadBytes: prepared.payloadByteCount, geometry: geometry,
            maxBytes: maxBytes, formatTag: formatTag)
        let info = AssetUpload.BeginInfo(channels: 1, frames: nil, topology: .unspecified,
                                         headBlock: 128, rateDivider: 1, pathCount: 0, inputCount: 0,
                                         processingChannels: UInt32(geometry.processingChannels),
                                         footprintBytes: footprint)
        // 流し込み（SoundFont）の用意。標本の表は置き場の入れ物から作る（SF2 はその中に入っている）。
        var attached: (generation: UInt64, slot: UInt32)?
        var sources: [ETSFZSampleSource] = []
        var connect: (() throws -> Void)?
        if let soundFont = prepared.soundFont {
            guard prepared.tableVersion == 9,
                  let bank = try? SFZLibrary.shared.backend.readSfzBankFile("\(prepared.id).sfzbank")
            else { throw ETSFZError.prepare(ETSFZStream.preparationFailedMessage) }
            sources = try soundFont.sources(bank: bank.url, bankBytes: bank.size)
            let generation = ETSFZStream.nextGeneration()
            let engine = dsp.engine, instance = node.instance, rate = dsp.sampleRate
            let forecast = geometry.playerKind == .note
            connect = {
                let slot = try ETSFZStream.attach(engine: engine, instance: instance, generation: generation,
                                                  sampleRate: rate, forecast: forecast)
                attached = (generation, slot)
            }
        } else {
            // 流しを持たない資産（SFZ）に替わるときは、前の流しの畳みも commit の直後（締め出している間）に済ませる。
            let engine = dsp.engine, instance = node.instance
            connect = { ETSFZStream.detach(engine: engine, instance: instance) }
        }
        try AssetUpload.send(engine: dsp.engine, instance: node.instance, slot: 0,
                             header: Array(control.prefix(ETSFZPoolFill.outerHeaderBytes)),
                             byteCount: prepared.payloadByteCount, info: info, formatTag: formatTag,
                             capacity: ETSFZ.maxSupportedBytes, afterCommit: connect) { staging in
            try ETSFZPayloadFill.fill(staging: staging, control: prepared.control, pool: prepared.poolEntries)
        }
        replaceStream(for: node.id, detach: false, with: attached.map { attachment -> SFZActiveStream in
            let source = ETSFZPageSource(slot: attachment.slot, generation: attachment.generation, samples: sources)
            let id = node.id, engine = dsp.engine, instance = node.instance
            source.onFailure { [weak self] in
                Task { @MainActor in self?.streamFailed(nodeID: id, number: number, engine: engine, instance: instance) }
            }
            source.start()
            return SFZActiveStream(source: source, engine: engine, instance: instance)
        }, engine: dsp.engine, instance: node.instance)
        // 送ると遅れが変わる。鎖を出し直して合わせる。
        dsp.republish()
    }

    /// 段が消えた供給と Preset の一覧を片づける。段の削除を知らせる口が無いので、次の読み込みの頭で見る
    /// （instance は ETPipeline_DestroyInstances が流しごと畳むので、止めるのは供給の thread だけ）。
    private func pruneRemovedNodes(dsp: EffeTuneDSP) {
        for id in Array(streams.keys) where dsp.slot(of: id) == nil {
            if let removed = streams.removeValue(forKey: id) {
                DispatchQueue.global(qos: .utility).async { removed.source.stop() }
            }
        }
        for id in Array(presetLists.keys) where dsp.slot(of: id) == nil { presetLists[id] = nil }
    }

    /// 段の供給を差し替える。前の供給は止める（待ちが最大 1 秒あるので UI のスレッドでは止めない）。
    /// 流しを持たない資産（SFZ）に替わるときは、engine 側の流しも畳む。
    /// detach: false は、流しの畳みを呼び手が commit の直後に済ませたとき（send）。
    private func replaceStream(for id: UUID, detach: Bool = true, with next: SFZActiveStream?, engine: UInt32, instance: UInt32) {
        let previous = streams.removeValue(forKey: id)
        if let next {
            streams[id] = next
        } else if detach {
            ETSFZStream.detach(engine: engine, instance: instance)
        }
        guard let previous else { return }
        DispatchQueue.global(qos: .utility).async { previous.source.stop() }
    }

    /// 資産を外し、流しと供給も畳む（鍵を外した・段の素材を戻した・供給が失敗した）。
    private func clearAsset(for id: UUID, engine: UInt32, instance: UInt32) {
        AssetUpload.clear(engine: engine, instance: instance)
        replaceStream(for: id, with: nil, engine: engine, instance: instance)
    }

    /// 供給が標本を読めなかった（置き場のファイルが消えた・差し替わった）。上流の sfzStreamFailed と同じく資産を外して
    /// 赤い状態行に出す。読み直すまでそのページは欠け続けるので、鳴らし続けない。
    private func streamFailed(nodeID: UUID, number: Int, engine: UInt32, instance: UInt32) {
        guard current(nodeID, number), streams[nodeID] != nil else { return }
        log.error("SFZ 流し込みが失敗（標本を読めない）")
        watchers[nodeID]?.cancel()
        watchers[nodeID] = nil
        clearAsset(for: nodeID, engine: engine, instance: instance)
        set(.failed(.sampleRead), for: nodeID)
        EffeTuneDSP.shared.republish(reason: "SFZ の流し込みが失敗")
    }

    /// 読み込んだ後の Preset（sp0）を、音源の Preset の一覧に照らして直す（上流の validatePreparedSfzBank）。
    /// 一覧に無い値（別の SoundFont の番号・SFZ のバンク）は -1（音源の先頭）へ戻す。
    private func reconcilePreset(_ prepared: ETSFZScriptPrepared, nodeID: UUID, dsp: EffeTuneDSP) {
        guard let slot = dsp.slot(of: nodeID), let node = dsp.node(at: slot),
              let preset = node.spec.params.first(where: { $0.key == "sp0" }),
              node.values.indices.contains(preset.offset) else { return }
        let current = node.values[preset.offset]
        let next = ETSFZPresetMenu.validatedSelection(current: current, presets: prepared.soundFont?.presets ?? [])
        if next != current { dsp.setValue(next, at: slot, offset: preset.offset) }
    }

    /// commit の後、資産の状態を読む。ERROR なら段の状態を .failed にする。ACTIVE か、資産が外れたら止める。
    /// 音が流れないと preparing のまま進まないので、fastWatchSeconds の後は 1 秒ごとに見る
    /// （次の読み込み・段の削除・素材を外すと nextGeneration が止める）。
    private func watch(nodeID: UUID, number: Int, instance: UInt32, dsp: EffeTuneDSP) {
        watchers[nodeID]?.cancel()
        watchers[nodeID] = Task { [weak self] in
            let fastUntil = Date().addingTimeInterval(Self.fastWatchSeconds)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Date() < fastUntil ? 100_000_000 : 1_000_000_000)
                guard !Task.isCancelled, let self, self.current(nodeID, number) else { return }
                switch ETSFZAssetWatch.verdict(AssetUpload.status(engine: dsp.engine, instance: instance)) {
                case .waiting:
                    continue
                case .active, .gone:
                    return
                case .failed(let code):
                    self.log.error("SFZ 資産が ERROR（\(code.rawValue, privacy: .public)）")
                    self.set(.failed(code), for: nodeID)
                    return
                }
            }
        }
    }

    // MARK: 取り込み

    /// 選んだフォルダの中の全ファイル（深さ 32・SFZ は 1 万本まで）。道は選んだフォルダからの相対。
    /// 2.14.0 から上流は数えるのを SFZ だけにした（音のファイルが多いバンクを断らない）。
    /// 道の正規化と SFZ・SoundFont の選別は JS がやる（listInstruments）。
    nonisolated static func enumerate(folder: URL) throws -> [ETSFZScriptFile] {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        var out: [ETSFZScriptFile] = []
        var instruments = 0
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else {
            throw ETSFZError.prepare("The SFZ folder could not be read.")
        }
        let base = folder.standardizedFileURL.pathComponents
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let parts = url.standardizedFileURL.pathComponents
            let relative = Array(parts.dropFirst(base.count))
            if relative.count > 32 { throw ETSFZError.prepare("The SFZ folder is nested too deeply.") }
            if values?.isDirectory == true { continue }
            let path = relative.joined(separator: "/")
            if path.lowercased().hasSuffix(".sfz") {
                instruments += 1
                if instruments > 10000 { throw ETSFZError.prepare("The SFZ folder contains too many instruments.") }
            }
            let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            out.append(ETSFZScriptFile(path: path, url: url, size: values?.fileSize ?? 0,
                                       lastModified: (modified * 1000).rounded(.down)))
        }
        return out
    }

    /// SoundFont のファイル 1 本の入り口（道はファイル名だけ。選んだフォルダが無いので、親は付けない）。
    nonisolated static func describe(file url: URL) throws -> [ETSFZScriptFile] {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let values = try? url.resourceValues(forKeys: keys), let size = values.fileSize else {
            throw ETSFZError.prepare("The SFZ folder could not be read.")
        }
        let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        return [ETSFZScriptFile(path: url.lastPathComponent, url: url, size: size, lastModified: (modified * 1000).rounded(.down))]
    }

    /// 選んだもの（フォルダか、SoundFont のファイル 1 本）を置き場に入れる。ファイル選択（.fileImporter）の戻りをそのまま渡す。
    func importToLibrary(picked url: URL) async -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        return isDirectory ? await importToLibrary(folder: url) : await importToLibrary(file: url)
    }

    /// 選んだフォルダの SFZ・SoundFont を全部、置き場に入れる（SoundFont Library の取り込み。段には入れない）。
    func importToLibrary(folder: URL) async -> String {
        await importToLibrary(scoped: folder) { try SFZLoader.enumerate(folder: folder) }
    }

    /// 選んだ SoundFont のファイル 1 本を、置き場に入れる。
    func importToLibrary(file: URL) async -> String {
        await importToLibrary(scoped: file) { try SFZLoader.describe(file: file) }
    }

    /// 上流の browser.js の importFiles と同じく 1 つずつ順に取り込み、失敗したものは数えて先へ進む。
    /// 戻りは結果の 1 文（上流の irLibrary.status.importResult に寄せた形）。
    private func importToLibrary(scoped root: URL, listing: @escaping @Sendable () throws -> [ETSFZScriptFile]) async -> String {
        let library = SFZLibrary.shared
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        var service = await library.scriptService()
        let files: [ETSFZScriptFile]
        let paths: [String]
        do {
            files = try await Task.detached(priority: .userInitiated) { try listing() }.value
            paths = try await service.listInstruments(in: files)
        } catch {
            return ETSFZMessages.error(((error as? ETSFZError)?.code ?? .prepare).rawValue)
        }
        guard !paths.isEmpty else { return ETSFZMessages.error(ETSFZErrorCode.noRegions.rawValue) }
        libraryImport = (0, paths.count)
        library.isImporting = true
        defer {
            libraryImport = nil
            library.isImporting = false
        }
        var imported = 0, failed = 0, tooLarge = 0
        for (number, path) in paths.enumerated() {
            do {
                // 1 件ごとに入口を取り直す（外から置き場を書き換えていたら、先に JS の一覧を開き直させる）。
                service = await library.scriptService()
                _ = try await service.importFolder(files: files, selectedPath: path)
                imported += 1
                library.reload()
            } catch {
                log.error("SoundFont Library 取り込み失敗 \(path, privacy: .public) \(String(describing: error), privacy: .public)")
                failed += 1
                if (error as? ETSFZError)?.code == .tooLarge { tooLarge += 1 }
            }
            libraryImport = (number + 1, paths.count)
        }
        var parts: [String] = []
        if imported > 0 { parts.append(imported == 1 ? "1 imported" : "\(imported) imported") }
        if failed > 0 { parts.append("\(failed) could not be imported") }
        var text = parts.joined(separator: ", ") + "."
        if tooLarge > 0 { text += " " + ETSFZMessages.error(ETSFZErrorCode.tooLarge.rawValue) }
        return text
    }

    /// 段の素材を呼び手が外した（Reset など）。走っている読み込みの結果を捨て、状態を None に戻す。
    /// 呼ばないと、読み込み中の Reset で状態が .loading のまま残り、失敗の赤い文も消えない。
    func forget(nodeID: UUID) {
        _ = nextGeneration(nodeID)
        set(.idle, for: nodeID)
        // 呼び手（Reset）が資産を外している。流しの供給も畳む。
        if let active = streams[nodeID] { replaceStream(for: nodeID, with: nil, engine: active.engine, instance: active.instance) }
    }

    /// 段の鍵を替える。**鍵が変わるときだけ Preset（sp0）を -1（既定）へ戻す**（上流は sf を変えると sp0 も戻す。
    /// 前のバンクの番号が別のバンクの別の音色を指さないため）。同じ鍵の選び直しでは戻さない。
    private func select(bankID: String, at slot: Int, nodeID: UUID, dsp: EffeTuneDSP) {
        let changed = dsp.node(at: slot)?.irId != bankID
        dsp.setIRId(bankID, at: slot)
        guard changed, let node = dsp.node(at: slot),
              let preset = node.spec.params.first(where: { $0.key == "sp0" }),
              node.values.indices.contains(preset.offset), node.values[preset.offset] != -1 else { return }
        dsp.setValue(-1, at: slot, offset: preset.offset)
    }

    /// 置き場にあるバンクを選んだ（選択欄から）。
    func choose(bankID: String, for nodeID: UUID, dsp: EffeTuneDSP) {
        guard let slot = dsp.slot(of: nodeID) else { return }
        // 別のバンクの Preset の一覧は出さない（読み込めたら入れ直す）。
        if dsp.node(at: slot)?.irId != bankID { presetLists[nodeID] = nil }
        select(bankID: bankID, at: slot, nodeID: nodeID, dsp: dsp)
        if bankID.isEmpty {
            _ = nextGeneration(nodeID)
            set(.idle, for: nodeID)
            clearAsset(for: nodeID, engine: dsp.engine, instance: dsp.node(at: slot)?.instance ?? 0)
            dsp.republish(reason: "SFZ を外した")
            return
        }
        start(nodeID: nodeID, bankID: bankID, dsp: dsp, announce: true)
    }

    /// 置き場から消し、段を None に戻す。
    func remove(bankID: String, for nodeID: UUID, dsp: EffeTuneDSP) {
        do {
            try SFZLibrary.shared.remove(id: bankID)
        } catch {
            set(.failed((error as? ETSFZError)?.code ?? .storage), for: nodeID)
            return
        }
        recent.remove(bankID: bankID)
        choose(bankID: "", for: nodeID, dsp: dsp)
    }
}
