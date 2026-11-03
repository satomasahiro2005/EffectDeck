//  JSFXOutputVolumeTests.swift
//  物理の出力の音量を JSFX の effectdeck_output_volume へ渡す口
//  （ETJSFX_SetOutputVolume、Patches/ysfx-effectdeck-ios.diff の組み込みの変数）。
//
//  見るのは次の 5 つ。
//   - 読めていないときは 0（消音）でなく -1。
//   - @init・@slider・@block に最新の値が届き、1 ブロックの中では動かない。
//   - 再設定・状態の復元の @init も、ysfx が変数を 0 に戻さず最新の値を見る。
//   - 保存されない・変更の通知も立てない（音量が動くたびに状態の保存が走らない）。
//   - 範囲外・非有限の値は -1 か 1 に収まる。
//
//  値はプロセスで 1 つなので、前のテストの値を持ち越さないよう setUp / tearDown で -1 に戻す。
//  値は fixture の隠しつまみに写して ETJSFX_GetSlider で読む。音を通すと 1e-16 の
//  非正規化対策が乗るので、音の側では測らない（JSFXHostSupport.swift の頭）。

import XCTest

final class JSFXOutputVolumeTests: XCTestCase {

    private let accuracy = 1e-12

    override func setUp() {
        super.setUp()
        ETJSFX_SetOutputVolume(-1)
    }

    override func tearDown() {
        ETJSFX_SetOutputVolume(-1)
        super.tearDown()
    }

    /// fixture（output_volume.jsfx）のつまみの番号。get / set は 0 始まり。
    private enum Probe {
        static let seenByInit: UInt32 = 0
        static let seenBySlider: UInt32 = 1
        static let seenByBlock: UInt32 = 2
        static let sameThroughSamples: UInt32 = 3
        static let scribble: UInt32 = 4
        static let keptFromInit: UInt32 = 5
    }

    // MARK: - 読めていない

    /// 一度も渡していなければ、@init・@slider・@block のどれも -1。0 は消音の本物の値なので混ぜない。
    func testUnknownIsMinusOne() throws {
        let host = try JSFX.load("output_volume")
        host.run(blocks: 1)
        XCTAssertEqual(host.get(Probe.seenByInit), -1)
        XCTAssertEqual(host.get(Probe.seenBySlider), -1)
        XCTAssertEqual(host.get(Probe.seenByBlock), -1)
    }

    // MARK: - 届き方

    func testValueReachesInitSliderAndBlock() throws {
        ETJSFX_SetOutputVolume(0.35)
        let host = try JSFX.load("output_volume")
        host.run(blocks: 1)
        XCTAssertEqual(host.get(Probe.seenByInit), 0.35, accuracy: accuracy)
        XCTAssertEqual(host.get(Probe.seenBySlider), 0.35, accuracy: accuracy)
        XCTAssertEqual(host.get(Probe.seenByBlock), 0.35, accuracy: accuracy)
    }

    /// 値を渡しても、次のブロックの頭までスクリプトからは見えない。1 ブロックの中は 1 つの値。
    func testChangeAppearsAtNextBlockAndHoldsThroughBlock() throws {
        ETJSFX_SetOutputVolume(0.2)
        let host = try JSFX.load("output_volume")
        host.run(blocks: 1)
        XCTAssertEqual(host.get(Probe.seenByBlock), 0.2, accuracy: accuracy)

        ETJSFX_SetOutputVolume(0.8)
        XCTAssertEqual(host.get(Probe.seenByBlock), 0.2, accuracy: accuracy, "音を通す前は変わらない")

        host.run(blocks: 1)
        XCTAssertEqual(host.get(Probe.seenByBlock), 0.8, accuracy: accuracy)
        XCTAssertEqual(host.get(Probe.sameThroughSamples), 1, "@sample のどこかで値が動いた")
    }

    /// スクリプトが変数へ書いても残らない。EEL に読み取り専用の変数は無いので、
    /// 保証は「次のブロックの頭で戻る」まで。ブロックの中では書いた値が見える（境界の記録）。
    func testScriptWriteDoesNotStick() throws {
        let host = try JSFX.load("output_volume")
        host.set(Probe.scribble, 1)
        ETJSFX_SetOutputVolume(0.4)
        host.run(blocks: 2)
        XCTAssertEqual(host.get(Probe.seenByBlock), 0.4, accuracy: accuracy, "書いた 0.123 が次のブロックに残った")
        XCTAssertEqual(host.get(Probe.sameThroughSamples), 0, "ブロックの中では書いた値が見える")
    }

    // MARK: - 再設定・復元

