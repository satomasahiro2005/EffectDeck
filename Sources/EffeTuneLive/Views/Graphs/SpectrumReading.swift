//  SpectrumReading.swift
//  Spectrum Analyzer が出したテレメトリ枠を解いて、描ける形にする。
//
//  元は SpectrumAnalyzerView.swift の `private struct Reading` と `columnize` だった。
//  PEQ の図に重ねる側（SpectrumOverlayLayer）が同じ枠を読むので、こちらへ出した。
//  **門の中身は 1 行も変えていない。**
//
//  ペイロードの並び。dsp/plugins/analyzer/spectrum_analyzer/kernel.cpp:531-534 が頭を書き、
//  同 467-472 が本体を書く。plugins/analyzer/spectrum_analyzer.js:315-347 が同じ位置を読む:
//      0                f32 sampleRate     kernel.cpp:531 / spectrum_analyzer.js:315
//      4                u32 binCount       kernel.cpp:532 / spectrum_analyzer.js:316
//      8                u16 points         kernel.cpp:533 / spectrum_analyzer.js:317
//     10                u16 flags          kernel.cpp:534 / spectrum_analyzer.js:318
//                                          bit0 = 上の 3 本を削った印（kernel.cpp:24-25）
//     12 + bin*4        f32 current        kernel.cpp:468 / spectrum_analyzer.js:343
//     12 + (n+bin)*4    f32 peaks          kernel.cpp:469-471 / spectrum_analyzer.js:347
//  長さは 12 + binCount*8 ちょうど（spectrum_analyzer.js:335）。
//
//  current も peaks も dB で来る（kernel.cpp:450 の 10*log10(power) + correction）。
//  こちらで dB に直さない。

import Foundation
import CoreGraphics

// MARK: - 枠を解く

struct ETSpectrumReading {

    var sampleRate: Double
    var points: Int
    var current: [Float]
    var peaks: [Float]

    var fftSize: Int { 1 << points }

    /// bin の間隔。spectrum_analyzer.js:760 の (i * sampleRate) / fftSize。
    var hzPerBin: Double { sampleRate / Double(fftSize) }

    var caption: String {
        "FFT \(fftSize) · " + String(format: "%.1f kHz", sampleRate / 1000)
    }

    /// 周波数に一番近い bin の値。
    func decibel(at hz: Double, floor: Double) -> Double {
        guard hzPerBin > 0, !current.isEmpty else { return floor }
        let i = min(max(Int((hz / hzPerBin).rounded()), 0), current.count - 1)
        return ETdB.finite(Double(current[i]), floor: floor)
    }

    /// 1/12 オクターブで均した current。図に重ねるときだけ通す
    /// （Spectrum Analyzer 自身の図は上流も生の bin を描く）。
    var smoothedCurrent: [Float] { ETSpectrumSmoothing.twelfthOctave(decibels: current) }

    /// 枠が無い・版が違う・形が合わないものは nil。
    /// 0 を返して図を描くと「値が無い」と「値が 0」の区別がつかなくなる。
    init?(frame: ETFrame?) {
        guard let frame, frame.matches(version: 1) else { return nil }

        let payload = frame.payloadView
        guard let rate = payload.f32(at: 0),
              let rawBins = payload.u32(at: 4),
              let rawPoints = payload.u16(at: 8),
              let flags = payload.u16(at: 10) else { return nil }

        // spectrum_analyzer.js:319-335 と同じ門。
        guard rate.isFinite, rate > 0 else { return nil }
        let pts = Int(rawPoints)
        guard pts >= 8, pts <= 14, flags & ~UInt16(1) == 0 else { return nil }

        let binCount = Int(rawBins)
        let fullBinCount = (1 << pts) / 2 + 1
        let truncated = flags & 1 != 0
        if pts == 14 {
            // kernel.cpp:526-530。u16 に収めるため上の 3 本だけ落としてある。
            guard truncated, binCount == 8190, fullBinCount - binCount == 3 else { return nil }
        } else {
            guard !truncated, binCount == fullBinCount else { return nil }
        }

        guard binCount > 1, payload.count == 12 + binCount * 8,
              let cur = payload.floats(at: 12, count: binCount),
              let pk = payload.floats(at: 12 + binCount * 4, count: binCount) else { return nil }

        sampleRate = Double(rate)
        points = pts
        current = cur
        peaks = pk
    }
}

// MARK: - 描く前に畳む

/// 1pt ぶんの代表値。
struct ETSpectrumColumn {
    var x: CGFloat
    var db: Double
}

extension ETSpectrumReading {

    /// bin は数千本ある。画面は 300pt しかないので、1pt ごとに最大値だけ残す。
    /// 毎枠 8000 本ぶんの Path を作らない。bin は周波数の順に並んでいるので
    /// 1 度なめれば足りる（対数でも線形でも順は変わらない）。
    ///
    /// - Parameters:
    ///   - values: dB の並び。current でも peaks でも、均したあとの列でもよい。
    ///   - range: 描く周波数の範囲。図の軸と同じものを渡す。
    func columns(_ values: [Float], plot: ETPlot, floor: Double,
                 range: ClosedRange<Double>) -> [ETSpectrumColumn] {
        guard !values.isEmpty, hzPerBin > 0 else { return [] }
        var out: [ETSpectrumColumn] = []
        out.reserveCapacity(Int(plot.rect.width) + 2)

        var bucket = Int.min
        var bestDB = floor
        var bestX: CGFloat = 0

        for i in 0..<values.count {
            let hz = Double(i) * hzPerBin
            guard hz >= range.lowerBound else { continue }
            guard hz <= range.upperBound else { break }
            let x = plot.x(hz)
            guard x.isFinite else { continue }
            let slot = Int(x)
            let db = max(ETdB.finite(Double(values[i]), floor: floor), floor)
            if slot != bucket {
                if bucket != Int.min { out.append(ETSpectrumColumn(x: bestX, db: bestDB)) }
                bucket = slot
                bestDB = db
                bestX = x
            } else if db > bestDB {
                bestDB = db
                bestX = x
            }
        }
        if bucket != Int.min { out.append(ETSpectrumColumn(x: bestX, db: bestDB)) }
        return out
    }
}
