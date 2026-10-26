//  EffeTuneDSP+LatencyWatch.swift
//  値を渡した直後には動かない遅れ（SFZ の dt・tm）を、tick で見直して組み直す。
//  帳面は ETLatencyWatch（Foundation だけ）。理由はそちらの冒頭。

import Foundation

extension EffeTuneDSP {

    /// settleAfterParams が「遅れは変わらなかった」と見たときに呼ぶ。
    /// 遅れが動かない値のほうが多いが、覚えるのは段ごとに 1 件で、処理が 2 秒回れば消える。
    func expectLatencyChange(of node: Node, before: UInt32) {
        latencyWatch.expect(id: node.id, latency: before)
    }

    /// AudioIO.tick から。1 回の呼びで組み直しは多くて 1 度。
    func watchLatency(now: TimeInterval, rendering: Bool) {
        guard !latencyWatch.isEmpty else { return }
        let changed = latencyWatch.tick(now: now, rendering: rendering) { [self] id in
            guard let slot = slot(of: id), let node = node(at: slot), node.instance != 0, engine != 0 else {
                return nil
            }
            return et_instance_latency(engine, node.instance)
        }
        if changed { republish(reason: "遅延が変わった（あとから）") }
    }
}
