//  EffeTune Live — Media Device Extension (iOS 27+)
//
//  ルートピッカーに EffeTune を1台出し、選ばれたらシステム音声のサンプルを受け取る。
//  API は Xcode 27 の MediaDevice.swiftinterface から起こしたもので、推測は含まない。
//
//  CoreAudio/AudioServerPlugIn.h に書かれている制約:
//    - AudioServerPlugIn は「単一の出力デバイス」しか提示できない
//    - transport type は kAudioDeviceTransportTypeRemoteScreen か RemoteStreaming
//      違うと登録が kAudioHardwareIllegalOperationError で失敗する
//    - デバイスの UID は MediaOutputDevice.id と一致していること
//
//  未確認: MediaOutputDevice.init? は requiredNetworkEndpoints が必須引数で
//  デフォルト値が無く、init 自体が failable。ネットワーク上の受信機を前提にした
//  設計なので、ローカル完結のデバイスで何を渡せば nil にならないかは実機で詰める。

import Foundation
import MediaDevice
import Network
import UniformTypeIdentifiers
import os

// 3 箇所で同じ文字列を使う:
//   1. entitlement com.apple.developer.media-device-extension の値
//   2. Info.plist の UTExportedTypeDeclarations / UTTypeIdentifier
//   3. protocolType
let kProtocolID = "media-device-protocol.ai.nemut.effetune"

let log = Logger(subsystem: "ai.nemut.effetune", category: "extension")

@main
@available(iOS 27.0, *)
final class EffeTuneLiveExtension: MediaDeviceExtension, RealtimeSampleHandling {

    // MARK: - MediaDeviceExtension

    var protocolType: UTType { UTType(exportedAs: kProtocolID) }

    var supportsSimultaneousSessions: Bool { false }

    lazy var routingManager: MediaDeviceRoutingManager = .routingManager(for: self)

    private var reportTimer: Timer?

    /// デバイスの id。AudioServerPlugIn の kAudioDevicePropertyDeviceUID と一致させる。
    ///
    /// **固定値でなければならない。** 一度プロセスごとに作り直してみたが、
    /// 探索と有効化が別プロセスで走ることがあるため、一覧に出したデバイスと
    /// ドライバが名乗るデバイスが食い違い、ルートピッカーに 2 つ出て
    /// どちらも繋がらなくなった。
    ///
    /// 引き換えに、古い登録が audiomxd に残ったままだと同じ UID の死んだ port
    /// （conn:1 quies:1 rout:0）に衝突する。そうなると端末の再起動でしか消えない。
    /// AudioServerPlugInRegisterMediaDeviceExtension に対になる解除が無いのが元。
    static let deviceUUID = UUID(uuidString: "6E656D75-7400-4E00-A000-000000000001")!

    /// 本体（EffeTuneLive）の ETLinkReceiver が bind している口。
    /// Sources/Shared/LocalLink.h:23-24 の ET_LINK_PORT / ET_LINK_HOST と同じもの。
    /// 数字を写さずマクロを引くのは、片方だけ変えられるのを防ぐため。
    /// ET_LINK_PORT は bridging header 経由（Extension-Bridging-Header.h:2）。
    /// もし `cannot find 'ET_LINK_PORT' in scope` で止まったら 47101 を直に書く。
    /// ビルドしていないのでここだけは確かめていない。
    static let linkEndpoint: NWEndpoint = .hostPort(
        host: .ipv4(.loopback),
        port: NWEndpoint.Port(rawValue: UInt16(ET_LINK_PORT)) ?? 47101
    )

