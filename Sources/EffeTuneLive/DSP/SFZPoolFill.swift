//  SFZPoolFill.swift
//  SFZ・SoundFont の PCM を、カーネルの staging へ直に書く（資産の末尾の「プール」）。
//  **Foundation だけ。**Linux でも走る（SFZPoolFillTests）。
//
//  上流の js/sfz/asset.js の packSfzAsset は、最後に標本の道ごとに
//      for frame … for channel … { if (!Number.isFinite(value)) throw …; packed[cursor++] = value }
//  と float を 1 つずつ書く。EffectDeck は JavaScriptCore 越しにこれを走らせず、パッチ
//  （Patches/effetune-js-sfz-pool-writer.diff）で globalThis.__effectdeckSfzPoolWriter があればそれを呼ぶ。
//  呼び先がここ。JS には PCM の本体を持たせず、ホストが持つ面（チャンネルごとの float）を
//  フレームごとにチャンネルを交互に並べて staging へ写す。
//
//  floatOffset は上流の `packed`（外側の 32 バイトの後ろから数える Float32Array）の添字。
//  staging の先頭は外側の 32 バイトで、payload をそのまま写した形なので、書く場所は 32 + 4 × floatOffset バイト目。
//  非有限（NaN・±inf）の値が 1 つでもあれば上流と同じ文で止める。

import Foundation

struct ETSFZPoolFill {

    /// 上流の文（js/sfz/asset.js）。
    static let invalidSamplesMessage = "SFZ audio contains invalid samples."
    /// 書く先が payload の外へ出るとき。上流の effect-cost.js の文に寄せた（JS 側の payload と食い違った印）。
    static let invalidPayloadMessage = "The instrument preparation data is invalid."
    /// 外側の 32 バイト（payload の頭。floatOffset の数え始めはこの後ろ）。
    static let outerHeaderBytes = 32

    /// 書き込み先。payload 全体（外側の 32 バイトから）の大きさで持つ。
    let staging: UnsafeMutableRawBufferPointer

    init(staging: UnsafeMutableRawBufferPointer) {
        self.staging = staging
    }

    /// 1 本の標本を書く。planes は面ごとの float（長さは frames 以上）。
    /// 面が足りない（frames に届かない）ものは、上流では channel[frame] が undefined で非有限になるのと同じく止める。
    func write(floatOffset: Int, frames: Int, planes: [UnsafeBufferPointer<Float>]) throws {
        guard floatOffset >= 0, frames >= 0 else { throw ETSFZError.prepare(Self.invalidPayloadMessage) }
        let channels = planes.count
        if frames == 0 || channels == 0 { return }
        let (words, overflowWords) = frames.multipliedReportingOverflow(by: channels)
        let (end, overflowEnd) = floatOffset.addingReportingOverflow(words)
        let (bytes, overflowBytes) = end.multipliedReportingOverflow(by: MemoryLayout<Float>.stride)
        guard !overflowWords, !overflowEnd, !overflowBytes,
              bytes <= staging.count - Self.outerHeaderBytes,
              let base = staging.baseAddress,
              Int(bitPattern: base) % MemoryLayout<Float>.alignment == 0
        else { throw ETSFZError.prepare(Self.invalidPayloadMessage) }
        for plane in planes where plane.count < frames {
            throw ETSFZError.prepare(Self.invalidSamplesMessage)
        }
        let pool = (base + Self.outerHeaderBytes).assumingMemoryBound(to: Float.self) + floatOffset
        if channels == 1 {
            // mono はそのまま並ぶ。
            let source = planes[0]
            for frame in 0..<frames {
                let value = source[frame]
                guard value.isFinite else { throw ETSFZError.prepare(Self.invalidSamplesMessage) }
                pool[frame] = value
            }
            return
        }
        for (channel, plane) in planes.enumerated() {
            var cursor = channel
            for frame in 0..<frames {
                let value = plane[frame]
                guard value.isFinite else { throw ETSFZError.prepare(Self.invalidSamplesMessage) }
                pool[cursor] = value
                cursor += channels
            }
        }
    }

    /// 配列の面から書く。
    func write(floatOffset: Int, frames: Int, planes: [[Float]]) throws {
        try Self.withBuffers(planes) { try write(floatOffset: floatOffset, frames: frames, planes: $0) }
    }

    /// 面の配列を、ポインタの束に直して body へ渡す（面の数だけ入れ子にする）。
    static func withBuffers<R>(_ planes: [[Float]], _ body: ([UnsafeBufferPointer<Float>]) throws -> R) throws -> R {
        func step(_ index: Int, _ acc: [UnsafeBufferPointer<Float>]) throws -> R {
            if index == planes.count { return try body(acc) }
            return try planes[index].withUnsafeBufferPointer { try step(index + 1, acc + [$0]) }
        }
        return try step(0, [])
    }
}
