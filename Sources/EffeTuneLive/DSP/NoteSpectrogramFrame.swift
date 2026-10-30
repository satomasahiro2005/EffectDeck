//  NoteSpectrogramFrame.swift
//  Note Spectrogram（NoteSpectrogramPlugin）の枠の読み。画面（NoteSpectrogramView）は描くだけ。
//
//  **Foundation だけ。**ETFrame と数だけで済むので、実機なしで試せる（Tests/Unit/Upstream213Tests.swift）。
//
//  上流は plugins/analyzer/note_spectrogram.js の parseTelemetryFrame（:342-412）。
//
//  テレメトリ: frameType 24、formatVersion 6（2.14.0。9192 バイト。2.13.0 の 5 は 8840 バイトで、
//  末尾の音程のずれが無い。PC の 2.13.0 から写した枠も読めるように 5 も受ける）。
//  dsp/plugins/analyzer/note_spectrogram/spectral_analysis.h の kRevisionAgeOffset 以下。
//
//  ペイロードの並び（版 6 は 9192 バイトちょうど）:
//      0     f32 sampleRate
//      4     f32 timeSeconds
//      8     u16 pitchCount     440
//      10    u16 firstMidi      21
//      12    f32 hopSeconds
//      16    u32 frameIndex
//      20    u32 modeCode       5（1 半音の細分）
//      24    u32 generation     0 は無効
//      28    u32 revisionAge    0 か 8。下の 3552 の面の age
//      32    f32 × 440          確からしさ 0〜1
//      1792  f32 × 440          dB（床は -240）
//      3552  f32 × 440          8 枠前の確からしさの直し（age が 0 なら無い）
//      5312  u32 age + f32 × 440 at 5316   2 枠前の直し（age 0 か 2）
//      7076  u32 age + f32 × 440 at 7080   4 枠前の直し（age 0 か 4）
//      8840  f32 × 88           鍵ごとの音程のずれ（セント、版 6）
//  直しは frameIndex - age の枠の確からしさを置き換える（上流 _applyFrameRevision）。dB は直さない。

import Foundation

enum ETNoteFrameLayout {
    /// 88 鍵。note_spectrogram.js:6 の MULTI_F0_NOTE_COUNT。
    static let notes = 88
    /// 1 半音を割る数。同 :7 の MULTI_F0_FINE_DIVISIONS。
    static let divisions = 5
    /// 440。同 :9 の MULTI_F0_PITCH_COUNT。
    static let pitches = notes * divisions
    static let firstMidi = 21

    static let frameType: UInt16 = 24
    static let version: UInt16 = 6
    static let legacyVersion: UInt16 = 5
    static let confidenceOffset = 32
    static let levelOffset = confidenceOffset + pitches * 4
    static let revisedOffset = levelOffset + pitches * 4
    static let intermediateOffset = revisedOffset + pitches * 4
    static let revisionBytes = 4 + pitches * 4
    /// 版 5 の長さ（8840）。音程のずれはこの後ろ。
    static let legacyPayloadBytes = intermediateOffset + 2 * revisionBytes
    static let centsOffset = legacyPayloadBytes
    static let payloadBytes = centsOffset + notes * 4

    /// 直しの面。(age, age の位置, 確からしさの位置)。並びは上流の MULTI_F0_REVISION_PLANES（:20-24）。
    static let revisionPlanes: [(age: UInt32, ageOffset: Int, levelsOffset: Int)] = [
        (2, intermediateOffset, intermediateOffset + 4),
        (4, intermediateOffset + revisionBytes, intermediateOffset + revisionBytes + 4),
        (8, 28, revisedOffset),
    ]
    /// 一番古い直しの age。帯はこれより前の列を直さない。
    static let maximumRevisionAge: UInt32 = 8
}

extension ETNoteFrameLayout {
    /// 直しの当て先の列。最新（head の 1 つ前）から age + 1 列ぶんだけ遡って、枠の番号が合う列を探す。
    /// 枠の番号は UInt32 で折り返すので、index は呼ぶ側が `frameIndex &- age` で出す。
    /// 取りこぼした・もう流れた・世代が違うなら nil。
    static func revisionColumn(frames: [(generation: UInt32, index: UInt32)?], head: Int, count: Int,
                               generation: UInt32, index: UInt32) -> Int? {
        let columns = frames.count
        guard columns > 0 else { return nil }
        let reach = min(count, Int(maximumRevisionAge) + 1)
        guard reach > 0 else { return nil }
        for back in 1...reach {
            let column = ((head - back) % columns + columns) % columns
            if let frame = frames[column], frame.generation == generation, frame.index == index {
                return column
            }
        }
        return nil
    }
}

