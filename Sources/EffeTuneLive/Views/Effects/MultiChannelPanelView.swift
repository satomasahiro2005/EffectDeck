//  MultiChannelPanelView.swift
//  MultiChannel Panel。チャンネルごとのメーターと、Mute / Solo / Link / Volume / Delay。
//
//  テレメトリ: ETFrameType.multiChannelLevels = 10、formatVersion 1
//  （kernel.cpp:16-17 の kTapMultiChannelLevels / kTelemetryVersion、
//    multi_channel_panel.js:1-2 の MULTI_CHANNEL_LEVELS_FRAME / _VERSION）
//
//  ペイロードの並び。dsp/plugins/basics/multi_channel_panel/kernel.cpp:148-161 が書き、
//  plugins/basics/multi_channel_panel.js:676-711 が同じ位置を読んでいる:
//      0            u8  channelCount     kernel.cpp:152 / multi_channel_panel.js:688
//      1..3         u8  0 で埋める       kernel.cpp:151 / 読む側は 0 でなければ捨てる（同 692-693）
//      4 + ch*8     f32 peak             kernel.cpp:155 / 同 700  線形の振幅
//      8 + ch*8     u8  muted            kernel.cpp:156 / 同 701
//                                        Solo を踏まえた「実際に消えているか」（kernel.cpp:96）
//      9..11 + ch*8 u8  0 で埋める       読む側は 0 でなければ捨てる（同 703-705）
//  長さは 4 + n*8 ちょうど（kernel.cpp:158-159 / multi_channel_panel.js:689-691）。
//
//  peak はフェーダーを通す前の値（kernel.cpp:117-120 が入力から取っている）。
//  web 版はこれに画面側の Volume を掛け、消えているチャンネルは 0 にしてから
//  メーターに出している（multi_channel_panel.js:744-761）。ここも同じにしてある。
//
//  落ち方と保持は web 版と同じ（multi_channel_panel.js:26-27）:
//      ピーク保持 1.0 秒、落下 20 dB/秒。目盛りは -96..0 dB（同 1043-1044）。

import SwiftUI

struct MultiChannelPanelView: View {

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    @ObservedObject private var telemetry = Telemetry.shared

    /// いま触っているチャンネル。16 本ぶんのつまみを縦に並べない。
    @State private var strip = 0
    /// 棒の値。dB。枠が来るたびに落としながら追いかける。
    @State private var bars: [Int: Double] = [:]
    @State private var lastFall = Date()

