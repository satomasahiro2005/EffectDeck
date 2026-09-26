//  SWRadioSimulatorView.swift
//  SW Radio Simulator（lofi/sw_radio_simulator）。
//
//  web 版は plugins/lofi/sw_radio_simulator.js。操作面は 5 枚のタブ
//  （同 1883-1953 Station / Propagation / Tuning / Receiver / Output）で、
//  受信機の状態を出す HUD が 1 本付く（同 1999-2010、中身は 2055 drawHud）。
//
//  HUD は DSP が出した測定値を並べるだけ。frameType 18 / formatVersion 1 /
//  payload 24 バイト（dsp/plugins/lofi/sw_radio_simulator/kernel.cpp:754-767）。
//  上流は幅 560px を切ると 4 枚を 2 列 2 段に折る（同 2093-2095）。
//  iPhone の幅は常にそちら側なので、2×2 で固定してある。
//
//  上流は HUD を操作面の下に置く（同 1991 で panel、2010 で graph）が、ここでは上に置いた。
//  このアプリは図を先に置くものが多い（CompressorView・PowerAmpSagView・OscilloscopeView ほか）。
//  TubeSimulatorView は上流の並びに合わせて後ろに置いている。
//
//  ⚡ と ▲ の記号は STATIC / CLIP の字に替えた（同 2117）。
//  ⚡ は iOS では絵文字として色付きで出る。数はそのまま。

import SwiftUI
import Foundation

// MARK: - テレメトリ

/// frameType 18 / formatVersion 1 / payload 24 バイト。
/// 並びは kernel.cpp:759-764。名前は js:1715-1720 と同じ。
struct ETSWRadioTelemetry {
    let carrierPreAgcDb: Double
    let agcGainDb: Double
    let modPercent: Double
    let fadeDb: Double
    let staticCount: UInt32
    let clipCount: UInt32

    static let payloadBytes = 24

    static func read(_ frame: ETFrame) -> ETSWRadioTelemetry? {
        guard frame.matches(version: 1), frame.hasPayload(bytes: payloadBytes) else { return nil }
        let payload = frame.payloadView
        guard let scalars = payload.floats(at: 0, count: 4),
              let counters = payload.uint32s(at: 16, count: 2) else { return nil }
        // js:1722-1723 は 4 つの実数が全部有限のときだけ採る。
        guard scalars.allSatisfy({ $0.isFinite }) else { return nil }
        return ETSWRadioTelemetry(carrierPreAgcDb: Double(scalars[0]),
                                  agcGainDb: Double(scalars[1]),
                                  modPercent: Double(scalars[2]),
                                  fadeDb: Double(scalars[3]),
                                  staticCount: counters[0],
                                  clipCount: counters[1])
    }
}

// MARK: - HUD

private struct ETSWRadioCard: Identifiable {
    let id: Int
    let title: String
    let value: String
    /// 2 行目。数え上げのカードだけ持つ。
    let detail: String?
    let level: Double
}

/// 受信機の HUD。Telemetry を観測するのはここだけにしてある。
/// カード全体で観測すると 30Hz で body が作り直され、開いた Menu が閉じる。
private struct SWRadioHUD: View {

    let tapId: UInt32
    /// 4 枚目の見出しが変わる（js:2116）。
    let isAM: Bool
    let isEnabled: Bool

    @ETTelemetryFeed private var telemetry

    /// 1 つ前の数え上げ。差を経過時間で割って毎秒の回数にする（js:1764-1778）。
    @State private var lastStaticCount: UInt32?
    @State private var lastClipCount: UInt32?
    @State private var lastCounterAt: TimeInterval = 0
    @State private var staticRate: Double = 0
    @State private var clipRate: Double = 0
    /// 最後に読んだ枠の時刻と、そこから 180ms（js:1773）。
    /// 枠が来るたびに seenAt を進めるので、光っている間は次の枠で判定し直される。
    @State private var seenAt: TimeInterval = 0
    @State private var flashUntil: TimeInterval = 0

    /// 4 枚目だけ 3 行になるので、そちらが収まる高さで揃える。
    private static let cardHeight: CGFloat = 66
    private static let gap: CGFloat = 6

