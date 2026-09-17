//  NowPlaying.swift
//  ロック画面とコントロールセンターに出す。
//
//  背面で鳴らし続けるアプリが何も出さないと、何が鳴っているのか分からず
//  止め方も分からなくなる。だから出す。
//
//  ただし曲名やアートワークは元のアプリのもので、こちらは持っていない。
//  出せるのは「EffectDeck が処理している」ことと、鎖の入切だけ。
//  曲の情報を偽って出すと、いま流れている曲だと誤解されるので出さない。

import Foundation
import MediaPlayer

@MainActor
enum NowPlaying {

    private static var wired = false

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
    /// `off` の 6 回は全部 `rsp=0` で内蔵／BT へ出ており、一度も仮想デバイスに
    /// 乗っていない。`routeSharingPolicy` はこちらが一度も設定していないので、
    /// 1（LongFormAudio）は系が書いたもの。ヘッダの定義がそのまま症状になっている:
    ///   「All applications on the system that use the long-form audio route
    ///    sharing policy will have their audio routed to the same location.」
    /// その location が EffeTune なので、自分の音が自分へ戻る。
    ///
    /// **引き金**: アプリが動いていない状態で EffeTune を選ぶ、または
    /// タスクキル後に選び直す。どちらも「仮想デバイスが選ばれている最中に
    /// こちらがセッションを開く」並びになる。
    ///
    /// **失うものは無い。** 名乗っていた頃もロック画面に EffectDeck の
    /// 再生/一時停止は出ていなかった（2026-09-16 ユーザー確認）。
    /// 鳴らしているアプリが Now Playing を握っているので、こちらは出番が無い。
    /// そもそも鎖の入切は、コントロールセンターで出力先を iPhone Speaker と
    /// EffeTune で切り替えるのと同じことなので、割り当てる価値も無い。
    /// つまりこの配線は**効果ゼロでループバックだけ招いていた**。
    /// 名乗らなければロック画面には実際に鳴っているアプリが出る。
    enum Mode: String {
        /// 名乗る。**2026-09-16 までの既定。ループバックの原因だったので外した。**
        case on
        /// **既定。** now playing 能力を名乗らない。
        case off
        /// **わざと先に名乗る。** `start()` より前に `playbackState = .playing` を置く。
        /// 測るためだけ。
        case first
    }

    /// 引数で来たら**焼き付ける**。
    /// `-ETNowPlaying first` のように渡すのは `devicectl` から起動したときだけで、
    /// アイコンから起動すると引数は付かない。焼いておけば次から効く。
    /// 戻すときは `-ETNowPlaying on`。
    nonisolated static let mode: Mode = {
        let d = UserDefaults.standard
        if let arg = d.string(forKey: "ETNowPlaying"), let m = Mode(rawValue: arg) {
            d.set(m.rawValue, forKey: "diag.nowPlaying")
            return m
        }
        return Mode(rawValue: d.string(forKey: "diag.nowPlaying") ?? "") ?? .off
    }()

    nonisolated static var disabled: Bool { mode == .off }

    /// `start()`（＝`setCategory`）より前に now playing を名乗る。
    /// `Mode.first` のときだけ AudioIO の init から呼ぶ。
    static func claimBeforeSession() {
        guard mode == .first else { return }
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = "EffectDeck"
        info[MPNowPlayingInfoPropertyIsLiveStream] = true
        info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = .playing
    }

    /// 鎖の入切を、ロック画面の再生/一時停止に割り当てる。
    /// 曲を止めるのではなく、素通しに切り替える。
    static func start(toggle: @escaping (Bool) -> Void) {
        guard !disabled else { return }
        let center = MPRemoteCommandCenter.shared()

        if !wired {
            wired = true
            center.playCommand.addTarget { _ in
                toggle(true)
                return .success
            }
            center.pauseCommand.addTarget { _ in
                toggle(false)
                return .success
            }
            center.togglePlayPauseCommand.addTarget { _ in
                toggle(!EffeTuneDSP.shared.bypass ? false : true)
                return .success
            }
            // 曲送りは持っていない。出すと押せてしまうので閉じる。
            center.nextTrackCommand.isEnabled = false
            center.previousTrackCommand.isEnabled = false
            center.changePlaybackPositionCommand.isEnabled = false
        }

        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
    }

    static func stop() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    /// いまの状態を反映する。
    /// - running: 音が来ていて処理の口が開いているか
    /// - active: 鎖を通しているか（素通しなら false）
    /// - count: 通しているエフェクトの数
    static func update(running: Bool, active: Bool, count: Int) {
        guard !disabled else { return }
        guard running else { stop(); return }

        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = "EffectDeck"
        info[MPMediaItemPropertyArtist] = active
            ? (count == 1 ? "1 effect" : "\(count) effects")
            : "Bypassed"
        // 尺も再生位置も持っていないので出さない。
        // 出すと元のアプリの曲の進みだと誤解される。
        info[MPNowPlayingInfoPropertyIsLiveStream] = true
        info[MPNowPlayingInfoPropertyPlaybackRate] = active ? 1.0 : 0.0

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = active ? .playing : .paused
    }
}
