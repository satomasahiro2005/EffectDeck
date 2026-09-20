//  JSFXAudioTests.swift
//  音そのものと、descriptor の約束。設計 §5（A01-A03 / 境界）と §6。
//
//  **bit-exact では比べない。**ysfx は @sample へ渡す前に 1e-16 を足す
//  （ysfx.cpp の denorm_value）。0 が 0 で出てこないのは仕様なので、
//  accuracy 付きで比べる。1e-6 は float の分解能から見て十分に厳しい。
//
//  つまみの綴りと番号の関係に注意。JSFX の `slider1` は index 0。
//  ETJSFX_SetSlider が取るのは index なので、この差でずれると
//  「効かないつまみ」になる。

import XCTest

final class JSFXAudioTests: XCTestCase {

    private let frames = JSFX.maxFrames

    /// §6。descriptor は外へ出す唯一の口なので、欠けている項目が無いか見る。
    func testProcessorDescriptorContract() throws {
        let host = try JSFX.load("passthrough")
        let descriptor = host.processor
        XCTAssertNotNil(descriptor.context)
        XCTAssertNotNil(descriptor.process)
        XCTAssertNotNil(descriptor.reset)
        XCTAssertNotNil(descriptor.latency)
        XCTAssertNotNil(descriptor.tailTime)
        // **destroy は持たせない。**持たせると、橋が外すときに host を道連れにする。
        // 寿命は ETJSFXHost.swift 側が持っている。
        XCTAssertNil(descriptor.destroy)
        XCTAssertEqual(descriptor.maxFrames, JSFX.maxFrames)
        // ysfx_max_channels。UI にも橋にも直書きしないための出口。
        XCTAssertEqual(descriptor.maxChannels, 64)
        XCTAssertEqual(descriptor.tailTime!(descriptor.context), .infinity)
    }

    /// A01。
    func testPassthroughReturnsTheInput() throws {
        let host = try JSFX.load("passthrough")
        let input = JSFX.signal(channels: 2, frames: frames)
        var planar = input
        XCTAssertEqual(host.process(&planar, channels: 2, frames: frames), 0)
        for (index, value) in planar.enumerated() {
            XCTAssertEqual(value, input[index], accuracy: 1e-6, "sample \(index)")
        }
    }

    /// A02。slider1（index 0）が @slider を通って @sample へ届く。
    /// **つまみを書いた同じブロックで効く**（applySliders → notify → @slider）。
    func testGainScalesBySlider() throws {
        let host = try JSFX.load("gain")
        let input = JSFX.signal(channels: 2, frames: frames)

        var planar = input
        XCTAssertEqual(host.process(&planar, channels: 2, frames: frames), 0)
        for (index, value) in planar.enumerated() {
            XCTAssertEqual(value, input[index], accuracy: 1e-6, "初期値 1.0: sample \(index)")
        }

        host.set(0, 0.5)
        planar = input
        XCTAssertEqual(host.process(&planar, channels: 2, frames: frames), 0)
        for (index, value) in planar.enumerated() {
            XCTAssertEqual(value, input[index] * 0.5, accuracy: 1e-6, "0.5: sample \(index)")
        }

        host.set(0, 0)
        planar = input
        XCTAssertEqual(host.process(&planar, channels: 2, frames: frames), 0)
        for (index, value) in planar.enumerated() {
            XCTAssertEqual(value, 0, accuracy: 1e-6, "0.0: sample \(index)")
        }
    }

    /// A03。
    func testStereoSwapExchangesChannels() throws {
        let host = try JSFX.load("swap")
        let input = JSFX.signal(channels: 2, frames: frames)
        var planar = input
        XCTAssertEqual(host.process(&planar, channels: 2, frames: frames), 0)

        let left = JSFX.channel(0, of: planar, frames: frames)
        let right = JSFX.channel(1, of: planar, frames: frames)
        let inLeft = JSFX.channel(0, of: input, frames: frames)
        let inRight = JSFX.channel(1, of: input, frames: frames)
        for offset in 0..<Int(frames) {
            XCTAssertEqual(left[left.startIndex + offset], inRight[inRight.startIndex + offset],
                           accuracy: 1e-6, "L: frame \(offset)")
            XCTAssertEqual(right[right.startIndex + offset], inLeft[inLeft.startIndex + offset],
                           accuracy: 1e-6, "R: frame \(offset)")
        }
    }

