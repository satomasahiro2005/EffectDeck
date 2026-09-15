//  LiveStatusStrip.swift
//  鎖の帯に出す、いまの遅れと負荷。
//
//  **ここだけが io を観測する。**
//  PipelineView 全体で観測すると tick() の 3.3Hz で body ごと作り直され、
//  ツールバーの Menu が UIDeferredMenuElement の「読み込み中」のまま固まる。
//  実機でそれを踏んだので、観測はこの小さなビューに閉じ込めてある。

import SwiftUI

struct LiveStatusStrip: View {
    @ObservedObject var io: AudioIO

    var body: some View {
        if io.running {
            HStack(spacing: 8) {
                Text("\(Int(io.processingRate / 1000))k")
                    .frame(width: 26, alignment: .trailing)
                // link + dsp。足すと出るまでの遅れ。
                // どちらが増えたのかが分かるように足し算のまま出す。
                Text("\(linkMs)+\(dspMs)ms")
                    .frame(width: 62, alignment: .trailing)
                Text(load)
                    .frame(width: 32, alignment: .trailing)
                    .foregroundStyle(io.load > 0.8 ? AnyShapeStyle(.red)
                                                   : AnyShapeStyle(.secondary))
            }
            // **幅を固定する。**
            // 桁が変わるたびに動くと、隣のものまで揺れて読めない。
            .font(.system(size: 10, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "Link latency \(linkMs) milliseconds, DSP latency \(dspMs) milliseconds, load \(load)")
        }
    }

    /// 2 つのアプリのあいだ。再同期でここへ置き直すので設計上の定数。
    /// 瞬間の溜まり（bufferedFrames）は払うたびに動いて読めないので使わない。
    /// 実際の溜まりは Status に出してある。
    private var linkMs: String {
        ms(Double(ETLinkReceiver.targetFrames))
    }

    /// このアプリの中。1 ブロックと、オーバーサンプリングの FIR。
    /// どちらも設定で決まる値で、鳴っている間は変わらない。
    private var dspMs: String {
        ms(Double(io.blockFrames) + Double(io.resamplerLatency))
    }

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
