//  PhaseSelectEqView.swift
//  Phase Select EQ（spatial/phase_select_eq）。
//
//  web 版は plugins/spatial/phase_select_eq.js。
//  図は「横＝L/R の位相差（-180…+180°）または定位（-100…+100%）、縦＝周波数（対数）」。
//  そこに DSP が出した点の雲を撒き、バンドの選択範囲を四角で重ねる（同 1422 drawGraph）。
//
//  掴む対象:
//    web 版は四角の中を掴むと範囲ごと動き（同 1051 mode 'move'）、
//    枠の角・辺に置いた 12〜20 個の取っ手（同 1199 _selectedHandles、当たり判定は半径 22px）
//    を掴むと境目が動く。
//
//  iPhone へ移すにあたって変えたところ:
//    - 取っ手が多すぎて指で選び分けられないので、辺の取っ手を落として「角 8 個」だけにした。
//      角は横と縦の境目を同時に動かすので、辺の取っ手にできることは角でも全部できる。
//      位相 0°で左右の四角がくっついたときの割り取っ手（同 1267 split）だけは、
//      それが無いと中央を開けられないので残してある。
//    - 当たり判定の半径をやめ、いちばん近い角が必ず選ばれるようにした（外さない）。
//      FrequencyResponseGraph と同じ考え方。
//    - 「範囲ごと動かす」と「角を動かす」が同じ面で当たると指では見分けられないので、
//      Move / Resize の帯で先に決める形にした。
//    - 掴んだ位置と角のずれ（web の grabOffset）は 44pt までにしてある。
//      それより遠くから掴んだときは角が指へ吸い付く。
//
//  掴んでいる値は図の外（上）に出る。指の下は見えない。

import SwiftUI
import Foundation

// MARK: - テレメトリ

/// 雲の点 1 つ。
struct ETPhaseMapPoint {
    let frequency: Double
    let phase: Double            // -180…180
    let balance: Double          // -100…100
    let relativeLevelDb: Double  // 0 以下
}

/// frameType 20 / formatVersion 2。
///
/// 頭 16 バイト（dsp/plugins/spatial/phase_select_eq/kernel.cpp:919-923）:
///    0 f32 sampleRate
///    4 u16 pointCount
///    6 u16 flags（いまは常に 0）
///    8 u32 fftSize
///   12 f32 frameMaximumDb
/// そのあと pointCount 個 ×16 バイト（同 948-951）:
///   +0 f32 frequency / +4 f32 phase / +8 f32 balance / +12 f32 relativeLevelDb
///
/// 読み方の条件は js 側の parseDspTelemetryFrame（plugins/spatial/phase_select_eq.js:427-457）
/// と同じにしてある。1 つでも外れたら枠ごと捨てる。
struct ETPhaseMapFrame {
    let sampleRate: Double
    let fftSize: UInt32
    let frameMaximumDb: Double
    let points: [ETPhaseMapPoint]

    static let headerBytes = 16
    static let pointBytes = 16
    static let maximumPoints = 512

    static func read(_ frame: ETFrame) -> ETPhaseMapFrame? {
        guard frame.matches(version: 2), frame.hasPayload(atLeast: headerBytes) else { return nil }
        let payload = frame.payloadView
        guard let sampleRate = payload.f32(at: 0),
              let pointCount = payload.u16(at: 4),
              let fftSize = payload.u32(at: 8),
              let maximumDb = payload.f32(at: 12) else { return nil }
        guard sampleRate.isFinite, sampleRate > 0,
              Int(pointCount) <= maximumPoints,
              payload.count == headerBytes + Int(pointCount) * pointBytes,
              fftSize >= 2, (fftSize & (fftSize - 1)) == 0,
              maximumDb.isFinite else { return nil }

        let maximumFrequency = min(40000.0, Double(sampleRate) * 0.49)
        var points: [ETPhaseMapPoint] = []
        points.reserveCapacity(Int(pointCount))
        for i in 0..<Int(pointCount) {
            let base = headerBytes + i * pointBytes
            guard let hz = payload.f32(at: base),
                  let phase = payload.f32(at: base + 4),
                  let balance = payload.f32(at: base + 8),
                  let level = payload.f32(at: base + 12) else { return nil }
            guard hz.isFinite, Double(hz) >= 20, Double(hz) <= maximumFrequency,
                  phase.isFinite, phase >= -180, phase <= 180,
                  balance.isFinite, balance >= -100, balance <= 100,
                  level.isFinite, level <= 0 else { return nil }
            points.append(ETPhaseMapPoint(frequency: Double(hz), phase: Double(phase),
                                          balance: Double(balance),
                                          relativeLevelDb: Double(level)))
        }
        return ETPhaseMapFrame(sampleRate: Double(sampleRate), fftSize: fftSize,
                               frameMaximumDb: Double(maximumDb), points: points)
    }
}

// MARK: - バンド 1 本

/// js の region と同じ 15 個。
struct ETPhaseRegion: Equatable {
    var enabled: Bool
    var ofl: Double, fl: Double, fh: Double, ofh: Double
    var opl: Double, pl: Double, ph: Double, oph: Double
    var gain: Double
    var solo: Bool
    var obl: Double, bl: Double, bh: Double, obh: Double

    /// plugins/spatial/phase_select_eq.js:16-31 PHASE_SELECT_EQ_DEFAULT_REGION と
    /// dsp/plugins/spatial/phase_select_eq/params.json の default が同じ値。
    static let fallback = ETPhaseRegion(
        enabled: true, ofl: 80, fl: 100, fh: 10000, ofh: 12000,
        opl: 0, pl: 0, ph: 30, oph: 45, gain: 100, solo: false,
        obl: -100, bl: -100, bh: 100, obh: 100)

    /// 周波数が範囲の外（生成された EffectCatalog が配列の既定を 0 に潰している）。
    var isDegenerate: Bool {
        fl < 20 || fh < 20 || ofl < 20 || ofh < 20 || fh <= fl
    }
}

enum ETPhaseEdge { case low, high }
enum ETPhaseAxisKind { case frequency, phase, balance }

