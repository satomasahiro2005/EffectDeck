//  EffeTuneDSP.swift
//  EffeTune の DSP コア (dsp/) を Swift から使う。
//
//  DSP そのものは EffeTune のものをそのまま動かしている。移植も書き直しもしていない。
//  dsp/ は host-neutral な C++20 で、ブラウザや WebAudio に触っていないので、
//  WASM を経由せず iOS 向けに arm64 で建つ。
//
//  役割分担:
//    - instance の作成・破棄・パラメータ更新は、このクラス（メインスレッド）
//    - 音のスレッドが読む「鎖の並び」だけ ETChain.c が持つ
//
//  instance を壊すときは、音のスレッドがそれを読み終えるのを待つ。
//  ETChain_ProcessCount が 2 つ進めば、その面はもう読まれていない。

import Foundation
import os

@MainActor
final class EffeTuneDSP: ObservableObject {

    /// 鎖に並んでいる 1 個。中身はDSP/ETChainNode.swift（Foundationだけで試験に入れるため外に出してある）。
    typealias Node = ETChainNode

    static let shared = EffeTuneDSP()

    private let log = Logger(subsystem: "ai.nemut.effetune", category: "dsp")

    @Published private(set) var chain: [Node] = []

    /// 開いている段。ここに入っているものだけが開く。
    ///
    /// 人が 1 本ずつ足したものは開いて出す。足した直後に触るのはその段なので、
    /// 畳んだまま出すと必ず 1 タップ増える。
    /// プリセットや共有リンクで鎖ごと入れ替えたときは全部畳む。10 本以上並ぶので、
    /// 開いていると一覧として読めない。
    /// 画面ではなくここに置いてあるのは、足す・入れ替えるの両方をこの型が握っていて、
    /// 端末に残すのも persist() だから。
    @Published var expanded: Set<UUID> = [] {
        didSet { if !restoring { persistExpanded() } }
    }

    /// 資産を入れたときの 1 行（「4ch True Stereo / 48000 Hz / 1.23 s」）。
    /// 段の id で引く。**音には関係しない。**カードに出すためだけに持つ。
    /// 入れ直しは DSP がやるので、ビューはここから読む。
    @Published var assetInfo: [UUID: String] = [:]

    /// 図も出さずに畳んでいるもの。
    ///
    /// **`expanded` の意味は変えていない。** 畳んでいて、ここに入っていなければ
    /// 「図だけ」。ここに入っていれば「名前の行だけ」。
    /// そうしたのは、既に端末に残っている `expanded` をそのまま生かすため。
    @Published var collapsedFully: Set<UUID> = []

    /// restore() の最中だけ true。読み込みで入れた値を書き戻さないため。
    private var restoring = false
    @Published private(set) var ready = false
    @Published var bypass = false {
        didSet {
            ETPipeline_SetBypass(bypass ? 1 : 0)
            RemoteMirror.shared.bypassChanged(bypass)   // PoC: PC の EffeTune へ写す
        }
    }

    /// テレメトリを読むのに要るので外へ出す。
    private(set) var engine: UInt32 = 0
    private var nextTap: UInt32 = 1
    /// 組んであるレート。IR を送るときの解決に要る（IRLoader）。
    private(set) var sampleRate: Double = 48000
    /// et_engine_prepare に渡した幅。実際の出力IFと同じ（DSPの上限16ch）。
    private(set) var maxChannels: UInt32 = 2
    private var maxFrames: UInt32 = 4096
    var maximumFrames: UInt32 { maxFrames }
    private var kernelIndex: [String: UInt32] = [:]

    /// et_engine_prepare を呼んだ回数。retire が prepare をまたいだかを見るのに使う。
    /// Engine::prepare は destroyAllInstances を通るので、またいだ後の番号は使い回されうる。
    private(set) var prepareGeneration = 0

    // MARK: - 出力補正（Output Correction）

    /// いまの出力先の補正。**chain（使う人の鎖）とは別の並び**で、エンジンへは chain の後ろに付けて渡す。
    /// 入れ替えるのは OutputCorrection（出力先が替わる・入切・紐付けやプリセットの変更・リモートの出入り）だけ。
    /// プリセット・共有・バックアップ・iCloud・pipeline.last・リモートの退避は chain しか見ないので、
    /// ここに入っているものは載らない。
    @Published private(set) var correction: [Node] = []

    /// エンジンへ渡す並び。main の後ろに補正。**slot はこの並びの位置。**
    /// main の slot は chain の添字と同じなので、段ごとの口（setValue など）の呼び手はそのまま通る。
    var nodes: [Node] { chain + correction }

    /// その slot の段。範囲の外なら nil。
    func node(at slot: Int) -> Node? {
        guard let at = locate(slot) else { return nil }
        switch at.part {
        case .main: return chain[at.local]
        case .correction: return correction[at.local]
        }
    }

    /// その段の slot。どちらにも居なければ nil。
    func slot(of id: UUID) -> Int? {
        if let i = chain.firstIndex(where: { $0.id == id }) { return i }
        if let i = correction.firstIndex(where: { $0.id == id }) { return chain.count + i }
        return nil
    }

    /// slot を部分と部分の中の位置へ。数え方は ETChainSlots（OutputCorrectionTests）。
    private func locate(_ slot: Int) -> (part: ETChainPart, local: Int)? {
        ETChainSlots.locate(slot, mainCount: chain.count, correctionCount: correction.count)
    }

    /// slot が在るか。nodes を作らずに見る（setValue はつまみを動かすたびに来る）。
    private func contains(slot: Int) -> Bool {
        slot >= 0 && slot < chain.count + correction.count
    }

    /// slot で段を読み書きする。**範囲は呼び手が contains(slot:) で見てから。**
    private subscript(slot slot: Int) -> Node {
        get {
            slot < chain.count ? chain[slot] : correction[slot - chain.count]
        }
        set {
            if slot < chain.count {
                chain[slot] = newValue
            } else {
                correction[slot - chain.count] = newValue
            }
        }
    }

    /// その部分の並び（読むだけ）。
    private func partNodes(_ part: ETChainPart) -> [Node] {
        switch part {
        case .main: return chain
        case .correction: return correction
        }
    }

    /// その部分の並びを書き換える。
    private func withPart<R>(_ part: ETChainPart, _ body: (inout [Node]) -> R) -> R {
        switch part {
        case .main: return body(&chain)
        case .correction: return body(&correction)
        }
    }

    /// 利用できるエフェクト。カーネルとして登録されているものだけ。
    private(set) var available: [ETEffect] = []

    /// 可視化の値を貯める輪の大きさと、1 秒あたりに出す回数。
    /// Telemetry の読み取りバッファも同じ大きさにしてある（Telemetry.swift）。
    ///
    /// 1MB。PEQ の図に重ねる探り（段 1 つに 2 台、FFT 4096 点で枠 16.4KB）が
    /// 増えても、汲む側が少し止まったくらいでは溢れないように（syncProbes の上の
    /// probePoints に見積もりがある）。arena は輪と同じ大きさの staging も取る
    /// （dsp/core/arena.cpp:33-37 の `telemetry_bytes * 2u`）ので、DSP 側で 2MB、
    /// 読み取りバッファを足して 3MB になる。
    static let telemetryRingBytes: UInt32 = 1024 * 1024
    static let telemetryHz: Float = 60

    /// 何も無いときに置く 1 本。型名は ETChainEditing.defaultType だけに書く。
    private static let defaultType = ETChainEditing.defaultType

    private init() {}

    // MARK: - 用意

    func prepare(sampleRate: Double, maxChannels: UInt32 = 2, maxFrames: UInt32 = 4096) {
        self.sampleRate = sampleRate
        self.maxChannels = maxChannels
        self.maxFrames = maxFrames

        if engine == 0 {
            engine = et_engine_create()
            guard engine != 0 else {
                log.error("et_engine_create が 0 を返した")
                return
            }
            buildKernelIndex()
        }

        // 毎回呼ぶ。Engine::prepare は destroyAllInstances() と invalidatePipeline() を
        // 通る（engine.cpp:219-222, 119-129）ので、pipeline_configured_ が false に戻る。
        // 以前は engine を作ったときだけ呼んでいたため、二度目の prepare のあとも
        // 「組めている」印と古い ET_OK が残り、死んだ instance のまま process していた。
        ETPipeline_SetEngine(engine)
        // Engine::prepare は destroyAllInstances を通る（engine.cpp:221）。
        // 探りの番号も一緒に死ぬので、控えを捨てて作り直させる。
        probes.removeAll()

        // ここから先の instance は前の世代と番号が重なりうる（retire が見る）。
        prepareGeneration &+= 1
        // テレメトリの輪を確保しないと、可視化の値が一切出てこない。
        let st = et_engine_prepare(engine, Float(sampleRate), maxChannels, maxFrames,
                                   Self.telemetryRingBytes)
        guard Int(st) == ET_OK else {
            log.error("et_engine_prepare が \(st) を返した")
            ready = false
            return
        }
        ready = true
        et_engine_set_telemetry_rate(engine, Self.telemetryHz)
        Telemetry.shared.clear()
        log.notice("DSP ready sr=\(sampleRate) engine=\(self.engine) kinds=\(self.available.count) abi=\(et_abi_version())")

        // 用意し直したので、いま並んでいるものを作り直す。
        rebuildAll()
        // 何も無ければ、前回の鎖か既定を組む。
        restore()
        // **restore() の後に呼ぶ。**chain が空のうちに補正を入れて publish すると、
        // persist() が pipeline.last へ [] を書く（rebuildAll の頭と同じ話）。
        // 補正がもう入っていれば（組み直し）何もしない。
        OutputCorrection.shared.dspPrepared()
    }

    func reset() {
        guard engine != 0 else { return }
        et_engine_reset(engine)
    }

    /// この段のカーネルが積み上げた状態だけを捨てる。
    ///
    /// 上流の `resetPluginState`（plugins/audio-processor.js:1763、_resetTemporalPlugin）に当たる。
    /// Analog Meter の Integrated / LRA / 最大 True Peak、Tonal Balance EQ の測定、
    /// Rhythm Analyzer の解析がこれで最初からになる。パラメータは変えない。
    ///
    /// **音のスレッドを締め出してから呼ぶ。** et_instance_reset は kernel->reset() を直に呼ぶだけで
    /// 段取りが無く（engine.cpp:409-421）、process の最中に走るとカーネルの状態を書き合う。
    /// パラメータは staging を通るので同じ心配が無いが、これは通らない。素通しが一瞬入る（Reset を押した
    /// ときだけ）。こちらの鎖は graph でなく pipeline 経路（ETPipeline）なので graphOwned にならず、ET_OK で返る。
    /// 送り直すと sequence が 0 から数え直しになるので、枠の番号は単調と思わないこと。
    @discardableResult
    func resetState(at index: Int) -> Bool {
        guard engine != 0, ready, contains(slot: index) else { return false }
        let instance = self[slot: index].instance
        guard instance != 0 else { return false }
        var status = Int32(ET_ERR_STATE)
        AssetUpload.holdOffAudioThread {
            status = Int32(et_instance_reset(engine, instance))
        }
        if status != Int32(ET_OK) {
            let type = self[slot: index].spec.type
            log.error("et_instance_reset が \(status) を返した \(type, privacy: .public)")
        }
        return status == Int32(ET_OK)
    }

