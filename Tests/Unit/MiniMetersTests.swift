//  MiniMetersTests.swift
//  PiP の帯（Views/MiniMeters.swift）の絵。**見た目は変えない**ので、器へ写す道（direct: true）と
//  全部 CoreGraphics で描く道（direct: false）が同じピクセルになることを、フレームを重ねて照らす。
//  器は PiPVisualizer.pixelBuffer と同じ作り（deviceRGB・premultipliedFirst + little endian・上を 0 に反転）。
//  **写す道に入れなかったとき（器の形が違うとき）に黙って遅くなる**ので、そのことも戻り値で見張る。

import CoreGraphics
import QuartzCore
import XCTest

@MainActor
final class MiniMetersTests: XCTestCase {

    // MARK: 器

    /// メモリに作る BGRA の器。PiP のプールの器と同じく、最初は前の絵（ここでは 0xA5）が残っている。
    private final class Canvas {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let data: UnsafeMutableRawPointer
        let context: CGContext

        init(layout: ETMiniMeters.Layout, padding: Int = 0, flipped: Bool = true,
             byteOrder: CGBitmapInfo = .byteOrder32Little) {
            let rowBytes = layout.width * 4 + padding
            let memory = UnsafeMutableRawPointer.allocate(byteCount: rowBytes * layout.height, alignment: 16)
            memset(memory, 0xA5, rowBytes * layout.height)
            let info = CGImageAlphaInfo.premultipliedFirst.rawValue | byteOrder.rawValue
            guard let made = CGContext(data: memory, width: layout.width, height: layout.height,
                                       bitsPerComponent: 8, bytesPerRow: rowBytes,
                                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else {
                fatalError("CGContext が作れない")
            }
            if flipped {
                made.translateBy(x: 0, y: CGFloat(layout.height))
                made.scaleBy(x: 1, y: -1)
            }
            width = layout.width
            height = layout.height
            bytesPerRow = rowBytes
            data = memory
            context = made
        }

        deinit { data.deallocate() }

        func pixel(x: Int, y: Int) -> UInt32 {
            data.load(fromByteOffset: y * bytesPerRow + x * 4, as: UInt32.self)
        }

        func bytes(x: Int, y: Int) -> [UInt8] {
            let p = data + (y * bytesPerRow + x * 4)
            return (0..<4).map { p.load(fromByteOffset: $0, as: UInt8.self) }
        }

        /// 行の詰め物は見ない。最初に食い違う画素。
        func firstDifference(from other: Canvas) -> (x: Int, y: Int)? {
            for y in 0..<height {
                if memcmp(data + y * bytesPerRow, other.data + y * other.bytesPerRow, width * 4) == 0 { continue }
                for x in 0..<width where pixel(x: x, y: y) != other.pixel(x: x, y: y) {
                    return (x, y)
                }
            }
            return nil
        }

        func distinctPixelCount() -> Int {
            var seen = Set<UInt32>()
            for y in 0..<height {
                for x in 0..<width { seen.insert(pixel(x: x, y: y)) }
            }
            return seen.count
        }
    }

    // MARK: 音

    /// 100Hz・1kHz・8kHz を重ね、右は 1kHz を逆相・高域を小さくする。
    /// 波形の 3 色・ステレオの点の広がり・スペクトログラムの変化・レベルと LUFS が全部動く。
    private struct Signal {
        private var index = 0

        /// 音の輪へプレーナ（左が frames 個、その後に右）で書く。
        mutating func write(frames: Int) {
            var planar = [Float](repeating: 0, count: 2 * frames)
            for i in 0..<frames {
                let t = Double(index + i) / 48000
                let swell = 0.35 + 0.65 * abs(sin(2 * Double.pi * 2 * t))
                let low = 0.4 * sin(2 * Double.pi * 100 * t)
                let mid = 0.25 * sin(2 * Double.pi * 1000 * t)
                let high = 0.15 * sin(2 * Double.pi * 8000 * t)
                planar[i] = Float(swell * (low + mid + high))
                planar[frames + i] = Float(swell * (low - mid + 0.5 * high))
            }
            planar.withUnsafeBufferPointer {
                ETMeterTap_Write(Int32(ET_METER_TAP_OUTPUT), $0.baseAddress, 2, UInt32(frames))
            }
            index += frames
        }
    }

