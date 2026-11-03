//  OutputCorrectionCore.swift
//  出力補正（Output Correction）の、値だけで決まる判断。**Foundationだけ**（OutputCorrectionTests）。
//
//  出力補正は、使う人の鎖（main）の後ろに付く固定の層。出力先（ヘッドホンなど）ごとに
//  ユーザープリセットを 1 つ紐付け、出力先が替わるとそのプリセットを読み直す。main には触らない。
//
//  ここに置くのは4つ。
//    - slot の数え方：エンジンへ渡す並び（main + 補正）の中の位置と、部分ごとの位置の行き来
//    - 端末ごとの紐付けの入れ物：出力先 → ユーザープリセットの名前（UserDefaults だけ）
//    - 読み込み・外し・名前だけの直しの段取り：いまの状態から「何をやるか」だけを返す
//    - 共有のための平らげ：main + 終端 + 補正を、受け手が普通の鎖として開ける1本にする

import Foundation

// MARK: - slot

/// 鎖の部分。補正は main と別の並びで持つ。
enum ETChainPart: Equatable {
    case main
    case correction
}

/// `nodes = main + 補正` の中の位置（slot）と、部分ごとの位置の計算。
/// main の slot は main の添字と同じなので、既存の呼び手はそのまま通る。
enum ETChainSlots {

    /// slot がどの部分の何番目か。範囲の外なら nil。
    static func locate(_ slot: Int, mainCount: Int, correctionCount: Int)
        -> (part: ETChainPart, local: Int)? {
        guard slot >= 0 else { return nil }
        if slot < mainCount { return (.main, slot) }
        let local = slot - mainCount
        return local < correctionCount ? (.correction, local) : nil
    }

    /// slot の集まりを部分ごとの位置の集まりに分ける。
    static func split(_ slots: IndexSet, mainCount: Int) -> (main: IndexSet, correction: IndexSet) {
        var main = IndexSet()
        var correction = IndexSet()
        for s in slots where s >= 0 {
            if s < mainCount { main.insert(s) } else { correction.insert(s - mainCount) }
        }
        return (main, correction)
    }
}

// MARK: - 端末ごとの紐付け

/// 補正を持つ出力先。`key` は ETOutputDevice.key、`name` は最後に見た名前、
/// `kind` は ETOutputDevice.Kind の字。
struct ETOutputCorrectionDevice: Equatable {
    let key: String
    let name: String
    let kind: String
}

/// 出力先 1 台の紐付け。`preset` は保存してある名前そのもの（`フォルダ/名前`）。
struct ETOutputCorrectionBinding: Equatable {
    let key: String
    let name: String
    let kind: String
    let preset: String
}

/// 出力補正の入れ物。**UserDefaults だけ**（iCloud・バックアップへは出さない。patch も持たない）。
///
/// 持つのは3つ。
///   - 入切（既定は切）
///   - 最後に落ち着いた出力先
///   - 出力先ごとの紐付け `{ "<鍵>": { preset, name, kind } }`
/// 値は字だけなので plist に載る。紐付けてある出力先だけを持つ。
final class ETOutputCorrectionStoreCore {

    static let onKey = "outputCorrection.on"
    static let deviceKey = "outputCorrection.device"
    static let devicesKey = "outputCorrection.devices"

    private let storage: ETKeyValueStorage

    init(storage: ETKeyValueStorage) {
        self.storage = storage
    }

    // MARK: 入切

    var isOn: Bool { storage.object(forKey: Self.onKey) as? Bool ?? false }

    /// 同じなら書かない。
    func setOn(_ on: Bool) {
        guard on != isOn else { return }
        storage.set(on, forKey: Self.onKey)
    }

    // MARK: 最後の出力先

    var currentDevice: ETOutputCorrectionDevice? {
        guard let d = storage.dictionary(forKey: Self.deviceKey),
              let key = d["key"] as? String, !key.isEmpty else { return nil }
        return ETOutputCorrectionDevice(key: key,
                                        name: d["name"] as? String ?? "",
                                        kind: d["kind"] as? String ?? "")
    }

    /// 同じなら書かない。
    func setCurrentDevice(_ d: ETOutputCorrectionDevice) {
        guard d != currentDevice else { return }
        storage.set(["key": d.key, "name": d.name, "kind": d.kind], forKey: Self.deviceKey)
    }

    // MARK: 紐付け

    /// 紐付け。形の崩れたもの・preset が空のものは nil。**プリセットが在るかは見ない。**
    func binding(for key: String) -> ETOutputCorrectionBinding? {
        guard let entry = stored()[key] else { return nil }
        return Self.binding(key, entry)
    }

