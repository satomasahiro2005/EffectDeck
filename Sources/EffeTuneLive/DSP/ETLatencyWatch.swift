//  ETLatencyWatch.swift
//  値を渡した直後には動かない遅れを、あとから見張る帳面。**Foundation だけ**（LatencyWatchTests）。
//
//  et_instance_set_params は値を並べておくだけ（Engine::setInstanceParams は stageParameters）。
//  カーネルが受け取るのは次の processSlot で、SFZ Note Player の latencySamples() は受け取った後の
//  params_ を読む（Saturation 系は並べてある値も読むので、渡した直後に変わる）。
//  なので setValue の直後に et_instance_latency を読んでも、SFZ の dt（Detection）と tm（Timing）は古いまま。
//  settleAfterParams の「遅れが変わったら組み直す」はここでは空振りする。
//
//  やること: 空振りした段を覚えておき、tick ごとに見直す。変わっていたら呼び手が組み直す（republish）。
//    - 音を処理していないあいだは覚えたまま（止めていても値は並んだままで、回り出したら変わる）。
//    - **段ごとに、その段が処理されているあいだだけ数える**（isProcessed）。engine は、マスターのバイパス・
//      段の切・Section の OFF のときその段に触らない（engine.cpp processPipeline）ので、
//      エンジンが回っていても並んだ値は受け取られない。
//    - 処理している時間が giveUpAfter を超えても変わらなければ諦める（本当に変わらない値）。
//    - 1 回の見直しで組み直しを返すのは 1 度だけ。変わった段の記録はその時に全部消す。

import Foundation

struct ETLatencyWatch {

    /// 処理しているのに遅れが変わらなかった時間がこれを超えたら諦める（秒）。
    static let giveUpAfter: TimeInterval = 2

    private struct Entry {
        var latency: UInt32
        var renderedFor: TimeInterval = 0
    }

    private var entries: [UUID: Entry] = [:]
    private var lastTick: TimeInterval?

    var isEmpty: Bool { entries.isEmpty }

    /// engine がその段を処理するか（engine.cpp processPipeline の飛ばす条件の裏）。
    /// マスターのバイパス中は先頭で全部返る。段の切（enabled 0）と Section の OFF（sectionGate 0）は段ごとに飛ばす。
    /// 上流が受けない Ch の段は descriptor で切になる（ETChainEditing.descriptors）。
    static func isProcessed(masterBypass: Bool, enabled: Bool, channelBypassed: Bool,
                            sectionGate: UInt8) -> Bool {
        !masterBypass && enabled && !channelBypassed && sectionGate != 0
    }
    var watched: Set<UUID> { Set(entries.keys) }

    /// tick の `rendering` に渡す値。**カーネルに処理が届いているときだけ真。**
    /// PowerGate が休んでいるあいだは、IO が回っていても ETPipeline_Process を呼ばない（AudioIO の render は
    /// `if awake` の内側）ので、並んだ値は受け取られない。回っているだけで数えると、音を止めたまま
    /// Detection を変えたとき 2 秒で諦めてしまい、再開後に遅れが動いても組み直されない。
    static func isRendering(running: Bool, resting: Bool) -> Bool {
        running && !resting
    }

    /// 値を渡した直後の遅れが変わらなかった段を覚える。すでに居る段は、数えた時間だけ 0 に戻す
    /// （もとの遅れは変えない。まだカーネルに届いていないので、古い値のまま）。
    mutating func expect(id: UUID, latency: UInt32) {
        // 空のあいだは tick が呼ばれず lastTick が古いまま。そのまま使うと最初の見直しが
        // 1 秒（上限）として数えられ、giveUpAfter の半分が 1 回で消える。
        if entries.isEmpty { lastTick = nil }
        if var e = entries[id] {
            e.renderedFor = 0
            entries[id] = e
        } else {
            entries[id] = Entry(latency: latency)
        }
    }

    /// 見直し。`latency(id)` はいまの遅れ（段が無ければ nil）。`processing(id)` はその段を engine が
    /// 処理しているか（isProcessed）。**組み直すべきなら true。**
    mutating func tick(now: TimeInterval, rendering: Bool, processing: (UUID) -> Bool,
                       latency: (UUID) -> UInt32?) -> Bool {
        defer { lastTick = now }
        guard !entries.isEmpty else { return false }
        // 前の見直しからの経過。間が空きすぎたとき（背景から戻った・止めていた）は数えない。
        let elapsed = lastTick.map { min(max(now - $0, 0), 1) } ?? 0
        var changed = false
        for (id, entry) in entries {
            guard let current = latency(id) else {
                entries[id] = nil
                continue
            }
            if current != entry.latency {
                changed = true
            } else if rendering && processing(id) {
                var e = entry
                e.renderedFor += elapsed
                if e.renderedFor >= Self.giveUpAfter {
                    entries[id] = nil
                } else {
                    entries[id] = e
                }
            }
        }
        if changed {
            // 変わった段だけ消す。変わっていない段は、組み直しのあとも見張る。
            for (id, entry) in entries where latency(id).map({ $0 != entry.latency }) ?? true {
                entries[id] = nil
            }
        }
        return changed
    }

    mutating func removeAll() {
        entries.removeAll()
        lastTick = nil
    }
}
