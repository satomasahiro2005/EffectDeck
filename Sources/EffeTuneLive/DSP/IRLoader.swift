//  IRLoader.swift
//  取り込んだインパルス応答をカーネルへ渡す。
//
//  ここが無かったので、IR Reverb は素材を選んでも素通しのままだった
//  （IRLibrary は Documents/IR へ写すところで止まっていて、
//   AssetUpload.send の呼び手は FIR 系の designer だけだった）。
//
//  やることは 2 つ。
//    1. 音のファイルを float の面へ読む（AVAudioFile。WAV / FLAC / AIFF / CAF）
//    2. 上流の解決規則で topology と rate divider を決めて AssetUpload.send へ渡す
//
//  解決規則は js/ir-library/ir-plugin-contract.js:104-200
//  (resolveIrProcessingConfig) をそのまま写したもの。推測は入れていない。
//
//  **4ch の True Stereo が通るようにしてある。** BRIR（ダミーヘッドで測った
//  「部屋＋スピーカー」の応答。左右スピーカー → 左右両耳の 4 経路）を読ませると、
//  ヘッドホンでも目の前のスピーカーで鳴っているように聞こえる、という使い方が
//  上流で知られている。channelMode が auto のとき、4ch かつ処理幅 2ch なら
//  自動で True Stereo になる（同 :150-155）。

import AVFoundation
import Foundation
import os

enum ETIRLoadError: LocalizedError {
    case cannotOpen(String)
    case emptyFile
    case tooManyChannels(Int)
    case unsupportedRate(Double)
    /// 上流の resolveIrProcessingConfig が返す拒否の文。そのまま出す。
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let why): return "Could not read the file. \(why)"
        case .emptyFile: return "The file contains no audio."
        case .tooManyChannels(let n): return "This impulse response has \(n) channels; up to 16 are supported."
        case .unsupportedRate(let r): return "Unsupported sample rate \(Int(r))."
        case .rejected(let message): return message
        }
    }
}

enum ETIRLoader {

    private static let log = Logger(subsystem: "ai.nemut.effetune", category: "ir")

    /// 読み込んだ IR。面ごとに分かれた float と、その素材のレート。
    struct Decoded {
        var channels: [[Float]]
        var sampleRate: Double
        var frames: Int
    }

    // MARK: - 読む

    /// ファイルを float の面へ読む。
    ///
    /// **ここでは伸縮しない。** 素材のレートのまま返す。
    /// 合わせるのは load の側（カーネルは「処理レート ÷ rate_divider」で
    /// 書かれていることを検算するので、そこへ合わせる必要がある）。
    static func decode(_ url: URL) throws -> Decoded {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw ETIRLoadError.cannotOpen(error.localizedDescription)
        }

