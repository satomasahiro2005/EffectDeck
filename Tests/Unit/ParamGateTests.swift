//  ParamGateTests.swift
//  ほかの値で触れなくなる行の規則（ETParamGate）。止めるのは操作だけで値は残す。
//
//  壊れると: Cassette の Mode を Encode Only にしても傷みの行が動かせてしまう（効かない行が
//  触れる）か、All のまま止まる（効く行が触れない）。上流 _syncModeDependentControls と Adaptive
//  Prediction の _syncControlAvailability と同じ表。

import XCTest

final class ParamGateTests: XCTestCase {

    private let cassette = "CassetteArtifactsPlugin"
    private let ape = "AdaptivePredictionEffectPlugin"

    private func disabled(_ type: String, _ key: String, _ values: [String: Float]) -> Bool {
        ETParamGate.isDisabled(type: type, key: key) { values[$0] }
    }

    // MARK: Cassette Artifacts

    /// 傷みの 7 行（dg tp bs wf hs dp az）。
    private let artifacts = ["dg", "tp", "bs", "wf", "hs", "dp", "az"]

    func testCassetteModeNames() throws {
        let spec = try XCTUnwrap(ETCatalog.first { $0.type == cassette })
        guard case .enumeration(let options) = try XCTUnwrap(spec.params.first { $0.key == "md" }).kind else {
            return XCTFail("md は選択肢")
        }
        XCTAssertEqual(options, ["Encode Only", "Encode + Artifacts", "All", "Artifacts + Decode", "Decode Only"])
        XCTAssertEqual(options[Int(ETParamGate.CassetteMode.all)], "All")
        XCTAssertEqual(options[Int(ETParamGate.CassetteMode.decodeOnly)], "Decode Only")
        let nr = try XCTUnwrap(spec.params.first { $0.key == "nr" })
        guard case .enumeration(let nrOptions) = nr.kind else { return XCTFail("nr は選択肢") }
        XCTAssertEqual(nrOptions.first, "Off")
    }

    func testCassetteAllGatesNothing() {
        for key in artifacts + ["dl", "rl", "og", "mx", "nr", "md"] {
            XCTAssertFalse(disabled(cassette, key, ["md": 2, "nr": 1]), key)
        }
    }

    func testCassetteEncodeOnlyAndDecodeOnlyStopTheArtifacts() {
        for mode: Float in [0, 4] {
            for key in artifacts {
                XCTAssertTrue(disabled(cassette, key, ["md": mode, "nr": 1]), "\(key) md=\(mode)")
            }
            // 傷みが無い Mode でも、NR が入っていれば Record Level は効く。
            XCTAssertFalse(disabled(cassette, "rl", ["md": mode, "nr": 1]))
            XCTAssertTrue(disabled(cassette, "rl", ["md": mode, "nr": 0]), "NR Off なら録音レベルは効かない")
        }
    }

    func testCassetteDolbyLevelErrorNeedsDecodeAndNoiseReduction() {
        // 復号を通る Mode: All（2）・Artifacts + Decode（3）・Decode Only（4）。
        for mode: Float in [2, 3, 4] {
            XCTAssertFalse(disabled(cassette, "dl", ["md": mode, "nr": 2]), "md=\(mode)")
            XCTAssertTrue(disabled(cassette, "dl", ["md": mode, "nr": 0]), "NR Off md=\(mode)")
        }
        for mode: Float in [0, 1] {
            XCTAssertTrue(disabled(cassette, "dl", ["md": mode, "nr": 2]), "復号を通らない md=\(mode)")
        }
    }

    func testCassetteEncodeArtifactsKeepsArtifactsAndRecordLevel() {
        for key in artifacts + ["rl"] {
            XCTAssertFalse(disabled(cassette, key, ["md": 1, "nr": 0]), key)
        }
    }