    var body: some View {
        content
            .onChange(of: frameSequence) { _, _ in advance() }
    }

    // MARK: 枠

    private var frame: ETFrame? {
        telemetry.frame(tap: tapId, type: .swRadioSimulator)
    }

    private var frameSequence: UInt32 { frame?.sequence ?? 0 }

    private var latest: ETSWRadioTelemetry? {
        guard let frame else { return nil }
        return ETSWRadioTelemetry.read(frame)
    }

    private func advance() {
        guard let t = latest else { return }
        let now = Date.timeIntervalSinceReferenceDate
        if let lastStatic = lastStaticCount, let lastClip = lastClipCount, lastCounterAt > 0 {
            let elapsed = now - lastCounterAt
            // 止まっていた間の差を毎秒の回数に均さない（js:1766）。
            if elapsed > 0, elapsed < 10 {
                let staticDelta = delta(t.staticCount, lastStatic)
                let clipDelta = delta(t.clipCount, lastClip)
                staticRate = Double(staticDelta) / elapsed
                clipRate = Double(clipDelta) / elapsed
                if staticDelta > 0 || clipDelta > 0 { flashUntil = now + 0.18 }
            }
        }
        lastStaticCount = t.staticCount
        lastClipCount = t.clipCount
        lastCounterAt = now
        seenAt = now
    }

    /// u32 の巻き戻り。半周を超える差は数え直しとみなして捨てる（js:1769-1770）。
    private func delta(_ now: UInt32, _ before: UInt32) -> UInt32 {
        let d = now &- before
        return d > 0x8000_0000 ? 0 : d
    }

    // MARK: 中身

    @ViewBuilder
    private var content: some View {
        if !isEnabled {
            // js:2070-2076 の messages。
            placeholder("Effect is off")
        } else if let t = latest {
            cards(t)
        } else {
            placeholder("Waiting for audio")
        }
    }

    private func placeholder(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: Self.cardHeight * 2 + Self.gap)
            .background(.quaternary, in: .rect(cornerRadius: ETMetrics.innerRadius, style: .continuous))
    }

    private func cards(_ t: ETSWRadioTelemetry) -> some View {
        let list = cardList(t)
        // 数え上げが動いた直後だけ 4 枚目に枠線が出る（js:2127, 2142）。
        let flashing = seenAt < flashUntil
        return VStack(spacing: Self.gap) {
            HStack(spacing: Self.gap) {
                card(list[0], flashing: false)
                card(list[1], flashing: false)
            }
            HStack(spacing: Self.gap) {
                card(list[2], flashing: false)
                card(list[3], flashing: flashing)
            }
        }
    }

    /// js:2100-2119。定数は js:45-48。
    private func cardList(_ t: ETSWRadioTelemetry) -> [ETSWRadioCard] {
        let sLevel = min(max((t.carrierPreAgcDb + 50) / 56, 0), 1)
        let sign = t.agcGainDb >= 0 ? "+" : ""
        return [
            ETSWRadioCard(id: 0, title: "S METER",
                          value: String(format: "S%.1f", 1 + 8 * sLevel),
                          detail: nil, level: sLevel),
            ETSWRadioCard(id: 1, title: "FADE",
                          value: String(format: "%.1f dB", t.fadeDb),
                          detail: nil, level: (t.fadeDb + 80) / 86),
            ETSWRadioCard(id: 2, title: "AGC GAIN",
                          value: sign + String(format: "%.1f dB", t.agcGainDb),
                          detail: nil, level: (t.agcGainDb + 12) / 54),
            ETSWRadioCard(id: 3, title: isAM ? "MOD / EVENTS" : "TX / EVENTS",
                          value: String(format: "%.0f%%", t.modPercent),
                          detail: String(format: "STATIC %.1f · CLIP %.1f", staticRate, clipRate),
                          level: t.modPercent / 160)
        ]
    }

    private func card(_ item: ETSWRadioCard, flashing: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.title)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)
            Text(item.value)
                .font(.system(size: 13, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let detail = item.detail {
                Text(detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Spacer(minLength: 0)
            levelBar(item.level)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.cardHeight)
        .background(.quaternary, in: .rect(cornerRadius: ETMetrics.innerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ETMetrics.innerRadius, style: .continuous)
            .stroke(.tint, lineWidth: flashing ? 1.5 : 0))
        .accessibilityElement(children: .combine)
    }

    private func levelBar(_ level: Double) -> some View {
        let filled = min(max(level, 0), 1)
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.tertiary)
                Capsule().fill(.tint).frame(width: geometry.size.width * filled)
            }
        }
        .frame(height: 4)
    }
}

