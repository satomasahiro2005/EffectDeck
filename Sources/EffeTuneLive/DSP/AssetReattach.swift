//  AssetReattach.swift
//  instance を作り直したあとに、資産を使う段へ入れ直す。
//
//  資産は instance が持っている。出力先を切り替えたり処理レートを変えたりすると
//  EffeTuneDSP.rebuildAll が instance ごと作り直すので、カーネルに入れた係数は消える。
//
//  IR Reverb は鎖が鍵（irId）を持っているので EffeTuneDSP.reloadAssets が入れ直す。
//  designer で作る 5 種は材料（測定や帯域の設定）が段ごとの置き場にあり、
//  入れ直しはそれぞれのビューの `.onChange(of: node.instance)` に任せていた。
//  **カードを畳んでいるとビューが組み立てられないので、一度も走らない。**
//  IR Reverb で同じことが起きたのと同じ形（EffeTuneLive の reloadAssets の頭）。
//
//  FIR Crossover はここに載せない。出口が 4ch 以上でないとカーネルが
//  受け取らず（fir_crossover/kernel.cpp:323-325）、この app は 2ch で組んである。
//  送り込みが最初から一度も走らないので、入れ直すものが無い。

import Foundation

@MainActor
enum ETAssetReattach {

    /// 鎖ぜんぶを見る。**何も無ければ何もしない**（置き場に材料が無い段は素通り）。
    static func all() {
        for node in EffeTuneDSP.shared.chain where node.instance != 0 {
            one(node)
        }
    }

    /// 1 段だけ。
    ///
    /// どれも「送るものが無い」「もう繋がっている」を自分で見て黙って戻るので、
    /// 余分に呼んでも音は途切れない。
    static func one(_ node: EffeTuneDSP.Node) {
        switch node.spec.type {
        case "RoomEqPlugin":
            RoomEQStore.shared.resendIfGone(node: node)
        case "CrosstalkCancellationPlugin":
            CrosstalkStore.shared.resend(node: node)
        case "GroupDelayEqPlugin":
            ETGroupDelayEQDesigners.shared.sync(node: node)
        case "GroupDelayPEQPlugin":
            GroupDelayPEQDesigners.shared.sync(node: node)
        case "FiveBandFIRPEQPlugin":
            // この置き場は designer を引くついでに繋ぎ直す。tapId が変わっていれば
            // 設定を引き継いだまま作り直して start() まで進む
            // （FiveBandFIRPEQView.swift の BandFIRPEQDesignerStore）。
            _ = BandFIRPEQDesignerStore.shared.designer(
                for: node,
                sampleRate: EffeTuneDSP.shared.sampleRate,
                outputChannelCount: 2)
        default:
            break
        }
    }
}
