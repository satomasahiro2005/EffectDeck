//  SFZLoader.swift
//  SFZ Note Player（SFZNotePlayerPlugin）のバンクを、置き場から読んでカーネルへ送る。
//
//  取り込みと読み直しの計算は Foundation だけの DSP/SFZLibraryFiles.swift（ETSFZService）。ここは
//    - 音のファイルを開く（AVAudioFile。decode・inspect）
//    - 置き場（Application Support/SFZ。バックアップから外す）
//    - 重い仕事を別のスレッドで走らせ、送るのだけを UI のスレッドで行う（AssetUpload.send は @MainActor）
//    - 段ごとの状態（読み込み中・入っている・見つからない・失敗）をカードへ知らせる
//  を持つ。IR Reverb の ETIRLoader と同じ位置づけ。
//
//  素材の鍵は段の `irId`（IR と同じ入れ物。保存の綴りは型で決まる: ETChainText.assetKey）に載せる。
//  鎖が戻った時点で EffeTuneDSP.reloadAssets が reloadAsset を呼び、ここへ来る。
//
//  **上限は 256 MiB で固定**（上流の既定。設定は持たない）。バンクの入れ物・読んだ PCM・送る資産・カーネルの写しが
//  同時に居るので、取り込み中のピークは上限の 3〜4 倍になりうる。

import AVFoundation
import Combine
import Foundation
import os

// MARK: - 音を開く

enum ETSFZAudio {

    /// バイト列を一時ファイルに書いて AVAudioFile で開き、float の面へ読む。
    /// 開く前に長さを見て、残りの予算を越えるなら読まずに too-large にする。
    static func decode(_ data: Data, ext: String, budget: Int) throws -> ETSFZPCM {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("sfz-\(UUID().uuidString)")
            .appendingPathExtension(ext.isEmpty ? "wav" : ext)
        do { try data.write(to: temporary) } catch { throw ETSFZError.prepare("An SFZ sample could not be read.") }
        defer { try? FileManager.default.removeItem(at: temporary) }
        return try decode(url: temporary, budget: budget)
    }

    static func decode(url: URL, budget: Int) throws -> ETSFZPCM {
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
        if frames * channelCount * 4 > budget { throw ETSFZError.tooLarge("The SFZ samples are too large to load.") }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            throw ETSFZError.prepare("An SFZ sample could not be read.")
        }
        do { try file.read(into: buffer) } catch { throw ETSFZError.prepare("An SFZ sample could not be read.") }
        let read = Int(buffer.frameLength)
        guard read > 0, let data = buffer.floatChannelData else {
            throw ETSFZError.prepare("An SFZ sample could not be read.")
        }
        // 非有限は 0 にする（資産に混ざると組めない）。
        let channels = (0..<channelCount).map {
            ETIRDecode.sanitized(UnsafeBufferPointer(start: data[$0], count: read))
        }
        return ETSFZPCM(channels: channels, sampleRate: Int(format.sampleRate.rounded()))
    }

    /// 開かずに形だけ（幅とフレーム数）。開けなければ nil。
    static func inspect(_ url: URL) -> (channels: Int, frames: Int)? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        return (Int(file.processingFormat.channelCount), Int(file.length))
    }
}

// MARK: - 置き場

/// バンクの置き場。画面が観測する一覧を持つ。ファイルの出し入れは ETSFZLibraryFiles。
@MainActor
final class SFZLibrary: ObservableObject {

    static let shared = SFZLibrary()

    @Published private(set) var entries: [ETSFZLibraryEntry] = []

    nonisolated let files: ETSFZLibraryFiles

    /// Application Support/SFZ。Documents に置くとバックアップに入る（バンクは大きい）。
    nonisolated static var defaultRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SFZ", isDirectory: true)
    }

    init(root: URL = SFZLibrary.defaultRoot) {
        files = ETSFZLibraryFiles(root: root)
        try? files.createFolder()
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var folder = root
        try? folder.setResourceValues(excluded)
        reload()
    }

    func reload() {
        entries = (try? files.readIndex()) ?? []
    }

    func entry(id: String) -> ETSFZLibraryEntry? { entries.first { $0.id == id } }

    /// 書き終えたバンクを一覧に足す（バンクの入れ物は呼び手が先に書いておく）。
    func add(_ entry: ETSFZLibraryEntry) throws {
        let next = ETSFZLibraryFiles.sorted(entries.filter { $0.id != entry.id } + [entry])
        try files.writeIndex(next)
        entries = next
    }

    func remove(id: String) throws {
        let next = entries.filter { $0.id != id }
        try files.writeIndex(next)
        entries = next
        try files.removeBank(id)
    }
}

// MARK: - 読み込み

/// 段ごとの状態。カードが読む。
enum SFZNodeState: Equatable {
    /// 素材が無い（None）か、まだ何も始めていない。
    case idle
    case loading
    case ready(name: String, regions: Int)
    /// 鍵が指すバンクが置き場に無い（別の端末で作った鎖など）。上流と同じく文は出さず、選択欄に Missing SFZ と出る。
    case missing
    case failed(ETSFZErrorCode)
}

