//  BassManagementSettings.swift
//  Bass Management（BassManagementPlugin）の 89 float を読み、直す。
//
//  **Foundation だけ。**EffeTuneDSP にも SwiftUI にも et_* にも触らない。
//  判断（設定の誤り・Sub の入切・経路の要約・設計の鍵）はここに集め、
//  画面と designer はここを呼ぶだけにする。
//
//  写した元（plugins/basics/bass_management.js）:
//    _linearInputChannels   :255-261
//    _configurationError    :263-294
//    _renderConfiguration   :665-688  経路の要約
//    _setSubOutputEnabled   :824-841
//    ON / Ø の升            :982-1000
//  設計の鍵の丸め方は js/bass-management/design-core.js:21-49
//  （normalizeBassManagementDesignConfig）。
//
//  並びは EffectCatalog の BassManagementPlugin。params.json の順ではない
//  （ri が末尾の 73-88 に来る）ので、位置は必ず key から引く。

import Foundation

struct BassManagementSettings: Equatable, Sendable {

    static let channelCount = 16
    /// bass_management.js:8。kernel.cpp:33 もこの 3 つしか受けない。
    static let slopeChoices = [24, 48, 96]
    /// bass_management.js:9。tp は enum なので float に入るのは**この添字**。
    static let tapChoices = [8192, 16384, 32768]
    /// bass_management.js:10-12。値は ro の数。
    static let roleNames = ["Full Range", "Managed", "LFE", "Unused"]
    /// kernel.cpp:219 と bass_management.js:369。128 以外は begin で弾かれる。
    static let headBlock = 128

    enum Role: Int {
        case fullRange = 0
        case managed = 1
        case lfe = 2
        case unused = 3
    }

    /// float の並びの中の位置。ETParam の key から引く。
    struct Layout: Equatable, Sendable {
        let phase: Int
        let taps: Int
        let roles: Int
        let frequencies: Int
        let slopes: Int
        let routes: Int
        let inversions: Int
        let subs: Int
        let lfeFrequency: Int
        let lfeSlope: Int
        let lfeLowpass: Int
        let bassGain: Int
        let lfeGain: Int
        let headroom: Int
        let floatCount: Int

        init?(params: [ETParam]) {
            func at(_ key: String) -> Int? { params.first { $0.key == key }?.offset }
            guard let ph = at("ph"), let tp = at("tp"), let ro = at("ro"), let fc = at("fc"),
                  let sl = at("sl"), let rt = at("rt"), let ri = at("ri"), let su = at("su"),
                  let lf = at("lf"), let ls = at("ls"), let lo = at("lo"), let bg = at("bg"),
                  let lg = at("lg"), let hg = at("hg") else { return nil }
            phase = ph; taps = tp; roles = ro; frequencies = fc; slopes = sl
            routes = rt; inversions = ri; subs = su
            lfeFrequency = lf; lfeSlope = ls; lfeLowpass = lo
            bassGain = bg; lfeGain = lg; headroom = hg
            floatCount = params.map { $0.offset + $0.count }.max() ?? 0
        }
    }

    var linear = false
    /// tapChoices の添字。
    var tapsIndex = 1
    var roles = [Int](repeating: 0, count: channelCount)
    var frequencies = [Double](repeating: 80, count: channelCount)
    var slopes = [Int](repeating: 24, count: channelCount)
    /// 入力ごとに、どの Sub へ送るかの bit。
    var routes = [Int](repeating: 0, count: channelCount)
    /// 入力ごとに、送り先で位相を返す bit。routes の部分集合。
    var inversions = [Int](repeating: 0, count: channelCount)
    var subs = 0
    var lfeFrequency: Double = 120
    var lfeSlope = 24
    var lfeLowpass = false
    var bassGain: Double = 0
    var lfeGain: Double = 0
    var headroom: Double = 0

    init() {}

