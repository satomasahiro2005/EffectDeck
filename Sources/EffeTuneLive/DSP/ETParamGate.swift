//  ETParamGate.swift
//  ほかの値によって触れなくなる行の規則。**Foundation だけ**なので実機なしで試せる（ParamGateTests）。
//
//  **止めるのは操作だけで、値は残す。**上流も input を disabled にするだけ。
//  決まった値しか取らない数（Oversampling）の表は ETAllowedValues（ETParamCoding.swift）。
//
//  規則は 2 通り。
//    - toggle が切れている間は触れない（`toggleOwner`）。
//    - 他の値の組で決まる（`predicate`）。選択肢は **並びの番号** で比べる。
//  値の引き方は呼ぶ側が渡す（`value(key)` は同じ段の短い名前から今の値を返す。無ければ nil）。

import Foundation

enum ETParamGate {

    /// toggle の持ち主。`型名.key` → その toggle の key。
    static func upstream(type: String, key: String) -> String? {
        toggleOwner[type + "." + key]
    }

    /// その行が触れないか。
    static func isDisabled(type: String, key: String, value: (String) -> Float?) -> Bool {
        if let owner = upstream(type: type, key: key), let v = value(owner) {
            return v < 0.5
        }
        switch type {
        case "CassetteArtifactsPlugin":
            return cassetteDisabled(key: key, value: value)
        case "AdaptivePredictionEffectPlugin":
            return adaptiveDisabled(key: key, value: value)
        default:
            return false
        }
    }

    private static let toggleOwner: [String: String] = [
        // dynamics/attack_tonal_balance.js:67-70（_syncGainControlAvailability）
        "AttackTonalBalancePlugin.at": "ae",
        "AttackTonalBalancePlugin.tn": "te",
    ]

    // MARK: Cassette Artifacts

    /// Mode の並び（cassette_artifacts.js:1-3）。
    enum CassetteMode {
        static let encodeOnly: Float = 0
        static let encodeArtifacts: Float = 1
        static let all: Float = 2
        static let artifactsDecode: Float = 3
        static let decodeOnly: Float = 4
    }

    /// cassette_artifacts.js の `_syncModeDependentControls`（2.13.0）。
    ///   - 傷み（dg・tp・bs・wf・hs・dp・az）は Encode Only / Decode Only のとき止まる。
    ///   - dl（Dolby Level Error）は復号を通らない Mode か、NR が Off のとき止まる。
    ///   - rl（Record Level）は傷みが無い Mode で NR が Off のとき止まる（録音の入れ方が効かない）。
    /// Mode が無い（古い鎖）ときは All と同じで、何も止めない。
    private static func cassetteDisabled(key: String, value: (String) -> Float?) -> Bool {
        let mode = Int((value("md") ?? CassetteMode.all).rounded())
        let artifactsActive = mode != Int(CassetteMode.encodeOnly) && mode != Int(CassetteMode.decodeOnly)
        let decodeActive = mode == Int(CassetteMode.all) || mode == Int(CassetteMode.artifactsDecode)
            || mode == Int(CassetteMode.decodeOnly)
        let noiseReductionOff = Int((value("nr") ?? 1).rounded()) == 0
        switch key {
        case "dg", "tp", "bs", "wf", "hs", "dp", "az": return !artifactsActive
        case "dl": return !decodeActive || noiseReductionOff
        case "rl": return !artifactsActive && noiseReductionOff
        default: return false
        }
    }

    // MARK: Adaptive Prediction

    /// adaptive_prediction_effect.js の _syncControls。Hold は Freeze を含み、Autonomy を 1 に固定する。
    ///   - Learn・Weight Decay・Infinity は Freeze か Hold のとき止まる。Weight Decay は無限大（0）のときも止まる。
    ///   - Autonomy は Hold のとき止まる。
    ///   - Freeze の札は Hold のとき止まる（Hold のあいだ Freeze も入っているものとして見せる）。
    private static func adaptiveDisabled(key: String, value: (String) -> Float?) -> Bool {
        let hold = (value("hold") ?? 0) >= 0.5
        let freeze = (value("freeze") ?? 0) >= 0.5
        switch key {
        case "learn": return freeze || hold
        case "weightDecay": return freeze || hold || (value("weightDecay") ?? 0) <= 0
        case "autonomy", "freeze": return hold
        default: return false
        }
    }
}
