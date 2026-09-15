//  PowerAmpSagView.swift
//  Power Amp Sag。電源の垂れ下がりを見るための 2 枚。
//
//  上流 plugins/dynamics/power_amp_sag.js の createUI（597-709 行）は
//    1. Sensitivity / Stability / Recovery Spd のスライダー（609, 619, 629 行）
//    2. Monoblock のチェックボックス（639-656 行）
//    3. 図を 2 枚、graphContainer に入れて追加（691-693 行）
//  図は drawGraphs（444-477 行）が
//      左 'Input Envelope' 単位 %・範囲 0〜100・目盛り 10（446-459 行）
//      右 'Gain Reduction' 単位 dB・範囲 -12〜+2・目盛り 2（463-476 行）
//  どちらも横が時間の履歴で、新しい値が右端。
//  CSS は幅が足りないとき 2 枚を縦に積む（power_amp_sag.css の
//  body.layout-mobile 以下、flex: 1 1 100%）。iPhone の幅はそちらなので、
//  ここも縦に 2 枚積んでいる。
//
//  目盛りの字は上流も幅で間引く。js:493 の labelEvery は cssWidth < 480 かつ
//  単位が % のとき step * 2、つまり % の側だけ 20 ごとになる。ここは iPhone の
//  幅しか無いので、その形で固定してある。線は上流と同じ 10 ごとに引く。
//
//  現在値は上流が図の右上に `currentValue.toFixed(1) + ' ' + unit`（js:585-593）。
//  ここは GraphCanvas の見出しに出す。図の中に字を置くと、線と重なる。
//
//  値はテレメトリから来る。自前で包絡は追わない。
//    枠の種類 12（powerAmpSag）・版 1・ペイロード 8 バイト
//    書く側 dsp/plugins/dynamics/power_amp_sag/kernel.cpp:155-164
//      payload[0..3] = f32 入力エンベロープ（%。kernel.cpp:150 の maximum_envelope * 100）
//      payload[4..7] = f32 ゲインリダクション（dB。kernel.cpp:147 の 20*log10(voltage)）
//    読む側 plugins/dynamics/power_amp_sag.js:304-320
//      有限でないもの、エンベロープが負のもの、ゲインリダクションが正のものは捨てる。
//      電源電圧は 1 を超えないので、リダクションは 0 以下にしかならない。
//
//  横軸について。DSP は 60Hz で吐く（EffeTuneDSP.telemetryHz）が、Telemetry は
//  tap と種類ごとに最新の 1 枠しか残さず、読み出しは PipelineView の 30Hz なので、
//  入るのは 1 回に 1 点だけ。点は等間隔に並べ、1 秒をまたいだところに上流と同じ
//  短い縦棒を置いている（js:535-548）。棒の間隔が揃わないのは、点の間隔が
//  一定の時間にならないため。見えている秒数は見出しにも出す。

import SwiftUI
import Foundation

struct PowerAmpSagView: View {
    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    var body: some View {
        // Telemetry を観測するのは図の中だけ。ここで観測すると 30Hz で
        // このカードごと作り直される。
        VStack(alignment: .leading, spacing: 12) {
            PowerAmpSagGraphs(tapId: node.tapId)

            ForEach(node.spec.params) { param in
                ParameterRow(param: param, nodeIndex: index, values: node.values, dsp: dsp)
            }
        }
    }
}

// MARK: - 図

/// Telemetry を観測するのはここだけ。30Hz で作り直されるのがこのビューに収まる。
private struct PowerAmpSagGraphs: View {
    let tapId: UInt32

    @ObservedObject private var telemetry = Telemetry.shared
    @StateObject private var history = PowerAmpSagHistory()

    /// 上流 js:446-459。0〜100 を 10 ごと。字は 20 ごと（js:493 の labelEvery）。
    private static let envelopeAxis = ETAxis(
        scale: .linear, lower: 0, upper: 100,
        ticks: stride(from: 0.0, through: 100.0, by: 10).map { value -> ETAxisTick in
            let label: String? = value.truncatingRemainder(dividingBy: 20) == 0
                ? "\(Int(value))" : nil
            return ETAxisTick(value, label)
        })

    /// 上流 js:463-476。-12〜+2 を 2 ごと。0 の線だけ濃くする。
    private static let reductionAxis = ETAxis(
        scale: .linear, lower: -12, upper: 2,
        ticks: stride(from: -12.0, through: 2.0, by: 2).map {
            ETAxisTick($0, "\(Int($0))", emphasized: $0 == 0)
        })