    /// 音の輪の出口を写す向きにして、今から読み始める帯を作る。
    private func makeMeters() -> ETMiniMeters {
        ETMeterTap_SetPoint(Int32(ET_METER_TAP_OUTPUT))
        let meters = ETMiniMeters()
        meters.reset()
        return meters
    }

    private func stopTap() { ETMeterTap_SetPoint(Int32(ET_METER_TAP_OFF)) }

    // MARK: 写す道と描く道

    private func assertCopyMatchesDirectDraw(fastPadding: Int, referencePadding: Int,
                                             file: StaticString = #filePath, line: UInt = #line) {
        let meters = makeMeters()
        defer { stopTap() }
        // 器は毎回使い回す（プールと同じ。前のフレームの絵が残っていても全部書き直すこと）。
        let fast = Canvas(layout: meters.layout, padding: fastPadding)
        let reference = Canvas(layout: meters.layout, padding: referencePadding)
        var signal = Signal()
        var now = CACurrentMediaTime()
        // スペクトログラムは 1 回に 2 列ずつ左へ送る。300 列を一周以上するまで重ねる。
        for frame in 0..<170 {
            signal.write(frames: 1600)
            now += 1.0 / 30
            meters.pull(rate: 48000, now: now)
            let copied = meters.draw(in: fast.context, direct: true)
            let direct = meters.draw(in: reference.context, direct: false)
            XCTAssertTrue(copied, "frame \(frame): PiP の器で写す道を通らなかった（黙って遅くなる）",
                          file: file, line: line)
            XCTAssertFalse(direct, "direct: false は写す道を通らない", file: file, line: line)
            if let diff = fast.firstDifference(from: reference) {
                XCTFail("frame \(frame): 写す道と描く道が (\(diff.x), \(diff.y)) で違う "
                        + "\(String(fast.pixel(x: diff.x, y: diff.y), radix: 16)) / "
                        + "\(String(reference.pixel(x: diff.x, y: diff.y), radix: 16))",
                        file: file, line: line)
                return
            }
        }
        // 全部同じ色の絵どうしを比べて通ってしまわないように、絵が出ていることも見る。
        XCTAssertGreaterThan(reference.distinctPixelCount(), 50, file: file, line: line)
    }

    func testCopyPathMatchesDirectDraw() {
        assertCopyMatchesDirectDraw(fastPadding: 0, referencePadding: 0)
    }

    /// 器の行に詰め物がある（CVPixelBuffer は 64 バイトなどに揃える）。行の長さは器のものを使う。
    func testCopyPathHonoursPaddedRows() {
        assertCopyMatchesDirectDraw(fastPadding: 64, referencePadding: 32)
    }

    // MARK: 想定の形でない器

    /// 写す道に入らなくても全部描く道で同じ絵が出る。確かめる画素はステレオ区画の隅
    /// （点も格子も届かないので背景の黒のまま）。
    private func assertFallsBackAndRenders(_ canvas: Canvas, expectedBlack: [UInt8],
                                           file: StaticString = #filePath, line: UInt = #line) {
        let meters = makeMeters()
        defer { stopTap() }
        var signal = Signal()
        var now = CACurrentMediaTime()
        for _ in 0..<5 {
            signal.write(frames: 1600)
            now += 1.0 / 30
            meters.pull(rate: 48000, now: now)
        }
        let copied = meters.draw(in: canvas.context)
        XCTAssertFalse(copied, "想定の形でない器で写す道を通った", file: file, line: line)
        let stereo = meters.layout.stereo
        XCTAssertEqual(canvas.bytes(x: Int(stereo.minX) + 1, y: 1), expectedBlack,
                       "全部描く道に落ちても背景は描く", file: file, line: line)
        XCTAssertGreaterThan(canvas.distinctPixelCount(), 50, file: file, line: line)
    }

    func testUnflippedContextFallsBackAndStillRenders() {
        let canvas = Canvas(layout: ETMiniMeters.Layout.strip, flipped: false)
        assertFallsBackAndRenders(canvas, expectedBlack: [0, 0, 0, 0xFF])
    }

    func testBigEndianContextFallsBackAndStillRenders() {
        let canvas = Canvas(layout: ETMiniMeters.Layout.strip, byteOrder: .byteOrder32Big)
        assertFallsBackAndRenders(canvas, expectedBlack: [0xFF, 0, 0, 0])
    }
}
