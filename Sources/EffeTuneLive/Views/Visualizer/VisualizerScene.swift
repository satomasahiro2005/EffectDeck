//  VisualizerScene.swift
//  Visualizer の場面。背景 1 つと、縦向き（portrait）・横向き（landscape）それぞれの要素の並び。
//  アプリの中の画面も Floating Meters も同じ型で、Floating Meters は縦横比（aspect）を足しただけ。
//  Foundation だけ（Tests/Unit/VisualizerSceneTests.swift）。
//
//  **どちらの並びを描くかは、舞台自身の形で決める**（`stageWidth >= stageHeight` なら landscape）。
//  端末の向き・iPad の分割・Stage Manager の窓・PiP の縦横比のどれでも同じ規則になる。
//  矩形は舞台に対する 0〜1 の割合で、並びの順がそのまま重なりの順（先頭が一番奥）。
//
//  **読むときは決して投げない。**知らない値は項目ごとに既定へ戻し、知らない種類の要素は捨てる。
//  normalized() が上限（要素 24・JSFX 2・NCS 2）と矩形・不透明度の範囲を直す。

import Foundation

/// RGB 8bit。保存は "#RRGGBB"。
struct ETVisualizerColor: Hashable, Codable {
    var rgb: UInt32

    init(_ rgb: UInt32) { self.rgb = rgb & 0xFFFFFF }

    /// "#RRGGBB" か "RRGGBB"。大小どちらも。ほかは nil。
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, text.allSatisfy(\.isHexDigit), let value = UInt32(text, radix: 16) else { return nil }
        self.rgb = value
    }

    var hex: String { String(format: "#%06X", rgb) }

    /// 0...1。
    var components: (r: Double, g: Double, b: Double) {
        (Double((rgb >> 16) & 0xFF) / 255, Double((rgb >> 8) & 0xFF) / 255, Double(rgb & 0xFF) / 255)
    }

    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let value = ETVisualizerColor(hex: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "color"))
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

/// 0...1 の割合（新しい場面）。旧 place() は 1280 基準の値を同じ型で返す（移行でだけ使う）。
struct ETVisualizerRect: Equatable, Hashable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double
}

enum ETVisualizerLayoutKey: String, CaseIterable, Identifiable {
    case portrait, landscape

    var id: String { rawValue }
    var label: String { self == .portrait ? "Portrait" : "Landscape" }

    /// 舞台の形で決める。正方形は landscape。
    static func of(width: Double, height: Double) -> ETVisualizerLayoutKey {
        width >= height ? .landscape : .portrait
    }
}

enum ETVisualizerElementKind: String, CaseIterable, Identifiable {
    case spectrum, spectrogram, waveform, oscilloscope, stereo
    case levelMeter = "level-meter"
    case analogMeter = "analog-meter"
    case artwork, title, artist, ncs, jsfx

    var id: String { rawValue }

    var label: String {
        switch self {
        case .spectrum: return "Spectrum"
        case .spectrogram: return "Spectrogram"
        case .waveform: return "Waveform"
        case .oscilloscope: return "Oscilloscope"
        case .stereo: return "Stereo"
        case .levelMeter: return "Level Meter"
        case .analogMeter: return "Analog Meter"
        case .artwork: return "Artwork"
        case .title: return "Title"
        case .artist: return "Artist"
        case .ncs: return "NCS"
        case .jsfx: return "JSFX"
        }
    }

    /// 曲の聞き取りに頼るもの（ETFeatures.visualizer の版でだけ出る）。
    var isSong: Bool { self == .artwork || self == .title || self == .artist }
    /// 解析を描く 7 種。
    var isMeter: Bool { !(isSong || self == .jsfx || self == .ncs) }
    var isText: Bool { self == .title || self == .artist }
}

enum ETVisualizerFont: String, CaseIterable, Identifiable {
    case system, serif, monospaced

    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .serif: return "Serif"
        case .monospaced: return "Monospaced"
        }
    }
}

enum ETVisualizerAlignment: String, CaseIterable, Identifiable {
    case leading, center, trailing

    var id: String { rawValue }
    var label: String {
        switch self {
        case .leading: return "Left"
        case .center: return "Center"
        case .trailing: return "Right"
        }
    }
}

enum ETVisualizerBlend: String, CaseIterable, Identifiable {
    case normal, screen, add

    var id: String { rawValue }
    var label: String {
        switch self {
        case .normal: return "Normal"
        case .screen: return "Screen"
        case .add: return "Add"
        }
    }
}

