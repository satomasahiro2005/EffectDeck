//  SFZParser.swift
//  SFZ Note Player（SFZNotePlayerPlugin、2.13.0 で増えた）が読む SFZ の定義の解釈。
//  **Foundation だけ。**実機もエンジンも要らず、Linux でも走る（SFZTests）。
//
//  上流は js/sfz/parser.js。同じ並びで写した（#include と #define の展開、ヘッダ global / master / group / region、
//  音名、default_path、sw_default / set_ccNN による最初の状態、使えない条件つきの領域の除外）。
//  見本は上流のパーサに作らせてある（Tools/golden/sfz_golden.mjs → Tests/Fixtures/SFZ/sfz-golden.json）。
//
//  JS の文字列は UTF-16 の並び。長さや位置は utf16 で数える（上限の判定が上流と同じになる）。
//  並べ替えも JS の既定（UTF-16 の単位ごと）に揃える（jsLess）。

import Foundation

// MARK: - 誤り

enum ETSFZErrorCode: String {
    case prepare
    case tooLarge = "too-large"
    case noRegions = "no-regions"
    case storage
    case cancelled
}

struct ETSFZError: Error, Equatable, LocalizedError {
    var code: ETSFZErrorCode
    var message: String
    var errorDescription: String? { message }

    static func prepare(_ message: String) -> ETSFZError { ETSFZError(code: .prepare, message: message) }
    static func tooLarge(_ message: String) -> ETSFZError { ETSFZError(code: .tooLarge, message: message) }
}

// MARK: - 規則と小道具

enum ETSFZ {
    /// 上流の既定の上限（js/sfz/limits.js）。設定の画面は持たず、いつもこの値。
    static let defaultMaxBytes = 256 * 1024 * 1024
    /// カーネルが受けられる最大（sfz_note_player/bank.h の kCapacity）。
    static let maxSupportedBytes = 1024 * 1024 * 1024

    static func isValidMaxBytes(_ value: Int) -> Bool { value >= 1 && value <= maxSupportedBytes }

    /// 鍵（バンクの id）。sha256 の先頭 24 桁の小文字の 16 進。
    static func isValidID(_ id: String) -> Bool {
        id.utf8.count == 24 && id.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    /// JS の `a < b`（UTF-16 の単位ごとの比べ）。
    static func jsLess(_ a: String, _ b: String) -> Bool {
        var x = a.utf16.makeIterator()
        var y = b.utf16.makeIterator()
        while true {
            switch (x.next(), y.next()) {
            case (nil, nil): return false
            case (nil, _): return true
            case (_, nil): return false
            case let (l?, r?):
                if l != r { return l < r }
            }
        }
    }

    static func jsSorted(_ values: [String]) -> [String] { values.sorted(by: jsLess) }

    /// 音名か整数を MIDI 番号へ。読めなければ nan（上流の `midi`）。
    static func midi(_ value: String) -> Double {
        if matches(value, "^-?[0-9]+$") { return jsNumber(value) }
        guard let m = captures(value, "^([a-g])([#b]?)(-?[0-9]+)$", options: [.caseInsensitive]) else { return .nan }
        let pitch: [String: Int] = ["c": 0, "d": 2, "e": 4, "f": 5, "g": 7, "a": 9, "b": 11]
        guard let base = pitch[m[1].lowercased()], let octave = Double(m[3]) else { return .nan }
        return (octave + 1) * 12 + Double(base) + (m[2] == "#" ? 1 : (m[2] == "b" ? -1 : 0))
    }

    /// JS の `Number(string)` のうち、SFZ の値に現れる形。空白は落とし、空は 0、読めなければ nan。
    static func jsNumber(_ raw: String) -> Double {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return 0 }
        if matches(s, "^[+-]?([0-9]+\\.?[0-9]*|\\.[0-9]+)([eE][+-]?[0-9]+)?$") { return Double(s) ?? .nan }
        if matches(s, "^[+-]?Infinity$") { return s.hasPrefix("-") ? -.infinity : .infinity }
        if matches(s, "^0[xX][0-9a-fA-F]+$"), let v = UInt64(s.dropFirst(2), radix: 16) { return Double(v) }
        if matches(s, "^0[bB][01]+$"), let v = UInt64(s.dropFirst(2), radix: 2) { return Double(v) }
        if matches(s, "^0[oO][0-7]+$"), let v = UInt64(s.dropFirst(2), radix: 8) { return Double(v) }
        return .nan
    }

