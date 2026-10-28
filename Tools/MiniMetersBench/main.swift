// MiniMeters の 1 コマの重さを、本番と同じ道筋で測る。
// 使い方は README.md。ビルドと実行は run.sh / build.sh が組む。
//
//   bench <出力tsv> [--rounds N] [--block N] [--discard N] [--warm N] [--songs ディレクトリ] [--canvas plain|cv]
//
// 測るもの（1 コマ = 本番の tick と同じ順）:
//   ETMeterTap_Write（1/30 秒ぶん）→ pull(rate:now:)（時間を計る）→ draw(in:)（時間を計る）
// -DSEAM でビルドした版（build.sh が作る。MiniMeters.swift の private を外した写し）は、
// 同じコマをもう 1 度区画ごとに分けて計る。**分けた版の合計は draw の全体と突き合わせる**（report.py）。

import AVFoundation
import CoreGraphics
import CoreVideo
import Darwin
import Foundation

// MARK: - 時計と数え方

@inline(__always) func nowNS() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
@inline(__always) func ms(_ a: UInt64, _ b: UInt64) -> Double { Double(b &- a) / 1e6 }

struct Series {
    var values: [Double] = []
    mutating func add(_ v: Double) { values.append(v) }
}

// MARK: - 器（PiPVisualizer.pixelBuffer と同じ形）

let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

/// 上を 0 にする反転まで本番と同じ。
func flip(_ c: CGContext, _ h: Int) {
    c.translateBy(x: 0, y: CGFloat(h))
    c.scaleBy(x: 1, y: -1)
}

/// plain は CGContext が自分で持つメモリ（mmpreview-ab と同じ）。
/// cv は本番と同じ IOSurface 付きの CVPixelBuffer を 3 枚まわす（毎コマ別のメモリに描く）。
final class Canvas {
    private var contexts: [CGContext] = []
    private var buffers: [CVPixelBuffer] = []
    private var index = 0

    init(kind: String, width: Int, height: Int) {
        if kind == "cv" {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
            var kept: [CVPixelBuffer] = []
            for _ in 0..<3 {
                var buffer: CVPixelBuffer?
                guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
                      let buffer else { fatalError("CVPixelBuffer を作れない") }
                // 測っている間は固定する（本番は毎コマ固定→解除するが、その分は draw の外）。
                CVPixelBufferLockBaseAddress(buffer, [])
                kept.append(buffer)
                let c = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo)!
                flip(c, height)
                contexts.append(c)
            }
            buffers = kept
        } else {
            let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo)!
            flip(c, height)
            contexts = [c]
        }
    }

    func next() -> CGContext {
        index = (index + 1) % contexts.count
        return contexts[index]
    }
}

// MARK: - 音

struct Rng {
    var s: UInt64
    mutating func next() -> Float {   // -1...1
        s = s &* 6364136223846793005 &+ 1442695040888963407
        // 上位 32 ビットを符号つきで読む（>> 33 だと 0...1 になり、雑音に直流が乗ってピンクノイズが張り付く）。
        return Float(Int32(truncatingIfNeeded: s >> 32)) / Float(Int32.max)
    }
}

/// 1/30 秒ぶんを planar（ch0 が n 個、続けて ch1）に埋める。戻り値は埋めた数（0 なら終わり）。
typealias Fill = (_ n: Int, _ planar: inout [Float]) -> Int

struct Source {
    let name: String
    let rate: Double
    let fill: Fill
}

/// 対数スイープ 20Hz→20kHz を 10 秒で繰り返す（左右同じ）。
func sweepSource() -> Source {
    var phase = 0.0, t = 0
    return Source(name: "sweep", rate: 48000, fill: { n, p in
        for i in 0..<n {
            let x = Double((t + i) % 480000) / 480000
            phase += 2 * .pi * 20 * pow(1000, x) / 48000
            let v = 0.5 * Float(sin(phase))
            p[i] = v; p[n + i] = v
        }
        phase = phase.truncatingRemainder(dividingBy: 2 * .pi)
        t += n
        return n
    })
}

