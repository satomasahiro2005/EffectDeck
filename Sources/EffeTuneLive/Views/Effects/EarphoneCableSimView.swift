//  EarphoneCableSimView.swift
//  Earphone Cable Sim（EarphoneCableSimPlugin）。
//
//  この効果はパラメータが全部 DSP にある（floatCount 25、
//  Generated/EffectCatalog.swift:500-518）ので、図が描ける。
//
//  掴む印は web 版にも無い。plugins/eq/earphone_cable_sim.js:546-574 の createUI は
//  格子の SVG と曲線の SVG を置くだけで、マーカーを 1 つも作っていない。
//  なので**描くだけ**にして、触ったときは値を読むだけにしてある。
//
//  --- 図の取り方（web 版と同じ）---
//    横 10Hz〜40kHz の対数        earphone_cable_sim.js:688-690 freqToX、804-805
//    縦 dB。範囲は自動            同 692-695 gainToY と 818-823
//        曲線の最大絶対値から [0.5,1,1.5,3,6,12,24,48]（同 820）の最初に収まる段を
//        目盛りの端にして、軸の範囲だけ 1.1 倍（同 823。曲線が枠に触らないように）
//    0dB の位置                   同 793-802
//        20Hz〜20kHz を対数で 256 点取ったパワー平均を 0dB に置く
//
//  --- 曲線の中身 ---
//  web 版は有理式を因数分解して matched-Z で双二次の縦続に落とし、その振幅を描く
//  （同 331-405 _buildSos、778-838 updateResponse）。ここでは離散化する前の
//  有理式をそのまま評価している。同じものになる理由は ECSModel の頭に書いた。
//
//  違いは 2 つある。どちらも承知のうえ:
//    - Nyquist より上。web 版は評価点を Nyquist 直下で止める（同 791 と 813）。
//      EffeTuneDSP がサンプルレートを外に出していないので、こちらは止めていない。
//      40kHz 付近は「アナログの狙い」であって、実際に効いている形とは少しずれる。
//    - matched-Z の誤差。周波数はずれないが振幅は高域でわずかに違う（同 369-377 の註）。

import SwiftUI
import Foundation

// MARK: - 物理モデル

/// 共鳴 1 つ。earphone_cable_sim.js:306-316 の _zload の和の 1 項。
private struct ECSResonance {
    var frequency: Double   // Hz
    var q: Double
    var impedance: Double   // ohm（山の高さ）
}

/// 送り出し（出力インピーダンス＋ケーブル）と、イヤホンの負荷インピーダンスの分圧。
///
///     H(f) = Zload / (Zsource + Zload)
///     Zsource = (zo + rc) + jωLc
///     Zload   = zb + jωLv + Σ (rz - zb) / (1 + jQ(f/f0 - f0/f))
///
/// web 版の _buildSos が組む有理式と同じもの。あちらは σ = s/ω_ref の多項式で持っていて、
/// Nload = (zb + Lv·σ)·Dprod + Σ (rz-zb)·σ·others、Den = (Rs + Lc·σ)·Dprod + Nload
/// （earphone_cable_sim.js:360-367）。Dk(σ) = σ·(1 + jQ(f/f0 - f0/f)) なので
/// （同 347 の [q·x0, 1, q/x0] に σ = j·f/1000 を入れると出る）、
/// 両方を Dprod で割ると Nload/Dprod = _zload(f)（同 306-316）、
/// Den/Dprod = Zsource + Zload になり、比は上の分圧そのものになる。
/// カーネルも同じ組み方（dsp/plugins/eq/earphone_cable_sim/kernel.cpp:401-430）。
private struct ECSModel {
    /// 出力インピーダンス + ケーブルの直流抵抗（ohm）。
    var seriesResistance: Double
    /// ケーブルのインダクタンス（H）。
    var cableInductance: Double
    /// 公称インピーダンス（ohm）。
    var baseImpedance: Double
    /// ボイスコイルのインダクタンス（H）。
    var voiceCoilInductance: Double
    var resonances: [ECSResonance]

    /// |H(f)|。線形。
    func magnitude(at hz: Double) -> Double {
        guard hz > 0 else { return 1 }
        let omega = 2 * Double.pi * hz

        var loadReal = baseImpedance
        var loadImaginary = omega * voiceCoilInductance
        for resonance in resonances {
            // (rz - zb) / (1 + jQ·ratio) を実部と虚部に分けて足す。
            let ratio = hz / resonance.frequency - resonance.frequency / hz
            let imaginary = resonance.q * ratio
            let denominator = 1 + imaginary * imaginary
            guard denominator.isFinite, denominator > 0 else { continue }
            let numerator = resonance.impedance - baseImpedance
            loadReal += numerator / denominator
            loadImaginary -= numerator * imaginary / denominator
        }

        let totalReal = seriesResistance + loadReal
        let totalImaginary = omega * cableInductance + loadImaginary

        let load = (loadReal * loadReal + loadImaginary * loadImaginary).squareRoot()
        let total = (totalReal * totalReal + totalImaginary * totalImaginary).squareRoot()
        guard load.isFinite, total.isFinite, total > 1e-12 else { return 1 }
        return load / total
    }
}

