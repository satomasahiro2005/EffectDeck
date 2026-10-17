//  VisualizerRenderer.swift
//  Visualizer を描く唯一の描き手。アプリの中の画面も Floating Meters も、これが同じ場面
//  （ETVisualizerScene）から CoreGraphics でピクセルの器へ直に描く。
//  UIKit にも CoreImage にも頼らない（字は CoreText、ぼかしたアートワークは呼び手が作って渡す）。
//  Mac の試し描きで同じ物を動かす。
//
//  **Classic は以前の MiniMeters そのまま**（色・目盛り・字なし）。Floating Meters の帯（長い辺 1280 画素、
//  倍率 1）では 1 ピクセルも変わらない。矩形の辺は画素に丸める（ETVisualizerEditing.pixelEdges）ので、
//  Classic の場面は昔の整数の矩形とぴったり同じになる。
//  **EffeTune は上流の Visualizer の既定に合わせる**（線 #40dfff、Heatmap、Stereo の相関と左右差の棒、
//  Analog Meter の VU の文字盤）。Oscilloscope と Analog Meter は Classic にも出るので、
//  そのときは同じ形を Classic の色で字なしで描く。
//
//  座標: 場面の矩形は舞台に対する 0〜1。線の太さ・目盛り・字の倍率は呼び手が渡す unit
//  （アプリの中は短い辺 / 720、Floating Meters は長い辺 / 1280。ETVisualizerUnit）。字の大きさは矩形の高さから決める。
//  `ctx` は上が 0 の向き（呼び手が反転してある）。器は BGRA（premultipliedFirst・little endian）。
//  毎回の確保はしない（色と路と字は static に置く）。
//
//  要素は並びの順に、背景 → (不透明度・光彩があれば透過層) → カード → 枠で切る → 反転 → 描く。
//  光彩は透過層ごと影を落とす（要素ごとに 1 回。描く 1 本ずつに影を付けない）。

import CoreGraphics
import CoreText
import Foundation

/// 見た目ごとの色。Classic は以前の MiniMeters、EffeTune は上流の暗いテーマ（effetune-theme.css の :root）。
struct ETVisualizerTheme {
    let background: CGColor
    /// 線・棒。
    let trace: CGColor
    /// 針・基準の目盛り・字・ピークの印。
    let text: CGColor
    let gridSubtle: CGColor
    let gridSoft: CGColor
    /// 弧の線・目盛り・字。
    let label: CGColor
    let danger: CGColor
    /// 棒の段を切る色。
    let deep: CGColor
    /// アートワークの下の溝（Classic）。
    let groove: CGColor

    private static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// 172,192,222 / 70,74,82 / 24,26,30 は以前の MiniMeters の meter / grid / groove。
    static let classic = ETVisualizerTheme(
        background: rgb(0x000000),
        trace: CGColor(red: 172 / 255, green: 192 / 255, blue: 222 / 255, alpha: 1),
        text: CGColor(red: 172 / 255, green: 192 / 255, blue: 222 / 255, alpha: 1),
        gridSubtle: CGColor(red: 70 / 255, green: 74 / 255, blue: 82 / 255, alpha: 1),
        gridSoft: CGColor(red: 70 / 255, green: 74 / 255, blue: 82 / 255, alpha: 1),
        label: CGColor(red: 70 / 255, green: 74 / 255, blue: 82 / 255, alpha: 1),
        danger: rgb(0xB91C1C),
        deep: rgb(0x000000),
        groove: CGColor(red: 24 / 255, green: 26 / 255, blue: 30 / 255, alpha: 1))

    static let effetune = ETVisualizerTheme(
        background: rgb(0x080D1C),
        trace: rgb(0x40DFFF),
        text: rgb(0xF6F8FB),
        gridSubtle: rgb(0x323233),
        gridSoft: rgb(0xF6F8FB, alpha: 0x33 / 255),
        label: rgb(0x666666),
        danger: rgb(0xB91C1C),
        deep: rgb(0x000000),
        groove: rgb(0x000000))

    static func of(_ style: ETVisualizerStyle) -> ETVisualizerTheme {
        style == .classic ? classic : effetune
    }

    /// 線・棒の色と、針・字の色だけ替えた写し。
    func with(trace: CGColor, text: CGColor) -> ETVisualizerTheme {
        ETVisualizerTheme(background: background, trace: trace, text: text, gridSubtle: gridSubtle,
                          gridSoft: gridSoft, label: label, danger: danger, deep: deep, groove: groove)
    }
}

/// 場面に添える「いま描く曲」。
struct ETVisualizerSongText: Equatable {
    let title: String
    let artist: String
}

/// 1 枚を描くのに要る、場面の外の材料。
struct ETVisualizerFrame {
    let analysis: ETVisualizerAnalysis
    /// 曲の聞き取りが使えない版（ETFeatures.visualizer が偽）では nil。
    let artwork: CGImage?
    /// ぼかしたアートワーク（ETVisualizerArtworkBlur）。出来るまでは nil で、背景の色で塗る。
    let blurredArtwork: CGImage?
    let song: ETVisualizerSongText?
    /// JSFX の要素 id → いまの絵。
    let jsfxImages: [UUID: CGImage]
    /// NCS の絵（要素 id → いまの絵）。NCS の要素と、取得中のアートワークの要素。
    let ncsImages: [UUID: CGImage]
    /// 曲の取得中の重さ 0...1（1 で粒子だけ）。Metal が無い・曲を使えない版では 0。
    let identifying: Double
    /// ETFeatures.visualizer。偽なら曲の要素とアートワークの背景は描かない。
    let allowsSong: Bool
    /// 編集画面。曲名・歌手・JSFX の名前を 35% の濃さで仮に出す。
    let placeholders: Bool
}

@MainActor
enum ETVisualizerRenderer {

    /// 0 dBFS の高さ（区画の半分に対する割合）。-0.2 dB ぶん（0.5 dB は空きすぎ）。
    private static let waveformHeadroom = CGFloat(pow(10, -0.2 / 20))

    // MARK: - 場面

    /// 矩形の辺を画素に丸める（決まりは ETVisualizerEditing.pixelEdges）。
    static func pixelRect(_ r: ETVisualizerRect, _ size: CGSize) -> CGRect {
        let e = ETVisualizerEditing.pixelEdges(r, width: Double(size.width), height: Double(size.height))
        return CGRect(x: e.0, y: e.1, width: e.2, height: e.3)
    }

    /// 色の入れ物。要素ごと・毎フレームに作らない。64 を超えたら空にする。
    private static var colorCache: [UInt64: CGColor] = [:]

    private static func color(_ rgb: ETVisualizerColor, alpha: CGFloat = 1) -> CGColor {
        let key = UInt64(rgb.rgb) | (UInt64((alpha * 255).rounded()) << 32)
        if let cached = colorCache[key] { return cached }
        let c = rgb.components
        let made = CGColor(red: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: alpha)
        if colorCache.count >= 64 { colorCache.removeAll(keepingCapacity: true) }
        colorCache[key] = made
        return made
    }

