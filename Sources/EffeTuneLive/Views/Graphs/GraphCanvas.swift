//  GraphCanvas.swift
//  図の土台。目盛り・格子・軸のラベルだけを引き受けて、中身は呼ぶ側に描かせる。
//
//  軸の取り方は EffeTune の web 版に合わせてある。
//    周波数は対数（plugins/eq/five_band_peq.js:716 freqToX）
//    レベルは線形の dB（同 718 gainToY）
//    スペクトラムの表示範囲 20Hz〜40kHz（plugins/analyzer/spectrum_analyzer.js:9-10）
//
//  色は決めない。.tint / .secondary / .quaternary だけを使う。
//  テーマを移すときは ETGraphShading の 4 行を差し替えれば済む。
//
//  使う側:
//      GraphCanvas(x: .frequency(), y: .decibels(-24...24, step: 6),
//                  readout: readoutItems) { ctx, plot in
//          ctx.stroke(path(in: plot), with: ETGraphShading.curve, lineWidth: 2)
//      }

import SwiftUI
import Foundation

// MARK: - 寸法

enum ETGraphMetrics {
    /// 図の高さの目安。iPhone の幅（390pt）で 140〜200pt に収める。
    static let height: CGFloat = 170
    static let compactHeight: CGFloat = 140
    /// 上に出す値の行。掴んでいる間だけ字が入るが、高さは常に取っておく（図が跳ねないように）。
    static let readoutHeight: CGFloat = 17
    static let labelSize: CGFloat = 9
    static let readoutSize: CGFloat = 11
}

/// 描くときの塗り。ここだけ見れば配色が分かるようにしておく。
enum ETGraphShading {
    static var grid: GraphicsContext.Shading { .style(.quaternary) }
    static var axis: GraphicsContext.Shading { .style(.tertiary) }
    static var curve: GraphicsContext.Shading { .style(.tint) }
    static var muted: GraphicsContext.Shading { .style(.secondary) }
    /// 図に重ねるスペクトラムの線。上流の --et-graph-overlay-after は
    /// アクセント色の 55%（effetune-theme.css:95）。canvas 側の 0.85
    /// （spectrum-overlay.css:16）は描く側が context.opacity で掛ける。
    static var overlay: GraphicsContext.Shading { .style(AnyShapeStyle(.tint).opacity(0.55)) }
    /// Compare のときの出口の線。上流の --et-graph-overlay-compare は
    /// 文字色の 90%（effetune-theme.css:96）。
    static var overlayCompare: GraphicsContext.Shading { .style(AnyShapeStyle(.primary).opacity(0.9)) }
    /// Compare で出口が入口より上の所の塗り。上流の --et-graph-overlay-positive は
    /// 警告色の 55%（effetune-theme.css:97）。下の所は overlay（アクセント色の 55%）で塗る
    /// （spectrum-overlay.js:579）。
    static var overlayPositive: GraphicsContext.Shading { .style(Color.orange.opacity(0.55)) }
}

// MARK: - 上に出す値

/// 掴んでいる値を図の外に出すための 1 つぶん。指の下は見えないので、ここに出す。
struct ETReadoutItem: Identifiable, Equatable {
    let label: String
    let value: String

    var id: String { label + "\u{1}" + value }

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

// MARK: - 土台

struct GraphCanvas<Overlay: View>: View {

    var x: ETAxis
    var y: ETAxis
    var height: CGFloat

    /// 畳んだカードから渡る高さの上限。nil なら height をそのまま使う。
    @Environment(\.etGraphMaxHeight) private var maxHeight
    @Environment(\.scenePhase) private var scenePhase
    /// PoC: PC の鎖を編集しているあいだの Analyzer（Views/RemoteScannerView.swift の ETRemoteMeasurementDim）。
    @Environment(\.etMeasurementDimmed) private var measurementDimmed
    /// 格子の層の鍵（ETGraphGrid）。外観とコントラストで線と字の色が変わる。
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @GestureState private var previewActive = false
    var insets: ETGraphInsets
    /// 掴んでいる値。空なら caption を出す。
    var readout: [ETReadoutItem]
    var caption: String?
    /// 読み値の行の**右端**に出す札。印を出したいときだけ。
    var badge: String?
    /// 読み値の行の右端（札の左）に置く部品。PEQ の重ね表示の切り替え
    /// （FrequencyResponseGraph）。図の面は印を掴むのに使っているので、面の上には置かない。
    var accessory: AnyView?
    /// 中身を枠で切るか。PEQ の曲線のように外へ出したいものは false。
    var clipsContent: Bool
    /// なぞった周波数をプレビュー音で鳴らすか。**解析の図だけが立てる。**
    /// 周波数軸の図すべてで鳴らしていたら、EQ の印を動かすたびに鳴った
    /// （FrequencyResponseGraph は図のどこを触っても最寄りの印を掴む）。
    var previewsFrequency: Bool
    /// 上の値の行（readoutHeight ぶん）を取るか。図の中に見出しを自分で描く図
    /// （Rhythm Analyzer）だけが false にして、行の分の空きを無くす。
    var showsHeader: Bool
    var draw: (inout GraphicsContext, ETPlot) -> Void
    var overlay: (ETPlot) -> Overlay

