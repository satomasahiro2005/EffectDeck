//  SFZCommon.swift
//  SFZ・SoundFont の読み込み側が共に引く小さな型。**Foundation だけ。**
//
//  2.16.0 まで Swift に写していた上流の js/sfz（SFZParser・SFZSource・SFZAsset・SFZBank・SFZLibraryFiles）は
//  2.17.0 で外した。SFZ の読みは上流の JS を JavaScriptCore で動かす（DSP/SFZScript/）。
//  ここに残るのは、JS の側と受け渡すための誤りの綴りと、鍵・上限の決まりと、一覧の 1 行。

import Foundation

// MARK: - 誤り

/// 上流の誤りの code。JS の側が返す綴りと同じ（ETSFZMessages が文言にする）。
enum ETSFZErrorCode: String {
    case prepare
    case tooLarge = "too-large"
    case noRegions = "no-regions"
    case storage
    case cancelled
    /// 流し込みの標本を読めなかった（SoundFont。供給が失敗した）。上流の sample-read。
    case sampleRead = "sample-read"
    /// この版が扱えない機能を使う、または欠けのある音源（上流の unsupported-runtime）。
    case unsupportedRuntime = "unsupported-runtime"
}

struct ETSFZError: Error, Equatable, LocalizedError {
    var code: ETSFZErrorCode
    var message: String
    var errorDescription: String? { message }

    static func prepare(_ message: String) -> ETSFZError { ETSFZError(code: .prepare, message: message) }
    static func tooLarge(_ message: String) -> ETSFZError { ETSFZError(code: .tooLarge, message: message) }
}

// MARK: - 規則

enum ETSFZ {
    /// 上流の既定の上限（js/sfz/limits.js）。設定の画面は持たず、いつもこの値。
    static let defaultMaxBytes = 256 * 1024 * 1024
    /// カーネルが受けられる最大（sfz_note_player/bank.h の kCapacity）。
    static let maxSupportedBytes = 1024 * 1024 * 1024

    /// 鍵（バンクの id）。sha256 の先頭 24 桁の小文字の 16 進。
    static func isValidID(_ id: String) -> Bool {
        id.utf8.count == 24 && id.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }
}

// MARK: - 一覧の 1 行

struct ETSFZLibraryEntry: Equatable, Identifiable {
    var id: String
    var name: String
    var regionCount: Int
    /// 入れ物の大きさ・入っているファイルの数・取り込んだ時刻（ISO 8601）。2.14.0 の上流の一覧と同じ。
    /// 2.13.0 で取り込んだものには無い。
    var size: Int? = nil
    var fileCount: Int? = nil
    var importedAt: String? = nil
    /// "sf2" / "sf3"（SoundFont のとき。SFZ は nil）。一覧の行に SF2・SF3 と出す（上流の formatBadge）。
    var format: String? = nil
}
