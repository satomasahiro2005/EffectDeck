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
    /// ただし幅まで iPad になると実機の見え方にならないので、
    /// iPhone の幅に絞る。
    static let phoneWidth: CGFloat = 393

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
