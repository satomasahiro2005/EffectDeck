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
    ///
    /// **`simctl launch` の引数は文字列で入る。**`object(forKey:) as? Int` は
    /// NSString に当たって必ず nil になるので、`-ETWidth 0` を渡しても既定の
    /// 393 に落ちていた。18 Pro Max（440pt）で左右に 23.5pt ずつ余るのはこれ。
    /// 在るかどうかは object で見て、値は integer で読む。
    static var phoneWidth: CGFloat {
        guard UserDefaults.standard.object(forKey: "ETWidth") != nil else { return 393 }
        let v = UserDefaults.standard.integer(forKey: "ETWidth")
        return v > 0 ? CGFloat(v) : .infinity
    }

    /// 宣材で使う同梱プリセット。名前 → `ETSystemPresets` の id。
    ///
    /// 型を並べただけの鎖は、つまみが既定値のまま並ぶので絵にならない。
    /// **同梱のプリセットを読むと、値も段の割り当ても入った状態になる。**
    /// ルーティングの画面を撮るときも、組んだ後の姿でなければ意味が無い。
    static let storePresets: [String: String] = [
        "vinyl": "Lo-Fi/Vinyl",                  // 10 段。段の割り当ても入っている
        "karaoke": "Others/Karaoke",             // 7 段中 5 段が割り当て済み
        "analyzers": "Visualize/All Analyzers",  // 図が 5 つ動く
        "live": "Spatial/Live",
        "tube": "Amp Simulation/Tube Amp",
        "bbe": "Processor/Bbe",             // 図が 2 枚並ぶ
        "fmradio": "Processor/Fm Radio",
    ]

    /// 値まで入った鎖。上流の共有リンクと同じ形の JSON で渡す。
    /// `EffeTuneDSP.restore()` がこちらを優先する。
    ///
    /// `-ETSeed store` のときは下に直に書いた 5 バンド PEQ を返す。
    /// 素の状態だと直線で店頭の絵にならないので、低音を持ち上げ、200Hz あたりの
    /// 濁りを削り、3kHz を少し出し、高域に棚を足した、よくある形にしてある。
    /// 後ろに Spectrum Analyzer を置いて、かかった結果が図に出るようにする。
    static var storeChain: String? {
        if let name = UserDefaults.standard.string(forKey: "ETSeed"),
           let id = storePresets[name] {
            return ETSystemPresets.first { $0.id == id }?.json
        }
        // 宣材用の Analyzer 4 枚。同梱の All Analyzers から Oscilloscope を外し、
        // Level Meter を頭へ持ってきたもの。畳んで撮ると図だけが 4 つ並ぶ。
        // **Spectrogram は埋まるまで時間が要る**（SLEEP を伸ばして撮ること）。
        if UserDefaults.standard.string(forKey: "ETSeed") == "analyzers4" {
            return """
            {"pipeline":[
              {"name":"Level Meter","enabled":true,"parameters":{}},
              {"name":"Spectrogram","enabled":true,"parameters":{"dr":-96,"pt":12}},
              {"name":"Spectrum Analyzer","enabled":true,"parameters":{"dr":-96,"pt":12}},
              {"name":"Stereo Meter","enabled":true,"parameters":{"wt":0.1}}
            ]}
            """
        }
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

    /// 起動と同時に出すシート。`-ETSheet settings` のように渡す。
    /// エフェクトのカードだけでなく、設定やプリセットの画面も撮るために要る。
    /// 実機では引数が付かないので nil。
    static var sheet: String? {
        UserDefaults.standard.string(forKey: "ETSheet")
    }

    static var requested: [String]? {
        guard let name = UserDefaults.standard.string(forKey: "ETSeed") else { return nil }
        // プリセットを読むものは、並べる型を自分では決めない（storeChain が持つ）。
        if storePresets[name] != nil || name == "analyzers4" { return [] }
        switch name {
        case "none":       return []
        case "peq":        return ["FiveBandPEQPlugin"]
        case "compressor": return ["CompressorPlugin"]
        case "saturation": return ["SaturationPlugin"]
        case "meter":      return ["LevelMeterPlugin"]
        case "spectrum":   return ["SpectrumAnalyzerPlugin"]
        // PEQ の図に重ねるスペクトラム。Analyzer を **PEQ の前**に置くと入口側になる
        // （ETSpectrumOverlayFinder.source が入口を先に見る）。
        // 波形のボタンを押すまで重ならないので、撮るときは 1 度押す。
        case "peq-spectrum": return ["SpectrumAnalyzerPlugin", "FiveBandPEQPlugin"]
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
