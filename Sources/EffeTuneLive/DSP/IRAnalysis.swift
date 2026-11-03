//  IRAnalysis.swift
//  IR Reverb の EDC（エネルギー減衰）グラフの数字。**Foundation だけ**で、単体テストに入る。
//
//  上流の写し元:
//    ir-preparation.js:287-338  analyze（包絡・EDC・RT60。L1 の上限と peakDb は図が使わないので写さない）
//    ir_reverb.js:1684-1717     getEdcGraphData（長さ・印の位置・RT60 の字）
//    ir_reverb.js:1787-1953     _drawEdcGraph（印の段・字の x・秒の目盛り）
//    ir_reverb.js:1955-1983     _readEdcGraph（指の位置の値）
//    plugins/graph-readout.js   seriesValueAt / format.time
//
//  描く部分（SwiftUI の Canvas）は Views/Effects/IRReverbDecayGraph.swift。字の幅を測るところ以外は
//  全部ここに出してあるので、Linux のテストで上流の答えと照合できる
//  （Tests/Unit/IRAnalysisTests.swift。見本は Tools/ir_analysis_golden.mjs が上流の JS で作る）。
//
//  --- 何から何を計算するか ---
//  上流は2本の線を描く。
//    Current   送った面（emitPreparedIr の channels）の解析。トポロジの選択と、カーネルに収めるための
//              切り詰め（末尾のフェード込み）の後。**カーネルが受け取った標本そのもの。**
//    Original  prepareIr の originalAnalysis（:367-373）。全部の面を、頭の無音・Direct Cut・
//              フェードイン・最初の利得まで済ませて、decay（dt）・trim（tr）・最後の利得の前に取ったもの。
//  後者の材料は ETIRPreparation.Prepared.originalChannels。

import Foundation

extension ETIRPreparation {
    /// 解析の点の数。上流の _prepareHostPcm / _createPreparedAsset が渡す 1600（ir_reverb.js:546, :567）。
    static let analysisPoints = 1600
}

// MARK: - 1本ぶんの解析

/// 上流の analyze が返す形のうち、図に使う分。
struct ETIRSeries: Equatable, Sendable {
    /// 解析した面の長さ（フレーム）。
    var frames: Int
    /// 各点の最初のフレーム。
    var sampleFrames: [Int]
    /// 各点の中の |標本| の最大（全部の面で）。
    var envelope: [Float]
    /// 各点のEDC（dB）。-120 で切る。
    var edcDb: [Float]
    var rt60Seconds: Double?
}

enum ETIRAnalysis {

    /// ir-preparation.js:287-338 の analyze。
    ///
    /// EDC は全部の面のΣx²を終わりから足していくSchroeder積分（computeEdc :156-165）。
    /// 各点 p は [floor(p·frames/n), floor((p+1)·frames/n)) の範囲で、EDC はその頭の値。
    /// frameEnergies と RT60 の推定は ETIRPreparation のものを使う（同じ式を2か所に持たない）。
    static func analyze(_ channels: [[Float]], sampleRate: Int,
                        pointLimit: Int = ETIRPreparation.analysisPoints) -> ETIRSeries {
        guard let frames = channels.first?.count, frames > 0, pointLimit > 0 else {
            return ETIRSeries(frames: 0, sampleFrames: [], envelope: [], edcDb: [], rt60Seconds: nil)
        }
        let pointCount = min(frames, pointLimit)

        let energies = ETIRPreparation.frameEnergies(channels, from: 0, gains: nil)
        var accumulated = [Double](repeating: 0, count: frames)
        var total = 0.0
        for frame in stride(from: frames - 1, through: 0, by: -1) {
            total += energies[frame]
            accumulated[frame] = total
        }

        var sampleFrames = [Int](repeating: 0, count: pointCount)
        var envelope = [Float](repeating: 0, count: pointCount)
        var edcDb = [Float](repeating: 0, count: pointCount)
        for point in 0..<pointCount {
            // 負にならないので整数の割り算がfloorと同じ。
            let start = point * frames / pointCount
            var end = (point + 1) * frames / pointCount
            if end <= start { end = start + 1 }
            var binPeak: Float = 0
            for channel in channels {
                channel.withUnsafeBufferPointer { x in
                    for frame in start..<min(end, frames) {
                        let magnitude = abs(x[frame])
                        if magnitude > binPeak { binPeak = magnitude }
                    }
                }
            }
            sampleFrames[point] = start
            envelope[point] = binPeak
            let ratio = total > 0 ? accumulated[start] / total : 0
            let decayDb = ratio > 0 ? 10 * log10(ratio) : -120
            edcDb[point] = Float(decayDb < -120 ? -120 : decayDb)
        }

        return ETIRSeries(frames: frames,
                          sampleFrames: sampleFrames,
                          envelope: envelope,
                          edcDb: edcDb,
                          rt60Seconds: ETIRPreparation.estimateRt60(channels, from: 0,
                                                                    sampleRate: Double(sampleRate),
                                                                    gains: nil))
    }

