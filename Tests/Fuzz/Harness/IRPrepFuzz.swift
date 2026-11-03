//  IRPrepFuzz.swift（Tests/Fuzz）
//  的 irprep: IR Reverb の下ごしらえ（ETIRPreparation）を、でたらめな面と設定で回す。
//
//  入力の頭 16 バイトが設定、残りが標本（ETIRPreparation.resolve → stage、prepare、truncate）。
//    0     面の数（0〜16。0 は断るのを見るため）
//    1-2   フレーム数（1〜2048。伸縮するときは 512 まで）
//    3     素材のレート（表から。範囲の外のものも混ぜる）
//    4     処理レート
//    5-7   channelMode / latency / convolutionRate（表から。知らない綴りも混ぜる）
//    8     処理する幅（0〜17）
//    9     標本の読み方（偶数: 16 bit の整数を ±1 へ、奇数: Float のビットそのまま）
//    10-15 Options（directCut、cutOffsetMs、decayPercent、trimPercent。範囲の外も混ぜる）
//
//  約束（**NaN・無限を先へ渡さない**）:
//    - resolve が通したものは形が合っている（面の数・経路）
//    - stage / prepare が返した面と利得は全部有限で、長さがそろっている
//    - 素材が有限で ±1 の中なら、伸縮（resampleChannels / pick）の結果も有限
//    - truncate は max(1, 上限) より長くしない
//    - 投げるのはよい（断るのは約束のうち）。落ちるのはだめ

import Foundation

enum IRPrepFuzz {
    private static let sourceRates: [Double] = [48000, 44100, 96000, 88200, 192000, 176400, 22050,
                                                8000, 1000, 999_999, 999, 1_000_000, 44100.5, 0]
    private static let processingRates: [Double] = [48000, 44100, 96000, 88200, 192000, 176400, 0]
    private static let modes = ["auto", "mono", "indep", "true", "multi", "stereo"]
    private static let latencies = ["0", "128", "256", "512", "1024", "64", ""]
    private static let convolutionRates = ["auto", "full", "half", "quarter", "eighth"]

