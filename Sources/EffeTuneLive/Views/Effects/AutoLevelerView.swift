//  AutoLevelerView.swift
//  Auto Leveler。入力と出力の LUFS を時間の履歴で出す。
//
//  上流は plugins/dynamics/auto_leveler.js:519-631（drawGraph）:
//    縦は -48〜0 dB。格子は -42 から -6 まで 6 dB ごと :545-553
//      y = height * (1 - (value + 48) / 48) :604
//    横は直近 1024/60 秒（AUTO_LEVELER_HISTORY_SECONDS :5）
//      1 秒ごとに下端から短い印 :566-578
//    線は入力（graph-trace）と出力（text-primary）の 2 本 :616-618
//    時刻が 1 秒より開いたところは繋がない（maxContinuousGap :589, 600-603）
//    右端に現在の出力 LUFS を toFixed(1) + ' dB' で書く :621-631
//  軸名は 'LUFS (dB)' :560 と 'Time' :562。縦は目盛りの数字が dB なので、
//  こちらは見出しの 1 行に畳んである。
//
//  テレメトリ: ETFrameType.loudnessLevels = 7、版 1、8 バイト
//    書く側 dsp/plugins/dynamics/auto_leveler/kernel.cpp:225-228 が
//           同 group_b_telemetry.h:27-34 を呼ぶ
//      0 f32 入力 LUFS / 4 f32 出力 LUFS
//    読む側 auto_leveler.js:383-398。両方とも有限で -144 以上のものだけ通す。
//    -144 は測れていないという意味の底なので、軸の下に落ちて枠で切れる。
//
//  枠に時刻は入っていない。上流も受け取った側で打っている
//  （auto_leveler.js:417-419 の performance.now()）ので、こちらも同じにする。
//
//  図が動くのは PipelineView の 1/30 秒ごとの pollTelemetry で枠が入れ替わるとき。
//  枠が来なくなれば右端は最後の標本の時刻で止まる。上流も displayTime を
//  latest + 1/60 秒で頭打ちにしている :430-435。
//
//  図は上に置いてある。上流は createUI がパラメータの後ろに繋いでいる :671 が、
//  こちらの専用画面は図を先に置いているので、そちらに合わせた。

import SwiftUI
import Foundation

struct AutoLevelerView: View {

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Telemetry を観るのは中の図だけ。ここで観ると 30Hz で
            // パラメータの行まで作り直される。
            AutoLevelerHistoryGraph(tapId: node.tapId)

            ForEach(node.spec.params) { param in
                ParameterRow(param: param, nodeIndex: index, values: node.values, dsp: dsp)
            }
        }
    }
}

// MARK: - 図

private struct AutoLevelerHistoryGraph: View {

    let tapId: UInt32

    @ObservedObject private var telemetry = Telemetry.shared
    @StateObject private var history = ETAutoLevelerHistory()

    /// 縦は -48〜0 dB。字を出すのは上流と同じ -42 から -6 まで
    /// （auto_leveler.js:545）。上下の端は枠の線と重なるので置かない。
    private static let lufsAxis = ETAxis(
        scale: .linear, lower: -48, upper: 0,
        ticks: stride(from: -42.0, through: -6.0, by: 6).map { ETAxisTick($0, "\(Int($0))") })

    var body: some View {
        // 枠を解くのは 1 回だけ。body は 30Hz で回る。
        let levels = self.levels
        return GraphCanvas(
            x: .blank((-ETAutoLevelerHistory.windowSeconds)...0),
            y: Self.lufsAxis,
            height: ETGraphMetrics.height,
            insets: ETGraphInsets(leading: 26, trailing: 6, top: 6, bottom: 6),
            caption: caption,
            clipsContent: true,
            draw: { context, plot in drawHistory(&context, plot) })
        .onAppear { push(levels) }
        .onChange(of: levels?.sequence) { _, _ in push(levels) }
    }

    // MARK: 描く

    private func drawHistory(_ context: inout GraphicsContext, _ plot: ETPlot) {
        guard let newest = history.newestTime else { return }
        let samples = history.recent(endingAt: newest)
        guard !samples.isEmpty else { return }

        // 1 秒ごとの印。下端から少しだけ立てる（上流 :566-578 は 8px）。
        var marks = Path()
        var second = (newest - ETAutoLevelerHistory.windowSeconds).rounded(.up)
        while second <= newest {
            let x = plot.x(second - newest)
            marks.move(to: CGPoint(x: x, y: plot.rect.maxY))
            marks.addLine(to: CGPoint(x: x, y: plot.rect.maxY - 6))
            second += 1
        }
        context.stroke(marks, with: ETGraphShading.axis, lineWidth: 1)

        // 入力が先、出力が後。重なったときに出力が上に来る（上流 :616-618 と同じ順）。
        context.stroke(trace(samples, newest: newest, plot: plot) { $0.input },
                       with: ETGraphShading.muted, lineWidth: 1)
        context.stroke(trace(samples, newest: newest, plot: plot) { $0.output },
                       with: ETGraphShading.curve,
                       style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))

