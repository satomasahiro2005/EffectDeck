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
//  FIR Crossover も処理幅を含む Target を持つため、出力IFの本数が変わったときは
//  ここから繋ぎ直す。これならカードが畳まれていても新しい instance へ戻せる。
//
//  Bass Management（2.11.0）は**材料が全部 params にある**。置き場に何も無くても
//  値だけで設計できるので、instance を作り直したときに加えて、プリセットを当てた直後
//  （EffeTuneDSP.setValues）と鎖を読んだ直後（loaded）にもここから設計させる。
//  そうしないと、畳んだカードの Linear は Sub と LFE が無音のまま残る
//  （bass_management/kernel.cpp:329-381）。
//
//  5Band FIR PEQ・Group Delay EQ / PEQ・FIR Crossoverは、材料をNode.designにも持つ
//  （DSP/DesignParams.swift）。鎖を読んだ直後は、材料を持っている段だけここから設計させる。
//  持っていない段は既定の設計（平ら）なので、置き場を作ると送り込みで音が一瞬切れるだけになる。

import Foundation

@MainActor
enum ETAssetReattach {

    /// 鎖ぜんぶを見る。**何も無ければ何もしない**（置き場に材料が無い段は素通り）。
    static func all() {
        for node in EffeTuneDSP.shared.nodes where node.instance != 0 {
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
        case ETDesignParam.groupDelayEQ:
            ETGroupDelayEQDesigners.shared.sync(node: node)
        case ETDesignParam.groupDelayPEQ:
            GroupDelayPEQDesigners.shared.sync(node: node)
        case ETDesignParam.firCrossover:
            FIRCrossoverDesigners.shared.sync(node: node)
        case ETDesignParam.fiveBandFIRPEQ:
            // 置き場が既にあるか、段が材料を持っているときだけ。tapIdが変わっていれば
            // 設定を引き継いだまま作り直してstart()まで進む
            // （FiveBandFIRPEQView.swiftのBandFIRPEQDesignerStore）。
            BandFIRPEQDesignerStore.shared.sync(node: node)
        case BassManagementDesigners.type:
            // 値が送ってある係数と同じなら何もしない（BassManagementDesigner.evaluate）。
            BassManagementDesigners.shared.sync(node: node)
        default:
            break
        }
    }

    /// 値か設計の材料が変わった直後（プリセットの適用・既定へ戻す・Routingの幅）。
    /// **材料をparamsかNode.designから読む型だけ**を見る。
    ///   - FIR Crossoverはlt / bcとNode.designを（FIRCrossoverView.swiftのFIRCrossoverDesigners.sync）、
    ///     Bass Managementは全部を読む
    ///   - 5Band FIR PEQ・Group Delay EQ / PEQはltとNode.designから設定を組み直す（各置き場のadopt）
    ///
    /// Room EQとCrosstalkは材料が置き場（測定）にあり、値が変わっても送るものは変わらない。
    static func paramsChanged(_ node: EffeTuneDSP.Node) {
        guard node.instance != 0 else { return }
        switch node.spec.type {
        case ETDesignParam.fiveBandFIRPEQ:
            BandFIRPEQDesignerStore.shared.adopt(node: node)
        case ETDesignParam.groupDelayEQ:
            ETGroupDelayEQDesigners.shared.adopt(node: node)
        case ETDesignParam.groupDelayPEQ:
            GroupDelayPEQDesigners.shared.adopt(node: node)
        case ETDesignParam.firCrossover, BassManagementDesigners.type:
            one(node)
        default:
            break
        }
    }

    /// 鎖へ読み込んだ直後。**材料がparamsとNode.designで揃う段だけ**を見る。
    /// Bass Managementは常に、designerの4種は材料を持っているときだけ
    /// （持っていなければ各置き場のsyncが黙って戻る）。
    static func loaded(_ nodes: [EffeTuneDSP.Node]) {
        for node in nodes where node.instance != 0 {
            if node.spec.type == BassManagementDesigners.type || !node.design.isEmpty
                || BandFIRPEQDesignerStore.carriesDesign(node) {
                one(node)
            }
        }
    }
}
