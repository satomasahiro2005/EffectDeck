//  OutputDevice.swift
//  出力先（ヘッドホン・イヤホン・内蔵スピーカー）ごとの出力補正の、値だけで決まる判断。
//  出力先の鍵・切り替える時機。**AVAudioSession に触らない**
//  （OutputDeviceTests）。口の型をKindに直す1か所だけAudioIOに残る。

import Foundation

// MARK: - 出力先の鍵

struct ETOutputDevice: Equatable {

    enum Kind: String {
        case speaker, wired, lineOut, bluetooth, bluetoothLE, hfp, usb, car, hdmi, other

        /// 行の頭に出す SF Symbols の名前。
        var symbol: String {
            switch self {
            case .speaker: return "speaker.wave.2"
            case .wired, .lineOut, .bluetooth, .bluetoothLE, .hfp: return "headphones"
            case .usb: return "cable.connector"
            case .car: return "car"
            case .hdmi: return "tv"
            case .other: return "speaker"
            }
        }
    }

    let kind: Kind
    let uid: String
    /// portName。行の名前に出す。
    let name: String

    /// 紐付けに使う鍵。nil は紐付けられない口。
    ///
    /// - スピーカー・有線・ライン出力は端末に1つずつなので種類だけで決める
    ///   （有線のヘッドホンはどれも同じ口として出る）。
    /// - Bluetooth・USB・CarPlay・HDMI は uid で見分ける。同じ名前のヘッドセットを
    ///   分けられるのは uid だけ。uid が空のときだけ名前に落とす。
    /// - HFP（通話の型）と知らない型は持たない。A2DP と HFP の行き来を「変化なし」にするため。
    var key: String? {
        switch kind {
        case .speaker: return "speaker"
        case .wired: return "wired"
        case .lineOut: return "lineOut"
        case .bluetooth, .bluetoothLE, .usb, .car, .hdmi:
            let id = uid.trimmingCharacters(in: .whitespacesAndNewlines)
            return id.isEmpty ? "\(kind.rawValue):name:\(name)" : "\(kind.rawValue):\(id)"
        case .hfp, .other: return nil
        }
    }

    /// 出力一覧の1回の読み。nil は「情報なし」で、決まっている出力先は動かさない。
    ///
    /// 自分の仮想デバイスが1つでも混じる読み（逃がしている最中の途中経過）と、
    /// HFP を含む読み、先頭が紐付けられない口の読みは、どれも情報にしない。
    static func pick(_ outputs: [ETOutputDevice]) -> ETOutputDevice? {
        guard let first = outputs.first,
              !outputs.contains(where: { ETAudioSessionRules.isOwnDevice(portName: $0.name) }),
              !outputs.contains(where: { $0.kind == .hfp }),
              first.key != nil else { return nil }
        return first
    }
}

// MARK: - 切り替えの時機

struct ETDeviceSwitch {

    /// 同じ出力先が続いてから切り替えるまで。揺れ（途中のスピーカー表示など）を越える。
    static let stableSeconds: TimeInterval = 2
    /// start() の後に待つ秒数。組み直しの後ろに回すため。
    static let afterStartSeconds: TimeInterval = 1.5
    /// 引き剥がしの操作の後に待つ秒数。その間のスピーカー表示を本物と取らない。
    static let afterEscapeSeconds: TimeInterval = ETRouteEscape.retry

    /// 決まっている出力先の鍵（outputCorrection.device に残す）。
    private(set) var settled: String?
    private(set) var candidate: String?
    private(set) var since: TimeInterval = 0

    init(settled: String?) {
        self.settled = settled
    }

    enum Step: Equatable {
        case idle
        case wait(until: TimeInterval)
        case switched(ETOutputDevice)
    }

    /// active = running && dsp.ready && !escape.overriding
    ///
    /// 「まだ準備できていない」は情報なしとして扱う。待ちの輪を持たないので、
    /// どこかで止まったまま居座ることがない。
    mutating func observe(_ device: ETOutputDevice?, active: Bool, now: TimeInterval,
                          lastStart: TimeInterval, lastEscape: TimeInterval) -> Step {
        guard active, let device, let key = device.key else {
            candidate = nil
            return .idle
        }
        if key == settled {
            candidate = nil
            return .idle
        }
        if candidate != key {
            // 揺れたら数え直す。
            candidate = key
            since = now
        }
        let due = max(since + Self.stableSeconds,
                      lastStart + Self.afterStartSeconds,
                      lastEscape + Self.afterEscapeSeconds)
        if now < due { return .wait(until: due) }
        settled = key
        candidate = nil
        return .switched(device)
    }
}