/// 前の枠の確からしさの直し。
struct ETNoteRevision {
    let age: UInt32
    let confidence: [Float]
}

/// 1 枠。
struct ETNoteSnapshot {

    let sampleRate: Double
    let time: Double
    let hopSeconds: Double
    let frameIndex: UInt32
    let generation: UInt32
    /// 細分ごとの確からしさ。440 個（note_spectrogram.js:373-384）。
    let confidence: [Float]
    /// 同じ並びの dB（床は -240）。
    let level: [Float]
    /// age 2・4・8 の直しのうち、この枠が運んでいるもの。
    let revisions: [ETNoteRevision]
    /// 鍵ごとの音程のずれ（セント、88 個）。版 5 の枠では全部 0。
    let pitchCents: [Float]

    init?(_ frame: ETFrame?) {
        guard let frame = frame, frame.type == ETNoteFrameLayout.frameType else { return nil }
        let current = frame.matches(version: ETNoteFrameLayout.version)
            && frame.hasPayload(bytes: ETNoteFrameLayout.payloadBytes)
        let legacy = frame.matches(version: ETNoteFrameLayout.legacyVersion)
            && frame.hasPayload(bytes: ETNoteFrameLayout.legacyPayloadBytes)
        guard current || legacy else { return nil }

        let payload = frame.payloadView
        guard let rate = payload.f32(at: 0),
              let seconds = payload.f32(at: 4),
              let pitchCount = payload.u16(at: 8),
              let firstMidi = payload.u16(at: 10),
              let hop = payload.f32(at: 12),
              let index = payload.u32(at: 16),
              let modeCode = payload.u32(at: 20),
              let generation = payload.u32(at: 24),
              let revisionAge = payload.u32(at: 28) else { return nil }

        // note_spectrogram.js:364-371 と同じ門。
        guard rate.isFinite, rate > 0, seconds.isFinite, seconds >= 0,
              pitchCount == UInt16(ETNoteFrameLayout.pitches),
              firstMidi == UInt16(ETNoteFrameLayout.firstMidi),
              hop.isFinite, hop > 0, modeCode == UInt32(ETNoteFrameLayout.divisions),
              generation != 0,
              revisionAge == 0 || revisionAge == ETNoteFrameLayout.maximumRevisionAge else { return nil }

        guard let fineConfidence = payload.floats(at: ETNoteFrameLayout.confidenceOffset,
                                                  count: ETNoteFrameLayout.pitches),
              let fineLevel = payload.floats(at: ETNoteFrameLayout.levelOffset,
                                             count: ETNoteFrameLayout.pitches)
            else { return nil }
        // 同 :375-384。1 つでも外れていたら枠ごと捨てる。
        for pitch in 0..<ETNoteFrameLayout.pitches {
            let value = fineConfidence[pitch]
            guard value.isFinite, value >= 0, value <= 1,
                  fineLevel[pitch].isFinite else { return nil }
        }
        // 同 :386-398。面の age は 0（無い）か決まった値だけ。直しの値も 0〜1。
        var revisions: [ETNoteRevision] = []
        for plane in ETNoteFrameLayout.revisionPlanes {
            guard let age = payload.u32(at: plane.ageOffset),
                  age == 0 || age == plane.age else { return nil }
            if age == 0 { continue }
            guard let values = payload.floats(at: plane.levelsOffset, count: ETNoteFrameLayout.pitches),
                  values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else { return nil }
            revisions.append(ETNoteRevision(age: age, confidence: values))
        }
        var cents = [Float](repeating: 0, count: ETNoteFrameLayout.notes)
        if current {
            guard let values = payload.floats(at: ETNoteFrameLayout.centsOffset, count: ETNoteFrameLayout.notes),
                  values.allSatisfy(\.isFinite) else { return nil }
            cents = values
        }

        sampleRate = Double(rate)
        time = Double(seconds)
        hopSeconds = Double(hop)
        frameIndex = index
        self.generation = generation
        confidence = fineConfidence
        level = fineLevel
        self.revisions = revisions
        pitchCents = cents
    }
}

