//  ETSFZScriptService.swift
//  SFZ・SoundFont の取り込みと読み直しを、上流の js/sfz・js/sf2（Resources/SFZ/effetune-sfz.js）に任せる入口。
//  JavaScriptCore を動かすのは ETJSHost.swift。ここは「何を JS へ渡し、何を受け取るか」だけを持つ。
//
//  **JS がやること**: 読み・コンパイル・パック・id・index.json・警告・見積りの足し算（上流のコードそのまま）。
//  **Swift に残すこと**: 音のファイルの復号（AVAudioFile）・バックエンドの 6 つの操作・SHA-256・乱数・
//  標本の PCM を staging へ運ぶこと（JS の 1 浮動小数ずつの複写は、JavaScriptCore が JIT を使えないと遅いので外へ出す）。
//
//  PCM の書き手（globalThis.__effectdeckSfzPoolWriter。Patches/effetune-js-sfz-pool-writer.diff が呼ぶ）:
//    .host  prepare の間だけ受けて、標本の面を ETSFZPoolEntry で返す。payload のプール部分は 0 のまま（返す control は
//           プールの手前まで）。取り込みの間は何もしない（PCM は要らない）。
//    .js    差し込まない。上流のとおり JS が payload を埋め、control は payload 全体になる（見本との照合用）。
//
//  JS の service は prepare のたびに `prepared` を空にして作り直す。上流の cache に当たると、書き手が呼ばれず
//  プールが空の payload が返るため。**作り直しを避けるのは呼び手の cache（ETSFZScriptPrepared を持つ）の仕事。**
//  置き場（index.json）を JS の外から書き換えたら reset() を呼ぶ（JS が持つ一覧を開き直す）。
//
//  上流の誤りの code（prepare / too-large / no-regions / storage / cancelled）は ETSFZErrorCode に、message は上流の文のまま。

import Foundation

#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(os)
import os
#endif

// MARK: - 値（Foundation だけ）

/// 準備の幾何。見積りと begin で同じ値を使う（上流の sfzPreparationContext）。
struct ETSFZGeometry: Equatable {
    var sampleRate: Double
    var processingChannels: Int
    var maxFrames: Int
    var minimumPhysicalBpm: Double = 0
    /// 0 = SFZ Note Player、1 = SoundFont Player。
    var playerKind: Int = 0
}

/// float の 1 面。Swift が持つ領域を、JS には複写せず見せる（JS が手放すまでこの領域は生きる）。
final class ETSFZPlane: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<Float>
    let count: Int

    init(count: Int) {
        self.count = count
        pointer = UnsafeMutablePointer<Float>.allocate(capacity: max(count, 1))
        pointer.initialize(repeating: 0, count: max(count, 1))
    }

    convenience init(_ values: [Float]) {
        self.init(count: values.count)
        values.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { pointer.update(from: base, count: values.count) }
        }
    }

    deinit { pointer.deallocate() }

    var buffer: UnsafeBufferPointer<Float> { UnsafeBufferPointer(start: pointer, count: count) }
}

/// 音のファイル 1 本を復号したもの。
struct ETSFZScriptPCM {
    var channels: [ETSFZPlane]
    var sampleRate: Int
}

/// フォルダの中の 1 本。path は選んだフォルダからの相対（正規化済み）。
struct ETSFZScriptFile {
    var path: String
    var url: URL
    var size: Int
    /// 更新時刻（エポックからのミリ秒。JS の File.lastModified）。
    var lastModified: Double = 0
}

/// 書き出す入れ物（Blob）の 1 部分。ファイルの範囲は JS の ヒープを通さず、そのまま写す。
enum ETSFZScriptSegment {
    case bytes(Data)
    case fileRange(url: URL, offset: UInt64, length: UInt64)
}

/// 置き場の 1 件（上流の index.json の entries と同じ鍵）。
struct ETSFZScriptEntry: Equatable, Identifiable {
    var id: String
    var name: String
    var regionCount: Int
    var size: Int?
    var fileCount: Int?
    var importedAt: String?
    var streamedSource: Bool = false
    /// "sf2" / "sf3"（SoundFont のとき）。
    var format: String?
}

struct ETSFZScriptWarning: Equatable {
    var code: String
    var count: Int
}

struct ETSFZScriptLabel: Equatable {
    var index: Int
    var label: String
}

struct ETSFZScriptPresentation: Equatable {
    var keys: [ETSFZScriptLabel] = []
    var controllers: [ETSFZScriptLabel] = []
    var outputs: [ETSFZScriptLabel] = []
    var switches: [(first: Int, last: Int, label: String)] = []
    var groups: [String] = []
    /// 画像の道（バンクの中）。imageData は読めたときだけ。
    var image: String?
    var imageData: Data?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.keys == rhs.keys && lhs.controllers == rhs.controllers && lhs.outputs == rhs.outputs &&
            lhs.groups == rhs.groups && lhs.image == rhs.image && lhs.imageData == rhs.imageData &&
            lhs.switches.count == rhs.switches.count &&
            zip(lhs.switches, rhs.switches).allSatisfy { $0.first == $1.first && $0.last == $1.last && $0.label == $1.label }
    }
}

