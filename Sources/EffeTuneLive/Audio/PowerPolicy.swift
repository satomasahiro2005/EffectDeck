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
///
/// 約束（PowerGateTests）:
///   - 閾値を**超えた**ブロックで即座に起きる。閾値ちょうどは無音
///   - 無音が idleSeconds **ちょうど**溜まったブロックで休む
///   - NaN のピークは無音として数える（比較が偽になる）
///   - idleSeconds が無限（.continuous）なら休まない
struct PowerGate {
    var thresholdLinear: Float = 0.0001      // -80 dB
    var idleSeconds: Double = 3.0

    private var silentFor: Double = 0
    private(set) var resting = false

    /// 1 ブロックぶん見る。鎖を通すなら true。
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
}

extension PowerGate {
    /// Settings の無音の閾値（dB）を、ピークと比べる振幅へ。
    static func linearThreshold(decibels: Double) -> Float {
        Float(pow(10.0, decibels / 20.0))
    }

    /// 休むまでの秒数。外部処理（AU / JSFX）の尾（リバーブの残響など）が
    /// 選んだ秒数より長ければ、尾を切らないようそちらに合わせる。
    ///
    /// **無音を入れても音を出し続ける段**（Adaptive Prediction の Autonomy / Hold）があるときは休まない。
    /// 上流はその段を temporalCapability 'must-process' にして、無音で飛ばさないようにしている
    /// （adaptive_prediction_effect.js の getTemporalCapability）。
    static func idleSeconds(mode: ETPowerMode, externalTail: Double, mustProcess: Bool = false) -> Double {
        mustProcess ? .infinity : max(mode.idleSeconds, externalTail)
    }

    /// このブロックを丸ごと 0 で済ませてよいか。
    ///
    /// 休んでいて、入力が**厳密に** 0 のときだけ。閾値以下でも 0 でなければ抜けない。
    /// 無音の閾値は Preferences.swift の silenceRange で -20dB まで上げられ、
    /// そこまで上げた人には閾値以下の弱音が素通しで聴こえているので、
    /// ピークで抜けるとその弱音が丸ごと消える。
    static func canSkipBlock(awake: Bool, inputPeak: Float) -> Bool {
        !awake && inputPeak == 0
    }
}
