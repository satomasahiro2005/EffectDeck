//  AudioLifecycle.swift
//  AudioIO が「いつ鳴らし始めるか」を決めるための状態——中断中か、最後に start() を
//  試みたのはいつか——と、中断の通知を受けたときに何をするか。
//
//  **AVAudioSession に触らない。** 通知の生値を ETAudioLifecycle.Interruption に
//  直すところだけが AudioIO に残る（AudioLifecycleTests）。
//
//  ここが崩れたときの症状は 2 つあり、どちらも実機でしか見えなかった:
//    - 中断（着信など）から戻っても**永久に音が戻らない**。OS が engine を止めても
//      stop() を通らないので running が true のまま残り、followPeer の条件が
//      成り立たなくなる（通知を購読する前はこれだった）
//    - 中断中に setActive(true) を 3.3Hz で叩き続ける
//  判断そのものは ETAudioSessionRules.shouldStart（PeerFollowTests）にあり、
//  ここはその入力になる 2 つの値の出入りを持つ。

import Foundation

struct ETAudioLifecycle {

    /// 着信などで OS がセッションを落としている間 true。
    /// この間の setActive(true) は失敗するだけなので、followPeer は start() を呼ばない。
    private(set) var interrupted = false

    /// 最後に start() を試みた時刻（`ProcessInfo.processInfo.systemUptime`）。
    /// 0 は「すぐに試してよい」。組み直しの判断（ETRouteRebuildRule）もこれを見る。
    private(set) var lastStartAttempt: TimeInterval = 0

    /// `AVAudioSession.interruptionNotification` を読んだもの。
    enum Interruption: Equatable {
        case began
        /// `shouldResume` は `AVAudioSession.InterruptionOptions.shouldResume`。
        case ended(shouldResume: Bool)
        /// 知らない種類（`@unknown default`）。
        case unknown
    }

    /// 中断の通知を受けたとき AudioIO がすること。この順で行う。
    struct Response: Equatable {
        /// `stop(keepListening: true)` を呼ぶ。
        var stop = false
        /// status を "Interrupted" にする（stop() が "Stopped" にした後で）。
        var markInterrupted = false
        /// `start()` を呼ぶ。
        var start = false
    }

    /// 中断の通知を 1 つ受ける。
    ///
    /// - began: 中断に入る。走っていれば止める（止めないと engine が死んだまま
    ///   running だけ true で残る）。走っていなくても status は "Interrupted" にする。
    /// - ended: 中断を解く。`shouldResume` のときだけすぐ start() する。
    ///   付いていなければ何もしない。拡張が繋がったままなら followPeer が拾う
    ///   （1 秒の間隔は lastStartAttempt から数える）。
    /// - unknown: 中断を解くだけ。解かないと followPeer が永久に止まる。
    mutating func interruption(_ event: Interruption, running: Bool) -> Response {
        switch event {
        case .began:
            interrupted = true
            return Response(stop: running, markInterrupted: true, start: false)
        case .ended(let shouldResume):
            interrupted = false
            return Response(stop: false, markInterrupted: false, start: shouldResume)
        case .unknown:
            interrupted = false
            return Response()
        }
    }

    /// start() の入口で呼ぶ。**失敗しても**次まで 1 秒空けるため、成否より前に押す。
    mutating func startAttempted(at now: TimeInterval) {
        lastStartAttempt = now
    }

    /// engine が上がったとき。中断の印は残さない。
    mutating func started() {
        interrupted = false
    }

    /// メディアサービスが作り直されたとき。古いセッションごと中断も消えているので解き、
    /// 次の followPeer ですぐ試せるよう lastStartAttempt も 0 に戻す。
    mutating func mediaServicesReset() {
        interrupted = false
        lastStartAttempt = 0
    }

    /// followPeer が start() を呼ぶか。中身は ETAudioSessionRules.shouldStart。
    /// **相手（拡張）が繋がっているかは見ない**（issue #5）。
    func shouldStart(running: Bool, engineRunning: Bool, now: TimeInterval) -> Bool {
        ETAudioSessionRules.shouldStart(running: running, engineRunning: engineRunning,
                                        interrupted: interrupted, now: now,
                                        lastStartAttempt: lastStartAttempt)
    }
}