    static func run(_ data: UnsafeRawBufferPointer) {
        var input = FuzzBytes(data)
        let channelCount = Int(input.u8()) % 17
        var frames = 1 + input.u16() % 2048
        let sourceRate = input.pick(sourceRates)
        let processingRate = input.pick(processingRates)
        let mode = input.pick(modes)
        let latency = input.pick(latencies)
        let rate = input.pick(convolutionRates)
        let routed = Int(input.u8()) % 18
        let rawFloats = input.bool()
        var options = ETIRPreparation.Options()
        options.directCut = input.bool()
        options.cutOffsetMs = Double(Int(input.u8()) - 60)          // -60〜195（-20〜50 の外も）
        options.decayPercent = Double(input.u16() % 450)            // 0〜449（10〜400 の外も）
        options.trimPercent = Double(Int(input.u8()) % 120)         // 0〜119（1〜100 の外も）
        // 伸縮は出すフレーム数×係数の数だけかかる。1 kHz → 192 kHz は 192 倍に伸びるので短く切る
        // （回す数を稼ぐため。長さで分かれる道は無い）。
        if sourceRate.rounded() != processingRate.rounded() {
            let ratio = max(sourceRate, processingRate) / max(1, min(sourceRate, processingRate))
            frames = min(frames, ratio > 4 ? 96 : 512)
        }

        // 標本。足りなければ 0 で埋める（頭の無音の扱いも回る）。
        var samples = input.rest()
        var channels: [[Float]] = []
        var cursor = 0
        func next() -> Float {
            if rawFloats {
                guard cursor + 4 <= samples.count else { cursor += 4; return 0 }
                defer { cursor += 4 }
                return Float(bitPattern: UInt32(samples[cursor]) | UInt32(samples[cursor + 1]) << 8
                             | UInt32(samples[cursor + 2]) << 16 | UInt32(samples[cursor + 3]) << 24)
            }
            guard cursor + 2 <= samples.count else { cursor += 2; return 0 }
            defer { cursor += 2 }
            return Float(Int16(bitPattern: UInt16(samples[cursor]) | UInt16(samples[cursor + 1]) << 8)) / 32768
        }
        for _ in 0..<channelCount {
            channels.append((0..<frames).map { _ in next() })
        }
        samples = []
        let bounded = channels.allSatisfy { $0.allSatisfy { $0.isFinite && abs($0) <= 1 } }

        // 伸縮だけ。素材が有限で ±1 の中なら結果も有限。
        if !channels.isEmpty, bounded, sourceRate > 0, processingRate > 0,
           ETIRPreparation.supportedRates.contains(sourceRate) {
            let resampled = ETIRPreparation.resampleChannels(channels, from: sourceRate, to: processingRate)
            finite(resampled, "resampleChannels \(sourceRate) → \(processingRate)")
            let picked = ETIRPreparation.pick(channels, from: sourceRate, to: processingRate)
            finite(picked, "pick \(sourceRate) → \(processingRate)")
        }

        // 下ごしらえだけ（伸縮なし）。
        for topology in [ETAssetTopology.mono, .independent, .trueStereo, .matrix] {
            if let prepared = try? ETIRPreparation.prepare(channels, sampleRate: 48000,
                                                           topology: topology, options: options) {
                check(prepared, "prepare \(topology)")
                Fuzz.oracle(prepared.channels.count == channels.count, "prepare が面の数を変えた")
            }
        }

        // 解決 → 伸縮 → 下ごしらえ → 面を選ぶ（IRLoader.load と同じ道）。
        guard let resolved = try? ETIRPreparation.resolve(sampleRate: processingRate,
                                                          channelCount: channelCount,
                                                          routedChannels: routed,
                                                          channelMode: mode,
                                                          latency: latency,
                                                          convolutionRate: rate) else { return }
        Fuzz.oracle((1...16).contains(resolved.assetChannels), "assetChannels \(resolved.assetChannels)")
        Fuzz.oracle(resolved.convolutionRate > 0, "convolutionRate \(resolved.convolutionRate)")
        for path in resolved.paths {
            Fuzz.oracle(Int(path.irChannel) < channelCount && Int(path.inputSlot) < routed,
                        "経路が面の外: \(path)")
        }
        guard let staged = try? ETIRPreparation.stage(channels, sourceRate: sourceRate,
                                                      resolved: resolved, options: options) else { return }
        check(staged, "stage")
        Fuzz.oracle(staged.sampleRate == resolved.convolutionRate, "stage のレート \(staged.sampleRate)")
        switch resolved.topology {
        case .mono: Fuzz.oracle(staged.channels.count == 1, "mono の面の数 \(staged.channels.count)")
        case .independent, .trueStereo:
            Fuzz.oracle(staged.channels.count == resolved.assetChannels, "送る面の数 \(staged.channels.count)")
        case .matrix, .unspecified: break
        }

        let limit = Int(input.u16()) - 8
        let cut = ETIRPreparation.truncate(staged.channels, maxFrames: limit)
        finite(cut.channels, "truncate")
        Fuzz.oracle(cut.channels.allSatisfy { $0.count <= max(1, limit) }, "truncate が上限より長い")
    }

    private static func check(_ prepared: ETIRPreparation.Prepared, _ context: String) {
        finite(prepared.channels, context)
        Fuzz.oracle(prepared.frames > 0, "\(context): 長さが 0")
        Fuzz.oracle(prepared.channels.allSatisfy { $0.count == prepared.frames }, "\(context): 面の長さがそろわない")
        Fuzz.oracle(prepared.initialGains.allSatisfy(\.isFinite) && prepared.finalGains.allSatisfy(\.isFinite),
                    "\(context): 利得が有限でない \(prepared.initialGains) \(prepared.finalGains)")
        Fuzz.oracle(prepared.sourceStartFrame >= 0, "\(context): 始まり \(prepared.sourceStartFrame)")
    }

    private static func finite(_ channels: [[Float]], _ context: String) {
        for (c, channel) in channels.enumerated() {
            if let i = channel.firstIndex(where: { !$0.isFinite }) {
                Fuzz.oracle(false, "\(context): 面 \(c) の \(i) が \(channel[i])")
            }
        }
    }
}
