//  DebugPresets.swift
//  実機で見るための鎖。**Debug ビルドだけ。**
//
//  出荷物には入らない（呼ぶ側が `#if DEBUG` で囲っている。EffectPickerView の
//  systemCategories と同じ扱い）。手で毎回組み直すのが面倒なだけのもので、
//  仕様でも見本でもない。
//
//  形はショート形式（`nm` / `en` と、パラメータをそのまま並べたもの）。
//  読むのは ETShareLink.parse なので、共有リンクやプリセットと同じ道を通る。
//
//  **名前は Generated/EffectCatalog.swift の `name` と一字も違えない。**
//  違うと PipelineStore.parse が「知らないエフェクト」で黙って落とす。

import Foundation

enum ETDebugPresets {

    /// 一覧に出す順。
    static let all: [(name: String, json: String)] = [
        ("Reorder · mixed heights", reorder),
        ("Sections · named and unnamed", sections),
        ("Graphs · analyzers", graphs),
    ]

    /// 並べ替えを見る。**高さをわざとばらばらにしてある。**
    ///
    /// 小さいカード（Volume は 1 行）と大きいカード（Spectrogram は図が
    /// 170pt、Note Spectrogram はさらに鍵盤が付く）を交互に置く。
    /// 落とし先の判定は「掴んだ矩形の端と、隣の行の中心」なので、
    /// **大きいものを掴む・大きいものへ重ねるの両方**をこれ 1 本で試せる。
    private static let reorder = """
    [{"nm":"Volume","en":true,"vl":0},
     {"nm":"Spectrogram","en":true},
     {"nm":"Volume","en":true,"vl":-3},
     {"nm":"Level Meter","en":true},
     {"nm":"Note Spectrogram","en":true},
     {"nm":"Volume","en":true,"vl":-6},
     {"nm":"5Band PEQ","en":true}]
    """

    /// 組を見る。名前つきの組・その中の段・**無名の区切り**・その外の段。
    ///
    /// 無名の区切りは「組を閉じる印」で、畳めること・線が畳んだときだけ出ること・
    /// 増え続けないことをここで見る。最後の 2 段は区切りより後ろなので、
    /// どの組にも属さない。
    private static let sections = """
    [{"nm":"Section","en":true,"cm":"Low"},
     {"nm":"Volume","en":true,"vl":-3},
     {"nm":"15Band GEQ","en":true},
     {"nm":"Section","en":true,"cm":""},
     {"nm":"Volume","en":true,"vl":0},
     {"nm":"Level Meter","en":true}]
    """

    /// 図を見る。畳んだ段（図だけ）で押せない札が出ていないか、
    /// 図の見せ方（`cl` / `sc` / `dm`）がアプリを開き直しても残るか。
    private static let graphs = """
    [{"nm":"Spectrogram","en":true,"sc":"linear"},
     {"nm":"Spectrum Analyzer","en":true,"sc":"log-hq","dm":"bar"},
     {"nm":"Note Spectrogram","en":true,"cl":"Rainbow","pr":"High"},
     {"nm":"Level Meter","en":true},
     {"nm":"Stereo Meter","en":true}]
    """
}
