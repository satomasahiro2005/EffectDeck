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
    /// マスターのバイパス・段の切・Section の OFF のあいだは、回っていても数えない（ETLatencyWatch.isProcessed）。
    /// そのあいだ並んだ値は受け取られず、戻したときの最初の処理で遅れが動くので、そこで組み直す。
    func watchLatency(now: TimeInterval, rendering: Bool) {
        guard !latencyWatch.isEmpty else { return }
        let masterBypass = bypass
        let changed = latencyWatch.tick(now: now, rendering: rendering, processing: { [self] id in
            guard let at = slot(of: id), let node = node(at: at) else { return false }
            return ETLatencyWatch.isProcessed(masterBypass: masterBypass, enabled: node.enabled,
                                              channelBypassed: Self.isChannelBypassed(node),
                                              sectionGate: node.sectionGate)
        }, latency: { [self] id in
            guard let at = slot(of: id), let node = node(at: at), node.instance != 0, engine != 0 else {
                return nil
            }
            return et_instance_latency(engine, node.instance)
        })
        if changed { republish(reason: "遅延が変わった（あとから）") }
    }
}
