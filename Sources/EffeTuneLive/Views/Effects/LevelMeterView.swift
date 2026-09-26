//  LevelMeterView.swift
//  Level Meter。横棒・ピーク保持の線・クリップの印。
//  このアプリでは「音が来ているか」を見るのに使うので、鎖の先頭に置かれる前提で作る。
//
//  テレメトリ: ETFrameType.level = 1、formatVersion 1
//  （kernel.cpp:14-15 の kTapLevel / kTelemetryVersion、
//    level_meter.js:1-2 の LEVEL_METER_TAP_LEVEL / _TELEMETRY_VERSION）
//
//  ペイロードの並び。dsp/plugins/analyzer/level_meter/kernel.cpp:117-138 が書き、
//  plugins/analyzer/level_meter.js:188-224 が同じ位置を読んでいる:
//      0            u32 channelCount   kernel.cpp:118 / level_meter.js:200
//      4 + ch*8     f32 peak           kernel.cpp:132 / level_meter.js:212  線形の振幅
//      8 + ch*8     f32 rms            kernel.cpp:133 / level_meter.js:213  線形の振幅
//      4 + n*8      u32 clipFlags      kernel.cpp:135 / level_meter.js:205
//                                      ch 番目の bit は |x| > 1 があった印（kernel.cpp:88-90）
//  長さは 8 + n*8 ちょうど（kernel.cpp:137 / level_meter.js:202）。
//  チャンネル数の上限は 16（kernel.cpp:16 / level_meter.js:3）。
//
//  rms も入っているが、web 版は棒にもピークにも peak しか使っていない
//  （level_meter.js:272 の channels[ch].peak）ので、こちらも peak だけで描く。
//
//  落ち方と保持は描く側の仕事。DSP が出すのはその瞬間の値だけなので、
//  web 版と同じ数字を使う（level_meter.js:14-16）:
//      ピーク保持 1.0 秒、落下 20 dB/秒、クリップの表示は 5 秒
//  目盛りは -96 dB から 0 dB（level_meter.js:381-382 の dbStart / dbRange）。

import SwiftUI

struct LevelMeterView: View {

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    @ETTelemetryFeed private var telemetry

    /// カードの頭のボタンで立つ。畳むのは "LEVEL" の見出しだけ。
    ///
    /// **dB の数字と目盛りは畳まない。** メーターは値を読むための道具で、
    /// 棒の長さだけ残しても何 dB か分からず用をなさない。
    /// 消してよいのは「これはレベルメーターです」と言っている字のほうで、
    /// 棒と目盛りを見れば分かることを二度書いている。
    @Environment(\.etGraphOnly) private var graphOnly

    /// 棒の値。dB。枠が来るたびに落としながら追いかける（level_meter.js:277-279）。
    @State private var bars: [Int: Double] = [:]
    @State private var lastFall = Date()
    /// クリップを見せ続ける終わりの時刻。
    @State private var overloadUntil: Date?

    /// 目盛りの下端と落ちる速さ。左の一覧の棒（ChainMinimap）も同じ数を使う。
    static let floorDB: Double = -96
    static let fallRate: Double = 20
    private static let holdTime: Double = 1.0
    private static let overloadTime: Double = 5.0
    private static let ticks: [Double] = [-96, -72, -48, -24, -12, 0]

    var body: some View {
        // **見出しの行は持たない。**
        // 数字は棒の横に水平に並んでいるので、印もその並びの右端へ入れる。
        // 別の行に置くと、出た瞬間に行が増えてカードの中身ごと下へずれる。
        meter
        .onChange(of: sequence) { _, _ in advance() }
        .onAppear { lastFall = Date() }
    }

    /// 読み値の行の右端に出す印。畳んでいても出す。
    private var overloadBadge: String? { isOverloaded ? "OVERLOAD" : nil }