@MainActor
final class SFZLoader: ObservableObject {

    static let shared = SFZLoader()

    private let log = Logger(subsystem: "ai.nemut.effetune", category: "sfz")

    @Published private(set) var states: [UUID: SFZNodeState] = [:]
    /// 取り込みで出た知らせ（loop 点の補正・飛ばした領域など）。カードが一度だけ出して空にする。
    @Published var notice: String?
    /// 段ごとの、いま走っている読み込みの番号。古い読み込みの結果は捨てる。
    private var generation: [UUID: Int] = [:]
    private var counter = 0
    /// 直前に送った資産（小さいときだけ）。出力先の切り替えなどで instance が作り直されるたびに
    /// 読み直さないため。256MiB 級のバンクは持たない（メモリを食う）。
    private var recent: (id: String, prepared: ETSFZPrepared)?
    private static let recentLimit = 64 * 1024 * 1024

    private let maxBytes = ETSFZ.defaultMaxBytes

    /// 一覧にあるのに入れ物のファイルが無い。
    private struct MissingBank: Error {}

    // MARK: 状態

    func state(of id: UUID) -> SFZNodeState { states[id] ?? .idle }

    private func set(_ state: SFZNodeState, for id: UUID) {
        if states[id] != state { states[id] = state }
    }

    private func nextGeneration(_ id: UUID) -> Int {
        counter += 1
        generation[id] = counter
        return counter
    }

    private func current(_ id: UUID, _ number: Int) -> Bool { generation[id] == number }

    // MARK: 入れ直し

