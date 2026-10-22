//  VolumeProbe.swift
//  #17 の測り。**test/volume-probe-17 だけに置く。店の版には入れない。**
//
//  拡張（Media Device Extension, volumeControl .none）へ音を流している間に、
//  本体の AVAudioSession.outputVolume が実際の出力先（AirPods・有線・スピーカー）の
//  音量を追うか、音量ボタンやコントロールセンターで何が動くかを実機で見る。
//
//  **読むだけ。**セッションの設定・有効化・経路・音量・拡張には触らない。
//  画面にも何も出さない。音のスレッドからは何も呼ばない。
//
//  1 回の出来事を 1 行にして、Logger（category "volume"）・標準出力・
//  Library/Caches/volume-probe.log の 3 か所へ出す。

import AVFoundation
import UIKit
import os

@MainActor
final class VolumeProbe {

    static let shared = VolumeProbe()

    private let log = Logger(subsystem: "ai.nemut.effetune", category: "volume")
    private let file = VolumeProbeFile()
    /// 状態を読むだけ。作らせないので weak で持つ（AudioIO.init の最後から渡る）。
    private weak var audio: AudioIO?
    private var started = false
    private var t0: TimeInterval = 0
    private var kvo: NSKeyValueObservation?
    private var observers: [NSObjectProtocol] = []
    private var pollTask: Task<Void, Never>?
    /// 最後に書いた v の字。poll はこれと違うときだけ書く。
    private var lastLogged: String?
    /// 1 秒前の receivedFrames。差が「いま拡張から届いているか」になる。
    private var prevRecv: UInt64 = 0
    private var recvPerSecond: UInt64 = 0

    private init() {}

