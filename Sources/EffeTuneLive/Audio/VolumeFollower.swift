//  VolumeFollower.swift
//  出力の音量（%）を読み続けて、音量に追従するカードの鳴らす値を引き直させる。
//
//  読むのは AVAudioSession.outputVolume だけ。実機で、本体のこの値が出力先ごとの物理の音量
//  （AirPods・有線・本体スピーカー）を前でも背景でも追うことを確かめてある。
//  値は 0.05 刻みで来るが、連続の値として扱う。
//
//  **読むだけ。**セッションの設定・有効化・経路・音量には触らない。音のスレッドからは呼ばない。
//  触るのは主スレッドだけ。KVO は主以外から来ることがあるので、値だけ取って主へ渡す。
//
//  出力先との組み合わせは、いちばん簡単な規則にしてある。変わるたびと、出力先が落ち着いたときに
//  いまの値を読む（AudioIO.followOutputDevice）。Bluetooth は繋がってから落ち着くまで十数秒かかる。

import AVFoundation
import UIKit

@MainActor
final class ETVolumeFollower: ObservableObject {

    static let shared = ETVolumeFollower()

    /// 0〜100。一度も読めていなければ nil（そのときカードは一番上のキーフレームを鳴らす）。
    @Published private(set) var position: Double?

    private var kvo: NSKeyValueObservation?
    private var observers: [NSObjectProtocol] = []
    private var started = false

    /// **何にも触らない。**AudioIO.init の途中で pushParams から最初に引かれるので、
    /// ここで AudioIO.shared や EffeTuneDSP.shared を引くと作りかけを再入する。
    private init() {}

    /// 読み始める。何度呼んでも 1 回だけ。
    func start() {
        guard !started else { return }
        started = true

        // .initial で今の値を取る。クロージャは主以外で呼ばれうるので、値だけ持って主へ渡す。
        kvo = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.initial, .new]) { @Sendable _, change in
            let v = change.newValue
            Task { @MainActor in ETVolumeFollower.shared.take(v) }
        }
        // 背景のあいだに変わった分を、戻ったときに読み直す。
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { _ in
                Task { @MainActor in ETVolumeFollower.shared.readNow() }
            })
    }

    /// 出力先が落ち着いた。そのときの値を読み直す。
    func deviceSettled() {
        readNow()
    }

    private func readNow() {
        take(AVAudioSession.sharedInstance().outputVolume)
    }

    private func take(_ v: Float?) {
        guard let v, v.isFinite else { return }
        let p = ETAutomation.Source.outputVolume.position(fromVolume: v)
        guard p != position else { return }
        position = p
        EffeTuneDSP.shared.applyAutomation()
    }
}
