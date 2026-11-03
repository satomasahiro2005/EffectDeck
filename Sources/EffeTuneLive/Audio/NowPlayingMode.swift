//  NowPlayingMode.swift
//  NowPlaying のうち MediaPlayer に触らない部分: 測るための切り替えの決め方、
//  ロック画面に出す字と中身、変わったときだけ出す判断（NowPlayingModeTests）。
//
//  **焼き付けは Debug だけ。**`-ETNowPlaying` を UserDefaults の diag.nowPlaying へ
//  残すのは、devicectl から 1 回渡せばアイコンから起動した次の回にも効かせるため
//  （測るための口）。Release でそれを読むと、開発中に焼いた `on` が店の版に残って
//  now playing を名乗り、ループバックを招く。Release は引数だけを見て、焼かない・読まない。

import Foundation

/// 測るためだけの口。**製品の設定には出さない。**
///
/// なぜ要るか。MediaExperience の `_CMSUtility_UpdateRoutingContextForSession` は
/// `_CMSUtility_SessionCanBeAndAllowedToBeNowPlayingApp` が真だと、
/// こちらのセッションを SystemMusic ルーティングコンテキストへ移して
/// `updateRouteSharingPolicy:setByClient:` を (1, 0) で撃つ。
/// SystemMusic は non-groupable な経路が選ばれると SystemAudio へ追従するので、
/// どちらに居ても仮想デバイスを指す＝ループバック。
///
/// 判定が走るのは `setCategory` の瞬間と、Now Playing の再生状態が変わった瞬間。
/// こちらは init で `MPRemoteCommandCenter` を配線し、tick で
/// `playbackState = .playing` を置くので、**`start()` との前後が起動ごとに
/// 入れ替わる**。起動ごとに結果が変わる観測と整合する。
/// （「20%」は Unable to Connect の頻度で、ループバックの頻度ではない）
///
/// 実測（2026-09-16）。セッションを開いた瞬間の出力先と `rsp`:
///
/// | `np` | セッション開始 | `out=EffeTune` の tick |
/// |---|---|---|
/// | `on`    | 5（うち 1 回が EffeTune で開いて `rsp=1`） | 3 |
/// | `first` | 2 | 7 |
/// | `off`   | **6** | **0** |
///
/// （当時の仮想デバイス名は EffeTune。いまは ET_NAME_STEM の EffectDeck）
///
/// `off` の 6 回は全部 `rsp=0` で内蔵／BT へ出ており、一度も仮想デバイスに
/// 乗っていない。`routeSharingPolicy` はこちらが一度も設定していないので、
/// 1（LongFormAudio）は系が書いたもの。ヘッダの定義がそのまま症状になっている:
///   「All applications on the system that use the long-form audio route
///    sharing policy will have their audio routed to the same location.」
/// その location が仮想デバイスなので、自分の音が自分へ戻る。
///
/// **引き金**: アプリが動いていない状態で仮想デバイスを選ぶ、または
/// タスクキル後に選び直す。どちらも「仮想デバイスが選ばれている最中に
/// こちらがセッションを開く」並びになる。
///
/// **失うものは無い。** 名乗っていた頃もロック画面に EffectDeck の
/// 再生/一時停止は出ていなかった（2026-09-16 ユーザー確認）。
/// 鳴らしているアプリが Now Playing を握っているので、こちらは出番が無い。
/// そもそも鎖の入切は、コントロールセンターで出力先を iPhone Speaker と
/// 仮想デバイスで切り替えるのと同じことなので、割り当てる価値も無い。
/// つまりこの配線は**効果ゼロでループバックだけ招いていた**。
/// 名乗らなければロック画面には実際に鳴っているアプリが出る。
enum ETNowPlayingMode: String {
    /// 名乗る。**2026-09-16 までの既定。ループバックの原因だったので外した。**
    case on
    /// **既定。** now playing 能力を名乗らない。
    case off
    /// **わざと先に名乗る。** `start()` より前に `playbackState = .playing` を置く。
    /// 測るためだけ。
    case first

    /// 起動の引数（`-ETNowPlaying first`）。
    static let argumentKey = "ETNowPlaying"
    /// Debug で引数を焼き付けておく鍵。
    static let persistedKey = "diag.nowPlaying"

    struct Resolution: Equatable {
        var mode: ETNowPlayingMode
        /// persistedKey へ書く値。nil なら書かない。
        var save: ETNowPlayingMode?
    }

    /// 起動時の値を決める。
    /// - Parameters:
    ///   - argument: `UserDefaults.standard.string(forKey: argumentKey)`。
    ///   - persisted: `UserDefaults.standard.string(forKey: persistedKey)`。
    ///   - persists: 焼き付けるか。**Debug だけ true**（NowPlaying.mode が決める）。
    ///
    /// 引数が正しければそれ（persists なら焼く）。引数が無いか読めない字なら、
    /// persists のときだけ焼いた値を見る。どちらも無ければ `off`。
    /// 戻すときは `-ETNowPlaying off`。
    static func resolve(argument: String?, persisted: String?, persists: Bool) -> Resolution {
        if let argument, let mode = ETNowPlayingMode(rawValue: argument) {
            return Resolution(mode: mode, save: persists ? mode : nil)
        }
        guard persists, let persisted, let mode = ETNowPlayingMode(rawValue: persisted) else {
            return Resolution(mode: .off, save: nil)
        }
        return Resolution(mode: mode, save: nil)
    }
}

/// ロック画面とコントロールセンターに出す字。曲の情報は持っていないので出さない。
enum ETNowPlayingText {
    static let title = "EffectDeck"

    /// 2 行目。鎖を通していれば効いている数、素通しなら "Bypassed"。
    /// "Bypassed" は鎖ぜんぶの電源の読み上げと同じ字にしてある（PipelineView.swift の voiceOverValue）。
    static func artist(active: Bool, count: Int) -> String {
        guard active else { return "Bypassed" }
        return count == 1 ? "1 effect" : "\(count) effects"
    }
}

/// ロック画面へ出す中身（NowPlaying.update に渡す 3 つ）。
struct ETNowPlayingState: Equatable {
    /// 音が来ていて処理の口が開いているか。
    var running: Bool
    /// 鎖を通しているか。素通し（bypass）か、効いているノードが 0 なら false。
    var active: Bool
    /// 通しているエフェクトの数（ETPipeline_ActiveNodes）。
    var count: Int

    init(running: Bool, bypass: Bool, applied: Int) {
        self.running = running
        active = !bypass && applied > 0
        count = applied
    }
}

/// 変わったときだけ出す。毎回書き換えるとロック画面がちらつく。
///
/// **stop() で forget() すること。** 覚えたままだと stop→start で同じ組になったとき
/// 「変わっていない」と見て、stop() で外したばかりのロック画面の割り当てを付け直さない
/// （設定変更やレートの組み直しで毎回起きる）。
struct ETNowPlayingThrottle {
    private var last: ETNowPlayingState?

    /// いま出すべきなら true を返し、その値を覚える。
    mutating func shouldPublish(_ state: ETNowPlayingState) -> Bool {
        guard state != last else { return false }
        last = state
        return true
    }

    mutating func forget() { last = nil }
}
