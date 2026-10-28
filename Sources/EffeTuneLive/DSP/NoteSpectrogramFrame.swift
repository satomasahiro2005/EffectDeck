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

// MARK: - 時間幅と列の数

enum ETNoteColumns {
    /// 時間の幅から、横幅いっぱいに並べる列の数。times は古い順の列の時刻（秒）。
    ///
    /// 列の間隔は一定ではないので、直近の間隔の**中央値**で割る。以前は溜まっている列全体の平均で割っていて、
    /// 背景に回した・再生を止めたなどで枠が届かなかった空白が平均に入り、間隔が大きく見えて列の数が減った
    /// （「N col」が短くなり、空白の列が流れ去るまで戻らなかった）。中央値なら空白が1つ入っても動かない。
    static func slots(forSpan span: Double, times: [Double], maxColumns: Int, window: Int = 64) -> Int {
        guard times.count > 1, span > 0 else { return maxColumns }
        var intervals: [Double] = []
        intervals.reserveCapacity(min(window, times.count - 1))
        var i = times.count - 1
        while i > 0 && intervals.count < window {
            let d = times[i] - times[i - 1]
            if d.isFinite && d > 0 { intervals.append(d) }
            i -= 1
        }
        guard !intervals.isEmpty else { return maxColumns }
        intervals.sort()
        let period = intervals[intervals.count / 2]
        return min(maxColumns, max(1, Int((span / period).rounded())))
    }
}
