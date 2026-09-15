//  MultibandTransientView.swift
//  Multiband Transient。3 バンドそれぞれに効いている transient gain の移り変わり。
//
//  上流 plugins/dynamics/multiband_transient.js の createUI（910-1117 行）の並びは
//    1. Freq 1 / Freq 2 のスライダー（981-982 行。20〜2000Hz と 200〜20000Hz）
//    2. Low / Mid / High のタブ。選んだバンドの 7 本だけを出す（993-1051 行）
//    3. バンドごとの gain 履歴の図を 3 枚（1060-1099 行）。図を触ってもバンドが変わる
//  図の軸は drawGraphs（766-867 行）:
//      縦 -6〜+6 dB（852 行の (value + 6) / 12）、字は -4/-2/0/2/4（803-810 行）
//      横は 306/60 = 5.1 秒ぶんの時間（7 行の HISTORY_SECONDS）。新しい値が右端
//  ここは図を 1 枚にして、選んでいるバンドを主線、残り 2 本を薄く添えている。
//  iPhone の幅で 3 枚縦に並べると 1 枚も読めない。3 本の動きが一度に見えるのは
//  上流と同じ。
//
//  値はテレメトリから来る。自前で包絡は追わない。
//    枠の種類 13（multibandDynamics）・版 1・ペイロード 16 バイト
//    書く側 dsp/plugins/dynamics/multiband_telemetry.h:27-38
//      payload[0]    = u8 バンド数（3）
//      payload[1]    = u8 種類（2 = ValueKind::TransientGain）
//      payload[2..3] = 0 のまま（std::array{} で 0 埋め、書いていない）
//      payload[4+4i] = f32 バンド i のゲイン（dB・符号つき）
//    読む側 plugins/dynamics/multiband_transient.js:548-569（同じ 4 つを確かめている）
//    値は dsp/plugins/dynamics/multiband_transient/kernel.cpp:197 の 20*log10(gain)。
//    そのブロック最後の、平滑を通したあとのゲイン。
//
//  横軸について。DSP は 60Hz で吐く（EffeTuneDSP.telemetryHz）が、Telemetry は
//  tap と種類ごとに最新の 1 枠しか残さず、読み出しは PipelineView の 30Hz なので、
//  入るのは 1 回に 1 点だけ。点の間隔は一定の時間にならないので目盛りは置かず、
//  いま見えているのが何秒ぶんかを見出しに出している（SpectrogramView と同じ）。
//
//  ゲインは -6〜+6 dB の枠から出ることがある（Transient Gain は ±24 dB まで振れる）。
//  上流も枠で切っているだけなので、ここも切って数字を見出しに出す。

import SwiftUI
import Foundation

struct MultibandTransientView: View {
    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    /// 図だけ見る指定。ParameterRow は自分で畳むが、見出しと
    /// バンドのボタンと DynamicEQParameterRow は畳まないのでここで見る
    /// （MultibandCompressorView.swift:49-50 と同じ）。
    @Environment(\.etGraphOnly) private var graphOnly

    /// 選んでいるバンド。上流の既定も Low（js:25 の selectedBand = 0）。
    @State private var band = 0

    var body: some View {
        let selected = min(max(band, 0), MultibandTransientBands.count - 1)
        let f1 = DynamicsParams.value(node, "f1")
        let f2 = DynamicsParams.value(node, "f2")

        // Telemetry を観測するのは図の中だけ。ここで観測すると 30Hz で
        // このカードごと作り直される。
        return VStack(alignment: .leading, spacing: 12) {
            MultibandTransientGraph(tapId: node.tapId, selected: selected)

            if !graphOnly {
                label("CROSSOVER")
                // f1 / f2 は count == 1 なので ParameterRow がそのまま使える
                // （配列でない行にはバンドのタブが出ない）。
                ForEach(node.spec.params.filter { !$0.isArray }) { param in
                    ParameterRow(param: param, nodeIndex: index, values: node.values, dsp: dsp)
                }

                label("BAND")
                bandPicker(selected: selected, f1: f1, f2: f2)
                // 配列の 7 本は上で選んだバンドへ向ける。行ごとにタブを出すと
                // タブが 7 段になる（ParameterRow の配列表示がそれ）。
                ForEach(node.spec.params.filter { $0.isArray }) { param in
                    DynamicEQParameterRow(param: param, band: selected,
                                          nodeIndex: index, values: node.values, dsp: dsp)
                }
            }
        }
    }

    // MARK: バンドを選ぶ

