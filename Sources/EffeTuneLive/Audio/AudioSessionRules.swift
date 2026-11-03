//  AudioSessionRules.swift
//  AudioIO が AVAudioSession の値から決めていることのうち、**値だけで決まるもの**。
//
//  AVAudioSession にも CoreAudio にも触らない。入力は数と文字列だけ。
//  だから実機なしで測れる（ProcessingChannelsTests / FeedbackLoopTests /
//  SampleRateRulesTests / PeerFollowTests）。
//  AudioIO はここを呼ぶだけにしてあり、同じ判断を 2 か所に持たない。
//
//  切り出した理由は RouteEscape.swift と同じ。判断が AVAudioSession に触る関数の中に
//  埋まっていると、多チャンネルの IF で音が別のスピーカーへ行く類の穴を
//  実機を繋ぐまで誰も見られない。

import Foundation

enum ETAudioSessionRules {

    // MARK: - 本数

    /// EffeTune DSP が扱える本数の上限（et_engine_prepare の maxChannels）。
    static let maxChannels = 16

    /// DSP と AVAudioEngine の間を何本で流すか。
    ///
    /// 入力は常に L/R なので、モノラル経路でも DSP までは 2 本を保ち、
    /// ミキサーにダウンミックスさせる。上は DSP の上限の 16。
    /// 出力が 4ch 以上なら同じ本数で処理する（Spatial Mapper 等で広げるため）。
    static func processingChannels(forOutputChannels actual: Int) -> Int {
        min(maxChannels, max(2, actual))
    }

    /// `setPreferredOutputNumberOfChannels` に出す本数。1〜16。
    /// 要求でしかないので、実際の本数は呼んだあとの outputNumberOfChannels を正とする。
    static func requestedOutputChannels(maximum: Int) -> Int {
        min(maxChannels, max(1, maximum))
    }

    // MARK: - レート

    /// リンクのレート。48kHz 固定（LocalLink.h、EffeTuneDriver.m の kSampleRate）。
    static let linkSampleRate: Double = 48000

    /// セッションが名乗ったレート。0 以下や NaN（まだ決まっていない）は 48kHz として組む。
    static func effectiveSampleRate(_ reported: Double) -> Double {
        reported > 0 ? reported : linkSampleRate
    }

    /// ハードウェアがリンクと同じ 48kHz で回っているか。
    ///
    /// setPreferredSampleRate は要求でしかなく、.mixWithOthers なので
    /// 先に鳴らしているアプリがレートを握っていれば通らない。通らないまま鳴らすと
    /// 48kHz のフレームを別のレートで出すことになり、音程と速さがずれる。
    static func matchesLinkRate(_ rate: Double) -> Bool {
        abs(rate - linkSampleRate) < 1
    }

    /// 組み上がったときの AudioIO.status。
    /// **字を変えるときは StatusReadings.swift の ETRunState.current を見ること。**
    /// そこは failurePrefixes の前方一致で失敗、"Interrupted" の完全一致で中断と読む。
    /// ここの字がどちらかに当たると、鳴っているのに Settings が失敗や中断を出す
    /// （SampleRateRulesTests.testRunningStatusReadsAsRunning）。
    /// レートの不一致は字ではなく sampleRate から ETIssue が出す。
    static func runningStatus(sampleRate: Double) -> String {
        matchesLinkRate(sampleRate)
            ? "Running"
            : String(format: "Running at %.0f Hz, input is 48000 Hz", sampleRate)
    }

    /// 1 ブロックのフレーム数（Settings の表示）。値が無い間は 0。
    /// Int に入らない値（NaN・無限・絶対値が 2^63 以上）も 0。Int(Double) はそこで落ちる。
    static func blockFrames(ioBufferDuration: Double, sampleRate: Double) -> Int {
        let frames = (ioBufferDuration * sampleRate).rounded()
        guard frames.isFinite, abs(frames) < Double(Int.max) else { return 0 }
        return Int(frames)
    }

    /// 図を音に合わせるときに遅らせる秒数。
    /// 出力の遅延 + 1 ブロック + リサンプラの遅延（入力レートのサンプル数）。
    static func displayDelay(sync: Bool, outputLatency: Double, ioBufferDuration: Double,
                             resamplerLatency: Int, sampleRate: Double) -> Double {
        guard sync else { return 0 }
        return outputLatency + ioBufferDuration + Double(resamplerLatency) / max(sampleRate, 1)
    }

    // MARK: - 帰還ループ

    /// ET_NAME_STEM（Sources/Shared/ETNames.h）の Swift の写し。
    ///
    /// ここに写してあるのは、このファイルを Foundation だけで建てるため。
    /// 食い違うと帰還ループに気づけなくなるので、3 か所で見張る:
    /// AudioIO の init の assert、FeedbackLoopTests（ETNames.h を読んで比べる）、
    /// Tools の検査。
    static let nameStem = "EffectDeck"

    /// その出力の口が自分の仮想デバイスか。
    ///
    /// **名前で見る。** ドライバは kAudioDeviceTransportTypeRemoteStreaming で名乗るので
    /// portType は .airPlay になるが、本物の AirPlay スピーカーも同じ型で出る。
    /// 型で判ると、鳴っている相手に「戻っている」と警告してしまう。
    /// **前方一致ではなく包含で、大文字小文字を区別しない。**
    /// ルートピッカーに出る名前（MediaOutputDevice.displayName）もドライバの名前も
    /// ET_NAME_STEM を含む（ETNames.h）。
    static func isOwnDevice(portName: String) -> Bool {
        portName.localizedCaseInsensitiveContains(nameStem)
    }

    // MARK: - 鳴らし始め

    /// start() に失敗したとき、次を試すまで空ける秒数。
    static let startRetryInterval: TimeInterval = 1

    /// followPeer が start() を呼ぶか。
    ///
    /// - running だけを見ると取りこぼす。中断で OS が engine を止めても stop() を
    ///   通らないので running は true のまま残る。engine の実状態と両方を見る。
    /// - 中断中の setActive(true) は失敗するだけなので呼ばない。
    /// - 失敗し続けるときに 3.3Hz で叩かないよう、前回から 1 秒は空ける。
    ///
    /// **相手（拡張）が繋がっているかは見ない。** 見ると繋がらなくなる
    /// （issue #5 / 2026-09-21。AudioIO.followPeer の説明）。だから引数にも無い。
    static func shouldStart(running: Bool, engineRunning: Bool, interrupted: Bool,
                            now: TimeInterval, lastStartAttempt: TimeInterval) -> Bool {
        if running && engineRunning { return false }
        if interrupted { return false }
        return now - lastStartAttempt >= startRetryInterval
    }
}
