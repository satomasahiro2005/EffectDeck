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
        case "FIRCrossoverPlugin":
            FIRCrossoverDesigners.shared.sync(node: node)
        case "FiveBandFIRPEQPlugin":
            // この置き場は designer を引くついでに繋ぎ直す。tapId が変わっていれば
            // 設定を引き継いだまま作り直して start() まで進む
            // （FiveBandFIRPEQView.swift の BandFIRPEQDesignerStore）。
            _ = BandFIRPEQDesignerStore.shared.designer(
                for: node,
                sampleRate: EffeTuneDSP.shared.sampleRate,
                outputChannelCount: Int(EffeTuneDSP.shared.maxChannels))
        case BassManagementDesigners.type:
            // 値が送ってある係数と同じなら何もしない（BassManagementDesigner.evaluate）。
            BassManagementDesigners.shared.sync(node: node)
        default:
            break
        }
    }

    /// 値が変わった直後（プリセットの適用・既定へ戻す・Routing の幅）。
    /// **材料を params から読む型だけ**を見る。FIR Crossover は lt / bc を
    /// （FIRCrossoverView.swift の FIRCrossoverDesigners.sync）、Bass Management は全部を読む。
    ///
    /// 他の 5 種は材料が置き場にあり、値が変わっても送るものは変わらない。
    /// しかも 5Band FIR PEQ は置き場が空だと既定の平らな設計を送り込みに行く
    /// （BandFIRPEQDesignerStore.designer(for:) が作って start() する）ので、ここでは触らない。
    static func paramsChanged(_ node: EffeTuneDSP.Node) {
        guard node.instance != 0, readsParams.contains(node.spec.type) else { return }
        one(node)
    }

    /// 鎖へ読み込んだ直後。**材料が params だけで揃う型だけ**を見る。
    /// FIR Crossover は置き場に designer が居ないと何もしないので、読み込んだ直後は外す。
    static func loaded(_ nodes: [EffeTuneDSP.Node]) {
        for node in nodes where node.instance != 0 && buildsFromParams.contains(node.spec.type) {
            one(node)
        }
    }

    /// 設計に使う値の一部でも params から読む型。
    private static let readsParams: Set<String> = ["FIRCrossoverPlugin", BassManagementDesigners.type]
    /// 設計の材料が全部 params にある型。
    private static let buildsFromParams: Set<String> = [BassManagementDesigners.type]
}