/// payload のプールの 1 区間（prepare の間に JS が呼んだ書き手 1 回ぶん）。
/// プールの float の位置 floatOffset（payload の 32 バイト目から数える）へ、frames × planes.count の
/// インターリーブで書く。planes は各チャンネルの面（frames 以上の長さ）。
struct ETSFZPoolEntry {
    var path: String
    var floatOffset: Int
    var frames: Int
    var planes: [ETSFZPlane]
}

/// prepare の結果。
struct ETSFZScriptPrepared {
    var id: String
    var name: String
    var format: String?
    var regionCount: Int
    var sampleCount: Int?
    /// payload の表の版（6・7 = 常駐、8・10 = 流し込みの SFZ、9 = SoundFont）。
    var tableVersion: Int
    var formatTag: Int
    /// payload の先頭。et_sample_player_preparation_bytes に渡す制御部（32 + 4·u32@48 バイト）。
    /// 流し込みの bank は payload 全体。poolMode が .js のときも payload 全体。
    var control: Data
    /// payload 全体の長さ（begin のサイズ。プールを含む）。
    var payloadByteCount: Int
    var poolEntries: [ETSFZPoolEntry]
    var warnings: [ETSFZScriptWarning]
    var unsupportedOpcodes: [String]
    var unsupportedRuntime: [String]
    var incomplete: Bool
    var tailSeconds: Double?
    var warmupSamples: Int?
    /// geometry を渡したときの、JS 側の見積り（payload + 見積り）。渡さなければ nil。
    var footprintBytes: Int?
    var nativePreparationBytes: Int?
    var processingChannels: Int
    var presentation: ETSFZScriptPresentation?
}

/// 取り消しの旗。Swift の Task の取り消しと、呼び手が渡す旗の両方がここへ集まる。JS は isCurrent で見る。
final class ETSFZCancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func cancel() { lock.lock(); flag = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

/// 上流の SfzLibraryService が頼む 6 つの操作。**呼ばれるのは JS のスレッドで、同期。**
/// key は index.json と `<24桁>.sfzbank`。
protocol ETSFZScriptBackend: AnyObject {
    func cleanupTemporary() throws
    func read(_ key: String) throws -> Data?
    func writeAtomic(_ key: String, _ data: Data) throws
    func remove(_ key: String) throws
    /// ストリーム用の入れ物（.sfzbank）を、開かずに指す。無ければ nil。
    func readSfzBankFile(_ name: String) throws -> ETSFZScriptFile?
    /// segments をつないだものを name へ原子的に書く。ファイルの範囲は直に写す。
    func writeSfzBankFile(_ name: String, segments: [ETSFZScriptSegment], isCurrent: () -> Bool) throws
}

/// 音のファイル（WAV・AIFF・FLAC など）のバイト列から PCM を作る。上流の decode の口。
typealias ETSFZScriptDecode = (_ data: Data) throws -> ETSFZScriptPCM
/// 制御部から、カーネルが標本の再生に足す確保量を引く（et_sample_player_preparation_bytes）。
/// ETSFZError で too-large などを投げてよい。
typealias ETSFZScriptEstimate = (_ control: Data, _ payloadBytes: Int, _ geometry: ETSFZGeometry, _ formatTag: Int) throws -> Int

/// 同梱の JS 2 本。
struct ETSFZScriptSources {
    var prelude: URL
    var bundle: URL

    /// アプリの資源から探す（平らに入る。サブフォルダ SFZ にあっても拾う）。
    static func bundled(_ bundle: Bundle = .main) throws -> ETSFZScriptSources {
        func find(_ name: String) -> URL? {
            bundle.url(forResource: name, withExtension: "js") ?? bundle.url(forResource: name, withExtension: "js", subdirectory: "SFZ")
        }
        guard let prelude = find("effetune-sfz-prelude"), let script = find("effetune-sfz") else {
            throw ETSFZError(code: .prepare, message: "SoundFont playback is unavailable. Reload the app and try again.")
        }
        return ETSFZScriptSources(prelude: prelude, bundle: script)
    }
}

/// 上流の誤りの code と message を ETSFZError にする（JS が付けた綴りだけを受け、知らない綴りは prepare）。
/// code が無いとき、取り消しの旗が立っていれば cancelled（待ちの途中で止まった誤りは code を持たない）。
enum ETSFZScriptErrors {
    static func map(code: String?, message: String, cancelled: Bool) -> ETSFZError {
        let known = code.flatMap(ETSFZErrorCode.init(rawValue:))
        return ETSFZError(code: known ?? (cancelled ? .cancelled : .prepare), message: message)
    }
}

enum ETSFZPoolMode {
    /// PCM は Swift が運ぶ（本番）。
    case host
    /// 上流のとおり JS が payload を埋める（見本との照合）。
    case js
}

// MARK: - JavaScriptCore 越しの本体

#if canImport(JavaScriptCore)

import JavaScriptCore

extension ETSFZError: ETJSCodedError {
    var jsMessage: String { message }
    var jsCode: String? { code.rawValue }
}

/// ホストのファイルを JS へは番号で渡し、範囲だけ読む。仕事が終わるごとに閉じる。
private final class ETSFZHandleTable {
    private var urls: [Int: URL] = [:]
    private var descriptors: [Int: Int32] = [:]
    private var next = 1

    func register(_ url: URL) -> Int {
        let handle = next
        next += 1
        urls[handle] = url
        return handle
    }

    func url(_ handle: Int) -> URL? { urls[handle] }

