//  CloudMirrorTests.swift
//  iCloud へ写す・戻す決まり（CloudMirrorCore）。
//
//  CloudMirror.swift の頭に、写し方を誤って 50 本のプリセットが 1 本になった話がある。
//  そこで決めた規則（触った項目だけ当てる・戻すのは手元が空の鍵だけ・大きすぎたら
//  前の写しを残す・撮影用の起動では何もしない）を、ここで 1 つずつ留める。
//  本物の KVS は使わない（ETMemoryStorage）。

import XCTest

final class CloudMirrorTests: XCTestCase {

    private let chainKey = "pipeline.last"
    private let presetsKey = PresetStoreCore.key
    private let effectKey = EffectPresetStoreCore.key

    private func core(_ cloud: ETMemoryStorage, seeded: Bool = false) -> CloudMirrorCore {
        CloudMirrorCore(cloud: cloud, seeded: seeded)
    }

    /// 辞書の鍵。辞書でなければ空。
    private func keys(_ value: Any?) -> Set<String> {
        Set((value as? [String: Any])?.keys.map { $0 } ?? [])
    }

    // MARK: - apply

    func testApplyNestedSet() {
        var root: [String: Any] = ["Volume": ["a": ["vl": 1.0]]]

        XCTAssertTrue(CloudMirrorCore.apply(&root, path: ["Volume", "b"], value: ["vl": 2.0]))
        XCTAssertTrue(CloudMirrorCore.apply(&root, path: ["Delay", "c"], value: ["dt": 3.0]))

        let volume = root["Volume"] as? [String: Any]
        XCTAssertEqual(keys(volume), ["a", "b"], "隣の項目を消した")
        XCTAssertEqual((volume?["b"] as? [String: Any])?["vl"] as? Double, 2.0)
        XCTAssertEqual(((root["Delay"] as? [String: Any])?["c"] as? [String: Any])?["dt"] as? Double, 3.0)
    }

    func testApplyEmptyPathDoesNothing() {
        var root: [String: Any] = ["a": 1.0]
        XCTAssertFalse(CloudMirrorCore.apply(&root, path: [], value: 2.0))
        XCTAssertEqual(root["a"] as? Double, 1.0)
    }

    /// 消した結果その枝が空になったら枝ごと落とす（plugin-preset-store.js:159）。
    func testDeletePrunesEmptyBranches() {
        var root: [String: Any] = ["Volume": ["a": ["vl": 1.0]], "Delay": ["c": ["dt": 3.0]]]

        XCTAssertTrue(CloudMirrorCore.apply(&root, path: ["Volume", "a"], value: nil))

        XCTAssertNil(root["Volume"], "空の枝が残った")
        XCTAssertNotNil(root["Delay"])
    }

    func testScalarInTheWayBecomesDictionary() {
        var root: [String: Any] = ["Volume": "not a dictionary"]

        XCTAssertTrue(CloudMirrorCore.apply(&root, path: ["Volume", "a"], value: ["vl": 1.0]))

        let volume = root["Volume"] as? [String: Any]
        XCTAssertEqual((volume?["a"] as? [String: Any])?["vl"] as? Double, 1.0)
    }

    // MARK: - 大きさ

    /// Data はそのまま数える。鎖（pipeline.last）は Data で、plist の根に置けるかを試さない。
    func testStoredSizeCountsData() {
        XCTAssertEqual(CloudMirrorCore.storedSize(of: Data(count: 1234)), 1234)
        XCTAssertEqual(CloudMirrorCore.storedSize(of: Data()), 0)

        let plist = CloudMirrorCore.storedSize(of: ["a": [["nm": "Volume", "vl": 1.0]]])
        XCTAssertNotNil(plist)
        XCTAssertGreaterThan(plist ?? 0, 0)

        // JSON の null（NSNull）は plist に載らない。
        XCTAssertNil(CloudMirrorCore.storedSize(of: ["a": NSNull()]))
    }

    // MARK: - 写す

    func testNilRemovesKey() {
        let cloud = ETMemoryStorage([chainKey: Data([1, 2, 3])])

        XCTAssertEqual(core(cloud).mirror(nil, forKey: chainKey), .removed)

        XCTAssertNil(cloud.object(forKey: chainKey))
    }

