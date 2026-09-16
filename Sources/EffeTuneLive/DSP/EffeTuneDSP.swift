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

    /// 鎖に並んでいる 1 個。
    struct Node: Identifiable {
        let id = UUID()
        let spec: ETEffect
        var values: [Float]
        var enabled: Bool = true
        /// Analyzer を図だけで見る。パラメータ行を畳む。
        var instance: UInt32 = 0
        /// 描画用の値がどのエフェクトから出たかを見分ける番号。
        var tapId: UInt32 = 0
        /// Section の名前（section.js の `cm`）。Section 以外では空。
        /// ETParam は float しか運べないので values には入れられない。
        var sectionName: String = ""
        /// IR Reverb が使っている素材の鍵（中身の sha256 先頭 24 桁）。
        /// IR Reverb 以外では空。sectionName と同じで、float に載らないので
        /// values ではなくここに持つ。上流のプリセットは `ir` という名前で書く
        /// （plugins/reverb/ir_reverb.js:866）。
        var irId: String = ""

        // --- 鎖の形 ---
        // 普通の使い方では全部 0→0 の All なので、既定から外れたものだけ画面に出す。
        var inputBus: UInt8 = 0
        var outputBus: UInt8 = 0
        var channelSpec: Int8 = -1      // Stereo。EffeTune の既定に合わせてある
        var sectionGate: UInt8 = 1

        /// 上の Section で止められている。
        /// これは鎖の並びから publish のたびに引き直す値で、
        /// 人が触ったルーティングではない。だから isDefaultRouting とは別に持つ。
        var isGated: Bool { sectionGate == 0 }

        var isDefaultRouting: Bool {
            // sectionGate をここに入れない。
            // Section を切ると配下の gate が 0 になるので、
            // ルーティングを一切触っていない段にまで印が付き、
            // Routing に「Reset routing」が生えてしまう。
            // それを押しても gate は publish で引き直され、
            // 代わりに全段の bus / channel が既定へ戻る。
            inputBus == 0 && outputBus == 0 && channelSpec == -1
        }

        /// 音を触らない飾り。DSP の instance を持たない。
        var isSection: Bool { ETSection.isSection(spec) }

        /// 音が通る形になっているか。false のものは publish の filter で descriptor から
        /// 落ちるので、画面に並んでいても音は通らない。UI はこれを出して区別する。
        /// 保存せず instance から引くのは、片方だけ古くなるのを避けるため。
        ///
        /// Section は instance を持たないが死んでいるわけではない。カーネルが無いので
        /// et_instance_create は必ず 0 を返す（engine.cpp:314-365 の registry 引き）。
        /// 上流も Section を descriptor に入れない
        /// （js/audio/dsp-pipeline-descriptor.js:194-198 の continue）。
        var alive: Bool { isSection || instance != 0 }
    }

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

    /// 図も出さずに畳んでいるもの。
    ///
    /// **`expanded` の意味は変えていない。** 畳んでいて、ここに入っていなければ
    /// 「図だけ」。ここに入っていれば「名前の行だけ」。
    /// そうしたのは、既に端末に残っている `expanded` をそのまま生かすため。
    @Published var collapsedFully: Set<UUID> = []

    /// restore() の最中だけ true。読み込みで入れた値を書き戻さないため。
    private var restoring = false
    @Published private(set) var ready = false
    @Published var bypass = false { didSet { ETPipeline_SetBypass(bypass ? 1 : 0) } }

    /// テレメトリを読むのに要るので外へ出す。
    private(set) var engine: UInt32 = 0
    private var nextTap: UInt32 = 1
    /// 組んであるレート。IR を送るときの解決に要る（IRLoader）。
    private(set) var sampleRate: Double = 48000
    private var maxFrames: UInt32 = 4096
    private var kernelIndex: [String: UInt32] = [:]

    /// 利用できるエフェクト。カーネルとして登録されているものだけ。
    private(set) var available: [ETEffect] = []

    /// 可視化の値を貯める輪の大きさと、1 秒あたりに出す回数。
    private static let telemetryRingBytes: UInt32 = 256 * 1024
    private static let telemetryHz: Float = 60

    /// 何も無いときに置く 1 本。restore() の既定と resetToDefault() が同じものを
    /// 指すように、型名はここだけに書く。
    private static let defaultType = "LevelMeterPlugin"

    private init() {}

    // MARK: - 用意

    func prepare(sampleRate: Double, maxChannels: UInt32 = 2, maxFrames: UInt32 = 4096) {
        self.sampleRate = sampleRate
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
    }

    func reset() {
        guard engine != 0 else { return }
        et_engine_reset(engine)
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

    /// 1 本足すだけ。publish はしない。
    /// まとめて足すときに 1 本ごとに configure を走らせないよう、単発用と分けてある。
    @discardableResult
    private func appendSpec(_ spec: ETEffect) -> Bool {
        var node = Node(spec: spec, values: spec.defaults)
        if node.values.count != spec.floatCount {
            node.values = spec.defaults + Array(repeating: 0,
                                                count: max(0, spec.floatCount - spec.defaults.count))
        }
        guard instantiate(&node) else { return false }
        chain.append(node)
        return true
    }

    func remove(at offsets: IndexSet) {
        let doomed = offsets.map { chain[$0].instance }.filter { $0 != 0 }
        chain.remove(atOffsets: offsets)
        publish()
        retire(doomed)
    }

    /// 鎖の並びを変える。位置は**鎖の添字**（画面の行番号ではない）。
    ///
    /// 動かした先が畳んだ Section の配下なら、その Section を開く（revealHidden）。
    /// 開かないと動かした行が画面から消え、どこへ行ったのか分からなくなる。
    /// 畳んだ Section と一緒に運ばれた配下は開く理由に数えない。Section ごと
    /// 動かしただけで、畳んでおいた中身が勝手に開いてしまうため。
    func move(from source: IndexSet, to destination: Int) {
        let types = chain.map(\.spec.type)
        // 連れて行かれるだけの配下。掴んだ行ではないので開く対象から外す。
        var carried: Set<UUID> = []
        for i in source where chain.indices.contains(i) {
            guard chain[i].isSection, !expanded.contains(chain[i].id) else { continue }
            for j in ETSection.range(after: i, types: types) where source.contains(j) {
                carried.insert(chain[j].id)
            }
        }
        let grabbed = Set(source.compactMap { chain.indices.contains($0) ? chain[$0].id : nil })
            .subtracting(carried)

        chain.move(fromOffsets: source, toOffset: destination)
        publish()
        revealHidden(grabbed)
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
        let types = chain.map(\.spec.type)
        for i in chain.indices
        where chain[i].isSection && !expanded.contains(chain[i].id) {
            let inside = ETSection.range(after: i, types: types)
            if inside.contains(where: { ids.contains(chain[$0].id) }) {
                expanded.insert(chain[i].id)
            }
        }
    }

    func setEnabled(_ enabled: Bool, at index: Int) {
        guard chain.indices.contains(index) else { return }
        chain[index].enabled = enabled
        publish()
    }

    /// 端末に残す。次の起動で同じ鎖が出る。
    private func persist() {
        // まとめ待ちを潰してから書く。待っていた内容はいまの chain に入っている。
        pendingPersist?.cancel()
        pendingPersist = nil
        PipelineStore.saveLast(chain)
        persistExpanded()
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
                restoring = true
                expanded = Set(chain.map(\.id))
                restoring = false
                publish()
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
        } else if !PipelineStore.hasSaved {
            if let meter = ETCatalog.first(where: { $0.type == Self.defaultType }) {
                add(meter)
            }
        }
    }

    /// プリセットを**いまの鎖へ足す**。置き換えない。
    ///
    /// 上流 preset-manager.js:78 addPresetToPipeline と同じ組み立てにしてある:
    ///   1. 先頭に Section を 1 本。名前（cm）はプリセット名（:95-105）
    ///   2. その後ろにプリセットの中身（:165）
    ///   3. **挿入先の次が Section でなく、末尾でもないなら**、終端用の
    ///      名前の無い Section をもう 1 本（:149-160, :166-168）。
    ///      後ろにあった鎖がこのプリセットの区切りに巻き込まれないように切る
    ///   4. 足したものは全部開いた状態にする（:170-172 expandedPlugins.add）
    ///
    /// 置き換えではないので、プリセットを 2 つ選べば 2 つとも鎖に並ぶ。
    /// 鎖を捨てたいときは ⋯ の Reset Pipeline を使う。
    ///
    /// index を省くと末尾へ足す（上流の insertionIndex = null と同じ）。
    func addPreset(named name: String, items: [PipelineStore.Loaded], at index: Int? = nil) {
        guard ready, !items.isEmpty else { return }
        let target = min(max(index ?? chain.count, 0), chain.count)

        var toAdd: [PipelineStore.Loaded] = [
            // **channelSpec は -1（Stereo）。** 0 は Left で、
            // ここに 0 を入れていたせいでプリセットを読むだけで Routing が
            // 既定から外れ、触っていないのに「Reset routing」が生えていた。
            // 保存や共有リンクにも Section へ "ch":"L" が混ざり、
            // 再起動すると parse が -1 に直すので表示だけ変わっていた。
            PipelineStore.Loaded(spec: ETSection.spec, values: [], enabled: true,
                                 inputBus: 0, outputBus: 0, channelSpec: -1,
                                 sectionName: name)
        ]
        toAdd += items

        // 末尾に足すなら閉じる必要が無い（その先に何も無い）。
        // 次が既に Section ならそれが区切りになるので、重ねない。
        let nextIsSection = target < chain.count && chain[target].isSection
        if target < chain.count && !nextIsSection {
            toAdd.append(PipelineStore.Loaded(spec: ETSection.spec, values: [], enabled: true,
                                              inputBus: 0, outputBus: 0, channelSpec: -1,
                                              sectionName: ""))
        }

        var made: [Node] = []
        for item in toAdd {
            var node = Node(spec: item.spec, values: item.values)
            node.enabled = item.enabled
            node.inputBus = item.inputBus
            node.outputBus = item.outputBus
            node.channelSpec = item.channelSpec
            node.sectionName = item.sectionName
            guard instantiate(&node) else { continue }
            made.append(node)
        }
        guard !made.isEmpty else { return }

        chain.insert(contentsOf: made, at: target)
        publish()
        // 足したものは開いて出す。上流も expandedPlugins に入れている。
        // publish() の後に入れるのは、persistExpanded に確定後の位置を書かせるため。
        for node in made { expanded.insert(node.id) }
    }

    /// 鎖をまるごと入れ替える。共有リンクの取り込みで使う。
    ///
    /// プリセットはこちらを通さない。上流は足す側なので addPreset(named:items:at:) を使う。
    func replaceChain(with items: [PipelineStore.Loaded]) {
        guard ready else { return }
        let doomed = chain.map(\.instance).filter { $0 != 0 }
        chain.removeAll()
        // 丸ごと入れ替えたら全部畳む。前の鎖の id は残っていても指す先が無い。
        restoring = true
        expanded.removeAll()
        restoring = false
        for item in items { append(item) }
        publish()
        retire(doomed)
    }

    /// いま並んでいるのが既定そのもの（Level Meter 1 本）か。
    /// 画面で「戻す」を押せなくするのに使う。型名を画面側に持たせないため、
    /// 何が既定かの判断はここに置く。
    var isDefaultChain: Bool {
        chain.count == 1 && chain[0].spec.type == Self.defaultType
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
        retire(doomed)
    }

    /// 1 本足すだけ。publish はしない（呼び手がまとめて 1 回だけ呼ぶ）。
    @discardableResult
    private func append(_ item: PipelineStore.Loaded) -> Bool {
        var node = Node(spec: item.spec, values: item.values)
        node.enabled = item.enabled
        node.inputBus = item.inputBus
        node.outputBus = item.outputBus
        node.channelSpec = item.channelSpec
        node.sectionName = item.sectionName
        guard instantiate(&node) else { return false }
        chain.append(node)
        return true
    }

    /// 型名から spec を引く。Section はカタログに載っていないので別に見る。
    static func spec(forType type: String) -> ETEffect? {
        if type == ETSection.type { return ETSection.spec }
        return ETCatalog.first { $0.type == type }
    }

    /// Section の名前を変える。DSP には伝えない（section.js の `cm` は音に効かない）。
    func setSectionName(_ name: String, at index: Int) {
        guard chain.indices.contains(index), chain[index].isSection else { return }
        chain[index].sectionName = name
        persist()
    }

    /// パラメータを 1 つ変える。offset は ETParam.offset（配列なら +i）。
    func setValue(_ value: Float, at index: Int, offset: Int) {
        guard chain.indices.contains(index),
              chain[index].values.indices.contains(offset) else { return }
        chain[index].values[offset] = value
        pushParams(chain[index])
        // publish() は通さない。descriptor に載るのは並びと入切と鎖の形だけで、
        // 値は pushParams が instance へ直に渡している。
        // ただし端末には残す。残さないと、次に鎖を足す/消す/動かすまで
        // "pipeline.last" が古い値のままで、次の起動でそこへ戻る。
        persistSoon()
    }

    func resetParams(at index: Int) {
        guard chain.indices.contains(index) else { return }
        chain[index].values = chain[index].spec.defaults
        pushParams(chain[index])
        persistSoon()
    }

    func clear() {
        let doomed = chain.map(\.instance).filter { $0 != 0 }
        chain.removeAll()
        publish()
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
    private func rebuildAll() {
        guard ready, !chain.isEmpty else { return }
        var failed: [String] = []
        for i in chain.indices {
            chain[i].instance = 0
            chain[i].tapId = 0
            if !instantiate(&chain[i]) { failed.append(chain[i].spec.type) }
        }
        if !failed.isEmpty {
            let total = chain.count
            log.error("rebuild で instance を作れなかった \(failed.count)/\(total): \(failed.joined(separator: ","), privacy: .public)")
        }
        publish()
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
    /// BandFIRPEQDesigner.republishForLatencyChange が chain から ETPipeNode を
    /// 作り直していて、そこは node.sectionGate をそのまま読む。
    private func applySectionGates() {
        let gates = ETSection.gates(types: chain.map(\.spec.type), enabled: chain.map(\.enabled))
        for i in chain.indices where chain[i].sectionGate != gates[i] {
            chain[i].sectionGate = gates[i]
        }
    }

    /// 有効なものだけを並べて音のスレッドへ渡す。
    private func publish() {
        applySectionGates()
        // Section は instance を持たないのでここで落ちる。上流も同じく
        // descriptor に入れない（dsp-pipeline-descriptor.js:194-198）。
        let nodes = chain.filter { $0.instance != 0 }.map { n in
            ETPipeNode(instance: n.instance,
                       enabled: n.enabled ? 1 : 0,
                       inputBus: n.inputBus,
                       outputBus: n.outputBus,
                       channelSpec: n.channelSpec,
                       sectionGate: n.sectionGate)
        }
        nodes.withUnsafeBufferPointer { ETPipeline_Publish($0.baseAddress, UInt32($0.count)) }
        // nodes と chain の両方を出す。食い違っていたら instance を作れなかった
        // ノードが混ざっている＝画面の本数だけ音が通っていない。
        // Section は必ず descriptor から外れるので、先に引いて dead と分ける。
        // 分けないと Section を 1 本置くたびに dead が 1 増えて、取りこぼしと見分けが付かない。
        let sections = chain.filter(\.isSection).count
        let dead = chain.count - sections - nodes.count
        let active = nodes.filter { $0.enabled != 0 && $0.sectionGate != 0 }.count
        let gated = nodes.filter { $0.enabled != 0 && $0.sectionGate == 0 }.count
        let pub = "publish nodes=\(nodes.count) chain=\(chain.count) sections=\(sections) dead=\(dead) active=\(active) gated=\(gated) taps=\(chain.map { String($0.tapId) }.joined(separator: ",")) types=\(chain.map(\.spec.type).joined(separator: ","))"
        log.notice("\(pub, privacy: .public)")
        if ETConsoleLog.on { print(pub) }
        persist()
    }

    /// 鎖の形を変える。既定は 0→0 の All。
    ///
    /// sectionGate は受けるが残らない。Section の入切と鎖の並びから決まる値なので、
    /// この直後の publish() が applySectionGates() で引き直す。
    func setRouting(at index: Int, inputBus: UInt8? = nil, outputBus: UInt8? = nil,
                    channelSpec: Int8? = nil, sectionGate: UInt8? = nil) {
        guard chain.indices.contains(index) else { return }
        if let v = inputBus    { chain[index].inputBus = v }
        if let v = outputBus   { chain[index].outputBus = v }
        if let v = channelSpec { chain[index].channelSpec = v }
        if let v = sectionGate { chain[index].sectionGate = v }
        publish()
    }

    /// 外した instance を、音のスレッドが読み終えてから壊す。
    private func retire(_ instances: [UInt32]) {
        guard !instances.isEmpty, engine != 0 else { return }
        let engine = self.engine
        let mark = ETPipeline_ProcessCount()
        Task.detached(priority: .utility) {
            // 音のスレッドが 2 周するのを待つ。鳴っていなければ待っても進まないので、
            // 0.5 秒で諦めて壊す（鳴っていない＝誰も読んでいない）。
            let deadline = Date().addingTimeInterval(0.5)
            while ETPipeline_ProcessCount() < mark + 2 && Date() < deadline {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            for i in instances { et_instance_destroy(engine, i) }

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
            // 呼び出し元は remove / clear / resetToDefault / replaceChain の 4 つで、
            // どれも同じ経路を通る。ここで 1 回組み直せば全部に効く。
            await MainActor.run { EffeTuneDSP.shared.republish() }
        }
    }

    /// descriptor だけ出し直す。端末には書かない。
    /// retire が壊したあとに pipeline_configured_ を立て直すためのもので、
    /// 鎖の中身は変わっていないので保存する理由が無い。
    func republish() {
        guard engine != 0 else { return }
        let nodes = chain.filter { $0.instance != 0 }.map { n in
            ETPipeNode(instance: n.instance,
                       enabled: n.enabled ? 1 : 0,
                       inputBus: n.inputBus,
                       outputBus: n.outputBus,
                       channelSpec: n.channelSpec,
                       sectionGate: n.sectionGate)
        }
        nodes.withUnsafeBufferPointer { ETPipeline_Publish($0.baseAddress, UInt32($0.count)) }
        let line = "republish nodes=\(nodes.count) （壊したので組み直した）"
        log.notice("\(line, privacy: .public)")
        if ETConsoleLog.on { print(line) }
    }
}
