//  ExternalSlotAllocator.swift
//  外部処理（AU / JSFX）のインスタンスを、ETPipeline の枠番号へ割り当てる。
//
//  **ETPipeline に触らない。** 番号を配るだけ（ExternalSlotAllocatorTests）。
//  枠の数は ET_EXTERNAL_MAX_PROCESSORS（ETPipeline.h）で、ETAUExternalBridge が
//  その値を渡して作る。ここに 8 を書かないのは、C と食い違わないため。
//
//  約束:
//    - 同じ id には同じ番号を返す（鎖の記述子が番号で指しているので、動かすと別物を指す）
//    - 空いた番号は再び使う。空いている中でいちばん小さい番号から配る
//    - 枠が埋まっていたら nil（呼び出し側が「上限は 8」と出す）
//    - removeAll で全部空ける。suspend（音を止めただけ）では呼ばない

import Foundation

struct ETExternalSlotAllocator {

    /// 枠の数。番号は 0..<capacity。UInt8 に収まるよう 0〜256 に押さえる。
    let capacity: Int

    /// id → 番号。
    private(set) var slots: [String: UInt8] = [:]

    init(capacity: Int) {
        self.capacity = min(256, max(0, capacity))
    }

    /// id に番号を割り当てる。既に持っていればそれを返す。埋まっていれば nil。
    mutating func reserve(_ instanceID: String) -> UInt8? {
        if let index = slots[instanceID] { return index }
        let used = Set(slots.values)
        guard let free = (0..<capacity).first(where: { !used.contains(UInt8($0)) }) else {
            return nil
        }
        let index = UInt8(free)
        slots[instanceID] = index
        return index
    }

    func index(for instanceID: String) -> UInt8? { slots[instanceID] }

    /// 番号を返す。持っていなければ nil。
    @discardableResult
    mutating func release(_ instanceID: String) -> UInt8? {
        slots.removeValue(forKey: instanceID)
    }

    mutating func removeAll() { slots.removeAll() }
}
