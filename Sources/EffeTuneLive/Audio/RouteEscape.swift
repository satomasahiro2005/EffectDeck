//  RouteEscape.swift
//  出力先が仮想デバイス（EffeTune 自身）を指しているとき、
//  このセッションだけ内蔵スピーカーへ引き剥がす——その**判断だけ**を持つ。
//
//  **AVAudioSession に触らない。** 入力は真偽値 2 つと時刻だけ。
//  だからシミュレータでも実機なしでも測れる（Tests/Unit/RouteEscapeTests.swift）。
//  切り出した理由は、この判断が実機でしか測れない場所に埋まっていたせいで
//  下の「掛け直さない」穴を 25 秒のログを取るまで見つけられなかったから。

import Foundation

struct ETRouteEscape {

    enum Action: Equatable {
        /// overrideOutputAudioPort(.speaker)
        case speaker
        /// overrideOutputAudioPort(.none)
        case clear
    }

    /// 諦めるまでの回数。
    ///
    /// **実機で測ったら、掛けてもルートが動かなかった。**
    ///   escape 仮想デバイスを指している -> speaker route=EffeTune   ×8（3 秒ごと）
    ///   tick out=EffeTune ovr=true …                                 一度も変わらず
    /// overrideOutputAudioPort は例外を投げずに成功を返すのに、
    /// 仮想デバイス（MediaDevice の出力）からは剥がせない。
    /// 効かない操作を打ち続けるとルート変更の連打になり、
    /// MediaDevice のセッションの方を壊す。数回試して駄目なら止める。
    /// 輪を切るのは呼び出し側の消音（AudioIO の render）が受け持つ。
    static let maxAttempts = 3

    /// 掛け直すまで空ける秒数。
    ///
    /// overrideOutputAudioPort は即時に反映されない。呼んだ直後に currentRoute を
    /// 見てもまだ仮想デバイスのままで、実際に切り替わるのは 2 秒ほど後
    /// （実機のログで確認）。その間「まだ仮想デバイスだ」と見て呼び直すと
    /// 2 秒で 8 回のルート変更を打ち、MediaDevice のセッションが壊れる。
    /// 反映の 2 秒より長く取る。
    static let retry: TimeInterval = 3

    /// いま引き剥がしを掛けているか。
    private(set) var overriding = false

    /// 最後に掛けた時刻（systemUptime）。間隔を計るためだけに持つ。
    private(set) var lastApply: TimeInterval = 0

    /// 仮想デバイスを指したまま掛けた回数。maxAttempts で打ち止め。
    private(set) var attempts = 0

    /// 掛けても外れなかったので諦めた。呼び出し側はここで消音へ倒す。
    var gaveUp: Bool { attempts >= Self.maxAttempts }

    /// - Parameters:
    ///   - onVirtual: 出力先に "EffeTune" を含む名前の口が居るか。
    ///   - onSpeaker: 出力先に内蔵スピーカーが居るか。
    ///   - now: `ProcessInfo.processInfo.systemUptime`。
    /// - Returns: 打つべき手。何もしないときは nil。
    mutating func decide(onVirtual: Bool, onSpeaker: Bool, now: TimeInterval) -> Action? {
        if onVirtual {
            // **掛かっていても掛け直す。**
            // ここは以前 `onVirtual && !overriding` と `!onVirtual && overriding`
            // の 2 本しか無く、`onVirtual && overriding` に何も書いていなかった。
            // 一度引き剥がしたあと相手がもう一度 EffeTune を選ぶとルートが戻り、
            // どちらの条件にも当たらないまま二度と掛け直さない。overriding を
            // 落とすのは stop() だけなので、走ったまま永久に戻らない。実機:
            //   14:42:59〜14:43:23 tick out=EffeTune ovr=true（25 秒で escape 0 本）
            // 自分の音が仮想デバイスへ出続け、それを拡張が拾って戻すので
            // レベルだけ上がり、スピーカーには何も出ない。
            guard !overriding || now - lastApply >= Self.retry else { return nil }
            // **打ち止め。** 効かないものを打ち続けない。
            guard attempts < Self.maxAttempts else { return nil }
            overriding = true
            lastApply = now
            attempts += 1
            return .speaker
        }

        guard overriding else { return nil }
        // 本当に外れたのかを確かめてから戻す。
        // Speaker になっているのはこちらが引き剥がした結果なので、
        // それを「外れた」と誤認して戻すと往復する。
        guard !onSpeaker else { return nil }
        overriding = false
        lastApply = now
        attempts = 0
        return .clear
    }

    /// セッションを開き直したとき。呼び出し側が override を .none に戻すのと対で使う。
    mutating func reset() {
        overriding = false
        lastApply = 0
        attempts = 0
    }
}
