//  VisualizerConfig.swift
//  旧い設定の形（v1）。いまは旧い Floating Meters の保存を読んで場面へ移すとき（VisualizerMigration）にだけ使う。
//  画面と Floating Meters が使う設定は場面（VisualizerScene）。ここの列挙型
//  （ETVisualizerStyle・ETSpectrumDisplay・ETAnalogMeterChoice・ETVisualizerSource・ETVisualizerNeedsSet・
//  ETVisualizerAspect）は場面と共有している。Foundation だけ（Tests/Unit/VisualizerConfigTests.swift）。
//
//  v1 が決めていたのは 4 つ。縦横比・出すパネルと並び順・見た目（Classic / EffeTune）・
//  Spectrum の線/棒と Analog Meter の VU/Loudness。
//
//  保存は JSON 1 つ。読むときは決して投げず、知らない値は面の既定に戻し、パネルは 8 種を 1 回ずつに直す。

import Foundation

/// 設定の持ち主。アプリの中の画面と、Floating Meters の PiP の窓。
enum ETVisualizerSurface: String, CaseIterable {
    case inApp, floating
}

/// 縦横比。Fit はアプリの中だけで、画面の形に合わせる。
enum ETVisualizerAspect: String, CaseIterable, Identifiable {
    case fit = "fit"
    case strip = "5:1"
    case ultraWide = "21:9"
    case wide = "16:9"
    case standard = "4:3"
    case square = "1:1"
    case tall = "9:16"

    var id: String { rawValue }

    /// 幅 / 高さ。Fit は画面の形次第なので nil。
    var ratio: Double? {
        switch self {
        case .fit: return nil
        case .strip: return 5
        case .ultraWide: return 21.0 / 9.0
        case .wide: return 16.0 / 9.0
        case .standard: return 4.0 / 3.0
        case .square: return 1
        case .tall: return 9.0 / 16.0
        }
    }

    var label: String { self == .fit ? "Fit" : rawValue }

    /// 選べる縦横比。PiP の窓は画面の形に合わせようがないので Fit を出さない。
    static func choices(for surface: ETVisualizerSurface) -> [ETVisualizerAspect] {
        surface == .inApp ? allCases : allCases.filter { $0 != .fit }
    }
}

/// 見た目。Classic は Floating Meters の今の色と目盛り、EffeTune は上流の Visualizer の既定。
enum ETVisualizerStyle: String, CaseIterable, Identifiable {
    case classic, effetune

    var id: String { rawValue }
    var label: String { self == .classic ? "Classic" : "EffeTune" }
}

enum ETVisualizerPanelKind: String, CaseIterable, Identifiable {
    case spectrogram, waveform, oscilloscope, spectrum, stereo
    case levelMeter = "level-meter"
    case analogMeter = "analog-meter"
    case artwork

    var id: String { rawValue }

    var label: String {
        switch self {
        case .spectrogram: return "Spectrogram"
        case .waveform: return "Waveform"
        case .oscilloscope: return "Oscilloscope"
        case .spectrum: return "Spectrum"
        case .stereo: return "Stereo"
        case .levelMeter: return "Level Meter"
        case .analogMeter: return "Analog Meter"
        case .artwork: return "Artwork"
        }
    }
}

struct ETVisualizerPanel: Equatable, Identifiable {
    var kind: ETVisualizerPanelKind
    var isOn: Bool
    var id: String { kind.rawValue }
}

/// Spectrum の描き方（上流の dm）。EffeTune の見た目でだけ効く。
enum ETSpectrumDisplay: String, CaseIterable, Identifiable {
    case line, bar

    var id: String { rawValue }
    var label: String { self == .line ? "Line" : "Bars" }
}

/// Analog Meter の針（上流の md）。
enum ETAnalogMeterChoice: String, CaseIterable, Identifiable {
    case vu = "VU"
    case loudness = "Loudness"