// MARK: - 音色（2.14.0）

/// 音ごとの音色の知らせ（型 31・版 1・80 バイト）。上流 note_spectrogram.js の handleTimbreTelemetry。
///      0  f32 sampleRate / 4 f32 timeSeconds / 8 f32 hopSeconds
///     12  u32 generation（Note Spectrogram の枠と同じ世代のものだけ使う）
///     16  u32 frameIndex / 20 u32 noteId（0 は無効）/ 24 u32 midi（21〜108）
///     28  u32 event（1 = 始まり、2 = 判定、3 = 終わり）
///     32  u32 startFrameIndex / 36 u32 endFrameIndex（0xffffffff はまだ鳴っている）
///     40  f32 × 9 確からしさ（判定のときだけ。合計 1）/ 76 u32 0
struct ETNoteTimbreEvent: Equatable {
    enum Kind: UInt32 { case start = 1, result = 2, end = 3 }

    let generation: UInt32
    let frameIndex: UInt32
    let noteId: UInt32
    let midi: Int
    let kind: Kind
    let startFrameIndex: UInt32
    let endFrameIndex: UInt32
    /// 判定のときだけ。並びは ETNoteTimbre.classes。
    let probabilities: [Float]?

    static let frameType: UInt16 = 31
    static let byteCount = 80
    static let openEnd: UInt32 = 0xffff_ffff

    init?(_ frame: ETFrame) {
        guard frame.type == Self.frameType, frame.matches(version: 1),
              frame.hasPayload(bytes: Self.byteCount) else { return nil }
        let p = frame.payloadView
        guard let rate = p.f32(at: 0), let time = p.f32(at: 4), let hop = p.f32(at: 8),
              let generation = p.u32(at: 12), let frameIndex = p.u32(at: 16), let noteId = p.u32(at: 20),
              let midi = p.u32(at: 24), let code = p.u32(at: 28), let start = p.u32(at: 32),
              let end = p.u32(at: 36), let tail = p.u32(at: 76),
              rate.isFinite, rate > 0, time.isFinite, time >= 0, hop.isFinite, hop > 0,
              noteId != 0, midi >= 21, midi <= 108, let kind = Kind(rawValue: code), tail == 0,
              frameIndex &- start < 0x8000_0000 else { return nil }
        var probabilities: [Float]?
        if kind == .result {
            guard let values = p.floats(at: 40, count: 9),
                  values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }),
                  abs(values.reduce(0, +) - 1) <= 0.001 else { return nil }
            probabilities = values
        }
        self.generation = generation
        self.frameIndex = frameIndex
        self.noteId = noteId
        self.midi = Int(midi)
        self.kind = kind
        startFrameIndex = start
        endFrameIndex = end
        self.probabilities = probabilities
    }
}

/// 音色の分類と色（上流 MULTI_F0_TIMBRE_*）。
enum ETNoteTimbre {
    static let classes = ["Bass", "Guitar", "Piano", "Strings", "Wind", "Synth", "Organ", "Other", "Vocal"]
    static let colors: [(r: Double, g: Double, b: Double)] = [
        (76, 120, 184), (201, 154, 59), (143, 114, 199), (76, 155, 115), (70, 158, 168),
        (189, 111, 162), (166, 125, 96), (156, 156, 156), (214, 107, 94),
    ]
    /// まだ判定の無い音。
    static let unclassified: (r: Double, g: Double, b: Double) = (116, 116, 116)
    /// 判定が付いてから色へ移るまでの描き直しの回数。
    static let fadeSteps = 3

    /// Highlight の選択肢（値, 表示）。上流 MULTI_F0_HIGHLIGHTS。
    static let highlights: [(value: String, label: String)] =
        [("None", "None"), ("Vocal", "Vocal"), ("Bass", "Bass"), ("Other3", "Other (3)")]
        + classes[1...6].map { ($0, $0) } + [("Other9", "Other (9)")]

