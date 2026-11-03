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

    /// 測るためだけの口。中身と理由は NowPlayingMode.swift の ETNowPlayingMode。
    typealias Mode = ETNowPlayingMode

    /// 引数で来たら**焼き付ける（Debug だけ）**。
    /// `-ETNowPlaying first` のように渡すのは `devicectl` から起動したときだけで、
    /// アイコンから起動すると引数は付かない。Debug では焼いておけば次から効く。
    /// Release は焼かず、焼いてある値も読まない（開発中に焼いた値を店の版へ持ち込まない）。
    /// 戻すときは `-ETNowPlaying off`。
    nonisolated static let mode: Mode = {
        let d = UserDefaults.standard
        #if DEBUG
        let persists = true
        #else
        let persists = false
        #endif
        let resolved = Mode.resolve(argument: d.string(forKey: Mode.argumentKey),
                                    persisted: persists ? d.string(forKey: Mode.persistedKey) : nil,
                                    persists: persists)
        if let save = resolved.save { d.set(save.rawValue, forKey: Mode.persistedKey) }
        return resolved.mode
    }()

    nonisolated static var disabled: Bool { mode == .off }

    /// `start()`（＝`setCategory`）より前に now playing を名乗る。
    /// `Mode.first` のときだけ AudioIO の init から呼ぶ。
    static func claimBeforeSession() {
        guard mode == .first else { return }
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = ETNowPlayingText.title
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
        info[MPMediaItemPropertyTitle] = ETNowPlayingText.title
        info[MPMediaItemPropertyArtist] = ETNowPlayingText.artist(active: active, count: count)
        // 尺も再生位置も持っていないので出さない。
        // 出すと元のアプリの曲の進みだと誤解される。
        info[MPNowPlayingInfoPropertyIsLiveStream] = true
        info[MPNowPlayingInfoPropertyPlaybackRate] = active ? 1.0 : 0.0

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = active ? .playing : .paused
    }
}
