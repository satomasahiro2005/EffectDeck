//  VisualizerPalette.swift
//  スペクトログラムの色。Foundation だけ（Tests/Unit/VisualizerPaletteTests.swift）。
//
//  Classic: Floating Meters の色（MiniMeters の見え方）。黒 → 深い紫 → 紫 → 赤紫 → 赤橙 → 橙 → 淡い黄。
//  EffeTune: 上流の Spectrogram の Heatmap（plugins/analyzer/spectrogram.js:14-23 の
//  SPECTROGRAM_COLOR_STOPS と BRIGHTNESS 0.75、getHeatmapLuts :945-985 の rgb 表）。
//  どちらも不透明な BGRA（little endian で 32bit に読むと ARGB）。

import Foundation

enum ETVisualizerPalette {

    // MARK: Classic

    /// 量（dB）から色。音楽の大半（-70〜-45dB）が紫と赤紫に、強い倍音と低音（-35dB より上）だけが橙に来るように置く。
    static let classicStops: [(t: Float, r: Float, g: Float, b: Float)] = [
        (0.00, 0.02, 0.01, 0.06),
        (0.25, 0.09, 0.03, 0.22),
        (0.45, 0.33, 0.07, 0.50),
        (0.62, 0.78, 0.16, 0.59),
        (0.78, 0.94, 0.27, 0.24),
        (0.90, 1.00, 0.55, 0.16),
        (1.00, 1.00, 0.90, 0.59),
    ]

    /// -84dB が下端、-6dB が上端。範囲の外は端の色。
    static func classicHeat(_ db: Float) -> UInt32 {
        let t = max(0, min(1, (db + 84) / 78))
        var i = 1
        while i < classicStops.count - 1 && classicStops[i].t < t { i += 1 }
        let lo = classicStops[i - 1], hi = classicStops[i]
        let f = (t - lo.t) / max(hi.t - lo.t, 1e-6)
        return packBGRA(lo.r + (hi.r - lo.r) * f, lo.g + (hi.g - lo.g) * f, lo.b + (hi.b - lo.b) * f)
    }

    // MARK: EffeTune

    private static let effetuneStops: [(pos: Double, r: Double, g: Double, b: Double)] = [
        (0.000, 0, 0, 0),
        (0.166, 0, 0, 255),
        (0.333, 0, 255, 255),
        (0.500, 0, 255, 0),
        (0.666, 255, 255, 0),
        (0.833, 255, 0, 0),
        (1.000, 255, 255, 255),
    ]
    private static let effetuneBrightness = 0.75

    /// 256 段。添字 0 が黒、255 が白の 0.75 倍。
    static let effetuneHeat: [UInt32] = (0..<256).map { index in
        let normalized = Double(index) / 255
        var lower = effetuneStops[0]
        var upper = effetuneStops[effetuneStops.count - 1]
        for k in 0..<(effetuneStops.count - 1)
        where normalized >= effetuneStops[k].pos && normalized <= effetuneStops[k + 1].pos {
            lower = effetuneStops[k]
            upper = effetuneStops[k + 1]
            break
        }
        let range = upper.pos - lower.pos
        let position = range == 0 ? 0 : (normalized - lower.pos) / range
        // JavaScript の Math.round（.5 は上へ）。
        func channel(_ a: Double, _ b: Double) -> UInt32 {
            UInt32(((a + (b - a) * position) * effetuneBrightness + 0.5).rounded(.down))
        }
        return 0xFF000000 | channel(lower.r, upper.r) << 16 | channel(lower.g, upper.g) << 8 | channel(lower.b, upper.b)
    }

    /// 強さ 0〜1 から色。
    static func effetuneColor(_ intensity: Float) -> UInt32 {
        effetuneHeat[Int((max(0, min(1, intensity)) * 255).rounded())]
    }
}

/// 器の並び（BGRA、little endian で 32bit に読むと ARGB）に合わせて詰める。成分は 0〜1。
func packBGRA(_ r: Float, _ g: Float, _ b: Float) -> UInt32 {
    func byte(_ v: Float) -> UInt32 { UInt32(max(0, min(255, (v * 255).rounded()))) }
    return 0xFF000000 | byte(r) << 16 | byte(g) << 8 | byte(b)
}
