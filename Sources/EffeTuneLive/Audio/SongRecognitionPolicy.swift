//  SongRecognitionPolicy.swift
//  曲の聞き取り（SongRecognizer.swift）の間合いだけを持つ。ShazamKit にも時計にも触れない。
//
//  入力は「いま」の時刻と、聞かせようとしている音のピークだけ。返すのは、
//  セッションを作って聞かせるか・そのまま聞かせるか・捨てるか・何もしないか。
//  切り出した理由は、間合い（どれだけ聞かせて、当たったらどれだけ休むか）を実機で試すと
//  1 回に 20 秒かかるため。Foundation だけなので Linux でも測れる（Tests/Unit/SongRecognitionPolicyTests.swift）。
//
//  当たったら少し休んで聞き直す。DJ ミックスのように無音を挟まず曲が替わるため
//  （本人「最近はdjmixとか多い」）。外れても出ている曲は消さない（つなぎの途中で外れるため）。
//  Visualizer を見ているときはたぶん充電中なので、聞き直す間合いは短くてよい（本人）。

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
    /// 1 回の聞き取りに聞かせる上限。
    static let attemptLimit: TimeInterval = 20
    /// 当たったあとの休み。休みが明けたら、溜めておいた音（SongRecognizer の history）から聞き直す。
    static let restAfterMatch: TimeInterval = 10
    /// 当たらなかったあとの休み。
    static let restAfterMiss: TimeInterval = 5
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
            if now - since >= Self.attemptLimit {
                phase = .resting(until: now + Self.restAfterMiss, silentSince: nil)
                return .drop(clear: false)
            }
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
            // 曲間の無音で休みを切り上げ、次の曲をすぐ拾えるようにする。
            phase = now - from >= Self.silenceToReset
                ? .waiting
                : .resting(until: until, silentSince: from)
            return .skip
        }
    }

    /// 曲に当たった。曲が変わったなら true（呼ぶ側はセッションを捨てる）。
    mutating func matched(id: String, now: TimeInterval) -> Bool {
        phase = .resting(until: now + Self.restAfterMatch, silentSince: nil)
        let changed = id != lastID
        lastID = id
        return changed
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
    }

    mutating func reset() {
        phase = .waiting
        lastID = nil
    }
}