    private func descriptor(_ handle: Int) throws -> Int32 {
        if let known = descriptors[handle] { return known }
        guard let url = urls[handle] else { throw ETSFZError(code: .prepare, message: "An SFZ sample could not be read.") }
        let opened = open(url.path, O_RDONLY)
        guard opened >= 0 else { throw ETSFZError(code: .prepare, message: "An SFZ sample could not be read.") }
        descriptors[handle] = opened
        return opened
    }

    /// 範囲を丁度 count バイト、destination へ読む。足りなければ誤り。
    func read(handle: Int, offset: UInt64, into destination: UnsafeMutableRawBufferPointer) throws {
        guard let base = destination.baseAddress, destination.count > 0 else { return }
        let fd = try descriptor(handle)
        var done = 0
        while done < destination.count {
            let n = pread(fd, base + done, destination.count - done, off_t(offset) + off_t(done))
            if n < 0 {
                if errno == EINTR { continue }
                throw ETSFZError(code: .prepare, message: "An SFZ sample could not be read.")
            }
            if n == 0 { throw ETSFZError(code: .prepare, message: "An instrument sample changed or could not be read. Reload the instrument.") }
            done += n
        }
    }

    func closeAll() {
        for (_, fd) in descriptors { close(fd) }
        descriptors.removeAll()
        urls.removeAll()
    }
}

/// 文脈ごとの持ち物（JS のスレッドの上でだけ触る）。
private final class ETSFZScriptState {
    let backend: ETSFZScriptBackend
    let decode: ETSFZScriptDecode
    let estimate: ETSFZScriptEstimate?
    let log: (String, String) -> Void

    let handles = ETSFZHandleTable()
    var token = ETSFZCancelToken()
    /// この仕事で JS へ渡した復号済みの面（書き手が受けた面を、複写せず引き当てる）。
    var planes: [UInt: ETSFZPlane] = [:]
    /// 非 nil の間だけ、書き手が面を受ける。
    var pool: [ETSFZPoolEntry]?
    var delivered: [String: Data] = [:]

    init(backend: ETSFZScriptBackend, decode: @escaping ETSFZScriptDecode, estimate: ETSFZScriptEstimate?,
         log: @escaping (String, String) -> Void) {
        self.backend = backend
        self.decode = decode
        self.estimate = estimate
        self.log = log
    }

    func begin(token: ETSFZCancelToken) {
        self.token = token
        planes.removeAll()
        pool = nil
        delivered.removeAll()
    }

    func end() {
        handles.closeAll()
        planes.removeAll()
        pool = nil
        delivered.removeAll()
        token = ETSFZCancelToken()
    }

    func requireCurrent() throws {
        if token.isCancelled { throw ETSFZError(code: .cancelled, message: "SFZ import was cancelled.") }
    }
}

final class ETSFZScriptService: @unchecked Sendable {

    private let host: ETJSHost
    private let sources: ETSFZScriptSources?
    private let loadError: Error?
    private let poolMode: ETSFZPoolMode
    private let maxBytes: Int

    /// sources が nil のときはアプリの資源（Bundle.main）から探す。
    /// maxBytes は上流の既定の上限（256 MiB。設定の画面は持たない）。
    init(backend: ETSFZScriptBackend, decode: @escaping ETSFZScriptDecode, estimate: ETSFZScriptEstimate? = nil,
         sources: ETSFZScriptSources? = nil, maxBytes: Int = 256 * 1024 * 1024, poolMode: ETSFZPoolMode = .host,
         idleSeconds: TimeInterval = 30, log: ((String, String) -> Void)? = nil) {
        var resolved = sources
        var failure: Error?
        if resolved == nil {
            do { resolved = try ETSFZScriptSources.bundled() } catch { failure = error }
        }
        self.sources = resolved
        loadError = failure
        self.poolMode = poolMode
        self.maxBytes = maxBytes
        let sink = log ?? ETSFZScriptService.defaultLog
        // setup は host の init で要るが、self をまだ持てない。必要なものだけ値で渡す。
        let environment = ETSFZScriptEnvironment(backend: backend, decode: decode, estimate: estimate, log: sink,
                                                 sources: resolved, failure: failure, poolMode: poolMode, maxBytes: maxBytes)
        host = ETJSHost(idleSeconds: idleSeconds) { context in try environment.install(into: context) }
    }

    var contextCount: Int { host.contextCount }

    // MARK: 操作

    /// 置き場の一覧（index.json の順）。
    func list() async throws -> [ETSFZScriptEntry] {
        try await job(nil) { context, _ in
            let text = try Self.callString(context, "list", [])
            return try Self.parseEntries(text)
        }
    }

    /// フォルダの中の SFZ の道（正規化・並べ替え済み）。SoundFont は D2 まで一覧に出さない。
    func listInstruments(in files: [ETSFZScriptFile], cancel: ETSFZCancelToken? = nil) async throws -> [String] {
        try await job(cancel) { context, state in
            let json = try Self.fileList(files, state)
            let text = try Self.callString(context, "listInstruments", [context.keptString(json)])
            guard let data = text.data(using: .utf8), let list = try JSONSerialization.jsonObject(with: data) as? [String] else {
                throw ETSFZError(code: .prepare, message: "The SFZ folder could not be read.")
            }
            return list.filter { $0.lowercased().hasSuffix(".sfz") }
        }
    }