// MARK: - タブ

/// js:1883-1953 の 5 枚。
private enum ETSWRadioTab: String, CaseIterable, Identifiable {
    case station, propagation, tuning, receiver, output

    var id: String { rawValue }

    var title: String {
        switch self {
        case .station:     return "Station"
        case .propagation: return "Propagation"
        case .tuning:      return "Tuning"
        case .receiver:    return "Receiver"
        case .output:      return "Output"
        }
    }

    /// そのタブに置く key。並びは上流の appendChild の順そのまま。
    var keys: [String] {
        switch self {
        case .station:     return ["rd", "tb", "pe", "md", "cp"]
        case .propagation: return ["sg", "sk", "fd", "ds", "st", "in", "io"]
        case .tuning:      return ["mo", "tn", "bf", "bw"]
        case .receiver:    return ["de", "ag", "dt", "hm", "hz"]
        case .output:      return ["sp", "og", "mx"]
        }
    }
}

// MARK: - 本体

struct SWRadioSimulatorView: View {

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    @Environment(\.etGraphOnly) private var graphOnly
    @State private var tab: ETSWRadioTab = .station

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SWRadioHUD(tapId: node.tapId, isAM: mode == "AM", isEnabled: node.enabled)
            if !graphOnly {
                tabStrip
                Divider()
                rows
            }
        }
    }

    // MARK: 値

    private func param(_ key: String) -> ETParam? {
        node.spec.params.first { $0.key == key }
    }

    /// 選択肢の中身。無ければ空。
    private func choice(_ key: String) -> String {
        guard let p = param(key), case .enumeration(let options) = p.kind,
              node.values.indices.contains(p.offset) else { return "" }
        let i = Int(node.values[p.offset].rounded())
        return options.indices.contains(i) ? options[i] : ""
    }

    private var mode: String {
        let m = choice("mo")
        return m.isEmpty ? "AM" : m
    }

    // MARK: タブ

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ETSWRadioTab.allCases) { item in
                    Button {
                        tab = item
                    } label: {
                        Text(item.title)
                            .font(.system(size: 12, weight: tab == item ? .bold : .regular))
                            .foregroundStyle(tab == item ? AnyShapeStyle(.white)
                                                         : AnyShapeStyle(.secondary))
                            .padding(.horizontal, 10)
                            .frame(minWidth: 44, minHeight: 30)
                            .background(tab == item ? AnyShapeStyle(.tint)
                                                    : AnyShapeStyle(.quaternary),
                                        in: .rect(cornerRadius: ETMetrics.innerRadius,
                                                  style: .continuous))
                            .frame(minHeight: ETMetrics.hitTarget)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(tab == item ? [.isSelected] : [])
                }
            }
        }
    }

    // MARK: 行

    private var rows: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(params(of: tab)) { p in
                ParameterRow(param: p, nodeIndex: index, values: node.values, dsp: dsp)
                    .disabled(isGated(p.key))
                    // effetune.css:3516-3518 の parameter-disabled と同じ薄さ。
                    .opacity(isGated(p.key) ? 0.52 : 1)
            }
        }
    }

    private func params(of page: ETSWRadioTab) -> [ETParam] {
        page.keys.compactMap { param($0) }
    }

    /// js:1856-1862 _syncModeDependentControls。
    /// BFO は SSB のときだけ、Detector と Detector RC は AM のときだけ効く。
    /// 値は残したまま触れなくするだけで、消しはしない。
    private func isGated(_ key: String) -> Bool {
        let ssb = mode != "AM"
        switch key {
        case "bf":       return !ssb
        case "de", "dt": return ssb
        default:         return false
        }
    }
}
