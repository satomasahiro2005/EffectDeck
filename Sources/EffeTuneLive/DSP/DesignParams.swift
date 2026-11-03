//  DesignParams.swift
//  designerで作る型の、設計の材料のうち**上流が鎖に書いているもの**。**Foundationだけ。**
//
//  5Band FIR PEQ・Group Delay EQ・Group Delay PEQ・FIR Crossoverのカーネルが持つ
//  パラメータはlt / fd（FIR Crossoverはbcも）だけで、帯域・位相・タップ数は係数に溶けて
//  資産として送り込まれる。だからparams.jsonに席が無く、values（floatの並び）にも載らない。
//  前はdesignerの置き場（段ごと・メモリの中だけ）にしか無く、アプリを開き直す・プリセットを
//  読む・共有リンクを開くと既定へ戻っていた。5Band FIR PEQはfd:16384を持った鎖を読んでも
//  Minimum Phase・遅延0に戻った。
//
//  上流はこれらをgetParameters()で返し、プリセットにも共有リンクにも書いている
//  （pinの行）:
//      five_band_fir_peq.js:106-134   pm / tp / f0-4 / g0-4 / q0-4 / s0-4 / t0-4 / e0-4
//      group_delay_eq.js:118-139      tp / d0-14
//      group_delay_peq.js:169-196     tp / t0-4 / f0-4 / d0-4 / q0-4 / e0-4
//      fir_crossover.js:96-121        pm / tp / f1-3 / s1-3
//      ir_reverb.js:171-174           dc / co / dt / tr（IRを送る前の下ごしらえ。IRPreparation.swift）
//  Sectionの名前（`cm`）・IRの鍵（`ir`）・表示の設定（DisplayParams.swift）と同じ立場なので、
//  同じようにNode側へ文字列で持ち、保存形式では**上流と同じ綴り**で書く。
//
//  **入れていないもの。**Room EQとCrosstalk Cancellationの材料は測定そのもので、
//  上流は測定の置き場の鍵（ms / llなど）しか鎖に書かない。こちらには測定を残す置き場が無く、
//  鍵だけ持っても引く先が無いので、設定だけ残しても音は戻らない。
//  Bass Managementは材料が全部paramsにある（AssetReattach.swiftの頭）。
//
//  読むときの寄せ方は上流のsetParametersに合わせる。ここに無い鍵は既定のまま
//  （上流も`params.x !== undefined`のときだけ書く）。

import Foundation

enum ETDesignParam {

    typealias Kind = ETDisplayParam.Kind

    static let fiveBandFIRPEQ = "FiveBandFIRPEQPlugin"
    static let groupDelayEQ = "GroupDelayEqPlugin"
    static let groupDelayPEQ = "GroupDelayPEQPlugin"
    static let firCrossover = "FIRCrossoverPlugin"
    static let irReverb = "IRReverbPlugin"

    /// その型が持つ設計の材料。持たないものは空。
    static func table(for type: String) -> [String: Kind] {
        switch type {
        case fiveBandFIRPEQ:
            return indexed(["f", "g", "q", "s"], 0..<5, .number)
                .merging(indexed(["t"], 0..<5, .text)) { a, _ in a }
                .merging(indexed(["e"], 0..<5, .flag)) { a, _ in a }
                .merging(["pm": .text, "tp": .number]) { a, _ in a }
        case groupDelayEQ:
            return indexed(["d"], 0..<GroupDelayEQDesign.bands.count, .number)
                .merging(["tp": .number]) { a, _ in a }
        case groupDelayPEQ:
            return indexed(["f", "d", "q"], 0..<GroupDelayPEQDesignCore.bandCount, .number)
                .merging(indexed(["t"], 0..<GroupDelayPEQDesignCore.bandCount, .text)) { a, _ in a }
                .merging(indexed(["e"], 0..<GroupDelayPEQDesignCore.bandCount, .flag)) { a, _ in a }
                .merging(["tp": .number]) { a, _ in a }
        case firCrossover:
            return indexed(["f", "s"], 1..<4, .number)
                .merging(["pm": .text, "tp": .number]) { a, _ in a }
        case irReverb:
            return ["dc": .flag, "co": .number, "dt": .number, "tr": .number]
        default:
            return [:]
        }
    }

    private static func indexed(_ stems: [String], _ range: Range<Int>, _ kind: Kind) -> [String: Kind] {
        var out: [String: Kind] = [:]
        for stem in stems {
            for i in range { out[stem + String(i)] = kind }
        }
        return out
    }