/// ピンクノイズ（Paul Kellet の近似）。左右同じ。
func pinkSource() -> Source {
    var rng = Rng(s: 3)
    var b0: Float = 0, b1: Float = 0, b2: Float = 0, b3: Float = 0, b4: Float = 0, b5: Float = 0, b6: Float = 0
    return Source(name: "pink", rate: 48000, fill: { n, p in
        for i in 0..<n {
            let w = rng.next()
            b0 = 0.99886 * b0 + w * 0.0555179; b1 = 0.99332 * b1 + w * 0.0750759
            b2 = 0.96900 * b2 + w * 0.1538520; b3 = 0.86650 * b3 + w * 0.3104856
            b4 = 0.55000 * b4 + w * 0.5329522; b5 = -0.7616 * b5 - w * 0.0168980
            let v = 0.12 * (b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362)
            b6 = w * 0.115926
            p[i] = v; p[n + i] = v
        }
        return n
    })
}

/// 回るステレオ: 同じ音程の右の位相を 0.25Hz で回し、ステレオの絵をぐるぐる動かす。
func rotatingSource() -> Source {
    var t = 0
    return Source(name: "rotating", rate: 48000, fill: { n, p in
        for i in 0..<n {
            let x = Double(t + i) / 48000
            let phi = 2 * .pi * 0.25 * x
            p[i] = 0.5 * Float(sin(2 * .pi * 330 * x)) + 0.2 * Float(sin(2 * .pi * 1200 * x))
            p[n + i] = 0.5 * Float(sin(2 * .pi * 330 * x + phi)) + 0.2 * Float(sin(2 * .pi * 1200 * x + 0.5 * phi))
        }
        t += n
        return n
    })
}

/// クリック: 0.25 秒ごとの減衰する 3kHz（右は少し小さい）。間は -90dBFS くらいの雑音。
func clicksSource() -> Source {
    var rng = Rng(s: 5)
    var t = 0
    return Source(name: "clicks", rate: 48000, fill: { n, p in
        for i in 0..<n {
            let j = (t + i) % 12000
            var l = 3e-5 * rng.next(), r = 3e-5 * rng.next()
            if j < 480 {
                let e = 0.9 * Float(exp(-Double(j) / 60) * cos(2 * .pi * 3000 * Double(j) / 48000))
                l += e; r += 0.7 * e
            }
            p[i] = l; p[n + i] = r
        }
        t += n
        return n
    })
}

/// 近い無音: -90dBFS くらいの雑音。
func silenceSource() -> Source {
    var rng = Rng(s: 1)
    return Source(name: "silence", rate: 48000, fill: { n, p in
        for i in 0..<n { p[i] = 3e-5 * rng.next(); p[n + i] = 3e-5 * rng.next() }
        return n
    })
}

/// 広いステレオ: 左右で別の音程の正弦波と、無相関の雑音（mmpreview-ab の synth_wide と同じ）。
func wideSource() -> Source {
    var rng = Rng(s: 7)
    var t = 0
    return Source(name: "wide", rate: 48000, fill: { n, p in
        for i in 0..<n {
            let x = Double(t + i) / 48000
            p[i] = 0.45 * Float(sin(2 * .pi * 220 * x)) + 0.25 * rng.next()
            p[n + i] = 0.45 * Float(sin(2 * .pi * 331 * x + 1)) + 0.25 * rng.next()
        }
        t += n
        return n
    })
}

func fileSeconds(_ path: String) -> Double? {
    guard let f = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
    return Double(f.length) / f.processingFormat.sampleRate
}

/// 曲は先に必要なぶんを全部読んでおく（測っている間に mp3 を復号すると、キャッシュを荒らして時間も延びる）。
func fileSource(name: String, path: String, start: Double, seconds: Double) -> Source {
    let file = try! AVAudioFile(forReading: URL(fileURLWithPath: path))
    let sr = file.processingFormat.sampleRate
    file.framePosition = AVAudioFramePosition(start * sr)
    let total = Int(seconds * sr)
    var left = [Float](), right = [Float]()
    left.reserveCapacity(total); right.reserveCapacity(total)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1 << 15)!
    while left.count < total {
        do { try file.read(into: buffer, frameCount: min(1 << 15, AVAudioFrameCount(total - left.count))) } catch { break }
        let n = Int(buffer.frameLength)
        guard n > 0, let data = buffer.floatChannelData else { break }
        let channels = Int(buffer.format.channelCount)
        left.append(contentsOf: UnsafeBufferPointer(start: data[0], count: n))
        right.append(contentsOf: UnsafeBufferPointer(start: data[min(1, channels - 1)], count: n))
    }
    var position = 0
    return Source(name: name, rate: sr, fill: { chunk, planar in
        let n = min(chunk, left.count - position)
        guard n > 0 else { return 0 }
        // 短く終わったら ch1 は n 個の位置から始まる（ETMeterTap_Write にも n を渡す）。
        for i in 0..<n { planar[i] = left[position + i]; planar[n + i] = right[position + i] }
        position += n
        return n
    })
}

