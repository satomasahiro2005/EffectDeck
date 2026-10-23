//  Automation.swift
//  カード1枚ぶんのオートメーション。**Foundationだけ。**
//
//  入力の元（source）を1つ決め、元の位置ごとにカードのパラメータ全部の控え（キーフレーム）を持つ。
//  鳴らす値は、いまの位置を挟む2つのキーフレームの補間。
//  v1の元は出力の音量（AVAudioSession.outputVolume、0〜100%）だけ。元を足しても保存形式は変えない
//  （`src`の綴りを足すだけ。知らない`src`は読まずに捨てる）。
//
//  **保存するのはキーフレームだけ。**補間した値は鳴らすためだけの値で、段の保存値・プリセット・
//  pipeline.last・iCloud・PC には書かない（EffeTuneDSP.applyAutomation）。
//  段の values は、一番上（音量が一番大きい）のキーフレームの値と常に同じ（ETChainNode.automation）。
//  画面はキーフレーム1つにつきカード1枚（Views/KeyframeSheet.swift）で、どれも同時に直せる。
//  「選んでいるキーフレーム」は持たない。
//
//  補間の規則（元に依らない）:
//    - dB・リニアの利得は直線、Hz と Q は対数（下限が0でも、両端が正なら対数）、そのほかの数は直線
//    - 刻みが1より粗い数（フィルタの傾き12 dB/octなど）は、補間した値を刻みへ丸める（カーネルが中間の値を受けない）
//    - 入切・選択肢（PEQ のフィルタ種別など）は2つの真ん中で切り替える
//    - 15Band / 5Band PEQ は、同じ帯でフィルタ種別か入切が違うときだけ切り替えずに0 dBを通って移る
//    - 範囲の外は端のキーフレームのまま。1つなら全位置でそれ
//    - 遅延を変える設定（オーバーサンプリングなど）は補間せず、全キーフレームで同じ値にする

import Foundation

struct ETAutomation: Equatable {

    /// 保存形式の段の鍵（ショートは段の直下、ロングは `name` の隣）。
    static let key = "automation"
    static let maxKeyframes = 64

    /// 元。**足すときは保存形式の綴りを足すだけ。**
    enum Source: String, CaseIterable {
        /// 物理の出力音量（%）。
        case outputVolume = "outputVolume"

        var range: ClosedRange<Double> { 0...100 }
        var step: Double { 5 }

        func label(_ position: Double) -> String { "\(Int(position.rounded()))%" }

        /// 刻みへ丸めて範囲へ収める。
        func snapped(_ p: Double) -> Double {
            guard p.isFinite else { return range.upperBound }
            let s = (p / step).rounded() * step
            return min(max(s, range.lowerBound), range.upperBound)
        }

        /// AVAudioSession.outputVolume（0〜1）→ 位置。
        func position(fromVolume v: Float) -> Double {
            min(max(Double(v) * 100, range.lowerBound), range.upperBound)
        }

        /// 刻みの位置すべて（0, 5, … 100）。
        var positions: [Double] {
            var out: [Double] = []
            var p = range.lowerBound
            while p <= range.upperBound + 0.001 {
                out.append(p)
                p += step
            }
            return out
        }
    }

    struct Keyframe: Equatable {
        var position: Double
        var values: [Float]
    }

    /// 補間のしかた。
    enum Blend: Equatable { case hold, step, linear, logarithmic }

    let source: Source
    /// 空でなく、位置は昇順で重ならない。
    private(set) var keyframes: [Keyframe]

    /// 同じ位置を同じと見る幅。
    private static let epsilon = 0.001

    /// 1つ目のキーフレームだけ。
    init(source: Source, position: Double, values: [Float]) {
        self.source = source
        self.keyframes = [Keyframe(position: source.snapped(position), values: values)]
    }

