//  LiveStatusStrip.swift
//  鎖の帯に出す、いまの遅れと負荷。
//
//  **ここだけが io を観測する。**
//  PipelineView 全体で観測すると tick() の 3.3Hz で body ごと作り直され、
//  ツールバーの Menu が UIDeferredMenuElement の「読み込み中」のまま固まる。
//  実機でそれを踏んだので、観測はこの小さなビューに閉じ込めてある。
//
//  **数字だけを並べるのをやめて、上流と同じく語を付けた。**
//  上流は右下の #pipelineStats に 2 つだけ出している（行は固定した e200e515 のもの）。
//
//    effetune.html:325   <span id="pipelineCpuValue">CPU: Avg 0.0%</span>
//    effetune.html:327   <div id="pipelineLatency">Total Delay: 0 samples</div>
//    js/locales/en.json5:73  "ui.pipelineLatency": "Total Delay: {samples} samples"
//    js/locales/en.json5:74  "ui.pipelineCpuUsage": "CPU: Avg {average}%"
//
//  出しているのは「遅れ」と「CPU」の 2 つで、レートはここに無い。
//  レートは鳴っている間ずっと同じ値で、live の代金ではなく設定の読み返しなので、
//  こちらでも帯から外した。SettingsView の Picker が "Sample Rate" の名前で
//  同じ値を出しているので、読める場所は残っている。
//
//  **単位の語と桁**
//  上流は遅れを samples、CPU を小数 1 桁で出している。こちらは ms と整数にした。
//   - samples ではなく ms。ここに出るのは鎖の遅れではなく、
//     link とブロックと FIR を足した「耳に届くまでの遅れ」で、
//     数えるものではなく待つ時間だから。samples は Status に出してある。
//   - 小数を落としたのは、上流の更新が 1 秒に 1 回（plugins/audio-processor.js の
//     finishPipelineCpuMeasurement が 1 秒ぶん貯めてから post する。e200e515 で 4828 行）
//     なのに対し、こちらの tick() は 3.3Hz で、小数 1 桁を出すと末尾がバーの中で常に踊るため。
//
//  **色の閾値は上流を写した。**
//    js/ui-manager.js:426-428  updatePipelineCpuUsage。100 以上なら overload、75 以上なら high、ほかは normal
//    effetune.css:694,698      high は --et-warning、overload は --et-danger
//  上流が塗るのはメーターの棒で、文字の色は変えない。こちらは棒を置く幅が無いので
//  （下の枠の話）、同じ閾値で数字そのものを .orange / .red にする。
//  色は新しく作らず、この app が既に使っている semantic color を使う
//  （警告の行は StatusView が .orange、EffectCardView の枠が .green）。
//
//  **枠**
//  ここは ToolbarItem(placement: .principal)＝ナビゲーションバーの中央で、
//  中央に置かれる以上、使える幅は「バーの中心から、右のボタン群の内側の端まで」の
//  2 倍しかない。左がどれだけ空いていても、そちらへは伸びない。
//
//    iPhone 16/17（幅 393pt、中心 x=196.5）
//      左 = 余白 16 + 電源トグル 44          → 空きの左端 x=60
//      右 = ボタン 3 つ（1 つ 38-44pt）+ 余白 16 → 空きの右端 x≈245-263
//      中央に置けるのは 2×(245-196.5)=97pt、ボタンが太ければそれ以下。
//
//  高さも効く。Info.plist が横向きを許しているので、横持ちの iPhone では
//  バーが 44pt ではなく 32pt になる。10pt の行は行送り約 12pt なので、
//  3 行（約 36pt）は横持ちで欠ける。**2 行までしか置けない。**
//  2 行しか置けない以上、語を付けられるのは 2 つまでで、
//  上流が右下に出している 2 つ（遅れと CPU）がそれに当たる。
//
//  幅は 32+4+38=74pt で、直す前と同じ。枠に入ることは実機で確かめてある形。
//
//  **数字と丸めは Settings と同じもの（ETStripReading、StatusReadings.swift）。**
//  以前はここで I/O と Fx を別々に丸め、CPU を %.0f で出していたので、
//  Settings の Total delay・CPU と 1 ms / 1 % 食い違うことがあった。
//  I/O＋Fx は Settings の Total delay と必ず同じになる。ここには見た目だけを置く。

