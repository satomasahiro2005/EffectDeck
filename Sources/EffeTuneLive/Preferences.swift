//  Preferences.swift
//  設定の置き場。EffeTune が localStorage の effetune_audio_preferences に
//  持っているものと、同じ考え方・同じ名前で揃えてある。

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
        case .r48:  return "Same as the incoming audio. Lowest load."
        case .r96:  return "Reduces aliasing from nonlinear effects. EffeTune's default."
        case .r192: return "Lowest aliasing, highest load."
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

    var note: String {
        switch self {
        case .interactive: return "Shortest delay. May break up under load."
        case .balanced:    return "A compromise."
        case .playback:    return "Most stable."
        }
    }

    /// 1 コールバックの長さ。短いほど遅延が減り、途切れやすくなる。
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

    @Published var processingRate: ETProcessingRate {
        didSet { save(processingRate.rawValue, "pref.rate"); onAudioChange?() }
    }
    @Published var latency: ETLatency {
        didSet { save(latency.rawValue, "pref.latency"); onAudioChange?() }
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
        keepScreenAwake = d.object(forKey: "pref.awake") as? Bool ?? false
    }

    private func save(_ v: Any, _ key: String) {
        UserDefaults.standard.set(v, forKey: key)
    }
}