    /// 整えて作る。位置が有限でないものは捨て、範囲へ収め、昇順にし、同じ位置は先のものを残す。
    /// 値の数が spec と違うものも捨てる。遅延に関わる設定は一番上のものに揃える。
    /// 残るものが無ければ nil。
    init?(source: Source, keyframes input: [Keyframe], spec: ETEffect) {
        let kept = input.enumerated().filter {
            $0.element.position.isFinite && $0.element.values.count == spec.floatCount
        }
        let sorted = kept.sorted {
            let a = Self.clamp($0.element.position, source), b = Self.clamp($1.element.position, source)
            return a != b ? a < b : $0.offset < $1.offset
        }
        var out: [Keyframe] = []
        for (_, k) in sorted {
            let p = Self.clamp(k.position, source)
            if let last = out.last, abs(last.position - p) < Self.epsilon { continue }
            out.append(Keyframe(position: p, values: k.values))
            if out.count == Self.maxKeyframes { break }
        }
        guard !out.isEmpty else { return nil }
        self.source = source
        self.keyframes = out
        self.shareHeld(from: out.count - 1, spec: spec)
    }

    private static func clamp(_ p: Double, _ source: Source) -> Double {
        min(max(p, source.range.lowerBound), source.range.upperBound)
    }

    /// 一番上のキーフレームの値。段の values はこれと同じ（保存・PC・音量が読めないときの値）。
    var topValues: [Float] { keyframes[keyframes.count - 1].values }

    // MARK: - 操作

    /// その位置にキーフレームを足し、その添字を返す。もうあればそれの添字を返すだけ。いっぱいなら nil。
    /// 新しいものは一番近いキーフレームの写し（同じ近さなら位置の低い方）。
    @discardableResult
    mutating func add(at position: Double) -> Int? {
        let p = source.snapped(position)
        if let i = keyframes.firstIndex(where: { abs($0.position - p) < Self.epsilon }) { return i }
        guard keyframes.count < Self.maxKeyframes else { return nil }
        var nearest = 0
        for i in keyframes.indices
        where abs(keyframes[i].position - p) < abs(keyframes[nearest].position - p) {
            nearest = i
        }
        let at = keyframes.firstIndex(where: { $0.position > p }) ?? keyframes.count
        keyframes.insert(Keyframe(position: p, values: keyframes[nearest].values), at: at)
        return at
    }

    /// k 番目のキーフレームを消す。最後の1つ・範囲の外は消さずに false。
    @discardableResult
    mutating func remove(at k: Int) -> Bool {
        guard keyframes.count > 1, keyframes.indices.contains(k) else { return false }
        keyframes.remove(at: k)
        return true
    }

    /// k 番目のキーフレームの位置を動かし、並べ直したあとの添字を返す。
    /// 刻みへ丸めて範囲へ収める。k が範囲の外か、動かし先に別のキーフレームが居れば何もせず nil。
    @discardableResult
    mutating func move(_ k: Int, to position: Double) -> Int? {
        guard keyframes.indices.contains(k) else { return nil }
        let p = source.snapped(position)
        if abs(keyframes[k].position - p) < Self.epsilon { return k }
        guard !keyframes.contains(where: { abs($0.position - p) < Self.epsilon }) else { return nil }
        var kf = keyframes.remove(at: k)
        kf.position = p
        let at = keyframes.firstIndex(where: { $0.position > p }) ?? keyframes.count
        keyframes.insert(kf, at: at)
        return at
    }

    /// k 番目のキーフレームの値を差し替える。遅延に関わる設定は全キーフレームへ写す。
    /// 数が合わない値・範囲の外の k は受けない。
    mutating func store(_ values: [Float], at k: Int, spec: ETEffect) {
        guard keyframes.indices.contains(k), values.count == keyframes[k].values.count else { return }
        keyframes[k].values = values
        shareHeld(from: k, spec: spec)
    }

    /// 補間しない設定（held）を k 番目のキーフレームの値に揃える。
    private mutating func shareHeld(from k: Int, spec: ETEffect) {
        let held = Self.heldOffsets(spec)
        guard !held.isEmpty else { return }
        let source = keyframes[k].values
        for i in keyframes.indices where i != k {
            for o in held where source.indices.contains(o) && keyframes[i].values.indices.contains(o) {
                keyframes[i].values[o] = source[o]
            }
        }
    }

