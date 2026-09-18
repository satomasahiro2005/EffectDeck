//  EffectSpec.swift
//  生成された EffectCatalog.swift が使う型。
//
//  中身は EffeTune の dsp/plugins/**/params.json と
//  dsp/generated/cpp/*Params.h から Tools/gen_catalog.py が写したもの。
//  offset と count は et_instance_set_params に渡す float 配列での位置。

import Foundation

/// 保存している数と画面に出す数の関係。
///
/// **`.naturalExp` は Tilt EQ の Pivot Freq だけ。**
/// params.json の `pivotExponent` は 3.0〜9.9 の自然対数で、カーネルは
/// `std::exp(raw_pivot)` を掛ける（tilt_eq/kernel.cpp:131。6.91 = ln(1000)）。
/// ラベルは "Pivot Freq (Hz)" なのに生の 6.91 が出ていて、しかも 1000 と打つと
/// 上限 9.9 に挟まれて約 19930Hz に飛んでいた。上流の web 版は数値欄を Hz にして
/// `Math.round(Math.exp(this.f0))` と `Math.log(clampedHz)` で往復している
/// （tilt_eq.js:266, 294-295）。
///
/// 同じ params.json に `bitErrorRateExponent` / `radioBitErrorExponent` もあるが、
/// あちらは `pow(10, x)` の指数を**そのまま見せるのが上流の表記**（ラベルが "10^x"）
/// なので `.direct` のまま。名前が Exponent で終わるかどうかで決めない。
enum ETParamScale {
    /// そのまま。
    case direct
    /// 保存しているのは自然対数。画面には exp した数を出す。
    case naturalExp

    func display(_ v: Float) -> Float {
        switch self {
        case .direct: return v
        case .naturalExp: return exp(v)
        }
    }

    func store(_ v: Float) -> Float {
        switch self {
        case .direct: return v
        case .naturalExp: return v > 0 ? log(v) : -.greatestFiniteMagnitude
        }
    }
}

enum ETParamKind {
    /// 数値。isInteger なら整数に丸める。step が 0 なら連続。
    case number(min: Float, max: Float, step: Float, unit: String, isInteger: Bool)
    /// 選択肢。値は values の添字。
    case enumeration([String])
    /// 入切。0 か 1。
    case toggle
}

struct ETParam: Identifiable {
    let name: String        // params.json の名前。ヘッダのメンバ名と同じ
    /// 保存形式で使う短い名前（`vl` など）。EffeTune のプリセットはこちらを書く。
    /// 2 文字とは限らない（Stereo Blend は `stereo`）。
    let key: String
    let label: String       // 画面に出す名前
    let kind: ETParamKind
    let defaultValue: Float
    let offset: Int         // packed float 配列での位置
    let count: Int          // 配列なら 2 以上

    /// EffeTune のプリセットで、この値がオブジェクト配列の中に入るときの外側の名前。
    ///
    /// 上流は 5Band Dynamic EQ を
    ///     "bs": [{"en": …, "ft": …, "f": …}, … ×5]
    /// と書く（params.json の objectArrayKey / memberKey）。
    /// 平らな `"en": [...]` で書いてはいけない理由が 2 つある:
    ///   1. 段の入切も `en` なので、shortForm が後から上書きして配列が Bool に潰れる
    ///   2. web 版も同梱プリセットもこの形しか読まない
    /// objectArrayKey を持つのは params.json 8 本・57 フィールド。
    var objectArrayKey: String? = nil

    /// Spatial Mapper 2.10.0 stores each 16×16 routing matrix as a flat array.
    var flatArrayKey: String? = nil

    /// そのオブジェクトの中での名前。
    var memberKey: String? = nil

    /// 保存している値と画面に出す値がずれるもの。
    var scale: ETParamScale = .direct

    var id: String { name }

    var isArray: Bool { count > 1 }

    /// オブジェクト配列の一要素として書くか。
    var isObjectMember: Bool { objectArrayKey != nil && memberKey != nil && isArray }

    /// 保存している値 → 画面に出す値。
    func display(_ v: Float) -> Float { scale.display(v) }

    /// 画面に打たれた値 → 保存する値。
    func store(_ v: Float) -> Float { scale.store(v) }

    /// 画面に出す値の文字列。scale を通した数で書く。
    func format(_ raw: Float) -> String {
        let v = display(raw)
        switch kind {
        case .toggle:
            return v >= 0.5 ? "入" : "切"
        case .enumeration(let values):
            let i = Int(v.rounded())
            return values.indices.contains(i) ? values[i] : "\(i)"
        case .number(_, _, _, let unit, let isInteger):
            let s = isInteger ? String(Int(v.rounded()))
                              : (abs(v) >= 100 ? String(format: "%.0f", v)
                                 : abs(v) >= 10 ? String(format: "%.1f", v)
                                 : String(format: "%.2f", v))
            return unit.isEmpty ? s : "\(s) \(unit)"
        }
    }
}

struct ETEffect: Identifiable {
    let type: String        // "ToneControlPlugin"。et_instance_create に渡す名前
    let name: String        // "Tone Control"
    let about: String
    let category: String    // "eq" など。dsp/plugins の直下の名前
    let paramsHash: UInt32
    let floatCount: Int
    let defaults: [Float]
    let params: [ETParam]

    var id: String { type }

    /// 画面に出さないもの。音を変えず、値を見せる場所もまだ無い。
    var isAnalyzer: Bool { category == "analyzer" }
}

extension ETEffect {
    static func external(type: String, name: String, category: String) -> ETEffect {
        ETEffect(type: type, name: name, about: "External processor", category: category,
                 paramsHash: 0, floatCount: 0, defaults: [], params: [])
    }
}

extension Array where Element == ETEffect {
    /// カテゴリごとに、名前順で。
    var byCategory: [(String, [ETEffect])] {
        Dictionary(grouping: self, by: \.category)
            .map { ($0.key, $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.0 < $1.0 }
    }
}
