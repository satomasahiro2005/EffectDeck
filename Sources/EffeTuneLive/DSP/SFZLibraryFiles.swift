//  SFZLibraryFiles.swift
//  SFZ のバンクの置き場（ライブラリ）と、フォルダの取り込み・バンクの読み直しの流れ。
//  **Foundation だけ。**音の読み（AVFoundation）は呼び手が closure で渡す。Linux でも走る（SFZTests）。
//
//  上流は js/sfz/service.js の SfzLibraryService（importFolderFiles・prepare・remove・index.json）。
//  置き場は <root>/index.json と <root>/<鍵>.sfzbank。index.json は
//  {"version":1,"entries":[{"id","name","regionCount"}]}（鍵の順）。
//  IR の置き場（IRLibrary）と違い、中身が大きい（上限 256 MiB）ので、Documents ではなく
//  Application Support に置き、バックアップからは外す（SFZLibrary.swift）。

import Foundation

struct ETSFZLibraryEntry: Equatable, Identifiable {
    var id: String
    var name: String
    var regionCount: Int
    /// 入れ物の大きさ・入っているファイルの数・取り込んだ時刻（ISO 8601）。2.14.0 の上流の一覧と同じ。
    /// 2.13.0 で取り込んだものには無い。
    var size: Int? = nil
    var fileCount: Int? = nil
    var importedAt: String? = nil
}

/// 読み込んで、カーネルへ送るだけになったバンク。
struct ETSFZPrepared {
    var name: String
    var asset: ETSFZPackedAsset
    var regionCount: Int
    var warnings: [ETSFZWarning]
}

/// フォルダの中の 1 本。道は選んだフォルダからの相対（正規化済み）。
struct ETSFZFolderFile {
    var path: String
    var url: URL
    var size: Int
}

/// 音のファイルを読む口。バイト列と拡張子（開く側が型を見るため）、まだ読んでよい量（decode 後のバイト）を渡す。
typealias ETSFZDecode = (Data, String, Int) throws -> ETSFZPCM
/// 音のファイルの形を、読まずに知る口（幅とフレーム数）。分からなければ nil。
typealias ETSFZInspect = (URL) -> (channels: Int, frames: Int)?

// MARK: - 置き場

/// 置き場のファイルの出し入れ。並べ替え・形の確かめは上流どおり。
final class ETSFZLibraryFiles: @unchecked Sendable {

    let root: URL

    init(root: URL) {
        self.root = root
    }

    private var indexURL: URL { root.appendingPathComponent("index.json") }
    private func bankURL(_ id: String) -> URL { root.appendingPathComponent("\(id).sfzbank") }

