//  SFZLibraryBackend.swift
//  SFZ・SoundFont の置き場（ライブラリ）の入れ物。上流の SfzLibraryService（js/sfz/service.js）が
//  JavaScriptCore の中から呼ぶ 6 つの口（cleanupTemporary・read・writeAtomic・remove・readSfzBankFile・
//  writeSfzBankFile）を、ディスクの上で実装する。**Foundation だけ。**Linux でも走る（SFZLibraryBackendTests）。
//
//  置き場は <root>/index.json と <root>/<24 桁の 16 進>.sfzbank。名前は上流の OPFS 版と同じ許可の形
//  （index.json と <24hex>.sfzbank）だけを通す。道の組み立て（..・/）が入り込む余地は無い。
//  大きい入れ物（上限 1 GiB）は JS を通さない。writeSfzBankFile は、バイト列とファイルの範囲の並びを
//  1 MiB ずつ一時ファイルへ流して、最後に差し替える（上流の createWritable と同じ「閉じて初めて見える」）。
//  index.json は上流が JSON.stringify で書くので、知らない鍵（streamedSource・format など）を落とさない
//  ETSFZLibraryIndex で読み書きする（2.16.0 までの Swift の写しは 5 つの鍵しか持たず落としていた。2.17.0 で外した）。

import Foundation

// MARK: - 誤り

enum ETSFZBackendError: Error, Equatable {
    /// 許さない名前・形（上流の TypeError）。
    case invalidItem
    /// 上限を超える（上流の RangeError）。
    case tooLarge
    /// isCurrent が false になった（上流の AbortError）。
    case cancelled
    /// 読み書きの失敗。元の理由は文字で持つ。
    case io(String)
}

// MARK: - 入れ物に書く中身

/// writeSfzBankFile に渡す Blob の 1 部分。**ファイルの範囲は JS にも Swift のメモリにも全部は載せず**、流して書く。
enum ETSFZBackendPart: Equatable {
    case bytes(Data)
    case fileRange(url: URL, offset: UInt64, length: UInt64)

    var length: UInt64 {
        switch self {
        case .bytes(let data): return UInt64(data.count)
        case .fileRange(_, _, let length): return length
        }
    }
}

/// readSfzBankFile の答え。File の代わり（道と大きさ）。中身の範囲は readRange で読む。
struct ETSFZBankFile: Equatable {
    var url: URL
    var size: UInt64
}

// MARK: - 置き場の入れ物

final class ETSFZLibraryBackend: @unchecked Sendable {

    /// 上流の maxIrLibraryBytesForName: index.json は 32 MiB、バンクは SFZ_MAX_SUPPORTED_BYTES。
    static let maxIndexBytes = 32 * 1024 * 1024
    static let maxBankBytes = 1024 * 1024 * 1024
    /// writeSfzBankFile が 1 度に運ぶ量。上流と同じ 1 MiB。
    static let chunkBytes = 1024 * 1024
    /// 一時ファイルの拡張子。cleanupTemporary が起動のときに拾う。
    static let temporarySuffix = ".tmp"

    let root: URL

    init(root: URL) {
        self.root = root
    }

    // MARK: 名前

    static func isIndexName(_ name: String) -> Bool { name == "index.json" }

    /// `<24hex>.sfzbank`（小文字の 16 進）。
    static func isBankName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard bytes.count == 24 + 8, bytes.suffix(8).elementsEqual(".sfzbank".utf8) else { return false }
        return bytes.prefix(24).allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    static func isValidName(_ name: String) -> Bool { isIndexName(name) || isBankName(name) }

    private func url(_ name: String) throws -> URL {
        guard Self.isValidName(name) else { throw ETSFZBackendError.invalidItem }
        return root.appendingPathComponent(name)
    }

    private static func limit(for name: String) -> Int { isIndexName(name) ? maxIndexBytes : maxBankBytes }

    private func fail(_ error: Error) -> ETSFZBackendError {
        if let known = error as? ETSFZBackendError { return known }
        return .io(String(describing: error))
    }

