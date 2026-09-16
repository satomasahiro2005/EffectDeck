//  DisplayPump.swift
//  画面の描き直しに合わせてテレメトリを汲む。
//
//  以前は `Timer.publish(every: 1.0 / 30.0, on: .main, in: .common)` で回していた。
//  2 つ困る:
//
//    1. **画面と揃わない。** runloop のタイマーは面の更新と無関係に発火し、
//       遅れると間引かれる。60Hz の面に 30Hz の更新を重ねると、
//       1 枠早い/遅いが交互に出て、図が均等に動いていないように見える。
//    2. **DSP が出した枠を半分捨てていた。** カーネル側は 60Hz で出している
//       （EffeTuneDSP.telemetryHz = 60）。30Hz で汲むと、輪の中で
//       新しい枠が古い枠を上書きしてから読むことになる。
//
//  CADisplayLink は面の更新の直前に呼ばれ、ProMotion では 120Hz まで上がる。
//  枠が来ていないときの poll は et_telemetry_read が 0 を返して即戻り、
//  @Published も触らない（Telemetry.poll の `guard read > 0`）ので、
//  余分に呼んでも描き直しは増えない。
//
//  **止めるのを忘れない。** CADisplayLink は target を強く持つので、
//  invalidate しないと画面を閉じても回り続ける。

import QuartzCore

final class ETDisplayPump: NSObject {

    static let shared = ETDisplayPump()

    private var link: CADisplayLink?
    private var body: (() -> Void)?

    private override init() { super.init() }

    /// 汲み始める。二度呼んでも 1 本しか作らない（中身だけ差し替わる）。
    ///
    /// **出す側も一緒に起こす。** 誰も汲んでいないあいだカーネルが枠を
    /// 書き続けると、輪（256KB）が溢れて `droppedFrames` が増える。
    /// 画面に何も描いていないのだから、出す必要が無い。
    @MainActor
    func start(_ body: @escaping () -> Void) {
        self.body = body
        EffeTuneDSP.shared.setTelemetryRate(EffeTuneDSP.telemetryHz)
        guard link == nil else { return }
        let made = CADisplayLink(target: self, selector: #selector(fire))
        // .common にしないと、リストを払っている間だけ止まる。
        made.add(to: .main, forMode: .common)
        link = made
    }

    @MainActor
    func stop() {
        link?.invalidate()
        link = nil
        body = nil
        // 出す側を止める。0 は engine.cpp:552 で「書かない」に落ちる。
        EffeTuneDSP.shared.setTelemetryRate(0)
    }

    @objc private func fire() {
        body?()
    }
}
