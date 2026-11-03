//  SpectrumOverlayLayer.swift
//  周波数特性の図に、いま鳴っている音のスペクトラムを重ねる。
//
//  上流にも同じものが在る。ただし **PEQ のプラグインの中には無い。**
//  ホスト側の共通機能で、plugins/spectrum-overlay.js（IIFE 1 本）が
//  js/ui/pipeline/pipeline-item-builder.js:640 の
//  `window.SpectrumOverlay?.attach(plugin, ui);` で一律に取り付けられる。
//  重ねる相手は spectrum-overlay.js:17-37 の表に逐語で並んでいて、
//  そこに FiveBandPEQPlugin / FifteenBandPEQPlugin が入っている。
//
//  ■ 値の出どころが上流とこちらで違う
//  上流はテレメトリを使わない。AudioWorklet のホストループが段を 1 個ずつ呼び、
//  その**前後で処理バッファを横取り**している
//  （plugins/audio-processor.js:5142-5157 が入口、:5275-5307 が出口。
//    2048 サンプルごとに `{ type: 'spectrumOverlay', ... }` を main へ投げる）。
//  そのために融合パスまで止めている（同 :3510
//  `this.dspPipelineReady = this.spectrumTapRoute.size === 0;`）。
//
//  こちらにその口は無い。
//    - PEQ のカーネル自身は何も書き出さない
//      （dsp/plugins/eq/five_band_peq/kernel.cpp と fifteen_band_peq/kernel.cpp に
//        telemetry の綴りが 1 度も出てこない）
//    - 鎖は Sources/Shared/ETPipeline.c が et_pipeline_process を **1 回**呼び、
//      dsp/core/engine.cpp:917-990 の中で全段が回る。段と段の間は Swift から見えない
//    - dsp/include/effetune/abi.h に段の前後を覗く関数は無い
//      （あるのは et_arena_bus_ptr＝バス単位と et_instance_process＝1 段単体）
//    - dsp は submodule で書き換え禁止なので spectrumTap 相当を足す道も無い
//
//  そこで **Spectrum Analyzer を探りとして段の前後に 1 台ずつ置き、その tap を借りる。**
//  置くのは EffeTuneDSP.syncProbes で、鎖（chain）には入れず、音のスレッドへ渡す
//  descriptor にだけ足す（ETChainEditing.descriptors）。だから保存形式・プリセット・
//  共有リンクには出ず、PEQ を外すと探りも一緒に外れる。
//  Spectrum Analyzer のカーネルは音を素通しする
//  （dsp/plugins/analyzer/spectrum_analyzer/kernel.cpp:190-239 の process は
//    audio[frame] と audio[frame_count+frame] を読んで (left+right)*0.5 を ring_ へ
//    積むだけで、audio に一度も書かない）。上流のオーバーレイがやっている
//  モノラル化（audio-processor.js:5142-5157 の全チャンネル平均）と同じ。
//  鎖は engine.cpp:917 の descriptor 順に処理されるので、
//  PEQ の直前の探りが見ている音 = PEQ に入る音、直後の探り = PEQ から出た音になる。
//
//  ■ 上流と揃えてあるもの
//    - 表示は After（出口だけ）と Compare（入口と出口）。上流の MODE_AFTER / MODE_COMPARE
//      （spectrum-overlay.js:11-12）。既定は After（上流で札を最初に押したときと同じ、
//      同 :242-246）
//    - After は出口の線 1 本（同 :410、色は --et-graph-overlay-after）。
//      Compare は入口と出口の間を塗り、出口の線を上に引く（同 :406-408、線の色は
//      --et-graph-overlay-compare）。出口が上なら暖色、下ならアクセント色で塗る（同 :579）。
//      入口の線そのものは引かない。上流も塗りの縁として見せているだけ
//    - 色は effetune-theme.css:95-97 の割合（アクセント 55%、文字色 90%、警告色 55%）。
//      ETGraphShading の overlay / overlayCompare / overlayPositive
//    - FFT 4096 点（spectrum-overlay.js:2-3）。探りの Points を 12 にしてある
//      （EffeTuneDSP.probePoints）
//    - 縦は DYNAMIC_RANGE_DB = -96 を図の高さいっぱいに線形で貼る（同 :4, :452-453）。
//      **PEQ のゲイン軸（±20dB）とは別の軸。** plot.y() を使わない
//    - 横は図の対数軸をそのまま使う
//    - 1/12 オクターブで均す（ETSpectrumSmoothing）。均さないと Spectrum Analyzer の図と
//      同じギザギザになり、web と線の性格が変わる
//    - 塗り・線は曲線の**上**に重ねる（spectrum-overlay.css:13 の z-index: 2）。
//      全体に 0.85 を掛ける（同 :19 の opacity）
//    - 右端に -24 / -48 / -72 の字（spectrum-overlay.js:599-601）。"Level (dBFS)" の縦書きは
//      出さない。上流も inset のある図（PEQ は inset=20）には出していない（同 :602）
//    - After / Compare は保存しない。上流も sessionModes というメモリ上の Map だけで
//      （同 :14, :218）、プリセットにも共有リンクにも書かない。
//      こちらは ETCardSelection（アプリを終うと消える、段ごとの覚え）に持つ
//
//  ■ 上流と違うもの
//    - **Off が無い。常に重ねる**（2026-09-30 に決めた）。上流の札は
//      Off → After → Compare を回すが（同 :242-246）、こちらは After ⇄ Compare だけ
//    - 切り替えは図の面の隅ではなく、図の上の読み値の行の右端に置く。上流は図の中の隅に
//      22×22 の札を置いている（spectrum-overlay.css:53-66）が、こちらは図の面が印を
//      掴むドラッグに使われていて、その上に置くと隅の印が掴めなくなる
//    - 音が途切れたときの -4dB/フレームの減衰（spectrum-overlay.js:400-403）は入れていない。
//      Telemetry は最新の 1 枠しか持たないので、最後の枠が残ったままになる。
//      Spectrum Analyzer のカード自身も同じ振る舞いにしてある
//    - ピーク保持と Quality（Normal / HQ）は重ねない。どちらも上流では Config の全体設定で、
//      既定は切と Normal（同 :15、js/electron/configIntegration.js:45）。
//      こちらはその設定を持たないので、上流の既定と同じ見た目になる