    func createFolder() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// 一覧。index.json が無ければ空。壊れていれば storage の誤り。
    func readIndex() throws -> [ETSFZLibraryEntry] {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: indexURL)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (object["version"] as? NSNumber)?.intValue == 1,
                  let list = object["entries"] as? [[String: Any]], list.count <= 10000 else {
                throw ETSFZError(code: .storage, message: "Invalid SFZ library index.")
            }
            return try list.map { item in
                guard let id = item["id"] as? String, ETSFZ.isValidID(id), let name = item["name"] as? String,
                      let count = (item["regionCount"] as? NSNumber)?.intValue, count >= 1 else {
                    throw ETSFZError(code: .storage, message: "Invalid SFZ library index.")
                }
                return ETSFZLibraryEntry(id: id, name: name, regionCount: count,
                                         size: (item["size"] as? NSNumber)?.intValue,
                                         fileCount: (item["fileCount"] as? NSNumber)?.intValue,
                                         importedAt: item["importedAt"] as? String)
            }
        } catch let error as ETSFZError {
            throw error
        } catch {
            throw ETSFZError(code: .storage, message: "The SFZ library could not be opened.")
        }
    }

    func writeIndex(_ entries: [ETSFZLibraryEntry]) throws {
        let list = entries.map { entry -> String in
            var fields = ["\"id\":\(ETSFZBank.jsonString(entry.id))", "\"name\":\(ETSFZBank.jsonString(entry.name))",
                          "\"regionCount\":\(entry.regionCount)"]
            if let size = entry.size { fields.append("\"size\":\(size)") }
            if let count = entry.fileCount { fields.append("\"fileCount\":\(count)") }
            if let time = entry.importedAt { fields.append("\"importedAt\":\(ETSFZBank.jsonString(time))") }
            return "{" + fields.joined(separator: ",") + "}"
        }
        let json = "{\"version\":1,\"entries\":[\(list.joined(separator: ","))]}"
        do {
            try createFolder()
            try Data(json.utf8).write(to: indexURL, options: .atomic)
        } catch {
            throw ETSFZError(code: .storage, message: "The SFZ bank could not be saved.")
        }
    }

    func writeBank(_ id: String, _ bytes: Data) throws {
        do {
            try createFolder()
            try bytes.write(to: bankURL(id), options: .atomic)
        } catch {
            throw ETSFZError(code: .storage, message: "The SFZ bank could not be saved.")
        }
    }

    /// バンクの入れ物。無ければ nil。
    func readBank(_ id: String) throws -> Data? {
        guard ETSFZ.isValidID(id), FileManager.default.fileExists(atPath: bankURL(id).path) else { return nil }
        do {
            return try Data(contentsOf: bankURL(id), options: .mappedIfSafe)
        } catch {
            throw ETSFZError(code: .storage, message: "The SFZ bank could not be read.")
        }
    }

    func removeBank(_ id: String) throws {
        guard ETSFZ.isValidID(id) else { throw ETSFZError(code: .storage, message: "Invalid SFZ bank identifier.") }
        do {
            if FileManager.default.fileExists(atPath: bankURL(id).path) { try FileManager.default.removeItem(at: bankURL(id)) }
        } catch {
            throw ETSFZError(code: .storage, message: "The SFZ bank could not be removed.")
        }
    }

    /// 入れた・外した後の一覧（鍵の順）。
    static func sorted(_ entries: [ETSFZLibraryEntry]) -> [ETSFZLibraryEntry] {
        entries.sorted { $0.id < $1.id }
    }
}

// MARK: - 取り込みと読み直し

enum ETSFZService {

    /// バンクの入れ物を読んで、カーネルへ送る形にする（上流の prepareBank）。音の読みは decode。
    static func prepare(bank bytes: Data, decode: ETSFZDecode, maxBytes: Int = ETSFZ.defaultMaxBytes,
                        onDiagnostic: ((ETSFZDiagnostics) -> Void)? = nil) throws -> ETSFZPrepared {
        let bank = try ETSFZBank.decode(bytes, maxBytes: maxBytes)
        var parsed = try parse(selectedPath: bank.selectedPath, readFile: { bank.file($0) },
                               hasFile: { bank.ranges[$0] != nil }, filePaths: Array(bank.ranges.keys),
                               maxBytes: maxBytes, onDiagnostic: onDiagnostic)
        parsed.warnings = ETSFZBank.mergeWarnings(bank.warnings, parsed.warnings)
        var prepared = try prepareSamples(parsed, readSample: { bank.file($0) }, decode: decode,
                                          maxBytes: maxBytes, onDiagnostic: onDiagnostic)
        prepared.name = String(bank.selectedPath.split(separator: "/", omittingEmptySubsequences: false).last ?? "")
        return prepared
    }

    /// 入れ物の中の SFZ を読む（parseBankFiles）。入れ物に bank.xml があればその `<Define>` も効かせる。
    private static func parse(selectedPath: String, readFile: (String) -> Data?, hasFile: @escaping (String) -> Bool,
                              filePaths: [String],
                              maxBytes: Int, onDiagnostic: ((ETSFZDiagnostics) -> Void)?) throws -> ETSFZParseResult {
        let readText: (String) throws -> String? = { path in readFile(path).map(ETSFZSource.decodeText) }
        let defines = try ETSFZSource.bankDefines(selectedPath: selectedPath,
                                                  bankPaths: filePaths.filter(ETSFZSource.isBankPath),
                                                  readText: readText).defines
        return try ETSFZParser.parse(selectedPath: selectedPath, readText: readText,
                                     hasSample: hasFile, maxBytes: maxBytes, defines: defines,
                                     onDiagnostic: onDiagnostic)
    }