    /// Mode を持たない古い鎖は All と同じ（今までの動き）。
    func testCassetteWithoutModeIsAll() {
        XCTAssertFalse(disabled(cassette, "dg", [:]))
        XCTAssertFalse(disabled(cassette, "dl", ["nr": 1]))
    }

    // MARK: Adaptive Prediction

    func testAdaptiveLearningStoppedByFreezeOrHold() {
        XCTAssertFalse(disabled(ape, "learn", [:]))
        XCTAssertTrue(disabled(ape, "learn", ["freeze": 1]))
        XCTAssertTrue(disabled(ape, "learn", ["hold": 1]))
        XCTAssertTrue(disabled(ape, "weightDecay", ["freeze": 1, "weightDecay": 10]))
        XCTAssertFalse(disabled(ape, "weightDecay", ["weightDecay": 10]))
    }

    func testAdaptiveInfiniteDecayStopsTheSlider() {
        XCTAssertTrue(disabled(ape, "weightDecay", ["weightDecay": 0]))
    }

    func testAdaptiveHoldFixesAutonomyAndFreeze() {
        XCTAssertFalse(disabled(ape, "autonomy", [:]))
        XCTAssertTrue(disabled(ape, "autonomy", ["hold": 1]))
        XCTAssertFalse(disabled(ape, "freeze", ["freeze": 1]), "Freeze だけなら Freeze は戻せる")
        XCTAssertTrue(disabled(ape, "freeze", ["hold": 1]))
        for key in ["gap", "original", "residual", "prediction", "hold"] {
            XCTAssertFalse(disabled(ape, key, ["hold": 1, "freeze": 1]), key)
        }
    }

    // MARK: toggle の持ち主（今までの表）

    func testToggleOwnersStillWork() {
        XCTAssertEqual(ETParamGate.upstream(type: "AttackTonalBalancePlugin", key: "at"), "ae")
        XCTAssertTrue(disabled("AttackTonalBalancePlugin", "at", ["ae": 0]))
        XCTAssertFalse(disabled("AttackTonalBalancePlugin", "at", ["ae": 1]))
        // 持ち主の値が引けないときは止めない。
        XCTAssertFalse(disabled("AttackTonalBalancePlugin", "at", [:]))
        XCTAssertFalse(disabled("CompressorPlugin", "th", [:]))
    }

    // MARK: 無音でも回す段（Power）

    func testIdleSecondsNeverRestsWhileAStageMustProcess() {
        XCTAssertEqual(PowerGate.idleSeconds(mode: .maximum, externalTail: 0, mustProcess: true), .infinity)
        XCTAssertEqual(PowerGate.idleSeconds(mode: .balanced, externalTail: 0, mustProcess: false), 3)
        var g = PowerGate()
        g.idleSeconds = PowerGate.idleSeconds(mode: .maximum, externalTail: 0, mustProcess: true)
        for _ in 0..<10_000 { XCTAssertTrue(g.update(peak: 0, seconds: 1)) }
    }

    func testChainMustProcessOnlyForEnabledReachableAdaptivePrediction() throws {
        let spec = try XCTUnwrap(ETCatalog.first { $0.type == ape })
        var node = ETChainNode(spec: spec, values: spec.defaults)
        XCTAssertTrue(ETChainEditing.chainMustProcess([node]))
        node.enabled = false
        XCTAssertFalse(ETChainEditing.chainMustProcess([node]), "切ってある")
        node.enabled = true
        node.channelSpec = -2
        XCTAssertFalse(ETChainEditing.chainMustProcess([node]), "All は素通し")
        node.channelSpec = 0
        XCTAssertTrue(ETChainEditing.chainMustProcess([node]))
        let other = try XCTUnwrap(ETCatalog.first { $0.type == "CompressorPlugin" })
        XCTAssertFalse(ETChainEditing.chainMustProcess([ETChainNode(spec: other, values: other.defaults)]))
        XCTAssertFalse(ETChainEditing.chainMustProcess([]))
    }
}
