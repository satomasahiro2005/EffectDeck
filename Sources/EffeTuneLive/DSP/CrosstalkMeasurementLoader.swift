//  CrosstalkMeasurementLoader.swift
//  Crosstalk Cancellation が食う「耳もとの測定」を音のファイルから作る。
//
//  CrosstalkCancellationDesigner は 4 枠の Measurement
//  （Designers/CrosstalkCancellationDesigner.swift:154-187）を要求するが、
//  それを作る側がこのアプリに無かった。上流は測定機能が持っている測定ストア
//  （js/measurement-store/client.js）から引いていて、こちらにはそれが無い。
//
//  無い代わりに、上流の**ファイル取り込み**の道をそのまま写す。
//  features/measurement/impulse-response-import.js:84-137 の
//  createImpulseResponseMeasurement は、取り込んだ IR から
//      onsetIndex          detectOnset(samples, sampleRate)
//      trimStartSamples    0
//      outputTimeReference 'file'
//      refScale            1
//  の記録を作る。ここで作るのも同じ 4 つ。推測は入れていない。
//
//  --- 1 本のファイルが 2 枠になる ---
//  片耳にマイクを置いて左右のスピーカーを順に鳴らした 1 回の測定が、
//  2ch のファイル 1 本。上流も「同じ耳へ届く 2 本は必ず 1 つの測定の 2 チャンネル」
//  として扱い、枠を耳ごとに組にしている
//  （plugins/spatial/crosstalk_cancellation.js:15-23）。
//  どちらのチャンネルがどちらのスピーカーかも上流が決めていて、
//  「左スピーカーの枠は測定の下のチャンネルを取る」（同 :30-31）。
//
//  --- id の形 ---
//  枠どうしが同じ測定から来ていることは id で判定される。
//  `::ch=` の前が測定の id で、後ろがチャンネルの名前
//  （js/measurement-store/client.js:4, 26-32）。名前は
//  impulse-response-import.js:19-22 の OUTPUT_CHANNELS の先頭 2 つ、
//  つまり "left" と "right"。
//  測定の id にはライブラリの鍵（中身の sha256 先頭 24 桁）を使う。
//  同じファイルを両耳に割り当てると id が衝突するので、designer の
//  duplicate-measurement-assignment で弾かれる。
//
//  --- ここで伸縮はしない ---
//  素材のレートのまま渡す。エンジンのレートへ合わせるのは designer の側
//  （resampleWindowedSinc。CrosstalkCancellationDesigner.swift:535-595）。

import Foundation

enum ETCrosstalkLoadError: LocalizedError {
    case notEnoughChannels(Int)

    var errorDescription: String? {
        switch self {
        case .notEnoughChannels(let count):
            return """
                   This file has \(count) channel\(count == 1 ? "" : "s"). \
                   A crosstalk measurement is one recording made at one ear with both \
                   speakers swept, so it needs at least two channels.
                   """
        }
    }
}

enum ETCrosstalkLoader {

    typealias Measurement = CrosstalkCancellationDesigner.Measurement

    /// 片耳ぶんの測定。ファイル 1 本から 2 枠ぶんを作る。
    struct Ear {
        /// 測定の id（`::ch=` の前）。ライブラリの鍵。
        var id: String
        /// 画面に出す名前。
        var name: String
        var sampleRate: Int
        var frames: Int
        /// 左スピーカーから届いた方（下のチャンネル）。
        var leftSpeaker: Measurement
        /// 右スピーカーから届いた方（上のチャンネル）。
        var rightSpeaker: Measurement
    }

    /// js/measurement-store/client.js:4。
    private static let virtualChannelSeparator = "::ch="

    // MARK: - 読む

    /// 音のファイルを片耳ぶんの測定にする。
    ///
    /// - Parameters:
    ///   - url: 取り込んだファイル（IRLibrary が Documents へ写したもの）
    ///   - id: 測定の id。ライブラリの鍵をそのまま渡す
    ///   - name: 画面に出す名前
    static func load(url: URL, id: String, name: String) throws -> Ear {
        let decoded = try ETIRLoader.decode(url)
        guard decoded.channels.count >= 2 else {
            throw ETCrosstalkLoadError.notEnoughChannels(decoded.channels.count)
        }
        let rate = Int(decoded.sampleRate.rounded())
        return Ear(id: id,
                   name: name,
                   sampleRate: rate,
                   frames: decoded.frames,
                   leftSpeaker: measurement(decoded.channels[0],
                                            id: id + virtualChannelSeparator + "left",
                                            sampleRate: rate),
                   rightSpeaker: measurement(decoded.channels[1],
                                             id: id + virtualChannelSeparator + "right",
                                             sampleRate: rate))
    }

    /// impulse-response-import.js:117-135 の records と同じ中身。
    private static func measurement(_ samples: [Float],
                                    id: String,
                                    sampleRate: Int) -> Measurement {
        Measurement(id: id,
                    data: samples.map { Double($0) },
                    sampleRate: sampleRate,
                    // ファイルの先頭が記録の先頭。上流も取り込みでは 0 を書く。
                    trimStartSamples: 0,
                    onsetIndex: detectOnset(samples, sampleRate: sampleRate),
                    // 取り込んだ IR は deconvolution の基準を持たないので 1。
                    referenceScale: 1,
                    timeReference: .file)
    }

    // MARK: - 立ち上がりの位置

    /// js/utils/measurement-dsp/onset.js:1-30 の detectOnset をそのまま写したもの。
    ///
    /// 1ms の窓でエネルギーを積み、山の 1% を越えた最初の位置を返す。
    /// **ここがずれても designer の検査は通る。** 設計だけが静かに壊れるので、
    /// 上流と同じ判定にしてある（勝手な閾値を置かない）。
    static func detectOnset(_ samples: [Float], sampleRate: Int) -> Int {
        guard !samples.isEmpty else { return 0 }

        var energies = [Double](repeating: 0, count: samples.count)
        for index in 0..<samples.count {
            let value = Double(samples[index])
            energies[index] = value * value
        }

        var leadingSilenceFrames = 0
        while leadingSilenceFrames < energies.count,
              energies[leadingSilenceFrames] <= 1e-20 {
            leadingSilenceFrames += 1
        }
        // 全部無音。onset.js:6 と同じく 0 を返す。
        if leadingSilenceFrames == energies.count { return 0 }

        let rounded = Int((Double(sampleRate) * 0.001).rounded())
        let windowFrames = rounded < 8 ? 8 : rounded

        var windowEnergy = [Double](repeating: 0, count: energies.count)
        var running = 0.0
        var peak = 0.0
        for frame in 0..<energies.count {
            running += energies[frame]
            if frame >= windowFrames { running -= energies[frame - windowFrames] }
            windowEnergy[frame] = running
            if running > peak { peak = running }
        }

        let threshold = peak * 0.01
        var onsetFrame = leadingSilenceFrames
        while onsetFrame < windowEnergy.count, windowEnergy[onsetFrame] < threshold {
            onsetFrame += 1
        }
        if onsetFrame == windowEnergy.count { onsetFrame = leadingSilenceFrames }
        return onsetFrame
    }
}