// MARK: - 画面

struct EarphoneCableSimView: View {

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    /// 指で触っている周波数。掴んで動かす印は web 版にも無いので、読むだけ。
    @State private var probeHz: Double?
    @Environment(\.etGraphOnly) private var graphOnly

    /// 共鳴の何番目を触っているか。ParameterRow のバンドタブと同じ考え方。
    @State private var slot = 0

    private static let lowFrequency: Double = 10
    private static let highFrequency: Double = 40000
    private static let curveSteps = 240
    /// 目盛りの段。earphone_cable_sim.js:820
    private static let labelSteps: [Double] = [0.5, 1, 1.5, 3, 6, 12, 24, 48]

    /// 生成されたカタログは配列の既定値を拾えていない
    /// （Tools/gen_catalog.py:111-114 で list を float に直せず 0 が入る）。
    /// 共鳴の周波数が 0 のままだと f/f0 - f0/f が発散して図が出せないので、
    /// web 版の初期値（earphone_cable_sim.js:31-38 RES_DEFAULTS）を最初の 1 回だけ入れる。
    /// 入切（re）には触らない。あれは音が変わる。
    private static let initialFrequencies: [Float] = [120, 2000, 5000, 9000, 60]
    private static let initialQ: [Float] = [2.0, 1.5, 2.0, 3.0, 1.5]
    private static let initialImpedance: [Float] = [48, 36, 64, 80, 64]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            graph

            ForEach(scalarParams) { param in
                ParameterRow(param: param, nodeIndex: index, values: node.values, dsp: dsp)
            }

