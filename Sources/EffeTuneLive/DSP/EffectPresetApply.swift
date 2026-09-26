//  EffectPresetApply.swift
//  エフェクト 1 個ぶんのプリセット（params の辞書）を float の並びへ落とす。
//
//  **EffeTuneDSP にも UserDefaults にも触らない。**
//  入力は ETEffect と [Float] と [String: Any] だけなので、実機もエンジンも
//  無しで測れる（Tests/Unit/EffectPresetTests.swift）。ETParamCoding を
//  切り出したのと同じ理由で、ここも読むだけでは何度も取り違える:
//  上流の適用規則がプラグインごとに違い、Tube Simulator だけ別の道を通る。
//
//  出典:
//    - 汎用の適用   js/ui/pipeline/plugin-preset-dialog.js:97-108
//    - 汎用の一致   js/ui/pipeline/plugin-preset-dialog.js:55-74
//    - Tube だけの規則 plugins/saturation/tube_simulator.js:6109-6153

import Foundation

enum EffectPresetApply {

    /// 上流が自前の適用規則を持っている唯一のもの。
    /// **表示名ではなく型で分ける。**
    private static let tubeSimulator = "TubeSimulatorPlugin"

    /// tube_simulator.js:58-60 の TUBE_SIMULATOR_DEFAULT_SE_PARAMETERS。
    /// applyCanonicalPreset が preset.params の**下**に敷く（:6130-6131）。
    private static let tubeSimulatorSEDefaults: [String: Any] = [
        "sd": "300B", "sb": 400, "sr": 1000, "sp": "3.5",
    ]

    // MARK: - 適用

    /// プリセットの params を float の並びへ。長さは必ず `current` と同じ。
    ///
    /// **書かれていない鍵は `current` のまま残す。** 上流の setParameters は
    /// `if (params.xx !== undefined)` の形で書くので、触れられていないものは
    /// 今の値が残る（plugins/dynamics/power_amp_sag.js:372-395）。
    /// 「書かれていない鍵は既定へ戻る」ではない。既定へ戻すのはプリセットではなく
    /// Reset Parameters の仕事で、上流でも別のボタン
    /// （js/ui/pipeline/pipeline-item-builder.js:139-145 で preset と reset は別）。
    ///
    /// 実測では、プリセットを持つ 26 本のうち 25 本は catalog の鍵を全部書くので
    /// この違いは出ない。出るのは Tube Simulator の `ag`（Auto Gain Reduction）
    /// だけで、上流もそこは書かずに残している。
    static func values(for spec: ETEffect, params: [String: Any],
                       current: [Float]) -> [Float] {
        let isTube = spec.type == tubeSimulator
        let source = isTube
            ? tubeSimulatorSEDefaults.merging(params) { _, fromPreset in fromPreset }
            : params

        var out = ETParamCoding.decode(params: spec.params,
                                       defaults: current, from: source,
                                       type: spec.type)
        guard isTube else { return out }

        // rl = Number(preset.params.sl ?? this.sl)（tube_simulator.js:6132）。
        // プリセットは設計上の負荷を持っているので、実際に繋がっている負荷も
        // それに合わせる（:6125-6128 の注記）。
        //
        // **enum の添字ではなく Ω の数。** `sl` の保存値は "15" という文字列で、
        // こちらの catalog では選択肢の添字 2（EffectCatalog.swift:1522）。
        // decode の結果をそのまま `rl` へ入れると 15Ω のつもりが 2Ω になる。
        if let rl = spec.params.first(where: { $0.key == "rl" }),
           out.indices.contains(rl.offset),
           let load = ohms(source["sl"]) ?? currentSpeakerOhms(spec: spec, values: current) {
            out[rl.offset] = load
        }

        // sg = 0（:6133）。プリセットは回路の記述であって保護設定ではないので、
        // 必ず 0dB の safety trim に着地する（:6117-6123）。
        if let sg = spec.params.first(where: { $0.key == "sg" }),
           out.indices.contains(sg.offset) {
            out[sg.offset] = 0
        }

        // `ag` は書かない。上流の setParameters にも入っていない。
        return out
    }

    // MARK: - 一致判定

    /// いまの値がどの出荷時プリセットに一致しているか。無ければ空。
    /// 返すのは上流の preset.id（ETEffectPreset.presetId）。
    ///
    /// 上流の汎用の判定は「**プリセットが書いた鍵だけ**を比べる」
    /// （plugin-preset-dialog.js:64-72 の `Object.entries(preset.params).every`）。
    /// こちらは適用した結果と今の値を丸ごと比べているが、書かれていない位置には
    /// current をそのまま写しているので、比べているのは同じ集合になる。
    ///
    /// 外すのは `sg` だけ:
    ///   - Tube Simulator は自前の判定を持っていて `sg` と `ag` を外す
    ///     （tube_simulator.js:6142-6148）。ここを外さないと、安全減衰が
    ///     一度でも効いた瞬間にどのプリセットにも一致しなくなる。
    ///     `ag` は values() が触らないので、そのまま一致する。
    ///   - 汎用側の getPresetComparisonExcludedKeys を持つのは Modal Resonator の
    ///     `sr` 1 本だけ（modal_resonator.js:30-32。選択中タブの添字）。
    ///     音に効かないので params.json に無く、こちらの catalog にも無い。
    ///     decode は知らない鍵を黙って飛ばすので、外す相手がそもそも居ない。
    static func matchingPresetId(for spec: ETEffect, current: [Float]) -> String {
        let skip = excludedOffsets(for: spec)
        for preset in ETEffectPresets[spec.name] ?? [] {
            let applied = values(for: spec, params: preset.params, current: current)
            guard applied.count == current.count else { continue }
            var same = true
            for i in current.indices where !skip.contains(i) {
                if applied[i] != current[i] { same = false; break }
            }
            if same { return preset.presetId }
        }
        return ""
    }

    /// 一致判定から外す位置。
    static func excludedOffsets(for spec: ETEffect) -> Set<Int> {
        guard spec.type == tubeSimulator,
              let sg = spec.params.first(where: { $0.key == "sg" }) else { return [] }
        return [sg.offset]
    }

    // MARK: - Tube Simulator のスピーカー負荷

    /// 保存形式の `sl`（"15" のような文字列）→ Ω の数。
    /// 上流の `Number(...)` に当たる（tube_simulator.js:6132）。
    private static func ohms(_ raw: Any?) -> Float? {
        if let s = raw as? String { return Float(s) }
        if let n = raw as? NSNumber { return n.floatValue }
        return nil
    }

    /// プリセットが `sl` を書いていないときの拠り所（上流の `?? this.sl`）。
    /// いま選ばれている選択肢の綴りを Ω の数に戻す。
    private static func currentSpeakerOhms(spec: ETEffect, values: [Float]) -> Float? {
        guard let sl = spec.params.first(where: { $0.key == "sl" }),
              case .enumeration(let options) = sl.kind,
              values.indices.contains(sl.offset) else { return nil }
        let i = Int(values[sl.offset].rounded())
        guard options.indices.contains(i) else { return nil }
        return Float(options[i])
    }
}

extension ETEffectPreset {

    /// 焼いてある json を辞書へ戻す。**開いたときに読む。**
    /// 131 件で 52KB なので、辞書のまま全部抱えるより、画面に出す分だけ
    /// その場で読むほうが軽い（SystemPresets.swift と同じ持ち方）。
    var params: [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else { return [:] }
        return dict
    }
}
