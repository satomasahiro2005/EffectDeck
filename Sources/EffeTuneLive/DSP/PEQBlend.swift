//  PEQBlend.swift
//  音量に追従する 15Band / 5Band PEQ の鳴らし方。**Foundationだけ。**
//
//  帯を添字で組にして補間すると、種別や周波数が違う帯同士が溶け合って、どのキーフレームの音でも
//  ない音を通る。そこで **帯は組にしない**。いまの区間の2つのキーフレーム A・B について、
//    A の全帯（利得を (1−t) 倍）→ B の全帯（利得を t 倍）
//  を直列に鳴らす（t=0 で A そのもの、t=1 で B そのもの）。周波数・Q・種別は補間しない。
//  利得を持たない種別（lp hp bp no ap）は倍にできないので、t が近い方のキーフレームのものだけを
//  通す（t=0.5 で入れ替わる）。
//
//  15 帯を2組同時に鳴らすため、同じ型の隠しの instance（相方）をもう1台置く
//  （EffeTuneDSP.syncCompanions。探りと同じ enabled 2 で、鎖・保存・共有には出ない）。
//  音量が動いても鎖は組み直さず、instance も作り直さない。区間が (A,B)→(B,C) に移るときは、
//  利得が 0 dB（素通し）の台だけを C に付け替える。
//  付け替えは、鳴らしている台なら先に全帯を素通しにし、素通しのうちに f・q・t・e を替える（reassignSteps）。
//
//  カーネルの挙動（peq_coefficients.h / kernel.cpp）:
//    - 利得 |g| < 0.01 dB か e < 0.5 の帯は素通しで、計算しない
//    - f・g・q の変化は約5 ms で滑らかに移る。種別（t）と入切（e）の変化は生の Float の比較で、
//      その場で切り替わる（ならして移らない）
//  だから種別か入切を変える帯は、先に利得を 0 にして移りきってから切り替え、あとで利得を戻す
//  （steps）。

import Foundation

enum ETPEQBlend {

    // MARK: - 帯の並び

    /// 帯の並び。peqTypes の型だけ（f, g, q, t, e の offset と帯の数）。
    struct Layout: Equatable {
        let bands: Int
        let frequency: Int
        let gain: Int
        let q: Int
        let type: Int
        let enabled: Int

        /// ETAutomation.peqTypes に無い・鍵が欠ける・並びが食い違うなら nil。
        init?(_ spec: ETEffect) {
            guard ETAutomation.peqTypes.contains(spec.type) else { return nil }
            func param(_ key: String) -> ETParam? { spec.params.first { $0.key == key } }
            guard let f = param("f"), let g = param("g"), let q = param("q"),
                  let t = param("t"), let e = param("e") else { return nil }
            let n = f.count
            guard n > 0, g.count == n, q.count == n, t.count == n, e.count == n else { return nil }
            let end = [f, g, q, t, e].map { $0.offset + n }.max() ?? 0
            guard end <= spec.floatCount else { return nil }
            bands = n
            frequency = f.offset
            gain = g.offset
            self.q = q.offset
            type = t.offset
            enabled = e.offset
        }

        /// その帯の5つの位置が values に収まるか。
        func fits(_ v: [Float]) -> Bool {
            let end = [frequency, gain, q, type, enabled].max() ?? 0
            return v.count >= end + bands
        }
    }

    /// peq_coefficients.h の kBypassThreshold。
    static let identityGain: Float = 0.01

    /// 利得を見ない種別 lp hp bp no ap（1, 2, 5, 6, 7）。
    static func isGainless(_ type: Float) -> Bool {
        guard type.isFinite else { return false }
        switch Int(type.rounded()) {
        case 1, 2, 5, 6, 7: return true
        default: return false
        }
    }

    /// その帯が素通しか（e<0.5、または利得を持つ種別で |g|<0.01）。
    static func isIdentity(_ v: [Float], band: Int, _ l: Layout) -> Bool {
        guard l.fits(v), band >= 0, band < l.bands else { return true }
        if !(v[l.enabled + band] >= 0.5) { return true }
        if isGainless(v[l.type + band]) { return false }
        return abs(v[l.gain + band]) < identityGain
    }