    /// フォルダの SFZ 1 本を取り込む（置き場へ書き、一覧に足す）。PCM は運ばない（読み直しは prepare）。
    func importFolder(files: [ETSFZScriptFile], selectedPath: String, cancel: ETSFZCancelToken? = nil) async throws -> ETSFZScriptEntry {
        guard !selectedPath.lowercased().hasSuffix(".sf2"), !selectedPath.lowercased().hasSuffix(".sf3") else {
            throw ETSFZError(code: .prepare, message: "SoundFont playback is unavailable. Reload the app and try again.")
        }
        return try await job(cancel) { context, state in
            let json = try Self.fileList(files, state)
            let text = try Self.callString(context, "importFolder", [context.keptString(json), context.keptString(selectedPath)])
            guard let entry = try Self.parseEntries("[\(text)]").first else {
                throw ETSFZError(code: .prepare, message: "The SFZ could not be imported.")
            }
            return entry
        }
    }

    /// 置き場のバンクを読み直して、カーネルへ送れる形にする。置き場に無ければ nil。
    /// geometry があれば、上流の見積り（footprint）まで JS が計算する。
    func prepare(id: String, geometry: ETSFZGeometry? = nil, cancel: ETSFZCancelToken? = nil) async throws -> ETSFZScriptPrepared? {
        let writes = poolMode == .host
        return try await job(cancel) { context, state in
            if writes { state.pool = [] }
            var arguments: [JSValueRef] = [context.keptString(id)]
            if let geometry {
                arguments.append(context.keptString(Self.geometryJSON(geometry)))
            }
            guard let text = try Self.callNullable(context, "prepare", arguments) else { return nil }
            return try Self.parsePrepared(text, state: state)
        }
    }

    /// バンクを置き場から消す（一覧と入れ物）。
    func remove(id: String) async throws {
        try await job(nil) { context, _ in
            _ = try Self.callNullable(context, "remove", [context.keptString(id)])
        }
    }

    /// JS が持つ一覧を開き直す（置き場を JS の外から書き換えたとき）。
    func reset() async throws {
        try await job(nil) { context, _ in
            _ = try Self.callNullable(context, "reset", [])
        }
    }

    /// 文脈を今すぐ捨てる。
    func shutdown() { host.drop() }

    // MARK: 仕事

    private func job<T>(_ cancel: ETSFZCancelToken?,
                        _ body: @escaping (ETJSContext, ETSFZScriptState) throws -> T) async throws -> T {
        let token = cancel ?? ETSFZCancelToken()
        do {
            return try await withTaskCancellationHandler {
                try await host.run { context in
                    guard let state = context.state as? ETSFZScriptState else {
                        throw ETSFZError(code: .prepare, message: "SoundFont playback is unavailable. Reload the app and try again.")
                    }
                    state.begin(token: token)
                    defer { state.end() }
                    try state.requireCurrent()
                    return try body(context, state)
                }
            } onCancel: {
                token.cancel()
            }
        } catch {
            throw Self.map(error, cancelled: token.isCancelled)
        }
    }

    static func map(_ error: Error, cancelled: Bool) -> Error {
        if let error = error as? ETSFZError { return error }
        if let error = error as? ETJSError {
            return ETSFZScriptErrors.map(code: error.code, message: error.message, cancelled: cancelled)
        }
        if cancelled { return ETSFZError(code: .cancelled, message: "Instrument import was cancelled.") }
        return ETSFZError(code: .prepare, message: String(describing: error))
    }

    private static let defaultLog: (String, String) -> Void = { level, text in
        #if canImport(os)
        let logger = Logger(subsystem: "ai.nemut.effetune", category: "sfzjs")
        switch level {
        case "error": logger.error("\(text, privacy: .public)")
        case "warn": logger.warning("\(text, privacy: .public)")
        default: logger.debug("\(text, privacy: .public)")
        }
        #endif
    }

    // MARK: JS の呼び出し

    /// __etSfz.<name>(…) を呼んで、Promise を待ち、文字列（JSON）で受ける。null / undefined は誤り。
    private static func callString(_ context: ETJSContext, _ name: String, _ arguments: [JSValueRef]) throws -> String {
        guard let text = try callNullable(context, name, arguments) else {
            throw ETSFZError(code: .prepare, message: "The SFZ library is unavailable.")
        }
        return text
    }

    private static func callNullable(_ context: ETJSContext, _ name: String, _ arguments: [JSValueRef]) throws -> String? {
        guard let api = context.property(context.global, "__etSfz"), let object = context.asObject(api) else {
            throw ETSFZError(code: .prepare, message: "SoundFont playback is unavailable. Reload the app and try again.")
        }
        let result = try context.awaitPromise(try context.callMethod(object, name, arguments))
        return context.isNullish(result) ? nil : context.text(of: result)
    }