    init(x: ETAxis,
         y: ETAxis,
         height: CGFloat = ETGraphMetrics.height,
         insets: ETGraphInsets = .standard,
         readout: [ETReadoutItem] = [],
         caption: String? = nil,
         badge: String? = nil,
         accessory: AnyView? = nil,
         clipsContent: Bool = true,
         previewsFrequency: Bool = false,
         showsHeader: Bool = true,
         draw: @escaping (inout GraphicsContext, ETPlot) -> Void,
         @ViewBuilder overlay: @escaping (ETPlot) -> Overlay) {
        self.x = x
        self.y = y
        self.height = height
        self.insets = insets
        self.readout = readout
        self.caption = caption
        self.badge = badge
        self.accessory = accessory
        self.clipsContent = clipsContent
        self.previewsFrequency = previewsFrequency
        self.showsHeader = showsHeader
        self.draw = draw
        self.overlay = overlay
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsHeader { header }
            GeometryReader { geo in
                ZStack {
                    // 格子は軸・余白・大きさが同じあいだ描き直さない（下の ETGraphGrid）。
                    // 以前は格子と中身が 1 枚の Canvas で、沈めるときの不透明度（0.3）は
                    // 合わさった絵に掛かっていた。Canvas が 2 枚だと 1 枚ずつに掛かり、
                    // Spectrogram の不透明な絵から格子が透けてしまう。
                    // compositingGroup で 1 枚の絵に戻して、掛かり方を前と同じにする。
                    // overlay は前から別の View だったので、グループの外に置く。
                    ZStack {
                        ETGraphGrid(x: x, y: y, insets: insets, size: geo.size,
                                    colorScheme: colorScheme, contrast: colorSchemeContrast)
                            .equatable()
                        Canvas { context, size in
                            let plot = ETPlot(size: size, x: x, y: y, insets: insets)
                            if clipsContent {
                                context.drawLayer { layer in
                                    layer.clip(to: Path(plot.rect.insetBy(dx: -0.5, dy: -0.5)))
                                    draw(&layer, plot)
                                }
                            } else {
                                draw(&context, plot)
                            }
                        }
                    }
                    .compositingGroup()
                    overlay(ETPlot(size: geo.size, x: x, y: y, insets: insets))
                }
                // etOwnsDrag-exempt: 解析の図の試聴の音を出すだけで何も動かさない。畳んだ図の払いと長押しを止めないため印を付けない（印は印を掴む子の面が付ける）
                .simultaneousGesture(DragGesture(minimumDistance: 0)
                    .updating($previewActive) { _, active, _ in active = x.isFrequency || y.isFrequency }
                    .onChanged { touch in
                        guard x.isFrequency || y.isFrequency else { return }
                        let plot = ETPlot(size: geo.size, x: x, y: y, insets: insets)
                        guard plot.rect.contains(touch.location) else {
                            ETPreviewTone_SetFrequency(0)
                            return
                        }
                        ETPreviewTone_SetFrequency(x.isFrequency ? plot.xValue(at: touch.location.x) : plot.yValue(at: touch.location.y))
                    }
                    .onEnded { _ in ETPreviewTone_SetFrequency(0) },
                    // 立てない図ではジェスチャごと外す。子の印を掴むジェスチャは残る。
                    including: previewsFrequency ? .all : .subviews)
            }
            .frame(height: min(height, maxHeight ?? height))
        }
        // 読み値の行ごと沈める。数字も手元の音のもの。
        .etDimmedWhenMeasuring(measurementDimmed)
        .onDisappear { ETPreviewTone_SetFrequency(0) }
        .onChange(of: previewActive) { wasActive, active in
            if wasActive && !active { ETPreviewTone_SetFrequency(0) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { ETPreviewTone_SetFrequency(0) }
        }
    }