    private static func themeFor(_ e: ETVisualizerElement) -> ETVisualizerTheme {
        let base = ETVisualizerTheme.of(e.look)
        let c = color(e.color)
        return e.kind == .analogMeter ? base.with(trace: base.trace, text: c) : base.with(trace: c, text: base.text)
    }

    /// 上下のグラデーション。同じ 2 色の間は作り直さない。
    private static var gradientKey: (UInt32, UInt32)?
    private static var gradientCache: CGGradient?

    private static func gradient(_ top: ETVisualizerColor, _ bottom: ETVisualizerColor) -> CGGradient? {
        if let key = gradientKey, key == (top.rgb, bottom.rgb), let cached = gradientCache { return cached }
        let made = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [color(top), color(bottom)] as CFArray, locations: [0, 1])
        gradientKey = (top.rgb, bottom.rgb)
        gradientCache = made
        return made
    }

    static func draw(scene: ETVisualizerScene, layout: ETVisualizerLayoutKey, frame: ETVisualizerFrame,
                     in ctx: CGContext, pixelSize: CGSize, unit: CGFloat) {
        drawBackground(scene.background, frame, ctx, pixelSize)
        // NCS の要素がある並びでは、取得中のアートワークは薄くなるだけで、2 つ目の球は描かない
        let hasNCS = scene[layout].contains { $0.kind == .ncs }
        for element in scene[layout] where frame.allowsSong || !element.kind.isSong {
            drawElement(element, scene.background, frame, ctx, pixelSize, unit, hasNCS)
        }
    }

    private static func drawBackground(_ background: ETVisualizerBackground, _ frame: ETVisualizerFrame,
                                       _ ctx: CGContext, _ size: CGSize) {
        let full = CGRect(origin: .zero, size: size)
        switch background.kind {
        case .solid:
            ctx.setFillColor(color(background.color))
            ctx.fill(full)
        case .gradient:
            if let gradient = gradient(background.color, background.color2) {
                ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            } else {
                ctx.setFillColor(color(background.color))
                ctx.fill(full)
            }
        case .artwork:
            if frame.allowsSong, let blurred = frame.blurredArtwork {
                // 舞台いっぱいに cover-fit。上に黒を重ねて暗くする。
                let fit = max(size.width / CGFloat(blurred.width), size.height / CGFloat(blurred.height))
                let width = CGFloat(blurred.width) * fit, height = CGFloat(blurred.height) * fit
                ctx.saveGState()
                ctx.interpolationQuality = .medium
                drawUpright(ctx, blurred, in: CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2,
                                                     width: width, height: height))
                ctx.restoreGState()
                ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: CGFloat(background.dim)))
                ctx.fill(full)
            } else {
                ctx.setFillColor(color(background.color))
                ctx.fill(full)
            }
        }
    }

    private static func drawElement(_ e: ETVisualizerElement, _ background: ETVisualizerBackground,
                                    _ frame: ETVisualizerFrame, _ ctx: CGContext, _ size: CGSize, _ unit: CGFloat,
                                    _ hasNCS: Bool) {
        let rect = pixelRect(e.rect, size)
        guard rect.width > 0, rect.height > 0 else { return }
        var blend = CGBlendMode.normal
        if e.kind == .jsfx, let mode = e.jsfx?.blend {
            switch mode {
            case .normal: blend = .normal
            case .screen: blend = .screen
            case .add: blend = .plusLighter
            }
        }
        // 不透明度・光彩・合成は、要素ぜんぶを 1 枚にまとめてから掛ける（透過層）。
        let layered = e.opacity < 1 || e.glow || blend != .normal
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if layered {
            ctx.setAlpha(CGFloat(e.opacity))
            if blend != .normal { ctx.setBlendMode(blend) }
            if e.glow {
                ctx.setShadow(offset: .zero, blur: 12 * unit, color: color(e.color, alpha: 0.85))
            }
            ctx.beginTransparencyLayer(in: rect.insetBy(dx: -16 * unit, dy: -16 * unit), auxiliaryInfo: nil)
            ctx.setBlendMode(.normal)
        }

        var content = rect
        if e.card {
            let radius = 10 * unit
            ctx.setFillColor(color(background.cardColor, alpha: CGFloat(background.cardOpacity)))
            addRoundedRect(ctx, rect, radius)
            ctx.fillPath()
            ctx.setStrokeColor(color(background.cardBorder))
            ctx.setLineWidth(unit)
            addRoundedRect(ctx, rect.insetBy(dx: unit / 2, dy: unit / 2), max(0, radius - unit / 2))
            ctx.strokePath()
            content = rect.insetBy(dx: 8 * unit, dy: 8 * unit)
        }
        if !e.card || (content.width >= 2 && content.height >= 2) {
            // 枠で切る。層の中でだけ切るので、光彩の影は枠の外へ出る。
            ctx.saveGState()
            ctx.clip(to: content)
            if e.flipX || e.flipY {
                ctx.translateBy(x: content.midX, y: content.midY)
                ctx.scaleBy(x: e.flipX ? -1 : 1, y: e.flipY ? -1 : 1)
                ctx.translateBy(x: -content.midX, y: -content.midY)
            }
            drawKind(e, content, frame, ctx, unit, hasNCS)
            ctx.restoreGState()
        }
        if layered { ctx.endTransparencyLayer() }
    }

    /// 角丸の枠の路（確保しない）。
    private static func addRoundedRect(_ ctx: CGContext, _ r: CGRect, _ radius: CGFloat) {
        let k = min(radius, r.width / 2, r.height / 2)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: r.minX + k, y: r.minY))
        ctx.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.maxY), radius: k)
        ctx.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY), radius: k)
        ctx.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.minY), radius: k)
        ctx.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY), radius: k)
        ctx.closePath()
    }

    private static func drawKind(_ e: ETVisualizerElement, _ content: CGRect, _ frame: ETVisualizerFrame,
                                 _ ctx: CGContext, _ unit: CGFloat, _ hasNCS: Bool) {
        let analysis = frame.analysis
        let theme = themeFor(e)
        let classic = e.look == .classic
        switch e.kind {
        case .spectrogram:
            if classic {
                drawClassicSpectrogram(ctx, content, unit, analysis.classicSpectrogram)
            } else if let ring = analysis.effetuneSpectrogram {
                drawRing(ctx, ring, content, newest: ring.columns, quality: .low)
            }
        case .waveform:
            if classic { drawClassicWaveform(ctx, content, unit, analysis) }
            else { drawWaveform(ctx, content, unit, theme, analysis) }
        case .oscilloscope:
            drawOscilloscope(ctx, content, unit, theme, analysis)
        case .spectrum:
            if classic { drawClassicSpectrum(ctx, content, unit, theme, analysis) }
            else { drawSpectrum(ctx, content, unit, theme, analysis, e.spectrumDisplay) }
        case .stereo:
            if classic { drawClassicStereo(ctx, content, unit, theme, analysis) }
            else { drawStereo(ctx, content, unit, theme, analysis, content.width / unit < 400) }
        case .levelMeter:
            // 向きは矩形の形で決める（幅が高さより大きければ横）。
            withLevelOrientation(ctx, content, horizontal: content.width > content.height) { local in
                if classic { drawClassicLevel(ctx, local, unit, theme, analysis) }
                else { drawLevel(ctx, local, unit, theme, analysis) }
            }
        case .analogMeter:
            drawAnalogMeter(ctx, content, unit, theme, analysis, e.analogMode, labels: !classic)
        case .artwork:
            drawArtwork(ctx, content, theme, frame.artwork, classic: classic, ncs: frame.ncsImages[e.id],
                        weight: CGFloat(frame.identifying), hasNCS: hasNCS)
        case .ncs:
            // 中の正方形に、絵をそのまま。絵が無い（Metal が無い・まだ最初の 1 枚が出来ていない）ときは何も描かない
            if let image = frame.ncsImages[e.id] {
                let side = min(content.width, content.height)
                ctx.interpolationQuality = .medium
                drawUpright(ctx, image, in: CGRect(x: content.midX - side / 2, y: content.midY - side / 2,
                                                   width: side, height: side))
            }
        case .title:
            drawSongText(ctx, content, text: frame.song?.title ?? "", placeholder: frame.placeholders ? "Title" : nil, e)
        case .artist:
            drawSongText(ctx, content, text: frame.song?.artist ?? "", placeholder: frame.placeholders ? "Artist" : nil, e)
        case .jsfx:
            if let image = frame.jsfxImages[e.id] {
                ctx.interpolationQuality = .medium
                drawUpright(ctx, image, in: content)
            } else if frame.placeholders, let name = e.jsfx?.name, !name.isEmpty {
                let size = min(content.height / 4, 28 * unit)
                drawLabel(ctx, name, size: size, at: CGPoint(x: content.midX, y: content.midY),
                          anchorX: 0.5, anchorY: 0.5, color: color(e.color, alpha: 0.35))
            }
        }
    }

    // MARK: - 共通

    private static func setFill(_ ctx: CGContext, packed color: UInt32) {
        ctx.setFillColor(red: CGFloat((color >> 16) & 0xFF) / 255, green: CGFloat((color >> 8) & 0xFF) / 255,
                         blue: CGFloat(color & 0xFF) / 255, alpha: 1)
    }

    /// 上が 0 の器に、絵を上下そのままに置く（絵は反転し直して置く）。
    private static func drawUpright(_ ctx: CGContext, _ image: CGImage, in rect: CGRect) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    /// 縦に描く棒（Level Meter）を、横向きの区画に回して描く。`local` は縦に描くときの区画
    /// （横向きなら幅と高さが入れ替わる。上が大きい値で、横向きでは右が大きい値になる）。
    private static func withLevelOrientation(_ ctx: CGContext, _ rect: CGRect, horizontal: Bool,
                                             _ body: (CGRect) -> Void) {
        guard horizontal else {
            body(rect)
            return
        }
        ctx.saveGState()
        ctx.concatenate(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: rect.maxX, ty: rect.minY))
        body(CGRect(x: 0, y: 0, width: rect.height, height: rect.width))
        ctx.restoreGState()
    }

    /// 輪の新しいほうから `newest` 列を、古い順に左から右へ区画いっぱいに置く。輪の継ぎ目で 2 つに分ける。
    private static func drawRing(_ ctx: CGContext, _ ring: ETSpectrogramRing, _ rect: CGRect,
                                 newest: Int, quality: CGInterpolationQuality) {
        guard let image = ring.image(), newest > 0 else { return }
        let n = min(newest, ring.columns)
        let start = ring.head - n
        // (輪の中の最初の列, 列の数)。古い側から。
        let older = start >= 0 ? (start, n) : (start + ring.columns, -start)
        let newer = start >= 0 ? (0, 0) : (0, ring.head)
        ctx.saveGState()
        ctx.interpolationQuality = quality
        let split = (rect.width * CGFloat(older.1) / CGFloat(n)).rounded()
        if older.1 > 0, let part = image.cropping(to: CGRect(x: older.0, y: 0, width: older.1, height: ring.rows)) {
            let width = newer.1 > 0 ? split : rect.width
            drawUpright(ctx, part, in: CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height))
        }
        if newer.1 > 0, let part = image.cropping(to: CGRect(x: newer.0, y: 0, width: newer.1, height: ring.rows)) {
            drawUpright(ctx, part, in: CGRect(x: rect.minX + split, y: rect.minY,
                                              width: rect.width - split, height: rect.height))
        }
        ctx.restoreGState()
    }

    // MARK: - Classic

    private static func drawClassicSpectrogram(_ ctx: CGContext, _ rect: CGRect, _ scale: CGFloat,
                                               _ ring: ETSpectrogramRing?) {
        guard let ring else { return }
        let count = min(ETVisualizerAnalysis.classicColumns, max(1, Int((rect.width / scale).rounded())))
        drawRing(ctx, ring, rect, newest: count, quality: .none)
    }

    private static func drawClassicWaveform(_ ctx: CGContext, _ rect: CGRect, _ scale: CGFloat,
                                            _ analysis: ETVisualizerAnalysis) {
        let center = rect.midY
        let count = min(Int(rect.width / scale), ETVisualizerAnalysis.waveformColumns)
        for k in 0..<count {
            let column = analysis.column(newest: k)
            // 0 dBFS を区画いっぱいにせず 0.2 dB ぶん空ける。音圧の高い曲はほぼ 0 dBFS に張り付き、
            // いっぱいだと上下が切れて見える（本人「0.5dbくらいだけ開けれる？」）。
            let half = CGFloat(min(column.peak, 1)) * waveformHeadroom * rect.height / 2
            guard half >= 0.5 * scale else { continue }
            ctx.setFillColor(red: CGFloat(column.color.r), green: CGFloat(column.color.g),
                             blue: CGFloat(column.color.b), alpha: 1)
            ctx.fill(CGRect(x: rect.maxX - CGFloat(k + 1) * scale, y: center - half, width: scale, height: 2 * half))
        }
    }

    /// MiniMeters の Both の形。塗りは列ごとに量の色（スペクトログラムと同じ並び）、上に 172,192,222 の線。
    /// 後ろに 10 刻みの周波数の細い線。
    private static func drawClassicSpectrum(_ ctx: CGContext, _ rect: CGRect, _ scale: CGFloat,
                                            _ theme: ETVisualizerTheme, _ analysis: ETVisualizerAnalysis) {
        let spectrum = analysis.classicSpectrum
        guard spectrum.count == ETVisualizerAnalysis.spectrumBins else { return }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.07)
        var decade = 10.0
        while decade < 20000 {
            for k in 1...9 {
                let f = decade * Double(k)
                guard f >= 20 && f <= 20000 else { continue }
                let gx = rect.minX + CGFloat(log(f / 20) / log(1000)) * rect.width
                ctx.fill(CGRect(x: gx.rounded(), y: rect.minY, width: scale, height: rect.height))
            }
            decade *= 10
        }
        func y(_ db: Float) -> CGFloat {
            let t = CGFloat((min(max(db, -84), -6) + 84) / 78)
            return rect.maxY - t * rect.height
        }
        let fine = spectrum.count
        let columns = max(1, Int(rect.width / scale / 2))
        let columnWidth = 2 * scale
        // 線の点は使い回す配列に溜める（毎フレームの確保をしない）。
        linePoints.removeAll(keepingCapacity: true)
        for c in 0..<columns {
            let lo = c * fine / columns
            let hi = max(lo + 1, (c + 1) * fine / columns)
            var db: Float = -120
            for i in lo..<min(hi, fine) { db = max(db, spectrum[i]) }
            let top = y(db)
            let x = rect.minX + CGFloat(c) * columnWidth
            setFill(ctx, packed: ETVisualizerPalette.classicHeat(db))
            ctx.fill(CGRect(x: x, y: top, width: columnWidth, height: rect.maxY - top))
            linePoints.append(CGPoint(x: x + scale, y: top))
        }
        ctx.beginPath()
        ctx.addLines(between: linePoints)
        ctx.setStrokeColor(theme.trace)
        ctx.setLineWidth(2 * scale)
        ctx.setLineJoin(.round)
        ctx.strokePath()
    }

    private static var linePoints: [CGPoint] = []

    private static func drawClassicStereo(_ ctx: CGContext, _ rect: CGRect, _ scale: CGFloat,
                                          _ theme: ETVisualizerTheme, _ analysis: ETVisualizerAnalysis) {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2 - 4 * scale
        // 菱形が 2 重と、縦横の線と、L・R の向きの線（MiniMeters の格子）。
        ctx.setStrokeColor(theme.gridSubtle)
        ctx.setLineWidth(2 * scale)
        ctx.beginPath()
        func diamond(_ r: CGFloat) {
            ctx.move(to: CGPoint(x: c.x, y: c.y - r))
            ctx.addLine(to: CGPoint(x: c.x + r, y: c.y))
            ctx.addLine(to: CGPoint(x: c.x, y: c.y + r))
            ctx.addLine(to: CGPoint(x: c.x - r, y: c.y))
            ctx.closePath()
        }
        diamond(radius)
        diamond(radius * 0.5)
        ctx.move(to: CGPoint(x: c.x, y: c.y - radius))
        ctx.addLine(to: CGPoint(x: c.x, y: c.y + radius))
        ctx.move(to: CGPoint(x: c.x - radius, y: c.y))
        ctx.addLine(to: CGPoint(x: c.x + radius, y: c.y))
        ctx.move(to: CGPoint(x: c.x - radius / 2, y: c.y - radius / 2))
        ctx.addLine(to: CGPoint(x: c.x + radius / 2, y: c.y + radius / 2))
        ctx.move(to: CGPoint(x: c.x + radius / 2, y: c.y - radius / 2))
        ctx.addLine(to: CGPoint(x: c.x - radius / 2, y: c.y + radius / 2))
        ctx.strokePath()

        // 直近 1024 点。重なったときの上下が以前と同じになるよう、以前の輪（1024 個・添字は通し番号の剰余）の順で打つ。
        let count = 1024
        let total = analysis.stereoTotal
        let base = total - count
        let dot = 4 * scale
        for i in 0..<count {
            let a = base + (((i - base) % count) + count) % count
            let frame = analysis.stereoFrame(at: a)
            let px = c.x + CGFloat(frame.r - frame.l) * 0.7071 * radius
            let py = c.y - CGFloat(frame.l + frame.r) * 0.7071 * radius
            ctx.setFillColor(red: CGFloat(frame.color.r), green: CGFloat(frame.color.g),
                             blue: CGFloat(frame.color.b), alpha: 1)
            ctx.fillEllipse(in: CGRect(x: px - dot / 2, y: py - dot / 2, width: dot, height: dot))
        }
    }

    /// L・R のピーク（細い 2 本）と LUFS（太い 1 本）。MiniMeters の Peak/LUFS と同じ並び。
    /// 幅は 64 ピクセルの区画のときの大きさ。区画が広ければ同じ割合で太くする。
    private static func drawClassicLevel(_ ctx: CGContext, _ rect: CGRect, _ scale: CGFloat,
                                         _ theme: ETVisualizerTheme, _ analysis: ETVisualizerAnalysis) {
        let k = max(1, rect.width / scale / 64) * scale
        let thin = 10 * k, wide = 16 * k, gap = 3 * k, apart = 8 * k
        let total = 2 * thin + gap + apart + wide
        var x = rect.midX - total / 2
        func y(_ db: Double) -> CGFloat {
            let t = CGFloat((min(max(db, -60), 0) + 60) / 60)
            return rect.maxY - t * rect.height
        }
        for ch in 0..<2 {
            let level = analysis.classicLevels[ch]
            ctx.setFillColor(theme.groove)
            ctx.fill(CGRect(x: x, y: rect.minY, width: thin, height: rect.height))
            let top = y(Double(level.current))
            ctx.setFillColor(theme.trace)
            ctx.fill(CGRect(x: x, y: top, width: thin, height: rect.maxY - top))
            ctx.fill(CGRect(x: x, y: y(Double(level.peak)) - scale, width: thin, height: 2 * scale))
            x += thin + gap
        }
        x += apart - gap
        ctx.setFillColor(theme.groove)
        ctx.fill(CGRect(x: x, y: rect.minY, width: wide, height: rect.height))
        if analysis.momentary.isFinite {
            let top = y(analysis.momentary)
            ctx.setFillColor(theme.trace)
            ctx.fill(CGRect(x: x, y: top, width: wide, height: rect.maxY - top))
        }
    }

    // MARK: - アートワーク

    /// 角丸の枠の路。区画ごとに覚える（場面にアートワークが複数あっても毎フレーム作り直さない）。8 を超えたら空にする。
    private struct RectKey: Hashable {
        let x: Int, y: Int, w: Int, h: Int
        init(_ r: CGRect) {
            x = Int((r.minX * 16).rounded()); y = Int((r.minY * 16).rounded())
            w = Int((r.width * 16).rounded()); h = Int((r.height * 16).rounded())
        }
    }
    private static var artworkClipPaths: [RectKey: CGPath] = [:]

    /// `weight` は取得中の重さ。NCS の要素が無い並びなら、アートワークの上に粒（ncs）を重ねて入れ替える。
    /// NCS の要素がある並びでは、アートワークが薄くなるだけ（粒は NCS の要素が出している）。
    /// 粒の絵が無い（最初の 1 枚が出来ていない・Metal が使えない）ときは、アートワークをそのまま出す。
    private static func drawArtwork(_ ctx: CGContext, _ rect: CGRect, _ theme: ETVisualizerTheme,
                                    _ artwork: CGImage?, classic: Bool, ncs: CGImage?, weight: CGFloat, hasNCS: Bool) {
        if classic {
            // 今と同じ溝の上に置く。曲が取れていないあいだも溝は出す。
            ctx.setFillColor(theme.groove)
            ctx.fill(rect)
        }
        let showNCS = weight > 0 && !hasNCS && ncs != nil
        let artAlpha: CGFloat = (weight > 0 && (showNCS || hasNCS)) ? 1 - weight : 1
        let drawsArtwork = artwork != nil && artAlpha > 0
        guard drawsArtwork || showNCS else { return }
        // ジャケットは正方形。枠が長方形（iPad の縦長・横長など）でも、枠の中のいちばん大きい正方形に置いて切り取らない。
        let side = min(rect.width, rect.height)
        let square = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        ctx.saveGState()
        if !classic {
            // 上流の artwork は角を 6% 丸める（visualizer-renderer.js:190, 239-243）。
            let radius = side * 0.06
            let key = RectKey(square)
            let path: CGPath
            if let cached = artworkClipPaths[key] {
                path = cached
            } else {
                path = CGPath(roundedRect: square, cornerWidth: radius, cornerHeight: radius, transform: nil)
                if artworkClipPaths.count >= 8 { artworkClipPaths.removeAll() }
                artworkClipPaths[key] = path
            }
            ctx.addPath(path)
            ctx.clip()
        }
        ctx.clip(to: square)
        if drawsArtwork, let artwork {
            // cover-fit（visualizer-renderer.js の drawCover）。正方形の中で、画像が正方形でなければここで切る。
            let fit = max(side / CGFloat(artwork.width), side / CGFloat(artwork.height))
            let width = CGFloat(artwork.width) * fit, height = CGFloat(artwork.height) * fit
            ctx.saveGState()
            ctx.setAlpha(artAlpha)
            ctx.interpolationQuality = .high
            drawUpright(ctx, artwork, in: CGRect(x: square.midX - width / 2, y: square.midY - height / 2,
                                                 width: width, height: height))
            ctx.restoreGState()
        }
        if showNCS, let ncs {
            ctx.saveGState()
            ctx.setAlpha(weight)
            ctx.interpolationQuality = .medium
            drawUpright(ctx, ncs, in: square)
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    // MARK: - EffeTune

    /// min→max を 1 列ずつ塗り、隣の列とつなぐ（oscilloscope.js:887-928 の paintEnvelopeColumns）。右が新しい。
    private static func drawWaveform(_ ctx: CGContext, _ rect: CGRect, _ scale: CGFloat,
                                     _ theme: ETVisualizerTheme, _ analysis: ETVisualizerAnalysis) {
        let count = min(Int(rect.width / scale), ETVisualizerAnalysis.waveformColumns)
        guard count > 0 else { return }
        let half = rect.height / 2, center = rect.midY
        ctx.setFillColor(theme.trace)
        var previousTop: CGFloat?
        var previousBottom: CGFloat?
        for k in stride(from: count - 1, through: 0, by: -1) {
            let column = analysis.column(newest: k)
            let top = center - CGFloat(column.hi) * half
            let bottom = center - CGFloat(column.lo) * half
            // 細い所もつなぎ、この 1 ピクセルが表すピークは残す。
            let connectedTop = previousBottom.map { min(top, $0) } ?? top
            let connectedBottom = previousTop.map { max(bottom, $0) } ?? bottom
            ctx.fill(CGRect(x: rect.maxX - CGFloat(k + 1) * scale, y: connectedTop - scale / 2, width: scale,
                            height: max(scale, connectedBottom - connectedTop + scale)))
            previousTop = top
            previousBottom = bottom
        }
    }

    /// モノラル 10ms。トリガは Auto / Rising / レベル 0 で、最新の立ち上がりのゼロ交差のうち後ろに窓ぶんの
    /// 標本が残っているもの。無ければ最新の窓。ホールドオフ（0.1ms）は 1 回の選び方では効かない。
    private static func drawOscilloscope(_ ctx: CGContext, _ rect: CGRect, _ scale: CGFloat,
                                         _ theme: ETVisualizerTheme, _ analysis: ETVisualizerAnalysis) {
        let window = max(2, Int(0.010 * analysis.sampleRate))
        let total = analysis.monoTotal
        guard total >= window else { return }
        var start = total - window
        var candidate = start
        let oldest = max(1, total - ETVisualizerAnalysis.monoCount + 1)
        while candidate >= oldest {
            if analysis.monoSample(at: candidate - 1) < 0 && analysis.monoSample(at: candidate) >= 0 {
                start = candidate
                break
            }
            candidate -= 1
        }
        let half = rect.height / 2
        ctx.beginPath()
        for i in 0..<window {
            let v = CGFloat(min(max(analysis.monoSample(at: start + i), -1), 1))
            let p = CGPoint(x: rect.minX + rect.width * CGFloat(i) / CGFloat(window - 1), y: rect.midY - v * half)
            if i == 0 { ctx.move(to: p) } else { ctx.addLine(to: p) }
        }
        ctx.setStrokeColor(theme.trace)
        ctx.setLineWidth(2 * scale)
        ctx.setLineJoin(.round)
        ctx.strokePath()
    }

    // MARK: Spectrum

    /// 0 dB が上、-96 dB が下。
    private static func spectrumY(_ rect: CGRect, _ db: Float) -> CGFloat {
        rect.minY + rect.height * CGFloat(min(max(db, -96), 0) / -96)
    }

    private static func drawSpectrum(_ ctx: CGContext, _ rect: CGRect, _ scale: CGFloat,
                                     _ theme: ETVisualizerTheme, _ analysis: ETVisualizerAnalysis,
                                     _ display: ETSpectrumDisplay) {
        let current = analysis.effetuneSpectrum, peaks = analysis.effetunePeaks
        let fine = ETVisualizerAnalysis.spectrumBins
        guard current.count == fine, peaks.count == fine else { return }
        if display == .line {
            strokeSpectrum(ctx, rect, peaks, width: scale, theme.trace)
            strokeSpectrum(ctx, rect, current, width: 2 * scale, theme.trace)
        } else {
            drawSpectrumBars(ctx, rect, scale, theme, current, peaks, bands: 48)
        }
    }

    private static func strokeSpectrum(_ ctx: CGContext, _ rect: CGRect, _ values: [Float],
                                       width: CGFloat, _ color: CGColor) {
        ctx.beginPath()
        var open = false
        let last = CGFloat(values.count - 1)
        for i in 0..<values.count {
            // Nyquist より上（-∞）は線を切る。
            guard values[i] > -.infinity else {
                open = false
                continue
            }
            let p = CGPoint(x: rect.minX + rect.width * CGFloat(i) / last, y: spectrumY(rect, values[i]))
            if open { ctx.addLine(to: p) } else { ctx.move(to: p); open = true }
        }
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.setLineJoin(.round)
        ctx.strokePath()
    }

    /// 棒（spectrum_analyzer.js:1309-1375 の drawSpectrumBars）。棒の隙間は 2 ピクセル、1dB ごとに
    /// 深い色の線で段に切る。Visualizer の既定（quantizeBars）どおり、棒の先は段に切り下げ、
    /// ピークは自分の段 1 つを（上下 0.5 ピクセルずつ空けて）灯す。帯の数は 48 固定（上流は narrow でも bc のまま）。
    private static func drawSpectrumBars(_ ctx: CGContext, _ rect: CGRect, _ scale: CGFloat,
                                         _ theme: ETVisualizerTheme, _ current: [Float], _ peaks: [Float],
                                         bands: Int) {
        let fine = current.count
        let bandWidth = rect.width / CGFloat(bands)
        let gap = bandWidth - 2 * scale >= scale ? 2 * scale : 0
        let barWidth = bandWidth - gap
        let pitch = rect.height / 96
        let fullBlocks = (rect.height / pitch).rounded(.down)
        // 帯の最大。Nyquist より上だけの帯は nil。
        func band(_ values: [Float], _ b: Int) -> Float? {
            var top: Float = -.infinity
            for i in (b * fine / bands)..<((b + 1) * fine / bands) { top = max(top, values[i]) }
            return top > -.infinity ? top : nil
        }
        func addBars() {
            for b in 0..<bands {
                guard let db = band(current, b) else { continue }
                let raw = spectrumY(rect, db)
                let y = rect.maxY - ((rect.maxY - raw) / pitch).rounded(.down) * pitch
                ctx.addRect(CGRect(x: rect.minX + CGFloat(b) * bandWidth + gap / 2, y: y,
                                   width: barWidth, height: rect.maxY - y))
            }
        }
        ctx.saveGState()
        ctx.setFillColor(theme.trace)
        ctx.beginPath()
        addBars()
        ctx.fillPath()
        // 段の切れ目は棒の中だけ。
        ctx.beginPath()
        addBars()
        ctx.clip()
        ctx.setStrokeColor(theme.deep)
        ctx.setLineWidth(scale)
        ctx.beginPath()
        var y = rect.maxY - pitch
        while y > rect.minY {
            ctx.move(to: CGPoint(x: rect.minX, y: y))
            ctx.addLine(to: CGPoint(x: rect.maxX, y: y))
            y -= pitch
        }
        ctx.strokePath()
        ctx.restoreGState()

        ctx.setFillColor(theme.trace)
        for b in 0..<bands {
            guard let db = band(peaks, b) else { continue }
            let raw = spectrumY(rect, db)
            let blocks = min(fullBlocks, ((rect.maxY - raw) / pitch).rounded(.up))
            let y = rect.maxY - blocks * pitch
            ctx.fill(CGRect(x: rect.minX + CGFloat(b) * bandWidth + gap / 2, y: y + scale / 2,
                            width: barWidth, height: pitch - scale))
        }
    }

    // MARK: Stereo

    /// σ = 5°、±15° のガウス（stereo_meter.js:620-636）。足して 1 にしてある。
    private static let gaussian: [Double] = {
        let weights = (-15...15).map { exp(-Double($0 * $0) / (2 * 5.0 * 5.0)) }
        let total = weights.reduce(0, +)
        return weights.map { $0 / total }
    }()

    /// ゴニオメーター（stereo_meter.js:510-761）。菱形の格子、L/R のリサージュ、ピークの輪郭、
    /// 左の相関の棒と下の左右差の棒。格子と字は付けない（軸は上流も既定で出さない）。
    private static func drawStereo(_ ctx: CGContext, _ rect: CGRect, _ scale: CGFloat,
                                   _ theme: ETVisualizerTheme, _ analysis: ETVisualizerAnalysis, _ narrow: Bool) {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) * 0.45
        // 格子（菱形・縦横・斜め）は描かない。上流の Visualizer は showAxes が既定で false で、
        // stereo_meter.js:570-608 が線を引かない。Classic の菱形は MiniMeters の見た目として別に描く。

        // 点。直近 0.1 秒を古いほど薄く（256 段に分けて、段ごとにまとめて塗る）。
        let count = min(Int(0.1 * analysis.sampleRate), ETVisualizerAnalysis.stereoCount, analysis.stereoTotal)
        if count > 0 {
            let size = (narrow ? 2 : 1) * scale
            let first = analysis.stereoTotal - count
            ctx.setFillColor(theme.trace)
            ctx.beginPath()
            var bucket = 0
            func flush() {
                if bucket > 0 {
                    ctx.setAlpha(CGFloat(bucket) / 255)
                    ctx.fillPath()
                } else {
                    ctx.beginPath()
                }
            }
            for i in 0..<count {
                let b = count > 1 ? min(255, i * 256 / (count - 1)) : 255
                if b != bucket {
                    flush()
                    bucket = b
                }
                let frame = analysis.stereoFrame(at: first + i)
                // x = R - L、y = L + R。ひし形の外へ大きく外れた点で路を壊さないよう止める。
                let x = min(max(Double(frame.r - frame.l), -4), 4)
                let y = min(max(Double(frame.l + frame.r), -4), 4)
                ctx.addRect(CGRect(x: c.x + CGFloat(0.5 * x) * radius - size / 2,
                                   y: c.y - CGFloat(0.5 * y) * radius - size / 2, width: size, height: size))
            }
            flush()
            ctx.setAlpha(1)
        }

        // ピークの輪郭。
        let envelope = analysis.envelope
        if envelope.count == ETVisualizerAnalysis.envelopeBins {
            let bins = envelope.count
            ctx.beginPath()
            for bin in 0..<bins {
                var sum = 0.0
                for (k, weight) in gaussian.enumerated() {
                    sum += envelope[((bin + k - 15) % bins + bins) % bins] * weight
                }
                let radians = Double(bin) * Double.pi / 180
                let r = CGFloat(min(max(sum, 0), 2)) * radius
                let p = CGPoint(x: c.x + CGFloat(cos(radians)) * r, y: c.y + CGFloat(sin(radians)) * r)
                if bin == 0 { ctx.move(to: p) } else { ctx.addLine(to: p) }
            }
            ctx.closePath()
            ctx.setStrokeColor(theme.text)
            ctx.setLineWidth(scale)
            ctx.setLineJoin(.round)
            ctx.strokePath()

            // 縁の棒。相関は左（中心から上が正）、左右差は下（中心から右が R 寄り、±18dB）。
            let statistics = analysis.stereoStatistics(seconds: 0.1)
            let thickness = 16 * scale
            ctx.setFillColor(theme.trace)
            let length = CGFloat(abs(statistics.correlation)) * rect.height / 2
            if length > 0.5 * scale {
                ctx.fill(CGRect(x: rect.minX, y: statistics.correlation >= 0 ? rect.midY - length : rect.midY,
                                width: thickness, height: length))
            }
            let balance = min(max(statistics.balance, -18), 18)
            let across = CGFloat(balance / 18) * rect.width / 2
            if abs(across) > 0.5 * scale {
                ctx.fill(CGRect(x: across >= 0 ? rect.midX : rect.midX + across, y: rect.maxY - thickness,
                                width: abs(across), height: thickness))
            }
        }
    }

    // MARK: Level Meter

    /// サンプルピーク L/R（-96〜0dB）。縦に描く（横向きは withLevelOrientation が回す）。
    private static func drawLevel(_ ctx: CGContext, _ rect: CGRect, _ scale: CGFloat,
                                  _ theme: ETVisualizerTheme, _ analysis: ETVisualizerAnalysis) {
        let gap = 2 * scale
        let barWidth = (rect.width - gap) / 2
        for ch in 0..<2 {
            let level = analysis.effetuneLevels[ch]
            let x = rect.minX + CGFloat(ch) * (barWidth + gap)
            let top = spectrumY(rect, level.current)
            ctx.setFillColor(theme.trace)
            ctx.fill(CGRect(x: x, y: top, width: barWidth, height: rect.maxY - top))
            let mark = min(spectrumY(rect, level.peak), rect.maxY - 2 * scale)
            ctx.setFillColor(theme.text)
            ctx.fill(CGRect(x: x, y: mark, width: barWidth, height: 2 * scale))
        }
        // 目盛りの線は引かない。上流の Visualizer は showAxes が既定で false で、level_meter.js の
        // drawStaticBackground が何も描かずに戻る。
    }

    // MARK: Analog Meter

    private static var scaleCache: [ETAnalogMeterChoice: ETAnalogMeter.Scale] = [:]

    /// 針の目盛り。既定の設定（VU は基準 -14、Loudness は目標 -23・Momentary）。
    private static func analogScale(_ mode: ETAnalogMeterChoice) -> ETAnalogMeter.Scale {
        if let cached = scaleCache[mode] { return cached }
        var settings = ETAnalogMeter.Settings()
        settings.mode = mode == .loudness ? ETAnalogMeter.loudnessMode : 0
        let made = ETAnalogMeter.scale(mode: ETAnalogMeter.modes[settings.mode], settings: settings)
        scaleCache[mode] = made
        return made
    }

    /// 目盛りの字から決まるもの。針の目盛りは変わらないので、モードごとに 1 度だけ作る。
    private struct AnalogInfo {
        /// いちばん長い字の文字数。
        let longestLabel: Int
        /// 字つきの目盛りのうち、隣り合う 2 つの間隔（0〜1 の位置の差）の最小。字が 2 つ未満なら nil。
        let minGap: Double?
        /// 字がぶつかるときに残す字（基準から数えて 1 つおき）。
        let sparse: Set<Double>
    }
    private static var infoCache: [ETAnalogMeterChoice: AnalogInfo] = [:]

    private static func analogInfo(_ mode: ETAnalogMeterChoice, _ meter: ETAnalogMeter.Scale) -> AnalogInfo {
        if let cached = infoCache[mode] { return cached }
        let labeled = meter.ticks.filter { !$0.label.isEmpty }
        var gap: Double?
        for i in labeled.indices where i > 0 {
            let step = abs(meter.valuePosition(labeled[i].value) - meter.valuePosition(labeled[i - 1].value))
            gap = min(gap ?? step, step)
        }
        let made = AnalogInfo(longestLabel: meter.ticks.map { $0.label.count }.max() ?? 0, minGap: gap,
                              sparse: ETAnalogMeter.sparseLabels(meter))
        infoCache[mode] = made
        return made
    }

    /// 針の計器。4:3 の面を中央に置く（VU は左右の 2 つ、Loudness は Program の 1 つ）。
    /// 弧と目盛りと針は Views/Effects/AnalogMeterView.swift の drawCell と同じ形。見出しと読み値は付けず、
    /// 面は透明（faceOpacity 0）。目盛りの字は EffeTune の見た目でだけ付ける。
    private static func drawAnalogMeter(_ ctx: CGContext, _ rect: CGRect, _ scale: CGFloat,
                                        _ theme: ETVisualizerTheme, _ analysis: ETVisualizerAnalysis,
                                        _ mode: ETAnalogMeterChoice, labels: Bool) {
        let meter = analogScale(mode)
        let loudness = mode == .loudness
        let grid = ETAnalogMeter.grid(cells: loudness ? 1 : ETAnalogMeter.cellCount(mode: 0, channelCount: 2))
        let columns = CGFloat(grid.columns), rows = CGFloat(grid.rows)
        let cellWidth = min(rect.width / columns, rect.height / rows * 4 / 3)
        let cellHeight = cellWidth * 3 / 4
        let originX = rect.midX - cellWidth * columns / 2
        let originY = rect.midY - cellHeight * rows / 2

        let arc = ETAnalogMeter.arcDegrees * Double.pi / 180
        let inset = 4 * scale
        let fontSize = 12 * scale
        let labelSize = fontSize * 0.85
        let info = analogInfo(mode, meter)
        let longestLabel = CGFloat(info.longestLabel)
        // 端の字は目盛りの外へ横に張り出すので、いちばん長い字の幅ぶんを幅の限りから引く。
        let sideRoom = (labels ? longestLabel * labelSize * 0.6 : 0) + 9 * scale * CGFloat(sin(arc)) + inset
        let labelRise = 9 * scale + (labels ? labelSize * 1.25 : 0)
        let redExtra: CGFloat = meter.redFrom == nil ? 0 : 2 * scale
        let topOffset = inset + 3 * scale + labelRise + redExtra
        let bottomOffset = inset * 2

        for cell in 0..<grid.cells {
            let box = CGRect(x: originX + CGFloat(cell % grid.columns) * cellWidth,
                             y: originY + CGFloat(cell / grid.columns) * cellHeight,
                             width: cellWidth, height: cellHeight)
            let pivot = CGPoint(x: box.midX, y: box.maxY - bottomOffset)
            let widthRadius = (box.width / 2 - inset - sideRoom) / CGFloat(sin(arc))
            let radius = max(8 * scale, min(widthRadius, pivot.y - (box.minY + topOffset)))
            func angle(_ position: Double) -> Double { -arc + 2 * arc * position }
            func point(_ position: Double, _ distance: CGFloat) -> CGPoint {
                let a = angle(position)
                return CGPoint(x: pivot.x + CGFloat(sin(a)) * distance, y: pivot.y - CGFloat(cos(a)) * distance)
            }
            func arcPath(_ from: Double, _ to: Double, _ distance: CGFloat) {
                let steps = 48
                for i in 0...steps {
                    let p = point(from + (to - from) * Double(i) / Double(steps), distance)
                    if i == 0 { ctx.move(to: p) } else { ctx.addLine(to: p) }
                }
            }

            // 弧と赤い帯。
            ctx.setLineJoin(.round)
            ctx.beginPath()
            arcPath(0, 1, radius)
            ctx.setStrokeColor(theme.label)
            ctx.setLineWidth(scale)
            ctx.strokePath()
            if let red = meter.redFrom {
                ctx.beginPath()
                arcPath(meter.valuePosition(red), 1, radius + 2 * scale)
                ctx.setStrokeColor(theme.danger)
                ctx.setLineWidth(3 * scale)
                ctx.strokePath()
            }

            // 目盛り。隣の字がぶつかるときは、基準から数えて 1 つおきにする（analog_meter.js:849-860）。
            let labelRadius = radius + 9 * scale
            var thin = false
            if labels, let gap = info.minGap {
                let widest = longestLabel * labelSize * 0.6
                let spacing = CGFloat(2 * Double(labelRadius) * sin(arc * gap))
                thin = spacing < widest + fontSize * 0.3
            }
            for tick in meter.ticks {
                let position = meter.valuePosition(tick.value)
                let major = !tick.label.isEmpty
                let emphasized = ETAnalogMeter.isEmphasized(tick.value, in: meter)
                ctx.beginPath()
                ctx.move(to: point(position, radius))
                ctx.addLine(to: point(position, radius + (major ? 7 : 4) * scale))
                ctx.setStrokeColor(emphasized ? theme.text : theme.label)
                ctx.setLineWidth(emphasized ? 2 * scale : scale)
                ctx.strokePath()
                guard labels, major else { continue }
                if thin && !info.sparse.contains(tick.value) { continue }
                // 字の箱は目盛りの向きに外へ張り出す位置で止める。端の字が自分の目盛りに乗らない。
                let a = angle(position)
                drawLabel(ctx, tick.label, size: labelSize, at: point(position, labelRadius),
                          anchorX: 0.5 - 0.5 * CGFloat(sin(a)), anchorY: 0.5 + 0.5 * CGFloat(cos(a)),
                          color: emphasized ? theme.text : theme.label)
            }

            // 針と軸。VU は左右それぞれの針、Loudness は Momentary。
            let db: Double
            if loudness {
                db = analysis.momentary
            } else {
                db = Double(analysis.vuDB[cell])
            }
            ctx.beginPath()
            ctx.move(to: pivot)
            ctx.addLine(to: point(meter.dbPosition(db), radius * 1.02))
            ctx.setStrokeColor(theme.text)
            ctx.setLineWidth(2 * scale)
            ctx.strokePath()
            ctx.setFillColor(theme.text)
            ctx.fillEllipse(in: CGRect(x: pivot.x - 3 * scale, y: pivot.y - 3 * scale, width: 6 * scale, height: 6 * scale))
        }
    }

    // MARK: 字

    private struct Label {
        let line: CTLine
        let width: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
    }
    private struct LabelKey: Hashable {
        let size: Int
        let text: String
    }
    private static var labelCache: [LabelKey: Label] = [:]

    /// 字を 1 つ置く。`anchorX` / `anchorY` は字の箱の中の割合（0.5, 0.5 が中央）で、それが `p` に来る。
    /// 上が 0 の器に合わせて textMatrix を反転する。色は context の塗りの色。
    private static func drawLabel(_ ctx: CGContext, _ text: String, size: CGFloat, at p: CGPoint,
                                  anchorX: CGFloat, anchorY: CGFloat, color: CGColor) {
        let key = LabelKey(size: Int((size * 100).rounded()), text: text)
        let label: Label
        if let cached = labelCache[key] {
            label = cached
        } else {
            let font = CTFontCreateUIFontForLanguage(.system, size, nil)
                ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font,
                NSAttributedString.Key(rawValue: kCTForegroundColorFromContextAttributeName as String): true,
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            label = Label(line: line, width: width, ascent: ascent, descent: descent)
            if labelCache.count > 256 { labelCache.removeAll() }
            labelCache[key] = label
        }
        ctx.saveGState()
        ctx.setFillColor(color)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: p.x - anchorX * label.width,
                                   y: p.y - anchorY * (label.ascent + label.descent) + label.ascent)
        CTLineDraw(label.line, ctx)
        ctx.restoreGState()
    }

    // MARK: 曲名・歌手名

    private struct TextKey: Hashable {
        let text: String
        let font: ETVisualizerFont
        let bold: Bool
        let size: Int
        let width: Int
    }
    private static var textCache: [TextKey: Label] = [:]

    private static func songFont(_ font: ETVisualizerFont, bold: Bool, size: CGFloat) -> CTFont {
        switch font {
        case .system:
            return CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)
                ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        case .serif:
            return CTFontCreateWithName((bold ? "Georgia-Bold" : "Georgia") as CFString, size, nil)
        case .monospaced:
            return CTFontCreateWithName((bold ? "Menlo-Bold" : "Menlo-Regular") as CFString, size, nil)
        }
    }

    /// 曲名・歌手名の 1 行。大きさは矩形の高さから決める。幅に入らなければ後ろを … で切る。
    /// 空なら何も描かない（編集画面では「Title」「Artist」を 35% の濃さで仮に出す）。色は要素の色（濃さは層が掛ける）。
    private static func drawSongText(_ ctx: CGContext, _ content: CGRect, text: String, placeholder: String?,
                                     _ e: ETVisualizerElement) {
        var shown = text
        var alpha: CGFloat = 1
        if shown.isEmpty {
            guard let placeholder else { return }
            shown = placeholder
            alpha = 0.35
        }
        let size = content.height / 1.25
        guard size >= 1, content.width >= 1 else { return }
        let key = TextKey(text: shown, font: e.font, bold: e.bold, size: Int((size * 10).rounded()),
                          width: Int(content.width))
        let label: Label
        if let cached = textCache[key] {
            label = cached
        } else {
            let font = songFont(e.font, bold: e.bold, size: size)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font,
                NSAttributedString.Key(rawValue: kCTForegroundColorFromContextAttributeName as String): true,
            ]
            var line = CTLineCreateWithAttributedString(NSAttributedString(string: shown, attributes: attributes))
            if CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) > content.width {
                let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
                if let truncated = CTLineCreateTruncatedLine(line, Double(content.width), .end, token) { line = truncated }
            }
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            label = Label(line: line, width: width, ascent: ascent, descent: descent)
            if textCache.count >= 32 { textCache.removeAll() }
            textCache[key] = label
        }
        let x: CGFloat
        switch e.alignment {
        case .leading: x = content.minX
        case .center: x = content.midX - label.width / 2
        case .trailing: x = content.maxX - label.width
        }
        ctx.saveGState()
        ctx.setFillColor(color(e.color, alpha: alpha))
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: x, y: content.midY - (label.ascent + label.descent) / 2 + label.ascent)
        CTLineDraw(label.line, ctx)
        ctx.restoreGState()
    }
}