    private static func geometryJSON(_ geometry: ETSFZGeometry) -> String {
        let object: [String: Any] = ["sampleRate": geometry.sampleRate, "processingChannels": geometry.processingChannels,
                                     "maxFrames": geometry.maxFrames, "minimumPhysicalBpm": geometry.minimumPhysicalBpm,
                                     "playerKind": geometry.playerKind]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// JS の File にする元（番号・大きさ・名前・更新時刻・選んだフォルダからの道）。
    private static func fileList(_ files: [ETSFZScriptFile], _ state: ETSFZScriptState) throws -> String {
        let list: [[String: Any]] = files.map { file in
            ["handle": state.handles.register(file.url), "size": file.size, "lastModified": file.lastModified,
             "name": file.path.split(separator: "/").last.map(String.init) ?? file.path, "path": file.path]
        }
        let data = try JSONSerialization.data(withJSONObject: list)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: JSON から値へ

    private static func int(_ value: Any?) -> Int? { (value as? NSNumber).flatMap { Int(exactly: $0.doubleValue) } }

    private static func parseEntries(_ text: String) throws -> [ETSFZScriptEntry] {
        guard let data = text.data(using: .utf8), let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ETSFZError(code: .storage, message: "The SFZ library could not be opened.")
        }
        return try list.map { item in
            guard let id = item["id"] as? String, let name = item["name"] as? String, let count = int(item["regionCount"]) else {
                throw ETSFZError(code: .storage, message: "Invalid SFZ library index.")
            }
            return ETSFZScriptEntry(id: id, name: name, regionCount: count, size: int(item["size"]),
                                    fileCount: int(item["fileCount"]), importedAt: item["importedAt"] as? String,
                                    streamedSource: (item["streamedSource"] as? Bool) ?? false,
                                    format: item["format"] as? String)
        }
    }

    private static func labels(_ value: Any?) -> [ETSFZScriptLabel] {
        ((value as? [[String: Any]]) ?? []).compactMap { item in
            guard let index = int(item["index"]), let label = item["label"] as? String else { return nil }
            return ETSFZScriptLabel(index: index, label: label)
        }
    }

    private static func parsePrepared(_ text: String, state: ETSFZScriptState) throws -> ETSFZScriptPrepared {
        guard let data = text.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String, let control = state.delivered["control"],
              let regionCount = int(object["regionCount"]), let tableVersion = int(object["tableVersion"]),
              let payloadBytes = int(object["payloadBytes"]) else {
            throw ETSFZError(code: .prepare, message: "The SFZ bank could not be prepared.")
        }
        var presentation: ETSFZScriptPresentation?
        if let item = object["presentation"] as? [String: Any] {
            var value = ETSFZScriptPresentation()
            value.keys = labels(item["keys"])
            value.controllers = labels(item["controllers"])
            value.outputs = labels(item["outputs"])
            value.switches = ((item["switches"] as? [[String: Any]]) ?? []).compactMap { entry in
                guard let first = int(entry["first"]), let last = int(entry["last"]), let label = entry["label"] as? String else { return nil }
                return (first, last, label)
            }
            value.groups = (item["groups"] as? [String]) ?? []
            value.image = item["image"] as? String
            value.imageData = state.delivered["image"]
            presentation = value
        }
        return ETSFZScriptPrepared(
            id: id, name: (object["name"] as? String) ?? "", format: object["format"] as? String,
            regionCount: regionCount, sampleCount: int(object["sampleCount"]), tableVersion: tableVersion,
            formatTag: int(object["formatTag"]) ?? 1, control: control, payloadByteCount: payloadBytes,
            poolEntries: state.pool ?? [],
            warnings: ((object["warnings"] as? [[String: Any]]) ?? []).compactMap { item in
                guard let code = item["code"] as? String, let count = int(item["count"]) else { return nil }
                return ETSFZScriptWarning(code: code, count: count)
            },
            unsupportedOpcodes: (object["unsupportedOpcodes"] as? [String]) ?? [],
            unsupportedRuntime: (object["unsupportedRuntime"] as? [String]) ?? [],
            incomplete: (object["incomplete"] as? Bool) ?? false,
            tailSeconds: (object["tailSeconds"] as? NSNumber)?.doubleValue, warmupSamples: int(object["warmupSamples"]),
            footprintBytes: int(object["footprintBytes"]), nativePreparationBytes: int(object["nativePreparationBytes"]),
            processingChannels: int(object["processingChannels"]) ?? 1, presentation: presentation)
    }
}

// MARK: - 文脈の組み立て

/// 文脈を建てるたびに、ホストの関数・プレリュード・束ね・つなぎの JS を入れる。
private final class ETSFZScriptEnvironment: @unchecked Sendable {
    let backend: ETSFZScriptBackend
    let decode: ETSFZScriptDecode
    let estimate: ETSFZScriptEstimate?
    let log: (String, String) -> Void
    let sources: ETSFZScriptSources?
    let failure: Error?
    let poolMode: ETSFZPoolMode
    let maxBytes: Int

    private let lock = NSLock()
    private var text: (prelude: String, bundle: String)?

    init(backend: ETSFZScriptBackend, decode: @escaping ETSFZScriptDecode, estimate: ETSFZScriptEstimate?,
         log: @escaping (String, String) -> Void, sources: ETSFZScriptSources?, failure: Error?,
         poolMode: ETSFZPoolMode, maxBytes: Int) {
        self.backend = backend
        self.decode = decode
        self.estimate = estimate
        self.log = log
        self.sources = sources
        self.failure = failure
        self.poolMode = poolMode
        self.maxBytes = maxBytes
    }