    /// 可視化の枠を出す速さ。**0 にすると書かなくなる**（engine.cpp:552）。
    ///
    /// 誰も汲んでいないあいだ書き続けると輪（telemetryRingBytes）が溢れて
    /// `Telemetry.droppedFrames` が増える。画面に描いていないなら要らないので、
    /// 汲む側（ETDisplayPump）の出入りに合わせて止める。
    func setTelemetryRate(_ hz: Float) {
        guard engine != 0, ready else { return }
        et_engine_set_telemetry_rate(engine, hz)
    }

    /// カーネルとして実際に登録されている型だけをカタログから残す。
    private func buildKernelIndex() {
        let count = et_kernel_count()
        var buf = [CChar](repeating: 0, count: 128)
        for i in 0..<count {
            let n = et_kernel_name(i, &buf, UInt32(buf.count))
            guard n > 0 else { continue }
            kernelIndex[String(cString: buf)] = i
        }
        // analyzer も出す。値は DSP がテレメトリで吐くので、こちらは描くだけでよい。
        // Section はカーネルを持たないので kernelIndex に載らない。鎖の飾りとして
        // 選べないと困るので、ここで足す（plugins/plugins.txt:123 と同じ扱い）。
        available = ETCatalog.filter { kernelIndex[$0.type] != nil } + [ETSection.spec]
        let missing = ETCatalog.filter { kernelIndex[$0.type] == nil }
        if !missing.isEmpty {
            log.info("カーネルが無い型 \(missing.count) 個: \(missing.prefix(5).map(\.type).joined(separator: ","))")
        }
    }

    // MARK: - 鎖をいじる

    /// 足す。`at` を渡すとその位置へ差し込む。nil なら末尾。
    ///
    /// **位置は鎖の添字。** 画面の行番号ではない（Section が畳まれていると
    /// 行と鎖はずれる）。呼ぶ側が鎖の添字へ直してから渡すこと。
    func add(_ spec: ETEffect, at index: Int? = nil) {
        guard appendSpec(spec) else { return }
        // appendSpec は末尾へ積む。差し込む位置が指定されていれば、そこへ移す。
        var placed = chain.count - 1
        if let index, index >= 0, index < placed {
            let node = chain.removeLast()
            chain.insert(node, at: index)
            placed = index
        }
        publish()
        guard chain.indices.contains(placed) else { return }
        let id = chain[placed].id
        expanded.insert(id)
        // 足す先は必ず鎖の末尾で、その末尾が畳んだ Section の配下に当たることがある。
        // 隠す範囲は Section の次から次の Section の手前までで、次が無ければ末尾まで
        // なので、鎖 [A, Section(畳), C] に足すと足したものが配下へ入り、
        // 画面には何も出ない。上の expanded.insert は自分のパラメータを開く印で、
        // 包んでいる Section は畳んだままなので効かない。
        revealHidden([id])
    }

    /// AU/JSFXをEffectDeckの鎖へ追加するための共通入口。
    /// 実行アダプタはexternalIDをキーに別レジストリから解決する。
    func addExternal(id: String, instanceID: String, name: String, category: String,
                     externalIndex: UInt8, at index: Int? = nil) {
        let spec = ETEffect.external(type: "External:\(id)", name: name, category: category)
        var node = Node(spec: spec, values: [])
        node.externalID = id
        node.externalInstanceID = instanceID
        node.externalIndex = externalIndex
        let placed: Int
        if let index, index >= 0, index < chain.count {
            chain.insert(node, at: index)
            placed = index
        } else {
            chain.append(node)
            placed = chain.count - 1
        }
        publish()
        expanded.insert(chain[placed].id)
    }

    /// 1 本足すだけ。publish はしない。
    /// まとめて足すときに 1 本ごとに configure を走らせないよう、単発用と分けてある。
    @discardableResult
    private func appendSpec(_ spec: ETEffect) -> Bool {
        var node = Node(spec: spec, values: spec.defaults)
        if node.values.count != spec.floatCount {
            node.values = spec.defaults + Array(repeating: 0,
                                                count: max(0, spec.floatCount - spec.defaults.count))
        }
        applyAddDefaults(&node)
        guard instantiate(&node) else { return false }
        chain.append(node)
        return true
    }

    /// 新しく足した段だけに掛ける既定。上流の constructor が params.json の既定から
    /// 外しているもの。
    ///
    /// **プリセット・共有リンク・保存した鎖には掛けない。**そちらは append(_:) と
    /// addPreset を通り、ここ（appendSpec）は通らない。持ってきた値と Routing に従う。
    private func applyAddDefaults(_ node: inout Node) {
        switch node.spec.type {
        case BassManagementDesigners.type:
            // bass_management.js:23。Ch は All。Reset では触らない
            // （上流は defaultParameters から channel を外す。plugin-manager.js:47）。
            node.channelSpec = -2
        default:
            break
        }
        applyConstructorValues(&node)
    }

    /// 上流の constructor が params.json の既定から外している**値**。
    /// 足すときと Reset のときの両方に掛ける。上流の Reset は生成時に控えた
    /// getParameters()（constructor の値）へ戻すため（plugin-manager.js:41,
    /// pipeline-item-builder.js:398-401）、足した直後と同じ姿に戻る。
    private func applyConstructorValues(_ node: inout Node) {
        switch node.spec.type {
        case BassManagementDesigners.type:
            // bass_management.js:42-45。処理幅ぶんの Role を Managed に。
            // su は 0 のままなので、Sub を選ぶまでカーネルは素通し（kernel.cpp:455-462）。
            guard let roles = node.spec.params.first(where: { $0.key == "ro" }) else { return }
            for ch in 0..<min(roles.count, Int(maxChannels))
            where node.values.indices.contains(roles.offset + ch) {
                node.values[roles.offset + ch] = 1
            }
        case "RoomEqPlugin":
            // 既定はレイテンシ最小（pm='min'）で、fd は 0 を送る
            // （room_eq.js:883, :1061）。params.json の 16384 は使わない。
            // 設計が走れば RoomEQStore が正しい値で上書きする。
            guard let fd = node.spec.params.first(where: { $0.key == "fd" }),
                  node.values.indices.contains(fd.offset) else { return }
            node.values[fd.offset] = 0
        default:
            break
        }
    }

    /// 消す。位置は **slot**（main と補正のどちらも指せる）。
    func remove(at offsets: IndexSet) {
        let parts = ETChainSlots.split(offsets, mainCount: chain.count)
        let mainOffsets = parts.main.filteredIndexSet { chain.indices.contains($0) }
        let correctionOffsets = parts.correction.filteredIndexSet { correction.indices.contains($0) }
        let gone = mainOffsets.map { chain[$0] } + correctionOffsets.map { correction[$0] }
        let doomed = gone.map(\.instance).filter { $0 != 0 }
        let external = gone.filter(\.isExternal).map(\.externalInstanceID)
        if !mainOffsets.isEmpty { chain.remove(atOffsets: mainOffsets) }
        if !correctionOffsets.isEmpty { correction.remove(atOffsets: correctionOffsets) }
        publish()
        for id in external { removeExternal(instanceID: id) }
        retire(doomed)
        // 消したあとに、何も閉じていない無名 Section が残ることがある
        // （[S("A"), X, S(""), Y] の Y を消すと S("") が閉じる相手を失う）。
        normalizeRootResets()
    }

    /// 鎖の並びを変える。位置は**鎖の添字**（画面の行番号ではない）。
    ///
    /// 動かした先が畳んだ Section の配下なら、その Section を開く（revealHidden）。
    /// 開かないと動かした行が画面から消え、どこへ行ったのか分からなくなる。
    /// 畳んだ Section と一緒に運ばれた配下は開く理由に数えない。Section ごと
    /// 動かしただけで、畳んでおいた中身が勝手に開いてしまうため。
    func move(from source: IndexSet, to destination: Int) {
        // 連れて行かれるだけの配下。掴んだ行ではないので開く対象から外す。
        let a = analysis
        let moved = Set(source.compactMap { chain.indices.contains($0) ? chain[$0].id : nil })
        var carried: Set<UUID> = []
        for i in source where chain.indices.contains(i) {
            guard chain[i].isSection, !expanded.contains(chain[i].id) else { continue }
            for member in a.members(of: chain[i].id) where moved.contains(member) {
                carried.insert(member)
            }
        }
        let grabbed = moved.subtracting(carried)

        chain.move(fromOffsets: source, toOffset: destination)
        publish()
        revealHidden(grabbed)
        normalizeRootResets()
    }

    /// **rootReset を正規形にする。**鎖を動かした後段から通す。
    ///
    /// 前は「何も閉じていない無名 Section を掃く」形で、名前・位置・前後の Section・
    /// 入切・掃除前後の gates・開いているか、の 6 つから**出自を推理していた**。
    /// 推理なので、人が名前を付けていないだけの Section まで候補に入り、
    /// 消さないための門を足し続けることになっていた。
    ///
    /// いまは推理しない。**自分が置いた rootReset だけを見る。**
    /// 要る・要らないは並びの形だけで決まる（ETRootResetRule.keep）。
    /// 普通の Section は名前が空でも一切触らない。
    ///
    /// main と補正は別々に見る。補正は main の後ろに独立して付く並びなので、
    /// main の最後の組が補正の頭まで続いているとは数えない（ETPipelineAnalysis.merged と同じ）。
    func normalizeRootResets() {
        var changed = false
        for part in [ETChainPart.main, .correction] {
            let list = partNodes(part)
            let keep = ETRootResetRule.keep(roles: list.map(\.role))
            let dead = IndexSet(list.indices.filter { !keep[$0] })
            guard !dead.isEmpty else { continue }
            withPart(part) { $0.remove(atOffsets: dead) }
            changed = true
        }
        if changed { publish() }
    }

    /// **その段を組から出す。**直前に rootReset を挿す。
    ///
    /// 何も起きなかったときは false。呼ぶ側は戻り値だけで触覚を決められる
    /// （前は「鎖の本数が増えたか」で見ていた。挿してから掃除で取り消される
    /// という二段構えだったので、そう数えるしかなかった）。
    ///
    /// - 既に root に居るなら何もしない
    /// - 直前が既に rootReset なら何もしない
    /// - 位置は slot。印はその段の居る部分（main か補正）の中だけで決めて挿す
    @discardableResult
    func leaveSection(at index: Int) -> Bool {
        guard let place = locate(index) else { return false }
        let list = partNodes(place.part)
        // **判断は純粋関数が持つ。**ここは並びを渡して答えを受けるだけ。
        // 模型の外から素の並びだけで試せるようにしてある（PipelineRulesTests）。
        guard let at = ETRootResetRule.insertion(roles: list.map(\.role),
                                                 enabled: list.map(\.enabled),
                                                 at: place.local) else { return false }
        var marker = Node(spec: ETSection.spec, values: [])
        marker.isRootReset = true
        withPart(place.part) { $0.insert(marker, at: at) }
        publish()
        return true
    }

