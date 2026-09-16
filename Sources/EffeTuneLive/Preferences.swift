//  Preferences.swift
//  設定の置き場。EffeTune が localStorage の effetune_audio_preferences に
//  持っているものと、同じ考え方・同じ名前で揃えてある。
//
//  note は「選んでいる値だとどうなるか」を 1 文で言うもの。
//  画面では選択肢のすぐ下に出す。反対側（選ばなかったときの話）は書かない。

import Foundation
import AVFoundation
import UIKit

/// DSP を回すレート。
/// 拡張から来る音は 48kHz 固定なので、比が整数になるものだけ出す。
/// 44.1kHz 系を混ぜると有理数比の変換になり、重くなる割に得るものが無い。
enum ETProcessingRate: Int, CaseIterable, Identifiable {
    case r48 = 48000
    case r96 = 96000
    case r192 = 192000

    var id: Int { rawValue }

    var factor: UInt32 {
        UInt32(rawValue / 48000)
    }

    var label: String {
        switch self {
        case .r48:  return "48 kHz"
        case .r96:  return "96 kHz"
        case .r192: return "192 kHz"
        }
    }

    var note: String {
        switch self {
        case .r48:
            return "The same rate the audio arrives at. Lowest load."
        case .r96:
            return "Twice the incoming rate, which reduces aliasing from distortion and "
                 + "other nonlinear effects. EffeTune's default."
        case .r192:
            return "Four times the incoming rate. Least aliasing, highest load."
        }
    }
}

/// EffeTune の latencyHint と同じ 3 段階。
enum ETLatency: String, CaseIterable, Identifiable {
    case interactive
    case balanced
    case playback

    var id: String { rawValue }

    var label: String {
        switch self {
        case .interactive: return "Low"
        case .balanced:    return "Mid"
        case .playback:    return "High"
        }
    }

    /// 選択肢に出す形。**選ぶ前に 3 つを見比べられる位置に数字を置く。**
    /// bufferDuration から作るので、画面側は AudioIO を読まずに済む。
    var choiceTitle: String { "\(label) · \(msLabel)" }

    var msLabel: String { String(format: "%.0f ms", bufferDuration * 1000) }

    var note: String {
        switch self {
        case .interactive: return "Shortest delay. Most likely to break up under load."
        case .balanced:    return "A compromise."
        case .playback:    return "Most stable."
        }
    }

    /// 1 コールバックの長さ。短いほど遅延が減り、途切れやすくなる。
    /// **要求でしかない。** 実際に通った長さは AudioIO.blockFrames を見る。
    var bufferDuration: TimeInterval {
        switch self {
        case .interactive: return 0.005
        case .balanced:    return 0.010
        case .playback:    return 0.023
        }
    }
}

@MainActor
final class Preferences: ObservableObject {

    static let shared = Preferences()

    /// 無音と見なす大きさの範囲。EffeTune の power-policy.js が持っている
    /// SILENCE_THRESHOLD_DB_VALUES（-90 … -20 を 10 dB 刻み）と同じ。
    ///
    /// 下限が -90 dB なのは、そこが「静かな録音が自分で持っている雑音」の高さだから。
    /// これより下げても、厳密な digital zero 以外では休みに入らなくなるだけで、
    /// 区別が付かない。
    /// 上限が -20 dB なのは、-20 dBFS はもう聞こえる音楽だから。
    /// これより上げると、静かな小節を無音と読んで頭を切る。
    static let silenceRange: ClosedRange<Double> = (-90)...(-20)
    static let silenceStep: Double = 10

    @Published var processingRate: ETProcessingRate {
        didSet { save(processingRate.rawValue, "pref.rate"); onAudioChange?() }
    }
    @Published var latency: ETLatency {
        didSet { save(latency.rawValue, "pref.latency"); onAudioChange?() }
    }
    @Published var powerMode: ETPowerMode {
        didSet { save(powerMode.rawValue, "pref.power"); onAudioChange?() }
    }
    /// 無音と見なす大きさ。EffeTune の Silence threshold と同じ。
    /// start() の中でしか読まれないので、変えたら組み直す（音が一瞬切れる）。
    @Published var silenceThresholdDb: Double {
        didSet { save(silenceThresholdDb, "pref.silence"); onAudioChange?() }
    }
    @Published var keepScreenAwake: Bool {
        didSet {
            save(keepScreenAwake, "pref.awake")
            UIApplication.shared.isIdleTimerDisabled = keepScreenAwake
        }
    }

    /// 音の経路を組み直す必要がある設定が変わったときに呼ばれる。
    var onAudioChange: (() -> Void)?

    private init() {
        let d = UserDefaults.standard
        processingRate = ETProcessingRate(rawValue: d.object(forKey: "pref.rate") as? Int ?? 96000) ?? .r96
        latency = ETLatency(rawValue: d.string(forKey: "pref.latency") ?? "") ?? .interactive
        powerMode = ETPowerMode(rawValue: d.string(forKey: "pref.power") ?? "") ?? .balanced
        silenceThresholdDb = d.object(forKey: "pref.silence") as? Double ?? -80
        keepScreenAwake = d.object(forKey: "pref.awake") as? Bool ?? false

        // **init の代入では didSet が走らない。**
        // そのため、保存値が true でも起動直後だけ画面が落ちていた。
        // 設定を開いて触るまで効かない設定は、効いていないのと同じ。
        UIApplication.shared.isIdleTimerDisabled = keepScreenAwake
    }

    private func save(_ v: Any, _ key: String) {
        UserDefaults.standard.set(v, forKey: key)
    }
}