    /// 確からしさで混ぜた色（timbreColorMode = Probability）。3 分類では Bass と Vocal 以外を Other の色にする。
    static func color(_ p: [Float], threeClass: Bool) -> (r: Double, g: Double, b: Double) {
        var r = 0.0, g = 0.0, b = 0.0
        for category in 0..<9 {
            let c = colors[threeClass && category > 0 && category < 8 ? 7 : category]
            let w = Double(p[category])
            r += w * c.r; g += w * c.g; b += w * c.b
        }
        return (r, g, b)
    }

    /// その Highlight の確からしさ。Other3 は Bass と Vocal 以外の合計。
    static func highlightProbability(_ p: [Float]?, target: String) -> Double {
        guard let p else { return 0 }
        if target == "Other3" { return Double(p[1..<8].reduce(0, +)) }
        let name = target == "Other9" ? "Other" : target
        guard let index = classes.firstIndex(of: name) else { return 0 }
        return Double(p[index])
    }
}

// MARK: - 和音と調（2.16.0）

/// 和音と調の名前（上流 note_spectrogram.js の MULTI_F0_KEY_NOTE_NAMES、multiF0ChordName）。
enum ETNoteChordKey {
    /// 型 32・版 1・32 バイト。
    static let frameType: UInt16 = 32
    static let version: UInt16 = 1
    static let byteCount = 32
    /// 確定した和音は 11 枠（約 0.22 秒）遅れて届く。枠 F の確定は枠 F - 11 の列に付く（MULTI_F0_CHORD_CONFIRMED_LAG）。
    static let confirmedLag: UInt32 = 11
    static let suffixes = ["", "m", "dim", "aug", "maj7", "m7", "7", "dim7", "m7b5", "sus2", "sus4"]
    static let sharpNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    static let majorSignatures = [0, -5, 2, -3, 4, -1, 6, 1, -4, 3, -2, 5]

    /// 24 の調ごとの 12 音名。上流 :105-117 と同じ作り（♭ は U+266D、# は ASCII）。
    /// 臨時記号が最も少ない綴り。6 つの引き分けは # に倒す。
    static let keyNoteNames: [[String]] = (0..<24).map { key in
        let signature = majorSignatures[(key % 12 + (key < 12 ? 0 : 3)) % 12]
        let flat = signature < 0
        var names = flat
            ? ["C", "D\u{266D}", "D", "E\u{266D}", "E", "F", "G\u{266D}", "G", "A\u{266D}", "A", "B\u{266D}", "B"]
            : sharpNames
        let order = flat ? [11, 4, 9, 2, 7, 0, 5] : [5, 0, 7, 2, 9, 4, 11]
        for index in 0..<abs(signature) {
            let natural = order[index]
            names[(natural + (flat ? -1 : 1) + 12) % 12] = String(sharpNames[natural].prefix(1)) + (flat ? "\u{266D}" : "#")
        }
        return names
    }

    /// 調に合わせた音名。調が無い（nil・24 以上）なら # の綴り。
    static func noteNames(forKey key: Int?) -> [String] {
        guard let key, key >= 0, key < 24 else { return sharpNames }
        return keyNoteNames[key]
    }

    /// 枠が運ぶ (root, quality, bass) の名前。(255, 255, 255) は和音なし（""）。範囲外は nil。
    /// 表記は # の綴りで固定（保存はこの形、表示で調の綴りへ直す）。
    static func chordName(root: UInt8, quality: UInt8, bass: UInt8) -> String? {
        if root == 255 && quality == 255 && bass == 255 { return "" }
        guard root < 12, quality < UInt8(suffixes.count), bass < 12 else { return nil }
        let base = sharpNames[Int(root)] + suffixes[Int(quality)]
        return bass == root ? base : base + "/" + sharpNames[Int(bass)]
    }

    /// 「D♭ major」「B♭ minor」。24 以上は「—」。
    static func keyName(_ key: Int) -> String {
        guard key >= 0, key < 24 else { return "\u{2014}" }
        return keyNoteNames[key][key % 12] + (key < 12 ? " major" : " minor")
    }