    /// 在るプリセットの紐付けだけ。名前（大文字小文字を問わない）、同じなら鍵の順。
    func bindings(existing: Set<String>) -> [ETOutputCorrectionBinding] {
        stored().compactMap { key, entry -> ETOutputCorrectionBinding? in
            guard let b = Self.binding(key, entry), existing.contains(b.preset) else { return nil }
            return b
        }.sorted {
            let c = $0.name.localizedCaseInsensitiveCompare($1.name)
            return c == .orderedSame ? $0.key < $1.key : c == .orderedAscending
        }
    }

    /// 紐付ける。nil なら外す。中身が同じなら書かない。無いものを外しても書かない。
    func bind(_ d: ETOutputCorrectionDevice, preset: String?) {
        var all = stored()
        guard let preset, !preset.isEmpty else {
            guard all.removeValue(forKey: d.key) != nil else { return }
            write(all)
            return
        }
        let entry = ["preset": preset, "name": d.name, "kind": d.kind]
        guard all[d.key] != entry else { return }
        all[d.key] = entry
        write(all)
    }

    /// 紐付けてある出力先だけ、名前・種類が違えば直す（見出しに最後に見た名前を出す）。
    func noteName(_ d: ETOutputCorrectionDevice) {
        var all = stored()
        guard var entry = all[d.key], Self.binding(d.key, entry) != nil,
              entry["name"] != d.name || entry["kind"] != d.kind else { return }
        entry["name"] = d.name
        entry["kind"] = d.kind
        all[d.key] = entry
        write(all)
    }

    /// プリセットの名前が変わった・消えた（to が nil）。**合うものがあるときだけ 1 回書く。**
    /// 元の名前で引いて 1 度で決める（A→B と B→A の入れ替えでも順に当たらない）。
    func retarget(_ moves: [(from: String, to: String?)]) {
        guard !moves.isEmpty else { return }
        var map: [String: String?] = [:]
        for m in moves { map.updateValue(m.to, forKey: m.from) }
        var all = stored()
        var changed = false
        for (key, entry) in all {
            guard let preset = entry["preset"], let move = map[preset] else { continue }
            changed = true
            if let to = move {
                var e = entry
                e["preset"] = to
                all[key] = e
            } else {
                all.removeValue(forKey: key)
            }
        }
        guard changed else { return }
        write(all)
    }

    // MARK: 中

    /// 紐付けの中身。字だけの辞書でないもの（前の形の写しなど）は読み飛ばす。
    /// 読み飛ばしたものは次に書くときに落ちる。
    private func stored() -> [String: [String: String]] {
        (storage.dictionary(forKey: Self.devicesKey) ?? [:]).compactMapValues { $0 as? [String: String] }
    }

    private static func binding(_ key: String, _ entry: [String: String]) -> ETOutputCorrectionBinding? {
        guard let preset = entry["preset"], !preset.isEmpty else { return nil }
        return ETOutputCorrectionBinding(key: key, name: entry["name"] ?? "",
                                         kind: entry["kind"] ?? "", preset: preset)
    }

    private func write(_ all: [String: [String: String]]) {
        storage.set(all, forKey: Self.devicesKey)
    }
}

// MARK: - 段取り

/// 入れたい・入っている補正。出力先の鍵、プリセットの名前、その中身の印。
struct ETOutputCorrectionTarget: Equatable {
    var device: String
    var preset: String
    var stamp: Data

    /// 中身の印。鍵の順を固定した JSON。JSON にできない形は空の Data（落ちない）。
    /// data(withJSONObject:) は不正な値（NaN など）だとトラップするので、先に isValidJSONObject で見る。
    static func stamp(_ form: Any) -> Data {
        guard JSONSerialization.isValidJSONObject(form),
              let data = try? JSONSerialization.data(withJSONObject: form, options: [.sortedKeys])
        else { return Data() }
        return data
    }
}

/// 段取りを決めるための、いまの状態。
struct ETOutputCorrectionState: Equatable {
    var isOn: Bool
    var isRemote: Bool
    /// エンジンが立っているか。
    var ready: Bool
    /// 落ち着いた出力先に紐付いた、在るプリセット。無ければ nil。
    var wanted: ETOutputCorrectionTarget?
    /// dsp.correction に入っているもの。
    var loaded: ETOutputCorrectionTarget?
}

enum ETOutputCorrectionStep: Equatable {
    /// 補正を外す。
    case unload
    /// 読み直す（入っているものは置き換わる）。
    case load(ETOutputCorrectionTarget)
    /// 名前だけ変わった。段には触らない。
    case relabel(ETOutputCorrectionTarget)
}

enum ETOutputCorrectionPolicy {

