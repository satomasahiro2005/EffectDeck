//  SHA256.swift（Linuxの代役）
//  CryptoKitのSHA256だけを、Tests/Linux/run.shの中で置き換える。**製品には入らない。**
//  使っているのはIRLibrary（IRの鍵）とETJSFXHost（JSFXの識別子）の
//  `SHA256.hash(data:)` と、その答えを1バイトずつ読むことだけ。
//  中身はFIPS 180-4のとおり。

import Foundation

public struct SHA256Digest: Sequence, Hashable, CustomStringConvertible, Sendable {
    let bytes: [UInt8]
    public static let byteCount = 32
    public func makeIterator() -> IndexingIterator<[UInt8]> { bytes.makeIterator() }
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try bytes.withUnsafeBytes(body)
    }
    public var description: String {
        "SHA256 digest: " + bytes.map { String(format: "%02x", $0) }.joined()
    }
}

public struct SHA256: Sendable {
    public typealias Digest = SHA256Digest
    public static let byteCount = 32
    public static let blockByteCount = 64

    private var h: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]
    private var pending: [UInt8] = []
    private var length: UInt64 = 0

    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    public init() {}

    public static func hash<D: DataProtocol>(data: D) -> SHA256Digest {
        var hasher = SHA256()
        hasher.update(data: data)
        return hasher.finalize()
    }

    public mutating func update<D: DataProtocol>(data: D) {
        for region in data.regions {
            region.withUnsafeBytes { raw in update(raw) }
        }
    }

    public mutating func update(bufferPointer: UnsafeRawBufferPointer) { update(bufferPointer) }

    private mutating func update(_ raw: UnsafeRawBufferPointer) {
        length &+= UInt64(raw.count)
        pending.append(contentsOf: raw)
        var offset = 0
        while pending.count - offset >= 64 {
            compress(pending, offset)
            offset += 64
        }
        if offset > 0 { pending.removeFirst(offset) }
    }

    public func finalize() -> SHA256Digest {
        var copy = self
        let bits = length &* 8
        copy.pending.append(0x80)
        while copy.pending.count % 64 != 56 { copy.pending.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { copy.pending.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift))) }
        var offset = 0
        while offset < copy.pending.count {
            copy.compress(copy.pending, offset)
            offset += 64
        }
        var out = [UInt8]()
        out.reserveCapacity(32)
        for word in copy.h {
            out.append(UInt8(truncatingIfNeeded: word >> 24))
            out.append(UInt8(truncatingIfNeeded: word >> 16))
            out.append(UInt8(truncatingIfNeeded: word >> 8))
            out.append(UInt8(truncatingIfNeeded: word))
        }
        return SHA256Digest(bytes: out)
    }

    private mutating func compress(_ block: [UInt8], _ offset: Int) {
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        var w = [UInt32](repeating: 0, count: 64)
        for t in 0..<16 {
            let i = offset + t * 4
            w[t] = UInt32(block[i]) << 24 | UInt32(block[i + 1]) << 16 | UInt32(block[i + 2]) << 8 | UInt32(block[i + 3])
        }
        for t in 16..<64 {
            let s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
            let s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
            w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
        }
        var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
        for t in 0..<64 {
            let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let ch = (e & f) ^ (~e & g)
            let t1 = hh &+ s1 &+ ch &+ SHA256.k[t] &+ w[t]
            let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let t2 = s0 &+ maj
            hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
        }
        h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d
        h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
    }
}
