//  SkipDetector.swift
//  曲の飛ばし（スキップ）の検出。48kHz のモノラルを渡すと、曲の境目の疑いを点数にして
//  「飛んだ」「確かめている」「飛んでいない」の出来事を返す。Foundation だけ（Tests/Unit/SkipDetectorTests.swift）。
//
//  **2 段で決める。**
//  (1) 即決: 50Hz の log-mel（24 帯）の特徴量で、直近 0.3 秒と、その前の約 2.5 秒の音色・大きさ・重心を比べる。
//      点数が大きければ 0.2〜0.3 秒ぶんの音で「飛んだ」。
//  (2) 確認: 中くらいの点数は、直前の曲の拍の格子（テンポと位相）が境目のあとも続くかを約 1 秒見る。
//      格子からずれていれば飛んだ。続いていれば同じ曲の中の変化（ドロップ・ブレイク）として捨てる。
//  音量だけの変化（ブレイクで静かになる・盛り上がる）は、形（音色）を大きさで割った特徴量を使うので点数が小さい。
//  大きさの項は最大でも 0.9 なので、それだけでは確認の閾値にも届かない。
//
//  特徴量は音の流れから 20ms ごとに 1024 点（Hann）を取る（hop 960）。窓は fftSize のまま重なる。
//  点数と判定は読み手のログに全部出す（実機の飛ばしから閾値を合わせるため）。

import Foundation

struct ETSkipDetector {

    // MARK: 定数

    // 枠
    static let sampleRate = 48_000.0
    static let fftSize = 1024
    /// 20ms（1 秒に 50 枠）。
    static let hop = 960
    static let melBands = 24
    static let melLow = 40.0, melHigh = 16_000.0
    /// 溜める枠の数。10.24 秒。
    static let ringFrames = 512

    // 点数
    static let silenceDB: Float = -70
    /// 直近の窓（0.3 秒）。
    static let recentFrames = 15
    /// 直近の窓と比べる窓のあいだに空ける枠。
    static let guardFrames = 5
    /// 比べる側の窓（2.5 秒）。
    static let referenceFrames = 125
    static let minReferenceFrames = 50
    /// 比べる側を探しにいく最大の遡り。
    static let referenceSearchFrames = 400
    static let minRecentVoiced = 10
    static let shapeFloorDB: Float = 1.5
    static let levelFloorDB: Float = 2.0
    static let levelCap: Float = 6
    static let centroidFloor: Float = 0.5
    static let timbreWeight: Float = 1.0
    static let levelWeight: Float = 0.15
    static let centroidWeight: Float = 0.3
    /// 無音が続いた枠の数がこれ以上なら「間が空いた」。
    static let gapMinFrames = 4
    static let gapBonus: Float = 0.5
    static let instantThreshold: Float = 2.4
    static let confirmThreshold: Float = 1.2
    static let noGridSkipThreshold: Float = 1.8
    /// 判定のあと、次の候補を探さない枠（1.5 秒）。
    static let refractoryFrames = 75
    static let boundaryFrameZ: Float = 1.0 + 0.5
    static let boundarySustainZ: Float = 1.0

    // 拍の格子
    static let onsetHistoryFrames = 300
    static let minOnsetFrames = 150
    /// 周期の範囲（枠）。176 から 70 BPM。
    static let minLag = 17, maxLag = 43
    static let minBeatStrength: Float = 0.2
    /// 境目から確かめる枠の数（1 秒）。
    static let confirmFrames = 50
    /// 境目の枠から数えて、拍を見る窓の頭を空ける枠。境目そのものの onset（音が替わった跳ね）を拍と取り違えない。
    static let postSkipFrames = 3
    static let alignedRatio: Float = 0.6
    static let minOnsetRatio: Float = 0.3

    // MARK: 出来事

    struct Scores: Equatable {
        let score, timbre, level, centroid: Float
        let gap: Bool
        /// 比べる側に使えた枠の数。
        let referenceFrames: Int
    }

    enum Stage: Equatable {
        /// 点数だけで決めた。
        case instant
        /// 拍の格子から外れた。aligned は格子に合う度合い（0〜1）。
        case beat(aligned: Float, bpm: Float)
        /// 格子が取れない（拍の無い曲）かつ点数が高い。
        case noGrid
    }

    enum KeepReason: Equatable {
        /// 格子が続いていた。
        case aligned(Float, bpm: Float)
        /// 境目のあとに拍が見えない（判断しない）。
        case noBeat(ratio: Float)
        /// 格子が取れず、点数も高くない。
        case noGridLowScore
    }

