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

    /// **秒そのものを出す。**
    /// 上流の Always on / Balanced / Maximum を写していたが、こちらは
    /// Maximum でも入力を止めない（下のコメント）ので、何を強めるのか読めなかった。
    /// 差は無音 1 秒か 3 秒かだけなので、その秒を名前にする。
    var label: String {
        switch self {
        case .continuous: return "Never"
        case .balanced:   return "3 s"
        case .maximum:    return "1 s"
        }
    }

    /// 選んだ値だとどうなるか。画面では選択肢のすぐ下に出る。
    /// 「音が戻れば復帰する」は 3 つに共通なので、節の footer に 1 回だけ置く。
    var note: String {
        switch self {
        case .continuous:
            return "The effects keep running even while the input is silent."
        case .balanced:
            return "Three seconds of silence and the effects stop running."
        case .maximum:
            return "One second of silence and the effects stop running. Best when the audio "
                 + "has long quiet stretches."
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