struct ETVisualizerJSFXElement: Hashable {
    /// ETJSFXHost.Entry.id。引くのは ETJSFXHost.entry(id:)（付け替え込み）。
    var entryID: String
    /// 見つからないときに出す名前。
    var name: String
    /// つまみの値（実値）。
    var sliders: [UInt32: Double] = [:]
    var blend: ETVisualizerBlend = .normal
}

struct ETVisualizerElement: Identifiable, Hashable {
    var id: UUID
    var kind: ETVisualizerElementKind
    var rect: ETVisualizerRect
    /// 編集画面の表示は「Look」。
    var look: ETVisualizerStyle = .effetune
    var color: ETVisualizerColor
    var card = false
    var glow = false
    /// 0.1...1。
    var opacity = 1.0
    var flipX = false
    var flipY = false
    /// Spectrum だけ。
    var spectrumDisplay: ETSpectrumDisplay = .line
    /// Analog Meter だけ。
    var analogMode: ETAnalogMeterChoice = .vu
    /// Title と Artist だけ。
    var font: ETVisualizerFont = .system
    var bold = false
    var alignment: ETVisualizerAlignment = .leading
    /// NCS だけ。0.25...2（ncs_gl.py の gain）。
    var ncsGain = 1.0
    /// kind が .jsfx のときだけ持つ。
    var jsfx: ETVisualizerJSFXElement?

    /// 見た目ごとの既定の色。メーターは trace、Analog Meter は text、字は白。
    static func defaultColor(kind: ETVisualizerElementKind, look: ETVisualizerStyle) -> ETVisualizerColor {
        switch kind {
        case .ncs: return ETNCSConstants.defaultColor
        case .analogMeter: return ETVisualizerColor(look == .classic ? 0xACC0DE : 0xF6F8FB)
        case .title, .artist, .artwork, .jsfx: return ETVisualizerColor(0xFFFFFF)
        default: return ETVisualizerColor(look == .classic ? 0xACC0DE : 0x40DFFF)
        }
    }
}

enum ETVisualizerBackgroundKind: String, CaseIterable, Identifiable {
    case solid, gradient, artwork

    var id: String { rawValue }
    var label: String {
        switch self {
        case .solid: return "Solid"
        case .gradient: return "Gradient"
        case .artwork: return "Artwork"
        }
    }
}

struct ETVisualizerBackground: Hashable {
    var kind: ETVisualizerBackgroundKind = .solid
    /// 単色・グラデーションの上・アートワークが無いときの色。
    var color = ETVisualizerColor(0x000000)
    /// グラデーションの下。
    var color2 = ETVisualizerColor(0x000000)
    /// アートワークの上に重ねる黒。0...0.9。
    var dim = 0.5
    var cardColor = ETVisualizerColor(0x0E141E)
    var cardBorder = ETVisualizerColor(0x222C3B)
    /// 0.1...1。
    var cardOpacity = 0.92
}

struct ETVisualizerScene: Hashable {
    var name: String
    var background: ETVisualizerBackground
    var portrait: [ETVisualizerElement]
    var landscape: [ETVisualizerElement]

    /// 並び 1 つあたり。
    static let maxElements = 24
    static let maxJSFX = 2
    static let maxNCS = 2
    static let minSize = 0.02

    subscript(layout: ETVisualizerLayoutKey) -> [ETVisualizerElement] {
        get { layout == .portrait ? portrait : landscape }
        set { if layout == .portrait { portrait = newValue } else { landscape = newValue } }
    }

    /// 版が曲を使えないとき（Release）は曲の要素を除いた並び。描くのも編集で選べるのもこれ。
    func elements(_ layout: ETVisualizerLayoutKey, allowsSong: Bool) -> [ETVisualizerElement] {
        allowsSong ? self[layout] : self[layout].filter { !$0.kind.isSong }
    }

    /// 解析に頼むもの（旧 config.needs と同じ対応を要素ごとに）。
    func needs(_ layout: ETVisualizerLayoutKey, allowsSong: Bool) -> ETVisualizerNeedsSet {
        var needs: ETVisualizerNeedsSet = []
        for element in elements(layout, allowsSong: allowsSong) {
            let classic = element.look == .classic
            switch element.kind {
            case .spectrogram: needs.insert(classic ? .classicSpectrogram : .effetuneSpectrogram)
            case .spectrum: needs.insert(classic ? .classicSpectrum : .effetuneSpectrum)
            case .levelMeter: if classic { needs.insert(.loudness) }
            case .analogMeter: needs.insert(element.analogMode == .loudness ? .loudness : .vu)
            case .stereo: if !classic { needs.insert(.stereoEnvelope) }
            case .ncs: needs.insert(.ncs)
            // 取得中はどの瞬間にも始まるので、アートワークも NCS の帯を頼む（Release では elements が落とす）
            case .artwork: needs.insert(.ncs)
            case .waveform, .oscilloscope, .title, .artist, .jsfx: break
            }
        }
        return needs
    }