    private func createFolder() throws {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw fail(error)
        }
    }

    private func size(of url: URL) throws -> UInt64? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes[.size] as? NSNumber)?.uint64Value
        } catch {
            throw fail(error)
        }
    }

    // MARK: 6 つの口

    /// 書きかけの一時ファイルを消す（SfzLibraryService.open が最初に呼ぶ）。無いフォルダは何もしない。
    func cleanupTemporary() throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: root.path) } catch { throw fail(error) }
        for name in names where name.hasSuffix(Self.temporarySuffix) {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
    }

    /// 中身。無ければ nil。上限を超えるものは tooLarge（index.json が大きすぎるときの上流と同じ）。
    func read(_ name: String) throws -> Data? {
        let target = try url(name)
        guard let bytes = try size(of: target) else { return nil }
        if bytes > UInt64(Self.limit(for: name)) { throw ETSFZBackendError.tooLarge }
        do {
            let data = try Data(contentsOf: target, options: Self.isBankName(name) ? .mappedIfSafe : [])
            if data.count > Self.limit(for: name) { throw ETSFZBackendError.tooLarge }
            return data
        } catch {
            throw fail(error)
        }
    }

    /// 書く。書きかけが見えないよう一時ファイルから差し替える。
    func writeAtomic(_ name: String, _ data: Data) throws {
        let target = try url(name)
        if data.count > Self.limit(for: name) { throw ETSFZBackendError.tooLarge }
        try createFolder()
        let temporary = makeTemporaryURL()
        do {
            try data.write(to: temporary)
            try replace(target, with: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw fail(error)
        }
    }

    /// 消す。無ければ何もしない（上流の NotFoundError を飲む）。
    func remove(_ name: String) throws {
        let target = try url(name)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        do { try FileManager.default.removeItem(at: target) } catch { throw fail(error) }
    }

    /// バンクの入れ物をファイルとして開く口。無ければ nil。
    func readSfzBankFile(_ name: String) throws -> ETSFZBankFile? {
        guard Self.isBankName(name) else { throw ETSFZBackendError.invalidItem }
        let target = try url(name)
        guard let bytes = try size(of: target) else { return nil }
        return ETSFZBankFile(url: target, size: bytes)
    }

    /// バンクの入れ物を、部分の並びから書く。大きさは 12 バイト（接頭）以上、上限は 1 GiB。
    /// 1 MiB ずつ流し、そのたびに isCurrent を見て（false なら cancelled）onProgress(完了, 全体) を呼ぶ。
    /// 範囲が指す元のファイルが途中で縮んでいたら失敗にする（上流の「The SFZ source changed during import.」）。
    func writeSfzBankFile(_ name: String, parts: [ETSFZBackendPart], isCurrent: (() -> Bool)? = nil,
                          onProgress: ((_ completedBytes: UInt64, _ totalBytes: UInt64) -> Void)? = nil) throws {
        guard Self.isBankName(name) else { throw ETSFZBackendError.invalidItem }
        let target = try url(name)
        var total: UInt64 = 0
        for part in parts {
            if case .fileRange(_, let offset, let length) = part, offset > UInt64.max - length { throw ETSFZBackendError.invalidItem }
            let (sum, overflow) = total.addingReportingOverflow(part.length)
            if overflow { throw ETSFZBackendError.tooLarge }
            total = sum
        }
        guard total >= 12 else { throw ETSFZBackendError.invalidItem }
        if total > UInt64(Self.maxBankBytes) { throw ETSFZBackendError.tooLarge }
        try createFolder()
        let temporary = makeTemporaryURL()
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw ETSFZBackendError.io("The SFZ bank could not be created.")
        }
        do {
            let out = try FileHandle(forWritingTo: temporary)
            var closed = false
            defer { if !closed { try? out.close() } }
            var completed: UInt64 = 0
            for part in parts {
                switch part {
                case .bytes(let data):
                    var offset = 0
                    while offset < data.count {
                        if isCurrent?() == false { throw ETSFZBackendError.cancelled }
                        let end = min(data.count, offset + Self.chunkBytes)
                        try out.write(contentsOf: data.subdata(in: (data.startIndex + offset)..<(data.startIndex + end)))
                        completed += UInt64(end - offset)
                        offset = end
                        onProgress?(completed, total)
                    }
                case .fileRange(let source, let start, let length):
                    let input = try FileHandle(forReadingFrom: source)
                    defer { try? input.close() }
                    try input.seek(toOffset: start)
                    var remaining = length
                    while remaining > 0 {
                        if isCurrent?() == false { throw ETSFZBackendError.cancelled }
                        let want = Int(min(remaining, UInt64(Self.chunkBytes)))
                        guard let chunk = try input.read(upToCount: want), chunk.count == want else {
                            throw ETSFZBackendError.io("The SFZ source changed during import.")
                        }
                        try out.write(contentsOf: chunk)
                        remaining -= UInt64(want)
                        completed += UInt64(want)
                        onProgress?(completed, total)
                    }
                }
            }
            if isCurrent?() == false { throw ETSFZBackendError.cancelled }
            closed = true
            try out.close()
            try replace(target, with: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw fail(error)
        }
    }

    /// バンクの入れ物の一部を読む（JS の File.slice(...).arrayBuffer() の代わり）。足りなければ失敗。
    func readRange(_ file: ETSFZBankFile, offset: UInt64, length: Int) throws -> Data {
        guard length >= 0, offset <= file.size, UInt64(length) <= file.size - offset else { throw ETSFZBackendError.invalidItem }
        if length == 0 { return Data() }
        do {
            let input = try FileHandle(forReadingFrom: file.url)
            defer { try? input.close() }
            try input.seek(toOffset: offset)
            guard let data = try input.read(upToCount: length), data.count == length else {
                throw ETSFZBackendError.io("The SFZ bank could not be read.")
            }
            return data
        } catch {
            throw fail(error)
        }
    }

    // MARK: index.json

    /// 一覧。index.json が無ければ空。壊れていれば invalidItem ではなく io（上流の「Invalid SFZ library index.」）。
    func readIndex() throws -> ETSFZLibraryIndex {
        guard let data = try read("index.json") else { return ETSFZLibraryIndex() }
        guard let index = ETSFZLibraryIndex(data: data) else { throw ETSFZBackendError.io("Invalid SFZ library index.") }
        return index
    }

    func writeIndex(_ index: ETSFZLibraryIndex) throws {
        try writeAtomic("index.json", index.serialized())
    }

    // MARK: 一時ファイルと差し替え

    private func makeTemporaryURL() -> URL {
        root.appendingPathComponent(UUID().uuidString.lowercased() + Self.temporarySuffix)
    }

    /// 同じフォルダの中の rename（置き換えは 1 命令）。
    private func replace(_ target: URL, with temporary: URL) throws {
        if rename(temporary.path, target.path) != 0 {
            throw ETSFZBackendError.io("The SFZ bank could not be saved.")
        }
    }
}