// MARK: - 1 つの音の流れ

/// 1 つの音源に 1 つの ETMiniMeters・時計・結果を持たせ、ブロックごとに順に回す。
@MainActor
final class Track {
    let source: Source
    let meters = ETMiniMeters()
    let chunk: Int
    var planar: [Float]
    var now = 1000.0
    var series: [String: Series] = [:]
    var frameIndex = 0   // 区画の順番を 1 コマおきに入れ替える

    init(_ source: Source) {
        self.source = source
        chunk = Int(source.rate / 30)
        planar = [Float](repeating: 0, count: chunk * 2)
    }

    /// 他の音源がリングを使ったあとに入るので、読み始めを今にする（前の音を読まない）。
    func enter() { meters.reset() }

    /// 1 コマ。`record` が false なら時間を残さない（温め）。戻り値は音が続いたか。
    func frame(canvas: Canvas, record: Bool) -> Bool {
        let n = source.fill(chunk, &planar)
        guard n > 0 else { return false }
        ETMeterTap_Write(1, planar, 2, UInt32(n))
        now += 1.0 / 30

        let t0 = nowNS()
        meters.pull(rate: source.rate, now: now)
        let t1 = nowNS()

        let context = canvas.next()
        #if SEAM
        // 全体の draw と、区画に分けた draw を 1 コマおきに順を入れ替えて計る（先に走るほうが冷たいため）。
        var total = 0.0, parts: [String: Double] = [:]
        if frameIndex % 2 == 0 {
            total = timedDraw(context); parts = timedParts(context)
        } else {
            parts = timedParts(context); total = timedDraw(context)
        }
        let ta = nowNS()
        meters.advanceSpectrogram()   // pull の中で 1 度走るものを単独で計る（状態は 2 列余計に進む）
        let tb = nowNS()
        #else
        let t2 = nowNS()
        let copied = meters.draw(in: context)
        let t3 = nowNS()
        guard copied else { fatalError("写す道を通らなかった（本番と違う遅さになる）") }
        let total = ms(t2, t3)
        #endif
        frameIndex += 1

        if record {
            series["pull", default: Series()].add(ms(t0, t1))
            series["draw_total", default: Series()].add(total)
            series["frame", default: Series()].add(ms(t0, t1) + total)
            #if SEAM
            for (k, v) in parts { series[k, default: Series()].add(v) }
            series["sec_sum", default: Series()].add(
                (parts["sec_copy"] ?? 0) + (parts["sec_waveform"] ?? 0) + (parts["sec_spectrum"] ?? 0)
                + (parts["sec_stereo"] ?? 0) + (parts["sec_levels"] ?? 0))
            series["pull_advance", default: Series()].add(ms(ta, tb))
            #endif
        }
        return true
    }

    #if SEAM
    func timedDraw(_ context: CGContext) -> Double {
        let a = nowNS()
        let copied = meters.draw(in: context)
        let b = nowNS()
        guard copied else { fatalError("写す道を通らなかった（本番と違う遅さになる）") }
        return ms(a, b)
    }

    /// draw(in:) の中身を同じ順で 1 つずつ計る。copyBackdrop は背景＋スペクトログラムを写す部分。
    func timedParts(_ context: CGContext) -> [String: Double] {
        let m = meters, l = m.layout
        var out: [String: Double] = [:]
        var a = nowNS(), b = a

        a = nowNS(); _ = m.copyBackdrop(into: context); b = nowNS()
        out["sec_copy"] = ms(a, b)
        a = nowNS(); m.drawWaveform(context, l.waveform); b = nowNS()
        out["sec_waveform"] = ms(a, b)
        a = nowNS(); m.drawSpectrum(context, l.spectrum); b = nowNS()
        out["sec_spectrum"] = ms(a, b)
        a = nowNS(); m.drawStereo(context, l.stereo); b = nowNS()
        out["sec_stereo"] = ms(a, b)
        a = nowNS(); m.drawLevels(context, l.level); b = nowNS()
        out["sec_levels"] = ms(a, b)

        // copyBackdrop の中の 2 つの写しを、同じ書き方で別に計る（検査の外側 = 差が guard の分）。
        // 器は上で描かれたあとだが、同じ値で上書きするだけなので結果は変わらない。
        let dstRow = context.bytesPerRow
        if let base = context.data, let made = m.backdrop, let from = made.data {
            let srcRow = made.bytesPerRow
            a = nowNS()
            for y in 0..<l.height { memcpy(base + y * dstRow, from + y * srcRow, l.width * 4) }
            b = nowNS()
            out["sec_copy_backdrop"] = ms(a, b)
            let x0 = Int(l.spectrogram.minX), y0 = Int(l.spectrogram.minY)
            let width = m.spectrogramWidth, height = m.spectrogramHeight
            a = nowNS()
            m.spectrogram.withUnsafeBytes { px in
                for y in 0..<height {
                    memcpy(base + (y0 + y) * dstRow + x0 * 4, px.baseAddress! + y * width * 4, width * 4)
                }
            }
            b = nowNS()
            out["sec_copy_spectrogram"] = ms(a, b)
        }
        return out
    }
    #endif
}

