//  NowPlaying.swift
//  ロック画面とコントロールセンターに出す。
//
//  背面で鳴らし続けるアプリが何も出さないと、何が鳴っているのか分からず
//  止め方も分からなくなる。だから出す。
//
//  ただし曲名やアートワークは元のアプリのもので、こちらは持っていない。
//  出せるのは「EffeTune Live が処理している」ことと、鎖の入切だけ。
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
    /// 実測（2026-09-16）: ループバック中の tick は
    ///   `out=EffeTune rsp=1 ports=MediaDeviceExtension ovr=true`
    /// `routeSharingPolicy` はこちらが一度も設定していないので、
    /// 1（LongFormAudio）は系が書いたもの。
    enum Mode: String {
        /// 製品の姿。
        case on
        /// now playing 能力を名乗らない。これで `rsp=1` が出なければ原因が確定する。
        /// 引き換えにロック画面から鎖の入切ができなくなる。
        case off
        /// **わざと先に名乗る。** `start()` より前に `playbackState = .playing` を置く。
        /// 前後の入れ替わりが原因なら、これで毎回 `rsp=1` になるはず。
        /// 起きるのを待たずに 1 回で判定するためのもの。
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
        return Mode(rawValue: d.string(forKey: "diag.nowPlaying") ?? "") ?? .on
    }()

    nonisolated static var disabled: Bool { mode == .off }

    /// `start()`（＝`setCategory`）より前に now playing を名乗る。
    /// `Mode.first` のときだけ AudioIO の init から呼ぶ。
    static func claimBeforeSession() {
        guard mode == .first else { return }
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = "EffeTune Live"
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
        info[MPMediaItemPropertyTitle] = "EffeTune Live"
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