    /// **requiredNetworkEndpoints には実在して到達できる口を渡す。**
    ///
    /// ここが 127.0.0.1:**0** になっていた。選ぶと 1.5 秒でスピーカーへ戻る症状で、
    /// こちら側に見つかった欠陥はこれだけ。
    ///
    /// 前は LocalEndpoint.swift（削除済み）が拡張の中で NWListener を立てて
    /// 実ポートを渡す設計だが、拡張は待ち受けを禁じられている:
    ///   et.log:3419 kernel(Sandbox) Sandbox: EffeTuneLiveExtension(564)
    ///               deny(1) network-bind local:*:0
    ///   et.log:3422 nw_listener_set_state_on_queue [L1] waiting -> failed,
    ///               error: Operation not permitted
    /// 拡張プロセス 13 本すべてで同じ（`grep -c 'deny(1) network-bind'` = 13 /
    /// `grep -c 'listener ready port='` = 0 / `grep -c 'ポートが確定しなかった'` = 13）。
    /// port が nil のまま、あちらの fallback
    ///   `.hostPort(host: .ipv4(.loopback), port: .any)`
    /// に落ちる。`NWEndpoint.Port.any` は 0 番。
    ///
    /// 名乗った口はシステムが持ち回って方針の許可に使う。MediaExperience
    /// (iOS 27.0 24A435) の実体:
    ///   -[MXSystemCastingExtensionInstance activateDeviceWithDescription:withNWEndpoints:
    ///     isMirroring:completionHandler:]  ← et.log:908 ほか 13 本
    ///   -[MDENetworkPolicyEngine promoteAssertion:toAccessNWEndpointsOverLAN:]
    ///     (0x1ae93b578)
    ///
    /// 127.0.0.1:47101 なら実在していて、拡張から実際に繋がっている:
    ///   et.log:9681 EffeTuneLiveExtension[564] ET connect 成功 port=47101（7 回）
    ///   et.log:65193 EffeTune Live[601] ET receiver 待ち受け開始 port=47101
    ///   Sources/Shared/LocalLink.m:285-300（本体側の bind/listen）
    /// 音はこの口を通らない（AudioServerPlugIn 経由で来る）。名乗るためだけに使う。
    ///
    /// **確かめていないこと**: 0 番が revert の原因だと書いてある行は無い。確定は
    /// (a) 13/13 で 0 番を名乗っていたこと (b) 失敗理由が et.log:1168
    /// AVOutputContextDeviceConnectionFailureReasonMDERouteRevertedToLocal であること。
    /// 切る判断そのものは audiomxd の中で、述語は Notice レベルに出ない。
    ///
    /// 待ち受けを立てなくなるので、あちらにあった
    /// 「ポートが確定するまで 1 秒待つ」sleep も走らない。listener が必ず失敗するので
    /// 毎回まるまる 1 秒 MainActor を止めていた（startDeviceDiscovery は
    /// MediaDevice.swiftinterface 上 @MainActor）。実測で activateDeviceWithDescription の
    /// XPC 到着から activateDevice の実行まで pid 573 で 379ms、pid 583 で 632ms。
    ///
    /// 他の引数は動かしていない。切る側が読むのは kFigEndpointProperty_Type だけで
    /// （_FigRoutingManagerIsEndpointOfType 0x1ae833c14 → 1ae833cbc CFEqual）、
    /// その type は _FigCustomEndpointCreateEndpointWithExtensionDevice 1ae922b6c-b74 が
    /// GOT 0x1e00ea930（kFigEndpointType_ThirdParty）から取って固定で書き込む。
    /// canGroupWithCurrentlyActivatedDevices も deviceType も volumeControl も
    /// この判定には入らない。同時に動かすと次の et.log でどれが効いたか読めなくなる。
    ///
    /// **直ったかどうかを見る行**（新しい et.log に対して、上から順に）:
    ///   1. `grep 'deny(1) network-bind' et.log` が 0 件。前は 13 件。
    ///      `grep 'ポートが確定しなかった'` も 0 件（前は 13 件）。
    ///      ここが残っていれば、まだどこかで待ち受けを立てている。
    ///   2. `grep 'endpoints=' et.log` に 127.0.0.1:47101 が出る。
    ///      前は 13 回とも `endpoints=<private>` で中身が読めなかった（et.log:3883 ほか）。
    ///      0 を名乗っていた事実はコードの経路からしか言えていなかったので、
    ///      修正前の形を確かめたければ先にこの 1 行だけ入れて 1 往復録ること。
    ///   3. `grep 'because a different endpoint got picked' et.log` が 0 件。前は 13 件。
    ///      `grep 'MDERouteRevertedToLocal'` も 0 件（前は 52 件）。
    ///   4. `customEndpoint_finishActivation` の 1.5 秒後に何も起きない。
    ///      前は 12 サイクル全部で 1.484〜1.553 秒後に切られていた。
    ///   5. activateDeviceWithDescription の XPC 到着から `activateDevice features=` まで
    ///      数十 ms。前は 379ms(pid 573) / 632ms(pid 583)。
    ///
    /// 3 が消えず 1 と 2 だけ直るなら、0 番は原因ではなかったということ。そのときは
    /// 所見の「次の一手」どおり Debug レベルで録り直す:
    ///   log stream --device --level debug --predicate 'subsystem == "com.apple.coremedia"
    ///     AND (eventMessage CONTAINS "FigRoutingManager" OR eventMessage CONTAINS "customEndpoint")'
    private lazy var localDevice: MediaOutputDevice? = {
        let eps: [NWEndpoint] = [Self.linkEndpoint]
        // privacy: .public にしないと <private> で潰れる。直ったかどうかはこの行で見る。
        log.notice("endpoints=\(eps.map { $0.debugDescription }.joined(separator: ","), privacy: .public)")
        return MediaOutputDevice(
            id: Self.deviceUUID,
            displayName: "EffeTune",
            capabilities: [.realtimeAudioStreaming],
            canGroupWithCurrentlyActivatedDevices: false,
            deviceType: .hifiSpeaker,
            // **音量はこちらで持たない。**
            // .relative だと Now Playing（ロック画面やコントロールセンター）に
            // + と − のボタンが出る。押されると setVolume が来て、
            // こちらが掛けた減衰と、鎖に入れた Volume と、端末の音量とで
            // 三重に掛かる。選択肢は none / absolute / relative の 3 つで、
            // none にするとボタンごと出なくなる（MediaDevice.swiftinterface:125-128）。
            // 音量は鎖の Volume か端末の音量ボタンで変える。
            // canMute も同じ理由で外す。鎖の頭の電源を切れば素通しになる。
            volumeControl: .none,
            canMute: false,
            requiredNetworkEndpoints: eps,
            txtRecords: [],
            supportsSimultaneousSessions: false
        )
    }()

