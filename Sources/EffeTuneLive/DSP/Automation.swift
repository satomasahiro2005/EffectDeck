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
//  段の values は、選んでいるキーフレームの値と常に同じ（ETChainNode.automation）。
//
//  補間の規則（元に依らない）:
//    - dB・リニアの利得は直線、Hz と Q は対数、そのほかの数は直線
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
    /// keyframes の有効な添字。
    private(set) var selected: Int

    /// 同じ位置を同じと見る幅。
    private static let epsilon = 0.001

    /// 1つ目のキーフレームだけ。
    init(source: Source, position: Double, values: [Float]) {
        self.source = source
        self.keyframes = [Keyframe(position: source.snapped(position), values: values)]
        self.selected = 0
    }

    /// 整えて作る。位置が有限でないものは捨て、範囲へ収め、昇順にし、同じ位置は先のものを残す。
    /// 値の数が spec と違うものも捨てる。選択は範囲へ寄せ、遅延に関わる設定は選んでいるものに揃える。
    /// 残るものが無ければ nil。
    init?(source: Source, keyframes input: [Keyframe], selected sel: Int?, spec: ETEffect) {
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
        self.selected = min(max(sel ?? out.count - 1, 0), out.count - 1)
        self.shareHeld(spec: spec)
    }

    private static func clamp(_ p: Double, _ source: Source) -> Double {
        min(max(p, source.range.lowerBound), source.range.upperBound)
    }

    var selectedValues: [Float] { keyframes[selected].values }

    // MARK: - 操作

    mutating func select(_ k: Int) {
        selected = min(max(k, 0), keyframes.count - 1)
    }

    /// その位置にキーフレームを足して選ぶ。もうあれば選ぶだけ。
    /// 新しいものは一番近いキーフレームの写し（同じ近さなら位置の低い方）。
    mutating func add(at position: Double) {
        let p = source.snapped(position)
        if let i = keyframes.firstIndex(where: { abs($0.position - p) < Self.epsilon }) {
            selected = i
            return
        }
        guard keyframes.count < Self.maxKeyframes else { return }
        var nearest = 0
        for i in keyframes.indices
        where abs(keyframes[i].position - p) < abs(keyframes[nearest].position - p) {
            nearest = i
        }
        let at = keyframes.firstIndex(where: { $0.position > p }) ?? keyframes.count
        keyframes.insert(Keyframe(position: p, values: keyframes[nearest].values), at: at)
        selected = at
    }

    /// 選んでいるキーフレームを消す。最後の1つは消さずに false。
    @discardableResult
    mutating func removeSelected() -> Bool {
        guard keyframes.count > 1 else { return false }
        keyframes.remove(at: selected)
        selected = min(selected, keyframes.count - 1)
        return true
    }

    /// 選んでいるキーフレームの値を差し替える。遅延に関わる設定は全キーフレームへ写す。
    /// 数が合わない値は受けない。
    mutating func store(selected values: [Float], spec: ETEffect) {
        guard values.count == keyframes[selected].values.count else { return }
        keyframes[selected].values = values
        shareHeld(spec: spec)
    }

    /// 補間しない設定（held）を選んでいるキーフレームの値に揃える。
    private mutating func shareHeld(spec: ETEffect) {
        let held = Self.heldOffsets(spec)
        guard !held.isEmpty else { return }
        let source = keyframes[selected].values
        for k in keyframes.indices where k != selected {
            for o in held where source.indices.contains(o) && keyframes[k].values.indices.contains(o) {
                keyframes[k].values[o] = source[o]
            }
        }
    }

    // MARK: - 位置

    /// まだキーフレームの無い刻みの位置（昇順）。
    func freePositions() -> [Double] {
        var out: [Double] = []
        var p = source.range.lowerBound
        while p <= source.range.upperBound + Self.epsilon {
            if !keyframes.contains(where: { abs($0.position - p) < Self.epsilon }) { out.append(p) }
            p += source.step
        }
        return out
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
        case .number(let min, _, _, let unit, _):
            // 保存しているのが対数の値（Tilt EQ の Pivot は ln(Hz)）なら、保存値の直線が Hz の対数になっている。
            if p.scale != .direct { return .linear }
            if min > 0 && (unit == "Hz" || unit == "kHz" || unit == "Q"
                           || p.name == "q" || p.name.hasSuffix("Q")) {
                return .logarithmic
            }
            return .linear
        }
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
            for o in p.offset..<(p.offset + p.count) where out.indices.contains(o) {
                out[o] = Self.mix(a.values[o], b.values[o], t: t, blend: blend, isInteger: isInteger)
            }
        }
        Self.fadePEQ(&out, a: a.values, b: b.values, t: t, spec: spec)
        return out
    }

    private static func mix(_ a: Float, _ b: Float, t: Float, blend: Blend, isInteger: Bool) -> Float {
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
        if isInteger && (blend == .linear || blend == .logarithmic) { v = v.rounded() }
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

    /// `{"src":"outputVolume","sel":1,"kf":[{"at":50,"p":{…}}, …]}`。
    /// `p` は段のパラメータと同じ綴り（ETParamCoding.encode）。
    func encoded(spec: ETEffect) -> [String: Any] {
        let list: [[String: Any]] = keyframes.map { k in
            let at: Any = k.position == k.position.rounded() ? Int(k.position) : k.position
            return ["at": at, "p": ETParamCoding.encode(params: spec.params, values: k.values)]
        }
        return ["src": source.rawValue, "sel": selected, "kf": list]
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
        for item in list {
            guard let kf = item as? [String: Any],
                  let n = kf["at"] as? NSNumber, n.doubleValue.isFinite else { continue }
            let p = kf["p"] as? [String: Any] ?? [:]
            let v = ETParamCoding.decode(params: spec.params, defaults: values, from: p, type: spec.type)
            keyframes.append(Keyframe(position: n.doubleValue, values: v))
        }
        let sel = (dict["sel"] as? NSNumber).map { $0.intValue }
        return ETAutomation(source: source, keyframes: keyframes, selected: sel, spec: spec)
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
