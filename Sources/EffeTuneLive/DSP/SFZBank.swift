//  SFZBank.swift
//  SFZ Note Player の「バンク」: 選んだフォルダの SFZ と音のファイルを 1 つに詰めた入れ物と、その鍵。
//  **Foundation だけ**（鍵の sha256 は CryptoKit。Linux では Tests/Linux/Shims の代役）。
//
//  上流は js/sfz/bank.js と js/sfz/service.js（selectSfzRegionsForBudget・mergeSfzWarnings・representativeSfzText）。
//
//  入れ物（SFZ1）:
//      0   u32 magic 0x315a4653（"SFZ1"）
//      4   u32 版 1
//      8   u32 メタデータの長さ
//      12  メタデータ（UTF-8 の JSON）  {"selectedPath":…,"files":[{"path","offset","length"},…],"warnings"?:[{"code","count"}]}
//      …   ファイルの中身を道の順に詰めたもの（offset はこの部分の先頭から）
//  鍵は入れ物全体の sha256 の先頭 24 桁。**上流と同じ鍵にするため、JSON を 1 バイトも違えず書く**
//  （キーの順・空白無し・JSON.stringify の字の逃がし方）。そうすれば同じフォルダを PC の EffeTune と
//  こちらで取り込んだとき、同じ鍵になり、鎖の `sf` が互いを指せる。

import CryptoKit
import Foundation

/// 取り込んだ音のファイルの形（長さと幅は分かれば）。予算の見積りに使う。
struct ETSFZSampleInfo: Equatable {
    var size: Int
    var frames: Int = 0
    var channels: Int = 0
}

struct ETSFZDecodedBank {
    var selectedPath: String
    var warnings: [ETSFZWarning]
    /// 入れ物の全部。中身は `ranges` の範囲。
    var bytes: Data
    var ranges: [String: Range<Int>]

    func file(_ path: String) -> Data? {
        ranges[path].map { bytes.subdata(in: $0) }
    }
}

enum ETSFZBank {

    static let magic: UInt32 = 0x315A_4653
    static let warningCodes: Set<String> = [
        "invalid-regions", "missing-samples", "unsupported-regions", "reduced-bank", "loop-points-ignored",
    ]
    static let headerBytes = 12
    static let maxFiles = 10000

    // MARK: JSON（JSON.stringify と同じ字）

    /// JSON.stringify の文字列。" と \ と制御文字だけ逃がす（/ も非 ASCII も、U+2028 も逃がさない）。
    static func jsonString(_ value: String) -> String {
        var out = "\""
        for unit in value.unicodeScalars {
            switch unit {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if unit.value < 0x20 { out += String(format: "\\u%04x", unit.value) } else { out.unicodeScalars.append(unit) }
            }
        }
        return out + "\""
    }

    private static func metadataJSON(selectedPath: String, entries: [(path: String, offset: Int, length: Int)],
                                     warnings: [ETSFZWarning]) -> String {
        let files = entries.map { "{\"path\":\(jsonString($0.path)),\"offset\":\($0.offset),\"length\":\($0.length)}" }
        var json = "{\"selectedPath\":\(jsonString(selectedPath)),\"files\":[\(files.joined(separator: ","))]"
        if !warnings.isEmpty {
            let list = warnings.map { "{\"code\":\(jsonString($0.code)),\"count\":\($0.count)}" }
            json += ",\"warnings\":[\(list.joined(separator: ","))]"
        }
        return json + "}"
    }

    private static func ordered(_ files: [String: Data]) -> [(path: String, bytes: Data)] {
        files.keys.sorted(by: ETSFZ.jsLess).map { ($0, files[$0]!) }
    }

    // MARK: 書く・読む

    static func encode(selectedPath: String, files: [String: Data], maxBytes: Int = ETSFZ.defaultMaxBytes,
                       warnings: [ETSFZWarning] = []) throws -> Data {
        precondition(ETSFZ.isValidMaxBytes(maxBytes), "Invalid SFZ size limit.")
        let list = ordered(files)
        var offset = 0
        var entries: [(path: String, offset: Int, length: Int)] = []
        for (path, bytes) in list {
            entries.append((try ETSFZParser.normalizePath(path), offset, bytes.count))
            offset += bytes.count
        }
        let metadata = Data(metadataJSON(selectedPath: selectedPath, entries: entries, warnings: warnings).utf8)
        let size = headerBytes + metadata.count + offset
        if size > maxBytes { throw ETSFZError.tooLarge("The SFZ bank is too large to save.") }
        var out = Data(capacity: size)
        for value in [magic, 1, UInt32(metadata.count)] {
            withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        }
        out.append(metadata)
        for (_, bytes) in list { out.append(bytes) }
        return out
    }