    private func scripts() throws -> (prelude: String, bundle: String) {
        lock.lock()
        defer { lock.unlock() }
        if let text { return text }
        if let failure { throw failure }
        guard let sources else { throw ETSFZError(code: .prepare, message: "SoundFont playback is unavailable. Reload the app and try again.") }
        do {
            let loaded = (try String(contentsOf: sources.prelude, encoding: .utf8), try String(contentsOf: sources.bundle, encoding: .utf8))
            text = loaded
            return loaded
        } catch {
            throw ETSFZError(code: .prepare, message: "SoundFont playback is unavailable. Reload the app and try again.")
        }
    }

    func install(into context: ETJSContext) throws {
        let loaded = try scripts()
        let state = ETSFZScriptState(backend: backend, decode: decode, estimate: estimate, log: log)
        context.state = state
        let host = context.makeObject()
        context.installTimers(on: host)
        installBasics(host, context, state)
        installBackend(host, context, state)
        installDecodeAndEstimate(host, context, state)
        context.setProperty(context.global, "__et", host)
        if poolMode == .host { installPoolWriter(context, state) }
        try context.evaluate(loaded.prelude, url: "effetune-sfz-prelude.js")
        try context.evaluate(loaded.bundle, url: "effetune-sfz.js")
        try context.evaluate(ETSFZScriptEnvironment.glue, url: "effetune-sfz-glue.js")
        guard let api = context.property(context.global, "__etSfz"), let object = context.asObject(api) else {
            throw ETSFZError(code: .prepare, message: "SoundFont playback is unavailable. Reload the app and try again.")
        }
        _ = try context.callMethod(object, "configure", [context.number(Double(maxBytes)), context.boolean(poolMode == .js)])
    }

    // MARK: ホストの関数

    private func installBasics(_ host: JSObjectRef, _ context: ETJSContext, _ state: ETSFZScriptState) {
        #if canImport(CryptoKit)
        context.install("sha256", on: host) { context, arguments in
            guard let first = arguments.first, let window = context.byteWindow(of: first) else {
                throw ETJSError(name: "TypeError", message: "sha256 needs bytes.")
            }
            let data = window.baseAddress.map { Data(bytesNoCopy: $0, count: window.count, deallocator: .none) } ?? Data()
            let made = try context.makeUint8Array(copying: Data(SHA256.hash(data: data)))
            return made
        }
        #endif
        context.install("random", on: host) { context, arguments in
            guard let first = arguments.first, let window = context.byteWindow(of: first) else {
                throw ETJSError(name: "TypeError", message: "random needs bytes.")
            }
            var generator = SystemRandomNumberGenerator()
            for index in 0..<window.count { window[index] = UInt8.random(in: 0...255, using: &generator) }
            return nil
        }
        context.install("log", on: host) { context, arguments in
            let level = arguments.first.map { context.text(of: $0) } ?? "log"
            let text = arguments.count > 1 ? context.text(of: arguments[1]) : ""
            state.log(level, text)
            return nil
        }
        context.install("isCurrent", on: host) { context, _ in context.boolean(!state.token.isCancelled) }
        context.install("deliver", on: host) { context, arguments in
            guard arguments.count > 1, let window = context.byteWindow(of: arguments[1]) else {
                throw ETJSError(name: "TypeError", message: "deliver needs a name and bytes.")
            }
            state.delivered[context.text(of: arguments[0])] = window.baseAddress.map { Data(bytes: $0, count: window.count) } ?? Data()
            return nil
        }
        context.install("readRange", on: host) { context, arguments in
            guard arguments.count >= 3, let handle = context.int(of: arguments[0]), let offset = context.double(of: arguments[1]),
                  let length = context.int(of: arguments[2]), offset >= 0, length >= 0 else {
                throw ETJSError(name: "TypeError", message: "readRange needs a handle, an offset and a length.")
            }
            try state.requireCurrent()
            let made = try context.makeUint8Array(length: length)
            try state.handles.read(handle: handle, offset: UInt64(offset), into: made.bytes)
            return made.array
        }
    }