    var id: String { rawValue }
    var label: String { rawValue }
}

/// 測る所。Floating Meters と画面で 1 つを分け合う。
enum ETVisualizerSource: String, CaseIterable, Identifiable {
    case input, output

    var id: String { rawValue }
    var label: String { self == .input ? "Chain Input" : "Chain Output" }
}

/// 解析が持つ状態のうち、パネルによって要るかどうかが分かれるもの（VisualizerAnalysis）。
/// 要らない間は確保も計算もしない。
struct ETVisualizerNeedsSet: OptionSet {
    let rawValue: Int

    static let classicSpectrogram = ETVisualizerNeedsSet(rawValue: 1 << 0)
    static let effetuneSpectrogram = ETVisualizerNeedsSet(rawValue: 1 << 1)
    static let classicSpectrum = ETVisualizerNeedsSet(rawValue: 1 << 2)
    static let effetuneSpectrum = ETVisualizerNeedsSet(rawValue: 1 << 3)
    /// K 特性のラウドネス。Classic の Level Meter か、Loudness の Analog Meter。
    static let loudness = ETVisualizerNeedsSet(rawValue: 1 << 4)
    /// VU の針（Analog Meter の VU）。
    static let vu = ETVisualizerNeedsSet(rawValue: 1 << 5)
    /// ステレオの角度ごとのピーク（EffeTune の Stereo）。
    static let stereoEnvelope = ETVisualizerNeedsSet(rawValue: 1 << 6)
}

struct ETVisualizerConfig: Equatable {
    var aspect: ETVisualizerAspect
    var style: ETVisualizerStyle
    /// 8 種を 1 回ずつ、ユーザーの並び順で。
    var panels: [ETVisualizerPanel]
    var spectrumDisplay: ETSpectrumDisplay = .line
    var analogMode: ETAnalogMeterChoice = .vu

    // MARK: 既定

    static func defaults(for surface: ETVisualizerSurface) -> ETVisualizerConfig {
        switch surface {
        case .floating:
            // 今の帯そのまま（アートワークは Debug と Beta でも既定では出さない）。
            return ETVisualizerConfig(
                aspect: .strip, style: .classic,
                panels: panels(on: [.spectrogram, .waveform, .spectrum, .stereo, .levelMeter]))
        case .inApp:
            return ETVisualizerConfig(
                aspect: .fit, style: .effetune,
                panels: panels(on: [.artwork, .spectrum, .spectrogram, .stereo, .analogMeter, .levelMeter]))
        }
    }

    /// `on` を先頭にその順で入れ、残りは切ったまま `allCases` の順で後ろに足す。
    private static func panels(on: [ETVisualizerPanelKind]) -> [ETVisualizerPanel] {
        on.map { ETVisualizerPanel(kind: $0, isOn: true) }
            + ETVisualizerPanelKind.allCases.filter { !on.contains($0) }.map { ETVisualizerPanel(kind: $0, isOn: false) }
    }

    // MARK: 保存

    /// 保存の形。値はどれも省ける文字か真偽にして、知らない値は読むときに既定へ戻す。
    private struct Wire: Codable {
        var v: Int?
        var aspect: String?
        var style: String?
        var panels: [WirePanel]?
        var spectrum: String?
        var analog: String?
    }

    private struct WirePanel: Codable {
        var kind: String?
        var on: Bool?
    }

