//  TelemetryFeed.swift
//  画面に出ていない図へはテレメトリの知らせを届けない。
//
//  2列のとき（iPadの広い窓）はカードを全部開くので、画面の外にも図が並ぶ。
//  Telemetry.sharedをそのまま観測すると、見えていない図まで枠が来るたびに
//  組み直される（60Hz × 図の数）。
//
//  `@ETTelemetryFeed private var telemetry`と書けば、中身は今までどおり
//  Telemetry.sharedで、`telemetry.frame(tap:type:)`もそのまま使える。
//  違うのは、環境のetGraphLiveが偽のあいだ知らせを1秒に1回まで間引くことだけ。
//  真に戻ったら、次の回に1回だけ知らせて最新の枠を描かせる。
//
//  **止め切らない。**GateやCompressorのGRの棒のように、枠が来て初めて出る部品がある。
//  止め切ると、一度も画面に入っていないカードは枠を見ないまま短く並び、別の理由で
//  描き直されたときに遅れて伸びる。上のカードが伸びると読んでいたカードが下へずれる
//  （ETReadingKeeperが止まっている間のずれは直すが、送っている最中のずれは直せない）。
//  1秒に1回なら、音が来てすぐに全部のカードが本来の高さになり、描く手間はほぼ増えない。
//
//  **最新の1枠だけを描く図に使う。**履歴を貯める図（Spectrogram、Stereo Meterなど）は
//  止めるとそのぶん抜けるので、今までどおりTelemetry.sharedを直に見る。
//
//  1列のときetGraphLiveは常に真（ETLiveRow）なので、@ObservedObjectと同じに動く。

import Combine
import QuartzCore
import SwiftUI

@propertyWrapper
struct ETTelemetryFeed: DynamicProperty {
    @Environment(\.etGraphLive) private var live
    @StateObject private var relay = ETTelemetryRelay()

    var wrappedValue: Telemetry {
        MainActor.assumeIsolated { Telemetry.shared }
    }

    /// 描く前に毎回呼ばれる。**ここでは知らせを出さない。**
    /// 描いている最中に知らせると、同じ回の中で組み直しを頼むことになる。
    func update() {
        MainActor.assumeIsolated { relay.setLive(live) }
    }
}

/// Telemetry.sharedの知らせを中継する。生きているあいだは全部、止めているあいだは1秒に1回。
final class ETTelemetryRelay: ObservableObject {
    /// 止めているあいだに知らせる間隔（秒）。
    private static let quietInterval: CFTimeInterval = 1

    private var live = true
    private var started = false
    private var link: AnyCancellable?
    /// 止めているあいだに最後に知らせた時刻。
    private var lastQuiet: CFTimeInterval = 0

    @MainActor
    func setLive(_ now: Bool) {
        if started && now == live { return }
        let resumed = started && now && !live
        started = true
        live = now
        if link == nil {
            link = Telemetry.shared.objectWillChange.sink { [weak self] _ in
                self?.relay()
            }
        }
        // 止めていたあいだの枠を1回だけ描かせる。update()の中なので次の回へ回す。
        if resumed {
            Task { @MainActor [weak self] in self?.objectWillChange.send() }
        }
    }

    /// Telemetry.sharedの知らせが来た。Telemetryは画面の描き直しに合わせてmainで汲む（ETDisplayPump）。
    private func relay() {
        guard !live else {
            objectWillChange.send()
            return
        }
        let now = CACurrentMediaTime()
        guard now - lastQuiet >= Self.quietInterval else { return }
        lastQuiet = now
        objectWillChange.send()
    }
}