    // MARK: - 位置

    /// まだキーフレームの無い刻みの位置（昇順）。
    func freePositions() -> [Double] {
        source.positions.filter { p in
            !keyframes.contains(where: { abs($0.position - p) < Self.epsilon })
        }
    }

    /// 足すときの既定の位置。いまの位置（読めなければ上限）の刻みが空いていればそこ、
    /// 塞がっていれば±1刻み・±2刻み…と近い空きを探す（同じ近さなら低い方）。空きが無ければ nil。
    func defaultAddPosition(current: Double?) -> Double? {
        let free = freePositions()
        guard !free.isEmpty else { return nil }
        let start = source.snapped(current ?? source.range.upperBound)
        return free.min {
            let a = abs($0 - start), b = abs($1 - start)
            return a != b ? a < b : $0 < $1
        }
    }

    /// 「+」に出す空きの位置と既定。まだ追従していない（a が nil）なら刻みの全部が空き。
    static func addChoices(_ a: ETAutomation?, source: Source = .outputVolume,
                           current: Double?) -> (free: [Double], suggested: Double?) {
        guard let a else {
            return (source.positions, source.snapped(current ?? source.range.upperBound))
        }
        return (a.freePositions(), a.defaultAddPosition(current: current))
    }

    // MARK: - 補間

    /// 補間しないパラメータ。遅延を変えるもの（鎖を組み直さないと動かない）と実行時の旗。
    static let heldNames: Set<String> = ["oversampling", "lookahead", "latencyMode", "latency"]

    private static func isHeld(_ p: ETParam) -> Bool {
        p.runtimeOnly || heldNames.contains(p.name)
    }

    /// 補間しない設定の位置。
    static func heldOffsets(_ spec: ETEffect) -> [Int] {
        spec.params.filter(isHeld).flatMap { Array($0.offset..<($0.offset + $0.count)) }
    }

    static func blend(of p: ETParam) -> Blend {
        if isHeld(p) { return .hold }
        switch p.kind {
        case .toggle, .enumeration:
            return .step
        case .number(_, _, _, let unit, _):
            // 保存しているのが対数の値（Tilt EQ の Pivot は ln(Hz)）なら、保存値の直線が Hz の対数になっている。
            if p.scale != .direct { return .linear }
            // 両端のどちらかが0以下なら mix が直線に落とす。
            if unit == "Hz" || unit == "kHz" || unit == "Q" || p.name == "q" || p.name.hasSuffix("Q") {
                return .logarithmic
            }
            return .linear
        }
    }

    /// 刻みが1より粗い数の格子（下限・刻み・上限）。保存値が画面の値と同じものだけ。
    /// フィルタの傾き（12 dB/oct 刻み）などは、刻みの外の値をカーネルが受けない。
    private static func grid(of p: ETParam) -> (min: Float, step: Float, max: Float)? {
        guard p.scale == .direct, case .number(let lo, let hi, let step, _, _) = p.kind,
              step > 1, lo.isFinite, hi.isFinite, hi > lo else { return nil }
        return (lo, step, hi)
    }

    /// その位置で鳴らす値。`current` は段の今の値（補間しない設定はそこから取る）。
    /// 位置が nil（音量を一度も読めていない）なら一番上のキーフレーム。
    /// 値の数が合わないキーフレームがあれば `current` のまま。
    func values(at position: Double?, spec: ETEffect, current: [Float]) -> [Float] {
        guard keyframes.allSatisfy({ $0.values.count == current.count }) else { return current }

        let a: Keyframe, b: Keyframe
        var t: Float = 0
        if let pos = position, pos.isFinite {
            if pos <= keyframes[0].position {
                a = keyframes[0]; b = a
            } else if pos >= keyframes[keyframes.count - 1].position {
                a = keyframes[keyframes.count - 1]; b = a
            } else {
                let i = keyframes.lastIndex(where: { $0.position <= pos }) ?? 0
                a = keyframes[i]; b = keyframes[i + 1]
                t = Float((pos - a.position) / (b.position - a.position))
            }
        } else {
            a = keyframes[keyframes.count - 1]; b = a
        }

        var out = current
        for p in spec.params {
            let blend = Self.blend(of: p)
            guard blend != .hold else { continue }
            var isInteger = false
            if case .number(_, _, _, _, let integer) = p.kind { isInteger = integer }
            let grid = Self.grid(of: p)
            for o in p.offset..<(p.offset + p.count) where out.indices.contains(o) {
                out[o] = Self.mix(a.values[o], b.values[o], t: t, blend: blend, isInteger: isInteger, grid: grid)
            }
        }
        Self.fadePEQ(&out, a: a.values, b: b.values, t: t, spec: spec)
        return out
    }

