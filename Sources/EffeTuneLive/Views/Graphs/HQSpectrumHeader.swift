import Foundation

/// Version 2 header shared by Spectrum Analyzer and Spectrogram in EffeTune 2.10.0.
struct ETHQSpectrumHeader {
    let rate: Double
    let points: Int
    let count: Int
    let time: Double

    init?(frame: ETFrame, spectrum: Bool) {
        let p = frame.payloadView
        guard frame.version == 2, let rate = p.f32(at: 0), rate.isFinite, rate > 0,
              let points = p.u16(at: 4), (8...14).contains(points),
              p.u16(at: 6) == 0, let hop = p.u32(at: 8),
              let generation = p.u32(at: 12), generation != 0,
              let low = p.u32(at: 16), let high = p.u32(at: 20),
              let count = p.u32(at: 28), count == (spectrum ? 2048 : 256),
              p.f32(at: 32) == 20, p.f32(at: 36) == 40000,
              let first = p.u32(at: 40), let valid = p.u32(at: 44),
              p.count == 48 + Int(count) * (spectrum ? 8 : 1) else { return nil }
        let expectedHop = spectrum ? max((1 << Int(points)) / 2, Int(ceil(Double(rate) / 30))) : (1 << Int(points)) / 2
        guard Int(hop) == expectedHop else { return nil }
        let validIndices = (0..<Int(count)).filter { i in
            let ascending = spectrum ? i : Int(count) - 1 - i
            return 20 * pow(2000, Double(ascending) / Double(count - 1)) <= Double(rate) / 2
        }
        guard Int(first) == (validIndices.first ?? 0), Int(valid) == validIndices.count else { return nil }
        self.rate = Double(rate)
        self.points = Int(points)
        self.count = Int(count)
        time = Double(UInt64(high) << 32 | UInt64(low)) / Double(rate)
    }
}
