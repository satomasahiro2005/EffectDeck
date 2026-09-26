//  StereoMeterView.swift
//  Stereo Meter。ゴニオメーター（L/R のリサージュ）に、相関の縦棒と左右差の横棒を
//  1 枚の正方形の中で重ねる。上流の drawMeter（stereo_meter.js:510-761）と同じ構えにしてある。
//
//  テレメトリ: ETFrameType.stereoField = 6、formatVersion 2
//  （kernel.cpp:15-16 の kTapStereoField / kTelemetryVersion、
//    stereo_meter.js:1-2 の STEREO_FIELD_TAP_FRAME / _TELEMETRY_VERSION）
//
//  ペイロードの並び。dsp/plugins/analyzer/stereo_meter/kernel.cpp:344-389 が書き、
//  plugins/analyzer/stereo_meter.js:326-396 が同じ位置を読んでいる:
//      0                      f32 sampleRate      kernel.cpp:348 / stereo_meter.js:341
//      4                      u16 sampleCount     kernel.cpp:349 / stereo_meter.js:342
//      6                      u16 sampleFlags     kernel.cpp:350 / stereo_meter.js:343
//                                                 bit0 = 取りこぼし（kernel.cpp:27）
//      8 + i*8                f32 x = R - L       kernel.cpp:362 / stereo_meter.js:358
//      12 + i*8               f32 y = L + R       kernel.cpp:363 / stereo_meter.js:359
//      env  = 8 + n*8         f32 × 360           角度ごとのピーク（kernel.cpp:367-371）
//                                                 添字は度。角度は -atan2(y, x)（kernel.cpp:178）
//      stat = env + 1440      f32 correlation     kernel.cpp:385 / stereo_meter.js:375
//      stat + 4               f32 balance         10log10(ΣR²) - 10log10(ΣL²)  kernel.cpp:382-386
//      stat + 8               f32 peakL           kernel.cpp:387  線形の振幅
//      stat + 12              f32 peakR           kernel.cpp:388  線形の振幅
//  長さは 8 + n*8 + 1456 ちょうど（kernel.cpp:389 / stereo_meter.js:344-350）。
//
//  peakL / peakR は門として読むだけで描かない。上流も読んで返すだけで
//  （stereo_meter.js:377-394）、drawMeter には一度も出てこない。
//
//  点の置き方は web 版と同じ（stereo_meter.js:599-600）:
//      screenX = cx + (x * 0.5) * radius
//      screenY = cy - (y * 0.5) * radius
//  つまり同相のモノラルは真上へ伸びる。包絡線だけは web 版が
//  y に + を使っている（同 645）ので、こちらも符号を合わせてある。
//
//  包絡線のならしは web 版と同じ σ = 5°、±15°のガウス（同 620-636）。
//
//  枠に入ってくるのは前回の書き出しからの差分だけ（kernel.cpp:344-347 の
//  pending_sample_count_）。Window の長さだけ遡って打つには貯める側が要るので、
//  ETStereoTrail を View 側に置いている。

import SwiftUI
import Foundation

struct StereoMeterView: View {

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    @Environment(\.etGraphOnly) private var graphOnly
    /// 表示だけの倍率（dB）。上流の `gn`（v2.11.0 の stereo_meter.js:160、:264-269）。DSP へは送らない。
    @State private var gain: Double = 0

    /// v2.11.0 の stereo_meter.js:222 の 0〜24dB。
    private static let gainRange: ClosedRange<Double> = 0...24

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // テレメトリを観測するのはこの中だけ。つまみの行を 30Hz で作り直さない。
            StereoMeterFigure(tapId: node.tapId, windowSeconds: windowSeconds, gainDB: gain)

