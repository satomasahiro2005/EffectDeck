//  VisualizerLayout.swift
//  旧い並べ方。パネルを並べた順に左上から行へ詰め、行をどこで切るかを縦横比から自動で決める。
//  いまは旧い Floating Meters の設定（ETVisualizerConfig v1）を新しい場面へ移すとき（VisualizerMigration）にだけ使い、
//  画面は場面（VisualizerScene）の矩形をそのまま使う。PiP の器の大きさ（pipPixelSize）はいまも使う。
//  Foundation だけ（Tests/Unit/VisualizerLayoutTests.swift）。
//
//  **上流と同じ割合の矩形で持つ。**基準の舞台は幅 1280（上流の REFERENCE_WIDTH）、高さは 1280 / 縦横比。
//  返す矩形は 1280 基準の値で、場面へ移すときに舞台の幅・高さで割って 0〜1 にする。
//
//  各パネルには得意な形がある（Stereo とアートワークは正方形、Level Meter は細い棒、
//  Analog Meter は上流と同じ 4:3 の文字盤）。切り方を全部試して、いちばん崩れないものを選ぶ。

import Foundation

struct ETVisualizerPlacement: Equatable {
    var kind: ETVisualizerPanelKind
    var rect: ETVisualizerRect
    /// 行に 1 つだけ残った Level Meter は横向きの棒になる。ほかのパネルでは使わない。
    var horizontal: Bool
}

enum ETVisualizerLayout {

    /// 基準の舞台の幅（上流の REFERENCE_WIDTH）。
    static let referenceWidth = 1280.0

    /// そのパネルの得意な幅 / 高さ。
    static func preferredAspect(_ kind: ETVisualizerPanelKind, analogMode: ETAnalogMeterChoice,
                                aloneInRow: Bool) -> Double {
        switch kind {
        case .spectrogram: return 300.0 / 256.0
        case .waveform: return 400.0 / 256.0
        case .spectrum: return 300.0 / 256.0
        case .stereo: return 216.0 / 256.0
        // 上流の Level Meter は縦に細い棒で、行に 1 つだけのときは 16:1 の横長（プリセットの一番下）。
        case .levelMeter: return aloneInRow ? 16.0 : 0.25
        // 上流の Oscilloscope の描き面。
        case .oscilloscope: return 32.0 / 15.0
        // 4:3 の文字盤 1 つぶん。VU は左右の 2 つ。
        case .analogMeter: return analogMode == .vu ? 8.0 / 3.0 : 4.0 / 3.0
        case .artwork: return 1.0
        }
    }

    /// 大きさの偏りの重み。s だけで選ぶと、1:1 や 9:16 でアートワークが 1 段を独り占めして
    /// 残りが下の細い 1 段に押し込まれる（シミュレータで確かめた）。
    static let imbalanceWeight = 0.3

    /// 行の切り方を全部試して置き場を返す。空なら空。
    /// 選び方: |log s|（全体を縦に引き伸ばす倍率 s が 1 から離れるほど悪い）に、パネルの面積の
    /// 最大と最小の比の対数 × imbalanceWeight を足したものが小さい順、行が少ない順、
    /// 行の自然な高さの差が小さい順。Level Meter は細い棒が持ち味なので面積の比に入れない。
    /// 同じなら先に試したほう（マスクの小さいほう＝行が少ない切り方）。
    static func place(_ kinds: [ETVisualizerPanelKind], analogMode: ETAnalogMeterChoice,
                      ratio: Double) -> [ETVisualizerPlacement] {
        let n = kinds.count
        guard n > 0, ratio > 0 else { return [] }
        let width = referenceWidth
        let height = width / ratio

        var best: (key: (Double, Int, Double), rows: [[Int]])?
        for mask in 0..<(1 << (n - 1)) {
            var rows: [[Int]] = [[0]]
            for i in 1..<n {
                if mask & (1 << (i - 1)) != 0 { rows.append([i]) } else { rows[rows.count - 1].append(i) }
            }
            var naturals: [Double] = []
            naturals.reserveCapacity(rows.count)
            for row in rows {
                let total = row.reduce(0.0) { $0 + preferredAspect(kinds[$1], analogMode: analogMode, aloneInRow: row.count == 1) }
                naturals.append(width / total)
            }
            let s = height / naturals.reduce(0, +)
            var smallest = Double.infinity, largest = 0.0
            for (r, row) in rows.enumerated() {
                let list = row.map { preferredAspect(kinds[$0], analogMode: analogMode, aloneInRow: row.count == 1) }
                let total = list.reduce(0, +)
                for (c, index) in row.enumerated() where kinds[index] != .levelMeter {
                    let area = width * list[c] / total * naturals[r] * s
                    smallest = min(smallest, area)
                    largest = max(largest, area)
                }
            }
            let imbalance = largest > 0 ? log(largest / smallest) : 0
            let cost = abs(log(s)) + Self.imbalanceWeight * imbalance
            let key = ((cost * 1e9).rounded(), rows.count,
                       (naturals.max() ?? 0) - (naturals.min() ?? 0))
            if let current = best?.key {
                let smaller = key.0 != current.0 ? key.0 < current.0
                    : (key.1 != current.1 ? key.1 < current.1 : key.2 < current.2)
                if !smaller { continue }
            }
            best = (key, rows)
        }
        guard let rows = best?.rows else { return [] }

        // 行の高さと列の幅を割合で出し、累積で丸めて隙間なく敷く。
        var naturals: [Double] = []
        var aspects: [[Double]] = []
        for row in rows {
            let list = row.map { preferredAspect(kinds[$0], analogMode: analogMode, aloneInRow: row.count == 1) }
            aspects.append(list)
            naturals.append(width / list.reduce(0, +))
        }
        let s = height / naturals.reduce(0, +)
        var placements: [ETVisualizerPlacement] = []
        var top = 0.0
        for (r, row) in rows.enumerated() {
            let rowHeight = naturals[r] * s
            let y0 = top.rounded()
            let y1 = (top + rowHeight).rounded()
            let total = aspects[r].reduce(0, +)
            var left = 0.0
            for (c, index) in row.enumerated() {
                let w = width * aspects[r][c] / total
                let x0 = left.rounded()
                let x1 = (left + w).rounded()
                placements.append(ETVisualizerPlacement(
                    kind: kinds[index],
                    rect: ETVisualizerRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0),
                    horizontal: kinds[index] == .levelMeter && row.count == 1))
                left += w
            }
            top += rowHeight
        }
        return placements
    }

    /// PiP の器の大きさ（ピクセル）。長いほうの辺を 1280 にして、短いほうは偶数に丸める。
    static func pipPixelSize(_ ratio: Double) -> (Int, Int) {
        func even(_ x: Double) -> Int { Int((x / 2).rounded()) * 2 }
        let long = Int(referenceWidth)
        return ratio >= 1 ? (long, even(referenceWidth / ratio)) : (even(referenceWidth * ratio), long)
    }
}