    /// 段が持つ鍵のバンクを置き場から読んで送る。鎖が戻ったとき・instance が作り直されたときに呼ぶ。
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
        guard SFZLibrary.shared.entry(id: bankID) != nil else {
            set(.missing, for: nodeID)
            return false
        }
        set(.loading, for: nodeID)
        let limit = maxBytes
        if let recent, recent.id == bankID {
            finish(nodeID: nodeID, bankID: bankID, number: number, dsp: dsp, announce: announce, result: .success(recent.prepared))
            return true
        }
        let files = SFZLibrary.shared.files
        Task.detached(priority: .userInitiated) {
            let result: Result<ETSFZPrepared, Error> = Result {
                guard let bytes = try files.readBank(bankID) else { throw MissingBank() }
                return try ETSFZService.prepare(bank: bytes,
                                                decode: { try ETSFZAudio.decode($0, ext: $1, budget: $2) },
                                                maxBytes: limit)
            }
            await MainActor.run {
                SFZLoader.shared.finish(nodeID: nodeID, bankID: bankID, number: number, dsp: EffeTuneDSP.shared,
                                        announce: announce, result: result)
            }
        }
        return true
    }

    /// 読めた資産を送る。UI のスレッドで。段がもう別の鍵になっていたら捨てる。
    private func finish(nodeID: UUID, bankID: String, number: Int, dsp: EffeTuneDSP, announce: Bool,
                        result: Result<ETSFZPrepared, Error>) {
        guard current(nodeID, number) else { return }
        switch result {
        case .failure(let error):
            let code = (error as? ETSFZError)?.code ?? .prepare
            if error is MissingBank {
                set(.missing, for: nodeID)
            } else {
                log.error("SFZ 読み込み失敗 \(String(describing: error), privacy: .public)")
                set(.failed(code), for: nodeID)
            }
        case .success(let prepared):
            guard let slot = dsp.slot(of: nodeID), let node = dsp.node(at: slot), node.irId == bankID else { return }
            do {
                try send(prepared, to: node, dsp: dsp)
                recent = prepared.asset.payload.count <= Self.recentLimit ? (bankID, prepared) : nil
                set(.ready(name: prepared.name, regions: prepared.regionCount), for: nodeID)
                if announce, let text = Self.warningMessage(prepared.warnings) { notice = text }
            } catch {
                log.error("SFZ 送り込み失敗 \(String(describing: error), privacy: .public)")
                let code: ETSFZErrorCode
                if case ETAssetUploadError.tooLarge = error { code = .tooLarge } else { code = .prepare }
                set(.failed(code), for: nodeID)
            }
        }
    }

    /// 資産をカーネルへ。begin の引数は SFZ 専用（SFZAsset.swift の注記）。
    private func send(_ prepared: ETSFZPrepared, to node: EffeTuneDSP.Node, dsp: EffeTuneDSP) throws {
        let asset = prepared.asset
        let info = AssetUpload.BeginInfo(channels: 1, frames: UInt32(asset.floatCount), topology: .unspecified,
                                         headBlock: 128, rateDivider: 1, pathCount: 0, inputCount: 0,
                                         processingChannels: 1, footprintBytes: UInt32(asset.footprintBytes))
        try AssetUpload.send(engine: dsp.engine, instance: node.instance, slot: 0, payload: asset.payload,
                             info: info, capacity: ETSFZ.maxSupportedBytes)
        // 送ると遅れが変わる。鎖を出し直して合わせる。
        dsp.republish()
    }

    // MARK: 取り込み

    /// 選んだフォルダの中の全ファイル（深さ 32・1 万本まで）。道は選んだフォルダからの相対。
    nonisolated static func enumerate(folder: URL) throws -> [ETSFZFolderFile] {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        var out: [ETSFZFolderFile] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
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
            if out.count >= 10000 { throw ETSFZError.prepare("The SFZ folder contains too many files.") }
            let path = try ETSFZParser.normalizePath(relative.joined(separator: "/"))
            out.append(ETSFZFolderFile(path: path, url: url, size: values?.fileSize ?? 0))
        }
        return out
    }

    /// 取り込んで置き場に入れ、段に送る。結果は states と notice に出る。
    func importFolder(_ files: [ETSFZFolderFile], selectedPath: String, into nodeID: UUID, dsp: EffeTuneDSP,
                      keepAccessTo folder: URL) {
        let number = nextGeneration(nodeID)
        set(.loading, for: nodeID)
        let limit = maxBytes
        let library = SFZLibrary.shared.files
        Task.detached(priority: .userInitiated) {
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            let result: Result<ETSFZService.ImportResult, Error> = Result {
                let imported = try ETSFZService.importFolder(
                    files: files, selectedPath: selectedPath, maxBytes: limit,
                    decode: { try ETSFZAudio.decode($0, ext: $1, budget: $2) },
                    inspect: { ETSFZAudio.inspect($0) })
                try library.writeBank(imported.id, imported.bank)
                return imported
            }
            await MainActor.run {
                SFZLoader.shared.finishImport(result, nodeID: nodeID, number: number, dsp: EffeTuneDSP.shared)
            }
        }
    }

    private func finishImport(_ result: Result<ETSFZService.ImportResult, Error>, nodeID: UUID, number: Int,
                              dsp: EffeTuneDSP) {
        guard current(nodeID, number) else { return }
        switch result {
        case .failure(let error):
            let code = (error as? ETSFZError)?.code ?? .prepare
            log.error("SFZ 取り込み失敗 \(String(describing: error), privacy: .public)")
            set(.failed(code), for: nodeID)
        case .success(let imported):
            do {
                try SFZLibrary.shared.add(ETSFZLibraryEntry(id: imported.id, name: imported.name,
                                                            regionCount: imported.regionCount))
            } catch {
                set(.failed(.storage), for: nodeID)
                return
            }
            guard let slot = dsp.slot(of: nodeID), dsp.node(at: slot) != nil else { return }
            dsp.setIRId(imported.id, at: slot)
            // 取り込んだ資産をそのまま送る（読み直さない）。
            finish(nodeID: nodeID, bankID: imported.id, number: number, dsp: dsp, announce: true,
                   result: .success(imported.prepared))
        }
    }

    /// 置き場にあるバンクを選んだ（選択欄から）。
    func choose(bankID: String, for nodeID: UUID, dsp: EffeTuneDSP) {
        guard let slot = dsp.slot(of: nodeID) else { return }
        dsp.setIRId(bankID, at: slot)
        if bankID.isEmpty {
            _ = nextGeneration(nodeID)
            set(.idle, for: nodeID)
            AssetUpload.clear(engine: dsp.engine, instance: dsp.node(at: slot)?.instance ?? 0)
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
        if recent?.id == bankID { recent = nil }
        choose(bankID: "", for: nodeID, dsp: dsp)
    }

    // MARK: 文

    /// 失敗の文。上流の文（sfz_note_player.js:_errorMessage）。設定の画面は無いので、上限を上げる案内は外した。
    static func errorMessage(_ code: ETSFZErrorCode) -> String {
        switch code {
        case .tooLarge: return "This SFZ exceeds the size limit. Choose a smaller SFZ."
        case .noRegions: return "No playable samples were found. Choose another SFZ."
        case .storage: return "The SFZ library could not be accessed. Check available storage space, then try again."
        case .cancelled: return ""
        case .prepare: return "The SFZ could not be loaded. Check that its sample files are available, or choose another SFZ."
        }
    }

    /// 読み込みの知らせ（_warningMessage）。同じ code は一度、code の順。
    static func warningMessage(_ warnings: [ETSFZWarning]) -> String? {
        let messages = [
            "loop-points-ignored": "Unused loop settings were adjusted so this SFZ could be loaded.",
            "invalid-regions": "Some sounds had invalid settings and were skipped.",
            "missing-samples": "Some sample files could not be found. The available sounds were loaded.",
            "unsupported-regions": "Some sounds use playback conditions this effect does not support and were skipped.",
            "reduced-bank": "A smaller selection of sounds was loaded to fit the size limit while keeping every note.",
        ]
        var seen = Set<String>()
        let lines = warnings.compactMap { w -> String? in
            guard let text = messages[w.code], seen.insert(w.code).inserted else { return nil }
            return text
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n\n")
    }
}
