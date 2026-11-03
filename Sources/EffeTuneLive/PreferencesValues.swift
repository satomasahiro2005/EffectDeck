//  PreferencesValues.swift
//  設定の値そのもの（選べる値と、保存した値の読み方）。**Foundationだけ。**
//
//  Preferences.swift から出した（PreferencesValuesTests）。あちらは画面が観測する
//  ObservableObject で、UIKit（画面を消さない設定）と AVFoundation を連れてくる。
//  選べる値の説明（note）の書き方は Preferences.swift の頭。

import Foundation

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

    /// 入口の 48 kHz に対する倍率。選ばせるのはレートのほうで、これは
    /// その隣に添える。「96 kHz」だけだと 2 倍なのか 1 倍なのかは、
    /// 入口のレートを覚えていないと出てこない。
    var factorLabel: String {
        switch self {
        case .r48:  return "1×"
        case .r96:  return "2×"
        case .r192: return "4×"
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

    /// **DAW と同じ言い方にする。**「Low / Mid / High」では何がどれだけ
    /// 動くのか読めない。バッファの大きさなら、DAW を触っている人は
    /// そのまま意味が分かるし、触っていない人にも「大きいほど安定」が伝わる。
    var label: String { "\(frames) spls" }

    /// 48 kHz で狙う 1 コールバックの長さ。**2 の冪に合わせてある。**
    /// DAW が並べるのと同じ数字にしないと、見覚えのある数として読めない。
    var frames: Int {
        switch self {
        case .interactive: return 256
        case .balanced:    return 512
        case .playback:    return 1024
        }
    }

    /// 選択肢に出す形。**選ぶ前に 3 つを見比べられる位置に数字を置く。**
    /// bufferDuration から作るので、画面側は AudioIO を読まずに済む。
    var choiceTitle: String { "\(label) · \(msLabel)" }

    var msLabel: String { String(format: "%.1f ms", bufferDuration * 1000) }

    var note: String {
        switch self {
        case .interactive: return "Lowest latency. Most likely to glitch under load."
        case .balanced:    return "A compromise."
        case .playback:    return "Most headroom. Least likely to glitch."
        }
    }

    /// 1 コールバックの長さ。短いほど遅延が減り、途切れやすくなる。
    /// **要求でしかない。** 実際に通った長さは AudioIO.blockFrames を見る。
    var bufferDuration: TimeInterval { Double(frames) / 48000 }
}

/// `@gfx` の canvas を**どう貼るか**。
///
/// **描く寸法はどちらも同じ**（スクリプトが宣言した `gfx_w` / `gfx_h`）。
/// 変わるのは表示の大きさだけで、Adaptive はカードの枠いっぱいへ伸ばし、
/// Pixel Perfect は framebuffer の 1 画素が画面の 1 画素になる所で止める。
/// `gfx_w` / `gfx_h` を枠に合わせて書き換えるのは全画面だけ。
enum ETJSFXCanvasMode: String, CaseIterable, Identifiable {
    // **並びは既定を左に。**allCases がそのまま札の順になる。
    case adaptive
    case pixelPerfect

    var id: String { rawValue }
    var label: String {
        switch self {
        case .adaptive:     return "Adaptive"
        case .pixelPerfect: return "Pixel Perfect"
        }
    }
}

/// 保存の鍵と、保存した値の読み方。
///
/// **読むときに範囲へ収める。**保存した値は前の版が書いたものかもしれないし、
/// 引数（`-pref.silence`）で渡されたものかもしれない。画面の Stepper は範囲の中しか
/// 出さないが、読んだ値が外にあるとそのまま音の判定（RenderState.gate）へ入る。
enum PreferencesValues {

    /// UserDefaults の鍵。**綴りを変えない。**UI テストと撮影は引数（`-pref.power balanced`）で渡す。
    enum Key {
        static let rate = "pref.rate"
        static let latency = "pref.latency"
        static let power = "pref.power"
        static let silence = "pref.silence"
        static let awake = "pref.awake"
        static let syncVisualsToAudio = "pref.syncVisualsToAudio"
        static let jsfxCanvasMode = "pref.jsfxCanvasMode"
        /// 前の版の「Remote Control を入れる」。remoteConnect へ移した（remoteWantsConnection）。読むだけ。
        static let remoteEnabled = "pref.remoteEnabled"
        static let remoteConnect = "pref.remoteConnect"
        static let remoteAddress = "pref.remoteAddress"
    }

    /// 起動でつなぎ直すか。新しい鍵があればそれ、無ければ前の版の remoteEnabled を引き継ぐ
    /// （入れてあった → つなぎ直す、切ってあった・何も無い → つながない）。
    static func remoteWantsConnection(stored: Any?, legacy: Any?) -> Bool {
        (stored as? Bool) ?? (legacy as? Bool) ?? false
    }

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
    /// 保存が無い・読めないときの値。
    static let silenceDefault: Double = -80

    /// 保存した Processing rate。無い・知らない値なら 96 kHz（EffeTune の既定）。
    static func processingRate(_ stored: Any?) -> ETProcessingRate {
        ETProcessingRate(rawValue: stored as? Int ?? ETProcessingRate.r96.rawValue) ?? .r96
    }

    /// 保存した Latency。無い・知らない値なら interactive。
    static func latency(_ stored: Any?) -> ETLatency {
        ETLatency(rawValue: stored as? String ?? "") ?? .interactive
    }

    /// 保存した Silence threshold。**範囲の外は端へ寄せる。**数でない・NaN なら既定。
    static func silenceThreshold(_ stored: Any?) -> Double {
        guard let db = stored as? Double, !db.isNaN else { return silenceDefault }
        return min(max(db, silenceRange.lowerBound), silenceRange.upperBound)
    }

    /// 保存した canvas の貼り方。無い・知らない値なら Adaptive。
    ///
    /// **既定は Adaptive。**Pixel Perfect は framebuffer の 1 画素を画面の
    /// 1 画素で貼るので、`gfx_ext_retina` を名乗らないスクリプトでは画面の
    /// 倍率だけ小さくなる（3x の端末で `@gfx 640 360` が 213x120 point）。
    /// 鮮明だが指では触りにくいので、大きく出るほうを既定にする。
    static func jsfxCanvasMode(_ stored: Any?) -> ETJSFXCanvasMode {
        ETJSFXCanvasMode(rawValue: stored as? String ?? "") ?? .adaptive
    }
}
