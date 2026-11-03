//  AudioBufferOps.swift
//  音のスレッドで使う並べ替えと書き出し。**生のポインタだけを取る。**
//
//  AudioBufferList も AVAudio* も取らないので、作り物の配列で試せる
//  （AudioBufferOpsTests）。AudioIO の render と ETAUExternalBridge の Adapter が呼ぶ。
//
//  **確保も待ちも ObjC もしない。** 渡される閉包は非エスケープなので積み上げで済む。
//  並べ方の約束: プレーナは「チャンネルごとの行」で、行の幅は明示したもの
//  （既定は frames）。EffeTune のカーネルは offset = channel * frame_count で読む。

import Foundation

enum ETAudioBufferOps {

    // MARK: - 見る

    /// 最大の絶対値。NaN は拾わない（`abs(NaN) > peak` が偽になる）。
    /// PowerGate は NaN を無音として扱うので、ここも同じ向きに倒す。
    static func peak(_ samples: UnsafePointer<Float>, count: Int) -> Float {
        guard count > 0 else { return 0 }
        var peak: Float = 0
        for i in 0..<count {
            let a = abs(samples[i])
            if a > peak { peak = a }
        }
        return peak
    }

    // MARK: - 入口

    /// リンクのインターリーブ（L,R,L,R…）を、`channels` 行のプレーナへ広げる。
    /// 1 行目が L、2 行目が R。3 行目以降は 0 で埋める（前のブロックの残りを出さない）。
    /// 入力は常に 2ch なので、`interleaved` は `frames * 2` だけ読む。
    static func spreadStereo(_ interleaved: UnsafePointer<Float>, frames: Int,
                             into planar: UnsafeMutablePointer<Float>, channels: Int) {
        guard frames > 0, channels > 0 else { return }
        planar.update(repeating: 0, count: frames * channels)
        if channels >= 2 {
            for i in 0..<frames {
                planar[i]          = interleaved[i * 2]
                planar[frames + i] = interleaved[i * 2 + 1]
            }
        } else {
            for i in 0..<frames { planar[i] = interleaved[i * 2] }
        }
    }

    // MARK: - 出口

    /// プレーナ（行の幅 = frames）を出力のバッファ群へ書く。
    ///
    /// - Parameters:
    ///   - frames: 有効なフレーム数（容量で切った n）。
    ///   - channels: プレーナの行数。
    ///   - frameCount: 出力が求めたフレーム数。frames を超えた分は 0 で埋める。
    ///   - bufferCount: バッファの数。
    ///   - buffer: k 番目のバッファの (先頭, 1 バッファに入っている本数)。
    ///     本数が 2 以上ならインターリーブ（frame * lanes + lane）。0 は 1 として扱う。
    /// - Returns: 書いた値のピーク（NaN は拾わない）。
    ///
    /// バッファは前から順にチャンネルを受け持つ。行の数より口が多ければ残りは 0、
    /// 口が少なければ余った行は書かない（ミキサーが受け持つ）。
    /// **先頭が nil のバッファは飛ばし、チャンネルも消費しない。**
    static func writeOutput(planar: UnsafePointer<Float>, frames: Int, channels: Int,
                            frameCount: Int, bufferCount: Int,
                            buffer: (Int) -> (data: UnsafeMutablePointer<Float>?, lanes: Int)) -> Float {
        guard frameCount > 0, bufferCount > 0 else { return 0 }
        var peak: Float = 0
        var sourceChannel = 0
        for k in 0..<bufferCount {
            let slot = buffer(k)
            guard let data = slot.data else { continue }
            let lanes = max(1, slot.lanes)
            for i in 0..<frameCount {
                for lane in 0..<lanes {
                    let value: Float
                    if i < frames, sourceChannel + lane < channels {
                        value = planar[(sourceChannel + lane) * frames + i]
                        peak = max(peak, abs(value))
                    } else {
                        value = 0
                    }
                    data[i * lanes + lane] = value
                }
            }
            sourceChannel += lanes
        }
        return peak
    }

    // MARK: - Audio Unit との受け渡し