            // **畳んだら札も消す。**畳んだ図は allowsHitTesting(false) で押せない
            // （EffectCardView の畳んだ図）ので、押せない札を残しても場所を取るだけ。
            if !graphOnly { resonanceSection }
        }
        .onAppear { seedResonancesIfNeeded() }
        // 畳むとこの View ごと消えるので、触っている共鳴は外に覚えておく。
        .etRemembers($slot, key: "slot", node: node.id)
    }

    /// まだ何も入っていないときだけ埋める。
    /// 共鳴の周波数の下限は 20Hz なので、下回っていれば未設定と分かる。
    private func seedResonancesIfNeeded() {
        guard let frequency = arrayParam("resonanceFrequency") else { return }
        let count = frequency.count
        guard (0..<count).allSatisfy({ value("resonanceFrequency", $0) < 20 }) else { return }

        seed(frequency, Self.initialFrequencies)
        if let q = arrayParam("resonanceQ") { seed(q, Self.initialQ) }
        if let impedance = arrayParam("resonanceImpedance") { seed(impedance, Self.initialImpedance) }
    }

    private func seed(_ param: ETParam, _ values: [Float]) {
        for i in 0..<min(param.count, values.count) {
            dsp.setValue(values[i], at: index, offset: param.offset + i)
        }
    }

    // MARK: 図

    private var graph: some View {
        let points = curve
        let peak = points.reduce(0.0) { max($0, abs($1.db)) }
        let outermost = Self.labelMagnitude(peak)
        let probe = probeHz
        let probeDecibels = probe.flatMap { Self.decibels(at: $0, in: points) }

        return GraphCanvas(
            x: .frequency(Self.lowFrequency, Self.highFrequency),
            y: Self.decibelAxis(labelMagnitude: outermost),
            height: ETGraphMetrics.height,
            insets: .standard,
            readout: Self.readout(hz: probe, decibels: probeDecibels),
            clipsContent: true,
            draw: { context, plot in
                var path = Path()
                for (i, point) in points.enumerated() {
                    let position = plot.point(point.hz, point.db)
                    if i == 0 { path.move(to: position) } else { path.addLine(to: position) }
                }
                context.stroke(path, with: ETGraphShading.curve,
                               style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                // 触っている所。指の下は見えないので、数値は図の外（上）に出す。
                if let hz = probe, let decibels = probeDecibels {
                    let position = plot.clampedPoint(hz, decibels)
                    var line = Path()
                    line.move(to: CGPoint(x: position.x, y: plot.rect.minY))
                    line.addLine(to: CGPoint(x: position.x, y: plot.rect.maxY))
                    context.stroke(line, with: ETGraphShading.grid,
                                   style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    context.stroke(Path(ellipseIn: CGRect(x: position.x - 5, y: position.y - 5,
                                                          width: 10, height: 10)),
                                   with: ETGraphShading.curve, lineWidth: 2)
                }
            },
            overlay: { plot in
                // 動かすものが無いので、一覧の縦スクロールと同時に効かせる。
                Color.clear
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { touch in
                                probeHz = plot.xAxis.clamp(plot.xValue(at: touch.location.x))
                            }
                            .onEnded { _ in probeHz = nil })
            })
    }

    /// 描く点。0dB は 20Hz〜20kHz のパワー平均に置く（earphone_cable_sim.js:793-802）。
    private var curve: [ETFreqPoint] {
        let model = self.model
        let reference = Self.referenceDecibels(model)
        let lower = log10(Self.lowFrequency)
        let upper = log10(Self.highFrequency)
        return (0...Self.curveSteps).map { i -> ETFreqPoint in
            let t = Double(i) / Double(Self.curveSteps)
            let hz = pow(10, lower + t * (upper - lower))
            let magnitude = max(model.magnitude(at: hz), 1e-12)
            return ETFreqPoint(hz, 20 * log10(magnitude) - reference)
        }
    }

    /// 0dB の基準。20Hz〜20kHz を対数で 256 点。
    private static func referenceDecibels(_ model: ECSModel) -> Double {
        let count = 256
        var sum = 0.0
        for i in 0..<count {
            let hz = 20 * pow(1000, Double(i) / Double(count - 1))
            let magnitude = model.magnitude(at: hz)
            sum += magnitude * magnitude
        }
        let mean = sum / Double(count)
        return mean > 0 ? 10 * log10(mean) : 0
    }

    /// 目盛りの端。曲線の最大絶対値が収まる最初の段。
    private static func labelMagnitude(_ peak: Double) -> Double {
        let wanted = max(0.5, peak)
        return labelSteps.first { wanted <= $0 } ?? 48
    }

    /// 目盛りは ±label・±label/2・0 の 5 本。軸の範囲だけ 1.1 倍にして、
    /// 曲線と字が枠に触らないようにする（earphone_cable_sim.js:823）。
    private static func decibelAxis(labelMagnitude m: Double) -> ETAxis {
        let ticks = [m, m / 2, 0, -m / 2, -m].map {
            ETAxisTick($0, tickLabel($0), emphasized: $0 == 0)
        }
        return ETAxis(scale: .linear, lower: -m * 1.1, upper: m * 1.1, ticks: ticks)
    }

    private static func tickLabel(_ value: Double) -> String {
        let text = value == value.rounded() ? String(format: "%.0f", value)
                                            : String(format: "%.1f", value)
        return value > 0 ? "+" + text : text
    }

    /// 触った周波数の dB。点と点の間は対数の横軸の上で線で結ぶ。
    private static func decibels(at hz: Double, in points: [ETFreqPoint]) -> Double? {
        guard let first = points.first, let last = points.last else { return nil }
        if hz <= first.hz { return first.db }
        if hz >= last.hz { return last.db }
        for i in 1..<points.count {
            let a = points[i - 1]
            let b = points[i]
            if hz <= b.hz {
                let span = log10(b.hz) - log10(a.hz)
                guard span > 0 else { return b.db }
                let t = (log10(hz) - log10(a.hz)) / span
                return a.db + t * (b.db - a.db)
            }
        }
        return last.db
    }

    private static func readout(hz: Double?, decibels: Double?) -> [ETReadoutItem] {
        guard let hz else { return [] }
        var items = [ETReadoutItem("FREQ", ETFormat.hz(hz))]
        if let decibels { items.append(ETReadoutItem("LEVEL", ETFormat.gain(decibels, decimals: 2))) }
        return items
    }

    // MARK: 値

    private var model: ECSModel {
        var resonances: [ECSResonance] = []
        for element in 0..<resonanceCount {
            guard value("resonanceEnabled", element) >= 0.5 else { continue }
            let frequency = value("resonanceFrequency", element)
            let q = value("resonanceQ", element)
            // 生成されたカタログは配列の既定値を拾えておらず 0 が入っている
            // （Generated/EffectCatalog.swift:507 と 514-517）。f=0 だと f/f0 - f0/f が
            // 発散するので、その枠は無かったことにする。
            guard frequency > 0, frequency.isFinite, q > 0, q.isFinite else { continue }
            resonances.append(ECSResonance(frequency: frequency, q: q,
                                           impedance: value("resonanceImpedance", element)))
        }
        return ECSModel(
            seriesResistance: value("outputImpedance") + value("cableResistance"),
            cableInductance: value("cableInductance") * 1e-6,        // uH -> H
            baseImpedance: value("baseImpedance"),
            voiceCoilInductance: value("voiceCoilInductance") * 1e-3, // mH -> H
            resonances: resonances)
    }

    /// 名前で引く。offset を直に書くと、カタログを作り直したときに黙ってずれる。
    private func value(_ name: String, _ element: Int = 0) -> Double {
        guard let param = node.spec.params.first(where: { $0.name == name }) else { return 0 }
        let offset = param.offset + element
        guard node.values.indices.contains(offset) else { return 0 }
        return Double(node.values[offset])
    }

    private func arrayParam(_ name: String) -> ETParam? {
        node.spec.params.first { $0.name == name && $0.isArray }
    }

    private var scalarParams: [ETParam] {
        node.spec.params.filter { !$0.isArray }
    }

    private var resonanceCount: Int {
        arrayParam("resonanceFrequency")?.count ?? 5
    }

    // MARK: 共鳴

    /// 共鳴は 4 つの配列（周波数・Q・インピーダンス・入切）が同じ 5 枠を指している。
    /// ParameterRow をそのまま 4 本並べるとタブが 4 つ出て、どれがどれか分からなくなるので、
    /// 枠を選ぶタブは 1 つにして、その枠の 4 つの値をまとめて出す。
    private var resonanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RESONANCES")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)

            slotPicker

            if let enabled = arrayParam("resonanceEnabled") {
                resonanceToggle(enabled)
            }
            if let frequency = arrayParam("resonanceFrequency") {
                resonanceSlider(frequency)
            }
            if let q = arrayParam("resonanceQ") {
                resonanceSlider(q)
            }
            if let impedance = arrayParam("resonanceImpedance") {
                resonanceSlider(impedance)
            }
        }
    }

    private var slotPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(0..<resonanceCount, id: \.self) { i in
                    Button {
                        slot = i
                    } label: {
                        Text("\(i + 1)")
                            .font(.system(size: 12, weight: slot == i ? .bold : .regular))
                            .foregroundStyle(slot == i ? AnyShapeStyle(.white)
                                                       : AnyShapeStyle(.secondary))
                            .frame(minWidth: 30, minHeight: 26)
                            .background(slot == i ? AnyShapeStyle(.tint)
                                                  : AnyShapeStyle(.quaternary),
                                        in: .rect(cornerRadius: ETMetrics.innerRadius, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: ETMetrics.innerRadius, style: .continuous)
                                    .stroke(.tint, lineWidth: isSlotEnabled(i) ? 1 : 0))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func isSlotEnabled(_ element: Int) -> Bool {
        value("resonanceEnabled", element) >= 0.5
    }

    private func resonanceToggle(_ param: ETParam) -> some View {
        let offset = param.offset + slot
        let isOn = node.values.indices.contains(offset) && node.values[offset] >= 0.5
        return Toggle(isOn: Binding(get: { isOn },
                                    set: { dsp.setValue($0 ? 1 : 0, at: index, offset: offset) })) {
            Text("Resonance \(slot + 1)").font(.system(size: 14))
        }
    }

    /// ParameterRow の数値行と同じ組み方。違うのは枠（slot）を外から渡している所だけ。
    @ViewBuilder
    private func resonanceSlider(_ param: ETParam) -> some View {
        let offset = param.offset + slot
        let current = node.values.indices.contains(offset) ? node.values[offset] : 0
        if case .number(let lower, let upper, let step, _, let isInteger) = param.kind,
           upper > lower {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(param.label)
                        .font(.system(size: 14))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 4)
                    ETValueField(text: param.format(current), label: param.label,
                                 editText: { ETNumberText.draft(Double(current)) }) { typed in
                        let clamped = min(max(Float(typed), lower), upper)
                        dsp.setValue(isInteger ? clamped.rounded() : clamped,
                                     at: index, offset: offset)
                    }
                }
                Slider(
                    value: Binding(
                        // 既定が範囲の外（Q の既定 0、最小 0.5）でも滑子が飛ばないように挟む。
                        get: { Double(min(max(current, lower), upper)) },
                        set: { dsp.setValue(isInteger ? Float($0.rounded()) : Float($0),
                                            at: index, offset: offset) }),
                    in: Double(lower)...Double(upper),
                    step: step > 0 ? Double(step) : (isInteger ? 1 : 0))
            }
        }
    }
}
