//  GraphAccessibility.swift
//  図を VoiceOver の Audio Graphs（「再生」と、データの要約）に渡す部品。
//
//  いまは EQ の応答曲線だけ（FrequencyResponseGraph の淡色でない曲線）。
//  ライブのアナライザは、VoiceOver から求められたときだけ最新の枠を間引いて作る形で、あとで足す。
//  GraphCanvas の `chart:` に ETChartAccess を渡すと、図の面が 1 つの要素になる。
//
//  descriptor を作る関数は VoiceOver が求めるまで呼ばれない（makeChartDescriptor）。
//  図を描くたびには何も計算しない。

import SwiftUI
import Accessibility
import Foundation

/// Audio Graphs に渡す中身。label は図の名前（VoiceOver が最初に読む）。
struct ETChartAccess {
    var label: String
    var descriptor: () -> AXChartDescriptor
}

private struct ETChartRepresentable: AXChartDescriptorRepresentable {
    let build: () -> AXChartDescriptor

    func makeChartDescriptor() -> AXChartDescriptor {
        build()
    }

    /// 曲線が変わったら中身を差し替える（EQ のつまみを動かした直後に「再生」しても今の形になる）。
    func updateChartDescriptor(_ descriptor: AXChartDescriptor) {
        let fresh = build()
        descriptor.summary = fresh.summary
        descriptor.series = fresh.series
    }
}

extension View {
    /// chart があるときだけ、この面を 1 つの要素にして Audio Graphs を付ける。
    /// 中の印や重ねた層は読ませない（印は下のバンドのスライダーが唯一の経路）。
    @ViewBuilder
    func etChartAccess(_ chart: ETChartAccess?) -> some View {
        if let chart {
            self
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(chart.label)
                .accessibilityChartDescriptor(ETChartRepresentable(build: chart.descriptor))
        } else {
            self
        }
    }
}

// MARK: - 周波数応答

enum ETFrequencyChart {

    /// 1 本の線。name は読み上げる名前。
    struct Line {
        var name: String
        var points: [ETFreqPoint]
    }

    /// 曲線から Audio Graphs の中身を作る。淡色の曲線（バンドごとの内訳）は呼ぶ側で除いておく。
    ///
    /// **横軸は log10(Hz) で持つ。**AXNumericDataAxisDescriptor を線形で使い、
    /// 値の読み上げだけ Hz に戻す。周波数をそのまま入れると、音が 20Hz〜2kHz に
    /// 詰まって 2kHz から上だけが広く鳴る。
    static func descriptor(lines: [Line],
                           frequency: ClosedRange<Double>,
                           decibels: ClosedRange<Double>,
                           decibelStep: Double) -> AXChartDescriptor {
        let lowLog = log10(max(frequency.lowerBound, 1e-9))
        let highLog = log10(max(frequency.upperBound, frequency.lowerBound * 1.000001))
        let xGrid = ETAxis.frequency(frequency.lowerBound, frequency.upperBound)
            .ticks.map { log10($0.value) }
        let yGrid = ETAxis.decibels(decibels, step: decibelStep).ticks.map(\.value)

        let xAxis = AXNumericDataAxisDescriptor(
            title: "Frequency",
            range: lowLog...highLog,
            gridlinePositions: xGrid,
            valueDescriptionProvider: { ETFormat.hz(pow(10, $0)) })
        let yAxis = AXNumericDataAxisDescriptor(
            title: "Level",
            range: decibels,
            gridlinePositions: yGrid,
            valueDescriptionProvider: { ETFormat.gain($0) })

        let series = lines.map { line -> AXDataSeriesDescriptor in
            let points = line.points.compactMap { p -> AXDataPoint? in
                guard p.hz >= frequency.lowerBound, p.hz <= frequency.upperBound else { return nil }
                // 範囲の外へ出た dB は端に留める（曲線は枠から出るが、音の高さは範囲の中で鳴らす）。
                let db = min(max(ETdB.finite(p.db, floor: decibels.lowerBound),
                                 decibels.lowerBound), decibels.upperBound)
                return AXDataPoint(x: log10(p.hz), y: db)
            }
            return AXDataSeriesDescriptor(name: line.name, isContinuous: true, dataPoints: points)
        }

        return AXChartDescriptor(
            title: "Frequency response",
            summary: summary(lines: lines, frequency: frequency, decibels: decibels),
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: series)
    }

    /// 範囲と、線ごとの最高・最低の点。
    static func summary(lines: [Line],
                        frequency: ClosedRange<Double>,
                        decibels: ClosedRange<Double>) -> String {
        var parts = ["Frequency \(ETFormat.hz(frequency.lowerBound)) to \(ETFormat.hz(frequency.upperBound)), level \(ETFormat.gain(decibels.lowerBound)) to \(ETFormat.gain(decibels.upperBound))."]
        for line in lines.prefix(3) {
            let inside = line.points.filter {
                $0.db.isFinite && $0.hz >= frequency.lowerBound && $0.hz <= frequency.upperBound
            }
            guard let high = inside.max(by: { $0.db < $1.db }),
                  let low = inside.min(by: { $0.db < $1.db }) else { continue }
            if high.db - low.db < 0.05 {
                parts.append("\(line.name): flat at \(ETFormat.gain(high.db)).")
            } else {
                parts.append("\(line.name): highest \(ETFormat.gain(high.db)) at \(ETFormat.hz(high.hz)), lowest \(ETFormat.gain(low.db)) at \(ETFormat.hz(low.hz)).")
            }
        }
        return parts.joined(separator: " ")
    }

    /// 曲線の id は呼ぶ側が決めた内部の名前なので、読み上げ用に直す。
    static func name(of curve: ETFrequencyCurve, count: Int) -> String {
        if let name = curve.name, !name.isEmpty { return name }
        if count == 1 { return "Response" }
        switch curve.id {
        case "sum":  return "Total"
        case "lp":   return "Low pass"
        case "hp":   return "High pass"
        default:     return curve.id.prefix(1).uppercased() + curve.id.dropFirst()
        }
    }
}