// MARK: - index.json（知らない鍵を落とさない）

/// JSON の値。数は元の字をそのまま持つ（往復で字が変わらない）。オブジェクトは並びを保つ。
indirect enum ETSFZJSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([ETSFZJSONValue])
    case object(ETSFZJSONObject)

    var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }

    /// 安全な整数のときだけ（JS の Number.isSafeInteger）。
    var safeInteger: Int? {
        guard case .number(let text) = self, let value = Double(text), value.isFinite, value == value.rounded(.towardZero),
              abs(value) <= 9007199254740991 else { return nil }
        return Int(value)
    }

    static func integer(_ value: Int) -> ETSFZJSONValue { .number(String(value)) }
}

struct ETSFZJSONMember: Equatable, Sendable {
    var key: String
    var value: ETSFZJSONValue
}

struct ETSFZJSONObject: Equatable, Sendable {
    var members: [ETSFZJSONMember] = []

    subscript(key: String) -> ETSFZJSONValue? {
        get { members.last { $0.key == key }?.value }
        set {
            if let at = members.firstIndex(where: { $0.key == key }) {
                if let value = newValue { members[at].value = value } else { members.remove(at: at) }
            } else if let value = newValue {
                members.append(ETSFZJSONMember(key: key, value: value))
            }
        }
    }
}

