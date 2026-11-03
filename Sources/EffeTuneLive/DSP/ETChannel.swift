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
//
//  **その段が何本を処理するか（processedWidth）もここだけに置く。**前は同じ決まりの写しが
//  4 つあって食い違っていた（EffeTuneDSP.routedChannels・BandFIRPEQDesigner・GroupDelayEQDesigner・
//  GroupDelayPEQSettings）。ETChannelTests が表の全部で見張るのは processedWidth だけ。
//  designer の 3 つはまだ自前の写しを持っていて、ここへ寄せるまでは表で見張られていない。

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

    /// その段をengineが実際に回す幅。**回さないなら0。**
    ///
    /// engine.cpp:757-769（build_plan）と:990-1000（processPipeline）の飛ばし方をそのまま写す:
    ///
    ///     routed_channels = channelSpec == -1 || channelSpec >= 16 ? 2 : 1;   // -2 は全部
    ///     first_channel   = channelSpec >= 16 ? (channelSpec - 16) * 2 : max(channelSpec, 0);
    ///     if (first_channel + routed_channels > channel_count) continue;      // 回さない
    ///
    ///   - -2（All）: engineの幅そのもの
    ///   - -1（Stereo、既定）: 1ch目と2ch目。出力1chでは回さない
    ///   - 0〜15（L / R / "3"〜"16"）: その1本。engineの幅より外なら回さない
    ///   - 16〜23（対）: 1+2 / 3+4 / … 。対がengineの幅に収まらなければ回さない
    ///
    /// engineの幅が1〜16の外、engineが拒むCh（validChannelSpec、engine.cpp:111-113）も0。
    ///
    /// 上流の selectedIrChannelCount（ir-plugin-contract.js:26-39）は1本を幅を見ずに1と数え、
    /// Stereoを出力1chで1と数える。どちらもengineは回さないので、こちらはengineに合わせる
    /// （ETChannelTestsが表の全部で照らす）。
    static func processedWidth(spec: Int8, engineChannels: Int) -> Int {
        guard (1...16).contains(engineChannels) else { return 0 }
        let first: Int
        let routed: Int
        switch spec {
        case -2:
            return engineChannels
        case -1:
            first = 0
            routed = 2
        case 0...15:
            first = Int(spec)
            routed = 1
        case 16...23:
            first = Int(spec - 16) * 2
            routed = 2
        default:
            return 0
        }
        return first + routed > engineChannels ? 0 : routed
    }

    /// 置いたChが名乗る幅。**はみ出しを見ない。**engineの幅が1以上なら0を返さない。
    ///
    /// 外部の段（AU / JSFX）のhostに組ませる形に使う。engineが飛ばす段でもhostはバスの形を作るので、
    /// 0は渡せない。値はprocessedWidthを入れる前のEffeTuneDSP.routedChannelsと同じ。
    static func nominalWidth(spec: Int8, engineChannels: Int) -> Int {
        switch spec {
        case -2: return engineChannels
        case -1: return min(2, engineChannels)
        case 16...: return 2
        default: return 1
        }
    }
}
