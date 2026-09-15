//  OscilloscopeView.swift
//  Oscilloscope。横が時間、縦が振幅。トリガで切り出した 1 掃引ぶんの波形。
//
//  テレメトリ: ETFrameType.scopeSnapshot = 3、formatVersion 2
//  （kernel.cpp:12-13 の kTapScopeSnapshot / kTelemetryVersion、
//    oscilloscope.js:552-553 付近の parseDspScopeTelemetryFrame）
//
//  ペイロードの頭。dsp/plugins/analyzer/oscilloscope/kernel.cpp:228-235 が書き、
//  plugins/analyzer/oscilloscope.js:565-570 が同じ位置を読む:
//      0   f32 sampleRate          kernel.cpp:229 / oscilloscope.js:565
//      4   u32 captureSampleCount  kernel.cpp:230 / oscilloscope.js:566
//      8   u32 triggerOffset       kernel.cpp:231（常に 0）/ oscilloscope.js:567
//     12   u16 bucketCount         kernel.cpp:232 / oscilloscope.js:568
//     14   u8  encoding            kernel.cpp:233 / oscilloscope.js:569  0=raw 1=M4
//     15   u8  flags               kernel.cpp:234 / oscilloscope.js:570  bit0 = 実トリガ
//
//  本体は 2 通りある（kernel.cpp:237-277 / oscilloscope.js:578-655）:
//    raw（標本 2048 本以下、kernel.cpp:16 の kMaxRawSamples）
//      16 + i*4   f32 sample
//      長さは 16 + captureSampleCount*4 ちょうど（oscilloscope.js:580）
//    M4（それより長いとき。512 の桶に畳んである、kernel.cpp:17）
//      16 + b*18      f32 first    桶の先頭の標本       kernel.cpp:268
//      16 + b*18 + 4  f32 minimum  桶の中の最小         kernel.cpp:269
//      16 + b*18 + 8  f32 maximum  桶の中の最大         kernel.cpp:270
//      16 + b*18 + 12 f32 last     桶の末尾の標本       kernel.cpp:271
//      16 + b*18 + 16 u8  minimum の桶内での位置        kernel.cpp:272
//      16 + b*18 + 17 u8  maximum の桶内での位置        kernel.cpp:273
//      桶の範囲は begin = floor(b*n/512)、end = floor((b+1)*n/512)（oscilloscope.js:626-627）
//      長さは 16 + 512*18 = 9232 ちょうど（oscilloscope.js:607-608）
//
//  M4 から点に戻す順番は oscilloscope.js:625-655 と同じ:
//      first → （min と max を標本の番号の順に）→ last
//  同じ標本の番号が続いたら 2 つめは捨てる。web 版はそこで値が食い違うと
//  枠ごと捨てているが（同 616-618）、こちらは捨てずに先に入れた方を残す。
//  線の形は変わらないので、捨てて図を消すより残す方がよい。
//
//  縦の取り方は oscilloscope.js:838-857 と同じ:
//      gridMax = 10^(displayLevel/20)、factor = 1/gridMax
//      y = centerY - (amp * factor) * (height/2)、centerY = height/2 - vo*height/2
//  これを軸に直すと、見えている範囲は
//      上端 = (1 - vo) * gridMax、下端 = (-1 - vo) * gridMax
//  displayLevel を下げるほど範囲が狭まる（縦に拡大する）。
//
//  目盛りの刻みは web 版と同じ nice number の取り方（同 861-882）。
//  iPhone の幅なので、web 版の狭いとき（isNarrow）の 8 本に合わせてある。

import SwiftUI
import Foundation

struct OscilloscopeView: View {

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    @StateObject private var telemetry = Telemetry.shared

    @State private var probe: ETScopeProbe?