    /// プレーナ（行の幅 = frames）を、行の幅が `stride` のプレーナと、
    /// インターリーブ（frame * channels + channel）の両方へ写す。
    /// AU がどちらの形で入力を引いても渡せるようにするため（ETAUExternalBridge）。
    static func stage(_ planar: UnsafePointer<Float>, frames: Int, channels: Int,
                      planarOut: UnsafeMutablePointer<Float>, stride: Int,
                      interleavedOut: UnsafeMutablePointer<Float>) {
        guard frames > 0, channels > 0 else { return }
        for frame in 0..<frames {
            for channel in 0..<channels {
                let value = planar[channel * frames + frame]
                planarOut[channel * stride + frame] = value
                interleavedOut[frame * channels + channel] = value
            }
        }
    }

    /// インターリーブ（frame * channels + channel）をプレーナ（行の幅 = frames）へ戻す。
    static func deinterleave(_ interleaved: UnsafePointer<Float>, frames: Int, channels: Int,
                             into planar: UnsafeMutablePointer<Float>) {
        guard frames > 0, channels > 0 else { return }
        for frame in 0..<frames {
            for channel in 0..<channels {
                planar[channel * frames + frame] = interleaved[frame * channels + channel]
            }
        }
    }

    // MARK: - 素通しの遅延の輪

    // 素通しのとき 96/192kHz へ上げて下げる往復を飛ばすための部品（AudioIO の render）。
    // 往復は高域を少し削って ETResampler_LatencySamples だけ遅らせる。
    // 遅れだけを輪で真似れば、入切のたびに音が時間方向へ飛ばない。
    // 輪の長さは 2 の冪（マスクで回す）。行は channel * length から始まる。

    /// `frames` 分のプレーナ（行の幅 = frames）を輪へ流し込む。返すのは次の書き込み位置。
    /// 素通しでまだ輪が温まっていないブロックが、往復を通しつつ最近の乾いた音を貯めるのに使う。
    static func feedRing(_ planar: UnsafePointer<Float>, frames: Int, channels: Int,
                         ring: UnsafeMutablePointer<Float>, length: Int, position: Int) -> Int {
        guard frames > 0, channels > 0, length > 0 else { return position }
        let mask = length - 1
        for c in 0..<channels {
            let row = ring + c * length
            let src = planar + c * frames
            for i in 0..<frames { row[(position + i) & mask] = src[i] }
        }
        return (position + frames) & mask
    }

    /// プレーナをその場で `delay` サンプル遅らせる。1 サンプルずつ「入れてから、delay 前を読む」。
    /// delay が length より小さければ、frames が length を超えても同じ結果になる。
    /// 履歴は輪の中身で、最初は 0。返すのは次の書き込み位置。
    static func delayThrough(_ planar: UnsafeMutablePointer<Float>, frames: Int, channels: Int,
                             ring: UnsafeMutablePointer<Float>, length: Int, position: Int,
                             delay: Int) -> Int {
        guard frames > 0, channels > 0, length > 0, delay >= 0, delay < length else { return position }
        let mask = length - 1
        for c in 0..<channels {
            let row = ring + c * length
            let dst = planar + c * frames
            for i in 0..<frames {
                let x = dst[i]
                row[(position + i) & mask] = x
                dst[i] = row[(position + i - delay) & mask]
            }
        }
        return (position + frames) & mask
    }

    /// 輪を古い方から新しい方へ並べ直す。出力は行の幅が length のプレーナ。
    /// 素通しをやめるとき、リサンプラの履歴を「ずっと通していた」ときと同じにするために使う。
    static func unrollRing(_ ring: UnsafePointer<Float>, length: Int, channels: Int, position: Int,
                           into out: UnsafeMutablePointer<Float>) {
        guard channels > 0, length > 0 else { return }
        let mask = length - 1
        for c in 0..<channels {
            let row = ring + c * length
            let dst = out + c * length
            for i in 0..<length { dst[i] = row[(position + i) & mask] }
        }
    }

    // MARK: - 負荷

    /// 1 ブロックの負荷（使った時間 / 使える時間）を 1 次の平滑で溜める。係数 0.1。
    /// 使える時間が 0 のブロックで割り算が飛ばないよう、下を 1ns で押さえる。
    static func smoothedLoad(_ previous: Double, spent: Double, budget: Double) -> Double {
        previous + (spent / max(budget, 1e-9) - previous) * 0.1
    }
}