/// 核の最小の大きさ。web は図の大きさから決めている
/// （plugins/spatial/phase_select_eq.js:42-69 phaseSelectEqCoreConstraints）。
/// 12 CSS ピクセルぶんは必ず見えるように、という決め方。
struct ETPhaseConstraints {
    var minimumPhaseDegrees: Double
    var minimumBalance: Double
    var minimumFrequencyHz: Double
    var minimumFrequencyRatio: Double

    init(plotWidth: Double, plotHeight: Double, maximumFrequency: Double,
         sampleRate: Double, fftSize: Double) {
        let width = max(1, plotWidth)
        let height = max(1, plotHeight)
        let displayMaximum = ETPhaseMath.clamp(maximumFrequency, 21, 40000)
        let rate = sampleRate > 0 ? sampleRate : 48000
        let size = fftSize >= 2 ? fftSize : 4096
        let logRange = log2(displayMaximum / 20)
        minimumPhaseDegrees = max(1, 12 / width * 360)
        minimumBalance = max(1, 12 / width * 200)
        minimumFrequencyHz = max(1, rate / size)
        minimumFrequencyRatio = pow(2, 12 / height * logRange)
    }
}

enum ETPhaseMath {

    /// js の phaseSelectEqClamp と同じ順番（下限を先に見る）。
    static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        v < lo ? lo : (v > hi ? hi : v)
    }

    /// js:149-152 phaseSelectEqSmooth01。
    static func smooth01(_ v: Double) -> Double {
        let c = clamp(v, 0, 1)
        return 0.5 - 0.5 * cos(.pi * c)
    }

    /// js:154-164 phaseSelectEqAxisWeight。
    static func axisWeight(_ value: Double, _ outerLow: Double, _ coreLow: Double,
                           _ coreHigh: Double, _ outerHigh: Double) -> Double {
        if value < outerLow || value > outerHigh { return 0 }
        if value >= coreLow && value <= coreHigh { return 1 }
        if value < coreLow {
            if coreLow == outerLow { return 1 }
            return smooth01((value - outerLow) / (coreLow - outerLow))
        }
        if outerHigh == coreHigh { return 1 }
        return smooth01((outerHigh - value) / (outerHigh - coreHigh))
    }

    /// js:135-147 phaseSelectEqDisplaySegments。位相は 0 をまたいで左右対称に出す。
    static func displaySegments(low: Double, high: Double) -> [(low: Double, high: Double)] {
        let nl = clamp(low, 0, 180)
        let nh = clamp(high, nl, 180)
        if nl == 0 { return [(-nh, nh)] }
        return [(-nh, -nl), (nl, nh)]
    }

    /// js:71-132 phaseSelectEqNormalizeRegion。境目の並びはここで必ず整う。
    static func normalized(_ source: ETPhaseRegion, _ c: ETPhaseConstraints) -> ETPhaseRegion {
        var r = source
        r.ofl = clamp(r.ofl, 20, 40000)
        r.fl = clamp(r.fl, 20, 40000)
        r.fh = clamp(r.fh, 20, 40000)
        r.ofh = clamp(r.ofh, 20, 40000)
        r.opl = clamp(r.opl, 0, 180)
        r.pl = clamp(r.pl, 0, 180)
        r.ph = clamp(r.ph, 0, 180)
        r.oph = clamp(r.oph, 0, 180)
        r.gain = clamp(r.gain, 0, 200)
        r.obl = clamp(r.obl, -100, 100)
        r.bl = clamp(r.bl, -100, 100)
        r.bh = clamp(r.bh, -100, 100)
        r.obh = clamp(r.obh, -100, 100)

        let minimumHz = clamp(c.minimumFrequencyHz, 1, 40000 - 20)
        let minimumRatio = clamp(c.minimumFrequencyRatio, 1, 40000 / 20)
        let maximumCoreLow = min(40000 - minimumHz, 40000 / minimumRatio)
        r.fl = clamp(r.fl, 20, maximumCoreLow)
        r.fh = clamp(r.fh, max(r.fl + minimumHz, r.fl * minimumRatio), 40000)
        r.ofl = clamp(r.ofl, 20, r.fl)
        r.ofh = clamp(r.ofh, r.fh, 40000)

        let minimumDegrees = clamp(c.minimumPhaseDegrees, 1, 180)
        r.pl = clamp(r.pl, 0, 180 - minimumDegrees)
        r.ph = clamp(r.ph, r.pl + minimumDegrees, 180)
        r.opl = clamp(r.opl, 0, r.pl)
        r.oph = clamp(r.oph, r.ph, 180)

        let minimumBalance = clamp(c.minimumBalance, 1, 200)
        r.bl = clamp(r.bl, -100, 100 - minimumBalance)
        r.bh = clamp(r.bh, r.bl + minimumBalance, 100)
        r.obl = clamp(r.obl, -100, r.bl)
        r.obh = clamp(r.obh, r.bh, 100)
        return r
    }

    /// js:690-755 _applyCoreBoundary。核を動かすと、渡り（outer）も同じ幅のままついて来る。
    static func applyCoreBoundary(_ r: inout ETPhaseRegion, original: ETPhaseRegion,
                                  axis: ETPhaseAxisKind, edge: ETPhaseEdge,
                                  value: Double, _ c: ETPhaseConstraints) {
        switch axis {
        case .frequency:
            if edge == .low {
                let exact = min(original.fh - c.minimumFrequencyHz,
                                original.fh / max(c.minimumFrequencyRatio, 1))
                let maximumLow = exact - abs(exact) * .ulpOfOne * 4
                let next = clamp(value, 20, maximumLow)
                let transitionRatio = original.ofl > 0 ? original.fl / original.ofl : 1
                r.fl = next
                r.ofl = transitionRatio > 0 ? next / transitionRatio : next
            } else {
                let minimumHigh = max(original.fl + c.minimumFrequencyHz,
                                      original.fl * c.minimumFrequencyRatio)
                let next = clamp(value, minimumHigh, 40000)
                let transitionRatio = original.fh > 0 ? original.ofh / original.fh : 1
                r.fh = next
                r.ofh = next * transitionRatio
            }

        case .balance:
            if edge == .low {
                let next = clamp(value, -100, original.bh - c.minimumBalance)
                let transition = original.bl - original.obl
                r.bl = next
                r.obl = next - transition
            } else {
                let next = clamp(value, original.bl + c.minimumBalance, 100)
                let transition = original.obh - original.bh
                r.bh = next
                r.obh = next + transition
            }

        case .phase:
            if edge == .low {
                let exact = original.ph - c.minimumPhaseDegrees
                let maximumLow = exact - abs(exact) * .ulpOfOne * 4
                let next = clamp(value, 0, maximumLow)
                let transition = original.pl - original.opl
                r.pl = next
                r.opl = next - transition
            } else {
                let next = clamp(value, original.pl + c.minimumPhaseDegrees, 180)
                let transition = original.oph - original.ph
                r.ph = next
                r.oph = next + transition
            }
        }
    }

    /// js:213-222 phaseSelectEqBalanceRatio。"70.0:30.0" の形。
    static func balanceRatio(_ balance: Double) -> String {
        let v = clamp(balance, -100, 100)
        let lower = ((100 - abs(v)) * 5).rounded() / 10
        let higher = 100 - lower
        let left = v < 0 ? higher : lower
        let right = v < 0 ? lower : higher
        return String(format: "%.1f:%.1f", left, right)
    }
}

