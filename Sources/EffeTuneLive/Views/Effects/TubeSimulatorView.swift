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
//
//  操作は上流と同じ 5 つのタブに分けてある（同 7283 _createTabbedControls）。
//  Output Circuit で使わなくなる行は引っ込める（同 6355 _syncPowerSectionVisibility）。
//  並びは操作 → 面の帯 → 図 → 数値で、上流の「Settings first, then the read-outs」
//  （同 7506-7512）と同じ。

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

// MARK: - 操作のまとまり

/// js:7333-7400 の 5 枚（_createTabbedControls は同 7283）。名前も並びも上流のまま。
private enum ETTubeTab: String, CaseIterable, Identifiable {
    case input, driver, power, transformer, output

    var id: String { rawValue }

    var title: String {
        switch self {
        case .input:       return "Input"
        case .driver:      return "Driver"
        case .power:       return "Power"
        case .transformer: return "Transformer"
        case .output:      return "Output"
        }
    }

    /// タブの中の順。上流が appendChild する順そのもの（js:7333-7400）。
    var keys: [String] {
        switch self {
        case .input:       return ["dr", "iv", "sz"]
        case .driver:      return ["tp", "bi", "pv", "su", "nf"]
        case .power:       return ["os", "pt", "pb", "kr", "sd", "sb", "sr"]
        case .transformer: return ["st", "zp", "sp", "sl", "rl"]
        case .output:      return ["og", "sg", "ag", "mx"]
        }
    }
}

/// os で出し入れする行（js:6355-6365 `_syncPowerSectionVisibility`）。
/// 値は消さずに行だけ引っ込めるので、回路を戻せば前の設定がそのまま戻る。
private enum ETTubeRows {
    /// 出力段があるときだけ出る。上流の `_powerRows`（js:7379-7380 の 2 行）。
    static let power: Set<String> = ["sl", "rl"]
    /// Push-Pull 専用。`_ppRows`（js:7355-7357 の 3 行 ＋ 7372-7373 の 2 行）。
    static let pushPull: Set<String> = ["pt", "pb", "kr", "st", "zp"]
    /// SE 専用。`_seRows`（js:7360-7362 の 3 行 ＋ 7376 の 1 行）。
    static let singleEnded: Set<String> = ["sd", "sb", "sr", "sp"]

    static func shows(_ key: String, outputCircuit: String) -> Bool {
        if pushPull.contains(key) { return outputCircuit == "Power" }
        if singleEnded.contains(key) { return outputCircuit == "SingleEnded" }
        if power.contains(key) { return outputCircuit != "Line" }
        return true
    }
}

/// 画面に出す選択肢の字。js:17-57 `TUBE_SIMULATOR_ENUM_ABI` の labels 側で、
/// 上流も画面にはこちらを出す（js:7327-7330 abiOptions）。
/// 保存値（values）は EffectCatalog.swift が持っていて、そちらは生成物なので触らない。
private enum ETTubeEnumLabels {
    static let table: [String: [String]] = [
        "tp": ["12AX7", "12AT7", "12AU7", "Bypass"],
        "os": ["Line", "Push-Pull Power", "SE Triode"],
        "pt": ["EL84 ×2", "EL34 ×2", "6L6GC ×2", "KT88 ×2"],
        "sd": ["300B", "2A3"],
        "st": ["0%", "20%", "43%"],
        "zp": ["6.0 kΩ", "6.6 kΩ", "8.0 kΩ"],
        "sp": ["2.5 kΩ", "3.5 kΩ", "5.0 kΩ"],
        "sl": ["4 Ω", "8 Ω", "15 Ω", "16 Ω"]
    ]

    /// 数が合わなければ保存値をそのまま出す。ABI が動いたときに字だけずれるのを避ける。
    static func labels(_ key: String, values: [String]) -> [String] {
        guard let labels = table[key], labels.count == values.count else { return values }
        return labels
    }
}