// MARK: - 本体

func percentile(_ sorted: [Double], _ p: Double) -> Double {
    let rank = Int((p * Double(sorted.count)).rounded(.up))
    return sorted[min(sorted.count - 1, max(0, rank - 1))]
}

func argValue(_ name: String, _ args: [String], _ fallback: String) -> String {
    if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }
    return fallback
}

MainActor.assumeIsolated {
    let args = CommandLine.arguments
    guard args.count >= 2 else { print("usage: bench <out.tsv> [options]"); exit(2) }
    let outPath = args[1]
    let rounds = Int(argValue("--rounds", args, "22"))!
    let block = Int(argValue("--block", args, "30"))!       // 1 度に回すコマ数（1 秒ぶん）
    let discard = Int(argValue("--discard", args, "2"))!    // ブロックの頭は切り替えで冷えているので捨てる
    let warm = Int(argValue("--warm", args, "180"))!        // 300 列のスペクトログラムが埋まるのは 150 コマ
    let songDir = argValue("--songs", args, NSHomeDirectory() + "/work/mmpreview")
    let canvasKind = argValue("--canvas", args, "plain")

    // 本番の描画は main（user interactive）。コマンドラインのまま走ると効率コアに寄ることがある。
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
    ETMeterTap_SetPoint(1)

    var sources: [Source] = [sweepSource(), pinkSource(), rotatingSource(), clicksSource(), silenceSource(), wideSource()]
    let needSeconds = Double(warm + rounds * block) / 30 + 2
    var skipped: [String] = []
    for song in ["demo", "vibe"] {
        let path = "\(songDir)/\(song).mp3"
        guard let len = fileSeconds(path) else { skipped.append(song); continue }
        for (tag, f) in [("a", 0.1), ("b", 0.5), ("c", 0.9)] {
            let start = max(0, (len - needSeconds) * f)
            sources.append(fileSource(name: "\(song)_\(tag)\(Int(start.rounded()))s", path: path, start: start, seconds: needSeconds))
        }
    }
    for s in skipped { FileHandle.standardError.write(Data("曲が無いので飛ばす: \(s).mp3\n".utf8)) }

    let layout = ETMiniMeters.Layout.strip
    let canvas = Canvas(kind: canvasKind, width: layout.width, height: layout.height)
    let tracks = sources.map { Track($0) }

    // 温め: 音源ごとに続けて回す（時間は残さない）。
    for t in tracks {
        t.enter()
        for _ in 0..<warm { if !t.frame(canvas: canvas, record: false) { fatalError("\(t.source.name): 音が足りない") } }
    }
    // 本番: 音源をブロックごとに順番に回す（時間の流れによるずれを全部の音源に均す）。
    for _ in 0..<rounds {
        for t in tracks {
            t.enter()
            for i in 0..<block {
                if !t.frame(canvas: canvas, record: i >= discard) { fatalError("\(t.source.name): 音が足りない") }
            }
        }
    }

    var tsv = "signal\tmetric\tn\tmedian_ms\tp95_ms\tmean_ms\tmin_ms\tmax_ms\n"
    for t in tracks {
        for key in t.series.keys.sorted() {
            let v = t.series[key]!.values.sorted()
            let mean = v.reduce(0, +) / Double(v.count)
            tsv += String(format: "%@\t%@\t%d\t%.5f\t%.5f\t%.5f\t%.5f\t%.5f\n", t.source.name, key, v.count,
                          percentile(v, 0.5), percentile(v, 0.95), mean, v.first!, v.last!)
        }
    }
    try! tsv.write(toFile: outPath, atomically: true, encoding: .utf8)
    print("wrote \(outPath)  signals=\(tracks.count) canvas=\(canvasKind) frames/signal=\(rounds * (block - discard))")
}
