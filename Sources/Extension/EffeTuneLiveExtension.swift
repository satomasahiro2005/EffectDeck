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

    private lazy var localDevice: MediaOutputDevice? = {
        // requiredNetworkEndpoints は必須引数で init も failable。
        // この API はネットワーク上の受信機を想定しているので、
        // ダミーではなく実際に listen しているソケットのエンドポイントを渡す。
        let eps = LocalEndpoint.shared.endpoints()
        log.notice("endpoints=\(eps.map { $0.debugDescription }.joined(separator: ","))")
        return MediaOutputDevice(
            id: Self.deviceUUID,
            displayName: "EffeTune",
            capabilities: [.realtimeAudioStreaming],
            canGroupWithCurrentlyActivatedDevices: false,
            deviceType: .hifiSpeaker,
            volumeControl: .relative,
            canMute: true,
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
        log.notice("startDeviceDiscovery -> foundDevice \(dev.description)")
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

    // MARK: - 音量

    func setVolume(_ volume: Float, for device: MediaOutputDevice) {
        EffeTuneDriver.shared.volume = volume
    }

    func volume(for device: MediaOutputDevice) -> Float {
        EffeTuneDriver.shared.volume
    }

    func changeVolume(by increments: Int, for device: MediaOutputDevice) {
        let step: Float = 1.0 / 16.0
        let v = EffeTuneDriver.shared.volume + Float(increments) * step
        EffeTuneDriver.shared.volume = min(max(v, 0), 1)
        if let d = localDevice { routingManager.volumeChanged(for: d) }
    }

    func muteDevice(_ device: MediaOutputDevice) {
        EffeTuneDriver.shared.muted.toggle()
    }

    func isDeviceMuted(_ device: MediaOutputDevice) -> Bool {
        EffeTuneDriver.shared.muted
    }

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
