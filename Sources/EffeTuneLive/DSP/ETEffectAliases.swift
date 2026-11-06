//  ETEffectAliases.swift
//  効果の旧い表示名。**Foundationだけ。**
//
//  2.17.0 で SFZ Note Player の表示名が SoundFont Note Player に変わった（型は SFZNotePlayerPlugin のまま）。
//  名前は鎖（`nm`）・プリセットの入れ物（表示名が外側の鍵）・Remote Control の効果の一覧（effects）に
//  そのまま載るので、旧い名前で書かれたものと旧い PC が残る。
//  **読むときは旧い名前も同じ効果として引き、書くときは新しい名前を使う。**
//  ただし PC の effects が新しい名前を持たず旧い名前を持つなら、その PC へ送る段だけ旧い名前で書く
//  （知らない効果を含む鎖は PC が丸ごと断る）。

import Foundation

enum ETEffectAliases {

    /// 改名した効果 1 つぶん。`since` は新しい名前になった dsp の版。
    struct Rename: Equatable {
        var legacyName: String
        var type: String
        var since: String
    }

    /// 改名の一覧。増えたらここへ足す。
    static let renames: [Rename] = [
        Rename(legacyName: "SFZ Note Player", type: "SFZNotePlayerPlugin", since: "0.17.0"),
    ]

    /// 旧い名前が指す型。旧い名前でなければ nil。
    static func type(forLegacyName name: String) -> String? {
        renames.first { $0.legacyName == name }?.type
    }

    /// 型の旧い名前。改名していない型は nil。
    static func legacyName(forType type: String) -> String? {
        renames.first { $0.type == type }?.legacyName
    }

    /// 旧い名前なら、いまの表示名へ。そうでなければそのまま。
    /// いまの名前は catalog の型から引く（名前をここで二重に持たない）。
    static func current(_ name: String, in catalog: [ETEffect] = ETCatalog) -> String {
        guard let type = type(forLegacyName: name),
              let hit = catalog.first(where: { $0.type == type }) else { return name }
        return hit.name
    }

    /// 旧い名前から効果を引く。旧い名前でなければ nil。
    static func effect(forLegacyName name: String, in catalog: [ETEffect]) -> ETEffect? {
        guard let type = type(forLegacyName: name) else { return nil }
        return catalog.first { $0.type == type }
    }

    /// いまの表示名の旧い名前。改名していなければ nil。
    static func legacyName(forCurrentName name: String, in catalog: [ETEffect] = ETCatalog) -> String? {
        guard let hit = catalog.first(where: { $0.name == name }) else { return nil }
        return legacyName(forType: hit.type)
    }

    /// PC へ送る段の名前。**新しい名前が基本。**
    /// - PC が効果の一覧（effects）を出すなら、新しい名前を持たず旧い名前を持つときだけ旧い名前。
    /// - 一覧を出さないなら、dsp の版が改名より前（`since` 未満）のときだけ旧い名前。
    ///   dsp も出さない・読めないときは新しい名前（分からないものは旧くないと見る）。
    static func wireName(of effect: ETEffect, effects: Set<String>?, dsp: String?) -> String {
        guard let rename = renames.first(where: { $0.type == effect.type }) else { return effect.name }
        if let effects {
            if !effects.contains(effect.name), effects.contains(rename.legacyName) { return rename.legacyName }
            return effect.name
        }
        if let dsp, isBefore(dsp, rename.since) { return rename.legacyName }
        return effect.name
    }

    /// 名前の集合を、いまの表示名へ寄せたもの（旧い名前を新しい名前に直す）。
    static func normalized<S: Sequence>(_ names: S, in catalog: [ETEffect] = ETCatalog) -> Set<String> where S.Element == String {
        Set(names.map { current($0, in: catalog) })
    }

    /// "0.16.0" < "0.17.0"。数字の組で比べる。数字でなければ偽。
    static func isBefore(_ version: String, _ other: String) -> Bool {
        guard let a = components(version), let b = components(other) else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    private static func components(_ version: String) -> [Int]? {
        let parts = version.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var out: [Int] = []
        for p in parts {
            guard let n = Int(p), n >= 0 else { return nil }
            out.append(n)
        }
        return out
    }
}
