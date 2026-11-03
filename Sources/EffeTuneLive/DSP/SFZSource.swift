//  SFZSource.swift
//  SFZ の字の読み方と、ファイルを持たない音（2.14.0）。**Foundation だけ。**
//
//  上流は js/sfz/source.js（decodeSfzText・readSfzBankDefines）と js/sfz/generators.js。
//  バンクの id は入れ物のバイト列から決まるので、どのファイルを入れ物に入れるか（bank.xml を含むか）まで
//  上流と同じにする（ETSFZService.importFolder）。

import Foundation

// MARK: - 作る音

/// `sample=*sine` などの、ファイルの代わりに作る 1 周期（ノイズは 8192 標本）の音。
enum ETSFZGenerator {

    static let names: Set<String> = ["*sine", "*saw", "*square", "*triangle", "*tri", "*noise", "*silence"]
    private static let periodFrames = 2048
    /// 1 周期 2048 標本を真ん中の C（MIDI 60）の高さで鳴らすレート。
    private static let periodRate = Int((440 * pow(2, Double(60 - 69) / 12) * Double(periodFrames)).rounded())

    static func isGenerator(_ sample: String) -> Bool { names.contains(sample) }

    /// 入れ物には入らない（大きさ 0）。予算の見積もりに使う。
    static func metadata(_ sample: String) -> ETSFZSampleInfo {
        ETSFZSampleInfo(size: 0, frames: sample == "*noise" ? 8192 : periodFrames, channels: 1)
    }

    static func sampleRate(_ sample: String) -> Int { sample == "*noise" ? 48000 : periodRate }

    static func pcm(_ sample: String) -> ETSFZPCM {
        let frames = metadata(sample).frames
        var pcm = [Float](repeating: 0, count: frames)
        // 決まった種の xorshift。保存したバンクと書き出しで同じ音になる。
        var noise: UInt32 = 0x53465A
        for frame in 0..<frames {
            let phase = Double(frame) / Double(frames)
            switch sample {
            case "*sine": pcm[frame] = Float(sin(2 * Double.pi * phase))
            case "*saw": pcm[frame] = Float(2 * phase - 1)
            case "*square": pcm[frame] = phase < 0.5 ? 1 : -1
            case "*triangle", "*tri": pcm[frame] = Float(1 - 4 * (phase < 0.5 ? 0.5 - phase : phase - 0.5))
            case "*noise":
                noise ^= noise << 13
                noise ^= noise >> 17
                noise ^= noise << 5
                pcm[frame] = Float(Double(noise) / 2_147_483_648 - 1)
            default: break
            }
        }
        return ETSFZPCM(channels: [pcm], sampleRate: sampleRate(sample))
    }
}

// MARK: - 字と bank.xml

enum ETSFZSource {

    /// UTF-8 として読めなければ windows-1252 で読む（decodeSfzText）。
    static func decodeText(_ bytes: Data) -> String {
        if let text = String(data: bytes, encoding: .utf8) { return text }
        return String(bytes.map { windows1252Scalar($0) }.map(Character.init))
    }

    /// WHATWG の windows-1252。0x80–0x9F の空き（0x81・0x8D・0x8F・0x90・0x9D）は同じ番号の制御文字。
    private static func windows1252Scalar(_ byte: UInt8) -> Unicode.Scalar {
        let table: [UInt32] = [
            0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
            0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F,
            0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
            0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178,
        ]
        let value = (0x80...0x9F).contains(byte) ? table[Int(byte) - 0x80] : UInt32(byte)
        return Unicode.Scalar(value)!
    }

