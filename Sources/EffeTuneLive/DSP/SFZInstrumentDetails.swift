//  SFZInstrumentDetails.swift
//  SoundFont Note Player の Instrument Details（2.17.0）と、鍵盤スイッチの枠（型 34・版 1）。**Foundation だけ。**
//
//  上流 plugins/sfz-instrument.js の _renderInstrumentDetails・_renderActiveSwitchLabels と、
//  _ensureSwitchTelemetrySubscription の枠の検め方をそのまま持つ。
//  枠（sfz_instrument のカーネルが毎回の telemetry で書く）:
//      0 + チャンネル × 2   i16 そのチャンネルで最後に押された鍵盤スイッチの鍵（-1 = 無し）
//  長さは 16 チャンネル × 2 = 32 バイトちょうど。鍵が -1…127 の外なら枠ごと捨てる。
//  画面は行の一覧と 1 行の状態をここから引く（SFZNotePlayerView）。

import Foundation

/// 鍵盤スイッチの枠（型 34・版 1）。
struct ETSFZKeyswitchFrame: Equatable {
    /// チャンネルごとの鍵（-1 = 無し）。16 個。
    var keys: [Int]

    static let channelCount = 16
    static let byteCount = channelCount * 2

    static func parse(type: UInt16, version: UInt16, payload: [UInt8]) -> ETSFZKeyswitchFrame? {
        guard type == ETFrameType.sfzKeyswitches.rawValue, version == 1, payload.count == byteCount else { return nil }
        var keys: [Int] = []
        keys.reserveCapacity(channelCount)
        for channel in 0..<channelCount {
            let raw = UInt16(payload[channel * 2]) | UInt16(payload[channel * 2 + 1]) << 8
            let key = Int(Int16(bitPattern: raw))
            guard key >= -1, key <= 127 else { return nil }
            keys.append(key)
        }
        return ETSFZKeyswitchFrame(keys: keys)
    }
}

/// Instrument Details の中身。
enum ETSFZInstrumentDetails {

    struct Row: Equatable {
        var name: String
        var value: String
    }

    /// 開く欄そのものを出すか。画像も行も無ければ出さない（上流は container.hidden）。
    static func isEmpty(_ presentation: ETSFZScriptPresentation?) -> Bool {
        guard let presentation else { return true }
        return presentation.imageData == nil && rows(presentation).isEmpty
    }

    /// 欄の行。並びは上流どおり Key → CC → Output → Group → 範囲（Global・Master・Region）→ Keyswitch。
    /// Output は 0 始まりで来るので 1 を足す。
    static func rows(_ presentation: ETSFZScriptPresentation) -> [Row] {
        var rows: [Row] = []
        for item in presentation.keys { rows.append(Row(name: "Key \(item.index)", value: item.label)) }
        for item in presentation.controllers { rows.append(Row(name: "CC \(item.index)", value: item.label)) }
        for item in presentation.outputs { rows.append(Row(name: "Output \(item.index + 1)", value: item.label)) }
        for label in presentation.groups { rows.append(Row(name: "Group", value: label)) }
        for item in presentation.scopes { rows.append(Row(name: capitalized(item.scope), value: item.label)) }
        for item in presentation.switches {
            let range = item.first == item.last ? "\(item.first)" : "\(item.first)–\(item.last)"
            rows.append(Row(name: "Keyswitch \(range)", value: item.label))
        }
        return rows
    }

    /// 上流の scope[0].toUpperCase() + scope.slice(1)。
    private static func capitalized(_ scope: String) -> String {
        guard let first = scope.first else { return scope }
        return first.uppercased() + String(scope.dropFirst())
    }

    /// 押されているスイッチの 1 行（"Keyswitch · Channel 1: Legato · Channel 2: Staccato"）。出すものが無ければ nil。
    /// mixerChannel は mc（0 = 全チャンネル、n = n 番だけ）。ラベルは範囲に入る名前を重ねずに並べる。
    static func activeLine(frame: ETSFZKeyswitchFrame?, switches: [(first: Int, last: Int, label: String)],
                           mixerChannel: Int = 0) -> String? {
        guard let frame, !switches.isEmpty else { return nil }
        var parts: [String] = []
        for (channel, key) in frame.keys.enumerated() {
            if key < 0 || (mixerChannel > 0 && channel != mixerChannel - 1) { continue }
            var names: [String] = []
            for item in switches where key >= item.first && key <= item.last && !names.contains(item.label) {
                names.append(item.label)
            }
            if !names.isEmpty { parts.append("Channel \(channel + 1): \(names.joined(separator: ", "))") }
        }
        return parts.isEmpty ? nil : "Keyswitch · " + parts.joined(separator: " · ")
    }
}