    /// 上流のバンドタブ（js:994-1012）と同じ。Menu は使わない。
    /// 名前の下にそのバンドが受け持つ帯を出しておく。
    private func bandPicker(selected: Int, f1: Double, f2: Double) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<MultibandTransientBands.count, id: \.self) { i in
                let isSelected = selected == i
                Button {
                    band = i
                } label: {
                    VStack(spacing: 1) {
                        Text(MultibandTransientBands.names[i])
                            .font(.system(size: 13, weight: isSelected ? .bold : .regular))
                        Text(MultibandTransientBands.span(i, f1: f1, f2: f2))
                            .font(.system(size: 9, design: .monospaced))
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .frame(maxWidth: .infinity, minHeight: ETMetrics.hitTarget)
                    .background(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                                in: .rect(cornerRadius: ETMetrics.innerRadius, style: .continuous))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(MultibandTransientBands.names[i]) band")
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .padding(.top, 2)
    }
}

// MARK: - バンドの呼び名

private enum MultibandTransientBands {
    /// 上流 js:993 の bandNames。
    static let names = ["Low", "Mid", "High"]
    static var count: Int { names.count }

    /// クロスオーバーから見た受け持ちの帯。
    static func span(_ band: Int, f1: Double, f2: Double) -> String {
        switch band {
        case 0:  return "< \(ETFormat.hzTick(f1))"
        case 1:  return "\(ETFormat.hzTick(f1))–\(ETFormat.hzTick(f2))"
        default: return "> \(ETFormat.hzTick(f2))"
        }
    }
}

// MARK: - 図

/// Telemetry を観測するのはここだけ。30Hz で作り直されるのがこのビューに収まる。
private struct MultibandTransientGraph: View {
    let tapId: UInt32
    let selected: Int

    @ObservedObject private var telemetry = Telemetry.shared
    @StateObject private var history = MultibandTransientHistory()

    /// 上流 js:803-810 と同じ。線は 2dB ごと、字は -4〜4 だけ。0 の線だけ濃くする。
    private static let gainAxis = ETAxis(
        scale: .linear, lower: -6, upper: 6,
        ticks: [-4.0, -2, 0, 2, 4].map { ETAxisTick($0, "\(Int($0))", emphasized: $0 == 0) })

    var body: some View {
        // 枠を解くのは 1 回だけ。描き直しのたびに 16 バイトを何度も読まない。
        let sample = MultibandTransientSample(telemetry.frame(tap: tapId,
                                                              type: .multibandDynamics))
        return GraphCanvas(
            x: .blank(),
            y: Self.gainAxis,
            height: ETGraphMetrics.compactHeight,
            insets: ETGraphInsets(leading: 24, trailing: 6, top: 6, bottom: 6),
            caption: caption,
            clipsContent: true,
            draw: { context, plot in
                // 3 本とも同じ時刻の並びを使う。輪を解くのは 1 回だけ。
                let stamps = history.stamps()
                for other in 0..<MultibandTransientBands.count where other != selected {
                    trace(&context, plot, stamps, band: other, emphasized: false)
                }
                trace(&context, plot, stamps, band: selected, emphasized: true)
            })
            .onAppear { push(sample) }
            .onChange(of: sample?.sequence) { _, _ in push(sample) }
    }

    /// 1 秒以上空いたところは繋がない。上流 js:843 の maxContinuousGap と同じ。
    /// カードを畳む・一覧を送って図が外れる・エフェクトを切る、のどれでも
    /// テレメトリは止まる。繋ぐと、その間に無かったゲインの線を引いてしまう。
    private static let maxGapSeconds: Double = 1

    /// 右端が最新。点は輪の大きさで割った間隔で左へ伸びる。
    /// 値は MultibandTransientSample が有限のものしか通さない。
    private func trace(_ context: inout GraphicsContext, _ plot: ETPlot, _ stamps: [Double],
                       band: Int, emphasized: Bool) {
        let values = history.series(band: band)
        let count = min(values.count, stamps.count)
        guard count > 1 else { return }
        let step = plot.rect.width / CGFloat(MultibandTransientHistory.capacity)
        let left = plot.rect.maxX - CGFloat(count - 1) * step

        var path = Path()
        var last: Double?
        for i in 0..<count {
            let point = CGPoint(x: left + CGFloat(i) * step, y: plot.y(Double(values[i])))
            if let last = last, stamps[i] - last <= Self.maxGapSeconds {
                path.addLine(to: point)
            } else {
                path.move(to: point)
            }
            last = stamps[i]
        }
        context.stroke(path,
                       with: emphasized ? ETGraphShading.curve : ETGraphShading.muted,
                       style: StrokeStyle(lineWidth: emphasized ? 2 : 1,
                                          lineCap: .round, lineJoin: .round))
    }

    private func push(_ sample: MultibandTransientSample?) {
        guard let sample = sample else { return }
        history.push(sample, tap: tapId)
    }

    private var caption: String {
        let name = MultibandTransientBands.names[min(max(selected, 0),
                                                     MultibandTransientBands.count - 1)]
        guard let value = history.latest(band: selected) else {
            return "\(name) · waiting for audio"
        }
        var text = "\(name) \(ETFormat.gain(Double(value)))"
        if let span = history.span { text += String(format: " · %.1f s", span) }
        return text
    }
}

// MARK: - 1 枠ぶん

private struct MultibandTransientSample {
    /// バンドごとのゲイン（dB）。3 個。
    let gains: [Float]
    let sequence: UInt32

    init?(_ frame: ETFrame?) {
        let bands = MultibandTransientBands.count
        guard let frame = frame, frame.matches(version: 1),
              frame.hasPayload(bytes: 4 + bands * 4) else { return nil }

        // multiband_transient.js:554-561 と同じ門。
        let payload = frame.payloadView
        guard payload.u8(at: 0) == UInt8(bands),
              payload.u8(at: 1) == 2,               // ValueKind::TransientGain
              payload.u8(at: 2) == 0, payload.u8(at: 3) == 0,
              let values = payload.floats(at: 4, count: bands),
              values.allSatisfy({ $0.isFinite }) else { return nil }

        gains = values
        sequence = frame.sequence
    }
}

// MARK: - 横に流す履歴

/// バンド 3 本ぶんの値を固定長の輪で持つ。新しい点は右端、古い点は左へ。
private final class MultibandTransientHistory: ObservableObject {

    static let bands = 3
    /// 上流と同じ 5.1 秒ぶん（js:7 の 306/60）。こちらは 30Hz で読むので 153 点。
    static let capacity = 153

    /// 中身が変わったことだけを知らせる。配列そのものは publish しない。
    @Published private(set) var revision: UInt32 = 0

    private var values = [Float](repeating: .nan,
                                 count: MultibandTransientHistory.capacity
                                     * MultibandTransientHistory.bands)
    private var times = [Double](repeating: .nan, count: MultibandTransientHistory.capacity)
    private var head = 0
    private var count = 0
    private var lastSequence: UInt32?
    private var lastTap: UInt32?

    func push(_ sample: MultibandTransientSample, tap: UInt32) {
        // 別のエフェクトの値を同じ輪に混ぜない。
        if lastTap != tap {
            reset()
            lastTap = tap
        }
        // 同じ枠を 2 度入れない。描き直しのたびに点が増えてしまう。
        if let previous = lastSequence, previous == sample.sequence { return }
        lastSequence = sample.sequence

        for band in 0..<Self.bands {
            values[head * Self.bands + band] = sample.gains[band]
        }
        times[head] = Date().timeIntervalSinceReferenceDate

        head = (head + 1) % Self.capacity
        if count < Self.capacity { count += 1 }
        revision &+= 1
    }

    /// 古い順に並べた時刻。series(band:) と同じ順・同じ長さ。
    /// 点の間隔が空いたところを線で繋がないために要る。
    func stamps() -> [Double] {
        guard count > 0 else { return [] }
        let start = (head - count + Self.capacity) % Self.capacity
        return (0..<count).map { times[(start + $0) % Self.capacity] }
    }

    /// 古い順に並べた 1 バンドぶん。
    func series(band: Int) -> [Float] {
        guard band >= 0, band < Self.bands, count > 0 else { return [] }
        let start = (head - count + Self.capacity) % Self.capacity
        return (0..<count).map { values[((start + $0) % Self.capacity) * Self.bands + band] }
    }

    func latest(band: Int) -> Float? {
        guard band >= 0, band < Self.bands, count > 0 else { return nil }
        return values[((head - 1 + Self.capacity) % Self.capacity) * Self.bands + band]
    }

    /// 見えている範囲の秒数。点の間隔は一定でないので、端の時刻の差で出す。
    var span: Double? {
        guard count > 1 else { return nil }
        let oldest = times[(head - count + Self.capacity) % Self.capacity]
        let newest = times[(head - 1 + Self.capacity) % Self.capacity]
        guard oldest.isFinite, newest.isFinite, newest > oldest else { return nil }
        return newest - oldest
    }

    private func reset() {
        for i in values.indices { values[i] = .nan }
        for i in times.indices { times[i] = .nan }
        head = 0
        count = 0
        lastSequence = nil
        revision &+= 1
    }
}