    /// A12/A13。**宣言していないチャンネルは素通りする**（ysfx が memcpy で送る）。
    /// 64ch まで通しても、上の 62 本は触られない。
    func testChannelsAboveThePinCountPassThrough() throws {
        let host = try JSFX.load("gain")
        host.set(0, 0.5)
        let channels: UInt32 = 64
        let input = JSFX.signal(channels: channels, frames: frames)
        var planar = input
        XCTAssertEqual(host.process(&planar, channels: channels, frames: frames), 0)

        for channel in 0..<Int(channels) {
            let expectedScale: Float = channel < 2 ? 0.5 : 1
            let out = JSFX.channel(channel, of: planar, frames: frames)
            let ins = JSFX.channel(channel, of: input, frames: frames)
            for offset in 0..<Int(frames) {
                XCTAssertEqual(out[out.startIndex + offset],
                               ins[ins.startIndex + offset] * expectedScale,
                               accuracy: 1e-6, "ch \(channel) frame \(offset)")
            }
        }
    }

    /// §5.3 の境界。**ここは全部 process の頭の門**なので、値は決まっている。
    func testFrameAndChannelBoundaries() throws {
        let host = try JSFX.load("passthrough")
        let descriptor = host.processor
        var planar = JSFX.signal(channels: 2, frames: frames + 1)

        XCTAssertEqual(host.process(&planar, channels: 2, frames: frames), 0, "frames == maxFrames")
        XCTAssertEqual(host.process(&planar, channels: 2, frames: frames + 1), -1, "maxFrames + 1")
        XCTAssertEqual(host.process(&planar, channels: 2, frames: 0), -1, "frames == 0")
        XCTAssertEqual(host.process(&planar, channels: 0, frames: frames), -1, "channels == 0")
        XCTAssertEqual(host.process(&planar, channels: descriptor.maxChannels + 1, frames: frames), -1,
                       "channels > maxChannels")

        // planar == NULL。buffer を触る前に落ちること。
        XCTAssertEqual(descriptor.process!(descriptor.context, nil, 2, frames, JSFX.sampleRate, 0), -1)
        // context == NULL も同じ門で落ちる（橋が外した後に呼ばれる形）。
        XCTAssertEqual(planar.withUnsafeMutableBufferPointer {
            descriptor.process!(nil, $0.baseAddress, 2, frames, JSFX.sampleRate, 0)
        }, -1)
    }

    /// §6 の Reconfigure。**新しいブロック長が descriptor に出る**こと、
    /// 古い長さは弾かれること、音は変わらないこと。
    func testReconfigureUpdatesBlockSizeAndKeepsAudioCorrect() throws {
        let host = try JSFX.load("gain")
        host.set(0, 0.5)
        host.run(blocks: 1, channels: 2, frames: frames)

        let smaller: UInt32 = 128
        XCTAssertTrue(ETJSFX_Reconfigure(host.raw, 96000, smaller))
        XCTAssertEqual(host.processor.maxFrames, smaller)
        XCTAssertTrue(host.isRunning)

        var planar = JSFX.signal(channels: 2, frames: frames)
        XCTAssertEqual(host.process(&planar, channels: 2, frames: frames, sampleRate: 96000), -1,
                       "再設定前の長さは通らない")

        let input = JSFX.signal(channels: 2, frames: smaller)
        planar = input
        XCTAssertEqual(host.process(&planar, channels: 2, frames: smaller, sampleRate: 96000), 0)
        for (index, value) in planar.enumerated() {
            XCTAssertEqual(value, input[index] * 0.5, accuracy: 1e-6, "sample \(index)")
        }

        // 0 フレームでは再設定できない（ETJSFX_Reconfigure の頭の門）。
        XCTAssertFalse(ETJSFX_Reconfigure(host.raw, 96000, 0))
        XCTAssertEqual(host.processor.maxFrames, smaller)
    }

    /// reset は位置を 0 へ戻すだけで、音の口は閉じない。
    func testResetKeepsTheProcessorUsable() throws {
        let host = try JSFX.load("passthrough")
        host.run(blocks: 2)
        let descriptor = host.processor
        descriptor.reset!(descriptor.context)

        let input = JSFX.signal(channels: 2, frames: frames)
        var planar = input
        XCTAssertEqual(host.process(&planar, channels: 2, frames: frames), 0)
        for (index, value) in planar.enumerated() {
            XCTAssertEqual(value, input[index], accuracy: 1e-6, "sample \(index)")
        }
    }
}
