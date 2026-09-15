//  SpectrumAnalyzerView.swift
//  Spectrum Analyzer。横が周波数、縦は dB。いまの値の線と、ピーク保持の線。
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
//  （spectrum_analyzer.js:760）。
//
//  横軸の取り方は DSP へ送らない。上流も描く側だけで切り替えている
//  （spectrum_analyzer.js:211-217 の frequencyToX）。
//
//  ピークの落下は DSP 側でやっている（kernel.cpp:45 の 20 dB/秒）。
//  web 版は受け取ってからの経過ぶんも足して落としている（spectrum_analyzer.js:651-662）が、
//  こちらは枠が来た時点の値をそのまま描く。描き直しの間隔が web 版より粗いので、
//  間を補間しても嘘が増えるだけになる。

import SwiftUI
import Foundation

/// 横軸の取り方。上流の `sc`（spectrum_analyzer.js:24）に当たる。
/// DSP へは送らないので EffectCatalog には無い。
enum ETSpectrumScale: String, CaseIterable, Identifiable {
    case log
    case linear

    var id: String { rawValue }

    /// spectrum_analyzer.js:513-514 の label。
    var label: String {
        switch self {
        case .log:    return "Log"
        case .linear: return "Linear"
        }
    }
}

struct SpectrumAnalyzerView: View {

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    @Environment(\.etGraphOnly) private var graphOnly

    @State private var scale: ETSpectrumScale = .log

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SpectrumAnalyzerGraph(tapId: node.tapId, floorDB: floorDB, scale: scale)
            // 上流は DB Range・Points・Frequency Scale の順に並べている
            // （spectrum_analyzer.js:465-519）。同じ順にする。
            ForEach(node.spec.params) { param in
                if param.name == "points" {
                    if !graphOnly {
                        PointsRow(param: param, nodeIndex: index,
                                  values: node.values, dsp: dsp)
                    }
                } else {
                    ParameterRow(param: param, nodeIndex: index, values: node.values, dsp: dsp)
                }
            }
            if !graphOnly { scalePicker }
        }
    }

    /// spectrum_analyzer.js:510-519 の createRadioGroup に当たる。Menu にはしない。
    private var scalePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Frequency Scale")
                .font(.system(size: 14))
            HStack(spacing: 6) {
                ForEach(ETSpectrumScale.allCases) { option in
                    let isSelected = scale == option
                    Button {
                        scale = option
                    } label: {
                        Text(option.label)
                            .font(.system(size: 13, weight: isSelected ? .bold : .regular))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundStyle(isSelected ? AnyShapeStyle(.white)
                                                        : AnyShapeStyle(.secondary))
                            .frame(maxWidth: .infinity, minHeight: ETMetrics.hitTarget)
                            .background(isSelected ? AnyShapeStyle(.tint)
                                                   : AnyShapeStyle(.quaternary),
                                        in: .rect(cornerRadius: ETMetrics.innerRadius,
                                                  style: .continuous))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(option.label) frequency scale")
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// 縦の下端。params.json の dBRange（-144〜-48、既定 -96）。
    private var floorDB: Double {
        guard let param = node.spec.params.first(where: { $0.name == "dBRange" }),
              node.values.indices.contains(param.offset) else { return -96 }
        let v = Double(node.values[param.offset])
        guard v.isFinite else { return -96 }
        return min(-48, max(-144, v))
    }
}

// MARK: - Points の行

/// Points。上流は数値欄に指数でなく FFT の点数を出し、打ち込む方も点数で受ける
/// （spectrum_analyzer.js:479,483 の `pointsValue.value = 1 << this.pt`、
///   :490-501 の pointsValueHandler）。つまみだけ 8〜14 のまま（同 476）。
/// ParameterRow は EffectCatalog の値をそのまま出すので、この行だけ自前で持つ。
private struct PointsRow: View {

    let param: ETParam
    let nodeIndex: Int
    let values: [Float]
    @ObservedObject var dsp: EffeTuneDSP

    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    /// つまみの範囲。params.json は 8〜14。
    private var range: ClosedRange<Double> {
        guard case .number(let lo, let hi, _, _, _) = param.kind, hi > lo else { return 8...14 }
        return Double(lo)...Double(hi)
    }

    private var raw: Float {
        values.indices.contains(param.offset) ? values[param.offset] : param.defaultValue
    }

    /// 指数。範囲の外の値が来ても 1<<exponent が壊れないよう、丸めてから使う。
    private var exponent: Int {
        Int(min(max(Double(raw), range.lowerBound), range.upperBound).rounded())
    }

    private var fftSize: String { "\(1 << exponent)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(param.label)
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                field
            }
            Slider(value: Binding(
                get: { Double(raw) },
                set: { dsp.setValue(Float($0.rounded()), at: nodeIndex, offset: param.offset) }),
                   in: range, step: 1)
                .accessibilityLabel(param.label)
                .accessibilityValue(fftSize)
        }
        .padding(.vertical, 2)
    }

    /// 数値欄。ParameterRow の valueField と同じ作りにしてある。
    /// Text に替えるとボタンでもテキスト欄でもなくなり、支援技術から操作できない。
    private var field: some View {
        TextField(param.label, text: Binding(
            get: { editing ? draft : fftSize },
            set: { draft = $0 }))
            .keyboardType(.numbersAndPunctuation)
            .multilineTextAlignment(.center)
            .font(.system(size: 13, design: .monospaced))
            .focused($focused)
            .frame(width: ETMetrics.valueWidth, height: ETMetrics.controlHeight)
            .background(.quaternary,
                        in: .rect(cornerRadius: ETMetrics.innerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: ETMetrics.innerRadius, style: .continuous)
                        .stroke(.tint, lineWidth: editing ? 1 : 0))
            .submitLabel(.done)
            .onSubmit { commit() }
            .onChange(of: focused) { _, now in
                if now {
                    draft = fftSize
                    editing = true
                } else if editing {
                    // 他を触ってキーボードが引っ込んだときも確定させる。
                    commit()
                }
            }
            .accessibilityLabel(param.label)
            .accessibilityValue(fftSize)
    }

    /// 打ち込まれた点数を指数へ。上流 js:490-501 と同じで、一番近い 2 の冪に寄せ、
    /// 8〜14 の外なら何もしない（元の値に戻る）。
    private func commit() {
        editing = false
        focused = false
        guard let n = Double(draft.trimmingCharacters(in: .whitespaces)),
              n > 0, n.isFinite else { return }
        let e = Int(log2(n).rounded())
        guard e >= Int(range.lowerBound), e <= Int(range.upperBound) else { return }
        dsp.setValue(Float(e), at: nodeIndex, offset: param.offset)
    }
}

