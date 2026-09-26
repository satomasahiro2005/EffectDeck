//  JSFXStateTests.swift
//  @serialize の往復と、壊れた状態の食わせ方。設計 §10.1 / §10.2 / §14。
//
//  形式は ETJSFXHost.cpp が自分で作っている:
//      magic 'EDJS'(4) | slider 数(4) | payload 長(4) | [index(4) 値(8)]* | payload
//  **ここへ来るバイト列は外から来る**（保存した preset、共有リンク、別の版で
//  書いたもの）。だから「戻せる」だけでなく「戻せないものを安全に断る」まで見る。
//
//  もう 1 つ。**保存も復元も maintenance を通る**ので、自動バイパス中に呼んでも
//  勝手に running へ戻してはいけない（§14）。戻す口は ClearDiagnostic だけ。

import XCTest

final class JSFXStateTests: XCTestCase {

    /// ETJSFXHost.cpp の kStateMagic（'EDJS' を little endian で書いたもの）。
    private let magic = Data([0x45, 0x44, 0x4A, 0x53])

    // MARK: - §10.1 往復

    /// つまみは値ごと戻る。**別の host へ入れても同じ。**
    func testSliderValuesSurviveSaveAndLoad() throws {
        let host = try JSFX.load("state")
        host.set(0, 42)
        host.run(blocks: 1)
        let saved = try XCTUnwrap(host.save())
        XCTAssertGreaterThan(saved.count, 12)
        XCTAssertEqual(saved.prefix(4), magic)

        host.set(0, 7)
        host.run(blocks: 1)
        XCTAssertEqual(host.get(0), 7)

        XCTAssertTrue(host.load(saved))
        XCTAssertEqual(host.get(0), 42)

        let other = try JSFX.load("state")
        XCTAssertEqual(other.get(0), 0)
        XCTAssertTrue(other.load(saved))
        XCTAssertEqual(other.get(0), 42)
    }

    /// @serialize が書いた中身そのものが戻ること。
    ///
    /// **つまみ経由で戻っただけでは区別が付かない**ので、fixture は
    /// つまみから復元できない値（ブロックごとに増える数）を payload へ書く。
    /// payload が落ちていれば、復元後の 1 ブロックで 5 になる（20 + 5 = 25 ではなく）。
    ///
    /// fixture の @init は `kept` に触らない。payload だけを測る形。
    /// @init でも書く形は testInitDoesNotOverwriteSerializedStateOnLoad が見る。
    func testSerializedPayloadSurvivesSaveAndLoad() throws {
        let host = try JSFX.load("state_payload")
        host.set(0, 5)
        host.run(blocks: 4)
        XCTAssertEqual(host.get(1), 20, "5 ずつ 4 ブロック")
        let saved = try XCTUnwrap(host.save())

        let other = try JSFX.load("state_payload")
        XCTAssertTrue(other.load(saved))
        XCTAssertEqual(other.get(1), 20, "つまみの側は戻っている")
        other.run(blocks: 1)
        XCTAssertEqual(other.get(1), 25, "payload の値が戻っていない")
    }

    /// **@init と @serialize の両方で書く変数が、復元で @init に消されない。**
    ///
    /// 復元の順序は つまみ → @init → @serialize 読み → @slider（ETJSFX_LoadState）。
    /// 以前は @serialize 読みの後に ysfx_init を呼んでいて、@init の `x = 1` が
    /// 読んだ値をその場で潰していた（Debug/JSFXFactory の Conformance の
    /// frames_processed がこの形）。
    /// 別の host へ入れた直後の Save が元と同じバイト列になること、次の 1 ブロックで
    /// @slider が戻した値を読み、@block がそこから続けることを見る。
    func testInitDoesNotOverwriteSerializedStateOnLoad() throws {
        let host = try JSFX.load("state_init")
        host.set(0, 5)
        host.run(blocks: 4)
        XCTAssertEqual(host.get(2), 21, "@init の 1 から 5 ずつ 4 ブロック")
        let saved = try XCTUnwrap(host.save())

        let other = try JSFX.load("state_init")
        XCTAssertTrue(other.load(saved))
        XCTAssertEqual(other.save(), saved, "復元した x が @init で 1 に戻っている")
        other.run(blocks: 1)
        XCTAssertEqual(other.get(1), 21, "@slider が戻した x を見ていない")
        XCTAssertEqual(other.get(2), 26, "@block が戻した x から続いていない")

        // 動かした後の同じ host へ戻しても同じ。
        host.run(blocks: 3)
        XCTAssertTrue(host.load(saved))
        host.run(blocks: 1)
        XCTAssertEqual(host.get(1), 21)
        XCTAssertEqual(host.get(2), 26)
    }

    /// **状態に無いつまみは、復元の @init でも既定値で見える。**
    ///
    /// script につまみを足した後で古い状態を戻す形。@init を先に回すので、
    /// 既定値へ戻すのを ysfx_load_state に任せると @init だけが動かした後の値（7）を読む。
    func testMissingSliderIsDefaultDuringInitOnLoad() throws {
        let old = try JSFX.load("state_grow_old")
        old.run()
        let saved = try XCTUnwrap(old.save())

        let host = try JSFX.load("state_grow_new")
        host.set(0, 7)
        host.run()
        XCTAssertTrue(host.load(saved))
        host.run()
        XCTAssertEqual(host.get(0), 3, "状態に無いつまみが既定値へ戻っていない")
        XCTAssertEqual(host.get(1), 6, "@init が既定値ではなく動かした後の値を読んだ")
    }

