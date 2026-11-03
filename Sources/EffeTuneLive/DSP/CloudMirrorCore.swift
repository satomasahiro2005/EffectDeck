//  CloudMirrorCore.swift
//  iCloud へ写す・iCloud から戻すときの決まり。**Foundationだけ。**
//
//  CloudMirror.swift から出した。あちらは NSUbiquitousKeyValueStore（Linux に無い）と
//  ログと通知を持つ。こちらは入れ物を 2 つ受け取って、何を書くか・何を戻すかだけを決める。
//  決まりそのもの（写すのは触った項目だけ、戻すのは手元が空の鍵だけ、大きすぎたら
//  前の写しを残す）の理由は CloudMirror.swift の頭に書いてある。ここでは繰り返さない。
//
//  **撮影用の起動（-ETSeed）かどうかは引数で受ける**（`seeded`）。ここで
//  ETScreenshotSeed を引くと、テストが UserDefaults の引数に左右される。

import Foundation

/// iCloud 側へ当てる 1 項目。`path` は外側から順の鍵、`value` が nil なら消す。
struct CloudChange {
    var path: [String]
    var value: Any?
}

/// 辞書の中の項目を iCloud へ当てる口（CloudMirror.patch）。
/// 1 回の呼び出しで渡したものは、iCloud の 1 回の書き込みにまとまる。
typealias CloudPatch = (_ key: String, _ changes: [CloudChange]) -> Void

struct CloudMirrorCore {

    /// 1 鍵ぶんの上限。全体も 1MB なので、3 鍵で分け合っても当たらない所で切る。
    /// 鎖 1 本は数百バイト、プリセットも短い辞書なので普通は届かない。
    static let byteLimit = 256 * 1024

    /// 書いた・書かなかった理由。ログを出すのは呼ぶ側（CloudMirror）。
    enum Outcome: Equatable {
        /// 書いた。載せたときの大きさ。
        case written(bytes: Int)
        /// 鍵ごと消した。
        case removed
        /// 撮影用の起動なので何もしない。
        case disabled
        /// 当てる項目が無かった（path が空など）。書いていない。
        case unchanged
        /// plist に載らない形。書いていない。
        case unencodable
        /// 上限を超える。**前の写しはそのまま残る。**
        case tooLarge(bytes: Int)
    }

    /// 戻したもの。
    struct Restored: Equatable {
        /// 鎖を戻したならその大きさ。
        var chainBytes: Int?
        /// 戻した辞書の鍵と、その項目数（渡した順）。
        var dictionaries: [Entry] = []

        struct Entry: Equatable {
            var key: String
            var count: Int
        }

        /// 鎖を戻した。**画面へ入れ直す（onChainRestored）のはこれが真のときだけ。**
        var chain: Bool { chainBytes != nil }
    }

    let cloud: ETKeyValueStorage
    /// 撮影用の起動（-ETSeed）。真なら何も写さず、何も戻さない。
    let seeded: Bool

    // MARK: - 写す

    /// 値を 1 鍵まるごと写す。nil なら鍵を消す。鎖（pipeline.last）のように値が 1 つのものに使う。
    @discardableResult
    func mirror(_ value: Any?, forKey key: String) -> Outcome {
        guard !seeded else { return .disabled }
        guard let value else {
            cloud.removeObject(forKey: key)
            return .removed
        }
        return write(value, forKey: key)
    }

    /// 辞書の中の項目だけを当てる。全部を当ててから 1 回だけ書く。
    @discardableResult
    func patch(key: String, changes: [CloudChange]) -> Outcome {
        guard !seeded else { return .disabled }
        var root = cloud.dictionary(forKey: key) ?? [:]
        var touched = false
        for change in changes {
            if Self.apply(&root, path: change.path[...], value: change.value) { touched = true }
        }
        guard touched else { return .unchanged }
        return write(root, forKey: key)
    }

    /// 大きさを測ってから書く。**載らない・大きすぎるときは消さない。**
    /// 写せないときに消すと、前に写した分まで失う。古い写しでも、何も無いよりは戻せる。
    private func write(_ value: Any, forKey key: String) -> Outcome {
        guard let size = Self.storedSize(of: value) else { return .unencodable }
        guard size <= Self.byteLimit else { return .tooLarge(bytes: size) }
        cloud.set(value, forKey: key)
        return .written(bytes: size)
    }

    /// path をたどって当てる。当てたら true（path が空のときだけ false）。
    ///
    /// 途中に辞書でない値が在れば辞書に置き換える。`value` が nil ならその項目を消し、
    /// 消した結果その枝が空になったら枝ごと落とす（上流も plugin-preset-store.js:159 でそうしている）。
    static func apply(_ node: inout [String: Any],
                      path: ArraySlice<String>,
                      value: Any?) -> Bool {
        guard let head = path.first else { return false }
        let rest = path.dropFirst()

        if rest.isEmpty {
            if let value {
                node[head] = value
            } else {
                node.removeValue(forKey: head)
            }
            return true
        }

        var child = node[head] as? [String: Any] ?? [:]
        guard apply(&child, path: rest, value: value) else { return false }
        if child.isEmpty {
            node.removeValue(forKey: head)
        } else {
            node[head] = child
        }
        return true
    }

    /// 載せたときの大きさ。載せられなければ nil。
    ///
    /// **Data はそのまま数える。**plist の根に scalar を置けるかどうかを
    /// 確かめられない所で書いているので、確かめずに済む形にする。
    /// 鎖（pipeline.last）は Data なので必ずこちらを通る。もし
    /// PropertyListSerialization が根の Data を断る実装なら、鎖は一度も
    /// 写らないまま「写している」と読める形になっていた。
    static func storedSize(of value: Any) -> Int? {
        if let data = value as? Data { return data.count }
        let plist = try? PropertyListSerialization.data(fromPropertyList: value,
                                                        format: .binary,
                                                        options: 0)
        return plist?.count
    }

    // MARK: - 戻す

    /// **手元がまだ空の鍵だけ**戻す。手元に何か在る鍵は、iCloud に何が在っても触らない。
    ///
    /// `chainKey` は Data で持つ鎖、`dictionaryKeys` は辞書で持つもの（プリセット 2 種）。
    func seed(into device: ETKeyValueStorage,
              chainKey: String,
              dictionaryKeys: [String]) -> Restored {
        var out = Restored()
        guard !seeded else { return out }

        if device.object(forKey: chainKey) == nil, let data = cloud.data(forKey: chainKey) {
            device.set(data, forKey: chainKey)
            out.chainBytes = data.count
        }

        for key in dictionaryKeys {
            guard device.object(forKey: key) == nil, let d = cloud.dictionary(forKey: key) else { continue }
            device.set(d, forKey: key)
            out.dictionaries.append(.init(key: key, count: d.count))
        }
        return out
    }
}