    required init() {
        log.notice("EffeTuneLiveExtension init")
    }

    func startDeviceDiscovery() {
        guard let dev = localDevice else {
            log.error("MediaOutputDevice の init が nil を返した。endpoints の渡し方を変える")
            routingManager.discoveryFailed(MediaDeviceError(.discoveryFailed))
            return
        }
        // ここも privacy: .public。今までの et.log は 13 回とも <private> で潰れていて
        // （et.log:3884 / 8408 / 15627 …）、何を名乗ったのかログから読めなかった。
        log.notice("startDeviceDiscovery -> foundDevice \(dev.description, privacy: .public)")
        routingManager.foundDevice(dev)
    }

    func stopDeviceDiscovery() {
        if let dev = localDevice { routingManager.lostDevice(dev) }
        log.notice("stopDeviceDiscovery")
    }

    func activateDevice(_ device: MediaOutputDevice,
                        session: MediaOutputSession,
                        for deviceFeatures: MediaOutputDevice.Capabilities) {
        log.notice("activateDevice features=\(deviceFeatures.description)")
        // ヘッダの注意: activate 直後に速やかにオーディオデバイスが現れないと
        // システムが deactivate して "Unable to Connect" になる。
        // だから startRealtimeSampleDelivery を待たずにここで publish する。
        let st = EffeTuneDriver.shared.publish(withDeviceUID: Self.deviceUUID.uuidString)
        if st != noErr {
            log.error("AudioServerPlugIn の登録に失敗 OSStatus=\(st)")
            routingManager.failedToActivateDevice(device, session: session,
                                                  error: MediaDeviceError(.connectionFailed))
            return
        }
        routingManager.activatedDevice(device, session: session)
    }

    func connectUsingPairingCode(_ pairingCode: String?,
                                 to device: MediaOutputDevice,
                                 session: MediaOutputSession) {
        routingManager.activatedDevice(device, session: session)
    }