    static func matches(_ text: String, _ pattern: String, options: NSRegularExpression.Options = []) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return false }
        return regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    /// 最初の一致の全体と各群。一致しなければ nil。群が空なら ""。
    static func captures(_ text: String, _ pattern: String,
                         options: NSRegularExpression.Options = []) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }
}

// MARK: - 領域

/// 1 つの領域（`<region>`）。値は上流と同じく数（Double）。既定は parser.js の DEFAULTS。
struct ETSFZRegion: Equatable {
    var sample: String
    var seqGroup: Int
    var lokey = 0.0
    var hikey = 127.0
    var lovel = 1.0
    var hivel = 127.0
    var lorand = 0.0
    var hirand = 1.0
    var seq_length = 1.0
    var seq_position = 1.0
    var pitch_keycenter = 60.0
    var pitch_keytrack = 100.0
    var transpose = 0.0
    var tune = 0.0
    var volume = 0.0
    var pan = 0.0
    var amp_veltrack = 100.0
    var offset = 0.0
    var end: Double?
    var loop_mode = 0.0
    var loop_start = 0.0
    var loop_end: Double?
    var ampeg_attack = 0.0
    var ampeg_hold = 0.0
    var ampeg_decay = 0.0
    var ampeg_sustain = 100.0
    var ampeg_release = 0.001

    /// 名前で読む（資産の並びを順に引くのに使う）。無いものは nil。
    func value(_ key: String) -> Double? {
        switch key {
        case "lokey": return lokey
        case "hikey": return hikey
        case "lovel": return lovel
        case "hivel": return hivel
        case "lorand": return lorand
        case "hirand": return hirand
        case "seq_length": return seq_length
        case "seq_position": return seq_position
        case "seqGroup": return Double(seqGroup)
        case "pitch_keycenter": return pitch_keycenter
        case "pitch_keytrack": return pitch_keytrack
        case "transpose": return transpose
        case "tune": return tune
        case "volume": return volume
        case "pan": return pan
        case "amp_veltrack": return amp_veltrack
        case "offset": return offset
        case "end": return end
        case "loop_mode": return loop_mode
        case "loop_start": return loop_start
        case "loop_end": return loop_end
        case "ampeg_attack": return ampeg_attack
        case "ampeg_hold": return ampeg_hold
        case "ampeg_decay": return ampeg_decay
        case "ampeg_sustain": return ampeg_sustain
        case "ampeg_release": return ampeg_release
        default: return nil
        }
    }

    mutating func set(_ key: String, _ number: Double) {
        switch key {
        case "lokey": lokey = number
        case "hikey": hikey = number
        case "lovel": lovel = number
        case "hivel": hivel = number
        case "lorand": lorand = number
        case "hirand": hirand = number
        case "seq_length": seq_length = number
        case "seq_position": seq_position = number
        case "pitch_keycenter": pitch_keycenter = number
        case "pitch_keytrack": pitch_keytrack = number
        case "transpose": transpose = number
        case "tune": tune = number
        case "volume": volume = number
        case "pan": pan = number
        case "amp_veltrack": amp_veltrack = number
        case "offset": offset = number
        case "end": end = number
        case "loop_mode": loop_mode = number
        case "loop_start": loop_start = number
        case "loop_end": loop_end = number
        case "ampeg_attack": ampeg_attack = number
        case "ampeg_hold": ampeg_hold = number
        case "ampeg_decay": ampeg_decay = number
        case "ampeg_sustain": ampeg_sustain = number
        case "ampeg_release": ampeg_release = number
        default: break
        }
    }
}

/// 読み込みのとき出す知らせ（`{code, count}`）。
struct ETSFZWarning: Equatable {
    var code: String
    var count: Int
}

struct ETSFZDiagnostics: Equatable {
    var ignoredOpcodes: [String] = []
    var excludedOpcodes: [String] = []
    var missingSamples: [String] = []
    var invalidRegions: [String] = []

    var isEmpty: Bool {
        ignoredOpcodes.isEmpty && excludedOpcodes.isEmpty && missingSamples.isEmpty && invalidRegions.isEmpty
    }
}

struct ETSFZParseResult: Equatable {
    var regions: [ETSFZRegion]
    var dependencies: [String]
    var diagnostics: ETSFZDiagnostics
    var warnings: [ETSFZWarning]
}