    // MARK: - 2台への割り当て

    /// 1台が鳴らすもの。keyframe=キーフレームの添字、weight=利得の倍率、
    /// gainless=利得を持たない帯を通すか。
    struct Voice: Equatable {
        var keyframe: Int
        var weight: Float
        var gainless: Bool
    }

    struct Pair: Equatable {
        var main: Voice
        var companion: Voice
    }

    /// 相方を持つか: peqTypes・role .effect・外部でない・instance≠0・keyframes≥2・inputBus==outputBus。
    /// バスを分けた段は出口で足し込まれる（engine.cpp）ので、その場で重ねる相方は置けない（探りと同じ）。
    static func wantsCompanion(_ node: ETChainNode) -> Bool {
        guard ETAutomation.peqTypes.contains(node.spec.type),
              node.role == .effect, !node.isExternal, node.instance != 0,
              let a = node.automation, a.keyframes.count >= 2,
              node.inputBus == node.outputBus else { return false }
        return true
    }

    /// いまの区間の2組（並べ替え前）。keyframes≥2 が前提。
    /// 位置が nil（音量が読めていない）か一番上以上なら、上の2つのうち一番上を鳴らす。
    static func voices(_ a: ETAutomation, at position: Double?) -> (lower: Voice, upper: Voice) {
        let n = a.keyframes.count
        precondition(n >= 2, "keyframes>=2 が前提")
        guard let pos = position, pos.isFinite else {
            return (Voice(keyframe: n - 2, weight: 0, gainless: false),
                    Voice(keyframe: n - 1, weight: 1, gainless: true))
        }
        if pos >= a.keyframes[n - 1].position {
            return (Voice(keyframe: n - 2, weight: 0, gainless: false),
                    Voice(keyframe: n - 1, weight: 1, gainless: true))
        }
        if pos <= a.keyframes[0].position {
            return (Voice(keyframe: 0, weight: 1, gainless: true),
                    Voice(keyframe: 1, weight: 0, gainless: false))
        }
        let i = a.keyframes.lastIndex(where: { $0.position <= pos }) ?? 0
        let lo = a.keyframes[i].position, hi = a.keyframes[i + 1].position
        // 保つ設定の区間は次のキーフレームまで下の1組のまま（上は重み0で載せたまま、位置に着いたら重みだけ入れ替わる）。
        let t: Float = a.keyframes[i].hold ? 0 : Float(min(max((pos - lo) / (hi - lo), 0), 1))
        return (Voice(keyframe: i, weight: 1 - t, gainless: t < 0.5),
                Voice(keyframe: i + 1, weight: t, gainless: t >= 0.5))
    }

    /// 2台への割り当て。前に載せていたキーフレーム（held＝その位置）と同じものは同じ台に残す。
    /// 中身でなく位置で見るのは、つまみを動かして値を直している間も同じ台に居続けるため
    /// （値で見ると直すたびに別物になり、2台が入れ替わって鳴りが途切れる）。位置はキーフレームの鍵。
    /// 同点なら lower を main に。
    static func pair(_ a: ETAutomation, at position: Double?,
                     mainHeld: Double?, companionHeld: Double?) -> Pair {
        let (lower, upper) = voices(a, at: position)
        func at(_ v: Voice) -> Double { a.keyframes[v.keyframe].position }
        func score(_ m: Voice, _ c: Voice) -> Int {
            (mainHeld == at(m) ? 1 : 0) + (companionHeld == at(c) ? 1 : 0)
        }
        return score(lower, upper) >= score(upper, lower)
            ? Pair(main: lower, companion: upper)
            : Pair(main: upper, companion: lower)
    }

    /// キーフレームが from から to へ動いたとき、台の鍵（その位置）を追わせる。ほかの鍵はそのまま。
    static func rekeyed(_ held: Double?, from: Double, to: Double) -> Double? {
        held == from ? to : held
    }