    /// 曲の聞き取りが要るか（曲の要素か、背景がアートワーク）。
    func usesSong(_ layout: ETVisualizerLayoutKey) -> Bool {
        background.kind == .artwork || self[layout].contains { $0.kind.isSong }
    }

    /// 同じ見た目か（名前と要素の id は見ない）。プリセットの「いま選んでいる印」に使う。
    func sameLook(as other: ETVisualizerScene) -> Bool {
        func blind(_ elements: [ETVisualizerElement]) -> [ETVisualizerElement] {
            elements.map { element in
                var copy = element
                copy.id = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
                return copy
            }
        }
        return background == other.background && blind(portrait) == blind(other.portrait)
            && blind(landscape) == blind(other.landscape)
    }

    /// 要素の id を全部振り直した写し（プリセットを当てるとき・複製）。
    func withFreshIDs() -> ETVisualizerScene {
        var copy = self
        copy.portrait = portrait.map { var e = $0; e.id = UUID(); return e }
        copy.landscape = landscape.map { var e = $0; e.id = UUID(); return e }
        return copy
    }

    // MARK: 直す

    static let defaultRect = ETVisualizerRect(x: 0.25, y: 0.25, w: 0.5, h: 0.5)

    /// 範囲と上限を直した写し。矩形は必ず舞台の中、id は重ならない。
    func normalized() -> ETVisualizerScene {
        var scene = self
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        scene.name = trimmed.isEmpty ? "Untitled" : trimmed

        var bg = background
        bg.dim = bg.dim.isFinite ? min(max(bg.dim, 0), 0.9) : 0.5
        bg.cardOpacity = bg.cardOpacity.isFinite ? min(max(bg.cardOpacity, 0.1), 1) : 0.92
        scene.background = bg

        var seen = Set<UUID>()
        func fix(_ elements: [ETVisualizerElement]) -> [ETVisualizerElement] {
            var result: [ETVisualizerElement] = []
            for source in elements {
                var e = source
                if e.kind == .jsfx {
                    guard let payload = e.jsfx, !payload.entryID.isEmpty else { continue }
                    var cleaned = payload
                    cleaned.sliders = payload.sliders.filter { $0.value.isFinite }
                    e.jsfx = cleaned
                } else {
                    e.jsfx = nil
                }
                e.rect = Self.clamp(e.rect)
                e.opacity = e.opacity.isFinite ? min(max(e.opacity, 0.1), 1) : 1
                e.ncsGain = e.ncsGain.isFinite ? min(max(e.ncsGain, 0.25), 2) : 1
                if !seen.insert(e.id).inserted {
                    e.id = UUID()
                    seen.insert(e.id)
                }
                result.append(e)
            }
            // 上限。先頭から 24 個、その中の最初の 2 つまでの JSFX と NCS。
            var jsfx = 0
            var ncs = 0
            return result.prefix(Self.maxElements).filter { element in
                guard element.kind == .jsfx else { return true }
                jsfx += 1
                return jsfx <= Self.maxJSFX
            }.filter { element in
                guard element.kind == .ncs else { return true }
                ncs += 1
                return ncs <= Self.maxNCS
            }
        }
        scene.portrait = fix(portrait)
        scene.landscape = fix(landscape)
        return scene
    }

    /// 矩形を舞台の中へ。有限でなければ既定の矩形。幅・高さは 0.02〜1。
    static func clamp(_ r: ETVisualizerRect) -> ETVisualizerRect {
        guard r.x.isFinite, r.y.isFinite, r.w.isFinite, r.h.isFinite else { return defaultRect }
        let w = min(max(r.w, minSize), 1), h = min(max(r.h, minSize), 1)
        // 右端・下端はちょうど 1 になる値（0.58 + 0.42 など）が丸めで 1 ulp はみ出すので、1e-12 まで許す。
        func place(_ origin: Double, _ size: Double) -> Double {
            let limit = 1 - size
            return origin <= limit + 1e-12 ? max(origin, 0) : limit
        }
        return ETVisualizerRect(x: place(r.x, w), y: place(r.y, h), w: w, h: h)
    }
}