    // MARK: -保存形式との出し入れ

    /// 保存形式へ足す。型は上流のもの（ETDisplayParam.encode）。
    static func write(_ design: [String: String], type: String,
                      into o: inout [String: Any]) {
        for (key, kind) in table(for: type) {
            guard let raw = design[key] else { continue }
            o[key] = ETDisplayParam.encode(raw, kind: kind)
        }
    }

    /// 保存形式から読む。読めないものはnilにして、既定のままにする。
    static func read(_ params: [String: Any], type: String) -> [String: String] {
        var out: [String: String] = [:]
        for (key, kind) in table(for: type) {
            guard let any = params[key], let raw = decode(any, kind: kind) else { continue }
            out[key] = raw
        }
        return out
    }

    /// エフェクトのプリセットが運んできた材料を今の材料へ重ねる。**書かれていない鍵は今のまま**
    /// （EffectPresetApply.valuesと同じ。上流のsetParametersも`params.x !== undefined`のときだけ書く）。
    static func applying(_ params: [String: Any], to design: [String: String],
                         type: String) -> [String: String] {
        design.merging(read(params, type: type)) { _, new in new }
    }

    /// 表示の設定（ETDisplayParam.decode）より緩い。上流の読み手に合わせる:
    ///   -数は字でも受ける。parseFiniteNumberと`Number(params.tp)`は"32768"も通す
    ///     （plugin-base.js:1174-1194）
    ///   -真偽は`Boolean(x)`。数は0以外、字は空でなければ真（five_band_fir_peq.js:171ほか）
    static func decode(_ any: Any, kind: Kind) -> String? {
        switch kind {
        case .text:
            return any as? String
        case .number:
            if let s = any as? String {
                let trimmed = s.trimmingCharacters(in: .whitespaces)
                guard let d = Double(trimmed), d.isFinite else { return nil }
                return format(d)
            }
            if let n = any as? NSNumber {
                let d = n.doubleValue
                return d.isFinite ? format(d) : nil
            }
            return nil
        case .flag:
            if let b = any as? Bool { return b ? "true" : "false" }
            if let n = any as? NSNumber { return n.doubleValue != 0 ? "true" : "false" }
            if let s = any as? String { return s.isEmpty ? "false" : "true" }
            return nil
        }
    }

    // MARK: -値の読み書き

    /// 数を持つときの綴り。String(Double)は読み戻すと同じ値になる最短の綴り。
    static func format(_ value: Double) -> String { String(value) }

    static func flag(_ value: Bool) -> String { value ? "true" : "false" }

    static func number(_ design: [String: String], _ key: String) -> Double? {
        guard let raw = design[key], let d = Double(raw), d.isFinite else { return nil }
        return d
    }

