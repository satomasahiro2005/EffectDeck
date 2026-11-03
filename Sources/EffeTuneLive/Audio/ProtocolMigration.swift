//  ProtocolMigration.swift
//  拡張のプロトコル名（Sources/Extension/Info.plist の UTTypeDescription）を
//  「48 kHz, 32-bit float」から「EffectDeck Audio」へ替えた版への更新（#12）。
//  **その判断だけ**を持つ。Foundation だけ（ProtocolMigrationTests）。
//
//  名前を替えると、上から入れた人は 1 回再起動するまで繋がらない（#2 と同じ。
//  iOS 27.2 beta 3 では新しい名前はすぐ出るが、経路は使えないまま）。
//  新しく入れた人には何も起きないので、案内は前の版から上げた人にだけ出す。
//
//  - 前の版から上げたか: 印（checkedKey）がまだ無く、鎖（PipelineStore.lastKey）が在る。
//    鎖は前の版でも起動すれば必ず書いている（restore → publish → persist。2026-09-15 から）。
//    **iCloud から戻す前に見ること。**戻すと新しく入れた端末にも鎖が在る形になる
//    （EffeTuneLiveApp.init で CloudMirror.seedIfEmpty より先に呼ぶ）。
//  - 案内を消す時機: 音が途切れずに sustainSeconds 続いたとき（ETSustainedAudio）。

import Foundation

enum ETProtocolMigration {

    /// この版を 1 度でも起動したら立てる。立っていれば以後は何も見ない。
    static let checkedKey = "protocolMigration.audioName.checked"
    /// 再起動の案内を出す間だけ立つ。
    static let pendingKey = "protocolMigration.audioName.pending"
    /// 前の版から上げた人にだけ在る鍵（PipelineStore.lastKey と同じ字）。
    static let legacyKey = "pipeline.last"

    /// 起動のたびに 1 回呼ぶ。案内を出す間なら true。
    @discardableResult
    static func noteLaunch(storage: ETKeyValueStorage) -> Bool {
        if storage.object(forKey: checkedKey) == nil {
            storage.set(true, forKey: checkedKey)
            if storage.object(forKey: legacyKey) != nil {
                storage.set(true, forKey: pendingKey)
            }
        }
        return isPending(storage: storage)
    }

    static func isPending(storage: ETKeyValueStorage) -> Bool {
        storage.object(forKey: pendingKey) as? Bool ?? false
    }

    static func clear(storage: ETKeyValueStorage) {
        storage.removeObject(forKey: pendingKey)
    }
}

/// 拡張から音が途切れずに来ているかを、目盛りごとに見る。
///
/// **hasPeer だけでは消さない。**繋がり損ねた接続も、落とされる前の約 1.5 秒は
/// 音を受け取る（AudioIO.followPeer の注記。2026-09-16 の recv の増分が 1.536 秒と 1.515 秒）。
/// そこで消すと、まだ繋がらないのに案内だけが消える。
/// 繋がっていて、受け取ったフレーム数が増え続けている間を数え、sustainSeconds に
/// 達したら本当に繋がったとみなす。10 秒は 1.5 秒の失敗より十分長く、繋がった人が
/// 1 曲鳴らしていれば必ず届く長さ。
struct ETSustainedAudio {

    static let sustainSeconds: TimeInterval = 10

    /// 増えない間をこれまでは許す。tick は約 0.3 秒おきで、48 kHz なら毎回増えるが、
    /// 受け取りの塊が目盛りをまたぐことがあるので 1 回ぶん見逃す。
    static let gapSeconds: TimeInterval = 1

    private var since: TimeInterval?
    private var lastGrowth: TimeInterval = 0
    private var lastReceived: UInt64 = 0

    /// 目盛り 1 つぶん見る。続いた長さが sustainSeconds に達したら true。
    /// - Parameters:
    ///   - peer: 拡張が繋がっているか（ETLinkReceiver.hasPeer。撮影用の音は入れない）。
    ///   - received: 受け取ったフレームの累計（ETLinkReceiver.receivedFrames）。
    ///   - now: `ProcessInfo.processInfo.systemUptime`。
    mutating func observe(peer: Bool, received: UInt64, now: TimeInterval) -> Bool {
        defer { lastReceived = received }
        guard peer else {
            since = nil
            return false
        }
        if received > lastReceived {
            if since == nil || now - lastGrowth > Self.gapSeconds { since = now }
            lastGrowth = now
        } else if since != nil, now - lastGrowth > Self.gapSeconds {
            since = nil
        }
        guard let since else { return false }
        return now - since >= Self.sustainSeconds
    }
}
