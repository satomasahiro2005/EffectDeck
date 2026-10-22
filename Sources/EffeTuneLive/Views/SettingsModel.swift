//  SettingsModel.swift
//  Settings 1 枚とツールバーの帯が読むものを、ビューの外で作る。
//
//  条件の判断と言い回しは StatusReadings.swift（Foundation だけ）に集めてある。理由は 2 つ。
//   - 同じ数字の呼び方が 2 か所にあると、片方だけ直って食い違う。
//     負荷の名前（"CPU"）と 1 文は ETLoadReading にしか無い。丸めも
//     ETDelaySplit と ETLoadReading.percent だけで、帯と Settings が同じものを通る。
//   - 「どの警告がいつ出るか」がビューの中の if に散らばっていると、
//     誤爆の検査が書けない。ETIssue.current が配列を返す形にしてある。
//     検査は Tests/Unit/StatusReadingsTests.swift。
//
//  ここに残すのは、実物に触る部分だけ:
//   - ETAppInfo（Bundle・uname・UIDevice・et_abi_version）
//   - ETAudioSnapshot を埋める**唯一の場所**（AudioIO・ETLinkReceiver・EffeTuneDSP・Telemetry）
//   - その snapshot を作って StatusReadings へ渡す薄い入口（SettingsView の呼び方はそのまま）
//
//  ここは AudioIO を**読むだけ**で、観測（@ObservedObject）はしない。
//  観測を置くのは SettingsView 側の小さな View（StatusSection / ProcessingTimeRow /
//  DelayRow / DetailsRows）と LiveStatusStrip だけで、List 全体には効かせない。

import Foundation
import Darwin
import UIKit

// MARK: - 版と端末

/// 版・ABI・端末。以前は SettingsView と AboutView が同じ private var version を
/// 1 つずつ持っていた。貼り付け用の文と画面の表示が食い違わないよう 1 か所にする。
enum ETAppInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }
    /// "2.9.0 (5)"
    static var display: String { "\(version) (\(build))" }

    /// DSP のバイナリ互換の番号。コンパイル時の定数で、使う人には意味が無い。
    /// 報告を受け取る側だけが読むので、Details と貼り付け用の文にしか出さない。
    static var abi: String { "\(et_abi_version())" }

    /// "iPhone17,2"。報告を 1 回で受け取るにはこれが要る。
    /// UIDevice.model は "iPhone" としか返さないので uname を使う。
    static var device: String {
        var info = utsname()
        uname(&info)
        let bytes = withUnsafeBytes(of: &info.machine) { raw -> [UInt8] in
            Array(raw.prefix(while: { $0 != 0 }))
        }
        let name = String(decoding: bytes, as: UTF8.self)
        return name.isEmpty ? "unknown" : name
    }

    @MainActor static var system: String { "iOS " + UIDevice.current.systemVersion }
}

// MARK: - 読む値を埋める

extension ETAudioSnapshot {
    /// **ここが唯一の埋め場所。**Status・CPU・遅れ・問題の行・Details・帯が
    /// 全部これを読む。量を足すときは欄をここと StatusReadings.swift に 1 つずつ。
    ///
    /// Telemetry の取りこぼしは**読むだけ**で観測しない（30Hz で publish するため）。
    @MainActor
    init(io: AudioIO, dsp: EffeTuneDSP) {
        self.init(
            status: io.status,
            hasPeer: io.hasPeer,
            running: io.running,
            resting: io.resting,
            route: io.route,
            outputRoute: io.outputRoute,
            loopback: io.loopback,
            load: io.load,
            blockFrames: io.blockFrames,
            sampleRate: io.sampleRate,
            processingRate: io.processingRate,
            resamplerLatency: io.resamplerLatency,
            pipelineLatency: io.pipelineLatency,
            bufferedFrames: io.bufferedFrames,
            received: io.received,
            applied: io.applied,
            linkTargetFrames: ETLinkReceiver.targetFrames,
            starveCount: ETLinkReceiver.starveCount,
            starveFrames: ETLinkReceiver.starveFrames,
            trimCount: ETLinkReceiver.trimCount,
            trimFrames: ETLinkReceiver.trimFrames,
            bypass: dsp.bypass,
            // Section は descriptor に入らないので分母から外す。
            effectCount: dsp.chain.filter { $0.role == .effect }.count,
            telemetryDropped: Telemetry.shared.droppedFrames)
    }
}

// MARK: - SettingsView からの入口

extension ETRunState {
    @MainActor
    static func current(io: AudioIO) -> ETRunState {
        current(ETAudioSnapshot(io: io, dsp: .shared))
    }
}

extension ETLoadReading {
    @MainActor
    init?(io: AudioIO) {
        self.init(ETAudioSnapshot(io: io, dsp: .shared))
    }
}

extension ETDelayReading {
    @MainActor
    init?(io: AudioIO) {
        self.init(ETAudioSnapshot(io: io, dsp: .shared))
    }
}

extension ETIssue {
    @MainActor
    static func current(io: AudioIO, dsp: EffeTuneDSP) -> [ETIssue] {
        current(ETAudioSnapshot(io: io, dsp: dsp))
    }
}

extension ETDiagnostics {
    @MainActor
    static func current(io: AudioIO, dsp: EffeTuneDSP, prefs: Preferences) -> ETDiagnostics {
        // 貼り付け用にだけ足す、いまの設定。
        let settings: [ETDiagnosticLine] = [
            ETDiagnosticLine(label: "Processing rate", value: prefs.processingRate.label),
            ETDiagnosticLine(label: "Latency", value: prefs.latency.choiceTitle),
            ETDiagnosticLine(label: "Pause after", value: prefs.powerMode.label),
            ETDiagnosticLine(label: "Silence threshold",
                             value: "\(Int(prefs.silenceThresholdDb)) dB"),
            ETDiagnosticLine(label: "Keep the screen on",
                             value: prefs.keepScreenAwake ? "On" : "Off"),
            ETDiagnosticLine(label: "Effect pipeline", value: dsp.bypass ? "Off" : "On"),
        ]
        return make(ETAudioSnapshot(io: io, dsp: dsp),
                    version: ETAppInfo.display,
                    abi: ETAppInfo.abi,
                    device: "\(ETAppInfo.device) · \(ETAppInfo.system)",
                    settings: settings)
    }
}

// MARK: - 失敗からの復帰

extension AudioIO {
    /// "Try again" から呼ぶ。
    ///
    /// start() は入口で stop(keepListening:) を通るので、ビュー側で stop→start を
    /// 並べる必要は無い（並べると、その間に followPeer が割り込む形ができる）。
    /// AudioIO.swift は別の作業が走っているので、口だけここに足してある。
    func restart() { start() }
}