/// 順序つきの対応（JS のオブジェクトの挿入順）。同じ鍵に入れ直すと位置はそのまま値だけ替わる。
/// **参照型にしてある。**`<global>` などは今の scope をそのまま持ち、後から入る鍵も見えなければならない
/// （上流は `global = scope` で同じオブジェクトを指す）。
private final class ETSFZScope {
    private(set) var keys: [String] = []
    private var values: [String: String] = [:]

    subscript(key: String) -> String? {
        get { values[key] }
        set {
            guard let newValue else { return }
            if values[key] == nil { keys.append(key) }
            values[key] = newValue
        }
    }

    var entries: [(key: String, value: String)] { keys.map { ($0, values[$0]!) } }

    /// `{...self, ...other}` の新しい写し。
    func merged(with other: ETSFZScope) -> ETSFZScope {
        let out = ETSFZScope()
        for (key, value) in entries { out[key] = value }
        for (key, value) in other.entries { out[key] = value }
        return out
    }
}

// MARK: - パーサ

enum ETSFZParser {

    static let maxIncludeVisits = 10000

    static let supported: Set<String> = [
        "sample", "key", "lokey", "hikey", "lovel", "hivel", "lorand", "hirand",
        "seq_length", "seq_position", "pitch_keycenter", "pitch_keytrack", "transpose",
        "tune", "volume", "pan", "amp_veltrack", "offset", "end", "loop_mode",
        "loop_start", "loop_end", "ampeg_attack", "ampeg_hold", "ampeg_decay",
        "ampeg_sustain", "ampeg_release",
    ]
    private static let loopModes: [String: Double] = [
        "no_loop": 0, "one_shot": 1, "loop_continuous": 2, "loop_sustain": 3,
    ]
    private static let noteKeys: Set<String> = ["key", "lokey", "hikey", "pitch_keycenter"]
    private static let integerKeys: Set<String> = [
        "lokey", "hikey", "lovel", "hivel", "seq_length", "seq_position",
        "pitch_keycenter", "transpose", "offset", "end", "loop_start", "loop_end",
    ]

    // MARK: 道

    /// 選んだフォルダの中に収まる道へ直す（normalizeSfzPath）。外へ出る・絶対の道は断る。
    static func normalizePath(_ value: String, directory: String = "") throws -> String {
        let path = value.replacingOccurrences(of: "\\", with: "/")
        if path.hasPrefix("/") || ETSFZ.matches(path, "^[a-z]:", options: [.caseInsensitive]) || path.contains("\0") {
            throw ETSFZError.prepare("SFZ references must stay inside the selected folder.")
        }
        var parts = directory.isEmpty ? [] : directory.components(separatedBy: "/")
        for part in path.components(separatedBy: "/") {
            if part.isEmpty || part == "." { continue }
            if part == ".." {
                if parts.isEmpty { throw ETSFZError.prepare("SFZ references must stay inside the selected folder.") }
                parts.removeLast()
            } else {
                parts.append(part)
            }
        }
        return parts.joined(separator: "/")
    }

    // MARK: 字面

    /// `//` と `/* */` を落とす。引用符の中は触らない。`//` は行末まで（改行は残す）、`/* */` は空白 1 つ。
    static func stripComments(_ text: String) -> String {
        let units = Array(text.utf16)
        let n = units.count
        let quote: UInt16 = 0x22, slash: UInt16 = 0x2F, star: UInt16 = 0x2A, newline: UInt16 = 0x0A
        var result: [UInt16] = []
        result.reserveCapacity(n)
        var quoted = false
        var index = 0
        while index < n {
            let char = units[index]
            let next: UInt16? = index + 1 < n ? units[index + 1] : nil
            if char == quote { quoted.toggle() }
            if !quoted && char == slash && next == slash {
                while index < n && units[index] != newline { index += 1 }
                result.append(newline)
            } else if !quoted && char == slash && next == star {
                index += 2
                while index < n && !(units[index] == star && index + 1 < n && units[index + 1] == slash) { index += 1 }
                index += 1
                result.append(0x20)
            } else {
                result.append(char)
            }
            index += 1
        }
        return String(decoding: result, as: UTF16.self)
    }

