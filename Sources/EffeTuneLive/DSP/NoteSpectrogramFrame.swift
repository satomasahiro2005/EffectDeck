//  NoteSpectrogramFrame.swift
//  Note Spectrogram（NoteSpectrogramPlugin）の枠の読み。画面（NoteSpectrogramView）は描くだけ。
//
//  **Foundation だけ。**ETFrame と数だけで済むので、実機なしで試せる（Tests/Unit/Upstream213Tests.swift）。
//
//  上流は plugins/analyzer/note_spectrogram.js の parseTelemetryFrame（:342-412）。
//
//  テレメトリ: frameType 24、formatVersion 5（2.13.0。2.12.0 までは 3、3548 バイト）。
//  dsp/plugins/analyzer/note_spectrogram/spectral_analysis.h の kRevisionAgeOffset 以下。
//
//  ペイロードの並び（8840 バイトちょうど）:
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
    static let version: UInt16 = 5
    static let confidenceOffset = 32
    static let levelOffset = confidenceOffset + pitches * 4
    static let revisedOffset = levelOffset + pitches * 4
    static let intermediateOffset = revisedOffset + pitches * 4
    static let revisionBytes = 4 + pitches * 4
    static let payloadBytes = intermediateOffset + 2 * revisionBytes

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

    init?(_ frame: ETFrame?) {
        guard let frame = frame, frame.type == ETNoteFrameLayout.frameType,
              frame.matches(version: ETNoteFrameLayout.version),
              frame.hasPayload(bytes: ETNoteFrameLayout.payloadBytes) else { return nil }

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

        sampleRate = Double(rate)
        time = Double(seconds)
        hopSeconds = Double(hop)
        frameIndex = index
        self.generation = generation
        confidence = fineConfidence
        level = fineLevel
        self.revisions = revisions
    }
}
