//  ETUndo.swift
//  鎖の取り消し（Undo / Redo）の控えと、戻すときの段取り。
//
//  上流は鎖が変わるたびに鎖まるごとの控えを取り、戻すときは控えから鎖を組み直す
//  （js/ui/pipeline/history-manager.js）。こちらも控えは鎖まるごとにする。
//  ただし組み直しはしない。段の id を控えに持たせ、同じ id の段は instance を
//  そのまま使って値だけ戻す。つまみ 1 つ戻すたびに全段を作り直すと、
//  残響が切れ、IR を読み直し、畳んでいたカードが全部閉じる。
//
//  ボタンは置かない。iOS の UndoManager に積むので、振る・3 本指・⌘Z で戻せる。
//  EffeTuneDSP から出してあるのは、Foundation だけで試験に入れるため（UndoTests）。

import Foundation

/// 取り消しの控え。鎖（main）だけを持つ。出力補正は人が並べたものではないので入れない。
struct ETUndoSnapshot {
    var nodes: [ETChainNode]
    /// 開いていた段。消した段を戻したとき、開いていたなら開いて出す。
    var expanded: Set<UUID> = []
    var collapsedFully: Set<UUID> = []

    /// 中身が同じか。違えば 1 手として積む。
    func sameContent(as other: ETUndoSnapshot) -> Bool {
        nodes.count == other.nodes.count
            && zip(nodes, other.nodes).allSatisfy { ETUndo.sameContent($0, $1) }
    }
}

enum ETUndo {

    /// 人が変えられるものが同じか。
    ///
    /// **比べないもの:**
    ///   - instance・tapId・sectionGate・externalIndex・resetCount（その場で振る番号と、並びから引き直す値）
    ///   - externalState（AU・JSFX の中身）。persist() が host から読み直すたびに変わりうるので、
    ///     比べると、触っていないのに 1 手増える。戻すときも host へ書き戻さない
    ///     （生きている host へ state を入れ直す口が無い）。
    static func sameContent(_ a: ETChainNode, _ b: ETChainNode) -> Bool {
        a.id == b.id
            && a.spec.type == b.spec.type
            && a.values == b.values
            && a.enabled == b.enabled
            && a.inputBus == b.inputBus
            && a.outputBus == b.outputBus
            && a.channelSpec == b.channelSpec
            && a.sectionName == b.sectionName
            && a.irId == b.irId
            && a.display == b.display
            && a.design == b.design
            && a.automation == b.automation
            && a.externalID == b.externalID
            && a.externalInstanceID == b.externalInstanceID
            && a.isRootReset == b.isRootReset
    }

    /// 控えへ戻すときに、段ごとに何をするか。
    struct Plan: Equatable {
        /// いまも在る段。instance をそのまま使い、値だけ控えに合わせる。
        var kept: [UUID] = []
        /// いまは無い段。控えから作り直す（消したのを戻す）。
        var created: [UUID] = []
        /// 控えに無い段。外して壊す（足したのを戻す）。
        var dropped: [UUID] = []
    }

    /// いまの並びから控えの並びへ。並びの順は控えのものを使う。
    ///
    /// 同じ id でも型が違えば作り直す。id は段ごとに振る UUID なので普通は起きないが、
    /// 起きたときに別の型の instance へ値を流し込まないため。
    static func plan(current: [ETChainNode], target: [ETChainNode]) -> Plan {
        var byID: [UUID: ETChainNode] = [:]
        for node in current { byID[node.id] = node }
        var plan = Plan()
        var reused: Set<UUID> = []
        for node in target {
            if let now = byID[node.id], now.spec.type == node.spec.type,
               now.externalID == node.externalID, now.isRootReset == node.isRootReset {
                plan.kept.append(node.id)
                reused.insert(node.id)
            } else {
                plan.created.append(node.id)
            }
        }
        plan.dropped = current.map(\.id).filter { !reused.contains($0) }
        return plan
    }

    /// 在る段に、控えの値を写す。instance など段そのものの番号は残す。
    static func adopt(_ saved: ETChainNode, into node: inout ETChainNode) {
        node.values = saved.values
        node.enabled = saved.enabled
        node.inputBus = saved.inputBus
        node.outputBus = saved.outputBus
        node.channelSpec = saved.channelSpec
        node.sectionName = saved.sectionName
        node.irId = saved.irId
        node.display = saved.display
        node.design = saved.design
        node.automation = saved.automation
    }
}