            // 上流は Window・Gain の順（v2.11.0 の stereo_meter.js:213-226）。
            ForEach(node.spec.params) { param in
                if param.name == "windowTime" {
                    StereoWindowRow(param: param, nodeIndex: index,
                                    values: node.values, dsp: dsp)
                } else {
                    ParameterRow(param: param, nodeIndex: index, values: node.values, dsp: dsp)
                }
            }
            if !graphOnly { gainRow }
        }
        // 畳むと View ごと消えるので鎖に持たせる。上流も `gn` をプリセットに書く
        // （v2.11.0 の stereo_meter.js:271-279）。
        .etSaved($gain, key: "gn", index: index, dsp: dsp)
    }

    /// v2.11.0 の stereo_meter.js:221-226 の createParameterControl('Gain', 0, 24, 1, …, 'dB')。
    private var gainRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Gain (dB)")
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                ETValueField(text: ETNumberText.plain(gain) + " dB",
                             label: "Gain",
                             editText: { ETNumberText.plain(gain) }) { typed in
                    // 上流の setGain（:264-269）と同じく挟むだけで丸めない。
                    gain = min(max(typed, Self.gainRange.lowerBound), Self.gainRange.upperBound)
                }
            }
            Slider(value: $gain, in: Self.gainRange, step: 1)
                .accessibilityLabel("Gain")
                .accessibilityValue(ETNumberText.plain(gain) + " dB")
        }
        .padding(.vertical, 2)
    }

    /// つまみが持っている Window の長さ。秒で入っている（EffectCatalog の windowTime）。
    private var windowSeconds: Double {
        guard let param = node.spec.params.first(where: { $0.name == "windowTime" }),
              node.values.indices.contains(param.offset) else { return 0.1 }
        let v = Double(node.values[param.offset])
        guard v.isFinite else { return 0.1 }
        // stereo_meter.js:247 と同じ範囲に落とす。
        return min(1.0, max(0.01, v))
    }
}

// MARK: - 図

/// ゴニオメーターと 2 本の棒。上流と同じく 1 枚の正方形に全部入れる。
private struct StereoMeterFigure: View {

    let tapId: UInt32
    let windowSeconds: Double
    /// 点と包絡線の半径にだけ掛ける（v2.11.0 の stereo_meter.js:542 の signalRadius）。
    /// ひし形・目盛り・相関と左右差の棒は変えない。
    let gainDB: Double

    @ObservedObject private var telemetry = Telemetry.shared
    @StateObject private var trail = ETStereoTrail()
    @State private var side: CGFloat = ETGraphMetrics.height

    /// 角度ごとのピーク（stereo_meter.js:6）。
    private static let envelopeBins = 360
    /// 上流の図の幅の上限（stereo_meter.js:218）。縦横は 1:1（同 219）。
    private static let maxSide: CGFloat = 480
    /// 縁の棒の太さ。上流の barThickness（stereo_meter.js:693）。
    private static let barThickness: CGFloat = 16
    /// 左右差の目盛りの端。上流の energyMax（同 721）。
    private static let energyMax: Double = 18