    /// Save → Load → Save。同じ状態からは同じバイト列が出る。
    func testSaveLoadSaveIsStable() throws {
        let host = try JSFX.load("state_payload")
        host.set(0, 3)
        host.run(blocks: 3)
        let first = try XCTUnwrap(host.save())

        let other = try JSFX.load("state_payload")
        XCTAssertTrue(other.load(first))
        XCTAssertEqual(other.save(), first)
    }

    // MARK: - §10.2 壊れた状態

    /// **全部 false で、しかも host は生きている**こと。
    /// 断ったあとに音が止まると、preset を 1 つ壊しただけで段が死ぬ。
    func testCorruptStateIsRejectedAndTheHostSurvives() throws {
        let host = try JSFX.load("state")
        host.set(0, 11)
        host.run(blocks: 1)
        let valid = try XCTUnwrap(host.save())

        var broken: [(String, Data)] = [
            ("空", Data()),
            ("頭が足りない", valid.prefix(11)),
            ("magic 違い", Data([0xFF, 0xFF, 0xFF, 0xFF]) + valid.dropFirst(4)),
            ("末尾が欠けている", valid.dropLast(1)),
            ("末尾が余っている", valid + Data([0x00])),
            ("全部 0", Data(count: 64)),
        ]

        // つまみの数が上限（ysfx_max_sliders = 256）を超えている。
        // 長さの辻褄は合わせてあるので、数の門だけが理由になる。
        var tooMany = magic
        tooMany.append(contentsOf: [0x2C, 0x01, 0x00, 0x00])   // 300 本
        tooMany.append(contentsOf: [0x00, 0x00, 0x00, 0x00])   // payload 0
        tooMany.append(Data(count: 12 * 300))
        broken.append(("つまみが多すぎる", tooMany))

        // 16 MiB より大きい。長さの門で落ちる。
        var huge = Data(count: 16 * 1024 * 1024 + 1)
        huge.replaceSubrange(0..<4, with: magic)
        broken.append(("大きすぎる", huge))

        // 決まった種の擬似乱数。**時計や乱数に頼らない**ために自前で回す。
        var seed: UInt64 = 0x9E3779B97F4A7C15
        var noise = Data()
        for _ in 0..<256 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            noise.append(UInt8((seed >> 33) & 0xFF))
        }
        broken.append(("でたらめ", noise))

        for (label, data) in broken {
            XCTAssertFalse(host.load(data), label)
        }

        // 断ったあとも動く。
        let input = JSFX.signal(channels: 2, frames: JSFX.maxFrames)
        var planar = input
        XCTAssertEqual(host.process(&planar, channels: 2, frames: JSFX.maxFrames), 0)
        for (index, value) in planar.enumerated() {
            XCTAssertEqual(value, input[index], accuracy: 1e-6, "sample \(index)")
        }
        XCTAssertTrue(host.isRunning)
        XCTAssertTrue(host.load(valid))
        XCTAssertEqual(host.get(0), 11)
    }

    /// 形は合っているが中身がでたらめな payload。**ysfx の @serialize 読みまで
    /// 届く**ので、ここで落ちないことを見る（戻り値は問わない）。
    func testGarbagePayloadWithAValidHeaderDoesNotCrash() throws {
        let host = try JSFX.load("state")
        var blob = magic
        blob.append(contentsOf: [0x00, 0x00, 0x00, 0x00])      // つまみ 0 本
        blob.append(contentsOf: [0x20, 0x00, 0x00, 0x00])      // payload 32 バイト
        var seed: UInt64 = 0xDEADBEEF12345678
        for _ in 0..<32 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            blob.append(UInt8((seed >> 33) & 0xFF))
        }
        _ = host.load(blob)

        XCTAssertEqual(host.run(blocks: 1), 0)
        XCTAssertTrue(host.isRunning)
    }

    // MARK: - §14 maintenance

    /// 自動バイパス中に保存・復元・再設定をしても、**勝手に走り出さない**。
    /// 戻す口は ClearDiagnostic だけ。
    func testMaintenanceDoesNotResumeABypassedHost() throws {
        let host = try JSFX.exhaustedSlowHost()
        XCTAssertFalse(host.isRunning, "slow.jsfx が締切を超えていない")
        XCTAssertFalse(host.diagnostic.isEmpty)

        let saved = try XCTUnwrap(host.save())
        XCTAssertFalse(host.isRunning, "SaveState で走り出した")

        XCTAssertTrue(host.load(saved))
        XCTAssertFalse(host.isRunning, "LoadState で走り出した")

        XCTAssertTrue(ETJSFX_Reconfigure(host.raw, 44100, JSFX.deadlineFrames))
        XCTAssertFalse(host.isRunning, "Reconfigure で走り出した")
        XCTAssertFalse(host.diagnostic.isEmpty, "診断が消えている")

        XCTAssertTrue(ETJSFX_ClearDiagnostic(host.raw))
        XCTAssertTrue(host.isRunning)
        XCTAssertEqual(host.diagnostic, "")
    }
}
