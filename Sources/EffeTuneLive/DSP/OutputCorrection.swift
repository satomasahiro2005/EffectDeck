//  OutputCorrection.swift
//  出力補正（Output Correction）の持ち主。入切・落ち着いた出力先・出力先ごとの紐付け・いま入っているもの。
//
//  出力補正は、使う人の鎖（EffeTuneDSP.chain）の後ろに付く固定の層。出力先ごとにユーザープリセットを
//  1 つ紐付け（名前で指すだけで、写しは持たない）、入れるときにそのプリセットの中身をその場で読む。
//  出力先が替わる・紐付けを替える・紐付けたプリセットを上書きすると読み直す。main には触らない。
//  段そのものは EffeTuneDSP.correction に入っていて、入れ替えは EffeTuneDSP.loadCorrection が行う。
//
//  何をやるか（読む・外す・名前だけ直す）は ETOutputCorrectionPolicy.steps が決める
//  （OutputCorrectionCore.swift、OutputCorrectionTests）。入切・出力先の確定・紐付けの変更・
//  プリセットの変更・リモートの出入り・DSP の用意のどれが起きても、ここは状態を直して reconcile() を 1 回呼ぶだけ。
//
//  紐付けは端末の UserDefaults にだけ持つ（ETOutputCorrectionStoreCore）。iCloud とバックアップへは出さない。
//  プリセットの名前の付け替え・削除には PresetStoreCore が紐付けを付いていかせる。
//
//  **ここから AudioIO.shared に触らない。**最初に作られるのは AudioIO の初期化の中
//  （prepare → dspPrepared）で、触ると static の初期化が自分を待って止まる。

import Foundation
import os

@MainActor
final class OutputCorrection: ObservableObject {

    static let shared = OutputCorrection()

    private let log = Logger(subsystem: "ai.nemut.effetune", category: "correction")

    /// 層の入切。既定は切。端末にだけ残す。
    @Published private(set) var isOn: Bool
    /// 落ち着いた出力先。鎖の下の行に名前を出す。
    @Published private(set) var device: ETOutputCorrectionDevice?
    /// 出力先ごとの紐付け（在るプリセットのものだけ）。鎖の下の行と出力補正のシート（OutputCorrectionView）が読む。
    /// プリセットの中身はここでは持たない。シートが出力先ごとに PresetStore から読む（全部の出力先の分が要るので）。
    @Published private(set) var bindings: [ETOutputCorrectionBinding] = []

    /// PC の鎖を編集している間（RemoteMirror が知らせる）。補正は外す。
    private var remote = false

    /// dsp.correction に入っているもの。
    private var loaded: ETOutputCorrectionTarget?

    private let core: ETOutputCorrectionStoreCore

    /// プリセットを読むだけ（patch は空で、書かない）。PresetStore.shared は使わない：
    /// 最初の読み込みは AudioIO の初期化の中（prepare → dspPrepared）で走る。
    private let presets: PresetStoreCore

    private init() {
        // 入れ物だけを読む。AudioIO にも EffeTuneDSP にもここでは触らない。
        core = ETOutputCorrectionStoreCore(storage: UserDefaults.standard)
        presets = PresetStoreCore(storage: UserDefaults.standard, patch: { _, _ in })
        isOn = core.isOn
        device = core.currentDevice
        bindings = core.bindings(existing: Set(presets.names))
    }

    /// その出力先に紐付けたプリセットの名前（保存してあるまま。`フォルダ/名前`）。無ければ nil。
    func preset(for key: String) -> String? { bindings.first { $0.key == key }?.preset }

    // MARK: - 起きたこと

    /// 層の入切。鎖の下の行の電源から。
    func setOn(_ on: Bool) {
        guard on != isOn else { return }
        core.setOn(on)
        isOn = on
        reconcile(cause: on ? "on" : "off")
    }

    /// 出力先が落ち着いた（AudioIO の .switched）。覚えて、入っていれば紐付けたプリセットを読み直す。
    /// 前の出力先と同じプリセットでも読み直す。
    func deviceSettled(_ d: ETOutputDevice) {
        guard let next = Self.entryDevice(d) else { return }
        core.setCurrentDevice(next)
        core.noteName(next)
        if device != next { device = next }
        refreshBindings()
        // 切り替えは入れ替えが無くても（切・リモート中・紐付け無し）1 行残す。
        reconcile(cause: "switch", always: true)
    }

    /// 落ち着いている出力先の名前が変わった（設定で付け直したなど）。名前だけ出し直す。読み直さない。
    func deviceSeen(_ d: ETOutputDevice) {
        guard let next = Self.entryDevice(d), device?.key == next.key, device != next else { return }
        core.setCurrentDevice(next)
        core.noteName(next)
        device = next
        refreshBindings()
    }

    /// 出力先にプリセットを紐付ける。nil なら外す。出力補正のシート（OutputCorrectionView）の選ぶ画面から。
    /// 切のときは書くだけ（鳴らすのは入のときだけ）。
    func bind(_ d: ETOutputCorrectionDevice, preset: String?) {
        core.bind(d, preset: preset)
        refreshBindings()
        reconcile(cause: "bind")
    }