    init(values: [Float], layout: Layout) {
        func value(_ offset: Int) -> Float {
            values.indices.contains(offset) ? values[offset] : 0
        }
        // **Int へ直す前に寄せる。**有限でも Int の外なら Int(_:) は落ちる。
        // 読み込みは ETUpstreamNormalize が寄せるが、ここは値の出どころを問わない。
        func int(_ offset: Int) -> Int {
            let v = value(offset)
            return v.isFinite ? Int(min(max(v.rounded(), -65536), 65536)) : 0
        }
        func mask(_ offset: Int) -> Int { min(max(int(offset), 0), 65535) }
        func real(_ offset: Int, _ fallback: Double) -> Double {
            let v = value(offset)
            return v.isFinite ? Double(v) : fallback
        }

        linear = int(layout.phase) == 1
        tapsIndex = int(layout.taps)
        roles = (0..<Self.channelCount).map { int(layout.roles + $0) }
        frequencies = (0..<Self.channelCount).map { real(layout.frequencies + $0, 80) }
        slopes = (0..<Self.channelCount).map { int(layout.slopes + $0) }
        routes = (0..<Self.channelCount).map { mask(layout.routes + $0) }
        inversions = (0..<Self.channelCount).map { mask(layout.inversions + $0) }
        subs = mask(layout.subs)
        lfeFrequency = real(layout.lfeFrequency, 120)
        lfeSlope = int(layout.lfeSlope)
        lfeLowpass = value(layout.lfeLowpass) >= 0.5
        bassGain = real(layout.bassGain, 0)
        lfeGain = real(layout.lfeGain, 0)
        headroom = real(layout.headroom, 0)
    }

    /// 並びへ書き戻す。触っていない位置は元の値のまま。
    func write(into values: inout [Float], layout: Layout) {
        func put(_ offset: Int, _ v: Float) {
            if values.indices.contains(offset) { values[offset] = v }
        }
        put(layout.phase, linear ? 1 : 0)
        put(layout.taps, Float(tapsIndex))
        for ch in 0..<Self.channelCount {
            put(layout.roles + ch, Float(roles[ch]))
            put(layout.frequencies + ch, Float(frequencies[ch]))
            put(layout.slopes + ch, Float(slopes[ch]))
            put(layout.routes + ch, Float(routes[ch]))
            put(layout.inversions + ch, Float(inversions[ch]))
        }
        put(layout.subs, Float(subs))
        put(layout.lfeFrequency, Float(lfeFrequency))
        put(layout.lfeSlope, Float(lfeSlope))
        put(layout.lfeLowpass, lfeLowpass ? 1 : 0)
        put(layout.bassGain, Float(bassGain))
        put(layout.lfeGain, Float(lfeGain))
        put(layout.headroom, Float(headroom))
    }

    // MARK: 読み

    /// kernel.cpp:35-37。添字が外れていれば 16384 に倒れる。
    var taps: Int {
        Self.tapChoices.indices.contains(tapsIndex) ? Self.tapChoices[tapsIndex] : 16384
    }

    /// bass_management.js:657。Linear は taps/2 + 頭ブロック、IIR は 0。
    var latencySamples: Int { linear ? taps / 2 + Self.headBlock : 0 }

    func role(_ channel: Int) -> Role? {
        roles.indices.contains(channel) ? Role(rawValue: roles[channel]) : nil
    }

    /// 処理幅の中で選ばれている Sub（bass_management.js:816-822）。
    func selectedSubs(width: Int) -> [Int] {
        (0..<Self.clampWidth(width)).filter { subs & (1 << $0) != 0 }
    }

    /// 低域の FIR が要る入力（bass_management.js:255-261）。
    func linearInputs(width: Int) -> [Int] {
        (0..<Self.clampWidth(width)).filter { filter(for: $0) != nil }
    }