    private static let floorDB: Double = -96
    private static let fallRate: Double = 20
    private static let holdTime: Double = 1.0
    private static let ticks: [Double] = [-96, -72, -48, -24, -12, 0]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            meter
            channelPicker
            switches
            if let volume = param("volume") { control(volume, channel: channel) }
            if let delay = param("delay") { control(delay, channel: channel) }
        }
        .onChange(of: levelKey) { _, _ in advance() }
        .onAppear { lastFall = Date() }
    }

    // MARK: 図

    @ViewBuilder private var meter: some View {
        if let r = reading {
            MeterView(channels: channels(r),
                      range: Self.floorDB...0,
                      ticks: Self.ticks,
                      holdsPeak: true,
                      holdTime: Self.holdTime,
                      fallRate: Self.fallRate,
                      rowHeight: r.peaks.count > 8 ? 9 : 14,
                      showsReadout: r.peaks.count <= 4)
        } else {
            MeterView(channels: [],
                      range: Self.floorDB...0,
                      ticks: Self.ticks,
                      caption: "Waiting for audio")
        }
    }

    private func channels(_ r: Reading) -> [ETMeterChannel] {
        r.peaks.indices.map { ch in
            let db = ETdB.fromAmplitude(gained(r, ch), floor: Self.floorDB)
            return ETMeterChannel(id: ch,
                                  label: "\(ch + 1)",
                                  levelDB: bars[ch] ?? db,
                                  peakDB: db)
        }
    }

    /// フェーダーを通した後の振幅（multi_channel_panel.js:760）。
    private func gained(_ r: Reading, _ ch: Int) -> Float {
        guard !r.muted[ch] else { return 0 }
        guard let volume = param("volume") else { return r.peaks[ch] }
        let db = Double(value(volume.offset + ch))
        return Float(Double(r.peaks[ch]) * ETdB.amplitude(db))
    }

    private func advance() {
        guard let r = reading else { return }
        let now = Date()
        let dt = min(max(now.timeIntervalSince(lastFall), 0), 0.5)
        lastFall = now

        var next: [Int: Double] = [:]
        for ch in r.peaks.indices {
            let db = ETdB.fromAmplitude(gained(r, ch), floor: Self.floorDB)
            let fallen = (bars[ch] ?? Self.floorDB) - Self.fallRate * dt
            next[ch] = max(db, max(fallen, Self.floorDB))
        }
        bars = next
    }

    // MARK: つまみ

    private var channelCount: Int {
        // 枠が来るまでは本数が分からない。せめて L/R は触れるようにしておく。
        min(max(reading?.peaks.count ?? 2, 2), 16)
    }

    private var channel: Int { min(max(strip, 0), channelCount - 1) }

    private var channelPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CHANNEL")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    // 本数はテレメトリで変わるので、範囲をそのまま渡さない。
                    ForEach(Array(0..<channelCount), id: \.self) { ch in
                        Button {
                            strip = ch
                        } label: {
                            Text("\(ch + 1)")
                                .font(.system(size: 12, weight: channel == ch ? .bold : .regular))
                                .foregroundStyle(channel == ch
                                                 ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                                .frame(minWidth: 30, minHeight: 26)
                                .background(channel == ch
                                            ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                                            in: .rect(cornerRadius: ETMetrics.innerRadius, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var switches: some View {
        HStack(spacing: 8) {
            if let mute = param("mute") {
                badgeButton("M", on: isOn(mute.offset + channel)) {
                    apply(mute.offset, isOn(mute.offset + channel) ? 0 : 1, channel: channel)
                }
            }
            if let solo = param("solo") {
                badgeButton("S", on: isOn(solo.offset + channel)) {
                    apply(solo.offset, isOn(solo.offset + channel) ? 0 : 1, channel: channel)
                }
            }
            if let link = param("link"), channel < link.count {
                badgeButton("LINK \(channel + 1)-\(channel + 2)",
                            on: isOn(link.offset + channel),
                            wide: true) {
                    setLink(link, on: !isOn(link.offset + channel))
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func badgeButton(_ label: String, on: Bool, wide: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .bold))
                .lineLimit(1)
                .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .padding(.horizontal, wide ? 10 : 0)
                .frame(minWidth: wide ? 0 : 34, minHeight: 28)
                .background(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                            in: .rect(cornerRadius: ETMetrics.innerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func control(_ param: ETParam, channel: Int) -> some View {
        if case .number(let lo, let hi, let step, let unit, _) = param.kind, hi > lo {
            let offset = param.offset + channel
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(unit.isEmpty ? param.label : "\(param.label) (\(unit))")
                        .font(.system(size: 14))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 4)
                    ValueBox(text: param.format(value(offset)))
                }
                Slider(value: Binding(get: { Double(value(offset)) },
                                      set: { apply(param.offset, Float($0), channel: channel) }),
                       in: Double(lo)...Double(hi),
                       step: step > 0 ? Double(step) : 0.0001)
            }
        }
    }

    // MARK: 値をいじる

    private func param(_ name: String) -> ETParam? {
        node.spec.params.first { $0.name == name }
    }

    private func value(_ offset: Int) -> Float {
        node.values.indices.contains(offset) ? node.values[offset] : 0
    }

    private func isOn(_ offset: Int) -> Bool { value(offset) >= 0.5 }

    /// つながっているチャンネルをまとめて動かす（multi_channel_panel.js:405-432 と同じ考え方）。
    /// link[i] は i と i+1 をつなぐので、選んだ所から両側へ伸ばす。
    private func linkedGroup(_ channel: Int) -> [Int] {
        guard let link = param("link") else { return [channel] }
        var low = channel
        var high = channel
        while low > 0, isOn(link.offset + low - 1) { low -= 1 }
        while high < link.count, isOn(link.offset + high) { high += 1 }
        return Array(low...min(high, channelCount - 1))
    }

    private func apply(_ base: Int, _ v: Float, channel: Int) {
        for ch in linkedGroup(channel) {
            dsp.setValue(v, at: index, offset: base + ch)
        }
    }

    /// つないだ瞬間に隣へ値を写す（multi_channel_panel.js:568-585）。
    private func setLink(_ link: ETParam, on: Bool) {
        let ch = channel
        dsp.setValue(on ? 1 : 0, at: index, offset: link.offset + ch)
        guard on, ch + 1 < 16 else { return }
        for name in ["mute", "solo", "volume", "delay"] {
            guard let p = param(name) else { continue }
            dsp.setValue(value(p.offset + ch), at: index, offset: p.offset + ch + 1)
        }
    }

    // MARK: 枠を読む

    private struct Reading {
        var peaks: [Float]
        var muted: [Bool]
        var sequence: UInt32
    }

    /// 枠の通し番号。これが変わったときだけ落とす計算をする。
    private var levelKey: UInt32 { reading?.sequence ?? 0 }

    private var reading: Reading? {
        guard let frame = telemetry.frame(tap: node.tapId, type: .multiChannelLevels),
              frame.matches(version: 1) else { return nil }

        let payload = frame.payloadView
        guard let count8 = payload.u8(at: 0) else { return nil }
        let count = Int(count8)
        // multi_channel_panel.js:689-694 と同じ門。詰め物が 0 でないものは読まない。
        guard count >= 1, count <= 16, payload.count == 4 + count * 8,
              payload.u8(at: 1) == 0, payload.u8(at: 2) == 0, payload.u8(at: 3) == 0
        else { return nil }

        var peaks: [Float] = []
        var muted: [Bool] = []
        peaks.reserveCapacity(count)
        muted.reserveCapacity(count)

        for ch in 0..<count {
            let offset = 4 + ch * 8
            guard let peak = payload.f32(at: offset),
                  let flag = payload.u8(at: offset + 4),
                  peak.isFinite, peak >= 0, flag <= 1,
                  payload.u8(at: offset + 5) == 0,
                  payload.u8(at: offset + 6) == 0,
                  payload.u8(at: offset + 7) == 0
            else { return nil }
            peaks.append(peak)
            muted.append(flag == 1)
        }
        return Reading(peaks: peaks, muted: muted, sequence: frame.sequence)
    }
}