    /// # の綴りの和音名を調の綴りに直す。**根音とスラッシュの後ろの音だけ**直し、接尾辞（m7b5 の b5）には触れない。
    static func displayChordName(_ canonical: String, names: [String]) -> String {
        guard names.count == 12, names != sharpNames, !canonical.isEmpty else { return canonical }
        func rename(_ note: String) -> String {
            guard let index = sharpNames.firstIndex(of: note) else { return note }
            return names[index]
        }
        /// 先頭の音名（A〜G と # 1 つ）と残り。
        func split(_ text: String) -> (note: String, rest: String) {
            guard let first = text.first, "ABCDEFG".contains(first) else { return ("", text) }
            let chars = Array(text)
            if chars.count > 1, chars[1] == "#" { return (String(chars[0..<2]), String(chars[2...])) }
            return (String(first), String(chars[1...]))
        }
        let parts = canonical.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let (root, suffix) = split(parts[0])
        var out = rename(root) + suffix
        if parts.count > 1 {
            let (note, rest) = split(parts[1])
            out += "/" + rename(note) + rest
        }
        return out
    }

    /// 音名 + オクターブ（「E♭4」）。
    static func noteName(midi: Int, names: [String]) -> String {
        let pitchClass = ((midi % 12) + 12) % 12
        let safe = names.count == 12 ? names : sharpNames
        return safe[pitchClass] + "\(midi / 12 - 1)"
    }

    /// 和音名から根音（0〜11）。""・読めないものは nil。
    static func root(of name: String) -> Int? {
        let chars = Array(name)
        guard let first = chars.first else { return nil }
        if chars.count > 1, chars[1] == "#", let index = sharpNames.firstIndex(of: String(chars[0..<2])) {
            return index
        }
        return sharpNames.firstIndex(of: String(first))
    }
}

/// 型 32 の 1 枠。上流の parseChordKeyTelemetryFrame（:455-476）と同じ門。
///      0 f32 sampleRate / 4 f32 timeSeconds / 8 f32 hopSeconds / 12 u32 generation / 16 u32 frameIndex
///     20,21,22 u8 いま届いた和音の root / quality / bass / 23,24,25 u8 確定した和音
///     26 u8 局所の調（0〜11 長調、12〜23 短調、24 なし、255 まだ）/ 27 u8 全体の調（0〜23、255 まだ）
///     28 f32 確定した和音の確からしさ
struct ETNoteChordKeyFrame: Equatable {
    let sampleRate: Double
    let time: Double
    let hopSeconds: Double
    let generation: UInt32
    let frameIndex: UInt32
    /// "" は和音なし。表記は # の綴り。
    let immediateName: String
    let confirmedName: String
    let confirmedRoot: Int?
    let localKey: Int?
    let overallKey: Int?
    let confirmedProbability: Float

    init?(_ frame: ETFrame) {
        guard frame.type == ETNoteChordKey.frameType, frame.matches(version: ETNoteChordKey.version),
              frame.hasPayload(bytes: ETNoteChordKey.byteCount) else { return nil }
        let p = frame.payload
        func u32(_ at: Int) -> UInt32 {
            UInt32(p[at]) | UInt32(p[at + 1]) << 8 | UInt32(p[at + 2]) << 16 | UInt32(p[at + 3]) << 24
        }
        func f32(_ at: Int) -> Float { Float(bitPattern: u32(at)) }
        let rate = f32(0), seconds = f32(4), hop = f32(8)
        guard rate.isFinite, rate > 0, seconds.isFinite, seconds >= 0, hop.isFinite, hop > 0 else { return nil }
        let generation = u32(12)
        guard generation != 0 else { return nil }
        guard let immediate = ETNoteChordKey.chordName(root: p[20], quality: p[21], bass: p[22]),
              let confirmed = ETNoteChordKey.chordName(root: p[23], quality: p[24], bass: p[25]) else { return nil }
        let local = p[26], overall = p[27]
        let probability = f32(28)
        guard local <= 24 || local == 255, overall <= 23 || overall == 255,
              probability.isFinite, probability >= 0, probability <= 1 else { return nil }
        sampleRate = Double(rate)
        time = Double(seconds)
        hopSeconds = Double(hop)
        self.generation = generation
        frameIndex = u32(16)
        immediateName = immediate
        confirmedName = confirmed
        confirmedRoot = confirmed.isEmpty ? nil : Int(p[23])
        localKey = local == 255 ? nil : Int(local)
        overallKey = overall == 255 ? nil : Int(overall)
        confirmedProbability = probability
    }
}

