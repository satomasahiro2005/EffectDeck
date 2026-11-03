//  PipelineFormFuzz.swift（Tests/Fuzz）
//  的 pipelineform: ETChainText.prepare を通らずに鎖を読む口。
//    - バックアップのファイル（ETBackup.read）
//    - pipeline.last・プリセット（PipelineStore.parse をそのまま）
//
//  **ここは範囲へ寄せない**（設計どおり、範囲の外の値もそのまま読む）ので、範囲は見ない。
//  約束:
//    - 読んだ値はどれも ±ETParamCoding.magnitudeLimit の中（FormOracle）
//    - 読んだ鎖は書き戻せる（FormOracle）
//    - 読めたバックアップは、書き出して読み直しても読める。鎖・プリセット・エフェクトの
//      プリセットの本数が変わらない

import Foundation

enum PipelineFormFuzz {
    static func run(_ data: UnsafeRawBufferPointer) {
        let bytes = Data(data)
        guard let json = try? JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed]),
              !Fuzz.hasNonFinite(json) else { return }

        FormOracle.check(PipelineStore.parse(json, catalog: ETCatalog), "parse")

        guard case .success(let contents) = ETBackup.read(bytes, catalog: ETCatalog) else { return }
        FormOracle.check(contents.chain, "backup")
        guard let written = ETBackup.data(chain: contents.chain,
                                          presets: contents.presets,
                                          effectPresets: contents.effectPresets) else {
            Fuzz.oracle(false, "読めたバックアップを書き出せない")
            return
        }
        guard case .success(let again) = ETBackup.read(written, catalog: ETCatalog) else {
            Fuzz.oracle(false, "書き出したバックアップが読めない")
            return
        }
        Fuzz.oracle(again.chain.count == contents.chain.count,
                    "バックアップの往復で鎖の段の数が変わる \(contents.chain.count) → \(again.chain.count)")
        Fuzz.oracle(again.presets.count == contents.presets.count,
                    "バックアップの往復でプリセットの数が変わる")
        Fuzz.oracle(again.effectPresetCount == contents.effectPresetCount,
                    "バックアップの往復でエフェクトのプリセットの数が変わる")
    }
}