    var body: some View {
        // 枠を解くのは 1 回だけ。指で触っている間も body は回る。
        let reading = self.reading
        return GraphCanvas(
            x: .blank(), y: .blank(),
            height: side,
            insets: .none,
            readout: readout(reading),
            caption: "Waiting for audio",
            clipsContent: true,
            draw: { context, plot in
                Self.drawField(&context, plot)
                if let r = reading {
                    let gain = pow(10, gainDB / 20)
                    trail.draw(&context, plot, seconds: windowSeconds, gain: gain)
                    Self.drawEnvelope(&context, plot, Self.smooth(r.envelope), gain: gain)
                    Self.drawCorrelationBar(&context, plot, Double(r.correlation))
                    Self.drawBalanceBar(&context, plot, Double(r.balance))
                }
                // 目盛りは棒の上（上流も棒を塗ってから引く）。値が無いときも枠として出す。
                Self.drawCorrelationTicks(&context, plot)
                Self.drawBalanceTicks(&context, plot)
                Self.drawAxisNames(&context, plot)
            })
            .frame(maxWidth: Self.maxSide)
            // 上流は aspectRatio '1 / 1'。幅を測って高さに使う。
            // 高さだけが変わるので、測り直しは繰り返さない。
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                if width > 0 { side = width }
            }
            .onAppear { push(reading) }
            .onChange(of: reading?.sequence) { _, _ in push(reading) }
            // 枠が途切れたら貯めた点を捨てる。繋ぎ直したときに前の音が混ざらないように。
            .onChange(of: reading == nil) { _, gone in
                if gone { trail.reset() }
            }
    }

    private func readout(_ r: Reading?) -> [ETReadoutItem] {
        guard let r = r else { return [] }
        return [ETReadoutItem("LR CORRELATION", String(format: "%.2f", Double(r.correlation))),
                ETReadoutItem("LR BALANCE", ETFormat.gain(Double(r.balance)))]
    }

    private func push(_ r: Reading?) {
        guard let r = r else { return }
        trail.push(samples: r.samples, sampleRate: Double(r.sampleRate), sequence: r.sequence)
    }

    // MARK: 枠・対角線・四隅の名前

    /// 値が無いときもこれだけは出す。
    private static func drawField(_ context: inout GraphicsContext, _ plot: ETPlot) {
        let rect = plot.rect
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let size = min(rect.width, rect.height)
        let radius = size * 0.45

        // ひし形。
        var diamond = Path()
        diamond.move(to: CGPoint(x: center.x, y: center.y - radius))
        diamond.addLine(to: CGPoint(x: center.x + radius, y: center.y))
        diamond.addLine(to: CGPoint(x: center.x, y: center.y + radius))
        diamond.addLine(to: CGPoint(x: center.x - radius, y: center.y))
        diamond.closeSubpath()
        context.stroke(diamond, with: ETGraphShading.axis, lineWidth: 1)

        // 縦横と 45 度（stereo_meter.js:552-570）。45 度は四隅まで伸ばす。
        var cross = Path()
        cross.move(to: CGPoint(x: center.x, y: center.y - radius))
        cross.addLine(to: CGPoint(x: center.x, y: center.y + radius))
        cross.move(to: CGPoint(x: center.x - radius, y: center.y))
        cross.addLine(to: CGPoint(x: center.x + radius, y: center.y))
        for corner in [CGPoint(x: 1, y: 1), CGPoint(x: -1, y: 1),
                       CGPoint(x: -1, y: -1), CGPoint(x: 1, y: -1)] {
            cross.move(to: center)
            cross.addLine(to: CGPoint(x: center.x + corner.x * radius,
                                      y: center.y + corner.y * radius))
        }
        context.stroke(cross, with: ETGraphShading.grid, lineWidth: 0.5)

        // 四隅の名前（stereo_meter.js:577-581）。
        let inset = size * 0.2
        let names: [(String, CGPoint)] = [
            ("L+", CGPoint(x: center.x - radius + inset, y: center.y - radius + inset)),
            ("R+", CGPoint(x: center.x + radius - inset, y: center.y - radius + inset)),
            ("R-", CGPoint(x: center.x - radius + inset, y: center.y + radius - inset)),
            ("L-", CGPoint(x: center.x + radius - inset, y: center.y + radius - inset))
        ]
        for (name, at) in names {
            context.draw(Text(name)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary),
                         at: at, anchor: .center)
        }
    }

    // MARK: 包絡線

    /// 角度ごとのピークを結んだ輪（stereo_meter.js:641-653）。
    /// gain は Gain の倍率（v2.11.0 の stereo_meter.js:671）。
    private static func drawEnvelope(_ context: inout GraphicsContext, _ plot: ETPlot,
                                     _ envelope: [Double], gain: Double) {
        guard envelope.count == envelopeBins else { return }
        let rect = plot.rect
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) * 0.45

        var path = Path()
        for bin in 0..<envelopeBins {
            let radians = Double(bin) * .pi / 180
            // 上限 4 は倍率を掛けた後で切る。図の外へ大きく外れた点で Path を壊さない。
            let r = min(max(envelope[bin] * gain, 0), 4) * 0.5 * Double(radius)
            let point = CGPoint(x: center.x + CGFloat(cos(radians) * r),
                                y: center.y + CGFloat(sin(radians) * r))
            if bin == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        context.stroke(path, with: ETGraphShading.muted,
                       style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
    }

    /// σ = 5°、±15°のガウスでならす（stereo_meter.js:620-636）。
    private static let gaussian: [Double] = {
        let sigma = 5.0
        return (-15...15).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
    }()

    private static func smooth(_ peaks: [Float]) -> [Double] {
        guard peaks.count == envelopeBins else { return [] }
        let weights = gaussian
        let total = weights.reduce(0, +)
        guard total > 0 else { return [] }
        return (0..<envelopeBins).map { bin in
            var sum = 0.0
            for (k, weight) in weights.enumerated() {
                let angle = ((bin + k - 15) % envelopeBins + envelopeBins) % envelopeBins
                sum += Double(peaks[angle]) * weight
            }
            return sum / total
        }
    }

    // MARK: 縁の棒

    /// 相関。左端の縦棒（stereo_meter.js:692-700）。中心から上が正、下が負。
    private static func drawCorrelationBar(_ context: inout GraphicsContext, _ plot: ETPlot,
                                           _ correlation: Double) {
        let rect = plot.rect
        let centerY = rect.midY
        let value = min(max(correlation, -1), 1)
        let length = CGFloat(abs(value)) * rect.height / 2
        guard length > 0.5 else { return }
        let bar = CGRect(x: rect.minX, y: value >= 0 ? centerY - length : centerY,
                         width: barThickness, height: length)
        context.fill(Path(bar), with: ETGraphShading.curve)
    }

    /// 相関の目盛り（stereo_meter.js:702-718）。3 本だけ（同 707）。字は toFixed(1)（同 717）。
    private static func drawCorrelationTicks(_ context: inout GraphicsContext, _ plot: ETPlot) {
        let rect = plot.rect
        let centerY = rect.midY
        let half = rect.height / 2
        let tickX = rect.minX + 2
        var ticks = Path()
        for tick in [0.5, 0.0, -0.5] {
            let y = centerY - CGFloat(tick) * half
            ticks.move(to: CGPoint(x: tickX + 16, y: y))
            ticks.addLine(to: CGPoint(x: tickX + 21, y: y))
            context.draw(tickText(String(format: "%.1f", tick)),
                         at: CGPoint(x: tickX + 23, y: y), anchor: .leading)
        }
        context.stroke(ticks, with: ETGraphShading.muted, lineWidth: 1)
    }

    /// 左右差。下端の横棒（stereo_meter.js:720-731）。中心から右が R 寄り。
    private static func drawBalanceBar(_ context: inout GraphicsContext, _ plot: ETPlot,
                                       _ balance: Double) {
        let rect = plot.rect
        let centerX = rect.midX
        let value = min(max(balance, -energyMax), energyMax)
        let length = CGFloat(value / energyMax) * rect.width / 2
        guard abs(length) > 0.5 else { return }
        let bar = CGRect(x: length >= 0 ? centerX : centerX + length,
                         y: rect.maxY - barThickness,
                         width: abs(length), height: barThickness)
        context.fill(Path(bar), with: ETGraphShading.curve)
    }

    /// 左右差の目盛り（stereo_meter.js:733-749）。字には dB を付ける（同 748）。
    private static func drawBalanceTicks(_ context: inout GraphicsContext, _ plot: ETPlot) {
        let rect = plot.rect
        let centerX = rect.midX
        let half = rect.width / 2
        let tickBaseY = rect.maxY - 2
        var ticks = Path()
        for tick in [-12.0, -6, 0, 6, 12] {
            let x = centerX + CGFloat(tick / energyMax) * half
            ticks.move(to: CGPoint(x: x, y: tickBaseY - 21))
            ticks.addLine(to: CGPoint(x: x, y: tickBaseY - 16))
            context.draw(tickText("\(Int(tick))dB"),
                         at: CGPoint(x: x, y: tickBaseY - 23), anchor: .bottom)
        }
        context.stroke(ticks, with: ETGraphShading.muted, lineWidth: 1)
    }

    /// 2 本の棒の名前（stereo_meter.js:751-760）。下は横、左は縦に回す。
    private static func drawAxisNames(_ context: inout GraphicsContext, _ plot: ETPlot) {
        let rect = plot.rect
        context.draw(axisText("LR Balance"),
                     at: CGPoint(x: rect.midX, y: rect.maxY - 1), anchor: .bottom)
        context.drawLayer { layer in
            layer.translateBy(x: rect.minX + 20, y: rect.midY)
            layer.rotate(by: .degrees(-90))
            layer.draw(axisText("LR Correlation"), at: CGPoint(x: 0, y: -3), anchor: .bottom)
        }
    }

    private static func tickText(_ s: String) -> Text {
        Text(s)
            .font(.system(size: ETGraphMetrics.labelSize, design: .monospaced))
            .foregroundStyle(.secondary)
    }

    private static func axisText(_ s: String) -> Text {
        Text(s).font(.system(size: 10)).foregroundStyle(.secondary)
    }

    // MARK: 枠を読む

    private struct Reading {
        var sampleRate: Float
        /// x, y が交互。x = R - L、y = L + R。
        var samples: [Float]
        var envelope: [Float]
        var correlation: Float
        var balance: Float
        var sequence: UInt32
    }

    private var reading: Reading? {
        guard let frame = telemetry.frame(tap: tapId, type: .stereoField),
              frame.matches(version: 2) else { return nil }

        let payload = frame.payloadView
        guard let sampleRate = payload.f32(at: 0),
              let count16 = payload.u16(at: 4),
              let flags = payload.u16(at: 6) else { return nil }

        let count = Int(count16)
        let envelopeOffset = 8 + count * 8
        let statisticsOffset = envelopeOffset + Self.envelopeBins * 4

        // stereo_meter.js:344-352 と同じ門。
        guard sampleRate.isFinite, sampleRate > 0, sampleRate <= 768000,
              count <= 8000, flags & ~UInt16(1) == 0,
              payload.count == statisticsOffset + 16 else { return nil }

        guard let samples = payload.floats(at: 8, count: count * 2),
              let envelope = payload.floats(at: envelopeOffset, count: Self.envelopeBins),
              let correlation = payload.f32(at: statisticsOffset),
              let balance = payload.f32(at: statisticsOffset + 4),
              let peakL = payload.f32(at: statisticsOffset + 8),
              let peakR = payload.f32(at: statisticsOffset + 12) else { return nil }

        // peakL / peakR は描かないが、上流と同じ門にしておく（stereo_meter.js:381-382）。
        guard !envelope.contains(where: { !$0.isFinite || $0 < 0 }),
              correlation.isFinite, correlation >= -1, correlation <= 1,
              balance.isFinite,
              peakL.isFinite, peakL >= 0, peakR.isFinite, peakR >= 0 else { return nil }

        return Reading(sampleRate: sampleRate, samples: samples, envelope: envelope,
                       correlation: correlation, balance: balance, sequence: frame.sequence)
    }
}

