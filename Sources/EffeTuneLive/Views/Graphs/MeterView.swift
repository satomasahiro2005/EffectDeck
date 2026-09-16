//  MeterView.swift
//  レベルメーター。横棒と、ピークを保持する線。ステレオなら 2 段。
//
//  web 版（plugins/analyzer/level_meter.js）と同じ数字にしてある。
//    目盛りは -96 dB から 0 dB（同 381-382 行 dbStart / dbRange）
//    ピークは 1.0 秒保持して 20 dB/秒 で落ちる（同 15-16 行）
//  保持と落下は web 版と同じく描く側の仕事。DSP が出すのはその瞬間の値だけ
//  （dsp/plugins/analyzer/level_meter/kernel.cpp:168 は線形の peak と rms）。
//
//  値は棒の中に書かない（指や棒で隠れる）。図の外（上）に出す。
//
//  使う側（枠の中身は種類ごとに違うので、読み方は担当が確かめてから渡すこと）:
//      MeterView(channels: ETMeterChannel.stereo(levels: rms, peaks: peak))

import SwiftUI

struct ETMeterChannel: Identifiable, Equatable {
    var id: Int
    /// "L" / "R" / "1" など。左に出す。
    var label: String
    /// 棒の長さ。dB。
    var levelDB: Double
    /// 線の位置。dB。保持は MeterView がする。
    var peakDB: Double
    var clipped: Bool

    init(id: Int, label: String, levelDB: Double, peakDB: Double? = nil, clipped: Bool = false) {
        self.id = id
        self.label = label
        self.levelDB = levelDB
        self.peakDB = peakDB ?? levelDB
        self.clipped = clipped
    }

    /// 線形の振幅から。テレメトリはたいてい線形で来る。
    static func amplitude(id: Int, label: String, level: Float, peak: Float? = nil,
                          clipped: Bool = false) -> ETMeterChannel {
        ETMeterChannel(id: id, label: label,
                       levelDB: ETdB.fromAmplitude(level),
                       peakDB: ETdB.fromAmplitude(peak ?? level),
                       clipped: clipped)
    }

    /// L/R の 2 段を線形の振幅から一度に。
    static func stereo(levels: [Float], peaks: [Float]? = nil,
                       clipped: [Bool] = []) -> [ETMeterChannel] {
        let names = ["L", "R", "3", "4", "5", "6", "7", "8"]
        return levels.indices.map { i -> ETMeterChannel in
            var peak: Float?
            if let peaks, peaks.indices.contains(i) { peak = peaks[i] }
            return amplitude(id: i,
                             label: i < names.count ? names[i] : "\(i + 1)",
                             level: levels[i],
                             peak: peak,
                             clipped: clipped.indices.contains(i) ? clipped[i] : false)
        }
    }
}

struct MeterView: View {

    var channels: [ETMeterChannel]
    var range: ClosedRange<Double>
    var ticks: [Double]
    /// 枠が持ってくるピークを、さらにこちらで保持する。
    var holdsPeak: Bool
    var holdTime: Double
    /// dB/秒。
    var fallRate: Double
    var rowHeight: CGFloat
    var caption: String?
    /// 上に値を出すか。メーターを小さく並べたいときは切る。
    var showsReadout: Bool
    /// 読み値の行の右端に出す札。
    var badge: String?

    /// 保持しているピーク。段ごと。
    @State private var held: [Int: Hold] = [:]

    private struct Hold {
        var db: Double
        var until: Date
        var updated: Date
    }

    init(channels: [ETMeterChannel],
         range: ClosedRange<Double> = -96...0,
         ticks: [Double] = [-96, -72, -48, -36, -24, -12, -6, 0],
         holdsPeak: Bool = true,
         holdTime: Double = 1.0,
         fallRate: Double = 20,
         rowHeight: CGFloat = 16,
         caption: String? = nil,
         showsReadout: Bool = true,
         badge: String? = nil) {
        self.channels = channels
        self.range = range
        self.ticks = ticks
        self.holdsPeak = holdsPeak
        self.holdTime = holdTime
        self.fallRate = fallRate
        self.rowHeight = rowHeight
        self.caption = caption
        self.showsReadout = showsReadout
        self.badge = badge
    }

    private var height: CGFloat {
        // 段の高さ＋隙間＋下の目盛り。
        CGFloat(max(channels.count, 1)) * (rowHeight + 6) + 18
    }

