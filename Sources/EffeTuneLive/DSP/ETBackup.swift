//  ETBackup.swift
//  鎖とプリセットのファイル（書き出し・読み込み）。
//
//  **形と読み書きの中身は ETBackupFormat.swift**（Foundationだけで、単体テストに入る）。
//  ここは鎖の Node（EffeTuneDSP）を書く手前の形（PipelineStore.Loaded）へ写すだけ。
//  Node からの写しは PipelineStore.swift が持っているので、ここで書き直さない。

import Foundation

extension ETBackup {

    /// 書き出す 1 本。空なら nil（出すものが無い）。中身は ETBackupFormat.swift の data。
    static func data(chain: [EffeTuneDSP.Node],
                     presets: [String: Any],
                     effectPresets: [String: Any]) -> Data? {
        data(chain: chain.map { PipelineStore.Loaded($0) },
             presets: presets,
             effectPresets: effectPresets)
    }
}