    /// 組み込みの変数として登録していなければ、再設定の ysfx_reinitialize_vars が 0 に戻し、
    /// @init が 0（消音）を読む。
    func testReconfigureInitSeesCurrentValue() throws {
        ETJSFX_SetOutputVolume(0.6)
        let host = try JSFX.load("output_volume")
        host.run(blocks: 1)
        ETJSFX_SetOutputVolume(0.7)
        XCTAssertTrue(ETJSFX_Reconfigure(host.raw, 44100, 512))
        XCTAssertEqual(host.get(Probe.seenByInit), 0.7, accuracy: accuracy)
    }

    /// 状態の復元の @init が最新の値を見る。つまみは保存した値に戻るので、@init が変数へ残した値を
    /// 次のブロックで読む（output_volume.jsfx の slider6）。
    func testLoadStateInitSeesCurrentValue() throws {
        ETJSFX_SetOutputVolume(0.3)
        let host = try JSFX.load("output_volume")
        host.run(blocks: 1)
        let saved = try XCTUnwrap(host.save())

        ETJSFX_SetOutputVolume(0.9)
        XCTAssertTrue(host.load(saved))
        host.run(blocks: 1)
        XCTAssertEqual(host.get(Probe.keptFromInit), 0.9, accuracy: accuracy, "復元の @init が古い値か 0 を読んだ")
        XCTAssertEqual(host.get(Probe.seenByBlock), 0.9, accuracy: accuracy)
    }

    // MARK: - 範囲

    func testSetClamps() throws {
        let host = try JSFX.load("output_volume")

        for unknown in [Double.nan, -0.2, -.infinity, .infinity] {
            ETJSFX_SetOutputVolume(unknown)
            host.run(blocks: 1)
            XCTAssertEqual(host.get(Probe.seenByBlock), -1, "\(unknown) は読めていない扱いにする")
        }

        ETJSFX_SetOutputVolume(1.5)
        host.run(blocks: 1)
        XCTAssertEqual(host.get(Probe.seenByBlock), 1)

        ETJSFX_SetOutputVolume(0)
        host.run(blocks: 1)
        XCTAssertEqual(host.get(Probe.seenByBlock), 0, "0 は消音の本物の値で、-1 と区別する")
    }

    // MARK: - 保存しない・通知しない

    /// 音量が動いても、保存した状態は 1 バイトも変わらず、つまみの変更の通知も立たない
    /// （立てば Swift の ConsumeSliderChange → snapshotState が走り、プリセットの保存になる）。
    func testVolumeIsNotSavedAndRaisesNoChange() throws {
        ETJSFX_SetOutputVolume(0.3)
        let host = try JSFX.load("output_volume_state")
        host.run(blocks: 1)
        let first = try XCTUnwrap(host.save())
        while ETJSFX_ConsumeSliderChange(host.raw) {}

        ETJSFX_SetOutputVolume(0.9)
        host.run(blocks: 3)
        XCTAssertFalse(ETJSFX_ConsumeSliderChange(host.raw), "音量の変化で保存の通知が立った")
        let second = try XCTUnwrap(host.save())
        XCTAssertEqual(first, second)
    }

    /// @serialize が名前を file_var で書いていても、復元で保存されていた古い値が残らない。
    /// 復元の直後（次のブロックの前）に保存し直すと、中身は最新の値になっている。
    func testSerializedCopyIsOverwritten() throws {
        ETJSFX_SetOutputVolume(0.3)
        let host = try JSFX.load("output_volume_serialize")
        host.run(blocks: 1)
        let saved = try XCTUnwrap(host.save())
        XCTAssertEqual(try serializedFloat(saved), 0.3, accuracy: 1e-6)

        ETJSFX_SetOutputVolume(0.8)
        XCTAssertTrue(host.load(saved))
        let afterLoad = try XCTUnwrap(host.save())
        XCTAssertEqual(try serializedFloat(afterLoad), 0.8, accuracy: 1e-6, "復元した古い値が残っている")

        host.run(blocks: 1)
        XCTAssertEqual(host.get(0), 0.8, accuracy: accuracy)
    }

    /// 保存した状態の末尾の 4 バイト（file_var は float32 のリトルエンディアン。payload はこの 1 つだけ）。
    private func serializedFloat(_ state: Data) throws -> Float {
        let tail = [UInt8](state.suffix(4))
        guard tail.count == 4 else { throw JSFXFixtureError.notFound("serialized payload") }
        let bits = UInt32(tail[0]) | UInt32(tail[1]) << 8 | UInt32(tail[2]) << 16 | UInt32(tail[3]) << 24
        return Float(bitPattern: bits)
    }
}
