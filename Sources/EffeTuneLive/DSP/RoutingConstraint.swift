//  RoutingConstraint.swift
//  エフェクトが要求するチャンネルの幅（docs/virtual-room-design.md §52）。
//
//  Virtual Room は左右 2ch を 2 本の仮想スピーカーとして扱うので、
//  Left だけ・All（3ch 以上）へ挿しても意味を成さない。
//  Routing の画面がこれを見て選択肢を絞る。
//
//  **UI だけを信じない。**DSP 側でも同じ検査をする（§52）。ここは
//  「人に間違った形を選ばせない」ためだけのもの。

import Foundation

enum ETRoutingConstraint {

    /// このエフェクトが要求するチャンネル数。nil なら何でもよい。
    static func channelWidth(of type: String) -> Int? {
        type == ETVirtualRoom.type ? 2 : nil
    }

    /// その channelSpec が幅を満たすか。
    ///
    /// -1 Stereo と 16…23 のペアが 2ch。-2 All は route の幅そのままなので
    /// 2ch とは限らず、0/1 は 1ch。
    static func allows(_ spec: Int8, width: Int) -> Bool {
        guard width == 2 else { return true }
        return spec == -1 || (16...23).contains(spec)
    }

    /// 画面に出す選択肢を絞る。
    ///
    /// **いま入っている値は外れていても残す。**取り込んだプリセットが満たさない
    /// 形を持っていることがあり、選択肢から消すと Picker が別の値へ飛ぶ。
    static func options(_ all: [(Int8, String)], type: String,
                        current: Int8) -> [(Int8, String)] {
        guard let width = channelWidth(of: type) else { return all }
        return all.filter { allows($0.0, width: width) || $0.0 == current }
    }
}
