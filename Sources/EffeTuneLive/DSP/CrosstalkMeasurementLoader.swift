//  CrosstalkMeasurementLoader.swift
//  Crosstalk Cancellation が食う「耳もとの測定」を音のファイルから作る。
//
//  ファイルの復号（ETIRLoader.decode）だけがここに在る。復号したチャンネルを
//  片耳ぶんの測定（左右スピーカーの 2 枠・id・onset）へ組むのは
//  CrosstalkMeasurementCore.swift の ETCrosstalkLoader.ear で、上流の取り込みの道
//  （impulse-response-import.js）をどう写したかもあちらの頭に書いてある。

import Foundation

extension ETCrosstalkLoader {

    /// 音のファイルを片耳ぶんの測定にする。
    ///
    /// - Parameters:
    ///   - url: 取り込んだファイル（IRLibrary が Documents へ写したもの）
    ///   - id: 測定の id。ライブラリの鍵をそのまま渡す
    ///   - name: 画面に出す名前
    static func load(url: URL, id: String, name: String) throws -> Ear {
        let decoded = try ETIRLoader.decode(url)
        return try ear(channels: decoded.channels,
                       sampleRate: decoded.sampleRate,
                       frames: decoded.frames,
                       id: id,
                       name: name)
    }
}