    func testMirrorWritesData() {
        let cloud = ETMemoryStorage()

        XCTAssertEqual(core(cloud).mirror(Data([1, 2, 3]), forKey: chainKey), .written(bytes: 3))

        XCTAssertEqual(cloud.data(forKey: chainKey), Data([1, 2, 3]))
    }

    /// 上限を超えるものは写さず、**前の写しを消さない。**古い写しでも、何も無いよりは戻せる。
    func testOver256KBKeepsOlderCloudCopy() {
        let older = Data([7, 7, 7])
        let cloud = ETMemoryStorage([chainKey: older,
                                     presetsKey: ["a": [["nm": "Volume", "vl": 1.0]]]])
        let mirror = core(cloud)
        let big = Data(count: CloudMirrorCore.byteLimit + 1)

        XCTAssertEqual(mirror.mirror(big, forKey: chainKey),
                       .tooLarge(bytes: CloudMirrorCore.byteLimit + 1))
        XCTAssertEqual(cloud.data(forKey: chainKey), older)

        // 辞書に足して上限を超えるときも、足す前の辞書がそのまま残る。
        let outcome = mirror.patch(key: presetsKey,
                                   changes: [CloudChange(path: ["b"], value: big)])
        guard case .tooLarge = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(keys(cloud.dictionary(forKey: presetsKey)), ["a"])

        // ちょうど上限は写す。
        let edge = Data(count: CloudMirrorCore.byteLimit)
        XCTAssertEqual(mirror.mirror(edge, forKey: chainKey),
                       .written(bytes: CloudMirrorCore.byteLimit))
    }

    func testUnencodableNotWritten() {
        let cloud = ETMemoryStorage([presetsKey: ["a": [["nm": "Volume", "vl": 1.0]]]])

        let outcome = core(cloud).patch(key: presetsKey,
                                        changes: [CloudChange(path: ["b"], value: ["vl": NSNull()])])

        XCTAssertEqual(outcome, .unencodable)
        XCTAssertEqual(keys(cloud.dictionary(forKey: presetsKey)), ["a"])
        XCTAssertEqual(cloud.rejected, [])
    }

    /// 触った項目だけ当てる。iCloud に在る別の端末の分は残る。
    func testPatchKeepsOtherDevicesEntries() {
        let cloud = ETMemoryStorage([presetsKey: ["theirs": [["nm": "Volume", "vl": 1.0]]]])

        let outcome = core(cloud).patch(key: presetsKey, changes: [
            CloudChange(path: ["mine"], value: [["nm": "Volume", "vl": 2.0]]),
        ])

        guard case .written = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(keys(cloud.dictionary(forKey: presetsKey)), ["theirs", "mine"])
    }

    /// 1 回に渡した項目は、iCloud への 1 回の書き込みにまとまる。
    func testPatchBatchesIntoOneWrite() {
        let cloud = ETMemoryStorage([presetsKey: ["old": [["nm": "Volume", "vl": 1.0]]]])
        let before = cloud.writes

        core(cloud).patch(key: presetsKey, changes: [
            CloudChange(path: ["old"], value: nil),
            CloudChange(path: ["new"], value: [["nm": "Volume", "vl": 1.0]]),
        ])

        XCTAssertEqual(cloud.writes - before, 1)
        XCTAssertEqual(keys(cloud.dictionary(forKey: presetsKey)), ["new"])
    }

    func testPatchWithNoUsableChangeWritesNothing() {
        let cloud = ETMemoryStorage()

        XCTAssertEqual(core(cloud).patch(key: presetsKey, changes: []), .unchanged)
        XCTAssertEqual(core(cloud).patch(key: presetsKey, changes: [CloudChange(path: [], value: 1.0)]),
                       .unchanged)
        XCTAssertEqual(cloud.writes, 0)
    }