// MARK: - 点を貯める輪

/// ゴニオメーターの点を貯める輪。
///
/// 上流は worklet 側が持つ 1 秒ぶんの輪を Window の長さだけ遡り、古い→新しいで
/// 256 段の濃さを付けて全部打つ（stereo_meter.js:584-618）。
/// こちらに来るのは前回の書き出しからの差分だけ（kernel.cpp:344-347）なので、
/// 同じ輪をここに持って繋ぎ直す。
///
/// 遡る数は「Window の長さ × ここに入れている 1 秒あたりの点の数」で数える。
/// 上流は Window ぶんの標本を 1 本残らず打つが、こちらはそれより粗い。理由は 2 つ。
///   入れるときに間引いている（48kHz なら 1/3、下の skip）
///   DSP は 60Hz で吐き、Telemetry は tap と種類ごとに最新の 1 枠しか残さず、
///   読み出しは 1/30 秒ごと（PipelineView の pollTelemetry）なので枠が半分落ちる
/// 打つ点の数は上流の 1/skip、それが覆う実時間は Window のおよそ 2 倍になる。
final class ETStereoTrail: ObservableObject {

    /// 貯める点の数。上流の Window の上限 1 秒（stereo_meter.js:247）に合わせてある。
    /// 96kHz の生の数（96000）は持てないので、入れるときに間引いて 1 秒がここに収まるようにする。
    static let capacity = 16384
    /// 1 回の描き直しで Path に積む点の上限。
    static let maxDrawn = 4000
    /// 古い→新しいの濃さの段数。上流は 256 段（stereo_meter.js:528-535、色は背景と
    /// trace の混色）。こちらは 1 段につき fill が 1 回増えるので 32 段に落としてある。
    static let shades = 32