import SwiftUI

// MARK: - 表示

/// 図に重ねるスペクトラムの出し方。綴りは上流の MODE_AFTER / MODE_COMPARE
/// （spectrum-overlay.js:11-12）。上流の MODE_OFF（同 :10）は持たない。
enum ETSpectrumOverlayMode: String {
    /// 段から出た音だけ。
    case after
    /// 段に入る音と出た音を並べる。
    case compare

    /// 札を押したときの次。上流は off → after → compare → off（spectrum-overlay.js:242-246）。
    var next: ETSpectrumOverlayMode { self == .after ? .compare : .after }

    var title: String { self == .after ? "After" : "Compare" }
}

// MARK: - 重ねる層

/// **Telemetry を見るのはここだけ**にしてある。
/// 外側で観測すると 30Hz で作り直されて、掴んでいる印や下のつまみが固まる
/// （SpectrumAnalyzerView.swift:228-229 に同じ事故の記録がある）。
struct SpectrumOverlayLayer: View {

    /// 段から出た音の tap。After でも Compare でも線を引く。
    var tapId: UInt32
    /// 段に入る音の tap。Compare のときだけ読む。nil なら After と同じに描く。
    var beforeTapId: UInt32?
    var mode: ETSpectrumOverlayMode
    /// 重ねる先の図の座標。枠と軸はこれが全部持っている。
    var plot: ETPlot
    /// spectrum-overlay.js:4 の DYNAMIC_RANGE_DB。
    var floorDB: Double

    @ETTelemetryFeed private var telemetry

    init(tapId: UInt32, beforeTapId: UInt32? = nil, mode: ETSpectrumOverlayMode = .after,
         plot: ETPlot, floorDB: Double = -96) {
        self.tapId = tapId
        self.beforeTapId = beforeTapId
        self.mode = mode
        self.plot = plot
        self.floorDB = floorDB
    }