// MARK: - 図の中の四角と角

private struct ETPhaseSegment {
    let low: Double       // 表示座標（度 or %）
    let high: Double
    let bottomHz: Double
    let topHz: Double
    let isOuter: Bool
}

private struct ETPhaseHandle: Identifiable {
    let id: String
    let isOuter: Bool
    /// 動かす境目。片方だけの取っ手（位相 0 の割り取っ手）は nil が入る。
    let horizontal: ETPhaseEdge?
    let frequency: ETPhaseEdge?
    /// 位相表示の左右。-1 か +1。バランス表示では +1。
    let side: Double
    let x: Double         // 表示座標の値
    let hz: Double
}

private enum ETPhaseDragKind {
    case move
    case resize(ETPhaseHandle)
}

private struct ETPhaseDrag {
    let band: Int
    let original: ETPhaseRegion
    let kind: ETPhaseDragKind
    let startHorizontal: Double
    let startFrequency: Double
    let startLocation: CGPoint
    let grabOffset: CGSize
    /// 位相で範囲ごと動かすときの向き。0 は未定。
    var side: Double
}

private struct ETPhaseHistoryFrame {
    let time: TimeInterval
    let points: [ETPhaseMapPoint]
}

// MARK: - 本体

struct PhaseSelectEqView: View {

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    @ObservedObject private var telemetry = Telemetry.shared
    @Environment(\.etGraphOnly) private var graphOnly

    enum AxisMode: String, CaseIterable { case phase, balance }
    enum DragMode: String, CaseIterable { case move, resize }

    @State private var band = 0
    @State private var axisMode: AxisMode = .phase
    @State private var dragMode: DragMode = .resize
    @State private var drag: ETPhaseDrag?
    @State private var showsBoundaries = false

    @State private var history: [ETPhaseHistoryFrame] = []
    @State private var lastSequence: UInt32?
    /// 雲を描くのに要る。枠が来るまでは 48k / 4096 として扱う（js:187-188 と同じ既定）。
    @State private var sampleRate: Double = 48000
    @State private var fftSize: Double = 4096
    /// 図の枠の実寸の横幅（目盛りの余白を除く）。描いて測るまではnil。
    @State private var plotWidth: Double?

    private static let bandCount = 5
    private static let graphHeight: CGFloat = 190
    private static let historySeconds: TimeInterval = 0.5
    private static let historyFade: TimeInterval = 0.22
    /// 掴んだ位置と角のずれを、ここまでしか持ち越さない。
    private static let maximumGrabOffset: CGFloat = 44

    private var insets: ETGraphInsets {
        ETGraphInsets(leading: 30, trailing: 10, top: 6, bottom: 14)
    }