/// 一覧の 1 件。上流の entry。知っている鍵は型で、それ以外は fields に残る。
struct ETSFZLibraryIndexEntry: Equatable, Sendable {
    var fields: ETSFZJSONObject

    init(fields: ETSFZJSONObject) { self.fields = fields }

    /// 取り込みで作る 1 件。鍵の並びは上流の importFolderFiles / _storeStreamedSource と同じ。
    init(id: String, name: String, regionCount: Int, size: Int? = nil, fileCount: Int? = nil,
         streamedSource: Bool = false, importedAt: String? = nil, format: String? = nil) {
        var object = ETSFZJSONObject()
        object["id"] = .string(id)
        object["name"] = .string(name)
        object["regionCount"] = .integer(regionCount)
        if let size { object["size"] = .integer(size) }
        if let fileCount { object["fileCount"] = .integer(fileCount) }
        if streamedSource { object["streamedSource"] = .bool(true) }
        if let importedAt { object["importedAt"] = .string(importedAt) }
        if let format { object["format"] = .string(format) }
        fields = object
    }

    var id: String { fields["id"]?.stringValue ?? "" }
    var name: String { fields["name"]?.stringValue ?? "" }
    var regionCount: Int { fields["regionCount"]?.safeInteger ?? 0 }
    var size: Int? { fields["size"]?.safeInteger }
    var fileCount: Int? { fields["fileCount"]?.safeInteger }
    var importedAt: String? { fields["importedAt"]?.stringValue }
    var streamedSource: Bool { fields["streamedSource"]?.boolValue ?? false }
    /// "sf2" / "sf3"。SFZ には無い。
    var format: String? { fields["format"]?.stringValue }
}

struct ETSFZLibraryIndex: Equatable, Sendable {
    var entries: [ETSFZLibraryIndexEntry] = []
    /// version・entries 以外の上位の鍵（上流の今の版には無いが、あっても落とさない）。
    var otherFields = ETSFZJSONObject()

    init() {}

    /// 上流の open() と同じ確かめ。version が 1、entries が 10000 件以下で、各件は
    /// 鍵の形の id・文字の name・1 以上の安全な整数の regionCount、streamedSource は無いか真偽値。
    /// 合わなければ nil。UTF-8 の BOM は TextDecoder と同じく外す。
    init?(data: Data) {
        var bytes = [UInt8](data)
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { bytes.removeFirst(3) }
        guard String(data: Data(bytes), encoding: .utf8) != nil,
              case .object(let root)? = ETSFZJSONReader.parse(bytes),
              let version = root["version"], version.safeInteger == 1,
              case .array(let list)? = root["entries"], list.count <= 10000 else { return nil }
        var parsed: [ETSFZLibraryIndexEntry] = []
        for item in list {
            guard case .object(let fields) = item else { return nil }
            let entry = ETSFZLibraryIndexEntry(fields: fields)
            guard ETSFZLibraryBackend.isBankName(entry.id + ".sfzbank"), fields["id"]?.stringValue != nil,
                  fields["name"]?.stringValue != nil,
                  let count = fields["regionCount"]?.safeInteger, count >= 1 else { return nil }
            if let flag = fields["streamedSource"], flag.boolValue == nil { return nil }
            parsed.append(entry)
        }
        entries = parsed
        for member in root.members where member.key != "version" && member.key != "entries" { otherFields.members.append(member) }
    }

    /// 上流の JSON.stringify（空白なし）と同じ書き方。
    func serialized() -> Data {
        var root = ETSFZJSONObject()
        root["version"] = .integer(1)
        root["entries"] = .array(entries.map { .object($0.fields) })
        for member in otherFields.members { root[member.key] = member.value }
        var out = ""
        ETSFZJSONWriter.write(.object(root), into: &out)
        return Data(out.utf8)
    }