    /// 中身が変わったことだけを知らせる。配列そのものは publish しない。
    @Published private(set) var revision: UInt32 = 0

    private var xs = [Float](repeating: 0, count: ETStereoTrail.capacity)
    private var ys = [Float](repeating: 0, count: ETStereoTrail.capacity)
    private var head = 0
    private var count = 0
    /// 音 1 秒あたり何点入れているか。遡る数を出すのに使う。
    private var storedRate: Double = 0
    private var lastSequence: UInt32?

    func push(samples: [Float], sampleRate: Double, sequence: UInt32) {
        guard sampleRate > 0 else { return }
        // 同じ枠を 2 度入れない。描き直しのたびに点が増えてしまう。
        if let previous = lastSequence, previous == sequence { return }
        lastSequence = sequence

        // 切り上げる。1 秒ぶんが capacity に必ず収まるようにしておく。
        let skip = max(1, Int((sampleRate / Double(Self.capacity)).rounded(.up)))
        let rate = sampleRate / Double(skip)
        if rate != storedRate {
            // 間隔が変わると「何点前が何秒前か」が合わなくなるので捨てる。
            head = 0
            count = 0
            storedRate = rate
        }

        let pairs = samples.count / 2
        var i = 0
        while i < pairs {
            xs[head] = samples[i * 2]
            ys[head] = samples[i * 2 + 1]
            head = (head + 1) % Self.capacity
            if count < Self.capacity { count += 1 }
            i += skip
        }
        revision &+= 1
    }