    private var isOverloaded: Bool {
        guard let until = overloadUntil else { return false }
        return Date() < until
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
                      rowHeight: rowHeight(count: r.peaks.count),
                      showsReadout: true,
                      badge: overloadBadge)
        } else {
            // 枠が来ていない。値が無いことと -inf は違うので、棒は描かない。
            MeterView(channels: [],
                      range: Self.floorDB...0,
                      ticks: Self.ticks,
                      caption: "Waiting for audio")
        }
    }

    /// 棒の高さ。畳んだら少し細くするが、読める太さは保つ。
    private func rowHeight(count: Int) -> CGFloat {
        if graphOnly { return count > 2 ? 9 : 13 }
        return count > 2 ? 12 : 18
    }

    private func channels(_ r: Reading) -> [ETMeterChannel] {
        let count = r.peaks.count
        return (0..<count).map { ch in
            let db = ETdB.fromAmplitude(r.peaks[ch], floor: Self.floorDB)
            return ETMeterChannel(id: ch,
                                  label: Self.label(ch, of: count),
                                  levelDB: bars[ch] ?? db,
                                  peakDB: db,
                                  clipped: r.clipped[ch])
        }
    }

    static func label(_ channel: Int, of count: Int) -> String {
        count == 2 ? (channel == 0 ? "L" : "R") : "\(channel + 1)"
    }

    // MARK: 落とす

    /// 新しい枠が来たときだけ動かす。描くたびには計算しない。
    private func advance() {
        guard let r = reading else { return }
        let now = Date()
        // 止まっていた間の落としすぎは 0.5 秒で止める。
        let dt = min(max(now.timeIntervalSince(lastFall), 0), 0.5)
        lastFall = now

        var next: [Int: Double] = [:]
        for ch in r.peaks.indices {
            let db = ETdB.fromAmplitude(r.peaks[ch], floor: Self.floorDB)
            let fallen = (bars[ch] ?? Self.floorDB) - Self.fallRate * dt
            next[ch] = max(db, max(fallen, Self.floorDB))
        }
        bars = next

        if let until = overloadUntil, now >= until { overloadUntil = nil }
        // clipFlags か、振幅が 1 を超えたら（level_meter.js:310）。
        if r.clipped.contains(true) || r.peaks.contains(where: { $0 > 1 }) {
            overloadUntil = now.addingTimeInterval(Self.overloadTime)
        }
    }

    // MARK: 枠を読む

    struct Reading {
        var peaks: [Float]
        var rms: [Float]
        var clipped: [Bool]
        var sequence: UInt32
    }

    /// 枠の通し番号。これが変わったときだけ落とす計算をする。
    private var sequence: UInt32 { reading?.sequence ?? 0 }

    private var reading: Reading? {
        Self.read(telemetry.frame(tap: node.tapId, type: .level))
    }

    /// 枠を読む。左の一覧の棒（ChainMinimap）も同じ読み方をする。
    static func read(_ frame: ETFrame?) -> Reading? {
        guard let frame, frame.matches(version: 1) else { return nil }

        let payload = frame.payloadView
        guard let count32 = payload.u32(at: 0) else { return nil }
        let count = Int(count32)
        // level_meter.js:201-203 と同じ門。長さが合わないものは読まない。
        guard count >= 1, count <= 16, payload.count == 8 + count * 8 else { return nil }

        guard let flags = payload.u32(at: 4 + count * 8) else { return nil }
        let mask = (UInt32(1) << UInt32(count)) - 1
        guard flags & ~mask == 0 else { return nil }

        guard let values = payload.floats(at: 4, count: count * 2) else { return nil }

        var peaks: [Float] = []
        var rms: [Float] = []
        var clipped: [Bool] = []
        peaks.reserveCapacity(count)
        rms.reserveCapacity(count)
        clipped.reserveCapacity(count)

        for ch in 0..<count {
            let peak = values[ch * 2]
            let level = values[ch * 2 + 1]
            guard peak.isFinite, peak >= 0, level.isFinite, level >= 0 else { return nil }
            peaks.append(peak)
            rms.append(level)
            clipped.append(flags & (UInt32(1) << UInt32(ch)) != 0)
        }
        return Reading(peaks: peaks, rms: rms, clipped: clipped, sequence: frame.sequence)
    }
}
