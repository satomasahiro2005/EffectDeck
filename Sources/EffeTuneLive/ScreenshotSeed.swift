//  ScreenshotSeed.swift
//  シミュレータで画面を見るために、鎖を仕込む。
//
//  シミュレータでは拡張が動かないので音は来ないが、画面は同じものが出る。
//  起動の引数 -ETSeed <名前> で何を並べるかを選ぶ。
//  実機では引数が付かないので何もしない。
//
//  撮るときは全部開いた状態にする（PipelineView が requested を見て決める）。

import CoreGraphics
import Foundation

enum ETScreenshotSeed {

    /// 撮影で使う横幅。
    ///
    /// iPad で撮るのは高さが要るから（長いカードが iPhone だと切れる）。
    /// ただし幅まで iPad になると実機の見え方にならないので、iPhone の幅に絞る。
    ///
    /// **iPhone のシミュレータで撮るときは絞ってはいけない。**
    /// 18 Pro Max は 440pt あるので、393 に絞ると両脇に 23.5pt ずつ余る。
    /// それを左右の余白の崩れと読み違えたことがある。
    /// `-ETWidth 0` を渡すと絞らない（端末そのままの幅で出る）。
    static var phoneWidth: CGFloat {
        let v = UserDefaults.standard.object(forKey: "ETWidth") as? Int
        guard let v else { return 393 }
        return v > 0 ? CGFloat(v) : .infinity
    }

    /// 起動と同時に出すシート。`-ETSheet settings` のように渡す。
    /// エフェクトのカードだけでなく、設定やプリセットの画面も撮るために要る。
    /// 実機では引数が付かないので nil。
    /// 値まで入った鎖。上流の共有リンクと同じ形の JSON で渡す。
    /// `-ETSeed store` のときだけ使い、EffeTuneDSP.restore() がこちらを優先する。
    ///
    /// 5 バンド PEQ は素の状態だと直線なので、店頭の絵にならない。
    /// 低音を持ち上げ、200Hz あたりの濁りを削り、3kHz を少し出し、
    /// 高域に棚を足した、よくある形にしてある。
    /// 後ろに Spectrum Analyzer を置いて、かかった結果が図に出るようにする。
    static var storeChain: String? {
        guard requested != nil, UserDefaults.standard.string(forKey: "ETSeed") == "store" else {
            return nil
        }
        // キーは EffectCatalog の ETParam.key（f / g / q / t / e）で、
        // 5 要素の配列。上流の js が持つ f0..f4 という平たい形ではない
        // （PipelineStore.swift:66,160 が params.json の key を見ている）。
        return """
        {"pipeline":[
          {"name":"Spectrum Analyzer","enabled":true,"parameters":{}},
          {"name":"5Band PEQ","enabled":true,"parameters":{
            "f":[60,220,900,3200,9000],
            "g":[6.5,-4,-2,3.5,4],
            "q":[0.7,1.2,1.6,1.1,0.7],
            "t":["ls","pk","pk","pk","hs"],
            "e":[true,true,true,true,true]}}
        ]}
        """
    }

    /// 畳んだ状態で撮るか。既定は開く（中身が写らないと意味が無いので）。
    /// 畳んだときの見え方を確かめたいときだけ立てる。
    static var collapsed: Bool {
        UserDefaults.standard.bool(forKey: "ETCollapsed")
    }

    static var sheet: String? {
        UserDefaults.standard.string(forKey: "ETSheet")
    }

    static var requested: [String]? {
        guard let name = UserDefaults.standard.string(forKey: "ETSeed") else { return nil }
        switch name {
        case "none":       return []
        case "peq":        return ["FiveBandPEQPlugin"]
        case "compressor": return ["CompressorPlugin"]
        case "saturation": return ["SaturationPlugin"]
        case "meter":      return ["LevelMeterPlugin"]
        case "spectrum":   return ["SpectrumAnalyzerPlugin"]
        case "chain":      return ["VolumePlugin", "ToneControlPlugin",
                                   "CompressorPlugin", "RSReverbPlugin"]
        // 店頭用。型だけでは既定値のままで、つまみが全部真ん中に並んで
        // 何も起きていない絵になる。値は下の shareLink が持つ。
        case "store":      return []
        // 名前が一致しなければ、そのまま型として扱う。
        // カンマ区切りで複数並べられる。1 エフェクトずつ撮るのに使う。
        default:           return name.split(separator: ",").map(String.init)
        }
    }
}