    /// 値の行。掴んでいないときは見出しを出す。高さは変えない。
    private var header: some View {
        HStack(spacing: 10) {
            if readout.isEmpty {
                if let caption {
                    Text(caption)
                        .font(.system(size: ETGraphMetrics.readoutSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                // **身元は並び順で取る。**ETReadoutItem の id は字そのもの
                // （label + value）なので、値が変わるたびに ForEach が
                // 「古いものを消して新しいものを挿す」形になる。挿し直された面は
                // 進んでいる位置の動きを引き継がないので、**行が動いている最中に
                // 値が変わると、字だけが先に着く**（並べ替えの 0.22 秒のあいだ、
                // 読み値は 30Hz で変わるのでほぼ必ず起きる）。
                ForEach(Array(readout.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 3) {
                        if !item.label.isEmpty {
                            Text(item.label)
                                .font(.system(size: 9, weight: .semibold))
                                .tracking(0.4)
                                .foregroundStyle(.secondary)
                        }
                        Text(item.value)
                            .font(.system(size: ETGraphMetrics.readoutSize, weight: .medium,
                                          design: .monospaced))
                    }
                }
            }
            Spacer(minLength: 0)
            if let accessory {
                accessory.fixedSize()
            }
            // 右端の札。行の高さは下で固定してあるので、出ても位置は動かない。
            if let badge {
                Text(badge)
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(0.5)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.tint, in: .capsule)
                    // 行の高さは下の frame が決めているので、
                    // 札が大きくても位置は動かない。
                    .fixedSize()
            }
        }
        .frame(height: ETGraphMetrics.readoutHeight, alignment: .leading)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

/// 格子と目盛りの字だけを描く層。
/// 中身（draw）は毎フレーム変わるが、格子は軸・余白・大きさが同じあいだ描き直さなくてよい。
/// 別の層にして .equatable() で飛ばす（計測では drawGrid が canvas の 672 サンプル中 489 だった）。
private struct ETGraphGrid: View, Equatable {
    let x: ETAxis
    let y: ETAxis
    let insets: ETGraphInsets
    /// size / colorScheme / contrast は比べるための鍵にだけ使う。
    /// 線と字の色（.quaternary / .tertiary / .secondary）は外観とコントラストで変わるので、
    /// Canvas が環境の変化で自分から描き直すかどうかに頼らず鍵に入れてある。
    /// body は読まないが、消してはいけない。
    let size: CGSize
    let colorScheme: ColorScheme
    let contrast: ColorSchemeContrast

    var body: some View {
        Canvas { context, canvasSize in
            Self.drawGrid(&context, ETPlot(size: canvasSize, x: x, y: y, insets: insets))
        }
        .accessibilityHidden(true)
    }

    // MARK: 格子

    static func drawGrid(_ context: inout GraphicsContext, _ plot: ETPlot) {
        let rect = plot.rect

        // 縦線と、その下の字。
        for tick in plot.xAxis.ticks {
            let px = plot.x(tick.value)
            guard px >= rect.minX - 0.5, px <= rect.maxX + 0.5 else { continue }
            var line = Path()
            line.move(to: CGPoint(x: px, y: rect.minY))
            line.addLine(to: CGPoint(x: px, y: rect.maxY))
            context.stroke(line, with: tick.emphasized ? ETGraphShading.axis : ETGraphShading.grid,
                           lineWidth: tick.emphasized ? 1 : 0.5)
            if let label = tick.label {
                context.draw(Self.tickText(label),
                             at: CGPoint(x: px, y: rect.maxY + 7), anchor: .center)
            }
        }

        // 横線と、その左の字。
        for tick in plot.yAxis.ticks {
            let py = plot.y(tick.value)
            guard py >= rect.minY - 0.5, py <= rect.maxY + 0.5 else { continue }
            var line = Path()
            line.move(to: CGPoint(x: rect.minX, y: py))
            line.addLine(to: CGPoint(x: rect.maxX, y: py))
            context.stroke(line, with: tick.emphasized ? ETGraphShading.axis : ETGraphShading.grid,
                           lineWidth: tick.emphasized ? 1 : 0.5)
            if let label = tick.label {
                context.draw(Self.tickText(label),
                             at: CGPoint(x: rect.minX - 3, y: py), anchor: .trailing)
            }
        }

        context.stroke(Path(rect), with: ETGraphShading.grid, lineWidth: 1)
    }

    private static func tickText(_ s: String) -> Text {
        Text(s)
            .font(.system(size: ETGraphMetrics.labelSize, design: .monospaced))
            .foregroundStyle(.secondary)
    }
}

extension GraphCanvas where Overlay == EmptyView {
    init(x: ETAxis,
         y: ETAxis,
         height: CGFloat = ETGraphMetrics.height,
         insets: ETGraphInsets = .standard,
         readout: [ETReadoutItem] = [],
         caption: String? = nil,
         badge: String? = nil,
         clipsContent: Bool = true,
         previewsFrequency: Bool = false,
         showsHeader: Bool = true,
         draw: @escaping (inout GraphicsContext, ETPlot) -> Void) {
        self.init(x: x, y: y, height: height, insets: insets, readout: readout,
                  caption: caption, badge: badge, clipsContent: clipsContent,
                  previewsFrequency: previewsFrequency, showsHeader: showsHeader, draw: draw,
                  overlay: { _ in EmptyView() })
    }
}