    private func installBackend(_ host: JSObjectRef, _ context: ETJSContext, _ state: ETSFZScriptState) {
        let backendObject = context.makeObject()
        context.install("cleanupTemporary", on: backendObject) { _, _ in
            try state.backend.cleanupTemporary()
            return nil
        }
        context.install("read", on: backendObject) { context, arguments in
            guard let key = arguments.first.map({ context.text(of: $0) }) else { throw ETJSError(name: "TypeError", message: "read needs a key.") }
            guard let data = try state.backend.read(key) else { return context.null }
            return try context.makeUint8Array(copying: data)
        }
        context.install("writeAtomic", on: backendObject) { context, arguments in
            guard arguments.count > 1, let window = context.byteWindow(of: arguments[1]) else {
                throw ETJSError(name: "TypeError", message: "writeAtomic needs a key and bytes.")
            }
            let data = window.baseAddress.map { Data(bytes: $0, count: window.count) } ?? Data()
            try state.backend.writeAtomic(context.text(of: arguments[0]), data)
            return nil
        }
        context.install("remove", on: backendObject) { context, arguments in
            guard let key = arguments.first.map({ context.text(of: $0) }) else { throw ETJSError(name: "TypeError", message: "remove needs a key.") }
            try state.backend.remove(key)
            return nil
        }
        context.install("openFile", on: backendObject) { context, arguments in
            guard let name = arguments.first.map({ context.text(of: $0) }) else { throw ETJSError(name: "TypeError", message: "openFile needs a name.") }
            guard let file = try state.backend.readSfzBankFile(name) else { return context.null }
            let object = context.makeObject()
            context.setProperty(object, "handle", context.number(Double(state.handles.register(file.url))))
            context.setProperty(object, "size", context.number(Double(file.size)))
            context.setProperty(object, "name", context.string(name))
            context.setProperty(object, "lastModified", context.number(file.lastModified))
            return object
        }
        context.install("writeFile", on: backendObject) { context, arguments in
            guard arguments.count > 1, let list = context.asObject(arguments[1]),
                  let lengthValue = context.property(list, "length"), let length = context.int(of: lengthValue) else {
                throw ETJSError(name: "TypeError", message: "writeFile needs a name and segments.")
            }
            var segments: [ETSFZScriptSegment] = []
            for index in 0..<length {
                guard let element = context.element(list, index), let segment = context.asObject(element) else {
                    throw ETJSError(name: "TypeError", message: "A segment is invalid.")
                }
                if let bytes = context.property(segment, "bytes"), !context.isNullish(bytes), let window = context.byteWindow(of: bytes) {
                    segments.append(.bytes(window.baseAddress.map { Data(bytes: $0, count: window.count) } ?? Data()))
                } else if let handleValue = context.property(segment, "handle"), let handle = context.int(of: handleValue),
                          let url = state.handles.url(handle),
                          let offset = context.property(segment, "offset").flatMap({ context.double(of: $0) }),
                          let count = context.property(segment, "length").flatMap({ context.double(of: $0) }) {
                    segments.append(.fileRange(url: url, offset: UInt64(offset), length: UInt64(count)))
                } else {
                    throw ETJSError(name: "TypeError", message: "A segment is invalid.")
                }
            }
            try state.backend.writeSfzBankFile(context.text(of: arguments[0]), segments: segments,
                                               isCurrent: { !state.token.isCancelled })
            return nil
        }
        context.setProperty(host, "backend", backendObject)
    }

    private func installDecodeAndEstimate(_ host: JSObjectRef, _ context: ETJSContext, _ state: ETSFZScriptState) {
        context.install("decode", on: host) { context, arguments in
            guard let first = arguments.first, let window = context.byteWindow(of: first) else {
                throw ETSFZError(code: .prepare, message: "An SFZ sample could not be read.")
            }
            try state.requireCurrent()
            let data = window.baseAddress.map { Data(bytes: $0, count: window.count) } ?? Data()
            let pcm = try state.decode(data)
            let result = context.keep(context.makeObject())
            context.setProperty(result, "sampleRate", context.number(Double(pcm.sampleRate)))
            var arrays: [JSValueRef] = []
            for plane in pcm.channels {
                state.planes[UInt(bitPattern: plane.pointer)] = plane
                arrays.append(context.keep(try context.makeFloat32Array(pointer: plane.pointer, count: plane.count, owner: plane)))
            }
            context.setProperty(result, "channels", context.makeArray(arrays))
            return result
        }
        context.install("estimate", on: host) { context, arguments in
            guard let estimate = state.estimate else {
                throw ETSFZError(code: .prepare, message: "Instrument effect preparation is unavailable. Reload the app and try again.")
            }
            guard arguments.count >= 8, let controlWindow = context.byteWindow(of: arguments[0]),
                  let payloadBytes = context.int(of: arguments[1]), let sampleRate = context.double(of: arguments[2]),
                  let channels = context.int(of: arguments[3]), let maxFrames = context.int(of: arguments[4]),
                  let bpm = context.double(of: arguments[5]), let kind = context.int(of: arguments[6]),
                  let formatTag = context.int(of: arguments[7]) else {
                throw ETSFZError(code: .prepare, message: "The instrument preparation data is invalid.")
            }
            let control = controlWindow.baseAddress.map { Data(bytes: $0, count: controlWindow.count) } ?? Data()
            let geometry = ETSFZGeometry(sampleRate: sampleRate, processingChannels: channels, maxFrames: maxFrames,
                                         minimumPhysicalBpm: bpm, playerKind: kind)
            return context.number(Double(try estimate(control, payloadBytes, geometry, formatTag)))
        }
    }

    /// Patches/effetune-js-sfz-pool-writer.diff が呼ぶ。標本 1 つにつき 1 回（path, 浮動小数の位置, フレーム数, チャンネル数, 面）。
    private func installPoolWriter(_ context: ETJSContext, _ state: ETSFZScriptState) {
        context.install("__effectdeckSfzPoolWriter", on: context.global) { context, arguments in
            // 取り込みの間は PCM が要らない（state.pool が nil）。呼ばれたことだけ受けて、複写を省く
            guard state.pool != nil else { return nil }
            guard arguments.count >= 5, let offset = context.int(of: arguments[1]), let frames = context.int(of: arguments[2]),
                  let channelCount = context.int(of: arguments[3]), let list = context.asObject(arguments[4]),
                  offset >= 0, frames >= 0, channelCount >= 1 else {
                throw ETSFZError(code: .prepare, message: "The SFZ bank could not be prepared.")
            }
            var planes: [ETSFZPlane] = []
            for index in 0..<channelCount {
                guard let element = context.element(list, index), context.isFloat32Array(element),
                      let window = context.byteWindow(of: element), window.count >= frames * MemoryLayout<Float>.stride else {
                    throw ETSFZError(code: .prepare, message: "The SFZ bank could not be prepared.")
                }
                let count = window.count / MemoryLayout<Float>.stride
                if let base = window.baseAddress, let known = state.planes[UInt(bitPattern: base)], known.count == count {
                    planes.append(known)
                } else {
                    // 復号を通らない面（発振器・埋め込み標本の変換）。JS が手放す前に複写する
                    let copy = ETSFZPlane(count: count)
                    if let base = window.baseAddress { copy.pointer.update(from: base.assumingMemoryBound(to: Float.self), count: count) }
                    planes.append(copy)
                }
            }
            state.pool?.append(ETSFZPoolEntry(path: context.text(of: arguments[0]), floatOffset: offset, frames: frames, planes: planes))
            return nil
        }
    }

