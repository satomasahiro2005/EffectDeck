//  SFZMessages.swift
//  SoundFont Note Player（SFZNotePlayerPlugin）と SoundFont Library の文面。**Foundation だけ。**
//
//  上流 2.17.0 の sfzNotePlayer.* と sfzLibrary.*（js/locales/en.json5）をそのまま持つ。表示名は SoundFont に
//  変わったので「SFZ」と書いていた文も SoundFont にそろえる。
//  外した句は 2 つだけ。
//  - 「Increase SoundFont size limit in Config → General」: こちらに容量上限の設定は無い（いつも既定）
//  - 「This browser …」: ブラウザではないので This device にした（sample-codec-unavailable）
//  画面は文面をここから引く（SFZNotePlayerView・SFZLibraryView）。字面が上流とずれたらテストが落ちる。
//
//  誤りの code は上流の綴り（too-large・no-regions・unsupported-runtime・sample-codec-unavailable）と
//  段の状態の綴り（tooLarge・noRegions・sampleRead・playback・unsupportedRuntime）のどちらでも引ける。
//  知らない綴りは prepare（上流の _showError と同じ）。cancelled だけは文を出さない。

import Foundation

enum ETSFZMessages {

    // MARK: 名前

    /// 段の表示名（2.17.0 から。型は SFZNotePlayerPlugin のまま）。確認の表の題に使う。
    static let playerTitle = "SoundFont Note Player"
    /// 選択欄の見出しとボタン（sfz_note_player.js:408,416）。
    static let bankLabel = "SoundFont:"
    static let libraryButton = "SoundFont Library…"
    /// バンクが何も無いとき・鍵が指すバンクが置き場に無いときの名前（sfzNotePlayer.missingBank）。
    static let noBankName = "None"
    static let missingBankName = "Missing SoundFont"

    // MARK: 誤り

    /// 赤い状態行と読み込みの知らせの文。
    static func error(_ code: String) -> String {
        switch code {
        case "cancelled": return ""
        case "too-large", "tooLarge":
            return "This SoundFont exceeds the size limit. Choose a smaller SoundFont."
        case "no-regions", "noRegions":
            return "No playable samples were found. Choose another SoundFont."
        case "storage":
            return "The SoundFont library could not be accessed. Check available storage space, then try again."
        case "sample-read", "sampleRead":
            return "Instrument playback stopped because sample data could not be loaded. Check that the source files are available. For large instruments, try a faster local drive or fewer simultaneous notes."
        case "playback":
            return "The instrument stopped because it could not continue playing. Load it again or choose another instrument."
        case "unsupported-runtime", "unsupportedRuntime":
            return "This instrument uses features that are not available in this version. Choose another SoundFont."
        case "sample-codec-unavailable", "unsupportedCodec":
            return "This device cannot play compressed SoundFonts. Choose an SF2 SoundFont."
        case "missing":
            return "The selected SoundFont could not be found. Choose it again or choose another SoundFont."
        default:
            return "The SoundFont could not be loaded. Check that its sample files are available, or choose another SoundFont."
        }
    }

    // MARK: 知らせ

    /// 上流の _warningMessage。同じ code は一度、**warnings に現れた順**（Set の順ではない）。知らない code は黙って飛ばす。
    static func warning(_ codes: [String]) -> String? {
        var seen = Set<String>()
        let lines = codes.compactMap { code -> String? in
            guard let text = warningTexts[code], seen.insert(code).inserted else { return nil }
            return text
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n\n")
    }

    private static let warningTexts: [String: String] = [
        "loop-points-ignored": "Unused loop settings were adjusted so this SoundFont could be loaded.",
        "invalid-regions": "Some sounds had invalid settings and were skipped.",
        "missing-samples": "Some sample files could not be found. The available sounds were loaded.",
        "envelope-times-adjusted": "Some sound fade times were invalid and were adjusted so this SoundFont could be loaded.",
        "reduced-bank": "A smaller selection of sounds was loaded to fit the size limit while keeping every note.",
    ]

    // MARK: SoundFont Library

    static let libraryTitle = "SoundFont Library"
    static let librarySearchPrompt = "Search SoundFont instruments"
    static let libraryEmpty = "No matching SoundFont instruments."
    static let libraryInUse = "This SoundFont is in use by an effect pipeline and cannot be deleted."
    static let libraryDeleted = "SoundFont deleted."
    static let libraryDeleteFailed = "The SoundFont could not be deleted."

    /// 一覧の行の小さい字（上流の formatBadge）。大きさ · SF2/SF3 · Files: n · Regions: n。
    /// 大きさが分からないものは size unknown。format は SF2・SF3 のときだけ大文字で出す（SFZ は何も出さない）。
    static func libraryBadge(size: Int?, format: String? = nil, fileCount: Int?, regionCount: Int?) -> String {
        var parts: [String] = []
        if let size, size >= 0 {
            parts.append(size >= 1_048_576 ? String(format: "%.1f MiB", Double(size) / 1_048_576)
                         : size >= 1024 ? String(format: "%.1f KiB", Double(size) / 1024) : "\(size) B")
        } else {
            parts.append("size unknown")
        }
        if let format, format == "sf2" || format == "sf3" { parts.append(format.uppercased()) }
        if let fileCount { parts.append("Files: \(fileCount)") }
        if let regionCount { parts.append("Regions: \(regionCount)") }
        return parts.joined(separator: " · ")
    }

    /// 「「name」を置き場から消すか」の確認の文。
    static func libraryConfirmDelete(_ name: String) -> String {
        "Delete “\(name)” from the library?"
    }
}