    func reset() {
        head = 0
        count = 0
        lastSequence = nil
        revision &+= 1
    }

    /// Window の長さだけ遡って打つ（stereo_meter.js:595-618）。
    /// gain は Gain の倍率（v2.11.0 の stereo_meter.js:627-628）。
    func draw(_ context: inout GraphicsContext, _ plot: ETPlot, seconds: Double,
              gain: Double = 1) {
        guard count > 0, storedRate > 0, seconds > 0 else { return }
        let needed = min(count, max(1, Int((seconds * storedRate).rounded())))
        let step = max(1, needed / Self.maxDrawn)

        let rect = plot.rect
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) * 0.45
        let start = (head - needed + Self.capacity) % Self.capacity

        var paths = [Path](repeating: Path(), count: Self.shades)
        var i = 0
        while i < needed {
            let slot = (start + i) % Self.capacity
            let x = Double(xs[slot])
            let y = Double(ys[slot])
            // 古い→新しいで 0→1（同 601-603）。
            let shade = needed > 1
                ? min(Self.shades - 1, i * Self.shades / (needed - 1))
                : Self.shades - 1
            i += step
            guard x.isFinite, y.isFinite else { continue }
            // ひし形の外へ大きく外れた点で Path を壊さないよう、ほどほどで止める。
            // 倍率を掛けた後で止める。
            let cx = min(max(x * gain, -4), 4)
            let cy = min(max(y * gain, -4), 4)
            let px = center.x + CGFloat(cx * 0.5) * radius
            let py = center.y - CGFloat(cy * 0.5) * radius
            paths[shade].addRect(CGRect(x: px - 0.75, y: py - 0.75, width: 1.5, height: 1.5))
        }