    private static func unquote(_ value: String) -> String {
        guard value.hasPrefix("\"") && value.hasSuffix("\"") else { return value }
        let units = Array(value.utf16)
        // 引用符 1 字だけの文字列は、両端が同じ 1 字なので空になる（JS の slice(1, -1)）。
        return units.count >= 2 ? String(decoding: units[1..<(units.count - 1)], as: UTF16.self) : ""
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 領域が使えない条件（CC・キースイッチ・トリガなど）か。
    private static func conditionalOpcode(_ key: String, _ value: String) -> Bool {
        if key == "trigger" { return value != "attack" }
        return ETSFZ.matches(key, "^(?:on_)?(?:lo|hi)(?:cc|hdcc|realcc|oncc|bend|chanaft|polyaft|prog|chan|timer|bpm)")
            || key.hasPrefix("sw_") || key == "sustain_sw" || key == "sostenuto_sw"
    }

    // MARK: 領域

    private static func normalizeRegion(_ raw: ETSFZScope, samplePath: String, seqGroup: Int) throws -> ETSFZRegion {
        var region = ETSFZRegion(sample: samplePath, seqGroup: seqGroup)
        for (key, value) in raw.entries {
            guard supported.contains(key), key != "sample" else { continue }
            let number: Double = key == "loop_mode" ? (loopModes[value] ?? .nan)
                : (noteKeys.contains(key) ? ETSFZ.midi(value) : ETSFZ.jsNumber(value))
            guard number.isFinite else { throw ETSFZError.prepare("Invalid SFZ opcode \(key).") }
            if key == "key" {
                region.lokey = number
                region.hikey = number
                region.pitch_keycenter = number
            } else {
                if integerKeys.contains(key) && number != number.rounded(.towardZero) {
                    throw ETSFZError.prepare("SFZ opcode \(key) must be an integer.")
                }
                region.set(key, number)
            }
        }
        if region.lovel == 0 { region.lovel = 1 }
        let times = [region.ampeg_attack, region.ampeg_hold, region.ampeg_decay, region.ampeg_release]
        if region.lokey < 0 || region.hikey > 127 || region.lokey > region.hikey
            || region.lovel < 1 || region.hivel > 127 || region.lovel > region.hivel
            || region.lorand < 0 || region.hirand > 1 || region.lorand > region.hirand
            || region.seq_length < 1 || region.seq_length > 16_777_216
            || region.seq_position < 1 || region.seq_position > region.seq_length
            || region.pitch_keycenter < 0 || region.pitch_keycenter > 127 || region.offset < 0
            || region.pitch_keytrack < -1200 || region.pitch_keytrack > 1200
            || region.transpose < -127 || region.transpose > 127 || region.tune < -1200 || region.tune > 1200
            || region.volume < -144 || region.volume > 144
            || region.pan < -100 || region.pan > 100 || region.amp_veltrack < -100 || region.amp_veltrack > 100
            || times.contains(where: { $0 < 0 || $0 > 100 })
            || region.ampeg_sustain < 0 || region.ampeg_sustain > 100 {
            throw ETSFZError.prepare("SFZ region contains an invalid parameter range.")
        }
        return region
    }

    // MARK: 読む

    /// 選んだ SFZ を読む。`readText` は道から本文（無ければ nil）、`hasSample` は道の音の有無。
    /// 上流は async。こちらは同じ順序の同期（読み込みは呼び手が別のスレッドで走らせる）。
    static func parse(selectedPath inputPath: String,
                      readText: (String) throws -> String?,
                      hasSample: ((String) -> Bool)? = nil,
                      maxBytes: Int = ETSFZ.defaultMaxBytes,
                      onDiagnostic: ((ETSFZDiagnostics) -> Void)? = nil) throws -> ETSFZParseResult {
        precondition(ETSFZ.isValidMaxBytes(maxBytes), "Invalid SFZ size limit.")
        let selectedPath = try normalizePath(inputPath)
        let directory = selectedPath.contains("/")
            ? String(selectedPath[..<selectedPath.lastIndex(of: "/")!]) : ""
        var dependencies = Set<String>()
        var defines: [String: String] = [:]
        var ignoredOpcodes = Set<String>(), excludedOpcodes = Set<String>()
        var missingSamples = Set<String>(), invalidRegions = Set<String>()
        var includeVisits = 0
        var sourceChars = 0
        var expandedChars = 0
        let tooLarge = { ETSFZError.tooLarge("The SFZ definition is too large to load.") }

        let defineKey = try NSRegularExpression(pattern: "\\$[a-z0-9_]+", options: [.caseInsensitive])
        func expandDefines(_ text: String) throws -> String {
            var length = text.utf16.count
            if length > maxBytes - expandedChars { throw tooLarge() }
            let ns = text as NSString
            var output = ""
            var cursor = 0
            for m in defineKey.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                output += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
                let key = ns.substring(with: m.range)
                let value = defines[key] ?? key
                length += value.utf16.count - key.utf16.count
                if length > maxBytes - expandedChars { throw tooLarge() }
                output += value
                cursor = m.range.location + m.range.length
            }
            output += ns.substring(from: cursor)
            expandedChars += length + 1
            if expandedChars > maxBytes { throw tooLarge() }
            return output
        }

        func expand(_ path: String, ancestors: [String]) throws -> String {
            if ancestors.contains(path) || ancestors.count >= 32 {
                throw ETSFZError.prepare("SFZ includes are recursive or too deep.")
            }
            // 読む前に、同じ定義やからの定義も含めて、訪問を数える。
            includeVisits += 1
            if includeVisits > maxIncludeVisits { throw tooLarge() }
            guard let text = try readText(path) else {
                throw ETSFZError.prepare("An SFZ include could not be found.")
            }
            sourceChars += text.utf16.count
            if sourceChars > maxBytes { throw tooLarge() }
            dependencies.insert(path)
            var output = ""
            var lines = stripComments(text).components(separatedBy: "\n")
            // 行の区切りは \r?\n。最後の行の \r は区切りの一部ではない。
            for i in lines.indices.dropLast() where lines[i].hasSuffix("\r") { lines[i].removeLast() }
            for line in lines {
                if let define = ETSFZ.captures(line, "^\\s*#define\\s+(\\$[a-z0-9_]+)\\s+(.+)$",
                                               options: [.caseInsensitive]) {
                    defines[define[1]] = try expandDefines(unquote(trimmed(define[2])))
                } else if let include = ETSFZ.captures(line, "^\\s*#include\\s+(.+)$", options: [.caseInsensitive]) {
                    let base = path.contains("/") ? String(path[..<path.lastIndex(of: "/")!]) : ""
                    let target = try normalizePath(unquote(try expandDefines(trimmed(include[1]))), directory: base)
                    output += try expand(target, ancestors: ancestors + [path])
                } else {
                    output += try expandDefines(line) + "\n"
                }
            }
            return output
        }

        let text = try expand(selectedPath, ancestors: [])
        let nsText = text as NSString
        let markerPattern = try NSRegularExpression(pattern: "<([a-z0-9_]+)>|([a-z0-9_]+)\\s*=",
                                                    options: [.caseInsensitive])
        let markers = markerPattern.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        var pending: [(raw: ETSFZScope, defaultPath: String, seqGroup: Int)] = []
        // CC の条件は sfizz と同じ初期値で固定する（この再生には CC の入力が無い）。
        var initialCC = [Int](repeating: 0, count: 128)
        initialCC[7] = 100
        initialCC[10] = 64
        initialCC[11] = 127
        let none = ETSFZScope()
        var global = none, master = none, group = none, scope = none
        var header = ""
        var defaultPath = ""
        var initialSwitch: Double?
        var seqGroup = 0
        func finishRegion() {
            guard header == "region" else { return }
            pending.append((global.merged(with: master).merged(with: group).merged(with: scope), defaultPath, seqGroup))
        }

        for (index, marker) in markers.enumerated() {
            let headerRange = marker.range(at: 1)
            if headerRange.location != NSNotFound {
                finishRegion()
                header = nsText.substring(with: headerRange).lowercased()
                scope = ETSFZScope()
                if header == "global" {
                    global = scope; master = ETSFZScope(); group = ETSFZScope(); seqGroup += 1
                } else if header == "master" {
                    master = scope; group = ETSFZScope(); seqGroup += 1
                } else if header == "group" {
                    group = scope; seqGroup += 1
                }
                continue
            }
            let key = nsText.substring(with: marker.range(at: 2)).lowercased()
            let valueStart = marker.range.location + marker.range.length
            let valueEnd = index + 1 < markers.count ? markers[index + 1].range.location : nsText.length
            let value = unquote(trimmed(nsText.substring(with: NSRange(location: valueStart,
                                                                         length: max(0, valueEnd - valueStart)))))
            if key == "sw_default" {
                let note = ETSFZ.midi(value)
                if note == note.rounded(.towardZero), note >= 0, note <= 127 { initialSwitch = note }
            }
            if header == "control" && key == "default_path" {
                defaultPath = value.replacingOccurrences(of: "\\", with: "/")
            } else if header == "control" && ETSFZ.matches(key, "^set_cc[0-9]{1,3}$")
                        && ETSFZ.jsNumber(String(key.dropFirst(6))) < 128 {
                let number = ETSFZ.jsNumber(value)
                guard number == number.rounded(.towardZero), number >= 0, number <= 127 else {
                    throw ETSFZError.prepare("Invalid SFZ opcode \(key).")
                }
                initialCC[Int(ETSFZ.jsNumber(String(key.dropFirst(6))))] = Int(number)
            } else if key == "key" {
                // 上流は `scope.lokey = scope.hikey = scope.pitch_keycenter = value`。連鎖の代入は右から
                // 評価されるので、挿入の順は pitch_keycenter → hikey → lokey（誤りに出る鍵の順に響く）。
                scope["pitch_keycenter"] = value
                scope["hikey"] = value
                scope["lokey"] = value
            } else if supported.contains(key) || key == "trigger" || conditionalOpcode(key, value) {
                scope[key] = value
            } else {
                ignoredOpcodes.insert(key)
            }
        }
        finishRegion()

        var regions: [ETSFZRegion] = []
        var invalidRegionCount = 0
        var unsupportedRegionCount = 0
        // control ヘッダは、位置によらず楽器の最初の状態を決める。
        for item in pending {
            let raw = item.raw
            do {
                var excluded: [String] = []
                for (key, value) in raw.entries {
                    if ["sw_default", "sw_lokey", "sw_hikey", "sw_label"].contains(key) { continue }
                    if key == "sw_last" {
                        if initialSwitch == nil || ETSFZ.midi(value) != initialSwitch! { excluded.append(key) }
                        continue
                    }
                    if let cc = ETSFZ.captures(key, "^(lo|hi)cc([0-9]{1,3})$"), ETSFZ.jsNumber(cc[2]) < 128 {
                        let bound = ETSFZ.jsNumber(value)
                        guard bound == bound.rounded(.towardZero), bound >= 0, bound <= 127 else {
                            throw ETSFZError.prepare("Invalid SFZ opcode \(key).")
                        }
                        let initial = initialCC[Int(ETSFZ.jsNumber(cc[2]))]
                        if cc[1] == "lo" ? Double(initial) < bound : Double(initial) > bound { excluded.append(key) }
                    } else if conditionalOpcode(key, value) {
                        excluded.append(key)
                    }
                }
                if !excluded.isEmpty {
                    for key in excluded { excludedOpcodes.insert(key) }
                    let unsupported = excluded.contains { key in
                        if key == "sw_last" { return initialSwitch == nil }
                        guard let cc = ETSFZ.captures(key, "^(?:lo|hi)cc([0-9]{1,3})$") else { return true }
                        return ETSFZ.jsNumber(cc[1]) >= 128
                    }
                    if unsupported { unsupportedRegionCount += 1 }
                    continue
                }
                guard let sampleValue = raw["sample"], !sampleValue.isEmpty else { continue }
                let sample = try normalizePath(item.defaultPath + unquote(sampleValue), directory: directory)
                let region = try normalizeRegion(raw, samplePath: sample, seqGroup: item.seqGroup)
                if let hasSample, !hasSample(sample) {
                    missingSamples.insert(sample)
                    continue
                }
                regions.append(region)
            } catch let error as ETSFZError where error.code == .prepare {
                invalidRegionCount += 1
                invalidRegions.insert("\(raw["sample"].flatMap { $0.isEmpty ? nil : $0 } ?? "(no sample)"): \(error.message)")
            }
        }

        let diagnostics = ETSFZDiagnostics(
            ignoredOpcodes: ETSFZ.jsSorted(Array(ignoredOpcodes)),
            excludedOpcodes: ETSFZ.jsSorted(Array(excludedOpcodes)),
            missingSamples: ETSFZ.jsSorted(Array(missingSamples)),
            invalidRegions: ETSFZ.jsSorted(Array(invalidRegions)))
        if !diagnostics.isEmpty { onDiagnostic?(diagnostics) }
        var warnings: [ETSFZWarning] = []
        if invalidRegionCount > 0 { warnings.append(ETSFZWarning(code: "invalid-regions", count: invalidRegionCount)) }
        if !missingSamples.isEmpty { warnings.append(ETSFZWarning(code: "missing-samples", count: missingSamples.count)) }
        if unsupportedRegionCount > 0 {
            warnings.append(ETSFZWarning(code: "unsupported-regions", count: unsupportedRegionCount))
        }
        return ETSFZParseResult(regions: regions, dependencies: ETSFZ.jsSorted(Array(dependencies)),
                                diagnostics: diagnostics, warnings: warnings)
    }
}
