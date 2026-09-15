//  EffectSpec.swift
//  生成された EffectCatalog.swift が使う型。
//
//  中身は EffeTune の dsp/plugins/**/params.json と
//  dsp/generated/cpp/*Params.h から Tools/gen_catalog.py が写したもの。
//  offset と count は et_instance_set_params に渡す float 配列での位置。

import Foundation

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

    var id: String { name }

    var isArray: Bool { count > 1 }

    /// 画面に出す値の文字列。
    func format(_ v: Float) -> String {
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

extension Array where Element == ETEffect {
    /// カテゴリごとに、名前順で。
    var byCategory: [(String, [ETEffect])] {
        Dictionary(grouping: self, by: \.category)
            .map { ($0.key, $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.0 < $1.0 }
    }
}