/// Floating Meters。場面に PiP の窓の縦横比を足したもの。
struct ETFloatingMetersScene: Hashable {
    /// Fit は持てない（normalized で Strip）。
    var aspect: ETVisualizerAspect
    var scene: ETVisualizerScene

    var layout: ETVisualizerLayoutKey { (aspect.ratio ?? 5) >= 1 ? .landscape : .portrait }

    func normalized() -> ETFloatingMetersScene {
        ETFloatingMetersScene(aspect: aspect == .fit ? .strip : aspect, scene: scene.normalized())
    }
}

enum ETVisualizerUnit {
    /// 線・目盛り・字の倍率（アプリの中）。短い辺が 720 のとき 1。
    static func inApp(pixelWidth: Double, pixelHeight: Double) -> Double { min(pixelWidth, pixelHeight) / 720 }
    /// Floating Meters。長い辺が 1280 のとき 1（PiP の器は常にそう）。
    static func floating(pixelWidth: Double, pixelHeight: Double) -> Double { max(pixelWidth, pixelHeight) / 1280 }
}

// MARK: - 保存

/// 保存の形。値はどれも省けるようにして、知らない値は項目ごとに既定へ戻す。
private struct WireJSFX: Codable {
    var entry: String?
    var name: String?
    var sliders: [String: Double]?
    var blend: String?
}

private struct WireElement: Codable {
    var id: String?
    var kind: String?
    var rect: [Double]?
    var look: String?
    var color: String?
    var card: Bool?
    var glow: Bool?
    var opacity: Double?
    var flipX: Bool?
    var flipY: Bool?
    var display: String?
    var meter: String?
    var font: String?
    var bold: Bool?
    var align: String?
    var gain: Double?
    var jsfx: WireJSFX?
}

private struct WireBackground: Codable {
    var kind: String?
    var color: String?
    var color2: String?
    var dim: Double?
    var card: String?
    var cardBorder: String?
    var cardOpacity: Double?
}

private struct WireScene: Codable {
    var v: Int?
    var name: String?
    var background: WireBackground?
    var portrait: [WireElement]?
    var landscape: [WireElement]?
}

private struct WireFloating: Codable {
    var v: Int?
    var aspect: String?
    var scene: WireScene?
}

private struct WireScenes: Codable {
    var v: Int?
    var scenes: [WireScene]?
}

private func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}

extension ETVisualizerBackground {
    fileprivate init(_ wire: WireBackground?) {
        self.init()
        guard let wire else { return }
        kind = wire.kind.flatMap(ETVisualizerBackgroundKind.init(rawValue:)) ?? kind
        color = wire.color.flatMap(ETVisualizerColor.init(hex:)) ?? color
        color2 = wire.color2.flatMap(ETVisualizerColor.init(hex:)) ?? color2
        if let dim = wire.dim, dim.isFinite { self.dim = dim }
        cardColor = wire.card.flatMap(ETVisualizerColor.init(hex:)) ?? cardColor
        cardBorder = wire.cardBorder.flatMap(ETVisualizerColor.init(hex:)) ?? cardBorder
        if let opacity = wire.cardOpacity, opacity.isFinite { cardOpacity = opacity }
    }

    fileprivate var wire: WireBackground {
        WireBackground(kind: kind.rawValue, color: color.hex, color2: color2.hex, dim: dim,
                       card: cardColor.hex, cardBorder: cardBorder.hex, cardOpacity: cardOpacity)
    }
}

extension ETVisualizerElement {
    /// 種類が読めない要素は nil（捨てる）。
    fileprivate init?(_ wire: WireElement) {
        guard let kind = wire.kind.flatMap(ETVisualizerElementKind.init(rawValue:)) else { return nil }
        let look = wire.look.flatMap(ETVisualizerStyle.init(rawValue:)) ?? .effetune
        var rect = ETVisualizerScene.defaultRect
        if let values = wire.rect, values.count == 4 {
            rect = ETVisualizerRect(x: values[0], y: values[1], w: values[2], h: values[3])
        }
        var payload: ETVisualizerJSFXElement?
        if let jsfx = wire.jsfx {
            var sliders: [UInt32: Double] = [:]
            for (key, value) in jsfx.sliders ?? [:] {
                if let index = UInt32(key), value.isFinite { sliders[index] = value }
            }
            payload = ETVisualizerJSFXElement(
                entryID: jsfx.entry ?? "", name: jsfx.name ?? "", sliders: sliders,
                blend: jsfx.blend.flatMap(ETVisualizerBlend.init(rawValue:)) ?? .normal)
        }
        self.init(
            id: wire.id.flatMap(UUID.init(uuidString:)) ?? UUID(), kind: kind, rect: rect, look: look,
            color: wire.color.flatMap(ETVisualizerColor.init(hex:))
                ?? ETVisualizerElement.defaultColor(kind: kind, look: look),
            card: wire.card ?? false, glow: wire.glow ?? false,
            opacity: wire.opacity ?? 1, flipX: wire.flipX ?? false, flipY: wire.flipY ?? false,
            spectrumDisplay: wire.display.flatMap(ETSpectrumDisplay.init(rawValue:)) ?? .line,
            analogMode: wire.meter.flatMap(ETAnalogMeterChoice.init(rawValue:)) ?? .vu,
            font: wire.font.flatMap(ETVisualizerFont.init(rawValue:)) ?? .system,
            bold: wire.bold ?? false,
            alignment: wire.align.flatMap(ETVisualizerAlignment.init(rawValue:)) ?? .leading,
            ncsGain: wire.gain.flatMap { $0.isFinite ? $0 : nil } ?? 1,
            jsfx: payload)
    }