    private var cloudShading: GraphicsContext.Shading { .style(.primary) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !graphOnly {
                modePickers
            }
            graph
            if !graphOnly {
                bandRow
                bandControls
                DisclosureGroup("Band Boundaries", isExpanded: $showsBoundaries) {
                    boundaryRows
                }
                .font(.system(size: 13, weight: .semibold))
            }
        }
        .onChange(of: frameSequence) { _, _ in appendHistory() }
    }

    // MARK: 値の読み書き

    private func offset(_ key: String, _ slot: Int) -> Int? {
        guard let p = node.spec.params.first(where: { $0.key == key }) else { return nil }
        let o = p.offset + (p.isArray ? slot : 0)
        return node.values.indices.contains(o) ? o : nil
    }

    private func value(_ key: String, _ slot: Int) -> Double {
        guard let o = offset(key, slot) else { return 0 }
        return Double(node.values[o])
    }

    private func set(_ key: String, _ slot: Int, _ v: Double) {
        guard let o = offset(key, slot) else { return }
        dsp.setValue(Float(v), at: index, offset: o)
    }

    private func region(_ slot: Int) -> ETPhaseRegion {
        ETPhaseRegion(enabled: value("en", slot) >= 0.5,
                      ofl: value("ofl", slot), fl: value("fl", slot),
                      fh: value("fh", slot), ofh: value("ofh", slot),
                      opl: value("opl", slot), pl: value("pl", slot),
                      ph: value("ph", slot), oph: value("oph", slot),
                      gain: value("gn", slot),
                      solo: value("so", slot) >= 0.5,
                      obl: value("obl", slot), bl: value("bl", slot),
                      bh: value("bh", slot), obh: value("obh", slot))
    }

    /// 画面に出すぶん。並びが壊れていても描けるように整えてから使う。
    private func displayRegion(_ slot: Int) -> ETPhaseRegion {
        ETPhaseMath.normalized(region(slot), constraints)
    }

    /// 変わったところだけ書く。1 回の指の動きで 15 回 set_params を叩かない。
    private func commit(_ r: ETPhaseRegion, _ slot: Int) {
        let cur = region(slot)
        if r.enabled != cur.enabled { set("en", slot, r.enabled ? 1 : 0) }
        if r.ofl != cur.ofl { set("ofl", slot, r.ofl) }
        if r.fl != cur.fl { set("fl", slot, r.fl) }
        if r.fh != cur.fh { set("fh", slot, r.fh) }
        if r.ofh != cur.ofh { set("ofh", slot, r.ofh) }
        if r.opl != cur.opl { set("opl", slot, r.opl) }
        if r.pl != cur.pl { set("pl", slot, r.pl) }
        if r.ph != cur.ph { set("ph", slot, r.ph) }
        if r.oph != cur.oph { set("oph", slot, r.oph) }
        if r.gain != cur.gain { set("gn", slot, r.gain) }
        if r.solo != cur.solo { set("so", slot, r.solo ? 1 : 0) }
        if r.obl != cur.obl { set("obl", slot, r.obl) }
        if r.bl != cur.bl { set("bl", slot, r.bl) }
        if r.bh != cur.bh { set("bh", slot, r.bh) }
        if r.obh != cur.obh { set("obh", slot, r.obh) }
    }

    private func commitNormalized(_ r: ETPhaseRegion, _ slot: Int) {
        commit(ETPhaseMath.normalized(r, constraints), slot)
    }

    // MARK: テレメトリ

    private var frame: ETFrame? {
        telemetry.frame(tap: node.tapId, type: .phaseSelectMap)
    }

    private var frameSequence: UInt32 { frame?.sequence ?? 0 }

    private func appendHistory() {
        guard let frame, let map = ETPhaseMapFrame.read(frame) else { return }
        // 連番が飛んだり取りこぼしの印が立っていたら、貯めたぶんは捨てる（js:461-470）。
        let expected = lastSequence.map { $0 &+ 1 }
        if expected == nil || frame.sequence != expected || frame.dropped {
            history.removeAll()
        }
        lastSequence = frame.sequence
        sampleRate = map.sampleRate
        fftSize = Double(map.fftSize)

        let now = Date.timeIntervalSinceReferenceDate
        history.append(ETPhaseHistoryFrame(time: now, points: map.points))
        let cutoff = now - Self.historySeconds
        history.removeAll { $0.time < cutoff }
        if history.count > 8 { history.removeFirst(history.count - 8) }
    }

    // MARK: 軸

    /// js:483-486 _maximumDisplayFrequency。
    private var maximumFrequency: Double {
        max(21, min(40000, sampleRate * 0.49))
    }

    private var constraints: ETPhaseConstraints {
        // 幅は測った実寸を使う。**390pt決め打ちにしない。**iPhoneより広い所（iPad）では
        // 最小幅が実際より太く効いて、帯を狭められなかった。測る前だけiPhoneの幅で見積もる。
        ETPhaseConstraints(plotWidth: plotWidth
                               ?? 390 - Double(insets.leading + insets.trailing) - 32,
                           plotHeight: Double(Self.graphHeight - insets.top - insets.bottom),
                           maximumFrequency: maximumFrequency,
                           sampleRate: sampleRate, fftSize: fftSize)
    }

    private var xAxis: ETAxis {
        if axisMode == .phase {
            // js:229-243 phaseSelectEqAxisGrid の <560px のとき。度記号まで同じ。
            let ticks: [ETAxisTick] = [
                ETAxisTick(-180, "-180°"), ETAxisTick(-90, "-90°"),
                ETAxisTick(0, "0°", emphasized: true),
                ETAxisTick(90, "+90°"), ETAxisTick(180, "+180°")
            ]
            return ETAxis(scale: .linear, lower: -180, upper: 180, ticks: ticks)
        }
        let ticks: [ETAxisTick] = [
            ETAxisTick(-100, "100:0"), ETAxisTick(-60, "80:20"),
            ETAxisTick(0, "50:50", emphasized: true),
            ETAxisTick(60, "20:80"), ETAxisTick(100, "0:100")
        ]
        return ETAxis(scale: .linear, lower: -100, upper: 100, ticks: ticks)
    }

    private var yAxis: ETAxis {
        // js:1450 の周波数の線と同じ並び。
        let top = maximumFrequency
        let ticks = [50.0, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]
            .filter { $0 < top }
            .map { ETAxisTick($0, ETFormat.hzTick($0)) }
        return ETAxis(scale: .logarithmic, lower: 20, upper: top, ticks: ticks)
    }

    // MARK: 図

    private var graph: some View {
        GraphCanvas(
            x: xAxis,
            y: yAxis,
            height: Self.graphHeight,
            insets: insets,
            readout: readout,
            caption: caption,
            clipsContent: true,
            draw: { context, plot in
                drawCloud(&context, plot)
                for slot in 0..<Self.bandCount where slot != band {
                    drawRegion(&context, plot, slot, selected: false)
                }
                drawRegion(&context, plot, band, selected: true)
                // 畳んだカードでは取っ手を描かない（FrequencyResponseGraph の印と同じ理由）。
                if !graphOnly { drawHandles(&context, plot) }
            },
            overlay: { plot in
                // バンドが切ってあるときは面を置かない。置くと一覧の縦スクロールを食う。
                if displayRegion(band).enabled {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(dragGesture(in: plot))
                }
            })
        // ETPlotと同じ引き算（GraphCanvas.swiftのETPlot.init）。
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            plotWidth = Double(max(1, width - insets.leading - insets.trailing))
        }
    }

    private func segments(_ r: ETPhaseRegion, outer: Bool) -> [ETPhaseSegment] {
        let bottomHz = outer ? r.ofl : r.fl
        let topHz = outer ? r.ofh : r.fh
        if axisMode == .phase {
            let low = outer ? r.opl : r.pl
            let high = outer ? r.oph : r.ph
            return ETPhaseMath.displaySegments(low: low, high: high).map {
                ETPhaseSegment(low: $0.low, high: $0.high,
                               bottomHz: bottomHz, topHz: topHz, isOuter: outer)
            }
        }
        return [ETPhaseSegment(low: outer ? r.obl : r.bl, high: outer ? r.obh : r.bh,
                               bottomHz: bottomHz, topHz: topHz, isOuter: outer)]
    }

    private func rect(_ seg: ETPhaseSegment, _ plot: ETPlot) -> CGRect {
        let left = plot.x(seg.low)
        let right = plot.x(seg.high)
        let top = plot.y(seg.topHz)
        let bottom = plot.y(seg.bottomHz)
        return CGRect(x: min(left, right), y: min(top, bottom),
                      width: abs(right - left), height: abs(bottom - top))
    }

    private func drawRegion(_ context: inout GraphicsContext, _ plot: ETPlot,
                            _ slot: Int, selected: Bool) {
        let r = displayRegion(slot)
        guard r.enabled else { return }
        let shading = selected ? ETGraphShading.curve : ETGraphShading.muted
        for seg in segments(r, outer: true) {
            context.stroke(Path(rect(seg, plot)), with: shading,
                           style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
        for seg in segments(r, outer: false) {
            let box = rect(seg, plot)
            context.stroke(Path(box), with: shading, lineWidth: selected ? 2 : 1)
            // バンド番号。四角の左上に置く（js:1379 _drawBandLabel と同じ場所）。
            context.draw(Text("\(slot + 1)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)),
                         at: CGPoint(x: box.minX + 4, y: box.minY + 4), anchor: .topLeading)
        }
    }

    /// 点の雲。濃さは「その枠の古さ」「点の大きさ」「いま見ていない軸での重み」の積（js:1481-1496）。
    private func drawCloud(_ context: inout GraphicsContext, _ plot: ETPlot) {
        guard !history.isEmpty else { return }
        let now = Date.timeIntervalSinceReferenceDate
        let r = displayRegion(band)
        var buckets: [Int: Path] = [:]

        for frame in history {
            let age = now - frame.time
            guard age <= Self.historySeconds else { continue }
            let ageOpacity = age > 0 ? exp(-age / Self.historyFade) : 1
            for p in frame.points {
                guard p.relativeLevelDb >= -72 else { continue }
                let level = ETPhaseMath.clamp((p.relativeLevelDb + 72) / 72, 0, 1)
                let hidden = hiddenAxisWeight(p, r)
                let alpha = ageOpacity * (0.15 + 0.75 * level) * (0.18 + 0.82 * hidden)
                guard alpha.isFinite, alpha > 0.02 else { continue }
                let bucket = min(5, max(0, Int(alpha * 6)))
                let radius = 0.6 + 1.1 * level
                let x = plot.x(axisMode == .phase ? p.phase : p.balance)
                let y = plot.y(p.frequency)
                buckets[bucket, default: Path()].addEllipse(
                    in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
            }
        }

        for (bucket, path) in buckets {
            context.opacity = Double(bucket + 1) / 6
            context.fill(path, with: cloudShading)
        }
        context.opacity = 1
    }

    /// いま横軸に出していない側（位相を出しているならバランス）での重み。js:1412-1420。
    private func hiddenAxisWeight(_ p: ETPhaseMapPoint, _ r: ETPhaseRegion) -> Double {
        guard r.enabled else { return 1 }
        if axisMode == .balance {
            return ETPhaseMath.axisWeight(abs(p.phase), r.opl, r.pl, r.ph, r.oph)
        }
        return ETPhaseMath.axisWeight(p.balance, r.obl, r.bl, r.bh, r.obh)
    }

    // MARK: 角

    private func handles(_ r: ETPhaseRegion) -> [ETPhaseHandle] {
        guard r.enabled else { return [] }
        var out: [ETPhaseHandle] = []
        for outer in [false, true] {
            for (segIndex, seg) in segments(r, outer: outer).enumerated() {
                let left = leftEdge(seg)
                let right = rightEdge(seg)
                let corners: [(Double, ETPhaseEdge, Double, ETPhaseEdge)] = [
                    (seg.low, left, seg.bottomHz, .low),
                    (seg.low, left, seg.topHz, .high),
                    (seg.high, right, seg.bottomHz, .low),
                    (seg.high, right, seg.topHz, .high)
                ]
                for (i, corner) in corners.enumerated() {
                    let side: Double = axisMode == .balance ? 1 : (corner.0 < 0 ? -1 : 1)
                    out.append(ETPhaseHandle(
                        id: "\(outer ? "o" : "c")\(segIndex)\(i)",
                        isOuter: outer, horizontal: corner.1, frequency: corner.3,
                        side: side, x: corner.0, hz: corner.2))
                }
            }
        }
        // 核の下側が 0°のときは左右の四角がくっついていて、真ん中に境目が無い。
        // web は そこに割り取っ手（js:1267 の split）を置いて中央を開けられるようにしている。
        // 指では左右どちらへ引いたかを見分ける意味が薄いので、右へ引くと開く形にした。
        if axisMode == .phase && r.pl == 0 {
            out.append(ETPhaseHandle(id: "split", isOuter: false,
                                     horizontal: .low, frequency: nil,
                                     side: 1, x: 0, hz: (r.fl * r.fh).squareRoot()))
        }
        return out
    }

    /// js:1250-1251。位相の左右対称表示では、左の辺が「大きい方の境目」になることがある。
    private func leftEdge(_ seg: ETPhaseSegment) -> ETPhaseEdge {
        if axisMode == .balance { return .low }
        if seg.high <= 0 { return .high }
        return seg.low < 0 ? .high : .low
    }

    private func rightEdge(_ seg: ETPhaseSegment) -> ETPhaseEdge {
        if axisMode == .balance { return .high }
        if seg.low >= 0 { return .high }
        return seg.high > 0 ? .high : .low
    }

    private func drawHandles(_ context: inout GraphicsContext, _ plot: ETPlot) {
        let r = displayRegion(band)
        guard r.enabled else { return }

        if dragMode == .move {
            // 範囲ごと動かすときは、どこを触ってもよい。中心に印だけ置く。
            for seg in segments(r, outer: false) {
                let box = rect(seg, plot)
                let c = CGPoint(x: box.midX, y: box.midY)
                var cross = Path()
                cross.move(to: CGPoint(x: c.x - 7, y: c.y))
                cross.addLine(to: CGPoint(x: c.x + 7, y: c.y))
                cross.move(to: CGPoint(x: c.x, y: c.y - 7))
                cross.addLine(to: CGPoint(x: c.x, y: c.y + 7))
                context.stroke(cross, with: ETGraphShading.curve, lineWidth: 2)
            }
            return
        }

        for handle in handles(r) {
            let pt = plot.clampedPoint(handle.x, handle.hz)
            if handle.id == "split" {
                // 割り取っ手は菱形。角の丸・四角と見分けがつくように（web も形を変えている）。
                var diamond = Path()
                diamond.move(to: CGPoint(x: pt.x, y: pt.y - 7))
                diamond.addLine(to: CGPoint(x: pt.x + 7, y: pt.y))
                diamond.addLine(to: CGPoint(x: pt.x, y: pt.y + 7))
                diamond.addLine(to: CGPoint(x: pt.x - 7, y: pt.y))
                diamond.closeSubpath()
                context.fill(diamond, with: ETGraphShading.curve)
            } else if handle.isOuter {
                context.stroke(Path(CGRect(x: pt.x - 5, y: pt.y - 5, width: 10, height: 10)),
                               with: ETGraphShading.curve, lineWidth: 2)
            } else {
                context.fill(Path(ellipseIn: CGRect(x: pt.x - 5, y: pt.y - 5, width: 10, height: 10)),
                             with: ETGraphShading.curve)
            }
        }
    }

    // MARK: 掴む

    private func dragGesture(in plot: ETPlot) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                if drag == nil { begin(gesture, plot) }
                apply(gesture, plot)
            }
            .onEnded { _ in drag = nil }
    }

    private func begin(_ gesture: DragGesture.Value, _ plot: ETPlot) {
        let original = displayRegion(band)
        let start = gesture.startLocation
        let kind: ETPhaseDragKind
        var offset = CGSize.zero

        if dragMode == .resize, let nearest = nearestHandle(to: start, plot, original) {
            let pt = plot.clampedPoint(nearest.x, nearest.hz)
            let dx = start.x - pt.x
            let dy = start.y - pt.y
            // 遠くから掴んだときはずれを持ち越さず、角を指へ吸い付かせる。
            if hypot(dx, dy) <= Self.maximumGrabOffset {
                offset = CGSize(width: dx, height: dy)
            }
            kind = .resize(nearest)
        } else {
            kind = .move
        }

        drag = ETPhaseDrag(band: band, original: original, kind: kind,
                           startHorizontal: plot.xAxis.clamp(plot.xValue(at: start.x)),
                           startFrequency: plot.yAxis.clamp(plot.yValue(at: start.y)),
                           startLocation: start, grabOffset: offset, side: 0)
    }

    private func nearestHandle(to location: CGPoint, _ plot: ETPlot,
                               _ r: ETPhaseRegion) -> ETPhaseHandle? {
        handles(r).min { a, b in
            let pa = plot.clampedPoint(a.x, a.hz)
            let pb = plot.clampedPoint(b.x, b.hz)
            return hypot(pa.x - location.x, pa.y - location.y)
                < hypot(pb.x - location.x, pb.y - location.y)
        }
    }

    private func apply(_ gesture: DragGesture.Value, _ plot: ETPlot) {
        guard var state = drag else { return }
        let c = constraints
        let original = state.original
        var r = original

        let point = CGPoint(x: gesture.location.x - state.grabOffset.width,
                            y: gesture.location.y - state.grabOffset.height)
        let horizontal = plot.xAxis.clamp(plot.xValue(at: point.x))
        let frequency = plot.yAxis.clamp(plot.yValue(at: point.y))

        switch state.kind {
        case .move:
            // js:1051-1089。位相は左右対称なので、動かす向きを最初のひと押しで決める。
            if axisMode == .phase {
                if state.side == 0 && abs(gesture.location.x - state.startLocation.x) > 1 {
                    state.side = gesture.location.x >= state.startLocation.x ? 1 : -1
                }
                let side = state.side == 0 ? 1 : state.side
                let delta = side * (horizontal - state.startHorizontal)
                let fitted = ETPhaseMath.clamp(delta, -original.opl, 180 - original.oph)
                r.opl += fitted
                r.pl += fitted
                r.ph += fitted
                r.oph += fitted
            } else {
                let delta = ETPhaseMath.clamp(horizontal - state.startHorizontal,
                                              -100 - original.obl, 100 - original.obh)
                r.obl += delta
                r.bl += delta
                r.bh += delta
                r.obh += delta
            }
            let ratio = state.startFrequency > 0 ? frequency / state.startFrequency : 1
            let fittedRatio = ETPhaseMath.clamp(ratio,
                                                original.ofl > 0 ? 20 / original.ofl : 1,
                                                original.ofh > 0 ? 40000 / original.ofh : 1)
            r.ofl *= fittedRatio
            r.fl *= fittedRatio
            r.fh *= fittedRatio
            r.ofh *= fittedRatio

        case .resize(let handle):
            if let edge = handle.horizontal {
                if axisMode == .phase {
                    let onSide = handle.side < 0 ? min(horizontal, 0) : max(horizontal, 0)
                    let absolute = abs(onSide)
                    if handle.isOuter {
                        if edge == .low { r.opl = absolute } else { r.oph = absolute }
                    } else {
                        ETPhaseMath.applyCoreBoundary(&r, original: original, axis: .phase,
                                                      edge: edge, value: absolute, c)
                    }
                } else {
                    if handle.isOuter {
                        if edge == .low { r.obl = horizontal } else { r.obh = horizontal }
                    } else {
                        ETPhaseMath.applyCoreBoundary(&r, original: original, axis: .balance,
                                                      edge: edge, value: horizontal, c)
                    }
                }
            }
            if let edge = handle.frequency {
                if handle.isOuter {
                    if edge == .low { r.ofl = frequency } else { r.ofh = frequency }
                } else {
                    ETPhaseMath.applyCoreBoundary(&r, original: original, axis: .frequency,
                                                  edge: edge, value: frequency, c)
                }
            }
        }

        drag = state
        commitNormalized(r, state.band)
    }

    // MARK: 図の外に出す値

    private var readout: [ETReadoutItem] {
        guard drag != nil else { return [] }
        let r = displayRegion(band)
        var items = [ETReadoutItem("BAND", "\(band + 1)")]
        items.append(ETReadoutItem("FREQ",
                                   "\(ETFormat.hzTick(r.fl))–\(ETFormat.hzTick(r.fh))"))
        if axisMode == .phase {
            items.append(ETReadoutItem("PHASE",
                                       String(format: "%.0f–%.0f°", r.pl, r.ph)))
        } else {
            items.append(ETReadoutItem("BAL",
                                       String(format: "%.0f–%.0f%%", r.bl, r.bh)))
        }
        return items
    }

    /// 横軸に出していない側の絞り込み。js:200-211, 246-256 と同じ文言。
    private var caption: String {
        let r = displayRegion(band)
        guard r.enabled else { return "Band \(band + 1) is off." }
        if axisMode == .balance {
            let limited = r.opl != 0 || r.pl != 0 || r.ph != 180 || r.oph != 180
            guard limited else { return "Band \(band + 1) · Phase full range" }
            return "Band \(band + 1) · P "
                + String(format: "%.0f°›%.0f–%.0f°›%.0f°", r.opl, r.pl, r.ph, r.oph)
        }
        let limited = r.obl != -100 || r.bl != -100 || r.bh != 100 || r.obh != 100
        guard limited else { return "Band \(band + 1) · Balance full range" }
        return "Band \(band + 1) · B \(ETPhaseMath.balanceRatio(r.obl))›"
            + "\(ETPhaseMath.balanceRatio(r.bl))–\(ETPhaseMath.balanceRatio(r.bh))›"
            + "\(ETPhaseMath.balanceRatio(r.obh))"
    }

    // MARK: 操作

    private var modePickers: some View {
        HStack(spacing: 8) {
            Picker("Axis", selection: $axisMode) {
                Text("Phase").tag(AxisMode.phase)
                Text("Balance").tag(AxisMode.balance)
            }
            .pickerStyle(.segmented)

            Picker("Drag", selection: $dragMode) {
                Text("Move").tag(DragMode.move)
                Text("Resize").tag(DragMode.resize)
            }
            .pickerStyle(.segmented)
        }
    }

    /// **番号だけの札を 1 行に並べる。**他の帯（ModalResonator の chip(_:)、
    /// 5band / 15band / FIR PEQ）と同じ形にしてある。
    ///
    /// 前はチェックボックスと「Band N」を 1 つの器に入れた札を LazyVGrid で折り返して
    /// いた（上流 js:801-826 の写し）。上流の 5band は右クリックで入切するので同じ形に
    /// できず、ここだけ別物になっていた。入切は下の一枚が持つ形に寄せる。
    private var bandRow: some View {
        HStack(spacing: 6) {
            ForEach(0..<Self.bandCount, id: \.self) { slot in
                bandTab(slot)
            }
        }
    }

    private func bandTab(_ slot: Int) -> some View {
        let picked = band == slot
        let on = region(slot).enabled
        return Button {
            band = slot
        } label: {
            Text("\(slot + 1)")
                .font(.system(size: 13, weight: picked ? .bold : .regular))
                .foregroundStyle(picked ? AnyShapeStyle(.white)
                                        : (on ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)))
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(picked ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                            in: .rect(cornerRadius: ETMetrics.innerRadius, style: .continuous))
                .opacity(on ? 1 : 0.45)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Band \(slot + 1)")
        .accessibilityAddTraits(picked ? [.isSelected] : [])
    }

    /// js:835-837 は Gain と Solo の 2 本。入切は帯のチェックが持っていたが、
    /// 札を番号だけにしたのでここへ移した（ModalResonator の bandPanel と同じ形）。
    private var bandControls: some View {
        let r = region(band)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("BAND \(band + 1)")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                // **enable(_:_:) を必ず通す。**生の 0/1 を書くと、EffectCatalog が
                // 配列の既定を 0 に潰している region を入にしたとき図に出ない四角になる。
                Toggle("Enabled", isOn: Binding(get: { r.enabled },
                                                set: { enable(band, $0) }))
                    .toggleStyle(.power)
                    .labelsHidden()
            }

            ETPhaseSliderRow(label: "Gain", unit: "%", value: r.gain,
                             range: 0...200, step: 1, logarithmic: false) {
                set("gn", band, $0)
            }
            Toggle(isOn: Binding(get: { r.solo }, set: { set("so", band, $0 ? 1 : 0) })) {
                Text("Solo").font(.system(size: 14))
            }
        }
    }

    /// 生成された EffectCatalog は配列の既定を 0 に潰しているので、
    /// 中身が範囲の外のまま入にすると図に出ない四角になる。そのときだけ規定値を入れる。
    private func enable(_ slot: Int, _ on: Bool) {
        var r = region(slot)
        if on && r.isDegenerate {
            let solo = r.solo
            r = ETPhaseRegion.fallback
            r.solo = solo
        }
        r.enabled = on
        commitNormalized(r, slot)
    }

    private var boundaryRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            frequencyRows
            phaseRows
            balanceRows
        }
        .padding(.top, 4)
    }

    private func groupHeading(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }

    /// js:838-841 と 848-853。絶対値で触るのは核だけ、渡りはオクターブ差で触る。
    /// 値は整えたぶんを読む。normalized が 20 ≤ ofl ≤ fl と fh ≤ ofh ≤ 40000 を
    /// 約束するので、log2 が負や inf にならない。
    private var frequencyRows: some View {
        let r = displayRegion(band)
        return VStack(alignment: .leading, spacing: 8) {
            groupHeading("FREQUENCY")
            ETPhaseSliderRow(label: "Core Low", unit: "Hz", value: r.fl,
                             range: 20...40000, step: 1, logarithmic: true) { core(.frequency, .low, $0) }
            ETPhaseSliderRow(label: "Core High", unit: "Hz", value: r.fh,
                             range: 20...40000, step: 1, logarithmic: true) { core(.frequency, .high, $0) }
            ETPhaseSliderRow(label: "Low Transition", unit: "oct", value: log2(r.fl / r.ofl),
                             range: 0...10, step: 0.01, logarithmic: false) {
                setFrequencyTransition(.low, $0)
            }
            ETPhaseSliderRow(label: "High Transition", unit: "oct", value: log2(r.ofh / r.fh),
                             range: 0...10, step: 0.01, logarithmic: false) {
                setFrequencyTransition(.high, $0)
            }
        }
    }

    /// js:842-847 と 854-859。核の端は 0-179 / 1-180 で、潰せないようにずらしてある。
    private var phaseRows: some View {
        let r = displayRegion(band)
        return VStack(alignment: .leading, spacing: 8) {
            groupHeading("PHASE")
            ETPhaseSliderRow(label: "Core Low", unit: "°", value: r.pl,
                             range: 0...179, step: 1, logarithmic: false) { core(.phase, .low, $0) }
            ETPhaseSliderRow(label: "Core High", unit: "°", value: r.ph,
                             range: 1...180, step: 1, logarithmic: false) { core(.phase, .high, $0) }
            ETPhaseSliderRow(label: "Low Transition", unit: "°", value: r.pl - r.opl,
                             range: 0...180, step: 1, logarithmic: false) { setPhaseTransition(.low, $0) }
            ETPhaseSliderRow(label: "High Transition", unit: "°", value: r.oph - r.ph,
                             range: 0...180, step: 1, logarithmic: false) { setPhaseTransition(.high, $0) }
        }
    }

    private var balanceRows: some View {
        let r = region(band)
        return VStack(alignment: .leading, spacing: 8) {
            groupHeading("BALANCE")
            ETPhaseSliderRow(label: "Outer Low", unit: "%", value: r.obl,
                             range: -100...100, step: 0.1, logarithmic: false) { setOuter(\.obl, $0) }
            ETPhaseSliderRow(label: "Core Low", unit: "%", value: r.bl,
                             range: -100...100, step: 0.1, logarithmic: false) { core(.balance, .low, $0) }
            ETPhaseSliderRow(label: "Core High", unit: "%", value: r.bh,
                             range: -100...100, step: 0.1, logarithmic: false) { core(.balance, .high, $0) }
            ETPhaseSliderRow(label: "Outer High", unit: "%", value: r.obh,
                             range: -100...100, step: 0.1, logarithmic: false) { setOuter(\.obh, $0) }
        }
    }

    /// js:766-773 _setTransitionOctaves。核は動かさず、渡りだけを何オクターブ外へ置くか。
    private func setFrequencyTransition(_ edge: ETPhaseEdge, _ octaves: Double) {
        var r = displayRegion(band)
        let o = ETPhaseMath.clamp(octaves, 0, 10)
        if edge == .low { r.ofl = r.fl / pow(2, o) } else { r.ofh = r.fh * pow(2, o) }
        commitNormalized(r, band)
    }

    /// js:775-782 _setPhaseTransition。渡りは核から何度ぶん外か。
    private func setPhaseTransition(_ edge: ETPhaseEdge, _ degrees: Double) {
        var r = displayRegion(band)
        let d = ETPhaseMath.clamp(degrees, 0, 180)
        if edge == .low { r.opl = r.pl - d } else { r.oph = r.ph + d }
        commitNormalized(r, band)
    }

    /// 渡り（outer）だけを動かす。並びは normalized が整える。
    private func setOuter(_ field: WritableKeyPath<ETPhaseRegion, Double>, _ newValue: Double) {
        var r = region(band)
        r[keyPath: field] = newValue
        commitNormalized(r, band)
    }

    /// 核を動かす。渡りも同じ幅のままついて来る（web と同じ）。
    private func core(_ axis: ETPhaseAxisKind, _ edge: ETPhaseEdge, _ newValue: Double) {
        let original = displayRegion(band)
        var r = original
        ETPhaseMath.applyCoreBoundary(&r, original: original, axis: axis,
                                      edge: edge, value: newValue, constraints)
        commitNormalized(r, band)
    }
}