    func start(audio: AudioIO) {
        self.audio = audio
        guard !started else { return }
        started = true
        t0 = ProcessInfo.processInfo.systemUptime
        prevRecv = ETLinkReceiver.shared.receivedFrames
        file.open()

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        emit("start", at: t0, extra: "wall=\(iso.string(from: Date()))")

        let session = AVAudioSession.sharedInstance()
        // .initial で今の値を 1 行目に出す。KVO はメイン以外から来ることがあるので、
        // 値と時刻だけ先に取ってからメインへ渡す。
        kvo = session.observe(\.outputVolume, options: [.initial, .new]) { [weak self] _, change in
            let v = change.newValue
            let at = ProcessInfo.processInfo.systemUptime
            Task { @MainActor in self?.emit("kvo", at: at, volume: v) }
        }

        let nc = NotificationCenter.default
        // userInfo は Sendable ではないので、ブロックの中で数と字に落としてから渡す（AudioIO と同じ）。
        observers.append(nc.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main) { [weak self] note in
                let at = ProcessInfo.processInfo.systemUptime
                let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 99
                let prev = (note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey]
                            as? AVAudioSessionRouteDescription).map { VolumeProbe.describe($0.outputs) } ?? "-"
                Task { @MainActor in
                    self?.emit("route:\(VolumeProbe.routeReason(raw))", at: at, extra: "prev=\(prev)")
                }
            })

        observers.append(nc.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main) { [weak self] note in
                let at = ProcessInfo.processInfo.systemUptime
                let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let opts = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
                let reason = note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
                let name: String
                switch type {
                case 1?: name = "began"
                case 0?: name = "ended"
                default: name = "type\(type.map { String($0) } ?? "nil")"
                }
                let extra = "opts=\(opts.map { String($0) } ?? "-") reason=\(reason.map { String($0) } ?? "-")"
                Task { @MainActor in self?.emit("intr:\(name)", at: at, extra: extra) }
            })

        observers.append(nc.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil, queue: .main) { [weak self] _ in
                let at = ProcessInfo.processInfo.systemUptime
                Task { @MainActor in self?.emit("reset", at: at) }
            })

        observers.append(nc.addObserver(
            forName: AVAudioSession.mediaServicesWereLostNotification,
            object: nil, queue: .main) { [weak self] _ in
                let at = ProcessInfo.processInfo.systemUptime
                Task { @MainActor in self?.emit("lost", at: at) }
            })

        observers.append(nc.addObserver(
            forName: AVAudioSession.silenceSecondaryAudioHintNotification,
            object: nil, queue: .main) { [weak self] note in
                let at = ProcessInfo.processInfo.systemUptime
                let raw = note.userInfo?[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt
                let name: String
                switch raw {
                case 1?: name = "begin"
                case 0?: name = "end"
                default: name = "type\(raw.map { String($0) } ?? "nil")"
                }
                Task { @MainActor in self?.emit("hint:\(name)", at: at) }
            })

        let app: [(Notification.Name, String)] = [
            (UIApplication.willEnterForegroundNotification, "fg"),
            (UIApplication.didEnterBackgroundNotification, "bg"),
            (UIApplication.didBecomeActiveNotification, "active"),
            (UIApplication.willResignActiveNotification, "inactive"),
        ]
        for (name, ev) in app {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                let at = ProcessInfo.processInfo.systemUptime
                Task { @MainActor in self?.emit(ev, at: at) }
            })
        }

        // KVO が来ないまま値だけ変わる（背景など）のを拾う。
        // Task.sleep はアプリを起こしも引き留めもしない。止められていれば一緒に止まる。
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                self.poll()
            }
        }
    }

    private func poll() {
        let recv = ETLinkReceiver.shared.receivedFrames
        recvPerSecond = recv >= prevRecv ? recv - prevRecv : recv
        prevRecv = recv
        let v = AVAudioSession.sharedInstance().outputVolume
        if Self.format(v) != lastLogged {
            emit("poll", at: ProcessInfo.processInfo.systemUptime, volume: v)
        }
    }

    /// 1 行組んで 3 か所へ出す。
    private func emit(_ ev: String, at: TimeInterval, volume: Float? = nil, extra: String? = nil) {
        let session = AVAudioSession.sharedInstance()
        let vs = Self.format(volume ?? session.outputVolume)
        lastLogged = vs

        let outs = Self.describe(session.currentRoute.outputs)
        let cat = session.category.rawValue.replacingOccurrences(of: "AVAudioSessionCategory", with: "")
        let active = "other:\(session.isOtherAudioPlaying ? 1 : 0),hint:\(session.secondaryAudioShouldBeSilencedHint ? 1 : 0)"

        let link = ETLinkReceiver.shared
        let linkText = "peer:\(link.hasPeer ? 1 : 0),listen:\(link.listening ? 1 : 0),rx1s:\(recvPerSecond),recv:\(link.receivedFrames),buf:\(link.bufferedFrames)"

        let engine: String
        let dev: String
        let run: String
        if let audio {
            engine = audio.engineIsRunning ? "running" : "stopped"
            dev = audio.outputDevice.map { Self.clean($0.key ?? "\($0.kind.rawValue):nokey") } ?? "nil"
            run = audio.running ? "1" : "0"
        } else {
            engine = "none"; dev = "none"; run = "-"
        }

        let appState: String
        switch UIApplication.shared.applicationState {
        case .active: appState = "active"
        case .inactive: appState = "inactive"
        case .background: appState = "bg"
        @unknown default: appState = "unknown"
        }

        var line = "vol t=\(String(format: "%.3f", at - t0)) ev=\(ev) v=\(vs) out=\(outs) cat=\(cat) active=\(active) link=\(linkText) engine=\(engine) dev=\(dev) run=\(run) app=\(appState) rsp=\(session.routeSharingPolicy.rawValue)"
        if let extra { line += " " + extra }

        log.notice("\(line, privacy: .public)")
        print(line)
        file.append(line)
    }

    // MARK: - 字にする

    private static func format(_ v: Float) -> String {
        String(format: "%.3f", Double(v))
    }

    /// 行を空白で区切って読めるよう、名前の中の空白は _ にする。
    private nonisolated static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: " ", with: "_")
    }

    private nonisolated static func describe(_ ports: [AVAudioSessionPortDescription]) -> String {
        guard !ports.isEmpty else { return "none" }
        return ports.map {
            "\($0.portType.rawValue):\(clean($0.portName)):\(clean($0.uid))"
        }.joined(separator: ",")
    }

    private nonisolated static func routeReason(_ raw: UInt) -> String {
        switch raw {
        case 0: return "unknown"
        case 1: return "newDevice"
        case 2: return "oldDeviceGone"
        case 3: return "category"
        case 4: return "override"
        case 6: return "wake"
        case 7: return "noSuitableRoute"
        case 8: return "routeConfig"
        default: return "r\(raw)"
        }
    }
}

/// ファイルへの追記。**専用の直列キューで書く。**メインも音のスレッドも待たせない。
/// handle はこのキューの中だけで触る。
final class VolumeProbeFile: @unchecked Sendable {

    private let queue = DispatchQueue(label: "ai.nemut.effetune.volume-probe", qos: .utility)
    private var handle: FileHandle?

    /// 2 MB を超えていたときだけ空にしてから開く。
    func open() {
        queue.async { self.openOnQueue() }
    }

    func append(_ line: String) {
        queue.async {
            guard let h = self.handle, let data = (line + "\n").data(using: .utf8) else { return }
            do { try h.write(contentsOf: data) } catch {}
        }
    }

    private func openOnQueue() {
        guard handle == nil else { return }
        let fm = FileManager.default
        guard let dir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let url = dir.appendingPathComponent("volume-probe.log")
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? NSNumber, size.int64Value > 2 * 1024 * 1024 {
            try? fm.removeItem(at: url)
        }
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            _ = fm.createFile(atPath: url.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        _ = try? h.seekToEnd()
        handle = h
    }
}