    var body: some View {
        // 枠を解くのは 1 回だけ。描き直しのたびに 8 バイトを何度も読まない。
        let sample = PowerAmpSagSample(telemetry.frame(tap: tapId, type: .powerAmpSag))
        // 2 枚は同じ時刻の並びを使う。輪を解くのは 1 回だけ。
        let stamps = history.stamps()

        return VStack(alignment: .leading, spacing: 10) {
            graph(title: "Input Envelope", unit: "%", axis: Self.envelopeAxis,
                  values: history.envelopes(), stamps: stamps, latest: history.latestEnvelope)
            graph(title: "Gain Reduction", unit: "dB", axis: Self.reductionAxis,
                  values: history.reductions(), stamps: stamps, latest: history.latestReduction)
        }
        .onAppear { push(sample) }
        .onChange(of: sample?.sequence) { _, _ in push(sample) }
    }

    private func graph(title: String, unit: String, axis: ETAxis,
                       values: [Float], stamps: [Double], latest: Float?) -> some View {
        GraphCanvas(
            x: .blank(),
            y: axis,
            height: ETGraphMetrics.compactHeight,
            insets: ETGraphInsets(leading: 26, trailing: 6, top: 6, bottom: 6),
            caption: caption(title: title, unit: unit, latest: latest),
            clipsContent: true,
            draw: { context, plot in
                Self.secondMarkers(&context, plot, stamps)
                Self.trace(&context, plot, values, stamps)
            })
    }

    /// 上流 js:585-593 と同じ小数 1 桁。値が無い間は待っていることを出す。
    private func caption(title: String, unit: String, latest: Float?) -> String {
        guard let latest = latest, latest.isFinite else { return "\(title) · waiting for audio" }
        let value = String(format: "%.1f", Double(latest))
        var text = "\(title) \(value) \(unit)"
        if let span = history.span { text += String(format: " · %.1f s", span) }
        return text
    }

    /// 1 秒以上空いたところは繋がない。上流 js:558 の maxContinuousGap と同じ。
    /// カードを畳む・一覧を送って図が外れる・エフェクトを切る、のどれでも
    /// テレメトリは止まる。繋ぐと、その間に無かった値の線を引いてしまう。
    private static let maxGapSeconds: Double = 1

    /// 右端が最新。点は輪の大きさで割った間隔で左へ伸びる。
    private static func trace(_ context: inout GraphicsContext, _ plot: ETPlot,
                              _ values: [Float], _ stamps: [Double]) {
        let count = min(values.count, stamps.count)
        guard count > 1 else { return }
        let step = plot.rect.width / CGFloat(PowerAmpSagHistory.capacity)
        let left = plot.rect.maxX - CGFloat(count - 1) * step

        var path = Path()
        var last: Double?
        for i in 0..<count {
            let point = CGPoint(x: left + CGFloat(i) * step, y: plot.y(Double(values[i])))
            if let previous = last, stamps[i] - previous <= maxGapSeconds {
                path.addLine(to: point)
            } else {
                path.move(to: point)
            }
            last = stamps[i]
        }
        context.stroke(path, with: ETGraphShading.curve,
                       style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
    }

    /// 1 秒ごとの短い縦棒（js:535-548）。上流は時間の座標で置いているが、
    /// こちらは点を等間隔に並べているので、秒をまたいだ直後の点に置く。
    private static func secondMarkers(_ context: inout GraphicsContext, _ plot: ETPlot,
                                      _ stamps: [Double]) {
        guard stamps.count > 1 else { return }
        let step = plot.rect.width / CGFloat(PowerAmpSagHistory.capacity)
        let left = plot.rect.maxX - CGFloat(stamps.count - 1) * step
        let markerHeight: CGFloat = 8

        var path = Path()
        for i in 1..<stamps.count {
            let previous = stamps[i - 1]
            let current = stamps[i]
            guard previous.isFinite, current.isFinite,
                  current - previous <= maxGapSeconds,
                  current.rounded(.down) > previous.rounded(.down) else { continue }
            let x = left + CGFloat(i) * step
            path.move(to: CGPoint(x: x, y: plot.rect.maxY - markerHeight))
            path.addLine(to: CGPoint(x: x, y: plot.rect.maxY))
        }
        context.stroke(path, with: ETGraphShading.axis, lineWidth: 1)
    }

    private func push(_ sample: PowerAmpSagSample?) {
        guard let sample = sample else { return }
        history.push(sample, tap: tapId)
    }
}

// MARK: - 1 枠ぶん

private struct PowerAmpSagSample {
    /// 入力エンベロープ（%）。
    let envelopePercent: Float
    /// ゲインリダクション（dB。0 以下）。
    let gainReductionDB: Float
    let sequence: UInt32

