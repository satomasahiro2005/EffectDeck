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
//  そこで **隣に置かれた Spectrum Analyzer を tap として借りる。**
//  Spectrum Analyzer のカーネルは音を素通しする
//  （dsp/plugins/analyzer/spectrum_analyzer/kernel.cpp:173-209 の process は
//    audio[frame] と audio[frame_count+frame] を読んで (left+right)*0.5 を ring_ へ
//    積むだけで、audio に一度も書かない）。上流のオーバーレイがやっている
//  モノラル化（audio-processor.js:5142-5157 の全チャンネル平均）と同じ。
//  鎖は engine.cpp:917 の descriptor 順に処理されるので、
//  PEQ の直前の段が見ている音 = PEQ に入る音になる。
//
//  **裏で analyzer を挿さない。** DSP/PipelineStore.swift:38-48 は chain をそのまま
//  保存形式へ落とすので、挿した段が共有リンクとプリセットに混ざり、web 版へ
//  持っていくと上流に無い段が 1 本生える。人が置いた analyzer が隣に居るときだけ重ねる。
//
//  ■ 上流と揃えてあるもの
//    - 縦は DYNAMIC_RANGE_DB = -96 を図の高さいっぱいに線形で貼る（同 :4, :404-405）。
//      **PEQ のゲイン軸（±20dB）とは別の軸。** plot.y() を使わない
//    - 横は図の対数軸をそのまま使う
//    - 1/12 オクターブで均す（ETSpectrumSmoothing）。均さないと Spectrum Analyzer の図と
//      同じギザギザになり、web と線の性格が変わる。**借りた analyzer が HQ（対数セル）の
//      ときは均さない。**上流の Quality = HQ も analyzer のセルをそのまま描く
//      （v2.11.0 の spectrum-overlay.js:372-375）
//    - 塗りではなく線。曲線の**上**に重ねる（spectrum-overlay.css:15 の z-index: 2）
//    - 右端に -24 / -48 / -72 の字（同 :548-551）。"Level (dBFS)" の縦書きは出さない。
//      上流も inset のある図（PEQ は inset=20）には出していない（同 :552）
//    - 入切は保存しない。上流も sessionModes というメモリ上の Map だけで
//      （同 :14）、プリセットにも共有リンクにも書かない
//
//  ■ 上流と違うもの
//    - 上流は off → after → compare の 3 状態。こちらは analyzer 1 台ぶんしか
//      見えないので入切の 2 状態。既定は「入口側」（どの帯域を触るか決めるのに
//      要るのは PEQ に入る音なので）で、入口に居なければ出口側を使う
//    - FFT の大きさは上流が 4096 固定（同 :2-3）、こちらは analyzer の Points 次第
//      （256〜16384）。Points の既定が 12 = 4096 なので既定では一致する
//    - 音が途切れたときの -4dB/フレームの減衰（同 :384-390）は入れていない。
//      Telemetry は最新の 1 枠しか持たないので、最後の枠が残ったままになる。
//      Spectrum Analyzer のカード自身も同じ振る舞いにしてある
//    - ピーク保持は重ねない。上流は v2.11.0 で Peak Hold（20 dB/秒で落とす）を足したが、
//      Config の全体設定で既定は切（spectrum-overlay.js:15、:362-368、
//      js/electron/configIntegration.js:45）。こちらはその設定を持たないので、
//      上流の既定と同じ見た目になる
//    - 上流の Quality（Normal / HQ）も全体設定。こちらは借りた analyzer の
//      Frequency Scale がそのまま効く（Log (HQ) なら HQ の枠が来る）

import SwiftUI

// MARK: - どの段から借りるか

/// 図に重ねる音の出どころ。
struct ETSpectrumOverlaySource {

    enum Side {
        /// PEQ に入る音（前の段の Spectrum Analyzer）。
        case input
        /// PEQ から出た音（後ろの段の Spectrum Analyzer）。
        case output
    }

    var tapId: UInt32
    var side: Side

    /// 図の見出しに出す字。どちらを見ているか取り違えると嘘になるので必ず出す。
    var caption: String {
        switch side {
        case .input:  return "Spectrum · input to this effect"
        case .output: return "Spectrum · output of this effect"
        }
    }
}

enum ETSpectrumOverlayFinder {

    /// Generated/EffectCatalog.swift:65 の type。
    static let analyzerType = "SpectrumAnalyzerPlugin"

    /// index の段の隣に居る Spectrum Analyzer を探す。居なければ nil。
    ///
    /// 入口側を先に見る。PEQ で「どの帯域を触るか」を決めるのに要るのは
    /// PEQ に入る音だから。上流の既定は after（出力）なので、そこだけ替えてある。
    static func source(in chain: [EffeTuneDSP.Node], at index: Int) -> ETSpectrumOverlaySource? {
        guard chain.indices.contains(index) else { return nil }
        let subject = chain[index]
        // バスを分けている段は、engine.cpp:978-990 が出口で足し込む＝他の音と混ざる。
        // その混ざったものを「この段の入出力」とは呼べないので、
        // 入口と出口が同じバスのときだけ重ねる。
        guard subject.inputBus == subject.outputBus else { return nil }

        if let tap = neighbour(in: chain, from: index, step: -1, like: subject) {
            return ETSpectrumOverlaySource(tapId: tap, side: .input)
        }
        if let tap = neighbour(in: chain, from: index, step: +1, like: subject) {
            return ETSpectrumOverlaySource(tapId: tap, side: .output)
        }
        return nil
    }