    // MARK: 指の位置の値

    /// graph-readout.js の seriesValueAt。昇順の xs を線形補間し、範囲の外と、非有限の隣は nil。
    /// 幅0の段は最初の値を取る。
    static func seriesValue(xs: [Int], ys: [Float], at x: Double) -> Double? {
        guard let first = xs.first, let last = xs.last, xs.count == ys.count else { return nil }
        guard x >= Double(first), x <= Double(last) else { return nil }
        var low = 0
        var high = xs.count - 1
        while high - low > 1 {
            let middle = (low + high) >> 1
            if Double(xs[middle]) <= x { low = middle } else { high = middle }
        }
        let x0 = Double(xs[low])
        let span = Double(xs[high]) - x0
        let t = span > 0 ? (x - x0) / span : 0
        let y0 = Double(ys[low])
        let y1 = t > 0 ? Double(ys[high]) : y0
        guard y0.isFinite, y1.isFinite else { return nil }
        return y0 + t * (y1 - y0)
    }

    /// graph-readout.js の format.time（符号は出さない。指の位置は0以上）。
    /// 枝は丸める前の値で決める（999.96 は「1000.0 ms」になり、「1.00 s」にはならない。上流の toFixed と同じ）。
    static func timeText(ms: Double) -> String {
        guard ms.isFinite else { return "—" }
        let magnitude = abs(ms)
        if magnitude < 10 { return String(format: "%.2f ms", magnitude) }
        if magnitude < 1000 { return String(format: "%.1f ms", magnitude) }
        return String(format: "%.2f s", magnitude / 1000)
    }

    // MARK: 字の位置

    /// ir_reverb.js:1906-1915 の drawMarkerLabel が決める x。
    /// px の右へ4pt、はみ出すなら左へ折り返し、最後に枠の中へ収める。
    static func markerLabelX(px: Double, textWidth: Double,
                             plotLeft: Double, plotRight: Double) -> Double {
        let plotWidth = max(1, plotRight - plotLeft)
        let measured = min(textWidth, plotWidth)
        var x = px + 4
        if x + measured > plotRight { x = px - measured - 4 }
        return max(plotLeft, min(x, plotRight - measured))
    }

    /// 1秒ごとの目盛り（:1840-1851）。1...floor(duration)。字が重なる分の間引きは
    /// 字の幅が要るので描く側が掛ける（px + w/2 + 4 >= 「Time」の左端なら飛ばす）。
    static func secondTicks(duration: Double) -> [Int] {
        let last = Int(duration.rounded(.down))
        return last >= 1 ? Array(1...last) : []
    }

    /// 印の字が入る段の数（ir_reverb.js:1795 の markerLabelRows）。
    static let markerLabelRows = 3
}

// MARK: - 図の材料

/// 解析に渡すもの。全部値で、裏のスレッドへそのまま渡せる。
struct ETIRGraphSource: Sendable {
    /// Prepared.originalChannels。
    var originalChannels: [[Float]]
    /// カーネルへ送った面（truncate の後）。
    var emittedChannels: [[Float]]
    /// 送ったレート（畳み込みのレート fc）。
    var sampleRate: Int
    var onsetFrame: Int
    var cutFrame: Int?
    var sourceStartFrame: Int
}

enum ETIRMarkerKind: Equatable, Sendable {
    case onset, cut, preDelay, trim, rt60
}

struct ETIRMarker: Equatable, Sendable {
    var kind: ETIRMarkerKind
    /// 位置（秒）。出さないものは nil。
    var seconds: Double?
}

/// getEdcGraphData の、pd と dc に依る部分。これらは解析し直さずに引き直せる。
struct ETIRGraphLayout: Equatable, Sendable {
    var duration: Double
    /// 上流の並び（onset, cut, predelay, trim, rt60）のまま。
    var markers: [ETIRMarker]
    var rt60Label: String

