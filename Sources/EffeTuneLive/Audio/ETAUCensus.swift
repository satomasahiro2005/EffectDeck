//  ETAUCensus.swift
//  系に登録されている Audio Unit の数え上げを、報告に添える 2 行にまとめる。
//
//  **なぜ要るのか（Issue #10）。**
//  Plugins の一覧に Apple の AU しか出ず、他社の AUv3（TB Morphit・AudioKit Reverb）が
//  出ない。再起動しても変わらない。一覧を作る問い合わせは Effect と MusicEffect の 2 種に
//  絞っているので、出ない理由は 3 通りに分かれる。
//    1. 系がこのプロセスに他社の部品を 1 本も返していない（入れ物の側の権限か登録の問題）
//    2. 返してはいるが種別が違い、2 種の絞り込みで落ちている
//    3. 起動直後には無く、後から登録が届いている
//  型を 0（全部）にした問い合わせと AudioComponentFindNext の両方で数え、種別ごと・
//  作り手ごとの数と、Apple 以外の名前を残せば、実機で 1 回動かすだけでどれかに決まる。
//
//  **Foundation だけ。**AVFoundation の型は ETAUHost の側で Item に写してから渡す。
//  こうしておくと字の組み立てを実機なしで試せる（AUCensusTests）。

import Foundation

enum ETAUCensus {

    /// 部品 1 本ぶん。AudioComponentDescription と名前から写す。
    struct Item: Hashable {
        let type: UInt32
        let subType: UInt32
        let manufacturer: UInt32
        let name: String
        /// 作り手の名前（manufacturerName）。FindNext から来たものは名前の頭から切り出す。
        let maker: String

        var key: String { "\(type):\(subType):\(manufacturer)" }
    }

    /// 'appl'。
    static let appleManufacturer: UInt32 = 0x6170_706C
    /// 'aufx' と 'aumf'。一覧に載せる 2 種（ETAUHost.refresh の絞り込みと同じ）。
    static let effectTypes: Set<UInt32> = [0x6175_6678, 0x6175_6D66]
    /// 名前を何本まで残すか。報告が他の行で埋まらないように。
    static let nameLimit = 30

    /// 4 文字の識別子を字にする。字にできない値は 16 進で出す（作り手の値は任意なので）。
    static func fourCC(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else {
            return String(format: "0x%08X", value)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// AudioComponentCopyName の「作り手: 名前」を分ける。区切りが無ければ作り手は空。
    static func splitName(_ full: String) -> (maker: String, name: String) {
        guard let range = full.range(of: ": ") else { return ("", full) }
        let maker = String(full[..<range.lowerBound])
        let name = String(full[range.upperBound...])
        return (maker, name)
    }

    /// Apple のものか。値と名前のどちらかで判る（Apple の AU は作り手が 'appl'）。
    static func isApple(_ item: Item) -> Bool {
        item.manufacturer == appleManufacturer || item.maker == "Apple"
    }

    /// 2 つの数え上げを、同じ部品は 1 本にして合わせる。並びは key 順で毎回同じにする。
    static func merged(_ lists: [Item]...) -> [Item] {
        var seen: [String: Item] = [:]
        for list in lists {
            for item in list where seen[item.key] == nil { seen[item.key] = item }
        }
        return seen.values.sorted { $0.key < $1.key }
    }

    /// 1 回の数え直しを 1 行にする。
    ///
    /// - listed: 一覧に載った数（Effect と MusicEffect の問い合わせ）
    /// - manager: AVAudioUnitComponentManager に型 0 で聞いた結果
    /// - scanned: AudioComponentFindNext で辿った結果
    /// - count: AudioComponentCount の答え
    /// - added: manager の問い合わせには無く、FindNext から一覧へ足した数
    static func summary(reason: String, listed: Int, manager: [Item], scanned: [Item],
                        count: UInt32, added: Int) -> String {
        let all = merged(manager, scanned)
        let others = all.filter { !isApple($0) }
        let otherEffects = others.filter { effectTypes.contains($0.type) }
        return "au refresh=\(reason) listed=\(listed) mgr=\(manager.count) find=\(scanned.count)"
            + " count=\(count) added=\(added) other=\(others.count) otherFx=\(otherEffects.count)"
            + " types=\(tally(all.map { fourCC($0.type) }))"
            + " makers=\(tally(all.map { fourCC($0.manufacturer) }))"
    }

    /// Apple 以外の部品を名前つきで並べる。無ければ空。nameLimit を超えた分は数だけ。
    static func outsiderLine(manager: [Item], scanned: [Item]) -> String {
        let mgrKeys = Set(manager.map(\.key))
        let findKeys = Set(scanned.map(\.key))
        let others = merged(manager, scanned).filter { !isApple($0) }
        guard !others.isEmpty else { return "" }
        let shown = others.prefix(nameLimit).map { item -> String in
            let title = item.maker.isEmpty ? item.name : "\(item.maker): \(item.name)"
            // どちらの数え上げに居たか。片方だけなら、その問い合わせが取りこぼしている。
            let seenBy = mgrKeys.contains(item.key)
                ? (findKeys.contains(item.key) ? "" : " mgr-only")
                : " find-only"
            return "\(title) [\(fourCC(item.type))/\(fourCC(item.subType))/\(fourCC(item.manufacturer))\(seenBy)]"
        }
        let rest = others.count > nameLimit ? " +\(others.count - nameLimit) more" : ""
        return "au other: " + shown.joined(separator: ", ") + rest
    }

    /// 「値:数」を数の多い順に。同数は字の順。
    private static func tally(_ keys: [String]) -> String {
        guard !keys.isEmpty else { return "-" }
        var counts: [String: Int] = [:]
        for key in keys { counts[key, default: 0] += 1 }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { "\($0.key):\($0.value)" }
            .joined(separator: ",")
    }
}