    private static func mix(_ a: Float, _ b: Float, t: Float, blend: Blend, isInteger: Bool,
                            grid: (min: Float, step: Float, max: Float)?) -> Float {
        if t <= 0 || a == b { return a }
        if t >= 1 { return b }
        var v: Float
        switch blend {
        case .hold, .step:
            v = t < 0.5 ? a : b
        case .linear:
            v = a + (b - a) * t
        case .logarithmic:
            if a > 0 && b > 0 {
                let la = log(Double(a)), lb = log(Double(b))
                v = Float(exp(la + (lb - la) * Double(t)))
            } else {
                v = a + (b - a) * t
            }
        }
        guard blend == .linear || blend == .logarithmic else { return v }
        if isInteger { v = v.rounded() }
        if let g = grid {
            v = min(max(g.min + ((v - g.min) / g.step).rounded() * g.step, g.min), g.max)
        }
        return v
    }

    // MARK: - PEQ の帯

    static let peqTypes: Set<String> = ["FifteenBandPEQPlugin", "FiveBandPEQPlugin"]

    /// 同じ帯でフィルタ種別か入切が違うときは、切り替えずに0 dBを通って移る。
    /// 前半は A の帯の利得を0 dBへ向けて絞り、後半は B の帯を0 dBから上げる。
    /// 0 dB が真ん中なので pk・ls・hs では曲線が途切れない。lp・hp・bp・notch・allpass は
    /// 利得を見ないので、真ん中で切り替わる。
    private static func fadePEQ(_ out: inout [Float], a: [Float], b: [Float], t: Float, spec: ETEffect) {
        guard peqTypes.contains(spec.type) else { return }
        func offset(_ key: String) -> Int? { spec.params.first { $0.key == key }?.offset }
        guard let f = offset("f"), let g = offset("g"), let q = offset("q"),
              let ty = offset("t"), let e = offset("e"),
              let count = spec.params.first(where: { $0.key == "f" })?.count else { return }
        for i in 0..<count {
            let idx = [f + i, g + i, q + i, ty + i, e + i]
            guard idx.allSatisfy({ out.indices.contains($0) && a.indices.contains($0) && b.indices.contains($0) })
            else { continue }
            let enabledA = a[e + i] >= 0.5, enabledB = b[e + i] >= 0.5
            let typeA = Int(a[ty + i].rounded()), typeB = Int(b[ty + i].rounded())
            guard (enabledA || enabledB) && (typeA != typeB || enabledA != enabledB) else { continue }
            let from = t < 0.5 ? a : b
            out[f + i] = from[f + i]
            out[q + i] = from[q + i]
            out[ty + i] = from[ty + i]
            out[e + i] = from[e + i]
            out[g + i] = t < 0.5 ? a[g + i] * (1 - 2 * t) : b[g + i] * (2 * t - 1)
        }
    }

    // MARK: - どのカードで使えるか

    /// 値が designer の設計や素材（IR・SFZ・測定）に繋がるので、音量で動かさないもの。
    static let excludedTypes: Set<String> = [
        "IRReverbPlugin", "FiveBandFIRPEQPlugin", "RoomEqPlugin", "GroupDelayEqPlugin",
        "GroupDelayPEQPlugin", "CrosstalkCancellationPlugin", "BassManagementPlugin",
        "SFZNotePlayerPlugin", "MatrixPlugin", "FIRCrossoverPlugin",
    ]

