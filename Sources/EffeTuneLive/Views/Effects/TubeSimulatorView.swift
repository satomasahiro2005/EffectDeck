//  TubeSimulatorView.swift
//  Tube Simulator（saturation/tube_simulator）。
//
//  web 版は plugins/saturation/tube_simulator.js。図はプレート特性（横 Vak / 縦 Ia）に
//  ロードラインを重ね、テレメトリで来た動作点を薄れる尾として点で置いたもの
//  （同 7058 _drawHud、7220 _drawPlateCharacteristics、7247 _drawTrajectory）。
//
//  web 版のキャンバスは掴めない。pointerdown を張っているのは Output Safety Trim の
//  入力欄だけで（同 6285）、掴んだ瞬間に「いま効いている減衰込みの値」を設定値へ
//  取り込む。これが Tube Simulator の掴む操作なので、そこはそのまま移した。
//  図の側は指で触ると値を読むだけにしてある（動作点は DSP が出す測定値で、
//  指で動かせるものではない）。
//
//  web は Stage1/Stage2（または Push/Pull）を横に 2 枚並べるが、390pt では 1 枚 180pt
//  になって軸の字が潰れる。面を選ぶ帯を 1 本足して、図は常に幅いっぱいの 1 枚にした。

import SwiftUI
import Foundation

// MARK: - テレメトリ

/// 1 チャンネルぶんの動作点。20 要素の並びは
/// dsp/plugins/saturation/tube_simulator/kernel.cpp:6472-6507 が書いている順。
/// 名前は plugins/saturation/tube_simulator.js:11-16 の TUBE_SIMULATOR_TELEMETRY_FIELDS と同じ。
struct ETTubeOperatingPoint {
    let f: [Double]

    var vk1: Double { f[0] }                    // cathode[0].voltage
    var vk2: Double { f[1] }                    // cathode[1].voltage
    var vbPlus: Double { f[2] }                 // supply.voltage
    var vgk1: Double { f[3] }                   // stage0 grid - cathode
    var vak1: Double { f[4] }                   // stage0 plate - cathode
    var ia1: Double { f[5] }                    // stage0 plate current [A]
    var vgk2: Double { f[6] }
    var vak2: Double { f[7] }
    var ia2: Double { f[8] }
    var ltpBalanceV: Double { f[9] }
    var powerPlatePushV: Double { f[10] }       // platePushV - cathodePushV
    var powerPlatePullV: Double { f[11] }
    var powerIaPushA: Double { f[12] }
    var powerIaPullA: Double { f[13] }
    var powerBPlusV: Double { f[14] }
    var screenPushV: Double { f[15] }
    var screenPullV: Double { f[16] }
    var transformerFluxWb: Double { f[17] }
    var speakerVrms100ms: Double { f[18] }
    var speakerRealPower100ms: Double { f[19] }
}

/// frameType 19 / formatVersion 2 / payload 164 バイト（41 float）。
/// 20 float ×2 チャンネル ＋ 末尾 1 語が自動減衰量（kernel.cpp:266-272, 6512）。
struct ETTubeTelemetry {
    let left: ETTubeOperatingPoint
    let right: ETTubeOperatingPoint
    /// 常に 0 以下。0 dB でも publish される（kernel.cpp:6510-6512 のコメント）。
    let safetyReductionDb: Double

    static let channelStride = 20
    static let safetyIndex = 40
    static let payloadBytes = 164

    static func read(_ frame: ETFrame) -> ETTubeTelemetry? {
        guard frame.matches(version: 2), frame.hasPayload(bytes: payloadBytes) else { return nil }
        let payload = frame.payloadView
        guard let words = payload.floats(at: 0, count: 41) else { return nil }
        guard words.allSatisfy({ $0.isFinite }) else { return nil }
        let left = (0..<channelStride).map { Double(words[$0]) }
        let right = (0..<channelStride).map { Double(words[channelStride + $0]) }
        return ETTubeTelemetry(left: ETTubeOperatingPoint(f: left),
                               right: ETTubeOperatingPoint(f: right),
                               safetyReductionDb: Double(words[safetyIndex]))
    }
}