    /// 撮影用の起動（-ETSeed）では写さない・戻さない。並んでいるのは見本の鎖で、
    /// 写すと同じ Apple ID の端末で 1 度撮っただけで人の鎖が消える。
    func testSeedDisablesMirror() {
        let cloud = ETMemoryStorage([chainKey: Data([1]),
                                     presetsKey: ["a": [["nm": "Volume", "vl": 1.0]]]])
        let mirror = core(cloud, seeded: true)

        XCTAssertEqual(mirror.mirror(Data([9]), forKey: chainKey), .disabled)
        XCTAssertEqual(mirror.mirror(nil, forKey: chainKey), .disabled)
        XCTAssertEqual(mirror.patch(key: presetsKey, changes: [CloudChange(path: ["a"], value: nil)]),
                       .disabled)
        XCTAssertEqual(cloud.writes, 0)

        let device = ETMemoryStorage()
        let restored = mirror.seed(into: device, chainKey: chainKey,
                                   dictionaryKeys: [presetsKey, effectKey])
        XCTAssertEqual(restored, CloudMirrorCore.Restored())
        XCTAssertEqual(device.writes, 0)
    }

    // MARK: - 戻す

    /// 手元がまだ空の鍵だけ戻す。手元に何か在る鍵は、iCloud に何が在っても触らない。
    func testRestoreFillsOnlyEmptyDeviceKeys() {
        let cloud = ETMemoryStorage([
            chainKey: Data([1, 2]),
            presetsKey: ["theirs": [["nm": "Volume", "vl": 1.0]]],
            effectKey: ["Volume": ["warm": ["vl": 2.0]], "Delay": ["long": ["dt": 3.0]]],
        ])
        let device = ETMemoryStorage([presetsKey: ["mine": [["nm": "Volume", "vl": 9.0]]]])

        let restored = core(cloud).seed(into: device, chainKey: chainKey,
                                        dictionaryKeys: [presetsKey, effectKey])

        XCTAssertEqual(restored.chainBytes, 2)
        XCTAssertEqual(restored.dictionaries, [.init(key: effectKey, count: 2)])
        XCTAssertEqual(device.data(forKey: chainKey), Data([1, 2]))
        XCTAssertEqual(keys(device.dictionary(forKey: presetsKey)), ["mine"],
                       "手元のプリセットを iCloud の分で置き換えた")
        XCTAssertEqual(keys(device.dictionary(forKey: effectKey)), ["Volume", "Delay"])
    }

    /// true（画面へ入れ直す合図）は鎖を戻したときだけ。
    func testRestoreTrueOnlyWhenChainRestored() {
        let presetsOnly = ETMemoryStorage([presetsKey: ["a": [["nm": "Volume", "vl": 1.0]]]])
        let r1 = core(presetsOnly).seed(into: ETMemoryStorage(), chainKey: chainKey,
                                        dictionaryKeys: [presetsKey, effectKey])
        XCTAssertFalse(r1.chain)
        XCTAssertEqual(r1.dictionaries, [.init(key: presetsKey, count: 1)])

        let withChain = ETMemoryStorage([chainKey: Data([1])])
        XCTAssertTrue(core(withChain).seed(into: ETMemoryStorage(), chainKey: chainKey,
                                           dictionaryKeys: []).chain)

        // 手元に鎖が在るなら、iCloud に鎖が在っても戻さない。
        let device = ETMemoryStorage([chainKey: Data([5])])
        XCTAssertFalse(core(withChain).seed(into: device, chainKey: chainKey,
                                            dictionaryKeys: []).chain)
        XCTAssertEqual(device.data(forKey: chainKey), Data([5]))

        // 2 回目は手元が埋まっているので何も戻さない（遅れて届いた通知でも壊さない）。
        let fresh = ETMemoryStorage()
        XCTAssertTrue(core(withChain).seed(into: fresh, chainKey: chainKey, dictionaryKeys: []).chain)
        XCTAssertFalse(core(withChain).seed(into: fresh, chainKey: chainKey, dictionaryKeys: []).chain)
    }

    /// iCloud 側が Data でない鎖・辞書でないプリセットは戻さない。
    func testRestoreIgnoresWrongTypes() {
        let cloud = ETMemoryStorage([chainKey: "not data", presetsKey: ["a", "b"]])
        let device = ETMemoryStorage()

        let restored = core(cloud).seed(into: device, chainKey: chainKey, dictionaryKeys: [presetsKey])

        XCTAssertEqual(restored, CloudMirrorCore.Restored())
        XCTAssertEqual(device.writes, 0)
    }
}
