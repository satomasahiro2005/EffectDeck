//  IRGraphStore.swift
//  IR Reverb の EDC グラフの置き場。段ごとに、最後に送った IR の解析（ETIRGraph）を持つ。
//
//  --- なぜ EffeTuneDSP に置かないか ---
//  EffeTuneDSP は全部のカードが観測している。図が届くたびにそこの @Published を動かすと、
//  鎖の全カードが描き直される。置き場を分けて、図を出す IRReverbDecayGraph だけが読む。
//
//  --- なぜ裏で計算するか ---
//  ETIRLoader.load は MainActor で同期に走る（IRLoader.swift の load の注釈）。EDC は
//  フレーム数 × 面数の積算と、フレームごとの log10 を、Original と Current の2本ぶんやる。
//  10 秒の 4ch なら数百万回で、同じ呼び出しの中でやると取り込みの間じゅう画面が止まる。
//  load は送るところまで同期のまま、解析だけを Task.detached に出す。
//
//  --- 何をキーにするか ---
//  上流は新しい資産が届いたときに描き直す（ir_reverb.js:652）。dc / co / dt / tr / cm / lt / cr を変えると
//  資産が作り直されて届く。ここも同じで、送った中身を決めるものを全部キーに入れ、同じなら
//  解析し直さない（起動時の入れ直しや、Pre Delay のように資産に関係しない値の変更では走らない）。
//  pd は解析に入らない（ETIRGraph.layout が引き直す）。
//
//  --- 古い図はいつ消すか ---
//  新しい図が届くまで前の図を出し続ける（上流も同じ。:652 まで古い canvas が残る）。
//  消すのは、段から資産が無くなったときだけ（clear）。

import Combine
import Foundation

@MainActor
final class ETIRGraphStore: ObservableObject {

    static let shared = ETIRGraphStore()

    /// 送った中身を決めるもの。同じなら解析も同じになる。
    struct Key: Hashable {
        var path: String
        var modified: Date?
        var fileSize: Int?
        var processingRate: Double
        var rateDivider: UInt32
        var convolutionRate: Int
        var topology: UInt32
        var assetChannels: Int
        var directCut: Bool
        var cutOffsetMs: Double
        var decayPercent: Double
        var trimPercent: Double
        /// 送った長さ（カーネルに収めるための切り詰めがここに出る）。
        var emittedFrames: Int
    }

    @Published private(set) var graphs: [UUID: ETIRGraph] = [:]

    private var keys: [UUID: Key] = [:]
    private var tasks: [UUID: (token: UInt64, task: Task<Void, Never>)] = [:]
    private var nextToken: UInt64 = 0

    /// 送った IR の図を用意する。キーが前と同じで図もあるなら何もしない。
    /// 違えば前の解析を止めて、新しいのを裏で回す。届くまで前の図は残る。
    func analyze(nodeID: UUID, key: Key, source: ETIRGraphSource) {
        if keys[nodeID] == key, graphs[nodeID] != nil { return }
        // 解析が走っている最中に同じキーでもう一度呼ばれたとき（入れ直しが重なる）も、
        // 二重に走らせない。
        if keys[nodeID] == key, tasks[nodeID] != nil { return }
        tasks[nodeID]?.task.cancel()
        nextToken &+= 1
        let token = nextToken
        keys[nodeID] = key
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let graph = ETIRGraph(source)
            await MainActor.run {
                guard let self, self.tasks[nodeID]?.token == token else { return }
                self.tasks[nodeID] = nil
                self.graphs[nodeID] = graph
            }
        }
        tasks[nodeID] = (token, task)
    }

    /// 段から資産が無くなった（外した・リセット・幅 0）。図も要らない。
    func clear(nodeID: UUID) {
        tasks[nodeID]?.task.cancel()
        tasks[nodeID] = nil
        keys[nodeID] = nil
        if graphs[nodeID] != nil { graphs[nodeID] = nil }
    }

    /// 鎖に残っていない段の分を捨てる。鎖を丸ごと入れ替えたとき（reloadAssets）に呼ぶ。
    func retain(_ ids: Set<UUID>) {
        for id in Set(keys.keys).union(graphs.keys).subtracting(ids) { clear(nodeID: id) }
    }
}