    /// step の向きへ 1 歩ずつ。**音を通す最初の段**だけを見る。
    ///
    /// engine.cpp:919 が飛ばす段（enabled == 0 か sectionGate == 0）は音を触らないので、
    /// 間に挟まっていても PEQ が受け渡す音は変わらない。飛ばして次を見る。
    /// instance == 0 の段も descriptor に入らない（EffeTuneDSP.swift:716 の filter）。
    /// Section はカーネルを持たないので必ずこちらに落ちる。
    private static func neighbour(in chain: [EffeTuneDSP.Node], from index: Int, step: Int,
                                  like subject: EffeTuneDSP.Node) -> UInt32? {
        var i = index + step
        while chain.indices.contains(i) {
            let node = chain[i]
            if node.instance == 0 || !node.enabled || node.sectionGate == 0 {
                i += step
                continue
            }
            // 音を通す最初の段が analyzer でなければ、隣には居ない。
            guard node.spec.type == analyzerType else { return nil }
            // set_tap に失敗した段は 0 のまま＝枠が tap 0 に出る（EffeTuneDSP.swift:641-645）。
            guard node.tapId != 0 else { return nil }
            // 違うバス・違うチャンネルに居る analyzer は、この段の音を見ていない。
            // channelSpec は engine.cpp:955-964 が切り出す先を決める値で、
            // -1 = Stereo、-2 = All、0..15 = 1 本、16 以上 = 組。
            guard node.inputBus == subject.inputBus,
                  node.inputBus == node.outputBus,
                  node.channelSpec == subject.channelSpec else { return nil }
            return node.tapId
        }
        return nil
    }
}

// MARK: - 重ねる層

/// **Telemetry を見るのはここだけ**にしてある。
/// 外側で観測すると 30Hz で作り直されて、掴んでいる印や下のつまみが固まる
/// （SpectrumAnalyzerView.swift:228-229 に同じ事故の記録がある）。
struct SpectrumOverlayLayer: View {

    var tapId: UInt32
    /// 重ねる先の図の座標。枠と軸はこれが全部持っている。
    var plot: ETPlot
    /// spectrum-overlay.js:4 の DYNAMIC_RANGE_DB。
    var floorDB: Double

    @ObservedObject private var telemetry = Telemetry.shared

    init(tapId: UInt32, plot: ETPlot, floorDB: Double = -96) {
        self.tapId = tapId
        self.plot = plot
        self.floorDB = floorDB
    }

    var body: some View {
        // 枠を解くのは 1 回だけ。Canvas の描画クロージャの中で Telemetry に触らない。
        let columns = self.columns
        let rect = plot.rect
        let bottomDB = floorDB
        return Canvas { context, _ in
            context.opacity = 0.85          // spectrum-overlay.css:16 の opacity
            if columns.count > 1 {
                context.drawLayer { layer in
                    layer.clip(to: Path(rect.insetBy(dx: -0.5, dy: -0.5)))
                    var path = Path()
                    for (i, column) in columns.enumerated() {
                        let pt = CGPoint(x: column.x,
                                         y: Self.y(column.db, in: rect, bottomDB: bottomDB))
                        if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                    }
                    layer.stroke(path, with: ETGraphShading.overlay,
                                 style: StrokeStyle(lineWidth: 1, lineJoin: .round))
                }
            }
            // 目盛りは枠が来ていなくても出す（spectrum-overlay.js:366-369）。
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

    /// 縦は -96dB を図の高さいっぱいに線形で貼る（spectrum-overlay.js:405
    /// `const y = height * level / DYNAMIC_RANGE_DB;`）。
    /// **plot.y() を使わない。** あちらは PEQ のゲイン軸（±20dB）で、これとは別の軸。
    private static func y(_ db: Double, in rect: CGRect, bottomDB: Double) -> CGFloat {
        guard bottomDB < 0 else { return rect.maxY }
        let level = min(db, 0)              // spectrum-overlay.js:404
        let t = min(max(level / bottomDB, 0), 1)
        return rect.minY + rect.height * CGFloat(t)
    }

    private static func levelText(_ s: String) -> Text {
        Text(s)
            .font(.system(size: ETGraphMetrics.labelSize, design: .monospaced))
            .foregroundStyle(AnyShapeStyle(.tint).opacity(0.8))
    }

    /// 最新の枠を 1/12 オクターブで均し（HQ の枠は均さない）、1pt ごとに畳んだ列。
    private var columns: [ETSpectrumColumn] {
        guard plot.xAxis.upper > plot.xAxis.lower,
              let reading = ETSpectrumReading(frame: telemetry.frame(tap: tapId, type: .spectrum)),
              reading.hzPerBin > 0 else { return [] }
        return reading.columns(reading.overlayCurrent, plot: plot, floor: floorDB,
                               range: plot.xAxis.lower...plot.xAxis.upper)
    }
}

// MARK: - 入切

/// 図に重ねるスペクトラムの入切。
///
/// 上流は図の中の隅に 22×22 の札を置いている（spectrum-overlay.css:53-66。
/// PEQ は右上、15Band PEQ は右下）が、こちらは図の面が印を掴むドラッグに使われていて、
/// その上にボタンを置くと右上の印が掴めなくなる。だから図の外の行に出す。
struct SpectrumOverlayToggle: View {

    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Image(systemName: "waveform")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 30, height: 30)
                .background(isOn ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.clear),
                            in: .rect(cornerRadius: ETMetrics.innerRadius, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Spectrum overlay")
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}