    /// いまの状態から、やることを返す。**入切・切り替え・紐付けの変更・プリセットの変更・
    /// リモートの出入り・準備完了のどれが起きても、この1つで決める。**
    ///
    /// - エンジンが立っていないときは何もしない（段に触らない）。
    /// - 欲しいものは「入っていて、リモートでない」ときだけ wanted。
    /// - 同じ出力先で中身の印が同じなら、名前の付け替えなので読み直さない（音が途切れない）。
    /// - 出力先が替われば、同じプリセットでも読み直す。
    static func steps(_ s: ETOutputCorrectionState) -> [ETOutputCorrectionStep] {
        guard s.ready else { return [] }
        let desired = (s.isOn && !s.isRemote) ? s.wanted : nil
        guard desired != s.loaded else { return [] }
        guard let d = desired else { return [.unload] }
        if let l = s.loaded, l.device == d.device, l.stamp == d.stamp { return [.relabel(d)] }
        return [.load(d)]
    }
}

// MARK: - 共有

/// プリセットの中身の 1 行（名前だけ）。出力補正のシートの行の中身の要約（summary）がこれから組む。
struct ETOutputCorrectionLine: Equatable, Identifiable {
    /// 並びの中の位置（終端を除いた通し番号）。
    let id: Int
    let name: String
    let isSection: Bool
    /// Section の配下。字下げする。
    let indented: Bool
}

enum ETOutputCorrectionForm {

    /// プリセットの中身を行にする。終端（rootReset）は出さずに字下げを戻す。
    /// 名前の無い Section は "Section"（左の一覧と同じ）。
    static func lines(_ items: [PipelineStore.Loaded]) -> [ETOutputCorrectionLine] {
        var out: [ETOutputCorrectionLine] = []
        var inSection = false
        for item in items {
            switch role(item) {
            case .rootReset:
                inSection = false
            case .section:
                out.append(ETOutputCorrectionLine(
                    id: out.count, name: item.sectionName.isEmpty ? "Section" : item.sectionName,
                    isSection: true, indented: false))
                inSection = true
            case .effect:
                out.append(ETOutputCorrectionLine(
                    id: out.count, name: item.spec.name, isSection: false, indented: inSection))
            }
        }
        return out
    }

    /// 出力補正のシートの出力先の行に出す 1 行。エフェクトの名前だけを " · " でつなぐ。
    /// Section の見出しは入れない（名前の並びで中身を見分けるための行で、組の形までは要らない）。
    static func summary(_ items: [PipelineStore.Loaded]) -> String {
        lines(items).filter { !$0.isSection }.map(\.name).joined(separator: " · ")
    }

    /// 選ぶ画面に並べるフォルダ。Presets のシートの User Presets と同じ束ね方・同じ順
    /// （フォルダに入っていないものが先頭、あとはフォルダの名前順。中の並びは渡された順のまま）。
    /// 別の順にすると、Presets で見慣れた場所に同じプリセットが無くなる。
    static func presetFolders(_ names: [String]) -> [(name: String, items: [String])] {
        ETUserPresetName.folders(names).sorted { a, b in
            if a.name.isEmpty != b.name.isEmpty { return a.name.isEmpty }
            return a.name < b.name
        }
    }

    /// main + 補正を、受け手が普通の鎖として開ける1本にする。
    /// 補正が空なら main をそのまま返す。
    ///
    /// 補正は main の後ろに独立して付くので、main が組の中で終わっていると、そのまま
    /// つなげれば補正が main の最後の組に呑まれる。それを防ぐ終端（rootReset）を挟む。
    /// 要らないとき（main が root で終わる・補正が Section で始まる・main が空）は
    /// 正規形（ETRootResetRule.keep）が落とすので、挟まない。
    /// 受け手には出力先の属性は付かない。
    static func flatten(main: [PipelineStore.Loaded],
                        correction: [PipelineStore.Loaded]) -> [PipelineStore.Loaded] {
        guard !correction.isEmpty else { return main }
        var out = main + [rootResetMarker] + correction
        if !ETRootResetRule.keep(roles: out.map(role))[main.count] { out.remove(at: main.count) }
        return out
    }

    /// 段の役目。終端・Section・普通の段。
    static func role(_ l: PipelineStore.Loaded) -> ETItemRole {
        if l.isRootReset { return .rootReset }
        return ETSection.isSection(l.spec) ? .section : .effect
    }

    /// leaveSection が挿すものと同じ（specは Section、入っている、名前は空）。
    private static var rootResetMarker: PipelineStore.Loaded {
        PipelineStore.Loaded(spec: ETSection.spec, values: [], enabled: true,
                             inputBus: 0, outputBus: 0, channelSpec: -1, isRootReset: true)
    }
}