        let format = file.processingFormat
        let channelCount = Int(format.channelCount)
        guard channelCount >= 1, channelCount <= 16 else {
            throw ETIRLoadError.tooManyChannels(channelCount)
        }
        let frames = Int(file.length)
        guard frames > 0 else { throw ETIRLoadError.emptyFile }
        guard format.sampleRate > 0 else { throw ETIRLoadError.unsupportedRate(format.sampleRate) }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames)) else {
            throw ETIRLoadError.cannotOpen("could not allocate a buffer")
        }
        do {
            try file.read(into: buffer)
        } catch {
            throw ETIRLoadError.cannotOpen(error.localizedDescription)
        }
        let read = Int(buffer.frameLength)
        guard read > 0 else { throw ETIRLoadError.emptyFile }

        // processingFormat は常に deinterleaved float32 なので面がそのまま取れる。
        guard let data = buffer.floatChannelData else {
            throw ETIRLoadError.cannotOpen("the decoder did not return float samples")
        }
        var channels = [[Float]]()
        channels.reserveCapacity(channelCount)
        for ch in 0..<channelCount {
            let plane = data[ch]
            var out = [Float](repeating: 0, count: read)
            out.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress?.update(from: plane, count: read)
            }
            // 非有限が 1 つでもあると makePayload が弾くので、ここで潰す。
            for i in 0..<read where !out[i].isFinite { out[i] = 0 }
            channels.append(out)
        }
        return Decoded(channels: channels, sampleRate: format.sampleRate, frames: read)
    }

    // MARK: - 解決

    /// 上流 resolveIrProcessingConfig の答え。
    struct Resolved {
        var topology: ETAssetTopology
        /// 送る面の数。mono は 1、indep は処理幅、true は 4、matrix は素材のまま。
        var assetChannels: Int
        var processingChannels: UInt32
        var paths: [ETAssetPath]
        var headBlock: UInt32
        var rateDivider: UInt32
        /// auto を解いた結果。UI に出す用。
        var channelMode: String
        var rateMode: String
    }

    /// ir-plugin-contract.js:104-200 をそのまま写したもの。
    ///
    /// - Parameters:
    ///   - sampleRate: **処理レート**（engine のレート）。素材のレートではない
    ///   - channelCount: 素材の面の数
    ///   - routedChannels: このエフェクトが処理する幅
    ///   - channelMode: "auto" / "mono" / "indep" / "true" / "multi"
    ///   - latency: "0" / "128" / "256" / "512" / "1024"
    ///   - convolutionRate: "auto" / "full" / "half" / "quarter"
    static func resolve(sampleRate: Double,
                        channelCount: Int,
                        routedChannels: Int,
                        channelMode: String,
                        latency: String,
                        convolutionRate: String) throws -> Resolved {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw ETIRLoadError.rejected("The current audio sample rate is unavailable.")
        }
        guard channelCount >= 1, channelCount <= 16 else {
            throw ETIRLoadError.rejected("This impulse response has an unsupported channel count.")
        }
        guard routedChannels >= 1, routedChannels <= 16 else {
            throw ETIRLoadError.rejected("The selected audio channels are not available.")
        }
        guard ["auto", "mono", "indep", "true", "multi"].contains(channelMode) else {
            throw ETIRLoadError.rejected("Choose a supported channel mode.")
        }

        guard let headBlock = UInt32(latency),
              [0, 128, 256, 512, 1024].contains(headBlock) else {
            throw ETIRLoadError.rejected("Choose a supported latency setting.")
        }

        var rateMode = convolutionRate
        if headBlock == 0 { rateMode = "full" }
        if rateMode == "auto" { rateMode = sampleRate >= 88200 ? "half" : "full" }
        guard ["full", "half", "quarter"].contains(rateMode) else {
            throw ETIRLoadError.rejected("Choose a supported convolution rate.")
        }
        if rateMode == "quarter" && sampleRate < 176400 {
            throw ETIRLoadError.rejected(
                "Quarter rate is available at sample rates of 176.4 kHz or higher.")
        }
        let rateDivider: UInt32 = rateMode == "quarter" ? 4 : (rateMode == "half" ? 2 : 1)

        var resolvedMode = channelMode
        if resolvedMode == "auto" {
            if channelCount == 1 {
                resolvedMode = "mono"
            } else if channelCount == 4 && routedChannels == 2 {
                resolvedMode = "true"
            } else if channelCount == routedChannels {
                resolvedMode = "indep"
            } else {
                resolvedMode = "multi"
            }
        }

        let topology: ETAssetTopology
        let assetChannels: Int
        var paths = [ETAssetPath]()
        switch resolvedMode {
        case "mono":
            topology = .mono
            assetChannels = 1
        case "true":
            guard channelCount == 4, routedChannels == 2 else {
                throw ETIRLoadError.rejected(
                    "True Stereo requires a four-channel IR and a stereo channel selection.")
            }
            topology = .trueStereo
            assetChannels = 4
        case "indep":
            guard channelCount >= routedChannels else {
                throw ETIRLoadError.rejected(
                    "Independent mode requires one IR channel for each selected audio channel.")
            }
            topology = .independent
            assetChannels = routedChannels
        default:
            // diagonalPaths（同 :41-52）。素材と処理幅の小さい方まで、1 対 1 で結ぶ。
            let count = min(channelCount, routedChannels, 16)
            guard count > 0 else {
                throw ETIRLoadError.rejected("Matrix mode could not create a valid channel route.")
            }
            for i in 0..<count {
                paths.append(ETAssetPath(inputSlot: UInt32(i),
                                         outputSlot: UInt32(i),
                                         irChannel: UInt32(i)))
            }
            topology = .matrix
            assetChannels = channelCount
        }

        return Resolved(topology: topology,
                        assetChannels: assetChannels,
                        processingChannels: UInt32(routedChannels),
                        paths: paths,
                        headBlock: headBlock,
                        rateDivider: rateDivider,
                        channelMode: resolvedMode,
                        rateMode: rateMode)
    }

    // MARK: - 送る

    /// 読んで、解決して、送る。**MainActor で呼ぶこと**（AssetUpload.swift 冒頭）。
    ///
    /// - Returns: UI へ出す 1 行。「4ch True Stereo / 48000 Hz / 1.2 s」の形。
    @MainActor
    @discardableResult
    static func load(url: URL,
                     engine: UInt32,
                     instance: UInt32,
                     processingRate: Double,
                     routedChannels: Int,
                     channelMode: String,
                     latency: String,
                     convolutionRate: String) throws -> String {
        let decoded = try decode(url)
        let resolved = try resolve(sampleRate: processingRate,
                                   channelCount: decoded.channels.count,
                                   routedChannels: routedChannels,
                                   channelMode: channelMode,
                                   latency: latency,
                                   convolutionRate: convolutionRate)

        // 送る面の数を topology に合わせる。
        //   mono   先頭 1 面だけ
        //   indep  先頭から処理幅ぶん
        //   true   4 面そのまま
        //   matrix 素材のまま
        var channels = decoded.channels
        if resolved.assetChannels < channels.count {
            channels = Array(channels.prefix(resolved.assetChannels))
        } else if resolved.assetChannels > channels.count {
            // indep で素材が足りない場合は resolve が弾いているので、ここには来ない。
            throw ETIRLoadError.rejected(
                "This impulse response does not have enough channels for the selected mode.")
        }

        // **ヘッダに書くのは「処理レート ÷ rate_divider」。素材のレートではない。**
        // カーネルの検算がそう書いてある（ir_reverb/kernel.cpp:486-496）:
        //     expected_rate = lround(sample_rate_ / rate_divider_)
        // `sample_rate_` はカーネルの処理レート。ここを素材のレートで書くと
        // commit が ET_ERR_ARGS(-1) で落ちる。
        //
        // だから**中身もそのレートへ合わせる**。44.1kHz の IR を 96kHz の鎖へ
        // 入れるのは普通にあるので、ここで伸縮する。
        let targetRate = processingRate / Double(resolved.rateDivider)
        let headerRate = Int(targetRate.rounded())
        if abs(decoded.sampleRate - targetRate) > 0.5 {
            channels = channels.map { resample($0, from: decoded.sampleRate, to: targetRate) }
        }

        try AssetUpload.send(engine: engine,
                             instance: instance,
                             channels: channels,
                             sampleRate: headerRate,
                             topology: resolved.topology,
                             paths: resolved.paths,
                             headBlock: resolved.headBlock,
                             rateDivider: resolved.rateDivider,
                             processingChannels: resolved.processingChannels)

        let seconds = Double(decoded.frames) / decoded.sampleRate
        let name = displayName(resolved.channelMode)
        // 出すのは素材のレート。送ったレートは中身の都合なので出さない。
        let line = String(format: "%dch %@ / %d Hz / %.2f s",
                          decoded.channels.count, name,
                          Int(decoded.sampleRate.rounded()), seconds)
        log.notice("IR 送り込み \(line, privacy: .public) divider=\(resolved.rateDivider)")
        return line
    }

    /// 線形で伸縮する。
    ///
    /// **凝ったものにしない。** IR は元から尾を引く波形で、変換の誤差は
    /// 畳み込みの結果に埋もれる。上流は WebAudio の decodeAudioData に
    /// 任せていて、そこも素材を文脈のレートへ合わせるだけ。
    /// 端は両側とも自分自身で押さえる（外挿しない）。
    static func resample(_ input: [Float], from: Double, to: Double) -> [Float] {
        guard from > 0, to > 0, input.count > 1 else { return input }
        let ratio = to / from
        let count = max(1, Int((Double(input.count) * ratio).rounded()))
        var out = [Float](repeating: 0, count: count)
        let last = input.count - 1
        for i in 0..<count {
            let x = Double(i) / ratio
            let i0 = min(last, Int(x))
            let i1 = min(last, i0 + 1)
            let t = Float(x - Double(i0))
            out[i] = input[i0] + (input[i1] - input[i0]) * t
        }
        return out
    }

    /// ir_reverb.js:1746-1756 の _channelModeName と同じ出し方。
    static func displayName(_ mode: String) -> String {
        switch mode {
        case "mono": return "Mono"
        case "indep": return "Independent"
        case "true": return "True Stereo"
        case "multi": return "Multi-channel"
        default: return mode
        }
    }
}
