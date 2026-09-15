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
        // 名前が一致しなければ、そのまま型として扱う。
        // カンマ区切りで複数並べられる。1 エフェクトずつ撮るのに使う。
        default:           return name.split(separator: ",").map(String.init)
        }
    }
}
