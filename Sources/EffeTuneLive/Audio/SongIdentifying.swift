//  SongIdentifying.swift
//  曲の「取得中」の見せ方の状態。Foundation だけ（Tests/Unit/SongIdentifyingTests.swift）。
//
//  取得中は、アートワークの要素が NCS の粒に替わる（重み 1）。新しい曲が決まったら 0.6 秒かけて
//  新しいアートワークへ切り替える（revealing）。取得中の粒の色は、前のアートワークの色から
//  8 秒かけて NCS の既定の色へ戻す。時刻は呼び手が渡す（CACurrentMediaTime）。

import Foundation

struct ETSongIdentifying: Equatable {
    /// 新しい曲が決まってから、粒が消えてアートワークになりきるまで。
    static let revealDuration: TimeInterval = 0.6
    /// 粒の色が前のアートワークの色から既定の色へ戻りきるまで。
    static let tintFade: TimeInterval = 8

    enum Phase: Equatable {
        case idle
        case identifying(since: TimeInterval)
        case revealing(since: TimeInterval)
    }

    private(set) var phase: Phase = .idle
    /// 前のアートワークの色。無ければ既定の色から始まる。
    private(set) var tint: ETVisualizerColor?
    /// 取得中に入った時刻（色の戻りの起点）。
    private(set) var startedAt: TimeInterval = 0

    /// 取得中に入る。すでに取得中なら何も替えない（起点と色を守る）。
    mutating func begin(now: TimeInterval, tint: ETVisualizerColor?) {
        if case .identifying = phase { return }
        phase = .identifying(since: now)
        startedAt = now
        self.tint = tint
    }

    /// 新しい曲が決まった。取得中のときだけ、粒からアートワークへの切り替えを始める。
    mutating func reveal(now: TimeInterval) {
        guard case .identifying = phase else { return }
        phase = .revealing(since: now)
    }

    /// 取得中をやめる（間違いだった・音が止まった）。すぐ元のアートワークに戻る。
    mutating func cancel() {
        phase = .idle
    }

    /// 切り替えが終わっていたら idle に戻す。
    mutating func settle(now: TimeInterval) {
        if case .revealing(let since) = phase, now - since >= Self.revealDuration { phase = .idle }
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// 粒の重み。0 でアートワークだけ、1 で粒だけ。
    func weight(now: TimeInterval) -> Double {
        switch phase {
        case .idle: return 0
        case .identifying: return 1
        case .revealing(let since): return 1 - Self.smoothstep(0, Self.revealDuration, now - since)
        }
    }

    /// 粒の色。前のアートワークの色（無ければ fallback）から fallback へ、チャンネルごとに混ぜて 8 bit に丸める。
    func color(now: TimeInterval, fallback: ETVisualizerColor) -> ETVisualizerColor {
        let from = tint ?? fallback
        let t = Self.smoothstep(0, Self.tintFade, now - startedAt)
        func channel(_ shift: UInt32) -> UInt32 {
            let a = Double((from.rgb >> shift) & 0xFF), b = Double((fallback.rgb >> shift) & 0xFF)
            return UInt32(min(max((a + (b - a) * t).rounded(), 0), 255))
        }
        return ETVisualizerColor((channel(16) << 16) | (channel(8) << 8) | channel(0))
    }
}
