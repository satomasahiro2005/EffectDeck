//  SongRecognitionPolicy.swift
//  曲の聞き取り（SongRecognizer.swift）の間合いだけを持つ。ShazamKit にも時計にも触れない。
//
//  入力は「いま」の時刻と、聞かせようとしている音のピークだけ。返すのは、
//  セッションを作って聞かせるか・そのまま聞かせるか・捨てるか・何もしないか。
//  Foundation だけなので Linux でも測れる（Tests/Unit/SongRecognitionPolicyTests.swift）。
//
//  **鳴っているあいだは休まず聞かせ続ける。**当たっても外れても同じセッションに流し続け、
//  曲が替われば SHSession が次の一致を返す。DJ ミックスのように無音を挟まず曲が替わるうえ
//  ずっと鳴っているので、休みを入れても意味がない（本人）。Visualizer を見ているときは
//  たぶん充電中なので電池も気にしない（本人）。止めるのは無音が続いたとき・音が飛んだとき・エラーのときだけ。
//  外れても出ている曲は消さない（つなぎの途中で外れるため）。

import Foundation

struct ETRecognizedSong: Equatable, Sendable {
    /// shazamID ?? isrc ?? appleMusicID ?? "\(title)|\(artist)"。同じ曲かの判定に使う。
    let id: String
    let title: String
    let artist: String?
    let artworkURL: URL?
}

struct SongRecognitionPolicy {

    /// -80 dBFS（PowerGate の既定と同じ）。これ以下は無音と見る。
    static let silencePeak: Float = 1e-4
    /// 聞かせている最中でも、無音がこれだけ続いたら捨てる。曲間で次の曲を拾い直すため。
    static let silenceToReset: TimeInterval = 2
    /// エラーのあとの休み。
    static let restAfterError: TimeInterval = 60

    enum Phase: Equatable {
        case waiting
        case listening(since: TimeInterval, silentSince: TimeInterval?)
        case resting(until: TimeInterval, silentSince: TimeInterval?)
    }

    enum Decision: Equatable {
        /// 何もしない。
        case skip
        /// セッションを作って、この音から聞かせる。
        case startAndFeed
        /// 作ってあるセッションに聞かせる。
        case feed
        /// セッションを捨てる。clear なら出ている曲も消す。
        case drop(clear: Bool)
    }

    private(set) var phase: Phase = .waiting
    /// 最後に当たった曲。同じ曲に当たり直しても変わったことにしない。
    private(set) var lastID: String?
    /// 替わり先の候補。曲の替わり目では前の曲と次の曲が混ざった音を問い合わせ、まるで違う曲に
    /// conf 1.00 で当たることがある（10-17 実機、Shinedown。skew が 0.0010 と大きかった）。
    /// 速さのずれ（skew）がほぼ無い当たりは 1 回で替え、ずれのある当たりは同じ候補に 2 回続けて
    /// 当たったときだけ替える（全部 2 回にしたら替わるのが 2 秒遅れて「めちゃめちゃ遅くなってる」）。
    /// 何も出ていないときはすぐ出す。
    private(set) var pendingID: String?

    /// 新しい音が来た。
    mutating func audio(now: TimeInterval, peak: Float) -> Decision {
        // NaN は無音の側へ倒す。
        let silent = !(peak > Self.silencePeak)
        switch phase {
        case .waiting:
            if silent { return .skip }
            phase = .listening(since: now, silentSince: nil)
            return .startAndFeed

        case .listening(let since, let silentSince):
            guard silent else {
                phase = .listening(since: since, silentSince: nil)
                return .feed
            }
            let from = silentSince ?? now
            if now - from >= Self.silenceToReset {
                phase = .waiting
                return .drop(clear: false)
            }
            // 短い無音は聞かせる（流れを切らない）。
            phase = .listening(since: since, silentSince: from)
            return .feed

        case .resting(let until, let silentSince):
            if now >= until {
                phase = .waiting
                return audio(now: now, peak: peak)
            }
            guard silent else {
                phase = .resting(until: until, silentSince: nil)
                return .skip
            }
            let from = silentSince ?? now
            // 無音が続いたら休みを切り上げ、次の音からすぐ聞き直す。
            phase = now - from >= Self.silenceToReset
                ? .waiting
                : .resting(until: until, silentSince: from)
            return .skip
        }
    }

    /// これより skew が小さい当たりは 1 回で信じる。正しい当たりは ±0.0003 に収まっていた（10-17）。
    static let trustedSkew: Float = 0.0003

    /// 曲に当たった。出す曲が替わったなら true。聞かせ続ける（セッションは捨てない）。
    mutating func matched(id: String, skew: Float = 0) -> Bool {
        if id == lastID {
            pendingID = nil
            return false
        }
        if lastID == nil || pendingID == id || abs(skew) <= Self.trustedSkew {
            lastID = id
            pendingID = nil
            return true
        }
        pendingID = id
        return false
    }

    /// エラーが返った（呼ぶ側はセッションを捨てる）。
    /// 101 は流れの時刻が飛んだという意味なので、休まず聞き直す。
    mutating func failed(code: Int, now: TimeInterval) {
        if code == 101 {
            discontinuity()
        } else {
            phase = .resting(until: now + Self.restAfterError, silentSince: nil)
        }
    }

    /// 読み手の音が飛んだ（呼ぶ側はセッションを捨てる）。
    mutating func discontinuity() {
        phase = .waiting
    }

    /// 相手が居なくなった・繋ぎ直した。
    mutating func peerLost() {
        phase = .waiting
        lastID = nil
        pendingID = nil
    }

    mutating func reset() {
        phase = .waiting
        lastID = nil
        pendingID = nil
    }
}
