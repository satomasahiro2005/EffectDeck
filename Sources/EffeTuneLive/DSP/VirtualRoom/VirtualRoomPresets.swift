//  VirtualRoomPresets.swift
//  EffectDeck 独自エフェクトの出荷時プリセット（docs/virtual-room-design.md §41）。
//
//  上流のプラグインが .js に持っているものは Tools/gen_effect_presets.py が
//  焼くが、Virtual Room は上流に無いので焼く元が無い。**手で書く。**
//  読む側は既存の Effect Presets をそのまま使う。カードの中に別の picker は
//  置かない（§41）。
//
//  材質の番号は effect.json の並び（§11）:
//      0 Concrete / 1 Painted Wall / 2 Drywall / 3 Wood /
//      4 Glass / 5 Heavy Curtain / 6 Carpet / 7 Acoustic Panel
//  Early Reflections は 0 = First Order / 1 = Second Order。
//
//  **seed も書く。**書かないと「同じプリセットなら同じ部屋」が成り立たない（§32）。

import Foundation

enum ETVirtualRoomPresets {

    private static let effect = "Virtual Room"
    /// 上流も 1 つしか群が無いものは空にしている。合わせる。
    private static let group = ""

    /// 保存形式（ショート）で書く。読むのは ETParamCoding.decode。
    private static func preset(_ id: String, _ label: String,
                               _ params: [String: Any]) -> ETEffectPreset {
        var all = params
        all["mv"] = 1
        let data = (try? JSONSerialization.data(withJSONObject: all,
                                                options: [.sortedKeys])) ?? Data()
        return ETEffectPreset(effect: effect, presetId: id, label: label,
                              group: group,
                              json: String(decoding: data, as: UTF8.self))
    }

    /// 全部に同じ seed を使う。部屋の形は seed で変わらないので、
    /// 違う値にする理由が無い（違えば「同じ設定なのに音が違う」だけになる）。
    private static let seed: [String: Any] = ["s0": 31777, "s1": 41855]

    static let list: [ETEffectPreset] = [
        // 近接。壁を抑えた小さい部屋で、鳴りではなく像を見るための設定。
        preset("nearfield-studio", "Nearfield Studio",
               seed.merging([
                   "rw": 4.2, "rd": 3.6, "rh": 2.6,
                   "lx": 50.0, "ly": 36.0, "lz": 1.2,
                   "sa": 30.0, "sd": 1.2, "se": 0.0,
                   "rm": 70.0, "ds": 0.8,
                   "sm": 7, "fm": 7, "bm": 5, "fl": 6, "ce": 7,
                   "eo": 1, "hr": 8.75, "pa": 100.0, "hs": 100.0, "og": 0.0,
               ]) { a, _ in a }),

        // 普通の居間。床は絨毯、後ろはカーテン。
        preset("living-room", "Living Room",
               seed.merging([
                   "rw": 5.5, "rd": 4.5, "rh": 2.5,
                   "lx": 50.0, "ly": 38.0, "lz": 1.2,
                   "sa": 30.0, "sd": 2.4, "se": 0.0,
                   "rm": 110.0, "ds": 1.0,
                   "sm": 2, "fm": 2, "bm": 5, "fl": 6, "ce": 2,
                   "eo": 1, "hr": 8.75, "pa": 100.0, "hs": 100.0, "og": 0.0,
               ]) { a, _ in a }),

        // 響きを落とした部屋。部屋の色を薄くしたいとき。
        preset("dry-room", "Dry Room",
               seed.merging([
                   "rw": 3.5, "rd": 3.0, "rh": 2.4,
                   "lx": 50.0, "ly": 36.0, "lz": 1.2,
                   "sa": 30.0, "sd": 1.4, "se": 0.0,
                   "rm": 40.0, "ds": 0.5,
                   "sm": 7, "fm": 7, "bm": 7, "fl": 6, "ce": 7,
                   "eo": 1, "hr": 8.75, "pa": 100.0, "hs": 100.0, "og": 0.0,
               ]) { a, _ in a }),

        // 広い部屋。硬い面を残して後ろを伸ばす。
        preset("large-room", "Large Room",
               seed.merging([
                   "rw": 12.0, "rd": 9.0, "rh": 4.5,
                   "lx": 50.0, "ly": 40.0, "lz": 1.2,
                   "sa": 30.0, "sd": 3.0, "se": 0.0,
                   "rm": 140.0, "ds": 1.6,
                   "sm": 1, "fm": 0, "bm": 1, "fl": 3, "ce": 0,
                   "eo": 1, "hr": 8.75, "pa": 100.0, "hs": 100.0, "og": 0.0,
               ]) { a, _ in a }),

        // §41。Room Amount 0%。**dry stereo には戻らない。**
        // 無響室に置いた仮想スピーカーだけが残る（§10）。
        preset("anechoic-speakers", "Anechoic Speakers",
               seed.merging([
                   "rw": 4.2, "rd": 3.6, "rh": 2.6,
                   "lx": 50.0, "ly": 36.0, "lz": 1.2,
                   "sa": 30.0, "sd": 1.8, "se": 0.0,
                   "rm": 0.0, "ds": 1.0,
                   "sm": 7, "fm": 7, "bm": 7, "fl": 7, "ce": 7,
                   "eo": 0, "hr": 8.75, "pa": 100.0, "hs": 100.0, "og": 0.0,
               ]) { a, _ in a }),
    ]
}

/// EffectDeck 独自エフェクトの出荷時プリセットを表示名で引く。
/// 生成物（ETEffectPresets）には入らないので、引く側がこちらも見る。
let ETDeckEffectPresets: [String: [ETEffectPreset]] =
    Dictionary(grouping: ETVirtualRoomPresets.list, by: \.effect)

enum ETPresetCatalog {
    /// 上流の出荷時プリセットと EffectDeck 独自のものを繋いで返す。
    static func presets(for effectName: String) -> [ETEffectPreset] {
        (ETEffectPresets[effectName] ?? []) + (ETDeckEffectPresets[effectName] ?? [])
    }
}