/// 選択肢を押せる面で並べる行。上流も `createRadioGroup`（js:7311-7318）で
/// 全部の選択肢を出しているので、開いてから選ぶ形にはしない。
/// title が nil なら見出しの行を作らない（タブの帯で使う）。
private struct ETTubeChoiceRow: View {
    let title: String?
    let labels: [String]
    let selected: Int
    let onSelect: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            HStack(spacing: 6) {
                ForEach(Array(labels.enumerated()), id: \.offset) { i, label in
                    let isSelected = i == selected
                    Button {
                        onSelect(i)
                    } label: {
                        Text(label)
                            .font(.system(size: 13, weight: isSelected ? .bold : .regular))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
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
                    .accessibilityLabel(label)
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                }
            }
        }
    }
}

// MARK: - 本体

struct TubeSimulatorView: View {

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    @Environment(\.etGraphOnly) private var graphOnly

    /// 開いているタブ。上流の初期値も input（js:6063）。
    @State private var tab: ETTubeTab = .input
    /// 選んでいる面。使えなくなったときは resolvedPanel が拾い直す。
    @State private var panelID: String?

    private static let curvePoints = 96

    var body: some View {
        // Telemetry を観測するのは図と Output Safety Trim の中だけ。ここで観測すると
        // 30Hz でカードごと作り直されて、タブと選択肢の押し心地が落ちる。
        VStack(alignment: .leading, spacing: 12) {
            // graph only のときは操作を丸ごと畳む。ParameterRow は自分で消えるが、
            // タブの帯と選択肢の行は自分では消えない。
            if !graphOnly {
                ETTubeChoiceRow(title: nil,
                                labels: ETTubeTab.allCases.map(\.title),
                                selected: ETTubeTab.allCases.firstIndex(of: tab) ?? 0,
                                onSelect: { tab = ETTubeTab.allCases[$0] })
                tabContent
                Divider()
            }
            // 上流も操作が先で、図と数値は後ろ（js:7506-7512 のコメント）。
            if panels.isEmpty {
                Text("No tube stage is active.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else if panels.count > 1 {
                panelPicker
            }
            TubeSimulatorHUD(tapId: node.tapId,
                             panel: resolvedPanel,
                             axes: axes,
                             caption: caption,
                             driverBypassed: choice("tp") == "Bypass",
                             inputReferenceVpk: value("iv"),
                             inputVolumeDb: value("dr"))
        }
    }

    // MARK: パラメータ

    /// 開いているタブの行だけ。os で消える行はここで落とす。
    private var tabContent: some View {
        let outputCircuit = choice("os")
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(tab.keys, id: \.self) { key in
                if let p = param(key), ETTubeRows.shows(key, outputCircuit: outputCircuit) {
                    row(p)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ p: ETParam) -> some View {
        if p.key == "sg" {
            TubeSimulatorSafetyTrimRow(index: index, param: p, values: node.values,
                                       dsp: dsp, tapId: node.tapId)
        } else if let options = enumOptions(p) {
            ETTubeChoiceRow(title: p.label,
                            labels: ETTubeEnumLabels.labels(p.key, values: options),
                            selected: enumIndex(p, count: options.count),
                            onSelect: { dsp.setValue(Float($0), at: index, offset: p.offset) })
        } else {
            ParameterRow(param: p, nodeIndex: index, values: node.values, dsp: dsp)
        }
    }

    private func enumOptions(_ p: ETParam) -> [String]? {
        if case .enumeration(let options) = p.kind { return options }
        return nil
    }

    private func enumIndex(_ p: ETParam, count: Int) -> Int {
        guard node.values.indices.contains(p.offset) else { return 0 }
        return min(max(Int(node.values[p.offset].rounded()), 0), max(count - 1, 0))
    }

    // MARK: 値の読み書き

    private func param(_ key: String) -> ETParam? {
        node.spec.params.first { $0.key == key }
    }

    private func value(_ key: String) -> Double {
        guard let p = param(key), node.values.indices.contains(p.offset) else { return 0 }
        return Double(node.values[p.offset])
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

    // MARK: 面

    /// いま回路にある球の群れ。js:6620-6625 _hudViewAvailable と同じ条件。
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

    private var caption: String {
        guard let panel = resolvedPanel else { return "" }
        let tube: String
        switch panel.group {
        case .driver:      tube = choice("tp")
        case .pushPull:    tube = choice("pt")
        case .singleEnded: tube = choice("sd")
        }
        // 尾の印の見分け方も一緒に出す（左は塗り丸、右は抜き四角）。
        return "\(panel.title) · \(tube) · L ● / R □"
    }

    // MARK: 軸

    private var axes: ETTubeAxes {
        guard let panel = resolvedPanel else {
            return ETTubeAxes(xMax: 1, yMax: 1, plateCurves: [], loadLine: nil)
        }
        switch panel.group {
        case .driver:      return driverAxes()
        case .pushPull:    return pushPullAxes()
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
}

// MARK: - 図と数値

/// **Telemetry を観測するのはここと Output Safety Trim の行だけ。**
/// カード全体で観測すると 30Hz で作り直されて、タブと選択肢が固まる。
private struct TubeSimulatorHUD: View {

    let tapId: UInt32
    let panel: ETTubePanel?
    let axes: ETTubeAxes
    let caption: String
    /// ドライバを外していると、段の数値は上流も出さない（js:6845-6882）。
    let driverBypassed: Bool
    let inputReferenceVpk: Double
    let inputVolumeDb: Double

    @ObservedObject private var telemetry = Telemetry.shared

    /// 動作点の尾。新しいものが後ろ。
    @State private var trail: [ETTubeTrailSample] = []
    /// 指で触った所の Vak。値を読むだけ。
    @State private var probeVak: Double?

    /// 尾の長さ。js:628-639 と同じ 0.5 秒・時定数 0.22 秒。
    private static let trailSeconds: TimeInterval = 0.5
    private static let trailFade: TimeInterval = 0.22
    private static let trailMinimumOpacity: Double = 0.02

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if panel != nil { graph }
            readouts
        }
        .onChange(of: frameSequence) { _, _ in appendTrail() }
    }

    // MARK: テレメトリ

    private var frame: ETFrame? {
        telemetry.frame(tap: tapId, type: .tubeSimulator)
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

    // MARK: 図

    private var graph: some View {
        VStack(alignment: .leading, spacing: 2) {
            // 上流は軸名を図の中に書く（js:7113-7123）。iPhone の幅では目盛りと重なるので外へ出した。
            Text("Ia (mA)")
                .font(.system(size: ETGraphMetrics.labelSize))
                .foregroundStyle(.secondary)
            GraphCanvas(
                x: xAxis,
                y: yAxis,
                height: ETGraphMetrics.height,
                insets: ETGraphInsets(leading: 32, trailing: 10, top: 6, bottom: 14),
                readout: probeReadout,
                caption: caption,
                clipsContent: true,
                draw: { context, plot in
                    drawPlateCurves(&context, plot)
                    drawLoadLine(&context, plot)
                    drawTrail(&context, plot)
                    drawProbe(&context, plot)
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
            Text("Vak (V)")
                .font(.system(size: ETGraphMetrics.labelSize))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var xAxis: ETAxis {
        // js:708-712 tubeSimulatorHudTicks と同じ 5 本。字は整数（js:7162 tick.toFixed(0)）。
        let ticks = (0..<5).map { i -> ETAxisTick in
            let v = axes.xMax * Double(i) / 4
            return ETAxisTick(v, String(format: "%.0f", v))
        }
        return ETAxis(scale: .linear, lower: 0, upper: axes.xMax, ticks: ticks)
    }

    private var yAxis: ETAxis {
        // 中身は A のままで、字だけ mA にする（js:7174 tick * 1000）。
        let ticks = (0..<5).map { i -> ETAxisTick in
            let v = axes.yMax * Double(i) / 4
            return ETAxisTick(v, String(format: "%.1f", v * 1000))
        }
        return ETAxis(scale: .linear, lower: 0, upper: axes.yMax, ticks: ticks)
    }

    private func drawPlateCurves(_ context: inout GraphicsContext, _ plot: ETPlot) {
        for curve in axes.plateCurves {
            guard curve.count > 1 else { continue }
            var path = Path()
            for (i, p) in curve.enumerated() {
                let pt = plot.point(Double(p.x), Double(p.y))
                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
            context.stroke(path, with: ETGraphShading.grid, lineWidth: 0.75)
        }
    }

    private func drawLoadLine(_ context: inout GraphicsContext, _ plot: ETPlot) {
        guard let line = axes.loadLine else { return }
        var path = Path()
        path.move(to: plot.point(Double(line.0.x), Double(line.0.y)))
        path.addLine(to: plot.point(Double(line.1.x), Double(line.1.y)))
        context.stroke(path, with: ETGraphShading.muted,
                       style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
    }

    /// 尾。点であって線ではない（js:7253-7255 のコメント: 枠は連続した曲線ではない）。
    /// 左は塗り丸、右は抜き四角。色は使わないので形で分ける。
    private func drawTrail(_ context: inout GraphicsContext, _ plot: ETPlot) {
        guard let panel else { return }
        let now = Date.timeIntervalSinceReferenceDate
        for sample in trail {
            let age = now - sample.time
            guard age <= Self.trailSeconds else { continue }
            let opacity = age > 0 ? exp(-age / Self.trailFade) : 1
            guard opacity >= Self.trailMinimumOpacity else { continue }
            context.opacity = opacity

            let l = Self.operatingPoint(sample.left, panel)
            let lp = plot.point(l.x, l.y)
            context.fill(Path(ellipseIn: CGRect(x: lp.x - 2.5, y: lp.y - 2.5, width: 5, height: 5)),
                         with: ETGraphShading.curve)

            let r = Self.operatingPoint(sample.right, panel)
            let rp = plot.point(r.x, r.y)
            context.stroke(Path(CGRect(x: rp.x - 2.5, y: rp.y - 2.5, width: 5, height: 5)),
                           with: ETGraphShading.muted, lineWidth: 1.5)
        }
        context.opacity = 1
    }

    private func drawProbe(_ context: inout GraphicsContext, _ plot: ETPlot) {
        guard let vak = probeVak else { return }
        var line = Path()
        let x = plot.x(vak)
        line.move(to: CGPoint(x: x, y: plot.rect.minY))
        line.addLine(to: CGPoint(x: x, y: plot.rect.maxY))
        context.stroke(line, with: ETGraphShading.axis,
                       style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
        if let ia = loadLineCurrent(at: vak) {
            let pt = plot.clampedPoint(vak, ia)
            context.stroke(Path(ellipseIn: CGRect(x: pt.x - 5, y: pt.y - 5, width: 10, height: 10)),
                           with: ETGraphShading.muted, lineWidth: 1.5)
        }
    }

    /// 面ごとに、どの 2 つの値を (Vak, Ia) として置くか（js:6775-6788 _appendTrajectory）。
    private static func operatingPoint(_ p: ETTubeOperatingPoint,
                                       _ panel: ETTubePanel) -> (x: Double, y: Double) {
        switch panel.id {
        case "stage1":   return (p.vak1, p.ia1)
        case "stage2":   return (p.vak2, p.ia2)
        case "pull":     return (p.powerPlatePullV, p.powerIaPullA)
        default:         return (p.powerPlatePushV, p.powerIaPushA)   // push / seOutput
        }
    }

    private func loadLineCurrent(at vak: Double) -> Double? {
        guard let line = axes.loadLine else { return nil }
        let x0 = Double(line.0.x), y0 = Double(line.0.y)
        let x1 = Double(line.1.x), y1 = Double(line.1.y)
        guard x1 != x0 else { return nil }
        let t = (vak - x0) / (x1 - x0)
        guard t >= 0, t <= 1 else { return nil }
        return y0 + t * (y1 - y0)
    }

    private var probeReadout: [ETReadoutItem] {
        guard let vak = probeVak else { return [] }
        var items = [ETReadoutItem("VAK", String(format: "%.0f V", vak))]
        if let ia = loadLineCurrent(at: vak) {
            items.append(ETReadoutItem("LOAD", String(format: "%.2f mA", ia * 1000)))
        }
        return items
    }

    // MARK: 数値

    private struct Reading: Identifiable {
        let label: String
        let value: String
        var id: String { label }

        init(_ label: String, _ value: String) {
            self.label = label
            self.value = value
        }
    }

    private var readouts: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(readings) { reading in
                HStack(spacing: 6) {
                    Text(reading.label)
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Text(reading.value)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
            Text(safetyLine)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// js:7485-7496 の 12 個。見出しも順も上流のまま。
    /// 値が来ていない行は上流の初期表示と同じダッシュにする。
    private var readings: [Reading] {
        let t = latest
        let l = t?.left
        let r = t?.right
        // ドライバ段の 5 つは、球を外していると上流も値を出さない。
        let d = driverBypassed ? nil : t
        return [
            Reading("STAGE 1 BIAS", Self.stereo(d?.left.vk1, d?.right.vk1, "V")),
            Reading("STAGE 2 BIAS", Self.stereo(d?.left.vk2, d?.right.vk2, "V")),
            Reading("B+", Self.stereo(d?.left.vbPlus, d?.right.vbPlus, "V")),
            Reading("STAGE 1 PLATE − B+ SAG",
                    Self.stereoFixed(d.map { $0.left.vak1 + $0.left.vk1 - $0.left.vbPlus },
                                     d.map { $0.right.vak1 + $0.right.vk1 - $0.right.vbPlus },
                                     "V", digits: 2, integerDigits: 3)),
            Reading("STAGE 2 PLATE − B+ SAG",
                    Self.stereoFixed(d.map { $0.left.vak2 + $0.left.vk2 - $0.left.vbPlus },
                                     d.map { $0.right.vak2 + $0.right.vk2 - $0.right.vbPlus },
                                     "V", digits: 2, integerDigits: 3)),
            Reading("INPUT REFERENCE (0 dBFS)", inputReferenceText),
            Reading("STAGE 1 EXTERNAL INPUT (0 dBFS)", stage1ExternalInputText),
            Reading("POWER LTP BALANCE",
                    Self.stereoFixed(l?.ltpBalanceV, r?.ltpBalanceV,
                                     "V", digits: 2, integerDigits: 3)),
            Reading("POWER B+", Self.stereo(l?.powerBPlusV, r?.powerBPlusV, "V")),
            Reading("SPEAKER OUTPUT (100 ms)",
                    Self.stereo(l?.speakerVrms100ms, r?.speakerVrms100ms, "Vrms")),
            Reading("SPEAKER REAL POWER (100 ms)",
                    Self.stereo(l?.speakerRealPower100ms, r?.speakerRealPower100ms, "W")),
            Reading("TRANSFORMER FLUX",
                    Self.stereoFixed(l.map { abs($0.transformerFluxWb) },
                                     r.map { abs($0.transformerFluxWb) },
                                     "Wb", digits: 3, integerDigits: 2))
        ]
    }

    /// js:6830-6835。テレメトリは要らない。iv だけで出る。
    private var inputReferenceText: String {
        let vrms = inputReferenceVpk / sqrt(2)
        let dbuFS = 20 * log10(vrms / 0.775)
        guard dbuFS.isFinite else { return String(format: "%.3f Vpk", inputReferenceVpk) }
        return String(format: "%.3f Vpk · %.3f Vrms · %.1f dBuFS", inputReferenceVpk, vrms, dbuFS)
    }

    /// js:6836-6841。ドライバを外していてもここは出る。
    private var stage1ExternalInputText: String {
        let vpk = inputReferenceVpk * pow(10, inputVolumeDb / 20)
        let text = String(format: "%.3f Vpk", vpk)
        return driverBypassed ? "Driver bypassed · " + text : text
    }

    /// js:6798-6801 _formatStereo。
    private static func stereo(_ left: Double?, _ right: Double?, _ unit: String,
                               digits: Int = 2) -> String {
        guard let left, let right, left.isFinite, right.isFinite else { return "L — / R —" }
        return String(format: "L %.\(digits)f / R %.\(digits)f", left, right) + " \(unit)"
    }

    /// js:6814-6827 _formatStereoFixed。符号を必ず出し、整数部を桁数ぶん空白で詰める。
    /// 符号や桁が変わっても列が動かないので、動いている数字が読める。
    private static func stereoFixed(_ left: Double?, _ right: Double?, _ unit: String,
                                    digits: Int, integerDigits: Int) -> String {
        guard let left, let right, left.isFinite, right.isFinite else { return "L — / R —" }
        return "L " + fixed(left, digits: digits, integerDigits: integerDigits)
            + " / R " + fixed(right, digits: digits, integerDigits: integerDigits)
            + " \(unit)"
    }

    /// 引き算の記号は U+2212。ハイフンより幅が広く、プラスと同じ幅になる。
    private static func fixed(_ v: Double, digits: Int, integerDigits: Int) -> String {
        let sign = v < 0 ? "\u{2212}" : "+"
        let text = String(format: "%.\(digits)f", abs(v))
        let whole = text.prefix { $0 != "." }
        let fraction = text.dropFirst(whole.count)
        let pad = String(repeating: " ", count: max(0, integerDigits - whole.count))
        return sign + pad + String(whole) + String(fraction)
    }

    /// 上流の status（js:6983-6988）。0 dB でも必ず出す。
    private var safetyLine: String {
        guard let reported = latest?.safetyReductionDb, reported.isFinite, reported < 0 else {
            return "Output safety reduction: 0.0 dB."
        }
        return String(format: "Output safety reduction: %.1f dB applied automatically. "
                      + "Move Output Safety Trim to clear it.", -reported)
    }
}

// MARK: - Output Safety Trim（web 版で唯一の掴む操作）

/// 掴んだ瞬間に「いま効いている減衰込みの値」を設定値へ取り込む行（js:6243-6312）。
/// テレメトリで数が動くので、Telemetry を見るのは図とこの行だけ。
private struct TubeSimulatorSafetyTrimRow: View {

    let index: Int
    let param: ETParam
    let values: [Float]
    @ObservedObject var dsp: EffeTuneDSP
    let tapId: UInt32

    @ObservedObject private var telemetry = Telemetry.shared

    /// 掴んでいる間はテレメトリで数値を動かさない。
    @State private var held = false
    /// 一度取り込んだ自動減衰。同じ値を二重に畳み込まない（js:6256 のコメント）。
    @State private var adoptedReduction: Double?

    var body: some View {
        // 掴んでいる間は設定値そのもの（取り込み済みなので同じ数）。
        // 離しているときは「いま効いている合計」を出す（js:6583-6588, 6299-6312）。
        let shown = held ? setting : effectiveTrimDb
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Output Safety Trim (dB)")
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                ETValueField(text: String(format: "%.1f dB", shown),
                             label: "Output Safety Trim (dB)",
                             editText: { ETNumberText.draft(shown) }) { typed in
                    set(min(max((typed * 10).rounded() / 10, -96), 0))
                }
            }
            Slider(value: Binding(get: { shown }, set: { set(($0 * 10).rounded() / 10) }),
                   in: -96...0,
                   step: 0.1,
                   onEditingChanged: { editing in
                       if editing {
                           held = true
                           adoptEffectiveTrim()
                       } else {
                           held = false
                       }
                   })
        }
        .padding(.vertical, 2)
        // 報告された減衰が変わったら、二重取り込みの止めを外す（js:6579-6583）。
        .onChange(of: safetyReductionDb) { _, _ in adoptedReduction = nil }
    }

    private var setting: Double {
        values.indices.contains(param.offset) ? Double(values[param.offset]) : 0
    }

    private func set(_ v: Double) {
        dsp.setValue(Float(v), at: index, offset: param.offset)
    }

    /// 常に 0 以下。テレメトリが来るまでは 0（js:6997-7002 _safetyReductionDb）。
    private var safetyReductionDb: Double {
        guard let frame = telemetry.frame(tap: tapId, type: .tubeSimulator),
              let reported = ETTubeTelemetry.read(frame)?.safetyReductionDb,
              reported.isFinite, reported <= 0 else { return 0 }
        return reported
    }

    /// 設定値 ＋ 自動減衰。0.1 dB に丸めて -96…0 に収める（js:6243-6249）。
    private var effectiveTrimDb: Double {
        let effective = setting + safetyReductionDb
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
        if effective == setting { return }
        set(effective)
    }
}