        for (shade, path) in paths.enumerated() where !path.isEmpty {
            // 一番古い点は上流でも背景と同じ色になる＝見えない。
            let opacity = Double(shade) / Double(Self.shades - 1)
            guard opacity > 0 else { continue }
            context.opacity = opacity
            context.fill(path, with: ETGraphShading.curve)
        }
        context.opacity = 1
    }
}

// MARK: - Window のつまみ

/// 上流は ms で見せて秒で持つ（stereo_meter.js:208-214 の createParameterControl と
/// 同 211 の value / 1000）。EffectCatalog は秒のままなので、この行だけ 1000 倍して出す。
private struct StereoWindowRow: View {

    let param: ETParam
    let nodeIndex: Int
    let values: [Float]

    @ObservedObject var dsp: EffeTuneDSP

    @Environment(\.etGraphOnly) private var graphOnly
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    /// stereo_meter.js:209 の 10〜1000ms、刻み 1。
    private static let range: ClosedRange<Double> = 10...1000

    private var milliseconds: Double {
        let seconds = values.indices.contains(param.offset)
            ? Double(values[param.offset]) : Double(param.defaultValue)
        guard seconds.isFinite else { return Self.range.lowerBound }
        return min(max(seconds * 1000, Self.range.lowerBound), Self.range.upperBound)
    }

    private func set(_ ms: Double) {
        guard ms.isFinite else { return }
        let clamped = min(max(ms, Self.range.lowerBound), Self.range.upperBound)
        dsp.setValue(Float(clamped / 1000), at: nodeIndex, offset: param.offset)
    }

    var body: some View {
        if graphOnly {
            EmptyView()
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(param.label + " (ms)")
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                field
            }
            Slider(value: Binding(get: { milliseconds }, set: { set($0) }),
                   in: Self.range, step: 1)
        }
        .padding(.vertical, 2)
    }

    /// 数値欄。ParameterRow と同じく常に TextField を置く
    /// （Text + onTapGesture だと支援技術から操作できない）。
    private var field: some View {
        TextField(param.label, text: Binding(get: { editing ? draft : text },
                                             set: { draft = $0 }))
            .keyboardType(.numbersAndPunctuation)
            .multilineTextAlignment(.center)
            .font(.system(size: 13, design: .monospaced))
            .focused($focused)
            .frame(width: ETMetrics.valueWidth, height: ETMetrics.controlHeight)
            .background(.quaternary, in: .rect(cornerRadius: ETMetrics.innerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: ETMetrics.innerRadius, style: .continuous)
                .stroke(.tint, lineWidth: editing ? 1 : 0))
            .submitLabel(.done)
            .onSubmit { commit() }
            .onChange(of: focused) { _, now in
                if now {
                    draft = plain
                    editing = true
                } else if editing {
                    // 他を触ってキーボードが引っ込んだときも確定させる。
                    commit()
                }
            }
            .accessibilityLabel(param.label)
            .accessibilityValue(text)
    }

    /// 上流の表示は (windowTime * 1000).toFixed(0)（stereo_meter.js:210）。
    private var plain: String { String(Int(milliseconds.rounded())) }

    private var text: String { plain + " ms" }

    private func commit() {
        editing = false
        focused = false
        guard let typed = Double(draft.trimmingCharacters(in: .whitespaces)) else { return }
        set(typed)
    }
}