// MARK: - 図

/// 図の一番内側。**Telemetry を見るのはここだけ**にしてある。
/// カード全体で観測すると 30Hz で作り直されて、下のボタンが固まる。
private struct SpectrumAnalyzerGraph: View {

    let tapId: UInt32
    let floorDB: Double
    let scale: ETSpectrumScale

    @ObservedObject private var telemetry = Telemetry.shared

    /// 触った所の周波数（x）と dB（y）。
    @State private var probe: CGPoint?

    /// 横軸の端。上流は標本化周波数に関わらず 20Hz〜40kHz を描く
    /// （spectrum_analyzer.js:680,683 と :9-10 の定数）。
    /// Nyquist から上は bin が無いので、そのぶん右が空くだけになる。
    private static let floorHz: Double = 20
    private static let ceilingHz: Double = 40000

    /// 横線の間隔。狭い画面は 24dB（spectrum_analyzer.js:732、:671 の isNarrow）。
    private static let dbStep: Double = 24

    var body: some View {
        // 枠を解くのは 1 回だけ。指で触っている間も body は回る。
        let reading = self.reading
        return GraphCanvas(
            x: frequencyAxis,
            y: decibelAxis,
            height: ETGraphMetrics.height,
            // dB の字に単位が付いて 6 文字まで伸びるので、左を標準より広く取る。
            insets: ETGraphInsets(leading: 38, trailing: 8, top: 6, bottom: 14),
            readout: readout,
            caption: reading?.caption ?? "Waiting for audio",
            clipsContent: true,
            draw: { context, plot in
                // 枠が来ていない。値が無いことと -inf は違うので、線は描かない。
                guard let r = reading else { return }
                let bottom = plot.rect.maxY

                let columns = Self.columnize(r.current, hzPerBin: r.hzPerBin,
                                             plot: plot, floor: floorDB)
                if columns.count > 1 {
                    var path = Path()
                    for (i, column) in columns.enumerated() {
                        let pt = CGPoint(x: column.x, y: plot.y(column.db))
                        if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                    }
                    var area = path
                    area.addLine(to: CGPoint(x: columns[columns.count - 1].x, y: bottom))
                    area.addLine(to: CGPoint(x: columns[0].x, y: bottom))
                    area.closeSubpath()
                    context.fill(area, with: ETGraphShading.grid)
                    context.stroke(path, with: ETGraphShading.curve,
                                   style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                }

                // ピーク保持。薄い線で上に重ねる。
                let held = Self.columnize(r.peaks, hzPerBin: r.hzPerBin,
                                          plot: plot, floor: floorDB)
                if held.count > 1 {
                    var path = Path()
                    for (i, column) in held.enumerated() {
                        let pt = CGPoint(x: column.x, y: plot.y(column.db))
                        if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                    }
                    context.stroke(path, with: ETGraphShading.muted, lineWidth: 1)
                }

                // 触った所の縦線。
                if let p = probe {
                    var line = Path()
                    let x = plot.x(Double(p.x))
                    line.move(to: CGPoint(x: x, y: plot.rect.minY))
                    line.addLine(to: CGPoint(x: x, y: plot.rect.maxY))
                    context.stroke(line, with: ETGraphShading.axis,
                                   style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                }
            },
            overlay: { plot in
                // 触って値を読むだけなので、一覧の縦スクロールと同時に効かせる。
                Color.clear
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { touch in
                                guard let r = reading else { probe = nil; return }
                                let hz = plot.xAxis.clamp(plot.xValue(at: touch.location.x))
                                probe = CGPoint(x: hz, y: r.decibel(at: hz, floor: floorDB))
                            }
                            .onEnded { _ in probe = nil })
            })
    }

    // MARK: 軸

    /// spectrum_analyzer.js:700-713 の baseGridFreqs（狭い画面の並び）。
    /// 両端は線だけ引いて字を出さない（同 722 の
    /// `freq !== minDisplayFreq && freq !== maxDisplayFreq`）。
    private var frequencyAxis: ETAxis {
        let base: [Double] = scale == .linear
            ? [20, 10000, 20000, 30000, 40000]
            : [20, 100, 1000, 10000, 20000]
        var freqs = base.filter { $0 >= Self.floorHz && $0 <= Self.ceilingHz }
        if freqs.first != Self.floorHz { freqs.insert(Self.floorHz, at: 0) }
        if freqs.last != Self.ceilingHz { freqs.append(Self.ceilingHz) }
        let ticks = freqs.map { hz -> ETAxisTick in
            let edge = hz == Self.floorHz || hz == Self.ceilingHz
            return ETAxisTick(hz, edge ? nil : ETFormat.hzTick(hz))
        }
        return ETAxis(scale: scale == .linear ? .linear : .logarithmic,
                      lower: Self.floorHz, upper: Self.ceilingHz, ticks: ticks)
    }

    /// spectrum_analyzer.js:733-742。0 から dr まで 24dB 刻み。
    /// 上端と下端は線だけ。字には単位を付ける（同 741 の `${db}dB`）。
    private var decibelAxis: ETAxis {
        var ticks: [ETAxisTick] = []
        var db = 0.0
        while db >= floorDB - 0.0001 {
            let edge = abs(db) < 0.0001 || abs(db - floorDB) < 0.0001
            ticks.append(ETAxisTick(db, edge ? nil : "\(Int(db.rounded()))dB"))
            db -= Self.dbStep
        }
        return ETAxis(scale: .linear, lower: floorDB, upper: 0, ticks: ticks)
    }

    private var readout: [ETReadoutItem] {
        guard let p = probe else { return [] }
        return [ETReadoutItem("FREQ", ETFormat.hz(Double(p.x))),
                ETReadoutItem("LEVEL", ETFormat.db(Double(p.y)))]
    }

    // MARK: 描く前に畳む

    private struct Column {
        var x: CGFloat
        var db: Double
    }

    /// bin は数千本ある。画面は 300pt しかないので、1pt ごとに最大値だけ残す。
    /// 毎枠 8000 本ぶんの Path を作らない。bin は周波数の順に並んでいるので
    /// 1 度なめれば足りる（対数でも線形でも順は変わらない）。
    private static func columnize(_ values: [Float], hzPerBin: Double,
                                  plot: ETPlot, floor: Double) -> [Column] {
        guard !values.isEmpty, hzPerBin > 0 else { return [] }
        var out: [Column] = []
        out.reserveCapacity(Int(plot.rect.width) + 2)

        var bucket = Int.min
        var bestDB = floor
        var bestX: CGFloat = 0

        for i in 0..<values.count {
            let hz = Double(i) * hzPerBin
            guard hz >= floorHz else { continue }
            guard hz <= ceilingHz else { break }
            let x = plot.x(hz)
            guard x.isFinite else { continue }
            let slot = Int(x)
            let db = max(ETdB.finite(Double(values[i]), floor: floor), floor)
            if slot != bucket {
                if bucket != Int.min { out.append(Column(x: bestX, db: bestDB)) }
                bucket = slot
                bestDB = db
                bestX = x
            } else if db > bestDB {
                bestDB = db
                bestX = x
            }
        }
        if bucket != Int.min { out.append(Column(x: bestX, db: bestDB)) }
        return out
    }

    // MARK: 枠を読む

    private struct Reading {
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
    }

    private var reading: Reading? {
        guard let frame = telemetry.frame(tap: tapId, type: .spectrum),
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

        return Reading(sampleRate: Double(sampleRate), points: points,
                       current: current, peaks: peaks)
    }
}
