//  KeyValueStorage.swift
//  鍵と値の入れ物（UserDefaults と iCloud の KVS）の口。**Foundationだけ。**
//
//  プリセットの入れ物（PresetStoreCore・EffectPresetStoreCore）と CloudMirrorCore は、
//  UserDefaults.standard や NSUbiquitousKeyValueStore.default を直に引かずにこれを受け取る。
//  アプリは今までどおり .standard / .default を渡し、テストは下の ETMemoryStorage を渡す
//  （PresetStoreTests・CloudMirrorTests）。
//
//  NSUbiquitousKeyValueStore は Linux の Foundation に無いので、そちらを合わせる 1 行は
//  CloudMirror.swift に置く。UserDefaults はどちらにも在るのでここで合わせる。
//
//  要求は両方が同じ綴りで元から持っているものだけにしてある。どちらも手を足さずに合う。

import Foundation

protocol ETKeyValueStorage: AnyObject {
    func object(forKey key: String) -> Any?
    func dictionary(forKey key: String) -> [String: Any]?
    func data(forKey key: String) -> Data?
    /// nil を渡すと消える（UserDefaults と同じ）。
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}

extension UserDefaults: ETKeyValueStorage {}

/// テスト用の入れ物。メモリに持つだけ。
///
/// **plist に載らない値は入れずに数える。**本物の UserDefaults と KVS はそういう値を
/// 渡されると例外で落ちる（JSON の null から来た NSNull など）。黙って入れると、
/// アプリなら落ちる書き込みがテストでは通ってしまうので、断った鍵を `rejected` に残す。
final class ETMemoryStorage: ETKeyValueStorage {
    private(set) var values: [String: Any]
    /// plist に載らない値を渡された鍵（渡された順）。
    private(set) var rejected: [String] = []
    /// set / removeObject が呼ばれた回数（中身が変わらなくても数える）。
    private(set) var writes = 0

    init(_ values: [String: Any] = [:]) {
        self.values = values
    }

    func object(forKey key: String) -> Any? { values[key] }
    func dictionary(forKey key: String) -> [String: Any]? { values[key] as? [String: Any] }
    func data(forKey key: String) -> Data? { values[key] as? Data }

    func set(_ value: Any?, forKey key: String) {
        writes += 1
        guard let value else {
            values.removeValue(forKey: key)
            return
        }
        guard PropertyListSerialization.propertyList(value, isValidFor: .binary) else {
            rejected.append(key)
            return
        }
        values[key] = value
    }

    func removeObject(forKey key: String) {
        writes += 1
        values.removeValue(forKey: key)
    }
}