import SwiftUI

struct LiveStatusStrip: View {
    @ObservedObject var io: AudioIO

    /// 出している面。**タップで入れ替える。**
    ///
    /// 幅は増やせない（ToolbarItem(placement: .principal) は中心から
    /// 右のボタン群の内側までの 2 倍しか使えず、iPhone 16 で 97pt 前後）。
    /// 4 つ全部を並べると入らないので、2 つずつ 2 面に分けて切り替える。
    /// 選んだ面は覚える。毎回同じものを見たい人のほうが多い。
    private enum Face: String {
        /// 遅れの内訳。鎖が足すぶんと、それ以外（リンク・ブロック・変換）。
        case delay
        /// 負荷と、いま回っているレート。
        case load

        var next: Face { self == .delay ? .load : .delay }
    }
    @AppStorage("strip.face") private var faceRaw = Face.delay.rawValue
    private var face: Face { Face(rawValue: faceRaw) ?? .delay }

    /// 「色の区別なし」の設定のときだけ、警告の行の頭に三角を付ける。
    /// 通常の見た目は変えない。幅は三角の欄ぶん（9pt＋隙間）だけ広げる。
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    /// 欄の幅。**桁で揺れないよう固定する。**
    /// 桁が変わるたびに動くと、隣のものまで揺れて読めない。
    ///
    /// 10pt の SF Mono は 1 文字の送りが 0.6em＝6.0pt、これに 10pt の
    /// トラッキング（およそ +0.12pt/文字）が乗る。つまり 1 文字 6.11pt。
    private enum Cell {
        /// 長いほうの語 "Rate" = 4 文字 → 24.4pt
        static let label: CGFloat = 26
        /// 出うる一番長い値 "151 ms" = 6 文字 → 36.7pt。
        /// 151 は、端末が 16kHz に落ちたとき（link 2048 frames で 128ms）の目安。
        /// "100%" も "idle" も 4 文字なので、これで足りる。
        static let value: CGFloat = 38
        static let gap: CGFloat = 4
        /// 帯そのものの幅。上下の行で揃えるので、中身が変わっても動かない。
        static var total: CGFloat { label + gap + value }
    }

    /// 鎖に入っている値ぜんぶの指紋。**プリセットの中身が届いたかを見るため。**
    ///
    /// 既定のままなら既定の和になる。プリセットを読んで値が入れば変わる。
    /// 「プリセットを選んでも中身が載っていない」を、画面の字ではなく
    /// 鎖が持っている数そのもので確かめられる。
    @MainActor
    enum ETDiagFingerprint {
        static var chainSum: Int {
            let total = EffeTuneDSP.shared.chain.reduce(Float(0)) { acc, node in
                acc + node.values.reduce(0, +)
            }
            return Int(total.rounded())
        }
    }

    /// 測るためだけの行。`-ETDiag 1` のときだけ読み上げの木に出す。
    ///
    /// 画面には出さない（幅 0・透明）。UI テストから
    /// `app.staticTexts["diag"].label` で読む。
    /// 出すのは configure が反映した結果（ETPipeline_ActiveNodes）と、
    /// UI が持っている鎖の長さ。**この 2 つがずれていたら
    /// descriptor が拾われていない**——足しても効かない状態そのもの。
    @ViewBuilder private var diag: some View {
        if UserDefaults.standard.string(forKey: "ETDiag") != nil {
            Text("active=\(ETPipeline_ActiveNodes()) chain=\(EffeTuneDSP.shared.chain.count) cfg=\(ETPipeline_LastStatus()) sum=\(ETDiagFingerprint.chainSum)")
                .accessibilityIdentifier("diag")
                .frame(width: 0, height: 0)
                .opacity(0)
                .allowsHitTesting(false)
        }
    }

    var body: some View {
        if io.running {
            // **読むのは 1 回。**同じ瞬間の値から 4 つの数字と読み上げを作る。
            strip(ETStripReading(ETAudioSnapshot(io: io, dsp: .shared)))
        }
    }