/// 列に付けた和音と調の覚え（上流 confirmedChords / localKey / overallKey）。Foundation だけなので試せる。
/// ETNoteBand が 1 つ持ち、列を書くたびに clearColumn、枠が来たら apply を呼ぶ。
struct ETNoteChordTrack {

    /// 描く和音の連なり。[start, end) は左から数えた列。
    struct Run: Equatable {
        let start: Int
        let end: Int
        let name: String
        let root: Int
    }

    let columns: Int
    /// nil はまだ分からない（描かない）。"" は和音なしと確定。それ以外は # の綴りの和音名。
    private(set) var chords: [String?]
    private(set) var localKey: Int?
    private(set) var overallKey: Int?
    private var lastFrameIndex: UInt32?

    init(columns: Int) {
        self.columns = columns
        chords = [String?](repeating: nil, count: columns)
    }

    /// 上流 clearChordKeyHistory。
    mutating func clear() {
        for i in chords.indices { chords[i] = nil }
        localKey = nil
        overallKey = nil
        lastFrameIndex = nil
    }

    /// 列を新しく書くとき。上流は書いた列の confirmedChords を null にする。
    mutating func clearColumn(_ column: Int) {
        guard chords.indices.contains(column) else { return }
        chords[column] = nil
    }

    /// 新しいか（UInt32 の折り返しを見る）。
    private static func newer(_ candidate: UInt32, than current: UInt32) -> Bool {
        let delta = candidate &- current
        return delta != 0 && delta < 0x8000_0000
    }

    /// 1 枠を当てる。上流 handleChordKeyTelemetry（:478-501）。何か変わったら true。
    /// frames は列ごとに入れた (世代, 枠の番号)、head は次に書く列、count は溜まっている列数。
    /// 確定した和音は 11 枠前の列のものなので、溜まっている列を全部探す（直しの 9 枠より深い）。
    mutating func apply(_ frame: ETNoteChordKeyFrame, activeGeneration: UInt32?,
                        frames: [(generation: UInt32, index: UInt32)?], head: Int, count: Int) -> Bool {
        guard frame.generation == activeGeneration else { return false }
        if let last = lastFrameIndex, !Self.newer(frame.frameIndex, than: last) { return false }
        let target = frame.frameIndex &- ETNoteChordKey.confirmedLag
        var changed = false
        let reach = min(count, min(columns, frames.count))
        if reach > 0 {
            for back in 1...reach {
                let column = ((head - back) % columns + columns) % columns
                guard let owner = frames[column], owner.generation == frame.generation,
                      owner.index == target else { continue }
                if chords[column] != frame.confirmedName {
                    chords[column] = frame.confirmedName
                    changed = true
                }
            }
        }
        if localKey != frame.localKey || overallKey != frame.overallKey { changed = true }
        localKey = frame.localKey
        overallKey = frame.overallKey
        lastFrameIndex = frame.frameIndex
        return changed
    }

    /// 左から数えて shown 列ぶん（start は輪の中の先頭の列）の和音の連なり。
    /// 同じ名前が続く間が 1 つ。nil か "" の列で切れ、同じ和音でも間を挟めば別の連なり（上流 previous = chord）。
    func runs(start: Int, shown: Int) -> [Run] {
        var out: [Run] = []
        var current: (start: Int, name: String)?
        func close(at end: Int) {
            guard let c = current else { return }
            if let root = ETNoteChordKey.root(of: c.name) {
                out.append(Run(start: c.start, end: end, name: c.name, root: root))
            }
            current = nil
        }
        for display in 0..<max(shown, 0) {
            let column = (start + display) % columns
            if let name = chords[column], !name.isEmpty {
                if let c = current, c.name == name { continue }
                close(at: display)
                current = (display, name)
            } else {
                close(at: display)
            }
        }
        close(at: max(shown, 0))
        return out
    }

    /// 左から数えた列の和音。
    func chord(displayColumn: Int, start: Int, shown: Int) -> String? {
        guard displayColumn >= 0, displayColumn < shown else { return nil }
        return chords[(start + displayColumn) % columns]
    }
}