    /// Section・外部（AUv3 / JSFX）は floatCount が0なので入らない。
    static func isAutomatable(_ spec: ETEffect) -> Bool {
        spec.floatCount > 0 && !spec.isAnalyzer && !excludedTypes.contains(spec.type)
    }

    static func isAutomatable(_ node: ETChainNode) -> Bool {
        node.role == .effect && !node.isExternal && isAutomatable(node.spec)
    }

    // MARK: - 保存形式

    /// `{"src":"outputVolume","kf":[{"at":50,"p":{…}}, …]}`。（以前の `sel` は読まずに捨てる）
    /// `p` は段のパラメータと同じ綴り（ETParamCoding.encode）。
    func encoded(spec: ETEffect) -> [String: Any] {
        let list: [[String: Any]] = keyframes.map { k in
            let at: Any = k.position == k.position.rounded() ? Int(k.position) : k.position
            return ["at": at, "p": ETParamCoding.encode(params: spec.params, values: k.values)]
        }
        return ["src": source.rawValue, "kf": list]
    }

    /// 読む。**読めないものは捨てて、読めるところだけ使う。**
    /// 使えないカード・辞書でないもの・知らない `src`・`kf` が配列でないか空になるものは nil。
    /// キーフレームは `at` が有限の数のものだけ。`p` に無いパラメータは `values`（段の上の値）のまま。
    static func decode(_ raw: Any?, spec: ETEffect, values: [Float]) -> ETAutomation? {
        guard isAutomatable(spec),
              let dict = raw as? [String: Any],
              let name = dict["src"] as? String, let source = Source(rawValue: name),
              let list = dict["kf"] as? [Any] else { return nil }

        var keyframes: [Keyframe] = []
        // 貼られた字が極端に長くても、読むのは先頭だけ（整えると maxKeyframes に収まる）。
        for item in list.prefix(maxKeyframes * 4) {
            guard let kf = item as? [String: Any],
                  let n = kf["at"] as? NSNumber, n.doubleValue.isFinite else { continue }
            let p = kf["p"] as? [String: Any] ?? [:]
            let v = ETParamCoding.decode(params: spec.params, defaults: values, from: p, type: spec.type)
            keyframes.append(Keyframe(position: n.doubleValue, values: v))
        }
        return ETAutomation(source: source, keyframes: keyframes, spec: spec)
    }

    // MARK: - 鎖

    /// 鳴らしている値に置き換えた鎖（共有リンク用）。オートメーションは残す。
    static func sounding(_ nodes: [ETChainNode], at position: Double?) -> [ETChainNode] {
        nodes.map { node in
            guard let a = node.automation else { return node }
            var copy = node
            copy.values = a.values(at: position, spec: node.spec, current: node.values)
            return copy
        }
    }
}

/// 段の口（setValue など）へ画面が渡す番号。0以上は今までどおり slot。
/// 負は音量に追従する段の写し：キーフレーム1つ（書ける）か、鳴っている値（読むだけ）。
/// 画面の部品は番号をそのまま DSP へ通すだけなので、部品を作り替えずに別の値を見せて直せる。
/// DSP の段ごとの口は slot の範囲を見ているので、デコードしない口に負の番号が来ても何もしない。
enum ETSlotAddress: Equatable {
    case slot(Int)
    case keyframe(slot: Int, index: Int)
    case sounding(slot: Int)

    /// 1つの段に割り当てる番号の幅（鳴っている値 + キーフレーム最大数）。
    private static let stride = ETAutomation.maxKeyframes + 1

    init(_ raw: Int) {
        if raw >= 0 {
            self = .slot(raw)
            return
        }
        // -1 - Int.min は溢れない（Int.max）。
        let n = -1 - raw
        let (s, r) = n.quotientAndRemainder(dividingBy: Self.stride)
        self = r == 0 ? .sounding(slot: s) : .keyframe(slot: s, index: r - 1)
    }

    var raw: Int {
        switch self {
        case .slot(let s): return s
        case .sounding(let s): return -1 - s * Self.stride
        case .keyframe(let s, let k): return -1 - (s * Self.stride + k + 1)
        }
    }
}