    /// 領域が指す音を全部読み、資産に組む（prepareSfzSamples）。
    static func prepareSamples(_ parsed: ETSFZParseResult, readSample: (String) throws -> Data?,
                               decode: ETSFZDecode, maxBytes: Int,
                               onDiagnostic: ((ETSFZDiagnostics) -> Void)?) throws -> ETSFZPrepared {
        var samples: [String: ETSFZPCM] = [:]
        var decodedBytes = 0
        for path in ETSFZ.jsSorted(Array(Set(parsed.regions.map(\.sample)))) {
            if ETSFZGenerator.isGenerator(path) {
                let pcm = ETSFZGenerator.pcm(path)
                decodedBytes += pcm.channels[0].count * 4
                if decodedBytes > maxBytes { throw ETSFZError.tooLarge("The SFZ samples are too large to load.") }
                samples[path] = pcm
                continue
            }
            guard let bytes = try readSample(path) else { throw ETSFZError.prepare("An SFZ sample could not be found.") }
            let ext = (path as NSString).pathExtension
            let pcm = try decode(bytes, ext, maxBytes - decodedBytes)
            if pcm.channels.count > 2 { throw ETSFZError.prepare("SFZ samples must contain mono or stereo audio.") }
            decodedBytes += pcm.channels.count * (pcm.channels.first?.count ?? 0) * 4
            if decodedBytes > maxBytes { throw ETSFZError.tooLarge("The SFZ samples are too large to load.") }
            samples[path] = pcm
        }
        let packed = try ETSFZAsset.pack(parsed.regions, samples: samples, maxBytes: maxBytes, onDiagnostic: onDiagnostic)
        // 定義の読みで落とした領域と、音を見て落とした領域は別なので足す。
        let recovered = packed.warnings.map { warning -> ETSFZWarning in
            guard warning.code == "invalid-regions" else { return warning }
            let before = parsed.warnings.first { $0.code == "invalid-regions" }?.count ?? 0
            return ETSFZWarning(code: warning.code, count: warning.count + before)
        }
        let warnings = ETSFZBank.mergeWarnings(parsed.warnings, recovered)
        return ETSFZPrepared(name: "", asset: packed, regionCount: packed.regionCount, warnings: warnings)
    }

    struct ImportResult {
        var id: String
        var name: String
        var regionCount: Int
        var bank: Data
        var prepared: ETSFZPrepared
        /// 入れ物に入れたファイルの数（一覧の Files）。
        var fileCount: Int = 0
    }