// MARK: - 値 1 個ぶんの行

/// ParameterRow は配列のパラメータに自前のバンドタブを持っている。
/// ここは 15 個すべてが同じバンドを指していないと困るので、行だけ別に用意した。
private struct ETPhaseSliderRow: View {
    let label: String
    let unit: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let logarithmic: Bool
    let onChange: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(unit.isEmpty ? label : "\(label) (\(unit))")
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                // 打ち込みも受ける。**下書きに text を渡さない**——"1.50 k" のような
                // 字は Double(_:) が nil を返して黙って捨てられる。挟むのは range で。
                ETValueField(text: text, label: label,
                             editText: { ETNumberText.draft(value) }) { typed in
                    onChange(min(max(typed, range.lowerBound), range.upperBound))
                }
            }
            Slider(value: Binding(get: { normalized }, set: { onChange(denormalized($0)) }),
                   in: 0...1)
        }
    }

    private var text: String {
        if logarithmic {
            return value >= 1000 ? String(format: "%.2f k", value / 1000)
                                 : String(format: "%.0f", value)
        }
        if step >= 1 { return String(format: "%.0f", value) }
        // 刻みが 0.01 の行（oct）は 1 桁だと動かしても数字が変わらない。
        return step >= 0.1 ? String(format: "%.1f", value) : String(format: "%.2f", value)
    }

    private var normalized: Double {
        if logarithmic {
            let lo = log(max(range.lowerBound, 1e-9))
            let hi = log(max(range.upperBound, range.lowerBound * 1.000001))
            let v = log(max(value, 1e-9))
            return ETPhaseMath.clamp((v - lo) / (hi - lo), 0, 1)
        }
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return ETPhaseMath.clamp((value - range.lowerBound) / span, 0, 1)
    }

    private func denormalized(_ t: Double) -> Double {
        if logarithmic {
            let lo = log(max(range.lowerBound, 1e-9))
            let hi = log(max(range.upperBound, range.lowerBound * 1.000001))
            return exp(lo + t * (hi - lo)).rounded()
        }
        let raw = range.lowerBound + t * (range.upperBound - range.lowerBound)
        guard step > 0 else { return raw }
        return (raw / step).rounded() * step
    }
}