    /// 縦の目盛りの本数。oscilloscope.js:861 の isNarrow 側。
    private static let amplitudeTickCount = 8
    /// 横の区切り。oscilloscope.js:903 の isNarrow 側。
    private static let timeDivisions = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            graph
            ForEach(node.spec.params) { param in
                ParameterRow(param: param, nodeIndex: index, values: node.values, dsp: dsp)
            }
        }
    }

    private var graph: some View {
        let trace = reading
        let span = trace?.spanMilliseconds ?? displayTimeMilliseconds
        let scale = ETScopeScale(displayLevel: displayLevel, verticalOffset: verticalOffset)
        let level = triggerLevel

        return GraphCanvas(
            x: .linear(0...span, ticks: Self.timeTicks(span), label: Self.timeLabel(span)),
            y: scale.axis(tickCount: Self.amplitudeTickCount),
            height: ETGraphMetrics.height,
            insets: ETGraphInsets(leading: 34, trailing: 8, top: 6, bottom: 14),
            readout: readout,
            caption: caption(trace),
            clipsContent: true,
            draw: { context, plot in
                // トリガの高さ。見えている範囲に入っているときだけ。
                if level >= scale.lower, level <= scale.upper {
                    var line = Path()
                    let y = plot.y(level)
                    line.move(to: CGPoint(x: plot.rect.minX, y: y))
                    line.addLine(to: CGPoint(x: plot.rect.maxX, y: y))
                    context.stroke(line, with: ETGraphShading.muted,
                                   style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }

                guard let trace = trace, trace.values.count > 1 else { return }
                var path = Path()
                for i in trace.values.indices {
                    let point = CGPoint(x: plot.x(trace.milliseconds(at: i)),
                                        y: plot.y(Double(trace.values[i])))
                    if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                context.stroke(path, with: ETGraphShading.curve,
                               style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))

                if let hover = probe {
                    var line = Path()
                    let x = plot.x(hover.milliseconds)
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
                                let ms = plot.xAxis.clamp(plot.xValue(at: touch.location.x))
                                probe = trace?.probe(atMilliseconds: ms)
                            }
                            .onEnded { _ in probe = nil })
            })
    }

    // MARK: 上に出す値

    private var readout: [ETReadoutItem] {
        guard let probe = probe else { return [] }
        return [ETReadoutItem("TIME", String(format: "%.3f ms", probe.milliseconds)),
                ETReadoutItem("AMP", ETScopeScale.amplitudeText(probe.amplitude))]
    }

    private func caption(_ trace: ETScopeTrace?) -> String {
        guard let trace = trace else { return "Waiting for trigger" }
        var text = trace.triggered ? "Triggered" : "Free run"
        text += " · " + String(format: "%.2f ms", trace.spanMilliseconds)
        text += trace.encoding == 0 ? " · raw" : " · M4"
        return text
    }

    // MARK: パラメータ

    private func value(_ name: String, _ fallback: Float) -> Float {
        guard let param = node.spec.params.first(where: { $0.name == name }),
              node.values.indices.contains(param.offset) else { return fallback }
        let v = node.values[param.offset]
        return v.isFinite ? v : fallback
    }

    /// 枠が来る前に軸を引くための長さ。kernel.cpp:108-113 と同じ丸め方。
    private var displayTimeMilliseconds: Double {
        Double(min(0.1, max(0.001, value("displayTime", 0.01)))) * 1000
    }

    private var displayLevel: Double {
        Double(min(0, max(-96, value("displayLevel", 0))))
    }

    private var verticalOffset: Double {
        Double(min(1, max(-1, value("verticalOffset", 0))))
    }

    private var triggerLevel: Double {
        Double(min(1, max(-1, value("triggerLevel", 0))))
    }

    // MARK: 横の目盛り

    private static func timeTicks(_ span: Double) -> [Double] {
        guard span > 0 else { return [] }
        return (0...timeDivisions).map { span * Double($0) / Double(timeDivisions) }
    }

    private static func timeLabel(_ span: Double) -> (Double) -> String {
        let decimals = span >= 20 ? 0 : (span >= 2 ? 1 : 2)
        return { String(format: "%.\(decimals)f", $0) }
    }

    // MARK: 枠を読む

    private var reading: ETScopeTrace? {
        ETScopeTrace(telemetry.frame(tap: node.tapId, type: .scopeSnapshot))
    }
}

// MARK: - 縦の取り方

/// oscilloscope.js:838-857 の対応。Display Level が画面の端の振幅、
/// Vertical Offset がその中心のずれ。
struct ETScopeScale {

    let lower: Double
    let upper: Double

    init(displayLevel: Double, verticalOffset: Double) {
        let gridMax = pow(10, displayLevel / 20)
        upper = (1 - verticalOffset) * gridMax
        lower = (-1 - verticalOffset) * gridMax
    }

    func axis(tickCount: Int) -> ETAxis {
        let span = upper - lower
        guard span > 0, tickCount > 0 else { return .blank(-1...1) }

        // oscilloscope.js:863-876 と同じ nice number。
        let raw = span / Double(tickCount)
        let exponent = floor(log10(raw))
        guard exponent.isFinite else { return .blank(lower...upper) }
        let fraction = raw / pow(10, exponent)
        let nice: Double = fraction < 1.5 ? 1 : (fraction < 3 ? 2 : (fraction < 7 ? 5 : 10))
        let step = nice * pow(10, exponent)
        guard step > 0 else { return .blank(lower...upper) }

        var ticks: [Double] = []
        var v = (lower / step).rounded(.up) * step
        while v <= upper + step * 0.5 && ticks.count < 24 {
            // 0 に近い値は指数の丸め残りが出るので、刻みの 1/1000 で潰す。
            ticks.append(abs(v) < step / 1000 ? 0 : v)
            v += step
        }

        // 桁が小さくなると "0.000005" のような字が左の余白に収まらないので、
        // 刻みが 0.001 を下回ったら指数で書く。
        let decimals = exponent < 0 ? min(6, Int(-exponent)) : 0
        let compact = step < 0.001
        return ETAxis(scale: .linear, lower: lower, upper: upper,
                      ticks: ticks.map { value in
                          let text: String
                          if value == 0 {
                              text = "0"
                          } else if compact {
                              text = String(format: "%.0e", value)
                          } else {
                              text = String(format: "%.\(decimals)f", value)
                          }
                          return ETAxisTick(value, text, emphasized: value == 0)
                      })
    }