        // 現在の出力 LUFS。上流は線の少し上、右端に置く（:621-631）。
        // 上流は枠の外へ出た字がそのまま切れるが、ここでは枠の中へ留めて読めるようにする。
        let output = samples[samples.count - 1].output
        let line = plot.y(plot.yAxis.clamp(output))
        let y = min(max(line - 10, plot.rect.minY + 7), plot.rect.maxY - 7)
        context.draw(Text(ETFormat.db(output))
                        .font(.system(size: ETGraphMetrics.readoutSize, design: .monospaced))
                        .foregroundStyle(.tint),
                     at: CGPoint(x: plot.rect.maxX - 6, y: y), anchor: .trailing)
    }

    /// 1 本ぶんの線。時刻が 1 秒より開いたところは繋がない（上流 :598-603）。
    private func trace(_ samples: [ETAutoLevelerHistory.Sample],
                       newest: Double,
                       plot: ETPlot,
                       _ value: (ETAutoLevelerHistory.Sample) -> Double) -> Path {
        var path = Path()
        var previous: Double?
        for sample in samples {
            let point = plot.point(sample.time - newest, value(sample))
            if let last = previous, sample.time - last <= ETAutoLevelerHistory.maxGapSeconds {
                path.addLine(to: point)
            } else {
                path.move(to: point)
            }
            previous = sample.time
        }
        return path
    }

    private var caption: String {
        guard history.count > 0 else { return "Waiting for audio" }
        return String(format: "Input / Output LUFS · %.0f s",
                      ETAutoLevelerHistory.windowSeconds)
    }

    // MARK: 枠を読む

    private func push(_ levels: ETAutoLevelerLevels?) {
        guard let levels else { return }
        // 枠に時刻が無いので、受け取った時刻を打つ。
        history.push(input: levels.input, output: levels.output,
                     sequence: levels.sequence,
                     time: ProcessInfo.processInfo.systemUptime)
    }

    private var levels: ETAutoLevelerLevels? {
        ETAutoLevelerLevels(telemetry.frame(tap: tapId, type: .loudnessLevels))
    }
}

// MARK: - 1 回ぶん

private struct ETAutoLevelerLevels {

    let input: Double
    let output: Double
    let sequence: UInt32

    init?(_ frame: ETFrame?) {
        guard let frame = frame, frame.matches(version: 1), frame.hasPayload(bytes: 8),
              let input = frame.payloadView.f32(at: 0),
              let output = frame.payloadView.f32(at: 4) else { return nil }

        // auto_leveler.js:393-396 と同じ門。
        guard input.isFinite, input >= -144, output.isFinite, output >= -144 else { return nil }

        self.input = Double(input)
        self.output = Double(output)
        self.sequence = frame.sequence
    }
}

// MARK: - 履歴

/// 標本を固定長の輪で持つ。新しいものが右端、古いものは左へ。
private final class ETAutoLevelerHistory: ObservableObject {

    /// 上流の輪と同じ本数（auto_leveler.js:33-35）。
    /// DSP は 60Hz で吐き、読み出しは 30Hz なので、実際に入るのは窓の半分ほど。
    static let capacity = 1024
    /// 横に出す秒数。上流の AUTO_LEVELER_HISTORY_SECONDS（auto_leveler.js:5）。
    static let windowSeconds: Double = 1024.0 / 60.0
    /// これ以上離れた標本は繋がない（auto_leveler.js:589）。
    static let maxGapSeconds: Double = 1

    struct Sample {
        var time: Double
        var input: Double
        var output: Double
    }

    /// 中身が変わったことだけを知らせる。配列そのものは publish しない。
    @Published private(set) var revision: UInt32 = 0

    private(set) var count = 0

    private var samples = [Sample](repeating: Sample(time: .nan, input: .nan, output: .nan),
                                   count: ETAutoLevelerHistory.capacity)
    private var head = 0
    private var lastSequence: UInt32?

    /// 一番新しい標本の時刻。これが図の右端になる。
    var newestTime: Double? {
        guard count > 0 else { return nil }
        let time = samples[(head - 1 + Self.capacity) % Self.capacity].time
        return time.isFinite ? time : nil
    }

    func push(input: Double, output: Double, sequence: UInt32, time: Double) {
        // 同じ枠を 2 度入れない。描き直しのたびに標本が増えてしまう。
        if let previous = lastSequence, previous == sequence { return }
        lastSequence = sequence

        samples[head] = Sample(time: time, input: input, output: output)
        head = (head + 1) % Self.capacity
        if count < Self.capacity { count += 1 }
        revision &+= 1
    }

    /// 窓に入っているぶんだけ、古い順に。
    func recent(endingAt newest: Double) -> [Sample] {
        guard count > 0 else { return [] }
        let cutoff = newest - Self.windowSeconds
        let start = (head - count + Self.capacity) % Self.capacity
        var out: [Sample] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let sample = samples[(start + i) % Self.capacity]
            guard sample.time.isFinite, sample.time >= cutoff else { continue }
            out.append(sample)
        }
        return out
    }
}