    private static func directory(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // 決まった字面の式なので失敗しない。
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static let entities = ["amp": "&", "quot": "\"", "apos": "'", "lt": "<", "gt": ">"]

    /// タグの属性。名前は小文字に、値の実体参照（amp・quot・apos・lt・gt）は字に戻す。同じ名前は後の勝ち。
    private static func attributes(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        let ns = text as NSString
        let pattern = regex("\\b([a-z_]+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')")
        // 実体参照は大文字小文字を分ける（上流の式に i が無い）。
        let entity = try! NSRegularExpression(pattern: "&(amp|quot|apos|lt|gt);")
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let valueRange = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 3)
            var value = ns.substring(with: valueRange)
            let valueNS = value as NSString
            var output = ""
            var cursor = 0
            for m in entity.matches(in: value, range: NSRange(location: 0, length: valueNS.length)) {
                output += valueNS.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
                output += entities[valueNS.substring(with: m.range(at: 1))] ?? ""
                cursor = m.range.location + m.range.length
            }
            value = output + valueNS.substring(from: cursor)
            result[ns.substring(with: match.range(at: 1)).lowercased()] = value
        }
        return result
    }

    /// 選んだ SFZ に効く ARIA の bank.xml の `<Define>`（readSfzBankDefines）。
    ///
    /// 候補は選んだ SFZ の上にある bank.xml で、深いもの → 名前の順に見る。`<AriaElement path>` に選んだ SFZ が
    /// 載っていればそれ、載っていなくても同じフォルダに bank.xml が 1 つだけならそれを使う。
    /// `$sample_dir` が `$Banks/` から始まるときは、bank の隣の Samples を指す相対の道に替える。
    static func bankDefines(selectedPath: String, bankPaths: [String],
                            readText: (String) throws -> String?) throws -> (defines: [String: String], bankPath: String?) {
        let candidates = bankPaths
            .filter { directory($0).isEmpty || selectedPath.hasPrefix(directory($0) + "/") }
            .sorted { a, b in
                let da = directory(a).utf16.count, db = directory(b).utf16.count
                if da != db { return da > db }
                return a.compare(b, locale: Locale(identifier: "en")) == .orderedAscending
            }
        let ariaBank = regex("<AriaBank\\b")
        let tagPattern = regex("<(AriaElement|Define)\\b([^<>]*)>")
        let defineKey = regex("^\\$[a-z0-9_]+$")
        for path in candidates {
            guard let text = try readText(path) else { continue }
            let ns = text as NSString
            let whole = NSRange(location: 0, length: ns.length)
            guard ariaBank.firstMatch(in: text, range: whole) != nil else { continue }
            let folder = directory(path)
            let tags = tagPattern.matches(in: text, range: whole).map {
                (name: ns.substring(with: $0.range(at: 1)).lowercased(),
                 values: attributes(ns.substring(with: $0.range(at: 2))))
            }
            var registered = false
            for tag in tags where tag.name == "ariaelement" {
                guard let element = tag.values["path"] else { continue }
                if try ETSFZParser.normalizePath(element, directory: folder).lowercased() == selectedPath.lowercased() {
                    registered = true
                    break
                }
            }
            // 一覧に載っていない SFZ を同梱しているバンクもある。
            if !registered && candidates.filter({ directory($0) == folder }).count != 1 { continue }
            var defines: [String: String] = [:]
            for tag in tags where tag.name == "define" {
                guard let key = tag.values["name"], var value = tag.values["value"],
                      defineKey.firstMatch(in: key, range: NSRange(location: 0, length: (key as NSString).length)) != nil
                else { continue }
                if key == "$sample_dir" && value.hasPrefix("$Banks/") {
                    // ARIA の登録は、入れたバンクの隣の Samples フォルダを指す。
                    let source = Array(selectedPath.components(separatedBy: "/").dropLast())
                    let samples = try ETSFZParser.normalizePath("Samples", directory: folder).components(separatedBy: "/")
                    var common = 0
                    while common < source.count && common < samples.count && source[common] == samples[common] {
                        common += 1
                    }
                    value = String(repeating: "../", count: source.count - common)
                        + samples[common...].joined(separator: "/")
                }
                defines[key] = value
            }
            return (defines, path)
        }
        return ([:], nil)
    }

    /// 道が ARIA の bank.xml か。
    static func isBankPath(_ path: String) -> Bool { path.lowercased().hasSuffix(".bank.xml") }
}