    /// 相方が無いとき（バスが違う・枠が足りない・キーフレーム1つ）の1台ぶん。
    /// 真ん中で素通しを通って入れ替わる。
    static func solo(_ a: ETAutomation, at position: Double?) -> Voice {
        let n = a.keyframes.count
        guard n >= 2 else { return Voice(keyframe: 0, weight: 1, gainless: true) }
        guard let pos = position, pos.isFinite else {
            return Voice(keyframe: n - 1, weight: 1, gainless: true)
        }
        if pos >= a.keyframes[n - 1].position { return Voice(keyframe: n - 1, weight: 1, gainless: true) }
        if pos <= a.keyframes[0].position { return Voice(keyframe: 0, weight: 1, gainless: true) }
        let i = a.keyframes.lastIndex(where: { $0.position <= pos }) ?? 0
        let lo = a.keyframes[i].position, hi = a.keyframes[i + 1].position
        // 保つ設定の区間は次のキーフレームまで下の1組のまま（上は重み0で載せたまま、位置に着いたら重みだけ入れ替わる）。
        let t: Float = a.keyframes[i].hold ? 0 : Float(min(max((pos - lo) / (hi - lo), 0), 1))
        return t < 0.5
            ? Voice(keyframe: i, weight: 1 - 2 * t, gainless: true)
            : Voice(keyframe: i + 1, weight: 2 * t - 1, gainless: true)
    }

    /// Voice → 渡す値（floatCount 全部）。f・q・t は変えない。
    /// 利得を持つ帯は g × weight、利得を持たない帯は gainless が偽なら切。
    static func values(_ v: Voice, in a: ETAutomation, layout l: Layout) -> [Float] {
        var out = a.keyframes[v.keyframe].values
        guard l.fits(out) else { return out }
        for i in 0..<l.bands {
            if isGainless(out[l.type + i]) {
                if !v.gainless { out[l.enabled + i] = 0 }
            } else if v.weight != 1 {
                out[l.gain + i] = v.weight == 0 ? 0 : out[l.gain + i] * v.weight
            }
        }
        return out
    }

    /// 利得0・利得を持たない帯は切。キーフレームの値はそのまま（相方を作ったとき、PC 編集中の相方）。
    static func silenced(_ values: [Float], layout l: Layout) -> [Float] {
        var out = values
        guard l.fits(out) else { return out }
        for i in 0..<l.bands {
            if isGainless(out[l.type + i]) {
                out[l.enabled + i] = 0
            } else {
                out[l.gain + i] = 0
            }
        }
        return out
    }

    // MARK: - 種別・入切の切り替えの段取り

    private static func topologyDiffers(_ a: [Float], _ b: [Float], band i: Int, _ l: Layout) -> Bool {
        a[l.type + i] != b[l.type + i] || a[l.enabled + i] != b[l.enabled + i]
    }

    /// 前に渡した値から次の値へ、素通しの帯でだけ種別・入切を変えて移る段取り（0〜3個）。
    ///   s1: 種別・入切を変える帯の利得を 0 へ（f・g・q の連続の変化だけ。ほかの帯は目標へ）
    ///   s2: その帯の種別・入切・周波数・Q を目標に（利得は 0 のまま。切り替えが起きるのはここだけ）
    ///   s3: 目標（利得を戻す）
    /// 前の値が無い・長さが違うなら [target]、同じなら []。
    static func steps(from pushed: [Float]?, to target: [Float], layout l: Layout) -> [[Float]] {
        guard let pushed, pushed.count == target.count, l.fits(target) else { return [target] }
        if pushed == target { return [] }

        var s1 = target, s2 = target
        var any = false
        for i in 0..<l.bands where topologyDiffers(pushed, target, band: i, l) {
            any = true
            // s1: 前の帯のまま利得だけ 0 へ。利得を持たない種別は 0 にできない（そのまま）。
            s1[l.frequency + i] = pushed[l.frequency + i]
            s1[l.q + i] = pushed[l.q + i]
            s1[l.type + i] = pushed[l.type + i]
            s1[l.enabled + i] = pushed[l.enabled + i]
            s1[l.gain + i] = isGainless(pushed[l.type + i]) ? pushed[l.gain + i] : 0
            // s2: 目標の帯を利得 0 で。
            s2[l.gain + i] = isGainless(target[l.type + i]) ? target[l.gain + i] : 0
        }
        guard any else { return [target] }

        var out: [[Float]] = []
        var previous = pushed
        for s in [s1, s2, target] where s != previous {
            out.append(s)
            previous = s
        }
        return out
    }