    static func flag(_ design: [String: String], _ key: String) -> Bool? {
        switch design[key] {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    /// parseFiniteNumber（plugin-base.js:1174-1194）。鍵が無いか数でなければ前の値、外なら端。
    static func finite(_ design: [String: String], _ key: String,
                       _ low: Double, _ high: Double, previous: Double) -> Double {
        guard let v = number(design, key) else { return previous }
        return min(max(v, low), high)
    }

    /// `Number(params.tp)`を決まった選択肢と突き合わせる。整数でなければ外れ。
    static func choice(_ design: [String: String], _ key: String, in choices: [Int]) -> Int? {
        guard let v = number(design, key), let i = Int(exactly: v), choices.contains(i) else {
            return nil
        }
        return i
    }
}

// MARK: - 5Band FIR PEQ

extension BandFIRPEQLatency {
    /// valuesのlt（並びの添字）から。外れていれば既定の128。
    init(parameterIndex value: Float) {
        let rounded = value.isFinite ? value.rounded() : 1
        self = Self.allCases.first { $0.parameterIndex == rounded } ?? .block128
    }
}

extension BandFIRPEQSettings {

    /// 段が持っている材料から。five_band_fir_peq.js:136-176のsetParametersと同じ寄せ方。
    ///
    /// - latency: valuesのltから（BandFIRPEQLatency(parameterIndex:)）。ltはparamsにある。
    /// - filterDelaySamples: valuesのfd。**pmもtpも無いときだけ**そこから位相とタップ数を戻す。
    ///   上流はpmを必ず書くのでこの道は通らない。通るのは、材料を書いていなかった頃の
    ///   EffectDeckが保存した鎖・プリセット・リンク（fdだけがtaps/2で残っている）。
    init(designParams d: [String: String], latency: BandFIRPEQLatency = .block128,
         filterDelaySamples: Float? = nil) {
        var s = BandFIRPEQSettings.default
        s.latency = latency

        if let pm = d["pm"], let phase = BandFIRPEQPhase(rawValue: pm) { s.phase = phase }
        let tapChoices = BandFIRPEQTaps.allCases.map(\.rawValue)
        if let tp = ETDesignParam.choice(d, "tp", in: tapChoices), let taps = BandFIRPEQTaps(rawValue: tp) {
            s.taps = taps
        }
        if d["pm"] == nil, d["tp"] == nil, let fd = filterDelaySamples, fd.isFinite, fd > 0 {
            s.phase = .linear
            if let whole = Int(exactly: fd.rounded()), let taps = BandFIRPEQTaps(rawValue: whole * 2) {
                s.taps = taps
            }
        }

        for i in s.bands.indices {
            var b = s.bands[i]
            if let t = d["t\(i)"], let type = BandFIRPEQFilterType(rawValue: t) { b.type = type }
            b.frequency = ETDesignParam.finite(d, "f\(i)", 20, 20000, previous: b.frequency)
            b.gain = ETDesignParam.finite(d, "g\(i)", -20, 20, previous: b.gain)
            b.q = ETDesignParam.finite(d, "q\(i)", 0.1, 100, previous: b.q)
            b.slope = ETDesignParam.finite(d, "s\(i)", 0.1, 384, previous: b.slope)
            if let e = ETDesignParam.flag(d, "e\(i)") { b.enabled = e }
            s.bands[i] = b
        }
        self = s
    }

    /// 保存する材料。ltはvaluesが持つので入れない（designerがstageのたびに書き戻す）。
    var designParams: [String: String] {
        var d: [String: String] = [
            "pm": phase.rawValue,
            "tp": ETDesignParam.format(Double(taps.rawValue)),
        ]
        for (i, b) in bands.enumerated() {
            d["t\(i)"] = b.type.rawValue
            d["f\(i)"] = ETDesignParam.format(b.frequency)
            d["g\(i)"] = ETDesignParam.format(b.gain)
            d["q\(i)"] = ETDesignParam.format(b.q)
            d["s\(i)"] = ETDesignParam.format(b.slope)
            d["e\(i)"] = ETDesignParam.flag(b.enabled)
        }
        return d
    }
}

// MARK: - Group Delay EQ

extension GroupDelayEQDesign {

    /// tpから。無い・外れていればfd（taps/2）から、それも外れていれば既定の16384。
    /// fdから戻す道は材料を書いていなかった頃の鎖のため（そのときもfdはtaps/2だった）。
    static func taps(designParams d: [String: String], filterDelaySamples: Float?) -> Int {
        if let tp = ETDesignParam.choice(d, "tp", in: tapsChoices) { return tp }
        if let fd = filterDelaySamples, fd.isFinite, let whole = Int(exactly: fd.rounded()),
           tapsChoices.contains(whole * 2) {
            return whole * 2
        }
        return 16384
    }

    /// 帯ごとの遅延（ms）。group_delay_eq.js:154-160と同じく、タップ数とレートで決まる
    /// 限界で挟む（parseFiniteNumber(value, -limit, limit,前の値)）。前の値は0。
    static func delays(designParams d: [String: String], taps: Int, sampleRate: Double) -> [Double] {
        let limit = uiDelayLimitMs(taps: taps, sampleRate: sampleRate > 0 ? sampleRate : 48000)
        return bands.indices.map { ETDesignParam.finite(d, "d\($0)", -limit, limit, previous: 0) }
    }

    /// 保存する材料。ltはvaluesが持つので入れない。
    static func designParams(taps: Int, delaysMs: [Double]) -> [String: String] {
        var d = ["tp": ETDesignParam.format(Double(taps))]
        for band in bands.indices {
            d["d\(band)"] = ETDesignParam.format(delaysMs.indices.contains(band) ? delaysMs[band] : 0)
        }
        return d
    }
}

// MARK: - Group Delay PEQ

extension GroupDelayPEQSettings {

    /// 段が持っている材料を当てたもの。group_delay_peq.js:204-245のsetParametersと同じ順で、
    /// tpを先に決め、その限界でdを挟み、最後に限界へ詰める。
    ///
    /// **帯域とタップ数は既定から組み直す。**材料が空なら既定の帯域（Resetと同じ）。
    /// レート・処理幅・ltは材料ではないのでselfのまま。
    func applying(designParams d: [String: String]) -> GroupDelayPEQSettings {
        var s = self
        s.bands = GroupDelayPEQSettings.defaultBands
        s.taps = ETDesignParam.choice(d, "tp", in: GroupDelayPEQDesignCore.tapsChoices) ?? 16384
        let limit = s.delayLimitMs
        for i in s.bands.indices {
            var b = s.bands[i]
            if let t = d["t\(i)"], let shape = GroupDelayPEQBand.Shape(rawValue: t) { b.shape = shape }
            b.frequency = ETDesignParam.finite(d, "f\(i)",
                                               GroupDelayPEQDesignCore.minimumFrequency,
                                               GroupDelayPEQDesignCore.maximumFrequency,
                                               previous: b.frequency)
            b.delayMs = ETDesignParam.finite(d, "d\(i)", -limit, limit, previous: b.delayMs)
            b.q = ETDesignParam.finite(d, "q\(i)",
                                       GroupDelayPEQDesignCore.minimumQ,
                                       GroupDelayPEQDesignCore.maximumQ,
                                       previous: b.q)
            if let e = ETDesignParam.flag(d, "e\(i)") { b.enabled = e }
            s.bands[i] = b
        }
        return s.clampingDelaysToLimit()
    }

    /// 保存する材料。ltはvaluesが持つので入れない。
    var designParams: [String: String] {
        var d = ["tp": ETDesignParam.format(Double(taps))]
        for (i, b) in bands.enumerated() {
            d["t\(i)"] = b.shape.rawValue
            d["f\(i)"] = ETDesignParam.format(b.frequency)
            d["d\(i)"] = ETDesignParam.format(b.delayMs)
            d["q\(i)"] = ETDesignParam.format(b.q)
            d["e\(i)"] = ETDesignParam.flag(b.enabled)
        }
        return d
    }
}

// MARK: - FIR Crossover

extension FIRCrossoverSettings {

    /// 段が持っている材料を当てたもの。fir_crossover.js:129-166のsetParametersと同じ読み方で、
    /// 範囲と並びへの寄せはclamp()（designer.updateの中で必ず通る）に任せる。
    ///
    /// **周波数・傾き・位相・タップ数は既定から組み直す。**bandCountとltはparamsにあるので
    /// selfのまま（FIRCrossoverDesigners.syncがvaluesから入れる）。
    func applying(designParams d: [String: String]) -> FIRCrossoverSettings {
        var s = self
        let defaults = FIRCrossoverSettings()
        s.phase = defaults.phase
        s.taps = defaults.taps
        s.frequencies = defaults.frequencies
        s.slopes = defaults.slopes

        if let pm = d["pm"], let phase = FIRCrossoverPhase(rawValue: pm) { s.phase = phase }
        if let tp = ETDesignParam.choice(d, "tp", in: FIRCrossoverSettings.tapChoices) { s.taps = tp }
        for i in 0..<3 {
            s.frequencies[i] = ETDesignParam.finite(d, "f\(i + 1)", 10, 40000,
                                                    previous: s.frequencies[i])
            // Math.round(Number(params.s1))が選択肢に入っているときだけ（fir_crossover.js:158-162）。
            if let v = ETDesignParam.number(d, "s\(i + 1)") {
                // Math.roundは.5を+∞側へ寄せる（-47.5 → -47）。
                let r = (v + 0.5).rounded(.down)
                if let whole = Int(exactly: r), FIRCrossoverSettings.slopeChoices.contains(whole) {
                    s.slopes[i] = whole
                }
            }
        }
        return s
    }
}

// MARK: - IR Reverb

extension ETIRPreparation.Options {

    /// 段が持っている材料から。ir_reverb.js:241-244のsetParametersと同じ寄せ方で、
    /// 鍵が無ければ既定（:37-40）、範囲の外は端へ寄せる。**材料が空なら上流の既定**なので、
    /// 鍵を書いていなかった頃の鎖は前と同じ下ごしらえで鳴る。
    init(designParams d: [String: String]) {
        var o = ETIRPreparation.Options.upstreamDefaults
        if let dc = ETDesignParam.flag(d, "dc") { o.directCut = dc }
        o.cutOffsetMs = ETDesignParam.finite(d, "co", -20, 50, previous: o.cutOffsetMs)
        o.decayPercent = ETDesignParam.finite(d, "dt", 10, 400, previous: o.decayPercent)
        o.trimPercent = ETDesignParam.finite(d, "tr", 1, 100, previous: o.trimPercent)
        self = o
    }
}