    /// 入れた後の一覧（同じ id を外して足し、id の順）。上流の importFolderFiles / _storeStreamedSource の並べ方。
    func upserting(_ entry: ETSFZLibraryIndexEntry) -> ETSFZLibraryIndex {
        var copy = self
        copy.entries = (entries.filter { $0.id != entry.id } + [entry]).sorted { $0.id < $1.id }
        return copy
    }

    func removing(id: String) -> ETSFZLibraryIndex {
        var copy = self
        copy.entries = entries.filter { $0.id != id }
        return copy
    }
}

// MARK: JSON の読み書き（上流の JSON.parse / JSON.stringify に合わせる最小限）

enum ETSFZJSONWriter {
    static func write(_ value: ETSFZJSONValue, into out: inout String) {
        switch value {
        case .null: out += "null"
        case .bool(let flag): out += flag ? "true" : "false"
        case .number(let text): out += text
        case .string(let text): writeString(text, into: &out)
        case .array(let items):
            out += "["
            for (at, item) in items.enumerated() {
                if at > 0 { out += "," }
                write(item, into: &out)
            }
            out += "]"
        case .object(let object):
            out += "{"
            for (at, member) in object.members.enumerated() {
                if at > 0 { out += "," }
                writeString(member.key, into: &out)
                out += ":"
                write(member.value, into: &out)
            }
            out += "}"
        }
    }

    /// JSON.stringify の字の逃がし方: " \ と制御文字だけ（U+2028 や DEL は逃がさない）。
    static func writeString(_ text: String, into out: inout String) {
        out += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        out += "\""
    }
}

enum ETSFZJSONReader {
    /// 全体が 1 つの値で、後ろに字が残らなければその値。深さは 64 まで。
    static func parse(_ bytes: [UInt8]) -> ETSFZJSONValue? {
        var reader = Reader(bytes: bytes)
        reader.skipSpace()
        guard let value = reader.value(depth: 0) else { return nil }
        reader.skipSpace()
        return reader.at == bytes.count ? value : nil
    }

    private struct Reader {
        let bytes: [UInt8]
        var at = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func skipSpace() {
            while at < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[at]) { at += 1 }
        }

        mutating func literal(_ word: String) -> Bool {
            let w = Array(word.utf8)
            guard at + w.count <= bytes.count, Array(bytes[at..<(at + w.count)]) == w else { return false }
            at += w.count
            return true
        }

        mutating func value(depth: Int) -> ETSFZJSONValue? {
            guard depth <= 64, at < bytes.count else { return nil }
            switch bytes[at] {
            case UInt8(ascii: "{"): return object(depth: depth)
            case UInt8(ascii: "["): return array(depth: depth)
            case UInt8(ascii: "\""): return string().map(ETSFZJSONValue.string)
            case UInt8(ascii: "t"): return literal("true") ? .bool(true) : nil
            case UInt8(ascii: "f"): return literal("false") ? .bool(false) : nil
            case UInt8(ascii: "n"): return literal("null") ? .null : nil
            default: return number()
            }
        }

        mutating func object(depth: Int) -> ETSFZJSONValue? {
            at += 1
            var result = ETSFZJSONObject()
            skipSpace()
            if at < bytes.count, bytes[at] == UInt8(ascii: "}") { at += 1; return .object(result) }
            while true {
                skipSpace()
                guard at < bytes.count, bytes[at] == UInt8(ascii: "\""), let key = string() else { return nil }
                skipSpace()
                guard at < bytes.count, bytes[at] == UInt8(ascii: ":") else { return nil }
                at += 1
                skipSpace()
                guard let member = value(depth: depth + 1) else { return nil }
                result[key] = member   // 同じ鍵は後のが勝つ（JSON.parse と同じ）。並びは最初の位置。
                skipSpace()
                guard at < bytes.count else { return nil }
                if bytes[at] == UInt8(ascii: ",") { at += 1; continue }
                if bytes[at] == UInt8(ascii: "}") { at += 1; return .object(result) }
                return nil
            }
        }