/// 尾に積む 1 枚。時刻は薄れ方に使う。
private struct ETTubeTrailSample {
    let time: TimeInterval
    let left: ETTubeOperatingPoint
    let right: ETTubeOperatingPoint
}

// MARK: - 球の素性

/// プレート特性を引くための定数。
/// 三極管の式は js:698 evaluateTubeSimulatorHudPlateCurrent と同じ。
struct ETTubeProfile {
    let mu: Double
    let ka: Double
    let alpha: Double
    let v0: Double
    let sc: Double
    let vs: Double
    let iaMax: Double
    let vgkSteps: [Double]
    /// ドライバ段だけが持つ負荷抵抗。出力段は 0。
    let plateResistance: Double
    /// SE 出力段だけが持つもの。静止点を解くのに要る。
    let standingCurrentA: Double
    let windingResistanceOhm: Double
    let powerTheveninResistanceOhm: Double

    init(mu: Double, ka: Double, alpha: Double, v0: Double, sc: Double, vs: Double,
         iaMax: Double, vgkSteps: [Double], plateResistance: Double = 0,
         standingCurrentA: Double = 0, windingResistanceOhm: Double = 0,
         powerTheveninResistanceOhm: Double = 0) {
        self.mu = mu
        self.ka = ka
        self.alpha = alpha
        self.v0 = v0
        self.sc = sc
        self.vs = vs
        self.iaMax = iaMax
        self.vgkSteps = vgkSteps
        self.plateResistance = plateResistance
        self.standingCurrentA = standingCurrentA
        self.windingResistanceOhm = windingResistanceOhm
        self.powerTheveninResistanceOhm = powerTheveninResistanceOhm
    }

    /// js:698-706。vak <= 0 は 0。
    func plateCurrent(vgk: Double, vak: Double) -> Double {
        guard vak > 0 else { return 0 }
        let z = (vgk + vak / mu - v0) / sc
        let softplus: Double = z > 32 ? z : (z < -32 ? exp(z) : log1p(exp(z)))
        let amplitude = ka * pow(sc * softplus, alpha)
        return amplitude * (1 - exp(-vak / vs))
    }
}

enum ETTubeProfiles {

    /// js:676-696 TUBE_SIMULATOR_HUD_PROFILES（定数は js:660-675 TUBE_SIMULATOR_TUBE_ROWS）。
    static let driver: [String: ETTubeProfile] = [
        "12AX7": ETTubeProfile(mu: 100, ka: 0.0010637222, alpha: 1.45, v0: -0.5866,
                               sc: 0.15, vs: 25, iaMax: 0.006,
                               vgkSteps: [-4, -3, -2, -1, 0], plateResistance: 100000),
        "12AT7": ETTubeProfile(mu: 60, ka: 0.0027035449, alpha: 1.4, v0: -0.3788,
                               sc: 0.15, vs: 22, iaMax: 0.012,
                               vgkSteps: [-6, -4.5, -3, -1.5, 0], plateResistance: 47000),
        "12AU7": ETTubeProfile(mu: 17, ka: 0.00097874385, alpha: 1.3, v0: 0.0014,
                               sc: 0.5, vs: 18, iaMax: 0.032,
                               vgkSteps: [-12, -9, -6, -3, 0], plateResistance: 22000)
    ]

