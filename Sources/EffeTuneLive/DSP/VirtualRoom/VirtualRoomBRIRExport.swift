//  VirtualRoomBRIRExport.swift
//  いまの Virtual Room から 4ch BRIR を作る（docs/virtual-room-design.md §42〜§45）。
//
//  **別のアルゴリズムは書かない。**§44 の条件は「実時間で聴く部屋と書き出す BRIR が
//  同じエンジンから出ること」なので、ここは `VirtualRoomPlugin` の instance を
//  もう 1 つ作って、そこへインパルスを通すだけにしてある。カーネルは同じもの。
//
//  実時間の engine は使わない。**別の engine を立てる**（abi.cpp は 16 個まで持てる）。
//  同じ engine の instance を main スレッドから process すると、音のスレッドと
//  scratch を取り合う。
//
//  §43 の並びは固定:
//      0 = LL   左スピーカー → 左耳
//      1 = LR   左スピーカー → 右耳
//      2 = RL   右スピーカー → 左耳
//      3 = RR   右スピーカー → 右耳

import AVFoundation
import Foundation
import os

enum ETVirtualRoomBRIR {

    private static let log = Logger(subsystem: "ai.nemut.effetune", category: "brir")

    /// §45。長さの上限。
    static let maximumSeconds = 10.0
    /// §45。末尾をここまで落ちた所で切る。
    static let tailFloorDB: Float = -80
    /// 切った後に残す余白（秒）。切り口が聞こえないように少しだけ残す。
    private static let tailMargin = 0.02
    /// これより短くはしない（秒）。
    private static let minimumSeconds = 0.05
    private static let block: UInt32 = 1024

    enum Failure: LocalizedError {
        case engine
        case instance
        case parameters(Int32)
        case render(Int32)
        case silent

        var errorDescription: String? {
            switch self {
            case .engine: return "Could not prepare an offline renderer."
            case .instance: return "Could not create a Virtual Room renderer."
            case .parameters(let s): return "The renderer rejected the parameters (\(s))."
            case .render(let s): return "Rendering failed (\(s))."
            case .silent: return "The room produced no output."
            }
        }
    }

    /// 書き出したファイルの URL を返す。呼ぶ側が共有シートへ渡す。
    static func export(spec: ETEffect, values: [Float], sampleRate: Double) throws -> URL {
        let channels = try render(spec: spec, values: values, sampleRate: sampleRate)
        return try write(channels, sampleRate: sampleRate)
    }

    // MARK: - 鳴らす

    /// §44。左だけ叩いて LL / LR、右だけ叩いて RL / RR。
    static func render(spec: ETEffect, values: [Float],
                       sampleRate: Double) throws -> [[Float]] {
        let engine = et_engine_create()
        guard engine != 0 else { throw Failure.engine }
        defer { et_engine_destroy(engine) }

        guard Int(et_engine_prepare(engine, Float(sampleRate), 2, block, 0)) == ET_OK else {
            throw Failure.engine
        }
        let instance = spec.type.withCString { et_instance_create(engine, $0) }
        guard instance != 0 else { throw Failure.instance }
        defer { et_instance_destroy(engine, instance) }

        let total = Int((sampleRate * maximumSeconds).rounded())
        let left = try sweep(engine: engine, instance: instance, spec: spec,
                             values: values, frames: total, impulseOn: 0)
        let right = try sweep(engine: engine, instance: instance, spec: spec,
                              values: values, frames: total, impulseOn: 1)

        var channels = [left.0, left.1, right.0, right.1]
        let keep = tailLength(of: channels, sampleRate: sampleRate)
        guard keep > 0 else { throw Failure.silent }
        for i in channels.indices { channels[i] = Array(channels[i].prefix(keep)) }
        log.notice("BRIR \(keep) frames @ \(sampleRate) Hz")
        return channels
    }

    /// 片方の耳ではなく、片方の**スピーカー**を叩く 1 回分。
    private static func sweep(engine: et_engine, instance: et_instance,
                              spec: ETEffect, values: [Float],
                              frames: Int, impulseOn: Int) throws -> ([Float], [Float]) {
        // reset してから値を入れ直す。reset が内部の係数まで捨てる作りでも、
        // 入れ直しておけば 2 回目が 1 回目と同じ部屋になる。
        et_instance_reset(engine, instance)
        var packed = values
        let st = packed.withUnsafeBufferPointer {
            et_instance_set_params(engine, instance, $0.baseAddress,
                                   UInt32(spec.floatCount), spec.paramsHash, 0)
        }
        guard Int(st) == ET_OK else { throw Failure.parameters(st) }

        var outL = [Float](repeating: 0, count: frames)
        var outR = [Float](repeating: 0, count: frames)
        // 面ごとに並ぶ（planar）。channel c は audio + c * frame_count から。
        var audio = [Float](repeating: 0, count: Int(block) * 2)

        var done = 0
        var time = 0.0
        while done < frames {
            let n = min(Int(block), frames - done)
            for i in audio.indices { audio[i] = 0 }
            if done == 0 { audio[impulseOn * Int(block)] = 1 }

            let st = audio.withUnsafeMutableBufferPointer {
                et_instance_process(engine, instance, $0.baseAddress, 2, UInt32(n), time)
            }
            guard Int(st) == ET_OK else { throw Failure.render(st) }

            for i in 0..<n {
                outL[done + i] = audio[i]
                outR[done + i] = audio[Int(block) + i]
            }
            done += n
            time += Double(n) / sampleRate
        }
        return (outL, outR)
    }

    /// §45。全面のピークに対して -80 dB を最後に超えた所まで残す。
    private static func tailLength(of channels: [[Float]], sampleRate: Double) -> Int {
        var peak: Float = 0
        for channel in channels { for v in channel { peak = max(peak, abs(v)) } }
        guard peak > 0 else { return 0 }

        let floor = peak * pow(10, tailFloorDB / 20)
        var last = 0
        for channel in channels {
            var i = channel.count - 1
            while i > last {
                if abs(channel[i]) > floor { break }
                i -= 1
            }
            last = max(last, i)
        }
        let margin = Int(sampleRate * tailMargin)
        let minimum = Int(sampleRate * minimumSeconds)
        return min(channels[0].count, max(last + margin + 1, minimum))
    }

    // MARK: - 書く

    /// §45。4ch Float32 WAV。レートはいま処理しているレートのまま。
    static func write(_ channels: [[Float]], sampleRate: Double) throws -> URL {
        let frames = channels[0].count
        // 4ch には並びの宣言が要る。**順番どおりに並べるだけ**の宣言にする。
        // 5.1 などの決まった配置に当てはめると、読む側が勝手に振り分ける。
        let layout = AVAudioChannelLayout(
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4)!
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                   channelLayout: layout)!

        let name = "VirtualRoom-BRIR-\(Int(sampleRate))Hz.wav"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 4,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVChannelLayoutKey: layout.layout != nil
                ? Data(bytes: layout.layout, count: MemoryLayout<AudioChannelLayout>.size)
                : Data(),
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames)),
              let data = buffer.floatChannelData else { throw Failure.silent }
        buffer.frameLength = AVAudioFrameCount(frames)
        for c in 0..<4 {
            channels[c].withUnsafeBufferPointer {
                data[c].update(from: $0.baseAddress!, count: frames)
            }
        }
        try file.write(from: buffer)
        return url
    }
}
