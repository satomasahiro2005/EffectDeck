//  LiveStatusStrip.swift
//  鎖の帯に出す、いまの処理レートと遅れと負荷。
//
//  **ここだけが io を観測する。**
//  PipelineView 全体で観測すると tick() の 3.3Hz で body ごと作り直され、
//  ツールバーの Menu が UIDeferredMenuElement の「読み込み中」のまま固まる。
//  実機でそれを踏んだので、観測はこの小さなビューに閉じ込めてある。
//
//  **3 つを 1 行に並べるのをやめて 2 行にした。**
//  ここは ToolbarItem(placement: .principal)＝ナビゲーションバーの中央で、
//  中央に置かれる以上、使える幅は「バーの中心から、右のボタン群の内側の端まで」の
//  2 倍しかない。左がどれだけ空いていても、そちらへは伸びない。
//
//    iPhone 16/17（幅 393pt、中心 x=196.5）
//      左 = 余白 16 + 電源トグル 44          → 空きの左端 x=60
//      右 = ボタン 3 つ（1 つ 38-44pt）+ 余白 16 → 空きの右端 x≈245-263
//      中央に置けるのは 2×(245-196.5)=97pt、ボタンが太ければそれ以下。
//
//  1 行に並べた形は 46+62+32 に隙間 8×2 で 156pt あり、この枠の 1.5 倍以上ある。
//  入らないぶんはバーに潰されるか右のボタンに重なるので、実機では欠けて見える。
//  2 行にすると 74pt で、狭く見積もった枠にも収まる。
//  高さは 10pt の行が 2 つでおよそ 25pt、inline のバーの 44pt に入る。

import SwiftUI

struct LiveStatusStrip: View {
    @ObservedObject var io: AudioIO

    /// 欄の幅。**桁で揺れないよう固定する。**
    /// 桁が変わるたびに動くと、隣のものまで揺れて読めない。
    ///
    /// 10pt の SF Mono は 1 文字の送りが 0.6em＝6.0pt、これに 10pt の
    /// トラッキング（およそ +0.12pt/文字）が乗る。つまり 7 文字で 42.8pt。
    /// 各欄は「出うる一番長い文字列＋1pt 強」にしてある。
    /// 余らせると trailing 揃えのぶんが左の隙間になって、隣との間が開いて見える
    /// （直す前の遅れの欄は 62pt に 7 文字＝42.8pt で、20pt が隙間になっていた）。
    private enum Cell {
        /// "43+23ms" = 7 文字 → 42.8pt
        static let latency: CGFloat = 44
        /// "idle" / "100%" = 4 文字 → 24.5pt
        static let load: CGFloat = 26
        static let gap: CGFloat = 4
        /// 帯そのものの幅。上下の行で揃えるので、中身が変わっても動かない。
        static var total: CGFloat { latency + gap + load }
    }

    var body: some View {
        if io.running {
            VStack(spacing: 1) {
                // 上の行は、いまどのレートで処理しているか。
                // 一番長い "192 kHz" でも 7 文字＝42.8pt で、下の行の 74pt に余る。
                // 幅は下の行に合わせて固定し、中身だけ中央に置く。
                Text(rate)
                    .frame(width: Cell.total, alignment: .center)
                // 下の行は、そのために払っている代金。
                HStack(spacing: Cell.gap) {
                    // link + dsp。足すと出るまでの遅れ。
                    // どちらが増えたのかが分かるように足し算のまま出す。
                    Text("\(linkMs)+\(dspMs)ms")
                        .frame(width: Cell.latency, alignment: .trailing)
                    Text(load)
                        .frame(width: Cell.load, alignment: .trailing)
                        .foregroundStyle(io.load > 0.8 ? AnyShapeStyle(.red)
                                                       : AnyShapeStyle(.secondary))
                }
                .frame(width: Cell.total, alignment: .trailing)
            }
            .font(.system(size: 10, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            // 桁が 1 つ増えたとき（通話でハードウェアのレートが落ちると
            // link が 3 桁になる）に、数字を「…」で落とさないための保険。
            // 切るより縮めるほうがまだ読める。普段は等倍のまま。
            .minimumScaleFactor(0.8)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "Processing \(rateKHz) kilohertz, link latency \(linkMs) milliseconds, "
                + "DSP latency \(dspMs) milliseconds, load \(load)")
        }
    }

    /// 処理レート。ハードウェアのレート×オーバーサンプリング倍率なので、
    /// 44.1k 系だと 176400 のような値になる。
    /// 切り捨てではなく丸める。ハードウェアが 47999.9 を返したときに
    /// "47 kHz" と出るのを避けるため。
    private var rateKHz: Int {
        Int((io.processingRate / 1000).rounded())
    }

    /// 単位は略さない。"192k" ではなく "192 kHz"。
    private var rate: String { "\(rateKHz) kHz" }

    /// 2 つのアプリのあいだ。再同期でここへ置き直すので設計上の定数。
    /// 瞬間の溜まり（bufferedFrames）は払うたびに動いて読めないので使わない。
    /// 実際の溜まりは Status に出してある。
    /// LocalLink.m の +targetFrames は 2048 固定なので、48kHz で 43ms。
    private var linkMs: String {
        ms(Double(ETLinkReceiver.targetFrames))
    }

    /// このアプリの中。1 ブロックと、オーバーサンプリングの FIR。
    /// どちらも設定で決まる値で、鳴っている間は変わらない。
    /// blockFrames は 0.005/0.010/0.023 秒（Preferences の ETLatency）、
    /// resamplerLatency は 0 か 32（ETResample.c の TAPS_PER_PHASE）なので、
    /// 48kHz では 5ms から 24ms のあいだ。
    private var dspMs: String {
        ms(Double(io.blockFrames) + Double(io.resamplerLatency))
    }

    /// sampleRate は start() で `session.sampleRate > 0 ? ... : 48000` としか
    /// 書かれないので 0 にも nan にもならないが、ここでも 0 を避けておく。
    /// frames 側は Int 由来なので、"nan" や "inf" が出る経路は無い。
    private func ms(_ frames: Double) -> String {
        let sr = io.sampleRate > 0 ? io.sampleRate : 48000
        return String(format: "%.0f", frames / sr * 1000)
    }

    /// 1 ブロックに使える時間のうち、どれだけ使ったか。
    /// 休んでいるときは数字を出さない（0% と紛らわしいため）。
    private var load: String {
        io.resting ? "idle" : String(format: "%.0f%%", io.load * 100)
    }
}
