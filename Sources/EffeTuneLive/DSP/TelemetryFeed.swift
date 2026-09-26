//  TelemetryFeed.swift
//  画面に出ていない図へはテレメトリの知らせを届けない。
//
//  2列のとき（iPadの広い窓）はカードを全部開くので、画面の外にも図が並ぶ。
//  Telemetry.sharedをそのまま観測すると、見えていない図まで枠が来るたびに
//  組み直される（60Hz × 図の数）。
//
//  `@ETTelemetryFeed private var telemetry`と書けば、中身は今までどおり
//  Telemetry.sharedで、`telemetry.frame(tap:type:)`もそのまま使える。
//  違うのは、環境のetGraphLiveが偽のあいだ知らせを止めることだけ。
//  真に戻ったら、次の回に1回だけ知らせて最新の枠を描かせる。
//
//  **最新の1枠だけを描く図に使う。**履歴を貯める図（Spectrogram、Stereo Meterなど）は
//  止めるとそのぶん抜けるので、今までどおりTelemetry.sharedを直に見る。
//
//  1列のときetGraphLiveは常に真（ETLiveRow）なので、@ObservedObjectと同じに動く。

import Combine
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

/// Telemetry.sharedの知らせを、生きているあいだだけ中継する。
final class ETTelemetryRelay: ObservableObject {
    private var live = true
    private var started = false
    private var link: AnyCancellable?

    @MainActor
    func setLive(_ now: Bool) {
        if started && now == live { return }
        let resumed = started && now && !live
        started = true
        live = now
        guard now else {
            link = nil
            return
        }
        if link == nil {
            link = Telemetry.shared.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
        // 止めていたあいだの枠を1回だけ描かせる。update()の中なので次の回へ回す。
        if resumed {
            Task { @MainActor [weak self] in self?.objectWillChange.send() }
        }
    }
}
