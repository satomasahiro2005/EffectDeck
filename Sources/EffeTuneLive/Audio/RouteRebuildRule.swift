//  RouteRebuildRule.swift
//  ハードウェアのレートや本数が組んだときと食い違ったとき、いつ組み直すか——
//  その**判断だけ**を持つ。
//
//  **AVAudioSession に触らない。** 入力は真偽値と時刻だけ（RouteRebuildRuleTests）。
//  AudioIO.tick がレート用と本数用に 1 つずつ持つ。
//
//  イヤホンを挿すとハードウェアのレートごと変わり、出力 IF の抜き差しで本数が変わる。
//  食い違ったまま流すと出力の速さがずれるか、音が別のスピーカーへ行くので組み直す。
//  ただし 1 回の食い違いでは組み直さない。engine.start() のあとにレートが落ち着く
//  ことがあり、そこで即座に組み直すと stop→start を毎秒繰り返して音が切れ続ける。

import Foundation

struct ETRouteRebuildRule {

    /// 食い違いが続いた目盛りの数がこれに達したら本物として扱う。
    /// tick は約 3.3Hz なので約 0.9 秒。
    static let ticksRequired = 3

    /// 直前の start() から最低これだけ空ける（秒）。
    static let settleSeconds: TimeInterval = 1

    /// いま続いている食い違いの目盛りの数。
    private(set) var mismatchTicks = 0

    /// 目盛り 1 つぶん見る。
    /// - Parameters:
    ///   - mismatch: いま食い違っているか（下の rateMismatch / channelMismatch）。
    ///   - now: `ProcessInfo.processInfo.systemUptime`。
    ///   - lastStart: 最後に start() を試みた時刻（同じ時計）。
    /// - Returns: いま組み直すなら true。true を返したら数え直す。
    ///
    /// 3 目盛りに達しても start() から 1 秒経っていなければ数え続け、
    /// 1 秒経った目盛りで組み直す（途中で食い違いが消えたら 0 に戻る）。
    mutating func observe(mismatch: Bool, now: TimeInterval, lastStart: TimeInterval) -> Bool {
        mismatchTicks = mismatch ? mismatchTicks + 1 : 0
        guard mismatchTicks >= Self.ticksRequired,
              now - lastStart >= Self.settleSeconds else { return false }
        mismatchTicks = 0
        return true
    }

    /// レートの食い違い。走っていて、ハードウェアが正のレートを名乗り、
    /// 組んだレートと 1Hz 以上違うときだけ。
    static func rateMismatch(running: Bool, built: Double?, hardware: Double) -> Bool {
        guard running, let built, hardware > 0 else { return false }
        return abs(hardware - built) >= 1
    }

    /// 本数の食い違い。`actual` は processingChannels を通した後の本数で比べる
    /// （モノラル経路でも 2 本で組むので、1ch の出力を食い違いと見ない）。
    static func channelMismatch(running: Bool, built: Int?, actual: Int) -> Bool {
        guard running, let built else { return false }
        return actual != built
    }
}

/// tick の 1 回で、どの見直しをするか。**AVAudioSession に触らない。**
///
/// 前面では今までどおり全部やる。背景では、再接続に要るもの（followPeer・ロック画面・
/// 音が続いたかの判定・診断の行）を毎回残し、AVAudioSession への問い合わせと
/// 誰にも見られない画面用の publish は、何かが落ち着いていないときだけにする。
/// 経路の変化は通知（routeChange・AVAudioEngineConfigurationChange）が撃つので、
/// ここは通知の取りこぼしを拾う保険と、時間で動く部品の見張りだけを受け持つ。
struct ETTickPlan: Equatable {
    var route: Bool
    var rebuild: Bool
    var display: Bool
    var diagnostic: Bool

    /// 診断の行を出す間隔（tick の数。約 6 秒）。docs/battery-log.md が読む。
    static let diagnosticEvery = 20

    /// 通知のあと、経路とレートを毎回見る秒数。レートが落ち着くまでの 1 秒に
    /// 組み直しの規則（3 目盛り + 1 秒）が収まる長さを取る。
    static let watchSeconds: TimeInterval = 5

    /// - Parameters:
    ///   - background: scenePhase が .background か（.inactive は前面扱い）。
    ///   - tick: 通算の目盛り。
    ///   - now: `ProcessInfo.processInfo.systemUptime`。
    ///   - watchUntil: ここまでは見張る（start() と経路・engine の通知で延ばす）。
    ///   - rebuildPending: レートか本数の食い違いを数えている途中か。
    ///     数え終わるまで毎回見ないと、規則の「3 目盛り」が 6 秒おきに間延びする。
    ///   - onVirtual: 走っていて、出力先が仮想デバイスのまま。引き剥がしの 3 秒再試行が
    ///     経路の問い合わせで動くので、毎回見る。
    static func make(background: Bool, tick: Int, now: TimeInterval, watchUntil: TimeInterval,
                     rebuildPending: Bool, onVirtual: Bool) -> ETTickPlan {
        let diagnostic = tick % diagnosticEvery == 0
        guard background else {
            return ETTickPlan(route: true, rebuild: true, display: true, diagnostic: diagnostic)
        }
        let watching = now < watchUntil
        return ETTickPlan(route: diagnostic || onVirtual || watching,
                          rebuild: diagnostic || rebuildPending || watching,
                          display: false,
                          diagnostic: diagnostic)
    }
}
