//  RoutingConstraint.swift
//  エフェクトが要求するチャンネルの幅（docs/virtual-room-design.md §52、§64）。
//
//  Virtual Room は Speaker Layout で幅が変わる。
//    Stereo  左右 2ch を 2 本の仮想スピーカーとして扱う。Stereo か対だけ
//    5.1     6ch（L, R, C, LFE, Ls, Rs）を読んで両耳へ畳む。All だけ
//  Left だけ・Right だけへ挿しても意味を成さない。
//  Routing の画面がこれを見て選択肢を絞る。
//
//  **UI だけを信じない。**DSP 側でも同じ検査をする（§52）。ここは
//  「人に間違った形を選ばせない」ためだけのもの。

import Foundation

enum ETRoutingConstraint {

    /// このエフェクトが要求するチャンネル数。nil なら何でもよい。
    /// `values` は段の値（Virtual Room は Speaker Layout を読む）。空なら既定（Stereo）。
    static func channelWidth(of type: String, values: [Float] = []) -> Int? {
        guard type == ETVirtualRoom.type else { return nil }
        return ETVirtualRoom.isSurround(values) ? ETVirtualRoom.surroundChannels : 2
    }

    /// その channelSpec が幅を満たすか。
    ///
    /// -1 Stereo と 16…23 のペアが 2ch。-2 All は route の幅そのままなので
    /// 2ch とは限らず、0/1 は 1ch。6ch（5.1）は All だけ（host が 6 本以上で組む。§64）。
    static func allows(_ spec: Int8, width: Int) -> Bool {
        switch width {
        case 2: return spec == -1 || (16...23).contains(spec)
        case ETVirtualRoom.surroundChannels: return spec == -2
        default: return true
        }
    }

    /// 画面に出す選択肢を絞る。
    ///
    /// **いま入っている値は外れていても残す。**取り込んだプリセットが満たさない
    /// 形を持っていることがあり、選択肢から消すと Picker が別の値へ飛ぶ。
    static func options(_ all: [(Int8, String)], type: String, values: [Float] = [],
                        current: Int8) -> [(Int8, String)] {
        guard let width = channelWidth(of: type, values: values) else { return all }
        return all.filter { allows($0.0, width: width) || $0.0 == current }
    }

    /// この段のために host が処理しなければならない幅（AudioSessionRules.processingChannels の
    /// requiredByChain）。ハードウェアが 2ch でも、5.1 の Virtual Room は 6 本を要る。
    /// 幅を求めない段は 2（host の下限）。
    static func requiredProcessingChannels(of type: String, values: [Float]) -> Int {
        guard let width = channelWidth(of: type, values: values) else { return 2 }
        return max(2, width)
    }

    /// Reset routing で戻す Ch。ふだんは Stereo（EffeTune の既定）、5.1 の Virtual Room だけ All。
    /// **一律に Stereo へ戻さない。**5.1 に Stereo は合わず（allows）、段が descriptor で外れて
    /// host も 2ch へ戻る。Speaker Layout は 5.1 のまま黙って鳴らなくなる。
    static func defaultChannelSpec(type: String, values: [Float]) -> Int8 {
        channelWidth(of: type, values: values) == ETVirtualRoom.surroundChannels ? -2 : -1
    }

    /// Speaker Layout を変えたときに Ch をどこへ移すか。移さなくてよければ nil。
    /// 5.1 は All でしか鳴らないので All へ、Stereo へ戻したら All を Stereo へ戻す
    /// （6ch の IF では All が 6 本になり、Stereo の Virtual Room が外れるため）。
    static func channelSpecAfterLayoutChange(surround: Bool, current: Int8) -> Int8? {
        if surround {
            return current == -2 ? nil : -2
        }
        return current == -2 ? -1 : nil
    }
}