    enum Event: Equatable {
        /// boundarySample は境目の推定（検出器が数え始めてからの標本。これより後は新しい曲の音だけ）、at は判定した時点。
        case skip(boundarySample: Int64, at: Int64, scores: Scores, stage: Stage)
        case confirming(at: Int64, scores: Scores, bpm: Float, strength: Float)
        case keep(at: Int64, scores: Scores, reason: KeepReason)
    }

    struct BeatGrid: Equatable {
        /// 拍の間（枠。小数）。
        let period: Float
        /// 自己相関の強さ。
        let strength: Float
        /// いちばん最近の拍（絶対の枠）。
        let lastBeat: Float
        var bpm: Float { 3000 / period }
    }

    // MARK: 状態

    private(set) var samplesSeen: Int64 = 0

    private let fft = ETRealFFT(size: ETSkipDetector.fftSize)
    private var powerScratch: [Float] = []
    /// まだ枠にしていない標本。bufferBase の枠が先頭。
    private var buffer: [Float] = []
    /// 次に作る枠の番号（絶対）。
    private var nextFrame = 0

    private var levelRing = [Float](repeating: -120, count: ETSkipDetector.ringFrames)
    private var centroidRing = [Float](repeating: 0, count: ETSkipDetector.ringFrames)
    private var onsetRing = [Float](repeating: 0, count: ETSkipDetector.ringFrames)
    private var voicedRing = [Bool](repeating: false, count: ETSkipDetector.ringFrames)
    private var shapeRing = [Float](repeating: 0, count: ETSkipDetector.ringFrames * ETSkipDetector.melBands)
    private var previousE = [Float](repeating: -120, count: ETSkipDetector.melBands)
    private var previousVoiced = false

    private var lastBoundaryFrame = 0
    private var refractoryUntil = 0
    private var maxScore: Float = 0

    private struct Reference {
        var mean: [Float]
        var std: [Float]
    }

    private struct Candidate {
        let openedAt: Int
        var peak: Scores
        /// 開いた枠で取った比べる側（境目の推定に使う）。
        let reference: Reference
        /// 間が空いて始まったときの、新しい曲の最初の枠。
        var gapBoundary: Int?
    }

    private struct Pending {
        let boundaryFrame: Int
        let deadline: Int
        let grid: BeatGrid
        let scores: Scores
        /// 格子を取った窓の onset の平均。
        let preEnergy: Float
    }

    private var candidate: Candidate?
    private var pending: Pending?

    // MARK: 定数の表