    /// 入れ物に詰めたときの大きさの見積り（警告の欄を含まない）。
    static func estimateBytes(selectedPath: String, sizes: [String: Int]) throws -> Int {
        var offset = 0
        var entries: [(path: String, offset: Int, length: Int)] = []
        for path in sizes.keys.sorted(by: ETSFZ.jsLess) {
            entries.append((try ETSFZParser.normalizePath(path), offset, sizes[path]!))
            offset += sizes[path]!
        }
        return headerBytes + metadataJSON(selectedPath: selectedPath, entries: entries, warnings: []).utf8.count + offset
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base]) | UInt32(data[base + 1]) << 8 | UInt32(data[base + 2]) << 16 | UInt32(data[base + 3]) << 24
    }

    private static func safeInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let d = number.doubleValue
        guard d.isFinite, d == d.rounded(.towardZero), abs(d) <= 9_007_199_254_740_991 else { return nil }
        return Int(d)
    }

    static func decode(_ bytes: Data, maxBytes: Int = ETSFZ.defaultMaxBytes) throws -> ETSFZDecodedBank {
        precondition(ETSFZ.isValidMaxBytes(maxBytes), "Invalid SFZ size limit.")
        if bytes.count > maxBytes { throw ETSFZError.tooLarge("The SFZ bank is too large to load.") }
        guard bytes.count >= headerBytes else { throw ETSFZError.prepare("Invalid SFZ bank.") }
        let metadataLength = Int(u32(bytes, 8))
        guard u32(bytes, 0) == magic, u32(bytes, 4) == 1, metadataLength <= bytes.count - headerBytes else {
            throw ETSFZError.prepare("Invalid SFZ bank header.")
        }
        let metadataBytes = bytes.subdata(in: (bytes.startIndex + headerBytes)..<(bytes.startIndex + headerBytes + metadataLength))
        guard let text = String(data: metadataBytes, encoding: .utf8),
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let list = object["files"] as? [Any], list.count <= maxFiles else {
            throw ETSFZError.prepare("Invalid SFZ bank file list.")
        }
        var warnings: [ETSFZWarning] = []
        if let raw = object["warnings"] {
            guard let items = raw as? [[String: Any]], items.count <= warningCodes.count else {
                throw ETSFZError.prepare("Invalid SFZ bank load warnings.")
            }
            for item in items {
                guard let code = item["code"] as? String, warningCodes.contains(code),
                      let count = safeInt(item["count"]), count >= 1 else {
                    throw ETSFZError.prepare("Invalid SFZ bank load warnings.")
                }
                warnings.append(ETSFZWarning(code: code, count: count))
            }
        }
        var ranges: [String: Range<Int>] = [:]
        var expectedOffset = 0
        let payloadBytes = bytes.count - headerBytes - metadataLength
        for case let entry as [String: Any] in list {
            guard let rawPath = entry["path"] as? String else { throw ETSFZError.prepare("An SFZ file path is invalid.") }
            let path = try ETSFZParser.normalizePath(rawPath)
            guard ranges[path] == nil, safeInt(entry["offset"]) == expectedOffset,
                  let length = safeInt(entry["length"]), length >= 0,
                  expectedOffset + length <= payloadBytes else {
                throw ETSFZError.prepare("Invalid SFZ bank file range.")
            }
            let start = bytes.startIndex + headerBytes + metadataLength + expectedOffset
            ranges[path] = start..<(start + length)
            expectedOffset += length
        }
        if list.count != ranges.count { throw ETSFZError.prepare("Invalid SFZ bank file range.") }
        if expectedOffset != payloadBytes { throw ETSFZError.prepare("Invalid SFZ bank size.") }
        guard let selected = object["selectedPath"] as? String else { throw ETSFZError.prepare("An SFZ file path is invalid.") }
        let selectedPath = try ETSFZParser.normalizePath(selected)
        guard ranges[selectedPath] != nil else {
            throw ETSFZError.prepare("The SFZ bank has no selected instrument.")
        }
        return ETSFZDecodedBank(selectedPath: selectedPath, warnings: warnings, bytes: bytes, ranges: ranges)
    }

    /// 鍵。入れ物全体の sha256 の先頭 24 桁。
    static func identify(_ bytes: Data) -> String {
        String(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined().prefix(24))
    }

    // MARK: フォルダの道

    /// 選んだフォルダの道の一覧から、SFZ の道を並べて返す（listSfzFolderFiles）。
    /// 道は正規化し、同じ道が 2 つあるか 10000 を越えれば断る。
    static func folderSFZPaths(_ rawPaths: [String]) throws -> [String] {
        guard rawPaths.count <= maxFiles else { throw ETSFZError.prepare("The SFZ folder contains too many files.") }
        var seen = Set<String>()
        for raw in rawPaths {
            let path = try ETSFZParser.normalizePath(raw)
            if path.isEmpty || !seen.insert(path).inserted {
                throw ETSFZError.prepare("The SFZ folder contains duplicate file paths.")
            }
        }
        return ETSFZ.jsSorted(seen.filter { ETSFZ.matches($0, "\\.sfz$", options: [.caseInsensitive]) })
    }

    // MARK: 警告

    /// 同じ code の count は大きいほうを取る（保存した定義を読み直しても二重に数えない）。code の順。
    static func mergeWarnings(_ groups: [ETSFZWarning]...) -> [ETSFZWarning] {
        var counts: [String: Int] = [:]
        for group in groups { for w in group { counts[w.code] = max(counts[w.code] ?? 0, w.count) } }
        return ETSFZ.jsSorted(Array(counts.keys)).map { ETSFZWarning(code: $0, count: counts[$0]!) }
    }

    // MARK: 予算に収める

    struct Selection: Equatable {
        var regions: [ETSFZRegion]
        var reduced: Bool
        var velocity: Int?
        var keyCount: Int?
    }

    /// 領域が予算（生のバイトと、送るときの大きさ）に収まらないとき、全ての鍵を残したまま、鍵ごとに
    /// 代表の 1 領域だけにして収める（selectSfzRegionsForBudget）。収まらなければ too-large。
    static func selectRegionsForBudget(_ regions: [ETSFZRegion], metadata: [String: ETSFZSampleInfo],
                                       maxBytes: Int, definitionBytes: Int = 0) throws -> Selection {
        func fits(_ candidate: [ETSFZRegion]) -> Bool {
            let paths = Set(candidate.map(\.sample))
            var rawBytes = definitionBytes
            var decodedBytes = 0
            for path in paths {
                guard let info = metadata[path] else { return false }
                rawBytes += info.size
                decodedBytes += info.frames * info.channels * 4
            }
            let groups = Set(candidate.map(\.seqGroup)).count
            let indexEntries = candidate.reduce(0) { $0 + Int($1.hikey - $1.lokey) + 1 }
            let footprint = 64 + 4 * ETSFZAsset.regionFields.count * candidate.count + decodedBytes
                + 4 * (129 + 2 * groups + indexEntries)
            return rawBytes <= maxBytes && footprint <= maxBytes
        }
        if fits(regions) { return Selection(regions: regions, reduced: false) }
        var byKey = [[Int]](repeating: [], count: 128)
        var originalKeys = Set<Int>()
        for (i, region) in regions.enumerated() {
            let info = metadata[region.sample]
            guard region.lokey <= region.hikey else { continue }
            for key in Int(region.lokey)...Int(region.hikey) {
                originalKeys.insert(key)
                if let info, info.frames > 0, info.channels > 0, info.channels <= 2 { byKey[key].append(i) }
            }
        }
        let keyCount = byKey.filter { !$0.isEmpty }.count
        if keyCount == 0 || keyCount != originalKeys.count {
            throw ETSFZError.tooLarge("The SFZ cannot fit its playable note range.")
        }
        // どの MIDI ベロシティでも試す。真ん中（64）に近い順。鍵は全部残し、鍵ごとに代表を 1 つ。
        let velocities: [Int] = Array(1...127).sorted { (a: Int, b: Int) -> Bool in
            let da = abs(a - 64)
            let db = abs(b - 64)
            return da != db ? da < db : a < b
        }
        for velocity in velocities {
            var selected: [(source: Int, region: ETSFZRegion)] = []
            for key in 0..<byKey.count {
                var best: Int?
                var bestDistance = Double.infinity
                var bestBytes = Double.infinity
                for i in byKey[key] {
                    let region = regions[i]
                    let v = Double(velocity)
                    let distance = v < region.lovel ? region.lovel - v : (v > region.hivel ? v - region.hivel : 0)
                    let info = metadata[region.sample]!
                    let bytes = Double(info.frames * info.channels * 4)
                    if distance < bestDistance || (distance == bestDistance && bytes < bestBytes) {
                        best = i
                        bestDistance = distance
                        bestBytes = bytes
                    }
                }
                guard let best else { continue }
                if let previous = selected.last, previous.source == best, previous.region.hikey == Double(key - 1) {
                    selected[selected.count - 1].region.hikey = Double(key)
                } else {
                    var region = regions[best]
                    region.lokey = Double(key)
                    region.hikey = Double(key)
                    region.lovel = 1
                    region.hivel = 127
                    region.lorand = 0
                    region.hirand = 1
                    region.seq_length = 1
                    region.seq_position = 1
                    selected.append((best, region))
                }
            }
            let candidate = selected.map(\.region)
            if fits(candidate) {
                return Selection(regions: candidate, reduced: true, velocity: velocity, keyCount: keyCount)
            }
        }
        throw ETSFZError.tooLarge("The SFZ cannot fit its playable note range.")
    }

    /// 縮めたバンクに入れる代わりの SFZ（representativeSfzText）。領域ごとに 1 行。
    static func representativeText(_ regions: [ETSFZRegion], selectedPath: String) -> String {
        let root = String(repeating: "../", count: selectedPath.components(separatedBy: "/").count - 1)
        let loopModes = ["no_loop", "one_shot", "loop_continuous", "loop_sustain"]
        return regions.map { region in
            let fields = ETSFZAsset.regionFields.dropFirst(4).filter { $0 != "seqGroup" }.compactMap { key -> String? in
                guard let value = region.value(key) else { return nil }
                let text = key == "loop_mode" ? loopModes[Int(value)] : jsNumberString(value)
                return "\(key)=\(text)"
            }
            return "<region> sample=" + jsonString(root + region.sample) + " " + fields.joined(separator: " ")
        }.joined(separator: "\n")
    }

    /// JS の `${number}`（Number.prototype.toString）。
    static func jsNumberString(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value == 0 { return "0" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        if value < 0 { return "-" + jsNumberString(-value) }
        // Swift の description は最短の往復する桁を出す（JS と同じ桁）。桁と小数点の位置に分ける。
        var text = "\(value)"
        var exponent = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exponent = Int(text[text.index(after: e)...].replacingOccurrences(of: "+", with: "")) ?? 0
            text = String(text[..<e])
        }
        var digits = text
        var pointAt = text.count
        if let dot = text.firstIndex(of: ".") {
            pointAt = text.distance(from: text.startIndex, to: dot)
            digits = text.replacingOccurrences(of: ".", with: "")
        }
        // 先頭の 0 を落とし、小数点の位置を詰める。
        while digits.hasPrefix("0") && digits.count > 1 { digits.removeFirst(); pointAt -= 1 }
        while digits.hasSuffix("0") && digits.count > 1 { digits.removeLast() }
        let n = pointAt + exponent
        let k = digits.count
        if k <= n && n <= 21 { return digits + String(repeating: "0", count: n - k) }
        if 0 < n && n <= 21 { return String(digits.prefix(n)) + "." + String(digits.dropFirst(n)) }
        if -6 < n && n <= 0 { return "0." + String(repeating: "0", count: -n) + digits }
        let e = n - 1
        let sign = e < 0 ? "-" : "+"
        if k == 1 { return digits + "e" + sign + String(abs(e)) }
        return String(digits.prefix(1)) + "." + String(digits.dropFirst()) + "e" + sign + String(abs(e))
    }
}