    init?(_ frame: ETFrame?) {
        guard let frame = frame, frame.matches(version: 1), frame.hasPayload(bytes: 8) else {
            return nil
        }
        // power_amp_sag.js:314-319 と同じ門。
        let payload = frame.payloadView
        guard let envelope = payload.f32(at: 0), let reduction = payload.f32(at: 4),
              envelope.isFinite, envelope >= 0,
              reduction.isFinite, reduction <= 0 else { return nil }

        envelopePercent = envelope
        gainReductionDB = reduction
        sequence = frame.sequence
    }
}

// MARK: - 横に流す履歴

/// 2 本ぶんの値を固定長の輪で持つ。新しい点は右端、古い点は左へ。
private final class PowerAmpSagHistory: ObservableObject {

    /// 上流と同じ 8.5 秒ぶん（js:5 の 512 / 60）。こちらは 30Hz で読むので 256 点。
    static let capacity = 256

    /// 中身が変わったことだけを知らせる。配列そのものは publish しない。
    @Published private(set) var revision: UInt32 = 0

    private var envelopeValues = [Float](repeating: .nan, count: PowerAmpSagHistory.capacity)
    private var reductionValues = [Float](repeating: .nan, count: PowerAmpSagHistory.capacity)
    private var times = [Double](repeating: .nan, count: PowerAmpSagHistory.capacity)
    private var head = 0
    private var count = 0
    private var lastSequence: UInt32?
    private var lastTap: UInt32?

    func push(_ sample: PowerAmpSagSample, tap: UInt32) {
        // 別のエフェクトの値を同じ輪に混ぜない。
        if lastTap != tap {
            reset()
            lastTap = tap
        }
        // 同じ枠を 2 度入れない。描き直しのたびに点が増えてしまう。
        if let previous = lastSequence, previous == sample.sequence { return }
        lastSequence = sample.sequence

        envelopeValues[head] = sample.envelopePercent
        reductionValues[head] = sample.gainReductionDB
        times[head] = Date().timeIntervalSinceReferenceDate

        head = (head + 1) % Self.capacity
        if count < Self.capacity { count += 1 }
        revision &+= 1
    }

    /// 古い順に並べた時刻。envelopes() / reductions() と同じ順・同じ長さ。
    /// 点の間隔が空いたところを線で繋がないために要る。
    func stamps() -> [Double] {
        ordered(times)
    }

    func envelopes() -> [Float] {
        ordered(envelopeValues)
    }

    func reductions() -> [Float] {
        ordered(reductionValues)
    }

    var latestEnvelope: Float? {
        guard count > 0 else { return nil }
        return envelopeValues[(head - 1 + Self.capacity) % Self.capacity]
    }

    var latestReduction: Float? {
        guard count > 0 else { return nil }
        return reductionValues[(head - 1 + Self.capacity) % Self.capacity]
    }

    /// 見えている範囲の秒数。点の間隔は一定でないので、端の時刻の差で出す。
    var span: Double? {
        guard count > 1 else { return nil }
        let oldest = times[(head - count + Self.capacity) % Self.capacity]
        let newest = times[(head - 1 + Self.capacity) % Self.capacity]
        guard oldest.isFinite, newest.isFinite, newest > oldest else { return nil }
        return newest - oldest
    }

    private func ordered<T>(_ ring: [T]) -> [T] {
        guard count > 0 else { return [] }
        let start = (head - count + Self.capacity) % Self.capacity
        return (0..<count).map { ring[(start + $0) % Self.capacity] }
    }

    private func reset() {
        envelopeValues = [Float](repeating: .nan, count: Self.capacity)
        reductionValues = [Float](repeating: .nan, count: Self.capacity)
        times = [Double](repeating: .nan, count: Self.capacity)
        head = 0
        count = 0
        lastSequence = nil
        revision &+= 1
    }
}
