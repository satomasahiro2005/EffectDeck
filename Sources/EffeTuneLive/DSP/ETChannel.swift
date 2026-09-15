//  ETChannel.swift
//  チャンネル指定の、保存形式（文字列）と descriptor（int8）の対応。
//
//  EffeTune のプリセットは `channel`（ロング形式）/ `ch`（ショート形式）に
//  文字列を書く。descriptor に渡すのは int8 なので、そこを繋ぐ。
//  対応は js/audio/dsp-pipeline-descriptor.js の encodeDspChannelSpec と同じ。
//
//  気をつけること:
//    - 既定は「キーが無い」で、それは Stereo (-1)。"Stereo" という綴りの値は無い
//    - "1" "2" は UI から出ない。1ch 目と 2ch 目は "L" / "R" が担当する
//    - 読み込み側の正規表現は "3"〜"16" しか通さないので、"1" を書くと
//      web 版では Stereo に落ちる。1ch 目を指すなら "L" を書くこと

import Foundation

enum ETChannel {

    /// 保存形式の文字列 → descriptor の値。未知のものは Stereo に落とす
    /// （web 版も同じ扱いで、エラーにはしない）。
    static func spec(from channel: String?) -> Int8 {
        guard let c = channel, !c.isEmpty else { return -1 }
        switch c {
        case "A", "All":    return -2
        case "L", "Left":   return 0
        case "R", "Right":  return 1
        case "34":   return 17
        case "56":   return 18
        case "78":   return 19
        case "910":  return 20
        case "1112": return 21
        case "1314": return 22
        case "1516": return 23
        default:
            if let n = Int(c), (1...16).contains(n) { return Int8(n - 1) }
            return -1
        }
    }

    /// descriptor の値 → 保存形式の文字列。nil ならキーごと出さない。
    static func channel(from spec: Int8) -> String? {
        switch spec {
        case -1: return nil          // Stereo。キーを出さないのが既定
        case -2: return "A"
        case 0:  return "L"
        case 1:  return "R"
        case 17: return "34"
        case 18: return "56"
        case 19: return "78"
        case 20: return "910"
        case 21: return "1112"
        case 22: return "1314"
        case 23: return "1516"
        default:
            // 2〜15 は 3ch 目〜16ch 目。web 版の読み込みが "3" 以上しか通さないので、
            // そこへ収まるものだけ文字列にする。
            if (2...15).contains(spec) { return String(Int(spec) + 1) }
            return nil
        }
    }

    static func pairName(_ spec: Int8) -> String {
        let first = (Int(spec) - 16) * 2 + 1
        return "\(first)+\(first + 1)"
    }
}