    var body: some View {
        // 枠を解くのは 1 回だけ。Canvas の描画クロージャの中で Telemetry に触らない。
        let after = columns(tap: tapId)
        // 上流も入口の枠が無いうちは After と同じに描く（spectrum-overlay.js:406）。
        let before: [ETSpectrumColumn]? = (mode == .compare ? beforeTapId : nil)
            .flatMap { Self.paired(columns(tap: $0), with: after) }
        let rect = plot.rect
        let bottomDB = floorDB
        return Canvas { context, _ in
            context.opacity = 0.85          // spectrum-overlay.css:19 の opacity
            if after.count > 1 {
                context.drawLayer { layer in
                    layer.clip(to: Path(rect.insetBy(dx: -0.5, dy: -0.5)))
                    let line = Self.line(after, rect: rect, bottomDB: bottomDB)
                    if let before {
                        Self.fillDifference(&layer, before: before, after: after,
                                            rect: rect, bottomDB: bottomDB)
                        layer.stroke(line, with: ETGraphShading.overlayCompare,
                                     style: StrokeStyle(lineWidth: 1, lineJoin: .round))
                    } else {
                        layer.stroke(line, with: ETGraphShading.overlay,
                                     style: StrokeStyle(lineWidth: 1, lineJoin: .round))
                    }
                }
            }
            // 目盛りは枠が来ていなくても出す（spectrum-overlay.js:395-397）。
            // 右の字が dBFS で、左の dB（ゲイン）と別物だと分かるように。
            var level = -24.0
            while level > bottomDB {
                context.draw(Self.levelText("\(Int(level))"),
                             at: CGPoint(x: rect.maxX - 3,
                                         y: Self.y(level, in: rect, bottomDB: bottomDB)),
                             anchor: .trailing)
                level -= 24
            }
        }
        .allowsHitTesting(false)
    }

    /// 縦は -96dB を図の高さいっぱいに線形で貼る（spectrum-overlay.js:453
    /// `const y = height * level / DYNAMIC_RANGE_DB;`）。
    /// **plot.y() を使わない。** あちらは PEQ のゲイン軸（±20dB）で、これとは別の軸。
    private static func y(_ db: Double, in rect: CGRect, bottomDB: Double) -> CGFloat {
        guard bottomDB < 0 else { return rect.maxY }
        let level = min(db, 0)              // spectrum-overlay.js:452
        let t = min(max(level / bottomDB, 0), 1)
        return rect.minY + rect.height * CGFloat(t)
    }