    /// この入力に掛かる LP/HP の (cutoff, slope)。掛からなければ nil。
    /// Managed は自分の fc / sl、LFE は LFE Low-pass が入っているときだけ lf / ls
    /// （design-core.js:69-72、kernel.cpp:38-40 の needsLowpass）。
    /// 値の丸めは design-core.js:21-49 と同じ。
    func filter(for channel: Int) -> (cutoff: Double, slope: Int)? {
        guard roles.indices.contains(channel) else { return nil }
        switch roles[channel] {
        case Role.managed.rawValue:
            return (Self.cutoff(frequencies[channel], fallback: 80),
                    Self.slope(slopes[channel]))
        case Role.lfe.rawValue where lfeLowpass:
            return (Self.cutoff(lfeFrequency, fallback: 120), Self.slope(lfeSlope))
        default:
            return nil
        }
    }

    // MARK: 設定の誤り

    /// bass_management.js:263-294 の _configurationError。
    /// 文言は上流のまま。All でないときの 1 文だけは画面が「Use all output channels」に置き換える。
    enum ConfigurationError: Equatable, Sendable {
        case notAllChannels
        case widthUnavailable
        case subOutsideWidth
        case outsideWidth(Int)
        case mainAndSub(Int)
        case inversionWithoutRoute(Int)
        case noTarget(Int)
        case unavailableTarget(Int)

        var message: String {
            switch self {
            case .notAllChannels:
                return "Set Ch to All."
            case .widthUnavailable:
                return "The current processing channel count is unavailable."
            case .subOutsideWidth:
                return "A selected Sub output is outside the current processing width."
            case .outsideWidth(let ch):
                return "Ch \(ch + 1) is configured outside the current processing width."
            case .mainAndSub(let ch):
                return "Ch \(ch + 1) cannot be both a Main input and a Sub output."
            case .inversionWithoutRoute(let ch):
                return "Ch \(ch + 1) has an inverted route that is not enabled."
            case .noTarget(let ch):
                return "Ch \(ch + 1) needs at least one Sub target."
            case .unavailableTarget(let ch):
                return "Ch \(ch + 1) targets an output that is not an available Sub."
            }
        }
    }

    func configurationError(allChannels: Bool, width: Int) -> ConfigurationError? {
        if !allChannels { return .notAllChannels }
        guard width >= 1, width <= Self.channelCount else { return .widthUnavailable }
        let available = width == Self.channelCount ? 65535 : (1 << width) - 1
        if subs & ~available != 0 { return .subOutsideWidth }
        for ch in width..<Self.channelCount
        where roles[ch] == Role.managed.rawValue || roles[ch] == Role.lfe.rawValue || routes[ch] != 0 {
            return .outsideWidth(ch)
        }
        if subs == 0 { return nil }
        for ch in 0..<width {
            let bit = 1 << ch
            if subs & bit != 0,
               roles[ch] == Role.fullRange.rawValue || roles[ch] == Role.managed.rawValue {
                return .mainAndSub(ch)
            }
            guard roles[ch] == Role.managed.rawValue || roles[ch] == Role.lfe.rawValue else { continue }
            let targets = routes[ch]
            if inversions[ch] & ~targets != 0 { return .inversionWithoutRoute(ch) }
            if targets == 0 { return .noTarget(ch) }
            if targets & ~subs != 0 || targets & ~available != 0 { return .unavailableTarget(ch) }
        }
        return nil
    }

    // MARK: 直す

    /// bass_management.js:824-841 の _setSubOutputEnabled。
    /// 入れると、その Ch を LFE にし、処理幅の全入力からその Sub へ送る（位相は戻す）。
    /// 切ると、全入力の経路と位相からその bit を落とす。Role はそのまま。
    func settingSubOutput(_ channel: Int, enabled: Bool, width: Int) -> Self {
        guard (0..<Self.channelCount).contains(channel) else { return self }
        var next = self
        let bit = 1 << channel
        if enabled {
            next.roles[channel] = Role.lfe.rawValue
            for input in 0..<Self.clampWidth(width) {
                next.routes[input] |= bit
                next.inversions[input] &= ~bit
            }
            next.subs |= bit
        } else {
            next.subs &= ~bit
            next.routes = next.routes.map { $0 & ~bit }
            next.inversions = next.inversions.map { $0 & ~bit }
        }
        return next
    }