    fileprivate var wire: WireElement {
        var payload: WireJSFX?
        if let jsfx {
            var sliders: [String: Double] = [:]
            for (index, value) in jsfx.sliders where value.isFinite { sliders[String(index)] = value }
            payload = WireJSFX(entry: jsfx.entryID, name: jsfx.name, sliders: sliders, blend: jsfx.blend.rawValue)
        }
        return WireElement(
            id: id.uuidString, kind: kind.rawValue, rect: [rect.x, rect.y, rect.w, rect.h], look: look.rawValue,
            color: color.hex, card: card, glow: glow, opacity: opacity, flipX: flipX, flipY: flipY,
            display: spectrumDisplay.rawValue, meter: analogMode.rawValue, font: font.rawValue, bold: bold,
            align: alignment.rawValue, gain: ncsGain, jsfx: payload)
    }
}

extension ETVisualizerScene {
    fileprivate init?(_ wire: WireScene) {
        // 2 つの並びがどちらも無い保存は場面ではない（{} など）。
        guard wire.portrait != nil || wire.landscape != nil else { return nil }
        self.init(name: wire.name ?? "Untitled", background: ETVisualizerBackground(wire.background),
                  portrait: (wire.portrait ?? []).compactMap(ETVisualizerElement.init),
                  landscape: (wire.landscape ?? []).compactMap(ETVisualizerElement.init))
    }

    fileprivate var wire: WireScene {
        WireScene(v: 2, name: name, background: background.wire, portrait: portrait.map(\.wire),
                  landscape: landscape.map(\.wire))
    }

    /// 読む。投げない。nil や壊れた中身は nil。範囲は直さない（normalized を呼ぶ）。
    static func decode(_ data: Data?) -> ETVisualizerScene? {
        guard let data, let wire = try? JSONDecoder().decode(WireScene.self, from: data) else { return nil }
        return ETVisualizerScene(wire)
    }

    /// JSON。範囲を直してから書く（NaN は JSON に書けない）。キーは並べ替えて、同じ中身なら同じ文字列。
    func encoded() -> Data {
        (try? makeEncoder().encode(normalized().wire)) ?? Data()
    }

    /// 自分で作った場面の一覧。{"v":2,"scenes":[…]}。読めない場面は飛ばす。
    static func decodeList(_ data: Data?) -> [ETVisualizerScene] {
        guard let data, let wire = try? JSONDecoder().decode(WireScenes.self, from: data) else { return [] }
        return (wire.scenes ?? []).compactMap(ETVisualizerScene.init)
    }

    static func encodeList(_ scenes: [ETVisualizerScene]) -> Data {
        (try? makeEncoder().encode(WireScenes(v: 2, scenes: scenes.map { $0.normalized().wire }))) ?? Data()
    }
}

extension ETFloatingMetersScene {
    static func decode(_ data: Data?) -> ETFloatingMetersScene? {
        guard let data, let wire = try? JSONDecoder().decode(WireFloating.self, from: data),
              let scene = wire.scene.flatMap(ETVisualizerScene.init) else { return nil }
        let aspect = wire.aspect.flatMap(ETVisualizerAspect.init(rawValue:)) ?? .strip
        return ETFloatingMetersScene(aspect: aspect, scene: scene).normalized()
    }

    func encoded() -> Data {
        let value = normalized()
        return (try? makeEncoder().encode(WireFloating(v: 2, aspect: value.aspect.rawValue, scene: value.scene.wire))) ?? Data()
    }
}