    /// 畳んだ Section の配下に入ってしまった段を、その Section を開いて見えるようにする。
    ///
    /// 畳んだ Section は配下の**行ごと**消える（PipelineView.rows）ので、そこへ
    /// 入れてしまうと動かした/足したものが画面から消える。上流は畳んでも行が残るので
    /// 起きない（js/ui/pipeline/pipeline-item-builder.js:795-836 は
    /// パラメータの表示を畳むだけ）。
    ///
    /// 画面ではなくここに置いてあるのは、鎖を動かす口（move / add）がこちらで、
    /// ドラッグからも ⋯ からも同じ扱いになるようにするため。
    func revealHidden(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        // **持ち主を引くだけ。**鎖を走って範囲を数え直さない。
        // rootReset は Section ではないので、ここへ入り込む経路そのものが無い。
        let a = analysis
        for id in ids {
            guard let owner = a.owner(of: id) else { continue }
            expanded.insert(owner)
        }
    }

    func setEnabled(_ enabled: Bool, at index: Int) {
        guard contains(slot: index) else { return }
        self[slot: index].enabled = enabled
        publish()
    }

    /// 端末に残す。次の起動で同じ鎖が出る。
    private func persist() {
        // まとめ待ちを潰してから書く。待っていた内容はいまの chain に入っている。
        pendingPersist?.cancel()
        pendingPersist = nil

        // PoC: PC の EffeTune へ写す（DSP/RemoteMirror.swift）。下の門は端末へ残すかの話で、
        // PC の鎖を編集しているあいだは端末へは書かずに PC へだけ送るので、門より前に呼ぶ。
        RemoteMirror.shared.chainChanged(chain)

        // **PC の鎖を編集しているあいだは端末へ書かない**（RemoteMirror.isRemote）。
        // いま並んでいるのは PC の鎖で、手元の鎖は退避してある。書くと pipeline.last と
        // iCloud（CloudMirror）が PC の鎖で上書きされ、切ったときに戻す先が消える。
        guard !RemoteMirror.shared.isRemote else { return }

        // **restore() が置いた既定の 1 本は残さない**（ETChainEditing.shouldPersist）。
        // 書くと iCloud 側の鎖が Level Meter 1 本で上書きされ、遅れて降りてくる鎖を
        // 受ける口も閉じる。入れ直した端末では、この 2 つが同じ起動の数ミリ秒差で起きていた。
        // 人が消して既定に戻した場合は hasSaved が true なので残す。
        // 何も触らずに終了した場合は次の起動でまた既定が並ぶ。見え方は同じ。
        guard ETChainEditing.shouldPersist(types: chain.map(\.spec.type),
                                           hasSaved: PipelineStore.hasSaved) else { return }

        // **host に生きた instance が無いときは、読み込んだ state を残す。**
        // 元のファイルが無い端末（消した・iCloud で鎖だけ来た）や、組み立てに
        // 失敗した段では stateData が nil を返す。そのまま書くと shortForm が
        // 鍵ごと落とし、保存と iCloud から slider と @serialize が消える。
        // 同じファイルを入れ直しても段は戻るが値は戻らない。
        // 生きていれば host は読み込んだ state から始めて上書きしていくので、
        // 普通の段の結果は変わらない。
        refreshExternalStates(.main)
        PipelineStore.saveLast(chain)
        persistExpanded()
    }

    /// 外の host（AU・JSFX）の生きた state をその部分の並びへ写す。読めなければ前の値を残す。
    private func refreshExternalStates(_ part: ETChainPart) {
        guard partNodes(part).contains(where: \.isExternal) else { return }
        withPart(part) { list in
            for index in list.indices where list[index].isExternal {
                list[index].externalState = externalState(for: list[index])
                    ?? list[index].externalState
            }
        }
    }

    /// PoC: PC の鎖を編集する前に、手元の鎖を退避する形（RemoteMirror）。
    ///
    /// **待っている遅延保存を先に書き切る。**退避した後は persist() が書かないので、
    /// 0.5 秒待ちの編集が落ちる。外部の段は persist() と同じく生きた instance の state を取る。
    func remoteStashForm() -> [[String: Any]] {
        if pendingPersist != nil { persist() }
        var nodes = chain
        for index in nodes.indices where nodes[index].isExternal {
            nodes[index].externalState = externalState(for: nodes[index]) ?? nodes[index].externalState
        }
        return PipelineStore.shortForm(nodes)
    }

    /// 走っている遅延保存。まとめるために持っている。
    private var pendingPersist: Task<Void, Never>?