        mutating func array(depth: Int) -> ETSFZJSONValue? {
            at += 1
            var items: [ETSFZJSONValue] = []
            skipSpace()
            if at < bytes.count, bytes[at] == UInt8(ascii: "]") { at += 1; return .array(items) }
            while true {
                skipSpace()
                guard let item = value(depth: depth + 1) else { return nil }
                items.append(item)
                skipSpace()
                guard at < bytes.count else { return nil }
                if bytes[at] == UInt8(ascii: ",") { at += 1; continue }
                if bytes[at] == UInt8(ascii: "]") { at += 1; return .array(items) }
                return nil
            }
        }

        /// JSON の数の文法（-?(0|[1-9]\d*)(\.\d+)?([eE][+-]?\d+)?）。
        mutating func number() -> ETSFZJSONValue? {
            let start = at
            func digits(_ reader: inout Reader) -> Bool {
                let before = reader.at
                while reader.at < reader.bytes.count, reader.bytes[reader.at] >= 48, reader.bytes[reader.at] <= 57 { reader.at += 1 }
                return reader.at > before
            }
            if at < bytes.count, bytes[at] == UInt8(ascii: "-") { at += 1 }
            guard at < bytes.count else { return nil }
            if bytes[at] == 48 {
                at += 1
            } else if !digits(&self) {
                return nil
            }
            if at < bytes.count, bytes[at] == UInt8(ascii: ".") {
                at += 1
                guard digits(&self) else { return nil }
            }
            if at < bytes.count, bytes[at] == UInt8(ascii: "e") || bytes[at] == UInt8(ascii: "E") {
                at += 1
                if at < bytes.count, bytes[at] == UInt8(ascii: "+") || bytes[at] == UInt8(ascii: "-") { at += 1 }
                guard digits(&self) else { return nil }
            }
            return .number(String(decoding: bytes[start..<at], as: UTF8.self))
        }

        mutating func hex4() -> UInt32? {
            guard at + 4 <= bytes.count else { return nil }
            var value: UInt32 = 0
            for byte in bytes[at..<(at + 4)] {
                let digit: UInt32
                switch byte {
                case 48...57: digit = UInt32(byte) - 48
                case 97...102: digit = UInt32(byte) - 87
                case 65...70: digit = UInt32(byte) - 55
                default: return nil
                }
                value = value << 4 | digit
            }
            at += 4
            return value
        }

        mutating func string() -> String? {
            at += 1
            var raw: [UInt8] = []
            while at < bytes.count {
                let byte = bytes[at]
                at += 1
                switch byte {
                case UInt8(ascii: "\""):
                    return String(decoding: raw, as: UTF8.self)
                case 0..<0x20:
                    return nil
                case UInt8(ascii: "\\"):
                    guard at < bytes.count else { return nil }
                    let escape = bytes[at]
                    at += 1
                    switch escape {
                    case UInt8(ascii: "\""): raw.append(0x22)
                    case UInt8(ascii: "\\"): raw.append(0x5C)
                    case UInt8(ascii: "/"): raw.append(0x2F)
                    case UInt8(ascii: "b"): raw.append(0x08)
                    case UInt8(ascii: "f"): raw.append(0x0C)
                    case UInt8(ascii: "n"): raw.append(0x0A)
                    case UInt8(ascii: "r"): raw.append(0x0D)
                    case UInt8(ascii: "t"): raw.append(0x09)
                    case UInt8(ascii: "u"):
                        guard var code = hex4() else { return nil }
                        if (0xD800...0xDBFF).contains(code), at + 1 < bytes.count, bytes[at] == UInt8(ascii: "\\"),
                           bytes[at + 1] == UInt8(ascii: "u") {
                            let saved = at
                            at += 2
                            if let low = hex4(), (0xDC00...0xDFFF).contains(low) {
                                code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                            } else {
                                at = saved
                            }
                        }
                        // 対の無い片割れは Swift の String に入らないので U+FFFD にする。
                        let scalar = Unicode.Scalar(code) ?? "\u{FFFD}"
                        raw.append(contentsOf: Array(String(Character(scalar)).utf8))
                    default: return nil
                    }
                default:
                    raw.append(byte)
                }
            }
            return nil
        }
    }
}