    /// どれかの帯で t か e（生の Float）が違うか。前の値が無い・長さが違うなら偽（切り替えるものが鳴っていない）。
    /// strict なら f・q の違いも数える（付け替えの段取り。素通しでない帯の f・q は動かさないため）。
    static func changesTopology(from pushed: [Float]?, to next: [Float], layout l: Layout,
                                strict: Bool = false) -> Bool {
        guard let pushed, pushed.count == next.count, l.fits(next) else { return false }
        for i in 0..<l.bands where swapDiffers(pushed, next, band: i, l, strict: strict) { return true }
        return false
    }

    private static func swapDiffers(_ a: [Float], _ b: [Float], band i: Int, _ l: Layout,
                                    strict: Bool) -> Bool {
        topologyDiffers(a, b, band: i, l)
            || (strict && (a[l.frequency + i] != b[l.frequency + i] || a[l.q + i] != b[l.q + i]))
    }

    // MARK: - 台に別のキーフレームを付け替える段取り

    /// 全帯が素通しか（付け替えてよい状態）。
    static func isSilent(_ v: [Float], layout l: Layout) -> Bool {
        guard l.fits(v) else { return true }
        for i in 0..<l.bands where !isIdentity(v, band: i, l) { return false }
        return true
    }

    /// 台が鳴らしているキーフレームを別のものへ替える段取り（0〜3個）。
    /// 帯を添字で組にして f・q・g を滑らかに移すと、どちらのキーフレームでもない音を通るので、
    ///   s1: いまの値の全帯を素通しへ（f・q・t は変えない。利得を持たない帯は切）
    ///   s2: 目標の f・q・t・e を利得 0 で入れる（素通しのうちに全帯を替える）
    ///   s3: 目標（利得を戻す）
    /// 前の値が素通しなら s1 は要らない。前の値が無い・長さが違うなら [target]、同じなら []。
    static func reassignSteps(from pushed: [Float]?, to target: [Float], layout l: Layout) -> [[Float]] {
        guard let pushed, pushed.count == target.count, l.fits(target) else { return [target] }
        if pushed == target { return [] }
        var out: [[Float]] = []
        var previous = pushed
        for s in [silenced(pushed, layout: l), silenced(target, layout: l), target] where s != previous {
            out.append(s)
            previous = s
        }
        return out
    }

    /// 前の値から次の値で、f・g・q・t・e のどれかが変わる帯（カーネルがならし・切り替えを始める帯）。
    /// 前の値が無い・長さが違うなら全帯。
    static func changedBands(from pushed: [Float]?, to next: [Float], layout l: Layout) -> [Int] {
        guard let pushed, pushed.count == next.count, l.fits(next) else { return Array(0..<l.bands) }
        return (0..<l.bands).filter { i in
            [l.frequency, l.gain, l.q, l.type, l.enabled].contains { pushed[$0 + i] != next[$0 + i] }
        }
    }

    /// その手が切り替える帯（t・e、strict なら f・q も変わる帯）。待つのはこの帯のならしだけ。
    static func switchingBands(from pushed: [Float]?, to next: [Float], layout l: Layout,
                               strict: Bool = false) -> [Int] {
        guard let pushed, pushed.count == next.count, l.fits(next) else { return [] }
        return (0..<l.bands).filter { swapDiffers(pushed, next, band: $0, l, strict: strict) }
    }
}