    /// 選んだフォルダと SFZ から、バンクを作って読み込む（importFolderFiles）。
    /// 置き場への書き込みは呼び手（成功してから）。
    static func importFolder(files: [ETSFZFolderFile], selectedPath inputPath: String,
                             maxBytes: Int = ETSFZ.defaultMaxBytes,
                             decode: ETSFZDecode, inspect: ETSFZInspect,
                             onDiagnostic: ((ETSFZDiagnostics) -> Void)? = nil) throws -> ImportResult {
        var selected: [String: ETSFZFolderFile] = [:]
        for file in files { selected[file.path] = file }
        let selectedPath = try ETSFZParser.normalizePath(inputPath)
        func read(_ path: String) throws -> Data? {
            guard let file = selected[path] else { return nil }
            if file.size > maxBytes { throw ETSFZError.tooLarge("An SFZ file is too large to save.") }
            let bytes: Data
            do { bytes = try Data(contentsOf: file.url) } catch {
                throw ETSFZError.prepare("An SFZ file could not be read.")
            }
            if bytes.count > maxBytes { throw ETSFZError.tooLarge("An SFZ file is too large to save.") }
            return bytes
        }
        var stored: [String: Data] = [:]
        let readText: (String) throws -> String? = { path in
            var bytes = stored[path]
            if bytes == nil {
                bytes = try read(path)
                guard let loaded = bytes else { return nil }
                stored[path] = loaded
            }
            return ETSFZSource.decodeText(bytes!)
        }
        let bankDefines = try ETSFZSource.bankDefines(
            selectedPath: selectedPath, bankPaths: selected.keys.filter(ETSFZSource.isBankPath), readText: readText)
        // 開き直すときに要るのは、合った bank.xml の定義だけ。読んだほかの候補は入れ物に入れない。
        for path in Array(stored.keys) where path != bankDefines.bankPath { stored[path] = nil }
        var parsed = try ETSFZParser.parse(
            selectedPath: selectedPath, readText: readText,
            hasSample: { selected[$0] != nil }, maxBytes: maxBytes, defines: bankDefines.defines,
            onDiagnostic: onDiagnostic)
        if parsed.regions.isEmpty { throw ETSFZError(code: .noRegions, message: "The SFZ has no playable regions.") }

        var accumulated = stored.values.reduce(0) { $0 + $1.count }
        var metadata: [String: ETSFZSampleInfo] = [:]
        var sizes = stored.mapValues(\.count)
        for path in ETSFZ.jsSorted(Array(Set(parsed.regions.map(\.sample)))) {
            if ETSFZGenerator.isGenerator(path) {
                metadata[path] = ETSFZGenerator.metadata(path)
                continue
            }
            let file = selected[path]!
            let header = inspect(file.url)
            metadata[path] = ETSFZSampleInfo(size: file.size, frames: header?.frames ?? 0, channels: header?.channels ?? 0)
            sizes[path] = file.size
        }
        let rawSize = sizes.values.reduce(0, +)
        let containerBytes = try ETSFZBank.estimateBytes(selectedPath: selectedPath, sizes: sizes) - rawSize
        let selection = try ETSFZBank.selectRegionsForBudget(parsed.regions, metadata: metadata, maxBytes: maxBytes,
                                                             definitionBytes: accumulated + containerBytes)
        parsed.regions = selection.regions
        if selection.reduced {
            parsed.warnings = ETSFZBank.mergeWarnings(parsed.warnings, [ETSFZWarning(code: "reduced-bank", count: 1)])
            stored = [:]
            let text = Data(ETSFZBank.representativeText(parsed.regions, selectedPath: selectedPath).utf8)
            stored[selectedPath] = text
            accumulated = text.count
        }
        for path in ETSFZ.jsSorted(Array(Set(parsed.regions.map(\.sample))))
        where stored[path] == nil && !ETSFZGenerator.isGenerator(path) {
            let file = selected[path]!
            if accumulated + file.size > maxBytes { throw ETSFZError.tooLarge("The SFZ bank is too large to save.") }
            let bytes = try read(path)!
            accumulated += bytes.count
            if accumulated > maxBytes { throw ETSFZError.tooLarge("The SFZ bank is too large to save.") }
            stored[path] = bytes
        }
        let bank = try ETSFZBank.encode(selectedPath: selectedPath, files: stored, maxBytes: maxBytes,
                                        warnings: selection.reduced ? parsed.warnings : [])
        let id = ETSFZBank.identify(bank)
        var prepared = try prepareSamples(parsed, readSample: { stored[$0] }, decode: decode, maxBytes: maxBytes,
                                          onDiagnostic: onDiagnostic)
        let name = String(selectedPath.split(separator: "/", omittingEmptySubsequences: false).last ?? "")
        prepared.name = name
        return ImportResult(id: id, name: name, regionCount: prepared.regionCount, bank: bank, prepared: prepared,
                            fileCount: stored.count)
    }
}