    /// 少し待ってから persist() する。
    ///
    /// パラメータは 1 目盛り動かすたびに setValue が来る。ドラッグ中はそれが
    /// 連続し、15BandGEQ の Reset のように 1 操作で 15 回続く所もある。
    /// そのたびに鎖ぜんぶを JSON へ直して UserDefaults へ書くと重いので、
    /// 最後の 1 回だけ書く。次が来たら前の待ちを捨てる。
    ///
    /// 0.5 秒のあいだにアプリが落とされるとその編集は残らない。
    /// 背景に回った時点で 1 回書くのが本筋だが、scenePhase を持てるのは
    /// App 側（EffeTuneLiveApp.swift）で、そこはこの担当の範囲ではない。
    private func persistSoon() {
        pendingPersist?.cancel()
        pendingPersist = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            self?.persist()
        }
    }

    private func persistExpanded() {
        // PC の鎖の開閉は手元の鎖の位置と合わない。persist() と同じく書かない。
        guard !RemoteMirror.shared.isRemote else { return }
        PipelineStore.saveExpanded(chain.indices.filter { expanded.contains(chain[$0].id) })
    }

    /// 起動時に呼ぶ。前回の鎖が残っていればそれを、無ければ既定を組む。
    /// 既定に Level Meter を 1 つ置いているのは、音が来ているかどうかが
    /// 一目で分かるようにするため。下の帯にメーターを置かない代わり。
    ///
    /// 全部 chain に入れ終えてから publish() を 1 回だけ呼ぶ。以前は append が
    /// 1 本ごとに publish していたので、10 本なら et_pipeline_configure が 10 回積まれた。
    /// configure は音のスレッドで走り、std::array<PipelineNode,128> のコピーと
    /// 遅延補正の確保・解放を伴う（engine.cpp:648-709）ので、起動直後に一番重くなる。
    func restore() {
        guard ready, chain.isEmpty else { return }

        // シミュレータで画面を見るときだけ、起動の引数で鎖を仕込む。
        // 値まで仕込む撮影用の鎖。共有リンクと同じ経路を通す。
        if let json = ETScreenshotSeed.storeChain {
            let loaded = ETShareLink.parse(json, catalog: ETCatalog)
            if !loaded.isEmpty {
                for item in loaded { append(item) }
                // 下の分岐と同じで、-ETCollapsed 1 なら畳んだ状態にする。
                // 図だけ残ってつまみが消えるので、Analyzer を並べた鎖はそちらが見やすい。
                restoring = true
                expanded = ETScreenshotSeed.collapsed ? [] : Set(chain.map(\.id))
                restoring = false
                publish()
                ETAssetReattach.loaded(chain)
                return
            }
        }

        if let seed = ETScreenshotSeed.requested {
            for type in seed {
                if let spec = Self.spec(forType: type) { appendSpec(spec) }
            }
            // 撮るときは中身が写らないと意味が無いので全部開く。
            // **畳んだ状態を撮りたいときは -ETCollapsed 1 を渡す。**
            restoring = true
            expanded = ETScreenshotSeed.collapsed ? [] : Set(chain.map(\.id))
            restoring = false
            publish()
            return
        }

        if let saved = PipelineStore.loadLast(catalog: ETCatalog), !saved.isEmpty {
            for item in saved { append(item) }
            // 前回開いていた段を開き直す。位置で覚えてあるので、
            // 読み込んだ本数に収まるものだけを拾う。
            restoring = true
            expanded = Set(PipelineStore.loadExpanded()
                .filter { chain.indices.contains($0) }
                .map { chain[$0].id })
            restoring = false
            publish()
            // **IRの入れ直しは次の回に回す**（rebuildAllと同じ）。ここはAudioIOの初期化の中、
            // 画面を作っている途中で走る。IRは畳み込みのレートへ伸縮して下ごしらえするので、
            // 4chの長いIRを何本も同期で読むとDebugビルドでは数秒かかり、起動が詰まる。
            Task { @MainActor [weak self] in
                self?.reloadAssets()
            }
            // 畳んだまま起動した Bass Management の Linear も設計させる（replaceChain と同じ）。
            ETAssetReattach.loaded(chain)
        } else if !PipelineStore.hasSaved {
            if let meter = ETCatalog.first(where: { $0.type == Self.defaultType }) {
                add(meter)
            }
        }
    }

    /// iCloud から遅れて降りてきた鎖を、いま画面に出す。
    /// 呼ぶのは CloudMirror（onChainRestored）で、手元が空だった鍵を
    /// 埋めた直後だけ。
    ///
    /// **まだ何も組んでいないときだけ入れる。**入れ直した直後の起動では
    /// restore() が既定の Level Meter を 1 本置いただけの状態で、失うものが無い。
    /// 人が何か足していれば isDefaultChain が false になり、ここは素通りする。
    /// 遅れて届いた古い鎖で、いま触っている鎖を潰さないため。
    func adoptSeededChain() {
        // PC の鎖を編集している最中に降りてきた鎖で、PC の鎖を潰さない（RemoteMirror）。
        guard ready, isDefaultChain, !RemoteMirror.shared.isRemote else { return }
        guard let saved = PipelineStore.loadLast(catalog: ETCatalog), !saved.isEmpty else { return }
        replaceChain(with: saved)
    }

    /// 鎖に残っている鍵から、資産（IR と SFZ のバンク）を入れ直す。
    ///
    /// **ビューに置いてはいけない。** 畳んだカードはビューが作られないので
    /// `.task` が走らず、開くまで素通しのままになる（実機で確認）。
    /// 音の側の話なので、鎖が戻った時点でここがやる。
    func reloadAssets() {
        let all = nodes
        for i in all.indices where !all[i].irId.isEmpty {
            reloadAsset(at: i)
        }
        // 組み直しは ETIRLoader.load が送るたびにやっている
        // （素材が入って初めてカーネルがその段を有効と数えるため）。
    }

    /// 鍵が `ids` に入っている段だけ入れ直す。PC から IR が届いたとき（RemoteMirror）。
    /// 鳴っている最中に、届いた IR と関係ない段まで組み直さない。
    func reloadAssets(ids: Set<String>) {
        let all = nodes
        for i in all.indices where !all[i].irId.isEmpty && ids.contains(all[i].irId) {
            reloadAsset(at: i)
        }
    }

    /// 1 段だけ入れ直す。
    ///
    /// 送れたら、そのときの 1 行（「4ch True Stereo / 48000 Hz / 1.23 s」）を
    /// `assetInfo` に残す。カードはそれを読む。
    /// engine が回さない段（幅 0）では送れないので、前の 1 行を理由の 1 行に替える
    /// （ETChainEditing.assetLineAfterReload）。
    @discardableResult
    func reloadAsset(at index: Int) -> Bool {
        guard contains(slot: index) else { return false }
        let node = self[slot: index]
        // SFZ Note Player のバンクは読み込みが重いので、別のスレッドで読んで送る（SFZLoader）。
        if node.spec.type == ETChainText.sfzType {
            guard node.instance != 0 else { return false }
            return SFZLoader.shared.reload(slot: index, dsp: self)
        }
        guard !node.irId.isEmpty, node.instance != 0 else { return false }
        let width = Self.routedChannels(of: node)
        let line = ETIRLoader.reload(irId: node.irId,
                                     engine: engine,
                                     instance: node.instance,
                                     processingRate: sampleRate,
                                     routedChannels: width,
                                     channelMode: Self.choice("cm", of: node),
                                     latency: Self.choice("lt", of: node),
                                     convolutionRate: Self.choice("cr", of: node),
                                     options: ETIRPreparation.Options(designParams: node.design))
        let shown = ETChainEditing.assetLineAfterReload(sent: line,
                                                        previous: assetInfo[node.id],
                                                        processedWidth: width)
        // 同じ値を書き戻すと @Published がカードを描き直させるので、変わるときだけ書く。
        if assetInfo[node.id] != shown { assetInfo[node.id] = shown }
        return line != nil
    }

    /// この段を engine が実際に処理する幅。**engine が回さない段は 0。**
    ///
    /// 決まりは ETChannel.processedWidth（engine.cpp:757-769 の飛ばし方と同じ）。
    /// 前は対を常に 2、1 本を常に 1 と数えていたので、出力 2ch で "56" に置いた IR Reverb や
    /// Crosstalk を 2ch 幅として設計していた（engine はその段を飛ばす）。
    /// -2（All）は接続中の出力IFに合わせた engine の幅そのもの。
    static func routedChannels(of node: Node) -> Int {
        ETChannel.processedWidth(spec: node.channelSpec, engineChannels: Int(shared.maxChannels))
    }

    /// 外部の段（AU / JSFX）の host に組ませる幅。**0 を渡さない。**
    ///
    /// engine が飛ばす段でも host は形（バスの ch 数）を作るので、置いた Ch が名乗る幅のまま
    /// 渡す（ETChannel.nominalWidth。routedChannels が 0 を返すようになる前と同じ値）。
    /// 外れていたJSFXの段を建て直すとき（ETJSFXHost.reviveDeadCards）も同じ幅を使う。
    static func externalChannels(of node: Node) -> Int {
        ETChannel.nominalWidth(spec: node.channelSpec, engineChannels: Int(shared.maxChannels))
    }

    /// 上流が受けない Ch に置かれた段。**descriptor では enabled 0 で渡す**。
    /// 決まりは ETChainEditing.isChannelBypassed。
    static func isChannelBypassed(_ node: Node) -> Bool {
        ETChainEditing.isChannelBypassed(type: node.spec.type, channelSpec: node.channelSpec)
    }

    /// その段で、資産を送り直さないと効かない値の位置（ETChainEditing.assetConfigOffsets）。
    private static func assetConfigOffsets(of node: Node) -> Set<Int> {
        ETChainEditing.assetConfigOffsets(params: node.spec.params, irId: node.irId)
    }

    /// その段がいま名乗っている遅れ（標本）。abi.h:125。
    private func instanceLatency(of node: Node) -> UInt32 {
        guard engine != 0, node.instance != 0 else { return 0 }
        return et_instance_latency(engine, node.instance)
    }

    /// パラメータを渡したあとの後始末。
    ///
    /// **鎖を組み直さないと遅延は動かない。** et_pipeline_latency が返すのは
    /// engine が覚えている値で、書くのは et_pipeline_configure のときだけ
    /// （engine.cpp:706）。値を渡しただけでは帯の Fx も、並列に走る段との
    /// 位置合わせも古いままになる。
    private func settleAfterParams(at index: Int, changed offset: Int, before: UInt32) {
        guard contains(slot: index) else { return }
        if Self.assetConfigOffsets(of: self[slot: index]).contains(offset) {
            // 送り直すと ETIRLoader.load の中で組み直される。
            reloadAsset(at: index)
        } else if instanceLatency(of: self[slot: index]) != before {
            republish(reason: "遅延が変わった")
        }
    }

    /// 選択肢の param から、いま選ばれている綴りを引く（ETChainEditing.choice）。
    static func choice(_ key: String, of node: Node) -> String {
        ETChainEditing.choice(key, params: node.spec.params, values: node.values)
    }

    /// プリセットを**いまの鎖へ足す**。置き換えない。
    ///
    /// 何をどこへ差し込むかは ETChainEditing.presetInsertion が決める（上流
    /// preset-manager.js:78 addPresetToPipeline と同じ組み立て）。先頭にプリセット名の
    /// Section、中身、要るときだけ閉じる名前の無い Section。外部の段には新しい身元が付いてくる。
    /// 足したものは全部開いた状態にする（:170-172 expandedPlugins.add）。
    ///
    /// 置き換えではないので、プリセットを 2 つ選べば 2 つとも鎖に並ぶ。
    /// 鎖を捨てたいときは ⋯ の Reset Pipeline を使う。
    ///
    /// index を省くと末尾へ足す（上流の insertionIndex = null と同じ）。
    func addPreset(named name: String, items: [PipelineStore.Loaded], at index: Int? = nil) {
        guard ready, !items.isEmpty else { return }
        let plan = ETChainEditing.presetInsertion(named: name, items: items, at: index,
                                                  roles: chain.map(\.role))
        let target = plan.target

        var made: [Node] = []
        for item in plan.items {
            var node = Node(spec: item.spec, values: item.values)
            // プリセットに入っていた終端。appendと同じくinstanceを作らずに置く。
            if item.isRootReset {
                node.isRootReset = true
                made.append(node)
                continue
            }
            node.enabled = item.enabled
            node.inputBus = item.inputBus
            node.outputBus = item.outputBus
            node.channelSpec = item.channelSpec
            node.sectionName = item.sectionName
            node.irId = item.irId
            node.display = item.display
            node.design = item.design
            node.externalID = item.externalID.isEmpty ? nil : item.externalID
            if node.isExternal {
                // 身元は presetInsertion が新しく付け直してある（同じ AU を 2 枚のカードが取り合わない）。
                node.externalInstanceID = item.externalInstanceID
                node.externalState = item.externalState
                guard let externalIndex = try? ETAUExternalBridge.shared.reserve(
                    instanceID: node.externalInstanceID) else { continue }
                node.externalIndex = externalIndex
                restoreExternal(node)
                made.append(node)
                continue
            }
            guard instantiate(&node) else { continue }
            made.append(node)
        }
        guard !made.isEmpty else { return }

        chain.insert(contentsOf: made, at: target)
        publish()
        // IR は instance を作っただけでは鳴らない。保存済みの資産を新しい
        // instance へ送り直す。既存の段まで再送せず、今回足した段だけにする。
        for offset in made.indices where !made[offset].irId.isEmpty {
            _ = reloadAsset(at: target + offset)
        }
        // 値だけで設計できる型（Bass Management の Linear）も同じ理由でここで作らせる。
        ETAssetReattach.loaded(Array(chain[target..<(target + made.count)]))
        // 足したものは開いて出す。上流も expandedPlugins に入れている。
        // publish() の後に入れるのは、persistExpanded に確定後の位置を書かせるため。
        for node in made { expanded.insert(node.id) }
        // 今回足したぶんは expanded なので掃除に触られない。片付くのは、前から
        // 鎖に残っていた死んだ印だけ。
        normalizeRootResets()
    }

    /// 鎖をまるごと入れ替える。共有リンクの取り込みで使う。
    ///
    /// プリセットはこちらを通さない。上流は足す側なので addPreset(named:items:at:) を使う。
    ///
    /// 入れ替えるのは main だけ。出力補正（correction）には触らない。
    func replaceChain(with items: [PipelineStore.Loaded]) {
        guard ready else { return }
        let doomed = chain.map(\.instance).filter { $0 != 0 }
        let external = chain.filter(\.isExternal).map(\.externalInstanceID)
        chain.removeAll()
        // Tear down old host identities before constructing replacements. A
        // saved/imported chain may legitimately contain the same IDs; removing
        // afterward would clear the freshly-created adapters as well.
        for id in external { removeExternal(instanceID: id) }
        // 丸ごと入れ替えたら全部畳む。前の鎖の id は残っていても指す先が無い。
        restoring = true
        expanded.removeAll()
        restoring = false
        for item in items { append(item) }
        publish()
        // プリセット／共有リンクから復元した IR を、新しく作った instance へ送る。
        // ビューの生成に依存させないので、畳んだ IR Reverb も直ちに有効になる。
        reloadAssets()
        // 値だけで設計できる型（Bass Management の Linear）も同じ。
        ETAssetReattach.loaded(chain)
        retire(doomed)
    }

    /// 出力補正をまるごと入れ替える（空なら外すだけ）。呼ぶのは OutputCorrection だけ。
    ///
    /// 順は replaceChain と同じ。前の段の番号を控え、外の host を先に外してから作り直し、
    /// publish() を通したあとで retire() へ渡す。main には触らない。
    /// 入れた段は畳んで出す（開閉は端末に残さない）。
    func loadCorrection(_ items: [PipelineStore.Loaded]) {
        guard ready else { return }
        let doomed = correction.map(\.instance).filter { $0 != 0 }
        let external = correction.filter(\.isExternal).map(\.externalInstanceID)
        let old = Set(correction.map(\.id))
        restoring = true
        expanded.subtract(old)
        restoring = false
        collapsedFully.subtract(old)
        correction.removeAll()
        // replaceChain と同じく、作り直す前に外す。同じプリセットを入れ直すことがある。
        for id in external { removeExternal(instanceID: id) }
        for item in items { append(item, to: .correction) }
        publish()
        // 入れ直した IR と、値だけで設計できる型（replaceChain と同じ）。
        for i in correction.indices where !correction[i].irId.isEmpty {
            reloadAsset(at: chain.count + i)
        }
        ETAssetReattach.loaded(correction)
        retire(doomed)
    }

    /// 出力補正を外す。
    func unloadCorrection() {
        loadCorrection([])
    }

    /// いま並んでいるのが既定そのもの（Level Meter 1 本）か。
    /// 画面で「戻す」を押せなくするのに使う。型名を画面側に持たせないため、
    /// 何が既定かの判断はここに置く。
    var isDefaultChain: Bool {
        ETChainEditing.isDefaultChain(types: chain.map(\.spec.type))
    }

    /// 鎖を捨てて、初めて起動したときと同じ Level Meter 1 本へ戻す。
    ///
    /// 1 本ずつ消す remove(at:) しか無いと、10 本並んだ鎖を畳むのに 10 回スワイプする。
    /// 空にせず Level Meter を 1 本置くのは restore() の既定と同じ理由で、
    /// 音が来ているかどうかが分かる 1 本だけは残すため。
    ///
    /// instance の後始末は replaceChain と同じ順にしてある。先に番号を控えて、
    /// 鎖を組み直して publish() を通したあとで retire() へ渡す。publish より先に
    /// 壊すと、音のスレッドがまだ読んでいる古い descriptor の指す先が消える。
    func resetToDefault() {
        guard ready else { return }
        let doomed = chain.map(\.instance).filter { $0 != 0 }
        let external = chain.filter(\.isExternal).map(\.externalInstanceID)
        chain.removeAll()
        // 前の鎖の id は残っていても指す先が無いので捨てる（replaceChain と同じ）。
        restoring = true
        expanded.removeAll()
        restoring = false
        if let meter = ETCatalog.first(where: { $0.type == Self.defaultType }) {
            appendSpec(meter)
        }
        publish()
        // 置いた 1 本は開く。replaceChain が全部畳むのは 10 本以上並ぶと
        // 一覧として読めなくなるからで、1 本しか無いならその理由が無い。
        // publish() のあとに入れるのは add(_:) と同じで、didSet の persistExpanded に
        // 確定した鎖の位置を書かせるため。
        if let id = chain.last?.id { expanded.insert(id) }
        for id in external { removeExternal(instanceID: id) }
        retire(doomed)
    }

    /// 1 本足すだけ。publish はしない（呼び手がまとめて 1 回だけ呼ぶ）。
    @discardableResult
    private func append(_ item: PipelineStore.Loaded, to part: ETChainPart = .main) -> Bool {
        var node = Node(spec: item.spec, values: item.values)
        // 自分で置いた終端（PipelineStore.parseが印から戻す）。leaveSectionが挿すものと同じで、
        // instanceは持たない。isSectionが偽なのでinstantiateへ渡すと失敗して落ちる。
        if item.isRootReset {
            node.isRootReset = true
            withPart(part) { $0.append(node) }
            return true
        }
        node.enabled = item.enabled
        node.inputBus = item.inputBus
        node.outputBus = item.outputBus
        node.channelSpec = item.channelSpec
        node.sectionName = item.sectionName
        node.irId = item.irId
        node.display = item.display
        node.design = item.design
        node.externalID = item.externalID.isEmpty ? nil : item.externalID
        if node.isExternal {
            // 空か、既に鎖に居る外部の段と同じ身元なら新しく作る（ETChainEditing.externalInstanceID）。
            // host は main と補正で共通なので、両方の身元を避ける。
            node.externalInstanceID = ETChainEditing.externalInstanceID(
                requested: item.externalInstanceID,
                taken: Set((chain + correction).filter(\.isExternal).map(\.externalInstanceID)))
            node.externalState = item.externalState
            guard let index = try? ETAUExternalBridge.shared.reserve(
                instanceID: node.externalInstanceID) else { return false }
            node.externalIndex = index
            restoreExternal(node)
        }
        if node.isExternal {
            withPart(part) { $0.append(node) }
            return true
        }
        guard instantiate(&node) else { return false }
        withPart(part) { $0.append(node) }
        return true
    }

    /// 型名から spec を引く。Section はカタログに載っていないので別に見る。
    static func spec(forType type: String) -> ETEffect? {
        if type == ETSection.type { return ETSection.spec }
        return ETCatalog.first { $0.type == type }
    }

    /// IR Reverb が使っている素材の鍵を覚える。
    ///
    /// **音には伝えない。** 素材そのものは ETIRLoader が送り込んでいて、
    /// ここに書くのは「次に開いたときどれを入れ直すか」の印。
    func setIRId(_ id: String, at index: Int) {
        guard contains(slot: index), self[slot: index].irId != id else { return }
        self[slot: index].irId = id
        persist()
    }

    func externalStateDidChange(instanceID: String) {
        guard chain.contains(where: { $0.isExternal && $0.externalInstanceID == instanceID })
            || correction.contains(where: { $0.isExternal && $0.externalInstanceID == instanceID })
        else { return }
        // Capturing fullStateForDocument can archive a sizeable object. Parameter
        // observers fire continuously while a native AU knob is dragged, so let
        // the existing debounce capture it once in persist() instead.
        persistSoon()
    }

    /// 外部の段の中身が別のidのものに替わった（JSFXを取り込み直して前の版を置き換えた）。
    /// **鎖が控えているidを、いま鳴っている版のidへ付け替える**（ETJSFXHost.build）。
    ///
    /// 付け替えないと、鎖・プリセット・iCloud・共有リンクは前の版のidを書き続ける。
    /// 前のidはJSFX/aliases.jsonの付け替えでしか引けないので、それを持たない端末や、
    /// 新しい版を消して入れ直した後では段が建たない。どの版が書いた状態かも分からなくなる。
    /// 音には触らない（descriptorはslotの番号しか持たない）ので出し直さず、保存だけする。
    /// spec.type（"External:<id>"）は古いまま残るが、保存の形には書かれず、読むときに
    /// externalIDから作り直す（PipelineForm.parse）。
    func externalComponentDidChange(instanceID: String, to componentID: String) {
        guard let index = nodes.firstIndex(where: {
            $0.isExternal && $0.externalInstanceID == instanceID
        }), self[slot: index].externalID != componentID else { return }
        self[slot: index].externalID = componentID
        persistSoon()
    }

    /// Section の名前を変える。DSP には伝えない（section.js の `cm` は音に効かない）。
    func setSectionName(_ name: String, at index: Int) {
        guard contains(slot: index), self[slot: index].isSection else { return }
        self[slot: index].sectionName = name
        persist()
    }

    /// 図の見せ方を 1 つ変える。**音には触らない。**
    ///
    /// 上流がプリセットに書いているものだけを持つ（DSP/DisplayParams.swift）。
    /// DSP へは渡さない（descriptor にも instance にも席が無い）が、端末には残す。
    /// 残さないと、アプリを開き直したときに既定へ戻る。
    func setDisplay(_ raw: String, key: String, at index: Int) {
        guard contains(slot: index), self[slot: index].display[key] != raw else { return }
        self[slot: index].display[key] = raw
        persistSoon()
    }

    /// プリセットが運んできた表示の設定（DisplayParams）を当てる。**書かれていない鍵は今のまま**
    /// （上流の setParameters は `if (params.xx !== undefined)` の形）。音には伝えない。
    ///
    /// 画面は .etSaved で現れたときにしか display を読まないので、変わったら作り直させる
    /// （Node.resetCount。resetParams と同じ）。
    func applyDisplay(from params: [String: Any], at index: Int) {
        guard contains(slot: index) else { return }
        let incoming = ETDisplayParam.read(params, type: self[slot: index].spec.type)
        guard !incoming.isEmpty else { return }
        var display = self[slot: index].display
        for (key, value) in incoming { display[key] = value }
        guard display != self[slot: index].display else { return }
        self[slot: index].display = display
        self[slot: index].resetCount &+= 1
        persistSoon()
    }

    /// designerで作る型の設計の材料を覚える。**音には伝えない。**
    ///
    /// 係数はdesignerが送り込んでいて、ここに書くのは「次に鎖を読んだときどう設計し直すか」の印
    /// （DSP/DesignParams.swift）。書き手はdesignerの置き場で、settingsが変わるたびに来る。
    /// 位置ではなくidで引くのは、置き場が段をidで持っていて、並べ替えを跨ぐため。
    func setDesign(_ design: [String: String], nodeID: UUID) {
        guard let index = slot(of: nodeID),
              self[slot: index].design != design else { return }
        self[slot: index].design = design
        persistSoon()
    }

    /// IR Reverb の下ごしらえのつまみ（dc / co / dt / tr）を 1 つ変える。
    ///
    /// カーネルのパラメータではない。IR を送る前にホストでかける処理の設定で
    /// （ETIRPreparation.Options）、変えたら下ごしらえからやり直して送り直す。
    /// 上流も 150ms 待ってからやり直す（ir_reverb.js:273-279 の `_queuePreparation('host', 150)`）。
    /// つまみを引きずっている間は来るたびに前の待ちを捨てるので、送り直すのは止めた後の 1 回だけ。
    func setIRPreparation(_ raw: String, key: String, at index: Int) {
        guard contains(slot: index), self[slot: index].design[key] != raw else { return }
        self[slot: index].design[key] = raw
        persistSoon()
        let id = self[slot: index].id
        pendingIRPreparation[id]?.cancel()
        pendingIRPreparation[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self else { return }
            self.pendingIRPreparation[id] = nil
            // 待っている間に並べ替え・削除があっても、id で引き直す。
            guard let i = self.slot(of: id) else { return }
            self.reloadAsset(at: i)
        }
    }

    /// 待っている IR の下ごしらえのやり直し。段の id ごとに 1 本。
    private var pendingIRPreparation: [UUID: Task<Void, Never>] = [:]

    /// パラメータを 1 つ変える。offset は ETParam.offset（配列なら +i）。
    func setValue(_ value: Float, at index: Int, offset: Int) {
        guard contains(slot: index),
              self[slot: index].values.indices.contains(offset) else { return }
        self[slot: index].values[offset] = value
        // SFZ Note Player: 上流は slider を動かすたびに setParameters を通り、Highest Note は Lowest Note より
        // 下に、Velocity 127 Level は Velocity 1 Level + 1 dB より下にならない（sfz_note_player.js:59-60）。
        if self[slot: index].spec.type == ETChainText.sfzType {
            self[slot: index].values = ETUpstreamNormalize.sfzCrossRules(params: self[slot: index].spec.params,
                                                                          values: self[slot: index].values)
        }
        let before = instanceLatency(of: self[slot: index])
        pushParams(self[slot: index])
        settleAfterParams(at: index, changed: offset, before: before)
        // PC へ写すのは main の段だけ（リモートの位置は main の添字。補正はリモートの間は外してある）。
        if index < chain.count { RemoteMirror.shared.paramsChanged(at: index) }
        // publish() は通さない。descriptor に載るのは並びと入切と鎖の形だけで、
        // 値は pushParams が instance へ直に渡している。
        // ただし端末には残す。残さないと、次に鎖を足す/消す/動かすまで
        // "pipeline.last" が古い値のままで、次の起動でそこへ戻る。
        persistSoon()
    }

    /// パラメータをまとめて差し替える。プリセットの適用はここを通る。
    ///
    /// setValue を回すと et_instance_set_params を値の数だけ撃つことになる
    /// （Tube Simulator なら 24 回）。値はどれも同じ instance の同じ配列へ入るので、
    /// 1 回で渡す。
    ///
    /// **長さが違う配列は受けない。** pushParams は spec.floatCount を渡していて
    /// 配列の長さを見ないので（:703-711）、短いものを入れると確保していない先を
    /// 読ませることになる。
    ///
    /// **後始末は setValue / resetParams と同じにする。**以前はここだけ何もしなかった。
    ///   - 遅延: os の入ったプリセット（歪み系 6 種、0 → 64）や Bass Management の
    ///     Phase / Linear Quality で変わる。組み直さないと帯の Fx と並列の段の位置合わせが古いまま。
    ///   - IR Reverb: cm / lt / cr と、材料の dc / co / dt / tr が変わったら送り直す（settleAfterParams と同じ）。
    ///   - designer で作る型: 値から材料を引き直させる（ETAssetReattach.paramsChanged）。
    ///     FIR Crossover は lt / bc を、Bass Management は全部を params から読む。
    ///     カードを畳んだまま当てるとビューが無いので、ここで呼ばないと誰も呼ばない。
    ///     5Band FIR PEQ・Group Delay EQ / PEQはltをvaluesから、残りの材料をNode.designから
    ///     読み直す（DesignParams.swift）。Room EQとCrosstalkは材料が測定なので何も引き直さない。
    ///     プリセットのlt / fdはその2種では次に設計し直すまで係数に効かない
    ///     （カーネルは入っている係数の遅延のまま鳴り続けるので、無音にはならない）。
    ///
    /// `design`はエフェクトのプリセットが運んできた辞書。そこにある設計の材料（5Band FIR PEQの
    /// 帯域など。DSP/DesignParams.swift）も同じ回で当てる。**書かれていない鍵は今のまま**
    /// （ETDesignParam.applying）。
    ///
    /// **値と材料を書いてから、designerに1度だけ読み直させる。**値を当てて読み直させ、材料を当てて
    /// もう1度読み直させていたときは、5Band FIR PEQでltの違うプリセットがまず古い帯域のまま
    /// その場で送り込まれ（遅延だけの違いはすぐ送り直す）、帯域も違えば続けて本当の設計が
    /// もう1度送り込まれた。送り込むたびに鎖全体が一瞬素通しになる（AssetUploadのholdOffAudioThread）。
    func setValues(_ values: [Float], at index: Int, design params: [String: Any] = [:]) {
        guard contains(slot: index),
              values.count == self[slot: index].values.count else { return }
        let before = instanceLatency(of: self[slot: index])
        let changed = Set(values.indices.filter { values[$0] != self[slot: index].values[$0] })
        let design = ETDesignParam.applying(params, to: self[slot: index].design,
                                            type: self[slot: index].spec.type)
        let redesign = design != self[slot: index].design
        self[slot: index].values = values
        if redesign { self[slot: index].design = design }
        pushParams(self[slot: index])
        // IR Reverb の下ごしらえ（dc / co / dt / tr）は材料の側にあるので、変われば送り直す。
        let preparationChanged = redesign && self[slot: index].spec.type == ETDesignParam.irReverb
        if !changed.isEmpty || preparationChanged {
            if preparationChanged
                || !Self.assetConfigOffsets(of: self[slot: index]).isDisjoint(with: changed) {
                // 送り直すと ETIRLoader.load の中で組み直される。
                reloadAsset(at: index)
            } else if instanceLatency(of: self[slot: index]) != before {
                republish(reason: "遅延が変わった")
            }
        }
        // 畳んだカードにはビューが無いので、ここで呼ばないと誰も呼ばない。
        if !changed.isEmpty || redesign {
            ETAssetReattach.paramsChanged(self[slot: index])
        }
        if index < chain.count { RemoteMirror.shared.paramsChanged(at: index) }
        // setValue と同じ理由で publish() は通さず、端末にだけ残す。
        persistSoon()
    }

    func resetParams(at index: Int) {
        guard contains(slot: index) else { return }
        let before = instanceLatency(of: self[slot: index])
        self[slot: index].values = self[slot: index].spec.defaults
        // 上流の Reset は constructor の値へ戻すので、足した直後と同じ既定を掛ける。
        applyConstructorValues(&self[slot: index])
        // designerの材料も既定へ戻す。上流のResetはgetParameters()を丸ごと写した既定を
        // setParametersへ渡す（pipeline-item-builder.js:392-410）ので、帯域やタップ数も戻る。
        self[slot: index].design = [:]
        // 待っている IR の下ごしらえのやり直しも捨てる（下で IR ごと外す）。
        pendingIRPreparation[self[slot: index].id]?.cancel()
        pendingIRPreparation[self[slot: index].id] = nil
        // 表示の設定も同じ既定に入っている（plugin-manager.js:41-48 は getParameters() から
        // type / id / enabled / バスだけを除く）。空にすれば各画面は自分の既定で描く。
        // 画面は .etSaved で現れたときにしか読まないので、作り直させる（Node.resetCount）。
        self[slot: index].display = [:]
        self[slot: index].resetCount &+= 1
        pushParams(self[slot: index])
        // IR Reverb は ir も既定（''、ir_reverb.js:28）へ戻るので、素材を外して素通しにする。
        // 入れ直すと Reset の後も同じ IR が鳴り続ける。
        let unloaded = !self[slot: index].irId.isEmpty
        if unloaded {
            self[slot: index].irId = ""
            assetInfo[self[slot: index].id] = nil
            AssetUpload.clear(engine: engine, instance: self[slot: index].instance)
        }
        // SFZ は読み込みの状態も戻す（読み込み中なら結果を捨て、失敗の文も消す）。
        if self[slot: index].spec.type == ETChainText.sfzType {
            SFZLoader.shared.forget(nodeID: self[slot: index].id)
        }
        // 経路と測定は鎖の外の置き場にある。上流はどちらも既定に入っているので戻す。
        switch self[slot: index].spec.type {
        case "MatrixPlugin":
            // mx は足した時の対角（matrix.js:105-111）。
            MatrixRouting.shared.reset(self[slot: index], engine: engine)
        case "CrosstalkCancellationPlugin":
            // ll / lr / rl / rr は空、設計の指示は初期値（crosstalk_cancellation.js:46-55）。
            CrosstalkStore.shared.reset(node: self[slot: index])
        case "RoomEqPlugin":
            // 測定の割り当て（ms0-15）は空、設計の設定は初期値（room_eq.js:880-914）。
            RoomEQStore.shared.reset(node: self[slot: index])
        default:
            break
        }
        // 素材を外すとカーネルがその段を有効と数えなくなるので組み直す
        // （入れたときも ETIRLoader.load が組み直している）。
        if unloaded || instanceLatency(of: self[slot: index]) != before {
            republish(reason: unloaded ? "IRを外した" : "遅延が変わった")
        }
        // setValues と同じ。値から材料を引く designer に、戻した値を読ませる。
        ETAssetReattach.paramsChanged(self[slot: index])
        if index < chain.count { RemoteMirror.shared.paramsChanged(at: index) }
        persistSoon()
    }

    func clear() {
        let doomed = chain.map(\.instance).filter { $0 != 0 }
        let external = chain.filter(\.isExternal).map(\.externalInstanceID)
        chain.removeAll()
        publish()
        for id in external { removeExternal(instanceID: id) }
        retire(doomed)
    }

    // MARK: - 中身

    private func instantiate(_ node: inout Node) -> Bool {
        guard engine != 0, ready else { return false }

        // Section はカーネルを持たない。呼べば必ず 0 が返り、失敗として弾かれてしまう。
        // 上流も Section を descriptor に入れない（dsp-pipeline-descriptor.js:194-198）。
        if node.isSection {
            node.instance = 0
            node.tapId = 0
            return true
        }

        let typeName = node.spec.type          // inout を os_log に渡せないので控えておく
        let inst = typeName.withCString { et_instance_create(engine, $0) }
        guard inst != 0 else {
            // 0 を返す条件は engine.cpp:314-365 に 4 つ。!prepared_ / 型が registry に無い /
            // objectSize > 16384 / kernel->prepare が preparedSuccessfully() を満たさない。
            // 最後のは sr と maxFrames 次第なので一緒に出す。
            let known = kernelIndex[typeName] != nil
            log.error("et_instance_create に失敗 \(typeName, privacy: .public) known=\(known) ready=\(self.ready) sr=\(self.sampleRate) maxFrames=\(self.maxFrames)")
            return false
        }
        let tap = nextTap
        nextTap &+= 1
        node.instance = inst
        node.tapId = tap
        // **戻り値を見る。** 捨てていたので、失敗しても気づけなかった。
        // 失敗すると slot.tapId は 0 のままで、engine.cpp:561 の TelemetryWriter が
        // tap 0 に書く＝そのノードの図は永久に "Waiting for audio" になる。
        // 返るのは ET_ERR_ARGS（instance が見つからない）か
        // ET_ERR_STATE（graph が持っている slot）。
        let tapStatus = et_instance_set_tap(engine, inst, tap)
        if tapStatus != ET_OK {
            log.error("et_instance_set_tap に失敗 \(typeName, privacy: .public) inst=\(inst) tap=\(tap) status=\(tapStatus)")
            node.tapId = 0
        }
        let made = "instance=\(inst) tap=\(tap) setTap=\(tapStatus) \(typeName)"
        log.notice("\(made, privacy: .public)")
        ETLogTap.record(made)
        if ETConsoleLog.on { print(made) }
        pushParams(node)
        return true
    }

    /// engine を用意し直したあとに呼ぶ。
    ///
    /// **必ず全部作り直す。** Engine::prepare は先頭で destroyAllInstances() を
    /// 呼ぶので（dsp/core/engine.cpp:221）、二度目の prepare で instance が
    /// 全部消える。番号だけ持ったまま descriptor を渡すと slot == nullptr で
    /// ET_ERR_DESC になり、鎖が一切効かなくなる。
    ///
    /// 失敗を握り潰さない。instance が 0 のまま残ったノードは publish() の
    /// filter で descriptor から落ちるが、descriptor 自体は整合しているので
    /// et_pipeline_configure は ET_OK を返す。画面には N 本並んだまま、
    /// 通っているのは 0〜N-1 本という状態になり、status だけ見ても気づけない。
    ///
    /// 鎖が空のときは何もしない。**publish() を通すと persist() が走り、
    /// まだ何も無いうちに "pipeline.last" へ [] が書かれる。** すると直後の
    /// restore() で PipelineStore.hasSaved が true になり、既定の Level Meter を
    /// 置く枝（loadLast が [] を返すので第一の枝は外れる）へ二度と入らない。
    /// 初回起動から鎖が空のまま＝ノード 0 本＝applied 0 になっていた。
    ///
    /// 出力補正の段も同じく作り直す（OutputCorrection.dspPrepared は入っていれば何もしない）。
    private func rebuildAll() {
        guard ready, !(chain.isEmpty && correction.isEmpty) else { return }
        var failed: [String] = []
        for i in chain.indices {
            chain[i].instance = 0
            chain[i].tapId = 0
            if chain[i].isExternal { continue }
            if !instantiate(&chain[i]) { failed.append(chain[i].spec.type) }
        }
        for i in correction.indices {
            correction[i].instance = 0
            correction[i].tapId = 0
            if correction[i].isExternal { continue }
            if !instantiate(&correction[i]) { failed.append(correction[i].spec.type) }
        }
        if !failed.isEmpty {
            let total = chain.count + correction.count
            log.error("rebuild で instance を作れなかった \(failed.count)/\(total): \(failed.joined(separator: ","), privacy: .public)")
        }
        publish()
        // **instance を作り直したら資産も入れ直す。**
        // 資産は instance が持っているので、作り直すと消える。
        // ここは出力先の切り替え・レート変更・オーバーサンプリングの変更で走る
        // （prepare → rebuildAll）。入れ直さないと IR が黙って外れる。
        //
        // **次の回に回す。** ここは音の経路を組む途中で、素材を読むのは重い
        // （4ch を伸縮して数 MB）。同期でやると起動が詰まって SIGKILL で殺される。
        Task { @MainActor [weak self] in
            self?.reloadAssets()
            // designer で作る 5 種も同じ理由で消えている。ビューに任せると
            // 畳んだカードでは走らない（AssetReattach.swift の頭）。
            ETAssetReattach.all()
        }
    }

    // MARK: - 図に重ねるための探り

    /// 図にスペクトラムを重ねるためだけに置く Spectrum Analyzer。段 1 つに 2 台
    /// （入口と出口）。上流のオーバーレイが段の前後で音を横取りするのと同じ位置
    /// （plugins/audio-processor.js:5142-5157 が入口、:5275-5307 が出口）。
    ///
    /// **chain には入れない。** PipelineStore は chain をそのまま保存形式へ落とす
    /// ので、入れるとプリセットと共有リンクに上流に無い段が生える。
    /// descriptor（publish / republish）にだけ足す（ETChainEditing.descriptors）。
    ///
    /// Spectrum Analyzer のカーネルは音を素通しする
    /// （dsp/plugins/analyzer/spectrum_analyzer/kernel.cpp:190-239 の process は
    ///   audio を読むだけで一度も書かない）ので、間に挟んでも音は変わらない。
    private struct Probe {
        var instance: UInt32
        var tapId: UInt32
    }

    private struct ProbePair {
        /// 段に入る音（相手の直前）。
        var before: Probe
        /// 段から出た音（相手の直後）。
        var after: Probe
    }

    /// 図に重ねる音の tap。before = 段に入る音、after = 段から出た音。
    struct ProbeTaps: Equatable {
        var before: UInt32
        var after: UInt32
    }

    /// 段の id → 探り。
    private var probes: [UUID: ProbePair] = [:]

    /// 探りを足した・外したら 1 進む。探りは publish() で作るので、$chain の後になることがある。
    /// PoC: RemoteMirror が PC の重ね表示を映す tap を決め直すのに見る。
    @Published private(set) var probeRevision = 0

    /// 図に音を重ねる段の型。上流の対応表（plugins/spectrum-overlay.js:17-37）から、
    /// こちらに専用の図があるものだけ。
    private static let probedTypes: Set<String> = ["FiveBandPEQPlugin", "FifteenBandPEQPlugin"]
    private static let probeType = "SpectrumAnalyzerPlugin"

    /// 探りの Points。上流のオーバーレイは FFT 4096 点固定
    /// （spectrum-overlay.js:2-3 の `FFT_POINTS = 12`、`FFT_SIZE = 1 << FFT_POINTS`）。
    ///
    /// 前は 10（1024 点）に落としていた。枠 16KB が 60Hz で出てテレメトリの輪が溢れる、
    /// という見立てだったが、**出る回数はそれより少ない。**カーネルは新しい解析が
    /// できた回だけ書き（kernel.cpp:241-254 の frame_generation_）、解析の間隔は
    /// FFT の半分と 1/30 秒の長い方（同 :359-368、:48 の kMaximumFrameRateHz = 30）。
    /// 12 なら 2048 サンプルごと＝48kHz で 23.4 回/秒 × 16.4KB ≒ 384KB/秒 が 1 台ぶん。
    /// PEQ 1 枚に 2 台で 768KB/秒、画面の 1 回（60Hz）あたり約 13KB。
    /// 輪は 1MB にした（telemetryRingBytes）ので、PEQ を 4 枚並べても
    /// 汲む側が 0.3 秒止まるまでは溢れない。
    private static let probePoints: Float = 12

    /// その段の図に重ねる音の tap。まだ無ければ nil。
    func probeTaps(at index: Int) -> ProbeTaps? {
        guard let n = self.node(at: index), let pair = probes[n.id] else { return nil }
        return ProbeTaps(before: pair.before.tapId, after: pair.after.tapId)
    }

    /// 要る探りを作り、要らなくなったものを外す。publish のたびに呼ぶ。
    ///
    /// **外した探りはここで壊さない。番号を返す。**
    /// 走っている descriptor にはまだ探りが enabled: 2 で載っていて、
    /// 音のスレッドはその kernel の中に居ることがある。ここで壊すと
    /// Spectrum Analyzer の FFT の器を解放後に書く（ASan で再現した）。
    /// 呼び手は Publish のあとで retire() へ渡す。native の段と同じ扱い。
    private func syncProbes() -> [UInt32] {
        guard engine != 0, ready else { return [] }

        // バスを分けている段は、engine.cpp:978-990 が出口で足し込む＝他の音と混ざる。
        // 「その段に入る音」「その段から出た音」と呼べるのは入口と出口が同じバスのときだけ。
        let all = nodes
        let candidates = all.filter {
            Self.probedTypes.contains($0.spec.type)
                && $0.instance != 0
                && $0.inputBus == $0.outputBus
        }.map(\.id)
        // **人が置いた段を descriptor から押し出さない。** ETPipeline_Publish は
        // ET_PIPE_MAX_NODES（ETPipeline.h:30、64）を越えた分を黙って切る
        // （ETPipeline.c:299）。探りは段 1 つに 2 本足すので、残りの枠に収まる数だけ、
        // 鎖の前から順に付ける。
        let placed = all.filter { $0.instance != 0 || $0.isExternal }.count
        let budget = max(0, (Int(ET_PIPE_MAX_NODES) - placed) / 2)
        let want = Set(candidates.prefix(budget))

        var doomed: [UInt32] = []
        var changed = false
        defer { if changed { probeRevision &+= 1 } }
        for id in Array(probes.keys) where !want.contains(id) {
            if let pair = probes[id] { doomed += [pair.before.instance, pair.after.instance] }
            probes[id] = nil
            changed = true
        }

        guard let spec = ETCatalog.first(where: { $0.type == Self.probeType }) else { return doomed }
        for id in want where probes[id] == nil {
            // 2 台そろわなければ置かない。片方だけ作れたものは、どの descriptor にも
            // 載っていないが、壊すと鎖ごと作り直される（invalidatePipeline）ので
            // 外した探りと一緒に retire() へ回す。次の publish でまた作り直す。
            let before = makeProbe(spec, doomed: &doomed)
            let after = makeProbe(spec, doomed: &doomed)
            guard let before, let after else {
                if let before { doomed.append(before.instance) }
                if let after { doomed.append(after.instance) }
                continue
            }
            probes[id] = ProbePair(before: before, after: after)
            changed = true
        }
        return doomed
    }

    /// 探りを 1 台作る。作れなければ nil（作りかけの instance は doomed へ積む）。
    private func makeProbe(_ spec: ETEffect, doomed: inout [UInt32]) -> Probe? {
        let inst = Self.probeType.withCString { et_instance_create(engine, $0) }
        guard inst != 0 else { return nil }
        let tap = nextTap
        nextTap &+= 1
        guard et_instance_set_tap(engine, inst, tap) == ET_OK else {
            // ここ（publish の中・メイン）で壊すと音のスレッドを待つことになり、
            // JSFX の長いブロックの間ずっと画面が止まる。retire() に任せる。
            doomed.append(inst)
            return nil
        }
        var v = spec.defaults
        if let pt = spec.params.first(where: { $0.key == "pt" }),
           v.indices.contains(pt.offset) {
            v[pt.offset] = Self.probePoints
        }
        _ = v.withUnsafeBufferPointer {
            et_instance_set_params(engine, inst, $0.baseAddress,
                                   UInt32(spec.floatCount), spec.paramsHash, 0)
        }
        return Probe(instance: inst, tapId: tap)
    }

    private func pushParams(_ node: Node) {
        guard engine != 0, node.instance != 0, node.spec.floatCount > 0 else { return }
        var v = node.values
        let st = v.withUnsafeBufferPointer {
            et_instance_set_params(engine, node.instance, $0.baseAddress,
                                   UInt32(node.spec.floatCount), node.spec.paramsHash, 0)
        }
        log.notice("set_params=\(st) \(node.spec.type, privacy: .public) n=\(node.spec.floatCount) v0=\(v.first ?? 0)")
    }

    /// Section の入切を、配下の段の sectionGate へ落とす。
    ///
    /// 上流は descriptor を組むたびに走らせている（dsp-pipeline-descriptor.js:190-212）。
    /// こちらも publish のたびに引き直す。sectionGate は鎖の並びから決まる値で、
    /// 段ごとに持たせる設定ではない。
    ///
    /// chain に書き戻すのは、descriptor を組み直す口がここだけではないため。
    /// republish()（retire や各 designer の遅延変更から呼ばれる）は chain から
    /// ETPipeNode を作り直していて、そこは node.sectionGate をそのまま読む。
    private func applySectionGates() {
        // **答えを出すのは ETPipelineAnalysis だけ。**ここは書き戻すだけで、
        // 数え方をここにも持たない（持つと二重管理になる。前は ETSection.gates が
        // 名前と型から数えていて、rootReset を Section と区別できなかった。もう消してある）。
        // main と補正の両方へ書く。答えは部分ごとに出したものを合わせてあるので、
        // main の終わりの OFF Section が補正の段を止めることはない。
        let a = analysis
        for i in chain.indices {
            let gate = chain[i].role == .effect ? a.gate(of: chain[i].id) : 1
            if chain[i].sectionGate != gate { chain[i].sectionGate = gate }
        }
        for i in correction.indices {
            let gate = correction[i].role == .effect ? a.gate(of: correction[i].id) : 1
            if correction[i].sectionGate != gate { correction[i].sectionGate = gate }
        }
    }

    /// いまの鎖の所属と gate。**派生値なので持ち回らない。**
    ///
    /// main と出力補正は別々に走らせて合わせる（ETPipelineAnalysis.merged）。
    /// 補正は main の後ろに独立して付く層で、main の組に入らない。
    var analysis: ETPipelineAnalysis {
        let main = Self.analyze(chain)
        guard !correction.isEmpty else { return main }
        return ETPipelineAnalysis.merged([main, Self.analyze(correction)])
    }

    private static func analyze(_ list: [Node]) -> ETPipelineAnalysis {
        ETPipelineAnalysis.analyze(roles: list.map(\.role),
                                   ids: list.map(\.id),
                                   enabled: list.map(\.enabled))
    }

    /// 有効なものだけを並べて音のスレッドへ渡す。
    private func publish() {
        applySectionGates()
        let retiredProbes = syncProbes()
        // Section は instance を持たないのでここで落ちる。上流も同じく
        // descriptor に入れない（dsp-pipeline-descriptor.js:194-198）。
        let nodes = pipeNodes()
        nodes.withUnsafeBufferPointer { ETPipeline_Publish($0.baseAddress, UInt32($0.count)) }
        // 外した探りは、探りの無い descriptor を出したあとで壊す。
        retire(retiredProbes)
        // nodes と chain の両方を出す。食い違っていたら instance を作れなかった
        // ノードが混ざっている＝画面の本数だけ音が通っていない。
        // Section は必ず descriptor から外れるので、先に引いて dead と分ける。
        // 分けないと Section を 1 本置くたびに dead が 1 増えて、取りこぼしと見分けが付かない。
        // 探り（enabled 2）は人が置いた段ではないので、どの数にも入れない
        // （入れると PEQ 1 枚ごとに dead が 2 減り、active が 2 増える）。
        // dead と sections は main と補正を合わせて数える（descriptor は両方から作る）。
        let all = self.nodes
        let placed = nodes.filter { $0.enabled != 2 }
        let sections = all.filter(\.isSection).count
        let dead = all.count - sections - placed.count
        let active = placed.filter { $0.enabled != 0 && $0.sectionGate != 0 }.count
        let gated = placed.filter { $0.enabled != 0 && $0.sectionGate == 0 }.count
        let pub = "publish nodes=\(nodes.count) chain=\(chain.count) oc=\(correction.count) sections=\(sections) dead=\(dead) active=\(active) gated=\(gated) taps=\(all.map { String($0.tapId) }.joined(separator: ",")) types=\(all.map(\.spec.type).joined(separator: ","))"
        log.notice("\(pub, privacy: .public)")
        ETLogTap.record(pub)
        if ETConsoleLog.on { print(pub) }
        // 枠（ET_PIPE_MAX_NODES）は main と補正で共有。越えた分は ETPipeline_Publish が黙って
        // 切り、補正は後ろなので先に切れる。止めずに記すだけ。
        if nodes.count > Int(ET_PIPE_MAX_NODES) {
            let over = "publish over limit n=\(nodes.count) max=\(ET_PIPE_MAX_NODES) （補正が切れる）"
            log.notice("\(over, privacy: .public)")
            ETLogTap.record(over)
            if ETConsoleLog.on { print(over) }
        }
        // 無音でも回し続ける段の有無で、休むまでの秒数が変わる（AudioIO.refreshGateIdle）。
        onPublished?()
        persist()
    }

    /// 鎖を出し直したときに呼ぶ。AudioIO が休む秒数を決め直すのに使う（AudioIO と互いに生成を待たないよう、引かずに受ける）。
    var onPublished: (() -> Void)?

    /// その段の実行時の事故が残っているか（et_instance_runtime_event の latched）。
    /// Adaptive Prediction が数値の失敗を起こすと立つ。Reset（resetToken）で下りる。
    func runtimeFault(at index: Int) -> Bool {
        guard engine != 0, contains(slot: index), self[slot: index].instance != 0 else { return false }
        var state = et_runtime_event_state()
        guard Int(et_instance_runtime_event(engine, self[slot: index].instance, &state)) == ET_OK else { return false }
        return state.latched != 0
    }

    /// 音のスレッドへ渡す並び。**中身は ETChainEditing.descriptors が決める**
    /// （探りは相手の直前・enabled 2、上流が受けない Ch の段は切）。
    /// ここは C の ETPipeNode へ写すだけで、publish と republish が同じものを出す。
    private func pipeNodes() -> [ETPipeNode] {
        // main の後ろに補正。境の印は要らない（engine は段ごとの sectionGate しか読まない）。
        ETChainEditing.descriptors(chain: chain + correction,
                                   probes: probes.mapValues(\.before.instance),
                                   afterProbes: probes.mapValues(\.after.instance)).map { d in
            ETPipeNode(instance: d.instance,
                       enabled: d.enabled,
                       inputBus: d.inputBus,
                       outputBus: d.outputBus,
                       channelSpec: d.channelSpec,
                       sectionGate: d.sectionGate,
                       kind: UInt8(d.kind == .external ? ET_PIPE_NODE_EXTERNAL : ET_PIPE_NODE_NATIVE),
                       externalIndex: d.externalIndex)
        }
    }

    /// 鎖の形を変える。既定は 0→0 の All。
    ///
    /// sectionGate は受けるが残らない。Section の入切と鎖の並びから決まる値なので、
    /// この直後の publish() が applySectionGates() で引き直す。
    func setRouting(at index: Int, inputBus: UInt8? = nil, outputBus: UInt8? = nil,
                    channelSpec: Int8? = nil, sectionGate: UInt8? = nil) {
        guard contains(slot: index) else { return }
        let previousChannels = Self.routedChannels(of: self[slot: index])
        let previousExternalChannels = Self.externalChannels(of: self[slot: index])
        let previousBypass = Self.isChannelBypassed(self[slot: index])
        if let v = inputBus    { self[slot: index].inputBus = v }
        if let v = outputBus   { self[slot: index].outputBus = v }
        if let v = channelSpec { self[slot: index].channelSpec = v }
        if let v = sectionGate { self[slot: index].sectionGate = v }
        publish()
        // 処理幅が変わると、幅を含めて設計する資産（FIR Crossover、Bass Management）は
        // 送り直しが要る。Routing は別の画面から変えるので、カードのビューが居るとは限らない。
        // 幅が同じでも外れる・戻るときは designer に知らせる（Bass Management は All 以外で外れる）。
        if !self[slot: index].isExternal,
           Self.routedChannels(of: self[slot: index]) != previousChannels
            || Self.isChannelBypassed(self[slot: index]) != previousBypass {
            ETAssetReattach.paramsChanged(self[slot: index])
        }
        if self[slot: index].isExternal {
            let channels = Self.externalChannels(of: self[slot: index])
            if channels != previousExternalChannels {
                if self[slot: index].externalID?.hasPrefix("jsfx:") == true {
                    ETJSFXHost.shared.setChannels(channels,
                                                  instanceID: self[slot: index].externalInstanceID)
                } else {
                    ETAUHost.shared.setChannels(channels,
                                                instanceID: self[slot: index].externalInstanceID)
                }
                AudioIO.shared.rebuildForExternalProcessor()
            }
        }
    }

    private func externalState(for node: Node) -> Data? {
        if node.externalID?.hasPrefix("jsfx:") == true {
            return ETJSFXHost.shared.stateData(instanceID: node.externalInstanceID)
        }
        return ETAUHost.shared.stateData(instanceID: node.externalInstanceID)
    }

    private func restoreExternal(_ node: Node) {
        guard let componentID = node.externalID else { return }
        let channels = Self.externalChannels(of: node)
        if componentID.hasPrefix("jsfx:") {
            ETJSFXHost.shared.restore(componentID: componentID,
                                      instanceID: node.externalInstanceID,
                                      state: node.externalState, channels: channels)
        } else {
            ETAUHost.shared.restore(componentID: componentID,
                                    instanceID: node.externalInstanceID,
                                    state: node.externalState, channels: channels)
        }
    }

    private func removeExternal(instanceID: String) {
        // Only one host owns the ID. Calling both also handles an unavailable
        // plug-in whose component metadata could not be restored.
        ETAUHost.shared.remove(instanceID: instanceID)
        ETJSFXHost.shared.remove(instanceID: instanceID)
    }

    /// 外した instance を、音のスレッドが読み終えてから壊す。
    ///
    /// **壊すのは ETPipeline_DestroyInstances、それもメインで。**
    /// ProcessCount を 2 つ待って守れるのは壊す instance だけで、
    /// et_instance_destroy が一緒に作り直す pipeline_ と遅延補正の線
    /// （engine.cpp:119-129）は守れない。音のスレッドがその線を読んでいる最中に
    /// 解放すると落ちる（ASan で % 0 と解放後の書き込みを再現した）。
    /// メインに寄せるのは et_instance_create と同じスレッドにするため。
    /// createInstance は kernel が空いた枠を拾うので、別のスレッドで壊している
    /// 途中の枠を掴みうる。
    private func retire(_ instances: [UInt32]) {
        guard !instances.isEmpty, engine != 0 else { return }
        let engine = self.engine
        let mark = ETPipeline_ProcessCount()
        let generation = prepareGeneration
        Task.detached(priority: .utility) {
            // 音のスレッドが 2 周するのを待つ。鳴っていなければ待っても進まないので、
            // 0.5 秒で諦めて壊す（鳴っていない＝誰も読んでいない）。
            let deadline = Date().addingTimeInterval(0.5)
            while ETPipeline_ProcessCount() < mark + 2 && Date() < deadline {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            // **壊すと鎖ごと無効になるので、必ず組み直す。**
            //
            //   void Engine::destroyInstance(et_instance instance) noexcept {
            //     InstanceSlot *slot = findInstance(instance);
            //     if (slot != nullptr && !slot->graphOwned) {
            //       destroySlot(*slot);
            //       invalidatePipeline();        // pipeline_configured_ = false
            //     }
            //   }
            //   （engine.cpp:395-401）
            //
            // 1 つ壊すだけで pipeline_configured_ が落ち、そのあと
            // processPipeline は毎ブロック ET_ERR_STATE を返す（engine.cpp:709-711）。
            // 処理もテレメトリも止まるので、鎖は画面に出ているのに音が通らず、
            // 図は "Waiting for audio" のまま。実機で測った:
            //   tick out=Speaker applied=0 active=1 chain=1 peer=true cfgStatus=0 proc=-2
            //
            // こちらは publish() のあとに（音のスレッドを待ってから）壊すので、
            // 順番として必ずこうなる。段の入切で直っていたのは、
            // setEnabled が publish() を呼んで configure がやり直されるから。
            //
            // 呼び出し元は remove / clear / resetToDefault / replaceChain と
            // publish（外した探り）で、どれも同じ経路を通る。ここで 1 回組み直せば全部に効く。
            // 壊すのと同じメインの 1 回で組み直すので、素通しになるのは多くて 1 ブロック。
            //
            // **音のスレッドが JSFX の長いブロックから戻らなければ、メインで待ち続けない。**
            // DestroyInstances は 50 ms で諦めて何も壊さずに戻る。ここで間を置いて
            // 呼び直す。待ち切ると、そのブロックが終わるまで画面が止まる。
            while true {
                let done = await MainActor.run { () -> Bool in
                    // Engine::prepare の destroyAllInstances が既に壊しており、番号が使い回されうる。
                    // ここで壊すと、組み直した後の生きた instance を消してしまう。
                    if EffeTuneDSP.shared.prepareGeneration != generation {
                        EffeTuneDSP.shared.republish(reason: "prepareをまたいだので壊さない")
                        return true
                    }
                    let ok = instances.withUnsafeBufferPointer {
                        ETPipeline_DestroyInstances(engine, $0.baseAddress, UInt32($0.count))
                    } != 0
                    if ok { EffeTuneDSP.shared.republish() }
                    return ok
                }
                if done { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    /// descriptor だけ出し直す。端末には書かない。
    /// retire が壊したあとに pipeline_configured_ を立て直すためのもので、
    /// 鎖の中身は変わっていないので保存する理由が無い。
    func republish(reason: String = "壊したので組み直した") {
        guard engine != 0 else { return }
        let nodes = pipeNodes()
        nodes.withUnsafeBufferPointer { ETPipeline_Publish($0.baseAddress, UInt32($0.count)) }
        let line = "republish nodes=\(nodes.count) （\(reason)）"
        log.notice("\(line, privacy: .public)")
        ETLogTap.record(line)
        if ETConsoleLog.on { print(line) }
    }
}