    /// ユーザープリセットが変わった（PresetStore の書き替えのたび）。
    /// 紐付けたプリセットの上書き・付け替え・削除なら、reconcile が中身の印で読み直すかを決める。
    func presetsChanged() {
        refreshBindings()
        reconcile(cause: "preset")
    }

    /// PC の鎖の編集に入った・出た（RemoteMirror）。
    func setRemote(_ on: Bool) {
        guard on != remote else { return }
        remote = on
        reconcile(cause: on ? "remote" : "local")
    }

    /// 全部消した（ETFactoryReset）。入切と紐付けを入れ物から読み直す。
    /// 落ち着いている出力先はいまの事実なので、覚え直す。
    func reloadAfterReset() {
        isOn = core.isOn
        if let device {
            core.setCurrentDevice(device)
            core.noteName(device)
        }
        refreshBindings()
        reconcile(cause: "reset", always: true)
    }

    /// DSP を用意した（EffeTuneDSP.prepare の restore() の後）。
    /// 組み直し（レートの変更など）では、入っているものはそのまま残る（段は rebuildAll が作り直してある）。
    func dspPrepared() {
        reconcile(cause: "prepared")
    }

    // MARK: - 段取り

    /// 紐付けを読み直す。変わったときだけ出し直す。
    private func refreshBindings() {
        let next = core.bindings(existing: Set(presets.names))
        if next != bindings { bindings = next }
    }

    private func reconcile(cause: String, always: Bool = false) {
        let dsp = EffeTuneDSP.shared
        // 使えるときだけ作る（印のためにプリセットを JSON にするので）。
        let wanted: ETOutputCorrectionTarget? = (isOn && !remote) ? wantedTarget() : nil
        let steps = ETOutputCorrectionPolicy.steps(ETOutputCorrectionState(
            isOn: isOn, isRemote: remote, ready: dsp.ready, wanted: wanted, loaded: loaded))
        guard !steps.isEmpty else {
            if always { record(cause: cause, steps: []) }
            return
        }
        for step in steps {
            switch step {
            case .unload:
                loaded = nil
                dsp.unloadCorrection()
            case .relabel(let t):
                loaded = t
            case .load(let t):
                load(t)
            }
        }
        record(cause: cause, steps: steps)
    }

    /// 落ち着いた出力先に紐付いた、在るプリセット。無ければ nil。
    private func wantedTarget() -> ETOutputCorrectionTarget? {
        guard let d = device, let name = preset(for: d.key),
              let form = presets.form(named: name) else { return nil }
        return ETOutputCorrectionTarget(device: d.key, preset: name,
                                        stamp: ETOutputCorrectionTarget.stamp(form))
    }

    /// そのプリセットの中身を読んで入れる。読めない段（知らないエフェクト）しか無ければ空の補正になる。
    private func load(_ t: ETOutputCorrectionTarget) {
        let items = presets.form(named: t.preset).map { PipelineStore.parse($0, catalog: ETCatalog) } ?? []
        // 外の段には新しい身元を付ける。プリセットの身元のままだと、同じプリセットを読んだ main の段と
        // 1 つの AU・1 つの外部の席を取り合う（ETChainEditing.presetInsertion と同じ）。
        let fresh = items.map { item -> PipelineStore.Loaded in
            var item = item
            if !item.externalID.isEmpty { item.externalInstanceID = UUID().uuidString }
            return item
        }
        EffeTuneDSP.shared.loadCorrection(fresh)
        // 空でも入れたことにする。同じものを何度も読み直さないように。
        loaded = t
    }

    // MARK: - 記録

    /// 1 行残す。**uid は出さない**（鍵にも入っているので鍵も出さない）。
    private func record(cause: String, steps: [ETOutputCorrectionStep]) {
        let names = steps.map { step -> String in
            switch step {
            case .unload: return "unload"
            case .load: return "load"
            case .relabel: return "relabel"
            }
        }
        let line = String(format: "device t=%.3f kind=%@ name=%@ cause=%@ oc=%@ steps=%@ nodes=%ld",
                          ProcessInfo.processInfo.systemUptime,
                          device?.kind ?? "-", device?.name ?? "-", cause,
                          isOn ? "on" : "off",
                          names.isEmpty ? "-" : names.joined(separator: ","),
                          EffeTuneDSP.shared.correction.count)
        log.notice("\(line, privacy: .public)")
        ETLogTap.record(line)
        if ETConsoleLog.on { print(line) }
    }

    /// 出力先を入れ物の形へ。鍵の無い口（HFP など）は nil。
    private static func entryDevice(_ d: ETOutputDevice) -> ETOutputCorrectionDevice? {
        guard let key = d.key else { return nil }
        return ETOutputCorrectionDevice(key: key, name: d.name, kind: d.kind.rawValue)
    }
}
