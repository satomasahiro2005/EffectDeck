//  SpectrumAnalyzerView.swift
//  Spectrum Analyzer。横は対数の周波数、縦は dB。いまの値の線と、ピーク保持の線。
//
//  テレメトリ: ETFrameType.spectrum = 4、formatVersion 1
//  （kernel.cpp:22-23 の kTapSpectrum / kTelemetryVersion、
//    spectrum_analyzer.js:1-2 の SPECTRUM_TAP_FRAME / _TELEMETRY_VERSION）
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
//
//  binCount は fftSize/2+1。ただし points=14 のときだけ payloadBytes が u16 に
//  収まらないので上の 3 本を落として 8190 本にしてある（kernel.cpp:526-528、
//  spectrum_analyzer.js:327-333 が fullBinCount - binCount === 3 を確かめている）。
//
//  bin の周波数は i * sampleRate / fftSize、fftSize = 1<<points
//  （spectrum_analyzer.js:759）。SpectrumGraph の .fft(sampleRate:) は
//  i * sr / (2 * 本数) を返す作りなので、本数が fftSize/2+1（または 8190）である
//  ぶんだけ sampleRate を割り増して渡し、式の値を一致させている（binScale）。
//
//  ピークの落下は DSP 側でやっている（kernel.cpp:45 の 20 dB/秒）。
//  web 版は受け取ってからの経過ぶんも足して落としている（spectrum_analyzer.js:651-662）が、
//  こちらは枠が来た時点の値をそのまま描く。描き直しの間隔が web 版より粗いので、
//  間を補間しても嘘が増えるだけになる。

import SwiftUI

struct SpectrumAnalyzerView: View {

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    @ObservedObject private var telemetry = Telemetry.shared

    /// 表示する周波数の上限。web 版は 40kHz まで引いている
    /// （spectrum_analyzer.js:10 の SPECTRUM_MAX_DISPLAY_FREQ）が、
    /// bin が無い所は空白になるだけなので、iPhone の幅では Nyquist で止める。
    private static let displayCeiling: Double = 40000
    private static let displayFloor: Double = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            graph
            ForEach(node.spec.params) { param in
                ParameterRow(param: param, nodeIndex: index, values: node.values, dsp: dsp)
            }
        }
    }

    @ViewBuilder private var graph: some View {
        if let r = reading {
            SpectrumGraph(decibels: r.current,
                          peaks: r.peaks,
                          bins: .fft(sampleRate: r.binScale),
                          frequencyRange: Self.displayFloor...r.displayTop,
                          decibelRange: floorDB...0,
                          style: .filled,
                          height: ETGraphMetrics.height,
                          caption: r.caption)
        } else {
            // 枠が来ていない。値が無いことと -inf は違うので、線は描かない。
            SpectrumGraph(decibels: [],
                          bins: .fft(sampleRate: 48000),
                          frequencyRange: Self.displayFloor...20000,
                          decibelRange: floorDB...0,
                          height: ETGraphMetrics.height,
                          caption: "Waiting for audio")
        }
    }

    /// 縦の下端。params.json の dBRange（-144〜-48、既定 -96）。
    private var floorDB: Double {
        guard let param = node.spec.params.first(where: { $0.name == "dBRange" }),
              node.values.indices.contains(param.offset) else { return -96 }
        let v = Double(node.values[param.offset])
        guard v.isFinite else { return -96 }
        return min(-48, max(-144, v))
    }

    // MARK: 枠を読む

    private struct Reading {
        var sampleRate: Double
        var points: Int
        var binCount: Int
        var current: [Float]
        var peaks: [Float]

        var fftSize: Int { 1 << points }

        /// SpectrumGraph の .fft(sampleRate:) に渡す値。
        /// あちらは i * value / (2 * 本数) を周波数とするので、
        /// i * sampleRate / fftSize と一致するよう割り増す。
        var binScale: Double {
            sampleRate * 2 * Double(binCount) / Double(fftSize)
        }

        /// Nyquist より上は bin が無いので、そこで軸を止める。
        var displayTop: Double {
            max(200, min(SpectrumAnalyzerView.displayCeiling, sampleRate * 0.5))
        }

        var caption: String {
            "FFT \(fftSize) · " + String(format: "%.1f kHz", sampleRate / 1000)
        }
    }

    private var reading: Reading? {
        guard let frame = telemetry.frame(tap: node.tapId, type: .spectrum),
              frame.matches(version: 1) else { return nil }

        let payload = frame.payloadView
        guard let sampleRate = payload.f32(at: 0),
              let rawBins = payload.u32(at: 4),
              let rawPoints = payload.u16(at: 8),
              let flags = payload.u16(at: 10) else { return nil }

        // spectrum_analyzer.js:319-335 と同じ門。
        guard sampleRate.isFinite, sampleRate > 0 else { return nil }
        let points = Int(rawPoints)
        guard points >= 8, points <= 14, flags & ~UInt16(1) == 0 else { return nil }

        let binCount = Int(rawBins)
        let fullBinCount = (1 << points) / 2 + 1
        let truncated = flags & 1 != 0
        if points == 14 {
            // kernel.cpp:526-530。u16 に収めるため上の 3 本だけ落としてある。
            guard truncated, binCount == 8190, fullBinCount - binCount == 3 else { return nil }
        } else {
            guard !truncated, binCount == fullBinCount else { return nil }
        }

        guard binCount > 1, payload.count == 12 + binCount * 8,
              let current = payload.floats(at: 12, count: binCount),
              let peaks = payload.floats(at: 12 + binCount * 4, count: binCount) else { return nil }

        return Reading(sampleRate: Double(sampleRate), points: points, binCount: binCount,
                       current: current, peaks: peaks)
    }
}