    var body: some View {
        GraphCanvas(
            x: ETAxis.decibels(range, step: 0).with(ticks: tickMarks),
            y: .blank(),
            height: height,
            insets: ETGraphInsets(leading: 16, trailing: 8, top: 4, bottom: 14),
            readout: showsReadout ? readout : [],
            caption: caption,
            badge: badge,
            clipsContent: false,
            draw: { context, plot in
                let rows = channels.count
                guard rows > 0 else { return }
                let gap: CGFloat = 6
                let total = CGFloat(rows) * rowHeight + CGFloat(max(rows - 1, 0)) * gap
                var top = plot.rect.midY - total / 2

                for channel in channels {
                    let row = CGRect(x: plot.rect.minX, y: top,
                                     width: plot.rect.width, height: rowHeight)
                    top += rowHeight + gap

                    // 溝。
                    let track = Path(roundedRect: row, cornerRadius: 2)
                    context.fill(track, with: ETGraphShading.grid)

                    // 棒。
                    let level = ETdB.finite(channel.levelDB, floor: range.lowerBound)
                    let width = plot.x(min(level, range.upperBound)) - row.minX
                    if width > 0.5 {
                        let bar = CGRect(x: row.minX, y: row.minY,
                                         width: min(width, row.width), height: row.height)
                        context.fill(Path(roundedRect: bar, cornerRadius: 2),
                                     with: ETGraphShading.curve)
                    }

                    // ピークの線。
                    let peak = ETdB.finite(peakValue(channel), floor: range.lowerBound)
                    if peak > range.lowerBound + 0.01 {
                        let px = min(max(plot.x(peak), row.minX), row.maxX)
                        var line = Path()
                        line.move(to: CGPoint(x: px, y: row.minY))
                        line.addLine(to: CGPoint(x: px, y: row.maxY))
                        context.stroke(line, with: ETGraphShading.axis, lineWidth: 2)
                    }

                    // 振り切れた印。
                    if channel.clipped {
                        let mark = CGRect(x: row.maxX - 4, y: row.minY, width: 4, height: row.height)
                        context.fill(Path(mark), with: ETGraphShading.curve)
                    }

                    // 段の名前。枠の左の余白に置く。
                    context.draw(Text(channel.label)
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.secondary),
                                 at: CGPoint(x: row.minX - 4, y: row.midY), anchor: .trailing)
                }
            })
        .onChange(of: channels) { _, new in
            updateHolds(new)
        }
        .onAppear { updateHolds(channels) }
    }

    // MARK: ピークの保持

    private func peakValue(_ channel: ETMeterChannel) -> Double {
        guard holdsPeak else { return channel.peakDB }
        return max(held[channel.id]?.db ?? channel.peakDB, channel.peakDB)
    }

    /// 新しい枠が来たときだけ動かす。描くたびには計算しない。
    private func updateHolds(_ incoming: [ETMeterChannel]) {
        guard holdsPeak else { return }
        let now = Date()
        var next = held
        for channel in incoming {
            let peak = ETdB.finite(channel.peakDB, floor: range.lowerBound)
            if var hold = next[channel.id] {
                if now > hold.until {
                    // 保持が切れたぶんだけ落とす。止まっていた間の落としすぎは 0.5 秒で止める。
                    let elapsed = min(now.timeIntervalSince(hold.updated), 0.5)
                    hold.db = max(range.lowerBound, hold.db - fallRate * elapsed)
                }
                if peak >= hold.db {
                    hold.db = peak
                    hold.until = now.addingTimeInterval(holdTime)
                }
                hold.updated = now
                next[channel.id] = hold
            } else {
                next[channel.id] = Hold(db: peak,
                                        until: now.addingTimeInterval(holdTime),
                                        updated: now)
            }
        }
        // もう無い段は捨てる。
        let ids = Set(incoming.map(\.id))
        let stale = Array(next.keys).filter { !ids.contains($0) }
        for key in stale { next.removeValue(forKey: key) }
        held = next
    }

    // MARK: 目盛りと値

    private var tickMarks: [ETAxisTick] {
        ticks.filter { $0 >= range.lowerBound && $0 <= range.upperBound }
             .map { ETAxisTick($0, "\(Int($0.rounded()))") }
    }

    /// 段ごとの値。図の外（上）に出す。
    private var readout: [ETReadoutItem] {
        channels.map { channel in
            ETReadoutItem(channel.label, ETFormat.db(peakValue(channel), decimals: 1))
        }
    }
}

extension ETAxis {
    /// 目盛りだけ差し替えた軸を返す。
    func with(ticks: [ETAxisTick]) -> ETAxis {
        var copy = self
        copy.ticks = ticks
        return copy
    }
}
