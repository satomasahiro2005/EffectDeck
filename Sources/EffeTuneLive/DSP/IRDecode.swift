//  IRDecode.swift
//  音のファイルを float の面へ読む（IRLoader.swift の「読む」を分けたもの）。
//
//  IRLoader.swift は AssetUpload と EffeTuneDSP に触るので単体テストのバンドルに入らない。
//  **読んだものの確かめ方（幅・長さ・レートの門、非有限を 0 にする）と表示名は Foundation だけで
//  書いてここに置く。**Linux（Tests/Linux/run.sh）でも走る（IRDecodeTests）。
//
//  AVAudioFile で開くところ（decode・canOpen）は `#if canImport(AVFoundation)` の中。
//  Mac のバンドルでは実際に書いた WAV を読ませて試す。IRLibrary.looksLikeAudio もここの
//  canOpen を呼ぶ（**音かどうかは、読む当人に訊く**。開く道を 1 本にしておく）。

import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

// ETIRLoadErrorはIRPreparation.swiftにある（単体テストのバンドルからも見えるように）。

/// 読み込んだ IR。面ごとに分かれた float と、その素材のレート。
struct ETIRDecoded {
    var channels: [[Float]]
    var sampleRate: Double
    var frames: Int
}

enum ETIRDecode {

    /// 受ける面の数の上限。カーネルの資産が持てる幅（AssetUpload.makePayload も 16 で切る）。
    static let maximumChannels = 16

    /// 開いたファイルの形を、読む前に確かめる。**順番は幅 → 長さ → レート。**
    /// 幅が 0 のときも tooManyChannels(0) になる（前からそう出している）。
    static func checkFormat(channelCount: Int, frames: Int, sampleRate: Double) throws {
        guard channelCount >= 1, channelCount <= maximumChannels else {
            throw ETIRLoadError.tooManyChannels(channelCount)
        }
        guard frames > 0 else { throw ETIRLoadError.emptyFile }
        // NaN もここで落ちる（比べると常に偽）。
        guard sampleRate > 0 else { throw ETIRLoadError.unsupportedRate(sampleRate) }
    }

    /// 読めた 1 面を写す。**非有限は 0 にする。**1 つでもあると makePayload が弾く。
    static func sanitized(_ plane: UnsafeBufferPointer<Float>) -> [Float] {
        var out = Array(plane)
        for i in out.indices where !out[i].isFinite { out[i] = 0 }
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

    #if canImport(AVFoundation)
    /// ファイルを float の面へ読む。
    ///
    /// **ここでは伸縮しない。** 素材のレートのまま返す。
    /// 合わせるのは ETIRLoader.load の側（カーネルは「処理レート ÷ rate_divider」で
    /// 書かれていることを検算するので、そこへ合わせる必要がある）。
    static func decode(_ url: URL) throws -> ETIRDecoded {
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
        let frames = Int(file.length)
        try checkFormat(channelCount: channelCount, frames: frames, sampleRate: format.sampleRate)

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
        let channels = (0..<channelCount).map {
            sanitized(UnsafeBufferPointer(start: data[$0], count: read))
        }
        return ETIRDecoded(channels: channels, sampleRate: format.sampleRate, frames: read)
    }

    /// 音のファイルか。**開けるかどうかで決める。**
    ///
    /// 読むのは decode の AVAudioFile 一本なので、そこが開ければ音、
    /// 開けなければ音ではない。形を並べて数える必要が無く、扱える形が増えても
    /// ここを直さなくてよい。
    ///
    /// 頭だけ読んで済ませたくなるが、**m4a や mp3 は先頭が印にならない**
    /// （ftyp は 4 バイト目から、mp3 は ID3 のことも生フレームのこともある）。
    /// 取り込みのときしか通らないので、開く手間は払ってよい。
    static func canOpen(_ url: URL) -> Bool {
        (try? AVAudioFile(forReading: url)) != nil
    }
    #endif
}