    /// bass_management.js:982-993。切ると位相の bit も落とす。
    func togglingRoute(input: Int, output: Int) -> Self {
        guard routes.indices.contains(input), (0..<Self.channelCount).contains(output) else { return self }
        var next = self
        let bit = 1 << output
        if next.routes[input] & bit != 0 {
            next.routes[input] &= ~bit
            next.inversions[input] &= ~bit
        } else {
            next.routes[input] |= bit
        }
        return next
    }

    /// bass_management.js:994-1000。入っている経路だけ返せる。
    func togglingInversion(input: Int, output: Int) -> Self {
        guard routes.indices.contains(input), (0..<Self.channelCount).contains(output) else { return self }
        let bit = 1 << output
        guard routes[input] & bit != 0 else { return self }
        var next = self
        next.inversions[input] ^= bit
        return next
    }

    // MARK: 要約

    /// bass_management.js:665-688 の経路の 1 行。
    func routeSummary(width: Int) -> String {
        guard subs != 0 else { return "No Sub outputs selected." }
        let clamped = Self.clampWidth(width)
        var parts: [String] = []
        for input in 0..<clamped
        where roles[input] == Role.managed.rawValue || roles[input] == Role.lfe.rawValue {
            let targets = (0..<clamped).filter { routes[input] & (1 << $0) != 0 }.map { String($0 + 1) }
            let destination = targets.isEmpty ? "no Sub" : "Sub " + targets.joined(separator: ", ")
            parts.append("Ch \(input + 1) \(Self.roleNames[roles[input]]) → \(destination)")
        }
        return parts.isEmpty ? "No managed or LFE inputs." : parts.joined(separator: " · ")
    }

    // MARK: 設計の鍵

    /// 設計し直すかどうかはこれで決める。上流の _designSignature（:237-239）は
    /// ro / fc / sl / lo / lf / ls を丸ごと比べるが、出てくる係数を決めるのは
    /// 「どの入力に、どの (cutoff, slope) の LP が掛かるか」とレート・taps・処理幅だけ。
    /// Full Range の Ch の fc を動かしただけで数秒の設計をやり直さないよう、それだけを持つ。
    func designKey(sampleRate: Double, width: Int) -> BassManagementDesignKey {
        let clamped = Self.clampWidth(width)
        let filters = (0..<clamped).compactMap { ch -> BassManagementDesignKey.Filter? in
            guard let f = filter(for: ch) else { return nil }
            return BassManagementDesignKey.Filter(channel: ch, cutoff: f.cutoff, slope: f.slope)
        }
        // design-core.js:22。丸めてから 8000〜768000 に収める。
        let raw = sampleRate.isFinite ? sampleRate : 48000
        let rate = Int((min(max(raw, 8000), 768000) + 0.5).rounded(.down))
        return BassManagementDesignKey(sampleRate: rate, width: clamped, taps: taps, filters: filters)
    }

    // MARK: 丸め

    /// design-core.js:23。1〜16。
    static func clampWidth(_ width: Int) -> Int { min(max(width, 1), channelCount) }

    /// design-core.js:31-32 と :37。20〜300、数でなければ既定。
    static func cutoff(_ value: Double, fallback: Double) -> Double {
        value.isFinite ? min(max(value, 20), 300) : fallback
    }

    /// design-core.js:33-36。24 / 48 / 96 以外は 24。
    static func slope(_ value: Int) -> Int { slopeChoices.contains(value) ? value : 24 }
}

/// 1 回の設計を決めるもの。これが同じなら係数も同じ。
struct BassManagementDesignKey: Hashable, Sendable {
    struct Filter: Hashable, Sendable {
        let channel: Int
        let cutoff: Double
        let slope: Int
    }

    /// 整数。カーネルはペイロードの +12 が lround(処理レート) と一致するかを見る（kernel.cpp:271）。
    let sampleRate: Int
    /// 処理幅。begin の inputCount と processingChannels（kernel.cpp:216-220）。
    let width: Int
    let taps: Int
    /// 入力の順。kernel.cpp:249-252 と 275-281 が経路をこの順で数える。
    let filters: [Filter]
}
