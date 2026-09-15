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

    /// 鎖の入切を、ロック画面の再生/一時停止に割り当てる。
    /// 曲を止めるのではなく、素通しに切り替える。
    static func start(toggle: @escaping (Bool) -> Void) {
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