    /// **2 回目以降が繋がらない原因はここではない。** 先に EffeTuneDriver.m の
    /// publishWithDeviceUID: にある長いコメントを読むこと。要点だけ書くと、
    /// 失敗は audiomxd の
    ///   customEndpoint_Activate: VA port type 'rstm' already connected;
    ///     skipping port-publication wait
    /// で決まっていて、この行が出るのは activateDevice が届く 4ms 前
    /// （dev.log 2026-09-16 02:40:01.489240 / 02:40:01.493678）。
    /// つまり Swift 側で何を呼ぼうと結果は動かない。効くのは
    /// 「前回の publish が残した rstm ポートを次の activate までに消す」ことだけで、
    /// それは unpublish の中でやっている。
    ///
    /// 下の foundDevice はドキュメントの言う口ではない（updateDevices が正しい）。
    /// stopDeviceDiscovery の lostDevice も同じく doc に無い。どちらも直す価値はあるが、
    /// gate の分岐とは別の話なので、unpublish の結果を 1 往復見てから触ること。
    /// 同時に変えると、どちらが効いたのか分からなくなる。
    func deactivateDevice(_ device: MediaOutputDevice, session: MediaOutputSession) {
        log.notice("deactivateDevice")
        reportTimer?.invalidate()
        reportTimer = nil
        EffeTuneDriver.shared.stopCapture()
        ETLinkSender.shared.stop()
        EffeTuneDriver.shared.unpublish()

        // 離れたあと、ルートピッカーに戻ってこないことがあるので名乗り直す。
        // 二重に出る原因かと疑って一度外したが、外しても直らなかったので戻した。
        if let dev = localDevice {
            log.notice("deactivate 後に再度 foundDevice")
            routingManager.foundDevice(dev)
        }
    }

    // MARK: - 音量（持たない）
    //
    // volumeControl: .none / canMute: false にしてあるので、これらは呼ばれない。
    // それでも protocol の要件なので残す。**中身は空にしてある。**
    // 万一システムが呼んでも、ドライバの減衰を動かさない。
    // 動かすと、鎖の Volume と端末の音量と合わせて三重に掛かる。

    func setVolume(_ volume: Float, for device: MediaOutputDevice) {
        log.notice("setVolume が来た（volumeControl は .none のはず）v=\(volume)")
    }

    func volume(for device: MediaOutputDevice) -> Float { 1.0 }

    func changeVolume(by increments: Int, for device: MediaOutputDevice) {
        log.notice("changeVolume が来た（volumeControl は .none のはず）d=\(increments)")
    }

    func muteDevice(_ device: MediaOutputDevice) {
        log.notice("muteDevice が来た（canMute は false のはず）")
    }

    func isDeviceMuted(_ device: MediaOutputDevice) -> Bool { false }

    // MARK: - URL 再生（使わない）

    func startSession(_ session: MediaOutputSession, identifier: String?, url: URL) {
        log.notice("startSession url=\(url.absoluteString) — realtime のみ対応")
        routingManager.sessionFailed(session, error: MediaDeviceError(.sessionFailed))
    }

    func stopSession(_ session: MediaOutputSession) {
        log.notice("stopSession")
    }

    func sendData(_ data: Data, toApplication applicationIdentifier: String,
                  session: MediaOutputSession) {
    }

    // MARK: - RealtimeSampleHandling

    func startRealtimeSampleDelivery(session: MediaOutputSession) {
        log.notice("startRealtimeSampleDelivery session=\(session.id)")

        // 受け取ったサンプルは TCP で本体（EffeTuneLive）へ送る。鳴らすのは本体側。
        // 拡張は「作る・待つ」が全部禁じられている（ファイル/共有メモリ/bind すべて deny）ので、
        // App Group の共有リングもドライバ内のループ（出力→入力）も使えない。
        // 外へ繋ぐのは許されているので、そちら 1 本にした。
        ETLinkSender.shared.start()
        EffeTuneDriver.shared.startCapture { planes, channels, frames, _ in
            ETLinkSender.shared.pushInterleaved(planes[0], frames: frames, channels: channels)
        }

        reportTimer?.invalidate()
        reportTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            _ = self
            log.notice("受信 frames=\(EffeTuneDriver.shared.framesDelivered) 接続=\(ETLinkSender.shared.connected) 送信=\(ETLinkSender.shared.sentFrames)")
        }
    }

    func stopRealtimeSampleDelivery(session: MediaOutputSession) {
        log.notice("stopRealtimeSampleDelivery")
        reportTimer?.invalidate()
        reportTimer = nil
        EffeTuneDriver.shared.stopCapture()
    }
}