    /// 描く印と、その字を入れる段（ir_reverb.js:1893-1913）。
    /// 非有限・負・duration 超えは描かない。段は描いたものだけを数えて3で回す。
    var drawnMarkers: [(kind: ETIRMarkerKind, seconds: Double, row: Int)] {
        var row = 0
        var out: [(kind: ETIRMarkerKind, seconds: Double, row: Int)] = []
        for marker in markers {
            guard let seconds = marker.seconds, seconds.isFinite, seconds >= 0, seconds <= duration
            else { continue }
            out.append((marker.kind, seconds, row))
            row = (row + 1) % ETIRAnalysis.markerLabelRows
        }
        return out
    }

    /// RT60 の印を描かなかったとき、字だけを右端に出す段。描いたなら nil。
    var trailingRt60Row: Int? {
        let drawn = drawnMarkers
        if drawn.contains(where: { $0.kind == .rt60 }) { return nil }
        return drawn.count % ETIRAnalysis.markerLabelRows
    }

    /// 印の字。
    func label(_ kind: ETIRMarkerKind) -> String {
        switch kind {
        case .onset:    return "onset"
        case .cut:      return "cut"
        case .preDelay: return "pre-delay"
        case .trim:     return "trim"
        case .rt60:     return rt60Label
        }
    }
}

struct ETIRGraph: Equatable, Sendable {
    var sampleRate: Int
    /// 送った面の長さ（上流の _prepared.frames）。
    var frames: Int
    var original: ETIRSeries
    var current: ETIRSeries
    var onsetFrame: Int
    var cutFrame: Int?
    var sourceStartFrame: Int
    /// 包絡の塗りの縦位置（dB）。Current のピークで割る。ピークが0なら nil（塗らない）。
    /// 描く度の log10 を避けるため、ここで持つ（ir_reverb.js:1849-1862）。
    var envelopeDb: [Double]?

    /// 重い。**裏のスレッドで呼ぶこと**（ETIRGraphStore）。
    init(_ source: ETIRGraphSource) {
        sampleRate = source.sampleRate
        frames = source.emittedChannels.first?.count ?? 0
        original = ETIRAnalysis.analyze(source.originalChannels, sampleRate: source.sampleRate)
        current = ETIRAnalysis.analyze(source.emittedChannels, sampleRate: source.sampleRate)
        onsetFrame = source.onsetFrame
        cutFrame = source.cutFrame
        sourceStartFrame = source.sourceStartFrame
        let peak = current.envelope.reduce(Float(0)) { $1 > $0 ? $1 : $0 }
        if peak > 0 {
            envelopeDb = current.envelope.map { value in
                let magnitude = Double(value) / Double(peak)
                return magnitude > 0 ? 20 * log10(magnitude) : -90
            }
        } else {
            envelopeDb = nil
        }
    }

    /// ir_reverb.js:1684-1717 の getEdcGraphData（durationSeconds / markers / rt60Label）。
    /// pd（ms）と dc は生きた値で引く。pd はここだけに効き、解析は要らない（:270, :283）。
    func layout(preDelayMs: Double, directCut: Bool) -> ETIRGraphLayout {
        let fs = Double(sampleRate)
        let duration = max(Double(frames) / fs, Double(original.frames) / fs, preDelayMs / 1000, 0.001)
        let cut: Double? = (!directCut || cutFrame == nil)
            ? nil
            : Double(max(0, cutFrame! - sourceStartFrame)) / fs
        let markers = [
            ETIRMarker(kind: .onset, seconds: Double(max(0, onsetFrame - sourceStartFrame)) / fs),
            ETIRMarker(kind: .cut, seconds: cut),
            ETIRMarker(kind: .preDelay, seconds: preDelayMs / 1000),
            ETIRMarker(kind: .trim, seconds: Double(frames) / fs),
            ETIRMarker(kind: .rt60, seconds: current.rt60Seconds),
        ]
        let label: String
        if let rt60 = current.rt60Seconds, rt60.isFinite {
            label = String(format: "RT60 %.2f s", rt60)
        } else {
            label = "RT60 unavailable"
        }
        return ETIRGraphLayout(duration: duration, markers: markers, rt60Label: label)
    }

    /// 指の位置（秒）の Original と Current の EDC（dB）。ir_reverb.js:1955-1983。
    func readout(seconds: Double) -> (original: Double?, current: Double?) {
        let at = seconds * Double(sampleRate)
        return (ETIRAnalysis.seriesValue(xs: original.sampleFrames, ys: original.edcDb, at: at),
                ETIRAnalysis.seriesValue(xs: current.sampleFrames, ys: current.edcDb, at: at))
    }
}