    private static func line(_ columns: [ETSpectrumColumn], rect: CGRect,
                             bottomDB: Double) -> Path {
        var path = Path()
        for (i, column) in columns.enumerated() {
            let pt = CGPoint(x: column.x, y: y(column.db, in: rect, bottomDB: bottomDB))
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        return path
    }

    /// 入口の列を出口の列に揃える。揃わなければ nil（Compare の塗りをやめて After で描く）。
    ///
    /// 2 台の探りは同じ設定で作るので、bin の数と間隔が同じなら 1pt ごとの畳み方
    /// （ETSpectrumReading.columns）も同じ位置で区切られ、列の数が一致する。
    /// 片方の枠がまだ来ていない・レートが変わった直後などで食い違う回は、
    /// 塗りを捨てる（ずれた列どうしで引くと嘘の差が出る）。
    private static func paired(_ before: [ETSpectrumColumn],
                               with after: [ETSpectrumColumn]) -> [ETSpectrumColumn]? {
        before.count == after.count && before.count > 1 ? before : nil
    }

    /// 入口と出口の間を塗る。spectrum-overlay.js:476-583 の `_drawDifference` と
    /// `_fillDifferenceRegion` の写し。
    ///
    /// 差（出口 − 入口）の符号が同じ区間ごとに、出口の線を行きに、入口の線を帰りに
    /// なぞって閉じる。符号が変わる所は出口の線の上で交点を内挿して、隣の区間と縁を
    /// 共有させる（同 :538-555）。出口が上（差が正）なら暖色、下ならアクセント色（同 :579）。
    /// 区間どうしは重ならないので、色ごとに 1 本の Path にまとめて塗る。
    private static func fillDifference(_ context: inout GraphicsContext,
                                       before: [ETSpectrumColumn], after: [ETSpectrumColumn],
                                       rect: CGRect, bottomDB: Double) {
        let count = min(before.count, after.count)
        guard count > 1 else { return }
        // 横は出口の列の位置に揃える（線を引くのも出口の列）。
        // 差は描く位置で取る。上流も 0 dB で頭を切った値どうしで引く（同 :498-499）。
        // こちらは -96 の下も図の底に貼り付くので、そこも揃う。
        let xs = after.prefix(count).map { $0.x }
        let afterY = after.prefix(count).map { y($0.db, in: rect, bottomDB: bottomDB) }
        let beforeY = before.prefix(count).map { y($0.db, in: rect, bottomDB: bottomDB) }
        // y は下向きに増えるので、出口が上 = afterY が小さい = 差が正。
        let difference = (0..<count).map { Double(beforeY[$0] - afterY[$0]) }

        var positive = Path()
        var negative = Path()
        func sign(_ v: Double) -> Int { v > 0 ? 1 : (v < 0 ? -1 : 0) }
        func region(_ start: Int, _ end: Int, sign: Int, from: CGPoint?, to: CGPoint?) {
            var path = Path()
            path.move(to: from ?? CGPoint(x: xs[start], y: afterY[start]))
            for i in start...end { path.addLine(to: CGPoint(x: xs[i], y: afterY[i])) }
            if let to { path.addLine(to: to) }
            for i in stride(from: end, through: start, by: -1) {
                path.addLine(to: CGPoint(x: xs[i], y: beforeY[i]))
            }
            if let from { path.addLine(to: from) }
            path.closeSubpath()
            if sign > 0 { positive.addPath(path) } else { negative.addPath(path) }
        }

        var regionStart = 0
        var regionSign = sign(difference[0])
        var startCross: CGPoint?
        for i in 1..<count {
            let s = sign(difference[i])
            if s == 0 { continue }
            if regionSign == 0 {
                regionSign = s
                continue
            }
            if s == regionSign { continue }
            let previous = i - 1
            let previousValue = difference[previous]
            let fraction = previousValue == 0
                ? 0.0 : previousValue / (previousValue - difference[i])
            let cross = CGPoint(
                x: xs[previous] + (xs[i] - xs[previous]) * CGFloat(fraction),
                y: afterY[previous] + (afterY[i] - afterY[previous]) * CGFloat(fraction))
            region(regionStart, previous, sign: regionSign, from: startCross, to: cross)
            regionStart = i
            regionSign = s
            startCross = cross
        }
        if regionSign != 0 {
            region(regionStart, count - 1, sign: regionSign, from: startCross, to: nil)
        }
        context.fill(positive, with: ETGraphShading.overlayPositive)
        context.fill(negative, with: ETGraphShading.overlay)
    }

    private static func levelText(_ s: String) -> Text {
        Text(s)
            .font(.system(size: ETGraphMetrics.labelSize, design: .monospaced))
            .foregroundStyle(AnyShapeStyle(.tint).opacity(0.8))
    }

    /// 最新の枠を 1/12 オクターブで均し（HQ の枠は均さない）、1pt ごとに畳んだ列。
    private func columns(tap: UInt32) -> [ETSpectrumColumn] {
        guard plot.xAxis.upper > plot.xAxis.lower,
              let reading = ETSpectrumReading(frame: telemetry.frame(tap: tap, type: .spectrum)),
              reading.hzPerBin > 0 else { return [] }
        return reading.columns(reading.overlayCurrent, plot: plot, floor: floorDB,
                               range: plot.xAxis.lower...plot.xAxis.upper)
    }
}

// MARK: - 切り替え

/// After ⇄ Compare の札。図の上の読み値の行の右端に出る（GraphCanvas.accessory）。
///
/// 上流は図の中の隅に 22×22 の札を置いている（spectrum-overlay.css:53-66）が、
/// こちらは図の面が印を掴むドラッグに使われていて、その上にボタンを置くと
/// 隅の印が掴めなくなる。だから図の面の外に出す。
struct SpectrumOverlayToggle: View {

    @Binding var mode: ETSpectrumOverlayMode
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Button {
            mode = mode.next
        } label: {
            Text(mode.title)
                // 札は伸ばさない（読み値の行に収める）。Large Content Viewer で長押しして読める。
                .font(.system(size: 10, weight: .semibold))
                // 「コントラストを上げる」のときだけ、字を .tint でなく本文の色にする
                // （.tint の字を薄い地に載せると小さい字では足りない）。
                .foregroundStyle(contrast == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: .capsule)
                // 当たり判定だけを 44pt まで広げる。見た目と行の高さは変えないので、
                // 広げた分（上下 14pt・左右 4pt）を負の余白で打ち消す。
                .padding(.vertical, 14)
                .padding(.horizontal, 4)
                .contentShape(.rect)
                .padding(.vertical, -14)
                .padding(.horizontal, -4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Spectrum overlay")
        .accessibilityValue(mode.title)
        .accessibilityShowsLargeContentViewer()
    }
}