    /// 上に出す振幅。小さい値まで見るので指数も使う。
    static func amplitudeText(_ v: Double) -> String {
        let magnitude = abs(v)
        if magnitude >= 0.01 || magnitude == 0 { return String(format: "%+.4f", v) }
        return String(format: "%+.2e", v)
    }
}

// MARK: - 1 掃引

struct ETScopeProbe {
    let milliseconds: Double
    let amplitude: Double
}

struct ETScopeTrace {

    let sampleRate: Double
    let sampleCount: Int
    let triggered: Bool
    let encoding: UInt8
    /// 描く点。元の標本の番号（M4 では飛び飛びになる）。
    let indices: [UInt32]
    let values: [Float]

    var spanMilliseconds: Double {
        Double(sampleCount) / sampleRate * 1000
    }

    func milliseconds(at point: Int) -> Double {
        Double(indices[point]) / sampleRate * 1000
    }

    /// 触った時刻に一番近い点。番号は増える一方なので、離れ始めたら打ち切ってよい。
    func probe(atMilliseconds ms: Double) -> ETScopeProbe? {
        guard !values.isEmpty else { return nil }
        var best = 0
        var bestDistance = Double.greatestFiniteMagnitude
        for i in values.indices {
            let d = abs(milliseconds(at: i) - ms)
            if d < bestDistance {
                bestDistance = d
                best = i
            } else if d > bestDistance {
                break
            }
        }
        return ETScopeProbe(milliseconds: milliseconds(at: best),
                            amplitude: Double(values[best]))
    }

    init?(_ frame: ETFrame?) {
        guard let frame = frame, frame.matches(version: 2), frame.hasPayload(atLeast: 20) else { return nil }

        let payload = frame.payloadView
        guard let rate = payload.f32(at: 0),
              let rawCount = payload.u32(at: 4),
              let bucketCount = payload.u16(at: 12),
              let encoding = payload.u8(at: 14),
              let flags = payload.u8(at: 15) else { return nil }

        // oscilloscope.js:571-577 と同じ門。
        guard rate.isFinite, rate > 0, rawCount > 0, rawCount <= 65536 else { return nil }
        let count = Int(rawCount)

        if encoding == 0 {
            // raw。oscilloscope.js:578-590。
            guard bucketCount == 0, count <= 2048,
                  payload.count == 16 + count * 4,
                  let samples = payload.floats(at: 16, count: count),
                  !samples.contains(where: { !$0.isFinite }) else { return nil }
            indices = (0..<count).map { UInt32($0) }
            values = samples
        } else if encoding == 1 {
            // M4。oscilloscope.js:604-655。
            guard bucketCount == 512, count > 2048,
                  payload.count == 16 + 512 * 18,
                  let decoded = Self.decodeM4(payload, sampleCount: count) else { return nil }
            indices = decoded.indices
            values = decoded.values
        } else {
            return nil
        }

        sampleRate = Double(rate)
        sampleCount = count
        triggered = flags & 1 != 0
        self.encoding = encoding
    }

    /// 512 の桶を点の列へ戻す。first → （min と max を標本の番号の順に）→ last。
    /// 同じ標本の番号が続いたら 2 つめは入れない（oscilloscope.js:615-623）。
    private static func decodeM4(_ payload: ETPayload,
                                 sampleCount: Int) -> (indices: [UInt32], values: [Float])? {
        var idx: [UInt32] = []
        var val: [Float] = []
        idx.reserveCapacity(512 * 4)
        val.reserveCapacity(512 * 4)

        for bucket in 0..<512 {
            let begin = Int(UInt64(bucket) * UInt64(sampleCount) / 512)
            let end = Int(UInt64(bucket + 1) * UInt64(sampleCount) / 512)
            let length = end - begin
            guard length > 0 else { return nil }

            let offset = 16 + bucket * 18
            guard let first = payload.f32(at: offset),
                  let minimum = payload.f32(at: offset + 4),
                  let maximum = payload.f32(at: offset + 8),
                  let last = payload.f32(at: offset + 12),
                  let minimumOffset = payload.u8(at: offset + 16),
                  let maximumOffset = payload.u8(at: offset + 17),
                  first.isFinite, minimum.isFinite, maximum.isFinite, last.isFinite,
                  Int(minimumOffset) < length, Int(maximumOffset) < length else { return nil }

            let minimumIndex = UInt32(begin + Int(minimumOffset))
            let maximumIndex = UInt32(begin + Int(maximumOffset))

            var points: [(UInt32, Float)] = [(UInt32(begin), first)]
            if minimumIndex <= maximumIndex {
                points.append((minimumIndex, minimum))
                points.append((maximumIndex, maximum))
            } else {
                points.append((maximumIndex, maximum))
                points.append((minimumIndex, minimum))
            }
            points.append((UInt32(end - 1), last))

            for point in points {
                if let previous = idx.last, previous == point.0 { continue }
                idx.append(point.0)
                val.append(point.1)
            }
        }

        guard idx.count > 1 else { return nil }
        return (idx, val)
    }
}