    /// js:548-559 TUBE_SIMULATOR_SE_HUD_PROFILES（定数は js:528-547 TUBE_SIMULATOR_SE_TUBE_MODELS）。
    static let singleEnded: [String: ETTubeProfile] = [
        "300B": ETTubeProfile(mu: 3.85, ka: 0.000906, alpha: 1.5, v0: 9.35,
                              sc: 0.75, vs: 35, iaMax: 0.16,
                              vgkSteps: [-120, -100, -80, -60, -40, -20, 0],
                              standingCurrentA: 0.06, windingResistanceOhm: 120,
                              powerTheveninResistanceOhm: 150),
        "2A3": ETTubeProfile(mu: 4.2, ka: 0.000846, alpha: 1.5, v0: -2.62,
                             sc: 0.75, vs: 30, iaMax: 0.18,
                             vgkSteps: [-60, -50, -40, -30, -20, -10, 0],
                             standingCurrentA: 0.06, windingResistanceOhm: 105,
                             powerTheveninResistanceOhm: 120)
    ]

    /// js:726-762 solveTubeSimulatorSeHudQuiescent。ニュートン法 16 回。
    static func seQuiescent(_ p: ETTubeProfile, bPlusSource: Double,
                            cathodeResistance: Double) -> (currentA: Double, plateCathodeV: Double) {
        var current = p.standingCurrentA
        for _ in 0..<16 {
            let cathode = current * cathodeResistance
            let bPlus = bPlusSource - current * p.powerTheveninResistanceOhm
            let plate = bPlus - current * p.windingResistanceOhm
            let vak = plate - cathode
            let z = vak <= 0 ? -Double.infinity : (-cathode + vak / p.mu - p.v0) / p.sc
            let softplus: Double = z > 32 ? z : (z < -32 ? exp(z) : log1p(exp(z)))
            let exponential = exp(z >= 0 ? -z : z)
            let sigmoid = z >= 0 ? 1 / (1 + exponential) : exponential / (1 + exponential)
            let u = z.isFinite ? p.sc * softplus : 0
            let amplitude = u > 0 ? p.ka * pow(u, p.alpha) : 0
            let amplitudeDerivative = u > 0 ? p.ka * p.alpha * pow(u, p.alpha - 1) * sigmoid : 0
            let kneeExponential = vak > 0 ? exp(-vak / p.vs) : 1
            let knee = 1 - kneeExponential
            let tubeCurrent = amplitude * knee
            let gridDerivative = amplitudeDerivative * knee
            let plateDerivative = amplitudeDerivative * knee / p.mu + amplitude * kneeExponential / p.vs
            let residual = current - tubeCurrent
            let derivative = 1 + gridDerivative * cathodeResistance
                + plateDerivative * (p.powerTheveninResistanceOhm + p.windingResistanceOhm
                                     + cathodeResistance)
            guard derivative.isFinite, abs(derivative) >= 1e-12 else { break }
            current -= residual / derivative
            current = current < 0 ? 0 : (current > 0.25 ? 0.25 : current)
        }
        let cathodeV = current * cathodeResistance
        let plateV = bPlusSource - current * (p.powerTheveninResistanceOhm + p.windingResistanceOhm)
        return (current, plateV - cathodeV)
    }
}

// MARK: - 図の中身

/// 面 1 枚ぶん。どの球の群れを描くかで軸が変わる。
private enum ETTubeGroup: String {
    case driver, pushPull, singleEnded
}

private struct ETTubePanel: Identifiable, Equatable {
    let id: String
    let title: String
    let group: ETTubeGroup
}

/// 軸と、そこに引く線。js:6680-6760 の *HudAxes と同じ組み立て。
private struct ETTubeAxes {
    var xMax: Double
    var yMax: Double
    var plateCurves: [[CGPoint]]
    var loadLine: (CGPoint, CGPoint)?
}

// MARK: - 本体

struct TubeSimulatorView: View {

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    @StateObject private var telemetry = Telemetry.shared

