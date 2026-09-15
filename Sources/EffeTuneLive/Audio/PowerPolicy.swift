//  PowerPolicy.swift
//  無音が続いたら演算を休む。EffeTune の Power saving mode と同じ考え方。
//
//  iPhone では web 版より切実で、背面で鳴らし続けるぶん電池を食う。
//  ただし iOS 固有の事情が1つあって、こちらがセッションを手放すと
//  出力先が元へ戻ってしまう恐れがある。だから**セッションは手放さず、
//  鎖を通すのをやめるだけ**にしてある。無音に何を掛けても無音なので、
//  聞こえ方は変わらない。

import Foundation

/// EffeTune の power-policy.js と同じ 3 段階。
enum ETPowerMode: String, CaseIterable, Identifiable {
    case continuous
    case balanced
    case maximum

    var id: String { rawValue }

    var label: String {
        switch self {
        case .continuous: return "Always on"
        case .balanced:   return "Balanced"
        case .maximum:    return "Maximum"
        }
    }

    var note: String {
        switch self {
        case .continuous: return "Never stops processing."
        case .balanced:   return "Rests while the signal is silent."
        case .maximum:    return "Rests sooner and stays resting longer."
        }
    }

    /// 休みに入るまでの無音の長さ。
    var idleSeconds: Double {
        switch self {
        case .continuous: return .infinity
        case .balanced:   return 3.0
        case .maximum:    return 1.0
        }
    }
}

/// 無音かどうかを見て、鎖を通すかどうかを決める。
/// 音のスレッドから呼ぶので、確保も待ちもしない。
struct PowerGate {
    var thresholdLinear: Float = 0.0001      // -80 dB
    var idleSeconds: Double = 3.0

    private var silentFor: Double = 0
    private(set) var resting = false

    mutating func update(peak: Float, seconds: Double) -> Bool {
        if peak > thresholdLinear {
            silentFor = 0
            resting = false
        } else {
            silentFor += seconds
            if silentFor >= idleSeconds { resting = true }
        }
        return !resting
    }

    mutating func wake() {
        silentFor = 0
        resting = false
    }
}
