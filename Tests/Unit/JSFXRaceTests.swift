//  JSFXRaceTests.swift
//  同時に触っても壊れないこと。設計 §15.1 / §15.2。
//
//  **見るのは 2 つだけ**: 止まらないこと（deadlock）と、終わったあとに host が
//  正しいこと。**途中の値は見ない。**maintenance に入っている間 process は
//  何もせずに返るので、どのブロックが素通りしたかは実行ごとに変わる。
//  そこを期待値にすると、実装が正しくても落ちるテストになる。
//
//  音のスレッドは C の口を直接叩く（OpaquePointer だけを渡す）。Swift の
//  持ち物を跨がせると、測りたいもの以外の同期が混ざる。

import XCTest
import Foundation

/// 別のスレッドから見つけたおかしな点を溜める。XCTAssert を裏のスレッドから
/// 呼ぶより、こちらで数えて最後に 1 度だけ判定する方が読みやすい。
private final class JSFXRaceFailures {
    private let lock = NSLock()
    private var notes: [String] = []

    func add(_ note: String) {
        lock.lock(); notes.append(note); lock.unlock()
    }

    var all: [String] {
        lock.lock(); defer { lock.unlock() }; return notes
    }
}

final class JSFXRaceTests: XCTestCase {

    private let frames = JSFX.maxFrames
    private let iterations = 200

    /// process ↔ SaveState / LoadState / Reconfigure / SetSlider。
    func testProcessAgainstMaintenanceOperations() throws {
        let host = try JSFX.load("gain")
        host.set(0, 0.5)
        host.run(blocks: 1)
        let saved = try XCTUnwrap(host.save())

        let raw = host.raw
        let frames = self.frames
        let iterations = self.iterations
        let group = DispatchGroup()

        withExtendedLifetime(host) {
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                let count = 2 * Int(frames)
                let buffer = UnsafeMutablePointer<Float>.allocate(capacity: count)
                buffer.initialize(repeating: 0.25, count: count)
                defer { buffer.deinitialize(count: count); buffer.deallocate() }
                let descriptor = ETJSFX_Processor(raw)
                for _ in 0..<iterations {
                    _ = descriptor.process!(descriptor.context, buffer, 2, frames,
                                            JSFX.sampleRate, 0)
                }
            }

            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                for step in 0..<iterations {
                    switch step % 4 {
                    case 0:
                        ETJSFX_SetSlider(raw, 0, 0.5)
                    case 1:
                        var bytes: UnsafeMutablePointer<UInt8>?
                        var size = 0
                        if ETJSFX_SaveState(raw, &bytes, &size), let bytes {
                            ETJSFX_FreeBytes(UnsafeMutableRawPointer(bytes))
                        }
                    case 2:
                        _ = saved.withUnsafeBytes {
                            ETJSFX_LoadState(raw, $0.bindMemory(to: UInt8.self).baseAddress,
                                             $0.count)
                        }
                    default:
                        // ブロック長は変えない。変えると process 側が -1 を返すだけになり、
                        // 測りたい重なりが起きなくなる。
                        _ = ETJSFX_Reconfigure(raw, step % 8 == 3 ? 44100 : 48000, frames)
                    }
                }
            }

            XCTAssertEqual(group.wait(timeout: .now() + 120), .success, "止まった")
        }

        // 落ち着かせてから、値と音を見る。
        XCTAssertTrue(host.isRunning)
        XCTAssertEqual(host.diagnostic, "")
        host.set(0, 0.5)
        let input = JSFX.signal(channels: 2, frames: frames)
        var planar = input
        XCTAssertEqual(host.process(&planar, channels: 2, frames: frames), 0)
        for (index, value) in planar.enumerated() {
            XCTAssertEqual(value, input[index] * 0.5, accuracy: 1e-6, "sample \(index)")
        }
        XCTAssertEqual(host.sliders().count, 1)
        XCTAssertEqual(host.get(0), 0.5)
    }

    /// §15.2。同じ host へ 2 本から process を入れる。**VM を同時に走らせない**
    /// のは host 側の仕事で、片方は何もせずに返る。**それぞれ別の buffer を渡す**
    /// （同じ buffer を渡すとテスト自身が競合になる）。
    func testTwoThreadsProcessingTheSameHost() throws {
        let host = try JSFX.load("gain")
        host.set(0, 1)
        host.run(blocks: 1)

        let raw = host.raw
        let frames = self.frames
        let iterations = self.iterations
        let group = DispatchGroup()
        let failures = JSFXRaceFailures()

        withExtendedLifetime(host) {
            for lane in 0..<2 {
                DispatchQueue.global(qos: .userInitiated).async(group: group) {
                    let count = 2 * Int(frames)
                    let expected = Float(lane) + 1
                    let buffer = UnsafeMutablePointer<Float>.allocate(capacity: count)
                    buffer.initialize(repeating: expected, count: count)
                    defer { buffer.deinitialize(count: count); buffer.deallocate() }
                    let descriptor = ETJSFX_Processor(raw)
                    for step in 0..<iterations {
                        let code = descriptor.process!(descriptor.context, buffer, 2, frames,
                                                       JSFX.sampleRate, 0)
                        if code != 0 {
                            failures.add("lane \(lane) step \(step): process = \(code)")
                        }
                        // gain は 1.0 なので、素通りでも掛けても入力のまま。
                        // **値が化けていない**ことだけ見る。
                        if buffer[0] != expected || buffer[count - 1] != expected {
                            failures.add("lane \(lane) step \(step): 値が化けた")
                        }
                    }
                }
            }
            XCTAssertEqual(group.wait(timeout: .now() + 120), .success, "止まった")
        }

        XCTAssertEqual(failures.all, [], "process が失敗したか、値が化けた")
        XCTAssertTrue(host.isRunning)
    }
}