    /// 選んでいる面。使えなくなったときは resolvedPanel が拾い直す。
    @State private var panelID: String?
    /// 動作点の尾。新しいものが後ろ。
    @State private var trail: [ETTubeTrailSample] = []
    /// 指で触った所の Vak。値を読むだけ。
    @State private var probeVak: Double?
    /// Output Safety Trim を掴んでいる間。掴んでいる間はテレメトリで数値を動かさない。
    @State private var trimHeld = false
    /// 一度取り込んだ自動減衰。同じ値を二重に畳み込まない（js:6256 のコメント）。
    @State private var adoptedReduction: Double?

    /// 尾の長さ。js:628-639 と同じ 0.5 秒・時定数 0.22 秒。
    private static let trailSeconds: TimeInterval = 0.5
    private static let trailFade: TimeInterval = 0.22
    private static let trailMinimumOpacity: Double = 0.02
    private static let curvePoints = 96

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if panels.isEmpty {
                Text("No tube stage is active.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                if panels.count > 1 { panelPicker }
                graph
            }
            readouts
            Divider()
            parameters
        }
        .onChange(of: frameSequence) { _, _ in
            releaseAdoptionIfReductionChanged()
            appendTrail()
        }
    }

    // MARK: 値の読み書き

    private func param(_ key: String) -> ETParam? {
        node.spec.params.first { $0.key == key }
    }

    private func value(_ key: String) -> Double {
        guard let p = param(key), node.values.indices.contains(p.offset) else { return 0 }
        return Double(node.values[p.offset])
    }

    private func set(_ key: String, _ v: Double) {
        guard let p = param(key) else { return }
        dsp.setValue(Float(v), at: index, offset: p.offset)
    }

    /// 選択肢の中身（"12AX7" や "6.0"）。数の選択肢はこの文字列を数として読む。
    private func choice(_ key: String) -> String {
        guard let p = param(key), case .enumeration(let options) = p.kind,
              node.values.indices.contains(p.offset) else { return "" }
        let i = Int(node.values[p.offset].rounded())
        return options.indices.contains(i) ? options[i] : ""
    }

    private func choiceNumber(_ key: String) -> Double {
        Double(choice(key)) ?? 0
    }

    // MARK: テレメトリ

    private var frame: ETFrame? {
        telemetry.frame(tap: node.tapId, type: .tubeSimulator)
    }

    private var frameSequence: UInt32 { frame?.sequence ?? 0 }

    private var latest: ETTubeTelemetry? {
        guard let frame else { return nil }
        return ETTubeTelemetry.read(frame)
    }

    private func appendTrail() {
        guard let sample = latest else { return }
        let now = Date.timeIntervalSinceReferenceDate
        trail.append(ETTubeTrailSample(time: now, left: sample.left, right: sample.right))
        let cutoff = now - Self.trailSeconds
        trail.removeAll { $0.time < cutoff }
        if trail.count > 96 { trail.removeFirst(trail.count - 96) }
    }

    // MARK: 面

    /// いま回路にある球の群れ。js:6597-6602 _hudViewAvailable と同じ条件。
    private var panels: [ETTubePanel] {
        var out: [ETTubePanel] = []
        if choice("tp") != "Bypass" {
            out.append(ETTubePanel(id: "stage1", title: "Stage 1", group: .driver))
            out.append(ETTubePanel(id: "stage2", title: "Stage 2", group: .driver))
        }
        switch choice("os") {
        case "Power":
            out.append(ETTubePanel(id: "push", title: "Push", group: .pushPull))
            out.append(ETTubePanel(id: "pull", title: "Pull", group: .pushPull))
        case "SingleEnded":
            out.append(ETTubePanel(id: "seOutput", title: "SE Output", group: .singleEnded))
        default:
            break
        }
        return out
    }

    /// 選択が消えたら、鎖の後ろ側の面へ寄せる（js:6615-6619 _syncHudView と同じ考え方）。
    private var resolvedPanel: ETTubePanel? {
        let list = panels
        if let panelID, let hit = list.first(where: { $0.id == panelID }) { return hit }
        return list.last
    }

    private var panelPicker: some View {
        Picker("Graph", selection: Binding(
            get: { resolvedPanel?.id ?? "" },
            set: { panelID = $0 })
        ) {
            ForEach(panels) { panel in
                Text(panel.title).tag(panel.id)
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: 軸

    private var axes: ETTubeAxes {
        guard let panel = resolvedPanel else {
            return ETTubeAxes(xMax: 1, yMax: 1, plateCurves: [], loadLine: nil)
        }
        switch panel.group {
        case .driver:     return driverAxes()
        case .pushPull:   return pushPullAxes()
        case .singleEnded: return singleEndedAxes()
        }
    }

    /// js:6684-6702 _driverHudAxes。
    private func driverAxes() -> ETTubeAxes {
        guard let profile = ETTubeProfiles.driver[choice("tp")] else {
            return ETTubeAxes(xMax: 1, yMax: 1, plateCurves: [], loadLine: nil)
        }
        let pv = max(value("pv"), 1)
        let plateScale = pv / 250
        let loadLineCurrent = pv / profile.plateResistance
        let currentMaximum = max(profile.iaMax * plateScale, loadLineCurrent * 1.1)
        return ETTubeAxes(xMax: pv,
                          yMax: max(currentMaximum, 1e-6),
                          plateCurves: plateCurves(profile, plateVoltage: pv),
                          loadLine: (CGPoint(x: 0, y: loadLineCurrent), CGPoint(x: pv, y: 0)))
    }

    /// js:6704-6724 _pushPullHudAxes。プレート特性は引かない（5 極管の表を持っていない）。
    private func pushPullAxes() -> ETTubeAxes {
        let primary = max(choiceNumber("zp") * 1000, 1)
        let pb = max(value("pb"), 1)
        let loadLineCurrent = 2 * pb / primary
        return ETTubeAxes(xMax: pb,
                          yMax: max(loadLineCurrent * 1.25, 1e-6),
                          plateCurves: [],
                          loadLine: (CGPoint(x: 0, y: loadLineCurrent), CGPoint(x: pb, y: 0)))
    }

    /// js:6726-6759 _singleEndedHudAxes。
    private func singleEndedAxes() -> ETTubeAxes {
        guard let profile = ETTubeProfiles.singleEnded[choice("sd")] else {
            return ETTubeAxes(xMax: 1, yMax: 1, plateCurves: [], loadLine: nil)
        }
        let sb = max(value("sb"), 1)
        let assumedLoad = max(choiceNumber("sl"), 0.001)
        let actualLoad = max(value("rl"), 0.001)
        // js:564-570 tubeSimulatorEffectivePrimaryImpedanceOhm
        let primary = max(choiceNumber("sp") * 1000 * actualLoad / assumedLoad, 1)
        let quiescent = ETTubeProfiles.seQuiescent(profile, bPlusSource: sb,
                                                   cathodeResistance: max(value("sr"), 0))
        let loadLineTop = quiescent.currentA + quiescent.plateCathodeV / primary
        let loadLineEnd = min(sb, quiescent.plateCathodeV + quiescent.currentA * primary)
        let loadLineEndCurrent = quiescent.currentA + (quiescent.plateCathodeV - loadLineEnd) / primary
        let currentMaximum = max(profile.iaMax, loadLineTop * 1.1)
        return ETTubeAxes(xMax: sb,
                          yMax: max(currentMaximum, 1e-6),
                          plateCurves: plateCurves(profile, plateVoltage: sb),
                          loadLine: (CGPoint(x: 0, y: loadLineTop),
                                     CGPoint(x: loadLineEnd, y: loadLineEndCurrent)))
    }

    /// js:714-727 tubeSimulatorHudPlateCurves。
    private func plateCurves(_ profile: ETTubeProfile, plateVoltage: Double) -> [[CGPoint]] {
        profile.vgkSteps.map { vgk in
            (0..<Self.curvePoints).map { i -> CGPoint in
                let vak = plateVoltage * Double(i) / Double(Self.curvePoints - 1)
                return CGPoint(x: vak, y: profile.plateCurrent(vgk: vgk, vak: vak))
            }
        }
    }

    // MARK: 図

    private var graph: some View {
        let a = axes
        let panel = resolvedPanel
        return GraphCanvas(
            x: xAxis(a),
            y: yAxis(a),
            height: ETGraphMetrics.height,
            insets: ETGraphInsets(leading: 32, trailing: 10, top: 6, bottom: 14),
            readout: probeReadout(a),
            caption: caption,
            clipsContent: true,
            draw: { context, plot in
                drawPlateCurves(&context, plot, a)
                drawLoadLine(&context, plot, a)
                drawTrail(&context, plot, panel)
                drawProbe(&context, plot, a)
            },
            overlay: { plot in
                // 触って値を読むだけなので、一覧の縦スクロールと同時に効かせる。
                Color.clear
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { touch in
                                probeVak = plot.xAxis.clamp(plot.xValue(at: touch.location.x))
                            }
                            .onEnded { _ in probeVak = nil })
            })
    }

    private func xAxis(_ a: ETTubeAxes) -> ETAxis {
        // js:708-712 tubeSimulatorHudTicks と同じ 5 本。字は整数（js:7162 tick.toFixed(0)）。
        let ticks = (0..<5).map { i -> ETAxisTick in
            let v = a.xMax * Double(i) / 4
            return ETAxisTick(v, String(format: "%.0f", v))
        }
        return ETAxis(scale: .linear, lower: 0, upper: a.xMax, ticks: ticks)
    }

    private func yAxis(_ a: ETTubeAxes) -> ETAxis {
        // 中身は A のままで、字だけ mA にする（js:7174 tick * 1000）。
        let ticks = (0..<5).map { i -> ETAxisTick in
            let v = a.yMax * Double(i) / 4
            return ETAxisTick(v, String(format: "%.1f", v * 1000))
        }
        return ETAxis(scale: .linear, lower: 0, upper: a.yMax, ticks: ticks)
    }

    private func drawPlateCurves(_ context: inout GraphicsContext, _ plot: ETPlot, _ a: ETTubeAxes) {
        for curve in a.plateCurves {
            guard curve.count > 1 else { continue }
            var path = Path()
            for (i, p) in curve.enumerated() {
                let pt = plot.point(Double(p.x), Double(p.y))
                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
            context.stroke(path, with: ETGraphShading.grid, lineWidth: 0.75)
        }
    }

    private func drawLoadLine(_ context: inout GraphicsContext, _ plot: ETPlot, _ a: ETTubeAxes) {
        guard let line = a.loadLine else { return }
        var path = Path()
        path.move(to: plot.point(Double(line.0.x), Double(line.0.y)))
        path.addLine(to: plot.point(Double(line.1.x), Double(line.1.y)))
        context.stroke(path, with: ETGraphShading.muted,
                       style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
    }

    /// 尾。点であって線ではない（js:7253-7255 のコメント: 枠は連続した曲線ではない）。
    /// 左は塗り丸、右は抜き四角。色は使わないので形で分ける。
    private func drawTrail(_ context: inout GraphicsContext, _ plot: ETPlot, _ panel: ETTubePanel?) {
        guard let panel else { return }
        let now = Date.timeIntervalSinceReferenceDate
        for sample in trail {
            let age = now - sample.time
            guard age <= Self.trailSeconds else { continue }
            let opacity = age > 0 ? exp(-age / Self.trailFade) : 1
            guard opacity >= Self.trailMinimumOpacity else { continue }
            context.opacity = opacity

            let l = operatingPoint(sample.left, panel)
            let lp = plot.point(l.x, l.y)
            context.fill(Path(ellipseIn: CGRect(x: lp.x - 2.5, y: lp.y - 2.5, width: 5, height: 5)),
                         with: ETGraphShading.curve)

            let r = operatingPoint(sample.right, panel)
            let rp = plot.point(r.x, r.y)
            context.stroke(Path(CGRect(x: rp.x - 2.5, y: rp.y - 2.5, width: 5, height: 5)),
                           with: ETGraphShading.muted, lineWidth: 1.5)
        }
        context.opacity = 1
    }

    private func drawProbe(_ context: inout GraphicsContext, _ plot: ETPlot, _ a: ETTubeAxes) {
        guard let vak = probeVak else { return }
        var line = Path()
        let x = plot.x(vak)
        line.move(to: CGPoint(x: x, y: plot.rect.minY))
        line.addLine(to: CGPoint(x: x, y: plot.rect.maxY))
        context.stroke(line, with: ETGraphShading.axis,
                       style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
        if let ia = loadLineCurrent(at: vak, a) {
            let pt = plot.clampedPoint(vak, ia)
            context.stroke(Path(ellipseIn: CGRect(x: pt.x - 5, y: pt.y - 5, width: 10, height: 10)),
                           with: ETGraphShading.muted, lineWidth: 1.5)
        }
    }

    /// 面ごとに、どの 2 つの値を (Vak, Ia) として置くか（js:6775-6788 _appendTrajectory）。
    private func operatingPoint(_ p: ETTubeOperatingPoint, _ panel: ETTubePanel) -> (x: Double, y: Double) {
        switch panel.id {
        case "stage1":   return (p.vak1, p.ia1)
        case "stage2":   return (p.vak2, p.ia2)
        case "pull":     return (p.powerPlatePullV, p.powerIaPullA)
        default:         return (p.powerPlatePushV, p.powerIaPushA)   // push / seOutput
        }
    }

    private func loadLineCurrent(at vak: Double, _ a: ETTubeAxes) -> Double? {
        guard let line = a.loadLine else { return nil }
        let x0 = Double(line.0.x), y0 = Double(line.0.y)
        let x1 = Double(line.1.x), y1 = Double(line.1.y)
        guard x1 != x0 else { return nil }
        let t = (vak - x0) / (x1 - x0)
        guard t >= 0, t <= 1 else { return nil }
        return y0 + t * (y1 - y0)
    }

    private func probeReadout(_ a: ETTubeAxes) -> [ETReadoutItem] {
        guard let vak = probeVak else { return [] }
        var items = [ETReadoutItem("VAK", String(format: "%.0f V", vak))]
        if let ia = loadLineCurrent(at: vak, a) {
            items.append(ETReadoutItem("LOAD", String(format: "%.2f mA", ia * 1000)))
        }
        return items
    }

    private var caption: String {
        guard let panel = resolvedPanel else { return "" }
        let tube: String
        switch panel.group {
        case .driver:      tube = choice("tp")
        case .pushPull:    tube = choice("pt")
        case .singleEnded: tube = choice("sd")
        }
        return "\(panel.title) · \(tube) · L filled / R outlined"
    }

    // MARK: 数値

    private var readouts: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let t = latest, let panel = resolvedPanel {
                switch panel.group {
                case .driver:
                    readoutRow("STAGE 1 BIAS", t.left.vk1, t.right.vk1, "V")
                    readoutRow("STAGE 2 BIAS", t.left.vk2, t.right.vk2, "V")
                    readoutRow("B+", t.left.vbPlus, t.right.vbPlus, "V")
                case .pushPull:
                    readoutRow("LTP BALANCE", t.left.ltpBalanceV, t.right.ltpBalanceV, "V")
                    readoutRow("POWER B+", t.left.powerBPlusV, t.right.powerBPlusV, "V")
                    readoutRow("SPEAKER", t.left.speakerVrms100ms, t.right.speakerVrms100ms, "Vrms")
                    readoutRow("REAL POWER", t.left.speakerRealPower100ms,
                               t.right.speakerRealPower100ms, "W")
                    readoutRow("FLUX", abs(t.left.transformerFluxWb),
                               abs(t.right.transformerFluxWb), "Wb", digits: 3)
                case .singleEnded:
                    readoutRow("POWER B+", t.left.powerBPlusV, t.right.powerBPlusV, "V")
                    readoutRow("SPEAKER", t.left.speakerVrms100ms, t.right.speakerVrms100ms, "Vrms")
                    readoutRow("REAL POWER", t.left.speakerRealPower100ms,
                               t.right.speakerRealPower100ms, "W")
                    readoutRow("FLUX", abs(t.left.transformerFluxWb),
                               abs(t.right.transformerFluxWb), "Wb", digits: 3)
                }
                Text(safetyLine)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Waiting for measurements…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func readoutRow(_ label: String, _ left: Double, _ right: Double,
                            _ unit: String, digits: Int = 2) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(String(format: "L %.\(digits)f / R %.\(digits)f", left, right) + " \(unit)")
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private var safetyLine: String {
        let reduction = safetyReductionDb
        if reduction < 0 {
            return String(format: "Output safety reduction: %.1f dB applied automatically. "
                          + "Move Output Safety Trim to clear it.", -reduction)
        }
        return "Output safety reduction: 0.0 dB."
    }

    // MARK: Output Safety Trim（web 版で唯一の掴む操作）

    /// 常に 0 以下。テレメトリが来るまでは 0（js:6997-7001 _safetyReductionDb）。
    private var safetyReductionDb: Double {
        guard let reported = latest?.safetyReductionDb, reported.isFinite, reported <= 0 else {
            return 0
        }
        return reported
    }

    /// 設定値 ＋ 自動減衰。0.1 dB に丸めて -96…0 に収める（js:6243-6249）。
    private var effectiveTrimDb: Double {
        let effective = value("sg") + safetyReductionDb
        let clamped = effective < -96 ? -96 : (effective > 0 ? 0 : effective)
        return (clamped * 10).rounded() / 10
    }

    /// 掴んだ瞬間に、いま出ている値を設定値へ取り込む（js:6257-6275 _adoptEffectiveSafetyTrim）。
    /// 取り込まずに設定値へ跳ね戻すと、抑えていたぶんだけ音量が上がる。
    private func adoptEffectiveTrim() {
        let reduction = safetyReductionDb
        if reduction == adoptedReduction { return }
        adoptedReduction = reduction
        let effective = effectiveTrimDb
        if effective == value("sg") { return }
        set("sg", effective)
    }

    /// 報告された減衰が変わったら、二重取り込みの止めを外す（js:6579-6583）。
    private func releaseAdoptionIfReductionChanged() {
        if adoptedReduction != safetyReductionDb { adoptedReduction = nil }
    }

    private var safetyTrimRow: some View {
        // 掴んでいる間は設定値そのもの（取り込み済みなので同じ数）。
        // 離しているときは「いま効いている合計」を出す（js:6583-6588, 6299-6312）。
        let shown = trimHeld ? value("sg") : effectiveTrimDb
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Output Safety Trim (dB)")
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                ValueBox(text: String(format: "%.1f dB", shown))
            }
            Slider(value: Binding(get: { shown }, set: { set("sg", ($0 * 10).rounded() / 10) }),
                   in: -96...0,
                   step: 0.1,
                   onEditingChanged: { editing in
                       if editing {
                           trimHeld = true
                           adoptEffectiveTrim()
                       } else {
                           trimHeld = false
                       }
                   })
        }
        .padding(.vertical, 2)
    }

    // MARK: パラメータ

    private var parameters: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(node.spec.params) { p in
                if p.key == "sg" {
                    safetyTrimRow
                } else {
                    ParameterRow(param: p, nodeIndex: index, values: node.values, dsp: dsp)
                }
            }
        }
    }
}