    private func strip(_ r: ETStripReading) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            diag
            switch face {
            case .delay:
                // リンク（2048 標本の固定）＋ iOS のブロック
                // ＋ オーバーサンプリングの FIR。設定で決まり、鎖では動かない。
                // **上に置く。** 設定で動かせるのはこちらなので先に読ませる。
                row("I/O", r.ioText, tint: AnyShapeStyle(.secondary))
                // **鎖が足す遅れ。** et_pipeline_latency の値で、
                // FIR を持つエフェクト（Phase Select EQ など）を入れると増える。
                // ここを出していなかったので、そういうものを入れても
                // 数字が動かなかった。I/O と足すと Settings の Total delay。
                row("Fx", r.fxText, tint: AnyShapeStyle(.secondary))
            case .load:
                // 上流の CPU と同じ量（経過時間 ÷ 音の長さ、plugins/audio-processor.js の
                // finishPipelineCpuMeasurement、e200e515 で 4830–4833 行）で、語も上流に合わせてある。
                row("CPU", r.loadText, tint: loadTint(r.loadLevel),
                    warns: r.loadLevel == .high || r.loadLevel == .over)
                // 効果を回しているレート（入口 × オーバーサンプリング倍率）。
                // 入口が 48 kHz から外れているときだけ色を付ける。
                // 速さと音程がずれている状態なので、黙って出すと気づけない。
                row("Rate", r.rate,
                    tint: r.rateIsOff ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary),
                    warns: r.rateIsOff)
            }
        }
        // **押せる。** 帯そのものが切り替えの口。
        // 44pt を確保するため上下に余白を足す（見た目は変わらない）。
        .padding(.vertical, 9)
        .contentShape(.rect)
        .onTapGesture { faceRaw = face.next.rawValue }
        .padding(.vertical, -9)
        // ナビゲーションバーは伸ばせないので、字は固定のまま
        // （文字サイズに追従させると枠から溢れる）。代わりに長押しの Large Content Viewer を出す。
        .font(.system(size: 10, design: .monospaced))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(1)
        // 桁が 1 つ増えたとき（通話でハードウェアのレートが落ちると
        // 遅れが 3 桁になる）に、数字を「…」で落とさないための保険。
        // 切るより縮めるほうがまだ読める。普段は等倍のまま。
        .minimumScaleFactor(0.8)
        .accessibilityElement(children: .combine)
        // 読み上げでは略さない。"%" や "ms" をそのまま読ませると意味が通らない。
        .accessibilityLabel(face == .delay ? r.delayVoice : r.loadVoice)
        .accessibilityHint("Shows " + (face == .delay ? "CPU and sample rate" : "the delay"))
        .accessibilityAddTraits(.isButton)
        .accessibilityShowsLargeContentViewer {
            Label(face == .delay ? r.delayVoice : r.loadVoice, systemImage: "gauge")
        }
    }

    /// 三角の欄の幅。
    private static let flagWidth: CGFloat = 9

    /// 語を左、値を右。上下の行で列が揃うように、どちらも幅を固定する。
    /// `warns` は色だけで伝えていた「ずれている・重い」の印。三角は色の区別なしの設定のときだけ出す。
    /// 欄は両方の行に置いて（警告が無い行は透明）、列を揃える。
    private func row(_ label: String, _ value: String, tint: AnyShapeStyle,
                     warns: Bool = false) -> some View {
        HStack(spacing: Cell.gap) {
            if differentiateWithoutColor {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(tint)
                    .opacity(warns ? 1 : 0)
                    .frame(width: Self.flagWidth)
                    .accessibilityHidden(true)
            }
            Text(label)
                .frame(width: Cell.label, alignment: .leading)
            Text(value)
                .frame(width: Cell.value, alignment: .trailing)
                .foregroundStyle(tint)
        }
        .frame(width: Cell.total + (differentiateWithoutColor ? Self.flagWidth + Cell.gap : 0),
               alignment: .leading)
    }

    // MARK: - CPU の色

    /// 閾値は ETLoadReading（上流の data-level と同じ、js/ui-manager.js の
    /// updatePipelineCpuUsage、e200e515 で 426–428 行）。
    /// 休んでいるあいだは nil で、たまたま 75 を跨いだ古い値で色を付けない。
    /// Settings の CPU 行は normal を .primary にしている（あちらは List の中）。
    private func loadTint(_ level: ETLoadReading.Level?) -> AnyShapeStyle {
        switch level {
        case .over?: return AnyShapeStyle(.red)
        case .high?: return AnyShapeStyle(.orange)
        case .normal?, nil: return AnyShapeStyle(.secondary)
        }
    }
}