    /// 読む。投げない。nil や壊れた中身は面の既定。
    static func decode(_ data: Data?, surface: ETVisualizerSurface) -> ETVisualizerConfig {
        let fallback = defaults(for: surface)
        guard let data, let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return fallback }
        var config = fallback
        config.aspect = wire.aspect.flatMap(ETVisualizerAspect.init(rawValue:)) ?? fallback.aspect
        config.style = wire.style.flatMap(ETVisualizerStyle.init(rawValue:)) ?? fallback.style
        config.spectrumDisplay = wire.spectrum.flatMap(ETSpectrumDisplay.init(rawValue:)) ?? fallback.spectrumDisplay
        config.analogMode = wire.analog.flatMap(ETAnalogMeterChoice.init(rawValue:)) ?? fallback.analogMode
        // 知らない種類と 2 つ目以降の重なりを捨てる。足りない種類は切ったまま後ろに足す。
        var seen = Set<ETVisualizerPanelKind>()
        var panels: [ETVisualizerPanel] = []
        for entry in wire.panels ?? [] {
            guard let kind = entry.kind.flatMap(ETVisualizerPanelKind.init(rawValue:)),
                  seen.insert(kind).inserted else { continue }
            panels.append(ETVisualizerPanel(kind: kind, isOn: entry.on ?? false))
        }
        for kind in ETVisualizerPanelKind.allCases where !seen.contains(kind) {
            panels.append(ETVisualizerPanel(kind: kind, isOn: false))
        }
        // panels を省いた保存は、並びも面の既定のまま。
        if wire.panels != nil { config.panels = panels }
        return config.normalized(for: surface)
    }

    /// JSON。キーは並べ替えて、同じ中身なら同じ文字列になるようにする。
    func encoded() -> Data {
        let wire = Wire(
            v: 1, aspect: aspect.rawValue, style: style.rawValue,
            panels: panels.map { WirePanel(kind: $0.kind.rawValue, on: $0.isOn) },
            spectrum: spectrumDisplay.rawValue, analog: analogMode.rawValue)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(wire)) ?? Data()
    }

    /// PiP は Fit を持てない。パネルは 8 種を 1 回ずつにそろえる。
    func normalized(for surface: ETVisualizerSurface) -> ETVisualizerConfig {
        var config = self
        if surface == .floating && config.aspect == .fit { config.aspect = .strip }
        var seen = Set<ETVisualizerPanelKind>()
        var panels: [ETVisualizerPanel] = []
        for panel in config.panels where seen.insert(panel.kind).inserted { panels.append(panel) }
        for kind in ETVisualizerPanelKind.allCases where !seen.contains(kind) {
            panels.append(ETVisualizerPanel(kind: kind, isOn: false))
        }
        config.panels = panels
        // 1 つも入っていない保存（"panels":[] や全部切り）は、何も出ない画面になるので面の既定に戻す。
        if !panels.contains(where: \.isOn) { config.panels = Self.defaults(for: surface).panels }
        return config
    }

    // MARK: 読み取り

    /// 描くパネル。入っていて、アートワークは曲の聞き取りが使える版（ETFeatures.visualizer）でだけ。
    func visibleKinds(allowsArtwork: Bool) -> [ETVisualizerPanelKind] {
        let kinds = panels.filter { $0.isOn && ($0.kind != .artwork || allowsArtwork) }.map(\.kind)
        // アートワークだけ入れた保存を、聞き取りの無い版で読んだとき。何も出ない画面にしない。
        if kinds.isEmpty, let first = panels.first(where: { $0.kind != .artwork }) { return [first.kind] }
        return kinds
    }

    /// 解析に頼む状態。
    func needs(allowsArtwork: Bool) -> ETVisualizerNeedsSet {
        var needs: ETVisualizerNeedsSet = []
        let classic = style == .classic
        for kind in visibleKinds(allowsArtwork: allowsArtwork) {
            switch kind {
            case .spectrogram: needs.insert(classic ? .classicSpectrogram : .effetuneSpectrogram)
            case .spectrum: needs.insert(classic ? .classicSpectrum : .effetuneSpectrum)
            case .levelMeter: if classic { needs.insert(.loudness) }
            case .analogMeter: needs.insert(analogMode == .loudness ? .loudness : .vu)
            case .stereo: if !classic { needs.insert(.stereoEnvelope) }
            case .waveform, .oscilloscope, .artwork: break
            }
        }
        return needs
    }
}
