//  DeckEffects.swift
//  EffectDeck だけが持つ内蔵エフェクト（docs/virtual-room-design.md §39、§40）。
//
//  上流の EffeTune には無いので、
//    - こちらの保存形式には型の印（`ed`）を書く。名前が偶然ぶつかっても解決を誤らない
//    - 上流向けのリンクには載せない。AU / JSFX と同じ扱いで落とすか素通しへ替える
//  の 2 つが要る。
//
//  **外から来たものではない。**`isExternal` とは別の概念で、
//  こちらはカーネルを自分で持っている普通の EffeTune エフェクトとして動く。

import Foundation

enum ETDeckEffect {

    /// 保存形式に書く型の印。`nm` より優先して解決する。
    static let markerKey = "ed"

    /// EffectDeck だけが持つ型。増えたらここに足す。
    static let types: Set<String> = [ETVirtualRoom.type]

    static func isDeckOnly(_ type: String) -> Bool { types.contains(type) }

    /// ショート形式へ印を書く。上流のエフェクトには何も足さない。
    static func mark(_ o: inout [String: Any], type: String) {
        guard isDeckOnly(type) else { return }
        o[markerKey] = type
    }
}