    private static let window: [Float] = (0..<fftSize).map {
        Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(fftSize - 1)))
    }
    /// 満点の正弦波が 0 dB になる係数。(Σw / 2)²。
    private static let norm: Double = {
        let s = Double(window.reduce(0, +)) / 2
        return s * s
    }()

    private struct Filter {
        let start: Int
        let weights: [Float]
    }

    /// 40Hz〜16kHz をメル尺で等間隔に切った三角の 24 本。ビンの無い帯は、いちばん近いビンを重み 1 で使う。
    private static let filters: [Filter] = {
        func mel(_ f: Double) -> Double { 2595 * log10(1 + f / 700) }
        func hz(_ m: Double) -> Double { 700 * (pow(10, m / 2595) - 1) }
        let lo = mel(melLow), hi = mel(melHigh)
        let points = (0..<(melBands + 2)).map { hz(lo + (hi - lo) * Double($0) / Double(melBands + 1)) }
        let binHz = sampleRate / Double(fftSize)
        let top = fftSize / 2 - 1
        return (0..<melBands).map { b in
            let left = points[b], center = points[b + 1], right = points[b + 2]
            var start = -1
            var weights: [Float] = []
            let first = max(1, Int((left / binHz).rounded(.up))), last = min(top, Int((right / binHz).rounded(.down)))
            if first <= last {
                for k in first...last {
                    let f = Double(k) * binHz
                    let w = f <= center ? (f - left) / (center - left) : (right - f) / (right - center)
                    if w > 0 {
                        if start < 0 { start = k }
                        weights.append(Float(w))
                    } else if start >= 0 {
                        weights.append(0)
                    }
                }
            }
            if start < 0 || weights.allSatisfy({ $0 == 0 }) {
                let k = min(max(Int((center / binHz).rounded()), 1), top)
                return Filter(start: k, weights: [1])
            }
            return Filter(start: start, weights: weights)
        }
    }()

    // MARK: 入口

    /// 捨てて最初から（音が飛んだ・止めた・繋ぎ直した）。
    mutating func reset() {
        samplesSeen = 0
        buffer.removeAll(keepingCapacity: true)
        nextFrame = 0
        levelRing = [Float](repeating: -120, count: Self.ringFrames)
        centroidRing = [Float](repeating: 0, count: Self.ringFrames)
        onsetRing = [Float](repeating: 0, count: Self.ringFrames)
        voicedRing = [Bool](repeating: false, count: Self.ringFrames)
        shapeRing = [Float](repeating: 0, count: Self.ringFrames * Self.melBands)
        previousE = [Float](repeating: -120, count: Self.melBands)
        previousVoiced = false
        lastBoundaryFrame = 0
        refractoryUntil = 0
        maxScore = 0
        candidate = nil
        pending = nil
    }

    /// 最後に読んでから一番高かった score（取得状況の skipScore）。読むと 0 に戻す。
    mutating func takeMaxScore() -> Float {
        defer { maxScore = 0 }
        return maxScore
    }

    /// 新しい音（モノラル 48kHz）を足して、出来事を返す。
    mutating func append(_ mono: UnsafeBufferPointer<Float>) -> [Event] {
        samplesSeen += Int64(mono.count)
        for x in mono { buffer.append(x.isFinite ? x : 0) }
        var events: [Event] = []
        var offset = 0
        while buffer.count - offset >= Self.fftSize {
            processFrame(from: offset)
            offset += Self.hop
            evaluate(nextFrame - 1, into: &events)
        }
        if offset > 0 { buffer.removeFirst(min(offset, buffer.count)) }
        return events
    }

    // MARK: 特徴量

    private func slot(_ frame: Int) -> Int { frame % Self.ringFrames }
    private func isVoiced(_ frame: Int) -> Bool { voicedRing[slot(frame)] }

    private mutating func processFrame(from offset: Int) {
        let frame = nextFrame
        let s = slot(frame)
        let samples = Array(buffer[offset..<(offset + Self.fftSize)])
        samples.withUnsafeBufferPointer { fft.power($0, window: Self.window, into: &powerScratch) }

        var total = 0.0
        for k in 1..<(Self.fftSize / 2) { total += Double(powerScratch[k]) }
        let level = Float(10 * log10(total / Self.norm + 1e-12))
        let voiced = level >= Self.silenceDB

        var energy = [Float](repeating: 0, count: Self.melBands)
        var sum = 0.0, weighted = 0.0
        for (b, filter) in Self.filters.enumerated() {
            var p = 0.0
            for (i, w) in filter.weights.enumerated() { p += Double(w) * Double(powerScratch[filter.start + i]) }
            energy[b] = Float(10 * log10(p / Self.norm + 1e-12))
            sum += p
            weighted += Double(b) * p
        }
        for b in 0..<Self.melBands {
            shapeRing[s * Self.melBands + b] = max(energy[b] - level, -80)
        }
        var onset: Float = 0
        if voiced && previousVoiced {
            for b in 0..<Self.melBands { onset += max(0, energy[b] - previousE[b]) }
            onset /= Float(Self.melBands)
        }
        levelRing[s] = level
        centroidRing[s] = sum > 0 ? Float(weighted / sum) : 0
        onsetRing[s] = onset
        voicedRing[s] = voiced
        previousE = energy
        previousVoiced = voiced
        nextFrame += 1
    }

    // MARK: 点数

    private func score(at t: Int) -> (scores: Scores, reference: Reference, firstRecent: Int)? {
        let oldest = max(0, nextFrame - Self.ringFrames)
        var recent: [Int] = []
        for f in max(t - Self.recentFrames + 1, oldest)...t where isVoiced(f) { recent.append(f) }
        guard recent.count >= Self.minRecentVoiced else { return nil }

        let newest = t - Self.recentFrames - Self.guardFrames
        let floorFrame = max(lastBoundaryFrame, oldest, newest - Self.referenceSearchFrames + 1)
        var reference: [Int] = []
        var f = newest
        while f >= floorFrame && reference.count < Self.referenceFrames {
            if isVoiced(f) { reference.append(f) }
            f -= 1
        }
        guard reference.count >= Self.minReferenceFrames else { return nil }

        let bands = Self.melBands
        var meanR = [Float](repeating: 0, count: bands), meanP = meanR, stdP = meanR
        for f in recent {
            for b in 0..<bands { meanR[b] += shapeRing[slot(f) * bands + b] }
        }
        for f in reference {
            for b in 0..<bands { meanP[b] += shapeRing[slot(f) * bands + b] }
        }
        let nR = Float(recent.count), nP = Float(reference.count)
        for b in 0..<bands {
            meanR[b] /= nR
            meanP[b] /= nP
        }
        for f in reference {
            for b in 0..<bands {
                let d = shapeRing[slot(f) * bands + b] - meanP[b]
                stdP[b] += d * d
            }
        }
        for b in 0..<bands { stdP[b] = (stdP[b] / nP).squareRoot() }

        var timbre: Float = 0
        for b in 0..<bands {
            let z = (meanR[b] - meanP[b]) / (stdP[b] + Self.shapeFloorDB)
            timbre += z * z
        }
        timbre = (timbre / Float(bands)).squareRoot()

        func stats(_ values: [Float], over frames: [Int]) -> (mean: Float, std: Float) {
            let mean = frames.reduce(0) { $0 + values[slot($1)] } / Float(frames.count)
            let variance = frames.reduce(0) { $0 + (values[slot($1)] - mean) * (values[slot($1)] - mean) } / Float(frames.count)
            return (mean, variance.squareRoot())
        }
        let levelR = stats(levelRing, over: recent), levelP = stats(levelRing, over: reference)
        let level = min(Self.levelCap, abs(levelR.mean - levelP.mean) / (levelP.std + Self.levelFloorDB))
        let centroidR = stats(centroidRing, over: recent), centroidP = stats(centroidRing, over: reference)
        let centroid = abs(centroidR.mean - centroidP.mean) / (centroidP.std + Self.centroidFloor)

        let first = recent[0]
        let gap = hasGap(before: first)
        let total = Self.timbreWeight * timbre + Self.levelWeight * level + Self.centroidWeight * centroid
            + (gap ? Self.gapBonus : 0)
        let scores = Scores(score: total, timbre: timbre, level: level, centroid: centroid, gap: gap,
                            referenceFrames: reference.count)
        return (scores, Reference(mean: meanP, std: stdP), first)
    }

    /// first の前の 10 枠に、無音が 4 枠以上続く所があるか。
    private func hasGap(before first: Int) -> Bool {
        let oldest = max(0, nextFrame - Self.ringFrames)
        var run = 0
        for f in max(first - 10, oldest)..<max(first, oldest) {
            if isVoiced(f) {
                run = 0
            } else {
                run += 1
                if run >= Self.gapMinFrames { return true }
            }
        }
        return false
    }

    // MARK: 判定

    private mutating func evaluate(_ t: Int, into events: inout [Event]) {
        let at = Int64(t * Self.hop + Self.fftSize)

        // 確かめている最中
        if let p = pending {
            if let scored = score(at: t) {
                maxScore = max(maxScore, scored.scores.score)
                if scored.scores.score >= Self.instantThreshold {
                    finishSkip(boundaryFrame: p.boundaryFrame, t: t, at: at, scores: scored.scores, stage: .instant, into: &events)
                    return
                }
            }
            if t >= p.deadline { resolvePending(p, t: t, at: at, into: &events) }
            return
        }
        if t < refractoryUntil { return }

        let scored = score(at: t)
        if let scored { maxScore = max(maxScore, scored.scores.score) }
        if candidate == nil {
            guard let scored, scored.scores.score >= Self.confirmThreshold else { return }
            candidate = Candidate(openedAt: t, peak: scored.scores, reference: scored.reference,
                                  gapBoundary: scored.scores.gap ? scored.firstRecent : nil)
        } else if let scored, scored.scores.score > candidate!.peak.score {
            candidate!.peak = scored.scores
            if scored.scores.gap && candidate!.gapBoundary == nil { candidate!.gapBoundary = scored.firstRecent }
        }
        guard let c = candidate else { return }

        if let scored, scored.scores.score >= Self.instantThreshold {
            finishSkip(boundaryFrame: estimateBoundary(c, t: t), t: t, at: at, scores: scored.scores, stage: .instant,
                       into: &events)
            return
        }
        if t >= c.openedAt + Self.recentFrames { resolveMedium(c, t: t, at: at, into: &events) }
    }

    private mutating func finishSkip(boundaryFrame: Int, t: Int, at: Int64, scores: Scores, stage: Stage,
                                     into events: inout [Event]) {
        let boundarySample = Int64(boundaryFrame * Self.hop + Self.fftSize)
        events.append(.skip(boundarySample: boundarySample, at: at, scores: scores, stage: stage))
        lastBoundaryFrame = boundaryFrame
        refractoryUntil = t + Self.refractoryFrames
        candidate = nil
        pending = nil
    }

    private mutating func finishKeep(t: Int, at: Int64, scores: Scores, reason: KeepReason, into events: inout [Event]) {
        events.append(.keep(at: at, scores: scores, reason: reason))
        refractoryUntil = t + Self.refractoryFrames
        candidate = nil
        pending = nil
    }

    /// 中くらいの点数。格子を取って、取れれば境目から 1 秒の拍を確かめる。
    private mutating func resolveMedium(_ c: Candidate, t: Int, at: Int64, into events: inout [Event]) {
        let boundaryFrame = estimateBoundary(c, t: t)
        let hi = c.openedAt - Self.recentFrames - Self.guardFrames
        let lo = max(hi - Self.onsetHistoryFrames + 1, lastBoundaryFrame, max(0, nextFrame - Self.ringFrames))
        var grid: BeatGrid?
        var preEnergy: Float = 0
        if hi >= lo && hi - lo + 1 >= Self.minOnsetFrames {
            let onsets = (lo...hi).map { onsetRing[slot($0)] }
            grid = Self.beatGrid(onsets, firstFrame: lo)
            preEnergy = onsets.reduce(0, +) / Float(onsets.count)
        }
        guard let grid else {
            if c.peak.score >= Self.noGridSkipThreshold {
                finishSkip(boundaryFrame: boundaryFrame, t: t, at: at, scores: c.peak, stage: .noGrid, into: &events)
            } else {
                finishKeep(t: t, at: at, scores: c.peak, reason: .noGridLowScore, into: &events)
            }
            return
        }
        events.append(.confirming(at: at, scores: c.peak, bpm: grid.bpm, strength: grid.strength))
        pending = Pending(boundaryFrame: boundaryFrame, deadline: boundaryFrame + Self.confirmFrames, grid: grid,
                          scores: c.peak, preEnergy: preEnergy)
        candidate = nil
    }

    private mutating func resolvePending(_ p: Pending, t: Int, at: Int64, into events: inout [Event]) {
        let oldest = max(0, nextFrame - Self.ringFrames)
        let start = max(p.boundaryFrame + Self.postSkipFrames, oldest)
        let post = start <= t ? (start...t).map { onsetRing[slot($0)] } : []
        let postEnergy = post.isEmpty ? 0 : post.reduce(0, +) / Float(post.count)
        let ratio = p.preEnergy > 0 ? postEnergy / p.preEnergy : 1
        if postEnergy < Self.minOnsetRatio * p.preEnergy {
            finishKeep(t: t, at: at, scores: p.scores, reason: .noBeat(ratio: ratio), into: &events)
            return
        }
        let result = Self.alignment(post: post, postStart: start, grid: p.grid)
        if result.best <= 1e-6 {
            finishKeep(t: t, at: at, scores: p.scores, reason: .noBeat(ratio: ratio), into: &events)
        } else if result.aligned < Self.alignedRatio {
            finishSkip(boundaryFrame: p.boundaryFrame, t: t, at: at, scores: p.scores,
                       stage: .beat(aligned: result.aligned, bpm: p.grid.bpm), into: &events)
        } else {
            finishKeep(t: t, at: at, scores: p.scores, reason: .aligned(result.aligned, bpm: p.grid.bpm), into: &events)
        }
    }

    /// 境目の枠の推定。候補が開く 15 枠前から今までで、比べる側からの距離 d_f が 1.5 以上になり、
    /// 続く 3 枠が 1.0 以上の最初の枠。間が空いていれば、その後の最初の音のある枠。見つからなければ 15 枠前と今の真ん中。
    private func estimateBoundary(_ c: Candidate, t: Int) -> Int {
        if let g = c.gapBoundary { return g }
        let oldest = max(0, nextFrame - Self.ringFrames)
        let lo = max(c.openedAt - Self.recentFrames, lastBoundaryFrame, oldest)
        func distance(_ f: Int) -> Float {
            var sum: Float = 0
            for b in 0..<Self.melBands {
                let z = (shapeRing[slot(f) * Self.melBands + b] - c.reference.mean[b]) / (c.reference.std[b] + Self.shapeFloorDB)
                sum += z * z
            }
            return (sum / Float(Self.melBands)).squareRoot()
        }
        if lo <= t {
            for f in lo...t where isVoiced(f) && distance(f) >= Self.boundaryFrameZ {
                var sustained = true
                for g in (f + 1)...max(f + 1, min(f + 3, t)) where g <= t {
                    if isVoiced(g) && distance(g) < Self.boundarySustainZ {
                        sustained = false
                        break
                    }
                }
                if sustained { return f }
            }
        }
        return max(c.openedAt - Self.recentFrames / 2, lastBoundaryFrame)
    }

    // MARK: 拍の格子

    /// onset の列（古い順。先頭の枠の番号が firstFrame）からテンポと位相。150 枠に満たない・拍が弱いなら nil。
    /// 周期は 17〜43 枠の自己相関（長さの偏りを n/(n−L) で戻す）の最大を放物線で詰めたもの。
    /// 位相は周期ごとに onset を足し込んで最大の所（いちばん最近の拍）。
    static func beatGrid(_ onsets: [Float], firstFrame: Int) -> BeatGrid? {
        let n = onsets.count
        guard n >= minOnsetFrames, n > maxLag else { return nil }
        let mean = onsets.reduce(0, +) / Float(n)
        let x = onsets.map { $0 - mean }
        let energy = x.reduce(0) { $0 + $1 * $1 }
        guard energy > 1e-9 else { return nil }

        var ac = [Float](repeating: 0, count: maxLag + 2)
        for lag in minLag...maxLag {
            var sum: Float = 0
            for f in lag..<n { sum += x[f] * x[f - lag] }
            ac[lag] = sum / energy * Float(n) / Float(n - lag)
        }
        var best = minLag
        for lag in minLag...maxLag where ac[lag] > ac[best] { best = lag }
        let strength = ac[best]
        guard strength >= minBeatStrength else { return nil }

        var period = Float(best)
        if best > minLag && best < maxLag {
            let y0 = ac[best - 1], y1 = ac[best], y2 = ac[best + 1]
            let denominator = y0 - 2 * y1 + y2
            if denominator < 0 { period += min(max(0.5 * (y0 - y2) / denominator, -0.5), 0.5) }
        }

        var bestK = 0
        var bestSum = -Float.infinity
        for k in 0..<Int(period.rounded()) {
            var sum: Float = 0
            var m = 0
            while true {
                let index = n - 1 - k - Int((Float(m) * period).rounded())
                if index < 0 { break }
                sum += x[index]
                m += 1
            }
            if sum > bestSum {
                bestSum = sum
                bestK = k
            }
        }
        return BeatGrid(period: period, strength: strength, lastBeat: Float(firstFrame + n - 1 - bestK))
    }

    /// 境目のあとの onset（post。先頭の枠の番号が postStart）が、格子の予想の拍に載っているか。
    /// 予想の拍 b_j = lastBeat + j·period を ±1 枠で拾った onset の平均 A(s) を、格子を s 枠ずらして並べ、
    /// ずらさない A(0) がずらした最大の何割か（aligned）。onset は平均を引いた正の部分。
    static func alignment(post: [Float], postStart: Int, grid: BeatGrid) -> (aligned: Float, best: Float) {
        guard !post.isEmpty, grid.period > 1 else { return (0, 0) }
        let mean = post.reduce(0, +) / Float(post.count)
        let x = post.map { max($0 - mean, 0) }
        // 予想の拍（窓の中のもの）
        let first = Int(((Float(postStart) - grid.lastBeat) / grid.period).rounded(.up)) - 1
        let last = Int(((Float(postStart + post.count) - grid.lastBeat) / grid.period).rounded(.down)) + 1
        var beats: [Int] = []
        for j in first...max(first, last) {
            let position = Int((grid.lastBeat + Float(j) * grid.period).rounded())
            if position >= postStart && position < postStart + post.count { beats.append(position) }
        }
        guard !beats.isEmpty else { return (0, 0) }

        let half = Int(grid.period / 2)
        let upper = Int((grid.period / 2).rounded(.up))
        var a0: Float = 0
        var best: Float = 0
        for shift in -half..<upper {
            var sum: Float = 0
            for position in beats {
                var peak: Float = 0
                for d in -1...1 {
                    let index = position + shift + d - postStart
                    if index >= 0 && index < x.count { peak = max(peak, x[index]) }
                }
                sum += peak
            }
            let a = sum / Float(beats.count)
            if shift == 0 { a0 = a }
            best = max(best, a)
        }
        guard best > 1e-6 else { return (0, best) }
        return (a0 / best, best)
    }
}