    // MARK: つなぎの JS

    /// 上流の service を、ホストの 6 つの操作で動かし、結果を JSON の文字列で返す薄い層。
    /// 束ね（ETSFZ）の後に評価する。**上流の挙動はここで変えない。**
    static let glue = #"""
    (function () {
      'use strict';
      const G = globalThis, H = G.__et, API = G.ETSFZ;
      const config = { maxBytes: 256 * 1024 * 1024, fullPayload: false };
      let service = null;
      const safe = value => { try { return JSON.stringify(value); } catch (error) { return String(value); } };
      const decode = async (buffer, sampleRate) => H.decode(buffer, sampleRate === undefined ? null : sampleRate);
      const isCurrent = () => H.isCurrent();
      const backend = {
        cleanupTemporary: async () => { H.backend.cleanupTemporary(); },
        read: async key => H.backend.read(key),
        writeAtomic: async (key, bytes) => { H.backend.writeAtomic(key, bytes); },
        remove: async key => { H.backend.remove(key); },
        readSfzBankFile: async name => { const file = H.backend.openFile(name); return file ? G.__etShim.hostFile(file) : null; },
        writeSfzBankFile: async (name, blob) => { H.backend.writeFile(name, G.__etShim.segments(blob)); },
      };
      const estimate = async (payload, context, formatTag) => {
        const data = API.samplePlayerPreparationData(payload);
        return H.estimate(data.control, data.payloadBytes, context.sampleRate, context.processingChannels,
          context.maxFrames, context.minimumPhysicalBpm, context.playerKind, formatTag);
      };
      const hostFiles = json => JSON.parse(json).map(file => G.__etShim.hostFile({ handle: file.handle, size: file.size,
        name: file.name, lastModified: file.lastModified, webkitRelativePath: 'root/' + file.path }));
      async function ensure() {
        if (!service) service = await new API.SfzLibraryService(backend, { getMaxBytes: () => config.maxBytes,
          onDiagnostic: detail => H.log('warn', 'SFZ: ' + safe(detail)) }).open();
        return service;
      }
      async function prepare(id, geometryJson) {
        const library = await ensure();
        // 上流の cache に当たると書き手が呼ばれない。いつも作り直す（呼び手が cache を持つ）
        library.prepared = null;
        const options = { decode, isCurrent, persistentCache: null };
        if (geometryJson) {
          options.preparationContext = API.sfzPreparationContext(JSON.parse(geometryJson));
          options.estimateEffectBytes = estimate;
        }
        const value = await library.prepare(id, options);
        library.prepared = null;
        if (!value) return null;
        const d = value.descriptor, data = API.samplePlayerPreparationData(d.payload);
        H.deliver('control', config.fullPayload ? d.payload : data.control);
        let imageBytes = null;
        if (value.presentation && value.presentation.imageBlob) {
          const bytes = await value.presentation.imageBlob.bytes();
          H.deliver('image', bytes);
          imageBytes = bytes.length;
        }
        return JSON.stringify({ id, name: value.name ?? null, format: value.format ?? null, regionCount: value.regionCount,
          sampleCount: value.sampleCount ?? null, tableVersion: new DataView(d.payload).getUint32(36, true),
          formatTag: d.formatTag ?? 1, payloadBytes: d.payload.byteLength, warnings: value.warnings ?? [],
          unsupportedOpcodes: d.unsupportedOpcodes ?? [], unsupportedRuntime: d.unsupportedRuntime ?? [],
          incomplete: d.incomplete ?? false, tailSeconds: d.tailSeconds ?? null, warmupSamples: d.warmupSamples ?? null,
          footprintBytes: d.footprintBytes ?? null, nativePreparationBytes: d.nativePreparationBytes ?? null,
          processingChannels: d.processingChannels ?? 1,
          presentation: value.presentation ? { ...value.presentation, imageBlob: undefined, imageBytes } : null });
      }
      Object.defineProperty(G, '__etSfz', { value: Object.freeze({
        configure(maxBytes, fullPayload) { config.maxBytes = maxBytes; config.fullPayload = fullPayload; service = null; },
        reset() { service = null; },
        async list() { return safe(await (await ensure()).list()); },
        async listInstruments(json) { return safe(API.listSfzFolderFiles(hostFiles(json))); },
        async importFolder(json, selectedPath) {
          const library = await ensure();
          const entry = await library.importFolderFiles(hostFiles(json), selectedPath, { decode, isCurrent, persistentCache: null });
          library.prepared = null;
          return safe(entry);
        },
        prepare,
        async remove(id) { await (await ensure()).remove(id); return null; },
      }), configurable: true });
    })();
    """#
}

#endif
